//! AST - абстрактное синтаксическое дерево Python
//! Аналог Include/internal/pycore_ast.h и Python/Python-ast.c (генерируется из Grammar/python.gram)

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const AST = struct {
    allocator: Allocator,
    // Пулы для arena allocation
    arena: std.heap.ArenaAllocator,

    pub fn init(allocator: Allocator) AST {
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *AST) void {
        self.arena.deinit();
    }

    pub fn alloc(self: *AST, comptime T: type) !*T {
        return self.arena.allocator().create(T);
    }
};

// Типы узлов - упрощенная версия Python ast module

pub const Module = struct {
    body: []Stmt,
    type_ignores: []TypeIgnore = &.{},
};

pub const Stmt = struct {
    lineno: usize,
    col_offset: usize,
    node: StmtKind,

    pub const StmtKind = union(enum) {
        FunctionDef: FunctionDef,
        AsyncFunctionDef: FunctionDef,
        ClassDef: ClassDef,
        Return: ?*Expr,
        Delete: []Expr,
        Assign: Assign,
        AugAssign: AugAssign,
        AnnAssign: AnnAssign,
        For: For,
        AsyncFor: For,
        While: While,
        If: If,
        With: With,
        AsyncWith: With,
        Match: void, // TODO: Python 3.10+
        Raise: ?Raise,
        Try: Try,
        Assert: Assert,
        Import: []Alias,
        ImportFrom: ImportFrom,
        Global: [][]const u8,
        Nonlocal: [][]const u8,
        Expr: Expr,
        Pass,
        Break,
        Continue,
    };
};

pub const Expr = struct {
    lineno: usize,
    col_offset: usize,
    node: ExprKind,

    pub const ExprKind = union(enum) {
        BoolOp: BoolOp,
        NamedExpr: NamedExpr, // walrus :=
        BinOp: BinOp,
        UnaryOp: UnaryOp,
        Lambda: Lambda,
        IfExp: IfExp,
        Dict: Dict,
        Set: []Expr,
        ListComp: Comprehension,
        SetComp: Comprehension,
        DictComp: DictComprehension,
        GeneratorExp: Comprehension,
        Await: *Expr,
        Yield: ?*Expr,
        YieldFrom: *Expr,
        Compare: Compare,
        Call: Call,
        FormattedValue: void,
        JoinedStr: []Expr,
        Constant: Constant,
        Attribute: Attribute,
        Subscript: Subscript,
        Starred: *Expr,
        Name: Name,
        List: []Expr,
        Tuple: []Expr,
        Slice: Slice,
    };
};

pub const Constant = union(enum) {
    None,
    Bool: bool,
    Int: []const u8, // храним как строку, парсим позже как big int
    Float: f64,
    Str: []const u8,
    Bytes: []const u8,
    Tuple: []Constant,
    Ellipsis,
};

pub const FunctionDef = struct {
    name: []const u8,
    args: Arguments,
    body: []Stmt,
    decorator_list: []Expr,
    returns: ?*Expr,
    type_comment: ?[]const u8 = null,
};

pub const ClassDef = struct {
    name: []const u8,
    bases: []Expr,
    keywords: []Keyword,
    body: []Stmt,
    decorator_list: []Expr,
};

pub const Arguments = struct {
    posonlyargs: []Arg,
    args: []Arg,
    vararg: ?*Arg,
    kwonlyargs: []Arg,
    kw_defaults: []?Expr,
    kwarg: ?*Arg,
    defaults: []Expr,
};

pub const Arg = struct {
    arg: []const u8,
    annotation: ?*Expr = null,
    type_comment: ?[]const u8 = null,
};

pub const Assign = struct {
    targets: []Expr,
    value: *Expr,
    type_comment: ?[]const u8 = null,
};

pub const AugAssign = struct {
    target: *Expr,
    op: Operator,
    value: *Expr,
};

pub const AnnAssign = struct {
    target: *Expr,
    annotation: *Expr,
    value: ?*Expr,
    simple: bool,
};

pub const For = struct {
    target: *Expr,
    iter: *Expr,
    body: []Stmt,
    else_body: []Stmt,
    type_comment: ?[]const u8 = null,
};

pub const While = struct {
    test_expr: *Expr,
    body: []Stmt,
    else_body: []Stmt,
};

pub const If = struct {
    test_expr: *Expr,
    body: []Stmt,
    else_body: []Stmt,
};

pub const With = struct {
    items: []WithItem,
    body: []Stmt,
    type_comment: ?[]const u8 = null,
};

pub const WithItem = struct {
    context_expr: *Expr,
    optional_vars: ?*Expr,
};

pub const Try = struct {
    body: []Stmt,
    handlers: []ExceptHandler,
    else_body: []Stmt,
    finalbody: []Stmt,
};

pub const ExceptHandler = struct {
    lineno: usize,
    col_offset: usize,
    type_expr: ?*Expr,
    name: ?[]const u8,
    body: []Stmt,
};

pub const Raise = struct {
    exc: ?*Expr,
    cause: ?*Expr,
};

pub const Assert = struct {
    test_expr: *Expr,
    msg: ?*Expr,
};

pub const Alias = struct {
    name: []const u8,
    asname: ?[]const u8,
};

pub const ImportFrom = struct {
    module_name: ?[]const u8,
    names: []Alias,
    level: usize,
};

pub const BoolOp = struct {
    op: BoolOperator,
    values: []Expr,
};

pub const NamedExpr = struct {
    target: *Expr,
    value: *Expr,
};

pub const BinOp = struct {
    left: *Expr,
    op: Operator,
    right: *Expr,
};

pub const UnaryOp = struct {
    op: UnaryOperator,
    operand: *Expr,
};

pub const Lambda = struct {
    args: Arguments,
    body: *Expr,
};

pub const IfExp = struct {
    test_expr: *Expr,
    body: *Expr,
    else_expr: *Expr,
};

pub const Dict = struct {
    keys: []?Expr,
    values: []Expr,
};

pub const Compare = struct {
    left: *Expr,
    ops: []CmpOp,
    comparators: []Expr,
};

pub const Call = struct {
    func: *Expr,
    args: []Expr,
    keywords: []Keyword,
};

pub const Keyword = struct {
    arg: ?[]const u8,
    value: *Expr,
};

pub const Attribute = struct {
    value: *Expr,
    attr: []const u8,
    ctx: ExprContext,
};

pub const Subscript = struct {
    value: *Expr,
    slice: *Expr,
    ctx: ExprContext,
};

pub const Name = struct {
    id: []const u8,
    ctx: ExprContext,
};

pub const Slice = struct {
    lower: ?*Expr,
    upper: ?*Expr,
    step: ?*Expr,
};

pub const Comprehension = struct {
    elt: *Expr,
    generators: []ComprehensionGenerator,
};

pub const ComprehensionGenerator = struct {
    target: *Expr,
    iter: *Expr,
    ifs: []Expr,
    is_async: bool,
};

pub const DictComprehension = struct {
    key: *Expr,
    value: *Expr,
    generators: []ComprehensionGenerator,
};

pub const TypeIgnore = struct {
    lineno: usize,
    tag: []const u8,
};

// Операторы
pub const Operator = enum {
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

pub const BoolOperator = enum { And, Or };
pub const UnaryOperator = enum { Invert, Not, UAdd, USub };
pub const CmpOp = enum { Eq, NotEq, Lt, LtE, Gt, GtE, Is, IsNot, In, NotIn };
pub const ExprContext = enum { Load, Store, Del };

pub fn constantToString(c: Constant, allocator: Allocator) ![]const u8 {
    return switch (c) {
        .None => try allocator.dupe(u8, "None"),
        .Bool => |b| try allocator.dupe(u8, if (b) "True" else "False"),
        .Int => |s| try allocator.dupe(u8, s),
        .Float => |f| try std.fmt.allocPrint(allocator, "{d}", .{f}),
        .Str => |s| try allocator.dupe(u8, s),
        .Bytes => |b| try allocator.dupe(u8, b),
        .Tuple => try allocator.dupe(u8, "(...)"),
        .Ellipsis => try allocator.dupe(u8, "..."),
    };
}
