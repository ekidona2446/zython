//! Виртуальная машина Zython - аналог Python/ceval.c
const std = @import("std");
const Allocator = std.mem.Allocator;
const object = @import("../object/object.zig");
const opcode_mod = @import("opcode.zig");
const xev = @import("xev");
const stdlib_uvicorn = @import("../stdlib/uvicorn.zig");
const stdlib_os = @import("../stdlib/os.zig");
const stdlib_sys = @import("../stdlib/sys.zig");
const stdlib_asyncio = @import("../stdlib/asyncio.zig");
const stdlib_socket = @import("../stdlib/socket.zig");
const stdlib_json = @import("../stdlib/json.zig");
const stdlib_datetime = @import("../stdlib/datetime.zig");
const stdlib_math = @import("../stdlib/math.zig");
const stdlib_zycorn = @import("../stdlib/http/zycorn.zig");

pub const VM = struct {
    allocator: Allocator,
    globals: std.StringHashMap(object.ObjectPtr),
    builtins: std.StringHashMap(object.ObjectPtr),
    frames: std.ArrayList(Frame),
    xev_loop: ?*xev.Loop,
    last_exception: ?object.ObjectPtr = null,

    pub const Frame = struct {
        code: *object.CodeObject,
        stack: std.ArrayList(object.ObjectPtr),
        locals: std.StringHashMap(object.ObjectPtr),
        globals: *std.StringHashMap(object.ObjectPtr),
        builtins: *std.StringHashMap(object.ObjectPtr),
        pc: usize,
        block_stack: std.ArrayList(Block),

        pub const Block = struct {
            type: BlockType,
            handler: usize,
            stack_level: usize,
        };
        pub const BlockType = enum { Loop, Except, Finally };
    };

    pub fn init(allocator: Allocator, xev_loop: ?*xev.Loop) !VM {
        const g = std.StringHashMap(object.ObjectPtr).init(allocator);
        var b = std.StringHashMap(object.ObjectPtr).init(allocator);
        try initBuiltins(allocator, &b);
        return .{
            .allocator = allocator,
            .globals = g,
            .builtins = b,
            .frames = std.ArrayList(Frame).empty,
            .xev_loop = xev_loop,
        };
    }

    pub fn deinit(self: *VM) void {
        self.globals.deinit();
        self.builtins.deinit();
        while (self.frames.pop()) |frame| {
            var f = frame;
            f.stack.deinit(self.allocator);
            f.locals.deinit();
            f.block_stack.deinit(self.allocator);
        }
        self.frames.deinit(self.allocator);
    }

    fn initBuiltins(allocator: Allocator, builtins: *std.StringHashMap(object.ObjectPtr)) !void {
        const none = try object.PyObject.newNone(allocator);
        try builtins.put("None", none);
        const true_obj = try object.PyObject.newBool(allocator, true);
        try builtins.put("True", true_obj);
        const false_obj = try object.PyObject.newBool(allocator, false);
        try builtins.put("False", false_obj);
    }

    pub fn evalCode(self: *VM, code: *object.CodeObject) anyerror!object.ObjectPtr {
        try self.frames.append(self.allocator, Frame{
            .code = code,
            .stack = std.ArrayList(object.ObjectPtr).empty,
            .locals = std.StringHashMap(object.ObjectPtr).init(self.allocator),
            .globals = &self.globals,
            .builtins = &self.builtins,
            .pc = 0,
            .block_stack = std.ArrayList(Frame.Block).empty,
        });
        defer {
            if (self.frames.pop()) |frame| {
                var f = frame;
                f.stack.deinit(self.allocator);
                f.locals.deinit();
                f.block_stack.deinit(self.allocator);
            }
        }

        const current_frame = &self.frames.items[self.frames.items.len - 1];

        while (current_frame.pc < current_frame.code.code.len) {
            const opcode_byte = current_frame.code.code[current_frame.pc];
            const opcode: opcode_mod.Opcode = @enumFromInt(opcode_byte);

            var arg: u16 = 0;
            if (current_frame.pc + 2 < current_frame.code.code.len) {
                const lo = current_frame.code.code[current_frame.pc + 1];
                const hi = current_frame.code.code[current_frame.pc + 2];
                arg = @as(u16, lo) | (@as(u16, hi) << 8);
            }
            const next_pc = current_frame.pc + 3;

            switch (opcode) {
                .NOP => {},
                .POP_TOP => {
                    _ = current_frame.stack.pop();
                },
                .LOAD_CONST => {
                    if (arg < current_frame.code.consts.len) {
                        const obj = current_frame.code.consts[arg];
                        obj.incref();
                        try current_frame.stack.append(self.allocator, obj);
                    } else return error.InvalidConstIndex;
                },
                .LOAD_NAME => {
                    if (arg < current_frame.code.names.len) {
                        const name = current_frame.code.names[arg];
                        if (current_frame.locals.get(name)) |obj| {
                            obj.incref();
                            try current_frame.stack.append(self.allocator, obj);
                        } else if (current_frame.globals.get(name)) |obj| {
                            obj.incref();
                            try current_frame.stack.append(self.allocator, obj);
                        } else if (current_frame.builtins.get(name)) |obj| {
                            obj.incref();
                            try current_frame.stack.append(self.allocator, obj);
                        } else {
                            const none = try object.PyObject.newNone(self.allocator);
                            try current_frame.stack.append(self.allocator, none);
                        }
                    }
                },
                .LOAD_FAST => {
                    if (arg < current_frame.code.varnames.len) {
                        const name = current_frame.code.varnames[arg];
                        if (current_frame.locals.get(name)) |obj| {
                            obj.incref();
                            try current_frame.stack.append(self.allocator, obj);
                        } else {
                            const none = try object.PyObject.newNone(self.allocator);
                            try current_frame.stack.append(self.allocator, none);
                        }
                    }
                },
                .STORE_NAME => {
                    if (arg < current_frame.code.names.len) {
                        const name = current_frame.code.names[arg];
                        const value = current_frame.stack.pop() orelse return error.StackUnderflow;
                        if (current_frame.locals.get(name)) |old| old.decref();
                        try current_frame.locals.put(name, value);
                        // globals: check existing and decref if needed
                        if (current_frame.globals.get(name)) |old_g| {
                            if (old_g != value) old_g.decref();
                        }
                        try current_frame.globals.put(name, value);
                        value.incref();
                    }
                },
                .STORE_FAST => {
                    if (arg < current_frame.code.varnames.len) {
                        const name = current_frame.code.varnames[arg];
                        const value = current_frame.stack.pop() orelse return error.StackUnderflow;
                        if (current_frame.locals.get(name)) |old| old.decref();
                        try current_frame.locals.put(name, value);
                    }
                },
                .LOAD_GLOBAL => {
                    if (arg < current_frame.code.names.len) {
                        const name = current_frame.code.names[arg];
                        if (current_frame.globals.get(name)) |obj| {
                            obj.incref();
                            try current_frame.stack.append(self.allocator, obj);
                        } else if (current_frame.builtins.get(name)) |obj| {
                            obj.incref();
                            try current_frame.stack.append(self.allocator, obj);
                        } else {
                            const none = try object.PyObject.newNone(self.allocator);
                            try current_frame.stack.append(self.allocator, none);
                        }
                    }
                },
                .LOAD_ATTR => {
                    const attr_name = if (arg < current_frame.code.names.len) current_frame.code.names[arg] else "unknown";
                    const obj = current_frame.stack.pop() orelse return error.StackUnderflow;
                    defer obj.decref();
                    switch (obj.value) {
                        .Dict => |*dict| {
                            if (dict.map.get(attr_name)) |val| {
                                val.incref();
                                try current_frame.stack.append(self.allocator, val);
                            } else {
                                const none = try object.PyObject.newNone(self.allocator);
                                try current_frame.stack.append(self.allocator, none);
                            }
                        },
                        .Module => |*mod| {
                            if (mod.dict.get(attr_name)) |val| {
                                val.incref();
                                try current_frame.stack.append(self.allocator, val);
                            } else {
                                const none = try object.PyObject.newNone(self.allocator);
                                try current_frame.stack.append(self.allocator, none);
                            }
                        },
                        else => {
                            const none = try object.PyObject.newNone(self.allocator);
                            try current_frame.stack.append(self.allocator, none);
                        },
                    }
                },
                .IMPORT_NAME => {
                    const mod_name = if (arg < current_frame.code.names.len) current_frame.code.names[arg] else "unknown";
                    _ = current_frame.stack.pop(); // fromlist
                    _ = current_frame.stack.pop(); // level
                    std.debug.print("[Zython] IMPORT_NAME {s}\n", .{mod_name});

                    // Проверяем builtin stdlib модули на libxev
                    var mod_obj: object.ObjectPtr = undefined;
                    var is_builtin = true;
                    if (std.mem.eql(u8, mod_name, "uvicorn")) {
                        mod_obj = try stdlib_uvicorn.UvicornModule.init(self.allocator);
                    } else if (std.mem.eql(u8, mod_name, "os")) {
                        mod_obj = try stdlib_os.OSModule.init(self.allocator);
                    } else if (std.mem.eql(u8, mod_name, "sys")) {
                        mod_obj = try stdlib_sys.SysModule.init(self.allocator);
                    } else if (std.mem.eql(u8, mod_name, "asyncio")) {
                        mod_obj = try stdlib_asyncio.AsyncioModule.init(self.allocator);
                    } else if (std.mem.eql(u8, mod_name, "socket")) {
                        mod_obj = try stdlib_socket.SocketModule.init(self.allocator);
                    } else if (std.mem.eql(u8, mod_name, "json")) {
                        mod_obj = try stdlib_json.JsonModule.init(self.allocator);
                    } else if (std.mem.eql(u8, mod_name, "datetime")) {
                        mod_obj = try stdlib_datetime.DatetimeModule.init(self.allocator);
                    } else if (std.mem.eql(u8, mod_name, "math")) {
                        mod_obj = try stdlib_math.MathModule.init(self.allocator);
                    } else if (std.mem.eql(u8, mod_name, "zycorn")) {
                        mod_obj = try stdlib_zycorn.ZycornModule.init(self.allocator);
                    } else if (std.mem.eql(u8, mod_name, "_zython")) {
                        var dict = std.StringHashMap(object.ObjectPtr).init(self.allocator);
                        const ver = try object.PyObject.newStr(self.allocator, "Zython 0.1.0 + libxev");
                        try dict.put("backend", ver);
                        const mod_val = object.ModuleValue{ .name = "_zython", .dict = dict, .file = null };
                        mod_obj = try object.PyObject.create(self.allocator, &object.ModuleType, .{ .Module = mod_val });
                    } else {
                        is_builtin = false;
                    }

                    if (!is_builtin) {
                        // Создаем пустой модуль заглушку для неизвестных модулей
                        const dict = std.StringHashMap(object.ObjectPtr).init(self.allocator);
                        const mod_val = object.ModuleValue{
                            .name = mod_name,
                            .dict = dict,
                            .file = null,
                        };
                        mod_obj = try object.PyObject.create(self.allocator, &object.ModuleType, .{ .Module = mod_val });
                    }

                    try current_frame.stack.append(self.allocator, mod_obj);
                },
                .IMPORT_FROM => {
                    // Для MVP: берем модуль со стека и пытаемся получить атрибут
                    const attr_name = if (arg < current_frame.code.names.len) current_frame.code.names[arg] else "unknown";
                    const mod_obj = if (current_frame.stack.items.len > 0) current_frame.stack.items[current_frame.stack.items.len - 1] else null;
                    if (mod_obj) |m| {
                        switch (m.value) {
                            .Module => |*mod| {
                                if (mod.dict.get(attr_name)) |val| {
                                    val.incref();
                                    try current_frame.stack.append(self.allocator, val);
                                } else {
                                    const none = try object.PyObject.newNone(self.allocator);
                                    try current_frame.stack.append(self.allocator, none);
                                }
                            },
                            else => {
                                const none = try object.PyObject.newNone(self.allocator);
                                try current_frame.stack.append(self.allocator, none);
                            },
                        }
                    } else {
                        const none = try object.PyObject.newNone(self.allocator);
                        try current_frame.stack.append(self.allocator, none);
                    }
                },
                .IMPORT_STAR => {
                    // from module import * - для MVP просто pop модуль
                    _ = current_frame.stack.pop();
                },
                .BUILD_LIST => {
                    const count = arg;
                    var list_obj = try object.PyObject.newList(self.allocator);
                    var i: usize = 0;
                    while (i < count) : (i += 1) {
                        const item = current_frame.stack.pop() orelse return error.StackUnderflow;
                        try list_obj.value.List.items.append(self.allocator, item);
                    }
                    std.mem.reverse(object.ObjectPtr, list_obj.value.List.items.items);
                    try current_frame.stack.append(self.allocator, list_obj);
                },
                .BUILD_TUPLE => {
                    const count = arg;
                    var items = try self.allocator.alloc(object.ObjectPtr, count);
                    var idx: usize = count;
                    while (idx > 0) {
                        idx -= 1;
                        items[idx] = current_frame.stack.pop() orelse return error.StackUnderflow;
                    }
                    const tuple_obj = try object.PyObject.create(self.allocator, &object.TupleType, .{ .Tuple = items });
                    try current_frame.stack.append(self.allocator, tuple_obj);
                },
                .BINARY_OP => {
                    const right = current_frame.stack.pop() orelse return error.StackUnderflow;
                    defer right.decref();
                    const left = current_frame.stack.pop() orelse return error.StackUnderflow;
                    defer left.decref();
                    const result = try self.binaryOp(left, right, @enumFromInt(@as(u8, @truncate(arg))));
                    try current_frame.stack.append(self.allocator, result);
                },
                .BINARY_SUBSCR => {
                    const sub = current_frame.stack.pop() orelse return error.StackUnderflow;
                    defer sub.decref();
                    const container = current_frame.stack.pop() orelse return error.StackUnderflow;
                    defer container.decref();
                    const result = try self.binarySubscr(container, sub);
                    try current_frame.stack.append(self.allocator, result);
                },
                .UNARY_NEGATIVE => {
                    const operand = current_frame.stack.pop() orelse return error.StackUnderflow;
                    defer operand.decref();
                    const result = try self.unaryNegative(operand);
                    try current_frame.stack.append(self.allocator, result);
                },
                .UNARY_NOT => {
                    const operand = current_frame.stack.pop() orelse return error.StackUnderflow;
                    defer operand.decref();
                    const result = try object.PyObject.newBool(self.allocator, !operand.isTruthy());
                    try current_frame.stack.append(self.allocator, result);
                },
                .COMPARE_OP => {
                    const right = current_frame.stack.pop() orelse return error.StackUnderflow;
                    defer right.decref();
                    const left = current_frame.stack.pop() orelse return error.StackUnderflow;
                    defer left.decref();
                    const result = try self.compareOp(left, right, arg);
                    try current_frame.stack.append(self.allocator, result);
                },
                .POP_JUMP_IF_FALSE => {
                    const value = current_frame.stack.pop() orelse return error.StackUnderflow;
                    defer value.decref();
                    if (!value.isTruthy()) {
                        current_frame.pc = arg;
                        continue;
                    }
                },
                .POP_JUMP_IF_TRUE => {
                    const value = current_frame.stack.pop() orelse return error.StackUnderflow;
                    defer value.decref();
                    if (value.isTruthy()) {
                        current_frame.pc = arg;
                        continue;
                    }
                },
                .JUMP_FORWARD => {
                    current_frame.pc = arg;
                    continue;
                },
                .JUMP_ABSOLUTE => {
                    current_frame.pc = arg;
                    continue;
                },
                .GET_ITER => {},
                .FOR_ITER => {
                    const iter_obj = if (current_frame.stack.items.len > 0) current_frame.stack.items[current_frame.stack.items.len - 1] else null;
                    if (iter_obj == null) {
                        current_frame.pc = arg;
                        continue;
                    }
                    switch (iter_obj.?.value) {
                        .List => |*list| {
                            if (list.items.items.len == 0) {
                                current_frame.pc = arg;
                                continue;
                            } else {
                                const item = list.items.items[0];
                                item.incref();
                                try current_frame.stack.append(self.allocator, item);
                                _ = list.items.orderedRemove(0);
                            }
                        },
                        .Range => |rng| {
                            // Простая реализация range итератора через скрытое состояние в фрейме
                            // Для MVP: храним текущий индекс range в locals под спец именем
                            const range_key = "__range_current";
                            var current_val: i64 = rng.start;
                            if (current_frame.locals.get(range_key)) |cur_obj| {
                                switch (cur_obj.value) {
                                    .Int => |iv| current_val = switch (iv) {
                                        .Small => |v| v,
                                        .Big => 0,
                                    },
                                    else => {},
                                }
                            }
                            // Проверяем конец
                            const done = if (rng.step > 0) current_val >= rng.stop else current_val <= rng.stop;
                            if (done) {
                                // Удаляем временный ключ
                                if (current_frame.locals.get(range_key)) |old| {
                                    old.decref();
                                    _ = current_frame.locals.remove(range_key);
                                }
                                current_frame.pc = arg;
                                continue;
                            } else {
                                const item = try object.PyObject.newInt(self.allocator, current_val);
                                try current_frame.stack.append(self.allocator, item);
                                // Обновляем текущий
                                const next_val = current_val + rng.step;
                                const next_obj = try object.PyObject.newInt(self.allocator, next_val);
                                if (current_frame.locals.get(range_key)) |old| old.decref();
                                try current_frame.locals.put(range_key, next_obj);
                            }
                        },
                        else => {
                            current_frame.pc = arg;
                            continue;
                        },
                    }
                },
                .CALL_FUNCTION => {
                    const arg_count = arg;
                    var args = try self.allocator.alloc(object.ObjectPtr, arg_count);
                    defer self.allocator.free(args);
                    var i: usize = arg_count;
                    while (i > 0) {
                        i -= 1;
                        args[i] = current_frame.stack.pop() orelse return error.StackUnderflow;
                    }
                    defer for (args) |a| a.decref();
                    const func_obj = current_frame.stack.pop() orelse return error.StackUnderflow;
                    defer func_obj.decref();
                    const result = try self.callFunction(func_obj, args);
                    try current_frame.stack.append(self.allocator, result);
                },
                .CALL => {
                    const arg_count = arg & 0xFF;
                    var args = try self.allocator.alloc(object.ObjectPtr, arg_count);
                    defer self.allocator.free(args);
                    var i: usize = arg_count;
                    while (i > 0) {
                        i -= 1;
                        args[i] = current_frame.stack.pop() orelse return error.StackUnderflow;
                    }
                    defer for (args) |a| a.decref();
                    const func_obj = current_frame.stack.pop() orelse return error.StackUnderflow;
                    defer func_obj.decref();
                    const result = try self.callFunction(func_obj, args);
                    try current_frame.stack.append(self.allocator, result);
                },
                .MAKE_FUNCTION => {
                    const qualname = if (current_frame.stack.items.len > 0) current_frame.stack.pop() else null;
                    if (qualname) |q| q.decref();
                    const code_obj_opt = current_frame.stack.pop() orelse return error.StackUnderflow;
                    const func_name = if (code_obj_opt.value == .Code) code_obj_opt.value.Code.name else "anonymous";
                    _ = func_name;
                    const func_obj = try object.PyObject.create(self.allocator, &object.FunctionType, .{ .Code = if (code_obj_opt.value == .Code) code_obj_opt.value.Code else undefined });
                    try current_frame.stack.append(self.allocator, func_obj);
                    code_obj_opt.decref();
                },
                .RETURN_VALUE => {
                    const ret_val = current_frame.stack.pop() orelse try object.PyObject.newNone(self.allocator);
                    return ret_val;
                },
                .ZYTHON_AWAIT_IO, .AWAIT => {
                    if (self.xev_loop) |loop| {
                        _ = loop;
                        std.debug.print("[Zython] AWAIT/ZYTHON_AWAIT_IO - yielding to libxev loop (io_uring)\n", .{});
                    }
                },
                else => {
                    std.debug.print("Unsupported opcode {d} at pc {d}\n", .{ opcode_byte, current_frame.pc });
                    return error.UnsupportedOpcode;
                },
            }
            current_frame.pc = next_pc;
        }
        return try object.PyObject.newNone(self.allocator);
    }

    fn binaryOp(self: *VM, left: object.ObjectPtr, right: object.ObjectPtr, op: opcode_mod.BinaryOp) anyerror!object.ObjectPtr {
        switch (left.value) {
            .Int => |lv| {
                switch (right.value) {
                    .Int => |rv| {
                        const l = switch (lv) {
                            .Small => |v| v,
                            .Big => 0,
                        };
                        const r = switch (rv) {
                            .Small => |v| v,
                            .Big => 0,
                        };
                        const result: i64 = switch (op) {
                            .ADD => l + r,
                            .SUBTRACT => l - r,
                            .MULTIPLY => l * r,
                            .TRUE_DIVIDE => if (r != 0) @divTrunc(l, r) else return error.ZeroDivision,
                            .FLOOR_DIVIDE => if (r != 0) @divFloor(l, r) else return error.ZeroDivision,
                            .REMAINDER => if (r != 0) @mod(l, r) else return error.ZeroDivision,
                            .POWER => std.math.pow(i64, l, r),
                            else => l + r,
                        };
                        return try object.PyObject.newInt(self.allocator, result);
                    },
                    .Float => |rv| {
                        const l: f64 = @floatFromInt(switch (lv) {
                            .Small => |v| v,
                            .Big => 0,
                        });
                        const result: f64 = switch (op) {
                            .ADD => l + rv,
                            .SUBTRACT => l - rv,
                            .MULTIPLY => l * rv,
                            .TRUE_DIVIDE => if (rv != 0) l / rv else return error.ZeroDivision,
                            else => l + rv,
                        };
                        return try object.PyObject.newFloat(self.allocator, result);
                    },
                    else => return try object.PyObject.newNone(self.allocator),
                }
            },
            .Float => |lv| {
                switch (right.value) {
                    .Float => |rv| {
                        const result: f64 = switch (op) {
                            .ADD => lv + rv,
                            .SUBTRACT => lv - rv,
                            .MULTIPLY => lv * rv,
                            .TRUE_DIVIDE => if (rv != 0) lv / rv else return error.ZeroDivision,
                            else => lv + rv,
                        };
                        return try object.PyObject.newFloat(self.allocator, result);
                    },
                    .Int => |rv| {
                        const r: f64 = @floatFromInt(switch (rv) {
                            .Small => |v| v,
                            .Big => 0,
                        });
                        const result: f64 = switch (op) {
                            .ADD => lv + r,
                            .SUBTRACT => lv - r,
                            .MULTIPLY => lv * r,
                            .TRUE_DIVIDE => if (r != 0) lv / r else return error.ZeroDivision,
                            else => lv + r,
                        };
                        return try object.PyObject.newFloat(self.allocator, result);
                    },
                    else => return try object.PyObject.newNone(self.allocator),
                }
            },
            .Str => |ls| {
                switch (right.value) {
                    .Str => |rs| {
                        if (op == .ADD) {
                            const combined = try std.mem.concat(self.allocator, u8, &.{ ls, rs });
                            defer self.allocator.free(combined);
                            return try object.PyObject.newStr(self.allocator, combined);
                        }
                        return try object.PyObject.newStr(self.allocator, ls);
                    },
                    else => return try object.PyObject.newNone(self.allocator),
                }
            },
            .List => |*llist| {
                switch (right.value) {
                    .List => |*rlist| {
                        if (op == .ADD) {
                            const new_list = try object.PyObject.newList(self.allocator);
                            for (llist.items.items) |item| {
                                item.incref();
                                try new_list.value.List.items.append(self.allocator, item);
                            }
                            for (rlist.items.items) |item| {
                                item.incref();
                                try new_list.value.List.items.append(self.allocator, item);
                            }
                            return new_list;
                        }
                        return try object.PyObject.newNone(self.allocator);
                    },
                    else => return try object.PyObject.newNone(self.allocator),
                }
            },
            else => return try object.PyObject.newNone(self.allocator),
        }
    }

    fn binarySubscr(self: *VM, container: object.ObjectPtr, sub: object.ObjectPtr) anyerror!object.ObjectPtr {
        switch (container.value) {
            .List => |*list| {
                switch (sub.value) {
                    .Int => |iv| {
                        const idx_i64 = switch (iv) {
                            .Small => |v| v,
                            .Big => return error.IndexError,
                        };
                        const idx: usize = if (idx_i64 < 0) blk: {
                            const len: i64 = @intCast(list.items.items.len);
                            const adjusted = len + idx_i64;
                            if (adjusted < 0) return error.IndexError;
                            break :blk @intCast(adjusted);
                        } else @intCast(idx_i64);
                        if (idx >= list.items.items.len) return error.IndexError;
                        const item = list.items.items[idx];
                        item.incref();
                        return item;
                    },
                    else => return error.TypeError,
                }
            },
            .Tuple => |items| {
                switch (sub.value) {
                    .Int => |iv| {
                        const idx_i64 = switch (iv) {
                            .Small => |v| v,
                            .Big => return error.IndexError,
                        };
                        const idx: usize = if (idx_i64 < 0) blk: {
                            const len: i64 = @intCast(items.len);
                            const adjusted = len + idx_i64;
                            if (adjusted < 0) return error.IndexError;
                            break :blk @intCast(adjusted);
                        } else @intCast(idx_i64);
                        if (idx >= items.len) return error.IndexError;
                        const item = items[idx];
                        item.incref();
                        return item;
                    },
                    else => return error.TypeError,
                }
            },
            .Dict => |*dict| {
                switch (sub.value) {
                    .Str => |key| {
                        if (dict.map.get(key)) |val| {
                            val.incref();
                            return val;
                        }
                        return error.KeyError;
                    },
                    else => return error.KeyError,
                }
            },
            .Str => |s| {
                switch (sub.value) {
                    .Int => |iv| {
                        const idx_i64 = switch (iv) {
                            .Small => |v| v,
                            .Big => return error.IndexError,
                        };
                        const idx: usize = if (idx_i64 < 0) blk: {
                            const len: i64 = @intCast(s.len);
                            const adjusted = len + idx_i64;
                            if (adjusted < 0) return error.IndexError;
                            break :blk @intCast(adjusted);
                        } else @intCast(idx_i64);
                        if (idx >= s.len) return error.IndexError;
                        const char_str = try self.allocator.alloc(u8, 1);
                        char_str[0] = s[idx];
                        const obj = try object.PyObject.create(self.allocator, &object.StrType, .{ .Str = char_str });
                        return obj;
                    },
                    else => return error.TypeError,
                }
            },
            else => return error.TypeError,
        }
    }

    fn unaryNegative(self: *VM, operand: object.ObjectPtr) anyerror!object.ObjectPtr {
        switch (operand.value) {
            .Int => |iv| {
                const v = switch (iv) {
                    .Small => |small| small,
                    .Big => 0,
                };
                return try object.PyObject.newInt(self.allocator, -v);
            },
            .Float => |f| {
                return try object.PyObject.newFloat(self.allocator, -f);
            },
            else => return try object.PyObject.newNone(self.allocator),
        }
    }

    fn compareOp(self: *VM, left: object.ObjectPtr, right: object.ObjectPtr, op_arg: u16) anyerror!object.ObjectPtr {
        const cmp_op: opcode_mod.CompareOp = @enumFromInt(@as(u8, @truncate(op_arg)));
        const result = switch (left.value) {
            .Int => |lv| switch (right.value) {
                .Int => |rv| blk: {
                    const l = switch (lv) {
                        .Small => |v| v,
                        .Big => 0,
                    };
                    const r = switch (rv) {
                        .Small => |v| v,
                        .Big => 0,
                    };
                    break :blk switch (cmp_op) {
                        .EQ => l == r,
                        .NE => l != r,
                        .LT => l < r,
                        .LE => l <= r,
                        .GT => l > r,
                        .GE => l >= r,
                        else => false,
                    };
                },
                else => false,
            },
            .Str => |ls| switch (right.value) {
                .Str => |rs| switch (cmp_op) {
                    .EQ => std.mem.eql(u8, ls, rs),
                    .NE => !std.mem.eql(u8, ls, rs),
                    .LT => std.mem.order(u8, ls, rs) == .lt,
                    .GT => std.mem.order(u8, ls, rs) == .gt,
                    .LE => std.mem.order(u8, ls, rs) != .gt,
                    .GE => std.mem.order(u8, ls, rs) != .lt,
                    else => false,
                },
                else => false,
            },
            .Bool => |lb| switch (right.value) {
                .Bool => |rb| switch (cmp_op) {
                    .EQ => lb == rb,
                    .NE => lb != rb,
                    else => false,
                },
                else => false,
            },
            else => false,
        };
        return try object.PyObject.newBool(self.allocator, result);
    }

    fn callFunction(self: *VM, func_obj: object.ObjectPtr, args: []object.ObjectPtr) anyerror!object.ObjectPtr {
        switch (func_obj.value) {
            .Code => |code| {
                var new_vm = try VM.init(self.allocator, self.xev_loop);
                defer new_vm.deinit();

                try new_vm.frames.append(self.allocator, Frame{
                    .code = code,
                    .stack = std.ArrayList(object.ObjectPtr).empty,
                    .locals = std.StringHashMap(object.ObjectPtr).init(self.allocator),
                    .globals = &self.globals,
                    .builtins = &self.builtins,
                    .pc = 0,
                    .block_stack = std.ArrayList(Frame.Block).empty,
                });

                const frame_ptr = &new_vm.frames.items[new_vm.frames.items.len - 1];
                for (code.varnames, 0..) |varname, i| {
                    if (i < args.len) {
                        args[i].incref();
                        try frame_ptr.locals.put(varname, args[i]);
                    }
                }

                const result = try new_vm.evalCode(code);
                return result;
            },
            .BuiltinFunction => |bf| {
                return try bf(args, self.allocator);
            },
            else => {
                return try object.PyObject.newNone(self.allocator);
            },
        }
    }
};

pub fn builtinPrint(args: []object.ObjectPtr, allocator: Allocator) !object.ObjectPtr {
    for (args, 0..) |arg, i| {
        if (i != 0) std.debug.print(" ", .{});
        const repr = arg.repr(allocator) catch "?";
        defer allocator.free(repr);
        std.debug.print("{s}", .{repr});
    }
    std.debug.print("\n", .{});
    return try object.PyObject.newNone(allocator);
}

test "vm basic" {
    const alloc = std.testing.allocator;
    var vm = try VM.init(alloc, null);
    defer vm.deinit();
    const none = try object.PyObject.newNone(alloc);
    defer none.decref();
    try std.testing.expect(none.value == .None);
}
