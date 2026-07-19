//! json module — аналог Lib/json/ + Modules/_json.c
//! Использует Zig std.json для реального парсинга и сериализации

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

        const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch {
            return error.JsonDecodeError;
        };
        defer parsed.deinit();

        return jsonValueToPy(allocator, parsed.value);
    }

    fn dumps(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        if (args.len == 0) return error.TypeError;
        const json_val = try pyToJsonValue(allocator, args[0]);
        // json.Value doesn't need deinit for simple types — the arena from parseFromSlice handles it

        const json_str = try std.json.Stringify.valueAlloc(allocator, json_val, .{});
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

    fn jsonValueToPy(allocator: Allocator, val: std.json.Value) anyerror!object.ObjectPtr {
        return switch (val) {
            .null => try object.PyObject.newNone(allocator),
            .bool => |b| try object.PyObject.newBool(allocator, b),
            .integer => |i| try object.PyObject.newInt(allocator, @intCast(i)),
            .float => |f| try object.PyObject.newFloat(allocator, f),
            .number_string => |s| try object.PyObject.newStr(allocator, s),
            .string => |s| try object.PyObject.newStr(allocator, s),
            .array => |arr| {
                const list_obj = try object.PyObject.newList(allocator);
                for (arr.items) |item| {
                    const py_item = try jsonValueToPy(allocator, item);
                    try list_obj.value.List.items.append(allocator, py_item);
                }
                return list_obj;
            },
            .object => |obj| {
                const dict_obj = try object.PyObject.newDict(allocator);
                var iter = obj.iterator();
                while (iter.next()) |entry| {
                    const val_obj = try jsonValueToPy(allocator, entry.value_ptr.*);
                    val_obj.incref();
                    try dict_obj.value.Dict.map.put(entry.key_ptr.*, val_obj);
                }
                return dict_obj;
            },
        };
    }

    fn pyToJsonValue(allocator: Allocator, obj: *const object.PyObject) anyerror!std.json.Value {
        return switch (obj.value) {
            .None => std.json.Value.null,
            .Bool => |b| std.json.Value{ .bool = b },
            .Int => |iv| std.json.Value{ .integer = switch (iv) {
                .Small => |v| v,
                .Big => 0,
            } },
            .Float => |f| std.json.Value{ .float = f },
            .Str => |s| std.json.Value{ .string = s },
            .List => |*l| {
                var arr = std.json.Array.init(allocator);
                for (l.items.items) |item| {
                    const val = try pyToJsonValue(allocator, item);
                    try arr.append(val);
                }
                return std.json.Value{ .array = arr };
            },
            .Dict => |*d| {
                // Build ObjectMap by inserting key-value pairs one at a time
                var keys: std.ArrayList([]const u8) = .empty;
                defer keys.deinit(allocator);
                var vals: std.ArrayList(std.json.Value) = .empty;
                defer vals.deinit(allocator);
                var iter = d.map.iterator();
                while (iter.next()) |entry| {
                    try keys.append(allocator, entry.key_ptr.*);
                    const val = try pyToJsonValue(allocator, entry.value_ptr.*);
                    try vals.append(allocator, val);
                }
                const obj_map = try std.json.ObjectMap.init(allocator, keys.items, vals.items);
                return std.json.Value{ .object = obj_map };
            },
            else => std.json.Value.null,
        };
    }
};
