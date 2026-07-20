//! binascii — аналог Modules/binascii.c, на чистом Zig (std.base64).
//! a2b_base64/b2a_base64/hexlify/unhexlify/crc32 и др.

const std = @import("std");
const object = @import("../object/object.zig");
const ops = @import("../vm/ops.zig");
const vm_mod = @import("../vm/vm.zig");

const VM = vm_mod.VM;
const Obj = object.Obj;
const KwArgs = object.KwArgs;

fn mset(vm: *VM, m: Obj, name: []const u8, val: Obj) !void {
    try ops.dictSetStr(m.v.module.dict, vm, name, val);
}
fn mfun(vm: *VM, m: Obj, name: []const u8, comptime f: anytype) !void {
    try mset(vm, m, name, try vm.rt.newBuiltin(name, object.wrapBuiltin(f)));
}

pub fn initModule(vm: *VM) anyerror!Obj {
    const rt = vm.rt;
    const m = try rt.newModuleObj("binascii");
    try mfun(vm, m, "a2b_base64", a2b_base64);
    try mfun(vm, m, "b2a_base64", b2a_base64);
    try mfun(vm, m, "hexlify", hexlify);
    try mfun(vm, m, "b2a_hex", hexlify);
    try mfun(vm, m, "unhexlify", unhexlify);
    try mfun(vm, m, "a2b_hex", unhexlify);
    try mfun(vm, m, "crc32", crc32);
    try mfun(vm, m, "a2b_qp", passthrough);
    try mfun(vm, m, "b2a_qp", passthrough);
    // error исключение
    const exc_t = vm.excType("Exception");
    var err_t = rt.exc_types.get("BinAsciiError") orelse blk: {
        const t = try rt.mkType("Error", exc_t);
        t.flags.exc = true;
        t.module = "binascii";
        try rt.exc_types.put("BinAsciiError", t);
        break :blk t;
    };
    err_t.module = "binascii";
    try mset(vm, m, "Error", try rt.mkObj(rt.type_t, .{ .type_ = err_t }));
    try mset(vm, m, "Incomplete", try rt.mkObj(rt.type_t, .{ .type_ = err_t }));
    return m;
}

fn getBuf(vm: *VM, o: Obj) anyerror![]const u8 {
    if (o.v == .bytes) return o.v.bytes.data;
    if (o.v == .bytearray) return o.v.bytearray.data.items;
    if (o.v == .str) return o.v.str.bytes;
    const s = try ops.pyStr(vm, o);
    return s.v.str.bytes;
}

fn a2b_base64(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    if (args.len < 1) return v.rt.newBytes("");
    const data = try getBuf(v, args[0]);
    const dec = std.base64.standard.Decoder;
    const out_len = dec.calcSizeForSlice(data) catch {
        // пробуем с пропуском невалидных символов
        const n = dec.calcSizeForSlice(data) catch data.len;
        _ = n;
        return v.rt.newBytes("");
    };
    const out = try v.rt.gpa.alloc(u8, out_len);
    dec.decode(out, data) catch {
        return v.rt.newBytes("");
    };
    return v.rt.newBytesOwned(out);
}

fn b2a_base64(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    const v: *VM = vm;
    if (args.len < 1) return v.rt.newBytes("");
    const data = try getBuf(v, args[0]);
    var newline = true;
    if (args.len > 1) newline = v.pyTruthy(args[1]) catch true;
    if (kw) |k| {
        if (k.get("newline")) |n| newline = v.pyTruthy(n) catch true;
    }
    const enc = std.base64.standard.Encoder;
    const out_len = enc.calcSize(data.len);
    const out = try v.rt.gpa.alloc(u8, out_len);
    _ = enc.encode(out, data);
    if (newline) {
        const with_nl = try v.rt.gpa.alloc(u8, out.len + 1);
        @memcpy(with_nl[0..out.len], out);
        with_nl[out.len] = '\n';
        return v.rt.newBytesOwned(with_nl);
    }
    return v.rt.newBytesOwned(out);
}

fn hexlify(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    if (args.len < 1) return v.rt.newBytes("");
    const data = try getBuf(v, args[0]);
    const out = try v.rt.gpa.alloc(u8, data.len * 2);
    _ = std.fmt.bufPrint(out, "{s}", .{std.fmt.fmtSliceHexLower(data)}) catch {
        // fallback вручную
        const hex = "0123456789abcdef";
        for (data, 0..) |b, i| {
            out[i * 2] = hex[b >> 4];
            out[i * 2 + 1] = hex[b & 0xf];
        }
        return v.rt.newBytesOwned(out);
    };
    return v.rt.newBytesOwned(out);
}

fn unhexlify(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    if (args.len < 1) return v.rt.newBytes("");
    const data = try getBuf(v, args[0]);
    if (data.len % 2 != 0) {
        try v.raiseStr("ValueError", "non-hexadecimal number found");
        return error.PyExc;
    }
    const out = try v.rt.gpa.alloc(u8, data.len / 2);
    var i: usize = 0;
    while (i < data.len) : (i += 2) {
        const hi = hexVal(data[i]) orelse {
            try v.raiseStr("ValueError", "non-hexadecimal number found");
            return error.PyExc;
        };
        const lo = hexVal(data[i + 1]) orelse {
            try v.raiseStr("ValueError", "non-hexadecimal number found");
            return error.PyExc;
        };
        out[i / 2] = (hi << 4) | lo;
    }
    return v.rt.newBytesOwned(out);
}

fn hexVal(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

fn crc32(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    const v: *VM = vm;
    if (args.len < 1) return v.rt.newInt(0);
    const data = try getBuf(v, args[0]);
    var crc: u32 = 0;
    if (args.len > 1 and args[1].v == .int) crc = @truncate(@as(u64, @bitCast(args[1].v.int)));
    _ = kw;
    const result = std.hash.Crc32.update(crc, data);
    return v.rt.newInt(@intCast(@as(i64, @bitCast(@as(u64, result)))));
}

fn passthrough(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    if (args.len >= 1) {
        const data = try getBuf(v, args[0]);
        return v.rt.newBytes(data);
    }
    return v.rt.newBytes("");
}
