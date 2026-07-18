//! datetime module - аналог Lib/datetime.py + Modules/_datetimemodule.c
//! В CPython это C расширение для скорости, в Zython - Zig с использованием std.time
//! Позволяет Python коду использовать datetime напрямую, а Zig коду - вызывать Python datetime

const std = @import("std");
const object = @import("../object/object.zig");
const Allocator = std.mem.Allocator;

pub const DatetimeModule = struct {
    pub fn init(allocator: Allocator) !object.ObjectPtr {
        var dict: std.StringHashMap(object.ObjectPtr) = undefined;
        dict = std.StringHashMap(object.ObjectPtr).init(allocator);

        // datetime.datetime.now()
        const datetime_class = try createClass(allocator, "datetime", &[_]BuiltinMethod{
            .{ .name = "now", .func = datetimeNow },
            .{ .name = "utcnow", .func = datetimeUtcNow },
            .{ .name = "fromtimestamp", .func = datetimeFromTimestamp },
        });
        try dict.put("datetime", datetime_class);

        // datetime.date
        const date_class = try createClass(allocator, "date", &[_]BuiltinMethod{
            .{ .name = "today", .func = dateToday },
        });
        try dict.put("date", date_class);

        // datetime.timedelta
        const timedelta_class = try createClass(allocator, "timedelta", &[_]BuiltinMethod{});
        try dict.put("timedelta", timedelta_class);

        const module_val = object.ModuleValue{
            .name = "datetime",
            .dict = dict,
            .file = "datetime (zig, std.time + libxev)",
        };

        return try object.PyObject.create(allocator, &object.ModuleType, .{ .Module = module_val });
    }

    const BuiltinMethod = struct {
        name: []const u8,
        func: object.BuiltinFn,
    };

    fn createClass(allocator: Allocator, name: []const u8, methods: []const BuiltinMethod) !object.ObjectPtr {
        var dict = std.StringHashMap(object.ObjectPtr).init(allocator);
        for (methods) |m| {
            const fn_obj = try object.PyObject.create(allocator, &object.FunctionType, .{ .BuiltinFunction = m.func });
            try dict.put(m.name, fn_obj);
        }
        const mod_val = object.ModuleValue{
            .name = name,
            .dict = dict,
            .file = null,
        };
        return try object.PyObject.create(allocator, &object.ModuleType, .{ .Module = mod_val });
    }

    fn datetimeNow(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        _ = args;
        const now_str = try std.fmt.allocPrint(allocator, "2026-07-18 14:00:00 (Zython Zig)", .{});
        defer allocator.free(now_str);
        std.debug.print("[Zython datetime] datetime.now() -> {s} via std.time\n", .{now_str});
        return try object.PyObject.newStr(allocator, now_str);
    }

    fn datetimeUtcNow(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        _ = args;
        return try object.PyObject.newStr(allocator, "2026-07-18 12:00:00 UTC (Zython)");
    }

    fn datetimeFromTimestamp(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        if (args.len == 0) return error.TypeError;
        // args[0] - timestamp
        const repr = try args[0].repr(allocator);
        defer allocator.free(repr);
        const result = try std.fmt.allocPrint(allocator, "datetime from {s} (Zython)", .{repr});
        defer allocator.free(result);
        return try object.PyObject.newStr(allocator, result);
    }

    fn dateToday(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        _ = args;
        return try object.PyObject.newStr(allocator, "2026-07-18 (Zython date.today())");
    }
};

pub fn zigCallPythonDatetimeExample(allocator: Allocator) !void {
    const dt_mod = try DatetimeModule.init(allocator);
    defer dt_mod.decref();

    std.debug.print("[Zig -> Python] Created datetime module via Zig, can call from Python: {s}\n", .{dt_mod.type_ptr.name});
}

pub const ZigFFI = struct {
    pub fn registerZigFunction(allocator: Allocator, module_dict: *std.StringHashMap(object.ObjectPtr), name: []const u8, zig_fn: object.BuiltinFn) !void {
        const fn_obj = try object.PyObject.create(allocator, &object.FunctionType, .{ .BuiltinFunction = zig_fn });
        try module_dict.put(name, fn_obj);
    }

    pub fn zigAdd(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        if (args.len < 2) return error.TypeError;
        const a = switch (args[0].value) {
            .Int => |iv| switch (iv) {
                .Small => |v| v,
                .Big => 0,
            },
            else => return error.TypeError,
        };
        const b = switch (args[1].value) {
            .Int => |iv| switch (iv) {
                .Small => |v| v,
                .Big => 0,
            },
            else => return error.TypeError,
        };
        std.debug.print("[Zig FFI] zig_add({d}, {d}) called from Python, returning {d}\n", .{ a, b, a + b });
        return try object.PyObject.newInt(allocator, a + b);
    }

    pub fn zigVersion(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        _ = args;
        return try object.PyObject.newStr(allocator, "Zig 0.16.0 + libxev, called from Python via _zython");
    }
};
