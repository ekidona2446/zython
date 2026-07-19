//! Методы встроенных типов — аналог Objects/*.c (str, list, dict, set, tuple,
//! int/float, bytes, range/slice, generator, property/super, file, object/type).

const std = @import("std");
const object = @import("../../object/object.zig");
const runtime_mod = @import("../runtime.zig");
const ops = @import("../../vm/ops.zig");
const vm_mod = @import("../../vm/vm.zig");
const bltn = @import("../builtins.zig");

const Runtime = runtime_mod.Runtime;
const VM = vm_mod.VM;
const Obj = object.Obj;
const Type = object.Type;
const Dict = object.Dict;
const KwArgs = object.KwArgs;

const typeErr = bltn.typeErr;
const valErr = bltn.valErr;
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

fn kwGet(kw: ?KwArgs, name: []const u8) ?Obj {
    if (kw) |k| return k.get(name);
    return null;
}

fn selfStr(args: []const Obj, vm: *VM) !*object.Str {
    if (args.len == 0 or args[0].v != .str) {
        try vm.raiseStr("TypeError", "descriptor requires a 'str' object");
        return error.PyExc;
    }
    return args[0].v.str;
}

fn selfList(args: []const Obj, vm: *VM) !*object.List {
    if (args.len == 0 or args[0].v != .list) {
        try vm.raiseStr("TypeError", "descriptor requires a 'list' object");
        return error.PyExc;
    }
    return args[0].v.list;
}

fn selfDict(args: []const Obj, vm: *VM) !*Dict {
    if (args.len == 0) {
        try vm.raiseStr("TypeError", "descriptor requires a 'dict' object");
        return error.PyExc;
    }
    // dict или dict-подкласс (instance, напр. enum._EnumDict): содержимое в instance.data
    return switch (args[0].v) {
        .dict => |d| d,
        .instance => |i| blk: {
            if (i.data == null) i.data = try vm.rt.newDict();
            break :blk i.data.?;
        },
        else => {
            try vm.raiseStr("TypeError", "descriptor requires a 'dict' object");
            return error.PyExc;
        },
    };
}

// ============================================================
// object
// ============================================================

pub fn registerObjectMethods(rt: *Runtime) !void {
    try td(rt, rt.object_t, "__init__", obj_init);
    try td(rt, rt.object_t, "__repr__", obj_repr);
    try td(rt, rt.object_t, "__str__", obj_repr);
    try td(rt, rt.object_t, "__init_subclass__", obj_init_subclass);
    try td(rt, rt.object_t, "__format__", obj_format);
    try td(rt, rt.object_t, "__reduce_ex__", obj_reduce_ex);
    try td(rt, rt.object_t, "__reduce__", obj_reduce);
    try td(rt, rt.object_t, "__sizeof__", obj_sizeof);
}

fn obj_reduce_ex(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const cls = try v.typeOf(args[0]);
    return v.rt.newTuple(&.{ cls, try v.rt.newTuple(&.{}) });
}
fn obj_reduce(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    return obj_reduce_ex(vm, args, kw);
}
fn obj_sizeof(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = args;
    _ = kw;
    return vm.rt.newInt(16);
}

fn obj_init(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = args;
    _ = kw;
    return vm.rt.newNone();
}

fn obj_repr(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const o = args[0];
    const mod = o.ty.module orelse "builtins";
    const addr: usize = @intFromPtr(o);
    var buf: []u8 = undefined;
    if (std.mem.eql(u8, mod, "builtins")) {
        buf = try std.fmt.allocPrint(v.rt.gpa, "<{s} object at 0x{x}>", .{ o.ty.name, addr });
    } else {
        buf = try std.fmt.allocPrint(v.rt.gpa, "<{s}.{s} object at 0x{x}>", .{ mod, o.ty.name, addr });
    }
    return v.rt.newStrOwned(buf);
}

fn obj_init_subclass(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = args;
    _ = kw;
    return vm.rt.newNone();
}

fn obj_format(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    // object.__format__": пустая спека — str(v), непустая — TypeError (object.__format__ в typeobject.c)
    _ = kw;
    const v: *VM = vm;
    const spec = args[1].v.str.bytes;
    if (spec.len != 0) {
        // для встроенных числовых/строковых типов у них свой __format__; сюда доходят только
        // классы без собственного __format__ — CPython бросает TypeError
        try v.raiseFmt("TypeError", "unsupported format string passed to {s}.__format__", .{args[0].ty.name});
        return error.PyExc;
    }
    return v.formatValue(args[0], 0, null);
}

// ============================================================
// type
// ============================================================

pub fn registerTypeMethods(rt: *Runtime) !void {
    try td(rt, rt.type_t, "__repr__", type_repr);
    try td(rt, rt.type_t, "__subclasses__", type_subclasses);
    try td(rt, rt.type_t, "__instancecheck__", type_instancecheck);
    try td(rt, rt.type_t, "__subclasscheck__", type_subclasscheck);
    try td(rt, rt.type_t, "mro", type_mro);
    // __mro__ как readonly property (аналог getset type_mro в typeobject.c)
    const prop = try rt.newProperty(.{ .fget = try rt.newBuiltin("__mro__", object.wrapBuiltin(type___mro__)) });
    try dictPutStartup(rt, rt.type_t.dict, "__mro__", prop);
    // Остальные readonly getset'ы type (typeobject.c: type_getsets)
    try tdGet(rt, "__name__", type___name__);
    try tdGet(rt, "__qualname__", type___qualname__);
    try tdGet(rt, "__module__", type___module__);
    try tdGet(rt, "__doc__", type___doc__);
    try tdGet(rt, "__bases__", type___bases__);
    try tdGet(rt, "__base__", type___base__);
    try tdGet(rt, "__flags__", type___flags__);
    try tdGet(rt, "__dict__", type___dict__);
    try tdGet(rt, "__text_signature__", type___text_signature__);
}

fn tdGet(rt: *Runtime, name: []const u8, comptime f: anytype) !void {
    const prop = try rt.newProperty(.{ .fget = try rt.newBuiltin(name, object.wrapBuiltin(f)) });
    try dictPutStartup(rt, rt.type_t.dict, name, prop);
}

fn type___name__(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    return v.rt.newStr(args[0].v.type_.name);
}

fn type___qualname__(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    return v.rt.newStr(args[0].v.type_.qualname);
}

fn type___module__(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    return v.rt.newStr(args[0].v.type_.module orelse "builtins");
}

fn type___doc__(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const d = args[0].v.type_.doc orelse return v.rt.newNone();
    return v.rt.newStr(d);
}

fn type___bases__(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const cls = args[0].v.type_;
    const items = try v.rt.gpa.alloc(object.Obj, cls.bases.len);
    for (cls.bases, 0..) |t, i| items[i] = try v.rt.mkObj(v.rt.type_t, .{ .type_ = t });
    return v.rt.newTupleOwned(items);
}

fn type___base__(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const cls = args[0].v.type_;
    if (cls.base == null or cls.base.? == cls) return v.rt.newNone();
    return v.rt.mkObj(v.rt.type_t, .{ .type_ = cls.base.? });
}

fn type___flags__(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    _ = args;
    // Точное значение Py_TPFLAGS_* пока не важно, возвращаем правдоподобную маску
    return v.rt.newInt(0);
}

fn type___dict__(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    // Упрощение: mappingproxy не реализован, отдаём сам dict (как CPython без прокси)
    return v.rt.mkObj(v.rt.dict_t, .{ .dict = args[0].v.type_.dict });
}

fn type___text_signature__(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    _ = args;
    return vm.rt.newNone();
}

fn type___mro__(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const cls = args[0].v.type_;
    const items = try vm.rt.gpa.alloc(object.Obj, cls.mro.len);
    for (cls.mro, 0..) |t, i| {
        items[i] = try vm.rt.mkObj(vm.rt.type_t, .{ .type_ = t });
    }
    return vm.rt.newTupleOwned(items);
}

fn type_repr(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const t = args[0].v.type_;
    const mod = t.module orelse "builtins";
    const s = if (std.mem.eql(u8, mod, "builtins"))
        try std.fmt.allocPrint(v.rt.gpa, "<class '{s}'>", .{t.name})
    else
        try std.fmt.allocPrint(v.rt.gpa, "<class '{s}.{s}'>", .{ mod, t.name });
    return v.rt.newStrOwned(s);
}

fn type_subclasses(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    // O(n) по всем типам рантайма — как у CPython по tp_subclasses
    const cls = args[0].v.type_;
    const out = try v.rt.newList();
    for (v.rt.all_types.items) |t| {
        if (t.base) |b| {
            if (b == cls) try out.v.list.items.append(v.rt.gpa, try v.rt.mkObj(v.rt.type_t, .{ .type_ = t }));
        }
    }
    return out;
}

fn type_instancecheck(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const inst = args[1];
    return v.rt.newBool(try ops.isInstance(v, inst, args[0]));
}

fn type_subclasscheck(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    if (args[1].v != .type_) return v.rt.false_obj;
    const a = args[0].v.type_;
    const b = args[1].v.type_;
    return v.rt.newBool(ops.isSubclass(b, a));
}

fn type_mro(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const cls = args[0].v.type_;
    const items = try v.rt.gpa.alloc(Obj, cls.mro.len);
    for (cls.mro, 0..) |t, i| items[i] = try v.rt.mkObj(v.rt.type_t, .{ .type_ = t });
    return v.rt.mkObj(v.rt.list_t, .{ .list = blk: {
        const l = try v.rt.gpa.create(object.List);
        l.* = .{ .items = .empty };
        try l.items.appendSlice(v.rt.gpa, items);
        break :blk l;
    } });
}

// ============================================================
// str
// ============================================================

pub fn registerStrMethods(rt: *Runtime) !void {
    const t = rt.str_t;
    try td(rt, t, "__format__", str___format__);
    try td(rt, t, "upper", str_upper);
    try td(rt, t, "lower", str_lower);
    try td(rt, t, "title", str_title);
    try td(rt, t, "capitalize", str_capitalize);
    try td(rt, t, "casefold", str_lower);
    try td(rt, t, "swapcase", str_swapcase);
    try td(rt, t, "strip", str_strip);
    try td(rt, t, "lstrip", str_lstrip);
    try td(rt, t, "rstrip", str_rstrip);
    try td(rt, t, "split", str_split);
    try td(rt, t, "rsplit", str_rsplit);
    try td(rt, t, "splitlines", str_splitlines);
    try td(rt, t, "join", str_join);
    try td(rt, t, "replace", str_replace);
    try td(rt, t, "find", str_find);
    try td(rt, t, "rfind", str_rfind);
    try td(rt, t, "index", str_index);
    try td(rt, t, "rindex", str_rindex);
    try td(rt, t, "count", str_count);
    try td(rt, t, "startswith", str_startswith);
    try td(rt, t, "endswith", str_endswith);
    try td(rt, t, "encode", str_encode);
    try td(rt, t, "format", str_format);
    try td(rt, t, "format_map", str_format_map);
    try td(rt, t, "zfill", str_zfill);
    try td(rt, t, "center", str_center);
    try td(rt, t, "ljust", str_ljust);
    try td(rt, t, "rjust", str_rjust);
    try td(rt, t, "partition", str_partition);
    try td(rt, t, "rpartition", str_rpartition);
    try td(rt, t, "removeprefix", str_removeprefix);
    try td(rt, t, "removesuffix", str_removesuffix);
    try td(rt, t, "expandtabs", str_expandtabs);
    try td(rt, t, "isdigit", str_isdigit);
    try td(rt, t, "isnumeric", str_isdigit);
    try td(rt, t, "isdecimal", str_isdigit);
    try td(rt, t, "isalpha", str_isalpha);
    try td(rt, t, "isalnum", str_isalnum);
    try td(rt, t, "isspace", str_isspace);
    try td(rt, t, "isupper", str_isupper);
    try td(rt, t, "islower", str_islower);
    try td(rt, t, "istitle", str_istitle);
    try td(rt, t, "isidentifier", str_isidentifier);
    try td(rt, t, "isprintable", str_isprintable);
    try td(rt, t, "__getitem__", str_getitem_dunder);
    try td(rt, t, "maketrans", str_maketrans);
    try td(rt, t, "translate", str_translate);
}

fn eachCp(bytes: []const u8, ctx: anytype, comptime f: anytype) !void {
    var i: usize = 0;
    while (i < bytes.len) {
        const l = std.unicode.utf8ByteSequenceLength(bytes[i]) catch 1;
        const end = @min(i + l, bytes.len);
        const cp = std.unicode.utf8Decode(bytes[i..end]) catch 0xFFFD;
        try f(ctx, cp, bytes[i..end]);
        i = end;
    }
}

/// Трансформация codepoint → codepoint, с fallback замены по таблице
fn strMapCp(vm: *VM, s: *object.Str, comptime map: fn (u21) u21) !Obj {
    var out: std.ArrayList(u8) = .empty;
    const Ctx = struct { out: *std.ArrayList(u8), gpa: std.mem.Allocator };
    var ctx = Ctx{ .out = &out, .gpa = vm.rt.gpa };
    try eachCp(s.bytes, &ctx, struct {
        fn f(c: *Ctx, cp: u21, raw: []const u8) !void {
            const mapped = map(cp);
            if (mapped == cp) {
                try c.out.appendSlice(c.gpa, raw);
            } else {
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(mapped, &buf) catch 0;
                try c.out.appendSlice(c.gpa, buf[0..n]);
            }
        }
    }.f);
    return vm.rt.newStrOwned(try out.toOwnedSlice(vm.rt.gpa));
}

fn mapUpper(cp: u21) u21 {
    return switch (cp) {
        'a'...'z' => cp - 32,
        0xE0...0xF6, 0xF8...0xFE => cp - 32, // à-þ (latin-1)
        0x430...0x44F => cp - 32, // а-я
        0x451 => 0x401, // ё
        else => cp,
    };
}

fn mapLower(cp: u21) u21 {
    return switch (cp) {
        'A'...'Z' => cp + 32,
        0xC0...0xD6, 0xD8...0xDE => cp + 32,
        0x410...0x42F => cp + 32,
        0x401 => 0x451,
        else => cp,
    };
}

// str.__format__: non-str ops через formatSimple (поддерживает align/width/prec)
fn str___format__(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    if (args.len < 2 or args[1].v != .str) {
        try v.raiseStr("TypeError", "__format__() argument 1 must be str");
        return error.PyExc;
    }
    const spec = args[1].v.str.bytes;
    // осмысленный тип для str — только 's' или пусто
    return v.formatSimple(args[0], spec);
}

fn str_upper(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    return strMapCp(v, try selfStr(args, v), mapUpper);
}

fn str_lower(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    return strMapCp(v, try selfStr(args, v), mapLower);
}

fn str_swapcase(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const s = try selfStr(args, v);
    var out: std.ArrayList(u8) = .empty;
    const Ctx = struct { out: *std.ArrayList(u8), gpa: std.mem.Allocator };
    var ctx = Ctx{ .out = &out, .gpa = v.rt.gpa };
    try eachCp(s.bytes, &ctx, struct {
        fn f(c: *Ctx, cp: u21, raw: []const u8) !void {
            const lo = mapLower(cp);
            const up = mapUpper(cp);
            const mapped: u21 = if (lo != cp) lo else if (up != cp) up else cp;
            if (mapped == cp) {
                try c.out.appendSlice(c.gpa, raw);
            } else {
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(mapped, &buf) catch 0;
                try c.out.appendSlice(c.gpa, buf[0..n]);
            }
        }
    }.f);
    return v.rt.newStrOwned(try out.toOwnedSlice(v.rt.gpa));
}

fn isPySpace(cp: u21) bool {
    return switch (cp) {
        ' ', '\t', '\n', '\r', 0x0B, 0x0C, 0x1C, 0x1D, 0x1E, 0x1F, 0x85, 0xA0 => true,
        0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000 => true,
        else => false,
    };
}

fn isAlpha(cp: u21) bool {
    return std.ascii.isAlphabetic(@as(u8, @truncate(cp))) and cp < 128 or (cp >= 0x410 and cp <= 0x44F) or cp == 0x401 or cp == 0x451 or (cp >= 0xC0 and cp <= 0x2AF and cp != 0xD7 and cp != 0xF7);
}

fn isDigit(cp: u21) bool {
    return cp >= '0' and cp <= '9';
}

fn stripImpl(vm: *VM, s: *object.Str, chars: ?[]const u8, comptime left: bool, comptime right: bool) !Obj {
    const b = s.bytes;
    var start: usize = 0;
    var end: usize = b.len;
    // собрать набор codepoint'ов chars
    var cps: std.ArrayList(u21) = .empty;
    if (chars) |cs| {
        var i: usize = 0;
        while (i < cs.len) {
            const l = std.unicode.utf8ByteSequenceLength(cs[i]) catch 1;
            const en = @min(i + l, cs.len);
            const cp = std.unicode.utf8Decode(cs[i..en]) catch 0xFFFD;
            try cps.append(vm.rt.gpa, cp);
            i = en;
        }
    }
    const inSet = struct {
        fn f(set: []const u21, cp: u21, default_ws: bool) bool {
            if (set.len == 0) return isPySpace(cp) == default_ws;
            for (set) |x| {
                if (x == cp) return true;
            }
            return false;
        }
    }.f;
    if (left) {
        while (start < b.len) {
            const l = std.unicode.utf8ByteSequenceLength(b[start]) catch 1;
            const en = @min(start + l, b.len);
            const cp = std.unicode.utf8Decode(b[start..en]) catch 0xFFFD;
            if (chars == null) {
                if (!isPySpace(cp)) break;
            } else {
                if (!inSet(cps.items, cp, false)) break;
            }
            start = en;
        }
    }
    if (right) {
        while (end > start) {
            // назад на один codepoint
            var bs = end - 1;
            while (bs > start and (b[bs] & 0xC0) == 0x80) bs -= 1;
            const cp = std.unicode.utf8Decode(b[bs..end]) catch 0xFFFD;
            if (chars == null) {
                if (!isPySpace(cp)) break;
            } else {
                if (!inSet(cps.items, cp, false)) break;
            }
            end = bs;
        }
    }
    if (start == 0 and end == b.len) return vm.rt.newStr(b);
    return vm.rt.newStr(b[start..end]);
}

fn str_strip(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const s = try selfStr(args, v);
    const chars: ?[]const u8 = if (args.len >= 2 and args[1].v == .str) args[1].v.str.bytes else null;
    return stripImpl(v, s, chars, true, true);
}

fn str_lstrip(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const s = try selfStr(args, v);
    const chars: ?[]const u8 = if (args.len >= 2 and args[1].v == .str) args[1].v.str.bytes else null;
    return stripImpl(v, s, chars, true, false);
}

fn str_rstrip(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const s = try selfStr(args, v);
    const chars: ?[]const u8 = if (args.len >= 2 and args[1].v == .str) args[1].v.str.bytes else null;
    return stripImpl(v, s, chars, false, true);
}

/// split/replace/find — по БАЙТАМ UTF-8: корректно для подстрок-границ codepoint'ов
fn str_split(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const s = try selfStr(args, v);
    const maxsplit: i64 = if (args.len >= 3) try indexLike(v, args[2]) else -1;
    const out = try v.rt.newList();
    if (args.len >= 2 and args[1].v == .str) {
        const sep = args[1].v.str.bytes;
        if (sep.len == 0) {
            try v.raiseStr("ValueError", "empty separator");
            return error.PyExc;
        }
        var rest = s.bytes;
        var n: i64 = 0;
        while (maxsplit < 0 or n < maxsplit) {
            if (std.mem.indexOf(u8, rest, sep)) |idx| {
                try out.v.list.items.append(v.rt.gpa, try v.rt.newStr(rest[0..idx]));
                rest = rest[idx + sep.len ..];
                n += 1;
            } else break;
        }
        try out.v.list.items.append(v.rt.gpa, try v.rt.newStr(rest));
    } else {
        // split по whitespace с склейкой
        var i: usize = 0;
        const b = s.bytes;
        var n: i64 = 0;
        while (true) {
            while (i < b.len and isPySpaceByte(b[i])) i += 1;
            if (i >= b.len) break;
            const start = i;
            while (i < b.len and !isPySpaceByte(b[i])) i += 1;
            try out.v.list.items.append(v.rt.gpa, try v.rt.newStr(b[start..i]));
            n += 1;
            if (maxsplit >= 0 and n > maxsplit) break;
        }
        if (maxsplit >= 0 and n > maxsplit) {
            // последний элемент включает остаток
            const last = out.v.list.items.pop().?;
            _ = last;
            // пересобрать: пропустить whitespace, остаток одной строкой
            while (i < b.len and isPySpaceByte(b[i])) i += 1;
            try out.v.list.items.append(v.rt.gpa, try v.rt.newStr(b[i..]));
        }
    }
    return out;
}

fn isPySpaceByte(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0B or c == 0x0C;
}

fn str_rsplit(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const s = try selfStr(args, v);
    const maxsplit: i64 = if (args.len >= 3) try indexLike(v, args[2]) else -1;
    const out = try v.rt.newList();
    if (args.len >= 2 and args[1].v == .str) {
        const sep = args[1].v.str.bytes;
        if (sep.len == 0) {
            try v.raiseStr("ValueError", "empty separator");
            return error.PyExc;
        }
        // собрать все разбиения, взять хвост
        var parts: std.ArrayList([]const u8) = .empty;
        var rest = s.bytes;
        while (std.mem.indexOf(u8, rest, sep)) |idx| {
            try parts.append(v.rt.gpa, rest[0..idx]);
            rest = rest[idx + sep.len ..];
        }
        try parts.append(v.rt.gpa, rest);
        if (maxsplit < 0 or parts.items.len - 1 <= @as(usize, @intCast(maxsplit))) {
            for (parts.items) |p| try out.v.list.items.append(v.rt.gpa, try v.rt.newStr(p));
        } else {
            const ms: usize = @intCast(maxsplit);
            const head_cnt = parts.items.len - ms;
            // head_cnt частей склеиваем обратно через sep
            var head: std.ArrayList(u8) = .empty;
            for (parts.items[0..head_cnt], 0..) |p, i| {
                if (i > 0) try head.appendSlice(v.rt.gpa, sep);
                try head.appendSlice(v.rt.gpa, p);
            }
            try out.v.list.items.append(v.rt.gpa, try v.rt.newStrOwned(try head.toOwnedSlice(v.rt.gpa)));
            for (parts.items[head_cnt..]) |p| try out.v.list.items.append(v.rt.gpa, try v.rt.newStr(p));
        }
    } else {
        // whitespace rsplit — редкий случай, делаем через полный split и хвост
        const full = try str_split(v, &.{ args[0] }, null);
        const items = full.v.list.items.items;
        if (maxsplit < 0 or items.len - 1 <= @as(usize, @intCast(maxsplit))) {
            return full;
        }
        const ms: usize = @intCast(maxsplit);
        const head_cnt = items.len - ms;
        var head: std.ArrayList(u8) = .empty;
        for (items[0..head_cnt], 0..) |p, i| {
            if (i > 0) try head.append(v.rt.gpa, ' ');
            try head.appendSlice(v.rt.gpa, p.v.str.bytes);
        }
        try out.v.list.items.append(v.rt.gpa, try v.rt.newStrOwned(try head.toOwnedSlice(v.rt.gpa)));
        for (items[head_cnt..]) |p| try out.v.list.items.append(v.rt.gpa, p);
    }
    return out;
}

fn str_splitlines(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const s = try selfStr(args, v);
    const keepends = args.len >= 2 and args[1].isTruthy();
    const out = try v.rt.newList();
    const b = s.bytes;
    var i: usize = 0;
    while (i < b.len) {
        const start = i;
        while (i < b.len and b[i] != '\n' and b[i] != '\r') i += 1;
        var line_end = i;
        var next = i;
        if (i < b.len) {
            if (b[i] == '\r' and i + 1 < b.len and b[i + 1] == '\n') {
                if (keepends) {
                    line_end = i + 2;
                }
                next = i + 2;
            } else {
                if (keepends) line_end = i + 1;
                next = i + 1;
            }
        }
        try out.v.list.items.append(v.rt.gpa, try v.rt.newStr(b[start..line_end]));
        i = next;
    }
    return out;
}

fn str_join(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const s = try selfStr(args, v);
    if (args.len < 2) return typeErr(v, "join() takes exactly one argument", .{});
    const items = try vm.collectSequence(args[1], null);
    var out: std.ArrayList(u8) = .empty;
    for (items, 0..) |item, i| {
        if (item.v != .str) {
            try v.raiseFmt("TypeError", "sequence item {d}: expected str instance, {s} found", .{ i, item.ty.name });
            return error.PyExc;
        }
        if (i > 0) try out.appendSlice(v.rt.gpa, s.bytes);
        try out.appendSlice(v.rt.gpa, item.v.str.bytes);
    }
    return v.rt.newStrOwned(try out.toOwnedSlice(v.rt.gpa));
}

fn str_replace(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const s = try selfStr(args, v);
    if (args.len < 3) return typeErr(v, "replace() needs at least 2 arguments", .{});
    const old = args[1].v.str.bytes;
    const new = args[2].v.str.bytes;
    const maxcount: i64 = if (args.len >= 4) try indexLike(v, args[3]) else -1;
    if (old.len == 0) {
        // вставка между символами (как CPython)
        var out: std.ArrayList(u8) = .empty;
        var n: i64 = 0;
        try out.appendSlice(v.rt.gpa, new);
        n += 1;
        for (s.bytes) |c| {
            try out.append(v.rt.gpa, c);
            if (maxcount < 0 or n < maxcount + 1) {
                try out.appendSlice(v.rt.gpa, new);
                n += 1;
            }
        }
        return v.rt.newStrOwned(try out.toOwnedSlice(v.rt.gpa));
    }
    var out: std.ArrayList(u8) = .empty;
    var rest = s.bytes;
    var n: i64 = 0;
    while (maxcount < 0 or n < maxcount) {
        if (std.mem.indexOf(u8, rest, old)) |idx| {
            try out.appendSlice(v.rt.gpa, rest[0..idx]);
            try out.appendSlice(v.rt.gpa, new);
            rest = rest[idx + old.len ..];
            n += 1;
        } else break;
    }
    try out.appendSlice(v.rt.gpa, rest);
    return v.rt.newStrOwned(try out.toOwnedSlice(v.rt.gpa));
}

/// Позиция подстроки в CODEPOINT'ах
fn findCp(hay: *object.Str, needle: []const u8, from_end: bool) ?usize {
    const b = hay.bytes;
    const idx: ?usize = if (from_end) std.mem.lastIndexOf(u8, b, needle) else std.mem.indexOf(u8, b, needle);
    if (idx) |i| {
        return object.Str.countCp(b[0..i]);
    }
    return null;
}

fn str_find(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const s = try selfStr(args, v);
    const needle = args[1].v.str.bytes;
    const cp = findCp(s, needle, false) orelse return v.rt.newInt(-1);
    return v.rt.newInt(@intCast(cp));
}

fn str_rfind(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const s = try selfStr(args, v);
    const needle = args[1].v.str.bytes;
    const cp = findCp(s, needle, true) orelse return v.rt.newInt(-1);
    return v.rt.newInt(@intCast(cp));
}

fn str_index(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const s = try selfStr(args, v);
    const needle = args[1].v.str.bytes;
    const cp = findCp(s, needle, false) orelse {
        try v.raiseStr("ValueError", "substring not found");
        return error.PyExc;
    };
    return v.rt.newInt(@intCast(cp));
}

fn str_rindex(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const s = try selfStr(args, v);
    const needle = args[1].v.str.bytes;
    const cp = findCp(s, needle, true) orelse {
        try v.raiseStr("ValueError", "substring not found");
        return error.PyExc;
    };
    return v.rt.newInt(@intCast(cp));
}

fn str_count(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const s = try selfStr(args, v);
    const needle = args[1].v.str.bytes;
    if (needle.len == 0) return v.rt.newInt(@intCast(s.cp_len + 1));
    var n: usize = 0;
    var rest = s.bytes;
    while (std.mem.indexOf(u8, rest, needle)) |idx| {
        n += 1;
        rest = rest[idx + needle.len ..];
    }
    return v.rt.newInt(@intCast(n));
}

fn hasAffix(s: *object.Str, aff: []const u8, comptime prefix: bool) bool {
    if (aff.len > s.bytes.len) return false;
    if (prefix) return std.mem.eql(u8, s.bytes[0..aff.len], aff);
    return std.mem.eql(u8, s.bytes[s.bytes.len - aff.len ..], aff);
}

fn affixCheck(vm: *VM, args: []const Obj, comptime prefix: bool) anyerror!Obj {
    const s = try selfStr(args, vm);
    const arg = args[1];
    var result = false;
    if (arg.v == .str) {
        result = hasAffix(s, arg.v.str.bytes, prefix);
    } else if (arg.v == .tuple) {
        for (arg.v.tuple) |t| {
            if (t.v != .str) return typeErr(vm, "a tuple of str is required", .{});
            if (hasAffix(s, t.v.str.bytes, prefix)) result = true;
        }
    } else {
        return typeErr(vm, "startswith/endswith first arg must be str or a tuple of str", .{});
    }
    return vm.rt.newBool(result);
}

fn str_startswith(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    return affixCheck(vm, args, true);
}

fn str_endswith(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    return affixCheck(vm, args, false);
}

fn str_encode(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const s = try selfStr(args, v);
    const enc: []const u8 = if (args.len >= 2 and args[1].v == .str) args[1].v.str.bytes else "utf-8";
    return encodeStr(v, s.bytes, enc);
}

pub fn encodeStr(vm: *VM, bytes: []const u8, enc: []const u8) anyerror!Obj {
    if (asciiEqlIgnoreCase(enc, "utf-8") or asciiEqlIgnoreCase(enc, "utf8")) {
        return vm.rt.newBytes(bytes);
    }
    if (asciiEqlIgnoreCase(enc, "ascii")) {
        for (bytes) |c| {
            if (c >= 128) {
                try vm.raiseStr("UnicodeEncodeError", "'ascii' codec can't encode character");
                return error.PyExc;
            }
        }
        return vm.rt.newBytes(bytes);
    }
    if (asciiEqlIgnoreCase(enc, "latin-1") or asciiEqlIgnoreCase(enc, "latin1") or asciiEqlIgnoreCase(enc, "iso-8859-1")) {
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < bytes.len) {
            const l = std.unicode.utf8ByteSequenceLength(bytes[i]) catch 1;
            const end = @min(i + l, bytes.len);
            const cp = std.unicode.utf8Decode(bytes[i..end]) catch 0xFFFD;
            if (cp > 255) {
                try vm.raiseStr("UnicodeEncodeError", "'latin-1' codec can't encode character");
                return error.PyExc;
            }
            try out.append(vm.rt.gpa, @intCast(cp));
            i = end;
        }
        return vm.rt.newBytesOwned(try out.toOwnedSlice(vm.rt.gpa));
    }
    try vm.raiseFmt("LookupError", "unknown encoding: {s}", .{enc});
    return error.PyExc;
}

pub fn asciiEqlIgnoreCase(a: []const u8, b: []const u8) bool {
    // сравнение имён кодировок: игнорируем регистр, '-' и '_'
    var ia: usize = 0;
    var ib: usize = 0;
    while (true) {
        while (ia < a.len and (a[ia] == '-' or a[ia] == '_')) ia += 1;
        while (ib < b.len and (b[ib] == '-' or b[ib] == '_')) ib += 1;
        if (ia >= a.len and ib >= b.len) return true;
        if (ia >= a.len or ib >= b.len) return false;
        if (std.ascii.toLower(a[ia]) != std.ascii.toLower(b[ib])) return false;
        ia += 1;
        ib += 1;
    }
}

// ============================================================
// str.format — мини-мачинири format-строки CPython
// ============================================================

fn str_format(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    const v: *VM = vm;
    const s = try selfStr(args, v);
    return formatStringImpl(v, s.bytes, args[1..], kw);
}

fn str_format_map(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const s = try selfStr(args, v);
    if (args.len < 2 or args[1].v != .dict) return typeErr(v, "format_map() argument must be a dict", .{});
    return formatMapImpl(v, s.bytes, args[1].v.dict);
}

fn str_zfill(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const s = try selfStr(args, v);
    const width = try indexLike(v, args[1]);
    return padStr(v, s.bytes, width, '0', .left);
}

const PadMode = enum { left, right, center };

fn padStr(vm: *VM, bytes: []const u8, width: i64, fill: u8, mode: PadMode) anyerror!Obj {
    const cp_len = object.Str.countCp(bytes);
    const w: usize = if (width <= 0) 0 else @intCast(width);
    if (cp_len >= w) return vm.rt.newStr(bytes);
    const pad_total = w - cp_len;
    var out: std.ArrayList(u8) = .empty;
    var lp: usize = 0;
    var rp: usize = 0;
    switch (mode) {
        .left => rp = pad_total, // rjust: padding слева → wait
        .right => lp = pad_total,
        .center => {
            lp = pad_total / 2;
            rp = pad_total - lp;
        },
    }
    // rjust → pad слева; ljust → pad справа; zfill → pad слева (после знака)
    if (mode == .left) {
        // zfill / rjust: pad слева
        if (fill == '0' and bytes.len > 0 and (bytes[0] == '+' or bytes[0] == '-')) {
            try out.append(vm.rt.gpa, bytes[0]);
            try out.appendNTimes(vm.rt.gpa, fill, pad_total);
            try out.appendSlice(vm.rt.gpa, bytes[1..]);
        } else {
            try out.appendNTimes(vm.rt.gpa, fill, pad_total);
            try out.appendSlice(vm.rt.gpa, bytes);
        }
    } else if (mode == .right) {
        try out.appendSlice(vm.rt.gpa, bytes);
        try out.appendNTimes(vm.rt.gpa, fill, pad_total);
    } else {
        try out.appendNTimes(vm.rt.gpa, fill, lp);
        try out.appendSlice(vm.rt.gpa, bytes);
        try out.appendNTimes(vm.rt.gpa, fill, rp);
    }
    return vm.rt.newStrOwned(try out.toOwnedSlice(vm.rt.gpa));
}

fn str_center(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const s = try selfStr(args, v);
    const width = try indexLike(v, args[1]);
    const fill: u8 = if (args.len >= 3 and args[2].v == .str and args[2].v.str.bytes.len == 1) args[2].v.str.bytes[0] else ' ';
    return padStr(v, s.bytes, width, fill, .center);
}

fn str_ljust(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const s = try selfStr(args, v);
    const width = try indexLike(v, args[1]);
    const fill: u8 = if (args.len >= 3 and args[2].v == .str and args[2].v.str.bytes.len == 1) args[2].v.str.bytes[0] else ' ';
    return padStr(v, s.bytes, width, fill, .right);
}

fn str_rjust(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const s = try selfStr(args, v);
    const width = try indexLike(v, args[1]);
    const fill: u8 = if (args.len >= 3 and args[2].v == .str and args[2].v.str.bytes.len == 1) args[2].v.str.bytes[0] else ' ';
    return padStr(v, s.bytes, width, fill, .left);
}

fn str_partition(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const s = try selfStr(args, v);
    const sep = args[1].v.str.bytes;
    if (std.mem.indexOf(u8, s.bytes, sep)) |idx| {
        return v.rt.newTuple(&.{ try v.rt.newStr(s.bytes[0..idx]), try v.rt.newStr(sep), try v.rt.newStr(s.bytes[idx + sep.len ..]) });
    }
    return v.rt.newTuple(&.{ try v.rt.newStr(s.bytes), try v.rt.newStr(""), try v.rt.newStr("") });
}

fn str_rpartition(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const s = try selfStr(args, v);
    const sep = args[1].v.str.bytes;
    if (std.mem.lastIndexOf(u8, s.bytes, sep)) |idx| {
        return v.rt.newTuple(&.{ try v.rt.newStr(s.bytes[0..idx]), try v.rt.newStr(sep), try v.rt.newStr(s.bytes[idx + sep.len ..]) });
    }
    return v.rt.newTuple(&.{ try v.rt.newStr(""), try v.rt.newStr(""), try v.rt.newStr(s.bytes) });
}

fn str_removeprefix(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const s = try selfStr(args, v);
    const p = args[1].v.str.bytes;
    if (hasAffix(s, p, true)) return v.rt.newStr(s.bytes[p.len..]);
    return v.rt.newStr(s.bytes);
}

fn str_removesuffix(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const s = try selfStr(args, v);
    const p = args[1].v.str.bytes;
    if (p.len > 0 and hasAffix(s, p, false)) return v.rt.newStr(s.bytes[0 .. s.bytes.len - p.len]);
    return v.rt.newStr(s.bytes);
}

fn str_expandtabs(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const s = try selfStr(args, v);
    const tabsize: usize = if (args.len >= 2) @intCast(@max(0, try indexLike(v, args[1]))) else 8;
    var out: std.ArrayList(u8) = .empty;
    var col: usize = 0;
    for (s.bytes) |c| {
        if (c == '\t') {
            const n = if (tabsize == 0) 0 else tabsize - (col % tabsize);
            try out.appendNTimes(v.rt.gpa, ' ', n);
            col += n;
        } else {
            try out.append(v.rt.gpa, c);
            if (c == '\n' or c == '\r') col = 0 else col += 1;
        }
    }
    return v.rt.newStrOwned(try out.toOwnedSlice(v.rt.gpa));
}

fn strPred(vm: *VM, s: *object.Str, comptime pred: fn (u21) bool) anyerror!Obj {
    if (s.bytes.len == 0) return vm.rt.false_obj;
    var i: usize = 0;
    const b = s.bytes;
    while (i < b.len) {
        const l = std.unicode.utf8ByteSequenceLength(b[i]) catch 1;
        const end = @min(i + l, b.len);
        const cp = std.unicode.utf8Decode(b[i..end]) catch 0xFFFD;
        if (!pred(cp)) return vm.rt.false_obj;
        i = end;
    }
    return vm.rt.true_obj;
}

fn str_isdigit(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    return strPred(v, try selfStr(args, v), isDigit);
}

fn predAlpha(cp: u21) bool {
    return (cp < 128 and std.ascii.isAlphabetic(@intCast(cp))) or (cp >= 0x410 and cp <= 0x44F) or cp == 0x401 or cp == 0x451 or (cp >= 0xC0 and cp <= 0x2AF and cp != 0xD7 and cp != 0xF7);
}

fn predAlnum(cp: u21) bool {
    return predAlpha(cp) or isDigit(cp);
}

fn predSpace(cp: u21) bool {
    return isPySpace(cp);
}

fn predPrintable(cp: u21) bool {
    if (cp < 32 or cp == 0x7F) return cp == ' ';
    if (isPySpace(cp) and cp != ' ') return false;
    return true;
}

fn str_isalpha(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    return strPred(v, try selfStr(args, v), predAlpha);
}

fn str_isalnum(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    return strPred(v, try selfStr(args, v), predAlnum);
}

fn str_isspace(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    return strPred(v, try selfStr(args, v), predSpace);
}

fn str_isprintable(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const s = try selfStr(args, v);
    if (s.bytes.len == 0) return v.rt.true_obj;
    return strPred(v, s, predPrintable);
}

fn str_isupper(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const s = try selfStr(args, v);
    var has_cased = false;
    var i: usize = 0;
    const b = s.bytes;
    while (i < b.len) {
        const l = std.unicode.utf8ByteSequenceLength(b[i]) catch 1;
        const end = @min(i + l, b.len);
        const cp = std.unicode.utf8Decode(b[i..end]) catch 0xFFFD;
        if (mapLower(cp) != cp) {
            has_cased = true;
        } else if (mapUpper(cp) != cp) {
            return v.rt.false_obj;
        }
        i = end;
    }
    return v.rt.newBool(has_cased);
}

fn str_islower(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const s = try selfStr(args, v);
    var has_cased = false;
    var i: usize = 0;
    const b = s.bytes;
    while (i < b.len) {
        const l = std.unicode.utf8ByteSequenceLength(b[i]) catch 1;
        const end = @min(i + l, b.len);
        const cp = std.unicode.utf8Decode(b[i..end]) catch 0xFFFD;
        if (mapUpper(cp) != cp) {
            has_cased = true;
        } else if (mapLower(cp) != cp) {
            return v.rt.false_obj;
        }
        i = end;
    }
    return v.rt.newBool(has_cased);
}

fn str_title(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const s = try selfStr(args, v);
    var out: std.ArrayList(u8) = .empty;
    var prev_cased = false;
    var i: usize = 0;
    const b = s.bytes;
    while (i < b.len) {
        const l = std.unicode.utf8ByteSequenceLength(b[i]) catch 1;
        const end = @min(i + l, b.len);
        const raw = b[i..end];
        var cp = std.unicode.utf8Decode(raw) catch 0xFFFD;
        const is_cased = mapUpper(cp) != cp or mapLower(cp) != cp;
        if (!prev_cased and is_cased) {
            cp = mapUpper(cp);
        } else if (prev_cased) {
            cp = mapLower(cp);
        }
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch 0;
        if (n > 0) try out.appendSlice(v.rt.gpa, buf[0..n]) else try out.appendSlice(v.rt.gpa, raw);
        prev_cased = is_cased or isDigit(cp);
        i = end;
    }
    return v.rt.newStrOwned(try out.toOwnedSlice(v.rt.gpa));
}

fn str_capitalize(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const s = try selfStr(args, v);
    if (s.bytes.len == 0) return v.rt.newStr("");
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    const b = s.bytes;
    var first = true;
    while (i < b.len) {
        const l = std.unicode.utf8ByteSequenceLength(b[i]) catch 1;
        const end = @min(i + l, b.len);
        const raw = b[i..end];
        var cp = std.unicode.utf8Decode(raw) catch 0xFFFD;
        if (first) {
            cp = mapUpper(cp);
            first = false;
        } else {
            cp = mapLower(cp);
        }
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch 0;
        if (n > 0) try out.appendSlice(v.rt.gpa, buf[0..n]) else try out.appendSlice(v.rt.gpa, raw);
        i = end;
    }
    return v.rt.newStrOwned(try out.toOwnedSlice(v.rt.gpa));
}

fn str_istitle(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const s = try selfStr(args, v);
    if (s.bytes.len == 0) return v.rt.false_obj;
    var prev_cased = false;
    var has_cased = false;
    var i: usize = 0;
    const b = s.bytes;
    while (i < b.len) {
        const l = std.unicode.utf8ByteSequenceLength(b[i]) catch 1;
        const end = @min(i + l, b.len);
        const cp = std.unicode.utf8Decode(b[i..end]) catch 0xFFFD;
        const is_cased = mapUpper(cp) != cp or mapLower(cp) != cp;
        if (!prev_cased) {
            if (is_cased and mapUpper(cp) == cp and mapLower(cp) != cp) {
                return v.rt.false_obj; // строчная на старте слова
            }
        } else {
            if (is_cased and mapUpper(cp) != cp) {
                return v.rt.false_obj; // заглавная не в начале слова
            }
        }
        if (is_cased) has_cased = true;
        prev_cased = is_cased or isDigit(cp);
        i = end;
    }
    return v.rt.newBool(has_cased);
}

fn str_isidentifier(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const s = try selfStr(args, v);
    if (s.bytes.len == 0) return v.rt.false_obj;
    var i: usize = 0;
    const b = s.bytes;
    var first = true;
    while (i < b.len) {
        const l = std.unicode.utf8ByteSequenceLength(b[i]) catch 1;
        const end = @min(i + l, b.len);
        const cp = std.unicode.utf8Decode(b[i..end]) catch 0xFFFD;
        if (first) {
            if (!predAlpha(cp) and cp != '_') return v.rt.false_obj;
            first = false;
        } else {
            if (!predAlnum(cp) and cp != '_') return v.rt.false_obj;
        }
        i = end;
    }
    return v.rt.true_obj;
}

fn str_getitem_dunder(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    return vm.pyGetItem(args[0], args[1]);
}

fn str_maketrans(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const d = try v.rt.newDictObj();
    if (args.len == 2 and args[1].v == .dict) {
        return args[1];
    }
    if (args.len >= 3) {
        const from_s = args[1].v.str;
        const to_s = args[2].v.str;
        if (from_s.cp_len != to_s.cp_len) {
            try v.raiseStr("ValueError", "the first two maketrans arguments must have equal length");
            return error.PyExc;
        }
        var i: usize = 0;
        while (i < from_s.cp_len) : (i += 1) {
            const k = try v.rt.newInt(from_s.codepointAt(i).?);
            const val = try v.rt.newInt(to_s.codepointAt(i).?);
            const h = try vm.pyHash(k);
            try d.v.dict.setWithHash(vm, k, val, h);
        }
        if (args.len >= 4 and args[3].v == .str) {
            const del = args[3].v.str;
            var j: usize = 0;
            while (j < del.cp_len) : (j += 1) {
                const k = try v.rt.newInt(del.codepointAt(j).?);
                const h = try vm.pyHash(k);
                try d.v.dict.setWithHash(vm, k, v.rt.newNone(), h);
            }
        }
    }
    return d;
}

fn str_translate(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const s = try selfStr(args, v);
    if (args.len < 2 or args[1].v != .dict) return typeErr(v, "translate() argument must be a mapping", .{});
    const table = args[1].v.dict;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    const b = s.bytes;
    outer: while (i < b.len) {
        const l = std.unicode.utf8ByteSequenceLength(b[i]) catch 1;
        const end = @min(i + l, b.len);
        const raw = b[i..end];
        const cp = std.unicode.utf8Decode(raw) catch 0xFFFD;
        const k = try v.rt.newInt(cp);
        const h = try vm.pyHash(k);
        if (try table.getWithHash(vm, k, h)) |val| {
            switch (val.v) {
                .none => {},
                .int => |iv| {
                    var buf: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(@intCast(@max(0, iv)), &buf) catch 0;
                    try out.appendSlice(v.rt.gpa, buf[0..n]);
                },
                .str => |sv| try out.appendSlice(v.rt.gpa, sv.bytes),
                else => {},
            }
            i = end;
            continue :outer;
        }
        try out.appendSlice(v.rt.gpa, raw);
        i = end;
    }
    return v.rt.newStrOwned(try out.toOwnedSlice(v.rt.gpa));
}

// ============================================================
// str.format machinery (PEP 3101, подмножество)
// ============================================================

const FmtGetter = struct {
    args: []const Obj,
    kw: ?KwArgs,
    dict: ?*Dict,
};

fn fmtLookup(vm: *VM, g: *const FmtGetter, name: []const u8, num: *FmtNumbering) anyerror!Obj {
    if (name.len == 0) {
        if (num.mode == .manual) {
            try vm.raiseStr("ValueError", "cannot switch from manual field specification to automatic field numbering");
            return error.PyExc;
        }
        num.mode = .auto;
        const i = num.auto_idx;
        num.auto_idx += 1;
        if (g.dict != null) {
            try vm.raiseStr("ValueError", "Format string contains positional fields");
            return error.PyExc;
        }
        if (i >= g.args.len) {
            try vm.raiseStr("IndexError", "Replacement index out of range");
            return error.PyExc;
        }
        return g.args[i];
    }
    // число → positional (manual numbering)
    var all_digits = true;
    for (name) |c| {
        if (c < '0' or c > '9') all_digits = false;
    }
    if (all_digits) {
        if (g.dict != null) {
            // format_map: числовые ключи — как строки
        } else {
            if (num.mode == .auto) {
                try vm.raiseStr("ValueError", "cannot switch from automatic field numbering to manual field specification");
                return error.PyExc;
            }
            num.mode = .manual;
            const i = std.fmt.parseInt(usize, name, 10) catch {
                try vm.raiseFmt("IndexError", "Replacement index {s} out of range", .{name});
                return error.PyExc;
            };
            if (i >= g.args.len) {
                try vm.raiseFmt("IndexError", "Replacement index {d} out of range", .{i});
                return error.PyExc;
            }
            return g.args[i];
        }
    }
    if (g.dict) |d| {
        const kobj = try vm.rt.newStr(name);
        const h = try vm.pyHash(kobj);
        if (try d.getWithHash(vm, kobj, h)) |x| return x;
        const eo = try vm.mkExc(vm.excType("KeyError"), &.{kobj});
        try vm.raiseObj(eo);
        return error.PyExc;
    }
    if (g.kw) |k| {
        if (k.get(name)) |x| return x;
    }
    const eo = try vm.mkExc(vm.excType("KeyError"), &.{try vm.rt.newStr(name)});
    try vm.raiseObj(eo);
    return error.PyExc;
}

fn formatFieldParse(field: []const u8) struct { name: []const u8, conv: u8, spec: []const u8 } {
    var name = field;
    var conv: u8 = 0;
    var spec: []const u8 = "";
    if (std.mem.indexOfScalar(u8, field, ':')) |ci| {
        name = field[0..ci];
        spec = field[ci + 1 ..];
    }
    if (std.mem.indexOfScalar(u8, name, '!')) |bi| {
        const c = name[bi + 1 ..];
        if (c.len > 0) conv = c[0];
        name = name[0..bi];
    }
    return .{ .name = name, .conv = conv, .spec = spec };
}

/// доступ по цепочке ".attr" и "[idx]"
/// состояние нумерации полей для PEP 3101: auto ({}) и manual ({0}) нельзя смешивать
const FmtNumbering = struct {
    auto_idx: usize = 0,
    mode: enum { none, auto, manual } = .none,
};

fn fmtResolveChain(vm: *VM, base_name: []const u8, g: *const FmtGetter, num: *FmtNumbering) anyerror!Obj {
    // отделить первое имя до '.' или '['
    var end: usize = 0;
    while (end < base_name.len and base_name[end] != '.' and base_name[end] != '[') end += 1;
    var obj = try fmtLookup(vm, g, base_name[0..end], num);
    var rest = base_name[end..];
    while (rest.len > 0) {
        if (rest[0] == '.') {
            var j: usize = 1;
            while (j < rest.len and rest[j] != '.' and rest[j] != '[') j += 1;
            obj = try ops.pyGetAttr(vm, obj, rest[1..j]);
            rest = rest[j..];
        } else {
            const close = std.mem.indexOfScalar(u8, rest, ']') orelse {
                try vm.raiseStr("ValueError", "Missing ']' in format string");
                return error.PyExc;
            };
            const key_s = rest[1..close];
            var key_obj: Obj = undefined;
            if (key_s.len > 0 and std.fmt.parseInt(i64, key_s, 10) catch null != null) {
                key_obj = try vm.rt.newInt(std.fmt.parseInt(i64, key_s, 10) catch unreachable);
            } else {
                key_obj = try vm.rt.newStr(key_s);
            }
            obj = try vm.pyGetItem(obj, key_obj);
            rest = rest[close + 1 ..];
        }
    }
    return obj;
}

pub fn formatStringImpl(vm: *VM, fmt: []const u8, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    var out: std.ArrayList(u8) = .empty;
    var g = FmtGetter{ .args = args, .kw = kw, .dict = null };
    var num: FmtNumbering = .{};
    try formatWalk(vm, fmt, &out, &g, &num);
    return vm.rt.newStrOwned(try out.toOwnedSlice(vm.rt.gpa));
}

pub fn formatMapImpl(vm: *VM, fmt: []const u8, d: *Dict) anyerror!Obj {
    var out: std.ArrayList(u8) = .empty;
    var g = FmtGetter{ .args = &.{}, .kw = null, .dict = d };
    var num: FmtNumbering = .{};
    try formatWalk(vm, fmt, &out, &g, &num);
    return vm.rt.newStrOwned(try out.toOwnedSlice(vm.rt.gpa));
}

fn formatWalk(vm: *VM, fmt: []const u8, out: *std.ArrayList(u8), g: *const FmtGetter, num: *FmtNumbering) anyerror!void {
    var i: usize = 0;
    while (i < fmt.len) {
        const c = fmt[i];
        if (c == '{') {
            if (i + 1 < fmt.len and fmt[i + 1] == '{') {
                try out.append(vm.rt.gpa, '{');
                i += 2;
                continue;
            }
            const close_rel = findFieldEnd(fmt[i + 1 ..]) orelse {
                try vm.raiseStr("ValueError", "Single '{' encountered in format string");
                return error.PyExc;
            };
            const field = fmt[i + 1 .. i + 1 + close_rel];
            const fp = formatFieldParse(field);
            var obj = try fmtResolveChain(vm, fp.name, g, num);
            // конверсия
            switch (fp.conv) {
                'r' => obj = try ops.pyRepr(vm, obj),
                's' => obj = try ops.pyStr(vm, obj),
                'a' => {
                    const bltn_mod = @import("../builtins.zig");
                    obj = try bltn_mod.asciiOf(vm, obj);
                },
                0 => {},
                else => {
                    try vm.raiseStr("ValueError", "Unknown conversion specifier");
                    return error.PyExc;
                },
            }
            // спека может содержать вложенные поля
            var spec_processed: []const u8 = fp.spec;
            if (std.mem.indexOfScalar(u8, fp.spec, '{') != null) {
                var spec_out: std.ArrayList(u8) = .empty;
                // вложенные поля внутри спеки делят счётчик автонумерации с внешними (stringlib/format.h)
                try formatWalk(vm, fp.spec, &spec_out, g, num);
                spec_processed = spec_out.items;
            }
            const spec_obj = if (spec_processed.len == 0 and obj.v != .str) null else try vm.rt.newStr(spec_processed);
            const formatted = try vm.formatValue(obj, 0, spec_obj);
            try out.appendSlice(vm.rt.gpa, formatted.v.str.bytes);
            i = i + 1 + close_rel + 1;
        } else if (c == '}') {
            if (i + 1 < fmt.len and fmt[i + 1] == '}') {
                try out.append(vm.rt.gpa, '}');
                i += 2;
                continue;
            }
            try vm.raiseStr("ValueError", "Single '}' encountered in format string");
            return error.PyExc;
        } else {
            try out.append(vm.rt.gpa, c);
            i += 1;
        }
    }
}

/// найти конец поля с учётом вложенности
fn findFieldEnd(s: []const u8) ?usize {
    var depth: usize = 0;
    for (s, 0..) |c, i| {
        if (c == '{') depth += 1;
        if (c == '}') {
            if (depth == 0) return i;
            depth -= 1;
        }
    }
    return null;
}

// ============================================================
// list
// ============================================================

pub fn registerListMethods(rt: *Runtime) !void {
    const t = rt.list_t;
    try td(rt, t, "append", list_append);
    try td(rt, t, "extend", list_extend);
    try td(rt, t, "insert", list_insert);
    try td(rt, t, "remove", list_remove);
    try td(rt, t, "pop", list_pop);
    try td(rt, t, "clear", list_clear);
    try td(rt, t, "index", list_index);
    try td(rt, t, "count", list_count);
    try td(rt, t, "sort", list_sort);
    try td(rt, t, "reverse", list_reverse);
    try td(rt, t, "copy", list_copy);
    try td(rt, t, "__iadd__", list_iadd);
}

fn list_append(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const l = try selfList(args, v);
    try l.items.append(v.rt.gpa, args[1]);
    return v.rt.newNone();
}

fn list_extend(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const l = try selfList(args, v);
    if (args[1].v == .list and args[1].v.list == l) {
        // self-extend: копия
        const cp = try v.rt.gpa.alloc(Obj, l.items.items.len);
        @memcpy(cp, l.items.items);
        try l.items.appendSlice(v.rt.gpa, cp);
        return v.rt.newNone();
    }
    const it = try vm.pyIter(args[1]);
    while (try vm.pyNext(it)) |item| {
        try l.items.append(v.rt.gpa, item);
    }
    return v.rt.newNone();
}

fn list_insert(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const l = try selfList(args, v);
    var i = try indexLike(v, args[1]);
    const n: i64 = @intCast(l.items.items.len);
    if (i < 0) i = @max(0, i + n);
    if (i > n) i = n;
    try l.items.insert(v.rt.gpa, @intCast(i), args[2]);
    return v.rt.newNone();
}

fn list_remove(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const l = try selfList(args, v);
    for (l.items.items, 0..) |item, i| {
        if (try vm.pyEq(item, args[1])) {
            _ = l.items.orderedRemove(i);
            return v.rt.newNone();
        }
    }
    const r = try ops.pyRepr(v, args[1]);
    try v.raiseFmt("ValueError", "list.remove(x): x not in list ({s})", .{r.v.str.bytes});
    return error.PyExc;
}

fn list_pop(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const l = try selfList(args, v);
    if (l.items.items.len == 0) {
        try v.raiseStr("IndexError", "pop from empty list");
        return error.PyExc;
    }
    var i: i64 = @intCast(l.items.items.len - 1);
    if (args.len >= 2) {
        i = try indexLike(v, args[1]);
        const n: i64 = @intCast(l.items.items.len);
        if (i < 0) i += n;
        if (i < 0 or i >= n) {
            try v.raiseStr("IndexError", "pop index out of range");
            return error.PyExc;
        }
    }
    return l.items.orderedRemove(@intCast(i));
}

fn list_clear(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const l = try selfList(args, v);
    l.items.clearRetainingCapacity();
    return v.rt.newNone();
}

fn list_index(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const l = try selfList(args, v);
    const start: usize = if (args.len >= 3) @intCast(@max(0, try indexLike(v, args[2]))) else 0;
    const stop: usize = if (args.len >= 4) @intCast(@max(0, try indexLike(v, args[3]))) else l.items.items.len;
    var i = start;
    while (i < @min(stop, l.items.items.len)) : (i += 1) {
        if (try vm.pyEq(l.items.items[i], args[1])) return v.rt.newInt(@intCast(i));
    }
    try v.raiseStr("ValueError", "value is not in list");
    return error.PyExc;
}

fn list_count(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const l = try selfList(args, v);
    var n: usize = 0;
    for (l.items.items) |item| {
        if (try vm.pyEq(item, args[1])) n += 1;
    }
    return v.rt.newInt(@intCast(n));
}

fn list_sort(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    const v: *VM = vm;
    const l = try selfList(args, v);
    try bltn.sortItems(v, l.items.items, kwGet(kw, "key"));
    if (kwGet(kw, "reverse")) |rv| {
        if (rv.isTruthy()) std.mem.reverse(Obj, l.items.items);
    }
    return v.rt.newNone();
}

fn list_reverse(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const l = try selfList(args, v);
    std.mem.reverse(Obj, l.items.items);
    return v.rt.newNone();
}

fn list_copy(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const l = try selfList(args, v);
    return v.rt.newListFrom(l.items.items);
}

fn list_iadd(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    _ = try list_extend(v, args, null);
    return args[0];
}

// ============================================================
// dict
// ============================================================

pub fn registerDictMethods(rt: *Runtime) !void {
    const t = rt.dict_t;
    try td(rt, t, "get", dict_get);
    try td(rt, t, "keys", dict_keys);
    try td(rt, t, "values", dict_values);
    try td(rt, t, "items", dict_items);
    try td(rt, t, "pop", dict_pop);
    try td(rt, t, "popitem", dict_popitem);
    try td(rt, t, "setdefault", dict_setdefault);
    try td(rt, t, "update", dict_update);
    try td(rt, t, "clear", dict_clear);
    try td(rt, t, "copy", dict_copy);
    try td(rt, t, "fromkeys", dict_fromkeys);
    try td(rt, t, "__contains__", dict_contains);
    try td(rt, t, "__setitem__", dict_setitem);
    try td(rt, t, "__getitem__", dict_getitem);
    try td(rt, t, "__delitem__", dict_delitem);
    try td(rt, t, "__len__", dict_len);
    try td(rt, t, "__iter__", dict_iter_m);
}

fn dict_iter_m(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const d = try selfDict(args, v);
    return v.rt.newIter(.{ .dict_iter = .{ .d = d, .i = 0, .kind = .keys } });
}

fn dict_setitem(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const d = try selfDict(args, v);
    const h = try v.pyHash(args[1]);
    try d.setWithHash(v, args[1], args[2], h);
    return v.rt.newNone();
}

fn dict_getitem(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const d = try selfDict(args, v);
    const h = try v.pyHash(args[1]);
    if (try d.getWithHash(v, args[1], h)) |x| return x;
    const cls = v.excType("KeyError");
    const e = try v.rt.newExc(cls);
    const ka = try v.rt.gpa.alloc(Obj, 1);
    ka[0] = args[1];
    e.v.exc.args = ka;
    try v.raiseObj(e);
    return error.PyExc;
}

fn dict_delitem(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const d = try selfDict(args, v);
    const h = try v.pyHash(args[1]);
    _ = try d.delWithHash(v, args[1], h);
    return v.rt.newNone();
}

fn dict_len(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const d = try selfDict(args, v);
    return v.rt.newInt(@intCast(d.len()));
}

fn dict_get(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const d = try selfDict(args, v);
    const h = try vm.pyHash(args[1]);
    if (try d.getWithHash(vm, args[1], h)) |x| return x;
    if (args.len >= 3) return args[2];
    return v.rt.newNone();
}

fn dict_keys(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const d = try selfDict(args, v);
    return v.rt.newIter(.{ .dict_iter = .{ .d = d, .i = 0, .kind = .keys } });
}

fn dict_values(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const d = try selfDict(args, v);
    return v.rt.newIter(.{ .dict_iter = .{ .d = d, .i = 0, .kind = .values } });
}

fn dict_items(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const d = try selfDict(args, v);
    return v.rt.newIter(.{ .dict_iter = .{ .d = d, .i = 0, .kind = .items } });
}

fn dict_pop(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const d = try selfDict(args, v);
    const h = try vm.pyHash(args[1]);
    if (try d.getWithHash(vm, args[1], h)) |x| {
        _ = try d.delWithHash(vm, args[1], h);
        return x;
    }
    if (args.len >= 3) return args[2];
    const eo = try v.mkExc(v.excType("KeyError"), &.{args[1]});
    try v.raiseObj(eo);
    return error.PyExc;
}

fn dict_popitem(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const d = try selfDict(args, v);
    var i = d.entries.items.len;
    while (i > 0) {
        i -= 1;
        const e = &d.entries.items[i];
        if (e.key != null) {
            const k = e.key.?;
            const val = e.val.?;
            const h = try vm.pyHash(k);
            _ = try d.delWithHash(vm, k, h);
            return v.rt.newTuple(&.{ k, val });
        }
    }
    try v.raiseStr("KeyError", "popitem(): dictionary is empty");
    return error.PyExc;
}

fn dict_setdefault(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const d = try selfDict(args, v);
    const def: Obj = if (args.len >= 3) args[2] else v.rt.newNone();
    const h = try vm.pyHash(args[1]);
    if (try d.getWithHash(vm, args[1], h)) |x| return x;
    try d.setWithHash(vm, args[1], def, h);
    return def;
}

fn dict_update(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    const v: *VM = vm;
    const d = try selfDict(args, v);
    if (args.len >= 2) {
        const src = args[1];
        if (src.v == .dict) {
            var it = src.v.dict.iterAlive();
            while (it.next()) |e| {
                const h = try vm.pyHash(e.key.?);
                try d.setWithHash(vm, e.key.?, e.val.?, h);
            }
        } else if (ops.lookupSpecial(v, src, "keys")) |keys_m| {
            const keys = try vm.pyCall(keys_m, &.{}, null);
            const kit = try vm.pyIter(keys);
            while (try vm.pyNext(kit)) |k| {
                const gv = try vm.pyGetItem(src, k);
                const h = try vm.pyHash(k);
                try d.setWithHash(vm, k, gv, h);
            }
        } else {
            const it = try vm.pyIter(src);
            var idx: usize = 0;
            while (try vm.pyNext(it)) |pair| {
                const kv = try vm.collectSequence(pair, 2);
                if (kv.len != 2) {
                    try v.raiseFmt("ValueError", "dictionary update sequence element #{d} has length {d}; 2 is required", .{ idx, kv.len });
                    return error.PyExc;
                }
                const h = try vm.pyHash(kv[0]);
                try d.setWithHash(vm, kv[0], kv[1], h);
                idx += 1;
            }
        }
    }
    if (kw) |k| {
        for (k.names, 0..) |n, i| {
            const kobj = try v.rt.newStr(n);
            const h = try vm.pyHash(kobj);
            try d.setWithHash(vm, kobj, k.vals[i], h);
        }
    }
    return v.rt.newNone();
}

fn dict_clear(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const d = try selfDict(args, v);
    d.entries.clearRetainingCapacity();
    @memset(d.table, -1);
    return v.rt.newNone();
}

fn dict_copy(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const d = try selfDict(args, v);
    const nd = try v.rt.newDictObj();
    var it = d.iterAlive();
    while (it.next()) |e| {
        const h = try vm.pyHash(e.key.?);
        try nd.v.dict.setWithHash(vm, e.key.?, e.val.?, h);
    }
    return nd;
}

fn dict_fromkeys(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    // fromkeys — classmethod: args[0] = cls
    const val: Obj = if (args.len >= 3) args[2] else v.rt.newNone();
    const d = try v.rt.newDictObj();
    const it = try vm.pyIter(args[1]);
    while (try vm.pyNext(it)) |k| {
        const h = try vm.pyHash(k);
        try d.v.dict.setWithHash(vm, k, val, h);
    }
    return d;
}

fn dict_contains(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const d = try selfDict(args, v);
    const h = try vm.pyHash(args[1]);
    return v.rt.newBool((try d.getWithHash(vm, args[1], h)) != null);
}

// ============================================================
// set / frozenset
// ============================================================

pub fn registerSetMethods(rt: *Runtime) !void {
    inline for (.{ rt.set_t, rt.frozenset_t }) |t| {
        try td(rt, t, "union", set_union);
        try td(rt, t, "intersection", set_intersection);
        try td(rt, t, "difference", set_difference);
        try td(rt, t, "symmetric_difference", set_symdiff);
        try td(rt, t, "issubset", set_issubset);
        try td(rt, t, "issuperset", set_issuperset);
        try td(rt, t, "isdisjoint", set_isdisjoint);
        try td(rt, t, "copy", set_copy);
        try td(rt, t, "__contains__", set_contains);
    }
    try td(rt, rt.set_t, "add", set_add);
    try td(rt, rt.set_t, "remove", set_remove);
    try td(rt, rt.set_t, "discard", set_discard);
    try td(rt, rt.set_t, "pop", set_pop);
    try td(rt, rt.set_t, "clear", set_clear);
    try td(rt, rt.set_t, "update", set_update_m);
}

pub fn setDict(s: Obj) *Dict {
    return if (s.v == .set) &s.v.set.dict else &s.v.frozenset.dict;
}

fn selfSet(args: []const Obj, vm: *VM) !Obj {
    if (args.len == 0 or (args[0].v != .set and args[0].v != .frozenset)) {
        try vm.raiseStr("TypeError", "descriptor requires a 'set' object");
        return error.PyExc;
    }
    return args[0];
}

fn set_add(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const s = try selfSet(args, v);
    const h = try vm.pyHash(args[1]);
    try setDict(s).setWithHash(vm, args[1], v.rt.newNone(), h);
    return v.rt.newNone();
}

fn set_remove(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const s = try selfSet(args, v);
    const h = try vm.pyHash(args[1]);
    if (!(try setDict(s).delWithHash(vm, args[1], h))) {
        const eo = try v.mkExc(v.excType("KeyError"), &.{args[1]});
        try v.raiseObj(eo);
        return error.PyExc;
    }
    return v.rt.newNone();
}

fn set_discard(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const s = try selfSet(args, v);
    const h = try vm.pyHash(args[1]);
    _ = try setDict(s).delWithHash(vm, args[1], h);
    return v.rt.newNone();
}

fn set_pop(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const s = try selfSet(args, v);
    const d = setDict(s);
    var it = d.iterAlive();
    if (it.next()) |e| {
        const k = e.key.?;
        const h = try vm.pyHash(k);
        _ = try d.delWithHash(vm, k, h);
        return k;
    }
    try v.raiseStr("KeyError", "pop from an empty set");
    return error.PyExc;
}

fn set_clear(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const s = try selfSet(args, v);
    const d = setDict(s);
    d.entries.clearRetainingCapacity();
    @memset(d.table, -1);
    return v.rt.newNone();
}

fn set_update_m(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const s = try selfSet(args, v);
    for (args[1..]) |src| {
        const it = try vm.pyIter(src);
        while (try vm.pyNext(it)) |item| {
            const h = try vm.pyHash(item);
            try setDict(s).setWithHash(vm, item, v.rt.newNone(), h);
        }
    }
    return v.rt.newNone();
}

/// собрать элементы исходника в новый set-результат по предикату
fn setOpImpl(vm: *VM, a: Obj, others: []const Obj, comptime op: enum { uni, inter, diff, symdiff }) anyerror!Obj {
    const frozen = a.v == .frozenset;
    const result_d = try vm.rt.newDict();
    switch (op) {
        .uni => {
            var it = setDict(a).iterAlive();
            while (it.next()) |e| try result_d.setWithHash(vm, e.key.?, vm.rt.newNone(), e.hash);
            for (others) |o| {
                const oit = try vm.pyIter(o);
                while (try vm.pyNext(oit)) |item| {
                    const h = try vm.pyHash(item);
                    try result_d.setWithHash(vm, item, vm.rt.newNone(), h);
                }
            }
        },
        .inter => {
            var it = setDict(a).iterAlive();
            outer: while (it.next()) |e| {
                for (others) |o| {
                    const oc = if (o.v == .set or o.v == .frozenset) blk: {
                        break :blk (try setDict(o).getWithHash(vm, e.key.?, e.hash)) != null;
                    } else try vm.pyContains(o, e.key.?);
                    if (!oc) continue :outer;
                }
                try result_d.setWithHash(vm, e.key.?, vm.rt.newNone(), e.hash);
            }
        },
        .diff => {
            var it = setDict(a).iterAlive();
            outer: while (it.next()) |e| {
                for (others) |o| {
                    const oc = if (o.v == .set or o.v == .frozenset) blk: {
                        break :blk (try setDict(o).getWithHash(vm, e.key.?, e.hash)) != null;
                    } else try vm.pyContains(o, e.key.?);
                    if (oc) continue :outer;
                }
                try result_d.setWithHash(vm, e.key.?, vm.rt.newNone(), e.hash);
            }
        },
        .symdiff => {
            // (a \ b) | (b \ a), один аргумент
            if (others.len != 1) return typeErr(vm, "symmetric_difference() takes exactly one argument", .{});
            const b = others[0];
            var it = setDict(a).iterAlive();
            while (it.next()) |e| {
                const oc = if (b.v == .set or b.v == .frozenset)
                    (try setDict(b).getWithHash(vm, e.key.?, e.hash)) != null
                else
                    try vm.pyContains(b, e.key.?);
                if (!oc) try result_d.setWithHash(vm, e.key.?, vm.rt.newNone(), e.hash);
            }
            const bit = try vm.pyIter(b);
            while (try vm.pyNext(bit)) |item| {
                const h = try vm.pyHash(item);
                if ((try setDict(a).getWithHash(vm, item, h)) == null) {
                    try result_d.setWithHash(vm, item, vm.rt.newNone(), h);
                }
            }
        },
    }
    var items: std.ArrayList(Obj) = .empty;
    var rit = result_d.iterAlive();
    while (rit.next()) |e| try items.append(vm.rt.gpa, e.key.?);
    return vm.rt.newSetObj(frozen, items.items);
}

fn set_union(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const s = try selfSet(args, v);
    return setOpImpl(v, s, args[1..], .uni);
}

fn set_intersection(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const s = try selfSet(args, v);
    return setOpImpl(v, s, args[1..], .inter);
}

fn set_difference(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const s = try selfSet(args, v);
    return setOpImpl(v, s, args[1..], .diff);
}

fn set_symdiff(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const s = try selfSet(args, v);
    return setOpImpl(v, s, args[1..], .symdiff);
}

fn set_issubset(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const s = try selfSet(args, v);
    var it = setDict(s).iterAlive();
    while (it.next()) |e| {
        if (!(try vm.pyContains(args[1], e.key.?))) return v.rt.false_obj;
    }
    return v.rt.true_obj;
}

fn set_issuperset(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const s = try selfSet(args, v);
    const it = try vm.pyIter(args[1]);
    while (try vm.pyNext(it)) |item| {
        const h = try vm.pyHash(item);
        if ((try setDict(s).getWithHash(vm, item, h)) == null) return v.rt.false_obj;
    }
    return v.rt.true_obj;
}

fn set_isdisjoint(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const s = try selfSet(args, v);
    const it = try vm.pyIter(args[1]);
    while (try vm.pyNext(it)) |item| {
        const h = try vm.pyHash(item);
        if ((try setDict(s).getWithHash(vm, item, h)) != null) return v.rt.false_obj;
    }
    return v.rt.true_obj;
}

fn set_copy(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    return setOpImpl(v, try selfSet(args, v), &.{}, .uni);
}

fn set_contains(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const s = try selfSet(args, v);
    const h = try vm.pyHash(args[1]);
    return v.rt.newBool((try setDict(s).getWithHash(vm, args[1], h)) != null);
}

// ============================================================
// tuple
// ============================================================

pub fn registerTupleMethods(rt: *Runtime) !void {
    try td(rt, rt.tuple_t, "count", tuple_count);
    try td(rt, rt.tuple_t, "index", tuple_index);
}

fn selfTuple(args: []const Obj, vm: *VM) ![]*object.PyObj {
    if (args.len == 0 or args[0].v != .tuple) {
        try vm.raiseStr("TypeError", "descriptor requires a 'tuple' object");
        return error.PyExc;
    }
    return args[0].v.tuple;
}

fn tuple_count(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const t = try selfTuple(args, v);
    var n: usize = 0;
    for (t) |item| {
        if (try vm.pyEq(item, args[1])) n += 1;
    }
    return v.rt.newInt(@intCast(n));
}

fn tuple_index(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const t = try selfTuple(args, v);
    const start: usize = if (args.len >= 3) @intCast(@max(0, try indexLike(v, args[2]))) else 0;
    var i = start;
    while (i < t.len) : (i += 1) {
        if (try vm.pyEq(t[i], args[1])) return v.rt.newInt(@intCast(i));
    }
    try v.raiseStr("ValueError", "tuple.index(x): x not in tuple");
    return error.PyExc;
}
