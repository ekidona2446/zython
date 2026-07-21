//! Zython Object Model v2 — аналог Include/object.h + Objects/*.c
//! Данные объектной модели: PyObj, Type (класс с MRO), контейнеры, код/фреймы/генераторы.
//! Чистые помощники (utf8, truthiness). Операции, которые могут выполнять Python-код
//! (repr/eq/call/…), живут в protocol.zig.

const std = @import("std");
const vm_mod = @import("../vm/vm.zig");
const Allocator = std.mem.Allocator;

pub const Obj = *PyObj;
pub const Big = std.math.big.int.Managed;

// ============================================================
// PyObj
// ============================================================

pub const Value = union(enum) {
    none,
    notimpl,
    ellipsis,
    bool_: bool,
    int: i64,
    bigint: *Big,
    float: f64,
    str: *Str,
    bytes: *Bytes,
    bytearray: *ByteArray,
    list: *List,
    tuple: []*PyObj,
    dict: *Dict,
    set: *Set,
    frozenset: *Set,
    instance: *Instance,
    type_: *Type,
    function: *Function,
    builtin: *Builtin,
    method: *Method,
    module: *Module,
    code: *Code,
    generator: *Generator,
    cell: *Cell,
    slice: *Slice,
    range: *Range,
    iter: *Iter,
    property: *Property,
    staticm: *StaticM,
    classm: *ClassM,
    super_: *Super,
    exc: *Exc,
    file: *File,
    lock: *Lock,
    local: *Local, // threading.local storage

    pub fn tagName(self: Value) []const u8 {
        return @tagName(self);
    }
};

pub const PyObj = struct {
    ty: *Type,
    v: Value,

    pub fn is(self: Obj, other: Obj) bool {
        return self == other;
    }
    pub fn isNone(self: Obj) bool {
        return self.v == .none;
    }
    pub fn isTrue(self: Obj) bool {
        return self.v == .bool_ and self.v.bool_;
    }

    pub fn isTruthy(self: Obj) bool {
        return switch (self.v) {
            .none => false,
            .notimpl => true,
            .bool_ => |b| b,
            .int => |i| i != 0,
            .bigint => |b| !b.eqlZero(),
            .float => |f| f != 0.0,
            .str => |s| s.cp_len != 0,
            .bytes => |b| b.data.len != 0,
            .bytearray => |b| b.data.items.len != 0,
            .list => |l| l.items.items.len != 0,
            .tuple => |t| t.len != 0,
            .dict => |d| d.len() != 0,
            .set, .frozenset => |s| s.len() != 0,
            .range => |r| r.len() != 0,
            .exc => true,
            .ellipsis => true,
            else => blk: {
                // __bool__ / __len__ — обрабатывается в protocol.pyTruthy;
                // здесь fallback по умолчанию (объекты истинны).
                break :blk true;
            },
        };
    }
};

// ============================================================
// Строки / байты
// ============================================================

pub const Str = struct {
    bytes: []u8, // UTF-8
    cp_len: usize, // длина в кодпоинтах
    hash_cache: i64 = 0,

    pub fn countCp(bytes: []const u8) usize {
        var n: usize = 0;
        var i: usize = 0;
        while (i < bytes.len) {
            const l = std.unicode.utf8ByteSequenceLength(bytes[i]) catch {
                i += 1;
                n += 1;
                continue;
            };
            i += l;
            n += 1;
        }
        return n;
    }

    /// Байтовая позиция кодпоинта cp_index. O(n).
    pub fn byteIndexOfCp(bytes: []const u8, cp_index: usize) usize {
        var n: usize = 0;
        var i: usize = 0;
        while (i < bytes.len and n < cp_index) {
            const l = std.unicode.utf8ByteSequenceLength(bytes[i]) catch 1;
            i += l;
            n += 1;
        }
        return i;
    }

    pub fn cpAt(self: *const Str, cp_index: usize) ?[]const u8 {
        const bi = byteIndexOfCp(self.bytes, cp_index);
        if (bi >= self.bytes.len) return null;
        const l = std.unicode.utf8ByteSequenceLength(self.bytes[bi]) catch 1;
        if (bi + l > self.bytes.len) return self.bytes[bi..bi+1];
        return self.bytes[bi .. bi + l];
    }

    /// Срез [start..stop) в кодпоинтах → байтовый подслайс
    pub fn cpSlice(self: *const Str, start: usize, stop: usize) []const u8 {
        const b0 = byteIndexOfCp(self.bytes, start);
        const b1 = byteIndexOfCp(self.bytes, stop);
        return self.bytes[b0..b1];
    }

    pub fn codepointAt(self: *const Str, cp_index: usize) ?u21 {
        const s = self.cpAt(cp_index) orelse return null;
        return std.unicode.utf8Decode(s) catch 0xFFFD;
    }
};

pub const Bytes = struct { data: []u8 };
pub const ByteArray = struct { data: std.ArrayList(u8) };

// ============================================================
// Контейнеры
// ============================================================

pub const List = struct {
    items: std.ArrayList(Obj),
};

pub const Dict = struct {
    // Вставка-упорядоченный dict: entries + open-addressing index → entry index.
    entries: std.ArrayList(Entry),
    table: []i64, // индексы в entries (-1 пусто, -2 удалено)
    mask: usize,
    used: usize, // живые
    fill: usize, // used + deleted

    pub const Entry = struct {
        key: ?Obj, // null → deleted
        val: ?Obj,
        hash: u64,
    };

    pub fn init() Dict {
        return .{ .entries = .empty, .table = &.{}, .mask = 0, .used = 0, .fill = 0 };
    }

    pub fn len(self: *const Dict) usize {
        return self.used;
    }

    fn hashSlot(table: []i64, mask: usize, hash: u64) usize {
        _ = table;
        return @intCast(hash & mask);
    }

    /// Найти слот для ключа. Возвращает (table_index, found_entry_index или -1).
    fn findSlot(self: *Dict, rt: anytype, key: Obj, hash: u64) !struct { usize, i64 } {
        if (self.mask == 0) return .{ 0, -1 };
        var i: usize = @intCast(hash & self.mask);
        while (true) {
            const eidx = self.table[i];
            if (eidx == -1) return .{ i, -1 };
            if (eidx >= 0) {
                const e = &self.entries.items[@intCast(eidx)];
                if (e.hash == hash) {
                    const eq = try rt.pyEq(e.key.?, key);
                    if (eq) return .{ i, eidx };
                }
            }
            i = (i + 1) & self.mask;
        }
    }

    pub fn getWithHash(self: *Dict, rt: anytype, key: Obj, hash: u64) !?Obj {
        const r = try self.findSlot(rt, key, hash);
        if (r[1] < 0) return null;
        return self.entries.items[@intCast(r[1])].val;
    }

    pub fn setWithHash(self: *Dict, rt: anytype, key: Obj, val: Obj, hash: u64) !void {
        if (self.mask == 0) try self.resize(rt, 8);
        const r = try self.findSlot(rt, key, hash);
        if (r[1] >= 0) {
            self.entries.items[@intCast(r[1])].val = val;
            return;
        }
        self.table[r[0]] = @intCast(self.entries.items.len);
        try self.entries.append(rt.gpa, .{ .key = key, .val = val, .hash = hash });
        self.used += 1;
        self.fill += 1;
        if (self.fill * 3 >= (self.mask + 1) * 2) try self.resize(rt, (self.mask + 1) * 2);
    }

    pub fn delWithHash(self: *Dict, rt: anytype, key: Obj, hash: u64) !bool {
        if (self.mask == 0) return false;
        const r = try self.findSlot(rt, key, hash);
        if (r[1] < 0) return false;
        const e = &self.entries.items[@intCast(r[1])];
        e.key = null;
        e.val = null;
        self.table[r[0]] = -2;
        self.used -= 1;
        return true;
    }

    fn resize(self: *Dict, rt: anytype, new_size: usize) !void {
        var size: usize = 8;
        while (size < new_size) size *= 2;
        const new_table = try rt.gpa.alloc(i64, size);
        @memset(new_table, -1);
        for (self.entries.items, 0..) |e, idx| {
            if (e.key == null) continue;
            var i: usize = @intCast(e.hash & (size - 1));
            while (new_table[i] != -1) i = (i + 1) & (size - 1);
            new_table[i] = @intCast(idx);
        }
        if (self.table.len > 0) rt.gpa.free(self.table);
        self.table = new_table;
        self.mask = size - 1;
        self.fill = self.used;
    }

    /// Итерация по живым entries в порядке вставки.
    pub fn iterAlive(self: *Dict) EntryIter {
        return .{ .d = self, .idx = 0 };
    }
    pub const EntryIter = struct {
        d: *Dict,
        idx: usize,
        pub fn next(self: *EntryIter) ?*Entry {
            while (self.idx < self.d.entries.items.len) {
                const e = &self.d.entries.items[self.idx];
                self.idx += 1;
                if (e.key != null) return e;
            }
            return null;
        }
    };
};

pub const Set = struct {
    dict: Dict, // key — элемент, val — всегда none

    pub fn init() Set {
        return .{ .dict = Dict.init() };
    }
    pub fn len(self: *const Set) usize {
        return self.dict.len();
    }
};

pub const Instance = struct {
    dict: Dict,
    data: ?*Dict = null, // содержимое для dict-подклассов (отдельно от атрибутов экземпляра)
};

// ============================================================
// Типы
// ============================================================

pub const TypeFlags = struct {
    builtin: bool = false, // встроенный тип (инстансы не создаются class-стейтментом)
    has_inst_dict: bool = true,
    is_type_obj: bool = false, // это type или подкласс type
    exc: bool = false, // производное от BaseException
};

pub const NativeNew = *const fn (rt: *vm_mod.VM, cls: *Type, args: []const Obj, kw: ?KwArgs) anyerror!Obj;

pub const Type = struct {
    ty: *Type, // метакласс (обычно typeType)
    name: []const u8,
    qualname: []const u8,
    module: ?[]const u8, // __module__
    base: ?*Type,
    bases: []const *Type,
    mro: []const *Type,
    dict: *Dict,
    flags: TypeFlags,
    tp_new: ?NativeNew = null,
    doc: ?[]const u8 = null,
};

// ============================================================
// Функции / модули / код
// ============================================================

/// kwargs для нативных вызовов
pub const KwArgs = struct {
    names: []const []const u8,
    vals: []const Obj,

    pub fn get(self: *const KwArgs, name: []const u8) ?Obj {
        for (self.names, 0..) |n, i| {
            if (std.mem.eql(u8, n, name)) return self.vals[i];
        }
        return null;
    }
};

pub const BuiltinFn = *const fn (vm: *vm_mod.VM, args: []const Obj, kw: ?KwArgs) anyerror!Obj;

/// Обёртка generic-функции `(vm: anytype, args, kw)` в конкретный BuiltinFn.
/// Позволяет всем встроенным функциям оставаться anytype, а хранить указатель — конкретный.
pub fn wrapBuiltin(comptime f: anytype) BuiltinFn {
    return struct {
        fn call(vm: *vm_mod.VM, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
            return f(vm, args, kw);
        }
    }.call;
}

/// bigint → f64 с насыщением в ±inf (аналог CPython OverflowError отложен на потом).
pub fn bigFloat(b: *const Big) f64 {
    if (b.toConst().bitCountAbs() > 1024) {
        return if (b.isPositive()) std.math.inf(f64) else -std.math.inf(f64);
    }
    return b.toConst().toFloat(f64, .nearest_even)[0];
}

/// bigint → i64 или error (переполнение).
pub fn bigToI64(b: *const Big) error{TargetTooSmall}!i64 {
    return b.toConst().toInt(i64) catch return error.TargetTooSmall;
}

pub const Builtin = struct {
    name: []const u8,
    f: BuiltinFn,
    doc: ?[]const u8 = null,
};

pub const Method = struct {
    self_obj: Obj,
    func: Obj,
};

pub const Function = struct {
    name: []const u8,
    qualname: []const u8,
    code: *Code,
    globals: *Dict,
    closure: []*Cell, // соответствует code.freevars
    defaults: []Obj,
    kwdefaults: ?*Dict,
    annotations: ?*Obj = null,
    dict: ?*Dict = null, // __dict__ функции (произвольные атрибуты: cache_info, __wrapped__, ...)
};

pub const Module = struct {
    name: []const u8,
    dict: *Dict,
    file: ?[]const u8 = null,
    path: ?[]const []const u8 = null, // __path__ для пакетов
    spec: ?Obj = null,
};

pub const Code = struct {
    name: []const u8,
    qualname: []const u8,
    filename: []const u8,
    firstlineno: u32,
    argcount: u16, // позиционные параметры (без self? включая)
    posonly: u16,
    kwonly: u16,
    nlocals: u16,
    varnames: []const []const u8, // params первыми
    cellvars: []const []const u8,
    freevars: []const []const u8,
    flags: packed struct(u8) {
        varargs: bool = false,
        varkw: bool = false,
        generator: bool = false,
        coroutine: bool = false,
        _pad: u4 = 0,
    },
    stacksize: u16,
    code: []const u8,
    consts: []const Obj,
    names: []const []const u8,
    lines: []const u32, // по одной на каждые 3 байта кода
};

pub const Cell = struct {
    v: ?Obj = null,
};

pub const Generator = struct {
    frame: ?*Frame, // null когда exhausted/closed
    started: bool = false,
    finished: bool = false,
    closed: bool = false,
};

pub const Block = struct {
    kind: enum { except_, finally_, with_ },
    handler: usize, // pc обработчика
    stack_lvl: usize, // глубина стека на момент входа
    after_pc: usize = 0, // куда прыгнуть если with подавил исключение
    exit_fn: ?Obj = null, // __exit__ для with
};

pub const Frame = struct {
    code: *Code,
    ip: usize,
    stack: std.ArrayList(Obj),
    // FAST-локалы (функции):
    locals: []Obj, // nlocals
    locals_set: []bool,
    // NAME-скопы (модуль/класс):
    locals_dict: ?*Dict = null,
    cells: []*Cell, // cellvars ++ freevars
    globals: *Dict,
    builtins: *Dict,
    blocks: std.ArrayList(Block),
    generator: ?*Generator = null,
    pending_exc: ?Obj = null, // исключение, с которым вошли в finally/with-обработчик
    depth_counted: bool = false, // VM учла этот фрейм в recursion depth

    pub fn lineNo(self: *const Frame) u32 {
        const idx = self.ip / 3;
        if (idx < self.code.lines.len) return self.code.lines[idx];
        return self.code.firstlineno;
    }
};

pub const TbItem = struct {
    filename: []const u8,
    lineno: u32,
    name: []const u8,
};

pub const Exc = struct {
    args: []Obj = &.{},
    dict: Dict, // атрибуты экземпляра
    tb: std.ArrayList(TbItem) = .empty,
    cause: ?Obj = null,
    context: ?Obj = null,
    suppress_context: bool = false,
    msg_cache: ?[]const u8 = null,
};

// ============================================================
// Дескрипторы и прочие типы
// ============================================================

pub const Property = struct {
    fget: ?Obj = null,
    fset: ?Obj = null,
    fdel: ?Obj = null,
    doc: ?Obj = null,
};

pub const StaticM = struct { callable: Obj };
pub const ClassM = struct { callable: Obj };
pub const Super = struct {
    ty: ?*Type = null, // класс-якорь (искать ПОСЛЕ него в mro obj_type)
    obj: ?Obj = null, // экземпляр ty-иерархии (или сам Type для super в classmethod)
    obj_type: ?*Type = null, // тип obj (или obj, если obj — Type)
};

pub const Slice = struct {
    start: ?Obj,
    stop: ?Obj,
    step: ?Obj,

    /// CPython slice.indices: возвращает (start, stop, step, slice_len)
    fn asInt(o: ?Obj) ?i64 {
        if (o) |x| {
            switch (x.v) {
                .int => |i| return i,
                .bool_ => |b| return if (b) 1 else 0,
                else => return null,
            }
        }
        return null;
    }

    pub fn indices(self: *const Slice, length: i64) ?struct { i64, i64, i64, i64 } {
        const len_i = length;
        var step: i64 = 1;
        if (self.step) |s| {
            if (s.isNone()) {
                step = 1;
            } else {
                step = asInt(s) orelse return null;
            }
        }
        if (step == 0) return null;
        var start: i64 = undefined;
        if (self.start == null or self.start.?.isNone()) {
            start = if (step < 0) len_i - 1 else 0;
        } else {
            start = asInt(self.start) orelse return null;
            if (start < 0) start += len_i;
            if (start < 0) start = if (step < 0) -1 else 0;
            if (start >= len_i) start = if (step < 0) len_i - 1 else len_i;
        }
        var stop: i64 = undefined;
        if (self.stop == null or self.stop.?.isNone()) {
            stop = if (step < 0) -1 else len_i;
        } else {
            stop = asInt(self.stop) orelse return null;
            if (stop < 0) stop += len_i;
            if (stop < 0) stop = if (step < 0) -1 else 0;
            if (stop >= len_i) stop = if (step < 0) len_i - 1 else len_i;
        }
        var slen: i64 = 0;
        if (step > 0) {
            if (stop > start) slen = @divTrunc(stop - start + step - 1, step);
        } else {
            if (start > stop) slen = @divTrunc(stop - start + step + 1, step);
        }
        return .{ start, stop, step, slen };
    }
};

pub const Range = struct {
    start: i64,
    stop: i64,
    step: i64,

    pub fn len(self: *const Range) usize {
        const s = self.step;
        var n: i64 = 0;
        if (s > 0) {
            if (self.stop > self.start) n = @divTrunc(self.stop - self.start + s - 1, s);
        } else {
            if (self.start > self.stop) n = @divTrunc(self.stop - self.start + s + 1, s);
        }
        return @intCast(n);
    }

    pub fn get(self: *const Range, i: usize) i64 {
        return self.start + self.step * @as(i64, @intCast(i));
    }

    pub fn contains(self: *const Range, v: i64) bool {
        if (self.step > 0) {
            if (v < self.start or v >= self.stop) return false;
        } else {
            if (v > self.start or v <= self.stop) return false;
        }
        return @mod(v - self.start, self.step) == 0;
    }
};

// ============================================================
// Итераторы
// ============================================================

pub const Iter = union(enum) {
    list_iter: struct { l: *List, i: usize },
    tuple_iter: struct { t: []*PyObj, i: usize },
    str_iter: struct { s: *Str, cp_i: usize },
    bytes_iter: struct { b: []const u8, i: usize },
    range_iter: struct { r: *Range, i: usize },
    dict_iter: struct { d: *Dict, i: usize, kind: DictIterKind },
    set_iter: struct { s: *Set, i: usize },
    seq_iter: struct { o: Obj, i: i64 }, // __getitem__ protocol
    reversed_seq: struct { o: Obj, i: i64 }, // reversed() над последовательностью
    enumerate_iter: struct { it: Obj, i: i64 },
    zip_iter: struct { its: []Obj },
    map_iter: struct { f: Obj, its: []Obj },
    filter_iter: struct { f: ?Obj, it: Obj },

    pub const DictIterKind = enum { keys, values, items };

    /// Следующий живой индекс в dict entries
    fn dictNext(d: *Dict, i: *usize) ?*Dict.Entry {
        while (i.* < d.entries.items.len) {
            const e = &d.entries.items[i.*];
            i.* += 1;
            if (e.key != null) return e;
        }
        return null;
    }

    /// Возвращает null при исчерпании. Может бросать PyError (seq protocol).
    pub fn next(self: *Iter, vm: anytype) anyerror!?Obj {
        switch (self.*) {
            .list_iter => |*li| {
                if (li.i >= li.l.items.items.len) return null;
                const o = li.l.items.items[li.i];
                li.i += 1;
                return o;
            },
            .tuple_iter => |*ti| {
                if (ti.i >= ti.t.len) return null;
                const o = ti.t[ti.i];
                ti.i += 1;
                return o;
            },
            .str_iter => |*si| {
                const bi = Str.byteIndexOfCp(si.s.bytes, si.cp_i);
                if (bi >= si.s.bytes.len) return null;
                const l = std.unicode.utf8ByteSequenceLength(si.s.bytes[bi]) catch 1;
                si.cp_i += 1;
                const end = @min(bi + l, si.s.bytes.len);
                return vm.rt.newStr(si.s.bytes[bi..end]);
            },
            .bytes_iter => |*bi| {
                if (bi.i >= bi.b.len) return null;
                const v = bi.b[bi.i];
                bi.i += 1;
                return vm.rt.newInt(v);
            },
            .range_iter => |*ri| {
                if (ri.i >= ri.r.len()) return null;
                const v = ri.r.get(ri.i);
                ri.i += 1;
                return vm.rt.newInt(v);
            },
            .dict_iter => |*di| {
                const e = dictNext(di.d, &di.i) orelse return null;
                return switch (di.kind) {
                    .keys => e.key.?,
                    .values => e.val.?,
                    .items => blk: {
                        const pair = try vm.rt.gpa.alloc(Obj, 2);
                        pair[0] = e.key.?;
                        pair[1] = e.val.?;
                        break :blk try vm.rt.newTupleOwned(pair);
                    },
                };
            },
            .set_iter => |*si| {
                const e = dictNext(&si.s.dict, &si.i) orelse return null;
                return e.key.?;
            },
            .seq_iter => |*si| {
                const item = vm.pyGetItemInt(si.o, si.i) catch |e| {
                    if (e == error.PyExc and vm.isIndexError()) return null;
                    return e;
                };
                si.i += 1;
                return item;
            },
            .reversed_seq => |*rs| {
                if (rs.i < 0) return null;
                const item = try vm.pyGetItemInt(rs.o, rs.i);
                rs.i -= 1;
                return item;
            },
            .enumerate_iter => |*en| {
                const item = (try vm.pyNext(en.it)) orelse return null;
                const idx = en.i;
                en.i += 1;
                const rt = vm.rt;
                const pair = try rt.gpa.alloc(*PyObj, 2);
                pair[0] = try rt.newInt(idx);
                pair[1] = item;
                return rt.mkObj(rt.tuple_t, .{ .tuple = pair });
            },
            .zip_iter => |*zi| {
                const items = try vm.rt.gpa.alloc(*PyObj, zi.its.len);
                for (zi.its, 0..) |it, k| {
                    items[k] = (try vm.pyNext(it)) orelse return null;
                }
                return vm.rt.mkObj(vm.rt.tuple_t, .{ .tuple = items });
            },
            .map_iter => |*mi| {
                const items = try vm.rt.gpa.alloc(*PyObj, mi.its.len);
                for (mi.its, 0..) |it, k| {
                    items[k] = (try vm.pyNext(it)) orelse return null;
                }
                return vm.pyCall(mi.f, items, null);
            },
            .filter_iter => |*fi| {
                while (true) {
                    const item = (try vm.pyNext(fi.it)) orelse return null;
                    var keep: bool = undefined;
                    if (fi.f) |f| {
                        const r = try vm.pyCall(f, &.{item}, null);
                        keep = try vm.pyTruthy(r);
                    } else {
                        keep = try vm.pyTruthy(item);
                    }
                    if (keep) return item;
                }
            },
        }
    }
};

// ============================================================
// Файлы (io)
// ============================================================

pub const File = struct {
    f: ?std.Io.File = null, // открытый файл (null — закрыт); std.Io — мультиплатформенный дескриптор
    std_fd: ?StdFd = null, // спец-потоки
    mem_buf: ?*std.ArrayList(u8) = null, // BytesIO/StringIO: данные в памяти
    readable: bool,
    writable: bool,
    binary: bool,
    close_fd: bool = true,
    name: ?[]const u8 = null,
    encoding: []const u8 = "utf-8",
    errors: []const u8 = "strict",
    pushback: std.ArrayList(u8) = .empty, // для readline/read ahead
    eof_read_done: bool = false,
    pos: u64 = 0, // логическая позиция (для positional read/write — seekable файла)

    pub const StdFd = enum { stdin, stdout, stderr };
};

// ============================================================
// Потоки (включается из vm; структуры здесь чтобы быть значениями)
// ============================================================

pub const Lock = struct {
    locked: bool = false,
    owner: ?usize = null, // thread id (для RLock и отладки)
    count: usize = 0, // для RLock
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    is_rlock: bool = false,
};

pub const Local = struct {
    // threading.local: хранилище по thread-id
    map: std.AutoHashMapUnmanaged(usize, *Dict) = .empty,
    mutex: std.Thread.Mutex = .{},
};

// ============================================================
// bignum helpers
// ============================================================

pub fn bigFromI64(gpa: Allocator, v: i64) !*Big {
    const b = try gpa.create(Big);
    b.* = try Big.initSet(gpa, v);
    return b;
}

pub fn bigClone(gpa: Allocator, src_b: *const Big) !*Big {
    const nb = try gpa.create(Big);
    nb.* = try Big.init(gpa);
    try nb.copy(src_b.toConst());
    return nb;
}

pub fn bigParse(gpa: Allocator, text: []const u8, base: u8) !?*Big {
    const b = try gpa.create(Big);
    b.* = Big.initSet(gpa, 0) catch return null;
    b.setString(base, text) catch {
        b.deinit();
        gpa.destroy(b);
        return null;
    };
    return b;
}
