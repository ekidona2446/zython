//! Токенизатор Python - аналог Parser/tokenizer.c в CPython
//! Поддерживает Python 3.x лексику

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const TokenType = enum {
    ENDMARKER,
    NAME,
    NUMBER,
    STRING,
    NEWLINE,
    NL,
    INDENT,
    DEDENT,
    LPAR,
    RPAR,
    LSQB,
    RSQB,
    COLON,
    COMMA,
    SEMI,
    PLUS,
    MINUS,
    STAR,
    SLASH,
    VBAR,
    AMPER,
    LESS,
    GREATER,
    EQUAL,
    DOT,
    PERCENT,
    LBRACE,
    RBRACE,
    EQEQUAL,
    NOTEQUAL,
    LESSEQUAL,
    GREATEREQUAL,
    TILDE,
    CIRCUMFLEX,
    LEFTSHIFT,
    RIGHTSHIFT,
    DOUBLESTAR,
    PLUSEQUAL,
    MINEQUAL,
    STAREQUAL,
    SLASHEQUAL,
    PERCENTEQUAL,
    AMPEREQUAL,
    VBAREQUAL,
    CIRCUMFLEXEQUAL,
    LEFTSHIFTEQUAL,
    RIGHTSHIFTEQUAL,
    DOUBLESTAREQUAL,
    DOUBLESLASH,
    DOUBLESLASHEQUAL,
    AT,
    ATEQUAL,
    RARROW,
    ELLIPSIS,
    COLONEQUAL, // walrus :=
    OP, // generic op
    COMMENT,
    // Keywords
    FALSE,
    NONE,
    TRUE,
    AND,
    AS,
    ASSERT,
    ASYNC,
    AWAIT,
    BREAK,
    CLASS,
    CONTINUE,
    DEF,
    DEL,
    ELIF,
    ELSE,
    EXCEPT,
    FINALLY,
    FOR,
    FROM,
    GLOBAL,
    IF,
    IMPORT,
    IN,
    IS,
    LAMBDA,
    NONLOCAL,
    NOT,
    OR,
    PASS,
    RAISE,
    RETURN,
    TRY,
    WHILE,
    WITH,
    YIELD,
    ERRORTOKEN,
};

pub const Token = struct {
    type: TokenType,
    string: []const u8,
    start: Position,
    end: Position,
    line: []const u8,

    pub const Position = struct {
        lineno: usize,
        col: usize,
    };
};

pub const Lexer = struct {
    allocator: Allocator,
    source: []const u8,
    pos: usize,
    lineno: usize,
    col: usize,
    indent_stack: std.ArrayList(usize),
    pending_dedents: usize,
    at_bol: bool, // at beginning of line

    pub fn init(allocator: Allocator, source: []const u8) Lexer {
        var indents: std.ArrayList(usize) = .empty;
        indents.append(allocator, 0) catch {};
        return .{
            .allocator = allocator,
            .source = source,
            .pos = 0,
            .lineno = 1,
            .col = 0,
            .indent_stack = indents,
            .pending_dedents = 0,
            .at_bol = true,
        };
    }

    pub fn deinit(self: *Lexer) void {
        self.indent_stack.deinit(self.allocator);
    }

    fn peek(self: *Lexer) ?u8 {
        if (self.pos >= self.source.len) return null;
        return self.source[self.pos];
    }

    fn advance(self: *Lexer) ?u8 {
        if (self.pos >= self.source.len) return null;
        const c = self.source[self.pos];
        self.pos += 1;
        if (c == '\n') {
            self.lineno += 1;
            self.col = 0;
            self.at_bol = true;
        } else {
            self.col += 1;
        }
        return c;
    }

    fn skipWhitespace(self: *Lexer) void {
        while (self.peek()) |c| {
            if (c == ' ' or c == '\t' or c == '\r') {
                _ = self.advance();
            } else break;
        }
    }

pub fn nextToken(self: *Lexer) !Token {
        // Handle pending DEDENTs
        if (self.pending_dedents > 0) {
            self.pending_dedents -= 1;
            self.indent_stack.items.len -= 1;
            return Token{
                .type = .DEDENT,
                .string = "",
                .start = .{ .lineno = self.lineno, .col = self.col },
                .end = .{ .lineno = self.lineno, .col = self.col },
                .line = "",
            };
        }

        // Handle indentation at beginning of line
        if (self.at_bol) {
            var indent: usize = 0;
            var pos_tmp = self.pos;
            while (pos_tmp < self.source.len) {
                const ch = self.source[pos_tmp];
                if (ch == ' ') {
                    indent += 1;
                    pos_tmp += 1;
                } else if (ch == '\t') {
                    indent += 8; // tab = 8 spaces for simplicity
                    pos_tmp += 1;
                } else {
                    break;
                }
            }

            // Check if line is blank, comment, or only whitespace + newline
            if (pos_tmp >= self.source.len) {
                // EOF with only whitespace
                // Emit remaining DEDENTs then ENDMARKER handled below
            } else {
                const next_ch = self.source[pos_tmp];
                if (next_ch == '\n' or next_ch == '#' or next_ch == '\r') {
                    // Blank line or comment - don't emit INDENT/DEDENT, just consume whitespace and continue
                    // For comment, we will handle later, but for indent purposes ignore
                    // We advance pos to pos_tmp (skip indent whitespace) and keep at_bol true for next char?
                    // Actually for blank line, we should still handle newline as NEWLINE, not indent
                    // So we skip the indent counting and let normal flow handle newline/comment
                } else {
                    // Real content line - compare indent
                    const current_indent = self.indent_stack.getLast();
                    if (indent > current_indent) {
                        try self.indent_stack.append(self.allocator, indent);
                        // Advance pos to after indent
                        while (self.pos < pos_tmp) {
                            _ = self.advance();
                        }
                        self.at_bol = false;
                        return Token{
                            .type = .INDENT,
                            .string = "",
                            .start = .{ .lineno = self.lineno, .col = 0 },
                            .end = .{ .lineno = self.lineno, .col = indent },
                            .line = "",
                        };
                    } else if (indent < current_indent) {
                        // Pop until we find matching indent or need to error
                        var dedents: usize = 0;
                        while (self.indent_stack.items.len > 0 and self.indent_stack.getLast() > indent) {
                            _ = self.indent_stack.pop();
                            dedents += 1;
                        }
                        if (self.indent_stack.getLast() != indent) {
                            // Inconsistent dedent - Python would error, we just allow and treat as dedent to closest
                        }
                        // Advance pos to after indent
                        while (self.pos < pos_tmp) {
                            _ = self.advance();
                        }
                        self.at_bol = false;
                        if (dedents > 1) {
                            self.pending_dedents = dedents - 1;
                        }
                        return Token{
                            .type = .DEDENT,
                            .string = "",
                            .start = .{ .lineno = self.lineno, .col = indent },
                            .end = .{ .lineno = self.lineno, .col = indent },
                            .line = "",
                        };
                    } else {
                        // Same indent - just advance past indent whitespace
                        while (self.pos < pos_tmp) {
                            _ = self.advance();
                        }
                        self.at_bol = false;
                    }
                }
            }
            // If we reached here without returning INDENT/DEDENT, at_bol should be false for non-blank lines
            // For blank lines, keep at_bol true? Actually after handling blank, we want to still be at_bol for next token?
            // We'll set at_bol false only if we consumed indent and have content
            if (self.at_bol) {
                // Still at BOL (blank line case) - we will handle newline below
            }
        }

        self.skipWhitespace();

        const start_pos = Token.Position{ .lineno = self.lineno, .col = self.col };
        const start_idx = self.pos;

        const c_opt = self.peek();
        if (c_opt == null) {
            // Emit remaining DEDENTs then ENDMARKER
            if (self.indent_stack.items.len > 1) {
                self.indent_stack.items.len -= 1;
                return Token{
                    .type = .DEDENT,
                    .string = "",
                    .start = start_pos,
                    .end = start_pos,
                    .line = "",
                };
            }
            return Token{
                .type = .ENDMARKER,
                .string = "",
                .start = start_pos,
                .end = start_pos,
                .line = "",
            };
        }

        const c = c_opt.?;

        // Newline handling
        if (c == '\n') {
            _ = self.advance();
            const tok = Token{
                .type = .NEWLINE,
                .string = "\n",
                .start = start_pos,
                .end = .{ .lineno = self.lineno, .col = 0 },
                .line = self.source[start_idx..self.pos],
            };
            self.at_bol = true;
            return tok;
        }

        // Comments
        if (c == '#') {
            while (self.peek()) |ch| {
                if (ch == '\n') break;
                _ = self.advance();
            }
            return Token{
                .type = .COMMENT,
                .string = self.source[start_idx..self.pos],
                .start = start_pos,
                .end = .{ .lineno = self.lineno, .col = self.col },
                .line = "",
            };
        }

        // String literals: ' " ''' """
        if (c == '\'' or c == '"') {
            return try self.lexString();
        }

        // Numbers
        if (std.ascii.isDigit(c) or (c == '.' and self.pos + 1 < self.source.len and std.ascii.isDigit(self.source[self.pos + 1]))) {
            return try self.lexNumber();
        }

        // Names / Keywords
        if (std.ascii.isAlphabetic(c) or c == '_') {
            while (self.peek()) |ch| {
                if (std.ascii.isAlphanumeric(ch) or ch == '_') {
                    _ = self.advance();
                } else break;
            }
            const word = self.source[start_idx..self.pos];
            const tt = keywordType(word);
            return Token{
                .type = tt,
                .string = word,
                .start = start_pos,
                .end = .{ .lineno = self.lineno, .col = self.col },
                .line = word,
            };
        }

        // Operators and delimiters (упрощенно)
        _ = self.advance();
        const op_type: TokenType = switch (c) {
            '(' => .LPAR,
            ')' => .RPAR,
            '[' => .LSQB,
            ']' => .RSQB,
            '{' => .LBRACE,
            '}' => .RBRACE,
            ':' => if (self.peek() == '=') blk: {
                _ = self.advance();
                break :blk .COLONEQUAL;
            } else .COLON,
            ',' => .COMMA,
            ';' => .SEMI,
            '+' => if (self.peek() == '=') blk: {
                _ = self.advance();
                break :blk .PLUSEQUAL;
            } else .PLUS,
            '-' => if (self.peek() == '>') blk: {
                _ = self.advance();
                break :blk .RARROW;
            } else if (self.peek() == '=') blk: {
                _ = self.advance();
                break :blk .MINEQUAL;
            } else .MINUS,
            '*' => if (self.peek() == '*') blk: {
                _ = self.advance();
                if (self.peek() == '=') {
                    _ = self.advance();
                    break :blk .DOUBLESTAREQUAL;
                }
                break :blk .DOUBLESTAR;
            } else if (self.peek() == '=') blk: {
                _ = self.advance();
                break :blk .STAREQUAL;
            } else .STAR,
            '/' => if (self.peek() == '/') blk: {
                _ = self.advance();
                if (self.peek() == '=') {
                    _ = self.advance();
                    break :blk .DOUBLESLASHEQUAL;
                }
                break :blk .DOUBLESLASH;
            } else if (self.peek() == '=') blk: {
                _ = self.advance();
                break :blk .SLASHEQUAL;
            } else .SLASH,
            '|' => if (self.peek() == '=') blk: {
                _ = self.advance();
                break :blk .VBAREQUAL;
            } else .VBAR,
            '&' => if (self.peek() == '=') blk: {
                _ = self.advance();
                break :blk .AMPEREQUAL;
            } else .AMPER,
            '<' => if (self.peek() == '=') blk: {
                _ = self.advance();
                break :blk .LESSEQUAL;
            } else if (self.peek() == '<') blk: {
                _ = self.advance();
                if (self.peek() == '=') {
                    _ = self.advance();
                    break :blk .LEFTSHIFTEQUAL;
                }
                break :blk .LEFTSHIFT;
            } else .LESS,
            '>' => if (self.peek() == '=') blk: {
                _ = self.advance();
                break :blk .GREATEREQUAL;
            } else if (self.peek() == '>') blk: {
                _ = self.advance();
                if (self.peek() == '=') {
                    _ = self.advance();
                    break :blk .RIGHTSHIFTEQUAL;
                }
                break :blk .RIGHTSHIFT;
            } else .GREATER,
            '=' => if (self.peek() == '=') blk: {
                _ = self.advance();
                break :blk .EQEQUAL;
            } else .EQUAL,
            '!' => if (self.peek() == '=') blk: {
                _ = self.advance();
                break :blk .NOTEQUAL;
            } else .OP,
            '%' => if (self.peek() == '=') blk: {
                _ = self.advance();
                break :blk .PERCENTEQUAL;
            } else .PERCENT,
            '^' => if (self.peek() == '=') blk: {
                _ = self.advance();
                break :blk .CIRCUMFLEXEQUAL;
            } else .CIRCUMFLEX,
            '~' => .TILDE,
            '.' => if (self.peek() == '.' and self.pos + 1 < self.source.len and self.source[self.pos + 1] == '.') blk: {
                _ = self.advance();
                _ = self.advance();
                break :blk .ELLIPSIS;
            } else .DOT,
            '@' => if (self.peek() == '=') blk: {
                _ = self.advance();
                break :blk .ATEQUAL;
            } else .AT,
            else => .OP,
        };

        return Token{
            .type = op_type,
            .string = self.source[start_idx..self.pos],
            .start = start_pos,
            .end = .{ .lineno = self.lineno, .col = self.col },
            .line = self.source[start_idx..self.pos],
        };
    }

    fn lexNumber(self: *Lexer) !Token {
        const start_idx = self.pos;
        const start_pos = Token.Position{ .lineno = self.lineno, .col = self.col };

        while (self.peek()) |ch| {
            if (std.ascii.isDigit(ch) or ch == '_' or ch == '.') {
                _ = self.advance();
            } else if (ch == 'e' or ch == 'E') {
                _ = self.advance();
                if (self.peek() == '+' or self.peek() == '-') _ = self.advance();
            } else if (ch == 'x' or ch == 'X' or ch == 'o' or ch == 'O' or ch == 'b' or ch == 'B') {
                _ = self.advance();
            } else if (std.ascii.isAlphabetic(ch)) {
                _ = self.advance();
            } else break;
        }

        return Token{
            .type = .NUMBER,
            .string = self.source[start_idx..self.pos],
            .start = start_pos,
            .end = .{ .lineno = self.lineno, .col = self.col },
            .line = self.source[start_idx..self.pos],
        };
    }

    fn lexString(self: *Lexer) !Token {
        const start_idx = self.pos;
        const start_pos = Token.Position{ .lineno = self.lineno, .col = self.col };
        const quote = self.peek().?;

        // Check for triple quotes
        var is_triple = false;
        if (self.pos + 2 < self.source.len and
            self.source[self.pos + 1] == quote and
            self.source[self.pos + 2] == quote)
        {
            is_triple = true;
            _ = self.advance();
            _ = self.advance();
            _ = self.advance();
        } else {
            _ = self.advance();
        }

        while (self.peek()) |ch| {
            if (ch == '\\') {
                _ = self.advance(); // backslash
                if (self.peek() != null) _ = self.advance(); // escaped
                continue;
            }
            if (is_triple) {
                if (ch == quote and
                    self.pos + 2 < self.source.len and
                    self.source[self.pos + 1] == quote and
                    self.source[self.pos + 2] == quote)
                {
                    _ = self.advance();
                    _ = self.advance();
                    _ = self.advance();
                    break;
                }
            } else {
                if (ch == quote) {
                    _ = self.advance();
                    break;
                }
                if (ch == '\n') {
                    break; // unterminated
                }
            }
            _ = self.advance();
        }

        return Token{
            .type = .STRING,
            .string = self.source[start_idx..self.pos],
            .start = start_pos,
            .end = .{ .lineno = self.lineno, .col = self.col },
            .line = self.source[start_idx..self.pos],
        };
    }

    fn keywordType(word: []const u8) TokenType {
        const map = std.StaticStringMap(TokenType).initComptime(.{
            .{ "False", .FALSE },
            .{ "None", .NONE },
            .{ "True", .TRUE },
            .{ "and", .AND },
            .{ "as", .AS },
            .{ "assert", .ASSERT },
            .{ "async", .ASYNC },
            .{ "await", .AWAIT },
            .{ "break", .BREAK },
            .{ "class", .CLASS },
            .{ "continue", .CONTINUE },
            .{ "def", .DEF },
            .{ "del", .DEL },
            .{ "elif", .ELIF },
            .{ "else", .ELSE },
            .{ "except", .EXCEPT },
            .{ "finally", .FINALLY },
            .{ "for", .FOR },
            .{ "from", .FROM },
            .{ "global", .GLOBAL },
            .{ "if", .IF },
            .{ "import", .IMPORT },
            .{ "in", .IN },
            .{ "is", .IS },
            .{ "lambda", .LAMBDA },
            .{ "nonlocal", .NONLOCAL },
            .{ "not", .NOT },
            .{ "or", .OR },
            .{ "pass", .PASS },
            .{ "raise", .RAISE },
            .{ "return", .RETURN },
            .{ "try", .TRY },
            .{ "while", .WHILE },
            .{ "with", .WITH },
            .{ "yield", .YIELD },
        });
        return map.get(word) orelse .NAME;
    }
};

test "lexer basic" {
    const alloc = std.testing.allocator;
    var lex = Lexer.init(alloc, "def foo():\n    return 42\n");
    defer lex.deinit();

    const tok1 = try lex.nextToken();
    try std.testing.expect(tok1.type == .DEF);
    const tok2 = try lex.nextToken();
    try std.testing.expect(tok2.type == .NAME);
}
