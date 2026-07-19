//! Токенизатор Python — аналог Parser/tokenizer.c.
//! Полная лексика Python 3.13: INDENT/DEDENT, NL vs NEWLINE, скобочная глубина,
//! префиксы строк (r/b/f/u), f-строки склеиваются в FSTRING токен (разбор в парсере),
//! продолжение строк бэкслешем, комментарии, все операторы.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const TokenType = enum {
    ENDMARKER,
    NAME,
    NUMBER,
    STRING, // обычная/сырая/байтовая строка (конкатенация — в парсере)
    FSTRING, // f"...": префиксная часть до содержимого парсится в парсере
    NEWLINE, // конец логической строки
    NL, // новая строка внутри скобок / пустая строка — парсером игнорируется
    INDENT,
    DEDENT,
    // delimiters
    LPAR,
    RPAR,
    LSQB,
    RSQB,
    LBRACE,
    RBRACE,
    COLON,
    COMMA,
    SEMI,
    DOT,
    ELLIPSIS,
    AT,
    RARROW,
    COLONEQUAL,
    // operators
    PLUS,
    MINUS,
    STAR,
    SLASH,
    DOUBLESLASH,
    PERCENT,
    VBAR,
    AMPER,
    CIRCUMFLEX,
    TILDE,
    LESS,
    GREATER,
    EQUAL,
    DOUBLESTAR,
    EQEQUAL,
    NOTEQUAL,
    LESSEQUAL,
    GREATEREQUAL,
    LEFTSHIFT,
    RIGHTSHIFT,
    PLUSEQUAL,
    MINEQUAL,
    STAREQUAL,
    SLASHEQUAL,
    DOUBLESLASHEQUAL,
    PERCENTEQUAL,
    VBAREQUAL,
    AMPEREQUAL,
    CIRCUMFLEXEQUAL,
    LEFTSHIFTEQUAL,
    RIGHTSHIFTEQUAL,
    DOUBLESTAREQUAL,
    ATEQUAL,
    // keywords
    KW_FALSE,
    KW_NONE,
    KW_TRUE,
    KW_AND,
    KW_AS,
    KW_ASSERT,
    KW_ASYNC,
    KW_AWAIT,
    KW_BREAK,
    KW_CLASS,
    KW_CONTINUE,
    KW_DEF,
    KW_DEL,
    KW_ELIF,
    KW_ELSE,
    KW_EXCEPT,
    KW_FINALLY,
    KW_FOR,
    KW_FROM,
    KW_GLOBAL,
    KW_IF,
    KW_IMPORT,
    KW_IN,
    KW_IS,
    KW_LAMBDA,
    KW_NONLOCAL,
    KW_NOT,
    KW_OR,
    KW_PASS,
    KW_RAISE,
    KW_RETURN,
    KW_TRY,
    KW_WHILE,
    KW_WITH,
    KW_YIELD,
    ERRORTOKEN,
};

pub const Token = struct {
    type: TokenType,
    text: []const u8,
    lineno: usize,
    col: usize,
};

pub const LexError = error{
    UnterminatedString,
    UnexpectedChar,
    IndentationError,
    OutOfMemory,
};

pub const Lexer = struct {
    allocator: Allocator,
    source: []const u8,
    pos: usize = 0,
    lineno: usize = 1,
    col: usize = 0,
    indent_stack: std.ArrayList(usize),
    pending: std.ArrayList(Token), // очередь готовых токенов (INDENT/DEDENT)
    paren_depth: usize = 0,
    at_bol: bool = true,
    emitted_any_on_line: bool = false,

    pub fn init(allocator: Allocator, source: []const u8) Lexer {
        var indents: std.ArrayList(usize) = .empty;
        indents.append(allocator, 0) catch {};
        return .{
            .allocator = allocator,
            .source = source,
            .indent_stack = indents,
            .pending = .empty,
        };
    }

    pub fn deinit(self: *Lexer) void {
        self.indent_stack.deinit(self.allocator);
        self.pending.deinit(self.allocator);
    }

    fn peekAt(self: *Lexer, off: usize) ?u8 {
        if (self.pos + off >= self.source.len) return null;
        return self.source[self.pos + off];
    }
    fn peek(self: *Lexer) ?u8 {
        return self.peekAt(0);
    }
    fn advance(self: *Lexer) ?u8 {
        if (self.pos >= self.source.len) return null;
        const c = self.source[self.pos];
        self.pos += 1;
        if (c == '\n') {
            self.lineno += 1;
            self.col = 0;
        } else {
            self.col += 1;
        }
        return c;
    }

    fn mkTok(self: *Lexer, t: TokenType, text: []const u8, lineno: usize, col: usize) Token {
        _ = self;
        return .{ .type = t, .text = text, .lineno = lineno, .col = col };
    }

    pub fn nextToken(self: *Lexer) LexError!Token {
        // 0. очередь pending
        if (self.pending.items.len > 0) {
            return self.pending.orderedRemove(0);
        }

        while (true) {
            // 1. обработка начала строки (отступы) — только вне скобок
            if (self.at_bol) {
                self.at_bol = false;
                self.emitted_any_on_line = false;
                var indent: usize = 0;
                var is_blank_or_comment = false;
                var p = self.pos;
                // считаем отступ
                while (p < self.source.len) {
                    const ch = self.source[p];
                    if (ch == ' ') {
                        indent += 1;
                        p += 1;
                    } else if (ch == '\t') {
                        indent += 8 - (indent % 8);
                        p += 1;
                    } else if (ch == '\x0c') { // formfeed — сброс отступа
                        indent = 0;
                        p += 1;
                    } else break;
                }
                if (p >= self.source.len) {
                    // EOF после отступов — ниже обработаем как конец файла
                    self.pos = p;
                    return self.eofTokens();
                }
                const nc = self.source[p];
                if (nc == '\n' or nc == '\r' or nc == '#') {
                    is_blank_or_comment = true;
                }
                if (is_blank_or_comment or self.paren_depth > 0) {
                    // пропускаем строку без генерации INDENT:
                    // пустая/коммент — до конца строки (newline/NCR обработаем ниже как NL)
                    if (is_blank_or_comment) {
                        while (p < self.source.len and self.source[p] != '\n') p += 1;
                        // пропустить \n
                        const lineno = self.lineno;
                        if (p < self.source.len) {
                            self.pos = p;
                            _ = self.advance(); // \n → lineno++
                            self.at_bol = true;
                            continue;
                        }
                        self.pos = p;
                        _ = lineno;
                        return self.eofTokens();
                    }
                    // paren_depth>0: просто пропустить пробелы
                    while (self.pos < p) _ = self.advance();
                } else {
                    // контентная строка: обрабатываем INDENT/DEDENT
                    const cur = self.indent_stack.getLast();
                    while (self.pos < p) _ = self.advance();
                    if (indent > cur) {
                        try self.indent_stack.append(self.allocator, indent);
                        self.emitted_any_on_line = true;
                        return self.mkTok(.INDENT, "", self.lineno, 0);
                    } else if (indent < cur) {
                        var dedents: usize = 0;
                        while (self.indent_stack.items.len > 1 and self.indent_stack.getLast() > indent) {
                            _ = self.indent_stack.pop();
                            dedents += 1;
                        }
                        if (self.indent_stack.getLast() != indent) {
                            // Недопустимый dedent — считаем ошибкой
                            return error.IndentationError;
                        }
                        for (0..dedents - 1) |_| {
                            try self.pending.append(self.allocator, self.mkTok(.DEDENT, "", self.lineno, 0));
                        }
                        self.emitted_any_on_line = true;
                        return self.mkTok(.DEDENT, "", self.lineno, 0);
                    }
                }
            }

            // 2. пробельные символы вне BOL
            {
                const c = self.peek() orelse return self.eofTokens();
                if (c == ' ' or c == '\t' or c == '\r' or c == '\x0c') {
                    _ = self.advance();
                    continue;
                }
                if (c == '\\' and self.peekAt(1) == '\n') {
                    _ = self.advance();
                    _ = self.advance();
                    continue;
                }
                if (c == '#') {
                    while (self.peek()) |ch| {
                        if (ch == '\n') break;
                        _ = self.advance();
                    }
                    continue;
                }
                if (c == '\n') {
                    const lineno = self.lineno;
                    _ = self.advance();
                    if (self.paren_depth > 0) {
                        return self.mkTok(.NL, "\n", lineno, 0);
                    }
                    self.at_bol = true;
                    if (!self.emitted_any_on_line) {
                        continue; // пустая строка — вообще без токенов (ставим at_bol)
                    }
                    return self.mkTok(.NEWLINE, "\n", lineno, 0);
                }
                break;
            }
        }

        // 3. собственно токен
        const c = self.peek().?;
        const start_pos = self.pos;
        const start_lineno = self.lineno;
        const start_col = self.col;
        self.emitted_any_on_line = true;

        // строки и префиксы
        if (c == '\'' or c == '"' or self.isStringPrefix(c)) {
            if (self.tryLexString()) |tok| return tok;
        }

        // числа
        if (std.ascii.isDigit(c) or (c == '.' and (self.peekAt(1) != null and std.ascii.isDigit(self.peekAt(1).?)))) {
            return self.lexNumber();
        }

        // имена/ключевые слова (включая не-ASCII начала идентификаторов)
        if (std.ascii.isAlphabetic(c) or c == '_' or c >= 0x80) {
            while (self.peek()) |ch| {
                if (std.ascii.isAlphanumeric(ch) or ch == '_' or ch >= 0x80) {
                    _ = self.advance();
                } else break;
            }
            const word = self.source[start_pos..self.pos];
            return self.mkTok(keywordType(word), word, start_lineno, start_col);
        }

        // операторы
        _ = self.advance();
        const t: TokenType = switch (c) {
            '(' => blk: {
                self.paren_depth += 1;
                break :blk .LPAR;
            },
            ')' => blk: {
                if (self.paren_depth > 0) self.paren_depth -= 1;
                break :blk .RPAR;
            },
            '[' => blk: {
                self.paren_depth += 1;
                break :blk .LSQB;
            },
            ']' => blk: {
                if (self.paren_depth > 0) self.paren_depth -= 1;
                break :blk .RSQB;
            },
            '{' => blk: {
                self.paren_depth += 1;
                break :blk .LBRACE;
            },
            '}' => blk: {
                if (self.paren_depth > 0) self.paren_depth -= 1;
                break :blk .RBRACE;
            },
            ':' => if (self.eat('=')) .COLONEQUAL else .COLON,
            ',' => .COMMA,
            ';' => .SEMI,
            '+' => if (self.eat('=')) .PLUSEQUAL else .PLUS,
            '-' => if (self.eat('=')) .MINEQUAL else if (self.eat('>')) .RARROW else .MINUS,
            '*' => if (self.eat('=')) .STAREQUAL else if (self.eat('*')) (if (self.eat('=')) .DOUBLESTAREQUAL else .DOUBLESTAR) else .STAR,
            '/' => if (self.eat('=')) .SLASHEQUAL else if (self.eat('/')) (if (self.eat('=')) .DOUBLESLASHEQUAL else .DOUBLESLASH) else .SLASH,
            '%' => if (self.eat('=')) .PERCENTEQUAL else .PERCENT,
            '|' => if (self.eat('=')) .VBAREQUAL else .VBAR,
            '&' => if (self.eat('=')) .AMPEREQUAL else .AMPER,
            '^' => if (self.eat('=')) .CIRCUMFLEXEQUAL else .CIRCUMFLEX,
            '~' => .TILDE,
            '<' => if (self.eat('=')) .LESSEQUAL else if (self.eat('<')) (if (self.eat('=')) .LEFTSHIFTEQUAL else .LEFTSHIFT) else .LESS,
            '>' => if (self.eat('=')) .GREATEREQUAL else if (self.eat('>')) (if (self.eat('=')) .RIGHTSHIFTEQUAL else .RIGHTSHIFT) else .GREATER,
            '=' => if (self.eat('=')) .EQEQUAL else .EQUAL,
            '!' => if (self.eat('=')) .NOTEQUAL else return error.UnexpectedChar,
            '.' => blk: {
                if (self.peek() == '.' and self.peekAt(1) == '.') {
                    _ = self.advance();
                    _ = self.advance();
                    break :blk .ELLIPSIS;
                }
                break :blk .DOT;
            },
            '@' => if (self.eat('=')) .ATEQUAL else .AT,
            else => return error.UnexpectedChar,
        };
        return self.mkTok(t, self.source[start_pos..self.pos], start_lineno, start_col);
    }

    fn eat(self: *Lexer, c: u8) bool {
        if (self.peek() == c) {
            _ = self.advance();
            return true;
        }
        return false;
    }

    fn eofTokens(self: *Lexer) LexError!Token {
        // NEWLINE (если была незакрытая логическая строка), DEDENTs, END
        var n_dedents: usize = 0;
        if (self.indent_stack.items.len > 1) n_dedents = self.indent_stack.items.len - 1;
        const need_newline = self.emitted_any_on_line;
        self.emitted_any_on_line = false;
        var i: usize = 0;
        if (need_newline) {
            try self.pending.append(self.allocator, self.mkTok(.NEWLINE, "\n", self.lineno, 0));
        }
        while (i < n_dedents) : (i += 1) {
            _ = self.indent_stack.pop();
            try self.pending.append(self.allocator, self.mkTok(.DEDENT, "", self.lineno, 0));
        }
        // вернуть первый pending или END
        if (self.pending.items.len == 0) {
            return self.mkTok(.ENDMARKER, "", self.lineno, self.col);
        }
        return self.pending.orderedRemove(0);
    }

    fn isStringPrefix(self: *Lexer, c: u8) bool {
        // r/R/b/B/f/F/u/U + кавычка, или комбинация из двух
        if (!(c == 'r' or c == 'R' or c == 'b' or c == 'B' or c == 'f' or c == 'F' or c == 'u' or c == 'U')) return false;
        const n1 = self.peekAt(1) orelse return false;
        if (n1 == '\'' or n1 == '"') return true;
        const n2 = self.peekAt(2) orelse return false;
        const p1_ok = n1 == 'r' or n1 == 'R' or n1 == 'b' or n1 == 'B' or n1 == 'f' or n1 == 'F' or n1 == 'u' or n1 == 'U';
        if (p1_ok and (n2 == '\'' or n2 == '"')) return true;
        return false;
    }

    pub const StringInfo = struct {
        is_raw: bool,
        is_bytes: bool,
        is_fstring: bool,
        quote: u8,
        triple: bool,
        content: []const u8, // между кавычками
    };

    fn tryLexString(self: *Lexer) ?Token {
        const start = self.pos;
        const start_lineno = self.lineno;
        var is_raw = false;
        var is_bytes = false;
        var is_f = false;
        // префиксы
        while (self.peek()) |c| {
            const lc = std.ascii.toLower(c);
            if (lc == 'r' or lc == 'b' or lc == 'f' or lc == 'u') {
                if (self.peekAt(1)) |n1| {
                    const n1l = std.ascii.toLower(n1);
                    const is_quote = n1 == '\'' or n1 == '"';
                    const is_prefix2 = switch (n1l) {
                        'r', 'b', 'f' => true,
                        else => false,
                    };
                    if (is_quote or is_prefix2) {
                        switch (lc) {
                            'r' => is_raw = true,
                            'b' => is_bytes = true,
                            'f' => is_f = true,
                            else => {},
                        }
                        _ = self.advance();
                        continue;
                    }
                }
            }
            break;
        }
        const q = self.peek() orelse return null;
        if (q != '\'' and q != '"') {
            // не строка (например префиксная буква — имя)
            if (self.pos == start) return null;
            // откат: префиксы уже съедены; вернёмся назад, чтобы лексер обработал имя
            self.pos = start;
            return null;
        }
        // тройная?
        var triple = false;
        if (self.peekAt(1) == q and self.peekAt(2) == q) {
            triple = true;
            _ = self.advance();
            _ = self.advance();
            _ = self.advance();
        } else {
            _ = self.advance();
        }
        // тело
        while (self.peek()) |c| {
            if (c == '\\') {
                _ = self.advance();
                if (self.peek() != null) _ = self.advance();
                continue;
            }
            if (triple) {
                if (c == q and self.peekAt(1) == q and self.peekAt(2) == q) {
                    _ = self.advance();
                    _ = self.advance();
                    _ = self.advance();
                    break;
                }
            } else {
                if (c == q) {
                    _ = self.advance();
                    break;
                }
                if (c == '\n') {
                    break; // CPython отрапортует об ошибке позже; мы вернём незакрытый
                }
            }
            _ = self.advance();
        }
        const t: TokenType = if (is_f) .FSTRING else .STRING;
        // сохраним метаданные в тексте токена: парсер сам распарсит префиксы заново
        return self.mkTok(t, self.source[start..self.pos], start_lineno, self.col);
    }

    fn lexNumber(self: *Lexer) Token {
        const start = self.pos;
        const start_lineno = self.lineno;
        var first = true;
        while (self.peek()) |ch| {
            if (first and ch == '0') {
                _ = self.advance();
                first = false;
                if (self.peek()) |p| {
                    const pl = std.ascii.toLower(p);
                    if (pl == 'x' or pl == 'o' or pl == 'b') {
                        _ = self.advance();
                        continue;
                    }
                }
                continue;
            }
            first = false;
            if (std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '.') {
                // остановка на '..' (a..b — не бывает в Python)
                if (ch == '.' and self.peekAt(1) == '.') break;
                // 'e+5' / 'e-5' — знак экспоненты
                _ = self.advance();
                if ((ch == 'e' or ch == 'E') and self.peek() != null and (self.peek().? == '+' or self.peek().? == '-')) {
                    _ = self.advance();
                }
                continue;
            }
            break;
        }
        return self.mkTok(.NUMBER, self.source[start..self.pos], start_lineno, 0);
    }

    fn keywordType(word: []const u8) TokenType {
        const map = std.StaticStringMap(TokenType).initComptime(.{
            .{ "False", .KW_FALSE },
            .{ "None", .KW_NONE },
            .{ "True", .KW_TRUE },
            .{ "and", .KW_AND },
            .{ "as", .KW_AS },
            .{ "assert", .KW_ASSERT },
            .{ "async", .KW_ASYNC },
            .{ "await", .KW_AWAIT },
            .{ "break", .KW_BREAK },
            .{ "class", .KW_CLASS },
            .{ "continue", .KW_CONTINUE },
            .{ "def", .KW_DEF },
            .{ "del", .KW_DEL },
            .{ "elif", .KW_ELIF },
            .{ "else", .KW_ELSE },
            .{ "except", .KW_EXCEPT },
            .{ "finally", .KW_FINALLY },
            .{ "for", .KW_FOR },
            .{ "from", .KW_FROM },
            .{ "global", .KW_GLOBAL },
            .{ "if", .KW_IF },
            .{ "import", .KW_IMPORT },
            .{ "in", .KW_IN },
            .{ "is", .KW_IS },
            .{ "lambda", .KW_LAMBDA },
            .{ "nonlocal", .KW_NONLOCAL },
            .{ "not", .KW_NOT },
            .{ "or", .KW_OR },
            .{ "pass", .KW_PASS },
            .{ "raise", .KW_RAISE },
            .{ "return", .KW_RETURN },
            .{ "try", .KW_TRY },
            .{ "while", .KW_WHILE },
            .{ "with", .KW_WITH },
            .{ "yield", .KW_YIELD },
        });
        return map.get(word) orelse .NAME;
    }
};

/// Утилита: разделить токен строки на префикс и тело (для парсера/компилятора).
pub fn splitStringToken(text: []const u8) Lexer.StringInfo {
    var i: usize = 0;
    var info = Lexer.StringInfo{
        .is_raw = false,
        .is_bytes = false,
        .is_fstring = false,
        .quote = '"',
        .triple = false,
        .content = "",
    };
    while (i < text.len) {
        const lc = std.ascii.toLower(text[i]);
        switch (lc) {
            'r' => info.is_raw = true,
            'b' => info.is_bytes = true,
            'f' => info.is_fstring = true,
            'u' => {},
            else => break,
        }
        i += 1;
    }
    if (i >= text.len) return info;
    info.quote = text[i];
    if (i + 2 < text.len and text[i + 1] == info.quote and text[i + 2] == info.quote) {
        info.triple = true;
        info.content = text[i + 3 ..];
        if (info.content.len >= 3) info.content = info.content[0 .. info.content.len - 3];
    } else {
        info.content = text[i + 1 ..];
        if (info.content.len >= 1) info.content = info.content[0 .. info.content.len - 1];
    }
    return info;
}
