//! Операции протокола Python — могут выполнять Python-код.
//! Аналог Objects/abstract.c + typeobject.c (слоты): getattr/setattr (дескрипторы),
//! вызовы, операторы (__add__/__radd__ и ко), сравнения, repr/str/hash, iter/next.

const std = @import("std");
const object = @import("../object/object.zig");
const vm_mod = @import("vm.zig");

const Obj = object.Obj;
const Type = object.Type;
const Dict = object.Dict;
const VM = vm_mod.VM;
const KwArgs = object.KwArgs;

pub const DEFAULT_Type_getattro = {};

// ============================================================
// Поиск по классу
// ============================================================

/// Найти атрибут в MRO класса (сырое значение, без биндинга).
pub fn lookupClass(cls: *Type, name: []const u8) ?Obj {
    for (cls.mro) |t| {
        var it = t.dict.iterAlive();
        while (it.next()) |e| {
            if (e.key.?.v == .str and std.mem.eql(u8, e.key.?.v.str.bytes, name)) {
                return e.val;
            }
        }
    }
    return null;
}

/// Есть ли у объекта-дескриптора __set__/__delete__ (data descriptor).
fn isDataDescriptor(attr: Obj) bool {
    switch (attr.v) {
        .property => return true,
        else => return lookupClass(attr.ty, "__set__") != null,
    }
}

/// Применить __get__ дескриптора. Если не дескриптор — вернуть как есть.
fn descrGet(vm: *VM, attr: Obj, obj: ?Obj, ty: *Type) anyerror!Obj {
    switch (attr.v) {
        .function => {
            if (obj) |o| return vm.rt.newMethod(o, attr);
            return attr; // unbound через класс → обычная функция
        },
        .builtin => {
            if (obj) |o| return vm.rt.newMethod(o, attr);
            return attr;
        },
        .method => return attr,
        .staticm => |s| return s.callable,
        .classm => |c| {
            const cls_obj = if (obj) |o| if (o.v == .type_) o.v.type_ else o.ty else ty;
            const cls_key = try vm.rt.mkObj(vm.rt.type_t, .{ .type_ = cls_obj });
            return vm.rt.newMethod(cls_key, c.callable);
        },
        .property => |p| {
            if (obj == null) return attr;
            if (p.fget) |fg| {
                return vm.pyCall(fg, &.{obj.?}, null);
            }
            return attr;
        },
        else => {
            if (lookupClass(attr.ty, "__get__")) |g| {
                const bound = try descrGet(vm, g, attr, attr.ty);
                const ty_obj = try vm.rt.mkObj(vm.rt.type_t, .{ .type_ = ty });
                return vm.pyCall(bound, &.{ obj orelse vm.rt.newNone(), ty_obj }, null);
            }
            return attr;
        },
    }
}

fn descrSet(vm: *VM, attr: Obj, obj: Obj, value: Obj) anyerror!bool {
    switch (attr.v) {
        .property => |p| {
            if (p.fset) |fs| {
                _ = try vm.pyCall(fs, &.{ obj, value }, null);
                return true;
            }
            if (p.fdel == null and p.fget == null) return false;
            try vm.raiseStr("AttributeError", "can't set attribute");
            return error.PyExc;
        },
        else => {
            if (lookupClass(attr.ty, "__set__")) |s| {
                const bound = try descrGet(vm, s, attr, attr.ty);
                _ = try vm.pyCall(bound, &.{ obj, value }, null);
                return true;
            }
            return false;
        },
    }
}

// ============================================================
// getattr / setattr / hasattr / delattr
// ============================================================

pub fn pyGetAttr(vm: *VM, obj: Obj, name: []const u8) anyerror!Obj {
    // Модули: сначала их dict (PEP 562 __getattr__).
    if (obj.v == .module) {
        const m = obj.v.module;
        if (try dictGetStr(m.dict, vm, name)) |v| return v;
        if (try dictGetStr(m.dict, vm, "__getattr__")) |ga| {
            const nameobj = try vm.rt.newStr(name);
            return vm.pyCall(ga, &.{nameobj}, null);
        }
        try vm.raiseFmt("AttributeError", "module '{s}' has no attribute '{s}'", .{ m.name, name });
        return error.PyExc;
    }

    // Класс (тип как значение): ищем сначала в его MRO, потом в метаклассе.
    if (obj.v == .type_) {
        const cls = obj.v.type_;
        if (lookupClass(cls, name)) |attr| {
            return descrGet(vm, attr, null, cls);
        }
        // метакласс
        if (obj.ty.mro.len > 0) {
            if (lookupClass(obj.ty, name)) |attr| {
                const attr2 = try descrGet(vm, attr, obj, obj.ty);
                return attr2;
            }
        }
        if (lookupClass(obj.ty, "__getattr__")) |_| {} // редкий случай, пропускаем
        try vm.raiseFmt("AttributeError", "type object '{s}' has no attribute '{s}'", .{ cls.name, name });
        return error.PyExc;
    }

    // super: атрибут ищется в MRO после s.ty, привязка к s.obj.
    if (obj.v == .super_) {
        const s = obj.v.super_;
        if (s.obj_type != null and s.obj != null) {
            const ot = s.obj_type.?;
            var start: usize = 0;
            for (ot.mro, 0..) |t, i| {
                if (t == s.ty) {
                    start = i + 1;
                    break;
                }
            }
            if (start > 0) {
                for (ot.mro[start..]) |t| {
                    var it = t.dict.iterAlive();
                    while (it.next()) |e| {
                        if (e.key.?.v == .str and std.mem.eql(u8, e.key.?.v.str.bytes, name)) {
                            return descrGet(vm, e.val.?, s.obj, ot);
                        }
                    }
                }
            }
        }
        try vm.raiseFmt("AttributeError", "'super' object has no attribute '{s}'", .{name});
        return error.PyExc;
    }

    // Обычный объект: ищем через тип
    const ty = obj.ty;
    // __getattribute__ override? (пока только стандартный алгоритм)
    var cls_attr: ?Obj = null;
    if (lookupClass(ty, name)) |attr| {
        if (isDataDescriptor(attr)) {
            return descrGet(vm, attr, obj, ty);
        }
        cls_attr = attr;
    }
    // instance dict
    if (instanceDict(obj)) |d| {
        if (try dictGetStr(d, vm, name)) |v| return v;
    }
    if (cls_attr) |attr| {
        return descrGet(vm, attr, obj, ty);
    }
    // __getattr__ fallback
    if (lookupClass(ty, "__getattr__")) |ga| {
        const bound = try descrGet(vm, ga, obj, ty);
        const nameobj = try vm.rt.newStr(name);
        return vm.pyCall(bound, &.{nameobj}, null);
    }
    try vm.raiseFmt("AttributeError", "'{s}' object has no attribute '{s}'", .{ ty.name, name });
    return error.PyExc;
}

pub fn instanceDict(obj: Obj) ?*Dict {
    return switch (obj.v) {
        .instance => |i| &i.dict,
        .exc => |e| &e.dict,
        else => null,
    };
}

/// dict lookup по строковому ключу-литералу
pub fn dictGetStr(d: *Dict, vm: *VM, name: []const u8) !?Obj {
    var it = d.iterAlive();
    while (it.next()) |e| {
        const k = e.key.?;
        if (k.v == .str and std.mem.eql(u8, k.v.str.bytes, name)) return e.val;
    }
    _ = vm;
    return null;
}

/// Установить строковый ключ в dict (ключ-строка создаётся при необходимости)
pub fn dictSetStr(d: *Dict, vm: *VM, name: []const u8, val: Obj) !void {
    var it = d.iterAlive();
    while (it.next()) |e| {
        const k = e.key.?;
        if (k.v == .str and std.mem.eql(u8, k.v.str.bytes, name)) {
            e.val = val;
            return;
        }
    }
    const kobj = try vm.rt.newStr(name);
    const h = try vm.pyHash(kobj);
    try d.setWithHash(vm, kobj, val, h);
}

pub fn dictDelStr(d: *Dict, vm: *VM, name: []const u8) !bool {
    var idx: ?usize = null;
    _ = &idx;
    var it = d.iterAlive();
    while (it.next()) |e| {
        const k = e.key.?;
        if (k.v == .str and std.mem.eql(u8, k.v.str.bytes, name)) {
            const h = try vm.pyHash(k);
            _ = try d.delWithHash(vm, k, h);
            return true;
        }
    }
    return false;
}

pub fn pySetAttr(vm: *VM, obj: Obj, name: []const u8, value: Obj) anyerror!void {
    if (obj.v == .module) {
        try dictSetStr(obj.v.module.dict, vm, name, value);
        return;
    }
    const ty = obj.ty;
    // data descriptor
    if (obj.v != .type_) {
        if (lookupClass(ty, name)) |attr| {
            if (try descrSet(vm, attr, obj, value)) return;
        }
        if (instanceDict(obj)) |d| {
            try dictSetStr(d, vm, name, value);
            return;
        }
        // класс-объекты CPython позволяют setattr и на типах; здесь просто ошибка
        try vm.raiseFmt("AttributeError", "'{s}' object attribute '{s}' is read-only", .{ ty.name, name });
        return error.PyExc;
    } else {
        // setattr на классе: пишем в dict класса
        const cls = obj.v.type_;
        try dictSetStr(cls.dict, vm, name, value);
    }
}

pub fn pyDelAttr(vm: *VM, obj: Obj, name: []const u8) anyerror!void {
    if (obj.v == .module) {
        if (try dictDelStr(obj.v.module.dict, vm, name)) return;
    } else if (instanceDict(obj)) |d| {
        if (try dictDelStr(d, vm, name)) return;
    }
    try vm.raiseFmt("AttributeError", "'{s}' object has no attribute '{s}'", .{ obj.ty.name, name });
    return error.PyExc;
}

/// Спецметод для неявных вызовов (операторы и т.п.) — только по типу.
pub fn lookupSpecial(vm: *VM, obj: Obj, name: []const u8) ?Obj {
    const cls_attr = lookupClass(obj.ty, name) orelse return null;
    return descrGet(vm, cls_attr, obj, obj.ty) catch null;
}

/// Как lookupSpecial, но dunder должен быть переопределён пользователем:
/// атрибут, найденный в object, не считается (аналог "tp___xxx__ != object.__xxx__" в CPython).
pub fn lookupSpecialUser(vm: *VM, obj: Obj, name: []const u8) ?Obj {
    for (obj.ty.mro) |t| {
        var it = t.dict.iterAlive();
        while (it.next()) |e| {
            if (e.key.?.v == .str and std.mem.eql(u8, e.key.?.v.str.bytes, name)) {
                if (t == vm.rt.object_t) return null;
                return descrGet(vm, e.val.?, obj, obj.ty) catch null;
            }
        }
    }
    return null;
}

// ============================================================
// Вызовы
// ============================================================

pub fn pyCall(vm: *VM, callable: Obj, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    switch (callable.v) {
        .builtin => |b| return b.f(vm, args, kw),
        .method => |m| {
            const with_self = try vm.rt.gpa.alloc(Obj, args.len + 1);
            with_self[0] = m.self_obj;
            @memcpy(with_self[1..], args);
            return pyCall(vm, m.func, with_self, kw);
        },
        .function => |f| {
            if (f.code.flags.generator) {
                const frame = try vm.makeFrame(f, args, kw);
                return vm.rt.newGenerator(frame);
            }
            return vm.runFunction(f, args, kw);
        },
        .type_ => |cls| {
            return pyCallType(vm, cls, args, kw);
        },
        .iter => {
            try vm.raiseStr("TypeError", "'iterator' object is not callable");
            return error.PyExc;
        },
        else => {
            if (lookupSpecial(vm, callable, "__call__")) |c| {
                return vm.pyCall(c, args, kw);
            }
            try vm.raiseFmt("TypeError", "'{s}' object is not callable", .{callable.ty.name});
            return error.PyExc;
        },
    }
}

/// Вызов класса: создание экземпляра.
/// Конструкция встроенных типов — аналог tp_new нативных типов CPython.
/// Возвращает null, если тип не нативный (тогда generic-путь instance+__init__).
pub fn nativeTypeNew(vm: *VM, cls: *Type, args: []const Obj, kw: ?KwArgs) anyerror!?Obj {
    const rt = vm.rt;
    const bltn = @import("../runtime/builtins.zig");
    const tmisc = @import("../runtime/methods/typemisc.zig");
    const tstr = @import("../runtime/methods/typestr.zig");

    // исключения: cls(*args) → Exc с args (аналог BaseException_new)
    if (cls.flags.exc) {
        const e = try rt.newExc(cls);
        const cp = try rt.gpa.alloc(Obj, args.len);
        @memcpy(cp, args);
        e.v.exc.args = cp;
        return e;
    }

    if (cls == rt.bool_t) {
        if (args.len == 0) return rt.newBool(false);
        return rt.newBool(try vm.pyTruthy(args[0]));
    }
    if (cls == rt.int_t) {
        if (args.len == 0) return rt.newInt(0);
        const x = args[0];
        switch (x.v) {
            .int, .bigint => return x,
            .bool_ => |b| return rt.newInt(@intFromBool(b)),
            .float => |f| {
                const t = @trunc(f);
                if (t >= -9.0e18 and t <= 9.0e18) return rt.newInt(@intFromFloat(t));
                return rt.newFloat(t); // TODO bigint из большого float
            },
            .str => |s| {
                const base: u8 = if (args.len >= 2) @intCast(try bltn.indexLike(vm, args[1])) else 10;
                return intFromStr(vm, s.bytes, base);
            },
            .bytes => |b| {
                const base: u8 = if (args.len >= 2) @intCast(try bltn.indexLike(vm, args[1])) else 10;
                return intFromStr(vm, b.data, base);
            },
            else => {},
        }
        if (lookupSpecial(vm, x, "__int__")) |m| {
            return vm.pyCall(m, &.{}, null);
        }
        try vm.raiseFmt("TypeError", "int() argument must be a string, a bytes-like object or a number, not '{s}'", .{x.ty.name});
        return error.PyExc;
    }
    if (cls == rt.float_t) {
        if (args.len == 0) return rt.newFloat(0.0);
        const x = args[0];
        if (x.v == .str) {
            const trimmed = std.mem.trim(u8, x.v.str.bytes, " \t\r\n");
            const f = std.fmt.parseFloat(f64, trimmed) catch {
                try vm.raiseFmt("ValueError", "could not convert string to float: '{s}'", .{x.v.str.bytes});
                return error.PyExc;
            };
            return rt.newFloat(f);
        }
        if (x.v == .bytes) {
            const f = std.fmt.parseFloat(f64, std.mem.trim(u8, x.v.bytes.data, " \t\r\n")) catch {
                try vm.raiseStr("ValueError", "could not convert bytes to float");
                return error.PyExc;
            };
            return rt.newFloat(f);
        }
        return rt.newFloat(try bltn.floatLike(vm, x));
    }
    if (cls == rt.str_t) {
        if (args.len == 0) return rt.newStr("");
        if (args.len >= 2 and (args[0].v == .bytes or args[0].v == .bytearray)) {
            // str(bytes, encoding[, errors])
            const enc = try pyStr(vm, args[1]);
            const data: []const u8 = if (args[0].v == .bytes) args[0].v.bytes.data else args[0].v.bytearray.data.items;
            return tmisc.decodeBytes(vm, data, enc.v.str.bytes);
        }
        return pyStr(vm, args[0]);
    }
    if (cls == rt.list_t) {
        if (args.len == 0) return rt.newList();
        return rt.newListFrom(try vm.collectSequence(args[0], null));
    }
    if (cls == rt.tuple_t) {
        if (args.len == 0) return rt.newTuple(&.{});
        return rt.newTuple(try vm.collectSequence(args[0], null));
    }
    if (cls == rt.set_t or cls == rt.frozenset_t) {
        const frozen = cls == rt.frozenset_t;
        if (args.len == 0) return rt.newSetObj(frozen, &.{});
        return rt.newSetObj(frozen, try vm.collectSequence(args[0], null));
    }
    if (cls == rt.dict_t) {
        const d = try rt.newDictObj();
        if (args.len >= 1) {
            const x = args[0];
            if (x.v == .dict) {
                for (x.v.dict.entries.items) |ent| {
                    if (ent.key) |k| try dictSetObj(vm, d.v.dict, k, ent.val.?);
                }
            } else {
                // iterable пар
                const pairs = try vm.collectSequence(x, null);
                for (pairs) |p| {
                    const kv = try vm.collectSequence(p, null);
                    if (kv.len != 2) {
                        try vm.raiseStr("ValueError", "dictionary update sequence element must have length 2");
                        return error.PyExc;
                    }
                    try dictSetObj(vm, d.v.dict, kv[0], kv[1]);
                }
            }
        }
        if (kw) |k| {
            for (k.names, k.vals) |n, val| {
                try dictSetObj(vm, d.v.dict, try rt.newStr(n), val);
            }
        }
        return d;
    }
    if (cls == rt.range_t) {
        if (args.len == 0) {
            try vm.raiseStr("TypeError", "range expected at least 1 argument");
            return error.PyExc;
        }
        var start: i64 = 0;
        var stop: i64 = try bltn.indexLike(vm, args[0]);
        var step: i64 = 1;
        if (args.len >= 2) {
            start = stop;
            stop = try bltn.indexLike(vm, args[1]);
        }
        if (args.len >= 3) step = try bltn.indexLike(vm, args[2]);
        if (step == 0) {
            try vm.raiseStr("ValueError", "range() arg 3 must not be zero");
            return error.PyExc;
        }
        return rt.newRange(start, stop, step);
    }
    if (cls == rt.slice_t) {
        if (args.len == 0) {
            try vm.raiseStr("TypeError", "slice expected at least 1 argument");
            return error.PyExc;
        }
        const opt = struct {
            fn conv(o: Obj) ?Obj {
                return if (o.isNone()) null else o;
            }
        };
        if (args.len == 1) return rt.newSlice(null, opt.conv(args[0]), null);
        if (args.len == 2) return rt.newSlice(opt.conv(args[0]), opt.conv(args[1]), null);
        return rt.newSlice(opt.conv(args[0]), opt.conv(args[1]), opt.conv(args[2]));
    }
    if (cls == rt.super_t) {
        const s = try rt.gpa.create(object.Super);
        s.* = .{};
        if (args.len >= 1) {
            if (args[0].v != .type_) {
                try vm.raiseStr("TypeError", "super() argument 1 must be a type");
                return error.PyExc;
            }
            s.ty = args[0].v.type_;
        }
        if (args.len >= 2) {
            s.obj = args[1];
            s.obj_type = if (args[1].v == .type_) args[1].v.type_ else args[1].ty;
        }
        if (s.ty == null or s.obj == null) {
            // super() без аргументов: __class__≈type(locals[0]), obj=locals[0]
            const ts = vm.currentTS();
            if (ts.frames.items.len == 0) {
                try vm.raiseStr("RuntimeError", "super(): no current frame");
                return error.PyExc;
            }
            const fr = ts.frames.items[ts.frames.items.len - 1];
            if (fr.locals.len == 0 or fr.locals[0].v == .none) {
                try vm.raiseStr("RuntimeError", "super(): arg[0] deleted");
                return error.PyExc;
            }
            s.obj = fr.locals[0];
            s.obj_type = fr.locals[0].ty;
            if (s.ty == null) s.ty = fr.locals[0].ty;
        }
        return rt.mkObj(rt.super_t, .{ .super_ = s });
    }
    if (cls == rt.bytes_t or cls == rt.bytearray_t) {
        const mutable = cls == rt.bytearray_t;
        var data: []const u8 = "";
        if (args.len >= 1) {
            const x = args[0];
            if (x.v == .int or x.v == .bool_) {
                const n_i = try bltn.indexLike(vm, x);
                if (n_i < 0) {
                    try vm.raiseStr("ValueError", "negative count");
                    return error.PyExc;
                }
                const buf = try rt.gpa.alloc(u8, @intCast(n_i));
                @memset(buf, 0);
                data = buf;
            } else if (x.v == .str) {
                const enc = if (args.len >= 2) (try pyStr(vm, args[1])).v.str.bytes else "utf-8";
                const enco = try tstr.encodeStr(vm, x.v.str.bytes, enc);
                data = enco.v.bytes.data;
            } else if (x.v == .bytes) {
                data = x.v.bytes.data;
            } else if (x.v == .bytearray) {
                data = x.v.bytearray.data.items;
            } else {
                const items = try vm.collectSequence(x, null);
                const buf = try rt.gpa.alloc(u8, items.len);
                for (items, 0..) |it, i| {
                    const b = try bltn.indexLike(vm, it);
                    if (b < 0 or b > 255) {
                        try vm.raiseStr("ValueError", "byte must be in range(0, 256)");
                        return error.PyExc;
                    }
                    buf[i] = @intCast(b);
                }
                data = buf;
            }
        }
        if (mutable) {
            return rt.newBytearray(data);
        }
        return rt.newBytes(data);
    }
    return null;
}

/// int(str, base) — с префиксами 0x/0o/0b, знаками, подчёркиваниями.
pub fn intFromStr(vm: *VM, raw: []const u8, base_arg: u8) anyerror!Obj {
    const s0 = std.mem.trim(u8, raw, " \t\r\n");
    var neg = false;
    var s = s0;
    if (s.len > 0 and (s[0] == '+' or s[0] == '-')) {
        neg = s[0] == '-';
        s = s[1..];
    }
    var base = base_arg;
    if (base == 0) {
        base = 10;
        if (s.len > 2 and s[0] == '0') {
            switch (s[1]) {
                'x', 'X' => {
                    base = 16;
                    s = s[2..];
                },
                'o', 'O' => {
                    base = 8;
                    s = s[2..];
                },
                'b', 'B' => {
                    base = 2;
                    s = s[2..];
                },
                else => {},
            }
        }
    } else if (s.len > 2 and s[0] == '0') {
        const want: u8 = switch (base) {
            16 => 'x',
            8 => 'o',
            2 => 'b',
            else => 0,
        };
        if (want != 0 and (s[1] == want or s[1] == (want & 0xDF))) s = s[2..];
    }
    // CPython: переполнение i64 → bigint.
    if (std.fmt.parseInt(i64, s, base)) |v64| {
        return vm.rt.newInt(if (neg) -v64 else v64);
    } else |e| {
        if (e == error.Overflow) {
            if (try object.bigParse(vm.rt.gpa, s, base)) |bg| {
                if (neg) bg.negate();
                return vm.rt.newBig(bg);
            }
        }
        try vm.raiseFmt("ValueError", "invalid literal for int() with base {d}: '{s}'", .{ base_arg, raw });
        return error.PyExc;
    }
}

/// dict[k] = v через хеш рантайма.
fn dictSetObj(vm: *VM, d: *object.Dict, k: Obj, v: Obj) anyerror!void {
    const h = try vm.rt.pyHash(k);
    try d.setWithHash(vm.rt, k, v, h);
}

fn pyCallType(vm: *VM, cls: *Type, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    // type(x) → тип x ; type(name,bases,dict) → создание класса
    if (cls == vm.rt.type_t) {
        if (args.len == 1) return vm.typeOf(args[0]);
        if (args.len == 3) return vm.buildClassFromCall(args, kw);
        try vm.raiseStr("TypeError", "type() takes 1 or 3 arguments");
        return error.PyExc;
    }
    if (cls.tp_new) |newf| {
        return newf(vm, cls, args, kw);
    }
    if (try nativeTypeNew(vm, cls, args, kw)) |obj| return obj;
    // __new__ пользовательский? (упрощение: игнорируем, создаём instance)
    const inst = try vm.rt.newInstance(cls);
    if (lookupSpecial(vm, inst, "__init__")) |init_m| {
        const res = try vm.pyCall(init_m, args, kw);
        if (!res.isNone()) {
            try vm.raiseFmt("TypeError", "__init__() should return None, not '{s}'", .{res.ty.name});
            return error.PyExc;
        }
    } else if (args.len != 0 or kw != null) {
        if (cls == vm.rt.object_t) {
            try vm.raiseStr("TypeError", "object() takes no arguments");
            return error.PyExc;
        }
    }
    return inst;
}

pub fn argCountTypeError(vm: *VM, comptime name: []const u8, expected: []const u8) anyerror {
    try vm.raiseFmt("TypeError", name ++ "() " ++ expected, .{});
}

// ============================================================
// type / isinstance / issubclass
// ============================================================

pub fn typeOf(vm: *VM, o: Obj) anyerror!Obj {
    return vm.rt.mkObj(vm.rt.type_t, .{ .type_ = o.ty });
}

pub fn isSubclass(a: *Type, b: *Type) bool {
    for (a.mro) |t| {
        if (t == b) return true;
    }
    return false;
}

pub fn isInstanceCls(o: Obj, cls: *Type) bool {
    return isSubclass(o.ty, cls);
}

pub fn isInstance(vm: *VM, o: Obj, cls_or_tuple: Obj) anyerror!bool {
    switch (cls_or_tuple.v) {
        .type_ => |t| return isInstanceCls(o, t),
        .tuple => |items| {
            for (items) |it| {
                if (try isInstance(vm, o, it)) return true;
            }
            return false;
        },
        else => {
            try vm.raiseStr("TypeError", "isinstance() arg 2 must be a type or tuple of types");
            return error.PyExc;
        },
    }
}

// ============================================================
// Равенство / сравнения / хеш
// ============================================================

pub fn pyEq(vm: *VM, a: Obj, b: Obj) anyerror!bool {
    if (a == b) return true;
    // числа
    if (isNumber(a) and isNumber(b)) {
        return (try numericCompare(vm, .eq, a, b)) orelse false;
    }
    switch (a.v) {
        .none => return false,
        .str => |sa| {
            if (b.v != .str) {
                if (try tryEqMethods(vm, a, b)) |r| return r;
                return false;
            }
            return std.mem.eql(u8, sa.bytes, b.v.str.bytes);
        },
        .bytes => |ba| {
            if (b.v != .bytes) {
                if (try tryEqMethods(vm, a, b)) |r| return r;
                return false;
            }
            return std.mem.eql(u8, ba.data, b.v.bytes.data);
        },
        .list => |la| {
            if (b.v != .list) {
                if (try tryEqMethods(vm, a, b)) |r| return r;
                return false;
            }
            const lb = b.v.list;
            if (la.items.items.len != lb.items.items.len) return false;
            for (la.items.items, lb.items.items) |x, y| {
                if (!(try vm.pyEq(x, y))) return false;
            }
            return true;
        },
        .tuple => |ta| {
            if (b.v != .tuple) {
                if (try tryEqMethods(vm, a, b)) |r| return r;
                return false;
            }
            const tb = b.v.tuple;
            if (ta.len != tb.len) return false;
            for (ta, tb) |x, y| {
                if (!(try vm.pyEq(x, y))) return false;
            }
            return true;
        },
        .dict => |da| {
            if (b.v != .dict) {
                if (try tryEqMethods(vm, a, b)) |r| return r;
                return false;
            }
            const db = b.v.dict;
            if (da.len() != db.len()) return false;
            var it = da.iterAlive();
            while (it.next()) |e| {
                const h = try vm.pyHash(e.key.?);
                const v2 = (try db.getWithHash(vm, e.key.?, h)) orelse return false;
                if (!(try vm.pyEq(e.val.?, v2))) return false;
            }
            return true;
        },
        .set, .frozenset => |sa| {
            if (!(b.v == .set or b.v == .frozenset)) {
                if (try tryEqMethods(vm, a, b)) |r| return r;
                return false;
            }
            const sb = if (b.v == .set) b.v.set else b.v.frozenset;
            if (sa.dict.len() != sb.dict.len()) return false;
            var it = sa.dict.iterAlive();
            while (it.next()) |e| {
                const h = try vm.pyHash(e.key.?);
                const v2 = (try sb.dict.getWithHash(vm, e.key.?, h)) orelse return false;
                _ = v2;
            }
            return true;
        },
        .exc => {
            return a == b;
        },
        else => {
            if (try tryEqMethods(vm, a, b)) |r| return r;
            return false;
        },
    }
}

/// Пробуем __eq__/__ne__: возвращает null, если методов нет (оба NotImplemented).
fn tryEqMethods(vm: *VM, a: Obj, b: Obj) anyerror!?bool {
    // Для встроенных одинаковых типов здесь не должно быть методов
    if (lookupSpecial(vm, a, "__eq__")) |eqm| {
        const r = try vm.pyCall(eqm, &.{b}, null);
        if (r.v != .notimpl) return r.isTruthy();
    }
    if (lookupSpecial(vm, b, "__eq__")) |eqm| {
        const r = try vm.pyCall(eqm, &.{a}, null);
        if (r.v != .notimpl) return r.isTruthy();
    }
    // Проверяем, определён ли __ne__ явно (не object.__ne__ — CPython сам инвертирует)
    if (lookupSpecial(vm, a, "__ne__")) |nem| {
        if (!isObjectDefault(vm, nem, "__ne__")) {
            const r = try vm.pyCall(nem, &.{b}, null);
            if (r.v != .notimpl) return r.isTruthy();
        }
    }
    return null;
}

fn isObjectDefault(vm: *VM, bound: Obj, name: []const u8) bool {
    _ = vm;
    _ = name;
    _ = bound;
    return false; // упрощение: __ne__ всегда вызываем, если есть
}

pub fn isNumber(o: Obj) bool {
    return switch (o.v) {
        .int, .bigint, .float, .bool_ => true,
        else => false,
    };
}

/// Числовое сравнение; null если не сравнимо (не должно случаться — оба числа).
pub fn numericCompare(vm: *VM, op: CompareOp, a: Obj, b: Obj) anyerror!?bool {
    const fa = try toF64OrBig(vm, a);
    const fb = try toF64OrBig(vm, b);
    switch (fa) {
        .f64 => |x| switch (fb) {
            .f64 => |y| return doF64Cmp(op, x, y),
            .big => |by| {
                // точность: для сравнения int vs float прибегаем к f64 (ок для наших целей)
                return doF64Cmp(op, x, bigToF64(by));
            },
        },
        .big => |bx| switch (fb) {
            .f64 => |y| return doF64Cmp(op, bigToF64(bx), y),
            .big => |by| {
                const ord = bx.order(by.*);
                return switch (op) {
                    .eq => ord == .eq,
                    .ne => ord != .eq,
                    .lt => ord == .lt,
                    .le => ord == .lt or ord == .eq,
                    .gt => ord == .gt,
                    .ge => ord == .gt or ord == .eq,
                };
            },
        },
    }
}

pub const CompareOp = enum { lt, le, eq, ne, gt, ge };

const Num = union(enum) { f64: f64, big: *object.Big };

fn bigToF64(b: *object.Big) f64 {
    return object.bigFloat(b);
}

fn toF64OrBig(vm: *VM, o: Obj) !Num {
    _ = vm;
    return switch (o.v) {
        .int => |i| .{ .f64 = @floatFromInt(i) },
        .bool_ => |b| .{ .f64 = if (b) 1 else 0 },
        .float => |f| .{ .f64 = f },
        .bigint => |b| .{ .big = b },
        else => unreachable,
    };
}

fn doF64Cmp(op: CompareOp, x: f64, y: f64) bool {
    return switch (op) {
        .eq => x == y,
        .ne => x != y,
        .lt => x < y,
        .le => x <= y,
        .gt => x > y,
        .ge => x >= y,
    };
}

/// Богатое сравнение (COMPARE_OP).
pub fn pyRichCompare(vm: *VM, op: CompareOp, a: Obj, b: Obj) anyerror!Obj {
    if (op == .eq or op == .ne) {
        const eq = try vm.pyEq(a, b);
        return vm.rt.newBool(if (op == .eq) eq else !eq);
    }
    if (a == b) {
        // свежие контейнеры равны себе по ссылке — но для встроенных упорядоченных типов
    }
    // числа
    if (isNumber(a) and isNumber(b)) {
        if (try numericCompare(vm, op, a, b)) |r| return vm.rt.newBool(r);
    }
    // строки: лексикографически по кодпоинтам (= по UTF-8 байтам)
    if (a.v == .str and b.v == .str) {
        const c = std.mem.order(u8, a.v.str.bytes, b.v.str.bytes);
        return vm.rt.newBool(switch (op) {
            .lt => c == .lt,
            .le => c == .lt or c == .eq,
            .gt => c == .gt,
            .ge => c == .gt or c == .eq,
            else => unreachable,
        });
    }
    if ((a.v == .list and b.v == .list) or (a.v == .tuple and b.v == .tuple)) {
        return seqCompare(vm, op, a, b);
    }
    // спецметоды
    const name = switch (op) {
        .lt => "__lt__",
        .le => "__le__",
        .gt => "__gt__",
        .ge => "__ge__",
        else => unreachable,
    };
    if (lookupSpecial(vm, a, name)) |m| {
        const r = try vm.pyCall(m, &.{b}, null);
        if (r.v != .notimpl) return vm.rt.newBool(r.isTruthy());
    }
    // отражённый
    const rname = switch (op) {
        .lt => "__gt__",
        .le => "__ge__",
        .gt => "__lt__",
        .ge => "__le__",
        else => unreachable,
    };
    if (lookupSpecial(vm, b, rname)) |m| {
        const r = try vm.pyCall(m, &.{a}, null);
        if (r.v != .notimpl) return vm.rt.newBool(r.isTruthy());
    }
    try vm.raiseFmt("TypeError", "'{s}' not supported between instances of '{s}' and '{s}'", .{ @tagName(op), a.ty.name, b.ty.name });
    return error.PyExc;
}

fn seqCompare(vm: *VM, op: CompareOp, a: Obj, b: Obj) anyerror!Obj {
    const la: []Obj = if (a.v == .list) a.v.list.items.items else a.v.tuple;
    const lb: []Obj = if (b.v == .list) b.v.list.items.items else b.v.tuple;
    const n = @min(la.len, lb.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (!(try vm.pyEq(la[i], lb[i]))) {
            return pyRichCompare(vm, op, la[i], lb[i]);
        }
    }
    const c = std.math.order(la.len, lb.len);
    return vm.rt.newBool(switch (op) {
        .lt => c == .lt,
        .le => c == .lt or c == .eq,
        .gt => c == .gt,
        .ge => c == .gt or c == .eq,
        else => unreachable,
    });
}

pub fn pyHash(vm: *VM, o: Obj) anyerror!u64 {
    switch (o.v) {
        .str => |s| {
            if (s.hash_cache != 0) return @bitCast(s.hash_cache);
            const h = std.hash.Wyhash.hash(0x5eed, s.bytes);
            // кэшируем h как есть; 0 → просто пересчитаем в следующий раз (не портим значение!)
            s.hash_cache = @bitCast(h);
            return h;
        },
        .int => |i| return @bitCast(hashInt(i)),
        .bool_ => |b| return @bitCast(hashInt(@intFromBool(b))),
        .bigint => |b| {
            const i = b.toInt(i64) catch {
                // хеш большого — по строковому представлению (ok)
                const s = try b.toString(vm.rt.gpa, 10, .lower);
                return std.hash.Wyhash.hash(0xb16, s);
            };
            return @bitCast(hashInt(i));
        },
        .float => |f| return floatHash(f),
        .none => return 0x4E0FE,
        .tuple => |t| {
            var h: u64 = 0x345678;
            for (t) |item| {
                const ih = try vm.pyHash(item);
                h = h *% 1000003 ^ ih;
            }
            return h;
        },
        .frozenset => |s| {
            var h: u64 = 0x5e7;
            var it = s.dict.iterAlive();
            while (it.next()) |e| {
                h +%= try vm.pyHash(e.key.?);
            }
            return h;
        },
        else => {
            if (lookupSpecial(vm, o, "__hash__")) |hm| {
                const r = try vm.pyCall(hm, &.{}, null);
                if (r.v == .int) return @bitCast(r.v.int);
                if (r.v == .none) return @intCast(@intFromPtr(o)); // __hash__ = None → unhashable → но упрощённо
                return @intCast(@intFromPtr(o));
            }
            return @intCast(@intFromPtr(o));
        },
    }
}

pub fn hashInt(v: i64) i64 {
    const p: i64 = (1 << 61) - 1;
    var m = @mod(v, p);
    if (m == -1) m = -2;
    return m;
}

fn floatHash(f: f64) u64 {
    if (std.math.isNan(f)) return 0x7FF;
    if (std.math.isPositiveInf(f)) return 314159;
    if (std.math.isNegativeInf(f)) return @bitCast(@as(i64, -314159));
    const fr = @round(f);
    if (f == fr and @abs(f) < 9.0e18) {
        return @bitCast(hashInt(@intFromFloat(fr)));
    }
    return std.hash.Wyhash.hash(0xf10a7, std.mem.asBytes(&f));
}

// ============================================================
// repr / str / ascii
// ============================================================

pub fn pyStr(vm: *VM, o: Obj) anyerror!Obj {
    switch (o.v) {
        .str => return o,
        .none => return vm.rt.newStr("None"),
        .notimpl => return vm.rt.newStr("NotImplemented"),
        .ellipsis => return vm.rt.newStr("Ellipsis"),
        .bool_ => |b| return vm.rt.newStr(if (b) "True" else "False"),
        .int => |i| return vm.rt.newStr(try std.fmt.allocPrint(vm.rt.gpa, "{d}", .{i})),
        .bigint => |b| return vm.rt.newStrOwned(try b.toString(vm.rt.gpa, 10, .lower)),
        .float => |f| return vm.rt.newStr(try floatRepr(vm.rt.gpa, f)),
        .exc => |e| {
            // BaseException.__str__: 0 args→"", 1→str(arg), else repr(args)
            if (e.args.len == 0) return vm.rt.newStr("");
            if (e.args.len == 1) return pyStr(vm, e.args[0]);
            return pyRepr(vm, try vm.rt.newTuple(e.args));
        },
        else => {},
    }
    // Всё остальное структурное (контейнеры/функции/модули/типы): str == repr (как CPython tp_str).
    // __str__ ищем только у пользовательских instance — именно там он переопределяемый.
    if (o.v == .instance) {
        // __str__ считается только когда переопределён пользователем (не object.__str__);
        // иначе — CPython-семантика: str() падает на пользовательский __repr__.
        if (lookupSpecialUser(vm, o, "__str__")) |sm| {
            const r = try vm.pyCall(sm, &.{}, null);
            if (r.v == .str) return r;
            return pyRepr(vm, r);
        }
    }
    return pyRepr(vm, o);
}

pub fn pyRepr(vm: *VM, o: Obj) anyerror!Obj {
    vm.repr_depth += 1;
    defer vm.repr_depth -= 1;
    if (vm.repr_depth > 120) {
        return vm.rt.newStr("...");
    }
    switch (o.v) {
        .str => return reprStr(vm, o.v.str),
        .bytes => |b| return reprBytes(vm, b.data, false),
        .bytearray => |b| return reprBytes(vm, b.data.items, true),
        .none, .notimpl, .ellipsis, .bool_, .int, .bigint, .float => return pyStr(vm, o),
        .list => |l| {
            var buf: std.ArrayList(u8) = .empty;
            try buf.append(vm.rt.gpa, '[');
            for (l.items.items, 0..) |item, i| {
                if (i != 0) try buf.appendSlice(vm.rt.gpa, ", ");
                if (item == o) {
                    try buf.appendSlice(vm.rt.gpa, "[...]");
                    continue;
                }
                const r = try pyRepr(vm, item);
                try buf.appendSlice(vm.rt.gpa, r.v.str.bytes);
            }
            try buf.append(vm.rt.gpa, ']');
            return vm.rt.newStrOwned(try buf.toOwnedSlice(vm.rt.gpa));
        },
        .tuple => |t| {
            var buf: std.ArrayList(u8) = .empty;
            try buf.append(vm.rt.gpa, '(');
            for (t, 0..) |item, i| {
                if (i != 0) try buf.appendSlice(vm.rt.gpa, ", ");
                if (item == o) {
                    try buf.appendSlice(vm.rt.gpa, "(...)");
                    continue;
                }
                const r = try pyRepr(vm, item);
                try buf.appendSlice(vm.rt.gpa, r.v.str.bytes);
            }
            if (t.len == 1) try buf.append(vm.rt.gpa, ',');
            try buf.append(vm.rt.gpa, ')');
            return vm.rt.newStrOwned(try buf.toOwnedSlice(vm.rt.gpa));
        },
        .dict => |d| {
            var buf: std.ArrayList(u8) = .empty;
            try buf.append(vm.rt.gpa, '{');
            var it = d.iterAlive();
            var first = true;
            while (it.next()) |e| {
                if (!first) try buf.appendSlice(vm.rt.gpa, ", ");
                first = false;
                const kr = try pyRepr(vm, e.key.?);
                try buf.appendSlice(vm.rt.gpa, kr.v.str.bytes);
                try buf.appendSlice(vm.rt.gpa, ": ");
                if (e.val.? == o) {
                    try buf.appendSlice(vm.rt.gpa, "{...}");
                } else {
                    const vr = try pyRepr(vm, e.val.?);
                    try buf.appendSlice(vm.rt.gpa, vr.v.str.bytes);
                }
            }
            try buf.append(vm.rt.gpa, '}');
            return vm.rt.newStrOwned(try buf.toOwnedSlice(vm.rt.gpa));
        },
        .set, .frozenset => |s| {
            var buf: std.ArrayList(u8) = .empty;
            if (o.v == .frozenset) try buf.appendSlice(vm.rt.gpa, "frozenset(");
            if (s.dict.len() == 0) {
                if (o.v == .set) {
                    try buf.appendSlice(vm.rt.gpa, "set()");
                }
            } else {
                try buf.append(vm.rt.gpa, '{');
                var it = s.dict.iterAlive();
                var first = true;
                while (it.next()) |e| {
                    if (!first) try buf.appendSlice(vm.rt.gpa, ", ");
                    first = false;
                    const kr = try pyRepr(vm, e.key.?);
                    try buf.appendSlice(vm.rt.gpa, kr.v.str.bytes);
                }
                try buf.append(vm.rt.gpa, '}');
            }
            if (o.v == .frozenset) try buf.append(vm.rt.gpa, ')');
            return vm.rt.newStrOwned(try buf.toOwnedSlice(vm.rt.gpa));
        },
        .range => |r| {
            var buf: std.ArrayList(u8) = .empty;
            if (r.step == 1) {
                try buf.appendSlice(vm.rt.gpa, try std.fmt.allocPrint(vm.rt.gpa, "range({d}, {d})", .{ r.start, r.stop }));
            } else {
                try buf.appendSlice(vm.rt.gpa, try std.fmt.allocPrint(vm.rt.gpa, "range({d}, {d}, {d})", .{ r.start, r.stop, r.step }));
            }
            return vm.rt.newStrOwned(try buf.toOwnedSlice(vm.rt.gpa));
        },
        .slice => |s| {
            const f = struct {
                fn f_(vm_: *VM, x: ?Obj) anyerror![]const u8 {
                    if (x) |v| {
                        if (v.isNone()) return "None";
                        const r = try pyRepr(vm_, v);
                        return r.v.str.bytes;
                    }
                    return "None";
                }
            };
            return vm.rt.newStr(try std.fmt.allocPrint(vm.rt.gpa, "slice({s}, {s}, {s})", .{ try f.f_(vm, s.start), try f.f_(vm, s.stop), try f.f_(vm, s.step) }));
        },
        .function => |f| {
            return vm.rt.newStr(try std.fmt.allocPrint(vm.rt.gpa, "<function {s} at 0x{x}>", .{ f.qualname, @intFromPtr(o) }));
        },
        .builtin => |b| {
            return vm.rt.newStr(try std.fmt.allocPrint(vm.rt.gpa, "<built-in function {s}>", .{b.name}));
        },
        .method => |m| {
            return vm.rt.newStr(try std.fmt.allocPrint(vm.rt.gpa, "<bound method of {s}>", .{m.self_obj.ty.name}));
        },
        .module => |m| {
            return vm.rt.newStr(try std.fmt.allocPrint(vm.rt.gpa, "<module '{s}'>", .{m.name}));
        },
        .type_ => |t| {
            const mod = t.module orelse "builtins";
            if (std.mem.eql(u8, mod, "builtins")) {
                return vm.rt.newStr(try std.fmt.allocPrint(vm.rt.gpa, "<class '{s}'>", .{t.name}));
            }
            return vm.rt.newStr(try std.fmt.allocPrint(vm.rt.gpa, "<class '{s}.{s}'>", .{ mod, t.qualname }));
        },
        .code => |c| {
            return vm.rt.newStr(try std.fmt.allocPrint(vm.rt.gpa, "<code object {s} at 0x{x}, file \"{s}\", line {d}>", .{ c.name, @intFromPtr(o), c.filename, c.firstlineno }));
        },
        .generator => {
            return vm.rt.newStr(try std.fmt.allocPrint(vm.rt.gpa, "<generator object at 0x{x}>", .{@intFromPtr(o)}));
        },
        .property => return vm.rt.newStr("<property object>"),
        .exc => |e| {
            if (e.args.len == 0) {
                return vm.rt.newStr(try std.fmt.allocPrint(vm.rt.gpa, "{s}()", .{o.ty.name}));
            }
            if (e.args.len == 1) {
                const a1 = try pyRepr(vm, e.args[0]);
                return vm.rt.newStr(try std.fmt.allocPrint(vm.rt.gpa, "{s}({s})", .{ o.ty.name, a1.v.str.bytes }));
            }
            const ta = try pyRepr(vm, try vm.rt.newTuple(e.args));
            return vm.rt.newStr(try std.fmt.allocPrint(vm.rt.gpa, "{s}{s}", .{ o.ty.name, ta.v.str.bytes }));
        },
        .instance => {
            if (lookupSpecialUser(vm, o, "__repr__")) |rm| {
                const r = try vm.pyCall(rm, &.{}, null);
                if (r.v == .str) return r;
                return vm.rt.newStr("<bad repr>");
            }
            return defaultRepr(vm, o);
        },
        else => {
            if (lookupSpecial(vm, o, "__repr__")) |rm| {
                const r = try vm.pyCall(rm, &.{}, null);
                if (r.v == .str) return r;
            }
            return defaultRepr(vm, o);
        },
    }
}

fn defaultRepr(vm: *VM, o: Obj) anyerror!Obj {
    const mod = o.ty.module orelse "builtins";
    if (std.mem.eql(u8, mod, "builtins")) {
        return vm.rt.newStr(try std.fmt.allocPrint(vm.rt.gpa, "<{s} object at 0x{x}>", .{ o.ty.name, @intFromPtr(o) }));
    }
    return vm.rt.newStr(try std.fmt.allocPrint(vm.rt.gpa, "<{s}.{s} object at 0x{x}>", .{ mod, o.ty.name, @intFromPtr(o) }));
}

fn reprStr(vm: *VM, s: *object.Str) anyerror!Obj {
    var buf: std.ArrayList(u8) = .empty;
    const g = vm.rt.gpa;
    // выбираем кавычку
    const has_sq = std.mem.indexOfScalar(u8, s.bytes, '\'') != null;
    const has_dq = std.mem.indexOfScalar(u8, s.bytes, '"') != null;
    const q: u8 = if (has_sq and !has_dq) '"' else '\'';
    try buf.append(g, q);
    var i: usize = 0;
    while (i < s.bytes.len) {
        const l = std.unicode.utf8ByteSequenceLength(s.bytes[i]) catch 1;
        if (i + l > s.bytes.len) {
            try buf.append(g, '?');
            i += 1;
            continue;
        }
        const cp = std.unicode.utf8Decode(s.bytes[i .. i + l]) catch {
            try buf.append(g, '?');
            i += 1;
            continue;
        };
        switch (cp) {
            '\\' => try buf.appendSlice(g, "\\\\"),
            '\n' => try buf.appendSlice(g, "\\n"),
            '\r' => try buf.appendSlice(g, "\\r"),
            '\t' => try buf.appendSlice(g, "\\t"),
            0x27, 0x22 => { // ' "
                if (cp == q) {
                    try buf.append(g, '\\');
                    try buf.append(g, q);
                } else {
                    try buf.append(g, @intCast(cp));
                }
            },
            else => {
                if (cp < 32 or cp == 0x7f) {
                    try buf.appendSlice(g, try std.fmt.allocPrint(g, "\\x{x:0>2}", .{cp}));
                } else {
                    try buf.appendSlice(g, s.bytes[i .. i + l]);
                }
            },
        }
        i += l;
    }
    try buf.append(g, q);
    return vm.rt.newStrOwned(try buf.toOwnedSlice(g));
}

fn reprBytes(vm: *VM, data: []const u8, is_byte_array: bool) anyerror!Obj {
    var buf: std.ArrayList(u8) = .empty;
    const g = vm.rt.gpa;
    if (is_byte_array) try buf.appendSlice(g, "bytearray(");
    try buf.appendSlice(g, "b'");
    for (data) |c| {
        switch (c) {
            '\\' => try buf.appendSlice(g, "\\\\"),
            '\n' => try buf.appendSlice(g, "\\n"),
            '\r' => try buf.appendSlice(g, "\\r"),
            '\t' => try buf.appendSlice(g, "\\t"),
            '\'' => try buf.appendSlice(g, "\\'"),
            else => {
                if (c < 32 or c >= 0x7f) {
                    try buf.appendSlice(g, try std.fmt.allocPrint(g, "\\x{x:0>2}", .{c}));
                } else {
                    try buf.append(g, c);
                }
            },
        }
    }
    try buf.append(g, '\'');
    if (is_byte_array) try buf.append(g, ')');
    return vm.rt.newStrOwned(try buf.toOwnedSlice(g));
}

pub fn floatRepr(gpa: std.mem.Allocator, f: f64) ![]const u8 {
    if (std.math.isNan(f)) return gpa.dupe(u8, "nan");
    if (std.math.isPositiveInf(f)) return gpa.dupe(u8, "inf");
    if (std.math.isNegativeInf(f)) return gpa.dupe(u8, "-inf");
    var buf: [64]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{f}) catch return gpa.dupe(u8, "0.0");
    // Python: всегда есть точка или экспонента
    if (std.mem.indexOfAny(u8, s, ".eE") == null) {
        return std.fmt.allocPrint(gpa, "{s}.0", .{s});
    }
    return gpa.dupe(u8, s);
}
