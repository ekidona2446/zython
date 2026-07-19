//! Runtime — владелец состояния интерпретатора (аналог _PyRuntimeState).
//! Аллокаторы, синглтоны (None/True/False), реестр типов, конструкторы объектов,
//! C3-линеаризация, sys.modules, builtins-дикт.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const object = @import("../object/object.zig");

pub const Obj = object.Obj;
const PyObj = object.PyObj;
const Type = object.Type;
const Dict = object.Dict;

pub const Runtime = struct {
    gpa: Allocator, // арена-аллокатор (основной; объекты живут до конца рантайма)
    arena: *std.heap.ArenaAllocator,
    backing: Allocator, // исходный gpa (для арены)

    // --- синглтоны ---
    none_obj: Obj,
    true_obj: Obj,
    false_obj: Obj,
    notimpl_obj: Obj,
    ellipsis_obj: Obj,

    // --- типы ---
    object_t: *Type,
    type_t: *Type,
    none_t: *Type,
    bool_t: *Type,
    int_t: *Type,
    float_t: *Type,
    str_t: *Type,
    bytes_t: *Type,
    bytearray_t: *Type,
    list_t: *Type,
    tuple_t: *Type,
    dict_t: *Type,
    set_t: *Type,
    frozenset_t: *Type,
    function_t: *Type,
    builtin_t: *Type,
    method_t: *Type,
    module_t: *Type,
    code_t: *Type,
    generator_t: *Type,
    cell_t: *Type,
    slice_t: *Type,
    range_t: *Type,
    iter_t: *Type, // обобщённый итератор (внутренний)
    property_t: *Type,
    staticm_t: *Type,
    classm_t: *Type,
    super_t: *Type,
    notimpl_t: *Type,
    ellipsis_t: *Type,
    file_t: *Type,
    lock_t: *Type,
    local_t: *Type,
    traceback_t: *Type,
    frame_t: *Type,

    // исключения: имя → тип (иерархия построена в builtins.registerExceptions)
    exc_types: std.StringHashMap(*Type),
    base_exception_t: *Type,
    exception_t: *Type,

    // --- модули и builtins ---
    builtins_dict: *Dict, // dict модуля builtins
    modules: *Dict, // sys.modules (ключи — str объекты)

    // sys.path (список str)
    sys_path: *object.List,

    io: ?std.Io = null, // Zig 0.16 io для fs операций (main передаёт)

    // директория со встроенной stdlib (vendored Lib: lib/python3.14 рядом с exe)
    lib_dir: ?[]const u8 = null,

    // argv процесса (sys.argv)
    argv: []const []const u8 = &.{},

    // окружение (os.environ) — dict str:str, заполняется из main
    py_environ: ?*Dict = null,

    // реестр всех типов (для __subclasses__ и GC-этапа)
    all_types: std.ArrayList(*Type) = .empty,

    interned: std.StringHashMap(Obj),

    // --- stdout/stderr/stdin (std.Io.File.Writer streaming) ---
    out_w: ?*std.Io.File.Writer = null,
    err_w: ?*std.Io.File.Writer = null,
    out_buf: []u8 = &.{},
    err_buf: []u8 = &.{},

    /// Настроить io + стандартные потоки (вызывается из main после Init).
    pub fn setupIo(self: *Runtime, io: std.Io) !void {
        self.io = io;
        self.out_buf = try self.gpa.alloc(u8, 4096);
        self.err_buf = try self.gpa.alloc(u8, 1024);
        const ow = try self.gpa.create(std.Io.File.Writer);
        ow.* = std.Io.File.Writer.initStreaming(std.Io.File.stdout(), io, self.out_buf);
        self.out_w = ow;
        const ew = try self.gpa.create(std.Io.File.Writer);
        ew.* = std.Io.File.Writer.initStreaming(std.Io.File.stderr(), io, self.err_buf);
        self.err_w = ew;
    }

    pub fn outWrite(self: *Runtime, s: []const u8) void {
        if (self.out_w) |w| {
            w.interface.writeAll(s) catch {};
        } else {
            std.debug.print("{s}", .{s});
        }
    }

    pub fn outFlush(self: *Runtime) void {
        if (self.out_w) |w| {
            w.interface.flush() catch {};
        }
    }

    pub fn errWrite(self: *Runtime, s: []const u8) void {
        if (self.err_w) |w| {
            w.interface.writeAll(s) catch {};
            w.interface.flush() catch {};
        } else {
            std.debug.print("{s}", .{s});
        }
    }

    /// Прочитать строку из stdin (до \n включительно). EOF → вернуть "" после первого чтения.
    pub fn inReadLine(self: *Runtime) ![]const u8 {
        const io = self.io orelse return "";
        var out: std.ArrayList(u8) = .empty;
        const stdin = std.Io.File.stdin();
        var one: [1]u8 = undefined;
        while (true) {
            const n = stdin.readStreaming(io, &.{&one}) catch break;
            if (n == 0) break;
            try out.append(self.gpa, one[0]);
            if (one[0] == '\n') break;
        }
        return out.items;
    }

    pub fn init(backing: Allocator, io: ?std.Io) !*Runtime {
        const arena = try backing.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(backing);
        const gpa = arena.allocator();

        const rt = try gpa.create(Runtime);
        rt.* = .{
            .gpa = gpa,
            .arena = arena,
            .backing = backing,
            .none_obj = try gpa.create(PyObj),
            .true_obj = try gpa.create(PyObj),
            .false_obj = try gpa.create(PyObj),
            .notimpl_obj = try gpa.create(PyObj),
            .ellipsis_obj = try gpa.create(PyObj),
            .object_t = undefined,
            .type_t = undefined,
            .none_t = undefined,
            .bool_t = undefined,
            .int_t = undefined,
            .float_t = undefined,
            .str_t = undefined,
            .bytes_t = undefined,
            .bytearray_t = undefined,
            .list_t = undefined,
            .tuple_t = undefined,
            .dict_t = undefined,
            .set_t = undefined,
            .frozenset_t = undefined,
            .function_t = undefined,
            .builtin_t = undefined,
            .method_t = undefined,
            .module_t = undefined,
            .code_t = undefined,
            .generator_t = undefined,
            .cell_t = undefined,
            .slice_t = undefined,
            .range_t = undefined,
            .iter_t = undefined,
            .property_t = undefined,
            .staticm_t = undefined,
            .classm_t = undefined,
            .super_t = undefined,
            .notimpl_t = undefined,
            .ellipsis_t = undefined,
            .file_t = undefined,
            .lock_t = undefined,
            .local_t = undefined,
            .traceback_t = undefined,
            .frame_t = undefined,
            .exc_types = std.StringHashMap(*Type).init(gpa),
            .base_exception_t = undefined,
            .exception_t = undefined,
            .builtins_dict = try gpa.create(Dict),
            .modules = try gpa.create(Dict),
            .sys_path = try gpa.create(object.List),
            .io = io,
            .interned = std.StringHashMap(Obj).init(gpa),
        };
        rt.builtins_dict.* = Dict.init();
        rt.modules.* = Dict.init();
        rt.sys_path.* = .{ .items = .empty };

        // --- sys.path: cwd + vendored lib + platform-specific site-packages + PYTHONPATH ---
        try rt.sys_path.items.append(gpa, try rt.newStr("")); // cwd
        try rt.sys_path.items.append(gpa, try rt.newStr("lib/python3.14")); // vendored
        try rt.addPlatformSitePaths(gpa);
        // PYTHONPATH (разделитель: ':' на posix, ';' на windows)
        if (std.c.getenv("PYTHONPATH")) |pp| {
            const pps = std.mem.span(pp);
            const sep: u8 = if (builtin.os.tag == .windows) ';' else ':';
            var it = std.mem.splitScalar(u8, pps, sep);
            while (it.next()) |p| {
                if (p.len == 0) continue;
                try rt.sys_path.items.append(gpa, try rt.newStr(p));
            }
        }

        // --- типы ---
        rt.object_t = try rt.mkTypeRaw("object", null);
        rt.type_t = try rt.mkTypeRaw("type", rt.object_t);
        rt.object_t.ty = rt.type_t;
        rt.type_t.ty = rt.type_t; // type — экземпляр самого себя
        rt.type_t.flags.is_type_obj = true;

        rt.none_t = try rt.mkType("NoneType", rt.object_t);
        rt.none_obj.* = .{ .ty = rt.none_t, .v = .none };
        rt.notimpl_t = try rt.mkType("NotImplementedType", rt.object_t);
        rt.notimpl_obj.* = .{ .ty = rt.notimpl_t, .v = .notimpl };
        rt.ellipsis_t = try rt.mkType("ellipsis", rt.object_t);
        rt.ellipsis_obj.* = .{ .ty = rt.ellipsis_t, .v = .ellipsis };

        rt.bool_t = try rt.mkType("bool", null); // база int — установим позже
        rt.int_t = try rt.mkType("int", rt.object_t);
        rt.bool_t.base = rt.int_t;
        rt.bool_t.bases = try rt.dupeTypes(&.{rt.int_t});
        rt.bool_t.mro = try rt.dupeTypes(&.{ rt.bool_t, rt.int_t, rt.object_t });

        rt.true_obj.* = .{ .ty = rt.bool_t, .v = .{ .bool_ = true } };
        rt.false_obj.* = .{ .ty = rt.bool_t, .v = .{ .bool_ = false } };

        rt.float_t = try rt.mkType("float", rt.object_t);
        rt.str_t = try rt.mkType("str", rt.object_t);
        rt.bytes_t = try rt.mkType("bytes", rt.object_t);
        rt.bytearray_t = try rt.mkType("bytearray", rt.object_t);
        rt.list_t = try rt.mkType("list", rt.object_t);
        rt.tuple_t = try rt.mkType("tuple", rt.object_t);
        rt.dict_t = try rt.mkType("dict", rt.object_t);
        rt.set_t = try rt.mkType("set", rt.object_t);
        rt.frozenset_t = try rt.mkType("frozenset", rt.object_t);
        rt.function_t = try rt.mkType("function", rt.object_t);
        rt.builtin_t = try rt.mkType("builtin_function_or_method", rt.object_t);
        rt.method_t = try rt.mkType("method", rt.object_t);
        rt.module_t = try rt.mkType("module", rt.object_t);
        rt.code_t = try rt.mkType("code", rt.object_t);
        rt.generator_t = try rt.mkType("generator", rt.object_t);
        rt.cell_t = try rt.mkType("cell", rt.object_t);
        rt.slice_t = try rt.mkType("slice", rt.object_t);
        rt.range_t = try rt.mkType("range", rt.object_t);
        rt.iter_t = try rt.mkType("iterator", rt.object_t);
        rt.property_t = try rt.mkType("property", rt.object_t);
        rt.staticm_t = try rt.mkType("staticmethod", rt.object_t);
        rt.classm_t = try rt.mkType("classmethod", rt.object_t);
        rt.super_t = try rt.mkType("super", rt.object_t);
        rt.file_t = try rt.mkType("TextIOWrapper", rt.object_t);
        rt.lock_t = try rt.mkType("lock", rt.object_t);
        rt.local_t = try rt.mkType("_local", rt.object_t);
        rt.traceback_t = try rt.mkType("traceback", rt.object_t);
        rt.frame_t = try rt.mkType("frame", rt.object_t);

        return rt;
    }

    pub fn deinit(self: *Runtime) void {
        self.arena.deinit();
        self.backing.destroy(self.arena);
    }

    /// Мультиплатформенное заполнение sys.path путями site-packages (Linux/macOS/Windows).
    fn addPlatformSitePaths(self: *Runtime, gpa: Allocator) !void {
        const vers = [_][]const u8{ "3.14", "3.13", "3.12" };
        switch (builtin.os.tag) {
            .linux => {
                for (vers) |ver| {
                    inline for ([_][]const u8{
                        "/usr/local/lib/python{s}/site-packages",
                        "/usr/lib/python{s}/site-packages",
                        "/usr/lib/python{s}",
                    }) |tmpl| {
                        try self.sys_path.items.append(gpa, try self.newStr(try std.fmt.allocPrint(gpa, tmpl, .{ver})));
                    }
                }
                try self.sys_path.items.append(gpa, try self.newStr("/usr/lib/python3/dist-packages"));
                try self.sys_path.items.append(gpa, try self.newStr("/usr/local/lib/python3/dist-packages"));
            },
            .macos => {
                for (vers) |ver| {
                    inline for ([_][]const u8{
                        "/opt/homebrew/lib/python{s}/site-packages",
                        "/usr/local/lib/python{s}/site-packages",
                        "/Library/Python/{s}/lib/python/site-packages",
                    }) |tmpl| {
                        try self.sys_path.items.append(gpa, try self.newStr(try std.fmt.allocPrint(gpa, tmpl, .{ver})));
                    }
                }
            },
            .windows => {
                inline for ([_][]const u8{ "314", "313", "312" }) |v| {
                    inline for ([_][]const u8{
                        "C:\\Python{s}\\Lib\\site-packages",
                        "C:\\Program Files\\Python{s}\\Lib\\site-packages",
                    }) |tmpl| {
                        try self.sys_path.items.append(gpa, try self.newStr(try std.fmt.allocPrint(gpa, tmpl, .{v})));
                    }
                }
                // user site через APPDATA
                if (std.c.getenv("APPDATA")) |ar| {
                    const p = try std.fmt.allocPrint(gpa, "{s}\\Python\\Python313\\site-packages", .{std.mem.span(ar)});
                    try self.sys_path.items.append(gpa, try self.newStr(p));
                }
            },
            else => {},
        }
    }

    fn dupeTypes(self: *Runtime, types: []const *Type) ![]const *Type {
        return try self.gpa.dupe(*Type, types);
    }

    fn mkTypeRaw(self: *Runtime, name: []const u8, base: ?*Type) !*Type {
        const t = try self.gpa.create(Type);
        const d = try self.gpa.create(Dict);
        d.* = Dict.init();
        t.* = .{
            .ty = undefined, // выставляется вызывающим
            .name = name,
            .qualname = name,
            .module = "builtins",
            .base = base,
            .bases = &.{},
            .mro = &.{},
            .dict = d,
            .flags = .{ .builtin = true },
        };
        // одиночная линейная иерархия (сырьё для builtins): mro = [t] + base.mro
        var mro: std.ArrayList(*Type) = .empty;
        try mro.append(self.gpa, t);
        if (base) |b| {
            for (b.mro) |anc| {
                if (anc != t) try mro.append(self.gpa, anc);
            }
        }
        t.mro = mro.items;
        self.all_types.append(self.gpa, t) catch {};
        return t;
    }

    /// Пользовательский класс: name, базы (type_ значения), пространство имён тела.
    /// Аналог type_new + PyType_Ready в CPython (typeobject.c).
    pub fn newUserType(self: *Runtime, name: []const u8, vm: anytype, bases: []const Obj, ns: *Dict) !*Type {
        const t = try self.gpa.create(Type);
        t.* = .{
            .ty = self.type_t,
            .name = try self.gpa.dupe(u8, name),
            .qualname = t.name,
            .module = "builtins",
            .base = if (bases.len > 0) bases[0].v.type_ else self.object_t,
            .bases = &.{},
            .mro = &.{},
            .dict = ns,
            .flags = .{ .builtin = false, .has_inst_dict = true },
        };
        self.all_types.append(self.gpa, t) catch {};
        const bt = try self.gpa.alloc(*Type, bases.len);
        for (bases, 0..) |b, i| bt[i] = b.v.type_;
        t.bases = bt;
        // подкласс type (метакласс) — тоже тип-объект: наследуем is_type_obj от баз
        for (bt) |b| {
            if (b.flags.is_type_obj) {
                t.flags.is_type_obj = true;
                break;
            }
        }
        // __module__ из ns
        const dict_mod = ns; // locals dict уже содержит __module__/__qualname__
        _ = dict_mod;
        var it = ns.iterAlive();
        while (it.next()) |e| {
            if (e.key.?.v == .str and std.mem.eql(u8, e.key.?.v.str.bytes, "__qualname__")) {
                if (e.val.?.v == .str) t.qualname = e.val.?.v.str.bytes;
            }
            if (e.key.?.v == .str and std.mem.eql(u8, e.key.?.v.str.bytes, "__module__")) {
                if (e.val.?.v == .str) t.module = e.val.?.v.str.bytes;
            }
        }
        // MRO: пустой список баз → object
        const eb: []const *Type = if (bt.len == 0) try self.dupeTypes(&.{self.object_t}) else bt;
        t.mro = self.c3mro(t, eb) catch {
            // конфликт MRO — бросаем Python TypeError через vm
            try vm.raiseFmt("TypeError", "Cannot create a consistent method resolution order (MRO) for bases", .{});
            return error.PyExc;
        };
        return t;
    }

    /// Создать встроенный тип с базой; MRO — цепочка до object.
    pub fn mkType(self: *Runtime, name: []const u8, base: ?*Type) !*Type {
        const t = try self.mkTypeRaw(name, base);
        t.ty = self.type_t;
        const b = base orelse self.object_t;
        t.base = b;
        t.bases = try self.dupeTypes(&.{b});
        var mro_list: std.ArrayList(*Type) = .empty;
        try mro_list.append(self.gpa, t);
        try mro_list.append(self.gpa, b);
        if (b.mro.len > 1) {
            for (b.mro[1..]) |anc| try mro_list.append(self.gpa, anc);
        }
        t.mro = try mro_list.toOwnedSlice(self.gpa);
        return t;
    }

    /// C3-линеаризация (алгоритм как в CPython typeobject.c).
    pub fn c3mro(self: *Runtime, cls: *Type, bases: []const *Type) ![]const *Type {
        var seqs: std.ArrayList([]const *Type) = .empty;
        defer seqs.deinit(self.gpa);
        for (bases) |b| try seqs.append(self.gpa, b.mro);
        if (bases.len > 0) try seqs.append(self.gpa, bases);

        var out: std.ArrayList(*Type) = .empty;
        try out.append(self.gpa, cls);

        // work with mutable heads
        const S = struct {
            seqs: std.ArrayList([]const *Type),
        };
        _ = S;
        while (true) {
            // убрать пустые
            var i: usize = 0;
            while (i < seqs.items.len) {
                if (seqs.items[i].len == 0) {
                    _ = seqs.orderedRemove(i);
                } else i += 1;
            }
            if (seqs.items.len == 0) break;
            // найти хорошую голову
            var found: ?*Type = null;
            outer: for (seqs.items) |seq| {
                const head = seq[0];
                for (seqs.items) |other| {
                    for (other[1..]) |t| {
                        if (t == head) continue :outer;
                    }
                }
                found = head;
                break;
            }
            if (found == null) return error.MroConflict;
            const h = found.?;
            try out.append(self.gpa, h);
            // удалить h из голов всех seqs (он обязан быть головой только своей seq, но может повторяться)
            for (seqs.items, 0..) |seq, si| {
                if (seq.len > 0 and seq[0] == h) {
                    seqs.items[si] = seq[1..];
                }
            }
        }
        return try out.toOwnedSlice(self.gpa);
    }

    // ============================================================
    // Конструкторы значений
    // ============================================================

    pub fn mkObj(self: *Runtime, ty: *Type, v: object.Value) !Obj {
        const o = try self.gpa.create(PyObj);
        o.* = .{ .ty = ty, .v = v };
        return o;
    }

    pub fn newNone(self: *Runtime) Obj {
        return self.none_obj;
    }
    pub fn newBool(self: *Runtime, b: bool) Obj {
        return if (b) self.true_obj else self.false_obj;
    }
    pub fn newNotImpl(self: *Runtime) Obj {
        return self.notimpl_obj;
    }
    pub fn newInt(self: *Runtime, v: i64) !Obj {
        return self.mkObj(self.int_t, .{ .int = v });
    }
    pub fn newBig(self: *Runtime, b: *object.Big) !Obj {
        return self.mkObj(self.int_t, .{ .bigint = b });
    }
    pub fn newFloat(self: *Runtime, v: f64) !Obj {
        return self.mkObj(self.float_t, .{ .float = v });
    }

    pub fn newStr(self: *Runtime, s: []const u8) !Obj {
        const duped = try self.gpa.dupe(u8, s);
        return self.newStrOwned(duped);
    }
    pub fn newStrOwned(self: *Runtime, s: []u8) !Obj {
        const st = try self.gpa.create(object.Str);
        st.* = .{ .bytes = s, .cp_len = object.Str.countCp(s) };
        return self.mkObj(self.str_t, .{ .str = st });
    }
    pub fn newBytes(self: *Runtime, s: []const u8) !Obj {
        const b = try self.gpa.create(object.Bytes);
        b.* = .{ .data = try self.gpa.dupe(u8, s) };
        return self.mkObj(self.bytes_t, .{ .bytes = b });
    }
    pub fn newBytesOwned(self: *Runtime, s: []u8) !Obj {
        const b = try self.gpa.create(object.Bytes);
        b.* = .{ .data = s };
        return self.mkObj(self.bytes_t, .{ .bytes = b });
    }
    pub fn newBytearray(self: *Runtime, s: []const u8) !Obj {
        const b = try self.gpa.create(object.ByteArray);
        b.* = .{ .data = .empty };
        try b.data.appendSlice(self.gpa, s);
        return self.mkObj(self.bytearray_t, .{ .bytearray = b });
    }

    pub fn newList(self: *Runtime) !Obj {
        const l = try self.gpa.create(object.List);
        l.* = .{ .items = .empty };
        return self.mkObj(self.list_t, .{ .list = l });
    }
    pub fn newListFrom(self: *Runtime, items: []const Obj) !Obj {
        const o = try self.newList();
        try o.v.list.items.appendSlice(self.gpa, items);
        return o;
    }

    pub fn newTuple(self: *Runtime, items: []const Obj) !Obj {
        const duped = try self.gpa.dupe(Obj, items);
        return self.mkObj(self.tuple_t, .{ .tuple = duped });
    }
    pub fn newTupleOwned(self: *Runtime, items: []Obj) !Obj {
        return self.mkObj(self.tuple_t, .{ .tuple = items });
    }

    pub fn newDictObj(self: *Runtime) !Obj {
        const d = try self.gpa.create(Dict);
        d.* = Dict.init();
        return self.mkObj(self.dict_t, .{ .dict = d });
    }
    pub fn newDict(self: *Runtime) !*Dict {
        const d = try self.gpa.create(Dict);
        d.* = Dict.init();
        return d;
    }

    pub fn newSetObj(self: *Runtime, frozen: bool, items: []const Obj) !Obj {
        const s = try self.gpa.create(object.Set);
        s.* = object.Set.init();
        const o = try self.mkObj(if (frozen) self.frozenset_t else self.set_t, if (frozen) .{ .frozenset = s } else .{ .set = s });
        for (items) |it| {
            const h = try self.pyHash(it);
            try s.dict.setWithHash(self, it, self.none_obj, h);
        }
        return o;
    }

    pub fn newBuiltin(self: *Runtime, name: []const u8, f: object.BuiltinFn) !Obj {
        const b = try self.gpa.create(object.Builtin);
        b.* = .{ .name = name, .f = f };
        return self.mkObj(self.builtin_t, .{ .builtin = b });
    }

    pub fn newMethod(self: *Runtime, self_obj: Obj, func: Obj) !Obj {
        const m = try self.gpa.create(object.Method);
        m.* = .{ .self_obj = self_obj, .func = func };
        return self.mkObj(self.method_t, .{ .method = m });
    }

    pub fn newFunction(self: *Runtime, name: []const u8, qualname: []const u8, code: *object.Code, globals: *Dict, closure: [] *object.Cell, defaults: []Obj, kwdefaults: ?*Dict) !Obj {
        const f = try self.gpa.create(object.Function);
        f.* = .{
            .name = name,
            .qualname = qualname,
            .code = code,
            .globals = globals,
            .closure = closure,
            .defaults = defaults,
            .kwdefaults = kwdefaults,
        };
        return self.mkObj(self.function_t, .{ .function = f });
    }

    pub fn newModuleObj(self: *Runtime, name: []const u8) !Obj {
        const m = try self.gpa.create(object.Module);
        m.* = .{ .name = try self.gpa.dupe(u8, name), .dict = try self.newDict() };
        return self.mkObj(self.module_t, .{ .module = m });
    }

    pub fn newCell(self: *Runtime, v: ?Obj) !*object.Cell {
        const c = try self.gpa.create(object.Cell);
        c.* = .{ .v = v };
        return c;
    }

    pub fn newSlice(self: *Runtime, start: ?Obj, stop: ?Obj, step: ?Obj) !Obj {
        const s = try self.gpa.create(object.Slice);
        s.* = .{ .start = start, .stop = stop, .step = step };
        return self.mkObj(self.slice_t, .{ .slice = s });
    }

    pub fn newRange(self: *Runtime, start: i64, stop: i64, step: i64) !Obj {
        const r = try self.gpa.create(object.Range);
        r.* = .{ .start = start, .stop = stop, .step = step };
        return self.mkObj(self.range_t, .{ .range = r });
    }

    pub fn newIter(self: *Runtime, it: object.Iter) !Obj {
        const p = try self.gpa.create(object.Iter);
        p.* = it;
        return self.mkObj(self.iter_t, .{ .iter = p });
    }

    pub fn newGenerator(self: *Runtime, frame: *object.Frame) !Obj {
        const g = try self.gpa.create(object.Generator);
        g.* = .{ .frame = frame };
        frame.generator = g;
        return self.mkObj(self.generator_t, .{ .generator = g });
    }

    pub fn newInstance(self: *Runtime, cls: *Type) !Obj {
        const inst = try self.gpa.create(object.Instance);
        inst.* = .{ .dict = Dict.init() };
        return self.mkObj(cls, .{ .instance = inst });
    }

    pub fn newProperty(self: *Runtime, p: object.Property) !Obj {
        const pp = try self.gpa.create(object.Property);
        pp.* = p;
        return self.mkObj(self.property_t, .{ .property = pp });
    }

    pub fn newStaticM(self: *Runtime, callable: Obj) !Obj {
        const s = try self.gpa.create(object.StaticM);
        s.* = .{ .callable = callable };
        return self.mkObj(self.staticm_t, .{ .staticm = s });
    }

    pub fn newClassM(self: *Runtime, callable: Obj) !Obj {
        const c = try self.gpa.create(object.ClassM);
        c.* = .{ .callable = callable };
        return self.mkObj(self.classm_t, .{ .classm = c });
    }

    pub fn newSuper(self: *Runtime, ty: *Type, objb: Obj) !Obj {
        const s = try self.gpa.create(object.Super);
        s.* = .{ .ty = ty, .obj = objb };
        return self.mkObj(self.super_t, .{ .super_ = s });
    }

    pub fn newExc(self: *Runtime, cls: *Type) !Obj {
        const e = try self.gpa.create(object.Exc);
        e.* = .{ .dict = Dict.init() };
        return self.mkObj(cls, .{ .exc = e });
    }

    pub fn newFile(self: *Runtime, f: std.Io.File, readable: bool, writable: bool, binary: bool) !Obj {
        const fo = try self.gpa.create(object.File);
        fo.* = .{ .f = f, .readable = readable, .writable = writable, .binary = binary };
        return self.mkObj(self.file_t, .{ .file = fo });
    }

    pub fn newLock(self: *Runtime, is_rlock: bool) !Obj {
        const l = try self.gpa.create(object.Lock);
        l.* = .{ .is_rlock = is_rlock };
        return self.mkObj(self.lock_t, .{ .lock = l });
    }

    pub fn newLocal(self: *Runtime) !Obj {
        const l = try self.gpa.create(object.Local);
        l.* = .{};
        return self.mkObj(self.local_t, .{ .local = l });
    }

    /// Простое структурное равенство ключей (str/int/bool/tuple из них).
    /// Используется Dict при построении рантайма; полный dispatch — в protocol.
    pub fn pyEq(self: *Runtime, a: Obj, b: Obj) !bool {
        _ = self;
        if (a == b) return true;
        return switch (a.v) {
            .str => |sa| switch (b.v) {
                .str => |sb| std.mem.eql(u8, sa.bytes, sb.bytes),
                else => false,
            },
            .int => |ia| switch (b.v) {
                .int => |ib| ia == ib,
                .bool_ => |bb| ia == @intFromBool(bb),
                else => false,
            },
            .bool_ => |ba| switch (b.v) {
                .bool_ => |bb| ba == bb,
                .int => |ib| @as(i64, @intFromBool(ba)) == ib,
                else => false,
            },
            .none => b.v == .none,
            else => a == b,
        };
    }

    /// Полный хеш (через protocol; здесь быстрый путь для простых типов).
    pub fn pyHash(self: *Runtime, o: Obj) !u64 {
        return switch (o.v) {
            .str => |s| blk: {
                if (s.hash_cache != 0) break :blk @bitCast(s.hash_cache);
                const h = std.hash.Wyhash.hash(0x5eed, s.bytes);
                s.hash_cache = @bitCast(h | 1);
                break :blk h;
            },
            .int => |i| pyHashInt(i),
            .bool_ => |b| pyHashInt(@intFromBool(b)),
            .none => 0x4E0FE,
            .tuple => |t| blk: {
                var h: u64 = 0x345678;
                for (t) |item| {
                    const ih = try self.pyHash(item);
                    h = h *% 1000003 ^ ih;
                }
                break :blk h;
            },
            else => @intCast(@intFromPtr(o)),
        };
    }

    pub fn pyHashInt(v: i64) u64 {
        // CPython: hash(i) = i mod (2^61-1), -1 → -2
        const p: i64 = (1 << 61) - 1;
        var m = @mod(v, p);
        if (m == -1) m = -2;
        return @bitCast(m);
    }
};
