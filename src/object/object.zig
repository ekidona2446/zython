//! Zython Object Model - аналог Objects/object.c и Include/object.h из CPython
//! Реализует PyObject с refcount, type system и tagged union для значений
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const TypeId = enum(u8) {
    None,
    Bool,
    Int,
    Float,
    Str,
    Bytes,
    List,
    Tuple,
    Dict,
    Set,
    Function,
    BuiltinFunction,
    Method,
    Module,
    Code,
    Frame,
    Generator,
    Coroutine,
    Type,
    Object,
    Slice,
    Range,
    Exception,
    AsyncGenerator,
};

pub const PyType = struct {
    name: []const u8,
    type_id: TypeId,
    doc: ?[]const u8 = null,

    // Минимальные слоты для совместимости с CPython type system
    pub fn toString(self: *const PyType) []const u8 {
        return self.name;
    }
};

// Глобальные типы (аналог PyLong_Type, PyUnicode_Type etc)
pub const NoneType = PyType{ .name = "NoneType", .type_id = .None };
pub const BoolType = PyType{ .name = "bool", .type_id = .Bool };
pub const IntType = PyType{ .name = "int", .type_id = .Int };
pub const FloatType = PyType{ .name = "float", .type_id = .Float };
pub const StrType = PyType{ .name = "str", .type_id = .Str };
pub const ListType = PyType{ .name = "list", .type_id = .List };
pub const TupleType = PyType{ .name = "tuple", .type_id = .Tuple };
pub const DictType = PyType{ .name = "dict", .type_id = .Dict };
pub const FunctionType = PyType{ .name = "function", .type_id = .Function };
pub const ModuleType = PyType{ .name = "module", .type_id = .Module };
pub const CodeType = PyType{ .name = "code", .type_id = .Code };

/// Основная структура значения - аналог union внутри PyObject*
/// Используем Zig tagged union для эффективности, но сохраняем refcount семантику
pub const PyValue = union(TypeId) {
    None: void,
    Bool: bool,
    Int: IntValue,
    Float: f64,
    Str: []u8, // owned
    Bytes: []u8,
    List: ListValue,
    Tuple: []ObjectPtr, // owned slice of pointers
    Dict: DictValue,
    Set: SetValue,
    Function: FunctionValue,
    BuiltinFunction: BuiltinFn,
    Method: void, // todo
    Module: ModuleValue,
    Code: *CodeObject,
    Frame: *FrameValue,
    Generator: void,
    Coroutine: void,
    Type: *PyType,
    Object: void, // generic object
    Slice: SliceValue,
    Range: RangeValue,
    Exception: ExceptionValue,
    AsyncGenerator: void,
};

pub const IntValue = union(enum) {
    Small: i64,
    Big: std.math.big.int.Managed, // для совместимости с Python big ints

    pub fn toI64(self: IntValue) ?i64 {
        return switch (self) {
            .Small => |v| v,
            .Big => |*big| big.to(i64) catch null,
        };
    }

    pub fn deinit(self: *IntValue, alloc: Allocator) void {
        _ = alloc;
        switch (self.*) {
            .Big => |*b| b.deinit(),
            .Small => {},
        }
    }
};

pub const ListValue = struct {
    items: std.ArrayList(ObjectPtr),
    pub fn init(alloc: Allocator) ListValue {
        _ = alloc;
        return .{ .items = .empty };
    }
};

pub const DictValue = struct {
    // Упрощенная реализация dict - как в CPython dictobject.c но на хешмапе Zig
    // В CPython используется open addressing с DKIX, здесь для MVP - hashmap
    map: std.StringHashMap(ObjectPtr), // для MVP ключи - строки, позже расширим
    generic_map: std.AutoHashMap(u64, ObjectPtr), // fallback по хешу (упрощение)

    pub fn init(alloc: Allocator) DictValue {
        return .{
            .map = std.StringHashMap(ObjectPtr).init(alloc),
            .generic_map = std.AutoHashMap(u64, ObjectPtr).init(alloc),
        };
    }
};

pub const SetValue = struct {
    items: std.AutoHashMap(u64, ObjectPtr),
};

pub const FunctionValue = struct {
    name: []const u8,
    qualname: []const u8,
    code: *CodeObject,
    globals: *ModuleValue,
    closure: ?[]ObjectPtr = null,
    defaults: ?[]ObjectPtr = null,
    is_async: bool = false,
    is_generator: bool = false,
};

pub const BuiltinFn = *const fn (args: []*PyObject, allocator: Allocator) anyerror!ObjectPtr;

pub const ModuleValue = struct {
    name: []const u8,
    dict: std.StringHashMap(ObjectPtr),
    file: ?[]const u8 = null,

    pub fn init(alloc: Allocator, name: []const u8) ModuleValue {
        return .{
            .name = name,
            .dict = std.StringHashMap(ObjectPtr).init(alloc),
        };
    }
};

pub const SliceValue = struct {
    start: ?ObjectPtr,
    stop: ?ObjectPtr,
    step: ?ObjectPtr,
};

pub const RangeValue = struct {
    start: i64,
    stop: i64,
    step: i64,
};

pub const ExceptionValue = struct {
    type_name: []const u8,
    value: ?ObjectPtr,
    traceback: ?[]FrameTrace = null,
};

pub const FrameTrace = struct {
    filename: []const u8,
    lineno: usize,
    funcname: []const u8,
};

/// CodeObject - аналог PyCodeObject в Include/cpython/code.h
pub const CodeObject = struct {
    filename: []const u8,
    name: []const u8,
    first_lineno: usize,
    argcount: u16,
    kwonlyargcount: u16,
    nlocals: u16,
    stacksize: u16,
    flags: CodeFlags,
    code: []u8, // bytecode
    consts: []ObjectPtr,
    names: [][]const u8,
    varnames: [][]const u8,
    freevars: [][]const u8 = &.{},
    cellvars: [][]const u8 = &.{},
    lnotab: []u8 = &.{}, // line number table

    pub const CodeFlags = packed struct(u16) {
        optimized: bool = false,
        newlocals: bool = false,
        varargs: bool = false,
        varkwargs: bool = false,
        nested: bool = false,
        generator: bool = false,
        coroutine: bool = false,
        has_finally: bool = false,
        async_generator: bool = false,
        _padding: u7 = 0,
    };
};

/// FrameValue - аналог PyFrameObject
pub const FrameValue = struct {
    code: *CodeObject,
    globals: *ModuleValue,
    locals: std.StringHashMap(ObjectPtr),
    stack: std.ArrayList(ObjectPtr),
    block_stack: std.ArrayList(Block),
    lasti: usize = 0, // last instruction index
    lineno: usize,

    pub const Block = struct {
        type: BlockType,
        handler: usize,
        level: usize,
    };
    pub const BlockType = enum { Loop, Except, Finally, With };
};

pub const ObjectPtr = *PyObject;

/// PyObject - центральная структура, аналог Include/object.h
pub const PyObject = struct {
    refcnt: usize = 1,
    type_ptr: *const PyType,
    value: PyValue,
    allocator: Allocator,

    // Для отслеживания GC (аналог _PyGC_Head)
    gc_tracked: bool = false,
    gc_refs: isize = 0,

    pub fn create(allocator: Allocator, type_ptr: *const PyType, value: PyValue) !ObjectPtr {
        const obj = try allocator.create(PyObject);
        obj.* = .{
            .refcnt = 1,
            .type_ptr = type_ptr,
            .value = value,
            .allocator = allocator,
        };
        return obj;
    }

    pub fn incref(self: ObjectPtr) void {
        self.refcnt +|= 1;
    }

    pub fn decref(self: ObjectPtr) void {
        if (self.refcnt == 0) return;
        self.refcnt -= 1;
        if (self.refcnt == 0) {
            self.deinit();
            self.allocator.destroy(self);
        }
    }

    fn deinit(self: ObjectPtr) void {
        // Освобождение ресурсов в зависимости от типа - аналог tp_dealloc
        switch (self.value) {
            .Str => |s| self.allocator.free(s),
            .Bytes => |b| self.allocator.free(b),
            .List => |*list| {
                for (list.items.items) |item| {
                    item.decref();
                }
                list.items.deinit(self.allocator);
            },
            .Tuple => |items| {
                for (items) |item| item.decref();
                self.allocator.free(items);
            },
            .Int => |*iv| {
                var v = iv.*;
                v.deinit(self.allocator);
            },
            .Dict => |*d| {
                // TODO: decref values
                d.map.deinit();
                d.generic_map.deinit();
            },
            .Function => |*f| {
                self.allocator.free(f.name);
            },
            .Code => |c| {
                self.allocator.free(c.code);
                // consts decref handled elsewhere
            },
            else => {},
        }
    }

    pub fn repr(self: *const PyObject, allocator: Allocator) ![]u8 {
        return switch (self.value) {
            .None => try allocator.dupe(u8, "None"),
            .Bool => |b| try allocator.dupe(u8, if (b) "True" else "False"),
            .Int => |iv| switch (iv) {
                .Small => |v| try std.fmt.allocPrint(allocator, "{d}", .{v}),
                .Big => |*big| try big.toString(allocator, 10, .lower),
            },
            .Float => |f| try std.fmt.allocPrint(allocator, "{d}", .{f}),
            .Str => |s| try std.fmt.allocPrint(allocator, "'{s}'", .{s}),
            .List => |*l| {
                var buf: std.ArrayList(u8) = .empty;
                try buf.append(allocator, '[');
                for (l.items.items, 0..) |item, i| {
                    if (i != 0) try buf.appendSlice(allocator, ", ");
                    const r = try item.repr(allocator);
                    defer allocator.free(r);
                    try buf.appendSlice(allocator, r);
                }
                try buf.append(allocator, ']');
                return buf.toOwnedSlice(allocator);
            },
            .Tuple => |items| {
                var buf: std.ArrayList(u8) = .empty;
                try buf.append(allocator, '(');
                for (items, 0..) |item, i| {
                    if (i != 0) try buf.appendSlice(allocator, ", ");
                    const r = try item.repr(allocator);
                    defer allocator.free(r);
                    try buf.appendSlice(allocator, r);
                }
                if (items.len == 1) try buf.append(allocator, ',');
                try buf.append(allocator, ')');
                return buf.toOwnedSlice(allocator);
            },
            .Dict => try allocator.dupe(u8, "{...}"),
            else => try std.fmt.allocPrint(allocator, "<{s} object>", .{self.type_ptr.name}),
        };
    }

    pub fn isTruthy(self: *const PyObject) bool {
        return switch (self.value) {
            .None => false,
            .Bool => |b| b,
            .Int => |iv| switch (iv) {
                .Small => |v| v != 0,
                .Big => |*big| !big.*.eqlZero(),
            },
            .Float => |f| f != 0.0,
            .Str => |s| s.len != 0,
            .List => |*l| l.items.items.len != 0,
            .Tuple => |items| items.len != 0,
            .Dict => |*d| d.map.count() != 0,
            else => true,
        };
    }

    // Хелперы создания объектов (аналог PyLong_FromLong, PyUnicode_FromString etc)
    pub fn newNone(allocator: Allocator) !ObjectPtr {
        return create(allocator, &NoneType, .{ .None = {} });
    }

    pub fn newBool(allocator: Allocator, b: bool) !ObjectPtr {
        return create(allocator, &BoolType, .{ .Bool = b });
    }

    pub fn newInt(allocator: Allocator, v: i64) !ObjectPtr {
        return create(allocator, &IntType, .{ .Int = .{ .Small = v } });
    }

    pub fn newFloat(allocator: Allocator, v: f64) !ObjectPtr {
        return create(allocator, &FloatType, .{ .Float = v });
    }

    pub fn newStr(allocator: Allocator, s: []const u8) !ObjectPtr {
        const duped = try allocator.dupe(u8, s);
        return create(allocator, &StrType, .{ .Str = duped });
    }

    pub fn newList(allocator: Allocator) !ObjectPtr {
        const list_val = ListValue.init(allocator);
        return create(allocator, &ListType, .{ .List = list_val });
    }

    pub fn newDict(allocator: Allocator) !ObjectPtr {
        const dict_val = DictValue.init(allocator);
        return create(allocator, &DictType, .{ .Dict = dict_val });
    }
};

// Для совместимости: Py_INCREF, Py_DECREF аналоги
pub inline fn INCREF(o: ObjectPtr) void {
    o.incref();
}
pub inline fn DECREF(o: ObjectPtr) void {
    o.decref();
}
pub inline fn XINCREF(o: ?ObjectPtr) void {
    if (o) |obj| obj.incref();
}
pub inline fn XDECREF(o: ?ObjectPtr) void {
    if (o) |obj| obj.decref();
}
