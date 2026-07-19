//! Методы встроенных типов, часть 2: int/float, bytes/bytearray, range/slice,
//! generator, property/super, file, iter.

const std = @import("std");
const object = @import("../../object/object.zig");
const runtime_mod = @import("../runtime.zig");
const ops = @import("../../vm/ops.zig");
const vm_mod = @import("../../vm/vm.zig");
const bltn = @import("../builtins.zig");
const tstr = @import("typestr.zig");

const Runtime = runtime_mod.Runtime;
const VM = vm_mod.VM;
const Obj = object.Obj;
const Type = object.Type;
const Dict = object.Dict;
const KwArgs = object.KwArgs;

const typeErr = bltn.typeErr;
const indexLike = bltn.indexLike;
const floatLike = bltn.floatLike;

fn dictPutStartup(rt: *Runtime, d: *Dict, name: []const u8, val: Obj) !void {
    const kobj = try rt.newStr(name);
    const h = try rt.pyHash(kobj);
    try d.setWithHash(rt, kobj, val, h);
}

fn td(rt: *Runtime, ty: *Type, name: []const u8, comptime f: anytype) !void {
    const fnobj = try rt.newBuiltin(name, object.wrapBuiltin(f));
    try dictPutStartup(rt, ty.dict, name, fnobj);
}

// ============================================================
// int / bool / float
// ============================================================

pub fn registerIntFloatMethods(rt: *Runtime) !void {
    inline for (.{ rt.int_t, rt.bool_t }) |t| {
        try td(rt, t, "bit_length", int_bit_length);
        try td(rt, t, "__format__", num___format__);
        try td(rt, t, "to_bytes", int_to_bytes);
        try td(rt, t, "from_bytes", int_from_bytes);
        try td(rt, t, "as_integer_ratio", int_as_integer_ratio);
        try td(rt, t, "conjugate", int_conjugate);
        try td(rt, t, "__trunc__", num_identity_first);
        try td(rt, t, "__floor__", num_identity_first);
        try td(rt, t, "__ceil__", num_identity_first);
        try td(rt, t, "__index__", num_identity_first);
        try td(rt, t, "is_integer", num_true);
        try td(rt, t, "hex", float_hex_int);
    }
    const f = rt.float_t;
    try td(rt, f, "is_integer", float_is_integer);
    try td(rt, f, "as_integer_ratio", float_as_integer_ratio);
    try td(rt, f, "conjugate", num_identity_first);
    try td(rt, f, "hex", float_hex);
    try td(rt, f, "fromhex", float_fromhex);
    try td(rt, f, "__trunc__", float_trunc);
    try td(rt, f, "__floor__", float_floor);
    try td(rt, f, "__ceil__", float_ceil);
    try td(rt, f, "__format__", num___format__);
}

// int/float.__format__ → formatSimple (spec: [[fill]align][sign][#][0][width][,][.prec][type])
fn num___format__(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    if (args.len < 2 or args[1].v != .str) {
        try v.raiseStr("TypeError", "__format__() argument 1 must be str");
        return error.PyExc;
    }
    return v.formatSimple(args[0], args[1].v.str.bytes);
}

fn num_identity_first(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    _ = vm;
    return args[0];
}

fn num_true(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = args;
    _ = kw;
    return vm.rt.true_obj;
}

fn intBitLen(v: i64) usize {
    var uv: u64 = if (v < 0) @intCast(-v) else @intCast(v);
    var n: usize = 0;
    while (uv != 0) : (uv >>= 1) n += 1;
    return n;
}

fn int_bit_length(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const i = try indexLike(v, args[0]);
    return v.rt.newInt(@intCast(intBitLen(i)));
}

fn int_to_bytes(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    const v: *VM = vm;
    const i = try indexLike(v, args[0]);
    var length: usize = if (args.len >= 2) @intCast(@max(0, try indexLike(v, args[1]))) else 0;
    var signed = false;
    var big = true;
    if (kw) |k| {
        if (k.get("byteorder")) |bo| {
            big = std.mem.eql(u8, bo.v.str.bytes, "big");
        }
        if (k.get("signed")) |sg| signed = sg.isTruthy();
    }
    if (args.len <= 1) {
        // вычислить минимальную длину
        if (i == 0) {
            length = 1;
        } else {
            const bits = intBitLen(i);
            length = (bits + 7) / 8;
            if (signed) length += 1;
        }
    }
    const out = try v.rt.gpa.alloc(u8, length);
    var uv: u64 = undefined;
    if (i < 0) {
        if (!signed) {
            try v.raiseStr("OverflowError", "can't convert negative int to unsigned");
            return error.PyExc;
        }
        // two's complement
        const bits: u7 = @intCast(length * 8);
        uv = @truncate(@as(u128, @bitCast(@as(i128, i))) & ((@as(u128, 1) << bits) - 1));
    } else {
        uv = @intCast(i);
    }
    var tmp = uv;
    var pos: usize = 0;
    while (pos < length) : (pos += 1) {
        out[if (big) length - 1 - pos else pos] = @truncate(tmp);
        tmp >>= 8;
    }
    if (tmp != 0) {
        try v.raiseStr("OverflowError", "int too big to convert");
        return error.PyExc;
    }
    if (signed and i < 0) {
        // верхний байт должен быть >= 0x80 — two's complement уже записан
    } else if (signed and out[if (big) 0 else length - 1] & 0x80 != 0) {
        // нужен доп. знаковый байт
        const out2 = try v.rt.gpa.alloc(u8, length + 1);
        if (big) {
            out2[0] = 0;
            @memcpy(out2[1..], out);
        } else {
            @memcpy(out2[0..length], out);
            out2[length] = 0;
        }
        return v.rt.newBytesOwned(out2);
    }
    return v.rt.newBytesOwned(out);
}

fn int_from_bytes(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    const v: *VM = vm;
    // classmethod: args[0] = cls, args[1] = bytes
    var bytes: []const u8 = undefined;
    if (args[1].v == .bytes) {
        bytes = args[1].v.bytes.data;
    } else if (args[1].v == .bytearray) {
        bytes = args[1].v.bytearray.data.items;
    } else {
        return typeErr(v, "from_bytes() argument must be bytes-like", .{});
    }
    var big = true;
    var signed = false;
    if (kw) |k| {
        if (k.get("byteorder")) |bo| {
            big = std.mem.eql(u8, bo.v.str.bytes, "big");
        }
        if (k.get("signed")) |sg| signed = sg.isTruthy();
    }
    var acc: i128 = 0;
    if (big) {
        for (bytes) |b| acc = (acc << 8) | b;
    } else {
        var shift: u7 = 0;
        for (bytes) |b| {
            acc |= @as(i128, b) << shift;
            shift += 8;
        }
    }
    if (signed and bytes.len > 0) {
        const top: u8 = if (big) bytes[0] else bytes[bytes.len - 1];
        if (top & 0x80 != 0) {
            acc -= @as(i128, 1) << @intCast(bytes.len * 8);
        }
    }
    return v.rt.newInt(@intCast(acc));
}

fn int_as_integer_ratio(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    return v.rt.newTuple(&.{ args[0], try v.rt.newInt(1) });
}

fn int_conjugate(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    _ = vm;
    return args[0];
}

fn float_hex_int(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const i = try floatLike(v, args[0]);
    return floatHexImpl(v, i);
}

fn float_is_integer(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const f = try floatLike(v, args[0]);
    return v.rt.newBool(@trunc(f) == f);
}

fn float_as_integer_ratio(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const f = try floatLike(v, args[0]);
    if (std.math.isNan(f)) {
        try v.raiseStr("ValueError", "cannot convert NaN to integer ratio");
        return error.PyExc;
    }
    if (std.math.isInf(f)) {
        try v.raiseStr("OverflowError", "cannot convert Infinity to integer ratio");
        return error.PyExc;
    }
    // двоичное разложение: f = m * 2^e
    const bits: u64 = @bitCast(f);
    const exp_bits: u64 = (bits >> 52) & 0x7FF;
    var mant: u64 = bits & ((@as(u64, 1) << 52) - 1);
    const e: i64 = @as(i64, @intCast(exp_bits)) - 1075;
    if (exp_bits != 0) mant |= @as(u64, 1) << 52;
    const sign: i64 = if (bits >> 63 != 0) -1 else 1;
    var num: i128 = @as(i128, @intCast(mant)) * sign;
    var den: i128 = 1;
    if (e >= 0) {
        num = num << @intCast(@min(60, e));
        if (e > 60) {
            // большое число — через bigint
            try v.raiseStr("OverflowError", "float too large (пока)");
            return error.PyExc;
        }
    } else {
        den = den << @intCast(@min(60, -e));
    }
    // сократить
    while (num != 0 and num & 1 == 0 and den & 1 == 0) {
        num >>= 1;
        den >>= 1;
    }
    const g: i128 = @intCast(std.math.gcd(@as(u128, @intCast(@abs(num))), @as(u128, @intCast(@abs(den)))));
    num = @divExact(num, g);
    den = @divExact(den, g);
    return v.rt.newTuple(&.{ try v.rt.newInt(@intCast(num)), try v.rt.newInt(@intCast(den)) });
}

fn floatHexImpl(vm: *VM, f: f64) anyerror!Obj {
    if (std.math.isNan(f)) return vm.rt.newStr("nan");
    if (std.math.isInf(f)) return vm.rt.newStr(if (f > 0) "inf" else "-inf");
    const s = try std.fmt.allocPrint(vm.rt.gpa, "{x}", .{f});
    return vm.rt.newStrOwned(s);
}

fn float_hex(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    return floatHexImpl(v, try floatLike(v, args[0]));
}

fn float_fromhex(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    // classmethod: args[0] = cls, args[1] = str
    const s = args[1].v.str.bytes;
    const f = std.fmt.parseFloat(f64, s) catch {
        try v.raiseStr("ValueError", "invalid hexadecimal floating-point string");
        return error.PyExc;
    };
    return v.rt.newFloat(f);
}

fn float_trunc(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const f = try floatLike(v, args[0]);
    return v.rt.newInt(@intFromFloat(@trunc(f)));
}

fn float_floor(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const f = try floatLike(v, args[0]);
    return v.rt.newInt(@intFromFloat(@floor(f)));
}

fn float_ceil(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const f = try floatLike(v, args[0]);
    return v.rt.newInt(@intFromFloat(@ceil(f)));
}

// ============================================================
// bytes / bytearray
// ============================================================

pub fn registerBytesMethods(rt: *Runtime) !void {
    inline for (.{ rt.bytes_t, rt.bytearray_t }) |t| {
        try td(rt, t, "decode", bytes_decode);
        try td(rt, t, "hex", bytes_hex);
        try td(rt, t, "fromhex", bytes_fromhex);
        try td(rt, t, "upper", bytes_upper);
        try td(rt, t, "lower", bytes_lower);
        try td(rt, t, "strip", bytes_strip);
        try td(rt, t, "split", bytes_split);
        try td(rt, t, "join", bytes_join);
        try td(rt, t, "replace", bytes_replace);
        try td(rt, t, "find", bytes_find);
        try td(rt, t, "index", bytes_index);
        try td(rt, t, "count", bytes_count);
        try td(rt, t, "startswith", bytes_startswith);
        try td(rt, t, "endswith", bytes_endswith);
    }
    try td(rt, rt.bytearray_t, "append", ba_append);
    try td(rt, rt.bytearray_t, "extend", ba_extend);
    try td(rt, rt.bytearray_t, "clear", ba_clear);
}

fn bytesData(o: Obj, vm: *VM) ![]const u8 {
    switch (o.v) {
        .bytes => |b| return b.data,
        .bytearray => |b| return b.data.items,
        .str => |s| return s.bytes,
        else => {
            try vm.raiseFmt("TypeError", "a bytes-like object is required, not '{s}'", .{o.ty.name});
            return error.PyExc;
        },
    }
}

fn bytesResult(vm: *VM, self_obj: Obj, data: []u8) !Obj {
    if (self_obj.v == .bytearray) {
        return vm.rt.newBytearray(data);
    }
    return vm.rt.newBytesOwned(data);
}

fn bytes_decode(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const data = try bytesData(args[0], v);
    const enc: []const u8 = if (args.len >= 2 and args[1].v == .str) args[1].v.str.bytes else "utf-8";
    return decodeBytes(v, data, enc);
}

pub fn decodeBytes(vm: *VM, data: []const u8, enc: []const u8) anyerror!Obj {
    if (tstr.asciiEqlIgnoreCase(enc, "utf-8") or tstr.asciiEqlIgnoreCase(enc, "utf8")) {
        if (!std.unicode.utf8ValidateSlice(data)) {
            try vm.raiseStr("UnicodeDecodeError", "'utf-8' codec can't decode byte: invalid utf-8");
            return error.PyExc;
        }
        return vm.rt.newStr(data);
    }
    if (tstr.asciiEqlIgnoreCase(enc, "ascii")) {
        for (data) |c| {
            if (c >= 128) {
                try vm.raiseStr("UnicodeDecodeError", "'ascii' codec can't decode byte");
                return error.PyExc;
            }
        }
        return vm.rt.newStr(data);
    }
    if (tstr.asciiEqlIgnoreCase(enc, "latin-1") or tstr.asciiEqlIgnoreCase(enc, "latin1") or tstr.asciiEqlIgnoreCase(enc, "iso-8859-1")) {
        var out: std.ArrayList(u8) = .empty;
        for (data) |c| {
            try out.append(vm.rt.gpa, c);
            // latin-1 > 127 → 2 байта UTF-8
            if (c >= 128) {
                out.items.len -= 1;
                var buf: [2]u8 = undefined;
                _ = std.unicode.utf8Encode(c, &buf) catch 0;
                try out.appendSlice(vm.rt.gpa, &buf);
            }
        }
        return vm.rt.newStrOwned(try out.toOwnedSlice(vm.rt.gpa));
    }
    try vm.raiseFmt("LookupError", "unknown encoding: {s}", .{enc});
    return error.PyExc;
}

fn bytes_hex(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const data = try bytesData(args[0], v);
    const out = try v.rt.gpa.alloc(u8, data.len * 2);
    const digits = "0123456789abcdef";
    for (data, 0..) |b, i| {
        out[i * 2] = digits[b >> 4];
        out[i * 2 + 1] = digits[b & 15];
    }
    return v.rt.newStrOwned(out);
}

fn bytes_fromhex(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const s = args[1].v.str.bytes;
    var hex: std.ArrayList(u8) = .empty;
    for (s) |c| {
        if (!std.ascii.isWhitespace(c)) try hex.append(v.rt.gpa, c);
    }
    if (hex.items.len % 2 != 0) {
        try v.raiseStr("ValueError", "non-hexadecimal number found in fromhex() arg");
        return error.PyExc;
    }
    const out = try v.rt.gpa.alloc(u8, hex.items.len / 2);
    var i: usize = 0;
    while (i < out.len) : (i += 1) {
        const hi = std.fmt.charToDigit(hex.items[i * 2], 16) catch {
            try v.raiseStr("ValueError", "non-hexadecimal number found in fromhex() arg");
            return error.PyExc;
        };
        const lo = std.fmt.charToDigit(hex.items[i * 2 + 1], 16) catch {
            try v.raiseStr("ValueError", "non-hexadecimal number found in fromhex() arg");
            return error.PyExc;
        };
        out[i] = (hi << 4) | lo;
    }
    return v.rt.newBytesOwned(out);
}

fn bytes_upper(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const data = try bytesData(args[0], v);
    const out = try v.rt.gpa.dupe(u8, data);
    for (out) |*c| c.* = std.ascii.toUpper(c.*);
    return bytesResult(v, args[0], out);
}

fn bytes_lower(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const data = try bytesData(args[0], v);
    const out = try v.rt.gpa.dupe(u8, data);
    for (out) |*c| c.* = std.ascii.toLower(c.*);
    return bytesResult(v, args[0], out);
}

fn bytes_strip(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const data = try bytesData(args[0], v);
    return bytesResult(v, args[0], try v.rt.gpa.dupe(u8, std.mem.trim(u8, data, " \t\n\r\x0b\x0c")));
}

fn bytes_split(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const data = try bytesData(args[0], v);
    const out = try v.rt.newList();
    const maxsplit: i64 = if (args.len >= 3) try indexLike(v, args[2]) else -1;
    if (args.len >= 2 and args[1].v != .none) {
        const sep = try bytesData(args[1], v);
        if (sep.len == 0) {
            try v.raiseStr("ValueError", "empty separator");
            return error.PyExc;
        }
        var rest = data;
        var n: i64 = 0;
        while (maxsplit < 0 or n < maxsplit) {
            if (std.mem.indexOf(u8, rest, sep)) |idx| {
                try out.v.list.items.append(v.rt.gpa, try v.rt.newBytes(rest[0..idx]));
                rest = rest[idx + sep.len ..];
                n += 1;
            } else break;
        }
        try out.v.list.items.append(v.rt.gpa, try v.rt.newBytes(rest));
    } else {
        var i: usize = 0;
        while (i < data.len) {
            while (i < data.len and std.ascii.isWhitespace(data[i])) i += 1;
            if (i >= data.len) break;
            const start = i;
            while (i < data.len and !std.ascii.isWhitespace(data[i])) i += 1;
            try out.v.list.items.append(v.rt.gpa, try v.rt.newBytes(data[start..i]));
        }
    }
    return out;
}

fn bytes_join(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const sep = try bytesData(args[0], v);
    const items = try vm.collectSequence(args[1], null);
    var out: std.ArrayList(u8) = .empty;
    for (items, 0..) |item, i| {
        if (i > 0) try out.appendSlice(v.rt.gpa, sep);
        try out.appendSlice(v.rt.gpa, try bytesData(item, v));
    }
    return bytesResult(v, args[0], try out.toOwnedSlice(v.rt.gpa));
}

fn bytes_replace(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const data = try bytesData(args[0], v);
    const old = try bytesData(args[1], v);
    const new = try bytesData(args[2], v);
    var out: std.ArrayList(u8) = .empty;
    var rest = data;
    while (old.len > 0 and std.mem.indexOf(u8, rest, old) != null) {
        const idx = std.mem.indexOf(u8, rest, old).?;
        try out.appendSlice(v.rt.gpa, rest[0..idx]);
        try out.appendSlice(v.rt.gpa, new);
        rest = rest[idx + old.len ..];
    }
    try out.appendSlice(v.rt.gpa, rest);
    return bytesResult(v, args[0], try out.toOwnedSlice(v.rt.gpa));
}

fn bytes_find(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const data = try bytesData(args[0], v);
    const needle = try bytesData(args[1], v);
    const idx = std.mem.indexOf(u8, data, needle) orelse return v.rt.newInt(-1);
    return v.rt.newInt(@intCast(idx));
}

fn bytes_index(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const r = try bytes_find(vm, args, null);
    if (r.v.int == -1) {
        try v.raiseStr("ValueError", "subsection not found");
        return error.PyExc;
    }
    return r;
}

fn bytes_count(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const data = try bytesData(args[0], v);
    const needle = try bytesData(args[1], v);
    if (needle.len == 0) return v.rt.newInt(@intCast(data.len + 1));
    var n: usize = 0;
    var rest = data;
    while (std.mem.indexOf(u8, rest, needle)) |idx| {
        n += 1;
        rest = rest[idx + needle.len ..];
    }
    return v.rt.newInt(@intCast(n));
}

fn bytes_startswith(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const data = try bytesData(args[0], v);
    const p = try bytesData(args[1], v);
    return v.rt.newBool(p.len <= data.len and std.mem.eql(u8, data[0..p.len], p));
}

fn bytes_endswith(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const data = try bytesData(args[0], v);
    const p = try bytesData(args[1], v);
    return v.rt.newBool(p.len <= data.len and std.mem.eql(u8, data[data.len - p.len ..], p));
}

fn ba_append(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    if (args[0].v != .bytearray) return typeErr(v, "descriptor 'append' requires a 'bytearray'", .{});
    const i = try indexLike(v, args[1]);
    if (i < 0 or i > 255) {
        try v.raiseStr("ValueError", "byte must be in range(0, 256)");
        return error.PyExc;
    }
    try args[0].v.bytearray.data.append(v.rt.gpa, @intCast(i));
    return v.rt.newNone();
}

fn ba_extend(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    if (args[0].v != .bytearray) return typeErr(v, "descriptor 'extend' requires a 'bytearray'", .{});
    const data = try bytesData(args[1], v);
    try args[0].v.bytearray.data.appendSlice(v.rt.gpa, data);
    return v.rt.newNone();
}

fn ba_clear(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    if (args[0].v != .bytearray) return typeErr(v, "descriptor 'clear' requires a 'bytearray'", .{});
    args[0].v.bytearray.data.clearRetainingCapacity();
    return v.rt.newNone();
}

// ============================================================
// range / slice
// ============================================================

pub fn registerRangeSliceMethods(rt: *Runtime) !void {
    try td(rt, rt.range_t, "index", range_index);
    try td(rt, rt.range_t, "count", range_count);
    try td(rt, rt.slice_t, "indices", slice_indices);
}

fn range_index(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const r = args[0].v.range;
    const x = try indexLike(v, args[1]);
    const len: i64 = @intCast(r.len());
    for (0..@intCast(len)) |i| {
        if (r.get(i) == x) return v.rt.newInt(@intCast(i));
    }
    try v.raiseStr("ValueError", "value is not in range");
    return error.PyExc;
}

fn range_count(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const r = args[0].v.range;
    const x = try indexLike(v, args[1]);
    const len: usize = r.len();
    for (0..len) |i| {
        if (r.get(i) == x) return v.rt.newInt(1);
    }
    return v.rt.newInt(0);
}

fn slice_indices(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const sl = args[0].v.slice;
    const length = try indexLike(v, args[1]);
    const r = sl.indices(length) orelse {
        try v.raiseStr("ValueError", "slice step cannot be zero");
        return error.PyExc;
    };
    return v.rt.newTuple(&.{ try v.rt.newInt(r[0]), try v.rt.newInt(r[1]), try v.rt.newInt(r[2]) });
}

// ============================================================
// generator
// ============================================================

pub fn registerGeneratorMethods(rt: *Runtime) !void {
    const t = rt.generator_t;
    try td(rt, t, "__next__", gen_next);
    try td(rt, t, "send", gen_send);
    try td(rt, t, "throw", gen_throw);
    try td(rt, t, "close", gen_close);
    try td(rt, t, "__iter__", gen_iter);
}

fn selfGen(args: []const Obj, vm: *VM) !Obj {
    if (args.len == 0 or args[0].v != .generator) {
        try vm.raiseStr("TypeError", "descriptor requires a generator");
        return error.PyExc;
    }
    return args[0];
}

fn gen_next(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const g = try selfGen(args, v);
    return v.genSend(g, v.rt.newNone());
}

fn gen_send(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const g = try selfGen(args, v);
    const val: Obj = if (args.len >= 2) args[1] else v.rt.newNone();
    return v.genSend(g, val);
}

fn gen_throw(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const g = try selfGen(args, v);
    _ = g;
    if (args.len >= 2) {
        const exc = try vm.normalizeException(args[1]);
        try v.raiseObj(exc);
        return error.PyExc;
    }
    try v.raiseStr("GeneratorExit", "");
    return error.PyExc;
}

fn gen_close(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const g = (try selfGen(args, v)).v.generator;
    g.finished = true;
    g.frame = null;
    return v.rt.newNone();
}

fn gen_iter(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    _ = vm;
    return args[0];
}

// ============================================================
// property / staticmethod / classmethod / super
// ============================================================

pub fn registerPropertySuperMethods(rt: *Runtime) !void {
    try td(rt, rt.property_t, "getter", prop_getter);
    try td(rt, rt.property_t, "setter", prop_setter);
    try td(rt, rt.property_t, "deleter", prop_deleter);
    try td(rt, rt.super_t, "__init__", super_init);
}

fn prop_getter(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const p = args[0].v.property;
    const np = try v.rt.gpa.create(object.Property);
    np.* = .{ .fget = args[1], .fset = p.fset, .fdel = p.fdel };
    return v.rt.mkObj(v.rt.property_t, .{ .property = np });
}

fn prop_setter(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const p = args[0].v.property;
    const np = try v.rt.gpa.create(object.Property);
    np.* = .{ .fget = p.fget, .fset = args[1], .fdel = p.fdel };
    return v.rt.mkObj(v.rt.property_t, .{ .property = np });
}

fn prop_deleter(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const p = args[0].v.property;
    const np = try v.rt.gpa.create(object.Property);
    np.* = .{ .fget = p.fget, .fset = p.fset, .fdel = args[1] };
    return v.rt.mkObj(v.rt.property_t, .{ .property = np });
}

fn super_init(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const s = args[0].v.super_;
    if (args.len >= 3) {
        if (args[1].v != .type_) return typeErr(v, "super() arg 1 must be a type", .{});
        s.ty = args[1].v.type_;
        s.obj = args[2];
        if (args[2].v == .type_) {
            s.obj_type = args[2].v.type_;
        } else {
            s.obj_type = args[2].ty;
        }
    }
    return v.rt.newNone();
}

// ============================================================
// file — методы файлового объекта (std.Io)
// ============================================================

pub fn registerFileMethods(rt: *Runtime) !void {
    const t = rt.file_t;
    try td(rt, t, "read", file_read);
    try td(rt, t, "readline", file_readline);
    try td(rt, t, "readlines", file_readlines);
    try td(rt, t, "write", file_write);
    try td(rt, t, "writelines", file_writelines);
    try td(rt, t, "flush", file_flush);
    try td(rt, t, "close", file_close);
    try td(rt, t, "seek", file_seek);
    try td(rt, t, "tell", file_tell);
    try td(rt, t, "readable", file_readable);
    try td(rt, t, "writable", file_writable);
    try td(rt, t, "seekable", file_seekable);
    try td(rt, t, "__enter__", file_enter);
    try td(rt, t, "__exit__", file_exit);
    try td(rt, t, "__iter__", file_enter);
    try td(rt, t, "__next__", file_next);
    try td(rt, t, "getvalue", file_getvalue);
    try td(rt, t, "truncate", file_truncate);
}

fn selfFile(args: []const Obj, vm: *VM) !*object.File {
    if (args.len == 0 or args[0].v != .file) {
        try vm.raiseStr("TypeError", "descriptor requires a file object");
        return error.PyExc;
    }
    const f = args[0].v.file;
    if (f.f == null and f.std_fd == null) {
        try vm.raiseStr("ValueError", "I/O operation on closed file");
        return error.PyExc;
    }
    return f;
}

fn ioOf(vm: *VM) !std.Io {
    if (vm.rt.io) |io| return io;
    try vm.raiseStr("RuntimeError", "io subsystem is not initialized");
    return error.PyExc;
}

/// прочитать все данные с текущей позиции (для seekable — positional, иначе streaming)
pub fn fileReadAll(vm: *VM, f: *object.File, max: ?usize) anyerror![]u8 {
    const io = try ioOf(vm);
    var out: std.ArrayList(u8) = .empty;
    // pushback сначала
    if (f.pushback.items.len > 0) {
        try out.appendSlice(vm.rt.gpa, f.pushback.items);
        f.pushback.clearRetainingCapacity();
    }
    if (f.mem_buf) |buf| {
        const start: usize = @intCast(@min(f.pos, buf.items.len));
        const avail = buf.items.len - start;
        const take = if (max) |m| @min(m, avail) else avail;
        try out.appendSlice(vm.rt.gpa, buf.items[start .. start + take]);
        f.pos += take;
        return out.items;
    }
    if (f.std_fd) |sf| {
        const file: std.Io.File = switch (sf) {
            .stdin => std.Io.File.stdin(),
            .stdout => std.Io.File.stdout(),
            .stderr => std.Io.File.stderr(),
        };
        var buf: [8192]u8 = undefined;
        while (true) {
            const n = file.readStreaming(io, &.{&buf}) catch |e| return bltn.ioErr(vm, e, null);
            if (n == 0) break;
            try out.appendSlice(vm.rt.gpa, buf[0..n]);
            if (max) |m| {
                if (out.items.len >= m) break;
            }
        }
    } else {
        const file = f.f.?;
        const limit: u64 = if (max) |m| @intCast(m) else std.math.maxInt(u64);
        while (out.items.len < limit) {
            var buf: [8192]u8 = undefined;
            const n = file.readPositional(io, &.{&buf}, f.pos) catch |e| return bltn.ioErr(vm, e, null);
            if (n == 0) break;
            f.pos += n;
            try out.appendSlice(vm.rt.gpa, buf[0..n]);
        }
    }
    return out.items;
}

fn fileReadResult(vm: *VM, f: *object.File, data: []u8) !Obj {
    if (f.binary) return vm.rt.newBytesOwned(data);
    return decodeBytes(vm, data, "utf-8");
}

fn file_read(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const f = try selfFile(args, v);
    if (!f.readable) {
        try v.raiseStr("UnsupportedOperation", "not readable");
        return error.PyExc;
    }
    const max: ?usize = if (args.len >= 2 and args[1].v == .int and args[1].v.int >= 0) @intCast(args[1].v.int) else null;
    const data = try fileReadAll(v, f, max);
    return fileReadResult(v, f, try v.rt.gpa.dupe(u8, data));
}

fn file_readline(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const f = try selfFile(args, v);
    if (f.mem_buf) |buf| {
        var out2: std.ArrayList(u8) = .empty;
        const start: usize = @intCast(@min(f.pos, buf.items.len));
        var i = start;
        while (i < buf.items.len) : (i += 1) {
            try out2.append(v.rt.gpa, buf.items[i]);
            if (buf.items[i] == '\n') {
                i += 1;
                break;
            }
        }
        f.pos = i;
        return fileReadResult(v, f, try out2.toOwnedSlice(v.rt.gpa));
    }
    const io = try ioOf(v);
    var out: std.ArrayList(u8) = .empty;
    // из pushback
    if (f.pushback.items.len > 0) {
        if (std.mem.indexOfScalar(u8, f.pushback.items, '\n')) |idx| {
            try out.appendSlice(v.rt.gpa, f.pushback.items[0 .. idx + 1]);
            const rest = try v.rt.gpa.dupe(u8, f.pushback.items[idx + 1 ..]);
            f.pushback.clearRetainingCapacity();
            try f.pushback.appendSlice(v.rt.gpa, rest);
            return fileReadResult(v, f, try out.toOwnedSlice(v.rt.gpa));
        }
        try out.appendSlice(v.rt.gpa, f.pushback.items);
        f.pushback.clearRetainingCapacity();
    }
    var one: [1]u8 = undefined;
    while (true) {
        const n = if (f.std_fd) |sf| blk: {
            const file: std.Io.File = switch (sf) {
                .stdin => std.Io.File.stdin(),
                .stdout => std.Io.File.stdout(),
                .stderr => std.Io.File.stderr(),
            };
            break :blk file.readStreaming(io, &.{&one}) catch |e| return bltn.ioErr(v, e, null);
        } else blk: {
            break :blk f.f.?.readPositional(io, &.{&one}, f.pos) catch |e| return bltn.ioErr(v, e, null);
        };
        if (n == 0) break;
        f.pos += 1;
        try out.append(v.rt.gpa, one[0]);
        if (one[0] == '\n') break;
    }
    return fileReadResult(v, f, try out.toOwnedSlice(v.rt.gpa));
}

fn file_readlines(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const f = try selfFile(args, v);
    const data = try fileReadAll(v, f, null);
    const out = try v.rt.newList();
    var i: usize = 0;
    while (i < data.len) {
        const start = i;
        while (i < data.len and data[i] != '\n') i += 1;
        if (i < data.len) i += 1;
        const line = try v.rt.gpa.dupe(u8, data[start..i]);
        try out.v.list.items.append(v.rt.gpa, try fileReadResult(v, f, line));
    }
    return out;
}

pub fn fileWriteBytes(vm: *VM, f: *object.File, data: []const u8) anyerror!usize {
    if (f.mem_buf) |buf| {
        const pos: usize = @intCast(@min(f.pos, std.math.maxInt(u32)));
        if (pos < buf.items.len) {
            const grow = pos + data.len - buf.items.len;
            const keep = buf.items.len - pos;
            try buf.replaceRange(vm.rt.gpa, pos, @min(data.len, keep), data);
            if (grow > 0 and data.len > keep) {
                // replaceRange уже вставил лишнее
            }
        } else {
            // заполнить нулями разрыв
            try buf.appendNTimes(vm.rt.gpa, 0, pos - buf.items.len);
            try buf.appendSlice(vm.rt.gpa, data);
        }
        f.pos = pos + data.len;
        return data.len;
    }
    const io = try ioOf(vm);
    if (f.std_fd) |sf| {
        const file: std.Io.File = switch (sf) {
            .stdin => std.Io.File.stdin(),
            .stdout => std.Io.File.stdout(),
            .stderr => std.Io.File.stderr(),
        };
        var wbuf: [4096]u8 = undefined;
        var w = std.Io.File.Writer.initStreaming(file, io, &wbuf);
        w.interface.writeAll(data) catch |e| return bltn.ioErr(vm, e, null);
        w.interface.flush() catch |e| return bltn.ioErr(vm, e, null);
        return data.len;
    }
    f.f.?.writePositionalAll(io, data, f.pos) catch |e| return bltn.ioErr(vm, e, null);
    f.pos += data.len;
    return data.len;
}

fn file_write(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const f = try selfFile(args, v);
    if (!f.writable) {
        try v.raiseStr("UnsupportedOperation", "not writable");
        return error.PyExc;
    }
    var data: []const u8 = undefined;
    if (args[1].v == .str) {
        data = args[1].v.str.bytes;
    } else if (args[1].v == .bytes) {
        data = args[1].v.bytes.data;
    } else if (args[1].v == .bytearray) {
        data = args[1].v.bytearray.data.items;
    } else {
        return typeErr(v, "write() argument must be str or bytes-like", .{});
    }
    const n = try fileWriteBytes(v, f, data);
    return v.rt.newInt(@intCast(n));
}

fn file_writelines(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const it = try vm.pyIter(args[1]);
    while (try vm.pyNext(it)) |line| {
        _ = try file_write(v, &.{ args[0], line }, null);
    }
    return v.rt.newNone();
}

fn file_flush(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    _ = try selfFile(args, vm);
    return vm.rt.newNone();
}

fn file_close(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    if (args[0].v != .file) return typeErr(v, "descriptor 'close' requires a file object", .{});
    const f = args[0].v.file;
    if (f.f) |file| {
        const io = try ioOf(v);
        file.close(io);
        f.f = null;
    }
    return v.rt.newNone();
}

fn file_seek(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const f = try selfFile(args, v);
    const offset = try indexLike(v, args[1]);
    const whence: i64 = if (args.len >= 3) try indexLike(v, args[2]) else 0;
    var len: u64 = 0;
    if (f.mem_buf) |buf| {
        len = buf.items.len;
    } else {
        const io = try ioOf(v);
        len = f.f.?.length(io) catch 0;
    }
    const new_pos: i64 = switch (whence) {
        0 => offset,
        1 => @as(i64, @intCast(f.pos)) + offset,
        2 => @as(i64, @intCast(len)) + offset,
        else => offset,
    };
    if (new_pos < 0) {
        try v.raiseStr("OSError", "negative seek position");
        return error.PyExc;
    }
    f.pos = @intCast(new_pos);
    f.pushback.clearRetainingCapacity();
    return v.rt.newInt(@intCast(f.pos));
}

fn file_tell(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const f = try selfFile(args, v);
    return v.rt.newInt(@intCast(f.pos));
}

fn file_readable(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const f = args[0].v.file;
    return v.rt.newBool(f.readable);
}

fn file_writable(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const f = args[0].v.file;
    return v.rt.newBool(f.writable);
}

fn file_seekable(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const f = args[0].v.file;
    return v.rt.newBool(f.std_fd == null);
}

fn file_enter(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    _ = vm;
    return args[0];
}

fn file_exit(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    _ = try file_close(v, args[0..1], null);
    return v.rt.false_obj;
}

fn file_getvalue(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    if (args[0].v != .file) return typeErr(v, "descriptor 'getvalue' requires a file object", .{});
    const f = args[0].v.file;
    const buf = f.mem_buf orelse {
        try v.raiseStr("AttributeError", "getvalue() is only available on memory files");
        return error.PyExc;
    };
    if (f.binary) return v.rt.newBytes(buf.items);
    return v.rt.newStr(buf.items);
}

fn file_truncate(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const f = try selfFile(args, v);
    if (f.mem_buf) |buf| {
        const size: usize = if (args.len >= 2 and args[1].v == .int) @intCast(@max(0, args[1].v.int)) else @intCast(f.pos);
        buf.shrinkRetainingCapacity(@min(size, buf.items.len));
        if (f.pos > buf.items.len) f.pos = buf.items.len;
        return v.rt.newInt(@intCast(buf.items.len));
    }
    try v.raiseStr("UnsupportedOperation", "truncate");
    return error.PyExc;
}

fn file_next(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const line = try file_readline(v, args, null);
    const empty = if (line.v == .str) line.v.str.bytes.len == 0 else line.v.bytes.data.len == 0;
    if (empty) {
        try v.raiseStr("StopIteration", "");
        return error.PyExc;
    }
    return line;
}
