//! AST Python — упрощённый аналог Include/internal/pycore_ast.h.
//! Arena-аллокация: все узлы и списки живут до конца парсинга модуля.

const std = @import("std");

pub const Module = struct {
    body: []Stmt,
};

pub const Stmt = struct {
    lineno: usize,
    node: S,
};

pub const S = union(enum) {
    Expr: *Expr,
    Assign: struct { targets: []*Expr, value: *Expr },
    AugAssign: struct { target: *Expr, op: BinOp, value: *Expr },
    AnnAssign: struct { target: *Expr, ann: *Expr, value: ?*Expr, simple: bool },
    If: struct { cond: *Expr, body: []Stmt, or_else: []Stmt },
    While: struct { cond: *Expr, body: []Stmt, or_else: []Stmt },
    For: struct { target: *Expr, iter: *Expr, body: []Stmt, or_else: []Stmt, is_async: bool },
    With: struct { items: []WithItem, body: []Stmt, is_async: bool },
    Raise: struct { exc: ?*Expr, cause: ?*Expr },
    Try: struct { body: []Stmt, handlers: []Handler, or_else: []Stmt, finalbody: []Stmt },
    Assert: struct { cond: *Expr, msg: ?*Expr },
    Import: []Alias,
    ImportFrom: struct { module: ?[]const u8, level: usize, names: []Alias, lineno: usize },
    Global: [][]const u8,
    Nonlocal: [][]const u8,
    FunctionDef: struct {
        name: []const u8,
        args: Arguments,
        body: []Stmt,
        decorator_list: []*Expr,
        returns: ?*Expr,
        is_async: bool,
    },
    ClassDef: struct {
        name: []const u8,
        bases: []*Expr,
        keywords: []Keyword,
        body: []Stmt,
        decorator_list: []*Expr,
    },
    Return: ?*Expr,
    Delete: []*Expr,
    Pass,
    Break,
    Continue,
};

pub const WithItem = struct { context: *Expr, optional: ?*Expr };
pub const Handler = struct { typ: ?*Expr, name: ?[]const u8, body: []Stmt, lineno: usize };
pub const Alias = struct { name: []const u8, asname: ?[]const u8 };
pub const Keyword = struct { name: ?[]const u8, value: *Expr }; // name=null для **
pub const NamedArg = struct { name: ?[]const u8, value: *Expr };

pub const Arg = struct {
    name: []const u8,
    ann: ?*Expr = null,
};

pub const Arguments = struct {
    posonly: []Arg = &.{},
    args: []Arg = &.{},
    vararg: ?Arg = null,
    kwonly: []Arg = &.{},
    kw_defaults: []?*Expr = &.{},
    kwarg: ?Arg = null,
    defaults: []*Expr = &.{},
};

pub const BinOp = enum {
    Add,
    Sub,
    Mult,
    MatMult,
    Div,
    Mod,
    Pow,
    LShift,
    RShift,
    BitOr,
    BitXor,
    BitAnd,
    FloorDiv,
};

pub const UnaryOp = enum { Invert, Not, UAdd, USub };
pub const BoolOp = enum { And, Or };
pub const CmpOp = enum { Eq, NotEq, Lt, LtE, Gt, GtE, Is, IsNot, In, NotIn };

pub const Expr = struct {
    lineno: usize,
    node: E,
};

pub const E = union(enum) {
    BoolOp: struct { op: BoolOp, values: []*Expr },
    NamedExpr: struct { target: *Expr, value: *Expr },
    BinOp: struct { left: *Expr, op: BinOp, right: *Expr },
    UnaryOp: struct { op: UnaryOp, operand: *Expr },
    Lambda: struct { args: Arguments, body: *Expr },
    IfExp: struct { cond: *Expr, body: *Expr, or_else: *Expr },
    Dict: struct { keys: []?*Expr, values: []*Expr },
    Set: []*Expr,
    ListComp: struct { elt: *Expr, gens: []Comprehension },
    SetComp: struct { elt: *Expr, gens: []Comprehension },
    DictComp: struct { key: *Expr, value: *Expr, gens: []Comprehension },
    GeneratorExp: struct { elt: *Expr, gens: []Comprehension },
    AwaitExpr: *Expr,
    Yield: ?*Expr,
    YieldFrom: *Expr,
    Compare: struct { left: *Expr, ops: []CmpOp, comparators: []*Expr },
    Call: struct { func: *Expr, args: []*Expr, keywords: []Keyword },
    FormattedValue: struct { value: *Expr, conversion: u8, spec: ?*Expr }, // conv: '!' char или 0
    JoinedStr: []*Expr,
    Constant: Const,
    Attribute: struct { value: *Expr, attr: []const u8 },
    Subscript: struct { value: *Expr, slice: *Expr },
    Starred: *Expr,
    Name: struct { id: []const u8, ctx: ExprCtx },
    List: []*Expr,
    Tuple: []*Expr,
    Slice: struct { lower: ?*Expr, upper: ?*Expr, step: ?*Expr },
};

pub const ExprCtx = enum { load, store, del };

pub const Const = union(enum) {
    none,
    btrue,
    bfalse,
    int: []const u8, // исходный текст (с префиксами/подчёркиваниями)
    float_: f64,
    complex_: f64, // только j-часть — не поддерживаем пока, reserved
    str: []const u8, // уже декодированная
    bytes: []const u8,
    ellipsis,
};

pub const Comprehension = struct {
    target: *Expr,
    iter: *Expr,
    ifs: []*Expr,
    is_async: bool,
};

pub const ParserArena = struct {
    arena: std.heap.ArenaAllocator,

    pub fn init(backing: std.mem.Allocator) ParserArena {
        return .{ .arena = std.heap.ArenaAllocator.init(backing) };
    }
    pub fn deinit(self: *ParserArena) void {
        self.arena.deinit();
    }
    pub fn alloc(self: *ParserArena, comptime T: type) !*T {
        return self.arena.allocator().create(T);
    }
    pub fn slice(self: *ParserArena, comptime T: type, items: []const T) ![]T {
        return self.arena.allocator().dupe(T, items);
    }
    pub fn str(self: *ParserArena, s: []const u8) ![]const u8 {
        return self.arena.allocator().dupe(u8, s);
    }
    pub fn a(self: *ParserArena) std.mem.Allocator {
        return self.arena.allocator();
    }
};
