//! math — аналог Modules/mathmodule.c.

const std = @import("std");
const object = @import("../object/object.zig");
const runtime_mod = @import("../runtime/runtime.zig");
const ops = @import("../vm/ops.zig");
const vm_mod = @import("../vm/vm.zig");
const bltn = @import("../runtime/builtins.zig");

const VM = vm_mod.VM;
const Obj = object.Obj;
const Dict = object.Dict;
const KwArgs = object.KwArgs;

const floatLike = bltn.floatLike;
const indexLike = bltn.indexLike;

fn mset(vm: *VM, m: Obj, name: []const u8, val: Obj) !void {
    try ops.dictSetStr(m.v.module.dict, vm, name, val);
}

fn mathUnary(comptime f: fn (f64) f64) object.BuiltinFn {
    return struct {
        fn call(v: *VM, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
            _ = kw;
            const x = try floatLike(v, args[0]);
            return v.rt.newFloat(f(x));
        }
    }.call;
}

fn mathDomainUnary(comptime name: []const u8, comptime f: fn (f64) f64) object.BuiltinFn {
    return struct {
        fn call(v: *VM, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
            _ = kw;
            const x = try floatLike(v, args[0]);
            const r = f(x);
            if (std.math.isNan(r) and !std.math.isNan(x)) {
                try v.raiseFmt("ValueError", "math domain error ({s})", .{name});
                return error.PyExc;
            }
            return v.rt.newFloat(r);
        }
    }.call;
}

pub fn initModule(vm: *VM) anyerror!Obj {
    const rt = vm.rt;
    const m = try rt.newModuleObj("math");
    const d = m.v.module.dict;

    // константы
    try mset(vm, m, "pi", try rt.newFloat(std.math.pi));
    try mset(vm, m, "e", try rt.newFloat(std.math.e));
    try mset(vm, m, "tau", try rt.newFloat(2.0 * std.math.pi));
    try mset(vm, m, "inf", try rt.newFloat(std.math.inf(f64)));
    try mset(vm, m, "nan", try rt.newFloat(std.math.nan(f64)));

    // все функции — через таблицу (имя, указатель)
    const funs = .{
        .{ "sqrt", mathDomainUnary("sqrt", struct {
            fn f(x: f64) f64 {
                return @sqrt(x);
            }
        }.f) },
        .{ "exp", mathUnary(struct {
            fn f(x: f64) f64 {
                return @exp(x);
            }
        }.f) },
        .{ "expm1", mathUnary(struct {
            fn f(x: f64) f64 {
                return @exp(x) - 1.0;
            }
        }.f) },
        .{ "log", mathDomainUnary("log", struct {
            fn f(x: f64) f64 {
                return @log(x);
            }
        }.f) },
        .{ "log2", mathDomainUnary("log2", struct {
            fn f(x: f64) f64 {
                return @log2(x);
            }
        }.f) },
        .{ "log10", mathDomainUnary("log10", struct {
            fn f(x: f64) f64 {
                return @log10(x);
            }
        }.f) },
        .{ "sin", mathUnary(struct {
            fn f(x: f64) f64 {
                return @sin(x);
            }
        }.f) },
        .{ "cos", mathUnary(struct {
            fn f(x: f64) f64 {
                return @cos(x);
            }
        }.f) },
        .{ "tan", mathUnary(struct {
            fn f(x: f64) f64 {
                return @tan(x);
            }
        }.f) },
        .{ "asin", mathDomainUnary("asin", struct {
            fn f(x: f64) f64 {
                return std.math.asin(x);
            }
        }.f) },
        .{ "acos", mathDomainUnary("acos", struct {
            fn f(x: f64) f64 {
                return std.math.acos(x);
            }
        }.f) },
        .{ "atan", mathUnary(struct {
            fn f(x: f64) f64 {
                return std.math.atan(x);
            }
        }.f) },
        .{ "sinh", mathUnary(struct {
            fn f(x: f64) f64 {
                return std.math.sinh(x);
            }
        }.f) },
        .{ "cosh", mathUnary(struct {
            fn f(x: f64) f64 {
                return std.math.cosh(x);
            }
        }.f) },
        .{ "tanh", mathUnary(struct {
            fn f(x: f64) f64 {
                return std.math.tanh(x);
            }
        }.f) },
        .{ "fabs", mathUnary(struct {
            fn f(x: f64) f64 {
                return @abs(x);
            }
        }.f) },
        .{ "floor", mathUnary(struct {
            fn f(x: f64) f64 {
                return @floor(x);
            }
        }.f) },
        .{ "ceil", mathUnary(struct {
            fn f(x: f64) f64 {
                return @ceil(x);
            }
        }.f) },
        .{ "trunc", mathUnary(struct {
            fn f(x: f64) f64 {
                return @trunc(x);
            }
        }.f) },
        .{ "degrees", mathUnary(struct {
            fn f(x: f64) f64 {
                return x * 180.0 / std.math.pi;
            }
        }.f) },
        .{ "radians", mathUnary(struct {
            fn f(x: f64) f64 {
                return x * std.math.pi / 180.0;
            }
        }.f) },
        .{ "erf", mathUnary(struct {
            fn f(x: f64) f64 {
                return erf(x);
            }
        }.f) },
    };
    inline for (funs) |fd| {
        const name = fd[0];
        try ops.dictSetStr(d, vm, name, try rt.newBuiltin(name, fd[1]));
    }

    // функции двух аргументов
    try ops.dictSetStr(d, vm, "pow", try rt.newBuiltin("pow", object.wrapBuiltin(m_pow)));
    try ops.dictSetStr(d, vm, "fmod", try rt.newBuiltin("fmod", object.wrapBuiltin(m_fmod)));
    try ops.dictSetStr(d, vm, "atan2", try rt.newBuiltin("atan2", object.wrapBuiltin(m_atan2)));
    try ops.dictSetStr(d, vm, "hypot", try rt.newBuiltin("hypot", object.wrapBuiltin(m_hypot)));
    try ops.dictSetStr(d, vm, "copysign", try rt.newBuiltin("copysign", object.wrapBuiltin(m_copysign)));
    try ops.dictSetStr(d, vm, "remainder", try rt.newBuiltin("remainder", object.wrapBuiltin(m_remainder)));
    // предикаты
    try ops.dictSetStr(d, vm, "isnan", try rt.newBuiltin("isnan", object.wrapBuiltin(m_isnan)));
    try ops.dictSetStr(d, vm, "isinf", try rt.newBuiltin("isinf", object.wrapBuiltin(m_isinf)));
    try ops.dictSetStr(d, vm, "isfinite", try rt.newBuiltin("isfinite", object.wrapBuiltin(m_isfinite)));
    // прочее
    try ops.dictSetStr(d, vm, "factorial", try rt.newBuiltin("factorial", object.wrapBuiltin(m_factorial)));
    try ops.dictSetStr(d, vm, "gcd", try rt.newBuiltin("gcd", object.wrapBuiltin(m_gcd)));
    try ops.dictSetStr(d, vm, "lcm", try rt.newBuiltin("lcm", object.wrapBuiltin(m_lcm)));
    try ops.dictSetStr(d, vm, "comb", try rt.newBuiltin("comb", object.wrapBuiltin(m_comb)));
    try ops.dictSetStr(d, vm, "perm", try rt.newBuiltin("perm", object.wrapBuiltin(m_perm)));
    try ops.dictSetStr(d, vm, "isqrt", try rt.newBuiltin("isqrt", object.wrapBuiltin(m_isqrt)));
    try ops.dictSetStr(d, vm, "frexp", try rt.newBuiltin("frexp", object.wrapBuiltin(m_frexp)));
    try ops.dictSetStr(d, vm, "ldexp", try rt.newBuiltin("ldexp", object.wrapBuiltin(m_ldexp)));
    try ops.dictSetStr(d, vm, "modf", try rt.newBuiltin("modf", object.wrapBuiltin(m_modf)));
    try ops.dictSetStr(d, vm, "fsum", try rt.newBuiltin("fsum", object.wrapBuiltin(m_fsum)));
    try ops.dictSetStr(d, vm, "prod", try rt.newBuiltin("prod", object.wrapBuiltin(m_prod)));
    try ops.dictSetStr(d, vm, "log1p", try rt.newBuiltin("log1p", object.wrapBuiltin(m_log1p)));
    try ops.dictSetStr(d, vm, "ulp", try rt.newBuiltin("ulp", object.wrapBuiltin(m_ulp)));
    return m;
}

fn erf(x: f64) f64 {
    // аппроксимация Abramowitz-Stegun 7.1.26
    const t = 1.0 / (1.0 + 0.5 * @abs(x));
    const tau = t * @exp(-x * x - 1.26551223 +
        t * (1.00002368 +
            t * (0.37409196 +
                t * (0.09678418 +
                    t * (-0.18628806 +
                        t * (0.27886807 +
                            t * (-1.13520398 +
                                t * (1.48851587 +
                                    t * (-0.82215223 +
                                        t * 0.17087277)))))))));
    return if (x >= 0) 1.0 - tau else tau - 1.0;
}

fn m_pow(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const x = try floatLike(v, args[0]);
    const y = try floatLike(v, args[1]);
    const r = std.math.pow(f64, x, y);
    if (std.math.isNan(r) and !(std.math.isNan(x) or std.math.isNan(y))) {
        if (x < 0 and @trunc(y) != y) {
            try v.raiseStr("ValueError", "math domain error");
            return error.PyExc;
        }
        if (x == 0 and y < 0) {
            try v.raiseStr("ZeroDivisionError", "0.0 cannot be raised to a negative power");
            return error.PyExc;
        }
    }
    return v.rt.newFloat(r);
}

fn m_fmod(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const x = try floatLike(v, args[0]);
    const y = try floatLike(v, args[1]);
    if (y == 0) {
        try v.raiseStr("ValueError", "math domain error");
        return error.PyExc;
    }
    return v.rt.newFloat(@mod(x, y));
}

fn m_atan2(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    return v.rt.newFloat(std.math.atan2(try floatLike(v, args[0]), try floatLike(v, args[1])));
}

fn m_hypot(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    var acc: f64 = 0;
    for (args) |a| {
        const x = try floatLike(v, a);
        acc += x * x;
    }
    return v.rt.newFloat(@sqrt(acc));
}

fn m_copysign(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    return v.rt.newFloat(std.math.copysign(try floatLike(v, args[0]), try floatLike(v, args[1])));
}

fn m_remainder(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const x = try floatLike(v, args[0]);
    const y = try floatLike(v, args[1]);
    return v.rt.newFloat(try std.math.rem(f64, x, y));
}

fn m_isnan(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    return v.rt.newBool(std.math.isNan(try floatLike(v, args[0])));
}

fn m_isinf(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    return v.rt.newBool(std.math.isInf(try floatLike(v, args[0])));
}

fn m_isfinite(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const f = try floatLike(v, args[0]);
    return v.rt.newBool(!std.math.isNan(f) and !std.math.isInf(f));
}

fn m_factorial(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const n = try indexLike(v, args[0]);
    if (n < 0) {
        try v.raiseStr("ValueError", "factorial() not defined for negative values");
        return error.PyExc;
    }
    var i: i64 = 2;
    var acc = try object.bigFromI64(v.rt.gpa, 1);
    while (i <= n) : (i += 1) {
        const bi = try object.bigFromI64(v.rt.gpa, i);
        try acc.mul(acc, bi);
    }
    // маленькие → обычный int
    if (acc.toInt(i64)) |small| return v.rt.newInt(small) else |_| {}
    return v.rt.newBig(acc);
}

fn m_gcd(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    if (args.len == 0) return v.rt.newInt(0);
    var g: u128 = @intCast(@abs(try indexLike(v, args[0])));
    for (args[1..]) |a| {
        g = std.math.gcd(g, @as(u128, @intCast(@abs(try indexLike(v, a)))));
    }
    return v.rt.newInt(@intCast(g));
}

fn m_lcm(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    if (args.len == 0) return v.rt.newInt(1);
    var l: u128 = @intCast(@abs(try indexLike(v, args[0])));
    for (args[1..]) |a| {
        const x: u128 = @intCast(@abs(try indexLike(v, a)));
        if (l == 0 or x == 0) {
            l = 0;
        } else {
            l = @divExact(l, std.math.gcd(l, x)) * x;
        }
    }
    return v.rt.newInt(@intCast(l));
}

fn combImpl(n: i64, k: i64) i128 {
    if (k < 0 or k > n) return 0;
    var kk = k;
    if (kk > n - kk) kk = n - kk;
    var acc: i128 = 1;
    var i: i64 = 0;
    while (i < kk) : (i += 1) {
        acc = @divExact(acc * @as(i128, n - i), @as(i128, i + 1));
    }
    return acc;
}

fn m_comb(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const n = try indexLike(v, args[0]);
    const k = try indexLike(v, args[1]);
    if (n < 0 or k < 0) {
        try v.raiseStr("ValueError", "comb() with negative arguments");
        return error.PyExc;
    }
    return v.rt.newInt(@intCast(combImpl(n, k)));
}

fn m_perm(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const n = try indexLike(v, args[0]);
    const k: i64 = if (args.len >= 2) try indexLike(v, args[1]) else n;
    if (n < 0 or k < 0) {
        try v.raiseStr("ValueError", "perm() with negative arguments");
        return error.PyExc;
    }
    var acc: i128 = 1;
    var i: i64 = 0;
    while (i < k) : (i += 1) acc *= @as(i128, n - i);
    return v.rt.newInt(@intCast(acc));
}

fn m_isqrt(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const n = try indexLike(v, args[0]);
    if (n < 0) {
        try v.raiseStr("ValueError", "isqrt() argument must be nonnegative");
        return error.PyExc;
    }
    return v.rt.newInt(@intCast(std.math.sqrt(@as(u128, @intCast(n)))));
}

fn m_frexp(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const x = try floatLike(v, args[0]);
    const fr = std.math.frexp(x);
    return v.rt.newTuple(&.{ try v.rt.newFloat(fr.significand), try v.rt.newInt(fr.exponent) });
}

fn m_ldexp(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const x = try floatLike(v, args[0]);
    const i = try indexLike(v, args[1]);
    return v.rt.newFloat(x * std.math.pow(f64, 2, @floatFromInt(i)));
}

fn m_modf(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const x = try floatLike(v, args[0]);
    const ip = @trunc(x);
    return v.rt.newTuple(&.{ try v.rt.newFloat(x - ip), try v.rt.newFloat(ip) });
}

fn m_fsum(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    // Neumaier summation (как CPython fsum по точности первого порядка)
    var sum: f64 = 0;
    var c: f64 = 0;
    const it = try vm.pyIter(args[0]);
    while (try vm.pyNext(it)) |item| {
        const x = try floatLike(v, item);
        const t = sum + x;
        if (@abs(sum) >= @abs(x)) {
            c += (sum - t) + x;
        } else {
            c += (x - t) + sum;
        }
        sum = t;
    }
    return v.rt.newFloat(sum + c);
}

fn m_prod(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    var acc = try v.rt.newInt(1);
    const start: usize = if (args.len >= 2) blk: {
        acc = args[1];
        break :blk 1;
    } else 1;
    _ = start;
    const it = try vm.pyIter(args[0]);
    while (try vm.pyNext(it)) |item| {
        acc = try vm.pyBinaryOp(.mul, acc, item);
    }
    return acc;
}

fn m_log1p(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const x = try floatLike(v, args[0]);
    if (x <= -1.0) {
        try v.raiseStr("ValueError", "math domain error");
        return error.PyExc;
    }
    return v.rt.newFloat(@log(1.0 + x));
}

fn m_ulp(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const x = try floatLike(v, args[0]);
    const bits: u64 = @bitCast(@abs(x));
    const e: i64 = @as(i64, @intCast((bits >> 52) & 0x7FF)) - 1023;
    return v.rt.newFloat(std.math.pow(f64, 2, @floatFromInt(e - 52)));
}
