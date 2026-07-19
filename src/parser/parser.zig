//! Парсер Python — рекурсивный спуск по грамматике 3.13.
//! Аналог Parser/parser.c (PEG), но классический RD с приоритетами.

const std = @import("std");
const lexer = @import("lexer.zig");
const ast = @import("ast.zig");

const Token = lexer.Token;
const TokenType = lexer.TokenType;
const Expr = ast.Expr;
const Stmt = ast.Stmt;

pub const ParseError = error{
    SyntaxError,
    UnexpectedToken,
    OutOfMemory,
    UnterminatedString,
    UnexpectedChar,
    IndentationError,
};

pub const Parser = struct {
    arena: *ast.ParserArena,
    tokens: []Token,
    pos: usize = 0,

    pub fn init(arena: *ast.ParserArena, tokens: []Token) Parser {
        return .{ .arena = arena, .tokens = tokens };
    }

    fn peek(self: *Parser) Token {
        return self.tokens[self.pos];
    }
    fn peekType(self: *Parser) TokenType {
        return self.tokens[self.pos].type;
    }
    fn peekN(self: *Parser, n: usize) TokenType {
        if (self.pos + n >= self.tokens.len) return .ENDMARKER;
        return self.tokens[self.pos + n].type;
    }
    fn advance(self: *Parser) Token {
        const t = self.tokens[self.pos];
        if (t.type != .ENDMARKER) self.pos += 1;
        return t;
    }
    fn atEnd(self: *Parser) bool {
        return self.peekType() == .ENDMARKER;
    }
    fn skipNL(self: *Parser) void {
        while (self.peekType() == .NL) _ = self.advance();
    }
    fn expect(self: *Parser, t: TokenType) ParseError!Token {
        self.skipNL();
        const tok = self.peek();
        if (tok.type != t) {
            std.debug.print("[parser] expected {s}, got {s} ('{s}') at line {d}\n", .{ @tagName(t), @tagName(tok.type), tok.text, tok.lineno });
            return error.UnexpectedToken;
        }
        return self.advance();
    }
    fn accept(self: *Parser, t: TokenType) ?Token {
        const tok = self.peek();
        if (tok.type == t) {
            _ = self.advance();
            if (t == .NEWLINE or t == .NL) self.skipNL();
            return tok;
        }
        return null;
    }

    fn mkExpr(self: *Parser, lineno: usize, node: ast.E) ParseError!*Expr {
        const e = try self.arena.alloc(Expr);
        e.* = .{ .lineno = lineno, .node = node };
        return e;
    }
    fn mkStmt(self: *Parser, lineno: usize, node: ast.S) ParseError!Stmt {
        _ = self;
        return .{ .lineno = lineno, .node = node };
    }
    fn dupeExprs(self: *Parser, items: []const *Expr) ParseError![]*Expr {
        return self.arena.slice(*Expr, items);
    }
    fn dupeStmts(self: *Parser, items: []const Stmt) ParseError![]Stmt {
        return self.arena.slice(Stmt, items);
    }
    fn dupeStr(self: *Parser, s: []const u8) ParseError![]const u8 {
        return self.arena.str(s);
    }

    // ============================================================
    // Вход
    // ============================================================

    pub fn parseModule(self: *Parser) ParseError!ast.Module {
        var body: std.ArrayList(Stmt) = .empty;
        while (true) {
            const t = self.peekType();
            if (t == .ENDMARKER) break;
            if (t == .NEWLINE or t == .NL) {
                _ = self.advance();
                continue;
            }
            const stmts = try self.parseStatements();
            for (stmts) |s| try body.append(self.arena.a(), s);
        }
        return .{ .body = self.arena.slice(Stmt, body.items) catch body.items };
    }

    /// statements: stmt (';' stmt)* [';'] NEWLINE | INDENT обрабатывается выше
    fn parseStatements(self: *Parser) ParseError![]Stmt {
        var list: std.ArrayList(Stmt) = .empty;
        while (true) {
            const s = try self.parseStmt();
            try list.append(self.arena.a(), s);
            if (self.accept(.SEMI)) |_| {
                if (self.peekType() == .NEWLINE) break;
                continue;
            }
            break;
        }
        if (self.peekType() == .NEWLINE) {
            _ = self.advance();
            self.skipNL();
        }
        return self.dupeStmts(list.items);
    }

    /// suite: ':' simple_stmt | ':' NEWLINE INDENT stmt+ DEDENT
    fn parseSuite(self: *Parser) ParseError![]Stmt {
        _ = try self.expect(.COLON);
        if (self.peekType() == .NEWLINE) {
            _ = self.advance();
            self.skipNL();
            _ = try self.expect(.INDENT);
            var body: std.ArrayList(Stmt) = .empty;
            while (self.peekType() != .DEDENT and !self.atEnd()) {
                if (self.peekType() == .NEWLINE or self.peekType() == .NL) {
                    _ = self.advance();
                    continue;
                }
                const stmts = try self.parseStatements();
                for (stmts) |s| try body.append(self.arena.a(), s);
            }
            _ = try self.expect(.DEDENT);
            return self.dupeStmts(body.items);
        }
        return self.parseStatements();
    }

    // ============================================================
    // Операторы
    // ============================================================

    fn parseStmt(self: *Parser) ParseError!Stmt {
        const tok = self.peek();
        const line = tok.lineno;
        return switch (tok.type) {
            .KW_DEF => self.parseFunctionDef(false),
            .AT => blk: {
                // декораторы — function или class
                _ = self.advance();
                break :blk self.parseDecorated(line);
            },
            .KW_ASYNC => blk: {
                if (self.peekN(1) == .KW_DEF) {
                    _ = self.advance();
                    break :blk self.parseFunctionDef(true);
                }
                if (self.peekN(1) == .KW_FOR) {
                    _ = self.advance();
                    break :blk self.parseFor(true);
                }
                if (self.peekN(1) == .KW_WITH) {
                    _ = self.advance();
                    break :blk self.parseWith(true);
                }
                break :blk self.parseExprStatement();
            },
            .KW_CLASS => self.parseClassDef(),
            .KW_IF => self.parseIf(),
            .KW_FOR => self.parseFor(false),
            .KW_WHILE => self.parseWhile(),
            .KW_WITH => self.parseWith(false),
            .KW_TRY => self.parseTry(),
            .KW_RETURN => {
                _ = self.advance();
                var v: ?*Expr = null;
                if (self.peekType() != .NEWLINE and self.peekType() != .SEMI and self.peekType() != .DEDENT and !self.atEnd()) {
                    v = try self.parseTestlistStar();
                }
                return self.mkStmt(line, .{ .Return = v });
            },
            .KW_RAISE => {
                _ = self.advance();
                var exc: ?*Expr = null;
                var cause: ?*Expr = null;
                if (self.peekType() != .NEWLINE and self.peekType() != .SEMI and !self.atEnd()) {
                    exc = try self.parseExpr();
                    if (self.accept(.KW_FROM)) |_| {
                        cause = try self.parseExpr();
                    }
                }
                return self.mkStmt(line, .{ .Raise = .{ .exc = exc, .cause = cause } });
            },
            .KW_ASSERT => {
                _ = self.advance();
                const test_ = try self.parseExpr();
                var msg: ?*Expr = null;
                if (self.accept(.COMMA)) |_| {
                    msg = try self.parseExpr();
                }
                return self.mkStmt(line, .{ .Assert = .{ .cond = test_, .msg = msg } });
            },
            .KW_IMPORT => self.parseImport(),
            .KW_FROM => self.parseImportFrom(),
            .KW_GLOBAL => {
                _ = self.advance();
                var names: std.ArrayList([]const u8) = .empty;
                while (true) {
                    const n = try self.expect(.NAME);
                    try names.append(self.arena.a(), try self.dupeStr(n.text));
                    if (self.accept(.COMMA)) |_| continue;
                    break;
                }
                return self.mkStmt(line, .{ .Global = try self.arena.slice([]const u8, names.items) });
            },
            .KW_NONLOCAL => {
                _ = self.advance();
                var names: std.ArrayList([]const u8) = .empty;
                while (true) {
                    const n = try self.expect(.NAME);
                    try names.append(self.arena.a(), try self.dupeStr(n.text));
                    if (self.accept(.COMMA)) |_| continue;
                    break;
                }
                return self.mkStmt(line, .{ .Nonlocal = try self.arena.slice([]const u8, names.items) });
            },
            .KW_DEL => {
                _ = self.advance();
                const targets = try self.parseExprlist();
                var non_const_count: usize = 0;
                for (targets) |t| {
                    _ = t;
                    non_const_count += 1;
                }
                return self.mkStmt(line, .{ .Delete = targets });
            },
            .KW_PASS => {
                _ = self.advance();
                return self.mkStmt(line, .Pass);
            },
            .KW_BREAK => {
                _ = self.advance();
                return self.mkStmt(line, .Break);
            },
            .KW_CONTINUE => {
                _ = self.advance();
                return self.mkStmt(line, .Continue);
            },
            else => self.parseExprStatement(),
        };
    }

    fn parseDecorated(self: *Parser, line: usize) ParseError!Stmt {
        var decorators: std.ArrayList(*Expr) = .empty;
        while (true) {
            // @ уже съеден первый раз; далее приходим по NEWLINE
            const d = try self.parseArithExpr(); // dotted name + call optional
            var dec = d;
            // разрешаем вызов в декораторе
            if (self.peekType() == .LPAR) {
                _ = self.advance();
                self.skipNL();
                var args: std.ArrayList(*Expr) = .empty;
                var keywords: std.ArrayList(ast.Keyword) = .empty;
                try self.parseCallArgs(&args, &keywords);
                _ = try self.expect(.RPAR);
                dec = try self.mkExpr(line, .{ .Call = .{ .func = d, .args = try self.dupeExprs(args.items), .keywords = try self.arena.slice(ast.Keyword, keywords.items) } });
            }
            try decorators.append(self.arena.a(), dec);
            _ = try self.expect(.NEWLINE);
            self.skipNL();
            if (self.accept(.AT)) |_| continue;
            break;
        }
        const tok = self.peek();
        if (tok.type == .KW_CLASS) {
            var cls = try self.parseClassDef();
            cls.node.ClassDef.decorator_list = try self.dupeExprs(decorators.items);
            return cls;
        }
        if (tok.type == .KW_DEF) {
            var f = try self.parseFunctionDef(false);
            f.node.FunctionDef.decorator_list = try self.dupeExprs(decorators.items);
            return f;
        }
        if (tok.type == .KW_ASYNC and self.peekN(1) == .KW_DEF) {
            _ = self.advance();
            var f = try self.parseFunctionDef(true);
            f.node.FunctionDef.decorator_list = try self.dupeExprs(decorators.items);
            return f;
        }
        return error.UnexpectedToken;
    }

    fn parseFunctionDef(self: *Parser, is_async: bool) ParseError!Stmt {
        const line = self.peek().lineno;
        _ = try self.expect(.KW_DEF);
        const name_tok = try self.expect(.NAME);
        _ = try self.expect(.LPAR);
        self.skipNL();
        const args = try self.parseArguments();
        _ = try self.expect(.RPAR);
        var returns: ?*Expr = null;
        if (self.accept(.RARROW)) |_| {
            returns = try self.parseExpr();
        }
        const body = try self.parseSuite();
        return self.mkStmt(line, .{ .FunctionDef = .{
            .name = try self.dupeStr(name_tok.text),
            .args = args,
            .body = body,
            .decorator_list = &.{},
            .returns = returns,
            .is_async = is_async,
        } });
    }

    fn parseArguments(self: *Parser) ParseError!ast.Arguments {
        var args: std.ArrayList(ast.Arg) = .empty;
        var kwonly: std.ArrayList(ast.Arg) = .empty;
        var kw_defaults: std.ArrayList(?*Expr) = .empty;
        var defaults: std.ArrayList(*Expr) = .empty;
        var vararg: ?ast.Arg = null;
        var kwarg: ?ast.Arg = null;
        var seen_star = false;
        var posonly_marker_count: usize = 0; // сколько аргументов до '/'

        const State = enum { pos, kw };
        var state: State = .pos;

        while (self.peekType() != .RPAR) {
            if (self.peekType() == .DOUBLESTAR) {
                _ = self.advance();
                const n = try self.expect(.NAME);
                var ann: ?*Expr = null;
                if (self.accept(.COLON)) |_| ann = try self.parseExpr();
                kwarg = .{ .name = try self.dupeStr(n.text), .ann = ann };
                _ = self.accept(.COMMA);
                break;
            }
            if (self.peekType() == .STAR) {
                _ = self.advance();
                seen_star = true;
                state = .kw;
                if (self.peekType() == .NAME) {
                    const n = try self.expect(.NAME);
                    var ann: ?*Expr = null;
                    if (self.accept(.COLON)) |_| ann = try self.parseExpr();
                    vararg = .{ .name = try self.dupeStr(n.text), .ann = ann };
                }
                if (self.accept(.COMMA)) |_| continue;
                continue;
            }
            if (self.peekType() == .SLASH) {
                _ = self.advance();
                // все предыдущие args → posonly
                posonly_marker_count = args.items.len;
                _ = self.accept(.COMMA);
                continue;
            }
            const n = try self.expect(.NAME);
            var ann: ?*Expr = null;
            if (self.accept(.COLON)) |_| ann = try self.parseExpr();
            const arg = ast.Arg{ .name = try self.dupeStr(n.text), .ann = ann };
            if (state == .pos) {
                try args.append(self.arena.a(), arg);
                if (self.accept(.EQUAL)) |_| {
                    const d = try self.parseExpr();
                    try defaults.append(self.arena.a(), d);
                } else if (defaults.items.len > 0) {
                    // non-default после default — SyntaxError, но мягко пропустим
                }
            } else {
                try kwonly.append(self.arena.a(), arg);
                if (self.accept(.EQUAL)) |_| {
                    const d = try self.parseExpr();
                    try kw_defaults.append(self.arena.a(), d);
                } else {
                    try kw_defaults.append(self.arena.a(), null);
                }
            }
            if (self.accept(.COMMA)) |_| continue;
            break;
        }
        // posonly split
        var res = ast.Arguments{};
        if (posonly_marker_count > 0) {
            res.posonly = try self.arena.slice(ast.Arg, args.items[0..posonly_marker_count]);
            res.args = try self.arena.slice(ast.Arg, args.items[posonly_marker_count..]);
        } else {
            res.posonly = &.{};
            res.args = try self.arena.slice(ast.Arg, args.items);
        }
        res.vararg = vararg;
        res.kwarg = kwarg;
        res.kwonly = try self.arena.slice(ast.Arg, kwonly.items);
        res.kw_defaults = try self.arena.slice(?*Expr, kw_defaults.items);
        // defaults применяются к хвосту posonly+args — нормализуем к хвосту args (как CPython: defaults относятся к последним из posonly+args)
        res.defaults = try self.arena.slice(*Expr, defaults.items);
        return res;
    }

    fn parseClassDef(self: *Parser) ParseError!Stmt {
        const line = self.peek().lineno;
        _ = try self.expect(.KW_CLASS);
        const name_tok = try self.expect(.NAME);
        var bases: std.ArrayList(*Expr) = .empty;
        var keywords: std.ArrayList(ast.Keyword) = .empty;
        if (self.accept(.LPAR)) |_| {
            self.skipNL();
            while (self.peekType() != .RPAR) {
                // bases: expr | name=expr (metaclass=)
                if (self.peekType() == .NAME and self.peekN(1) == .EQUAL) {
                    const kn = try self.expect(.NAME);
                    _ = try self.expect(.EQUAL);
                    const v = try self.parseExpr();
                    try keywords.append(self.arena.a(), .{ .name = try self.dupeStr(kn.text), .value = v });
                } else {
                    const b = try self.parseArithExpr();
                    try bases.append(self.arena.a(), b);
                }
                if (self.accept(.COMMA)) |_| continue;
                break;
            }
            _ = try self.expect(.RPAR);
        }
        const body = try self.parseSuite();
        return self.mkStmt(line, .{ .ClassDef = .{
            .name = try self.dupeStr(name_tok.text),
            .bases = try self.dupeExprs(bases.items),
            .keywords = try self.arena.slice(ast.Keyword, keywords.items),
            .body = body,
            .decorator_list = &.{},
        } });
    }

    fn parseIf(self: *Parser) ParseError!Stmt {
        const line = self.peek().lineno;
        _ = try self.expect(.KW_IF);
        const test_ = try self.parseNamedExpr();
        const body = try self.parseSuite();
        var or_else: []Stmt = &.{};
        if (self.peekType() == .KW_ELIF) {
            const elif_stmt = try self.parseElif();
            var list: std.ArrayList(Stmt) = .empty;
            try list.append(self.arena.a(), elif_stmt);
            or_else = try self.dupeStmts(list.items);
        } else if (self.peekType() == .KW_ELSE) {
            _ = self.advance();
            or_else = try self.parseSuite();
        }
        return self.mkStmt(line, .{ .If = .{ .cond = test_, .body = body, .or_else = or_else } });
    }

    fn parseElif(self: *Parser) ParseError!Stmt {
        const line = self.peek().lineno;
        _ = try self.expect(.KW_ELIF);
        const test_ = try self.parseNamedExpr();
        const body = try self.parseSuite();
        var or_else: []Stmt = &.{};
        if (self.peekType() == .KW_ELIF) {
            const nested = try self.parseElif();
            var list: std.ArrayList(Stmt) = .empty;
            try list.append(self.arena.a(), nested);
            or_else = try self.dupeStmts(list.items);
        } else if (self.peekType() == .KW_ELSE) {
            _ = self.advance();
            or_else = try self.parseSuite();
        }
        return self.mkStmt(line, .{ .If = .{ .cond = test_, .body = body, .or_else = or_else } });
    }

    fn parseWhile(self: *Parser) ParseError!Stmt {
        const line = self.peek().lineno;
        _ = try self.expect(.KW_WHILE);
        const test_ = try self.parseNamedExpr();
        const body = try self.parseSuite();
        var or_else: []Stmt = &.{};
        if (self.peekType() == .KW_ELSE) {
            _ = self.advance();
            or_else = try self.parseSuite();
        }
        return self.mkStmt(line, .{ .While = .{ .cond = test_, .body = body, .or_else = or_else } });
    }

    fn parseFor(self: *Parser, is_async: bool) ParseError!Stmt {
        const line = self.peek().lineno;
        _ = try self.expect(.KW_FOR);
        const target = try self.parseTargetList();
        _ = try self.expect(.KW_IN);
        const iter = try self.parseTestlistStarEx();
        const body = try self.parseSuite();
        var or_else: []Stmt = &.{};
        if (self.peekType() == .KW_ELSE) {
            _ = self.advance();
            or_else = try self.parseSuite();
        }
        return self.mkStmt(line, .{ .For = .{ .target = target, .iter = iter, .body = body, .or_else = or_else, .is_async = is_async } });
    }

    fn parseWith(self: *Parser, is_async: bool) ParseError!Stmt {
        const line = self.peek().lineno;
        _ = try self.expect(.KW_WITH);
        var items: std.ArrayList(ast.WithItem) = .empty;
        // поддержим скобки: with (a as b, c): — Python 3.9+
        const has_paren = self.accept(.LPAR) != null;
        while (true) {
            const ctx = try self.parseExpr();
            var opt: ?*Expr = null;
            if (self.accept(.KW_AS)) |_| {
                opt = try self.parseExpr();
            }
            try items.append(self.arena.a(), .{ .context = ctx, .optional = opt });
            if (self.accept(.COMMA)) |_| {
                if (has_paren and self.peekType() == .RPAR) break;
                continue;
            }
            break;
        }
        if (has_paren) _ = try self.expect(.RPAR);
        const body = try self.parseSuite();
        return self.mkStmt(line, .{ .With = .{ .items = try self.arena.slice(ast.WithItem, items.items), .body = body, .is_async = is_async } });
    }

    fn parseTry(self: *Parser) ParseError!Stmt {
        const line = self.peek().lineno;
        _ = try self.expect(.KW_TRY);
        const body = try self.parseSuite();
        var handlers: std.ArrayList(ast.Handler) = .empty;
        var or_else: []Stmt = &.{};
        var finalbody: []Stmt = &.{};
        while (self.peekType() == .KW_EXCEPT) {
            const hline = self.peek().lineno;
            _ = self.advance();
            var typ: ?*Expr = null;
            var name: ?[]const u8 = null;
            if (self.peekType() != .COLON) {
                var t = try self.parseExpr();
                // except (A, B) as e:
                if (self.accept(.KW_AS)) |_| {
                    const n = try self.expect(.NAME);
                    name = try self.dupeStr(n.text);
                }
                typ = t;
                _ = &t;
            }
            const hbody = try self.parseSuite();
            try handlers.append(self.arena.a(), .{ .typ = typ, .name = name, .body = hbody, .lineno = hline });
        }
        if (self.peekType() == .KW_ELSE) {
            _ = self.advance();
            or_else = try self.parseSuite();
        }
        if (self.peekType() == .KW_FINALLY) {
            _ = self.advance();
            finalbody = try self.parseSuite();
        }
        return self.mkStmt(line, .{ .Try = .{ .body = body, .handlers = try self.arena.slice(ast.Handler, handlers.items), .or_else = or_else, .finalbody = finalbody } });
    }

    fn parseImport(self: *Parser) ParseError!Stmt {
        const line = self.peek().lineno;
        _ = try self.expect(.KW_IMPORT);
        var aliases: std.ArrayList(ast.Alias) = .empty;
        while (true) {
            var buf: std.ArrayList(u8) = .empty;
            while (true) {
                const n = try self.expect(.NAME);
                try buf.appendSlice(self.arena.a(), n.text);
                if (self.accept(.DOT)) |_| {
                    try buf.append(self.arena.a(), '.');
                    continue;
                }
                break;
            }
            var asname: ?[]const u8 = null;
            if (self.accept(.KW_AS)) |_| {
                const n = try self.expect(.NAME);
                asname = try self.dupeStr(n.text);
            }
            try aliases.append(self.arena.a(), .{ .name = try self.dupeStr(buf.items), .asname = asname });
            if (self.accept(.COMMA)) |_| continue;
            break;
        }
        return self.mkStmt(line, .{ .Import = try self.arena.slice(ast.Alias, aliases.items) });
    }

    fn parseImportFrom(self: *Parser) ParseError!Stmt {
        const line = self.peek().lineno;
        _ = try self.expect(.KW_FROM);
        var level: usize = 0;
        while (true) {
            if (self.accept(.DOT)) |_| {
                level += 1;
                continue;
            }
            if (self.accept(.ELLIPSIS)) |_| {
                level += 3;
                continue;
            }
            break;
        }
        var module: ?[]const u8 = null;
        if (self.peekType() == .NAME) {
            var buf: std.ArrayList(u8) = .empty;
            while (true) {
                const n = try self.expect(.NAME);
                try buf.appendSlice(self.arena.a(), n.text);
                if (self.accept(.DOT)) |_| {
                    try buf.append(self.arena.a(), '.');
                    continue;
                }
                break;
            }
            module = try self.dupeStr(buf.items);
        }
        _ = try self.expect(.KW_IMPORT);
        var aliases: std.ArrayList(ast.Alias) = .empty;
        if (self.accept(.STAR)) |_| {
            try aliases.append(self.arena.a(), .{ .name = "*", .asname = null });
        } else {
            const has_paren = self.accept(.LPAR) != null;
            while (true) {
                const n = try self.expect(.NAME);
                var asname: ?[]const u8 = null;
                if (self.accept(.KW_AS)) |_| {
                    const an = try self.expect(.NAME);
                    asname = try self.dupeStr(an.text);
                }
                try aliases.append(self.arena.a(), .{ .name = try self.dupeStr(n.text), .asname = asname });
                if (self.accept(.COMMA)) |_| {
                    if (has_paren and self.peekType() == .RPAR) break;
                    continue;
                }
                break;
            }
            if (has_paren) _ = try self.expect(.RPAR);
        }
        return self.mkStmt(line, .{ .ImportFrom = .{ .module = module, .level = level, .names = try self.arena.slice(ast.Alias, aliases.items), .lineno = line } });
    }

    /// expr_stmt: testlist_star (augassign expr | ('=' testlist_star)* | (':' expr ['=' expr]))
    fn parseExprStatement(self: *Parser) ParseError!Stmt {
        const line = self.peek().lineno;
        // yield-statement: `yield ...` как самостоятельный оператор (grammar: star_expressions)
        if (self.peekType() == .KW_YIELD) {
            const y = try self.parseYieldExpr();
            return self.mkStmt(line, .{ .Expr = y });
        }
        // AnnAssign: NAME ':' expr ['=' expr]
        if (self.peekType() == .NAME and self.peekN(1) == .COLON) {
            const n = try self.expect(.NAME);
            _ = try self.expect(.COLON);
            const ann = try self.parseExpr();
            var value: ?*Expr = null;
            if (self.accept(.EQUAL)) |_| {
                value = try self.parseTestlistStar();
            }
            const target = try self.mkExpr(line, .{ .Name = .{ .id = try self.dupeStr(n.text), .ctx = .store } });
            return self.mkStmt(line, .{ .AnnAssign = .{ .target = target, .ann = ann, .value = value, .simple = true } });
        }

        const lhs = try self.parseTestlistStarEx();

        // attribute/subscript annassign:  a.b: T / a[i]: T
        if (self.peekType() == .COLON and (lhs.node == .Attribute or lhs.node == .Subscript or lhs.node == .Name)) {
            _ = self.advance();
            const ann = try self.parseExpr();
            var value: ?*Expr = null;
            if (self.accept(.EQUAL)) |_| {
                value = try self.parseTestlistStar();
            }
            return self.mkStmt(line, .{ .AnnAssign = .{ .target = lhs, .ann = ann, .value = value, .simple = false } });
        }

        const tt = self.peekType();
        switch (tt) {
            .PLUSEQUAL, .MINEQUAL, .STAREQUAL, .SLASHEQUAL, .DOUBLESLASHEQUAL, .PERCENTEQUAL, .DOUBLESTAREQUAL, .LEFTSHIFTEQUAL, .RIGHTSHIFTEQUAL, .VBAREQUAL, .AMPEREQUAL, .CIRCUMFLEXEQUAL, .ATEQUAL => {
                _ = self.advance();
                const op: ast.BinOp = switch (tt) {
                    .PLUSEQUAL => .Add,
                    .MINEQUAL => .Sub,
                    .STAREQUAL => .Mult,
                    .SLASHEQUAL => .Div,
                    .DOUBLESLASHEQUAL => .FloorDiv,
                    .PERCENTEQUAL => .Mod,
                    .DOUBLESTAREQUAL => .Pow,
                    .LEFTSHIFTEQUAL => .LShift,
                    .RIGHTSHIFTEQUAL => .RShift,
                    .VBAREQUAL => .BitOr,
                    .AMPEREQUAL => .BitAnd,
                    .CIRCUMFLEXEQUAL => .BitXor,
                    .ATEQUAL => .MatMult,
                    else => .Add,
                };
                const rhs = try self.parseTestlistStar();
                return self.mkStmt(line, .{ .AugAssign = .{ .target = lhs, .op = op, .value = rhs } });
            },
            .EQUAL => {
                var targets: std.ArrayList(*Expr) = .empty;
                try targets.append(self.arena.a(), lhs);
                var value: *Expr = undefined;
                while (true) {
                    _ = try self.expect(.EQUAL);
                    const next = try self.parseTestlistStarOrAssign();
                    if (self.peekType() == .EQUAL) {
                        try targets.append(self.arena.a(), next);
                        continue;
                    }
                    value = next;
                    break;
                }
                return self.mkStmt(line, .{ .Assign = .{ .targets = try self.dupeExprs(targets.items), .value = value } });
            },
            else => {
                return self.mkStmt(line, .{ .Expr = lhs });
            },
        }
    }

    fn parseTestlistStar(self: *Parser) ParseError!*Expr {
        // expr (, expr)* [,] — tuple если есть запятая
        const line = self.peek().lineno;
        const first = try self.parseExpr();
        if (self.peekType() == .COMMA) {
            var items: std.ArrayList(*Expr) = .empty;
            try items.append(self.arena.a(), first);
            while (self.accept(.COMMA)) |_| {
                if (self.peekType() == .NEWLINE or self.peekType() == .SEMI or self.peekType() == .RPAR or self.atEnd()) break;
                const e = try self.parseExpr();
                try items.append(self.arena.a(), e);
            }
            return self.mkExpr(line, .{ .Tuple = try self.dupeExprs(items.items) });
        }
        return first;
    }

    /// testlist_star с поддержкой *starred (для for-target, rhs присваивания)
    fn parseTestlistStarEx(self: *Parser) ParseError!*Expr {
        const line = self.peek().lineno;
        var items: std.ArrayList(*Expr) = .empty;
        var has_starred = false;
        while (true) {
            if (self.peekType() == .STAR) {
                _ = self.advance();
                const e = try self.parseExpr();
                has_starred = true;
                try items.append(self.arena.a(), try self.mkExpr(e.lineno, .{ .Starred = e }));
            } else {
                const e = try self.parseExpr();
                try items.append(self.arena.a(), e);
            }
            if (self.accept(.COMMA)) |_| {
                if (self.peekType() == .NEWLINE or self.peekType() == .SEMI or self.peekType() == .RPAR or self.atEnd() or self.peekType() == .EQUAL) break;
                continue;
            }
            break;
        }
        if (items.items.len == 1 and !has_starred) return items.items[0];
        return self.mkExpr(line, .{ .Tuple = try self.dupeExprs(items.items) });
    }

    fn parseTestlistStarOrAssign(self: *Parser) ParseError!*Expr {
        if (self.peekType() == .KW_YIELD) {
            return self.parseYieldExpr();
        }
        return self.parseTestlistStarEx();
    }

    /// список целей для for/del: expr (, expr)*
    fn parseTargetList(self: *Parser) ParseError!*Expr {
        const line = self.peek().lineno;
        var items: std.ArrayList(*Expr) = .empty;
        while (true) {
            if (self.peekType() == .STAR) {
                _ = self.advance();
                const e = try self.parseExpr();
                try items.append(self.arena.a(), try self.mkExpr(e.lineno, .{ .Starred = e }));
            } else {
                const e = try self.parseArithExpr();
                try items.append(self.arena.a(), e);
            }
            if (self.accept(.COMMA)) |_| {
                if (self.peekType() == .KW_IN or self.peekType() == .NEWLINE) break;
                continue;
            }
            break;
        }
        if (items.items.len == 1) return items.items[0];
        return self.mkExpr(line, .{ .Tuple = try self.dupeExprs(items.items) });
    }

    fn parseExprlist(self: *Parser) ParseError![]*Expr {
        var items: std.ArrayList(*Expr) = .empty;
        while (true) {
            if (self.peekType() == .STAR) {
                _ = self.advance();
                const e = try self.parseExpr();
                try items.append(self.arena.a(), try self.mkExpr(e.lineno, .{ .Starred = e }));
            } else {
                const e = try self.parseExpr();
                try items.append(self.arena.a(), e);
            }
            if (self.accept(.COMMA)) |_| {
                if (self.peekType() == .NEWLINE or self.peekType() == .SEMI) break;
                continue;
            }
            break;
        }
        return self.dupeExprs(items.items);
    }

    // ============================================================
    // Выражения (приоритеты снизу вверх)
    // ============================================================

    pub fn parseExpr(self: *Parser) ParseError!*Expr {
        if (self.peekType() == .KW_LAMBDA) return self.parseLambda();
        return self.parseNamedExpr();
    }

    fn parseNamedExpr(self: *Parser) ParseError!*Expr {
        const line = self.peek().lineno;
        const e = try self.parseTernary();
        if (self.peekType() == .COLONEQUAL) {
            _ = self.advance();
            const v = try self.parseNamedExpr();
            if (e.node != .Name) return error.SyntaxError;
            return self.mkExpr(line, .{ .NamedExpr = .{ .target = e, .value = v } });
        }
        return e;
    }

    fn parseTernary(self: *Parser) ParseError!*Expr {
        const line = self.peek().lineno;
        const body = try self.parseOr();
        if (self.peekType() == .KW_IF) {
            _ = self.advance();
            const test_ = try self.parseOr();
            _ = try self.expect(.KW_ELSE);
            const or_else = try self.parseTernary();
            return self.mkExpr(line, .{ .IfExp = .{ .cond = test_, .body = body, .or_else = or_else } });
        }
        return body;
    }

    fn parseOr(self: *Parser) ParseError!*Expr {
        const line = self.peek().lineno;
        var left = try self.parseAnd();
        while (self.peekType() == .KW_OR) {
            _ = self.advance();
            const right = try self.parseAnd();
            left = try self.mkExpr(line, .{ .BoolOp = .{ .op = .Or, .values = try self.arena.slice(*Expr, &.{ left, right }) } });
        }
        return left;
    }

    fn parseAnd(self: *Parser) ParseError!*Expr {
        const line = self.peek().lineno;
        var left = try self.parseNot();
        while (self.peekType() == .KW_AND) {
            _ = self.advance();
            const right = try self.parseNot();
            left = try self.mkExpr(line, .{ .BoolOp = .{ .op = .And, .values = try self.arena.slice(*Expr, &.{ left, right }) } });
        }
        return left;
    }

    fn parseNot(self: *Parser) ParseError!*Expr {
        const line = self.peek().lineno;
        if (self.peekType() == .KW_NOT) {
            _ = self.advance();
            const e = try self.parseNot();
            return self.mkExpr(line, .{ .UnaryOp = .{ .op = .Not, .operand = e } });
        }
        return self.parseComparison();
    }

    fn parseComparison(self: *Parser) ParseError!*Expr {
        const line = self.peek().lineno;
        const first = try self.parseBitwiseOr();
        var ops_list: std.ArrayList(ast.CmpOp) = .empty;
        var comparators: std.ArrayList(*Expr) = .empty;
        while (true) {
            const tt = self.peekType();
            var op: ?ast.CmpOp = null;
            switch (tt) {
                .EQEQUAL => op = .Eq,
                .NOTEQUAL => op = .NotEq,
                .LESS => op = .Lt,
                .LESSEQUAL => op = .LtE,
                .GREATER => op = .Gt,
                .GREATEREQUAL => op = .GtE,
                .KW_IS => {
                    _ = self.advance();
                    if (self.accept(.KW_NOT)) |_| {
                        try ops_list.append(self.arena.a(), .IsNot);
                    } else {
                        try ops_list.append(self.arena.a(), .Is);
                    }
                    const e = try self.parseBitwiseOr();
                    try comparators.append(self.arena.a(), e);
                    continue;
                },
                .KW_IN => {
                    _ = self.advance();
                    try ops_list.append(self.arena.a(), .In);
                    const e = try self.parseBitwiseOr();
                    try comparators.append(self.arena.a(), e);
                    continue;
                },
                .KW_NOT => {
                    if (self.peekN(1) == .KW_IN) {
                        _ = self.advance();
                        _ = self.advance();
                        try ops_list.append(self.arena.a(), .NotIn);
                        const e = try self.parseBitwiseOr();
                        try comparators.append(self.arena.a(), e);
                        continue;
                    }
                    break;
                },
                else => break,
            }
            if (op) |o| {
                _ = self.advance();
                try ops_list.append(self.arena.a(), o);
                const e = try self.parseBitwiseOr();
                try comparators.append(self.arena.a(), e);
            } else break;
        }
        if (ops_list.items.len == 0) return first;
        return self.mkExpr(line, .{ .Compare = .{ .left = first, .ops = try self.arena.slice(ast.CmpOp, ops_list.items), .comparators = try self.dupeExprs(comparators.items) } });
    }

    fn parseBitwiseOr(self: *Parser) ParseError!*Expr {
        const line = self.peek().lineno;
        var left = try self.parseBitwiseXor();
        while (self.peekType() == .VBAR) {
            _ = self.advance();
            const right = try self.parseBitwiseXor();
            left = try self.mkExpr(line, .{ .BinOp = .{ .left = left, .op = .BitOr, .right = right } });
        }
        return left;
    }

    fn parseBitwiseXor(self: *Parser) ParseError!*Expr {
        const line = self.peek().lineno;
        var left = try self.parseBitwiseAnd();
        while (self.peekType() == .CIRCUMFLEX) {
            _ = self.advance();
            const right = try self.parseBitwiseAnd();
            left = try self.mkExpr(line, .{ .BinOp = .{ .left = left, .op = .BitXor, .right = right } });
        }
        return left;
    }

    fn parseBitwiseAnd(self: *Parser) ParseError!*Expr {
        const line = self.peek().lineno;
        var left = try self.parseShift();
        while (self.peekType() == .AMPER) {
            _ = self.advance();
            const right = try self.parseShift();
            left = try self.mkExpr(line, .{ .BinOp = .{ .left = left, .op = .BitAnd, .right = right } });
        }
        return left;
    }

    fn parseShift(self: *Parser) ParseError!*Expr {
        const line = self.peek().lineno;
        var left = try self.parseArithExpr();
        while (self.peekType() == .LEFTSHIFT or self.peekType() == .RIGHTSHIFT) {
            const tt = self.advance();
            const right = try self.parseArithExpr();
            const op: ast.BinOp = if (tt.type == .LEFTSHIFT) .LShift else .RShift;
            left = try self.mkExpr(line, .{ .BinOp = .{ .left = left, .op = op, .right = right } });
        }
        return left;
    }

    pub fn parseArithExpr(self: *Parser) ParseError!*Expr {
        const line = self.peek().lineno;
        var left = try self.parseTerm();
        while (self.peekType() == .PLUS or self.peekType() == .MINUS) {
            const tt = self.advance();
            const right = try self.parseTerm();
            const op: ast.BinOp = if (tt.type == .PLUS) .Add else .Sub;
            left = try self.mkExpr(line, .{ .BinOp = .{ .left = left, .op = op, .right = right } });
        }
        return left;
    }

    fn parseTerm(self: *Parser) ParseError!*Expr {
        const line = self.peek().lineno;
        var left = try self.parseFactor();
        while (true) {
            const tt = self.peekType();
            const op: ast.BinOp = switch (tt) {
                .STAR => .Mult,
                .SLASH => .Div,
                .DOUBLESLASH => .FloorDiv,
                .PERCENT => .Mod,
                .AT => .MatMult,
                else => break,
            };
            _ = self.advance();
            const right = try self.parseFactor();
            left = try self.mkExpr(line, .{ .BinOp = .{ .left = left, .op = op, .right = right } });
        }
        return left;
    }

    fn parseFactor(self: *Parser) ParseError!*Expr {
        const line = self.peek().lineno;
        const tt = self.peekType();
        switch (tt) {
            .PLUS => {
                _ = self.advance();
                const e = try self.parseFactor();
                return self.mkExpr(line, .{ .UnaryOp = .{ .op = .UAdd, .operand = e } });
            },
            .MINUS => {
                _ = self.advance();
                const e = try self.parseFactor();
                return self.mkExpr(line, .{ .UnaryOp = .{ .op = .USub, .operand = e } });
            },
            .TILDE => {
                _ = self.advance();
                const e = try self.parseFactor();
                return self.mkExpr(line, .{ .UnaryOp = .{ .op = .Invert, .operand = e } });
            },
            else => return self.parsePower(),
        }
    }

    fn parsePower(self: *Parser) ParseError!*Expr {
        const line = self.peek().lineno;
        const base = try self.parseAwaitPrimary();
        if (self.peekType() == .DOUBLESTAR) {
            _ = self.advance();
            const exp = try self.parseFactor();
            return self.mkExpr(line, .{ .BinOp = .{ .left = base, .op = .Pow, .right = exp } });
        }
        return base;
    }

    fn parseAwaitPrimary(self: *Parser) ParseError!*Expr {
        const line = self.peek().lineno;
        if (self.peekType() == .KW_AWAIT) {
            _ = self.advance();
            const inner = try self.parseAwaitPrimary();
            return self.mkExpr(line, .{ .AwaitExpr = inner });
        }
        return self.parsePrimary();
    }

    pub fn parsePrimary(self: *Parser) ParseError!*Expr {
        var e = try self.parseAtom();
        while (true) {
            const tt = self.peekType();
            switch (tt) {
                .DOT => {
                    _ = self.advance();
                    const name_tok = try self.expect(.NAME);
                    e = try self.mkExpr(e.lineno, .{ .Attribute = .{ .value = e, .attr = try self.dupeStr(name_tok.text) } });
                },
                .LPAR => {
                    const line = e.lineno;
                    _ = self.advance();
                    self.skipNL();
                    var args: std.ArrayList(*Expr) = .empty;
                    var keywords: std.ArrayList(ast.Keyword) = .empty;
                    try self.parseCallArgs(&args, &keywords);
                    _ = try self.expect(.RPAR);
                    e = try self.mkExpr(line, .{ .Call = .{ .func = e, .args = try self.dupeExprs(args.items), .keywords = try self.arena.slice(ast.Keyword, keywords.items) } });
                },
                .LSQB => {
                    _ = self.advance();
                    self.skipNL();
                    const slice = try self.parseSubscriptList();
                    _ = try self.expect(.RSQB);
                    e = try self.mkExpr(e.lineno, .{ .Subscript = .{ .value = e, .slice = slice } });
                },
                else => return e,
            }
        }
    }

    /// содержимое [...]: expr | slice | (expr|slice) (, ...)*
    fn parseSubscriptList(self: *Parser) ParseError!*Expr {
        const line = self.peek().lineno;
        var items: std.ArrayList(*Expr) = .empty;
        var has_comma = false;
        while (true) {
            const item = try self.parseSubscriptExpr();
            try items.append(self.arena.a(), item);
            if (self.accept(.COMMA)) |_| {
                has_comma = true;
                if (self.peekType() == .RSQB) break;
                continue;
            }
            break;
        }
        if (items.items.len == 1 and !has_comma) return items.items[0];
        return self.mkExpr(line, .{ .Tuple = try self.dupeExprs(items.items) });
    }

    fn parseSubscriptExpr(self: *Parser) ParseError!*Expr {
        const line = self.peek().lineno;
        // slice: [lower][:upper] [: [step]]
        var lower: ?*Expr = null;
        var upper: ?*Expr = null;
        var step: ?*Expr = null;
        var is_slice = false;

        if (self.peekType() == .STAR) {
            _ = self.advance();
            const e = try self.parseExpr();
            return self.mkExpr(line, .{ .Starred = e });
        }

        if (self.peekType() != .COLON) {
            const first = try self.parseExpr();
            if (self.peekType() == .COLON) {
                lower = first;
            } else {
                return first;
            }
        }
        // есть хотя бы ':'
        if (self.accept(.COLON)) |_| {
            is_slice = true;
            if (self.peekType() != .COLON and self.peekType() != .RSQB and self.peekType() != .COMMA) {
                upper = try self.parseExpr();
            }
            if (self.accept(.COLON)) |_| {
                if (self.peekType() != .RSQB and self.peekType() != .COMMA) {
                    step = try self.parseExpr();
                }
            }
        }
        if (is_slice) {
            return self.mkExpr(line, .{ .Slice = .{ .lower = lower, .upper = upper, .step = step } });
        }
        // невозможно, но на всякий случай
        return lower.?;
    }

    // ============================================================
    // Атомы
    // ============================================================

    fn parseAtom(self: *Parser) ParseError!*Expr {
        const tok = self.peek();
        const line = tok.lineno;
        switch (tok.type) {
            .NAME => {
                _ = self.advance();
                return self.mkExpr(line, .{ .Name = .{ .id = try self.dupeStr(tok.text), .ctx = .load } });
            },
            .NUMBER => {
                _ = self.advance();
                return self.numberToExpr(tok, line);
            },
            .STRING => {
                _ = self.advance();
                const c = try self.decodeStringToken(tok.text);
                // склейка смежных строк
                var merged = c;
                while (self.peekType() == .STRING or self.peekType() == .FSTRING) {
                    const more = self.advance();
                    if (more.type == .STRING) {
                        const c2 = try self.decodeStringToken(more.text);
                        merged = try self.concatConsts(merged, c2, line);
                    } else {
                        // f-строка рядом — собираем JoinedStr
                        const js = try self.fstringToExpr(more.text, line);
                        var parts: std.ArrayList(*Expr) = .empty;
                        const left_e = try self.mkExpr(line, .{ .Constant = merged });
                        try parts.append(self.arena.a(), left_e);
                        if (js.node == .JoinedStr) {
                            for (js.node.JoinedStr) |p| try parts.append(self.arena.a(), p);
                        } else {
                            try parts.append(self.arena.a(), js);
                        }
                        // продолжаем склейку ниже — JoinedStr как Constant не влезает; соберём всё в JoinedStr
                        while (self.peekType() == .STRING or self.peekType() == .FSTRING) {
                            const m2 = self.advance();
                            if (m2.type == .STRING) {
                                const c3 = try self.decodeStringToken(m2.text);
                                if (c3 == .str) {
                                    try parts.append(self.arena.a(), try self.mkExpr(line, .{ .Constant = c3 }));
                                }
                            } else {
                                const j2 = try self.fstringToExpr(m2.text, line);
                                if (j2.node == .JoinedStr) {
                                    for (j2.node.JoinedStr) |p| try parts.append(self.arena.a(), p);
                                } else try parts.append(self.arena.a(), j2);
                            }
                        }
                        return self.mkExpr(line, .{ .JoinedStr = try self.dupeExprs(parts.items) });
                    }
                }
                return self.mkExpr(line, .{ .Constant = merged });
            },
            .FSTRING => {
                _ = self.advance();
                const first = try self.fstringToExpr(tok.text, line);
                // склейка со строками после
                var parts: std.ArrayList(*Expr) = .empty;
                if (first.node == .JoinedStr) {
                    for (first.node.JoinedStr) |p| try parts.append(self.arena.a(), p);
                } else try parts.append(self.arena.a(), first);
                while (self.peekType() == .STRING or self.peekType() == .FSTRING) {
                    const t2 = self.advance();
                    if (t2.type == .STRING) {
                        const c = try self.decodeStringToken(t2.text);
                        if (c == .str) try parts.append(self.arena.a(), try self.mkExpr(line, .{ .Constant = c }));
                    } else {
                        const j2 = try self.fstringToExpr(t2.text, line);
                        if (j2.node == .JoinedStr) {
                            for (j2.node.JoinedStr) |p| try parts.append(self.arena.a(), p);
                        } else try parts.append(self.arena.a(), j2);
                    }
                }
                return self.mkExpr(line, .{ .JoinedStr = try self.dupeExprs(parts.items) });
            },
            .KW_TRUE => {
                _ = self.advance();
                return self.mkExpr(line, .{ .Constant = .btrue });
            },
            .KW_FALSE => {
                _ = self.advance();
                return self.mkExpr(line, .{ .Constant = .bfalse });
            },
            .KW_NONE => {
                _ = self.advance();
                return self.mkExpr(line, .{ .Constant = .none });
            },
            .ELLIPSIS => {
                _ = self.advance();
                return self.mkExpr(line, .{ .Constant = .ellipsis });
            },
            .LPAR => {
                _ = self.advance();
                self.skipNL();
                if (self.accept(.RPAR)) |_| {
                    return self.mkExpr(line, .{ .Tuple = &.{} });
                }
                // genexp? lambda? yield?
                if (self.peekType() == .KW_YIELD) {
                    const y = try self.parseYieldExpr();
                    _ = try self.expect(.RPAR);
                    return y;
                }
                const first = try self.parseExprOrStarred();
                if (self.peekType() == .KW_FOR) {
                    // genexp
                    const gens = try self.parseComprehensions();
                    _ = try self.expect(.RPAR);
                    return self.mkExpr(line, .{ .GeneratorExp = .{ .elt = first, .gens = gens } });
                }
                if (self.peekType() == .COMMA) {
                    var items: std.ArrayList(*Expr) = .empty;
                    try items.append(self.arena.a(), first);
                    while (self.accept(.COMMA)) |_| {
                        if (self.peekType() == .RPAR) break;
                        const e = try self.parseExprOrStarred();
                        try items.append(self.arena.a(), e);
                    }
                    _ = try self.expect(.RPAR);
                    return self.mkExpr(line, .{ .Tuple = try self.dupeExprs(items.items) });
                }
                _ = try self.expect(.RPAR);
                return first;
            },
            .LSQB => {
                _ = self.advance();
                self.skipNL();
                if (self.accept(.RSQB)) |_| {
                    return self.mkExpr(line, .{ .List = &.{} });
                }
                const first = try self.parseExprOrStarred();
                if (self.peekType() == .KW_FOR) {
                    const gens = try self.parseComprehensions();
                    _ = try self.expect(.RSQB);
                    return self.mkExpr(line, .{ .ListComp = .{ .elt = first, .gens = gens } });
                }
                var items: std.ArrayList(*Expr) = .empty;
                try items.append(self.arena.a(), first);
                while (self.accept(.COMMA)) |_| {
                    if (self.peekType() == .RSQB) break;
                    const e = try self.parseExprOrStarred();
                    try items.append(self.arena.a(), e);
                }
                _ = try self.expect(.RSQB);
                return self.mkExpr(line, .{ .List = try self.dupeExprs(items.items) });
            },
            .LBRACE => {
                _ = self.advance();
                self.skipNL();
                if (self.accept(.RBRACE)) |_| {
                    return self.mkExpr(line, .{ .Dict = .{ .keys = &.{}, .values = &.{} } });
                }
                // dict или set
                var keys: std.ArrayList(?*Expr) = .empty;
                var values: std.ArrayList(*Expr) = .empty;
                var set_items: std.ArrayList(*Expr) = .empty;
                var is_dict: ?bool = null;

                // первый элемент
                if (self.peekType() == .DOUBLESTAR) {
                    _ = self.advance();
                    const e = try self.parseExpr();
                    try keys.append(self.arena.a(), null);
                    try values.append(self.arena.a(), e);
                    is_dict = true;
                } else {
                    const first = try self.parseExprOrStarred();
                    if (self.peekType() == .COLON) {
                        is_dict = true;
                        _ = self.advance();
                        const v = try self.parseExpr();
                        if (self.peekType() == .KW_FOR) {
                            const gens = try self.parseComprehensions();
                            _ = try self.expect(.RBRACE);
                            return self.mkExpr(line, .{ .DictComp = .{ .key = first, .value = v, .gens = gens } });
                        }
                        try keys.append(self.arena.a(), first);
                        try values.append(self.arena.a(), v);
                    } else if (self.peekType() == .KW_FOR) {
                        const gens = try self.parseComprehensions();
                        _ = try self.expect(.RBRACE);
                        return self.mkExpr(line, .{ .SetComp = .{ .elt = first, .gens = gens } });
                    } else {
                        try set_items.append(self.arena.a(), first);
                    }
                }
                while (self.accept(.COMMA)) |_| {
                    if (self.peekType() == .RBRACE) break;
                    if (is_dict == true) {
                        if (self.peekType() == .DOUBLESTAR) {
                            _ = self.advance();
                            const e = try self.parseExpr();
                            try keys.append(self.arena.a(), null);
                            try values.append(self.arena.a(), e);
                        } else {
                            const k = try self.parseExpr();
                            _ = try self.expect(.COLON);
                            const v = try self.parseExpr();
                            try keys.append(self.arena.a(), k);
                            try values.append(self.arena.a(), v);
                        }
                    } else {
                        const e = try self.parseExprOrStarred();
                        try set_items.append(self.arena.a(), e);
                    }
                }
                _ = try self.expect(.RBRACE);
                if (is_dict == true) {
                    return self.mkExpr(line, .{ .Dict = .{ .keys = try self.arena.slice(?*Expr, keys.items), .values = try self.dupeExprs(values.items) } });
                }
                return self.mkExpr(line, .{ .Set = try self.dupeExprs(set_items.items) });
            },
            .DOT => {
                return error.UnexpectedToken;
            },
            else => {
                std.debug.print("[parser] unexpected atom {s} '{s}' line {d}\n", .{ @tagName(tok.type), tok.text, tok.lineno });
                return error.UnexpectedToken;
            },
        }
    }

    fn parseExprOrStarred(self: *Parser) ParseError!*Expr {
        if (self.peekType() == .STAR) {
            const line = self.peek().lineno;
            _ = self.advance();
            const e = try self.parseExpr();
            return self.mkExpr(line, .{ .Starred = e });
        }
        return self.parseExpr();
    }

    fn parseComprehensions(self: *Parser) ParseError![]ast.Comprehension {
        var gens: std.ArrayList(ast.Comprehension) = .empty;
        while (true) {
            var is_async = false;
            if (self.peekType() == .KW_ASYNC and self.peekN(1) == .KW_FOR) {
                _ = self.advance();
                is_async = true;
            }
            _ = try self.expect(.KW_FOR);
            const target = try self.parseTargetList();
            _ = try self.expect(.KW_IN);
            const iter = try self.parseOrIter();
            var ifs: std.ArrayList(*Expr) = .empty;
            while (self.accept(.KW_IF)) |_| {
                const c = try self.parseOrIter();
                try ifs.append(self.arena.a(), c);
            }
            try gens.append(self.arena.a(), .{ .target = target, .iter = iter, .ifs = try self.dupeExprs(ifs.items), .is_async = is_async });
            if (self.peekType() == .KW_FOR or (self.peekType() == .KW_ASYNC and self.peekN(1) == .KW_FOR)) continue;
            break;
        }
        return self.arena.slice(ast.Comprehension, gens.items);
    }

    /// итератор в comprehension: or_test или (a, b) — «or_test (, or_test)*» без создания genexp
    fn parseOrIter(self: *Parser) ParseError!*Expr {
        const line = self.peek().lineno;
        const first = try self.parseOr();
        if (self.peekType() == .COMMA) {
            var items: std.ArrayList(*Expr) = .empty;
            try items.append(self.arena.a(), first);
            while (self.accept(.COMMA)) |_| {
                if (self.peekType() == .KW_FOR or self.peekType() == .RPAR or self.peekType() == .RSQB) break;
                const e = try self.parseOr();
                try items.append(self.arena.a(), e);
            }
            return self.mkExpr(line, .{ .Tuple = try self.dupeExprs(items.items) });
        }
        return first;
    }

    fn parseCallArgs(self: *Parser, args: *std.ArrayList(*Expr), keywords: *std.ArrayList(ast.Keyword)) ParseError!void {
        self.skipNL();
        if (self.peekType() == .RPAR) return;
        // genexp как единственный аргумент
        const save = self.pos;
        if (self.peekType() != .STAR and self.peekType() != .DOUBLESTAR) {
            if (self.parseExpr()) |first| {
                if (self.peekType() == .KW_FOR and !(self.peekN(1) == .RPAR)) {
                    const gens = try self.parseComprehensions();
                    const line = first.lineno;
                    const ge = try self.mkExpr(line, .{ .GeneratorExp = .{ .elt = first, .gens = gens } });
                    try args.append(self.arena.a(), ge);
                    return;
                }
                self.pos = save;
            } else |_| {
                self.pos = save;
            }
        }
        var seen_kw = false;
        while (true) {
            const tt = self.peekType();
            if (tt == .STAR) {
                _ = self.advance();
                const e = try self.parseExpr();
                try args.append(self.arena.a(), try self.mkExpr(e.lineno, .{ .Starred = e }));
            } else if (tt == .DOUBLESTAR) {
                _ = self.advance();
                const e = try self.parseExpr();
                try keywords.append(self.arena.a(), .{ .name = null, .value = e });
                seen_kw = true;
            } else if (tt == .NAME and self.peekN(1) == .EQUAL) {
                const n = try self.expect(.NAME);
                _ = try self.expect(.EQUAL);
                const v = try self.parseExpr();
                try keywords.append(self.arena.a(), .{ .name = try self.dupeStr(n.text), .value = v });
                seen_kw = true;
            } else if (tt == .NAME and self.peekN(1) == .COLONEQUAL) {
                const n = try self.expect(.NAME);
                _ = try self.expect(.COLONEQUAL);
                const v = try self.parseExpr();
                const target = try self.mkExpr(n.lineno, .{ .Name = .{ .id = try self.dupeStr(n.text), .ctx = .store } });
                try args.append(self.arena.a(), try self.mkExpr(n.lineno, .{ .NamedExpr = .{ .target = target, .value = v } }));
            } else {
                const e = try self.parseExpr();
                try args.append(self.arena.a(), e);
            }
            if (self.accept(.COMMA)) |_| {
                if (self.peekType() == .RPAR) break;
                continue;
            }
            break;
        }
    }

    fn parseLambda(self: *Parser) ParseError!*Expr {
        const line = self.peek().lineno;
        _ = try self.expect(.KW_LAMBDA);
        var args = ast.Arguments{};
        if (self.peekType() != .COLON) {
            args = try self.parseArguments();
        }
        _ = try self.expect(.COLON);
        const body = try self.parseExpr();
        return self.mkExpr(line, .{ .Lambda = .{ .args = args, .body = body } });
    }

    pub fn parseYieldExpr(self: *Parser) ParseError!*Expr {
        const line = self.peek().lineno;
        _ = try self.expect(.KW_YIELD);
        if (self.accept(.KW_FROM)) |_| {
            const e = try self.parseExpr();
            return self.mkExpr(line, .{ .YieldFrom = e });
        }
        if (self.peekType() == .NEWLINE or self.peekType() == .SEMI or self.peekType() == .RPAR or self.peekType() == .RSQB or self.atEnd() or self.peekType() == .COLON) {
            return self.mkExpr(line, .{ .Yield = null });
        }
        const v = try self.parseTestlistStarEx();
        return self.mkExpr(line, .{ .Yield = v });
    }

    // ============================================================
    // Литералы: числа, строки, f-строки
    // ============================================================

    fn numberToExpr(self: *Parser, tok: Token, line: usize) ParseError!*Expr {
        const txt = tok.text;
        // комплексные (1j) — пока не поддерживаем, но распознаем
        var is_float = false;
        var has_j = false;
        for (txt) |c| {
            if (c == '.' or c == 'e' or c == 'E') is_float = true;
            if (c == 'j' or c == 'J') has_j = true;
        }
        if (is_float and (txt[0] == '0' and txt.len > 1 and (txt[1] == 'x' or txt[1] == 'X' or txt[1] == 'o' or txt[1] == 'O' or txt[1] == 'b' or txt[1] == 'B'))) {
            is_float = false; // 0x... e-letter
        }
        if (has_j) {
            return error.SyntaxError; // complex — TODO
        }
        if (is_float) {
            const cleaned = cleanUnderscores(txt);
            const f = std.fmt.parseFloat(f64, cleaned) catch {
                return error.SyntaxError;
            };
            return self.mkExpr(line, .{ .Constant = .{ .float_ = f } });
        }
        return self.mkExpr(line, .{ .Constant = .{ .int = try self.dupeStr(txt) } });
    }

    fn cleanUnderscores(txt: []const u8) []const u8 {
        // агрессивно: без аллокации, если нет подчёркиваний
        if (std.mem.indexOfScalar(u8, txt, '_') == null) return txt;
        // нам нужно постоянное хранилище — используем статичный буфер? Нет, пусть вызывающий dupe'нет; тут статика на 128
        // — вызывается редко
        const static = struct {
            var buf: [128]u8 = undefined;
        };
        var n: usize = 0;
        for (txt) |c| {
            if (c == '_') continue;
            if (n < static.buf.len) {
                static.buf[n] = c;
                n += 1;
            }
        }
        return static.buf[0..n];
    }

    fn concatConsts(self: *Parser, a: ast.Const, b: ast.Const, line: usize) ParseError!ast.Const {
        _ = line;
        switch (a) {
            .str => |sa| switch (b) {
                .str => |sb| {
                    const buf = try self.arena.a().alloc(u8, sa.len + sb.len);
                    @memcpy(buf[0..sa.len], sa);
                    @memcpy(buf[sa.len..], sb);
                    return .{ .str = buf };
                },
                else => return error.SyntaxError,
            },
            .bytes => |ba| switch (b) {
                .bytes => |bb| {
                    const buf = try self.arena.a().alloc(u8, ba.len + bb.len);
                    @memcpy(buf[0..ba.len], ba);
                    @memcpy(buf[ba.len..], bb);
                    return .{ .bytes = buf };
                },
                else => return error.SyntaxError,
            },
            else => return error.SyntaxError,
        }
    }

    /// Декодировать STRING-токен (с префиксами) в Const.
    pub fn decodeStringToken(self: *Parser, text: []const u8) ParseError!ast.Const {
        const info = lexer.splitStringToken(text);
        const body = info.content;
        if (info.is_raw) {
            // сырая: только убрать кавычки; обратный слеш остаётся как есть.
            if (info.is_bytes) {
                return .{ .bytes = try self.dupeStr(body) };
            }
            return .{ .str = try self.dupeStr(body) };
        }
        if (info.is_bytes) {
            const decoded = try decodeEscapes(self.arena, body, true);
            return .{ .bytes = decoded };
        }
        const decoded = try decodeEscapes(self.arena, body, false);
        return .{ .str = decoded };
    }

    /// f-строка → JoinedStr / FormattedValue / Constant.
    pub fn fstringToExpr(self: *Parser, text: []const u8, line: usize) ParseError!*Expr {
        const info = lexer.splitStringToken(text);
        const body = info.content;
        var parts: std.ArrayList(*Expr) = .empty;
        var lit: std.ArrayList(u8) = .empty;
        defer lit.deinit(self.arena.a());

        var i: usize = 0;
        while (i < body.len) {
            const c = body[i];
            if (c == '{') {
                if (i + 1 < body.len and body[i + 1] == '{') {
                    try lit.append(self.arena.a(), '{');
                    i += 2;
                    continue;
                }
                // flush literal
                if (lit.items.len > 0) {
                    const decoded = try decodeEscapes(self.arena, lit.items, false);
                    try parts.append(self.arena.a(), try self.mkExpr(line, .{ .Constant = .{ .str = decoded } }));
                    lit.clearRetainingCapacity();
                }
                // найти закрывающую '}' (без учёта вложенных строк, но с балансом скобок)
                var depth: usize = 1;
                var j = i + 1;
                var conv_colon: ?usize = null; // ':' формат-спеки
                var conv_bang: ?usize = null; // '!' конверсии
                while (j < body.len) : (j += 1) {
                    const cj = body[j];
                    if (cj == '{' or cj == '(' or cj == '[') {
                        depth += 1;
                        continue;
                    }
                    if (cj == '}' or cj == ')' or cj == ']') {
                        depth -= 1;
                        if (depth == 0) break;
                        continue;
                    }
                    if (cj == '\'' or cj == '"') {
                        // пропустить строку (упрощённо: не учитываем тройные)
                        const q = cj;
                        j += 1;
                        while (j < body.len and body[j] != q) : (j += 1) {
                            if (body[j] == '\\') j += 1;
                        }
                        continue;
                    }
                    if (depth == 1 and cj == ':' and conv_colon == null and conv_bang == null) {
                        conv_colon = j;
                        continue;
                    }
                    if (depth == 1 and cj == '!' and conv_bang == null and conv_colon == null) {
                        conv_bang = j;
                        continue;
                    }
                }
                if (depth != 0) return error.SyntaxError;
                const expr_end = conv_bang orelse (conv_colon orelse j);
                const expr_src = body[i + 1 .. expr_end];
                var conv: u8 = 0;
                var spec_start: usize = j + 1;
                if (conv_bang) |cb| {
                    if (cb + 1 < j) {
                        conv = body[cb + 1];
                    }
                    if (conv_colon) |cc| spec_start = cc + 1;
                } else if (conv_colon) |cc| {
                    spec_start = cc + 1;
                }
                // парсим выражение
                const expr = try self.parseInlineExpr(expr_src, line);
                // формат-спека
                var spec_expr: ?*Expr = null;
                if (conv_bang != null or conv_colon != null) {
                    const spec_src = body[spec_start..j];
                    if (spec_src.len > 0) {
                        // спека может содержать вложенные {expr} — рекурсивно как мини-fstring
                        spec_expr = try self.formatSpecToExpr(spec_src, line);
                    } else {
                        spec_expr = try self.mkExpr(line, .{ .Constant = .{ .str = "" } });
                    }
                }
                try parts.append(self.arena.a(), try self.mkExpr(line, .{ .FormattedValue = .{ .value = expr, .conversion = conv, .spec = spec_expr } }));
                i = j + 1;
                continue;
            }
            if (c == '}') {
                if (i + 1 < body.len and body[i + 1] == '}') {
                    try lit.append(self.arena.a(), '}');
                    i += 2;
                    continue;
                }
                return error.SyntaxError;
            }
            try lit.append(self.arena.a(), c);
            i += 1;
        }
        if (lit.items.len > 0) {
            const decoded = try decodeEscapes(self.arena, lit.items, false);
            try parts.append(self.arena.a(), try self.mkExpr(line, .{ .Constant = .{ .str = decoded } }));
        }
        // если одна часть-строка → Constant
        if (parts.items.len == 1 and parts.items[0].node == .Constant) {
            return parts.items[0];
        }
        return self.mkExpr(line, .{ .JoinedStr = try self.dupeExprs(parts.items) });
    }

    fn formatSpecToExpr(self: *Parser, spec: []const u8, line: usize) ParseError!*Expr {
        var parts: std.ArrayList(*Expr) = .empty;
        var lit: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < spec.len) {
            const c = spec[i];
            if (c == '{') {
                const depth_start = i;
                _ = depth_start;
                // flush
                if (lit.items.len > 0) {
                    try parts.append(self.arena.a(), try self.mkExpr(line, .{ .Constant = .{ .str = try self.dupeStr(lit.items) } }));
                    lit.clearRetainingCapacity();
                }
                var depth: usize = 1;
                var j = i + 1;
                while (j < spec.len) : (j += 1) {
                    if (spec[j] == '{') depth += 1;
                    if (spec[j] == '}') {
                        depth -= 1;
                        if (depth == 0) break;
                    }
                }
                const inner = spec[i + 1 .. j];
                const expr = try self.parseInlineExpr(inner, line);
                try parts.append(self.arena.a(), try self.mkExpr(line, .{ .FormattedValue = .{ .value = expr, .conversion = 0, .spec = null } }));
                i = j + 1;
                continue;
            }
            try lit.append(self.arena.a(), c);
            i += 1;
        }
        if (lit.items.len > 0) {
            try parts.append(self.arena.a(), try self.mkExpr(line, .{ .Constant = .{ .str = try self.dupeStr(lit.items) } }));
        }
        if (parts.items.len == 1) return parts.items[0];
        return self.mkExpr(line, .{ .JoinedStr = try self.dupeExprs(parts.items) });
    }

    /// Распарсить выражение из строки (для f-строк).
    fn parseInlineExpr(self: *Parser, src: []const u8, line: usize) ParseError!*Expr {
        // «хак»: оборачиваем в скобки и лексируем отдельным лексером.
        // Убираем ведущие/конечные пробелы.
        const trimmed = std.mem.trim(u8, src, " \t\n\r");
        const wrapped = try std.fmt.allocPrint(self.arena.a(), "({s})", .{trimmed});
        var lex = lexer.Lexer.init(self.arena.a(), wrapped);
        var tokens: std.ArrayList(Token) = .empty;
        while (true) {
            const t = lex.nextToken() catch return error.SyntaxError;
            const end_ = t.type == .ENDMARKER;
            try tokens.append(self.arena.a(), t);
            if (end_) break;
        }
        var sub = Parser.init(self.arena, tokens.items);
        _ = try sub.expect(.LPAR);
        const e = try sub.parseExpr();
        _ = line;
        return e;
    }
};

/// Декодирование escape-последовательностей.
pub fn decodeEscapes(arena: *ast.ParserArena, body: []const u8, is_bytes: bool) ParseError![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    const a = arena.a();
    var i: usize = 0;
    while (i < body.len) {
        const c = body[i];
        if (c != '\\') {
            try out.append(a, c);
            i += 1;
            continue;
        }
        i += 1;
        if (i >= body.len) break;
        const e = body[i];
        i += 1;
        switch (e) {
            'n' => try out.append(a, '\n'),
            't' => try out.append(a, '\t'),
            'r' => try out.append(a, '\r'),
            '\\' => try out.append(a, '\\'),
            '\'' => try out.append(a, '\''),
            '"' => try out.append(a, '"'),
            '0' => try out.append(a, 0),
            'a' => try out.append(a, 7),
            'b' => try out.append(a, 8),
            'f' => try out.append(a, 12),
            'v' => try out.append(a, 11),
            '\n' => {}, // line continuation
            'x' => {
                if (i + 1 < body.len) {
                    const h = body[i .. i + 2];
                    const v = std.fmt.parseInt(u8, h, 16) catch 0;
                    if (is_bytes) {
                        try out.append(a, v);
                    } else {
                        // в str \xHH → символ с кодом HH (до FF)
                        var b: [4]u8 = undefined;
                        const n = std.unicode.utf8Encode(v, &b) catch 1;
                        try out.appendSlice(a, b[0..n]);
                    }
                    i += 2;
                }
            },
            'u' => {
                if (i + 3 < body.len) {
                    const h = body[i .. i + 4];
                    const v = std.fmt.parseInt(u21, h, 16) catch 0;
                    var b: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(v, &b) catch 1;
                    try out.appendSlice(a, b[0..n]);
                    i += 4;
                }
            },
            'U' => {
                if (i + 7 < body.len) {
                    const h = body[i .. i + 8];
                    const v = std.fmt.parseInt(u32, h, 16) catch 0;
                    const vv: u21 = @intCast(@min(v, 0x10FFFF));
                    var b: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(vv, &b) catch 1;
                    try out.appendSlice(a, b[0..n]);
                    i += 8;
                }
            },
            '1', '2', '3', '4', '5', '6', '7' => {
                var v: u32 = e - '0';
                var cnt: usize = 1;
                while (cnt < 3 and i < body.len and body[i] >= '0' and body[i] <= '7') : (cnt += 1) {
                    v = v * 8 + (body[i] - '0');
                    i += 1;
                }
                if (is_bytes) {
                    try out.append(a, @intCast(v & 0xff));
                } else {
                    var b: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(@intCast(v & 0xff), &b) catch 1;
                    try out.appendSlice(a, b[0..n]);
                }
            },
            'N' => {
                // \N{name} — не поддерживаем: пропускаем как есть
                try out.append(a, '\\');
                try out.append(a, 'N');
            },
            else => {
                // неизвестный escape — сохраняем слеш
                try out.append(a, '\\');
                try out.append(a, e);
            },
        }
    }
    return try out.toOwnedSlice(a);
}
