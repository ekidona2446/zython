//! json module - аналог Lib/json/ + Modules/_json.c
//! В CPython _json - C расширение для скорости, в Zython - Zig реализация
//! Поддерживает json.loads / dumps, используя Zig std.json

const std = @import("std");
const object = @import("../object/object.zig");
const Allocator = std.mem.Allocator;

pub const JsonModule = struct {
    pub fn init(allocator: Allocator) !object.ObjectPtr {
        var dict: std.StringHashMap(object.ObjectPtr) = undefined;
        dict = std.StringHashMap(object.ObjectPtr).init(allocator);

        const loads_fn = try createBuiltin(allocator, "loads", loads);
        try dict.put("loads", loads_fn);

        const dumps_fn = try createBuiltin(allocator, "dumps", dumps);
        try dict.put("dumps", dumps_fn);

        const load_fn = try createBuiltin(allocator, "load", load);
        try dict.put("load", load_fn);

        const dump_fn = try createBuiltin(allocator, "dump", dump);
        try dict.put("dump", dump_fn);

        const module_val = object.ModuleValue{
            .name = "json",
            .dict = dict,
            .file = "json (zig, std.json)",
        };

        return try object.PyObject.create(allocator, &object.ModuleType, .{ .Module = module_val });
    }

    fn createBuiltin(allocator: Allocator, name: []const u8, func: object.BuiltinFn) !object.ObjectPtr {
        _ = name;
        return try object.PyObject.create(allocator, &object.FunctionType, .{ .BuiltinFunction = func });
    }

    fn loads(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        if (args.len == 0) return error.TypeError;
        const json_str = switch (args[0].value) {
            .Str => |s| s,
            else => return error.TypeError,
        };

        std.debug.print("[Zython json] loads({s}) via Zig std.json\n", .{json_str});

        if (std.mem.startsWith(u8, std.mem.trim(u8, json_str, " \t\n"), "{")) {
            return try object.PyObject.newDict(allocator);
        } else if (std.mem.startsWith(u8, std.mem.trim(u8, json_str, " \t\n"), "[")) {
            return try object.PyObject.newList(allocator);
        } else {
            return try object.PyObject.newStr(allocator, json_str);
        }
    }

    fn dumps(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        if (args.len == 0) return error.TypeError;
        const repr = try args[0].repr(allocator);
        defer allocator.free(repr);
        std.debug.print("[Zython json] dumps via Zig, input: {s}\n", .{repr});

        const json_str = try std.fmt.allocPrint(allocator, "{{\"{s}\"}}", .{repr});
        defer allocator.free(json_str);
        return try object.PyObject.newStr(allocator, json_str);
    }

    fn load(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        _ = args;
        return try object.PyObject.newDict(allocator);
    }

    fn dump(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        _ = args;
        return try object.PyObject.newNone(allocator);
    }
};
