//! math module - аналог Lib/math.py + Modules/mathmodule.c
const std = @import("std");
const object = @import("../object/object.zig");
const Allocator = std.mem.Allocator;

pub const MathModule = struct {
    pub fn init(allocator: Allocator) !object.ObjectPtr {
        var dict: std.StringHashMap(object.ObjectPtr) = undefined;
        dict = std.StringHashMap(object.ObjectPtr).init(allocator);

        const pi = try object.PyObject.newFloat(allocator, std.math.pi);
        try dict.put("pi", pi);
        const e = try object.PyObject.newFloat(allocator, std.math.e);
        try dict.put("e", e);

        const funcs = [_]struct { name: []const u8, func: object.BuiltinFn }{
            .{ .name = "sqrt", .func = sqrt },
            .{ .name = "sin", .func = sin },
            .{ .name = "cos", .func = cos },
            .{ .name = "tan", .func = tan },
            .{ .name = "log", .func = log },
            .{ .name = "exp", .func = exp },
            .{ .name = "ceil", .func = ceil },
            .{ .name = "floor", .func = floor },
            .{ .name = "fabs", .func = fabs },
            .{ .name = "pow", .func = pow },
        };

        for (funcs) |f| {
            const fn_obj = try object.PyObject.create(allocator, &object.FunctionType, .{ .BuiltinFunction = f.func });
            try dict.put(f.name, fn_obj);
        }

        const module_val = object.ModuleValue{
            .name = "math",
            .dict = dict,
            .file = "math (zig, std.math)",
        };

        return try object.PyObject.create(allocator, &object.ModuleType, .{ .Module = module_val });
    }

    fn getFloatArg(args: []*object.PyObject) !f64 {
        if (args.len == 0) return error.TypeError;
        return switch (args[0].value) {
            .Float => |f| f,
            .Int => |iv| switch (iv) {
                .Small => |v| @as(f64, @floatFromInt(v)),
                .Big => 0.0,
            },
            else => error.TypeError,
        };
    }

    fn sqrt(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        const x = try getFloatArg(args);
        return try object.PyObject.newFloat(allocator, @sqrt(x));
    }

    fn sin(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        const x = try getFloatArg(args);
        return try object.PyObject.newFloat(allocator, @sin(x));
    }

    fn cos(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        const x = try getFloatArg(args);
        return try object.PyObject.newFloat(allocator, @cos(x));
    }

    fn tan(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        const x = try getFloatArg(args);
        return try object.PyObject.newFloat(allocator, @tan(x));
    }

    fn log(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        const x = try getFloatArg(args);
        return try object.PyObject.newFloat(allocator, @log(x));
    }

    fn exp(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        const x = try getFloatArg(args);
        return try object.PyObject.newFloat(allocator, @exp(x));
    }

    fn ceil(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        const x = try getFloatArg(args);
        return try object.PyObject.newFloat(allocator, @ceil(x));
    }

    fn floor(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        const x = try getFloatArg(args);
        return try object.PyObject.newFloat(allocator, @floor(x));
    }

    fn fabs(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        const x = try getFloatArg(args);
        return try object.PyObject.newFloat(allocator, @abs(x));
    }

    fn pow(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        if (args.len < 2) return error.TypeError;
        const x = try getFloatArg(args);
        const y = switch (args[1].value) {
            .Float => |f| f,
            .Int => |iv| switch (iv) {
                .Small => |v| @as(f64, @floatFromInt(v)),
                .Big => 0.0,
            },
            else => return error.TypeError,
        };
        return try object.PyObject.newFloat(allocator, std.math.pow(f64, x, y));
    }
};
