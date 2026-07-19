//! Система импорта — аналог Python/import.c + __build_class__ (Python/bltinmodule.c).
//!
//! Резолвер:
//!   1. sys.modules (кэш)
//!   2. нативные модули (registry из stdlib/*.zig)
//!   3. frozen/встроенный lib (vendored .py рядом с бинарём: lib/python3.13/)
//!   4. sys.path: каждая директория: pkg/mod.py, pkg/mod/__init__.py, ./mod.py
//!
//! Относительные импорты — через __package__ текущего модуля.

const std = @import("std");
const object = @import("../object/object.zig");
const runtime_mod = @import("runtime.zig");
const ops = @import("../vm/ops.zig");
const vm_mod = @import("../vm/vm.zig");
const compiler = @import("../compiler/compiler.zig");
const bltn = @import("builtins.zig");

const Runtime = runtime_mod.Runtime;
const VM = vm_mod.VM;
const Obj = object.Obj;
const Type = object.Type;
const Dict = object.Dict;
const KwArgs = object.KwArgs;
const Module = object.Module;

const typeErr = bltn.typeErr;

/// Нативный модуль: имя + конструктор.
pub const NativeModule = struct {
    name: []const u8,
    init: *const fn (vm: *VM) anyerror!Obj,
};

/// Реестр нативных модулей, заполняется из root.zig при инициализации.
pub var native_modules: []const NativeModule = &.{};

pub fn findNative(name: []const u8) ?*const NativeModule {
    for (native_modules) |*m| {
        if (std.mem.eql(u8, m.name, name)) return m;
    }
    return null;
}

// ============================================================
// __import__
// ============================================================

pub fn bi_import(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    if (args.len < 1 or args[0].v != .str) return typeErr(v, "__import__() argument 1 must be str", .{});
    const name = args[0].v.str.bytes;
    const level: i64 = if (args.len >= 5 and args[4].v == .int) args[4].v.int else 0;
    const fromlist: ?Obj = if (args.len >= 4 and args[3].v != .none and args[3].v != .bool_) args[3] else null;
    const globals: *Dict = if (args.len >= 2 and args[1].v == .dict) args[1].v.dict else currentGlobals(v);
    return importModule(v, name, level, fromlist, globals, null);
}

fn currentGlobals(v: *VM) *Dict {
    const ts = v.currentTS();
    if (ts.frames.items.len > 0) {
        return ts.frames.items[ts.frames.items.len - 1].globals;
    }
    return v.rt.builtins_dict;
}

/// Полный импорт: возвращает целевой модуль (для fromlist) или верхний пакет.
pub fn importModule(v: *VM, name: []const u8, level: i64, fromlist: ?Obj, globals: *Dict, frame: ?*object.Frame) anyerror!Obj {
    _ = frame;
    const rt = v.rt;
    if (level > 0) {
        // относительный: нужен пакет текущего модуля
        var pkg_name: []const u8 = "";
        if (try ops.dictGetStr(globals, v, "__package__")) |p| {
            if (p.v == .str) pkg_name = p.v.str.bytes;
        } else if (try ops.dictGetStr(globals, v, "__name__")) |n| {
            if (n.v == .str) {
                pkg_name = n.v.str.bytes;
                // пакет модуля a.b.c — a.b (если c не пакет)
                if (std.mem.lastIndexOfScalar(u8, pkg_name, '.')) |dot| {
                    pkg_name = pkg_name[0..dot];
                } else {
                    pkg_name = "";
                }
            }
        }
        // подняться level-1 раз
        var i: i64 = 1;
        while (i < level) : (i += 1) {
            if (std.mem.lastIndexOfScalar(u8, pkg_name, '.')) |dot| {
                pkg_name = pkg_name[0..dot];
            } else {
                pkg_name = "";
            }
        }
        var buf: std.ArrayList(u8) = .empty;
        try buf.appendSlice(rt.gpa, pkg_name);
        if (name.len > 0) {
            if (pkg_name.len > 0) try buf.append(rt.gpa, '.');
            try buf.appendSlice(rt.gpa, name);
        }
        const abs_name = buf.items;
        const m = try loadModule(v, abs_name);
        if (fromlist != null) return m;
        // import .sub → верхний уровень пакета
        const top = firstPart(abs_name);
        if (std.mem.eql(u8, top, abs_name)) return m;
        return sysModulesGet(v, top) orelse m;
    }
    if (name.len == 0) {
        try v.raiseStr("ValueError", "Empty module name");
        return error.PyExc;
    }
    const m = try loadModule(v, name);
    if (fromlist != null) {
        // from a.b import x → нужен a.b; гарантируем импорт подмодулей из fromlist
        if (fromlist.?.v == .tuple) {
            for (fromlist.?.v.tuple) |fl| {
                if (fl.v != .str) continue;
                const sub = fl.v.str.bytes;
                if (std.mem.eql(u8, sub, "*")) continue;
                if ((try ops.dictGetStr(m.v.module.dict, v, sub)) == null) {
                    // может это подмодуль — импортируем
                    var buf: std.ArrayList(u8) = .empty;
                    try buf.appendSlice(rt.gpa, name);
                    try buf.append(rt.gpa, '.');
                    try buf.appendSlice(rt.gpa, sub);
                    _ = loadModule(v, buf.items) catch |e| {
                        if (e == error.PyExc) {
                            v.currentTS().cur_exc = null; // мягкий fallback на атрибут
                            continue;
                        }
                        return e;
                    };
                }
            }
        }
        return m;
    }
    // import a.b.c → вернуть верхний a
    if (std.mem.indexOfScalar(u8, name, '.') != null) {
        return sysModulesGet(v, firstPart(name)) orelse m;
    }
    return m;
}

pub fn firstPart(name: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, name, '.')) |dot| return name[0..dot];
    return name;
}

/// sys.modules.get(name)
pub fn sysModulesGet(v: *VM, name: []const u8) ?Obj {
    var it = v.rt.modules.iterAlive();
    while (it.next()) |e| {
        if (e.key.?.v == .str and std.mem.eql(u8, e.key.?.v.str.bytes, name)) return e.val;
    }
    return null;
}

/// IMPORT_FROM: достать атрибут у модуля; при отсутствии — попробовать подмодуль.
pub fn importFrom(v: *VM, mod: Obj, name: []const u8) anyerror!Obj {
    if (mod.v != .module) {
        try v.raiseStr("ImportError", "from-import of a non-module object");
        return error.PyExc;
    }
    const d = mod.v.module.dict;
    const k = try v.rt.newStr(name);
    const h = try v.rt.pyHash(k);
    if (try d.getWithHash(v.rt, k, h)) |o| return o;
    // может быть подмодулем пакета
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(v.rt.gpa, mod.v.module.name);
    try buf.append(v.rt.gpa, '.');
    try buf.appendSlice(v.rt.gpa, name);
    if (loadModule(v, buf.items)) |sub| {
        return sub;
    } else |e| {
        if (e == error.PyExc) {
            v.currentTS().cur_exc = null;
        } else return e;
    }
    try v.raiseFmt("ImportError", "cannot import name '{s}' from '{s}'", .{ name, mod.v.module.name });
    return error.PyExc;
}

pub fn sysModulesPut(v: *VM, name: []const u8, m: Obj) !void {
    const kobj = try v.rt.newStr(name);
    const h = try v.pyHash(kobj);
    try v.rt.modules.setWithHash(v, kobj, m, h);
}

/// sys.modules[name] = m (m.obj известен)
fn sysModulesPutObj(v: *VM, m: Obj) !void {
    try sysModulesPut(v, m.v.module.name, m);
}

/// Импорт модуля по абсолютному имени (a.b.c), с кэшем и регистрацией родителей.
pub fn loadModule(v: *VM, name: []const u8) anyerror!Obj {
    if (sysModulesGet(v, name)) |m| return m;
    // родитель пакета (a.b → a)
    var parent: ?Obj = null;
    var leaf: []const u8 = name;
    if (std.mem.lastIndexOfScalar(u8, name, '.')) |dot| {
        parent = try loadModule(v, name[0..dot]);
        leaf = name[dot + 1 ..];
    }
    // 1. нативный (только верхний уровень или зарегистрированный полный путь)
    if (findNative(name)) |nm| {
        const m = try nm.init(v);
        try sysModulesPut(v, name, m);
        if (parent) |p| try linkSubmodule(v, p, leaf, m);
        return m;
    }
    // 2. файловая система: директории поиска
    const found = try findModuleFile(v, name, parent);
    if (found == null) {
        try v.raiseFmt("ModuleNotFoundError", "No module named '{s}'", .{name});
        return error.PyExc;
    }
    const m = try loadFromFile(v, name, found.?);
    if (parent) |p| try linkSubmodule(v, p, leaf, m);
    return m;
}

fn linkSubmodule(v: *VM, parent: Obj, leaf: []const u8, m: Obj) !void {
    // parent.leaf = m
    try ops.dictSetStr(parent.v.module.dict, v, leaf, m);
}

const FoundFile = struct {
    path: []const u8,
    is_package: bool,
    pkg_dir: ?[]const u8 = null,
};

/// Поиск файла модуля в sys.path и штатных lib-директориях.
fn findModuleFile(v: *VM, name: []const u8, parent: ?Obj) anyerror!?FoundFile {
    const rt = v.rt;
    var rel_buf: std.ArrayList(u8) = .empty;
    for (name) |c| {
        try rel_buf.append(rt.gpa, if (c == '.') '/' else c);
    }
    // если есть родитель-пакет с __path__ — искать только там
    var search_dirs: std.ArrayList([]const u8) = .empty;
    if (parent) |p| {
        if (try ops.dictGetStr(p.v.module.dict, v, "__path__")) |pp| {
            if (pp.v == .list) {
                for (pp.v.list.items.items) |d| {
                    if (d.v == .str) try search_dirs.append(rt.gpa, d.v.str.bytes);
                }
            }
        }
        // имя листа без пакета
        if (std.mem.lastIndexOfScalar(u8, name, '.')) |dot| {
            rel_buf.clearRetainingCapacity();
            try rel_buf.appendSlice(rt.gpa, name[dot + 1 ..]);
        }
    }
    if (search_dirs.items.len == 0) {
        // lib-директория интерпретатора + sys.path
        if (rt.lib_dir) |ld| try search_dirs.append(rt.gpa, ld);
        for (rt.sys_path.items.items) |d| {
            if (d.v == .str) try search_dirs.append(rt.gpa, d.v.str.bytes);
        }
    }
    const io = rt.io orelse return null;
    for (search_dirs.items) |dir| {
        // dir/name.py
        {
            const p = try std.fmt.allocPrint(rt.gpa, "{s}/{s}.py", .{ dir, rel_buf.items });
            if (fileExists(io, p)) {
                return FoundFile{ .path = p, .is_package = false };
            }
        }
        // dir/name/__init__.py
        {
            const pkg_dir = try std.fmt.allocPrint(rt.gpa, "{s}/{s}", .{ dir, rel_buf.items });
            const p = try std.fmt.allocPrint(rt.gpa, "{s}/__init__.py", .{pkg_dir});
            if (fileExists(io, p)) {
                return FoundFile{ .path = p, .is_package = true, .pkg_dir = pkg_dir };
            }
        }
    }
    return null;
}

fn fileExists(io: std.Io, path: []const u8) bool {
    var f = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    f.close(io);
    return true;
}

/// Прочитать файл целиком (через std.Io)
pub fn readFileAlloc(v: *VM, path: []const u8) anyerror![]u8 {
    const io = v.rt.io orelse {
        try v.raiseStr("RuntimeError", "io subsystem is not initialized");
        return error.PyExc;
    };
    var f = std.Io.Dir.cwd().openFile(io, path, .{}) catch |e| {
        return bltn.ioErr(v, e, path);
    };
    defer f.close(io);
    const len = f.length(io) catch |e| return bltn.ioErr(v, e, path);
    const buf = try v.rt.gpa.alloc(u8, @intCast(len));
    var got: usize = 0;
    while (got < buf.len) {
        const n = f.readPositional(io, &.{buf[got..]}, got) catch |e| {
            return bltn.ioErr(v, e, path);
        };
        if (n == 0) break;
        got += n;
    }
    return buf[0..got];
}

fn loadFromFile(v: *VM, name: []const u8, ff: FoundFile) anyerror!Obj {
    const rt = v.rt;
    const src = try readFileAlloc(v, ff.path);
    const code = compiler.compileSource(v, ff.path, src, .exec) catch |e| {
        if (e == error.PyExc) return error.PyExc;
        return e;
    };
    const m = try rt.newModuleObj(name);
    // сразу в sys.modules — циклические импорты видят частичный модуль
    try sysModulesPutObj(v, m);
    const md = m.v.module;
    md.file = ff.path;
    try ops.dictSetStr(md.dict, v, "__name__", try rt.newStr(name));
    try ops.dictSetStr(md.dict, v, "__file__", try rt.newStr(ff.path));
    if (ff.is_package) {
        const path_list = try rt.newList();
        try path_list.v.list.items.append(rt.gpa, try rt.newStr(ff.pkg_dir.?));
        try ops.dictSetStr(md.dict, v, "__path__", path_list);
        try ops.dictSetStr(md.dict, v, "__package__", try rt.newStr(name));
    } else {
        const pkg = if (std.mem.lastIndexOfScalar(u8, name, '.')) |dot| name[0..dot] else "";
        try ops.dictSetStr(md.dict, v, "__package__", try rt.newStr(pkg));
    }
    try ops.dictSetStr(md.dict, v, "__builtins__", try v.rt.mkObj(v.rt.dict_t, .{ .dict = v.rt.builtins_dict }));
    v.runNameScope(code, md.dict, null) catch |e| {
        // исключение при загрузке → удалить из sys.modules (как CPython)
        const kobj = rt.newStr(name) catch return error.PyExc;
        const h = v.pyHash(kobj) catch 0;
        _ = v.rt.modules.delWithHash(v, kobj, h) catch false;
        return e;
    };
    return m;
}

// ============================================================
// __build_class__
// ============================================================

pub fn bi_build_class(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    const v: *VM = vm;
    if (args.len < 2) return typeErr(v, "__build_class__ requires at least 2 arguments", .{});
    const func = args[0];
    const name_obj = args[1];
    if (name_obj.v != .str) return typeErr(v, "__build_class__ name must be str", .{});
    const name = name_obj.v.str.bytes;
    const bases: []const Obj = args[2..];

    // определить метакласс: kw metaclass= или самый производный метатип баз
    var metaclass: *Type = v.rt.type_t;
    if (kw) |k| {
        if (k.get("metaclass")) |mc| {
            if (mc.v != .type_) return typeErr(v, "metaclass must be a type", .{});
            metaclass = mc.v.type_;
        }
    }
    for (bases) |b| {
        if (b.v != .type_) return typeErr(v, "bases must be types", .{});
        const bt = b.ty;
        if (mostDerivedMeta(bt, metaclass)) metaclass = bt;
    }
    // проверка конфликтов (упрощённо: winner должен быть подклассом остальных)
    for (bases) |b| {
        const bt = b.ty;
        if (!ops.isSubclass(metaclass, bt) and !ops.isSubclass(bt, metaclass)) {
            try v.raiseFmt("TypeError", "metaclass conflict: the metaclass of a derived class must be a (non-strict) subclass of the metaclasses of all its bases", .{});
            return error.PyExc;
        }
    }

    if (metaclass != v.rt.type_t) {
        // metaclass(name, bases, ns, **kw): выполнить тело, собрать ns и вызвать метакласс
        const ns = try execClassBody(v, func, name);
        const nb = try basesToTypes(v, bases);
        _ = nb;
        const base_tuple = try v.rt.newTuple(bases);
        const ns_obj = try v.rt.mkObj(v.rt.dict_t, .{ .dict = ns });
        const name_s = try v.rt.newStr(name);
        const mc_obj = try v.rt.mkObj(v.rt.type_t, .{ .type_ = metaclass });
        return v.pyCall(mc_obj, &.{ name_s, base_tuple, ns_obj }, kw);
    }

    // обычный класс
    const ns = try execClassBody(v, func, name);
    const cls = try v.rt.newUserType(name, v, bases, ns);
    return v.rt.mkObj(v.rt.type_t, .{ .type_ = cls });
}

fn basesToTypes(v: *VM, bases: []const Obj) ![]const *Type {
    const out = try v.rt.gpa.alloc(*Type, bases.len);
    for (bases, 0..) |b, i| out[i] = b.v.type_;
    return out;
}

/// Выполнить тело класса: вернуть dict пространства имён.
fn execClassBody(v: *VM, func: Obj, name: []const u8) anyerror!*Dict {
    if (func.v != .function) return typeErr(v, "__build_class__ body must be a function", .{});
    const f = func.v.function;
    const ns = try v.rt.newDict();
    const frame = try v.makeFrame(f, &.{}, null);
    frame.locals_dict = ns;
    const ts = v.currentTS();
    const mark = ts.frames.items.len;
    try ts.frames.append(v.gpa, frame);
    try v.runUntil(ts, mark);
    // __qualname__ если отсутствует
    if ((try ops.dictGetStr(ns, v, "__qualname__")) == null) {
        try ops.dictSetStr(ns, v, "__qualname__", try v.rt.newStr(name));
    }
    return ns;
}

/// true, если метакласс `a` производнее `b` (a — подкласс b, но не наоборот... строго: a подкласс b).
fn mostDerivedMeta(a: *Type, b: *Type) bool {
    return ops.isSubclass(a, b) and !ops.isSubclass(b, a);
}
