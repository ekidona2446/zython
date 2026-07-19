//! builtins — аналог Python/bltinmodule.c + методы встроенных типов (Objects/*.c).
//!
//! Регистрация выполняется один раз при инициализации интерпретатора.
//! Все функции имеют тип object.BuiltinFn: вызываются VM с *VM.

const std = @import("std");
const object = @import("../object/object.zig");
const runtime_mod = @import("runtime.zig");
const ops = @import("../vm/ops.zig");
const vm_mod = @import("../vm/vm.zig");
const import_mod = @import("import.zig");

const Runtime = runtime_mod.Runtime;
const VM = vm_mod.VM;
const Obj = object.Obj;
const Type = object.Type;
const Dict = object.Dict;
const KwArgs = object.KwArgs;

// ============================================================
// Служебные helper'ы регистрации (работают на *Runtime до старта VM)
// ============================================================

fn dictPutStartup(rt: *Runtime, d: *Dict, name: []const u8, val: Obj) !void {
    const kobj = try rt.newStr(name);
    const h = try rt.pyHash(kobj);
    try d.setWithHash(rt, kobj, val, h);
}

/// methods on type
fn td(rt: *Runtime, ty: *Type, name: []const u8, comptime f: anytype) !void {
    const fnobj = try rt.newBuiltin(name, object.wrapBuiltin(f));
    try dictPutStartup(rt, ty.dict, name, fnobj);
}

/// function in builtins module
fn bd(rt: *Runtime, name: []const u8, comptime f: anytype) !void {
    const fnobj = try rt.newBuiltin(name, object.wrapBuiltin(f));
    try dictPutStartup(rt, rt.builtins_dict, name, fnobj);
}

/// object in builtins module
fn bdo(rt: *Runtime, name: []const u8, val: Obj) !void {
    try dictPutStartup(rt, rt.builtins_dict, name, val);
}

/// type object value (type_t-обёртка) в builtins
fn bdt(rt: *Runtime, ty: *Type) !void {
    const tobj = try rt.mkObj(rt.type_t, .{ .type_ = ty });
    try dictPutStartup(rt, rt.builtins_dict, ty.name, tobj);
}

fn kwGet(kw: ?KwArgs, name: []const u8) ?Obj {
    if (kw) |k| return k.get(name);
    return null;
}

// ============================================================
// Иерархия исключений (аналог Objects/exceptions.c)
// ============================================================

const ExcDef = struct { name: []const u8, base: []const u8 };

const exc_tree = [_]ExcDef{
    .{ .name = "BaseException", .base = "" },
    .{ .name = "SystemExit", .base = "BaseException" },
    .{ .name = "KeyboardInterrupt", .base = "BaseException" },
    .{ .name = "GeneratorExit", .base = "BaseException" },
    .{ .name = "Exception", .base = "BaseException" },
    .{ .name = "ArithmeticError", .base = "Exception" },
    .{ .name = "ZeroDivisionError", .base = "ArithmeticError" },
    .{ .name = "OverflowError", .base = "ArithmeticError" },
    .{ .name = "FloatingPointError", .base = "ArithmeticError" },
    .{ .name = "AssertionError", .base = "Exception" },
    .{ .name = "AttributeError", .base = "Exception" },
    .{ .name = "BufferError", .base = "Exception" },
    .{ .name = "EOFError", .base = "Exception" },
    .{ .name = "ImportError", .base = "Exception" },
    .{ .name = "ModuleNotFoundError", .base = "ImportError" },
    .{ .name = "LookupError", .base = "Exception" },
    .{ .name = "IndexError", .base = "LookupError" },
    .{ .name = "KeyError", .base = "LookupError" },
    .{ .name = "MemoryError", .base = "Exception" },
    .{ .name = "NameError", .base = "Exception" },
    .{ .name = "UnboundLocalError", .base = "NameError" },
    .{ .name = "OSError", .base = "Exception" },
    .{ .name = "BlockingIOError", .base = "OSError" },
    .{ .name = "ConnectionError", .base = "OSError" },
    .{ .name = "BrokenPipeError", .base = "ConnectionError" },
    .{ .name = "ConnectionAbortedError", .base = "ConnectionError" },
    .{ .name = "ConnectionRefusedError", .base = "ConnectionError" },
    .{ .name = "ConnectionResetError", .base = "ConnectionError" },
    .{ .name = "FileExistsError", .base = "OSError" },
    .{ .name = "FileNotFoundError", .base = "OSError" },
    .{ .name = "InterruptedError", .base = "OSError" },
    .{ .name = "IsADirectoryError", .base = "OSError" },
    .{ .name = "NotADirectoryError", .base = "OSError" },
    .{ .name = "PermissionError", .base = "OSError" },
    .{ .name = "ProcessLookupError", .base = "OSError" },
    .{ .name = "TimeoutError", .base = "OSError" },
    .{ .name = "ReferenceError", .base = "Exception" },
    .{ .name = "RuntimeError", .base = "Exception" },
    .{ .name = "NotImplementedError", .base = "RuntimeError" },
    .{ .name = "RecursionError", .base = "RuntimeError" },
    .{ .name = "StopIteration", .base = "Exception" },
    .{ .name = "StopAsyncIteration", .base = "Exception" },
    .{ .name = "SyntaxError", .base = "Exception" },
    .{ .name = "IndentationError", .base = "SyntaxError" },
    .{ .name = "TabError", .base = "IndentationError" },
    .{ .name = "SystemError", .base = "Exception" },
    .{ .name = "TypeError", .base = "Exception" },
    .{ .name = "ValueError", .base = "Exception" },
    .{ .name = "UnicodeError", .base = "ValueError" },
    .{ .name = "UnicodeDecodeError", .base = "UnicodeError" },
    .{ .name = "UnicodeEncodeError", .base = "UnicodeError" },
    .{ .name = "UnicodeTranslateError", .base = "UnicodeError" },
    .{ .name = "Warning", .base = "Exception" },
    .{ .name = "DeprecationWarning", .base = "Warning" },
    .{ .name = "PendingDeprecationWarning", .base = "Warning" },
    .{ .name = "SyntaxWarning", .base = "Warning" },
    .{ .name = "RuntimeWarning", .base = "Warning" },
    .{ .name = "FutureWarning", .base = "Warning" },
    .{ .name = "ImportWarning", .base = "Warning" },
    .{ .name = "UnicodeWarning", .base = "Warning" },
    .{ .name = "BytesWarning", .base = "Warning" },
    .{ .name = "ResourceWarning", .base = "Warning" },
    .{ .name = "UserWarning", .base = "Warning" },
};

fn registerExceptions(rt: *Runtime) !void {
    for (exc_tree) |d| {
        const base: *Type = if (d.base.len == 0) rt.object_t else rt.exc_types.get(d.base).?;
        const ty = try rt.mkType(d.name, base);
        ty.flags.exc = true;
        try rt.exc_types.put(d.name, ty);
        try td(rt, ty, "__init__", exc_init);
        try td(rt, ty, "__str__", exc_str);
        try td(rt, ty, "with_traceback", exc_with_traceback);
        try bdt(rt, ty);
        if (std.mem.eql(u8, d.name, "BaseException")) rt.base_exception_t = ty;
        if (std.mem.eql(u8, d.name, "Exception")) rt.exception_t = ty;
    }
    // getset'ы BaseException (exceptions.c: BaseException_getsets) — наследуются всеми
    const be = rt.base_exception_t;
    try excProp(rt, be, "__cause__", exc_get_cause);
    try excProp(rt, be, "__context__", exc_get_context);
    try excProp(rt, be, "__suppress_context__", exc_get_suppress);
    try excProp(rt, be, "args", exc_get_args);
    try excProp(rt, be, "__traceback__", exc_get_traceback);
}

fn excProp(rt: *Runtime, ty: *Type, name: []const u8, comptime f: anytype) !void {
    const prop = try rt.newProperty(.{ .fget = try rt.newBuiltin(name, object.wrapBuiltin(f)) });
    try dictPutStartup(rt, ty.dict, name, prop);
}

fn exc_get_cause(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    return args[0].v.exc.cause orelse vm.rt.newNone();
}

fn exc_get_context(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    return args[0].v.exc.context orelse vm.rt.newNone();
}

fn exc_get_suppress(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    return vm.rt.newBool(args[0].v.exc.suppress_context);
}

fn exc_get_args(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    return vm.rt.newTuple(args[0].v.exc.args);
}

/// BaseException.__traceback__ → traceback-объект (tb_frame/tb_next/tb_lineno) или None.
fn exc_get_traceback(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const rt = v.rt;
    if (args[0].v != .exc) return rt.newNone();
    const e = args[0].v.exc;
    if (e.tb.items.len == 0) return rt.newNone();
    const last = e.tb.items[e.tb.items.len - 1];
    // frame-объект
    const fr = try rt.newInstance(rt.frame_t);
    try ops.dictSetStr(&fr.v.instance.dict, v, "f_lineno", try rt.newInt(last.lineno));
    try ops.dictSetStr(&fr.v.instance.dict, v, "f_lasti", try rt.newInt(0));
    try ops.dictSetStr(&fr.v.instance.dict, v, "f_code", rt.newNone());
    // traceback-объект
    const tb = try rt.newInstance(rt.traceback_t);
    try ops.dictSetStr(&tb.v.instance.dict, v, "tb_frame", fr);
    try ops.dictSetStr(&tb.v.instance.dict, v, "tb_next", rt.newNone());
    try ops.dictSetStr(&tb.v.instance.dict, v, "tb_lineno", try rt.newInt(last.lineno));
    try ops.dictSetStr(&tb.v.instance.dict, v, "tb_lasti", try rt.newInt(0));
    return tb;
}

/// BaseException.__init__: сохраняет args
fn exc_init(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const self_obj = args[0];
    const exc_args = args[1..];
    const e = self_obj.v.exc;
    const cp = try vm.rt.gpa.alloc(Obj, exc_args.len);
    @memcpy(cp, exc_args);
    e.args = cp;
    return vm.rt.newNone();
}

/// BaseException.__str__: '' / str(args[0]) / str(args)
fn exc_str(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const self_obj = args[0];
    const e = self_obj.v.exc;
    if (e.args.len == 0) return vm.rt.newStr("");
    if (e.args.len == 1) return ops.pyStr(vm, e.args[0]);
    const tup = try vm.rt.newTuple(e.args);
    return ops.pyRepr(vm, tup);
}

fn exc_with_traceback(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    _ = vm;
    return args[0];
}

// ============================================================
// Топ-уровневая регистрация
// ============================================================

pub fn registerAll(rt: *Runtime) !void {
    const tstr = @import("methods/typestr.zig");
    const tmisc = @import("methods/typemisc.zig");
    try registerExceptions(rt);
    try registerSingletons(rt);
    try registerBuiltinTypes(rt);
    try registerFunctions(rt);
    try tstr.registerObjectMethods(rt);
    try tstr.registerTypeMethods(rt);
    try tstr.registerStrMethods(rt);
    try tstr.registerListMethods(rt);
    try tstr.registerDictMethods(rt);
    try tstr.registerSetMethods(rt);
    try tstr.registerTupleMethods(rt);
    try tmisc.registerIntFloatMethods(rt);
    try tmisc.registerBytesMethods(rt);
    try tmisc.registerRangeSliceMethods(rt);
    try tmisc.registerGeneratorMethods(rt);
    try tmisc.registerPropertySuperMethods(rt);
    try tmisc.registerFileMethods(rt);
    // object.__class_getitem__ — generic-подписка для всех типов (list[int], Generic[...])
    try td(rt, rt.object_t, "__class_getitem__", obj_class_getitem);
    // Дескрипторы типа function: types.py делает type(function.__code__) и т.п.
    // Доступ к __code__/__globals__/... на *экземпляре* функции идёт через спец-блок
    // pyGetAttr(.function); здесь нужны заглушки-дескрипторы для доступа на самом типе.
    for ([_][]const u8{ "__code__", "__globals__", "__defaults__", "__kwdefaults__", "__closure__", "__annotations__", "__name__", "__qualname__", "__doc__", "__module__", "__dict__" }) |nm| {
        const prop = try rt.newProperty(.{ .fget = null });
        try dictPutStartup(rt, rt.function_t.dict, nm, prop);
    }
}

/// object.__class_getitem__(cls, item) → GenericAlias (минимально: кортеж (cls, item)).
fn obj_class_getitem(vm: anytype, args: []const Obj, kw: ?object.KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    if (args.len >= 2) {
        return v.rt.newTuple(&.{ args[0], args[1] });
    }
    if (args.len == 1) return args[0];
    return v.rt.newNone();
}

fn registerSingletons(rt: *Runtime) !void {
    try bdo(rt, "None", rt.newNone());
    try bdo(rt, "True", rt.true_obj);
    try bdo(rt, "False", rt.false_obj);
    try bdo(rt, "Ellipsis", rt.ellipsis_obj);
    try bdo(rt, "NotImplemented", rt.notimpl_obj);
    try bdo(rt, "__debug__", rt.true_obj);
    try bd(rt, "__build_class__", import_mod.bi_build_class);
    try bd(rt, "__import__", import_mod.bi_import);
}

fn registerBuiltinTypes(rt: *Runtime) !void {
    try bdt(rt, rt.object_t);
    try bdt(rt, rt.type_t);
    try bdt(rt, rt.int_t);
    try bdt(rt, rt.bool_t);
    try bdt(rt, rt.float_t);
    try bdt(rt, rt.bytes_t);
    try bdt(rt, rt.bytearray_t);
    try bdt(rt, rt.str_t);
    try bdt(rt, rt.list_t);
    try bdt(rt, rt.tuple_t);
    try bdt(rt, rt.dict_t);
    try bdt(rt, rt.set_t);
    try bdt(rt, rt.frozenset_t);
    try bdt(rt, rt.range_t);
    try bdt(rt, rt.slice_t);
    try bdt(rt, rt.property_t);
    try bdt(rt, rt.staticm_t);
    try bdt(rt, rt.classm_t);
    rt.staticm_t.tp_new = staticm_new;
    rt.classm_t.tp_new = classm_new;
    {
        const tn = try rt.newBuiltin("__new__", object.wrapBuiltin(type_new));
        const sm = try rt.newStaticM(tn);
        try dictPutStartup(rt, rt.type_t.dict, "__new__", sm);
    }
    {
        const on = try rt.newBuiltin("__new__", object.wrapBuiltin(object_new));
        const sm = try rt.newStaticM(on);
        try dictPutStartup(rt, rt.object_t.dict, "__new__", sm);
    }
    try bdt(rt, rt.super_t);
    // __new__ в dict builtin-типов: нужно enum._find_data_type ('__new__' in int.__dict__).
    // Вызов типа идёт через tp_new (приоритетнее), так что это только маркер наличия.
    {
        const bn = try rt.newBuiltin("__new__", object.wrapBuiltin(builtin_generic_new));
        const sm = try rt.newStaticM(bn);
        for ([_]*object.Type{ rt.int_t, rt.bool_t, rt.float_t, rt.bytes_t, rt.bytearray_t, rt.str_t, rt.tuple_t, rt.list_t, rt.dict_t, rt.set_t, rt.frozenset_t }) |t| {
            try dictPutStartup(rt, t.dict, "__new__", sm);
        }
    }
}

fn builtin_generic_new(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    if (args.len < 1 or args[0].v != .type_) {
        return v.rt.newInstance(v.rt.object_t);
    }
    return v.rt.newInstance(args[0].v.type_);
}

/// object.__new__(cls) → новый экземпляр cls.
fn object_new(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    if (args.len < 1 or args[0].v != .type_) {
        try v.raiseStr("TypeError", "object.__new__(cls): cls must be a type");
        return error.PyExc;
    }
    return v.rt.newInstance(args[0].v.type_);
}

/// type.__new__(mcs, name, bases, namespace) → новый класс (или type(x) → тип x).
fn type_new(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    const v: *VM = vm;
    if (args.len < 1) {
        try v.raiseStr("TypeError", "type.__new__() needs at least 1 argument");
        return error.PyExc;
    }
    if (args.len == 1 and args[0].v != .type_) return v.typeOf(args[0]);
    if (args[0].v == .str) {
        return v.buildClassFromCall(args, kw);
    }
    if (args[0].v == .type_) {
        // type.__new__(mcs, name, bases, ns): прямое создание (без dispatch на кастомный __new__)
        return v.buildClassDirect(args[0].v.type_, args[1..]);
    }
    return v.typeOf(args[0]);
}

/// classmethod(f) → .classm Value (дескриптор, связывается с классом при доступе).
fn classm_new(vm: *VM, cls: *object.Type, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = cls;
    _ = kw;
    if (args.len < 1) {
        try vm.raiseStr("TypeError", "classmethod() needs 1 argument");
        return error.PyExc;
    }
    return vm.rt.newClassM(args[0]);
}

/// staticmethod(f) → .staticm Value.
fn staticm_new(vm: *VM, cls: *object.Type, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = cls;
    _ = kw;
    if (args.len < 1) {
        try vm.raiseStr("TypeError", "staticmethod() needs 1 argument");
        return error.PyExc;
    }
    return vm.rt.newStaticM(args[0]);
}

// ============================================================
// Встроенные функции
// ============================================================

fn registerFunctions(rt: *Runtime) !void {
    try bd(rt, "print", bi_print);
    try bd(rt, "input", bi_input);
    try bd(rt, "len", bi_len);
    try bd(rt, "repr", bi_repr);
    // ВАЖНО: "str" не регистрируем функцией — это класс (bdt), str(x) идёт через pyCallType.
    // Когда-то здесь был bd("str", bi_str), затиравший тип: type("x") is str == False.
    try bd(rt, "ascii", bi_ascii);
    try bd(rt, "iter", bi_iter);
    try bd(rt, "next", bi_next);
    try bd(rt, "enumerate", bi_enumerate);
    try bd(rt, "zip", bi_zip);
    try bd(rt, "map", bi_map);
    try bd(rt, "filter", bi_filter);
    try bd(rt, "reversed", bi_reversed);
    try bd(rt, "any", bi_any);
    try bd(rt, "all", bi_all);
    try bd(rt, "sorted", bi_sorted);
    try bd(rt, "min", bi_min);
    try bd(rt, "max", bi_max);
    try bd(rt, "sum", bi_sum);
    try bd(rt, "abs", bi_abs);
    try bd(rt, "round", bi_round);
    try bd(rt, "divmod", bi_divmod);
    try bd(rt, "pow", bi_pow);
    try bd(rt, "hex", bi_hex);
    try bd(rt, "oct", bi_oct);
    try bd(rt, "bin", bi_bin);
    try bd(rt, "chr", bi_chr);
    try bd(rt, "ord", bi_ord);
    try bd(rt, "id", bi_id);
    try bd(rt, "hash", bi_hash);
    try bd(rt, "callable", bi_callable);
    try bd(rt, "isinstance", bi_isinstance);
    try bd(rt, "issubclass", bi_issubclass);
    try bd(rt, "getattr", bi_getattr);
    try bd(rt, "setattr", bi_setattr);
    try bd(rt, "hasattr", bi_hasattr);
    try bd(rt, "delattr", bi_delattr);
    try bd(rt, "globals", bi_globals);
    try bd(rt, "locals", bi_locals);
    try bd(rt, "vars", bi_vars);
    try bd(rt, "dir", bi_dir);
    try bd(rt, "open", bi_open);
    try bd(rt, "exec", bi_exec);
    try bd(rt, "eval", bi_eval);
    try bd(rt, "format", bi_format);
    try bd(rt, "exit", bi_exit);
    try bd(rt, "quit", bi_exit);
    try bd(rt, "compile", bi_compile);
    try bd(rt, "breakpoint", bi_breakpoint);
}

fn bi_print(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    const v: *VM = vm;
    const sep = kwGet(kw, "sep") orelse try v.rt.newStr(" ");
    const end = kwGet(kw, "end") orelse try v.rt.newStr("\n");
    const file = kwGet(kw, "file");
    var first = true;
    for (args) |a| {
        if (!first) try writeTo(v, file, sep.v.str.bytes);
        first = false;
        const s = try ops.pyStr(v, a);
        try writeTo(v, file, s.v.str.bytes);
    }
    try writeTo(v, file, end.v.str.bytes);
    if (kwGet(kw, "flush")) |fl| {
        if (fl.isTruthy()) try flushTo(v, file);
    }
    return v.rt.newNone();
}

fn writeTo(vm: *VM, file: ?Obj, s: []const u8) !void {
    if (file) |f| {
        if (f.v == .file) {
            const write_m = try ops.pyGetAttr(vm, f, "write");
            const so = try vm.rt.newStr(s);
            _ = try vm.pyCall(write_m, &.{so}, null);
            return;
        }
    }
    vm.rt.outWrite(s);
}

fn flushTo(vm: *VM, file: ?Obj) !void {
    if (file) |f| {
        if (f.v == .file) {
            const m = try ops.pyGetAttr(vm, f, "flush");
            _ = try vm.pyCall(m, &.{}, null);
            return;
        }
    }
    vm.rt.outFlush();
}

fn bi_input(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    const v: *VM = vm;
    _ = kw;
    if (args.len > 0) {
        const s = try ops.pyStr(v, args[0]);
        v.rt.outWrite(s.v.str.bytes);
        v.rt.outFlush();
    }
    const line = try v.rt.inReadLine();
    var l = line;
    if (l.len > 0 and l[l.len - 1] == '\n') l = l[0 .. l.len - 1];
    if (l.len > 0 and l[l.len - 1] == '\r') l = l[0 .. l.len - 1];
    return v.rt.newStr(l);
}

fn bi_len(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    if (args.len != 1) return typeErr(v, "len() takes exactly one argument ({d} given)", .{args.len});
    const n = try v.pyLen(args[0]);
    return v.rt.newInt(@intCast(n));
}

fn bi_repr(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    if (args.len != 1) return typeErr(vm, "repr() takes exactly one argument", .{});
    return ops.pyRepr(vm, args[0]);
}

fn bi_str(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    if (args.len == 0) return v.rt.newStr("");
    if (args.len >= 1 and args[0].v == .bytes) {
        return v.rt.newStr(args[0].v.bytes.data);
    }
    return ops.pyStr(v, args[0]);
}

fn bi_ascii(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const r = try ops.pyRepr(v, args[0]);
    const src = r.v.str.bytes;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < src.len) {
        const l = std.unicode.utf8ByteSequenceLength(src[i]) catch 1;
        if (i + l > src.len) break;
        const cp = std.unicode.utf8Decode(src[i .. i + l]) catch 0xFFFD;
        if (cp < 128) {
            try out.appendSlice(v.rt.gpa, src[i .. i + l]);
        } else if (cp <= 0xFF) {
            try out.print(v.rt.gpa, "\\x{x:0>2}", .{cp});
        } else if (cp <= 0xFFFF) {
            try out.print(v.rt.gpa, "\\u{x:0>4}", .{cp});
        } else {
            try out.print(v.rt.gpa, "\\U{x:0>8}", .{cp});
        }
        i += l;
    }
    return v.rt.newStrOwned(try out.toOwnedSlice(v.rt.gpa));
}

fn bi_iter(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    if (args.len == 1) return v.pyIter(args[0]);
    return typeErr(v, "iter() takes 1 argument (2-arg форма пока не поддержана)", .{});
}

fn bi_next(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const r = try v.pyNext(args[0]);
    if (r) |x| return x;
    if (args.len == 2) return args[1];
    try v.raiseStr("StopIteration", "");
    return error.PyExc;
}

fn bi_enumerate(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    const v: *VM = vm;
    const start: i64 = if (args.len >= 2) try indexLike(v, args[1]) else if (kwGet(kw, "start")) |s| try indexLike(v, s) else 0;
    const it = try v.pyIter(args[0]);
    return v.rt.newIter(.{ .enumerate_iter = .{ .it = it, .i = start } });
}

fn bi_zip(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const its = try v.rt.gpa.alloc(Obj, args.len);
    for (args, 0..) |a, i| its[i] = try v.pyIter(a);
    return v.rt.newIter(.{ .zip_iter = .{ .its = its } });
}

fn bi_map(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    if (args.len < 2) return typeErr(v, "map() must have at least two arguments", .{});
    const its = try v.rt.gpa.alloc(Obj, args.len - 1);
    for (args[1..], 0..) |a, i| its[i] = try v.pyIter(a);
    return v.rt.newIter(.{ .map_iter = .{ .f = args[0], .its = its } });
}

fn bi_filter(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    if (args.len != 2) return typeErr(v, "filter() takes exactly 2 arguments", .{});
    const it = try v.pyIter(args[1]);
    const f: ?Obj = if (args[0].v == .none) null else args[0];
    return v.rt.newIter(.{ .filter_iter = .{ .f = f, .it = it } });
}

fn bi_any(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    if (args.len != 1) return typeErr(v, "any() takes exactly one argument ({d} given)", .{args.len});
    const iter = try v.pyIter(args[0]);
    while (try v.pyNext(iter)) |item| {
        if (try v.pyTruthy(item)) return v.rt.true_obj;
    }
    return v.rt.false_obj;
}

fn bi_all(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    if (args.len != 1) return typeErr(v, "all() takes exactly one argument ({d} given)", .{args.len});
    const iter = try v.pyIter(args[0]);
    while (try v.pyNext(iter)) |item| {
        if (!(try v.pyTruthy(item))) return v.rt.false_obj;
    }
    return v.rt.true_obj;
}

fn bi_reversed(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    if (args.len != 1) return typeErr(v, "reversed() takes exactly one argument", .{});
    const o = args[0];
    if (ops.lookupSpecial(v, o, "__reversed__")) |rev| {
        return vm.pyCall(rev, &.{}, null);
    }
    const n = try v.pyLen(o);
    return v.rt.newIter(.{ .reversed_seq = .{ .o = o, .i = @as(i64, @intCast(n)) - 1 } });
}

/// Сравнение для сортировки
fn sortLess(vm: *VM, a: Obj, b: Obj) anyerror!bool {
    const r = try ops.pyRichCompare(vm, .lt, a, b);
    return try vm.pyTruthy(r);
}

/// merge sort (стабильный, как у CPython)
pub fn sortItems(vm: *VM, items: []Obj, key_fn: ?Obj) anyerror!void {
    if (items.len < 2) return;
    const rt = vm.rt;
    var keys: []Obj = items;
    if (key_fn) |kf| {
        keys = try rt.gpa.alloc(Obj, items.len);
        for (items, 0..) |it, i| keys[i] = try vm.pyCall(kf, &.{it}, null);
    }
    const tmp_k = try rt.gpa.alloc(Obj, items.len);
    const tmp_v = try rt.gpa.alloc(Obj, items.len);
    try mergeSort(vm, keys, items, tmp_k, tmp_v);
}

fn mergeSort(vm: *VM, keys: []Obj, vals: []Obj, tmp_k: []Obj, tmp_v: []Obj) anyerror!void {
    if (keys.len < 2) return;
    const mid = keys.len / 2;
    try mergeSort(vm, keys[0..mid], vals[0..mid], tmp_k[0..mid], tmp_v[0..mid]);
    try mergeSort(vm, keys[mid..], vals[mid..], tmp_k[mid..], tmp_v[mid..]);
    var i: usize = 0;
    var j: usize = mid;
    var k: usize = 0;
    while (i < mid and j < keys.len) {
        if (try sortLess(vm, keys[j], keys[i])) {
            tmp_k[k] = keys[j];
            tmp_v[k] = vals[j];
            j += 1;
        } else {
            tmp_k[k] = keys[i];
            tmp_v[k] = vals[i];
            i += 1;
        }
        k += 1;
    }
    while (i < mid) : (i += 1) {
        tmp_k[k] = keys[i];
        tmp_v[k] = vals[i];
        k += 1;
    }
    while (j < keys.len) : (j += 1) {
        tmp_k[k] = keys[j];
        tmp_v[k] = vals[j];
        k += 1;
    }
    @memcpy(keys[0..k], tmp_k[0..k]);
    @memcpy(vals[0..k], tmp_v[0..k]);
}

fn bi_sorted(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    const v: *VM = vm;
    const items = try vm.collectSequence(args[0], null);
    const list = try v.rt.newList();
    for (items) |it| try list.v.list.items.append(v.rt.gpa, it);
    try sortItems(v, list.v.list.items.items, kwGet(kw, "key"));
    if (kwGet(kw, "reverse")) |rv| {
        if (rv.isTruthy()) std.mem.reverse(Obj, list.v.list.items.items);
    }
    return list;
}

fn minMaxImpl(vm: *VM, args: []const Obj, kw: ?KwArgs, is_max: bool) anyerror!Obj {
    var items: []Obj = undefined;
    if (args.len == 1) {
        items = try vm.collectSequence(args[0], null);
    } else if (args.len >= 2) {
        const cp = try vm.rt.gpa.alloc(Obj, args.len);
        @memcpy(cp, args);
        items = cp;
    } else {
        return typeErr(vm, "min/max expected at least 1 argument", .{});
    }
    if (items.len == 0) {
        if (kwGet(kw, "default")) |d| return d;
        try vm.raiseStr("ValueError", if (is_max) "max() argument is an empty sequence" else "min() argument is an empty sequence");
        return error.PyExc;
    }
    const key_fn = kwGet(kw, "key");
    var best = items[0];
    var best_key: Obj = if (key_fn) |kf| try vm.pyCall(kf, &.{best}, null) else best;
    for (items[1..]) |it| {
        const k: Obj = if (key_fn) |kf| try vm.pyCall(kf, &.{it}, null) else it;
        const cmp = try ops.pyRichCompare(vm, if (is_max) .gt else .lt, k, best_key);
        if (try vm.pyTruthy(cmp)) {
            best = it;
            best_key = k;
        }
    }
    return best;
}

fn bi_min(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    return minMaxImpl(vm, args, kw, false);
}
fn bi_max(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    return minMaxImpl(vm, args, kw, true);
}

fn bi_sum(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    if (args.len == 0) return typeErr(v, "sum() takes at least 1 positional argument", .{});
    var acc: Obj = if (args.len >= 2) args[1] else try v.rt.newInt(0);
    const it = try v.pyIter(args[0]);
    while (try v.pyNext(it)) |item| {
        acc = try vm.pyBinaryOp(.add, acc, item);
    }
    return acc;
}

fn bi_abs(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const o = args[0];
    switch (o.v) {
        .int => |i| return v.rt.newInt(if (i < 0) -i else i),
        .bool_ => return o,
        .float => |f| return v.rt.newFloat(@abs(f)),
        .bigint => |b| {
            const nb = try v.rt.gpa.create(object.Big);
            nb.* = try b.clone();
            nb.abs();
            return v.rt.newBig(nb);
        },
        else => {
            if (ops.lookupSpecial(v, o, "__abs__")) |m| return vm.pyCall(m, &.{o}, null);
            return typeErr(v, "bad operand type for abs(): '{s}'", .{o.ty.name});
        },
    }
}

fn bi_round(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const o = args[0];
    const ndigits: ?i64 = if (args.len >= 2 and args[1].v != .none) try indexLike(v, args[1]) else null;
    var f: f64 = undefined;
    switch (o.v) {
        .int => |i| {
            if (ndigits == null) return v.rt.newInt(i);
            const n = ndigits.?;
            if (n >= 0) return v.rt.newInt(i);
            f = @floatFromInt(i);
        },
        .bool_ => |b| return v.rt.newInt(@intFromBool(b)),
        .float => |fl| f = fl,
        else => {
            if (ops.lookupSpecial(v, o, "__round__")) |m| {
                if (ndigits) |n| return vm.pyCall(m, &.{ o, try v.rt.newInt(n) }, null);
                return vm.pyCall(m, &.{o}, null);
            }
            return typeErr(v, "type {s} doesn't define __round__", .{o.ty.name});
        },
    }
    const n: i64 = ndigits orelse 0;
    const p = std.math.pow(f64, 10.0, @floatFromInt(n));
    const scaled = f * p;
    const r = roundHalfEven(scaled) / p;
    if (ndigits == null) {
        return v.rt.newInt(@intFromFloat(r));
    }
    return v.rt.newFloat(r);
}

fn roundHalfEven(x: f64) f64 {
    const fl = @floor(x);
    const diff = x - fl;
    if (diff < 0.5) return fl;
    if (diff > 0.5) return fl + 1;
    const fi: i128 = @intFromFloat(@trunc(fl));
    return if (@mod(fi, 2) == 0) fl else fl + 1;
}

fn bi_divmod(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const q = try vm.pyBinaryOp(.floordiv, args[0], args[1]);
    const r = try vm.pyBinaryOp(.mod, args[0], args[1]);
    return v.rt.newTuple(&.{ q, r });
}

fn bi_pow(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    if (args.len == 3) {
        const base = try indexLike(v, args[0]);
        const exp = try indexLike(v, args[1]);
        const m = try indexLike(v, args[2]);
        if (m == 0) {
            try v.raiseStr("ValueError", "pow() 3rd argument cannot be 0");
            return error.PyExc;
        }
        if (exp < 0) {
            try v.raiseStr("ValueError", "pow() 2nd argument cannot be negative when 3rd argument specified");
            return error.PyExc;
        }
        var result: i128 = 1;
        var b: i128 = @mod(base, m);
        var e: u128 = @intCast(exp);
        const mm: i128 = m;
        while (e > 0) : (e >>= 1) {
            if (e & 1 == 1) result = @mod(result * b, mm);
            b = @mod(b * b, mm);
        }
        return v.rt.newInt(@intCast(result));
    }
    return vm.pyBinaryOp(.pow, args[0], args[1]);
}

fn bi_hex(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const x = try indexLike(v, args[0]);
    const s = if (x < 0)
        try std.fmt.allocPrint(v.rt.gpa, "-0x{x}", .{@as(u64, @intCast(-x))})
    else
        try std.fmt.allocPrint(v.rt.gpa, "0x{x}", .{@as(u64, @intCast(x))});
    return v.rt.newStrOwned(s);
}

fn bi_oct(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const x = try indexLike(v, args[0]);
    const s = if (x < 0)
        try std.fmt.allocPrint(v.rt.gpa, "-0o{o}", .{@as(u64, @intCast(-x))})
    else
        try std.fmt.allocPrint(v.rt.gpa, "0o{o}", .{@as(u64, @intCast(x))});
    return v.rt.newStrOwned(s);
}

fn bi_bin(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const x = try indexLike(v, args[0]);
    const s = if (x < 0)
        try std.fmt.allocPrint(v.rt.gpa, "-0b{b}", .{@as(u64, @intCast(-x))})
    else
        try std.fmt.allocPrint(v.rt.gpa, "0b{b}", .{@as(u64, @intCast(x))});
    return v.rt.newStrOwned(s);
}

fn bi_chr(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const x = try indexLike(v, args[0]);
    if (x < 0 or x > 0x10FFFF) {
        try v.raiseStr("ValueError", "chr() arg not in range(0x110000)");
        return error.PyExc;
    }
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(@intCast(x), &buf) catch {
        try v.raiseStr("ValueError", "chr() arg not in range(0x110000)");
        return error.PyExc;
    };
    return v.rt.newStr(buf[0..n]);
}

fn bi_ord(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const o = args[0];
    if (o.v == .str and o.v.str.cp_len == 1) {
        return v.rt.newInt(o.v.str.codepointAt(0).?);
    }
    if (o.v == .bytes and o.v.bytes.data.len == 1) {
        return v.rt.newInt(o.v.bytes.data[0]);
    }
    return typeErr(v, "ord() expected a character", .{});
}

fn bi_id(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    return v.rt.newInt(@intCast(@intFromPtr(args[0])));
}

fn bi_hash(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const h = try vm.pyHash(args[0]);
    // CPython: hash() == -1 заменяется на -2 (мы храним как unsigned)
    const hi: i64 = @bitCast(h);
    return v.rt.newInt(if (hi == -1) -2 else hi);
}

fn bi_callable(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    return v.rt.newBool(isCallable(args[0]));
}

pub fn isCallable(o: Obj) bool {
    return switch (o.v) {
        .builtin, .function, .method, .type_ => true,
        else => ops.lookupClass(o.ty, "__call__") != null,
    };
}

fn classTupleCheck(vm: *VM, clsinfo: Obj) anyerror!void {
    switch (clsinfo.v) {
        .type_ => return,
        .tuple => |t| {
            for (t) |x| try classTupleCheck(vm, x);
        },
        else => {
            try vm.raiseStr("TypeError", "isinstance() arg 2 must be a type, a tuple of types, or a union");
            return error.PyExc;
        },
    }
}

fn bi_isinstance(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    try classTupleCheck(v, args[1]);
    return v.rt.newBool(try ops.isInstance(v, args[0], args[1]));
}

fn issubclassImpl(vm: *VM, c: *Type, clsinfo: Obj) anyerror!bool {
    _ = vm;
    switch (clsinfo.v) {
        .type_ => |t| return ops.isSubclass(c, t),
        .tuple => |t| {
            for (t) |x| {
                if (x.v == .type_ and ops.isSubclass(c, x.v.type_)) return true;
            }
            return false;
        },
        else => return false,
    }
}

fn bi_issubclass(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    try classTupleCheck(v, args[1]);
    if (args[0].v != .type_) return typeErr(v, "issubclass() arg 1 must be a class", .{});
    return v.rt.newBool(try issubclassImpl(v, args[0].v.type_, args[1]));
}

fn bi_getattr(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    if (args.len < 2 or args[1].v != .str) return typeErr(v, "getattr(): attribute name must be string", .{});
    const name = args[1].v.str.bytes;
    if (args.len == 3) {
        return ops.pyGetAttr(v, args[0], name) catch |e| {
            if (e == error.PyExc) {
                v.currentTS().cur_exc = null;
                return args[2];
            }
            return e;
        };
    }
    return ops.pyGetAttr(v, args[0], name);
}

fn bi_setattr(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    if (args.len != 3 or args[1].v != .str) return typeErr(v, "setattr(): attribute name must be string", .{});
    try ops.pySetAttr(v, args[0], args[1].v.str.bytes, args[2]);
    return v.rt.newNone();
}

fn bi_hasattr(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    if (args.len != 2 or args[1].v != .str) return typeErr(v, "hasattr(): attribute name must be string", .{});
    _ = ops.pyGetAttr(v, args[0], args[1].v.str.bytes) catch |e| {
        if (e == error.PyExc) {
            v.currentTS().cur_exc = null;
            return v.rt.false_obj;
        }
        return e;
    };
    return v.rt.true_obj;
}

fn bi_delattr(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    if (args.len != 2 or args[1].v != .str) return typeErr(v, "delattr(): attribute name must be string", .{});
    try ops.pyDelAttr(v, args[0], args[1].v.str.bytes);
    return v.rt.newNone();
}

fn bi_globals(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = args;
    _ = kw;
    const v: *VM = vm;
    const ts = v.currentTS();
    if (ts.frames.items.len == 0) return typeErr(v, "no frame", .{});
    const fr = ts.frames.items[ts.frames.items.len - 1];
    return v.rt.mkObj(v.rt.dict_t, .{ .dict = fr.globals });
}

fn bi_locals(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = args;
    _ = kw;
    const v: *VM = vm;
    const ts = v.currentTS();
    if (ts.frames.items.len == 0) return typeErr(v, "no frame", .{});
    const fr = ts.frames.items[ts.frames.items.len - 1];
    if (fr.locals_dict) |ld| {
        return v.rt.mkObj(v.rt.dict_t, .{ .dict = ld });
    }
    const d = try v.rt.newDict();
    for (fr.code.varnames, 0..) |name, i| {
        if (i < fr.locals.len and fr.locals_set[i]) {
            const kobj = try v.rt.newStr(name);
            const h = try vm.pyHash(kobj);
            try d.setWithHash(vm, kobj, fr.locals[i], h);
        }
    }
    return v.rt.mkObj(v.rt.dict_t, .{ .dict = d });
}

fn bi_vars(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    if (args.len == 0) return bi_locals(vm, args, null);
    const o = args[0];
    if (o.v == .module) return v.rt.mkObj(v.rt.dict_t, .{ .dict = o.v.module.dict });
    if (ops.instanceDict(o)) |d| return v.rt.mkObj(v.rt.dict_t, .{ .dict = d });
    return typeErr(v, "vars() argument must have __dict__ attribute", .{});
}

fn strLess(_: void, a: Obj, b: Obj) bool {
    if (a.v == .str and b.v == .str) return std.mem.order(u8, a.v.str.bytes, b.v.str.bytes) == .lt;
    return false;
}

fn dirAddUnique(list: *std.ArrayList(Obj), gpa: std.mem.Allocator, key: Obj) !void {
    for (list.items) |n| {
        if (n.v == .str and key.v == .str and std.mem.eql(u8, n.v.str.bytes, key.v.str.bytes)) return;
    }
    try list.append(gpa, key);
}

fn bi_dir(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    var names: std.ArrayList(Obj) = .empty;
    if (args.len == 0) {
        const loc = try bi_locals(vm, args, null);
        var it = loc.v.dict.iterAlive();
        while (it.next()) |e| try names.append(v.rt.gpa, e.key.?);
    } else {
        const o = args[0];
        if (o.v == .module) {
            var it = o.v.module.dict.iterAlive();
            while (it.next()) |e| try names.append(v.rt.gpa, e.key.?);
        } else if (o.v == .type_) {
            for (o.v.type_.mro) |t| {
                var it = t.dict.iterAlive();
                while (it.next()) |e| try dirAddUnique(&names, v.rt.gpa, e.key.?);
            }
        } else {
            if (ops.instanceDict(o)) |d| {
                var it = d.iterAlive();
                while (it.next()) |e| try dirAddUnique(&names, v.rt.gpa, e.key.?);
            }
            for (o.ty.mro) |t| {
                var it = t.dict.iterAlive();
                while (it.next()) |e| try dirAddUnique(&names, v.rt.gpa, e.key.?);
            }
        }
    }
    std.mem.sort(Obj, names.items, {}, strLess);
    return v.rt.newListFrom(names.items);
}

fn bi_format(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    if (args.len < 1) return typeErr(v, "format() needs at least 1 argument", .{});
    const spec: ?Obj = if (args.len >= 2) try ops.pyStr(v, args[1]) else null;
    return vm.formatValue(args[0], 0, spec);
}

fn bi_exit(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const ty = v.excType("SystemExit");
    const eo = try v.mkExc(ty, args);
    try v.raiseObj(eo);
    return error.PyExc;
}

fn bi_compile(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    if (args.len < 3) return typeErr(v, "compile() takes at least 3 arguments", .{});
    if (args[0].v != .str) return typeErr(v, "compile() source must be str", .{});
    const filename = if (args[1].v == .str) args[1].v.str.bytes else "<string>";
    const mode = if (args[2].v == .str) args[2].v.str.bytes else "exec";
    const compiler = @import("../compiler/compiler.zig");
    const fm: compiler.FileMode = if (std.mem.eql(u8, mode, "eval")) .eval else .exec;
    const code = compiler.compileSource(v, filename, args[0].v.str.bytes, fm) catch |e| {
        if (e == error.PyExc) return error.PyExc;
        return e;
    };
    return v.rt.mkObj(v.rt.code_t, .{ .code = code });
}

fn bi_breakpoint(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = args;
    _ = kw;
    const v: *VM = vm;
    @breakpoint();
    return v.rt.newNone();
}

/// repr() с экранированием не-ASCII (конверсия !a)
pub fn asciiOf(vm: *VM, o: Obj) anyerror!Obj {
    return bi_ascii(vm, &.{o}, null);
}

// ============================================================
// Общие утилиты
// ============================================================

pub fn typeErr(vm: *VM, comptime fmt: []const u8, a: anytype) anyerror {
    try vm.raiseFmt("TypeError", fmt, a);
    return error.PyExc;
}

pub fn valErr(vm: *VM, comptime fmt: []const u8, a: anytype) anyerror {
    try vm.raiseFmt("ValueError", fmt, a);
    return error.PyExc;
}

/// int-подобный объект → i64 (+ __index__)
pub fn indexLike(vm: *VM, o: Obj) anyerror!i64 {
    switch (o.v) {
        .int => |i| return i,
        .bool_ => |b| return @intFromBool(b),
        .bigint => |b| return b.toInt(i64) catch {
            try vm.raiseStr("OverflowError", "Python int too large to convert to C long");
            return error.PyExc;
        },
        else => {
            if (ops.lookupSpecial(vm, o, "__index__")) |m| {
                const r = try vm.pyCall(m, &.{o}, null);
                return indexLike(vm, r);
            }
            try vm.raiseFmt("TypeError", "'{s}' object cannot be interpreted as an integer", .{o.ty.name});
            return error.PyExc;
        },
    }
}

/// числовое значение как f64 (int/bool/float/bigint)
pub fn floatLike(vm: *VM, o: Obj) anyerror!f64 {
    switch (o.v) {
        .int => |i| return @floatFromInt(i),
        .bool_ => |b| return @floatFromInt(@intFromBool(b)),
        .float => |f| return f,
        .bigint => |b| return if (b.toConst().bitCountAbs() <= 1024) b.toConst().toFloat(f64, .nearest_even)[0] else {
            try vm.raiseStr("OverflowError", "int too large to convert to float");
            return error.PyExc;
        },
        else => {
            if (ops.lookupSpecial(vm, o, "__float__")) |m| {
                const r = try vm.pyCall(m, &.{o}, null);
                return floatLike(vm, r);
            }
            if (ops.lookupSpecial(vm, o, "__index__")) |m| {
                const r = try vm.pyCall(m, &.{o}, null);
                return floatLike(vm, r);
            }
            try vm.raiseFmt("TypeError", "must be real number, not {s}", .{o.ty.name});
            return error.PyExc;
        },
    }
}

// ============================================================
// open() и файлы — через std.Io (мультиплатформенно)
// ============================================================

fn bi_open(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    const v: *VM = vm;
    _ = kw;
    if (args.len == 0) return typeErr(v, "open() missing required argument 'file'", .{});
    const mode_s: []const u8 = if (args.len >= 2 and args[1].v == .str) args[1].v.str.bytes else "r";
    var readable = false;
    var writable = false;
    var binary = false;
    var truncate = false;
    var append_mode = false;
    var exclusive = false;
    var plus = false;
    for (mode_s) |c| {
        switch (c) {
            'r' => readable = true,
            'w' => {
                writable = true;
                truncate = true;
            },
            'a' => {
                writable = true;
                append_mode = true;
            },
            'x' => {
                writable = true;
                exclusive = true;
            },
            'b' => binary = true,
            't' => {},
            '+' => plus = true,
            else => {
                try v.raiseFmt("ValueError", "invalid mode: '{s}'", .{mode_s});
                return error.PyExc;
            },
        }
    }
    if (plus) {
        readable = true;
        writable = true;
    }
    const path_obj = args[0];
    if (path_obj.v != .str) {
        return typeErr(v, "open() argument 'file' must be str", .{});
    }
    const path_str = path_obj.v.str.bytes;
    const io = v.rt.io orelse {
        try v.raiseStr("RuntimeError", "io subsystem is not initialized");
        return error.PyExc;
    };
    const dir = std.Io.Dir.cwd();
    var f: std.Io.File = undefined;
    if (writable) {
        f = dir.createFile(io, path_str, .{ .truncate = truncate, .exclusive = exclusive, .read = readable }) catch |e| {
            return ioErr(v, e, path_str);
        };
    } else {
        f = dir.openFile(io, path_str, .{}) catch |e| {
            return ioErr(v, e, path_str);
        };
    }
    const fobj = try v.rt.newFile(f, readable, writable, binary);
    fobj.v.file.name = path_str;
    if (append_mode) {
        const len = f.length(io) catch 0;
        fobj.v.file.pos = len;
    }
    return fobj;
}

/// Преобразование ошибок std.Io в OSError-подобные исключения Python
pub fn ioErr(vm: *VM, e: anyerror, path: ?[]const u8) anyerror {
    const name: []const u8 = switch (e) {
        error.FileNotFound => "FileNotFoundError",
        error.AccessDenied, error.PermissionDenied => "PermissionError",
        error.IsDir => "IsADirectoryError",
        error.NotDir => "NotADirectoryError",
        error.PathAlreadyExists, error.FileBusy, error.FileLocksNotSupported => "FileExistsError",
        else => "OSError",
    };
    const msg = if (path) |p|
        try std.fmt.allocPrint(vm.rt.gpa, "({s}): '{s}'", .{ @errorName(e), p })
    else
        try std.fmt.allocPrint(vm.rt.gpa, "{s}", .{@errorName(e)});
    try vm.raiseStr(name, msg);
    return error.PyExc;
}

// ============================================================
// exec / eval
// ============================================================

fn bi_exec(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    if (args.len == 0) return typeErr(v, "exec() takes at least 1 argument", .{});
    const src_obj = args[0];
    const globals = if (args.len >= 2 and args[1].v == .dict) args[1].v.dict else defaultGlobals(v);
    const locals = if (args.len >= 3 and args[2].v == .dict) args[2].v.dict else null;
    if (src_obj.v == .code) {
        try v.runNameScope(src_obj.v.code, globals, locals);
        return v.rt.newNone();
    }
    if (src_obj.v != .str) return typeErr(v, "exec() arg 1 must be a string or code object", .{});
    const compiler = @import("../compiler/compiler.zig");
    const parsed_args = try parseEvalMode(v, args[1..]);
    _ = parsed_args;
    const code = compiler.compileSource(v, "<string>", src_obj.v.str.bytes, .exec) catch |e| {
        if (e == error.PyExc) return error.PyExc;
        return e;
    };
    try v.runNameScope(code, globals, locals);
    return v.rt.newNone();
}

fn parseEvalMode(v: *VM, args: []const Obj) !void {
    _ = v;
    _ = args;
}

fn bi_eval(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    if (args.len == 0) return typeErr(v, "eval() takes at least 1 argument", .{});
    const src_obj = args[0];
    if (src_obj.v != .str) return typeErr(v, "eval() arg 1 must be a string", .{});
    const globals = if (args.len >= 2 and args[1].v == .dict) args[1].v.dict else defaultGlobals(v);
    const locals = if (args.len >= 3 and args[2].v == .dict) args[2].v.dict else null;
    const compiler = @import("../compiler/compiler.zig");
    const code = compiler.compileSource(v, "<string>", src_obj.v.str.bytes, .eval) catch |e| {
        if (e == error.PyExc) return error.PyExc;
        return e;
    };
    const fnobj = try v.rt.newFunction("<eval>", "<eval>", code, globals, &.{}, &.{}, null);
    const frame = try v.makeFrame(fnobj.v.function, &.{}, null);
    frame.locals_dict = locals orelse globals;
    const ts = v.currentTS();
    const mark = ts.frames.items.len;
    try ts.frames.append(v.gpa, frame);
    try v.runUntil(ts, mark);
    const rv = ts.return_value orelse v.rt.newNone();
    ts.return_value = null;
    return rv;
}

fn defaultGlobals(v: *VM) *Dict {
    const ts = v.currentTS();
    if (ts.frames.items.len > 0) {
        return ts.frames.items[ts.frames.items.len - 1].globals;
    }
    return v.rt.builtins_dict;
}
