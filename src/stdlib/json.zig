//! json — аналог Lib/json/ + Modules/_json.c, переписан на Zig (object model v2).
//! loads/dumps/load/dump + JSONDecodeError. Собственный рекурсивный парсер и
//! сериализатор (без std.json — проще контролировать ошибки и формат вывода).

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
    const m = try rt.newModuleObj("json");

    // JSONDecodeError — подкласс ValueError (наследует __init__/__str__ по MRO)
    const ve = vm.excType("ValueError");
    var jde = rt.exc_types.get("JSONDecodeError") orelse blk: {
        const t = try rt.mkType("JSONDecodeError", ve);
        t.flags.exc = true;
        t.module = "json";
        try rt.exc_types.put("JSONDecodeError", t);
        break :blk t;
    };
    jde.module = "json";
    try mset(vm, m, "JSONDecodeError", try rt.mkObj(rt.type_t, .{ .type_ = jde }));

    try mfun(vm, m, "loads", json_loads);
    try mfun(vm, m, "dumps", json_dumps);
    try mfun(vm, m, "load", json_load);
    try mfun(vm, m, "dump", json_dump);

    // Совместимость: классы-заглушки (requests/некоторые либы ссылаются)
    try mset(vm, m, "__version__", try rt.newStr("2.0.9"));
    return m;
}

// ============================================================
// loads — парсинг JSON → Python
// ============================================================

const Parser = struct {
    s: []const u8,
    i: usize,
    vm: *VM,

    fn skipWs(p: *Parser) void {
        while (p.i < p.s.len) {
            const c = p.s[p.i];
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') p.i += 1 else break;
        }
    }

    fn fail(p: *Parser, comptime msg: []const u8) anyerror!Obj {
        try p.vm.raiseFmt("JSONDecodeError", msg ++ " (char {d})", .{p.i});
        return error.PyExc;
    }

    fn parse(p: *Parser) anyerror!Obj {
        p.skipWs();
        if (p.i >= p.s.len) return p.fail("Expecting value");
        const c = p.s[p.i];
        return switch (c) {
            '{' => p.parseObject(),
            '[' => p.parseArray(),
            '"' => p.parseString(),
            't', 'f' => p.parseBool(),
            'n' => p.parseNull(),
            else => p.parseNumber(),
        };
    }

    fn parseObject(p: *Parser) anyerror!Obj {
        const rt = p.vm.rt;
        const d = try rt.newDictObj();
        p.i += 1; // {
        p.skipWs();
        if (p.i < p.s.len and p.s[p.i] == '}') {
            p.i += 1;
            return d;
        }
        while (true) {
            p.skipWs();
            if (p.i >= p.s.len or p.s[p.i] != '"') return p.fail("Expecting property name enclosed in double quotes");
            const key = try p.parseString();
            p.skipWs();
            if (p.i >= p.s.len or p.s[p.i] != ':') return p.fail("Expecting ':' delimiter");
            p.i += 1;
            const val = try p.parse();
            try ops.dictSetStr(d.v.dict, p.vm, key.v.str.bytes, val);
            p.skipWs();
            if (p.i >= p.s.len) return p.fail("Expecting ',' delimiter");
            if (p.s[p.i] == ',') {
                p.i += 1;
                continue;
            }
            if (p.s[p.i] == '}') {
                p.i += 1;
                return d;
            }
            return p.fail("Expecting ',' delimiter");
        }
    }

    fn parseArray(p: *Parser) anyerror!Obj {
        const rt = p.vm.rt;
        const lst = try rt.newList();
        p.i += 1; // [
        p.skipWs();
        if (p.i < p.s.len and p.s[p.i] == ']') {
            p.i += 1;
            return lst;
        }
        while (true) {
            const val = try p.parse();
            try lst.v.list.items.append(rt.gpa, val);
            p.skipWs();
            if (p.i >= p.s.len) return p.fail("Expecting ',' delimiter");
            if (p.s[p.i] == ',') {
                p.i += 1;
                continue;
            }
            if (p.s[p.i] == ']') {
                p.i += 1;
                return lst;
            }
            return p.fail("Expecting ',' delimiter");
        }
    }

    fn parseString(p: *Parser) anyerror!Obj {
        const rt = p.vm.rt;
        p.i += 1; // открывающая "
        var out: std.ArrayList(u8) = .empty;
        while (p.i < p.s.len) {
            const c = p.s[p.i];
            if (c == '"') {
                p.i += 1;
                return rt.newStr(out.items);
            }
            if (c == '\\') {
                p.i += 1;
                if (p.i >= p.s.len) return p.fail("Invalid \\escape");
                const e = p.s[p.i];
                p.i += 1;
                switch (e) {
                    '"' => out.append(rt.gpa, '"') catch {},
                    '\\' => out.append(rt.gpa, '\\') catch {},
                    '/' => out.append(rt.gpa, '/') catch {},
                    'b' => out.append(rt.gpa, 0x08) catch {},
                    'f' => out.append(rt.gpa, 0x0C) catch {},
                    'n' => out.append(rt.gpa, '\n') catch {},
                    'r' => out.append(rt.gpa, '\r') catch {},
                    't' => out.append(rt.gpa, '\t') catch {},
                    'u' => {
                        const cp = p.parseHex4() catch return p.fail("Invalid \\uXXXX escape");
                        // суррогатная пара
                        var code: u21 = @intCast(cp);
                        if (cp >= 0xD800 and cp <= 0xDBFF) {
                            if (p.i + 1 < p.s.len and p.s[p.i] == '\\' and p.s[p.i + 1] == 'u') {
                                p.i += 2;
                                const lo = p.parseHex4() catch return p.fail("Invalid \\uXXXX escape");
                                if (lo >= 0xDC00 and lo <= 0xDFFF) {
                                    code = 0x10000 + (@as(u21, cp - 0xD800) << 10) + @as(u21, lo - 0xDC00);
                                }
                            }
                        }
                        var buf: [4]u8 = undefined;
                        const n = std.unicode.utf8Encode(code, &buf) catch 1;
                        out.appendSlice(rt.gpa, buf[0..n]) catch {};
                    },
                    else => return p.fail("Invalid \\escape"),
                }
            } else {
                out.append(rt.gpa, c) catch {};
                p.i += 1;
            }
        }
        return p.fail("Unterminated string");
    }

    fn parseHex4(p: *Parser) !u16 {
        if (p.i + 4 > p.s.len) return error.Bad;
        var v: u16 = 0;
        var k: usize = 0;
        while (k < 4) : (k += 1) {
            const c = p.s[p.i + k];
            const d: u16 = switch (c) {
                '0'...'9' => c - '0',
                'a'...'f' => c - 'a' + 10,
                'A'...'F' => c - 'A' + 10,
                else => return error.Bad,
            };
            v = v * 16 + d;
        }
        p.i += 4;
        return v;
    }

    fn parseBool(p: *Parser) anyerror!Obj {
        if (std.mem.startsWith(u8, p.s[p.i..], "true")) {
            p.i += 4;
            return p.vm.rt.newBool(true);
        }
        if (std.mem.startsWith(u8, p.s[p.i..], "false")) {
            p.i += 5;
            return p.vm.rt.newBool(false);
        }
        return p.fail("Expecting value");
    }

    fn parseNull(p: *Parser) anyerror!Obj {
        if (std.mem.startsWith(u8, p.s[p.i..], "null")) {
            p.i += 4;
            return p.vm.rt.newNone();
        }
        return p.fail("Expecting value");
    }

    fn parseNumber(p: *Parser) anyerror!Obj {
        const rt = p.vm.rt;
        const start = p.i;
        var is_float = false;
        if (p.i < p.s.len and (p.s[p.i] == '-' or p.s[p.i] == '+')) p.i += 1;
        while (p.i < p.s.len) {
            const c = p.s[p.i];
            if (c >= '0' and c <= '9') {
                p.i += 1;
            } else if (c == '.' or c == 'e' or c == 'E' or c == '+' or c == '-') {
                if (c == '.' or c == 'e' or c == 'E') is_float = true;
                p.i += 1;
            } else break;
        }
        if (p.i == start) return p.fail("Expecting value");
        const num = p.s[start..p.i];
        if (is_float) {
            const f = std.fmt.parseFloat(f64, num) catch return p.fail("Invalid number");
            return rt.newFloat(f);
        }
        if (std.mem.eql(u8, num, "-")) return p.fail("Invalid number");
        const iv = std.fmt.parseInt(i64, num, 10) catch {
            // переполнение i64 → bigint
            const big = (object.bigParse(rt.gpa, num, 10) catch null) orelse return p.fail("Invalid number");
            return rt.newBig(big);
        };
        return rt.newInt(iv);
    }
};

fn json_loads(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    if (args.len < 1) {
        try v.raiseFmt("TypeError", "loads() missing 1 required positional argument: 's'", .{});
        return error.PyExc;
    }
    var bytes: []const u8 = undefined;
    switch (args[0].v) {
        .str => |s| bytes = s.bytes,
        .bytes => |b| bytes = b.data,
        .bytearray => |b| bytes = b.data.items,
        else => {
            try v.raiseFmt("TypeError", "the JSON object must be str, bytes or bytearray, not {s}", .{args[0].ty.name});
            return error.PyExc;
        },
    }
    var p = Parser{ .s = bytes, .i = 0, .vm = v };
    const result = try p.parse();
    p.skipWs();
    if (p.i < bytes.len) {
        try v.raiseFmt("JSONDecodeError", "Extra data (char {d})", .{p.i});
        return error.PyExc;
    }
    return result;
}

// ============================================================
// dumps — сериализация Python → JSON
// ============================================================

const Dumper = struct {
    out: std.ArrayList(u8),
    vm: *VM,
    indent: ?[]const u8,
    ensure_ascii: bool,
    depth: usize,

    fn writeStr(d: *Dumper, s: []const u8) void {
        d.out.appendSlice(d.vm.rt.gpa, s) catch {};
    }

    fn dumpString(d: *Dumper, s: []const u8) void {
        d.writeStr("\"");
        var i: usize = 0;
        while (i < s.len) {
            const c = s[i];
            switch (c) {
                '"' => d.writeStr("\\\""),
                '\\' => d.writeStr("\\\\"),
                '\n' => d.writeStr("\\n"),
                '\r' => d.writeStr("\\r"),
                '\t' => d.writeStr("\\t"),
                0x08 => d.writeStr("\\b"),
                0x0C => d.writeStr("\\f"),
                else => {
                    if (c < 0x20) {
                        var buf: [8]u8 = undefined;
                        const sl = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{c}) catch "\\u0000";
                        d.writeStr(sl);
                    } else if (c < 0x80 or !d.ensure_ascii) {
                        d.out.append(d.vm.rt.gpa, c) catch {};
                    } else {
                        // UTF-8 → codepoint → \uXXXX (с суррогатной парой для >0xFFFF)
                        const l = std.unicode.utf8ByteSequenceLength(c) catch 1;
                        const end = @min(i + l, s.len);
                        const cp = std.unicode.utf8Decode(s[i..end]) catch 0xFFFD;
                        var buf: [16]u8 = undefined;
                        if (cp > 0xFFFF) {
                            const v = cp - 0x10000;
                            const hi: u16 = @intCast(0xD800 + (v >> 10));
                            const lo: u16 = @intCast(0xDC00 + (v & 0x3FF));
                            const sl = std.fmt.bufPrint(&buf, "\\u{x:0>4}\\u{x:0>4}", .{ hi, lo }) catch "";
                            d.writeStr(sl);
                        } else {
                            const sl = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{cp}) catch "";
                            d.writeStr(sl);
                        }
                        i = end;
                        continue;
                    }
                },
            }
            i += 1;
        }
        d.writeStr("\"");
    }

    fn newlineIndent(d: *Dumper) void {
        if (d.indent) |ind| {
            d.writeStr("\n");
            var k: usize = 0;
            while (k < d.depth) : (k += 1) d.writeStr(ind);
        }
    }

    fn dump(d: *Dumper, o: Obj) anyerror!void {
        const v = d.vm;
        switch (o.v) {
            .none => d.writeStr("null"),
            .bool_ => |b| d.writeStr(if (b) "true" else "false"),
            .int => |iv| {
                var buf: [24]u8 = undefined;
                const sl = std.fmt.bufPrint(&buf, "{d}", .{iv}) catch "0";
                d.writeStr(sl);
            },
            .bigint => |b| {
                const sl = b.toString(d.vm.rt.gpa, 10, .lower) catch "0";
                d.writeStr(sl);
            },
            .float => |f| {
                const sl = try ops.floatRepr(d.vm.rt.gpa, f);
                d.writeStr(sl);
            },
            .str => |s| d.dumpString(s.bytes),
            .list => |l| {
                const items = l.items.items;
                if (items.len == 0) {
                    d.writeStr("[]");
                    return;
                }
                d.writeStr("[");
                d.depth += 1;
                for (items, 0..) |it, idx| {
                    if (idx > 0) d.writeStr(",");
                    d.newlineIndent();
                    try d.dump(it);
                }
                d.depth -= 1;
                d.newlineIndent();
                d.writeStr("]");
            },
            .tuple => |t| {
                if (t.len == 0) {
                    d.writeStr("[]");
                    return;
                }
                d.writeStr("[");
                d.depth += 1;
                for (t, 0..) |it, idx| {
                    if (idx > 0) d.writeStr(",");
                    d.newlineIndent();
                    try d.dump(it);
                }
                d.depth -= 1;
                d.newlineIndent();
                d.writeStr("]");
            },
            .dict => |dict| {
                if (dict.len() == 0) {
                    d.writeStr("{}");
                    return;
                }
                d.writeStr("{");
                d.depth += 1;
                var first = true;
                var it = dict.iterAlive();
                while (it.next()) |e| {
                    if (!first) d.writeStr(",");
                    first = false;
                    d.newlineIndent();
                    // ключ должен быть str
                    if (e.key.?.v != .str) {
                        try v.raiseFmt("TypeError", "keys must be str, not {s}", .{e.key.?.ty.name});
                        return error.PyExc;
                    }
                    d.dumpString(e.key.?.v.str.bytes);
                    d.writeStr(if (d.indent != null) ": " else ":");
                    try d.dump(e.val.?);
                }
                d.depth -= 1;
                d.newlineIndent();
                d.writeStr("}");
            },
            else => {
                try v.raiseFmt("TypeError", "Object of type {s} is not JSON serializable", .{o.ty.name});
                return error.PyExc;
            },
        }
    }
};

fn json_dumps(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    const v: *VM = vm;
    if (args.len < 1) {
        try v.raiseFmt("TypeError", "dumps() missing 1 required positional argument: 'obj'", .{});
        return error.PyExc;
    }
    // параметры
    var indent: ?[]const u8 = null;
    var ensure_ascii = true;
    if (kw) |k| {
        if (k.get("ensure_ascii")) |ea| ensure_ascii = try v.pyTruthy(ea);
        if (k.get("indent")) |io| {
            if (io.v == .int) {
                const n = io.v.int;
                if (n > 0) {
                    var sp: std.ArrayList(u8) = .empty;
                    var x: i64 = 0;
                    while (x < n) : (x += 1) sp.append(v.rt.gpa, ' ') catch {};
                    indent = sp.items;
                } else if (n == 0) {
                    indent = "";
                }
            } else if (io.v == .str) {
                indent = io.v.str.bytes;
            }
        }
    }
    // args[1] может быть indent (позиционно, как в CPython: dumps(obj, skipkeys, ensure_ascii, check_circular, allow_nan, cls, indent,...))
    if (indent == null and args.len > 7 and args[7].v == .int and args[7].v.int > 0) {
        var sp: std.ArrayList(u8) = .empty;
        var x: i64 = 0;
        while (x < args[7].v.int) : (x += 1) sp.append(v.rt.gpa, ' ') catch {};
        indent = sp.items;
    }

    var d = Dumper{ .out = .empty, .vm = v, .indent = indent, .ensure_ascii = ensure_ascii, .depth = 0 };
    try d.dump(args[0]);
    return v.rt.newStr(d.out.items);
}

// ============================================================
// load / dump — через файловый объект (fp.read() / fp.write())
// ============================================================

fn json_load(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    const v: *VM = vm;
    if (args.len < 1) {
        try v.raiseFmt("TypeError", "load() missing 1 required positional argument: 'fp'", .{});
        return error.PyExc;
    }
    const read_fn = try ops.pyGetAttr(v, args[0], "read");
    const text = try ops.pyCall(v, read_fn, &.{}, null);
    return json_loads(v, &.{text}, kw);
}

fn json_dump(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    const v: *VM = vm;
    if (args.len < 2) {
        try v.raiseFmt("TypeError", "dump() missing required argument: 'fp'", .{});
        return error.PyExc;
    }
    const s = try json_dumps(v, args[0..1], kw);
    const write_fn = try ops.pyGetAttr(v, args[1], "write");
    _ = try ops.pyCall(v, write_fn, &.{s}, null);
    return v.rt.newNone();
}
