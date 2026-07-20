//! VM — стек-машина Zython (аналог Python/ceval.c).
//! Трамплинированный цикл по фреймам: вызовы, исключения с размоткой,
//! генераторы, потоки с GIL.

const std = @import("std");
const object = @import("../object/object.zig");
const opcode_mod = @import("opcode.zig");
const ops = @import("ops.zig");

pub const Obj = object.Obj;
const Frame = object.Frame;
const Code = object.Code;
const Dict = object.Dict;
const KwArgs = object.KwArgs;
const Opcode = opcode_mod.Opcode;
pub const Runtime = @import("../runtime/runtime.zig").Runtime;

pub const MAX_RECURSION = 1000;
pub const GIL_CHECK_INTERVAL = 2000;

// ============================================================
// ThreadState — аналог PyThreadState
// ============================================================

pub const ThreadState = struct {
    id: usize,
    frames: std.ArrayList(*Frame),
    // текущее пропагируемое исключение + стек обрабатываемых (sys.exc_info)
    cur_exc: ?Obj = null,
    handled: std.ArrayList(Obj) = .empty,
    gil_ticks: u32 = 0,
    held_gil: bool = true,
    return_value: ?Obj = null,
    // для _thread
    thread_handle: ?std.Thread = null,
    finished: bool = false,
    uncaught: ?Obj = null, // необработанное исключение потока
};

// ============================================================
// VM
// ============================================================

pub const VM = struct {
    rt: *Runtime,
    gpa: std.mem.Allocator, // алиас rt.gpa (Dict-API принимает rt-like)
    depth: usize = 0,
    repr_depth: usize = 0,

    gil: std.Io.Mutex = .init,
    threads: std.ArrayList(*ThreadState),
    threads_mutex: std.Io.Mutex = .init,
    interrupt_requested: bool = false,

    last_yielded: ?Obj = null,

    pub fn init(rt: *Runtime) !*VM {
        const vm = try rt.gpa.create(VM);
        vm.* = .{
            .rt = rt,
            .gpa = rt.gpa,
            .threads = .empty,
        };
        return vm;
    }

    const TLS = struct {
        threadlocal var ts: ?*ThreadState = null;
    };

    /// Текущий ThreadState вызывающего потока (создаётся при необходимости).
    pub fn currentHandledExc(self: *VM) ?Obj {
        const ts = self.currentTS();
        if (ts.handled.items.len == 0) return null;
        return ts.handled.items[ts.handled.items.len - 1];
    }

    /// Выполнить код в NAME-области (модуль: locals==globals; класс: свежий dict).
    /// Используется импортом и __build_class__ (аналог exec деревьев CPython).
    pub fn runNameScope(self: *VM, code: *object.Code, globals: *Dict, locals: ?*Dict) anyerror!void {
        const fnobj = try self.rt.newFunction(code.name, code.qualname, code, globals, &.{}, &.{}, null);
        const f = fnobj.v.function;
        const frame = try self.makeFrame(f, &.{}, null);
        frame.locals_dict = locals orelse globals;
        const ts = self.currentTS();
        const mark = ts.frames.items.len;
        try ts.frames.append(self.gpa, frame);
        try self.runUntil(ts, mark);
    }

    pub fn currentTS(self: *VM) *ThreadState {
        if (TLS.ts) |ts| return ts;
        const ts = self.createTS() catch @panic("oom in createTS");
        TLS.ts = ts;
        return ts;
    }

    /// Установить TS для текущего потока (используется дочерними потоками).
    pub fn setCurrentTS(self: *VM, ts: *ThreadState) void {
        _ = self;
        TLS.ts = ts;
    }

    fn createTS(self: *VM) !*ThreadState {
        const ts = try self.gpa.create(ThreadState);
        ts.* = .{ .id = next_thread_id.fetchAdd(1, .monotonic), .frames = .empty };
        self.threads_mutex.lockUncancelable(self.syncIo());
        try self.threads.append(self.gpa, ts);
        self.threads_mutex.unlock(self.syncIo());
        return ts;
    }

    var next_thread_id: std.atomic.Value(usize) = std.atomic.Value(usize).init(1);

    // ============================================================
    // GIL
    // ============================================================

    /// Io-хэндл для синхронизационных примитивов (mutex/cond работают через него).
    fn syncIo(self: *VM) std.Io {
        return self.rt.io orelse unreachable;
    }

    pub fn gilAcquire(self: *VM) void {
        self.gil.lockUncancelable(self.syncIo());
        const ts = self.currentTS();
        ts.held_gil = true;
        ts.gil_ticks = 0;
    }

    pub fn gilRelease(self: *VM) void {
        const ts = self.currentTS();
        ts.held_gil = false;
        self.gil.unlock(self.syncIo());
    }

    fn gilCheckpoint(self: *VM, ts: *ThreadState) void {
        ts.gil_ticks +%= 1;
        if (ts.gil_ticks % GIL_CHECK_INTERVAL != 0) return;
        if (!self.hasOtherThreads()) return;
        self.gilRelease();
        self.syncIo().sleep(std.Io.Duration.zero, .boot) catch {};
        self.gilAcquire();
    }

    fn hasOtherThreads(self: *VM) bool {
        self.threads_mutex.lockUncancelable(self.syncIo());
        defer self.threads_mutex.unlock(self.syncIo());
        var n: usize = 0;
        for (self.threads.items) |t| {
            if (!t.finished) n += 1;
        }
        return n > 1;
    }

    // ============================================================
    // Исключения — хелперы
    // ============================================================

    pub fn excType(self: *VM, name: []const u8) *object.Type {
        return self.rt.exc_types.get(name) orelse self.rt.exception_t;
    }

    fn mkExcMsg(self: *VM, cls: *object.Type, msg: []const u8) anyerror!Obj {
        const e = try self.rt.newExc(cls);
        const msg_obj = try self.rt.newStr(msg);
        const arg_arr = try self.gpa.alloc(Obj, 1);
        arg_arr[0] = msg_obj;
        e.v.exc.args = arg_arr;
        return e;
    }

    /// Исключение с готовым набором args (как вызов cls(*args)).
    pub fn mkExc(self: *VM, cls: *object.Type, args: []const Obj) anyerror!Obj {
        const e = try self.rt.newExc(cls);
        const cp = try self.gpa.alloc(Obj, args.len);
        @memcpy(cp, args);
        e.v.exc.args = cp;
        return e;
    }

    pub fn raiseStr(self: *VM, type_name: []const u8, msg: []const u8) anyerror!void {
        const e = try self.mkExcMsg(self.excType(type_name), msg);
        self.currentTS().cur_exc = e;
        return error.PyExc;
    }

    pub fn raiseFmt(self: *VM, type_name: []const u8, comptime fmt: []const u8, args: anytype) anyerror!void {
        const msg = try std.fmt.allocPrint(self.gpa, fmt, args);
        return self.raiseStr(type_name, msg);
    }

    pub fn raiseObj(self: *VM, exc: Obj) anyerror!void {
        self.currentTS().cur_exc = exc;
        return error.PyExc;
    }

    pub fn raiseType(self: *VM, cls: *object.Type, msg: []const u8) anyerror!void {
        const e = try self.mkExcMsg(cls, msg);
        self.currentTS().cur_exc = e;
        return error.PyExc;
    }

    pub fn isIndexError(self: *VM) bool {
        const ts = self.currentTS();
        const e = ts.cur_exc orelse return false;
        if (e.v != .exc) return false;
        return ops.isSubclass(e.ty, self.excType("IndexError")) or
            ops.isSubclass(e.ty, self.excType("KeyError")) or
            ops.isSubclass(e.ty, self.excType("StopIteration"));
    }

    pub fn isStopIterationValue(self: *VM) bool {
        const ts = self.currentTS();
        const e = ts.cur_exc orelse return false;
        if (e.v != .exc) return false;
        return ops.isSubclass(e.ty, self.excType("StopIteration"));
    }

    pub fn normalizeException(self: *VM, o: Obj) anyerror!Obj {
        switch (o.v) {
            .exc => return o,
            .type_ => |t| {
                if (!ops.isSubclass(t, self.rt.base_exception_t)) {
                    try self.raiseStr("TypeError", "exceptions must derive from BaseException");
                    return error.PyExc;
                }
                return self.rt.newExc(t);
            },
            else => {
                try self.raiseStr("TypeError", "exceptions must derive from BaseException");
                return error.PyExc;
            },
        }
    }

    // ============================================================
    // Стек helpers
    // ============================================================

    inline fn fpop(_: *VM, f: *Frame) Obj {
        return f.stack.pop().?;
    }

    inline fn ftop(_: *VM, f: *Frame) Obj {
        return f.stack.items[f.stack.items.len - 1];
    }

    // ============================================================
    // Фреймы: создание, связывание аргументов
    // ============================================================

    pub fn makeFrame(self: *VM, f: *object.Function, args: []const Obj, kw: ?KwArgs) anyerror!*Frame {
        const code = f.code;
        const frame = try self.gpa.create(Frame);
        const nlocals: usize = code.nlocals;
        const locals = try self.gpa.alloc(Obj, nlocals);
        const locals_set = try self.gpa.alloc(bool, nlocals);
        @memset(locals_set, false);

        const ncells = code.cellvars.len + code.freevars.len;
        const cells = try self.gpa.alloc(*object.Cell, ncells);
        for (0..ncells) |i| cells[i] = try self.rt.newCell(null);

        frame.* = .{
            .code = code,
            .ip = 0,
            .stack = .empty,
            .locals = locals,
            .locals_set = locals_set,
            .cells = cells,
            .globals = f.globals,
            .builtins = self.rt.builtins_dict,
            .blocks = .empty,
        };
        try frame.stack.ensureTotalCapacity(self.gpa, code.stacksize + 16);

        // --- связывание аргументов ---
        const argcount: usize = code.argcount;
        const kwonly: usize = code.kwonly;
        const total_named = argcount + kwonly;

        var npos = args.len;
        var star_args: ?[]Obj = null;
        if (npos > argcount) {
            if (code.flags.varargs) {
                const rest = try self.gpa.alloc(Obj, args.len - argcount);
                @memcpy(rest, args[argcount..]);
                star_args = rest;
                npos = argcount;
            } else {
                try self.raiseFmt("TypeError", "{s}() takes {d} positional arguments but {d} were given", .{ code.name, argcount, args.len });
                return error.PyExc;
            }
        }
        for (0..npos) |i| {
            locals[i] = args[i];
            locals_set[i] = true;
        }
        var vararg_idx: ?usize = null;
        var varkw_idx: ?usize = null;
        var next_slot: usize = total_named;
        if (code.flags.varargs) {
            vararg_idx = next_slot;
            next_slot += 1;
        }
        if (code.flags.varkw) {
            varkw_idx = next_slot;
            next_slot += 1;
        }
        if (star_args) |sa| {
            locals[vararg_idx.?] = try self.rt.newTupleOwned(sa);
            locals_set[vararg_idx.?] = true;
        } else if (code.flags.varargs) {
            locals[vararg_idx.?] = try self.rt.newTuple(&.{});
            locals_set[vararg_idx.?] = true;
        }

        // kwargs
        var extra_kw: ?*Dict = null;
        if (code.flags.varkw) extra_kw = try self.rt.newDict();
        if (kw) |kwargs| {
            outer: for (kwargs.names, 0..) |name, vi| {
                const val = kwargs.vals[vi];
                for (code.varnames[0..total_named], 0..) |vn, si| {
                    if (std.mem.eql(u8, vn, name)) {
                        if (locals_set[si]) {
                            try self.raiseFmt("TypeError", "{s}() got multiple values for argument '{s}'", .{ code.name, name });
                            return error.PyExc;
                        }
                        locals[si] = val;
                        locals_set[si] = true;
                        continue :outer;
                    }
                }
                if (extra_kw) |ek| {
                    const kobj = try self.rt.newStr(name);
                    const h = try self.pyHash(kobj);
                    try ek.setWithHash(self, kobj, val, h);
                } else {
                    try self.raiseFmt("TypeError", "{s}() got an unexpected keyword argument '{s}'", .{ code.name, name });
                    return error.PyExc;
                }
            }
        }

        // defaults
        const defaults = f.defaults;
        const ndef = defaults.len;
        if (ndef > 0) {
            const start = argcount - ndef;
            for (0..ndef) |di| {
                const si = start + di;
                if (!locals_set[si]) {
                    locals[si] = defaults[di];
                    locals_set[si] = true;
                }
            }
        }
        // kwdefaults
        for (0..kwonly) |ki| {
            const si = argcount + ki;
            if (!locals_set[si]) {
                var found = false;
                if (f.kwdefaults) |kwd| {
                    var it = kwd.iterAlive();
                    while (it.next()) |e| {
                        if (e.key.?.v == .str and std.mem.eql(u8, e.key.?.v.str.bytes, code.varnames[si])) {
                            locals[si] = e.val.?;
                            locals_set[si] = true;
                            found = true;
                            break;
                        }
                    }
                }
                if (!found) {
                    try self.raiseFmt("TypeError", "{s}() missing 1 required keyword-only argument: '{s}'", .{ code.name, code.varnames[si] });
                    return error.PyExc;
                }
            }
        }
        // missing positional
        for (0..argcount) |i| {
            if (!locals_set[i]) {
                try self.raiseFmt("TypeError", "{s}() missing 1 required positional argument: '{s}'", .{ code.name, code.varnames[i] });
                return error.PyExc;
            }
        }
        if (varkw_idx) |vki| {
            locals[vki] = try self.rt.mkObj(self.rt.dict_t, .{ .dict = extra_kw.? });
            locals_set[vki] = true;
        }

        // cells из cellvars
        for (code.cellvars, 0..) |cv, ci| {
            for (code.varnames, 0..) |vn, vi| {
                if (std.mem.eql(u8, cv, vn)) {
                    if (vi < nlocals and locals_set[vi]) {
                        cells[ci].v = locals[vi];
                        locals_set[vi] = false;
                        locals[vi] = undefined;
                    }
                    break;
                }
            }
        }
        // freevars из замыкания
        for (code.freevars, 0..) |_, fi| {
            if (fi < f.closure.len) {
                cells[code.cellvars.len + fi] = f.closure[fi];
            }
        }
        return frame;
    }

    pub fn runFunction(self: *VM, f: *object.Function, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
        const ts = self.currentTS();
        if (self.depth >= MAX_RECURSION) {
            try self.raiseStr("RecursionError", "maximum recursion depth exceeded");
            return error.PyExc;
        }
        const frame = try self.makeFrame(f, args, kw);
        self.depth += 1;
        frame.depth_counted = true;
        const mark = ts.frames.items.len;
        try ts.frames.append(self.gpa, frame);
        try self.runUntil(ts, mark);
        if (mark == 0) {
            // верхний уровень: returnFromFrame положил результат в ts.return_value
            const rv = ts.return_value;
            ts.return_value = null;
            return rv orelse self.rt.newNone();
        }
        // Кооперативная модель: RETURN_VALUE кадра кладёт результат на стек кадра-вызывателя
        // (frames[mark-1]) — снимаем его оттуда (returnFromFrame в vm.x / CPython analog).
        const caller = ts.frames.items[mark - 1];
        const rv = caller.stack.pop();
        return rv orelse self.rt.newNone();
    }

    pub fn runUntil(self: *VM, ts: *ThreadState, mark: usize) anyerror!void {
        while (ts.frames.items.len > mark) {
            const frame = ts.frames.items[ts.frames.items.len - 1];
            self.executeFrame(ts, frame) catch |err| {
                if (err == error.PyExc) {
                    try self.unwind(ts, frame, mark);
                    continue;
                }
                if (err == error.GenYield) {
                    // генератор на вершине, но нас не просили его крутить — не должно произойти
                    return err;
                }
                return err;
            };
        }
    }

    // ============================================================
    // Размотка исключений
    // ============================================================

    fn unwind(self: *VM, ts: *ThreadState, start_frame: *Frame, mark: usize) anyerror!void {
        var frame_opt: ?*Frame = start_frame;
        while (frame_opt) |frame| {
            while (frame.blocks.items.len > 0) {
                const exc = ts.cur_exc.?;
                const blk = frame.blocks.pop().?;
                frame.stack.shrinkRetainingCapacity(blk.stack_lvl);
                switch (blk.kind) {
                    .except_ => {
                        try ts.handled.append(self.gpa, exc);
                        ts.cur_exc = null;
                        try frame.stack.append(self.gpa, exc);
                        frame.ip = blk.handler;
                        return;
                    },
                    .finally_ => {
                        try frame.stack.append(self.gpa, exc);
                        ts.cur_exc = null;
                        frame.pending_exc = exc;
                        frame.ip = blk.handler;
                        return;
                    },
                    .with_ => {
                        ts.cur_exc = null;
                        const exit_fn = blk.exit_fn.?;
                        const exc_ty = try self.rt.mkObj(self.rt.type_t, .{ .type_ = exc.ty });
                        const res = self.pyCall(exit_fn, &.{ exc_ty, exc, self.rt.newNone() }, null) catch |e| {
                            if (e == error.PyExc) {
                                // __exit__ бросил новое исключение — продолжаем с ним
                                continue;
                            }
                            return e;
                        };
                        if (res.isTruthy()) {
                            ts.cur_exc = null;
                            frame.pending_exc = null;
                            frame.ip = blk.after_pc;
                            return;
                        }
                        ts.cur_exc = exc;
                        continue;
                    },
                }
            }
            // нет обработчиков — снимаем фрейм
            const exc = ts.cur_exc orelse return;
            self.addTbToExc(exc, frame);
            if (frame.depth_counted) {
                self.depth -= 1;
                frame.depth_counted = false;
            }
            frame.stack.deinit(self.gpa);
            _ = ts.frames.pop();
            if (ts.frames.items.len <= mark) {
                ts.cur_exc = exc;
                return error.PyExc;
            }
            frame_opt = ts.frames.items[ts.frames.items.len - 1];
        }
    }

    fn addTbToExc(self: *VM, exc: Obj, frame: *Frame) void {
        if (exc.v != .exc) return;
        const e = exc.v.exc;
        e.tb.append(self.gpa, .{
            .filename = frame.code.filename,
            .lineno = frame.lineNo(),
            .name = frame.code.qualname,
        }) catch {};
    }

    // ============================================================
    // Главный цикл интерпретатора
    // ============================================================

    fn executeFrame(self: *VM, ts: *ThreadState, frame: *Frame) anyerror!void {
        const code = frame.code.code;
        const consts = frame.code.consts;
        const names = frame.code.names;

        while (frame.ip < code.len) {
            const pc = frame.ip;
            const op: Opcode = @enumFromInt(code[pc]);
            const arg: u16 = @as(u16, code[pc + 1]) | (@as(u16, code[pc + 2]) << 8);
            frame.ip = pc + 3;

            switch (op) {
                .NOP, .CACHE => {},
                .RESUME => self.gilCheckpoint(ts),
                .END => {
                    try self.returnFromFrame(ts, frame, self.rt.newNone());
                    return;
                },
                .POP_TOP => _ = self.fpop(frame),
                .DUP_TOP => {
                    const v = self.ftop(frame);
                    try frame.stack.append(self.gpa, v);
                },
                .DUP_TOP_TWO => {
                    const n = frame.stack.items.len;
                    const b = frame.stack.items[n - 1];
                    const a = frame.stack.items[n - 2];
                    try frame.stack.append(self.gpa, a);
                    try frame.stack.append(self.gpa, b);
                },
                .ROT_TWO => {
                    const n = frame.stack.items.len;
                    const tmp = frame.stack.items[n - 1];
                    frame.stack.items[n - 1] = frame.stack.items[n - 2];
                    frame.stack.items[n - 2] = tmp;
                },
                .ROT_THREE => {
                    const n = frame.stack.items.len;
                    const tmp = frame.stack.items[n - 1];
                    frame.stack.items[n - 1] = frame.stack.items[n - 2];
                    frame.stack.items[n - 2] = frame.stack.items[n - 3];
                    frame.stack.items[n - 3] = tmp;
                },

                .LOAD_CONST => try frame.stack.append(self.gpa, consts[arg]),
                .LOAD_NONE => try frame.stack.append(self.gpa, self.rt.newNone()),
                .LOAD_TRUE => try frame.stack.append(self.gpa, self.rt.true_obj),
                .LOAD_FALSE => try frame.stack.append(self.gpa, self.rt.false_obj),
                .LOAD_ELLIPSIS => try frame.stack.append(self.gpa, self.rt.ellipsis_obj),

                .LOAD_NAME => {
                    const name = names[arg];
                    if (try ops.dictGetStr(frame.locals_dict.?, self, name)) |v| {
                        try frame.stack.append(self.gpa, v);
                    } else if (try ops.dictGetStr(frame.globals, self, name)) |v| {
                        try frame.stack.append(self.gpa, v);
                    } else if (try ops.dictGetStr(frame.builtins, self, name)) |v| {
                        try frame.stack.append(self.gpa, v);
                    } else {
                        try self.raiseFmt("NameError", "name '{s}' is not defined", .{name});
                        return error.PyExc;
                    }
                },
                .STORE_NAME => {
                    const v = self.fpop(frame);
                    try ops.dictSetStr(frame.locals_dict.?, self, names[arg], v);
                },
                .DELETE_NAME => {
                    if (!(try ops.dictDelStr(frame.locals_dict.?, self, names[arg]))) {
                        try self.raiseFmt("NameError", "name '{s}' is not defined", .{names[arg]});
                        return error.PyExc;
                    }
                },
                .LOAD_FAST => {
                    if (arg >= frame.locals.len or !frame.locals_set[arg]) {
                        try self.raiseFmt("UnboundLocalError", "local variable '{s}' referenced before assignment", .{if (arg < frame.code.varnames.len) frame.code.varnames[arg] else "?"});
                        return error.PyExc;
                    }
                    try frame.stack.append(self.gpa, frame.locals[arg]);
                },
                .STORE_FAST => {
                    const v = self.fpop(frame);
                    frame.locals[arg] = v;
                    frame.locals_set[arg] = true;
                },
                .DELETE_FAST => {
                    if (!frame.locals_set[arg]) {
                        try self.raiseFmt("UnboundLocalError", "local variable '{s}' referenced before assignment", .{if (arg < frame.code.varnames.len) frame.code.varnames[arg] else "?"});
                        return error.PyExc;
                    }
                    frame.locals_set[arg] = false;
                },
                .LOAD_DEREF, .LOAD_CLASSDEREF => {
                    const c = frame.cells[arg].v;
                    if (c == null) {
                        try self.raiseFmt("NameError", "free variable referenced before assignment in enclosing scope", .{});
                        return error.PyExc;
                    }
                    try frame.stack.append(self.gpa, c.?);
                },
                .STORE_DEREF => {
                    const v = self.fpop(frame);
                    frame.cells[arg].v = v;
                },
                .DELETE_DEREF => frame.cells[arg].v = null,
                .LOAD_GLOBAL => {
                    const name = names[arg];
                    if (try ops.dictGetStr(frame.globals, self, name)) |v| {
                        try frame.stack.append(self.gpa, v);
                    } else if (try ops.dictGetStr(frame.builtins, self, name)) |v| {
                        try frame.stack.append(self.gpa, v);
                    } else {
                        try self.raiseFmt("NameError", "name '{s}' is not defined", .{name});
                        return error.PyExc;
                    }
                },
                .STORE_GLOBAL => {
                    const v = self.fpop(frame);
                    try ops.dictSetStr(frame.globals, self, names[arg], v);
                },
                .DELETE_GLOBAL => {
                    if (!(try ops.dictDelStr(frame.globals, self, names[arg]))) {
                        try self.raiseFmt("NameError", "name '{s}' is not defined", .{names[arg]});
                        return error.PyExc;
                    }
                },
                .MAKE_CELL, .COPY_FREE_VARS => {},
                .LOAD_CLOSURE => {
                    const cell_obj = try self.rt.mkObj(self.rt.cell_t, .{ .cell = frame.cells[arg] });
                    try frame.stack.append(self.gpa, cell_obj);
                },

                .BUILD_TUPLE => {
                    const items = try self.gpa.alloc(Obj, arg);
                    var i: usize = arg;
                    while (i > 0) {
                        i -= 1;
                        items[i] = self.fpop(frame);
                    }
                    try frame.stack.append(self.gpa, try self.rt.newTupleOwned(items));
                },
                .BUILD_LIST => {
                    const list = try self.rt.newList();
                    const tmp = try self.gpa.alloc(Obj, arg);
                    var i: usize = arg;
                    while (i > 0) {
                        i -= 1;
                        tmp[i] = self.fpop(frame);
                    }
                    try list.v.list.items.appendSlice(self.gpa, tmp);
                    try frame.stack.append(self.gpa, list);
                },
                .BUILD_SET => {
                    const tmp = try self.gpa.alloc(Obj, arg);
                    var i: usize = arg;
                    while (i > 0) {
                        i -= 1;
                        tmp[i] = self.fpop(frame);
                    }
                    try frame.stack.append(self.gpa, try self.rt.newSetObj(false, tmp));
                },
                .BUILD_MAP => {
                    const d = try self.rt.newDictObj();
                    var i: usize = 0;
                    while (i < arg) : (i += 1) {
                        const val = self.fpop(frame);
                        const key = self.fpop(frame);
                        const h = try self.pyHash(key);
                        try d.v.dict.setWithHash(self, key, val, h);
                    }
                    try frame.stack.append(self.gpa, d);
                },
                .MAP_ADD => {
                    // arg = сколько значений выше dict на стеке (включая k,v)
                    const val = self.fpop(frame);
                    const key = self.fpop(frame);
                    const d = frame.stack.items[frame.stack.items.len + 1 - arg];
                    const h = try self.pyHash(key);
                    try d.v.dict.setWithHash(self, key, val, h);
                },
                .SET_ADD => {
                    // arg = сколько значений выше set на стеке (включая item)
                    const item = self.fpop(frame);
                    const s = frame.stack.items[frame.stack.items.len - arg];
                    const set = if (s.v == .set) s.v.set else s.v.frozenset;
                    const h = try self.pyHash(item);
                    try set.dict.setWithHash(self, item, self.rt.newNone(), h);
                },
                .LIST_APPEND => {
                    // arg = сколько значений выше list на стеке (включая item)
                    const item = self.fpop(frame);
                    const l = frame.stack.items[frame.stack.items.len - arg];
                    try l.v.list.items.append(self.gpa, item);
                },
                .BUILD_CONST_KEY_MAP => {
                    const keys = consts[arg].v.tuple;
                    const d = try self.rt.newDictObj();
                    // значения лежат на стеке в прямом порядке (v1..vn сверху вниз);
                    // выгребаем в буфер и вставляем в исходном порядке — dict сохраняет insertion order
                    const tmp = try self.gpa.alloc(Obj, keys.len);
                    defer self.gpa.free(tmp);
                    var j: usize = keys.len;
                    while (j > 0) {
                        j -= 1;
                        tmp[j] = self.fpop(frame);
                    }
                    for (keys, 0..) |key, i| {
                        const h = try self.pyHash(key);
                        try d.v.dict.setWithHash(self, key, tmp[i], h);
                    }
                    try frame.stack.append(self.gpa, d);
                },
                .BUILD_STRING => {
                    var buf: std.ArrayList(u8) = .empty;
                    const parts = try self.gpa.alloc(Obj, arg);
                    var i: usize = arg;
                    while (i > 0) {
                        i -= 1;
                        parts[i] = self.fpop(frame);
                    }
                    for (parts) |p| {
                        if (p.v == .str) try buf.appendSlice(self.gpa, p.v.str.bytes);
                    }
                    try frame.stack.append(self.gpa, try self.rt.newStrOwned(try buf.toOwnedSlice(self.gpa)));
                },
                .BUILD_SLICE => {
                    var step: ?Obj = null;
                    if (arg == 3) step = self.fpop(frame);
                    const stop = self.fpop(frame);
                    const start = self.fpop(frame);
                    try frame.stack.append(self.gpa, try self.rt.newSlice(start, stop, step));
                },
                .UNPACK_SEQUENCE => {
                    const seq = self.fpop(frame);
                    const items = try self.collectSequence(seq, arg);
                    if (items.len != arg) {
                        if (items.len < arg) {
                            try self.raiseFmt("ValueError", "not enough values to unpack (expected {d}, got {d})", .{ arg, items.len });
                        } else {
                            try self.raiseFmt("ValueError", "too many values to unpack (expected {d})", .{arg});
                        }
                        return error.PyExc;
                    }
                    var i: usize = arg;
                    while (i > 0) {
                        i -= 1;
                        try frame.stack.append(self.gpa, items[i]);
                    }
                },
                .UNPACK_EX => {
                    const before: usize = arg & 0xff;
                    const after: usize = arg >> 8;
                    const seq = self.fpop(frame);
                    const items = try self.collectSequence(seq, before + after);
                    if (items.len < before + after) {
                        try self.raiseFmt("ValueError", "not enough values to unpack (expected at least {d}, got {d})", .{ before + after, items.len });
                        return error.PyExc;
                    }
                    // after элементов (в обратном порядке)
                    var cnt: usize = after;
                    var ii: usize = items.len;
                    while (cnt > 0) {
                        cnt -= 1;
                        ii -= 1;
                        try frame.stack.append(self.gpa, items[ii]);
                    }
                    const mid = items[before .. items.len - after];
                    try frame.stack.append(self.gpa, try self.rt.newListFrom(mid));
                    cnt = before;
                    while (cnt > 0) {
                        cnt -= 1;
                        try frame.stack.append(self.gpa, items[cnt]);
                    }
                },
                .LIST_EXTEND => {
                    const it = self.fpop(frame);
                    const l = self.ftop(frame);
                    const iter = try self.pyIter(it);
                    while (try self.pyNext(iter)) |item| {
                        try l.v.list.items.append(self.gpa, item);
                    }
                },
                .SET_UPDATE => {
                    const it = self.fpop(frame);
                    const s_obj = self.ftop(frame);
                    const s = if (s_obj.v == .set) s_obj.v.set else s_obj.v.frozenset;
                    const iter = try self.pyIter(it);
                    while (try self.pyNext(iter)) |item| {
                        const h = try self.pyHash(item);
                        try s.dict.setWithHash(self, item, self.rt.newNone(), h);
                    }
                },
                .DICT_UPDATE, .DICT_MERGE => {
                    const it = self.fpop(frame);
                    const d = self.ftop(frame);
                    if (it.v == .dict) {
                        var e_iter = it.v.dict.iterAlive();
                        while (e_iter.next()) |e| {
                            const h = try self.pyHash(e.key.?);
                            try d.v.dict.setWithHash(self, e.key.?, e.val.?, h);
                        }
                    } else if (op == .DICT_UPDATE) {
                        const iter = try self.pyIter(it);
                        while (try self.pyNext(iter)) |pair| {
                            const kv = try self.collectSequence(pair, 2);
                            if (kv.len != 2) {
                                try self.raiseFmt("ValueError", "dictionary update sequence element #{d} has length {d}; 2 is required", .{ 0, kv.len });
                                return error.PyExc;
                            }
                            const h = try self.pyHash(kv[0]);
                            try d.v.dict.setWithHash(self, kv[0], kv[1], h);
                        }
                    } else {
                        try self.raiseStr("TypeError", "argument is not a mapping");
                        return error.PyExc;
                    }
                },

                .BINARY_OP => {
                    const b = self.fpop(frame);
                    const a = self.fpop(frame);
                    const bop: opcode_mod.BinaryOp = @enumFromInt(@as(u8, @truncate(arg)));
                    const r = try self.pyBinaryOp(bop, a, b);
                    try frame.stack.append(self.gpa, r);
                },
                .UNARY_OP => {
                    const a = self.fpop(frame);
                    const uop: opcode_mod.UnaryOp = @enumFromInt(@as(u8, @truncate(arg)));
                    const r = try self.pyUnaryOp(uop, a);
                    try frame.stack.append(self.gpa, r);
                },
                .COMPARE_OP => {
                    const b = self.fpop(frame);
                    const a = self.fpop(frame);
                    const cop: ops.CompareOp = @enumFromInt(@as(u8, @truncate(arg)));
                    const r = try ops.pyRichCompare(self, cop, a, b);
                    try frame.stack.append(self.gpa, r);
                },
                .CONTAINS_OP => {
                    const b = self.fpop(frame);
                    const a = self.fpop(frame);
                    const r = try self.pyContains(b, a);
                    try frame.stack.append(self.gpa, self.rt.newBool(if (arg == 1) !r else r));
                },
                .IS_OP => {
                    const b = self.fpop(frame);
                    const a = self.fpop(frame);
                    // типы: один Type = один класс, но Obj-обёрток может быть много →
                    // сравниваем Type-указатель (иначе `base is object` ломается).
                    const is_ = if (a.v == .type_ and b.v == .type_) a.v.type_ == b.v.type_ else a == b;
                    try frame.stack.append(self.gpa, self.rt.newBool(if (arg == 1) !is_ else is_));
                },

                .LOAD_ATTR => {
                    const o = self.fpop(frame);
                    const v = try ops.pyGetAttr(self, o, names[arg]);
                    try frame.stack.append(self.gpa, v);
                },
                .STORE_ATTR => {
                    // стек компилятора: [value, obj] (obj сверху)
                    const o = self.fpop(frame);
                    const v = self.fpop(frame);
                    try ops.pySetAttr(self, o, names[arg], v);
                },
                .DELETE_ATTR => {
                    const o = self.fpop(frame);
                    try ops.pyDelAttr(self, o, names[arg]);
                },
                .LOAD_SUBSCR => {
                    const sub = self.fpop(frame);
                    const o = self.fpop(frame);
                    const v = try self.pyGetItem(o, sub);
                    try frame.stack.append(self.gpa, v);
                },
                .STORE_SUBSCR => {
                    const sub = self.fpop(frame);
                    const o = self.fpop(frame);
                    const v = self.fpop(frame);
                    try self.pySetItem(o, sub, v);
                },
                .DELETE_SUBSCR => {
                    const sub = self.fpop(frame);
                    const o = self.fpop(frame);
                    try self.pyDelItem(o, sub);
                },

                .GET_ITER, .GET_YIELD_FROM_ITER => {
                    const o = self.fpop(frame);
                    try frame.stack.append(self.gpa, try self.pyIter(o));
                },
                .GET_LEN => {
                    const o = self.ftop(frame);
                    const n = try self.pyLen(o);
                    try frame.stack.append(self.gpa, try self.rt.newInt(@intCast(n)));
                },
                .FOR_ITER => {
                    const it = self.ftop(frame);
                    const next_v = try self.pyNext(it);
                    if (next_v) |v| {
                        try frame.stack.append(self.gpa, v);
                    } else {
                        _ = self.fpop(frame); // pop iterator
                        frame.ip = pc + 3 + arg;
                    }
                },

                .JUMP_FORWARD => frame.ip += arg,
                .JUMP_ABSOLUTE => frame.ip = arg,
                .JUMP_BACKWARD => {
                    frame.ip -= arg;
                    self.gilCheckpoint(ts);
                },
                .POP_JUMP_IF_FALSE, .POP_JUMP_IF_TRUE => {
                    const v = self.fpop(frame);
                    const t = try self.pyTruthy(v);
                    const want_true = op == .POP_JUMP_IF_TRUE;
                    if (t == want_true) frame.ip = arg;
                },
                .JUMP_IF_FALSE_OR_POP, .JUMP_IF_TRUE_OR_POP => {
                    const v = self.ftop(frame);
                    const t = try self.pyTruthy(v);
                    const want_true = op == .JUMP_IF_TRUE_OR_POP;
                    if (t == want_true) {
                        frame.ip = arg;
                    } else {
                        _ = self.fpop(frame);
                    }
                },
                .JUMP_IF_NOT_EXC_MATCH => {
                    // стек: […, exc, exc_dup, type]; на любой ветке остаётся […, exc]
                    const match = self.fpop(frame); // тип исключения (сверху)
                    const exc = self.fpop(frame); // дубликат исключения
                    const m = try self.excMatches(exc, match);
                    if (!m) frame.ip = arg;
                },

                .KW_NAMES => {
                    const t = consts[arg];
                    const cnt = t.v.tuple.len;
                    const arr = try self.gpa.alloc([]const u8, cnt);
                    for (t.v.tuple, 0..) |s, i| arr[i] = s.v.str.bytes;
                    frame.kwnames = arr;
                },
                .CALL => {
                    const nargs: usize = arg & 0xff;
                    const nkw: usize = arg >> 8;
                    const total = nargs + nkw;
                    var kw: ?KwArgs = null;
                    if (nkw > 0) {
                        const kn = frame.kwnames orelse &.{};
                        frame.kwnames = null;
                        kw = .{
                            .names = kn,
                            .vals = frame.stack.items[frame.stack.items.len - nkw ..],
                        };
                    }
                    // позиционные — БЕЗ kw-значений (kw отдельно)
                    const args = frame.stack.items[frame.stack.items.len - total .. frame.stack.items.len - nkw];
                    const func = frame.stack.items[frame.stack.items.len - total - 1];

                    var f: ?*object.Function = null;
                    var self_obj: ?Obj = null;
                    switch (func.v) {
                        .function => |ff| f = ff,
                        .method => |m| {
                            if (m.func.v == .function) {
                                f = m.func.v.function;
                                self_obj = m.self_obj;
                            }
                        },
                        else => {},
                    }

                    if (f) |ff| {
                        var args2 = args;
                        if (self_obj) |so| {
                            const with_self = try self.gpa.alloc(Obj, args.len + 1);
                            with_self[0] = so;
                            @memcpy(with_self[1..], args);
                            args2 = with_self;
                        }
                        if (self.depth >= MAX_RECURSION) {
                            try self.raiseStr("RecursionError", "maximum recursion depth exceeded");
                            return error.PyExc;
                        }
                        const nf = try self.makeFrame(ff, args2, kw);
                        frame.stack.shrinkRetainingCapacity(frame.stack.items.len - total - 1);
                        if (ff.code.flags.generator or ff.code.flags.coroutine) {
                            const gen = try self.rt.newGenerator(nf);
                            try frame.stack.append(self.gpa, gen);
                        } else {
                            self.depth += 1;
                            nf.depth_counted = true;
                            try ts.frames.append(self.gpa, nf);
                            // runUntil прокрутит кадр callee, затем вернётся сюда
                            return;
                        }
                    } else {
                        // shrink считаем от состояния стека ДО вызова: builtin может
                        // временно растить стек caller'а (например __build_class__ →
                        // execClassBody → runUntil кладёт return_value тела класса).
                        // Весь этот мусор отбрасывается; результат builtin возвращает сам.
                        const len_before = frame.stack.items.len;
                        const result = try self.pyCallRaw(func, args, kw);
                        frame.stack.shrinkRetainingCapacity(len_before - total - 1);
                        try frame.stack.append(self.gpa, result);
                    }
                },
                .CALL_FUNCTION_EX => {
                    const kwargs = self.fpop(frame);
                    const callargs = self.fpop(frame);
                    const func = self.fpop(frame);
                    var args_list: []const Obj = &.{};
                    if (callargs.v == .tuple) {
                        args_list = callargs.v.tuple;
                    } else {
                        args_list = try self.collectSequence(callargs, null);
                    }
                    var kw: ?KwArgs = null;
                    if (!kwargs.isNone()) {
                        if (kwargs.v != .dict) {
                            try self.raiseStr("TypeError", "argument after ** must be a mapping");
                            return error.PyExc;
                        }
                        const d = kwargs.v.dict;
                        const cnt = d.len();
                        const names_arr = try self.gpa.alloc([]const u8, cnt);
                        const vals_arr = try self.gpa.alloc(Obj, cnt);
                        var idx: usize = 0;
                        var it = d.iterAlive();
                        while (it.next()) |e| {
                            if (e.key.?.v != .str) {
                                try self.raiseStr("TypeError", "keywords must be strings");
                                return error.PyExc;
                            }
                            names_arr[idx] = e.key.?.v.str.bytes;
                            vals_arr[idx] = e.val.?;
                            idx += 1;
                        }
                        kw = .{ .names = names_arr, .vals = vals_arr };
                    }
                    const result = try ops.pyCall(self, func, args_list, kw);
                    try frame.stack.append(self.gpa, result);
                },
                .MAKE_FUNCTION => {
                    // Порядок на стеке (TOS сверху): annotations? / closure? / kwdefaults? / defaults? / code
                    var closure: []*object.Cell = &.{};
                    var defaults: []Obj = &.{};
                    var kwdefaults: ?*Dict = null;
                    if (arg & 0x08 != 0) {
                        _ = self.fpop(frame); // annotations — пропускаем
                    }
                    if (arg & 0x04 != 0) {
                        const ct = self.fpop(frame);
                        const cells = try self.gpa.alloc(*object.Cell, ct.v.tuple.len);
                        for (ct.v.tuple, 0..) |c_, i| cells[i] = c_.v.cell;
                        closure = cells;
                    }
                    if (arg & 0x02 != 0) {
                        const kd = self.fpop(frame);
                        kwdefaults = kd.v.dict;
                    }
                    if (arg & 0x01 != 0) {
                        const dt = self.fpop(frame);
                        defaults = dt.v.tuple;
                    }
                    const qualcode = self.fpop(frame); // code obj
                    const c = qualcode.v.code;
                    const fn_obj = try self.rt.newFunction(c.name, c.qualname, c, frame.globals, closure, defaults, kwdefaults);
                    try frame.stack.append(self.gpa, fn_obj);
                },
                .LOAD_METHOD_OPT, .CALL_METHOD_OPT => unreachable,
                .LOAD_BUILD_CLASS => {
                    if (try ops.dictGetStr(self.rt.builtins_dict, self, "__build_class__")) |v| {
                        try frame.stack.append(self.gpa, v);
                    } else {
                        try self.raiseStr("NameError", "__build_class__ not found");
                        return error.PyExc;
                    }
                },

                .SETUP_EXCEPT, .SETUP_FINALLY => {
                    try frame.blocks.append(self.gpa, .{
                        .kind = if (op == .SETUP_EXCEPT) .except_ else .finally_,
                        .handler = pc + 3 + arg,
                        .stack_lvl = frame.stack.items.len,
                    });
                },
                .SETUP_WITH => {
                    const exit_fn = self.fpop(frame);
                    try frame.blocks.append(self.gpa, .{
                        .kind = .with_,
                        .handler = 0,
                        .stack_lvl = frame.stack.items.len,
                        .after_pc = pc + 3 + arg,
                        .exit_fn = exit_fn,
                    });
                },
                .POP_BLOCK => _ = frame.blocks.pop(),
                .POP_EXCEPT => {
                    if (ts.handled.items.len > 0) _ = ts.handled.pop();
                },
                .RAISE => {
                    switch (arg) {
                        0 => {
                            const handled = self.currentHandledExc() orelse {
                                try self.raiseStr("RuntimeError", "No active exception to re-raise");
                                return error.PyExc;
                            };
                            ts.cur_exc = handled;
                            return error.PyExc;
                        },
                        1 => {
                            const o = self.fpop(frame);
                            const exc = try self.normalizeException(o);
                            if (self.currentHandledExc()) |h| {
                                if (exc.v == .exc) exc.v.exc.context = h;
                            }
                            ts.cur_exc = exc;
                            self.addTbToExc(exc, frame);
                            return error.PyExc;
                        },
                        2 => {
                            const cause = self.fpop(frame);
                            const o = self.fpop(frame);
                            const exc = try self.normalizeException(o);
                            if (exc.v == .exc) {
                                // __context__ ставится всегда (если есть активный handled);
                                // from лишь переключает его отображение (__suppress_context__).
                                if (self.currentHandledExc()) |h| exc.v.exc.context = h;
                                if (!cause.isNone()) {
                                    const cn = try self.normalizeException(cause);
                                    exc.v.exc.cause = cn;
                                }
                                exc.v.exc.suppress_context = true;
                            }
                            ts.cur_exc = exc;
                            self.addTbToExc(exc, frame);
                            return error.PyExc;
                        },
                        else => {},
                    }
                },
                .RAISE_AGAIN => {
                    const handled = self.currentHandledExc() orelse {
                        try self.raiseStr("RuntimeError", "No active exception to re-raise");
                        return error.PyExc;
                    };
                    ts.cur_exc = handled;
                    return error.PyExc;
                },
                .END_FINALLY => {
                    const marker = self.fpop(frame);
                    if (!marker.isNone()) {
                        ts.cur_exc = marker;
                        frame.pending_exc = null;
                        return error.PyExc;
                    }
                },
                .PUSH_EXC_INFO => {
                    const handled = self.currentHandledExc() orelse self.rt.newNone();
                    try frame.stack.append(self.gpa, handled);
                },
                .CHECK_EXC_MATCH => {
                    const exc = self.fpop(frame);
                    const match = self.fpop(frame);
                    const m = try self.excMatches(exc, match);
                    try frame.stack.append(self.gpa, self.rt.newBool(m));
                },
                .LOAD_ASSERTION_ERROR => {
                    const t = self.excType("AssertionError");
                    try frame.stack.append(self.gpa, try self.rt.mkObj(self.rt.type_t, .{ .type_ = t }));
                },

                .IMPORT_NAME => {
                    const fromlist_raw = self.fpop(frame);
                    const level_obj = self.fpop(frame);
                    const level: i64 = if (level_obj.v == .int) level_obj.v.int else 0;
                    // Python None как fromlist означает "обычный import a.b" (не from-import)
                    const fromlist: ?Obj = if (fromlist_raw.v == .none or fromlist_raw.v == .bool_) null else fromlist_raw;
                    const import_mod = @import("../runtime/import.zig");
                    const mod = try import_mod.importModule(self, names[arg], @intCast(level), fromlist, frame.globals, frame);
                    try frame.stack.append(self.gpa, mod);
                },
                .IMPORT_FROM => {
                    const mod = self.ftop(frame);
                    const attr_name = names[arg];
                    const import_mod = @import("../runtime/import.zig");
                    const v = import_mod.importFrom(self, mod, attr_name) catch |e| blk: {
                        if (e == error.PyExc and mod.v == .module) {
                            const ts2 = self.currentTS();
                            const was_import_error = ts2.cur_exc != null and ts2.cur_exc.?.v == .exc and
                                ops.isSubclass(ts2.cur_exc.?.ty, self.excType("ImportError")) and false;
                            _ = was_import_error;
                            if (mod.v.module.path != null) {
                                ts2.cur_exc = null;
                                const full = try std.fmt.allocPrint(self.gpa, "{s}.{s}", .{ mod.v.module.name, attr_name });
                                if (import_mod.importModule(self, full, 0, self.rt.newNone(), frame.globals, frame)) |sub| {
                                    break :blk sub;
                                } else |_| {}
                            }
                        }
                        return e;
                    };
                    try frame.stack.append(self.gpa, v);
                },
                .IMPORT_STAR => {
                    const mod = self.fpop(frame);
                    if (mod.v == .module) {
                        var it = mod.v.module.dict.iterAlive();
                        while (it.next()) |e| {
                            if (e.key.?.v == .str) {
                                const k = e.key.?.v.str.bytes;
                                if (k.len > 0 and k[0] == '_') continue;
                                if (frame.locals_dict) |ld| {
                                    try ops.dictSetStr(ld, self, k, e.val.?);
                                }
                            }
                        }
                    }
                },

                .RETURN_VALUE => {
                    const v = self.fpop(frame);
                    try self.returnFromFrame(ts, frame, v);
                    return;
                },
                .YIELD_VALUE => {
                    const v = self.fpop(frame);
                    self.last_yielded = v;
                    return error.GenYield;
                },
                .YIELD_FROM => {
                    // стек: [iter, sent]; при приостановке стек [iter], ip без изменений
                    const sent = self.fpop(frame);
                    const it = self.ftop(frame);
                    const sub_v = self.yieldFromStep(it, sent) catch |e| {
                        if (e == error.GenYield) {
                            // подгенератор выдал значение — передаём наверх
                            frame.ip = pc;
                            return error.GenYield;
                        }
                        if (e == error.PyExc and self.isStopIterationValue()) {
                            const stop = ts.cur_exc.?;
                            ts.cur_exc = null;
                            _ = self.fpop(frame); // pop iter
                            var val: Obj = self.rt.newNone();
                            if (stop.v.exc.args.len > 0) val = stop.v.exc.args[0];
                            try frame.stack.append(self.gpa, val);
                            frame.ip = pc + 3;
                            continue;
                        }
                        return e;
                    };
                    // подитератор выдал значение — yield наверх
                    self.last_yielded = sub_v;
                    frame.ip = pc;
                    return error.GenYield;
                },
                .FORMAT_VALUE => {
                    var fmt_spec: ?Obj = null;
                    if (arg & opcode_mod.FORMAT_VALUE_WITH_SPEC != 0) {
                        fmt_spec = self.fpop(frame);
                    }
                    const v = self.fpop(frame);
                    const conv: u8 = @truncate(arg & 3);
                    const s = try self.formatValue(v, conv, fmt_spec);
                    try frame.stack.append(self.gpa, s);
                },
                .STORE_ANNOTATION => _ = self.fpop(frame),
                .LOAD_BUILD_CLASS_DONE_PLACEHOLDER => {},
            }
        }
        try self.returnFromFrame(ts, frame, self.rt.newNone());
    }

    fn returnFromFrame(self: *VM, ts: *ThreadState, frame: *Frame, value: Obj) anyerror!void {
        _ = ts.frames.pop();
        const counted = frame.depth_counted;
        if (counted) {
            self.depth -= 1;
            frame.depth_counted = false;
        }
        if (frame.generator) |g| {
            g.finished = true;
            g.frame = null;
            ts.return_value = value;
            return;
        }
        if (ts.frames.items.len == 0) {
            ts.return_value = value;
            return;
        }
        const caller = ts.frames.items[ts.frames.items.len - 1];
        try caller.stack.append(self.gpa, value);
    }

    // ============================================================
    // Генераторы: send/next/throw/close
    // ============================================================

    /// Один шаг итератора для YIELD_FROM. Может бросить GenYield (value в last_yielded),
    /// PyExc+StopIteration (конец) или вернуть значение (которое надо перевыдать наверх).
    fn yieldFromStep(self: *VM, it: Obj, sent: Obj) anyerror!Obj {
        if (it.v == .generator) {
            return self.genSendExplicit(it, sent);
        }
        if (ops.lookupSpecial(self, it, "send")) |send_m| {
            return self.pyCall(send_m, &.{sent}, null);
        }
        const r = try self.pyNext(it);
        if (r == null) {
            const cls = self.excType("StopIteration");
            const e = try self.rt.newExc(cls);
            try self.raiseObj(e);
            return error.PyExc;
        }
        return r.?;
    }

    pub fn genSend(self: *VM, gen: Obj, sent: Obj) anyerror!Obj {
        return self.genSendExplicit(gen, sent);
    }

    /// Возвращает yielded-значение. При завершении бросает StopIteration (value в args).
    /// Приостановка (yield подгенератора) — возвращает значение через обычный return.
    fn genSendExplicit(self: *VM, gen: Obj, sent: Obj) anyerror!Obj {
        const g = gen.v.generator;
        const stop_it = self.excType("StopIteration");
        if (g.finished or g.closed) {
            try self.raiseType(stop_it, "");
            return error.PyExc;
        }
        const ts = self.currentTS();
        const frame = g.frame orelse {
            try self.raiseType(stop_it, "");
            return error.PyExc;
        };

        if (g.started) {
            for (ts.frames.items) |fr| {
                if (fr == frame) {
                    try self.raiseStr("ValueError", "generator already executing");
                    return error.PyExc;
                }
            }
            try frame.stack.append(self.gpa, sent);
        } else {
            if (!sent.isNone()) {
                try self.raiseStr("TypeError", "can't send non-None value to a just-started generator");
                return error.PyExc;
            }
            g.started = true;
        }

        if (!frame.depth_counted) {
            if (self.depth >= MAX_RECURSION) {
                try self.raiseStr("RecursionError", "maximum recursion depth exceeded");
                return error.PyExc;
            }
            self.depth += 1;
            frame.depth_counted = true;
        }
        const mark = ts.frames.items.len;
        try ts.frames.append(self.gpa, frame);

        while (true) {
            self.executeFrame(ts, frame) catch |err| {
                switch (err) {
                    error.GenYield => {
                        _ = ts.frames.pop();
                        const y = self.last_yielded orelse self.rt.newNone();
                        self.last_yielded = null;
                        return y;
                    },
                    error.PyExc => {
                        self.unwind(ts, frame, mark) catch |e2| {
                            if (e2 != error.PyExc) return e2;
                            // исключение вышло из генератора — он мёртв
                            g.finished = true;
                            g.frame = null;
                            return error.PyExc;
                        };
                        continue; // обработано внутри генератора — продолжаем
                    },
                    else => {
                        g.finished = true;
                        g.frame = null;
                        return err;
                    },
                }
            };
            // нормальный выход по return
            g.finished = true;
            g.frame = null;
            const rv = ts.return_value orelse self.rt.newNone();
            ts.return_value = null;
            const e = try self.rt.newExc(stop_it);
            if (!rv.isNone()) {
                const args = try self.gpa.alloc(Obj, 1);
                args[0] = rv;
                e.v.exc.args = args;
            }
            try self.raiseObj(e);
            return error.PyExc;
        }
    }

    // ============================================================
    // iter/next/len/contains (переадресация в protocol-логику)
    // ============================================================

    pub fn pyIter(self: *VM, o: Obj) anyerror!Obj {
        switch (o.v) {
            .list => |l| return self.rt.newIter(.{ .list_iter = .{ .l = l, .i = 0 } }),
            .tuple => |t| return self.rt.newIter(.{ .tuple_iter = .{ .t = t, .i = 0 } }),
            .str => |s| return self.rt.newIter(.{ .str_iter = .{ .s = s, .cp_i = 0 } }),
            .bytes => |b| return self.rt.newIter(.{ .bytes_iter = .{ .b = b.data, .i = 0 } }),
            .bytearray => |b| return self.rt.newIter(.{ .bytes_iter = .{ .b = b.data.items, .i = 0 } }),
            .range => |r| return self.rt.newIter(.{ .range_iter = .{ .r = r, .i = 0 } }),
            .dict => |d| return self.rt.newIter(.{ .dict_iter = .{ .d = d, .i = 0, .kind = .keys } }),
            .set => |s| return self.rt.newIter(.{ .set_iter = .{ .s = s, .i = 0 } }),
            .frozenset => |s| return self.rt.newIter(.{ .set_iter = .{ .s = s, .i = 0 } }),
            .iter, .generator => return o,
            else => {},
        }
        if (ops.lookupSpecial(self, o, "__iter__")) |im| {
            return self.pyCall(im, &.{}, null);
        }
        if (ops.lookupSpecial(self, o, "__getitem__") != null) {
            return self.rt.newIter(.{ .seq_iter = .{ .o = o, .i = 0 } });
        }
        try self.raiseFmt("TypeError", "'{s}' object is not iterable", .{o.ty.name});
        return error.PyExc;
    }

    pub fn pyNext(self: *VM, it: Obj) anyerror!?Obj {
        if (it.v == .iter) {
            return it.v.iter.next(self);
        }
        if (it.v == .generator) {
            const v = self.genSend(it, self.rt.newNone()) catch |e| {
                if (e == error.PyExc and self.isStopIterationValue()) {
                    self.currentTS().cur_exc = null;
                    return null;
                }
                return e;
            };
            return v;
        }
        if (ops.lookupSpecial(self, it, "__next__")) |nm| {
            const v = self.pyCall(nm, &.{}, null) catch |e| {
                if (e == error.PyExc and self.isStopIterationValue()) {
                    self.currentTS().cur_exc = null;
                    return null;
                }
                return e;
            };
            return v;
        }
        try self.raiseFmt("TypeError", "'{s}' object is not an iterator", .{it.ty.name});
        return error.PyExc;
    }

    pub fn pyLen(self: *VM, o: Obj) anyerror!usize {
        switch (o.v) {
            .str => |s| return s.cp_len,
            .bytes => |b| return b.data.len,
            .bytearray => |b| return b.data.items.len,
            .list => |l| return l.items.items.len,
            .tuple => |t| return t.len,
            .dict => |d| return d.len(),
            .set, .frozenset => |s| return s.len(),
            .range => |r| return r.len(),
            else => {},
        }
        if (ops.lookupSpecial(self, o, "__len__")) |lm| {
            const r = try self.pyCall(lm, &.{}, null);
            if (r.v == .int) {
                if (r.v.int < 0) {
                    try self.raiseStr("ValueError", "__len__() should return >= 0");
                    return error.PyExc;
                }
                return @intCast(r.v.int);
            }
            try self.raiseFmt("TypeError", "'{s}' object cannot be interpreted as an integer", .{r.ty.name});
            return error.PyExc;
        }
        try self.raiseFmt("TypeError", "object of type '{s}' has no len()", .{o.ty.name});
        return error.PyExc;
    }

    /// type(name, bases, dict) — трёхаргументная форма (аналог type_new_3 CPython).
    pub fn buildClassFromCall(self: *VM, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
        if (args[0].v != .str) {
            try self.raiseStr("TypeError", "type() argument 1 must be str");
            return error.PyExc;
        }
        const bases = try self.collectSequence(args[1], null);
        if (args[2].v != .dict) {
            try self.raiseStr("TypeError", "type() argument 3 must be dict");
            return error.PyExc;
        }
        // метакласс из bases (самый производный) — как CPython type(name, bases, dict)
        var meta: *object.Type = self.rt.type_t;
        for (bases) |b| {
            if (b.v == .type_) {
                const bmeta = b.v.type_.ty;
                if (ops.isSubclass(bmeta, meta)) meta = bmeta;
            }
        }
        if (meta != self.rt.type_t) {
            return self.buildClassFromCallMeta(meta, args, kw);
        }
        const t = try self.rt.newUserType(args[0].v.str.bytes, self, bases, args[2].v.dict);
        return self.rt.mkObj(self.rt.type_t, .{ .type_ = t });
    }

    /// Прямое создание класса (без dispatch на кастомный __new__) — для type.__new__.
    pub fn buildClassDirect(self: *VM, meta: *object.Type, args: []const Obj) anyerror!Obj {
        if (args.len < 3 or args[0].v != .str) {
            try self.raiseStr("TypeError", "type.__new__() needs (name, bases, dict)");
            return error.PyExc;
        }
        const bases = try self.collectSequence(args[1], null);
        // namespace: dict или dict-подкласс (instance, напр. enum._EnumDict → instance.data)
        const ns_dict: *object.Dict = switch (args[2].v) {
            .dict => |d| d,
            .instance => |i| blk: {
                if (i.data) |d| break :blk d;
                break :blk &i.dict;
            },
            else => {
                try self.raiseStr("TypeError", "type.__new__() argument 3 must be dict");
                return error.PyExc;
            },
        };
        const t = try self.rt.newUserType(args[0].v.str.bytes, self, bases, ns_dict);
        t.ty = meta; // настоящий метакласс класса (нужен для __mro__/isinstance)
        const class_obj = try self.rt.mkObj(meta, .{ .type_ = t });
        // PEP 487: __set_name__(owner, name) на атрибутах класса.
        // Критично для enum: _proto_member.__set_name__ создаёт реальные члены.
        // Ключи собираем заранее — __set_name__ может удалять атрибуты из namespace.
        {
            var sn_names: std.ArrayList(Obj) = .empty;
            var sn_vals: std.ArrayList(Obj) = .empty;
            var it = ns_dict.iterAlive();
            while (it.next()) |e| {
                if (ops.lookupSpecial(self, e.val.?, "__set_name__") != null) {
                    try sn_names.append(self.gpa, e.key.?);
                    try sn_vals.append(self.gpa, e.val.?);
                }
            }
            for (sn_names.items, sn_vals.items) |nm, val| {
                if (ops.lookupSpecial(self, val, "__set_name__")) |sn| {
                    _ = self.pyCall(sn, &.{ class_obj, nm }, null) catch {
                        self.currentTS().cur_exc = null;
                    };
                }
            }
        }
        return class_obj;
    }

    /// Создание класса через вызов метакласса: Meta(name, bases, dict) → класс с ty=meta.
    pub fn buildClassFromCallMeta(self: *VM, meta: *object.Type, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
        if (args[0].v != .str) {
            try self.raiseStr("TypeError", "type() argument 1 must be str");
            return error.PyExc;
        }
        // Кастомный __new__ метакласса (Python-функция, как EnumType.__new__):
        // meta(name, bases, ns) → meta.__new__(meta, name, bases, ns) — аналог CPython type_call.
        if (ops.lookupClass(meta, "__new__")) |new_| {
            switch (new_.v) {
                .function, .method => {
                    const meta_obj = try self.rt.mkObj(self.rt.type_t, .{ .type_ = meta });
                    return self.pyCall(new_, &.{ meta_obj, args[0], args[1], args[2] }, kw);
                },
                .staticm => |s| {
                    const meta_obj = try self.rt.mkObj(self.rt.type_t, .{ .type_ = meta });
                    return self.pyCall(s.callable, &.{ meta_obj, args[0], args[1], args[2] }, kw);
                },
                else => {},
            }
        }
        // default: прямое создание типа
        const bases = try self.collectSequence(args[1], null);
        if (args[2].v != .dict) {
            try self.raiseStr("TypeError", "type() argument 3 must be dict");
            return error.PyExc;
        }
        const t = try self.rt.newUserType(args[0].v.str.bytes, self, bases, args[2].v.dict);
        t.ty = meta; // настоящий метакласс класса
        // новый класс — экземпляр метакласса meta
        return self.rt.mkObj(meta, .{ .type_ = t });
    }

    pub fn pyTruthy(self: *VM, o: Obj) anyerror!bool {
        switch (o.v) {
            .instance, .exc => {},
            else => return o.isTruthy(),
        }
        if (ops.lookupSpecial(self, o, "__bool__")) |bm| {
            const r = try self.pyCall(bm, &.{}, null);
            if (r.v == .bool_) return r.v.bool_;
            try self.raiseStr("TypeError", "__bool__ should return bool");
            return error.PyExc;
        }
        if (ops.lookupSpecial(self, o, "__len__")) |lm| {
            const r = try self.pyCall(lm, &.{}, null);
            if (r.v == .int) return r.v.int != 0;
        }
        return true;
    }

    pub fn pyContains(self: *VM, container: Obj, item: Obj) anyerror!bool {
        switch (container.v) {
            .str => |s| {
                if (item.v != .str) {
                    try self.raiseStr("TypeError", "'in <string>' requires string as left operand");
                    return error.PyExc;
                }
                return std.mem.containsAtLeast(u8, s.bytes, 1, item.v.str.bytes);
            },
            .list => |l| {
                for (l.items.items) |x| {
                    if (try self.pyEq(x, item)) return true;
                }
                return false;
            },
            .tuple => |t| {
                for (t) |x| {
                    if (try self.pyEq(x, item)) return true;
                }
                return false;
            },
            .dict => |d| {
                const h = try self.pyHash(item);
                return (try d.getWithHash(self, item, h)) != null;
            },
            .set => |s| {
                const h = try self.pyHash(item);
                return (try s.dict.getWithHash(self, item, h)) != null;
            },
            .frozenset => |s| {
                const h = try self.pyHash(item);
                return (try s.dict.getWithHash(self, item, h)) != null;
            },
            .bytes => |b| {
                if (item.v == .int) {
                    const c: u8 = @intCast(@mod(item.v.int, 256));
                    return std.mem.indexOfScalar(u8, b.data, c) != null;
                }
                if (item.v == .bytes) {
                    return std.mem.containsAtLeast(u8, b.data, 1, item.v.bytes.data);
                }
                return false;
            },
            .bytearray => |b| {
                if (item.v == .int) {
                    const c: u8 = @intCast(@mod(item.v.int, 256));
                    return std.mem.indexOfScalar(u8, b.data.items, c) != null;
                }
                if (item.v == .bytes) {
                    return std.mem.containsAtLeast(u8, b.data.items, 1, item.v.bytes.data);
                }
                return false;
            },
            .range => {
                if (item.v == .int) return container.v.range.contains(item.v.int);
                if (item.v == .bool_) return container.v.range.contains(@intFromBool(item.v.bool_));
                return false;
            },
            else => {},
        }
        if (ops.lookupSpecial(self, container, "__contains__")) |cm| {
            const r = try self.pyCall(cm, &.{item}, null);
            return r.isTruthy();
        }
        const it = try self.pyIter(container);
        while (try self.pyNext(it)) |x| {
            if (try self.pyEq(x, item)) return true;
        }
        return false;
    }

    // ============================================================
    // getitem/setitem/delitem
    // ============================================================

    pub fn pyGetItem(self: *VM, o: Obj, sub: Obj) anyerror!Obj {
        switch (o.v) {
            .list => |l| {
                switch (sub.v) {
                    .slice => |s| {
                        const idx = s.indices(@intCast(l.items.items.len)) orelse {
                            try self.raiseStr("ValueError", "slice step cannot be zero");
                            return error.PyExc;
                        };
                        const out = try self.rt.newList();
                        var i: i64 = idx[0];
                        var n: i64 = idx[3];
                        while (n > 0) : (n -= 1) {
                            try out.v.list.items.append(self.gpa, l.items.items[@intCast(i)]);
                            i += idx[2];
                        }
                        return out;
                    },
                    else => {
                        const i = try self.indexLike(sub, l.items.items.len);
                        return l.items.items[i];
                    },
                }
            },
            .tuple => |t| {
                switch (sub.v) {
                    .slice => |s| {
                        const idx = s.indices(@intCast(t.len)) orelse {
                            try self.raiseStr("ValueError", "slice step cannot be zero");
                            return error.PyExc;
                        };
                        const out = try self.gpa.alloc(Obj, @intCast(idx[3]));
                        var i: i64 = idx[0];
                        var n: usize = 0;
                        while (n < idx[3]) : (n += 1) {
                            out[n] = t[@intCast(i)];
                            i += idx[2];
                        }
                        return self.rt.newTupleOwned(out);
                    },
                    else => {
                        const i = try self.indexLike(sub, t.len);
                        return t[i];
                    },
                }
            },
            .str => |s| {
                switch (sub.v) {
                    .slice => |sl| {
                        const idx = sl.indices(@intCast(s.cp_len)) orelse {
                            try self.raiseStr("ValueError", "slice step cannot be zero");
                            return error.PyExc;
                        };
                        var buf: std.ArrayList(u8) = .empty;
                        var i: i64 = idx[0];
                        var n: i64 = idx[3];
                        while (n > 0) : (n -= 1) {
                            try buf.appendSlice(self.gpa, s.cpAt(@intCast(i)).?);
                            i += idx[2];
                        }
                        return self.rt.newStrOwned(try buf.toOwnedSlice(self.gpa));
                    },
                    else => {
                        const i = try self.indexLike(sub, s.cp_len);
                        return self.rt.newStr(s.cpAt(i).?);
                    },
                }
            },
            .bytes => |b| {
                switch (sub.v) {
                    .slice => |sl| {
                        const idx = sl.indices(@intCast(b.data.len)) orelse {
                            try self.raiseStr("ValueError", "slice step cannot be zero");
                            return error.PyExc;
                        };
                        var buf: std.ArrayList(u8) = .empty;
                        var i: i64 = idx[0];
                        var n: i64 = idx[3];
                        while (n > 0) : (n -= 1) {
                            try buf.append(self.gpa, b.data[@intCast(i)]);
                            i += idx[2];
                        }
                        return self.rt.newBytesOwned(try buf.toOwnedSlice(self.gpa));
                    },
                    else => {
                        const i = try self.indexLike(sub, b.data.len);
                        return self.rt.newInt(b.data[i]);
                    },
                }
            },
            .bytearray => |b| {
                switch (sub.v) {
                    .slice => |sl| {
                        const idx = sl.indices(@intCast(b.data.items.len)) orelse {
                            try self.raiseStr("ValueError", "slice step cannot be zero");
                            return error.PyExc;
                        };
                        var buf: std.ArrayList(u8) = .empty;
                        var i: i64 = idx[0];
                        var n: i64 = idx[3];
                        while (n > 0) : (n -= 1) {
                            try buf.append(self.gpa, b.data.items[@intCast(i)]);
                            i += idx[2];
                        }
                        return self.rt.newBytearray(buf.items);
                    },
                    else => {
                        const i = try self.indexLike(sub, b.data.items.len);
                        return self.rt.newInt(b.data.items[i]);
                    },
                }
            },
            .dict => |d| {
                const h = try self.pyHash(sub);
                if (try d.getWithHash(self, sub, h)) |v| return v;
                const cls = self.excType("KeyError");
                const e = try self.rt.newExc(cls);
                const args = try self.gpa.alloc(Obj, 1);
                args[0] = sub;
                e.v.exc.args = args;
                try self.raiseObj(e);
                return error.PyExc;
            },
            .range => |r| {
                switch (sub.v) {
                    .slice => |sl| {
                        const idx = sl.indices(@intCast(r.len())) orelse {
                            try self.raiseStr("ValueError", "slice step cannot be zero");
                            return error.PyExc;
                        };
                        const new_start = r.get(@intCast(idx[0]));
                        const new_step = r.step * idx[2];
                        const new_stop = new_start + new_step * idx[3];
                        return self.rt.newRange(new_start, new_stop, new_step);
                    },
                    else => {
                        const i = try self.indexLike(sub, r.len());
                        return self.rt.newInt(r.get(i));
                    },
                }
            },
            else => {},
        }
        // subscript на классе: __class_getitem__ (неявный classmethod) — list[int], Generic[...]
        if (o.v == .type_) {
            const cls = o.v.type_;
            if (ops.lookupClass(cls, "__class_getitem__")) |cg| {
                switch (cg.v) {
                    .builtin => return self.pyCall(cg, &.{ o, sub }, null),
                    else => {
                        const bound = try ops.descrGet(self, cg, o, cls);
                        return self.pyCall(bound, &.{sub}, null);
                    },
                }
            }
        }
        if (ops.lookupSpecial(self, o, "__getitem__")) |gm| {
            return self.pyCall(gm, &.{sub}, null);
        }
        try self.raiseFmt("TypeError", "'{s}' object is not subscriptable", .{o.ty.name});
        return error.PyExc;
    }

    pub fn pyGetItemInt(self: *VM, o: Obj, i: i64) anyerror!Obj {
        const io = try self.rt.newInt(i);
        return self.pyGetItem(o, io);
    }

    fn indexLike(self: *VM, sub: Obj, len: usize) anyerror!usize {
        var i: i64 = 0;
        switch (sub.v) {
            .int => |v| i = v,
            .bool_ => |b| i = @intFromBool(b),
            else => {
                if (ops.lookupSpecial(self, sub, "__index__")) |im| {
                    const r = try self.pyCall(im, &.{}, null);
                    if (r.v == .int) {
                        i = r.v.int;
                    } else {
                        try self.raiseStr("TypeError", "__index__ returned non-int");
                        return error.PyExc;
                    }
                } else {
                    try self.raiseFmt("TypeError", "indices must be integers, not '{s}'", .{sub.ty.name});
                    return error.PyExc;
                }
            },
        }
        if (i < 0) i += @intCast(len);
        if (i < 0 or i >= @as(i64, @intCast(len))) {
            try self.raiseStr("IndexError", "index out of range");
            return error.PyExc;
        }
        return @intCast(i);
    }

    pub fn pySetItem(self: *VM, o: Obj, sub: Obj, val: Obj) anyerror!void {
        switch (o.v) {
            .list => |l| {
                switch (sub.v) {
                    .slice => |s| {
                        const idx = s.indices(@intCast(l.items.items.len)) orelse {
                            try self.raiseStr("ValueError", "slice step cannot be zero");
                            return error.PyExc;
                        };
                        const items = try self.collectSequence(val, null);
                        if (idx[2] == 1) {
                            const start: usize = @intCast(idx[0]);
                            const stop: usize = @intCast(idx[1]);
                            var new_items: std.ArrayList(Obj) = .empty;
                            try new_items.appendSlice(self.gpa, l.items.items[0..start]);
                            try new_items.appendSlice(self.gpa, items);
                            try new_items.appendSlice(self.gpa, l.items.items[stop..]);
                            l.items.deinit(self.gpa);
                            l.items = new_items;
                        } else {
                            if (items.len != idx[3]) {
                                try self.raiseFmt("ValueError", "attempt to assign sequence of size {d} to extended slice of size {d}", .{ items.len, idx[3] });
                                return error.PyExc;
                            }
                            var i: i64 = idx[0];
                            for (items) |item| {
                                l.items.items[@intCast(i)] = item;
                                i += idx[2];
                            }
                        }
                        return;
                    },
                    else => {
                        const i = try self.indexLike(sub, l.items.items.len);
                        l.items.items[i] = val;
                        return;
                    },
                }
            },
            .dict => |d| {
                const h = try self.pyHash(sub);
                try d.setWithHash(self, sub, val, h);
                return;
            },
            .bytearray => |b| {
                const i = try self.indexLike(sub, b.data.items.len);
                if (val.v == .int and val.v.int >= 0 and val.v.int < 256) {
                    b.data.items[i] = @intCast(val.v.int);
                    return;
                }
                try self.raiseStr("TypeError", "an integer in range(256) is required");
                return error.PyExc;
            },
            else => {},
        }
        if (ops.lookupSpecial(self, o, "__setitem__")) |sm| {
            _ = try self.pyCall(sm, &.{ sub, val }, null);
            return;
        }
        try self.raiseFmt("TypeError", "'{s}' object does not support item assignment", .{o.ty.name});
        return error.PyExc;
    }

    pub fn pyDelItem(self: *VM, o: Obj, sub: Obj) anyerror!void {
        switch (o.v) {
            .list => |l| {
                switch (sub.v) {
                    .slice => |s| {
                        const idx = s.indices(@intCast(l.items.items.len)) orelse {
                            try self.raiseStr("ValueError", "slice step cannot be zero");
                            return error.PyExc;
                        };
                        if (idx[2] == 1) {
                            const start: usize = @intCast(idx[0]);
                            const stop: usize = @intCast(idx[1]);
                            var new_items: std.ArrayList(Obj) = .empty;
                            try new_items.appendSlice(self.gpa, l.items.items[0..start]);
                            try new_items.appendSlice(self.gpa, l.items.items[stop..]);
                            l.items.deinit(self.gpa);
                            l.items = new_items;
                        } else if (idx[2] == -1 and idx[0] >= idx[1]) {
                            // reversed full range
                            const hi: usize = @intCast(idx[0] + 1);
                            const lo: usize = @intCast(idx[1] + 1);
                            var new_items: std.ArrayList(Obj) = .empty;
                            try new_items.appendSlice(self.gpa, l.items.items[0..lo]);
                            try new_items.appendSlice(self.gpa, l.items.items[hi..]);
                            l.items.deinit(self.gpa);
                            l.items = new_items;
                        } else {
                            var i: i64 = idx[0];
                            var n: i64 = idx[3];
                            while (n > 0) : (n -= 1) {
                                _ = l.items.orderedRemove(@intCast(i));
                                if (idx[2] > 0) i += idx[2] - 1 else i += idx[2] + 1;
                            }
                        }
                        return;
                    },
                    else => {
                        const i = try self.indexLike(sub, l.items.items.len);
                        _ = l.items.orderedRemove(i);
                        return;
                    },
                }
            },
            .dict => |d| {
                const h = try self.pyHash(sub);
                if (try d.delWithHash(self, sub, h)) return;
                const cls = self.excType("KeyError");
                const e = try self.rt.newExc(cls);
                const args = try self.gpa.alloc(Obj, 1);
                args[0] = sub;
                e.v.exc.args = args;
                try self.raiseObj(e);
                return error.PyExc;
            },
            else => {},
        }
        if (ops.lookupSpecial(self, o, "__delitem__")) |dm| {
            _ = try self.pyCall(dm, &.{sub}, null);
            return;
        }
        try self.raiseFmt("TypeError", "'{s}' object does not support item deletion", .{o.ty.name});
        return error.PyExc;
    }

    pub fn collectSequence(self: *VM, it: Obj, expected: ?usize) anyerror![]Obj {
        _ = expected;
        switch (it.v) {
            .list => |l| return l.items.items,
            .tuple => |t| return t,
            else => {},
        }
        var out: std.ArrayList(Obj) = .empty;
        const iter = try self.pyIter(it);
        var guard: usize = 0;
        while (try self.pyNext(iter)) |item| {
            try out.append(self.gpa, item);
            guard += 1;
            if (guard > 10_000_000) {
                try self.raiseStr("ValueError", "too many values to unpack");
                return error.PyExc;
            }
        }
        return out.items;
    }

    // ============================================================
    // Бинарные/унарные операции
    // ============================================================

    pub fn pyBinaryOp(self: *VM, bop: opcode_mod.BinaryOp, a: Obj, b: Obj) anyerror!Obj {
        const is_inplace = @intFromEnum(bop) >= @intFromEnum(opcode_mod.BinaryOp.iadd);
        if (is_inplace) {
            const iname = inameFor(bop);
            if (ops.lookupSpecial(self, a, iname)) |im| {
                const r = try self.pyCall(im, &.{b}, null);
                if (r.v != .notimpl) return r;
            }
        }
        const base_op: opcode_mod.BinaryOp = if (is_inplace)
            @enumFromInt(@intFromEnum(bop) - @intFromEnum(opcode_mod.BinaryOp.iadd))
        else
            bop;

        if (try self.numericBinary(base_op, a, b)) |r| return r;

        // PEP 604: X | Y для типов → union (минимально: кортеж типов; types.UnionType = type(int|str))
        if (base_op == .bit_or and a.v == .type_ and b.v == .type_) {
            return self.rt.newTuple(&.{ a, b });
        }

        // операции над множествами: & | - ^
        if (a.v == .set and (b.v == .set or b.v == .frozenset)) {
            const bd: *object.Set = if (b.v == .set) b.v.set else b.v.frozenset;
            switch (base_op) {
                .bit_and => {
                    const out = try self.rt.newSetObj(false, &.{});
                    var it = a.v.set.dict.iterAlive();
                    while (it.next()) |e| {
                        const h = try self.pyHash(e.key.?);
                        if (try bd.dict.getWithHash(self.rt, e.key.?, h)) |_| {
                            try out.v.set.dict.setWithHash(self.rt, e.key.?, self.rt.newNone(), h);
                        }
                    }
                    return out;
                },
                .bit_or => {
                    const out = try self.rt.newSetObj(false, &.{});
                    var it = a.v.set.dict.iterAlive();
                    while (it.next()) |e| {
                        const h = try self.pyHash(e.key.?);
                        try out.v.set.dict.setWithHash(self.rt, e.key.?, self.rt.newNone(), h);
                    }
                    var it2 = bd.dict.iterAlive();
                    while (it2.next()) |e| {
                        const h = try self.pyHash(e.key.?);
                        try out.v.set.dict.setWithHash(self.rt, e.key.?, self.rt.newNone(), h);
                    }
                    return out;
                },
                .sub => {
                    const out = try self.rt.newSetObj(false, &.{});
                    var it = a.v.set.dict.iterAlive();
                    while (it.next()) |e| {
                        const h = try self.pyHash(e.key.?);
                        if ((try bd.dict.getWithHash(self.rt, e.key.?, h)) == null) {
                            try out.v.set.dict.setWithHash(self.rt, e.key.?, self.rt.newNone(), h);
                        }
                    }
                    return out;
                },
                .bit_xor => {
                    const out = try self.rt.newSetObj(false, &.{});
                    var it = a.v.set.dict.iterAlive();
                    while (it.next()) |e| {
                        const h = try self.pyHash(e.key.?);
                        if ((try bd.dict.getWithHash(self.rt, e.key.?, h)) == null) {
                            try out.v.set.dict.setWithHash(self.rt, e.key.?, self.rt.newNone(), h);
                        }
                    }
                    var it2 = bd.dict.iterAlive();
                    while (it2.next()) |e| {
                        const h = try self.pyHash(e.key.?);
                        if ((try a.v.set.dict.getWithHash(self.rt, e.key.?, h)) == null) {
                            try out.v.set.dict.setWithHash(self.rt, e.key.?, self.rt.newNone(), h);
                        }
                    }
                    return out;
                },
                else => {},
            }
        }

        if (base_op == .add) {
            if (a.v == .str and b.v == .str) {
                const buf = try self.gpa.alloc(u8, a.v.str.bytes.len + b.v.str.bytes.len);
                @memcpy(buf[0..a.v.str.bytes.len], a.v.str.bytes);
                @memcpy(buf[a.v.str.bytes.len..], b.v.str.bytes);
                return self.rt.newStrOwned(buf);
            }
            if (a.v == .bytearray and b.v == .bytearray) {
                var buf: std.ArrayList(u8) = .empty;
                try buf.appendSlice(self.gpa, a.v.bytearray.data.items);
                try buf.appendSlice(self.gpa, b.v.bytearray.data.items);
                return self.rt.newBytearray(buf.items);
            }
            if (a.v == .bytes and b.v == .bytes) {
                const buf = try self.gpa.alloc(u8, a.v.bytes.data.len + b.v.bytes.data.len);
                @memcpy(buf[0..a.v.bytes.data.len], a.v.bytes.data);
                @memcpy(buf[a.v.bytes.data.len..], b.v.bytes.data);
                return self.rt.newBytesOwned(buf);
            }
            if (a.v == .list and b.v == .list) {
                const out = try self.rt.newList();
                try out.v.list.items.appendSlice(self.gpa, a.v.list.items.items);
                try out.v.list.items.appendSlice(self.gpa, b.v.list.items.items);
                return out;
            }
            if (a.v == .tuple and b.v == .tuple) {
                const out = try self.gpa.alloc(Obj, a.v.tuple.len + b.v.tuple.len);
                @memcpy(out[0..a.v.tuple.len], a.v.tuple);
                @memcpy(out[a.v.tuple.len..], b.v.tuple);
                return self.rt.newTupleOwned(out);
            }
        }
        if (base_op == .mul) {
            if (try self.repeatSeq(a, b)) |r| return r;
            if (try self.repeatSeq(b, a)) |r| return r;
        }
        if (base_op == .mod and a.v == .str) {
            return self.strPercentFormat(a.v.str.bytes, b);
        }

        const fname = nameFor(base_op);
        const rname = rnameFor(base_op);
        if (ops.lookupSpecial(self, a, fname)) |fm| {
            const r = try self.pyCall(fm, &.{b}, null);
            if (r.v != .notimpl) return r;
        }
        if (a.ty != b.ty) {
            if (ops.lookupSpecial(self, b, rname)) |rm| {
                const r = try self.pyCall(rm, &.{a}, null);
                if (r.v != .notimpl) return r;
            }
        }
        try self.raiseFmt("TypeError", "unsupported operand type(s) for {s}: '{s}' and '{s}'", .{ symbolFor(base_op), a.ty.name, b.ty.name });
        return error.PyExc;
    }

    fn nameFor(bop: opcode_mod.BinaryOp) []const u8 {
        return switch (bop) {
            .add => "__add__",
            .sub => "__sub__",
            .mul => "__mul__",
            .matmul => "__matmul__",
            .truediv => "__truediv__",
            .floordiv => "__floordiv__",
            .mod => "__mod__",
            .pow => "__pow__",
            .lshift => "__lshift__",
            .rshift => "__rshift__",
            .bit_and => "__and__",
            .bit_or => "__or__",
            .bit_xor => "__xor__",
            else => "?",
        };
    }
    fn rnameFor(bop: opcode_mod.BinaryOp) []const u8 {
        return switch (bop) {
            .add => "__radd__",
            .sub => "__rsub__",
            .mul => "__rmul__",
            .matmul => "__rmatmul__",
            .truediv => "__rtruediv__",
            .floordiv => "__rfloordiv__",
            .mod => "__rmod__",
            .pow => "__rpow__",
            .lshift => "__rlshift__",
            .rshift => "__rrshift__",
            .bit_and => "__rand__",
            .bit_or => "__ror__",
            .bit_xor => "__rxor__",
            else => "?",
        };
    }
    fn inameFor(bop: opcode_mod.BinaryOp) []const u8 {
        return switch (bop) {
            .iadd => "__iadd__",
            .isub => "__isub__",
            .imul => "__imul__",
            .imatmul => "__imatmul__",
            .itruediv => "__itruediv__",
            .ifloordiv => "__ifloordiv__",
            .imod => "__imod__",
            .ipow => "__ipow__",
            .ilshift => "__ilshift__",
            .irshift => "__irshift__",
            .ibit_and => "__iand__",
            .ibit_or => "__ior__",
            .ibit_xor => "__ixor__",
            else => "?",
        };
    }
    fn symbolFor(bop: opcode_mod.BinaryOp) []const u8 {
        return switch (bop) {
            .add => "+",
            .sub => "-",
            .mul => "*",
            .matmul => "@",
            .truediv => "/",
            .floordiv => "//",
            .mod => "%",
            .pow => "** or pow()",
            .lshift => "<<",
            .rshift => ">>",
            .bit_and => "&",
            .bit_or => "|",
            .bit_xor => "^",
            else => "?",
        };
    }

    fn numericBinary(self: *VM, bop: opcode_mod.BinaryOp, a: Obj, b: Obj) anyerror!?Obj {
        const a_int = a.v == .int or a.v == .bool_ or a.v == .bigint;
        const b_int = b.v == .int or b.v == .bool_ or b.v == .bigint;
        const a_float = a.v == .float;
        const b_float = b.v == .float;
        if (!(a_int or a_float) or !(b_int or b_float)) return null;

        if (a_float or b_float) {
            const x = asF64(a);
            const y = asF64(b);
            return switch (bop) {
                .add => try self.rt.newFloat(x + y),
                .sub => try self.rt.newFloat(x - y),
                .mul => try self.rt.newFloat(x * y),
                .truediv => blk: {
                    if (y == 0) {
                        try self.raiseStr("ZeroDivisionError", "float division by zero");
                        return error.PyExc;
                    }
                    break :blk try self.rt.newFloat(x / y);
                },
                .floordiv => blk: {
                    if (y == 0) {
                        try self.raiseStr("ZeroDivisionError", "float floor division by zero");
                        return error.PyExc;
                    }
                    break :blk try self.rt.newFloat(@floor(x / y));
                },
                .mod => blk: {
                    if (y == 0) {
                        try self.raiseStr("ZeroDivisionError", "float modulo");
                        return error.PyExc;
                    }
                    break :blk try self.rt.newFloat(@mod(x, y));
                },
                .pow => try self.rt.newFloat(std.math.pow(f64, x, y)),
                else => return null,
            };
        }

        const a_small: ?i64 = switch (a.v) {
            .int => |v| v,
            .bool_ => |v| @intFromBool(v),
            else => null,
        };
        const b_small: ?i64 = switch (b.v) {
            .int => |v| v,
            .bool_ => |v| @intFromBool(v),
            else => null,
        };

        if (a_small != null and b_small != null) {
            const x = a_small.?;
            const y = b_small.?;
            return switch (bop) {
                .add => blk: {
                    const v = @addWithOverflow(x, y);
                    if (v[1] == 0) break :blk try self.rt.newInt(v[0]);
                    break :blk try self.bigBinary(.add, a, b);
                },
                .sub => blk: {
                    const v = @subWithOverflow(x, y);
                    if (v[1] == 0) break :blk try self.rt.newInt(v[0]);
                    break :blk try self.bigBinary(.sub, a, b);
                },
                .mul => blk: {
                    const v = @mulWithOverflow(x, y);
                    if (v[1] == 0) break :blk try self.rt.newInt(v[0]);
                    break :blk try self.bigBinary(.mul, a, b);
                },
                .truediv => blk: {
                    if (y == 0) {
                        try self.raiseStr("ZeroDivisionError", "division by zero");
                        return error.PyExc;
                    }
                    break :blk try self.rt.newFloat(@as(f64, @floatFromInt(x)) / @as(f64, @floatFromInt(y)));
                },
                .floordiv => blk: {
                    if (y == 0) {
                        try self.raiseStr("ZeroDivisionError", "integer division or modulo by zero");
                        return error.PyExc;
                    }
                    break :blk try self.rt.newInt(@divFloor(x, y));
                },
                .mod => blk: {
                    if (y == 0) {
                        try self.raiseStr("ZeroDivisionError", "integer division or modulo by zero");
                        return error.PyExc;
                    }
                    break :blk try self.rt.newInt(@mod(x, y));
                },
                .pow => try self.intPow(x, y),
                .lshift => blk: {
                    if (y < 0) {
                        try self.raiseStr("ValueError", "negative shift count");
                        return error.PyExc;
                    }
                    if (y >= 62 and x != 0) break :blk try self.bigBinary(.lshift, a, b);
                    break :blk try self.rt.newInt(x << @intCast(y));
                },
                .rshift => blk: {
                    if (y < 0) {
                        try self.raiseStr("ValueError", "negative shift count");
                        return error.PyExc;
                    }
                    const sh: u6 = if (y >= 64) 63 else @intCast(y);
                    break :blk try self.rt.newInt(x >> sh);
                },
                .bit_and => try self.rt.newInt(x & y),
                .bit_or => try self.rt.newInt(x | y),
                .bit_xor => try self.rt.newInt(x ^ y),
                else => return null,
            };
        }
        return try self.bigBinary(bop, a, b);
    }

    fn asF64(o: Obj) f64 {
        return switch (o.v) {
            .int => |v| @floatFromInt(v),
            .bool_ => |v| if (v) 1 else 0,
            .float => |v| v,
            .bigint => |v| object.bigFloat(v),
            else => 0,
        };
    }

    fn intPow(self: *VM, x: i64, y: i64) anyerror!Obj {
        if (y < 0) {
            return self.rt.newFloat(std.math.pow(f64, @floatFromInt(x), @floatFromInt(y)));
        }
        var result: i64 = 1;
        var base = x;
        var exp = y;
        while (exp > 0) {
            if (exp & 1 == 1) {
                const v = @mulWithOverflow(result, base);
                if (v[1] != 0) return self.bigBinary(.pow, a: {
                    break :a try self.rt.newInt(x);
                }, try self.rt.newInt(y));
                result = v[0];
            }
            exp >>= 1;
            if (exp > 0) {
                const v = @mulWithOverflow(base, base);
                if (v[1] != 0) return self.bigBinary(.pow, try self.rt.newInt(x), try self.rt.newInt(y));
                base = v[0];
            }
        }
        return self.rt.newInt(result);
    }

    fn bigBinary(self: *VM, bop: opcode_mod.BinaryOp, a: Obj, b: Obj) anyerror!Obj {
        const g = self.gpa;
        var ba: *object.Big = undefined;
        var bb: *object.Big = undefined;
        if (a.v == .bigint) {
            ba = try object.bigClone(g, a.v.bigint);
        } else if (a.v == .int) {
            ba = try object.bigFromI64(g, a.v.int);
        } else if (a.v == .bool_) {
            ba = try object.bigFromI64(g, @intFromBool(a.v.bool_));
        } else return error.TypeErr;
        if (b.v == .bigint) {
            bb = try object.bigClone(g, b.v.bigint);
        } else if (b.v == .int) {
            bb = try object.bigFromI64(g, b.v.int);
        } else if (b.v == .bool_) {
            bb = try object.bigFromI64(g, @intFromBool(b.v.bool_));
        } else return error.TypeErr;

        var r = try object.bigFromI64(g, 0);
        const demote_ok = true;
        switch (bop) {
            .add => try r.add(ba, bb),
            .sub => try r.sub(ba, bb),
            .mul => try r.mul(ba, bb),
            .lshift => try r.shiftLeft(ba, @intCast(bb.toInt(u32) catch 0)),
            .rshift => try r.shiftRight(ba, @intCast(bb.toInt(u32) catch 0)),
            .bit_and => try r.bitAnd(ba, bb),
            .bit_or => try r.bitOr(ba, bb),
            .bit_xor => try r.bitXor(ba, bb),
            .floordiv, .mod => {
                var rem = try object.bigFromI64(g, 0);
                if (bb.eqlZero()) {
                    try self.raiseStr("ZeroDivisionError", "integer division or modulo by zero");
                    return error.PyExc;
                }
                try r.divFloor(rem, ba, bb);
                if (bop == .mod) {
                    r.deinit();
                    r = rem;
                } else {
                    rem.deinit();
                }
            },
            .pow => {
                if (!bb.isPositive()) {
                    return self.rt.newFloat(std.math.pow(f64, asF64(a), asF64(b)));
                }
                const y64 = bb.toInt(i64) catch {
                    try self.raiseStr("OverflowError", "exponent too large");
                    return error.PyExc;
                };
                var result = try object.bigFromI64(g, 1);
                var base = ba;
                var e = y64;
                while (e > 0) {
                    if (e & 1 == 1) try result.mul(result, base);
                    e >>= 1;
                    if (e > 0) {
                        const base2 = try object.bigFromI64(g, 0);
                        try base2.mul(base, base);
                        base = base2;
                    }
                }
                r.deinit();
                r = result;
            },
            .truediv => {
                const x = object.bigFloat(ba);
                const y = object.bigFloat(bb);
                if (y == 0) {
                    try self.raiseStr("ZeroDivisionError", "division by zero");
                    return error.PyExc;
                }
                return self.rt.newFloat(x / y);
            },
            else => return error.TypeErr,
        }
        if (demote_ok) {
            if (r.toInt(i64)) |v| {
                r.deinit();
                return self.rt.newInt(v);
            } else |_| {}
        }
        return self.rt.newBig(r);
    }

    fn repeatSeq(self: *VM, seq: Obj, n_obj: Obj) anyerror!?Obj {
        var n: i64 = 0;
        switch (n_obj.v) {
            .int => |v| n = v,
            .bool_ => |v| n = @intFromBool(v),
            else => return null,
        }
        const total: usize = @intCast(if (n <= 0) 0 else n);
        switch (seq.v) {
            .str => |s| {
                var buf: std.ArrayList(u8) = .empty;
                try buf.ensureTotalCapacity(self.gpa, s.bytes.len * total);
                for (0..total) |_| {
                    try buf.appendSlice(self.gpa, s.bytes);
                }
                return try self.rt.newStrOwned(try buf.toOwnedSlice(self.gpa));
            },
            .list => |l| {
                const out = try self.rt.newList();
                try out.v.list.items.ensureTotalCapacity(self.gpa, l.items.items.len * total);
                for (0..total) |_| {
                    try out.v.list.items.appendSlice(self.gpa, l.items.items);
                }
                return out;
            },
            .tuple => |t| {
                const out = try self.gpa.alloc(Obj, t.len * total);
                for (0..total) |i| {
                    @memcpy(out[i * t.len .. (i + 1) * t.len], t);
                }
                return try self.rt.newTupleOwned(out);
            },
            .bytes => |b| {
                var buf: std.ArrayList(u8) = .empty;
                for (0..total) |_| {
                    try buf.appendSlice(self.gpa, b.data);
                }
                return try self.rt.newBytesOwned(try buf.toOwnedSlice(self.gpa));
            },
            else => return null,
        }
    }

    pub fn pyUnaryOp(self: *VM, uop: opcode_mod.UnaryOp, a: Obj) anyerror!Obj {
        switch (uop) {
            .not => return self.rt.newBool(!(try self.pyTruthy(a))),
            .neg => switch (a.v) {
                .int => |v| {
                    if (v == std.math.minInt(i64)) {
                        return self.bigUnary(.neg, a);
                    }
                    return self.rt.newInt(-v);
                },
                .bool_ => |v| return self.rt.newInt(-@as(i64, @intFromBool(v))),
                .float => |v| return self.rt.newFloat(-v),
                .bigint => return self.bigUnary(.neg, a),
                else => {},
            },
            .pos => switch (a.v) {
                .int, .bigint, .float => return a,
                .bool_ => |v| return self.rt.newInt(@intFromBool(v)),
                else => {},
            },
            .invert => switch (a.v) {
                .int => |v| return self.rt.newInt(~v),
                .bool_ => |v| return self.rt.newInt(~@as(i64, @intFromBool(v))),
                .bigint => return self.bigUnary(.invert, a),
                else => {},
            },
        }
        const name = switch (uop) {
            .neg => "__neg__",
            .pos => "__pos__",
            .invert => "__invert__",
            .not => "?",
        };
        if (ops.lookupSpecial(self, a, name)) |m| {
            return self.pyCall(m, &.{}, null);
        }
        try self.raiseFmt("TypeError", "bad operand type for unary {s}: '{s}'", .{ name, a.ty.name });
        return error.PyExc;
    }

    fn bigUnary(self: *VM, uop: opcode_mod.UnaryOp, a: Obj) anyerror!Obj {
        const g = self.gpa;
        var ba: *object.Big = undefined;
        if (a.v == .bigint) {
            ba = a.v.bigint;
        } else return error.TypeErr;
        _ = uop;
        var r = try object.bigFromI64(g, 0);
        try r.copy(ba.toConst());
        r.negate();
        if (r.toInt(i64)) |v| {
            r.deinit();
            return self.rt.newInt(v);
        } else |_| {}
        return self.rt.newBig(r);
    }

    /// %-форматирование строк
    pub fn strPercentFormat(self: *VM, fmt: []const u8, arg: Obj) anyerror!Obj {
        var buf: std.ArrayList(u8) = .empty;
        const g = self.gpa;
        var arg_tuple: []Obj = &.{};
        var is_dict = false;
        switch (arg.v) {
            .tuple => |t| arg_tuple = t,
            .dict => is_dict = true,
            else => {
                arg_tuple = try g.alloc(Obj, 1);
                arg_tuple[0] = arg;
            },
        }

        var ai: usize = 0;
        var i: usize = 0;
        while (i < fmt.len) {
            const c = fmt[i];
            if (c != '%') {
                try buf.append(g, c);
                i += 1;
                continue;
            }
            i += 1;
            if (i >= fmt.len) {
                try self.raiseStr("ValueError", "incomplete format");
                return error.PyExc;
            }
            if (fmt[i] == '%') {
                try buf.append(g, '%');
                i += 1;
                continue;
            }
            var key: ?[]const u8 = null;
            if (i < fmt.len and fmt[i] == '(') {
                const end = std.mem.indexOfScalarPos(u8, fmt, i, ')') orelse {
                    try self.raiseStr("ValueError", "incomplete format key");
                    return error.PyExc;
                };
                key = fmt[i + 1 .. end];
                i = end + 1;
            }
            var flag_zero = false;
            var flag_minus = false;
            var flag_plus = false;
            var flag_space = false;
            var flag_alt = false;
            while (i < fmt.len) : (i += 1) {
                switch (fmt[i]) {
                    '0' => flag_zero = true,
                    '-' => flag_minus = true,
                    '+' => flag_plus = true,
                    ' ' => flag_space = true,
                    '#' => flag_alt = true,
                    else => break,
                }
            }
            var width: ?usize = null;
            {
                var w: usize = 0;
                var has = false;
                while (i < fmt.len and fmt[i] >= '0' and fmt[i] <= '9') : (i += 1) {
                    w = w * 10 + (fmt[i] - '0');
                    has = true;
                }
                if (has) width = w;
            }
            var prec: ?usize = null;
            if (i < fmt.len and fmt[i] == '.') {
                i += 1;
                var p: usize = 0;
                var has = false;
                while (i < fmt.len and fmt[i] >= '0' and fmt[i] <= '9') : (i += 1) {
                    p = p * 10 + (fmt[i] - '0');
                    has = true;
                }
                prec = if (has) p else 0;
            }
            if (i >= fmt.len) {
                try self.raiseStr("ValueError", "incomplete format");
                return error.PyExc;
            }
            const conv = fmt[i];
            i += 1;

            var v: Obj = undefined;
            if (key) |k| {
                if (!is_dict) {
                    try self.raiseStr("TypeError", "format requires a mapping");
                    return error.PyExc;
                }
                const kobj = try self.rt.newStr(k);
                const h = try self.pyHash(kobj);
                const got = try arg.v.dict.getWithHash(self, kobj, h);
                if (got == null) {
                    const cls = self.excType("KeyError");
                    const e = try self.rt.newExc(cls);
                    const a1 = try self.gpa.alloc(Obj, 1);
                    a1[0] = kobj;
                    e.v.exc.args = a1;
                    try self.raiseObj(e);
                    return error.PyExc;
                }
                v = got.?;
            } else {
                if (ai >= arg_tuple.len) {
                    try self.raiseStr("TypeError", "not enough arguments for format string");
                    return error.PyExc;
                }
                v = arg_tuple[ai];
                ai += 1;
            }

            var piece: []const u8 = undefined;
            var needs_sign_check = false;
            switch (conv) {
                's' => piece = (try ops.pyStr(self, v)).v.str.bytes,
                'r', 'a' => piece = (try ops.pyRepr(self, v)).v.str.bytes,
                'd', 'i', 'u' => {
                    piece = try self.fmtPercentInt(v, 10, false);
                    needs_sign_check = true;
                },
                'x' => {
                    var s2 = try self.fmtPercentInt(v, 16, false);
                    if (flag_alt and s2.len > 0 and s2[0] != '-') s2 = try std.fmt.allocPrint(g, "0x{s}", .{s2});
                    piece = s2;
                    needs_sign_check = true;
                },
                'X' => {
                    var s2 = try self.fmtPercentInt(v, 16, true);
                    if (flag_alt and s2.len > 0 and s2[0] != '-') s2 = try std.fmt.allocPrint(g, "0X{s}", .{s2});
                    piece = s2;
                    needs_sign_check = true;
                },
                'o' => {
                    var s2 = try self.fmtPercentInt(v, 8, false);
                    if (flag_alt and (s2.len == 0 or s2[0] != '0')) s2 = try std.fmt.allocPrint(g, "0{s}", .{s2});
                    piece = s2;
                    needs_sign_check = true;
                },
                'e', 'E', 'f', 'F', 'g', 'G' => {
                    const fv = try self.toFloatVal(v);
                    piece = try self.fmtPercentFloat(fv, conv, prec);
                    needs_sign_check = true;
                },
                'c' => {
                    if (v.v == .int) {
                        var ub: [4]u8 = undefined;
                        const cp_i = @mod(v.v.int, 0x110000);
                        const n = std.unicode.utf8Encode(@intCast(cp_i), &ub) catch {
                            try self.raiseStr("OverflowError", "%c arg not in range(0x110000)");
                            return error.PyExc;
                        };
                        piece = try g.dupe(u8, ub[0..n]);
                    } else if (v.v == .str and v.v.str.cp_len == 1) {
                        piece = v.v.str.bytes;
                    } else if (v.v == .bytes and v.v.bytes.data.len == 1) {
                        piece = v.v.bytes.data;
                    } else {
                        try self.raiseStr("TypeError", "%c requires int or char");
                        return error.PyExc;
                    }
                },
                else => {
                    try self.raiseFmt("ValueError", "unsupported format character '{c}'", .{conv});
                    return error.PyExc;
                },
            }

            if (needs_sign_check and (flag_plus or flag_space)) {
                if (piece.len > 0 and piece[0] != '-' and piece[0] != '+') {
                    try buf.append(g, if (flag_plus) '+' else ' ');
                }
            }
            const cp_len = object.Str.countCp(piece);
            if (width) |w| {
                if (cp_len < w) {
                    const pad_char: u8 = if (flag_zero and !flag_minus) '0' else ' ';
                    const pad_n = w - cp_len;
                    if (!flag_minus) {
                        const starts_sign = piece.len > 0 and (piece[0] == '-' or piece[0] == '+' or piece[0] == ' ');
                        if (pad_char == '0' and starts_sign) {
                            try buf.append(g, piece[0]);
                            for (0..pad_n) |_| try buf.append(g, pad_char);
                            try buf.appendSlice(g, piece[1..]);
                        } else {
                            for (0..pad_n) |_| try buf.append(g, pad_char);
                            try buf.appendSlice(g, piece);
                        }
                    } else {
                        try buf.appendSlice(g, piece);
                        for (0..pad_n) |_| try buf.append(g, ' ');
                    }
                    continue;
                }
            }
            try buf.appendSlice(g, piece);
        }
        if (ai < arg_tuple.len and !is_dict) {
            try self.raiseStr("TypeError", "not all arguments converted during string formatting");
            return error.PyExc;
        }
        return self.rt.newStrOwned(try buf.toOwnedSlice(g));
    }

    fn fmtPercentInt(self: *VM, v: Obj, base: u8, upper: bool) anyerror![]const u8 {
        switch (v.v) {
            .int => |i| {
                if (base == 16) return if (upper) std.fmt.allocPrint(self.gpa, "{X}", .{i}) else std.fmt.allocPrint(self.gpa, "{x}", .{i});
                if (base == 8) return std.fmt.allocPrint(self.gpa, "{o}", .{i});
                return std.fmt.allocPrint(self.gpa, "{d}", .{i});
            },
            .bool_ => |b| return std.fmt.allocPrint(self.gpa, "{d}", .{@intFromBool(b)}),
            .bigint => |bb| return bb.toString(self.gpa, base, if (upper) .upper else .lower),
            else => {
                try self.raiseFmt("TypeError", "%d format: a number is required, not {s}", .{v.ty.name});
                return error.PyExc;
            },
        }
    }

    fn toFloatVal(self: *VM, v: Obj) anyerror!f64 {
        return switch (v.v) {
            .int => |i| @floatFromInt(i),
            .bool_ => |b| @floatFromInt(@intFromBool(b)),
            .float => |f| f,
            .bigint => |b| object.bigFloat(b),
            else => {
                try self.raiseFmt("TypeError", "must be real number, not {s}", .{v.ty.name});
                return error.PyExc;
            },
        };
    }

    fn fmtPercentFloat(self: *VM, f: f64, conv: u8, prec: ?usize) anyerror![]const u8 {
        const g = self.gpa;
        const p = prec orelse 6;
        if (std.math.isNan(f)) return g.dupe(u8, "nan");
        if (std.math.isInf(f)) return g.dupe(u8, if (f > 0) "inf" else "-inf");
        var buf: [512]u8 = undefined;
        switch (conv) {
            'f', 'F' => {
                const s = std.fmt.bufPrint(&buf, "{d:.[1]}", .{ f, p }) catch return error.FormatErr;
                return g.dupe(u8, s);
            },
            'e' => {
                const s = std.fmt.bufPrint(&buf, "{e:.[1]}", .{ f, p }) catch return error.FormatErr;
                return g.dupe(u8, s);
            },
            'E' => {
                const s = std.fmt.bufPrint(&buf, "{e:.[1]}", .{ f, p }) catch return error.FormatErr;
                const upper = try g.dupe(u8, s);
                for (upper) |*ch| ch.* = std.ascii.toUpper(ch.*);
                return upper;
            },
            'g', 'G' => {
                const s = std.fmt.bufPrint(&buf, "{d:.[1]}", .{ f, p }) catch return error.FormatErr;
                return g.dupe(u8, s);
            },
            else => return error.FormatErr,
        }
    }

    pub fn formatValue(self: *VM, v: Obj, conv: u8, fmt_spec: ?Obj) anyerror!Obj {
        var s: Obj = undefined;
        switch (conv) {
            2 => s = try ops.pyRepr(self, v),
            else => s = try ops.pyStr(self, v),
        }
        if (fmt_spec) |fs| {
            if (fs.v == .str and fs.v.str.bytes.len == 0) return s;
            return self.applyFormatSpec(v, fs.v.str.bytes);
        }
        return s;
    }

    pub fn applyFormatSpec(self: *VM, v: Obj, spec: []const u8) anyerror!Obj {
        if (ops.lookupSpecial(self, v, "__format__")) |fm| {
            const spec_obj = try self.rt.newStr(spec);
            return self.pyCall(fm, &.{spec_obj}, null);
        }
        return self.formatSimple(v, spec);
    }

    /// Вставка ',' как разделителя тысяч в целую часть числа (PEP 3101 запятая-группировка).
    fn thousandsGroup(g: std.mem.Allocator, body: []const u8) ![]const u8 {
        var st: usize = 0;
        if (body.len > 0 and (body[0] == '-' or body[0] == '+' or body[0] == ' ')) st = 1;
        var en: usize = st;
        while (en < body.len and body[en] >= '0' and body[en] <= '9') en += 1;
        const ndig = en - st;
        if (ndig < 5) return body; // нечего группировать (и отсекаем inf/nan)
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(g, body[0..st]);
        const first: usize = if (ndig % 3 == 0) 3 else ndig % 3;
        try out.appendSlice(g, body[st .. st + first]);
        var i: usize = first;
        while (i < ndig) : (i += 3) {
            try out.append(g, ',');
            try out.appendSlice(g, body[st + i .. st + i + 3]);
        }
        try out.appendSlice(g, body[en..]);
        return out.items;
    }

    /// [[fill]align][sign][#][0][width][,][.prec][type]
    pub fn formatSimple(self: *VM, v: Obj, spec: []const u8) anyerror!Obj {
        const g = self.gpa;
        var i: usize = 0;
        var fill: u21 = ' ';
        var align_: u8 = 0; // < > = ^
        if (spec.len >= 2) {
            const second = spec[1];
            if (second == '<' or second == '>' or second == '=' or second == '^') {
                const l1 = std.unicode.utf8ByteSequenceLength(spec[0]) catch 1;
                fill = std.unicode.utf8Decode(spec[0..l1]) catch ' ';
                align_ = second;
                i = 1 + l1;
            }
        }
        if (i < spec.len and (spec[i] == '<' or spec[i] == '>' or spec[i] == '=' or spec[i] == '^')) {
            align_ = spec[i];
            i += 1;
        }
        var sign: u8 = '-';
        if (i < spec.len and (spec[i] == '+' or spec[i] == '-' or spec[i] == ' ')) {
            sign = spec[i];
            i += 1;
        }
        var alt = false;
        if (i < spec.len and spec[i] == '#') {
            alt = true;
            i += 1;
        }
        var zero_pad = false;
        if (i < spec.len and spec[i] == '0') {
            zero_pad = true;
            i += 1;
        }
        var width: ?usize = null;
        {
            var w: usize = 0;
            var has = false;
            while (i < spec.len and spec[i] >= '0' and spec[i] <= '9') : (i += 1) {
                w = w * 10 + (spec[i] - '0');
                has = true;
            }
            if (has) width = w;
        }
        var comma = false;
        if (i < spec.len and spec[i] == ',') {
            comma = true;
            i += 1;
        }
        var prec: ?usize = null;
        if (i < spec.len and spec[i] == '.') {
            i += 1;
            var p: usize = 0;
            var has = false;
            while (i < spec.len and spec[i] >= '0' and spec[i] <= '9') : (i += 1) {
                p = p * 10 + (spec[i] - '0');
                has = true;
            }
            prec = if (has) p else 0;
        }
        var ty: u8 = 0;
        if (i < spec.len) {
            ty = spec[i];
            i += 1;
        }

        // формируем body
        var body: []const u8 = undefined;
        var is_num = false;
        switch (v.v) {
            .int, .bigint, .bool_ => {
                is_num = true;
                body = switch (ty) {
                    'x' => try self.fmtPercentInt(v, 16, false),
                    'X' => try self.fmtPercentInt(v, 16, true),
                    'o' => try self.fmtPercentInt(v, 8, false),
                    'b' => try self.fmtPercentInt(v, 2, false),
                    'd', 0 => try self.fmtPercentInt(v, 10, false),
                    'e', 'E', 'f', 'F', 'g', 'G', '%' => blk: {
                        const fv = try self.toFloatVal(v);
                        if (ty == '%') {
                            break :blk try std.fmt.allocPrint(g, "{s}%", .{try self.fmtPercentFloat(fv * 100, 'f', prec)});
                        }
                        body = try self.fmtPercentFloat(fv, ty, prec);
                        break :blk body;
                    },
                    'c' => blk: {
                        if (v.v == .int) {
                            var ub: [4]u8 = undefined;
                            const n = std.unicode.utf8Encode(@intCast(@mod(v.v.int, 0x110000)), &ub) catch return error.FormatErr;
                            break :blk try g.dupe(u8, ub[0..n]);
                        }
                        try self.raiseStr("TypeError", "cannot format char");
                        return error.PyExc;
                    },
                    else => try self.fmtPercentInt(v, 10, false),
                };
                _ = &body;
                if (ty == 'e' or ty == 'E' or ty == 'f' or ty == 'F' or ty == 'g' or ty == 'G' or ty == '%') {
                    if (body.len > 1 and body[body.len - 1] != '%') {} else {}
                }
            },
            .float => {
                is_num = true;
                body = switch (ty) {
                    0, 'g', 'G' => try ops.floatRepr(g, v.v.float),
                    'e', 'E', 'f', 'F' => try self.fmtPercentFloat(v.v.float, ty, prec),
                    '%' => try std.fmt.allocPrint(g, "{s}%", .{try self.fmtPercentFloat(v.v.float * 100, 'f', prec)}),
                    else => try ops.floatRepr(g, v.v.float),
                };
            },
            .str => {
                body = v.v.str.bytes;
                if (prec) |p| {
                    if (v.v.str.cp_len > p) {
                        body = v.v.str.cpSlice(0, p);
                    }
                }
            },
            else => {
                body = (try ops.pyStr(self, v)).v.str.bytes;
            },
        }

        // префиксы alt
        if (alt and is_num) {
            switch (ty) {
                'x' => if (body.len > 0 and body[0] != '-') {
                    body = try std.fmt.allocPrint(g, "0x{s}", .{body});
                },
                'X' => if (body.len > 0 and body[0] != '-') {
                    body = try std.fmt.allocPrint(g, "0X{s}", .{body});
                },
                'o' => if (body.len > 0 and body[0] != '0') {
                    body = try std.fmt.allocPrint(g, "0o{s}", .{body});
                },
                'b' => if (body.len > 0 and body[0] != '-') {
                    body = try std.fmt.allocPrint(g, "0b{s}", .{body});
                },
                else => {},
            }
        }
        // знак
        if (is_num and body.len > 0 and body[0] != '-' and body[0] != '+') {
            if (sign == '+') {
                body = try std.fmt.allocPrint(g, "+{s}", .{body});
            } else if (sign == ' ') {
                body = try std.fmt.allocPrint(g, " {s}", .{body});
            }
        }
        // запятая-группировка: только десятичные представления
        if (comma) {
            if (is_num and (ty == 0 or ty == 'd' or ty == 'e' or ty == 'E' or ty == 'f' or ty == 'F' or ty == 'g' or ty == 'G' or ty == '%')) {
                body = try thousandsGroup(g, body);
            } else if (is_num) {
                try self.raiseFmt("ValueError", "Cannot specify ',' with '{c}'.", .{ty});
                return error.PyExc;
            } else {
                try self.raiseFmt("ValueError", "Cannot specify ',' with '{c}'.", .{ty});
                return error.PyExc;
            }
        }

        if (width) |w| {
            // выравнивание в кодпоинтах — для простоты по байтам для ASCII
            const cp_len = object.Str.countCp(body);
            if (cp_len < w) {
                // флаг '0' для чисел без явного align → fill='0', align='=' (PEP 3101)
                var eff_fill: u21 = fill;
                var eff_align: u8 = align_;
                if (zero_pad and align_ == 0 and is_num) {
                    eff_fill = '0';
                    eff_align = '=';
                }
                const a2: u8 = if (eff_align == 0) (if (is_num) '>' else '<') else eff_align;
                const pad_n = w - cp_len;
                var fb: [4]u8 = undefined;
                const flen = std.unicode.utf8Encode(eff_fill, &fb) catch 1;
                const fill_slice = fb[0..flen];
                var out: std.ArrayList(u8) = .empty;
                switch (a2) {
                    '<' => {
                        try out.appendSlice(g, body);
                        for (0..pad_n) |_| try out.appendSlice(g, fill_slice);
                    },
                    '>' => {
                        for (0..pad_n) |_| try out.appendSlice(g, fill_slice);
                        try out.appendSlice(g, body);
                    },
                    '=' => {
                        // после знака
                        var sign_len: usize = 0;
                        if (body.len > 0 and (body[0] == '-' or body[0] == '+' or body[0] == ' ')) sign_len = 1;
                        const pad_char: []const u8 = if (zero_pad or fill != ' ') fill_slice else " ";
                        _ = pad_char;
                        try out.appendSlice(g, body[0..sign_len]);
                        for (0..pad_n) |_| try out.appendSlice(g, fill_slice);
                        try out.appendSlice(g, body[sign_len..]);
                    },
                    '^' => {
                        const left = pad_n / 2;
                        const right = pad_n - left;
                        for (0..left) |_| try out.appendSlice(g, fill_slice);
                        try out.appendSlice(g, body);
                        for (0..right) |_| try out.appendSlice(g, fill_slice);
                    },
                    else => try out.appendSlice(g, body),
                }
                return self.rt.newStrOwned(try out.toOwnedSlice(g));
            }
        }
        return self.rt.newStr(body);
    }

    pub fn excMatches(self: *VM, exc: Obj, match: Obj) anyerror!bool {
        switch (match.v) {
            .type_ => |t| return ops.isSubclass(exc.ty, t),
            .tuple => |items| {
                for (items) |it| {
                    if (try self.excMatches(exc, it)) return true;
                }
                return false;
            },
            else => {
                try self.raiseStr("TypeError", "catching classes that do not inherit from BaseException is not allowed");
                return error.PyExc;
            },
        }
    }

    fn pyCallRaw(self: *VM, func: Obj, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
        return ops.pyCall(self, func, args, kw);
    }

    pub fn pyCall(self: *VM, callable: Obj, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
        return ops.pyCall(self, callable, args, kw);
    }

    pub fn typeOf(self: *VM, o: Obj) anyerror!Obj {
        return ops.typeOf(self, o);
    }

    pub fn pyEq(self: *VM, a: Obj, b: Obj) anyerror!bool {
        return ops.pyEq(self, a, b);
    }
    pub fn pyHash(self: *VM, o: Obj) anyerror!u64 {
        return ops.pyHash(self, o);
    }
};
