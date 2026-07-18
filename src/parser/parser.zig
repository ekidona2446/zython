//! Парсер Python - аналог Parser/parser.c + парсер на PEG в Python 3.9+ (Parser/pegen)
//! Для Zython MVP: recursive descent parser для подмножества Python 3.x
//! Совместимость: должен парсить валидный Python 3.x код

const std = @import("std");
const Allocator = std.mem.Allocator;
const lexer = @import("lexer.zig");
const ast = @import("ast.zig");

pub const Parser = struct {
    allocator: Allocator,
    ast_arena: ast.AST,
    tokens: []lexer.Token,
    pos: usize,
    source: []const u8,

    pub fn init(allocator: Allocator, source: []const u8, tokens: []lexer.Token) Parser {
        return .{
            .allocator = allocator,
            .ast_arena = ast.AST.init(allocator),
            .tokens = tokens,
            .pos = 0,
            .source = source,
        };
    }

    pub fn deinit(self: *Parser) void {
        self.ast_arena.deinit();
    }

    fn peek(self: *Parser) lexer.Token {
        if (self.pos >= self.tokens.len) return self.tokens[self.tokens.len - 1];
        return self.tokens[self.pos];
    }

    fn peekN(self: *Parser, n: usize) lexer.Token {
        const idx = self.pos + n;
        if (idx >= self.tokens.len) return self.tokens[self.tokens.len - 1];
        return self.tokens[idx];
    }

    fn advance(self: *Parser) lexer.Token {
        const tok = self.peek();
        if (self.pos < self.tokens.len) self.pos += 1;
        return tok;
    }

    fn expect(self: *Parser, tt: lexer.TokenType) !lexer.Token {
        const tok = self.peek();
        if (tok.type != tt) {
            return error.UnexpectedToken;
        }
        return self.advance();
    }

    fn atEnd(self: *Parser) bool {
        return self.peek().type == .ENDMARKER;
    }

    /// Парсит модуль - entry point
    pub fn parseModule(self: *Parser) anyerror!ast.Module {
        var stmts: std.ArrayList(ast.Stmt) = .empty;
        defer stmts.deinit(self.allocator);

        while (!self.atEnd()) {
            const t = self.peek();
            if (t.type == .NEWLINE or t.type == .NL or t.type == .COMMENT or t.type == .INDENT or t.type == .DEDENT) {
                _ = self.advance();
                continue;
            }
            if (t.type == .ENDMARKER) break;
            const stmt = try self.parseStmt();
            try stmts.append(self.allocator, stmt);
        }

        return ast.Module{
            .body = try self.ast_arena.arena.allocator().dupe(ast.Stmt, stmts.items),
        };
    }

    fn parseStmt(self: *Parser) anyerror!ast.Stmt {
        const tok = self.peek();
        const start_line = tok.start.lineno;

        return switch (tok.type) {
            .DEF => try self.parseFunctionDef(false),
            .ASYNC => if (self.peekN(1).type == .DEF) try self.parseFunctionDef(true) else try self.parseExprStmt(),
            .CLASS => try self.parseClassDef(),
            .IF => try self.parseIf(),
            .FOR => try self.parseFor(false),
            .WHILE => try self.parseWhile(),
            .RETURN => try self.parseReturn(),
            .IMPORT => try self.parseImport(),
            .FROM => try self.parseImportFrom(),
            .PASS => {
                _ = self.advance();
                return ast.Stmt{ .lineno = start_line, .col_offset = 0, .node = .Pass };
            },
            .BREAK => {
                _ = self.advance();
                return ast.Stmt{ .lineno = start_line, .col_offset = 0, .node = .Break };
            },
            .CONTINUE => {
                _ = self.advance();
                return ast.Stmt{ .lineno = start_line, .col_offset = 0, .node = .Continue };
            },
            else => try self.parseExprStmt(),
        };
    }

    fn parseFunctionDef(self: *Parser, is_async: bool) anyerror!ast.Stmt {
        const lineno = self.peek().start.lineno;
        if (is_async) _ = self.advance();
        _ = try self.expect(.DEF);
        const name_tok = try self.expect(.NAME);
        const name = try self.ast_arena.arena.allocator().dupe(u8, name_tok.string);

        _ = try self.expect(.LPAR);
        const args = try self.parseArguments();
        _ = try self.expect(.RPAR);

        while (self.peek().type != .COLON and !self.atEnd()) _ = self.advance();
        _ = try self.expect(.COLON);

        const body = try self.parseSuite();

        const func_def = ast.FunctionDef{
            .name = name,
            .args = args,
            .body = body,
            .decorator_list = &.{},
            .returns = null,
        };

        return ast.Stmt{
            .lineno = lineno,
            .col_offset = 0,
            .node = if (is_async) .{ .AsyncFunctionDef = func_def } else .{ .FunctionDef = func_def },
        };
    }

    fn parseClassDef(self: *Parser) anyerror!ast.Stmt {
        const lineno = self.peek().start.lineno;
        _ = try self.expect(.CLASS);
        const name_tok = try self.expect(.NAME);
        const name = try self.ast_arena.arena.allocator().dupe(u8, name_tok.string);

        var bases: std.ArrayList(ast.Expr) = .empty;
        defer bases.deinit(self.allocator);

        if (self.peek().type == .LPAR) {
            _ = self.advance();
            while (self.peek().type != .RPAR and !self.atEnd()) {
                const expr = try self.parseExpr();
                try bases.append(self.allocator, expr);
                if (self.peek().type == .COMMA) _ = self.advance();
            }
            _ = try self.expect(.RPAR);
        }

        while (self.peek().type != .COLON and !self.atEnd()) _ = self.advance();
        _ = try self.expect(.COLON);
        const body = try self.parseSuite();

        return ast.Stmt{
            .lineno = lineno,
            .col_offset = 0,
            .node = .{
                .ClassDef = .{
                    .name = name,
                    .bases = try self.ast_arena.arena.allocator().dupe(ast.Expr, bases.items),
                    .keywords = &.{},
                    .body = body,
                    .decorator_list = &.{},
                },
            },
        };
    }

    fn parseSuite(self: *Parser) anyerror![]ast.Stmt {
        var stmts: std.ArrayList(ast.Stmt) = .empty;
        defer stmts.deinit(self.allocator);

        if (self.peek().type == .NEWLINE) {
            _ = self.advance();
            if (self.peek().type == .INDENT) {
                _ = self.advance();
                while (self.peek().type != .DEDENT and !self.atEnd()) {
                    if (self.peek().type == .NEWLINE or self.peek().type == .NL or self.peek().type == .COMMENT) {
                        _ = self.advance();
                        continue;
                    }
                    const stmt = try self.parseStmt();
                    try stmts.append(self.allocator, stmt);
                }
                if (self.peek().type == .DEDENT) _ = self.advance();
            } else {
                const stmt = try self.parseStmt();
                try stmts.append(self.allocator, stmt);
            }
        } else {
            const stmt = try self.parseStmt();
            try stmts.append(self.allocator, stmt);
        }

        return try self.ast_arena.arena.allocator().dupe(ast.Stmt, stmts.items);
    }

    fn parseArguments(self: *Parser) anyerror!ast.Arguments {
        var args: std.ArrayList(ast.Arg) = .empty;
        defer args.deinit(self.allocator);

        while (self.peek().type != .RPAR and !self.atEnd()) {
            if (self.peek().type == .NAME) {
                const tok = self.advance();
                try args.append(self.allocator, .{ .arg = try self.ast_arena.arena.allocator().dupe(u8, tok.string) });
            }
            if (self.peek().type == .COMMA) _ = self.advance() else break;
        }

        return ast.Arguments{
            .posonlyargs = &.{},
            .args = try self.ast_arena.arena.allocator().dupe(ast.Arg, args.items),
            .vararg = null,
            .kwonlyargs = &.{},
            .kw_defaults = &.{},
            .kwarg = null,
            .defaults = &.{},
        };
    }

    fn parseIf(self: *Parser) anyerror!ast.Stmt {
        const lineno = self.peek().start.lineno;
        _ = try self.expect(.IF);
        const test_expr = try self.parseExprAlloc();

        while (self.peek().type != .COLON and !self.atEnd()) _ = self.advance();
        _ = try self.expect(.COLON);

        const body = try self.parseSuite();

        var else_stmts: []ast.Stmt = &.{};
        if (self.peek().type == .ELIF) {
            const elif_stmt = try self.parseIf();
            var list = [_]ast.Stmt{elif_stmt};
            else_stmts = try self.ast_arena.arena.allocator().dupe(ast.Stmt, &list);
        } else if (self.peek().type == .ELSE) {
            _ = self.advance();
            _ = try self.expect(.COLON);
            else_stmts = try self.parseSuite();
        }

        return ast.Stmt{
            .lineno = lineno,
            .col_offset = 0,
            .node = .{ .If = .{
                .test_expr = test_expr,
                .body = body,
                .else_body = else_stmts,
            } },
        };
    }

    fn parseFor(self: *Parser, is_async: bool) anyerror!ast.Stmt {
        const lineno = self.peek().start.lineno;
        if (is_async) _ = self.advance();
        _ = try self.expect(.FOR);
        const target = try self.parseExprAlloc();
        _ = try self.expect(.IN);
        const iter = try self.parseExprAlloc();
        _ = try self.expect(.COLON);
        const body = try self.parseSuite();

        var else_body: []ast.Stmt = &.{};
        if (self.peek().type == .ELSE) {
            _ = self.advance();
            _ = try self.expect(.COLON);
            else_body = try self.parseSuite();
        }

        const for_node = ast.For{
            .target = target,
            .iter = iter,
            .body = body,
            .else_body = else_body,
        };

        return ast.Stmt{
            .lineno = lineno,
            .col_offset = 0,
            .node = if (is_async) .{ .AsyncFor = for_node } else .{ .For = for_node },
        };
    }

    fn parseWhile(self: *Parser) anyerror!ast.Stmt {
        const lineno = self.peek().start.lineno;
        _ = try self.expect(.WHILE);
        const test_expr = try self.parseExprAlloc();
        _ = try self.expect(.COLON);
        const body = try self.parseSuite();
        var else_body: []ast.Stmt = &.{};
        if (self.peek().type == .ELSE) {
            _ = self.advance();
            _ = try self.expect(.COLON);
            else_body = try self.parseSuite();
        }
        return ast.Stmt{
            .lineno = lineno,
            .col_offset = 0,
            .node = .{ .While = .{
                .test_expr = test_expr,
                .body = body,
                .else_body = else_body,
            } },
        };
    }

    fn parseReturn(self: *Parser) anyerror!ast.Stmt {
        const lineno = self.peek().start.lineno;
        _ = try self.expect(.RETURN);
        var value: ?ast.Expr = null;
        if (self.peek().type != .NEWLINE and self.peek().type != .ENDMARKER and self.peek().type != .SEMI) {
            value = try self.parseExpr();
        }
        var opt: ?ast.Expr = value;
        return ast.Stmt{
            .lineno = lineno,
            .col_offset = 0,
            .node = .{ .Return = if (opt) |*v| try self.allocExpr(v.*) else null },
        };
    }

    fn parseImport(self: *Parser) anyerror!ast.Stmt {
        const lineno = self.peek().start.lineno;
        _ = try self.expect(.IMPORT);
        var aliases: std.ArrayList(ast.Alias) = .empty;
        defer aliases.deinit(self.allocator);

        while (!self.atEnd()) {
            const name_tok = try self.expect(.NAME);
            var asname: ?[]const u8 = null;
            if (self.peek().type == .AS) {
                _ = self.advance();
                const as_tok = try self.expect(.NAME);
                asname = try self.ast_arena.arena.allocator().dupe(u8, as_tok.string);
            }
            try aliases.append(self.allocator, .{
                .name = try self.ast_arena.arena.allocator().dupe(u8, name_tok.string),
                .asname = asname,
            });
            if (self.peek().type == .COMMA) _ = self.advance() else break;
        }

        return ast.Stmt{
            .lineno = lineno,
            .col_offset = 0,
            .node = .{ .Import = try self.ast_arena.arena.allocator().dupe(ast.Alias, aliases.items) },
        };
    }

    fn parseImportFrom(self: *Parser) anyerror!ast.Stmt {
        const lineno = self.peek().start.lineno;
        _ = try self.expect(.FROM);
        var module_name: ?[]const u8 = null;
        if (self.peek().type == .NAME) {
            const tok = self.advance();
            module_name = try self.ast_arena.arena.allocator().dupe(u8, tok.string);
        }
        _ = try self.expect(.IMPORT);

        var aliases: std.ArrayList(ast.Alias) = .empty;
        defer aliases.deinit(self.allocator);
        while (!self.atEnd() and self.peek().type == .NAME) {
            const tok = self.advance();
            try aliases.append(self.allocator, .{
                .name = try self.ast_arena.arena.allocator().dupe(u8, tok.string),
                .asname = null,
            });
            if (self.peek().type == .COMMA) _ = self.advance() else break;
        }

        return ast.Stmt{
            .lineno = lineno,
            .col_offset = 0,
            .node = .{ .ImportFrom = .{
                .module_name = module_name,
                .names = try self.ast_arena.arena.allocator().dupe(ast.Alias, aliases.items),
                .level = 0,
            } },
        };
    }

    fn parseExprStmt(self: *Parser) anyerror!ast.Stmt {
        const lineno = self.peek().start.lineno;
        const expr = try self.parseExpr();

        if (self.peek().type == .EQUAL) {
            _ = self.advance();
            const value = try self.parseExprAlloc();
            const target = try self.allocExpr(expr);
            var targets = [_]ast.Expr{target.*};
            const duped_targets = try self.ast_arena.arena.allocator().dupe(ast.Expr, &targets);
            return ast.Stmt{
                .lineno = lineno,
                .col_offset = 0,
                .node = .{ .Assign = .{
                    .targets = duped_targets,
                    .value = value,
                } },
            };
        }

        return ast.Stmt{
            .lineno = lineno,
            .col_offset = 0,
            .node = .{ .Expr = expr },
        };
    }

    fn parseExpr(self: *Parser) anyerror!ast.Expr {
        return try self.parseOr();
    }

    fn allocExpr(self: *Parser, expr: ast.Expr) anyerror!*ast.Expr {
        const ptr = try self.ast_arena.alloc(ast.Expr);
        ptr.* = expr;
        return ptr;
    }

    fn parseExprAlloc(self: *Parser) anyerror!*ast.Expr {
        const expr = try self.parseExpr();
        return try self.allocExpr(expr);
    }

    fn parseOr(self: *Parser) anyerror!ast.Expr {
        var left = try self.parseAnd();
        while (self.peek().type == .OR) {
            _ = self.advance();
            const right = try self.parseAnd();
            left = right;
        }
        return left;
    }

    fn parseAnd(self: *Parser) anyerror!ast.Expr {
        var left = try self.parseComparison();
        while (self.peek().type == .AND) {
            _ = self.advance();
            const right = try self.parseComparison();
            left = right;
        }
        return left;
    }

    fn parseComparison(self: *Parser) anyerror!ast.Expr {
        const left = try self.parseArith();
        // TODO: full comparison chaining
        if (self.peek().type == .EQEQUAL or self.peek().type == .NOTEQUAL or self.peek().type == .LESS or self.peek().type == .GREATER or self.peek().type == .LESSEQUAL or self.peek().type == .GREATEREQUAL) {
            _ = self.advance();
            _ = try self.parseArith();
        }
        return left;
    }

    fn parseArith(self: *Parser) anyerror!ast.Expr {
        var left = try self.parseTerm();
        while (self.peek().type == .PLUS or self.peek().type == .MINUS) {
            const op_tok = self.advance();
            const right = try self.parseTerm();
            const op: ast.Operator = if (op_tok.type == .PLUS) .Add else .Sub;
            const binop = try self.ast_arena.alloc(ast.Expr);
            const left_ptr = try self.allocExpr(left);
            const right_ptr = try self.allocExpr(right);
            binop.* = .{
                .lineno = left.lineno,
                .col_offset = 0,
                .node = .{ .BinOp = .{ .left = left_ptr, .op = op, .right = right_ptr } },
            };
            left = binop.*;
        }
        return left;
    }

    fn parseTerm(self: *Parser) anyerror!ast.Expr {
        var left = try self.parseFactor();
        while (self.peek().type == .STAR or self.peek().type == .SLASH or self.peek().type == .PERCENT or self.peek().type == .DOUBLESLASH) {
            const op_tok = self.advance();
            const right = try self.parseFactor();
            const op: ast.Operator = switch (op_tok.type) {
                .STAR => .Mult,
                .SLASH => .Div,
                .PERCENT => .Mod,
                .DOUBLESLASH => .FloorDiv,
                else => .Mult,
            };
            const binop = try self.ast_arena.alloc(ast.Expr);
            const left_ptr = try self.allocExpr(left);
            const right_ptr = try self.allocExpr(right);
            binop.* = .{
                .lineno = left.lineno,
                .col_offset = 0,
                .node = .{ .BinOp = .{ .left = left_ptr, .op = op, .right = right_ptr } },
            };
            left = binop.*;
        }
        return left;
    }

    fn parseFactor(self: *Parser) anyerror!ast.Expr {
        const tok = self.peek();
        switch (tok.type) {
            .AWAIT => {
                _ = self.advance();
                const operand = try self.parseFactor();
                const operand_ptr = try self.allocExpr(operand);
                return ast.Expr{
                    .lineno = tok.start.lineno,
                    .col_offset = 0,
                    .node = .{ .Await = operand_ptr },
                };
            },
            .PLUS, .MINUS, .NOT, .TILDE => {
                _ = self.advance();
                const operand = try self.parseFactor();
                const operand_ptr = try self.allocExpr(operand);
                const op: ast.UnaryOperator = switch (tok.type) {
                    .MINUS => .USub,
                    .PLUS => .UAdd,
                    .NOT => .Not,
                    .TILDE => .Invert,
                    else => .UAdd,
                };
                return ast.Expr{
                    .lineno = tok.start.lineno,
                    .col_offset = 0,
                    .node = .{ .UnaryOp = .{ .op = op, .operand = operand_ptr } },
                };
            },
            else => return try self.parsePower(),
        }
    }

    fn parsePower(self: *Parser) anyerror!ast.Expr {
        const base = try self.parsePrimary();
        if (self.peek().type == .DOUBLESTAR) {
            _ = self.advance();
            const exp = try self.parseFactor();
            const left_ptr = try self.allocExpr(base);
            const right_ptr = try self.allocExpr(exp);
            return ast.Expr{
                .lineno = base.lineno,
                .col_offset = 0,
                .node = .{ .BinOp = .{ .left = left_ptr, .op = .Pow, .right = right_ptr } },
            };
        }
        return base;
    }

    fn parsePrimary(self: *Parser) anyerror!ast.Expr {
        var expr = try self.parseAtom();
        while (true) {
            switch (self.peek().type) {
                .DOT => {
                    _ = self.advance();
                    const attr_tok = try self.expect(.NAME);
                    const expr_ptr = try self.allocExpr(expr);
                    expr = ast.Expr{
                        .lineno = expr.lineno,
                        .col_offset = 0,
                        .node = .{ .Attribute = .{
                            .value = expr_ptr,
                            .attr = try self.ast_arena.arena.allocator().dupe(u8, attr_tok.string),
                            .ctx = .Load,
                        } },
                    };
                },
                .LPAR => {
                    _ = self.advance();
                    var args: std.ArrayList(ast.Expr) = .empty;
                    defer args.deinit(self.allocator);
                    while (self.peek().type != .RPAR and !self.atEnd()) {
                        const arg = try self.parseExpr();
                        try args.append(self.allocator, arg);
                        if (self.peek().type == .COMMA) _ = self.advance() else break;
                    }
                    _ = try self.expect(.RPAR);
                    const func_ptr = try self.allocExpr(expr);
                    expr = ast.Expr{
                        .lineno = expr.lineno,
                        .col_offset = 0,
                        .node = .{ .Call = .{
                            .func = func_ptr,
                            .args = try self.ast_arena.arena.allocator().dupe(ast.Expr, args.items),
                            .keywords = &.{},
                        } },
                    };
                },
                .LSQB => {
                    _ = self.advance();
                    const slice = try self.parseExprAlloc();
                    _ = try self.expect(.RSQB);
                    const value_ptr = try self.allocExpr(expr);
                    expr = ast.Expr{
                        .lineno = expr.lineno,
                        .col_offset = 0,
                        .node = .{ .Subscript = .{
                            .value = value_ptr,
                            .slice = slice,
                            .ctx = .Load,
                        } },
                    };
                },
                else => break,
            }
        }
        return expr;
    }

    fn parseAtom(self: *Parser) anyerror!ast.Expr {
        const tok = self.peek();
        switch (tok.type) {
            .NAME => {
                _ = self.advance();
                return ast.Expr{
                    .lineno = tok.start.lineno,
                    .col_offset = 0,
                    .node = .{ .Name = .{ .id = try self.ast_arena.arena.allocator().dupe(u8, tok.string), .ctx = .Load } },
                };
            },
            .NUMBER => {
                _ = self.advance();
                const is_float = std.mem.indexOf(u8, tok.string, ".") != null or std.mem.indexOf(u8, tok.string, "e") != null or std.mem.indexOf(u8, tok.string, "E") != null;
                if (is_float) {
                    const f = std.fmt.parseFloat(f64, tok.string) catch 0.0;
                    return ast.Expr{
                        .lineno = tok.start.lineno,
                        .col_offset = 0,
                        .node = .{ .Constant = .{ .Float = f } },
                    };
                } else {
                    return ast.Expr{
                        .lineno = tok.start.lineno,
                        .col_offset = 0,
                        .node = .{ .Constant = .{ .Int = try self.ast_arena.arena.allocator().dupe(u8, tok.string) } },
                    };
                }
            },
            .STRING => {
                _ = self.advance();
                var s = tok.string;
                if (s.len >= 2) {
                    s = s[1 .. s.len - 1];
                }
                return ast.Expr{
                    .lineno = tok.start.lineno,
                    .col_offset = 0,
                    .node = .{ .Constant = .{ .Str = try self.ast_arena.arena.allocator().dupe(u8, s) } },
                };
            },
            .TRUE => {
                _ = self.advance();
                return ast.Expr{
                    .lineno = tok.start.lineno,
                    .col_offset = 0,
                    .node = .{ .Constant = .{ .Bool = true } },
                };
            },
            .FALSE => {
                _ = self.advance();
                return ast.Expr{
                    .lineno = tok.start.lineno,
                    .col_offset = 0,
                    .node = .{ .Constant = .{ .Bool = false } },
                };
            },
            .NONE => {
                _ = self.advance();
                return ast.Expr{
                    .lineno = tok.start.lineno,
                    .col_offset = 0,
                    .node = .{ .Constant = .None },
                };
            },
            .LPAR => {
                _ = self.advance();
                if (self.peek().type == .RPAR) {
                    _ = self.advance();
                    return ast.Expr{
                        .lineno = tok.start.lineno,
                        .col_offset = 0,
                        .node = .{ .Tuple = &.{} },
                    };
                }
                const inner = try self.parseExpr();
                if (self.peek().type == .COMMA) {
                    var items: std.ArrayList(ast.Expr) = .empty;
                    defer items.deinit(self.allocator);
                    try items.append(self.allocator, inner);
                    while (self.peek().type == .COMMA) {
                        _ = self.advance();
                        if (self.peek().type == .RPAR) break;
                        const next_expr = try self.parseExpr();
                        try items.append(self.allocator, next_expr);
                    }
                    _ = try self.expect(.RPAR);
                    const duped = try self.ast_arena.arena.allocator().dupe(ast.Expr, items.items);
                    return ast.Expr{
                        .lineno = tok.start.lineno,
                        .col_offset = 0,
                        .node = .{ .Tuple = duped },
                    };
                } else {
                    _ = try self.expect(.RPAR);
                    return inner;
                }
            },
            .LSQB => {
                _ = self.advance();
                var items: std.ArrayList(ast.Expr) = .empty;
                defer items.deinit(self.allocator);
                while (self.peek().type != .RSQB and !self.atEnd()) {
                    const e = try self.parseExpr();
                    try items.append(self.allocator, e);
                    if (self.peek().type == .COMMA) _ = self.advance() else break;
                }
                _ = try self.expect(.RSQB);
                return ast.Expr{
                    .lineno = tok.start.lineno,
                    .col_offset = 0,
                    .node = .{ .List = try self.ast_arena.arena.allocator().dupe(ast.Expr, items.items) },
                };
            },
            else => {
                return error.UnexpectedToken;
            },
        }
    }
};
