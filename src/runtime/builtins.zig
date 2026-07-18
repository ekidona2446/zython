//! Встроенные функции и типы - аналог Python/bltinmodule.c
//! Реализация Python builtins на Zig с libxev интеграцией
//! Zig 0.16.0 compatible

const std = @import("std");
const Allocator = std.mem.Allocator;
const object = @import("../object/object.zig");

pub const Builtins = struct {
    pub const BuiltinDef = struct {
        name: []const u8,
        func: object.BuiltinFn,
        doc: []const u8,
    };

    pub fn getBuiltins() []const BuiltinDef {
        return &.{
            .{ .name = "print", .func = printFunc, .doc = "print(*objects, sep=' ', end='\\n')" },
            .{ .name = "len", .func = lenFunc, .doc = "len(obj)" },
            .{ .name = "abs", .func = absFunc, .doc = "abs(number)" },
            .{ .name = "range", .func = rangeFunc, .doc = "range(stop) or range(start, stop, step)" },
            .{ .name = "int", .func = intFunc, .doc = "int(x=0)" },
            .{ .name = "float", .func = floatFunc, .doc = "float(x=0)" },
            .{ .name = "str", .func = strFunc, .doc = "str(obj='')" },
            .{ .name = "list", .func = listFunc, .doc = "list(iterable=[])" },
            .{ .name = "dict", .func = dictFunc, .doc = "dict()" },
            .{ .name = "type", .func = typeFunc, .doc = "type(obj)" },
            .{ .name = "isinstance", .func = isinstanceFunc, .doc = "isinstance(obj, class)" },
        };
    }

    fn printFunc(args: []*object.PyObject, allocator: Allocator) !object.ObjectPtr {
        for (args, 0..) |arg, i| {
            if (i != 0) std.debug.print(" ", .{});
            switch (arg.value) {
                .Str => |s| std.debug.print("{s}", .{s}),
                .Int => |iv| switch (iv) {
                    .Small => |v| std.debug.print("{d}", .{v}),
                    .Big => |*b| {
                        var tmp = b.*;
                        const s = tmp.toString(allocator, 10, .lower) catch "big";
                        defer allocator.free(s);
                        std.debug.print("{s}", .{s});
                    },
                },
                .Float => |f| std.debug.print("{d}", .{f}),
                .Bool => |b| std.debug.print("{s}", .{if (b) "True" else "False"}),
                .None => std.debug.print("None", .{}),
                .List => |*l| {
                    std.debug.print("[", .{});
                    for (l.items.items, 0..) |item, j| {
                        if (j != 0) std.debug.print(", ", .{});
                        const r = item.repr(allocator) catch "?";
                        defer allocator.free(r);
                        std.debug.print("{s}", .{r});
                    }
                    std.debug.print("]", .{});
                },
                else => {
                    const r = arg.repr(allocator) catch "?";
                    defer allocator.free(r);
                    std.debug.print("{s}", .{r});
                },
            }
        }
        std.debug.print("\n", .{});
        return try object.PyObject.newNone(allocator);
    }

    fn lenFunc(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        if (args.len != 1) return error.TypeError;
        const obj = args[0];
        const length: i64 = switch (obj.value) {
            .Str => |s| @intCast(s.len),
            .List => |*l| @intCast(l.items.items.len),
            .Tuple => |t| @intCast(t.len),
            .Dict => |*d| @intCast(d.map.count()),
            .Bytes => |b| @intCast(b.len),
            else => return error.TypeError,
        };
        return try object.PyObject.newInt(allocator, length);
    }

    fn absFunc(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        if (args.len != 1) return error.TypeError;
        return switch (args[0].value) {
            .Int => |iv| switch (iv) {
                .Small => |v| try object.PyObject.newInt(allocator, if (v < 0) -v else v),
                .Big => |*b| {
                    var copy = try b.clone();
                    // In Zig 0.16 Managed doesn't have orderAgainstScalar directly, use toConst()
                    if (copy.toConst().orderAgainstScalar(0) == .lt) {
                        copy.negate();
                    }
                    const obj = try allocator.create(object.PyObject);
                    obj.* = .{
                        .refcnt = 1,
                        .type_ptr = &object.IntType,
                        .value = .{ .Int = .{ .Big = copy } },
                        .allocator = allocator,
                    };
                    return obj;
                },
            },
            .Float => |f| try object.PyObject.newFloat(allocator, @abs(f)),
            else => error.TypeError,
        };
    }

    fn rangeFunc(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        var start: i64 = 0;
        var stop: i64 = 0;
        var step: i64 = 1;

        switch (args.len) {
            1 => {
                switch (args[0].value) {
                    .Int => |iv| stop = switch (iv) {
                        .Small => |v| v,
                        .Big => return error.Overflow,
                    },
                    else => return error.TypeError,
                }
            },
            2 => {
                start = switch (args[0].value) {
                    .Int => |iv| switch (iv) {
                        .Small => |v| v,
                        .Big => return error.Overflow,
                    },
                    else => return error.TypeError,
                };
                stop = switch (args[1].value) {
                    .Int => |iv| switch (iv) {
                        .Small => |v| v,
                        .Big => return error.Overflow,
                    },
                    else => return error.TypeError,
                };
            },
            3 => {
                start = switch (args[0].value) {
                    .Int => |iv| switch (iv) {
                        .Small => |v| v,
                        .Big => return error.Overflow,
                    },
                    else => return error.TypeError,
                };
                stop = switch (args[1].value) {
                    .Int => |iv| switch (iv) {
                        .Small => |v| v,
                        .Big => return error.Overflow,
                    },
                    else => return error.TypeError,
                };
                step = switch (args[2].value) {
                    .Int => |iv| switch (iv) {
                        .Small => |v| v,
                        .Big => return error.Overflow,
                    },
                    else => return error.TypeError,
                };
            },
            else => return error.TypeError,
        }

        if (step == 0) return error.ValueError;

        const range_obj = try allocator.create(object.PyObject);
        range_obj.* = .{
            .refcnt = 1,
            .type_ptr = &object.IntType,
            .value = .{ .Range = .{ .start = start, .stop = stop, .step = step } },
            .allocator = allocator,
        };
        return range_obj;
    }

    fn intFunc(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        if (args.len == 0) return try object.PyObject.newInt(allocator, 0);
        return switch (args[0].value) {
            .Int => {
                args[0].incref();
                return args[0];
            },
            .Float => |f| try object.PyObject.newInt(allocator, @intFromFloat(f)),
            .Str => |s| {
                const parsed = std.fmt.parseInt(i64, s, 10) catch return error.ValueError;
                return try object.PyObject.newInt(allocator, parsed);
            },
            .Bool => |b| try object.PyObject.newInt(allocator, if (b) 1 else 0),
            else => error.TypeError,
        };
    }

    fn floatFunc(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        if (args.len == 0) return try object.PyObject.newFloat(allocator, 0.0);
        return switch (args[0].value) {
            .Float => {
                args[0].incref();
                return args[0];
            },
            .Int => |iv| {
                const v: f64 = switch (iv) {
                    .Small => |small| @floatFromInt(small),
                    .Big => 0.0,
                };
                return try object.PyObject.newFloat(allocator, v);
            },
            .Str => |s| {
                const parsed = std.fmt.parseFloat(f64, s) catch return error.ValueError;
                return try object.PyObject.newFloat(allocator, parsed);
            },
            else => error.TypeError,
        };
    }

    fn strFunc(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        if (args.len == 0) return try object.PyObject.newStr(allocator, "");
        if (args[0].value == .Str) {
            return try object.PyObject.newStr(allocator, args[0].value.Str);
        }
        const repr = try args[0].repr(allocator);
        defer allocator.free(repr);
        return try object.PyObject.newStr(allocator, repr);
    }

    fn listFunc(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        const list_obj = try object.PyObject.newList(allocator);
        if (args.len == 0) return list_obj;
        switch (args[0].value) {
            .List => |*l| {
                for (l.items.items) |item| {
                    item.incref();
                    try list_obj.value.List.items.append(allocator, item);
                }
            },
            .Tuple => |items| {
                for (items) |item| {
                    item.incref();
                    try list_obj.value.List.items.append(allocator, item);
                }
            },
            else => {},
        }
        return list_obj;
    }

    fn dictFunc(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        _ = args;
        return try object.PyObject.newDict(allocator);
    }

    fn typeFunc(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        if (args.len != 1) return error.TypeError;
        const type_name = args[0].type_ptr.name;
        return try object.PyObject.newStr(allocator, type_name);
    }

    fn isinstanceFunc(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        if (args.len != 2) return error.TypeError;
        const is_instance = switch (args[1].value) {
            .Str => |type_str| std.mem.eql(u8, type_str, args[0].type_ptr.name),
            .Type => |t| t.type_id == args[0].type_ptr.type_id,
            else => false,
        };
        return try object.PyObject.newBool(allocator, is_instance);
    }
};
