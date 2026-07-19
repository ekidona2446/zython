//! Компилятор AST → байткод: таблица символов + кодогенерация.
//! Аналог Python/compile.c + symtable.c (двухпроходный: символьное дерево, затем эмит).

const std = @import("std");
const ast = @import("../parser/ast.zig");
const object = @import("../object/object.zig");
const opcode_mod = @import("../vm/opcode.zig");
const rt_mod = @import("../runtime/runtime.zig");

const Obj = object.Obj;
const Opcode = opcode_mod.Opcode;
const Runtime = rt_mod.Runtime;

pub const CompileError = error{
    OutOfMemory,
    SyntaxError,
    MroConflict,
};

// ============================================================
// Символы и области
// ============================================================

pub const ScopeKind = enum { module_, class_, function_, lambda_, comprehension_ };
pub const CompKind = enum { list, set, dict, gen };

const SymFlags = struct {
    assigned: bool = false,
    param: bool = false,
    used: bool = false,
    global: bool = false,
    nonlocal: bool = false,
    free: bool = false, // freevar в этом scope
    cell: bool = false, // cellvar в этом scope
};

const Sym = struct {
    flags: SymFlags = .{},
};

const BlockKind = enum { loop, try_except, try_finally, with_ };
const BlockRec = struct {
    kind: BlockKind,
    break_label: ?usize = null, // для loop (метка)
    continue_label: ?usize = null,
    finally_body: []const ast.Stmt = &.{}, // для try_finally — чтобы inline-повторить
    with_exit_slot: ?u16 = null, // для with_
    break_jumps: std.ArrayList(usize) = .empty, // jump-позиции break в цикле (патч в blocks_pop)
};

pub const Scope = struct {
    kind: ScopeKind,
    name: []const u8,
    qualname: []const u8,
    parent: ?*Scope,
    syms: std.StringHashMap(Sym),
    children: std.ArrayList(*Scope),
    varnames: std.ArrayList([]const u8),
    cellvars: std.ArrayList([]const u8),
    freevars: std.ArrayList([]const u8),
    argcount: u16 = 0,
    posonly: u16 = 0,
    kwonly: u16 = 0,
    has_varargs: bool = false,
    has_varkw: bool = false,
    is_generator: bool = false,
    is_coroutine: bool = false,
    needs_name_scope: bool = false, // module/class → dict-based frame
    stacksize: u16 = 128,
    // кодогенерация
    code: std.ArrayList(u8),
    lines: std.ArrayList(u32),
    consts: std.ArrayList(Obj),
    names: std.ArrayList([]const u8),
    blocks: std.ArrayList(BlockRec),
    hidden_idx: usize = 0,

    // AST тела (для codegen функций/лямбд/классов)
    body_stmts: []const ast.Stmt = &.{},
    body_expr: ?*ast.Expr = null, // тело-выражение лямбды
    // comprehension
    body_comp: CompBody = .{ .elt = null, .key = null, .value = null, .gens = &.{} },
    comp_kind: CompKind = .list,
    emitted: bool = false, // уже сгенерирован этим codegen-проходом

    fn new(a: std.mem.Allocator, kind: ScopeKind, name: []const u8, qualname: []const u8, parent: ?*Scope) !*Scope {
        const s = try a.create(Scope);
        s.* = .{
            .kind = kind,
            .name = name,
            .qualname = qualname,
            .parent = parent,
            .syms = std.StringHashMap(Sym).init(a),
            .children = .empty,
            .varnames = .empty,
            .cellvars = .empty,
            .freevars = .empty,
            .code = .empty,
            .lines = .empty,
            .consts = .empty,
            .names = .empty,
            .blocks = .empty,
        };
        return s;
    }

    fn isFunctionLike(self: *Scope) bool {
        return self.kind == .function_ or self.kind == .lambda_ or self.kind == .comprehension_;
    }
};

// ============================================================
// Компилятор
// ============================================================

pub const Compiler = struct {
    rt: *Runtime,
    a: std.mem.Allocator, // арена рантайма
    filename: []const u8,

    pub fn init(rt: *Runtime, filename: []const u8) Compiler {
        return .{ .rt = rt, .a = rt.gpa, .filename = filename };
    }

    // ----------------------------------------------------------
    // Вход
    // ----------------------------------------------------------

    pub fn compileModule(self: *Compiler, mod: ast.Module) !*object.Code {
        const scope = try Scope.new(self.a, .module_, "<module>", "<module>", null);
        scope.needs_name_scope = true;
        try self.collectScope(scope, mod.body);
        try self.resolveFree(scope);
        try self.emitStmts(scope, mod.body);
        self.emit0(scope, .NOP, 0);
        self.emit0(scope, .END, 0);
        return self.finishScope(scope, "<module>");
    }

    fn finishScope(self: *Compiler, scope: *Scope, name: []const u8) !*object.Code {
        _ = name;
        const code = try self.a.create(object.Code);
        code.* = .{
            .name = scope.name,
            .qualname = scope.qualname,
            .filename = self.filename,
            .firstlineno = if (scope.body_stmts.len > 0) @intCast(@min(scope.body_stmts[0].lineno, std.math.maxInt(u32))) else if (scope.body_expr) |be| @intCast(@min(be.lineno, std.math.maxInt(u32))) else 1,
            .argcount = scope.argcount,
            .posonly = scope.posonly,
            .kwonly = scope.kwonly,
            .nlocals = @intCast(scope.varnames.items.len),
            .varnames = scope.varnames.items,
            .cellvars = scope.cellvars.items,
            .freevars = scope.freevars.items,
            .flags = .{
                .varargs = scope.has_varargs,
                .varkw = scope.has_varkw,
                .generator = scope.is_generator,
                .coroutine = scope.is_coroutine,
            },
            .stacksize = scope.stacksize + 64,
            .code = scope.code.items,
            .consts = scope.consts.items,
            .names = scope.names.items,
            .lines = scope.lines.items,
        };
        return code;
    }

    // ----------------------------------------------------------
    // Эмит-команды
    // ----------------------------------------------------------

    fn emitOp(self: *Compiler, scope: *Scope, op: Opcode, arg: u16, line: usize) void {
        scope.code.append(self.a, @intFromEnum(op)) catch {};
        scope.code.append(self.a, @truncate(arg & 0xff)) catch {};
        scope.code.append(self.a, @truncate(arg >> 8)) catch {};
        scope.lines.append(self.a, @intCast(line)) catch {};
    }

    fn emit0(self: *Compiler, scope: *Scope, op: Opcode, line: usize) void {
        self.emitOp(scope, op, 0, line);
    }

    fn pos(self: *Compiler, scope: *Scope) usize {
        _ = self;
        return scope.code.items.len;
    }

    fn patchAbs(self: *Compiler, scope: *Scope, at: usize, target: usize) void {
        _ = self;
        scope.code.items[at + 1] = @truncate(target & 0xff);
        scope.code.items[at + 2] = @truncate(target >> 8);
    }

    fn patchRel(self: *Compiler, scope: *Scope, at: usize, target: usize) void {
        // rel offset от конца инструкции
        _ = self;
        const rel = target - (at + 3);
        scope.code.items[at + 1] = @truncate(rel & 0xff);
        scope.code.items[at + 2] = @truncate(rel >> 8);
    }

    fn addConst(self: *Compiler, scope: *Scope, o: Obj) !u16 {
        // дедуп по простым типам
        for (scope.consts.items, 0..) |c, i| {
            if (constEq(c, o)) return @intCast(i);
        }
        const idx = scope.consts.items.len;
        try scope.consts.append(self.a, o);
        return @intCast(idx);
    }

    fn addNameIdx(self: *Compiler, scope: *Scope, name: []const u8) !u16 {
        for (scope.names.items, 0..) |n, i| {
            if (std.mem.eql(u8, n, name)) return @intCast(i);
        }
        const idx = scope.names.items.len;
        try scope.names.append(self.a, name);
        return @intCast(idx);
    }

    fn addVarnameIdx(self: *Compiler, scope: *Scope, name: []const u8) !u16 {
        for (scope.varnames.items, 0..) |n, i| {
            if (std.mem.eql(u8, n, name)) return @intCast(i);
        }
        const idx = scope.varnames.items.len;
        try scope.varnames.append(self.a, name);
        return @intCast(idx);
    }

    fn addCellIdx(self: *Compiler, scope: *Scope, name: []const u8) !u16 {
        for (scope.cellvars.items, 0..) |n, i| {
            if (std.mem.eql(u8, n, name)) return @intCast(i);
        }
        const idx = scope.cellvars.items.len;
        try scope.cellvars.append(self.a, name);
        return @intCast(idx);
    }

    fn constEq(a: Obj, b: Obj) bool {
        if (a.v == .none and b.v == .none) return true;
        if (a.v == .bool_ and b.v == .bool_) return a.v.bool_ == b.v.bool_;
        switch (a.v) {
            .int => |i| return b.v == .int and b.v.int == i,
            .float => |f| return b.v == .float and b.v.float == f,
            .str => |s| return b.v == .str and std.mem.eql(u8, s.bytes, b.v.str.bytes),
            .bytes => |s| return b.v == .bytes and std.mem.eql(u8, s.data, b.v.bytes.data),
            .none => return b.v == .none,
            .ellipsis => return b.v == .ellipsis,
            else => return a == b,
        }
    }

    // ----------------------------------------------------------
    // Работа с символами — привязки
    // ----------------------------------------------------------

    fn bind(self: *Compiler, scope: *Scope, name: []const u8) !void {
        _ = self;
        const gop = try scope.syms.getOrPut(name);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.flags.assigned = true;
    }

    fn use(self: *Compiler, scope: *Scope, name: []const u8) !void {
        _ = self;
        const gop = try scope.syms.getOrPut(name);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.flags.used = true;
    }

    fn bindParam(self: *Compiler, scope: *Scope, name: []const u8) !void {
        _ = self;
        const gop = try scope.syms.getOrPut(name);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.flags.param = true;
        gop.value_ptr.flags.assigned = true;
    }

    fn markGlobal(self: *Compiler, scope: *Scope, name: []const u8) !void {
        _ = self;
        const gop = try scope.syms.getOrPut(name);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.flags.global = true;
    }

    fn markNonlocal(self: *Compiler, scope: *Scope, name: []const u8) !void {
        _ = self;
        const gop = try scope.syms.getOrPut(name);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.flags.nonlocal = true;
    }

    // ----------------------------------------------------------
    // Символьный сбор (по всему дереву областей)
    // ----------------------------------------------------------

    fn collectScope(self: *Compiler, scope: *Scope, stmts: []ast.Stmt) CompileError!void {
        for (stmts) |s| try self.collectStmt(scope, s);
    }

    fn collectTarget(self: *Compiler, scope: *Scope, e: *ast.Expr) CompileError!void {
        switch (e.node) {
            .Name => |n| try self.bind(scope, n.id),
            .Tuple, .List => |items| {
                for (items) |it| {
                    if (it.node == .Starred) {
                        try self.collectTarget(scope, it.node.Starred);
                    } else {
                        try self.collectTarget(scope, it);
                    }
                }
            },
            .Starred => |inner| try self.collectTarget(scope, inner),
            .Subscript => |sub| try self.collectExpr(scope, sub.value),
            .Attribute => |attr| try self.collectExpr(scope, attr.value),
            else => {},
        }
    }

    fn collectStmt(self: *Compiler, scope: *Scope, s: ast.Stmt) CompileError!void {
        switch (s.node) {
            .Expr => |e| try self.collectExpr(scope, e),
            .Assign => |as| {
                try self.collectExpr(scope, as.value);
                for (as.targets) |t| try self.collectTarget(scope, t);
            },
            .AugAssign => |as| {
                try self.collectExpr(scope, as.value);
                try self.collectTarget(scope, as.target);
            },
            .AnnAssign => |as| {
                try self.collectExpr(scope, as.ann);
                if (as.value) |v| try self.collectExpr(scope, v);
                try self.collectTarget(scope, as.target);
            },
            .If => |x| {
                try self.collectExpr(scope, x.cond);
                try self.collectScope(scope, x.body);
                try self.collectScope(scope, x.or_else);
            },
            .While => |x| {
                try self.collectExpr(scope, x.cond);
                try self.collectScope(scope, x.body);
                try self.collectScope(scope, x.or_else);
            },
            .For => |x| {
                try self.collectExpr(scope, x.iter);
                try self.collectTarget(scope, x.target);
                try self.collectScope(scope, x.body);
                try self.collectScope(scope, x.or_else);
            },
            .With => |x| {
                for (x.items) |item| {
                    try self.collectExpr(scope, item.context);
                    if (item.optional) |o| try self.collectTarget(scope, o);
                }
                try self.collectScope(scope, x.body);
            },
            .Raise => |x| {
                if (x.exc) |e| try self.collectExpr(scope, e);
                if (x.cause) |e| try self.collectExpr(scope, e);
            },
            .Try => |x| {
                try self.collectScope(scope, x.body);
                for (x.handlers) |h| {
                    if (h.typ) |t| try self.collectExpr(scope, t);
                    if (h.name) |n| try self.bind(scope, n);
                    try self.collectScope(scope, h.body);
                }
                try self.collectScope(scope, x.or_else);
                try self.collectScope(scope, x.finalbody);
            },
            .Assert => |x| {
                try self.collectExpr(scope, x.cond);
                if (x.msg) |m| try self.collectExpr(scope, m);
            },
            .Import => |aliases| {
                for (aliases) |al| {
                    const name = al.asname orelse firstPart(al.name);
                    try self.bind(scope, try self.rt.gpa.dupe(u8, name));
                }
            },
            .ImportFrom => |x| {
                for (x.names) |al| {
                    if (std.mem.eql(u8, al.name, "*")) continue;
                    try self.bind(scope, al.asname orelse al.name);
                }
            },
            .Global => |names| {
                for (names) |n| try self.markGlobal(scope, n);
            },
            .Nonlocal => |names| {
                for (names) |n| try self.markNonlocal(scope, n);
            },
            .FunctionDef => |x| {
                try self.bind(scope, x.name);
                for (x.decorator_list) |d| try self.collectExpr(scope, d);
                if (x.returns) |r| try self.collectExpr(scope, r);
                try self.collectArgsAnnotations(scope, x.args);
                for (x.args.defaults) |d| try self.collectExpr(scope, d);
                for (x.args.kw_defaults) |d| {
                    if (d) |dd| try self.collectExpr(scope, dd);
                }
                // вложенный scope создаётся в эмите; здесь только обход символов тела
                const child = try self.makeChildScope(scope, x.name, .function_, x.args, x.body, x.is_async);
                try scope.children.append(self.a, child);
            },
            .ClassDef => |x| {
                try self.bind(scope, x.name);
                for (x.decorator_list) |d| try self.collectExpr(scope, d);
                for (x.bases) |b| try self.collectExpr(scope, b);
                for (x.keywords) |kw| try self.collectExpr(scope, kw.value);
                const child = try Scope.new(self.a, .class_, x.name, if (scope.kind == .module_) x.name else try std.fmt.allocPrint(self.a, "{s}.{s}", .{ scope.qualname, x.name }), scope);
                child.needs_name_scope = true;
                try scope.children.append(self.a, child);
                try self.collectScope(child, x.body);
            },
            .Return => |v| {
                if (v) |vv| try self.collectExpr(scope, vv);
            },
            .Delete => |targets| {
                for (targets) |t| try self.collectTarget(scope, t);
            },
            .Pass, .Break, .Continue => {},
        }
    }

    fn collectArgsAnnotations(self: *Compiler, scope: *Scope, args: ast.Arguments) CompileError!void {
        for (args.posonly) |p| if (p.ann) |an| try self.collectExpr(scope, an);
        for (args.args) |p| if (p.ann) |an| try self.collectExpr(scope, an);
        for (args.kwonly) |p| if (p.ann) |an| try self.collectExpr(scope, an);
        if (args.vararg) |v| if (v.ann) |an| try self.collectExpr(scope, an);
        if (args.kwarg) |v| if (v.ann) |an| try self.collectExpr(scope, an);
    }

    fn makeChildScope(self: *Compiler, parent: *Scope, name: []const u8, kind: ScopeKind, args: ast.Arguments, body: []ast.Stmt, is_async: bool) CompileError!*Scope {
        const qn = if (parent.kind == .module_)
            try self.a.dupe(u8, name)
        else if (parent.kind == .class_)
            try std.fmt.allocPrint(self.a, "{s}.{s}", .{ parent.qualname, name })
        else
            try std.fmt.allocPrint(self.a, "{s}.<locals>.{s}", .{ parent.qualname, name });
        const child = try Scope.new(self.a, kind, try self.a.dupe(u8, name), qn, parent);
        child.is_coroutine = is_async;

        // параметры: порядок varnames: posonly+args, kwonly, vararg, kwarg
        const n_pos = args.posonly.len + args.args.len;
        child.argcount = @intCast(n_pos);
        child.posonly = @intCast(args.posonly.len);
        child.kwonly = @intCast(args.kwonly.len);
        child.has_varargs = args.vararg != null;
        child.has_varkw = args.kwarg != null;
        for (args.posonly) |p| {
            try child.varnames.append(self.a, p.name);
            try self.bindParam(child, p.name);
        }
        for (args.args) |p| {
            try child.varnames.append(self.a, p.name);
            try self.bindParam(child, p.name);
        }
        for (args.kwonly) |p| {
            try child.varnames.append(self.a, p.name);
            try self.bindParam(child, p.name);
        }
        if (args.vararg) |v| {
            try child.varnames.append(self.a, v.name);
            try self.bindParam(child, v.name);
        }
        if (args.kwarg) |v| {
            try child.varnames.append(self.a, v.name);
            try self.bindParam(child, v.name);
        }
        try self.collectScope(child, body);
        return child;
    }

    fn collectExpr(self: *Compiler, scope: *Scope, e: *ast.Expr) CompileError!void {
        switch (e.node) {
            .BoolOp => |x| {
                for (x.values) |v| try self.collectExpr(scope, v);
            },
            .NamedExpr => |x| {
                try self.collectExpr(scope, x.value);
                // walrus в comprehension биндит в охватывающей function-scope
                var s = scope;
                if (s.kind == .comprehension_) {
                    while (s.parent) |p| {
                        if (p.isFunctionLike()) break;
                        s = p;
                    }
                    if (s.kind == .comprehension_ or s.kind == .module_ or s.kind == .class_) {
                        // CPython биндит в ближайший function/module
                    }
                }
                try self.bind(s, x.target.node.Name.id);
            },
            .BinOp => |x| {
                try self.collectExpr(scope, x.left);
                try self.collectExpr(scope, x.right);
            },
            .UnaryOp => |x| try self.collectExpr(scope, x.operand),
            .Lambda => |x| {
                _ = try self.makeChildScope(scope, "<lambda>", .lambda_, x.args, &.{}, false);
                // тело лямбды — выражение; collect:
                const child = scope.children.items[scope.children.items.len - 1];
                try self.collectExpr(child, x.body);
                for (x.args.defaults) |d| try self.collectExpr(scope, d);
                for (x.args.kw_defaults) |d| {
                    if (d) |dd| try self.collectExpr(scope, dd);
                }
            },
            .IfExp => |x| {
                try self.collectExpr(scope, x.cond);
                try self.collectExpr(scope, x.body);
                try self.collectExpr(scope, x.or_else);
            },
            .Dict => |x| {
                for (x.keys) |k| {
                    if (k) |kk| try self.collectExpr(scope, kk);
                }
                for (x.values) |v| try self.collectExpr(scope, v);
            },
            .Set => |items| {
                for (items) |i| {
                    try self.collectExprOrStarred(scope, i);
                }
            },
            .ListComp => |x| {
                try self.collectComprehension(scope, x.elt, null, null, x.gens);
            },
            .SetComp => |x| {
                try self.collectComprehension(scope, x.elt, null, null, x.gens);
            },
            .GeneratorExp => |x| {
                try self.collectComprehension(scope, x.elt, null, null, x.gens);
            },
            .DictComp => |x| {
                try self.collectComprehension(scope, null, x.key, x.value, x.gens);
            },
            .AwaitExpr => |x| try self.collectExpr(scope, x),
            .Yield => |v| {
                scope.is_generator = true;
                if (v) |vv| try self.collectExpr(scope, vv);
            },
            .YieldFrom => |v| {
                scope.is_generator = true;
                try self.collectExpr(scope, v);
            },
            .Compare => |x| {
                try self.collectExpr(scope, x.left);
                for (x.comparators) |c| try self.collectExpr(scope, c);
            },
            .Call => |x| {
                try self.collectExpr(scope, x.func);
                for (x.args) |a| try self.collectExprOrStarred(scope, a);
                for (x.keywords) |kw| try self.collectExpr(scope, kw.value);
            },
            .FormattedValue => |x| {
                try self.collectExpr(scope, x.value);
                if (x.spec) |sp| try self.collectExpr(scope, sp);
            },
            .JoinedStr => |xs| {
                for (xs) |v| try self.collectExpr(scope, v);
            },
            .Constant => {},
            .Attribute => |x| try self.collectExpr(scope, x.value),
            .Subscript => |x| {
                try self.collectExpr(scope, x.value);
                try self.collectExpr(scope, x.slice);
            },
            .Starred => |x| try self.collectExpr(scope, x),
            .Name => |n| try self.use(scope, n.id),
            .List => |items| {
                for (items) |i| try self.collectExprOrStarred(scope, i);
            },
            .Tuple => |items| {
                for (items) |i| try self.collectExprOrStarred(scope, i);
            },
            .Slice => |x| {
                if (x.lower) |l| try self.collectExpr(scope, l);
                if (x.upper) |u| try self.collectExpr(scope, u);
                if (x.step) |st| try self.collectExpr(scope, st);
            },
        }
    }

    fn collectExprOrStarred(self: *Compiler, scope: *Scope, e: *ast.Expr) CompileError!void {
        try self.collectExpr(scope, e);
    }

    /// Сбор области comprehension: первый iterable вычисляется в ТЕКУЩЕЙ области,
    /// остальное — в вложенной функциональной.
    fn collectComprehension(self: *Compiler, scope: *Scope, elt: ?*ast.Expr, key: ?*ast.Expr, value: ?*ast.Expr, gens: []ast.Comprehension) CompileError!void {
        if (gens.len == 0) return;
        // первый iter — во внешней области
        try self.collectExpr(scope, gens[0].iter);
        for (gens[0].ifs) |c| try self.collectExpr(scope, c);
        const child = try Scope.new(self.a, .comprehension_, if (key != null) "<dictcomp>" else if (value == null and elt != null) "<comp>" else "<comp>", "<comp>", scope);
        try scope.children.append(self.a, child);
        // неявный аргумент .0
        try child.varnames.append(self.a, ".0");
        try self.bindParam(child, ".0");
        child.argcount = 1;
        // остальные iter — во вложенной
        try self.collectTarget(child, gens[0].target);
        for (gens[1..]) |g| {
            try self.collectExpr(child, g.iter);
            try self.collectTarget(child, g.target);
            for (g.ifs) |c| try self.collectExpr(child, c);
        }
        if (elt) |e| try self.collectExpr(child, e);
        if (key) |k| try self.collectExpr(child, k);
        if (value) |v| try self.collectExpr(child, v);
    }

    // ----------------------------------------------------------
    // Распределение: free/cell/global после сбора (по дереву)
    // ----------------------------------------------------------

    fn resolveFree(self: *Compiler, scope: *Scope) CompileError!void {
        // сначала рекурсивно по детям (они могут пометить нас cell)
        for (scope.children.items) |ch| {
            try self.resolveFree(ch);
        }
        // для каждого моего символа: решить категорию
        var it = scope.syms.iterator();
        while (it.next()) |kv| {
            const name = kv.key_ptr.*;
            const flags = kv.value_ptr;
            if (flags.flags.global) continue;
            if (flags.flags.nonlocal) {
                // найти в функциональных предках
                if (self.findInAncestors(scope, name)) {
                    flags.flags.free = true;
                    continue;
                }
                return error.SyntaxError; // no binding for nonlocal
            }
            if (flags.flags.cell) {
                // помечен ребёнком; остаётся локалью, но через cell
                continue;
            }
            if (flags.flags.assigned or flags.flags.param) {
                continue; // обычная локаль
            }
            // используется, но не связан здесь
            if (!flags.flags.used) continue;
            if (scope.kind == .module_ or scope.kind == .class_) {
                continue; // через NAME/GLOBAL динамически
            }
            if (self.findInAncestors(scope, name)) {
                flags.flags.free = true;
            }
            // иначе — глобаль/builtin (LOAD_GLOBAL)
        }
        // наполнить cellvars/freevars списки (порядок важен: cellvars, затем freevars)
        var it2 = scope.syms.iterator();
        while (it2.next()) |kv| {
            const flags = kv.value_ptr;
            if (flags.flags.cell and !contains(scope.cellvars.items, kv.key_ptr.*)) {
                try scope.cellvars.append(self.a, kv.key_ptr.*);
            }
        }
        var it3 = scope.syms.iterator();
        while (it3.next()) |kv| {
            const flags = kv.value_ptr;
            if (flags.flags.free and !contains(scope.freevars.items, kv.key_ptr.*)) {
                try scope.freevars.append(self.a, kv.key_ptr.*);
            }
        }
    }

    /// Имя определено в одном из функциональных предков (не в module/class)?
    fn findInAncestors(self: *Compiler, scope: *Scope, name: []const u8) bool {
        var p = scope.parent;
        while (p) |par| {
            if (par.kind == .module_) break;
            if (par.isFunctionLike()) {
                if (par.syms.get(name)) |sym| {
                    if ((sym.flags.assigned or sym.flags.param) and !sym.flags.global and !sym.flags.nonlocal) {
                        // пометить родителя cell
                        const sp = par.syms.getPtr(name).?;
                        sp.flags.cell = true;
                        _ = self;
                        return true;
                    }
                }
            }
            p = par.parent;
        }
        _ = self;
        return false;
    }

    fn contains(items: []const []const u8, s: []const u8) bool {
        for (items) |i| if (std.mem.eql(u8, i, s)) return true;
        return false;
    }

    // ----------------------------------------------------------
    // Категории доступа к переменным при эмите
    // ----------------------------------------------------------

    const NameCat = enum { name_scope, fast, deref, global_ };

    fn catOf(self: *Compiler, scope: *Scope, name: []const u8) NameCat {
        _ = self;
        if (scope.needs_name_scope) return .name_scope;
        if (scope.syms.get(name)) |sym| {
            if (sym.flags.global) return .global_;
            if (sym.flags.free) return .deref;
            if (sym.flags.cell) return .deref;
            if (sym.flags.assigned or sym.flags.param) return .fast;
            // не присвоена: fallback global
            return .global_;
        }
        return .global_;
    }

    fn emitLoadName(self: *Compiler, scope: *Scope, name: []const u8, line: usize) !void {
        switch (self.catOf(scope, name)) {
            .name_scope => self.emitOp(scope, .LOAD_NAME, try self.addNameIdx(scope, name), line),
            .fast => self.emitOp(scope, .LOAD_FAST, try self.addVarnameIdx(scope, name), line),
            .deref => self.emitOp(scope, .LOAD_DEREF, try self.derefIdx(scope, name), line),
            .global_ => self.emitOp(scope, .LOAD_GLOBAL, try self.addNameIdx(scope, name), line),
        }
    }

    fn emitStoreName(self: *Compiler, scope: *Scope, name: []const u8, line: usize) !void {
        switch (self.catOf(scope, name)) {
            .name_scope => self.emitOp(scope, .STORE_NAME, try self.addNameIdx(scope, name), line),
            .fast => self.emitOp(scope, .STORE_FAST, try self.addVarnameIdx(scope, name), line),
            .deref => self.emitOp(scope, .STORE_DEREF, try self.derefIdx(scope, name), line),
            .global_ => self.emitOp(scope, .STORE_GLOBAL, try self.addNameIdx(scope, name), line),
        }
    }

    fn emitDelName(self: *Compiler, scope: *Scope, name: []const u8, line: usize) !void {
        switch (self.catOf(scope, name)) {
            .name_scope => self.emitOp(scope, .DELETE_NAME, try self.addNameIdx(scope, name), line),
            .fast => self.emitOp(scope, .DELETE_FAST, try self.addVarnameIdx(scope, name), line),
            .deref => self.emitOp(scope, .DELETE_DEREF, try self.derefIdx(scope, name), line),
            .global_ => self.emitOp(scope, .DELETE_GLOBAL, try self.addNameIdx(scope, name), line),
        }
    }

    /// Индекс в frame.cells (cellvars ++ freevars)
    fn derefIdx(self: *Compiler, scope: *Scope, name: []const u8) !u16 {
        _ = self;
        for (scope.cellvars.items, 0..) |n, i| {
            if (std.mem.eql(u8, n, name)) return @intCast(i);
        }
        for (scope.freevars.items, 0..) |n, i| {
            if (std.mem.eql(u8, n, name)) return @intCast(scope.cellvars.items.len + i);
        }
        // не должно произойти
        return 0;
    }

    // ----------------------------------------------------------
    // Эмит: операторы
    // ----------------------------------------------------------

    fn emitStmts(self: *Compiler, scope: *Scope, stmts: []const ast.Stmt) CompileError!void {
        for (stmts) |s| try self.emitStmt(scope, s);
    }

    fn emitStmt(self: *Compiler, scope: *Scope, s: ast.Stmt) CompileError!void {
        switch (s.node) {
            .Expr => |e| {
                try self.emitExpr(scope, e);
                // docstring: оставляем значение на стеке? просто POP
                self.emit0(scope, .POP_TOP, s.lineno);
            },
            .Assign => |as| {
                try self.emitExpr(scope, as.value);
                for (as.targets, 0..) |t, ti| {
                    if (ti + 1 < as.targets.len) self.emit0(scope, .DUP_TOP, s.lineno);
                    try self.emitStore(scope, t, s.lineno);
                }
            },
            .AugAssign => |as| {
                try self.emitAugAssign(scope, as.target, as.op, as.value, s.lineno);
            },
            .AnnAssign => |as| {
                if (as.value) |v| {
                    try self.emitExpr(scope, v);
                    try self.emitStore(scope, as.target, s.lineno);
                }
                // аннотацию сохраняем в __annotations__ на module/class уровнях
                if (scope.needs_name_scope and as.target.node == .Name) {
                    try self.emitExpr(scope, as.ann);
                    self.emitOp(scope, .STORE_ANNOTATION, try self.addNameIdx(scope, as.target.node.Name.id), s.lineno);
                } else if (scope.isFunctionLike() and as.target.node == .Name) {
                    // в функциях вычисляем аннотацию для побочных эффектов? CPython не вычисляет (кроме value) — пропуск
                }
            },
            .If => |x| {
                try self.emitExpr(scope, x.cond);
                const else_jump = self.pos(scope);
                self.emitOp(scope, .POP_JUMP_IF_FALSE, 0xffff, s.lineno);
                try self.emitStmts(scope, x.body);
                const end_jump = self.pos(scope);
                self.emitOp(scope, .JUMP_ABSOLUTE, 0xffff, s.lineno);
                const else_target = self.pos(scope);
                self.patchAbs(scope, else_jump, else_target);
                try self.emitStmts(scope, x.or_else);
                const end_target = self.pos(scope);
                self.patchAbs(scope, end_jump, end_target);
            },
            .While => |x| {
                const loop_start = self.pos(scope);
                try self.blocks_push(scope, .loop, loop_start, null);
                try self.emitExpr(scope, x.cond);
                const exit_jump = self.pos(scope);
                self.emitOp(scope, .POP_JUMP_IF_FALSE, 0xffff, s.lineno);
                try self.emitStmts(scope, x.body);
                self.emitBackJump(scope, loop_start, s.lineno);
                const else_target = self.pos(scope);
                self.patchAbs(scope, exit_jump, else_target);
                try self.emitStmts(scope, x.or_else);
                const end_target = self.pos(scope);
                try self.blocks_pop(scope, end_target);
            },
            .For => |x| {
                try self.emitExpr(scope, x.iter);
                self.emit0(scope, .GET_ITER, s.lineno);
                const loop_start = self.pos(scope);
                self.emitOp(scope, .FOR_ITER, 0xffff, s.lineno);
                try self.blocks_push(scope, .loop, loop_start, null);
                try self.emitStore(scope, x.target, s.lineno);
                try self.emitStmts(scope, x.body);
                self.emitBackJump(scope, loop_start, s.lineno);
                const else_target = self.pos(scope);
                self.patchRel(scope, loop_start, else_target);
                try self.emitStmts(scope, x.or_else);
                const end_target = self.pos(scope);
                try self.blocks_pop(scope, end_target);
            },
            .With => |x| {
                try self.emitWithItems(scope, x.items, x.body, 0, s.lineno);
            },
            .Raise => |x| {
                if (x.exc == null) {
                    self.emitOp(scope, .RAISE, 0, s.lineno);
                } else {
                    try self.emitExpr(scope, x.exc.?);
                    if (x.cause) |c| {
                        try self.emitExpr(scope, c);
                        self.emitOp(scope, .RAISE, 2, s.lineno);
                    } else {
                        self.emitOp(scope, .RAISE, 1, s.lineno);
                    }
                }
            },
            .Try => |x| {
                if (x.finalbody.len > 0 and x.handlers.len == 0) {
                    // чистый try/finally
                    self.emitOp(scope, .SETUP_FINALLY, 0xffff, s.lineno);
                    const setup_pos = self.pos(scope) - 3;
                    try self.blocks_push_finally(scope, x.finalbody);
                    try self.emitStmts(scope, x.body);
                    self.emit0(scope, .POP_BLOCK, s.lineno);
                    self.emit0(scope, .LOAD_NONE, s.lineno);
                    const handler = self.pos(scope);
                    self.patchRel(scope, setup_pos, handler);
                    try self.blocks_pop_finally_for_fallthrough(scope, x.finalbody);
                    self.emit0(scope, .END_FINALLY, s.lineno);
                } else {
                    // try/except (+else) [+finally]
                    var finally_setup: ?usize = null;
                    if (x.finalbody.len > 0) {
                        self.emitOp(scope, .SETUP_FINALLY, 0xffff, s.lineno);
                        finally_setup = self.pos(scope) - 3;
                        try self.blocks_push_finally(scope, x.finalbody);
                    }
                    self.emitOp(scope, .SETUP_EXCEPT, 0xffff, s.lineno);
                    const except_setup = self.pos(scope) - 3;
                    try self.blocks_push(scope, .try_except, null, null);
                    try self.emitStmts(scope, x.body);
                    self.emit0(scope, .POP_BLOCK, s.lineno);
                    _ = try self.blocks_pop_only(scope);
                    try self.emitStmts(scope, x.or_else);
                    const end_jump = self.pos(scope);
                    self.emitOp(scope, .JUMP_FORWARD, 0xffff, s.lineno);
                    const handler = self.pos(scope);
                    self.patchRel(scope, except_setup, handler);
                    // обработчики
                    var raise_again_jumps: std.ArrayList(usize) = .empty;
                    for (x.handlers, 0..) |h, hi| {
                        _ = hi;
                        const hline = h.lineno;
                        if (h.typ == null) {
                            // bare except: TOS = exc
                            self.emit0(scope, .POP_TOP, hline);
                            try self.emitStmts(scope, h.body);
                            self.emit0(scope, .POP_EXCEPT, hline);
                            const j = self.pos(scope);
                            self.emitOp(scope, .JUMP_FORWARD, 0xffff, hline);
                            try raise_again_jumps.append(self.a, j);
                        } else {
                            self.emit0(scope, .DUP_TOP, hline);
                            try self.emitExpr(scope, h.typ.?);
                            const next_jump = self.pos(scope);
                            self.emitOp(scope, .JUMP_IF_NOT_EXC_MATCH, 0xffff, hline);
                            // matched: стек [exc]
                            if (h.name) |n| {
                                try self.emitStoreName(scope, n, hline);
                            } else {
                                self.emit0(scope, .POP_TOP, hline);
                            }
                            try self.emitStmts(scope, h.body);
                            if (h.name) |n| {
                                try self.emitDelName(scope, n, hline);
                            }
                            self.emit0(scope, .POP_EXCEPT, hline);
                            const j = self.pos(scope);
                            self.emitOp(scope, .JUMP_FORWARD, 0xffff, hline);
                            try raise_again_jumps.append(self.a, j);
                            const next_target = self.pos(scope);
                            self.patchAbs(scope, next_jump, next_target);
                        }
                    }
                    self.emitOp(scope, .RAISE_AGAIN, 0, s.lineno);
                    const end_target = self.pos(scope);
                    for (raise_again_jumps.items) |j| self.patchRel(scope, j, end_target);
                    self.patchRel(scope, end_jump, end_target);
                    if (x.finalbody.len > 0) {
                        // fallthrough к finally: POP_BLOCK + None + suite + END_FINALLY
                        self.emit0(scope, .POP_BLOCK, s.lineno);
                        self.emit0(scope, .LOAD_NONE, s.lineno);
                        const fhandler = self.pos(scope);
                        self.patchRel(scope, finally_setup.?, fhandler);
                        try self.blocks_pop_finally_for_fallthrough(scope, x.finalbody);
                        self.emit0(scope, .END_FINALLY, s.lineno);
                    }
                }
            },
            .Assert => |x| {
                try self.emitExpr(scope, x.cond);
                const ok_jump = self.pos(scope);
                self.emitOp(scope, .POP_JUMP_IF_TRUE, 0xffff, s.lineno);
                self.emit0(scope, .LOAD_ASSERTION_ERROR, s.lineno);
                if (x.msg) |m| {
                    try self.emitExpr(scope, m);
                    self.emitOp(scope, .CALL, 1, s.lineno);
                }
                self.emitOp(scope, .RAISE, 1, s.lineno);
                const ok_target = self.pos(scope);
                self.patchAbs(scope, ok_jump, ok_target);
            },
            .Import => |aliases| {
                for (aliases) |al| {
                    const lvl = try self.addConst(scope, try self.rt.newInt(0));
                    self.emitOp(scope, .LOAD_CONST, lvl, s.lineno);
                    self.emitOp(scope, .LOAD_NONE, 0, s.lineno);
                    self.emitOp(scope, .IMPORT_NAME, try self.addNameIdx(scope, al.name), s.lineno);
                    if (al.asname) |asn| {
                        // import a.b as x → нужен a.b сам (не верхнеуровневый a)
                        const parts = try splitName(self.a, al.name);
                        for (parts[1..]) |p| {
                            self.emitOp(scope, .IMPORT_FROM, try self.addNameIdx(scope, p), s.lineno);
                            self.emit0(scope, .ROT_TWO, s.lineno);
                            self.emit0(scope, .POP_TOP, s.lineno);
                        }
                        try self.emitStoreName(scope, asn, s.lineno);
                    } else {
                        // import a.b → bind top-level a
                        const top = firstPart(al.name);
                        try self.emitStoreName(scope, try self.a.dupe(u8, top), s.lineno);
                    }
                }
            },
            .ImportFrom => |x| {
                const lvl = try self.addConst(scope, try self.rt.newInt(@intCast(x.level)));
                self.emitOp(scope, .LOAD_CONST, lvl, x.lineno);
                // fromlist: tuple имён
                var names_objs: std.ArrayList(Obj) = .empty;
                for (x.names) |al| {
                    try names_objs.append(self.a, try self.rt.newStr(al.name));
                }
                const fl = try self.addConst(scope, try self.rt.newTuple(names_objs.items));
                self.emitOp(scope, .LOAD_CONST, fl, x.lineno);
                const modname = x.module orelse "";
                self.emitOp(scope, .IMPORT_NAME, try self.addNameIdx(scope, modname), x.lineno);
                if (x.names.len == 1 and std.mem.eql(u8, x.names[0].name, "*")) {
                    self.emit0(scope, .IMPORT_STAR, x.lineno);
                } else {
                    for (x.names) |al| {
                        self.emitOp(scope, .IMPORT_FROM, try self.addNameIdx(scope, al.name), x.lineno);
                        try self.emitStoreName(scope, al.asname orelse al.name, x.lineno);
                    }
                    self.emit0(scope, .POP_TOP, x.lineno); // pop module
                }
            },
            .Global, .Nonlocal => {},
            .FunctionDef => |x| {
                // декораторы сначала
                for (x.decorator_list) |d| {
                    try self.emitExpr(scope, d);
                }
                // ребёнок: первый не-emitted FunctionDef-scope с этим именем
                const child = takeChild(scope, .function_, x.name) orelse return error.SyntaxError;
                child.body_stmts = x.body;
                try self.emitFunctionFromScope(scope, child, x.args, x.decorator_list.len, s.lineno);
                try self.emitStoreName(scope, x.name, s.lineno);
            },
            .ClassDef => |x| {
                for (x.decorator_list) |d| {
                    try self.emitExpr(scope, d);
                }
                // class-scope
                const child = takeChild(scope, .class_, x.name) orelse return error.SyntaxError;
                // код тела класса
                const body_code = try self.compileClassBody(child, x);
                const code_obj = try self.rt.mkObj(self.rt.code_t, .{ .code = body_code });
                self.emit0(scope, .LOAD_BUILD_CLASS, s.lineno);
                // функция из кода (без аргументов — это маркер; __build_class__ будет exec'ить)
                const cidx = try self.addConst(scope, code_obj);
                self.emitOp(scope, .LOAD_CONST, cidx, s.lineno);
                var mk_flags: u16 = 0;
                if (child.freevars.items.len > 0) mk_flags |= 0x04;
                if (mk_flags != 0) {
                    // closure tuple из cellvars родителя
                    for (child.freevars.items) |fv| {
                        const idx = try self.parentCellIdx(scope, fv);
                        self.emitOp(scope, .LOAD_CLOSURE, idx, s.lineno);
                    }
                    self.emitOp(scope, .BUILD_TUPLE, @intCast(child.freevars.items.len), s.lineno);
                }
                self.emitOp(scope, .MAKE_FUNCTION, mk_flags, s.lineno);
                const name_const = try self.addConst(scope, try self.rt.newStr(x.name));
                self.emitOp(scope, .LOAD_CONST, name_const, s.lineno);
                for (x.bases) |b| try self.emitExpr(scope, b);
                for (x.keywords) |kw| {
                    try self.emitExpr(scope, kw.value);
                }
                if (x.keywords.len > 0) {
                    // KW_NAMES tuple
                    var names_list: std.ArrayList(Obj) = .empty;
                    for (x.keywords) |kw| {
                        try names_list.append(self.a, try self.rt.newStr(kw.name.?));
                    }
                    const tup = try self.addConst(scope, try self.rt.newTuple(names_list.items));
                    self.emitOp(scope, .KW_NAMES, tup, s.lineno);
                }
                const nargs: u16 = @intCast(2 + x.bases.len);
                const nkw: u16 = @intCast(x.keywords.len);
                self.emitOp(scope, .CALL, nargs | (nkw << 8), s.lineno);
                // декораторы
                for (x.decorator_list) |_| {
                    self.emit0(scope, .ROT_TWO, s.lineno);
                    self.emitOp(scope, .CALL, 1, s.lineno);
                }
                try self.emitStoreName(scope, x.name, s.lineno);
            },
            .Return => |v| {
                if (scope.kind == .module_) {
                    // return вне функции — SyntaxError; мягко: игнорируем
                }
                // cleanup по блокам
                try self.emitBlockCleanups(scope, null);
                if (v) |vv| {
                    try self.emitExpr(scope, vv);
                } else {
                    self.emit0(scope, .LOAD_NONE, s.lineno);
                }
                self.emit0(scope, .RETURN_VALUE, s.lineno);
            },
            .Delete => |targets| {
                for (targets) |t| try self.emitDelete(scope, t, s.lineno);
            },
            .Pass => self.emit0(scope, .NOP, s.lineno),
            .Break => {
                try self.emitBlockCleanups(scope, .loop);
                const jpos = self.pos(scope);
                self.emitOp(scope, .JUMP_ABSOLUTE, 0xffff, s.lineno);
                try self.recordBreakJump(scope, jpos);
            },
            .Continue => {
                try self.emitBlockCleanups(scope, .loop);
                const target = try self.blocks_continue_target(scope);
                self.emitOp(scope, .JUMP_ABSOLUTE, @intCast(target), s.lineno);
            },
        }
    }

    fn emitBackJump(self: *Compiler, scope: *Scope, target: usize, line: usize) void {
        const at = self.pos(scope);
        self.emitOp(scope, .JUMP_BACKWARD, 0, line);
        const rel = at + 3 - target;
        self.patchRelBack(scope, at, rel);
    }

    fn patchRelBack(self: *Compiler, scope: *Scope, at: usize, rel: usize) void {
        _ = self;
        scope.code.items[at + 1] = @truncate(rel & 0xff);
        scope.code.items[at + 2] = @truncate(rel >> 8);
    }

    // ----------------------------------------------------------
    // Блоки (break/continue/return cleanup)
    // ----------------------------------------------------------

    fn blocks_push(self: *Compiler, scope: *Scope, kind: BlockKind, continue_label: ?usize, break_label: ?usize) CompileError!void {
        try scope.blocks.append(self.a, .{
            .kind = kind,
            .continue_label = continue_label,
            .break_label = break_label,
        });
    }

    fn blocks_push_finally(self: *Compiler, scope: *Scope, body: []const ast.Stmt) CompileError!void {
        try scope.blocks.append(self.a, .{ .kind = .try_finally, .finally_body = body });
    }

    fn blocks_push_with(self: *Compiler, scope: *Scope, exit_slot: u16) CompileError!void {
        try scope.blocks.append(self.a, .{ .kind = .with_, .with_exit_slot = exit_slot });
    }

    /// Снять loop-блок в конце цикла и пропатчить все break-переходы на end_target.
    fn blocks_pop(self: *Compiler, scope: *Scope, end_target: usize) CompileError!void {
        var blk = scope.blocks.pop() orelse return;
        for (blk.break_jumps.items) |jpos| self.patchAbs(scope, jpos, end_target);
        blk.break_jumps.deinit(self.a);
    }

    /// Записать позицию break-перехода во внутренний loop-блок.
    fn recordBreakJump(self: *Compiler, scope: *Scope, jpos: usize) CompileError!void {
        var i: usize = scope.blocks.items.len;
        while (i > 0) {
            i -= 1;
            if (scope.blocks.items[i].kind == .loop) {
                try scope.blocks.items[i].break_jumps.append(self.a, jpos);
                return;
            }
        }
        return error.SyntaxError; // break вне цикла
    }

    fn blocks_pop_only(self: *Compiler, scope: *Scope) CompileError!BlockRec {
        _ = self;
        const blk = scope.blocks.pop() orelse return error.SyntaxError;
        return blk;
    }

    /// Нормальный выход try/finally: попаем блок и эмитим suite (fallthrough).
    fn blocks_pop_finally_for_fallthrough(self: *Compiler, scope: *Scope, body: []const ast.Stmt) CompileError!void {
        _ = try self.blocks_pop_only(scope);
        try self.emitStmts(scope, body);
    }

    /// Генерирует cleanup-код для блоков при break/continue/return.
    /// stop_at_loop — остановиться как только достигли loop-блока (включительно? нет: cleanup до него, не включая сам loop).
    fn emitBlockCleanups(self: *Compiler, scope: *Scope, stop_at: ?BlockKind) CompileError!void {
        var i: usize = scope.blocks.items.len;
        while (i > 0) {
            i -= 1;
            const blk = scope.blocks.items[i];
            if (stop_at != null and blk.kind == .loop) break;
            switch (blk.kind) {
                .try_finally => {
                    self.emit0(scope, .POP_BLOCK, 0);
                    try self.emitStmts(scope, blk.finally_body);
                },
                .with_ => {
                    self.emit0(scope, .POP_BLOCK, 0);
                    if (scope.needs_name_scope) {
                        self.emitOp(scope, .LOAD_NAME, blk.with_exit_slot.?, 0);
                    } else {
                        self.emitOp(scope, .LOAD_FAST, blk.with_exit_slot.?, 0);
                    }
                    self.emit0(scope, .LOAD_NONE, 0);
                    self.emit0(scope, .LOAD_NONE, 0);
                    self.emit0(scope, .LOAD_NONE, 0);
                    self.emitOp(scope, .CALL, 3, 0);
                    self.emit0(scope, .POP_TOP, 0);
                },
                .try_except => {
                    self.emit0(scope, .POP_BLOCK, 0);
                },
                .loop => {},
            }
        }
    }

    fn blocks_continue_target(self: *Compiler, scope: *Scope) CompileError!usize {
        _ = self;
        var i: usize = scope.blocks.items.len;
        while (i > 0) {
            i -= 1;
            const blk = scope.blocks.items[i];
            if (blk.kind == .loop) {
                return blk.continue_label orelse return error.SyntaxError;
            }
        }
        return error.SyntaxError;
    }

    // ----------------------------------------------------------
    // Выражения
    // ----------------------------------------------------------

    fn emitExpr(self: *Compiler, scope: *Scope, e: *ast.Expr) CompileError!void {
        switch (e.node) {
            .Constant => |c| {
                const idx = try self.emitConstant(scope, c, e.lineno);
                switch (idx) {
                    SENTINEL_NONE => self.emit0(scope, .LOAD_NONE, e.lineno),
                    SENTINEL_TRUE => self.emit0(scope, .LOAD_TRUE, e.lineno),
                    SENTINEL_FALSE => self.emit0(scope, .LOAD_FALSE, e.lineno),
                    SENTINEL_ELLIPSIS => self.emit0(scope, .LOAD_ELLIPSIS, e.lineno),
                    else => self.emitOp(scope, .LOAD_CONST, idx, e.lineno),
                }
            },
            .Name => |n| try self.emitLoadName(scope, n.id, e.lineno),
            .Tuple => |items| {
                // все константы? → const-tuple
                if (try self.allConsts(scope, items)) |tuple_obj| {
                    const idx = try self.addConst(scope, tuple_obj);
                    self.emitOp(scope, .LOAD_CONST, idx, e.lineno);
                } else {
                    for (items) |it| try self.emitExprOrStar(scope, it, e.lineno);
                    self.emitOp(scope, .BUILD_TUPLE, @intCast(items.len), e.lineno);
                }
            },
            .List => |items| {
                var has_starred = false;
                for (items) |it| {
                    if (it.node == .Starred) has_starred = true;
                }
                if (!has_starred) {
                    for (items) |it| try self.emitExpr(scope, it);
                    self.emitOp(scope, .BUILD_LIST, @intCast(items.len), e.lineno);
                } else {
                    self.emitOp(scope, .BUILD_LIST, 0, e.lineno);
                    for (items) |it| {
                        if (it.node == .Starred) {
                            try self.emitExpr(scope, it.node.Starred);
                            self.emit0(scope, .LIST_EXTEND, e.lineno);
                        } else {
                            try self.emitExpr(scope, it);
                            self.emitOp(scope, .LIST_APPEND, 1, e.lineno);
                        }
                    }
                }
            },
            .Set => |items| {
                var has_starred = false;
                for (items) |it| {
                    if (it.node == .Starred) has_starred = true;
                }
                if (!has_starred) {
                    for (items) |it| try self.emitExpr(scope, it);
                    self.emitOp(scope, .BUILD_SET, @intCast(items.len), e.lineno);
                } else {
                    self.emitOp(scope, .BUILD_SET, 0, e.lineno);
                    for (items) |it| {
                        if (it.node == .Starred) {
                            try self.emitExpr(scope, it.node.Starred);
                            self.emit0(scope, .SET_UPDATE, e.lineno);
                        } else {
                            try self.emitExpr(scope, it);
                            self.emitOp(scope, .SET_ADD, 1, e.lineno);
                        }
                    }
                }
            },
            .Dict => |x| {
                if (x.keys.len == 0) {
                    self.emitOp(scope, .BUILD_MAP, 0, e.lineno);
                } else {
                    var has_unpack = false;
                    for (x.keys) |k| {
                        if (k == null) has_unpack = true;
                    }
                    if (!has_unpack) {
                        // все ключи константны? → const-key map
                        var allc = true;
                        for (x.keys) |k| {
                            if (!isConstExpr(k.?)) allc = false;
                        }
                        if (allc) {
                            var names_list: std.ArrayList(Obj) = .empty;
                            for (x.keys) |k| {
                                try names_list.append(self.a, try self.constValue(scope, k.?));
                            }
                            const tup_const = try self.addConst(scope, try self.rt.newTuple(names_list.items));
                            for (x.values) |v| try self.emitExpr(scope, v);
                            self.emitOp(scope, .BUILD_CONST_KEY_MAP, tup_const, e.lineno);
                        } else {
                            self.emitOp(scope, .BUILD_MAP, 0, e.lineno);
                            for (x.keys, x.values) |k, v| {
                                try self.emitExpr(scope, k.?);
                                try self.emitExpr(scope, v);
                                self.emitOp(scope, .MAP_ADD, 2, e.lineno);
                            }
                        }
                    } else {
                        self.emitOp(scope, .BUILD_MAP, 0, e.lineno);
                        for (x.keys, x.values) |k, v| {
                            if (k == null) {
                                try self.emitExpr(scope, v);
                                self.emit0(scope, .DICT_UPDATE, e.lineno);
                            } else {
                                try self.emitExpr(scope, k.?);
                                try self.emitExpr(scope, v);
                                self.emitOp(scope, .MAP_ADD, 2, e.lineno);
                            }
                        }
                    }
                }
            },
            .BoolOp => |x| {
                const is_or = x.op == .Or;
                var end_jumps: std.ArrayList(usize) = .empty;
                for (x.values, 0..) |v, i| {
                    if (i + 1 < x.values.len) {
                        try self.emitExpr(scope, v);
                        const j = self.pos(scope);
                        if (is_or) {
                            self.emitOp(scope, .JUMP_IF_TRUE_OR_POP, 0xffff, e.lineno);
                        } else {
                            self.emitOp(scope, .JUMP_IF_FALSE_OR_POP, 0xffff, e.lineno);
                        }
                        try end_jumps.append(self.a, j);
                    }
                }
                try self.emitExpr(scope, x.values[x.values.len - 1]);
                const end_target = self.pos(scope);
                for (end_jumps.items) |j| self.patchAbs(scope, j, end_target);
            },
            .NamedExpr => |x| {
                try self.emitExpr(scope, x.value);
                self.emit0(scope, .DUP_TOP, e.lineno);
                try self.emitStore(scope, x.target, e.lineno);
            },
            .BinOp => |x| {
                try self.emitExpr(scope, x.left);
                try self.emitExpr(scope, x.right);
                self.emitBinOp(scope, x.op, false, e.lineno);
            },
            .UnaryOp => |x| {
                try self.emitExpr(scope, x.operand);
                const uop: opcode_mod.UnaryOp = switch (x.op) {
                    .Invert => .invert,
                    .Not => .not,
                    .UAdd => .pos,
                    .USub => .neg,
                };
                self.emitOp(scope, .UNARY_OP, @intFromEnum(uop), e.lineno);
            },
            .IfExp => |x| {
                try self.emitExpr(scope, x.cond);
                const else_jump = self.pos(scope);
                self.emitOp(scope, .POP_JUMP_IF_FALSE, 0xffff, e.lineno);
                try self.emitExpr(scope, x.body);
                const end_jump = self.pos(scope);
                self.emitOp(scope, .JUMP_ABSOLUTE, 0xffff, e.lineno);
                const else_target = self.pos(scope);
                self.patchAbs(scope, else_jump, else_target);
                try self.emitExpr(scope, x.or_else);
                const end_target = self.pos(scope);
                self.patchAbs(scope, end_jump, end_target);
            },
            .Compare => |x| {
                if (x.ops.len == 1) {
                    try self.emitExpr(scope, x.left);
                    try self.emitExpr(scope, x.comparators[0]);
                    try self.emitCmpOp(scope, x.ops[0], e.lineno);
                } else {
                    // chained: a < b < c
                    try self.emitExpr(scope, x.left);
                    var end_jumps: std.ArrayList(usize) = .empty;
                    for (x.ops, 0..) |op, i| {
                        try self.emitExpr(scope, x.comparators[i]);
                        if (i + 1 < x.ops.len) {
                            self.emit0(scope, .DUP_TOP, e.lineno);
                            self.emit0(scope, .ROT_THREE, e.lineno);
                            try self.emitCmpOp(scope, op, e.lineno);
                            const j = self.pos(scope);
                            self.emitOp(scope, .JUMP_IF_FALSE_OR_POP, 0xffff, e.lineno);
                            try end_jumps.append(self.a, j);
                        } else {
                            try self.emitCmpOp(scope, op, e.lineno);
                        }
                    }
                    const end_target = self.pos(scope);
                    for (end_jumps.items) |j| self.patchAbs(scope, j, end_target);
                }
            },
            .Call => |x| {
                try self.emitCall(scope, x, e.lineno);
            },
            .Attribute => |x| {
                try self.emitExpr(scope, x.value);
                self.emitOp(scope, .LOAD_ATTR, try self.addNameIdx(scope, x.attr), e.lineno);
            },
            .Subscript => |x| {
                try self.emitExpr(scope, x.value);
                try self.emitSubscript(scope, x.slice, e.lineno);
                self.emit0(scope, .LOAD_SUBSCR, e.lineno);
            },
            .Slice => {
                return error.SyntaxError; // голый slice вне subscript — не expression
            },
            .Starred => {
                return error.SyntaxError; // голый starred
            },
            .JoinedStr => |parts| {
                var n: u16 = 0;
                for (parts) |p| {
                    try self.emitExpr(scope, p);
                    n += 1;
                }
                self.emitOp(scope, .BUILD_STRING, n, e.lineno);
            },
            .FormattedValue => |x| {
                try self.emitExpr(scope, x.value);
                var conv: u8 = 0;
                conv = switch (x.conversion) {
                    's' => 1,
                    'r' => 2,
                    'a' => 3,
                    else => 0,
                };
                if (x.spec) |sp| {
                    try self.emitExpr(scope, sp);
                    conv |= opcode_mod.FORMAT_VALUE_WITH_SPEC;
                }
                self.emitOp(scope, .FORMAT_VALUE, conv, e.lineno);
            },
            .Lambda => |x| {
                const child = takeChild(scope, .lambda_, null) orelse return error.SyntaxError;
                child.body_expr = x.body;
                try self.emitLambdaFromScope(scope, child, x.args, e.lineno);
            },
            .AwaitExpr => |inner| {
                // TODO asyncio: пока просто вычисляем операнд
                try self.emitExpr(scope, inner);
            },
            .Yield => |v| {
                if (v) |vv| {
                    try self.emitExpr(scope, vv);
                } else {
                    self.emit0(scope, .LOAD_NONE, e.lineno);
                }
                self.emit0(scope, .YIELD_VALUE, e.lineno);
            },
            .YieldFrom => |v| {
                try self.emitExpr(scope, v);
                self.emit0(scope, .GET_YIELD_FROM_ITER, e.lineno);
                self.emit0(scope, .LOAD_NONE, e.lineno);
                self.emitOp(scope, .YIELD_FROM, 0, e.lineno);
            },
            .ListComp => |x| {
                try self.emitComprehension(scope, x.elt, null, null, x.gens, .list, e.lineno);
            },
            .SetComp => |x| {
                try self.emitComprehension(scope, x.elt, null, null, x.gens, .set, e.lineno);
            },
            .GeneratorExp => |x| {
                try self.emitComprehension(scope, x.elt, null, null, x.gens, .gen, e.lineno);
            },
            .DictComp => |x| {
                try self.emitComprehension(scope, null, x.key, x.value, x.gens, .dict, e.lineno);
            },
        }
    }

    fn emitExprOrStar(self: *Compiler, scope: *Scope, e: *ast.Expr, line: usize) CompileError!void {
        _ = line;
        // Starred в tuple литерале не допустим без скобок-списка… Python разрешает (*a,) — поддержим через BUILD_LIST+LIST_EXTEND? Проще: запрет
        try self.emitExpr(scope, e);
    }

    fn emitSubscript(self: *Compiler, scope: *Scope, slice: *ast.Expr, line: usize) CompileError!void {
        if (slice.node == .Slice) {
            const sl = slice.node.Slice;
            if (sl.lower) |l| {
                try self.emitExpr(scope, l);
            } else {
                self.emit0(scope, .LOAD_NONE, line);
            }
            if (sl.upper) |u| {
                try self.emitExpr(scope, u);
            } else {
                self.emit0(scope, .LOAD_NONE, line);
            }
            if (sl.step) |st| {
                try self.emitExpr(scope, st);
                self.emitOp(scope, .BUILD_SLICE, 3, line);
            } else {
                self.emitOp(scope, .BUILD_SLICE, 2, line);
            }
            return;
        }
        try self.emitExpr(scope, slice);
    }

    fn emitBinOp(self: *Compiler, scope: *Scope, op: ast.BinOp, inplace: bool, line: usize) void {
        const bop: opcode_mod.BinaryOp = switch (op) {
            .Add => if (inplace) .iadd else .add,
            .Sub => if (inplace) .isub else .sub,
            .Mult => if (inplace) .imul else .mul,
            .MatMult => if (inplace) .imatmul else .matmul,
            .Div => if (inplace) .itruediv else .truediv,
            .Mod => if (inplace) .imod else .mod,
            .Pow => if (inplace) .ipow else .pow,
            .LShift => if (inplace) .ilshift else .lshift,
            .RShift => if (inplace) .irshift else .rshift,
            .BitOr => if (inplace) .ibit_or else .bit_or,
            .BitXor => if (inplace) .ibit_xor else .bit_xor,
            .BitAnd => if (inplace) .ibit_and else .bit_and,
            .FloorDiv => if (inplace) .ifloordiv else .floordiv,
        };
        self.emitOp(scope, .BINARY_OP, @intFromEnum(bop), line);
    }

    fn emitCmpOp(self: *Compiler, scope: *Scope, op: ast.CmpOp, line: usize) CompileError!void {
        switch (op) {
            .Eq => self.emitOp(scope, .COMPARE_OP, @intFromEnum(opsCompareOp.eq), line),
            .NotEq => self.emitOp(scope, .COMPARE_OP, @intFromEnum(opsCompareOp.ne), line),
            .Lt => self.emitOp(scope, .COMPARE_OP, @intFromEnum(opsCompareOp.lt), line),
            .LtE => self.emitOp(scope, .COMPARE_OP, @intFromEnum(opsCompareOp.le), line),
            .Gt => self.emitOp(scope, .COMPARE_OP, @intFromEnum(opsCompareOp.gt), line),
            .GtE => self.emitOp(scope, .COMPARE_OP, @intFromEnum(opsCompareOp.ge), line),
            .Is => self.emitOp(scope, .IS_OP, 0, line),
            .IsNot => self.emitOp(scope, .IS_OP, 1, line),
            .In => self.emitOp(scope, .CONTAINS_OP, 0, line),
            .NotIn => self.emitOp(scope, .CONTAINS_OP, 1, line),
        }
    }

    const opsCompareOp = enum(u8) { lt, le, eq, ne, gt, ge };

    // ----------------------------------------------------------
    // Вызовы
    // ----------------------------------------------------------

    fn emitCall(self: *Compiler, scope: *Scope, x: anytype, line: usize) CompileError!void {
        // x — .Call payload
        const args = x.args;
        const keywords = x.keywords;
        var has_star = false;
        var has_dstar = false;
        for (args) |a| {
            if (a.node == .Starred) has_star = true;
        }
        for (keywords) |kw| {
            if (kw.name == null) has_dstar = true;
        }

        if (has_star or has_dstar) {
            // CALL_FUNCTION_EX
            try self.emitExpr(scope, x.func);
            self.emitOp(scope, .BUILD_LIST, 0, line);
            for (args) |a| {
                if (a.node == .Starred) {
                    try self.emitExpr(scope, a.node.Starred);
                    self.emit0(scope, .LIST_EXTEND, line);
                } else {
                    try self.emitExpr(scope, a);
                    self.emitOp(scope, .LIST_APPEND, 1, line);
                }
            }
            var has_kwargs = false;
            for (keywords) |kw| {
                if (!has_kwargs) {
                    self.emitOp(scope, .BUILD_MAP, 0, line);
                    has_kwargs = true;
                }
                if (kw.name) |n| {
                    const kobj = try self.addConst(scope, try self.rt.newStr(n));
                    self.emitOp(scope, .LOAD_CONST, kobj, line);
                    try self.emitExpr(scope, kw.value);
                    self.emitOp(scope, .MAP_ADD, 2, line);
                } else {
                    try self.emitExpr(scope, kw.value);
                    self.emit0(scope, .DICT_MERGE, line);
                }
            }
            if (!has_kwargs) {
                self.emitOp(scope, .BUILD_MAP, 0, line);
            }
            self.emit0(scope, .CALL_FUNCTION_EX, line);
            return;
        }

        try self.emitExpr(scope, x.func);
        const nargs: u16 = @intCast(args.len);
        const nkw: u16 = @intCast(keywords.len);
        for (args) |a| try self.emitExpr(scope, a);
        for (keywords) |kw| try self.emitExpr(scope, kw.value);
        if (keywords.len > 0) {
            var names_list: std.ArrayList(Obj) = .empty;
            for (keywords) |kw| {
                try names_list.append(self.a, try self.rt.newStr(kw.name.?));
            }
            const tup = try self.addConst(scope, try self.rt.newTuple(names_list.items));
            self.emitOp(scope, .KW_NAMES, tup, line);
        }
        self.emitOp(scope, .CALL, nargs | (nkw << 8), line);
    }

    // ----------------------------------------------------------
    // Присваивание / удаление / augmented
    // ----------------------------------------------------------

    fn emitStore(self: *Compiler, scope: *Scope, target: *ast.Expr, line: usize) CompileError!void {
        switch (target.node) {
            .Name => |n| try self.emitStoreName(scope, n.id, line),
            .Attribute => |a| {
                try self.emitExpr(scope, a.value);
                self.emitOp(scope, .STORE_ATTR, try self.addNameIdx(scope, a.attr), line);
            },
            .Subscript => |s| {
                try self.emitExpr(scope, s.value);
                try self.emitSubscript(scope, s.slice, line);
                self.emit0(scope, .STORE_SUBSCR, line);
            },
            .Tuple, .List => |items| {
                var star_idx: ?usize = null;
                for (items, 0..) |it, i| {
                    if (it.node == .Starred) star_idx = i;
                }
                if (star_idx == null) {
                    self.emitOp(scope, .UNPACK_SEQUENCE, @intCast(items.len), line);
                } else {
                    const before: u16 = @intCast(star_idx.?);
                    const after: u16 = @intCast(items.len - star_idx.? - 1);
                    self.emitOp(scope, .UNPACK_EX, before | (after << 8), line);
                }
                for (items) |it| {
                    if (it.node == .Starred) {
                        try self.emitStore(scope, it.node.Starred, line);
                    } else {
                        try self.emitStore(scope, it, line);
                    }
                }
            },
            .Starred => |inner| try self.emitStore(scope, inner, line),
            else => return error.SyntaxError,
        }
    }

    fn emitDelete(self: *Compiler, scope: *Scope, target: *ast.Expr, line: usize) CompileError!void {
        switch (target.node) {
            .Name => |n| try self.emitDelName(scope, n.id, line),
            .Attribute => |a| {
                try self.emitExpr(scope, a.value);
                self.emitOp(scope, .DELETE_ATTR, try self.addNameIdx(scope, a.attr), line);
            },
            .Subscript => |s| {
                try self.emitExpr(scope, s.value);
                try self.emitSubscript(scope, s.slice, line);
                self.emit0(scope, .DELETE_SUBSCR, line);
            },
            .Tuple, .List => |items| {
                for (items) |it| try self.emitDelete(scope, it, line);
            },
            else => return error.SyntaxError,
        }
    }

    fn emitAugAssign(self: *Compiler, scope: *Scope, target: *ast.Expr, op: ast.BinOp, value: *ast.Expr, line: usize) CompileError!void {
        switch (target.node) {
            .Name => |n| {
                try self.emitLoadName(scope, n.id, line);
                try self.emitExpr(scope, value);
                self.emitBinOp(scope, op, true, line);
                try self.emitStoreName(scope, n.id, line);
            },
            .Attribute => |a| {
                try self.emitExpr(scope, a.value);
                self.emit0(scope, .DUP_TOP, line);
                self.emitOp(scope, .LOAD_ATTR, try self.addNameIdx(scope, a.attr), line);
                try self.emitExpr(scope, value);
                self.emitBinOp(scope, op, true, line);
                self.emit0(scope, .ROT_TWO, line);
                self.emitOp(scope, .STORE_ATTR, try self.addNameIdx(scope, a.attr), line);
            },
            .Subscript => |s| {
                try self.emitExpr(scope, s.value);
                try self.emitSubscript(scope, s.slice, line);
                self.emit0(scope, .DUP_TOP_TWO, line);
                self.emit0(scope, .LOAD_SUBSCR, line);
                try self.emitExpr(scope, value);
                self.emitBinOp(scope, op, true, line);
                self.emit0(scope, .ROT_THREE, line);
                self.emit0(scope, .STORE_SUBSCR, line);
            },
            else => return error.SyntaxError,
        }
    }

    // ----------------------------------------------------------
    // with
    // ----------------------------------------------------------

    fn emitWithItems(self: *Compiler, scope: *Scope, items: []ast.WithItem, body: []ast.Stmt, idx: usize, line: usize) CompileError!void {
        const item = items[idx];
        try self.emitExpr(scope, item.context);
        // [mgr]
        self.emit0(scope, .DUP_TOP, line);
        self.emitOp(scope, .LOAD_ATTR, try self.addNameIdx(scope, "__exit__"), line);
        self.emit0(scope, .ROT_TWO, line);
        self.emitOp(scope, .LOAD_ATTR, try self.addNameIdx(scope, "__enter__"), line);
        self.emitOp(scope, .CALL, 0, line);
        if (item.optional) |o| {
            try self.emitStore(scope, o, line);
        } else {
            self.emit0(scope, .POP_TOP, line);
        }
        // stack [exit]
        // скрытый слот
        const slot = try self.hiddenSlot(scope);
        self.emit0(scope, .DUP_TOP, line);
        if (scope.needs_name_scope) {
            self.emitOp(scope, .STORE_NAME, slot, line);
        } else {
            self.emitOp(scope, .STORE_FAST, slot, line);
        }
        const setup_at = self.pos(scope);
        self.emitOp(scope, .SETUP_WITH, 0xffff, line);
        try self.blocks_push_with(scope, slot);
        if (idx + 1 < items.len) {
            try self.emitWithItems(scope, items, body, idx + 1, line);
        } else {
            try self.emitStmts(scope, body);
        }
        _ = try self.blocks_pop_only(scope);
        self.emit0(scope, .POP_BLOCK, line);
        // normal exit: exit(None,None,None)
        if (scope.needs_name_scope) {
            self.emitOp(scope, .LOAD_NAME, slot, line);
        } else {
            self.emitOp(scope, .LOAD_FAST, slot, line);
        }
        self.emit0(scope, .LOAD_NONE, line);
        self.emit0(scope, .LOAD_NONE, line);
        self.emit0(scope, .LOAD_NONE, line);
        self.emitOp(scope, .CALL, 3, line);
        self.emit0(scope, .POP_TOP, line);
        const after = self.pos(scope);
        self.patchRel(scope, setup_at, after);
    }

    /// Выдать скрытый слот для __exit__ (varname "#exit_N" или name)
    fn hiddenSlot(self: *Compiler, scope: *Scope) !u16 {
        const name = try std.fmt.allocPrint(self.a, "#exit_{d}", .{scope.hidden_idx});
        scope.hidden_idx += 1;
        if (scope.needs_name_scope) {
            // сделаем вид локальной переменной модуля
            try self.bind(scope, name);
            return self.addNameIdx(scope, name);
        }
        try self.bind(scope, name);
        return self.addVarnameIdx(scope, name);
    }

    // ----------------------------------------------------------
    // Функции / лямбды / классы
    // ----------------------------------------------------------

    fn emitFunctionFromScope(self: *Compiler, scope: *Scope, child: *Scope, args: ast.Arguments, ndec: usize, line: usize) CompileError!void {
        // скомпилировать тело
        const child_code = try self.compileFunctionBody(child, args);
        const code_obj = try self.rt.mkObj(self.rt.code_t, .{ .code = child_code });
        const cidx = try self.addConst(scope, code_obj);
        self.emitOp(scope, .LOAD_CONST, cidx, line);
        var flags: u16 = 0;
        // defaults tuple
        if (args.defaults.len > 0) {
            flags |= 0x01;
            for (args.defaults) |d| try self.emitExpr(scope, d);
            self.emitOp(scope, .BUILD_TUPLE, @intCast(args.defaults.len), line);
        }
        // kwdefaults dict
        var has_kwdefaults = false;
        for (args.kw_defaults) |d| {
            if (d != null) has_kwdefaults = true;
        }
        if (has_kwdefaults) {
            flags |= 0x02;
            self.emitOp(scope, .BUILD_MAP, 0, line);
            for (args.kwonly, args.kw_defaults) |ka, kd| {
                if (kd) |dd| {
                    const kobj = try self.addConst(scope, try self.rt.newStr(ka.name));
                    self.emitOp(scope, .LOAD_CONST, kobj, line);
                    try self.emitExpr(scope, dd);
                    self.emitOp(scope, .MAP_ADD, 2, line);
                }
            }
        }
        if (child.freevars.items.len > 0) {
            flags |= 0x04;
            for (child.freevars.items) |fv| {
                const idx = try self.parentCellIdx(scope, fv);
                self.emitOp(scope, .LOAD_CLOSURE, idx, line);
            }
            self.emitOp(scope, .BUILD_TUPLE, @intCast(child.freevars.items.len), line);
        }
        self.emitOp(scope, .MAKE_FUNCTION, flags, line);
        // декораторы (на стеке до этого: func — после декораторов)
        for (0..ndec) |_| {
            self.emit0(scope, .ROT_TWO, line);
            self.emitOp(scope, .CALL, 1, line);
        }
    }

    /// Взять первый ещё не сгенерированный child-scope нужного вида
    /// (collect проходит тела в порядке исходника — совпадает с порядком codegen).
    fn takeChild(scope: *Scope, kind: ScopeKind, name: ?[]const u8) ?*Scope {
        for (scope.children.items) |ch| {
            if (ch.emitted) continue;
            if (ch.kind != kind) continue;
            if (name) |n| {
                if (!std.mem.eql(u8, ch.name, n)) continue;
            }
            ch.emitted = true;
            return ch;
        }
        return null;
    }

    fn parentCellIdx(self: *Compiler, scope: *Scope, name: []const u8) !u16 {
        // в родителе символ должен быть cell
        for (scope.cellvars.items, 0..) |n, i| {
            if (std.mem.eql(u8, n, name)) return @intCast(i);
        }
        if (contains(scope.cellvars.items, name)) unreachable;
        // добавить в cellvars (декларативно)
        const idx = try self.addCellIdx(scope, name);
        // символ должен быть помечен cell в syms (findInAncestors должен был сработать)
        if (scope.syms.getPtr(name)) |sp| sp.flags.cell = true;
        return idx;
    }

    fn emitLambdaFromScope(self: *Compiler, scope: *Scope, child: *Scope, args: ast.Arguments, line: usize) CompileError!void {
        try self.emitFunctionFromScope(scope, child, args, 0, line);
    }

    /// Скомпилировать тело функции (свой scope уже собран).
    fn compileFunctionBody(self: *Compiler, child: *Scope, args: ast.Arguments) CompileError!*object.Code {
        _ = args;
        self.emit0(child, .RESUME, 0);
        // тело: для обычной функции стейтменты из AST — но AST не хранится в scope…
        // — тело передаётся отдельно при вызове; здесь child.body уже был collect'нут в makeChildScope.
        // Для codegen нам нужен сам AST. Хранить? Храним: child.body_ast
        for (child.body_stmts) |s| try self.emitStmt(child, s);
        if (child.body_expr) |e| {
            try self.emitExpr(child, e);
            self.emit0(child, .RETURN_VALUE, 0);
        }
        self.emit0(child, .LOAD_NONE, 0);
        self.emit0(child, .RETURN_VALUE, 0);
        return self.finishScope(child, child.name);
    }

    fn compileClassBody(self: *Compiler, child: *Scope, x: anytype) CompileError!*object.Code {
        self.emit0(child, .RESUME, 0);
        // __module__ и __qualname__
        {
            const name_idx = try self.addNameIdx(child, "__name__");
            self.emitOp(child, .LOAD_NAME, name_idx, 0);
            const mod_idx = try self.addNameIdx(child, "__module__");
            self.emitOp(child, .STORE_NAME, mod_idx, 0);
            const qn = try self.addConst(child, try self.rt.newStr(child.qualname));
            self.emitOp(child, .LOAD_CONST, qn, 0);
            const q_idx = try self.addNameIdx(child, "__qualname__");
            self.emitOp(child, .STORE_NAME, q_idx, 0);
        }
        try self.emitStmts(child, x.body);
        self.emit0(child, .END, 0);
        return self.finishScope(child, x.name);
    }

    // ----------------------------------------------------------
    // Comprehensions
    // ----------------------------------------------------------

    fn emitComprehension(self: *Compiler, scope: *Scope, elt: ?*ast.Expr, key: ?*ast.Expr, value: ?*ast.Expr, gens: []ast.Comprehension, ckind: CompKind, line: usize) CompileError!void {
        const child = takeChild(scope, .comprehension_, null) orelse return error.SyntaxError;

        // первый iterable — во внешней области (как у CPython)
        try self.emitExpr(scope, gens[0].iter);
        self.emit0(scope, .GET_ITER, line);

        // компилируем код comprehension
        child.comp_kind = ckind;
        if (ckind == .gen) child.is_generator = true;
        child.body_comp = .{ .elt = elt, .key = key, .value = value, .gens = gens };
        const code = try self.compileComprehensionBody(child);
        const code_obj = try self.rt.mkObj(self.rt.code_t, .{ .code = code });
        const cidx = try self.addConst(scope, code_obj);

        var flags: u16 = 0;
        if (child.freevars.items.len > 0) {
            flags |= 0x04;
            for (child.freevars.items) |fv| {
                const idx = try self.parentCellIdx(scope, fv);
                self.emitOp(scope, .LOAD_CLOSURE, idx, line);
            }
            self.emitOp(scope, .BUILD_TUPLE, @intCast(child.freevars.items.len), line);
        }
        self.emitOp(scope, .LOAD_CONST, cidx, line);
        self.emitOp(scope, .MAKE_FUNCTION, flags, line);
        self.emit0(scope, .ROT_TWO, line); // [fn, iter]
        self.emitOp(scope, .CALL, 1, line);
    }

    fn compileComprehensionBody(self: *Compiler, child: *Scope) CompileError!*object.Code {
        const cc = child.body_comp;
        self.emit0(child, .RESUME, 0);
        // инициализация контейнера
        switch (child.comp_kind) {
            .dict => self.emitOp(child, .BUILD_MAP, 0, 0),
            .set => self.emitOp(child, .BUILD_SET, 0, 0),
            .list => self.emitOp(child, .BUILD_LIST, 0, 0),
            .gen => {},
        }
        // varnames[0] == ".0" — первый параметр (итератор внешнего iterable)
        try self.emitCompLoop(child, cc, 0);
        if (child.comp_kind != .gen) {
            // на вершине стека — контейнер
            self.emit0(child, .RETURN_VALUE, 0);
        }
        self.emit0(child, .LOAD_NONE, 0);
        self.emit0(child, .RETURN_VALUE, 0);
        return self.finishScope(child, child.name);
    }

    /// Рекурсивная генерация циклов comprehension.
    /// Инвариант: на стеке лежит [контейнер?] + (для gi>0) итератор этого уровня на вершине.
    /// Внешний итератор хранится в fast-слоте 0 (".0") и перезагружается каждую итерацию.
    fn emitCompLoop(self: *Compiler, child: *Scope, cc: CompBody, gi: usize) CompileError!void {
        const g = cc.gens[gi];
        if (gi > 0) {
            try self.emitExpr(child, g.iter);
            self.emit0(child, .GET_ITER, 0);
        }
        // .0 загружается ОДИН раз до start-метки (JUMP_BACKWARD вернётся на FOR_ITER, а не на LOAD)
        if (gi == 0) self.emitOp(child, .LOAD_FAST, 0, 0);
        const loop_start = self.pos(child);
        const iter_pos = self.pos(child);
        self.emitOp(child, .FOR_ITER, 0xffff, 0);
        // стек: […, iter, value] → store снимает value
        try self.emitStore(child, g.target, 0);
        var skip_jumps: std.ArrayList(usize) = .empty;
        for (g.ifs) |cond| {
            try self.emitExpr(child, cond);
            const j = self.pos(child);
            self.emitOp(child, .POP_JUMP_IF_FALSE, 0xffff, 0);
            try skip_jumps.append(self.a, j);
        }
        if (gi + 1 < cc.gens.len) {
            try self.emitCompLoop(child, cc, gi + 1);
        } else {
            // глубина контейнера: выше него N итераторов (по одному на generator)
            const niters: u16 = @intCast(cc.gens.len);
            switch (child.comp_kind) {
                .dict => {
                    try self.emitExpr(child, cc.key.?);
                    try self.emitExpr(child, cc.value.?);
                    self.emitOp(child, .MAP_ADD, niters + 2, 0);
                },
                .set => {
                    try self.emitExpr(child, cc.elt.?);
                    self.emitOp(child, .SET_ADD, niters + 1, 0);
                },
                .list => {
                    try self.emitExpr(child, cc.elt.?);
                    self.emitOp(child, .LIST_APPEND, niters + 1, 0);
                },
                .gen => {
                    try self.emitExpr(child, cc.elt.?);
                    self.emit0(child, .YIELD_VALUE, 0);
                    self.emit0(child, .POP_TOP, 0);
                },
            }
        }
        const skip_target = self.pos(child);
        for (skip_jumps.items) |j| self.patchAbs(child, j, skip_target);
        self.emitBackJump(child, loop_start, 0);
        const after = self.pos(child);
        // FOR_ITER при исчерпании сам снимает итератор со стека
        self.patchRel(child, iter_pos, after);
    }

    // ----------------------------------------------------------
    // Константы
    // ----------------------------------------------------------

    const SENTINEL_NONE: u16 = 0xFFFF;
    const SENTINEL_TRUE: u16 = 0xFFFE;
    const SENTINEL_FALSE: u16 = 0xFFFD;
    const SENTINEL_ELLIPSIS: u16 = 0xFFFC;

    fn emitConstant(self: *Compiler, scope: *Scope, c: ast.Const, line: usize) CompileError!u16 {
        _ = line;
        switch (c) {
            .none => return SENTINEL_NONE,
            .btrue => return SENTINEL_TRUE,
            .bfalse => return SENTINEL_FALSE,
            .ellipsis => return SENTINEL_ELLIPSIS,
            .int => |txt| {
                const o = try self.parseIntLiteral(txt);
                return self.addConst(scope, o);
            },
            .float_ => |f| {
                return self.addConst(scope, try self.rt.newFloat(f));
            },
            .str => |s| {
                return self.addConst(scope, try self.rt.newStr(s));
            },
            .bytes => |s| {
                return self.addConst(scope, try self.rt.newBytes(s));
            },
            .complex_ => return error.SyntaxError,
        }
    }

    fn parseIntLiteral(self: *Compiler, txt_raw: []const u8) CompileError!Obj {
        // удалить подчёркивания
        var buf: std.ArrayList(u8) = .empty;
        for (txt_raw) |c| {
            if (c == '_') continue;
            try buf.append(self.a, c);
        }
        const txt = buf.items;
        var base: u8 = 10;
        var digits = txt;
        if (txt.len > 2 and txt[0] == '0') {
            switch (std.ascii.toLower(txt[1])) {
                'x' => {
                    base = 16;
                    digits = txt[2..];
                },
                'o' => {
                    base = 8;
                    digits = txt[2..];
                },
                'b' => {
                    base = 2;
                    digits = txt[2..];
                },
                else => {},
            }
        }
        if (base == 10) {
            const v = std.fmt.parseInt(i64, digits, 10) catch {
                const big = (try object.bigParse(self.rt.gpa, digits, 10)) orelse return error.SyntaxError;
                return self.rt.newBig(big);
            };
            return self.rt.newInt(v);
        }
        const v = std.fmt.parseInt(i64, digits, base) catch {
            const big = (try object.bigParse(self.rt.gpa, digits, base)) orelse return error.SyntaxError;
            return self.rt.newBig(big);
        };
        return self.rt.newInt(v);
    }

    fn isConstExpr(e: *ast.Expr) bool {
        return e.node == .Constant;
    }

    fn constValue(self: *Compiler, scope: *Scope, e: *ast.Expr) CompileError!Obj {
        _ = scope;
        switch (e.node.Constant) {
            .int => |txt| return self.parseIntLiteral(txt),
            .float_ => |f| return self.rt.newFloat(f),
            .str => |s| return self.rt.newStr(s),
            .bytes => |s| return self.rt.newBytes(s),
            .none => return self.rt.newNone(),
            .btrue => return self.rt.true_obj,
            .bfalse => return self.rt.false_obj,
            .ellipsis => return self.rt.ellipsis_obj,
            .complex_ => return error.SyntaxError,
        }
    }

    fn allConsts(self: *Compiler, scope: *Scope, items: []*ast.Expr) CompileError!?Obj {
        if (items.len == 0) return null; // empty tuple → строим BUILD_TUPLE 0 (или константа позже)
        for (items) |it| {
            if (!isConstExpr(it)) return null;
        }
        var vals: std.ArrayList(Obj) = .empty;
        for (items) |it| {
            try vals.append(self.a, try self.constValue(scope, it));
        }
        return try self.rt.newTuple(vals.items);
    }

    fn firstPart(name: []const u8) []const u8 {
        if (std.mem.indexOfScalar(u8, name, '.')) |dot| return name[0..dot];
        return name;
    }

    fn splitName(a: std.mem.Allocator, name: []const u8) ![][]const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        var start: usize = 0;
        for (name, 0..) |c, i| {
            if (c == '.') {
                try out.append(a, name[start..i]);
                start = i + 1;
            }
        }
        try out.append(a, name[start..]);
        return out.items;
    }
};

const CompBody = struct {
    elt: ?*ast.Expr,
    key: ?*ast.Expr,
    value: ?*ast.Expr,
    gens: []ast.Comprehension,
};

// расширения Scope, объявленные отдельно чтобы не раздувать заголовок
// (Zig не позволяет reopen, поэтому поля объявлены сюда через компил-time вставку)

// ============================================================
// Точка входа: source → Code (lexer → parser → compiler)
// ============================================================

pub const FileMode = enum { exec, eval };

const lexer_mod = @import("../parser/lexer.zig");
const parser_mod = @import("../parser/parser.zig");

pub fn compileSource(vm: anytype, filename: []const u8, src: []const u8, mode: FileMode) anyerror!*object.Code {
    const rt: *Runtime = vm.rt;
    const a = rt.gpa;
    var lex = lexer_mod.Lexer.init(a, src);
    var tokens: std.ArrayList(lexer_mod.Token) = .empty;
    while (true) {
        const t = lex.nextToken() catch {
            return raiseSyntax(vm, filename, lex.lineno, "lexical error");
        };
        try tokens.append(a, t);
        if (t.type == .ENDMARKER) break;
    }
    var parena = ast.ParserArena.init(a);
    var p = parser_mod.Parser.init(&parena, tokens.items);
    if (mode == .eval) {
        const expr = p.parseExpr() catch {
            return raiseSyntax(vm, filename, 1, "invalid syntax");
        };
        // обернуть выражение в модуль `return <expr>` через код напрямую:
        var c = Compiler.init(rt, filename);
        const scope = try Scope.new(c.a, .module_, "<module>", "<module>", null);
        scope.needs_name_scope = true;
        try c.collectExpr(scope, expr);
        try c.resolveFree(scope);
        try c.emitExpr(scope, expr);
        c.emit0(scope, .RETURN_VALUE, 0);
        return c.finishScope(scope, "<eval>");
    }
    const mod = p.parseModule() catch {
        return raiseSyntax(vm, filename, 1, "invalid syntax");
    };
    var c = Compiler.init(rt, filename);
    return c.compileModule(mod);
}

fn raiseSyntax(vm: anytype, filename: []const u8, line: usize, msg: []const u8) anyerror {
    const v: @TypeOf(vm) = vm;
    const text = try std.fmt.allocPrint(v.rt.gpa, "({s}, line {d})", .{ filename, line });
    try v.raiseFmt("SyntaxError", "{s} {s}", .{ msg, text });
    return error.PyExc;
}
