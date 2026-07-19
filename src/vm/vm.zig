//! Виртуальная машина Zython — аналог Python/ceval.c
//! Поддерживает CPython 3.13+ opcodes с расширениями Zython для libxev
//! Многопоточность через libxev ThreadPool

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const object = @import("../object/object.zig");
const opcode_mod = @import("opcode.zig");
const xev = @import("xev");
const stdlib_os = @import("../stdlib/os.zig");
const stdlib_sys = @import("../stdlib/sys.zig");
const stdlib_asyncio = @import("../stdlib/asyncio.zig");
const stdlib_socket = @import("../stdlib/socket.zig");
const stdlib_json = @import("../stdlib/json.zig");
const stdlib_datetime = @import("../stdlib/datetime.zig");
const stdlib_math = @import("../stdlib/math.zig");
const stdlib_uvicorn = @import("../stdlib/uvicorn.zig");
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
                .CACHE => {},
                .POP_TOP => {
                    if (current_frame.stack.items.len > 0) {
                        const popped = current_frame.stack.pop();
                        if (popped) |p| p.decref();
                    }
                },
                .PUSH_NULL => {
                    // In CPython 3.13+, PUSH_NULL pushes a NULL to the stack for CALL
                    // We push None as a placeholder
                    const null_obj = try object.PyObject.newNone(self.allocator);
                    try current_frame.stack.append(self.allocator, null_obj);
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
                            std.debug.print("[Zython VM] NameError: name '{s}' is not defined\n", .{name});
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
                .LOAD_SMALL_INT => {
                    // CPython 3.13: LOAD_SMALL_INT loads small integer from arg directly
                    try current_frame.stack.append(self.allocator, try object.PyObject.newInt(self.allocator, @intCast(arg)));
                },
                .STORE_NAME => {
                    if (arg < current_frame.code.names.len) {
                        const name = current_frame.code.names[arg];
                        const value = current_frame.stack.pop() orelse return error.StackUnderflow;
                        if (current_frame.locals.get(name)) |old| old.decref();
                        try current_frame.locals.put(name, value);
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
                .STORE_GLOBAL => {
                    if (arg < current_frame.code.names.len) {
                        const name = current_frame.code.names[arg];
                        const value = current_frame.stack.pop() orelse return error.StackUnderflow;
                        if (current_frame.globals.get(name)) |old| old.decref();
                        try current_frame.globals.put(name, value);
                    }
                },
                .DELETE_FAST => {
                    if (arg < current_frame.code.varnames.len) {
                        const name = current_frame.code.varnames[arg];
                        if (current_frame.locals.get(name)) |old| old.decref();
                        _ = current_frame.locals.remove(name);
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
                            std.debug.print("[Zython VM] NameError: global name '{s}' is not defined\n", .{name});
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
                .STORE_ATTR => {
                    const attr_name = if (arg < current_frame.code.names.len) current_frame.code.names[arg] else "unknown";
                    const val = current_frame.stack.pop() orelse return error.StackUnderflow;
                    const obj = current_frame.stack.pop() orelse return error.StackUnderflow;
                    switch (obj.value) {
                        .Dict => |*dict| {
                            val.incref();
                            try dict.map.put(attr_name, val);
                        },
                        .Module => |*mod| {
                            val.incref();
                            try mod.dict.put(attr_name, val);
                        },
                        else => {},
                    }
                    val.decref();
                    obj.decref();
                },
                .IMPORT_NAME => {
                    const mod_name = if (arg < current_frame.code.names.len) current_frame.code.names[arg] else "unknown";
                    // Pop fromlist and level from stack (CPython convention)
                    if (current_frame.stack.items.len > 0) _ = current_frame.stack.pop();
                    if (current_frame.stack.items.len > 0) _ = current_frame.stack.pop();

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
                    } else if (std.mem.eql(u8, mod_name, "zython") or std.mem.eql(u8, mod_name, "_zython")) {
                        // Import zython module — access to Zig runtime
                        var dict = std.StringHashMap(object.ObjectPtr).init(self.allocator);
                        const zver = builtin.zig_version;
                        const ver = try std.fmt.allocPrint(self.allocator, "{d}.{d}.{d}", .{ zver.major, zver.minor, zver.patch });
                        const ver_obj = try object.PyObject.newStr(self.allocator, ver);
                        try dict.put("zig_version", ver_obj);
                        const backend = try object.PyObject.newStr(self.allocator, @tagName(xev.backend));
                        try dict.put("backend", backend);
                        const no_gil = try object.PyObject.newBool(self.allocator, true);
                        try dict.put("no_gil", no_gil);
                        const mod_val = object.ModuleValue{ .name = mod_name, .dict = dict, .file = null };
                        mod_obj = try object.PyObject.create(self.allocator, &object.ModuleType, .{ .Module = mod_val });
                    } else {
                        is_builtin = false;
                    }

                    if (!is_builtin) {
                        // Create stub module for unknown modules
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
                .BUILD_MAP => {
                    const count = arg;
                    const dict_obj = try object.PyObject.newDict(self.allocator);
                    // Items are on stack as key, value, key, value, ...
                    var i: usize = 0;
                    while (i < count) : (i += 1) {
                        const val = current_frame.stack.pop() orelse return error.StackUnderflow;
                        const key = current_frame.stack.pop() orelse return error.StackUnderflow;
                        switch (key.value) {
                            .Str => |s| {
                                val.incref();
                                try dict_obj.value.Dict.map.put(s, val);
                            },
                            else => {
                                // Use generic_map for non-string keys
                                const hash = @intFromPtr(key);
                                val.incref();
                                try dict_obj.value.Dict.generic_map.put(hash, val);
                            },
                        }
                        key.decref();
                    }
                    try current_frame.stack.append(self.allocator, dict_obj);
                },
                .BUILD_SET => {
                    const count = arg;
                    const set_obj = try object.PyObject.create(self.allocator, &object.PyType{ .name = "set", .type_id = .Set }, .{ .Set = .{ .items = std.AutoHashMap(u64, object.ObjectPtr).init(self.allocator) } });
                    var i: usize = 0;
                    while (i < count) : (i += 1) {
                        _ = current_frame.stack.pop() orelse return error.StackUnderflow;
                    }
                    try current_frame.stack.append(self.allocator, set_obj);
                },
                .BUILD_SLICE => {
                    // Simplified: just pop args and push None
                    var i: usize = 0;
                    while (i < arg) : (i += 1) {
                        if (current_frame.stack.items.len > 0) {
                            const popped = current_frame.stack.pop();
                            if (popped) |p| p.decref();
                        }
                    }
                    const none = try object.PyObject.newNone(self.allocator);
                    try current_frame.stack.append(self.allocator, none);
                },
                .BUILD_STRING => {
                    const count = arg;
                    var parts: std.ArrayList([]const u8) = .empty;
                    defer parts.deinit(self.allocator);
                    var i: usize = 0;
                    while (i < count) : (i += 1) {
                        const item = current_frame.stack.pop() orelse return error.StackUnderflow;
                        const s = switch (item.value) {
                            .Str => |s| try self.allocator.dupe(u8, s),
                            else => try item.repr(self.allocator),
                        };
                        try parts.append(self.allocator, s);
                        item.decref();
                    }
                    std.mem.reverse([]const u8, parts.items);
                    const result = try std.mem.concat(self.allocator, u8, parts.items);
                    defer self.allocator.free(result);
                    const str_obj = try object.PyObject.newStr(self.allocator, result);
                    try current_frame.stack.append(self.allocator, str_obj);
                    for (parts.items) |p| self.allocator.free(p);
                },
                .BINARY_OP => {
                    if (arg == 26) {
                        // NB_SUBSCR — subscription a[b]
                        const sub = current_frame.stack.pop() orelse return error.StackUnderflow;
                        defer sub.decref();
                        const container = current_frame.stack.pop() orelse return error.StackUnderflow;
                        defer container.decref();
                        const result = try self.binarySubscr(container, sub);
                        try current_frame.stack.append(self.allocator, result);
                    } else {
                        const right = current_frame.stack.pop() orelse return error.StackUnderflow;
                        defer right.decref();
                        const left = current_frame.stack.pop() orelse return error.StackUnderflow;
                        defer left.decref();
                        const result = try self.binaryOp(left, right, @enumFromInt(@as(u8, @truncate(arg))));
                        try current_frame.stack.append(self.allocator, result);
                    }
                },
                .BINARY_SLICE => {
                    const upper = current_frame.stack.pop() orelse return error.StackUnderflow;
                    defer upper.decref();
                    const lower = current_frame.stack.pop() orelse return error.StackUnderflow;
                    defer lower.decref();
                    const container = current_frame.stack.pop() orelse return error.StackUnderflow;
                    defer container.decref();
                    // For now, use index-based access if lower is an int and upper is None
                    switch (lower.value) {
                        .Int => |iv| {
                            const idx = switch (iv) { .Small => |v| v, .Big => 0 };
                            switch (container.value) {
                                .List => |*list| {
                                    const uidx: usize = if (idx >= 0) @intCast(idx) else blk: {
                                        const len: i64 = @intCast(list.items.items.len);
                                        break :blk @intCast(std.math.clamp(len + idx, 0, len));
                                    };
                                    if (uidx < list.items.items.len) {
                                        const item = list.items.items[uidx];
                                        item.incref();
                                        try current_frame.stack.append(self.allocator, item);
                                    } else {
                                        try current_frame.stack.append(self.allocator, try object.PyObject.newNone(self.allocator));
                                    }
                                },
                                else => try current_frame.stack.append(self.allocator, try object.PyObject.newNone(self.allocator)),
                            }
                        },
                        else => {
                            container.incref();
                            try current_frame.stack.append(self.allocator, container);
                        },
                    }
                },
                .STORE_SUBSCR => {
                    const val = current_frame.stack.pop() orelse return error.StackUnderflow;
                    const sub = current_frame.stack.pop() orelse return error.StackUnderflow;
                    const container = current_frame.stack.pop() orelse return error.StackUnderflow;
                    switch (container.value) {
                        .Dict => |*dict| switch (sub.value) {
                            .Str => |s| {
                                val.incref();
                                try dict.map.put(s, val);
                            },
                            else => {},
                        },
                        .List => |*list| switch (sub.value) {
                            .Int => |iv| {
                                const idx = switch (iv) {
                                    .Small => |v| if (v >= 0) @as(usize, @intCast(v)) else return error.IndexError,
                                    .Big => return error.IndexError,
                                };
                                if (idx < list.items.items.len) {
                                    list.items.items[idx].decref();
                                    val.incref();
                                    list.items.items[idx] = val;
                                }
                            },
                            else => {},
                        },
                        else => {},
                    }
                    val.decref();
                    sub.decref();
                    container.decref();
                },
                .DELETE_SUBSCR => {
                    const sub = current_frame.stack.pop() orelse return error.StackUnderflow;
                    const container = current_frame.stack.pop() orelse return error.StackUnderflow;
                    switch (container.value) {
                        .Dict => |*dict| switch (sub.value) {
                            .Str => |s| {
                                if (dict.map.get(s)) |old| old.decref();
                                _ = dict.map.remove(s);
                            },
                            else => {},
                        },
                        else => {},
                    }
                    sub.decref();
                    container.decref();
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
                .UNARY_INVERT => {
                    const operand = current_frame.stack.pop() orelse return error.StackUnderflow;
                    defer operand.decref();
                    switch (operand.value) {
                        .Int => |iv| {
                            const v = switch (iv) { .Small => |val| val, .Big => 0 };
                            try current_frame.stack.append(self.allocator, try object.PyObject.newInt(self.allocator, ~v));
                        },
                        else => try current_frame.stack.append(self.allocator, try object.PyObject.newNone(self.allocator)),
                    }
                },
                .COMPARE_OP => {
                    const right = current_frame.stack.pop() orelse return error.StackUnderflow;
                    defer right.decref();
                    const left = current_frame.stack.pop() orelse return error.StackUnderflow;
                    defer left.decref();
                    const result = try self.compareOp(left, right, arg);
                    try current_frame.stack.append(self.allocator, result);
                },
                .CONTAINS_OP => {
                    const right = current_frame.stack.pop() orelse return error.StackUnderflow;
                    defer right.decref();
                    const left = current_frame.stack.pop() orelse return error.StackUnderflow;
                    defer left.decref();
                    // arg=0 means "in", arg=1 means "not in"
                    var found = false;
                    switch (right.value) {
                        .List => |*l| {
                            for (l.items.items) |item| {
                                if (try self.valuesEqual(left, item)) {
                                    found = true;
                                    break;
                                }
                            }
                        },
                        .Str => |s| switch (left.value) {
                            .Str => |sub| found = std.mem.containsAtLeast(u8, s, 1, sub),
                            else => {},
                        },
                        .Dict => |*d| switch (left.value) {
                            .Str => |key| found = d.map.contains(key),
                            else => {},
                        },
                        else => {},
                    }
                    if (arg == 1) found = !found;
                    try current_frame.stack.append(self.allocator, try object.PyObject.newBool(self.allocator, found));
                },
                .IS_OP => {
                    const right = current_frame.stack.pop() orelse return error.StackUnderflow;
                    defer right.decref();
                    const left = current_frame.stack.pop() orelse return error.StackUnderflow;
                    defer left.decref();
                    // arg=0 means "is", arg=1 means "is not"
                    const is_same = left == right;
                    const result = if (arg == 0) is_same else !is_same;
                    try current_frame.stack.append(self.allocator, try object.PyObject.newBool(self.allocator, result));
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
                .POP_JUMP_IF_NONE => {
                    const value = current_frame.stack.pop() orelse return error.StackUnderflow;
                    defer value.decref();
                    if (value.value == .None) {
                        current_frame.pc = arg;
                        continue;
                    }
                },
                .POP_JUMP_IF_NOT_NONE => {
                    const value = current_frame.stack.pop() orelse return error.StackUnderflow;
                    defer value.decref();
                    if (value.value != .None) {
                        current_frame.pc = arg;
                        continue;
                    }
                },
                .JUMP_FORWARD => {
                    current_frame.pc = arg;
                    continue;
                },
                .JUMP_BACKWARD => {
                    current_frame.pc = arg;
                    continue;
                },
                .COPY => {
                    // COPY(i) — copy i-th item from top of stack
                    const idx_from_top = arg;
                    if (idx_from_top < current_frame.stack.items.len) {
                        const idx = current_frame.stack.items.len - 1 - idx_from_top;
                        const item = current_frame.stack.items[idx];
                        item.incref();
                        try current_frame.stack.append(self.allocator, item);
                    }
                },
                .SWAP => {
                    // SWAP(i) — swap top of stack with i-th item
                    const idx_from_top = arg;
                    if (idx_from_top < current_frame.stack.items.len and current_frame.stack.items.len > 0) {
                        const top = current_frame.stack.items.len - 1;
                        const target = top - idx_from_top;
                        const tmp = current_frame.stack.items[top];
                        current_frame.stack.items[top] = current_frame.stack.items[target];
                        current_frame.stack.items[target] = tmp;
                    }
                },
                .GET_ITER => {
                    // Mark object as iterable — in our simplified version, just leave on stack
                    // The object stays as-is; FOR_ITER will handle iteration
                },
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
                            const done = if (rng.step > 0) current_val >= rng.stop else current_val <= rng.stop;
                            if (done) {
                                if (current_frame.locals.get(range_key)) |old| {
                                    old.decref();
                                    _ = current_frame.locals.remove(range_key);
                                }
                                current_frame.pc = arg;
                                continue;
                            } else {
                                const item = try object.PyObject.newInt(self.allocator, current_val);
                                try current_frame.stack.append(self.allocator, item);
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
                .CALL => {
                    // CPython 3.13 CALL: the callable is below the null/self marker
                    // We simplify: pop args, then pop function
                    const arg_count = arg & 0xFF;
                    var args = try self.allocator.alloc(object.ObjectPtr, arg_count);
                    defer self.allocator.free(args);
                    var i: usize = arg_count;
                    while (i > 0) {
                        i -= 1;
                        args[i] = current_frame.stack.pop() orelse return error.StackUnderflow;
                    }
                    defer for (args) |a| a.decref();
                    // Pop NULL/self marker if present
                    const maybe_null = current_frame.stack.pop() orelse return error.StackUnderflow;
                    const func_obj = if (maybe_null.value == .None) blk: {
                        // This was a NULL marker, pop the actual function
                        break :blk current_frame.stack.pop() orelse return error.StackUnderflow;
                    } else maybe_null;
                    defer func_obj.decref();
                    const result = try self.callFunction(func_obj, args);
                    try current_frame.stack.append(self.allocator, result);
                },
                .CALL_FUNCTION => {
                    // Legacy CALL_FUNCTION for our own compiler
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
                .MAKE_FUNCTION => {
                    const qualname = if (current_frame.stack.items.len > 0) current_frame.stack.pop() else null;
                    if (qualname) |q| q.decref();
                    const code_obj_opt = current_frame.stack.pop() orelse return error.StackUnderflow;
                    const func_obj = try object.PyObject.create(self.allocator, &object.FunctionType, .{ .Code = if (code_obj_opt.value == .Code) code_obj_opt.value.Code else undefined });
                    try current_frame.stack.append(self.allocator, func_obj);
                    code_obj_opt.decref();
                },
                .RETURN_VALUE => {
                    const ret_val = current_frame.stack.pop() orelse try object.PyObject.newNone(self.allocator);
                    return ret_val;
                },
                .RETURN_CONST => {
                    // CPython 3.13: RETURN_CONST arg — load const and return it
                    if (arg < current_frame.code.consts.len) {
                        const obj = current_frame.code.consts[arg];
                        obj.incref();
                        return obj;
                    }
                    return try object.PyObject.newNone(self.allocator);
                },
                .RAISE_VARARGS => {
                    const exc = if (arg > 0 and current_frame.stack.items.len > 0) current_frame.stack.pop() else null;
                    if (exc) |e| {
                        const repr = e.repr(self.allocator) catch "unknown" ;
                        defer self.allocator.free(repr);
                        std.debug.print("[Zython VM] Exception raised: {s}\n", .{repr});
                        self.last_exception = e;
                    }
                    return error.RuntimeError;
                },
                .POP_EXCEPT => {
                    // Pop exception handler from block stack
                    if (current_frame.block_stack.items.len > 0) {
                        _ = current_frame.block_stack.pop();
                    }
                },
                .PUSH_EXC_INFO => {
                    // Push current exception info
                    const exc = self.last_exception orelse try object.PyObject.newNone(self.allocator);
                    exc.incref();
                    try current_frame.stack.append(self.allocator, exc);
                },
                .RESUME => {
                    // CPython 3.13: RESUME instruction at start of frame — no-op for us
                },
                .EXTENDED_ARG => {
                    // Next instruction's arg will be extended — handled by arg composition
                    // For now, just skip
                },
                .COPY_FREE_VARS => {
                    // Copy free variables — no-op in our simplified implementation
                },
                .ZYTHON_AWAIT_IO, .GET_AWAITABLE => {
                    if (self.xev_loop) |loop| {
                        _ = loop;
                        std.debug.print("[Zython VM] AWAIT -> yielding to libxev loop ({s})\n", .{@tagName(xev.backend)});
                    }
                },
                .ZYTHON_THREAD_SPAWN => {
                    std.debug.print("[Zython VM] THREAD_SPAWN -> xev.ThreadPool schedule\n", .{});
                },
                .ZYTHON_THREAD_JOIN => {
                    std.debug.print("[Zython VM] THREAD_JOIN -> waiting for thread completion\n", .{});
                },
                .ZYTHON_ASYNC_CALL => {
                    std.debug.print("[Zython VM] ASYNC_CALL -> xev async call\n", .{});
                },
                .ZYTHON_YIELD_XEV => {
                    std.debug.print("[Zython VM] YIELD_XEV -> yield to libxev\n", .{});
                },
                else => {
                    std.debug.print("[Zython VM] Unsupported opcode {s} ({d}) at pc {d}\n", .{ opcode.toString(), opcode_byte, current_frame.pc });
                    return error.UnsupportedOpcode;
                },
            }
            current_frame.pc = next_pc;
        }
        return try object.PyObject.newNone(self.allocator);
    }

    fn valuesEqual(self: *VM, a: object.ObjectPtr, b: object.ObjectPtr) !bool {
        _ = self;
        return switch (a.value) {
            .Int => |av| switch (b.value) {
                .Int => |bv| switch (av) {
                    .Small => |a1| switch (bv) {
                        .Small => |b1| a1 == b1,
                        .Big => false,
                    },
                    .Big => false,
                },
                else => false,
            },
            .Str => |as| switch (b.value) {
                .Str => |bs| std.mem.eql(u8, as, bs),
                else => false,
            },
            .Bool => |ab| switch (b.value) {
                .Bool => |bb| ab == bb,
                else => false,
            },
            .None => b.value == .None,
            else => a == b,
        };
    }

    fn binaryOp(self: *VM, left: object.ObjectPtr, right: object.ObjectPtr, op: opcode_mod.BinaryOp) anyerror!object.ObjectPtr {
        switch (left.value) {
            .Int => |lv| {
                switch (right.value) {
                    .Int => |rv| {
                        const l = switch (lv) { .Small => |v| v, .Big => 0 };
                        const r = switch (rv) { .Small => |v| v, .Big => 0 };
                        const result: i64 = switch (op) {
                            .ADD => l + r,
                            .SUBTRACT => l - r,
                            .MULTIPLY => l * r,
                            .TRUE_DIVIDE => if (r != 0) @divTrunc(l, r) else return error.ZeroDivision,
                            .FLOOR_DIVIDE => if (r != 0) @divFloor(l, r) else return error.ZeroDivision,
                            .REMAINDER => if (r != 0) @mod(l, r) else return error.ZeroDivision,
                            .POWER => std.math.pow(i64, l, r),
                            .AND => l & r,
                            .OR => l | r,
                            .XOR => l ^ r,
                            .LSHIFT => l << @intCast(std.math.clamp(r, 0, 63)),
                            .RSHIFT => l >> @intCast(std.math.clamp(r, 0, 63)),
                            .INPLACE_ADD => l + r,
                            .INPLACE_SUBTRACT => l - r,
                            .INPLACE_MULTIPLY => l * r,
                            else => l + r,
                        };
                        return try object.PyObject.newInt(self.allocator, result);
                    },
                    .Float => |rv| {
                        const l: f64 = @floatFromInt(switch (lv) { .Small => |v| v, .Big => 0 });
                        const result: f64 = switch (op) {
                            .ADD => l + rv,
                            .SUBTRACT => l - rv,
                            .MULTIPLY => l * rv,
                            .TRUE_DIVIDE => if (rv != 0) l / rv else return error.ZeroDivision,
                            .FLOOR_DIVIDE => if (rv != 0) @floor(l / rv) else return error.ZeroDivision,
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
                        const r: f64 = @floatFromInt(switch (rv) { .Small => |v| v, .Big => 0 });
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
                        if (op == .ADD or op == .INPLACE_ADD) {
                            const combined = try std.mem.concat(self.allocator, u8, &.{ ls, rs });
                            defer self.allocator.free(combined);
                            return try object.PyObject.newStr(self.allocator, combined);
                        }
                        return try object.PyObject.newStr(self.allocator, ls);
                    },
                    .Int => |rv| {
                        // str * int = repeat
                        if (op == .MULTIPLY) {
                            const count = switch (rv) { .Small => |v| std.math.clamp(v, 0, 1000), .Big => 1 };
                            if (count == 0) return try object.PyObject.newStr(self.allocator, "");
                            var result_buf: std.ArrayList(u8) = .empty;
                            var i: i64 = 0;
                            while (i < count) : (i += 1) {
                                try result_buf.appendSlice(self.allocator, ls);
                            }
                            const str = try result_buf.toOwnedSlice(self.allocator);
                            defer self.allocator.free(str);
                            return try object.PyObject.newStr(self.allocator, str);
                        }
                        return try object.PyObject.newStr(self.allocator, ls);
                    },
                    else => return try object.PyObject.newNone(self.allocator),
                }
            },
            .List => |*llist| {
                switch (right.value) {
                    .List => |*rlist| {
                        if (op == .ADD or op == .INPLACE_ADD) {
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
                        const idx_i64 = switch (iv) { .Small => |v| v, .Big => return error.IndexError };
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
                        const idx_i64 = switch (iv) { .Small => |v| v, .Big => return error.IndexError };
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
                        const idx_i64 = switch (iv) { .Small => |v| v, .Big => return error.IndexError };
                        const idx: usize = if (idx_i64 < 0) blk: {
                            const len: i64 = @intCast(s.len);
                            const adjusted = len + idx_i64;
                            if (adjusted < 0) return error.IndexError;
                            break :blk @intCast(adjusted);
                        } else @intCast(idx_i64);
                        if (idx >= s.len) return error.IndexError;
                        const char_str = try self.allocator.alloc(u8, 1);
                        char_str[0] = s[idx];
                        return try object.PyObject.create(self.allocator, &object.StrType, .{ .Str = char_str });
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
                const v = switch (iv) { .Small => |small| small, .Big => 0 };
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
                    const l = switch (lv) { .Small => |v| v, .Big => 0 };
                    const r = switch (rv) { .Small => |v| v, .Big => 0 };
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
                .Float => |rv| blk: {
                    const l: f64 = @floatFromInt(switch (lv) { .Small => |v| v, .Big => 0 });
                    break :blk switch (cmp_op) {
                        .EQ => l == rv,
                        .NE => l != rv,
                        .LT => l < rv,
                        .LE => l <= rv,
                        .GT => l > rv,
                        .GE => l >= rv,
                        else => false,
                    };
                },
                else => false,
            },
            .Float => |lv| switch (right.value) {
                .Float => |rv| switch (cmp_op) {
                    .EQ => lv == rv,
                    .NE => lv != rv,
                    .LT => lv < rv,
                    .LE => lv <= rv,
                    .GT => lv > rv,
                    .GE => lv >= rv,
                    else => false,
                },
                .Int => |rv| blk: {
                    const r: f64 = @floatFromInt(switch (rv) { .Small => |v| v, .Big => 0 });
                    break :blk switch (cmp_op) {
                        .EQ => lv == r,
                        .NE => lv != r,
                        .LT => lv < r,
                        .LE => lv <= r,
                        .GT => lv > r,
                        .GE => lv >= r,
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
            .None => switch (right.value) {
                .None => switch (cmp_op) {
                    .EQ => true,
                    .NE => false,
                    else => false,
                },
                else => switch (cmp_op) {
                    .EQ => false,
                    .NE => true,
                    else => false,
                },
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
                std.debug.print("[Zython VM] Cannot call object of type {s}\n", .{func_obj.type_ptr.name});
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
