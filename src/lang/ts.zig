const std = @import("std");
const ir = @import("../ir.zig");

/// the TypeScript / JavaScript front-end
///
/// `tokenize` is the same lexer `src/lint.zig` has always used, moved here so
/// there is one lexer in the tree. it is deliberately token-level: biome's
/// GritQL patterns were token-shaped, so the rules that mirror them stay exact.
/// `parse` builds the structure those rules cannot see, for rules that need
/// nesting, bindings or references.
///
/// what the lexer handles, because these are the parts a naive scanner gets
/// wrong: comments, quoted strings with escapes, template literals (the text is
/// skipped, the `${}` containers are tokenised), regex literals whose `/` would
/// otherwise look like division, and JSX elements. a JSX tag is skipped, its
/// `{}` containers are tokenised, and the element name it reads is recorded in
/// `Lexed.jsx_names` instead of the token stream, because a tag name is a
/// reference an unused-declaration rule has to see and no token rule may match
///
/// what the parser does not model: types beyond their extent, decorators, and
/// anything it does not recognise. unrecognised input becomes an `.unknown`
/// node and bumps `Module.unsupported`, so a caller can tell "linted and clean"
/// from "did not understand it" and the corpus test asserts it never happens

/// identifiers and keywords are both `.word`, exactly as the token rules expect
pub const TokenKind = enum { word, number, string, template, template_end, regex, punct };

pub const Token = struct {
    text: []const u8,
    line: u32,
    kind: TokenKind,
    /// byte offsets into the source, half-open
    start: u32 = 0,
    end: u32 = 0,

    pub inline fn isWord(self: Token, text: []const u8) bool {
        return self.kind == .word and self.text.len == text.len and std.mem.eql(u8, self.text, text);
    }

    /// a one-character needle is answered from the length and the byte, which is
    /// most of the punctuation the parser asks about: `(`, `)`, `{`, `}`, `,`,
    /// `;`, `:`, `=`, `.` and `?` all take the fast path instead of a call into
    /// `std.mem.eql`
    pub inline fn isPunct(self: Token, text: []const u8) bool {
        if (self.kind != .punct) return false;
        if (text.len == 1) return self.text.len == 1 and self.text[0] == text[0];
        return std.mem.eql(u8, self.text, text);
    }

    /// a literal token, whose source text is the literal itself
    pub fn isLiteral(self: Token) bool {
        return self.kind == .number or self.kind == .string or self.kind == .regex;
    }
};

/// a source file's tokens, plus the references the lexer had to fold away
pub const Lexed = struct {
    tokens: []Token,
    /// the identifiers a JSX element name reads, in source order. a tag leaves
    /// no token, so `<Panel />` is invisible in `tokens` and this is the only
    /// record that `Panel` is live
    jsx_names: []const []const u8,
};

/// tokenise `source`, dropping the JSX reference list a caller that has no
/// unused-declaration rule to feed it does not need
pub fn tokenize(allocator: std.mem.Allocator, source: []const u8, line_out: *u32) ![]Token {
    const lexed = try tokenizeAll(allocator, source, line_out);
    allocator.free(lexed.jsx_names);
    return lexed.tokens;
}

pub fn tokenizeAll(allocator: std.mem.Allocator, source: []const u8, line_out: *u32) !Lexed {
    var lexer = Lexer{ .source = source, .allocator = allocator };
    try lex(&lexer, .end_of_input);
    line_out.* = lexer.line_number;
    const tokens = try lexer.tokens.toOwnedSlice(allocator);
    errdefer allocator.free(tokens);
    return .{ .tokens = tokens, .jsx_names = try lexer.jsx_names.toOwnedSlice(allocator) };
}

/// whether `/` starts a regex, as far as the lexer has worked it out. a word or
/// a punctuation token settles the question but only a `/` or `<` ever asks, so
/// the answer waits until then instead of being computed for every token
const RegexState = enum { allowed, disallowed, deferred };

const Lexer = struct {
    source: []const u8,
    pos: usize = 0,
    line_number: u32 = 1,
    tokens: std.ArrayList(Token) = .empty,
    /// the JSX element names a tag reads. they stay out of `tokens` so no token
    /// rule can match inside a tag, and they are slices of `source`
    jsx_names: std.ArrayList([]const u8) = .empty,
    allocator: std.mem.Allocator,
    regex_state: RegexState = .allowed,

    /// record the identifier a JSX element name reads. `<div />` names an
    /// intrinsic and an attribute name names a prop, so neither is a reference
    /// to a binding. a component name is: an uppercase name itself, or the root
    /// of a dotted name, because `<Panel.Item />` reads `Panel` and then a
    /// property of it
    fn recordJsxElementName(self: *Lexer, start: usize, end: usize) !void {
        const name = self.source[start..end];
        if (name.len == 0) return;
        const dotted = end < self.source.len and self.source[end] == '.';
        if (!dotted and !isUpperAscii(name[0])) return;
        try self.jsx_names.append(self.allocator, name);
    }

    fn push(self: *Lexer, kind: TokenKind, start: usize, end: usize, line: u32) !void {
        try self.tokens.append(self.allocator, .{
            .text = self.source[start..end],
            .line = line,
            .kind = kind,
            .start = @intCast(start),
            .end = @intCast(end),
        });
    }

    fn advanceLine(self: *Lexer) void {
        self.line_number += 1;
    }

    /// whether `/` starts a regex here. a deferred state is decided now, from the
    /// token that was pushed last, and is remembered so the walk happens once
    fn regexAllowed(self: *Lexer) bool {
        switch (self.regex_state) {
            .allowed => return true,
            .disallowed => return false,
            .deferred => {
                const allowed = !canEndExpression(self.tokens.items[self.tokens.items.len - 1].text);
                self.regex_state = if (allowed) .allowed else .disallowed;
                return allowed;
            },
        }
    }
};

const Stop = enum { end_of_input, brace_close };

/// explicit error set: lex/lexTemplate/skipJsx are mutually recursive and Zig
/// cannot infer an error set across the cycle
const LexError = error{OutOfMemory};

fn lex(lexer: *Lexer, stop: Stop) LexError!void {
    const source = lexer.source;

    while (lexer.pos < source.len) {
        const char = source[lexer.pos];

        if (char == '\n') {
            lexer.advanceLine();
            lexer.pos += 1;
            continue;
        }
        if (char == ' ' or char == '\t' or char == '\r' or char == 0x0b or char == 0x0c) {
            lexer.pos += 1;
            continue;
        }

        // comments: never part of a pattern match, and biome's grit patterns
        // cannot see inside them
        if (char == '/' and lexer.pos + 1 < source.len) {
            if (source[lexer.pos + 1] == '/') {
                lexer.pos += 2;
                while (lexer.pos < source.len and source[lexer.pos] != '\n') lexer.pos += 1;
                continue;
            }
            if (source[lexer.pos + 1] == '*') {
                lexer.pos += 2;
                while (lexer.pos + 1 < source.len and !(source[lexer.pos] == '*' and source[lexer.pos + 1] == '/')) {
                    if (source[lexer.pos] == '\n') lexer.advanceLine();
                    lexer.pos += 1;
                }
                lexer.pos = @min(lexer.pos + 2, source.len);
                continue;
            }
        }

        if (char == '\'' or char == '"') {
            const start = lexer.pos;
            const line = lexer.line_number;
            lexer.pos += 1;
            skipQuoted(lexer, char);
            try lexer.push(.string, start, lexer.pos, line);
            lexer.regex_state = .disallowed;
            continue;
        }

        if (char == '`') {
            const start = lexer.pos;
            const line = lexer.line_number;
            lexer.pos += 1;
            try lexer.push(.template, start, lexer.pos, line);
            try lexTemplate(lexer, start, line);
            continue;
        }

        if (char == '/' and lexer.regexAllowed()) {
            const start = lexer.pos;
            const line = lexer.line_number;
            lexer.pos += 1;
            skipRegex(lexer);
            try lexer.push(.regex, start, lexer.pos, line);
            lexer.regex_state = .disallowed;
            continue;
        }

        if (char == '<' and lexer.regexAllowed() and looksLikeJsx(source, lexer.pos)) {
            if (try skipJsx(lexer)) continue;
        }

        if (char == '}') {
            if (stop == .brace_close) {
                lexer.pos += 1;
                return;
            }
            try lexer.push(.punct, lexer.pos, lexer.pos + 1, lexer.line_number);
            lexer.pos += 1;
            lexer.regex_state = .disallowed;
            continue;
        }

        if (isIdentifierStart(char)) {
            const start = lexer.pos;
            const line = lexer.line_number;
            lexer.pos += 1;
            while (lexer.pos < source.len and isIdentifierContinue(source[lexer.pos])) lexer.pos += 1;
            try lexer.push(.word, start, lexer.pos, line);
            lexer.regex_state = .deferred;
            continue;
        }

        if (char >= '0' and char <= '9') {
            const start = lexer.pos;
            const line = lexer.line_number;
            lexer.pos += 1;
            while (lexer.pos < source.len and (isIdentifierContinue(source[lexer.pos]) or source[lexer.pos] == '.')) lexer.pos += 1;
            try lexer.push(.number, start, lexer.pos, line);
            lexer.regex_state = .disallowed;
            continue;
        }

        const matched = matchPunctuation(source, lexer.pos);
        try lexer.push(.punct, lexer.pos, lexer.pos + matched.len, lexer.line_number);
        lexer.pos += matched.len;
        lexer.regex_state = .deferred;
    }

    if (stop == .brace_close) {
        // unterminated expression container: nothing sensible to bind to
        return;
    }
}

/// skip a '...' or "..." literal, honouring backslash escapes
fn skipQuoted(lexer: *Lexer, quote: u8) void {
    const source = lexer.source;
    while (lexer.pos < source.len) {
        const char = source[lexer.pos];
        if (char == '\\') {
            lexer.pos += 2;
            continue;
        }
        if (char == '\n') lexer.advanceLine();
        if (char == quote) {
            lexer.pos += 1;
            return;
        }
        lexer.pos += 1;
    }
}

/// skip a regex literal, honouring escapes and [...] character classes
fn skipRegex(lexer: *Lexer) void {
    const source = lexer.source;
    var in_class = false;
    while (lexer.pos < source.len) {
        const char = source[lexer.pos];
        if (char == '\\') {
            lexer.pos += 2;
            continue;
        }
        if (char == '\n') {
            // an unterminated regex: the `/` was a division after all
            lexer.advanceLine();
            return;
        }
        if (char == '[') in_class = true;
        if (char == ']') in_class = false;
        if (char == '/' and !in_class) {
            lexer.pos += 1;
            while (lexer.pos < source.len and isIdentifierContinue(source[lexer.pos])) lexer.pos += 1;
            return;
        }
        lexer.pos += 1;
    }
}

/// tokenise the `${ ... }` containers of a template literal; the text between
/// them is skipped, exactly as grit's tree matching skips it. the closing
/// backtick becomes a `template_end` token so the parser can bound the literal
fn lexTemplate(lexer: *Lexer, start: usize, line: u32) LexError!void {
    const source = lexer.source;
    while (lexer.pos < source.len) {
        const char = source[lexer.pos];
        if (char == '\\') {
            lexer.pos += 2;
            continue;
        }
        if (char == '\n') {
            lexer.advanceLine();
            lexer.pos += 1;
            continue;
        }
        if (char == '`') {
            lexer.pos += 1;
            try lexer.push(.template_end, lexer.pos - 1, lexer.pos, lexer.line_number);
            lexer.regex_state = .disallowed;
            return;
        }
        if (char == '$' and lexer.pos + 1 < source.len and source[lexer.pos + 1] == '{') {
            lexer.pos += 2;
            lexer.regex_state = .allowed;
            try lex(lexer, .brace_close);
            continue;
        }
        lexer.pos += 1;
    }
    _ = start;
    _ = line;
}

fn looksLikeJsx(source: []const u8, pos: usize) bool {
    if (pos + 1 >= source.len) return false;
    const next = source[pos + 1];
    if (next == '>') return true;
    if (next == '/' and pos + 2 < source.len) return isIdentifierStart(source[pos + 2]);
    return isIdentifierStart(next);
}

/// skip a JSX element, tokenising only its `{ ... }` expression containers.
/// returns false when the `<` was not JSX after all, so the caller can fall back
/// to treating it as an operator
fn skipJsx(lexer: *Lexer) LexError!bool {
    const source = lexer.source;
    const start_pos = lexer.pos;
    const start_line = lexer.line_number;
    const start_tokens = lexer.tokens.items.len;
    const start_jsx_names = lexer.jsx_names.items.len;
    const start_regex_state = lexer.regex_state;
    var i = lexer.pos;
    var depth: usize = 0;
    var saw_element = false;

    while (i < source.len) {
        const char = source[i];
        if (char == '\n') {
            lexer.line_number += 1;
            i += 1;
            continue;
        }
        if (char == '<') {
            if (i + 1 >= source.len) break;
            const next = source[i + 1];
            if (next == '/') {
                // closing tag
                var j = i + 2;
                while (j < source.len and source[j] != '>') {
                    if (source[j] == '\n') lexer.line_number += 1;
                    j += 1;
                }
                if (j >= source.len) break;
                i = j + 1;
                if (depth == 0) break;
                depth -= 1;
                if (depth == 0) break;
                continue;
            }
            if (next == '>') {
                depth += 1;
                saw_element = true;
                i += 2;
                continue;
            }
            if (!isIdentifierStart(next)) break;
            saw_element = true;
            // the element name, the only part of a tag that reads a binding
            var name_end = i + 1;
            while (name_end < source.len and isIdentifierContinue(source[name_end])) name_end += 1;
            try lexer.recordJsxElementName(i + 1, name_end);
            // opening tag: skip attributes until the tag ends
            var j = i + 1;
            var self_closing = false;
            while (j < source.len) {
                const attribute_char = source[j];
                if (attribute_char == '\n') {
                    lexer.line_number += 1;
                    j += 1;
                    continue;
                }
                if (attribute_char == '"' or attribute_char == '\'') {
                    j += 1;
                    while (j < source.len and source[j] != attribute_char) {
                        if (source[j] == '\\') j += 1;
                        if (source[j] == '\n') lexer.line_number += 1;
                        j += 1;
                    }
                    j += 1;
                    continue;
                }
                if (attribute_char == '{') {
                    lexer.pos = j + 1;
                    lexer.regex_state = .allowed;
                    try lex(lexer, .brace_close);
                    j = lexer.pos;
                    continue;
                }
                if (attribute_char == '>') break;
                if (attribute_char == '/' and j + 1 < source.len and source[j + 1] == '>') {
                    self_closing = true;
                    break;
                }
                j += 1;
            }
            if (j >= source.len) break;
            if (self_closing) {
                i = j + 2;
                // a self-closing element at the top level is the whole element.
                // scanning on treats every later `<` as a sibling and skips the
                // code between them, which is how a file lost every finding past
                // its first `<Panel />`
                if (depth == 0) break;
                continue;
            }
            i = j + 1;
            depth += 1;
            continue;
        }
        if (char == '{') {
            lexer.pos = i + 1;
            lexer.regex_state = .allowed;
            try lex(lexer, .brace_close);
            i = lexer.pos;
            continue;
        }
        i += 1;
    }

    // an element that is still open at end of source was not an element: a
    // generic arrow's `<T>` reads as an opening tag, and accepting it swallows
    // every byte that follows. self-closing elements leave depth at 0, so both
    // shapes that really are JSX satisfy this
    if (!saw_element or depth != 0) {
        lexer.pos = start_pos;
        lexer.line_number = start_line;
        // a `{ ... }` container scanned before the element proved false already
        // pushed its tokens, and that container may have held a nested element,
        // so the fallback has to drop both lists back to where it started
        lexer.tokens.shrinkRetainingCapacity(start_tokens);
        lexer.jsx_names.shrinkRetainingCapacity(start_jsx_names);
        lexer.regex_state = start_regex_state;
        return false;
    }

    lexer.pos = i;
    lexer.regex_state = .disallowed;
    return true;
}

/// which bytes can start an identifier, and which can continue one, as tables.
/// the lexer asks this once per identifier byte, so the comparison chains it
/// replaces cost about twice as much in the aggregate
const identifier_bytes = struct {
    const start = init: {
        var table = [_]bool{false} ** 256;
        for ('a'..'z' + 1) |byte| table[byte] = true;
        for ('A'..'Z' + 1) |byte| table[byte] = true;
        table['_'] = true;
        table['$'] = true;
        for (0x80..256) |byte| table[byte] = true;
        break :init table;
    };

    const continue_ = init: {
        var table = start;
        for ('0'..'9' + 1) |byte| table[byte] = true;
        break :init table;
    };
};

fn isIdentifierStart(char: u8) bool {
    return identifier_bytes.start[char];
}

/// whether a byte is an ASCII capital. a JSX element name that starts with one
/// reads a binding, and a lowercase name is an intrinsic string like `div`
fn isUpperAscii(byte: u8) bool {
    return byte >= 'A' and byte <= 'Z';
}

pub fn isIdentifierContinue(char: u8) bool {
    return identifier_bytes.continue_[char];
}

/// identifiers, `this`, literals and closers end an expression, so a following
/// `/` is division rather than a regex
fn canEndExpression(text: []const u8) bool {
    if (text.len == 0) return false;
    const closers = [_][]const u8{ ")", "]", "}", "++", "--" };
    for (closers) |closer| {
        if (std.mem.eql(u8, text, closer)) return true;
    }
    if (isIdentifierStart(text[0])) {
        const keywords_that_do_not_end = [_][]const u8{ "return", "typeof", "case", "in", "of", "delete", "void", "do", "else", "instanceof", "new", "yield", "await", "throw" };
        for (keywords_that_do_not_end) |keyword| {
            if (std.mem.eql(u8, text, keyword)) return false;
        }
        return true;
    }
    if (text[0] >= '0' and text[0] <= '9') return true;
    return false;
}

/// longest match at a punctuation byte, dispatched on that byte instead of
/// scanning the whole operator table: every `)`, `,` and `;` in a file used to
/// walk ~50 `mem.eql` calls before reaching the single-char default, which was
/// two thirds of the lexer's cost (measured, 5000 files: 769ms -> 230ms)
fn matchPunctuation(source: []const u8, pos: usize) []const u8 {
    const char = source[pos];
    const rest = source[pos..];
    switch (char) {
        '=' => {
            if (std.mem.startsWith(u8, rest, "===")) return "===";
            if (std.mem.startsWith(u8, rest, "==")) return "==";
            if (std.mem.startsWith(u8, rest, "=>")) return "=>";
        },
        '!' => {
            if (std.mem.startsWith(u8, rest, "!==")) return "!==";
            if (std.mem.startsWith(u8, rest, "!=")) return "!=";
        },
        '<' => {
            if (std.mem.startsWith(u8, rest, "<<=")) return "<<=";
            if (std.mem.startsWith(u8, rest, "<<")) return "<<";
            if (std.mem.startsWith(u8, rest, "<=")) return "<=";
        },
        '>' => {
            if (std.mem.startsWith(u8, rest, ">>>=")) return ">>>=";
            if (std.mem.startsWith(u8, rest, ">>>")) return ">>>";
            if (std.mem.startsWith(u8, rest, ">>=")) return ">>=";
            if (std.mem.startsWith(u8, rest, ">>")) return ">>";
            if (std.mem.startsWith(u8, rest, ">=")) return ">=";
        },
        '&' => {
            if (std.mem.startsWith(u8, rest, "&&=")) return "&&=";
            if (std.mem.startsWith(u8, rest, "&&")) return "&&";
            if (std.mem.startsWith(u8, rest, "&=")) return "&=";
        },
        '|' => {
            if (std.mem.startsWith(u8, rest, "||=")) return "||=";
            if (std.mem.startsWith(u8, rest, "||")) return "||";
            if (std.mem.startsWith(u8, rest, "|=")) return "|=";
        },
        '?' => {
            if (std.mem.startsWith(u8, rest, "??=")) return "??=";
            if (std.mem.startsWith(u8, rest, "??")) return "??";
            if (std.mem.startsWith(u8, rest, "?.")) return "?.";
        },
        '.' => {
            if (std.mem.startsWith(u8, rest, "...")) return "...";
        },
        '+' => {
            if (std.mem.startsWith(u8, rest, "++")) return "++";
            if (std.mem.startsWith(u8, rest, "+=")) return "+=";
        },
        '-' => {
            if (std.mem.startsWith(u8, rest, "--")) return "--";
            if (std.mem.startsWith(u8, rest, "-=")) return "-=";
        },
        '*' => {
            if (std.mem.startsWith(u8, rest, "**=")) return "**=";
            if (std.mem.startsWith(u8, rest, "**")) return "**";
            if (std.mem.startsWith(u8, rest, "*=")) return "*=";
        },
        '/' => {
            if (std.mem.startsWith(u8, rest, "/=")) return "/=";
        },
        '%' => {
            if (std.mem.startsWith(u8, rest, "%=")) return "%=";
        },
        '^' => {
            if (std.mem.startsWith(u8, rest, "^=")) return "^=";
        },
        else => {},
    }
    return source[pos .. pos + 1];
}

const testing = std.testing;

test "tokenize keeps operators distinct and tracks lines" {
    const a = testing.allocator;
    var line: u32 = 1;
    const tokens = try tokenize(a, "a === b == c\nnull", &line);
    defer a.free(tokens);

    try testing.expectEqualStrings("a", tokens[0].text);
    try testing.expectEqualStrings("===", tokens[1].text);
    try testing.expectEqualStrings("==", tokens[3].text);
    try testing.expectEqual(@as(u32, 1), tokens[4].line);
    try testing.expectEqual(@as(u32, 2), tokens[5].line);
    try testing.expectEqual(@as(u32, 2), tokens[1].start);
    try testing.expectEqual(@as(u32, 5), tokens[1].end);
    try testing.expectEqual(@as(u32, 8), tokens[3].start);
    try testing.expectEqual(@as(u32, 10), tokens[3].end);
}

test "a self-closing jsx element does not swallow the rest of the file" {
    const a = testing.allocator;
    const source =
        \\const Widget = (): unknown => <Panel />;
        \\void Widget;
        \\
    ;
    var line: u32 = 1;
    const lexed = try tokenizeAll(a, source, &line);
    defer a.free(lexed.tokens);
    defer a.free(lexed.jsx_names);

    var saw_widget_reference = false;
    for (lexed.tokens) |token| {
        if (token.isWord("Widget") and token.line == 2) saw_widget_reference = true;
    }
    try testing.expect(saw_widget_reference);
    try testing.expectEqual(@as(usize, 1), lexed.jsx_names.len);
    try testing.expectEqualStrings("Panel", lexed.jsx_names[0]);
}

test "a jsx element name is recorded, an intrinsic and an attribute are not" {
    const a = testing.allocator;
    const source =
        \\const view = <div className="x"><Panel.Item title={1} /></div>;
        \\
    ;
    var line: u32 = 1;
    const lexed = try tokenizeAll(a, source, &line);
    defer a.free(lexed.tokens);
    defer a.free(lexed.jsx_names);

    try testing.expectEqual(@as(usize, 1), lexed.jsx_names.len);
    try testing.expectEqualStrings("Panel", lexed.jsx_names[0]);
}

test "a generic arrow records no jsx element name" {
    const a = testing.allocator;
    const source =
        \\const pickRandom = <T>(options: readonly T[]): T => options[0];
        \\void pickRandom;
        \\
    ;
    var line: u32 = 1;
    const lexed = try tokenizeAll(a, source, &line);
    defer a.free(lexed.tokens);
    defer a.free(lexed.jsx_names);

    try testing.expectEqual(@as(usize, 0), lexed.jsx_names.len);
    for (lexed.tokens) |token| {
        if (token.isWord("pickRandom") and token.line == 2) return;
    }
    return error.TestUnexpectedResult;
}

test "tokenize matches every operator at its longest form" {
    const a = testing.allocator;
    // the full operator set, each read on its own: a missed multi-byte match
    // splits into two tokens and an over-eager one swallows a following space
    const operators = [_][]const u8{
        ">>>=", "===", "!==", "**=", "&&=", "||=", "??=", "...", ">>>", "==",  "!=",
        "<=",   ">=",  "&&",  "||",  "??",  "?.",  "++",  "--",  "+=",  "-=",  "*=",
        "/=",   "%=",  "<<=", ">>=", "**",  "=>",  "|=",  "&=",  "^=",  "<<",  ">>",
        "(",    ")",   "{",   "}",   "[",   "]",   ";",   ",",   ":",   "?",   ".",
        "=",    "+",   "-",   "*",   "/",   "%",   "<",   ">",   "!",   "~",   "&",
        "|",    "^",   "@",   "#",
    };
    // each operator is read after an identifier, so `/` cannot be taken for the
    // start of a regex literal and `<` not for JSX: at that position the longest
    // operator is the only one that can match
    for (operators) |expected| {
        const source = try std.fmt.allocPrint(a, "x {s}", .{expected});
        defer a.free(source);

        var line: u32 = 1;
        const tokens = try tokenize(a, source, &line);
        defer a.free(tokens);

        try testing.expectEqual(@as(usize, 2), tokens.len);
        try testing.expectEqualStrings(expected, tokens[1].text);
    }
}

test "tokenize distinguishes strings, templates and regexes from code" {
    const a = testing.allocator;
    var line: u32 = 1;
    const source = "const s = \"a == b\";\nconst t = `x ${null} y`;\nconst r = /switch \\(x\\)/;\n";
    const tokens = try tokenize(a, source, &line);
    defer a.free(tokens);

    var saw_null = false;
    var saw_double_equals = false;
    var saw_switch_word = false;
    for (tokens) |token| {
        if (token.isWord("null")) saw_null = true;
        if (token.isPunct("==")) saw_double_equals = true;
        if (token.isWord("switch")) saw_switch_word = true;
    }
    try testing.expect(saw_null);
    try testing.expect(!saw_double_equals);
    try testing.expect(!saw_switch_word);
}

// ---------------------------------------------------------------------------
// parser
// ---------------------------------------------------------------------------

/// parse `source` into the IR. never fails on malformed input: constructs the
/// parser does not model become `.unknown` nodes and bump `Module.unsupported`,
/// so a caller can tell "linted and clean" from "did not understand it"
pub fn parse(allocator: std.mem.Allocator, source: []const u8) !ir.Module {
    var line: u32 = 1;
    const tokens = try tokenize(allocator, source, &line);
    defer allocator.free(tokens);
    return parseTokens(allocator, source, tokens);
}

/// build the tree from a token stream the caller already holds. `tokenize` plus
/// this is the same tree `parse` returns, for one lex instead of two: the engine
/// needs the tokens and the tree both, and re-lexing inside the parse was most
/// of what the parse cost
pub fn parseTokens(allocator: std.mem.Allocator, source: []const u8, tokens: []const Token) !ir.Module {
    var module = try ir.Module.init(allocator, source);
    errdefer module.deinit();
    module.nodes.items[module.root].span = .{ .start = 0, .end = @intCast(source.len), .line = 1 };

    var parser = Parser{ .tokens = tokens, .module = &module, .source = source };
    try parser.parseModule();
    return module;
}

/// every binary operator, told apart by length and first byte rather than by a
/// scan of a 25-entry set. the expression loop asks this of every token it meets,
/// and the set scan was the larger half of that loop's cost
fn isBinaryOperator(token: Token) bool {
    if (token.kind == .word) return token.isWord("in") or token.isWord("instanceof");
    if (token.kind != .punct) return false;

    const text = token.text;
    if (text.len == 1) {
        return switch (text[0]) {
            '|', '^', '&', '<', '>', '+', '-', '*', '/', '%' => true,
            else => false,
        };
    }
    if (text.len == 2) {
        return switch (text[0]) {
            '|' => text[1] == '|',
            '&' => text[1] == '&',
            '?' => text[1] == '?',
            '=' => text[1] == '=',
            '!' => text[1] == '=',
            '<' => text[1] == '=' or text[1] == '<',
            '>' => text[1] == '=' or text[1] == '>',
            '*' => text[1] == '*',
            else => false,
        };
    }
    if (text.len == 3) {
        return std.mem.eql(u8, text, "===") or std.mem.eql(u8, text, "!==") or std.mem.eql(u8, text, ">>>");
    }
    return false;
}

/// assignment operators all end in `=`, so that byte rejects every other
/// punctuation token in one comparison
fn isAssignmentOperator(text: []const u8) bool {
    if (text.len == 0 or text.len > 4) return false;
    if (text[text.len - 1] != '=') return false;

    if (text.len == 1) return true;
    if (text.len == 2) {
        return switch (text[0]) {
            '+', '-', '*', '/', '%', '&', '|', '^' => true,
            else => false,
        };
    }
    if (text.len == 3) {
        const pair = text[0..2];
        return std.mem.eql(u8, pair, "**") or std.mem.eql(u8, pair, "&&") or
            std.mem.eql(u8, pair, "||") or std.mem.eql(u8, pair, "??") or
            std.mem.eql(u8, pair, "<<") or std.mem.eql(u8, pair, ">>");
    }
    return std.mem.eql(u8, text, ">>>=");
}

const unary_keywords = [_][]const u8{ "typeof", "void", "delete", "await", "yield" };

const unary_punctuation = [_][]const u8{ "!", "~", "+", "-", "++", "--" };

const member_modifiers = [_][]const u8{
    "public", "private", "protected", "static", "readonly", "abstract", "declare", "override", "async", "get", "set", "accessor",
};

/// keywords that cannot be an identifier reference
/// words that never name a value or a type: the keywords and the literals. the
/// scope pass reads the same set, so a keyword can never be mistaken for a
/// reference to a binding of the same name
pub const non_reference_words = [_][]const u8{
    "true", "false", "null", "undefined", "this", "super", "typeof", "void", "delete", "await", "yield",
    "new", "in", "of", "instanceof", "as", "return", "throw", "if", "else", "for", "while", "do", "switch",
    "case", "default", "break", "continue", "try", "catch", "finally", "function", "class", "const", "let",
    "var", "import", "export", "from", "extends", "implements", "interface", "type", "enum", "namespace",
    "declare", "async", "abstract", "keyof", "infer", "satisfies", "is", "asserts",
};

/// the same set as a comptime lookup. the parser asks whether a word token is a
/// keyword about 60 times per file, and the linear scan answered with 53 length
/// comparisons every time, which measured 3.5% of a run
const non_reference_lookup = std.StaticStringMap(void).initComptime(init: {
    var entries: [non_reference_words.len]struct { []const u8 } = undefined;
    for (non_reference_words, 0..) |word, index| entries[index] = .{word};
    break :init entries;
});

/// where a type expression ends at depth 0. the two stop sets differ only in
/// `{`: in most positions a brace *starts* an object type, but after a return
/// annotation or `implements` it starts the body, so the type has to stop there.
/// an object *type* in those positions (`(): {a: number} => x`) is read as a body
/// instead, a known gap the corpus records
const TypeStop = enum { brace_starts_object, brace_starts_body };

/// how many type-parameter levels a `>`-family token closes: one for `>`, two for
/// `>>`, three for `>>>`, nothing for `>=`, `>>=`, `>>>=` and every other token.
/// a hand-rolled length test got `>>=` wrong once, so this is one function that
/// spells all six forms out
fn angleClosers(text: []const u8) usize {
    return switch (text.len) {
        1 => @intFromBool(text[0] == '>'),
        2 => if (text[0] == '>' and text[1] == '>') 2 else 0,
        3 => if (std.mem.eql(u8, text, ">>>")) 3 else 0,
        else => 0,
    };
}

/// the stop test, by first byte and length rather than a scan of a 21-entry set.
/// `skipType` asks this of every token inside a type, and it sat at the end of
/// the parse's hot loop
fn isTypeStop(stop: TypeStop, text: []const u8) bool {
    if (text.len == 0) return false;
    return switch (text[0]) {
        ',', ';', ':', '?', '+', '-', '*', '/', '%', '~', '^' => text.len == 1,
        '=' => text.len <= 3, // `=`, `=>`, `==`, `===`
        '!' => text.len <= 3, // `!`, `!=`, `!==`
        '&' => text.len == 2, // `&&`; `&` is a type operator
        '|' => text.len == 2, // `||`; `|` is a type operator
        '{' => stop == .brace_starts_body,
        else => false,
    };
}
/// punctuation a type can continue after, across a line break. `type A =`
/// followed by `| B` on the next line is one alias, not two statements
const type_continuation_punct = [_][]const u8{
    "=", "|", "&", ":", "<", ",", "(", "[", "{", "=>", "+", "-", "*", "/", "%", "^", "!", "~", "?", "...",
};

/// words a type can continue after, across a line break: `keyof`,
/// `typeof`, `extends`, and the `import("m").T` form
const type_continuation_words = [_][]const u8{
    "keyof", "typeof", "extends", "infer", "readonly", "in", "out", "is", "as", "asserts", "satisfies", "new", "import",
};

const Parser = struct {
    tokens: []const Token,
    module: *ir.Module,
    source: []const u8,
    pos: usize = 0,

    inline fn peek(self: *const Parser) ?Token {
        if (self.pos >= self.tokens.len) return null;
        return self.tokens[self.pos];
    }

    inline fn atEnd(self: *const Parser) bool {
        return self.pos >= self.tokens.len;
    }

    inline fn atWord(self: *const Parser, text: []const u8) bool {
        const token = self.peek() orelse return false;
        return token.isWord(text);
    }

    fn peekAt(self: *const Parser, offset: usize) ?Token {
        const index = self.pos + offset;
        if (index >= self.tokens.len) return null;
        return self.tokens[index];
    }

    inline fn atPunct(self: *const Parser, text: []const u8) bool {
        const token = self.peek() orelse return false;
        return token.isPunct(text);
    }

    fn advance(self: *Parser) Token {
        const token = self.tokens[self.pos];
        self.pos += 1;
        return token;
    }

    fn begin(self: *const Parser) usize {
        return self.pos;
    }

    fn spanSince(self: *const Parser, from: usize) ir.Span {
        if (from < self.pos) {
            const first = self.tokens[from];
            const last = self.tokens[self.pos - 1];
            return .{ .start = first.start, .end = last.end, .line = first.line };
        }
        const empty_start: u32 = if (self.pos < self.tokens.len) self.tokens[self.pos].start else @intCast(self.source.len);
        const empty_line: u32 = if (self.pos < self.tokens.len) self.tokens[self.pos].line else 1;
        return .{ .start = empty_start, .end = empty_start, .line = empty_line };
    }

    fn addNode(self: *Parser, kind: ir.Kind, from: usize) !ir.NodeIndex {
        return self.module.add(kind, self.spanSince(from));
    }

    /// re-span a node once its tail is known
    fn closeNode(self: *Parser, index: ir.NodeIndex, from: usize) void {
        self.module.nodes.items[index].span = self.spanSince(from);
    }

    fn skipSemis(self: *Parser) void {
        while (!self.atEnd() and self.atPunct(";")) self.pos += 1;
    }

    /// consume one token as an unmodelled construct
    fn parseUnknown(self: *Parser) !ir.NodeIndex {
        self.module.unsupported += 1;
        const from = self.begin();
        if (!self.atEnd()) self.pos += 1;
        return self.addNode(.unknown, from);
    }

    fn parseModule(self: *Parser) !void {
        while (!self.atEnd()) {
            self.skipSemis();
            if (self.atEnd()) return;
            const statement = try self.parseStatement();
            self.module.appendChild(self.module.root, statement);
        }
    }

    fn parseStatement(self: *Parser) anyerror!ir.NodeIndex {
        const token = self.peek() orelse return self.parseUnknown();

        if (token.isPunct("{")) return self.parseBlock();
        if (token.isPunct("@")) {
            // a decorator is not modelled: consume it whole so the code after it
            // is still parsed, and mark the file unsupported
            const from = self.begin();
            self.module.unsupported += 1;
            self.pos += 1;
            if (!self.atEnd()) _ = try self.parsePostfix();
            return self.addNode(.unknown, from);
        }

        if (token.kind == .word) {
            if (statement_handlers.get(token.text)) |handler| return handler(self);
        }
        return self.parseExpressionStatement();
    }

    fn parseExpressionStatement(self: *Parser) !ir.NodeIndex {
        const from = self.begin();
        const expression = try self.parseExpression();
        const statement = try self.addNode(.expression_stmt, from);
        self.module.appendChild(statement, expression);
        if (self.atPunct(";")) self.pos += 1;
        // the terminator belongs to the statement, and a span that stops before
        // it leaves the last byte of the file uncovered
        self.closeNode(statement, from);
        return statement;
    }

    fn parseBlock(self: *Parser) !ir.NodeIndex {
        const from = self.begin();
        const block = try self.addNode(.block, from);
        if (self.atPunct("{")) self.pos += 1;
        while (!self.atEnd() and !self.atPunct("}")) {
            self.skipSemis();
            if (self.atEnd() or self.atPunct("}")) break;
            const statement = try self.parseStatement();
            self.module.appendChild(block, statement);
        }
        if (self.atPunct("}")) self.pos += 1;
        self.closeNode(block, from);
        return block;
    }

    // -----------------------------------------------------------------------
    // declarations

    fn parseImport(self: *Parser) !ir.NodeIndex {
        const from = self.begin();
        self.pos += 1; // import

        const node = try self.addNode(.import_decl, from);
        if (self.atPunct("(")) {
            // a dynamic import in statement position is just an expression
            self.pos = from;
            return self.parseExpressionStatement();
        }

        while (!self.atEnd()) {
            const token = self.peek().?;
            if (token.kind == .punct) {
                if (token.isPunct("{")) {
                    self.pos += 1;
                    // `{ a, b as c, type d }`: the first name of each clause
                    // names the module's export and the name after `as` is the
                    // local binding, so only the binding is a declaration.
                    // `,` and `as` both open a new clause
                    var expect_binding = true;
                    while (!self.atEnd() and !self.atPunct("}")) {
                        const clause = self.peek().?;
                        if (clause.isPunct(",")) {
                            expect_binding = true;
                            self.pos += 1;
                            continue;
                        }
                        if (clause.isWord("type")) {
                            self.pos += 1;
                            continue;
                        }
                        const next = self.peekAt(1);
                        const aliased = next != null and next.?.isWord("as");
                        if (clause.kind == .word and !clause.isWord("as") and expect_binding and !aliased) {
                            const binding = try self.addNode(.identifier, self.begin());
                            self.module.nodes.items[binding].name = clause.text;
                            self.module.nodes.items[binding].binding = .import_binding;
                            self.module.appendChild(node, binding);
                        }
                        if (clause.isWord("as")) expect_binding = true else expect_binding = false;
                        self.pos += 1;
                    }
                    if (self.atPunct("}")) self.pos += 1;
                    continue;
                }
                if (token.isPunct("*")) {
                    self.pos += 1;
                    continue;
                }
                if (token.isPunct(";")) {
                    self.pos += 1;
                    break;
                }
                self.pos += 1;
                continue;
            }
            if (token.kind == .string) {
                self.module.nodes.items[node].name = stripQuotes(token.text);
                self.pos += 1;
                break;
            }
            if (token.kind == .word and token.isWord("from")) {
                self.pos += 1;
                continue;
            }
            if (token.kind == .word and (token.isWord("type") or token.isWord("as"))) {
                self.pos += 1;
                continue;
            }
            if (token.kind == .word) {
                const binding = try self.addNode(.identifier, self.begin());
                self.module.nodes.items[binding].name = token.text;
                self.module.nodes.items[binding].binding = .import_binding;
                self.module.appendChild(node, binding);
                self.pos += 1;
                continue;
            }
            self.pos += 1;
        }
        self.closeNode(node, from);
        return node;
    }

    fn parseExport(self: *Parser) !ir.NodeIndex {
        const from = self.begin();
        self.pos += 1; // export

        // `export type ...` is type-only: it enforces nothing
        if (self.atWord("type")) {
            const next = if (self.pos + 1 < self.tokens.len) self.tokens[self.pos + 1] else null;
            if (next != null and (next.?.isPunct("{") or next.?.isPunct("*") or next.?.kind == .word)) {
                if (next.?.isPunct("{") or next.?.isPunct("*")) return self.parseTypeDeclaration();
            }
        }

        // `export { a, b } from "m"` and `export * from "m"`
        if (self.atPunct("{") or self.atPunct("*")) {
            const names_start = self.pos;
            if (self.atPunct("{")) {
                try self.skipBalanced("{", "}");
            } else {
                self.pos += 1;
            }
            if (self.atWord("from")) {
                self.pos += 1;
                const reexport = try self.addNode(.reexport, from);
                _ = names_start;
                if (!self.atEnd() and self.peek().?.kind == .string) {
                    self.module.nodes.items[reexport].name = stripQuotes(self.peek().?.text);
                    self.pos += 1;
                }
                if (self.atPunct(";")) self.pos += 1;
                self.closeNode(reexport, from);
                return reexport;
            }
            // a local `export { a }`: names only, no module
            if (self.atPunct(";")) self.pos += 1;
            const wrapper = try self.addNode(.export_decl, from);
            self.closeNode(wrapper, from);
            return wrapper;
        }

        if (self.atWord("default")) self.pos += 1;

        const wrapper = try self.addNode(.export_decl, from);
        if (self.atEnd()) {
            self.closeNode(wrapper, from);
            return wrapper;
        }
        // `export default { ... }` is an object literal, not a block: reading it
        // as a block turns every method in it into a statement
        if (self.atPunct("{")) {
            const value = try self.parseExpression();
            self.module.appendChild(wrapper, value);
            if (self.atPunct(";")) self.pos += 1;
            self.closeNode(wrapper, from);
            return wrapper;
        }
        const declaration = try self.parseStatement();
        self.module.appendChild(wrapper, declaration);
        self.closeNode(wrapper, from);
        return wrapper;
    }

    fn parseConst(self: *Parser) !ir.NodeIndex {
        return self.parseVariableDeclaration(.@"const", true);
    }

    fn parseLet(self: *Parser) !ir.NodeIndex {
        return self.parseVariableDeclaration(.@"let", true);
    }

    fn parseVar(self: *Parser) !ir.NodeIndex {
        return self.parseVariableDeclaration(.@"var", true);
    }

    fn parseVariableDeclaration(self: *Parser, declaration_kind: ir.DeclKind, consume_semicolon: bool) !ir.NodeIndex {
        const from = self.begin();
        const keyword = self.advance();
        const node = try self.addNode(.variable_decl, from);
        self.module.nodes.items[node].decl_kind = declaration_kind;
        self.module.nodes.items[node].operator = keyword.text;

        while (!self.atEnd()) {
            try self.parseBindingTarget(node);
            if (self.atPunct(":")) {
                self.pos += 1;
                self.skipType(.brace_starts_object);
            }
            if (self.atPunct("=")) {
                const value_from = self.begin();
                self.pos += 1;
                const value = try self.parseExpression();
                self.module.appendChild(node, value);
                _ = value_from;
            }
            if (self.atPunct(",")) {
                self.pos += 1;
                continue;
            }
            break;
        }

        if (consume_semicolon and self.atPunct(";")) self.pos += 1;
        self.closeNode(node, from);
        return node;
    }

    /// a binding target: an identifier, or a `{ }` / `[ ]` pattern whose bound
    /// names become identifier children
    fn parseBindingTarget(self: *Parser, parent: ir.NodeIndex) !void {
        if (self.atEnd()) return;
        const token = self.peek().?;

        if (token.kind == .word) {
            const binding = try self.addNode(.identifier, self.begin());
            self.module.nodes.items[binding].name = token.text;
            self.module.nodes.items[binding].binding = .variable;
            self.module.appendChild(parent, binding);
            self.pos += 1;
            return;
        }

        if (token.isPunct("{") or token.isPunct("[")) {
            const pattern_from = self.begin();
            const opener = token.text;
            const closer: []const u8 = if (opener[0] == '{') "}" else "]";
            const pattern = try self.addNode(.literal, self.begin());
            self.module.appendChild(parent, pattern);

            self.pos += 1;
            var depth: usize = 1;
            var previous_was_key = false;
            while (!self.atEnd() and depth > 0) {
                const current = self.peek().?;
                if (current.kind == .punct and std.mem.eql(u8, current.text, opener)) depth += 1;
                if (current.kind == .punct and std.mem.eql(u8, current.text, closer)) {
                    depth -= 1;
                    if (depth == 0) {
                        self.pos += 1;
                        break;
                    }
                }
                if (current.kind == .word) {
                    const next = if (self.pos + 1 < self.tokens.len) self.tokens[self.pos + 1] else null;
                    const is_key = next != null and next.?.isPunct(":");
                    if (!is_key and !previous_was_key and !isNonReference(current.text)) {
                        const binding = try self.addNode(.identifier, self.begin());
                        self.module.nodes.items[binding].name = current.text;
                        self.module.nodes.items[binding].binding = .variable;
                        self.module.appendChild(pattern, binding);
                    }
                    previous_was_key = is_key;
                } else {
                    previous_was_key = false;
                }
                self.pos += 1;
            }
            self.closeNode(pattern, pattern_from);
            return;
        }

        self.pos += 1;
    }

    fn parseFunctionDeclaration(self: *Parser) !ir.NodeIndex {
        const from = self.begin();
        if (self.atWord("abstract")) self.pos += 1;
        if (self.atWord("async")) self.pos += 1;
        const node = try self.addNode(.function_decl, from);
        if (self.atWord("function")) {
            self.pos += 1;
            if (self.atPunct("*")) self.pos += 1;
            if (!self.atEnd() and self.peek().?.kind == .word) {
                self.module.nodes.items[node].name = self.peek().?.text;
                self.pos += 1;
            }
        }
        if (self.atPunct("<")) self.skipType(.brace_starts_object);
        try self.parseParameterList(node);
        if (self.atPunct(":")) {
            self.pos += 1;
            self.skipType(.brace_starts_body);
        }
        if (self.atPunct("{")) {
            const body = try self.parseBlock();
            self.module.appendChild(node, body);
        } else if (self.atPunct(";")) {
            self.pos += 1;
        }
        self.closeNode(node, from);
        return node;
    }

    /// `( a, b = 1, ...rest )`: bindings become identifier children, default
    /// values are parsed so their references count
    ///
    /// a `name:` here is an annotation, not an object key, unless the parameter
    /// is itself a destructuring pattern: `(value: number)` binds `value`, and
    /// `({ value: local })` binds the name after the colon. the brace depth is
    /// what tells them apart
    fn parseParameterList(self: *Parser, parent: ir.NodeIndex) !void {
        if (!self.atPunct("(")) return;
        self.pos += 1;
        var depth: usize = 1;
        var brace_depth: usize = 0;
        while (!self.atEnd() and depth > 0) {
            if (self.atPunct("(")) depth += 1;
            if (self.atPunct(")")) {
                depth -= 1;
                if (depth == 0) {
                    self.pos += 1;
                    return;
                }
            }
            if (self.atPunct("{")) brace_depth += 1;
            if (self.atPunct("}")) {
                if (brace_depth > 0) brace_depth -= 1;
            }
            const token = self.peek().?;
            if (token.isPunct(":") or token.isPunct("=")) {
                const is_default = token.isPunct("=");
                self.pos += 1;
                if (is_default) {
                    const value = try self.parseExpression();
                    self.module.appendChild(parent, value);
                } else {
                    self.skipType(.brace_starts_object);
                }
                continue;
            }
            if (token.kind == .word) {
                const next = if (self.pos + 1 < self.tokens.len) self.tokens[self.pos + 1] else null;
                const is_key = brace_depth > 0 and next != null and next.?.isPunct(":");
                if (!is_key and !isNonReference(token.text)) {
                    const binding = try self.addNode(.identifier, self.begin());
                    self.module.nodes.items[binding].name = token.text;
                    self.module.nodes.items[binding].binding = .parameter;
                    self.module.appendChild(parent, binding);
                }
            }
            self.pos += 1;
        }
    }

    fn parseClassDeclaration(self: *Parser) !ir.NodeIndex {
        const from = self.begin();
        if (self.atWord("abstract") or self.atWord("declare")) self.pos += 1;
        const node = try self.addNode(.class_decl, from);
        if (self.atWord("class")) {
            self.pos += 1;
            if (!self.atEnd() and (self.peek().?).kind == .word) {
                self.module.nodes.items[node].name = (self.peek().?).text;
                self.pos += 1;
            }
        }
        if (self.atPunct("<")) self.skipType(.brace_starts_object);
        if (self.atWord("extends")) {
            self.pos += 1;
            const base = try self.parseExpression();
            self.module.appendChild(node, base);
        }
        if (self.atWord("implements")) {
            self.pos += 1;
            self.skipType(.brace_starts_body);
        }
        if (self.atPunct("{")) try self.parseClassBody(node);
        self.closeNode(node, from);
        return node;
    }

    fn parseClassBody(self: *Parser, parent: ir.NodeIndex) !void {
        self.pos += 1; // {
        while (!self.atEnd() and !self.atPunct("}")) {
            if (self.atPunct(";")) {
                self.pos += 1;
                continue;
            }
            const from = self.begin();
            while (!self.atEnd() and self.peek().?.kind == .word and isModifier(self.peek().?.text)) self.pos += 1;
            while (!self.atEnd() and self.peek().?.isPunct("*")) self.pos += 1;

            if (self.atEnd() or self.atPunct("}")) break;

            if (self.atPunct("[")) {
                self.pos += 1;
                const computed = try self.parseExpression();
                self.module.appendChild(parent, computed);
                if (self.atPunct("]")) self.pos += 1;
            } else if (self.peek().?.kind == .word or (self.peek().?).isLiteral()) {
                self.pos += 1;
            } else {
                _ = try self.parseUnknown();
                continue;
            }

            if (self.atPunct("?")) self.pos += 1;
            if (self.atPunct("<")) self.skipType(.brace_starts_object);

            if (self.atPunct("(")) {
                const member = try self.addNode(.function_decl, from);
                self.module.appendChild(parent, member);
                try self.parseParameterList(member);
                if (self.atPunct(":")) {
                    self.pos += 1;
                    self.skipType(.brace_starts_body);
                }
                if (self.atPunct("{")) {
                    const body = try self.parseBlock();
                    self.module.appendChild(member, body);
                }
                self.closeNode(member, from);
                continue;
            }

            if (self.atPunct(":")) {
                self.pos += 1;
                self.skipType(.brace_starts_object);
            }
            if (self.atPunct("=")) {
                self.pos += 1;
                const value = try self.parseExpression();
                self.module.appendChild(parent, value);
            }
            if (self.atPunct(";")) self.pos += 1;
        }
        if (self.atPunct("}")) self.pos += 1;
    }

    fn parseTypeDeclaration(self: *Parser) !ir.NodeIndex {
        const from = self.begin();
        const node = try self.addNode(.type_decl, from);
        // the span runs to the end of the declaration: the matching brace for a
        // block body, the `;` otherwise
        if (self.atWord("declare")) self.pos += 1;
        // `type X = ...` is an alias: its `{ ... }` is a type rather than a
        // body, so the declaration runs to the `;` (or to the statement that
        // follows it) instead of stopping at the first balanced brace
        const is_alias = self.atWord("type");
        if (!self.atEnd()) self.pos += 1;
        var depth: usize = 0;
        while (!self.atEnd()) {
            const token = self.peek().?;
            if (depth == 0 and is_alias and endsTypeAlias(self.tokens[self.pos - 1], token)) break;
            if (token.kind == .punct) {
                if (token.isPunct("{") or token.isPunct("(") or token.isPunct("[")) depth += 1;
                if (token.isPunct("}") or token.isPunct(")") or token.isPunct("]")) {
                    if (depth == 0) break;
                    depth -= 1;
                    if (depth == 0 and token.isPunct("}") and !is_alias) {
                        self.pos += 1;
                        break;
                    }
                }
                if (token.isPunct(";") and depth == 0) {
                    self.pos += 1;
                    break;
                }
            }
            self.pos += 1;
        }
        self.closeNode(node, from);
        return node;
    }

    fn parseAsyncDeclaration(self: *Parser) !ir.NodeIndex {
        const next = if (self.pos + 1 < self.tokens.len) self.tokens[self.pos + 1] else null;
        if (next != null and next.?.isWord("function")) {
            self.pos += 1;
            return self.parseFunctionDeclaration();
        }
        return self.parseExpressionStatement();
    }

const Handler = *const fn (*Parser) anyerror!ir.NodeIndex;

/// one handler per statement keyword. a dispatch table rather than a switch, so
/// the set of statements the parser understands is readable in one place
const statement_handlers = std.StaticStringMap(Handler).initComptime(.{
    .{ "import", parseImport },
    .{ "export", parseExport },
    .{ "const", parseConst },
    .{ "let", parseLet },
    .{ "var", parseVar },
    .{ "function", parseFunctionDeclaration },
    .{ "class", parseClassDeclaration },
    .{ "abstract", parseClassDeclaration },
    .{ "if", parseIf },
    .{ "for", parseFor },
    .{ "while", parseWhile },
    .{ "do", parseDoWhile },
    .{ "switch", parseSwitch },
    .{ "try", parseTry },
    .{ "return", parseReturn },
    .{ "throw", parseThrow },
    .{ "break", parseBreakOrContinue },
    .{ "continue", parseBreakOrContinue },
    .{ "interface", parseTypeDeclaration },
    .{ "type", parseTypeDeclaration },
    .{ "enum", parseTypeDeclaration },
    .{ "namespace", parseTypeDeclaration },
    .{ "declare", parseTypeDeclaration },
    .{ "async", parseAsyncDeclaration },
});


    fn parseIf(self: *Parser) !ir.NodeIndex {
        const from = self.begin();
        self.pos += 1;
        const node = try self.addNode(.if_stmt, from);

        if (self.atPunct("(")) {
            self.pos += 1;
            const condition = try self.parseExpression();
            self.module.appendChild(node, condition);
            if (self.atPunct(")")) self.pos += 1;
        }
        const then_branch = try self.parseStatement();
        self.module.appendChild(node, then_branch);

        if (self.atWord("else")) {
            self.pos += 1;
            const else_branch = try self.parseStatement();
            self.module.appendChild(node, else_branch);
        }
        self.closeNode(node, from);
        return node;
    }

    fn parseWhile(self: *Parser) !ir.NodeIndex {
        const from = self.begin();
        self.pos += 1;
        const node = try self.addNode(.while_stmt, from);
        if (self.atPunct("(")) {
            self.pos += 1;
            const condition = try self.parseExpression();
            self.module.appendChild(node, condition);
            if (self.atPunct(")")) self.pos += 1;
        }
        const body = try self.parseStatement();
        self.module.appendChild(node, body);
        self.closeNode(node, from);
        return node;
    }

    fn parseDoWhile(self: *Parser) !ir.NodeIndex {
        const from = self.begin();
        self.pos += 1;
        const node = try self.addNode(.while_stmt, from);
        const body = try self.parseStatement();
        self.module.appendChild(node, body);
        if (self.atWord("while")) {
            self.pos += 1;
            if (self.atPunct("(")) {
                self.pos += 1;
                const condition = try self.parseExpression();
                self.module.appendChild(node, condition);
                if (self.atPunct(")")) self.pos += 1;
            }
        }
        if (self.atPunct(";")) self.pos += 1;
        self.closeNode(node, from);
        return node;
    }

    fn parseFor(self: *Parser) !ir.NodeIndex {
        const from = self.begin();
        self.pos += 1;
        if (self.atWord("await")) self.pos += 1;
        const node = try self.addNode(.for_stmt, from);

        if (self.atPunct("(")) {
            self.pos += 1;

            if (self.atWord("const") or self.atWord("let") or self.atWord("var")) {
                const declaration_kind = ir.DeclKind.fromKeyword(self.peek().?.text);
                const declaration = try self.parseVariableDeclaration(declaration_kind, false);
                self.module.appendChild(node, declaration);
            } else if (!self.atPunct(";")) {
                const initializer = try self.parseExpression();
                self.module.appendChild(node, initializer);
            }

            if (self.atPunct(";")) {
                self.module.nodes.items[node].operator = ";";
                self.pos += 1;
                if (!self.atPunct(";")) {
                    const condition = try self.parseExpression();
                    self.module.appendChild(node, condition);
                }
                if (self.atPunct(";")) self.pos += 1;
                if (!self.atPunct(")")) {
                    const update = try self.parseExpression();
                    self.module.appendChild(node, update);
                }
            } else if (self.atWord("of") or self.atWord("in")) {
                self.module.nodes.items[node].operator = self.peek().?.text;
                self.pos += 1;
                const iterable = try self.parseExpression();
                self.module.appendChild(node, iterable);
            }
            if (self.atPunct(")")) self.pos += 1;
        }

        const body = try self.parseStatement();
        self.module.appendChild(node, body);
        self.closeNode(node, from);
        return node;
    }

    fn parseSwitch(self: *Parser) !ir.NodeIndex {
        const from = self.begin();
        self.pos += 1;
        const node = try self.addNode(.switch_stmt, from);

        if (self.atPunct("(")) {
            self.pos += 1;
            const discriminant = try self.parseExpression();
            self.module.appendChild(node, discriminant);
            if (self.atPunct(")")) self.pos += 1;
        }
        if (self.atPunct("{")) {
            self.pos += 1;
            while (!self.atEnd() and !self.atPunct("}")) {
                if (self.atWord("case") or self.atWord("default")) {
                    const clause_from = self.begin();
                    const is_default = self.atWord("default");
                    self.pos += 1;
                    const clause = try self.addNode(.case_clause, clause_from);
                    if (!is_default) {
                        const case_value = try self.parseExpression();
                        self.module.appendChild(clause, case_value);
                    }
                    if (self.atPunct(":")) self.pos += 1;
                    while (!self.atEnd() and !self.atPunct("}") and !self.atWord("case") and !self.atWord("default")) {
                        const statement = try self.parseStatement();
                        self.module.appendChild(clause, statement);
                    }
                    self.closeNode(clause, clause_from);
                    self.module.appendChild(node, clause);
                    continue;
                }
                _ = try self.parseUnknown();
            }
            if (self.atPunct("}")) self.pos += 1;
        }
        self.closeNode(node, from);
        return node;
    }

    fn parseTry(self: *Parser) !ir.NodeIndex {
        const from = self.begin();
        self.pos += 1;
        const node = try self.addNode(.try_stmt, from);

        const body = try self.parseBlock();
        self.module.appendChild(node, body);

        while (self.atWord("catch") or self.atWord("finally")) {
            const clause_from = self.begin();
            const is_catch = self.atWord("catch");
            self.pos += 1;
            const clause = try self.addNode(if (is_catch) .catch_clause else .block, clause_from);
            self.module.appendChild(node, clause);
            if (is_catch and self.atPunct("(")) {
                self.pos += 1;
                try self.parseBindingTarget(clause);
                if (self.atPunct(":")) {
                    self.pos += 1;
                    self.skipType(.brace_starts_object);
                }
                if (self.atPunct(")")) self.pos += 1;
            }
            const clause_body = try self.parseBlock();
            self.module.appendChild(clause, clause_body);
            self.closeNode(clause, clause_from);
        }
        self.closeNode(node, from);
        return node;
    }

    fn parseReturn(self: *Parser) !ir.NodeIndex {
        const from = self.begin();
        self.pos += 1;
        const node = try self.addNode(.return_stmt, from);
        if (!self.atEnd() and !self.atPunct(";") and !self.atPunct("}")) {
            const value = try self.parseExpression();
            self.module.appendChild(node, value);
        }
        if (self.atPunct(";")) self.pos += 1;
        self.closeNode(node, from);
        return node;
    }

    fn parseThrow(self: *Parser) !ir.NodeIndex {
        const from = self.begin();
        self.pos += 1;
        const node = try self.addNode(.throw_stmt, from);
        if (!self.atEnd() and !self.atPunct(";") and !self.atPunct("}")) {
            const value = try self.parseExpression();
            self.module.appendChild(node, value);
        }
        if (self.atPunct(";")) self.pos += 1;
        self.closeNode(node, from);
        return node;
    }

    fn parseBreakOrContinue(self: *Parser) !ir.NodeIndex {
        const from = self.begin();
        const is_break = self.atWord("break");
        self.pos += 1;
        const node = try self.addNode(if (is_break) .break_stmt else .continue_stmt, from);
        if (!self.atEnd() and (self.peek().?).kind == .word and !(self.peek().?).isWord("case")) self.pos += 1;
        if (self.atPunct(";")) self.pos += 1;
        self.closeNode(node, from);
        return node;
    }

    // -----------------------------------------------------------------------
    // expressions

    fn parseExpression(self: *Parser) anyerror!ir.NodeIndex {
        return self.parseAssignment();
    }

    fn parseAssignment(self: *Parser) anyerror!ir.NodeIndex {
        const from = self.begin();
        const target = try self.parseBinary();

        // `cond ? when_true : when_false`. the alternative is parsed as an
        // assignment so a nested conditional and an arrow body both work
        if (self.atPunct("?")) {
            self.pos += 1;
            const node = try self.addNode(.conditional, from);
            self.module.appendChild(node, target);
            const when_true = try self.parseAssignment();
            self.module.appendChild(node, when_true);
            if (self.atPunct(":")) self.pos += 1;
            const when_false = try self.parseAssignment();
            self.module.appendChild(node, when_false);
            self.closeNode(node, from);
            return node;
        }

        const token = self.peek() orelse return target;
        if (token.kind != .punct or !isAssignmentOperator(token.text)) return target;

        self.pos += 1;
        const node = try self.addNode(.assignment, from);
        self.module.nodes.items[node].operator = token.text;
        self.module.appendChild(node, target);
        const value = try self.parseAssignment();
        self.module.appendChild(node, value);
        self.closeNode(node, from);
        return node;
    }

    fn parseBinary(self: *Parser) anyerror!ir.NodeIndex {
        var left = try self.parsePostfix();

        while (!self.atEnd()) {
            const token = self.peek().?;
            const is_operator = isBinaryOperator(token);
            const is_cast = token.isWord("as");
            if (!is_operator and !is_cast) break;

            const from = if (self.pos > 0) self.pos - 1 else 0;
            self.pos += 1;

            if (is_cast) {
                const cast = try self.addNode(.as_expr, from);
                const type_from = self.begin();
                self.skipType(.brace_starts_object);
                if (type_from < self.pos) {
                    const slice = self.tokens[type_from..self.pos];
                    self.module.nodes.items[cast].name = self.source[slice[0].start..slice[slice.len - 1].end];
                }
                self.module.nodes.items[cast].operator = "as";
                self.module.appendChild(cast, left);
                self.closeNode(cast, from);
                left = cast;
                continue;
            }

            const node = try self.addNode(.binary, from);
            self.module.nodes.items[node].operator = token.text;
            self.module.appendChild(node, left);
            const right = try self.parsePostfix();
            self.module.appendChild(node, right);
            self.closeNode(node, from);
            left = node;
        }
        return left;
    }

    fn parsePostfix(self: *Parser) anyerror!ir.NodeIndex {
        var expression = try self.parsePrimary();

        while (!self.atEnd()) {
            const token = self.peek().?;

            if (token.isPunct(".") or token.isPunct("?.")) {
                const from = if (self.pos > 0) self.pos - 1 else 0;
                self.pos += 1;
                if (self.atEnd() or (self.peek().?).kind != .word) continue;
                const name = self.peek().?.text;
                self.pos += 1;
                const member = try self.addNode(.member, from);
                self.module.nodes.items[member].name = name;
                self.module.appendChild(member, expression);
                self.closeNode(member, from);
                expression = member;
                continue;
            }

            if (token.isPunct("(")) {
                const from = if (self.pos > 0) self.pos - 1 else 0;
                self.pos += 1;
                const call = try self.addNode(.call, from);
                self.module.appendChild(call, expression);
                // parseExpression consumes every bracketed group it meets, so
                // this loop must not track depth itself: counting the `(` of an
                // argument like `(a, b) => c` reads the call's own `)` as if it
                // were nested, and the tail ends up unknown
                while (!self.atEnd() and !self.atPunct(")")) {
                    if (self.atPunct(",")) {
                        self.pos += 1;
                        continue;
                    }
                    const argument_start = self.pos;
                    const argument = try self.parseExpression();
                    self.module.appendChild(call, argument);
                    if (self.pos == argument_start) self.pos += 1;
                }
                if (self.atPunct(")")) self.pos += 1;
                self.closeNode(call, from);
                expression = call;
                continue;
            }

            if (token.isPunct("[")) {
                const from = if (self.pos > 0) self.pos - 1 else 0;
                self.pos += 1;
                const index = try self.addNode(.member, from);
                self.module.appendChild(index, expression);
                if (!self.atPunct("]")) {
                    const key = try self.parseExpression();
                    self.module.appendChild(index, key);
                }
                if (self.atPunct("]")) self.pos += 1;
                self.closeNode(index, from);
                expression = index;
                continue;
            }

            // `!` non-null assertion and `++` / `--` postfix
            if (token.isPunct("!") or token.isPunct("++") or token.isPunct("--")) {
                self.pos += 1;
                continue;
            }

            // `f<T>(x)` generic call and `new Map<string, T>()`: the type
            // arguments are not part of the value
            if (token.isPunct("<")) {
                if (self.matchingAngle(self.pos)) |close_index| {
                    const after = if (close_index + 1 < self.tokens.len) self.tokens[close_index + 1] else null;
                    const is_type_arguments = after != null and
                        (after.?.isPunct("(") or after.?.isPunct(".") or after.?.isPunct("?.") or after.?.isPunct("["));
                    if (is_type_arguments) {
                        self.pos = close_index + 1;
                        continue;
                    }
                }
                break;
            }
            break;
        }
        return expression;
    }

    fn parsePrimary(self: *Parser) anyerror!ir.NodeIndex {
        const from = self.begin();
        const token = self.peek() orelse return self.parseUnknown();

        if (token.isLiteral()) {
            self.pos += 1;
            const node = try self.addNode(.literal, from);
            self.module.nodes.items[node].operator = token.text;
            return node;
        }

        if (token.kind == .template) {
            self.pos += 1;
            const node = try self.addNode(.template, from);
            while (!self.atEnd() and !self.atPunct("`")) {
                if ((self.peek().?).kind == .template_end) {
                    self.pos += 1;
                    break;
                }
                const expression = try self.parseExpression();
                self.module.appendChild(node, expression);
                if (self.pos == from + 1) self.pos += 1;
            }
            self.closeNode(node, from);
            return node;
        }

        if (token.isPunct("(")) {
            return self.parseParenOrArrow();
        }

        if (token.isPunct("[")) {
            self.pos += 1;
            const node = try self.addNode(.array_literal, from);
            while (!self.atEnd() and !self.atPunct("]")) {
                if (self.atPunct(",")) {
                    self.pos += 1;
                    continue;
                }
                const element = try self.parseExpression();
                self.module.appendChild(node, element);
            }
            if (self.atPunct("]")) self.pos += 1;
            self.closeNode(node, from);
            return node;
        }

        // `...value` in an array, a call argument or a binding pattern
        if (token.isPunct("...")) {
            self.pos += 1;
            const node = try self.addNode(.spread, from);
            const operand = try self.parseAssignment();
            self.module.appendChild(node, operand);
            self.closeNode(node, from);
            return node;
        }

        if (token.isPunct("{")) {
            return self.parseObjectLiteral();
        }

        if (token.isPunct("<")) {
            // `<T>(x: T): T => x` is a generic arrow function, not a type
            // assertion: the type parameter list is followed by a parameter
            // list whose paren group ends in `=>`
            if (self.matchingAngle(self.pos)) |angle_close| {
                const after_angle = if (angle_close + 1 < self.tokens.len) self.tokens[angle_close + 1] else null;
                if (after_angle != null and after_angle.?.isPunct("(")) {
                    if (self.matchingParen(angle_close + 1)) |params_close| {
                        const after_params = if (params_close + 1 < self.tokens.len) self.tokens[params_close + 1] else null;
                        const is_arrow = after_params != null and (after_params.?.isPunct("=>") or
                            (after_params.?.isPunct(":") and self.hasArrowAfter(params_close + 1)));
                        if (is_arrow) {
                            self.pos = angle_close + 1;
                            return self.parseArrow(from, true);
                        }
                    }
                }
            }

            // a type assertion `<T>value`
            self.pos += 1;
            self.skipType(.brace_starts_object);
            const operand = try self.parsePostfix();
            const node = try self.addNode(.as_expr, from);
            self.module.nodes.items[node].operator = "asserts";
            self.module.appendChild(node, operand);
            self.closeNode(node, from);
            return node;
        }

        if (token.kind == .punct and contains(&unary_punctuation, token.text)) {
            self.pos += 1;
            const node = try self.addNode(.unary, from);
            self.module.nodes.items[node].operator = token.text;
            const operand = try self.parsePostfix();
            self.module.appendChild(node, operand);
            self.closeNode(node, from);
            return node;
        }

        if (token.kind == .word) {
            if (contains(&unary_keywords, token.text) or token.isWord("new")) {
                self.pos += 1;
                const node = try self.addNode(.unary, from);
                self.module.nodes.items[node].operator = token.text;
                const operand = try self.parsePostfix();
                self.module.appendChild(node, operand);
                self.closeNode(node, from);
                return node;
            }

            if (token.isWord("function") or (token.isWord("async") and self.peekAt(1) != null and self.peekAt(1).?.isWord("function"))) {
                // `async function` is the same expression, the modifier is
                // consumed so the name lands on the node
                if (token.isWord("async")) self.pos += 1;
                self.pos += 1;
                const node = try self.addNode(.function_expr, from);
                if (self.atPunct("*")) self.pos += 1;
                if (!self.atEnd() and (self.peek().?).kind == .word) self.pos += 1;
                if (self.atPunct("<")) self.skipType(.brace_starts_object);
                try self.parseParameterList(node);
                if (self.atPunct(":")) {
                    self.pos += 1;
                    self.skipType(.brace_starts_body);
                }
                if (self.atPunct("{")) {
                    const body = try self.parseBlock();
                    self.module.appendChild(node, body);
                }
                self.closeNode(node, from);
                return node;
            }

            if (token.isWord("class")) {
                return self.parseClassDeclaration();
            }

            if (token.isWord("import")) {
                // a dynamic `import(...)`
                self.pos += 1;
                const node = try self.addNode(.call, from);
                if (self.atPunct("(")) self.pos += 1;
                if (!self.atEnd() and (self.peek().?).kind == .string) self.pos += 1;
                if (self.atPunct(")")) self.pos += 1;
                self.closeNode(node, from);
                return node;
            }

            // `async (a: T): U => body` and `async a => body` are arrows whose
            // parameter list the normal path cannot see: `async` reads as an
            // identifier followed by a call
            if (token.isWord("async")) {
                const next = self.peekAt(1);
                if (next != null and next.?.kind == .word and
                    self.peekAt(2) != null and self.peekAt(2).?.isPunct("=>"))
                {
                    self.pos += 1;
                    return self.parseArrow(from, false);
                }
                if (next != null and next.?.isPunct("(")) {
                    if (self.matchingParen(self.pos + 1)) |close_index| {
                        const after = if (close_index + 1 < self.tokens.len) self.tokens[close_index + 1] else null;
                        const is_arrow = after != null and (after.?.isPunct("=>") or
                            (after.?.isPunct(":") and self.hasArrowAfter(close_index + 1)));
                        if (is_arrow) {
                            self.pos += 1;
                            return self.parseArrow(from, true);
                        }
                    }
                }
                // `async <T>(x: T) => x`: the type parameters come first
                if (next != null and next.?.isPunct("<")) {
                    if (self.matchingAngle(self.pos + 1)) |angle_close| {
                        const after_angle = if (angle_close + 1 < self.tokens.len) self.tokens[angle_close + 1] else null;
                        if (after_angle != null and after_angle.?.isPunct("(")) {
                            if (self.matchingParen(angle_close + 1)) |params_close| {
                                const after_params = if (params_close + 1 < self.tokens.len) self.tokens[params_close + 1] else null;
                                const is_arrow = after_params != null and (after_params.?.isPunct("=>") or
                                    (after_params.?.isPunct(":") and self.hasArrowAfter(params_close + 1)));
                                if (is_arrow) {
                                    self.pos = angle_close + 1;
                                    return self.parseArrow(from, true);
                                }
                            }
                        }
                    }
                }
            }

            // a single-parameter arrow: `x => ...`
            if (self.pos + 1 < self.tokens.len and self.tokens[self.pos + 1].isPunct("=>")) {
                return self.parseArrow(from, false);
            }

            if (isNonReference(token.text)) {
                self.pos += 1;
                const node = try self.addNode(.literal, from);
                self.module.nodes.items[node].operator = token.text;
                return node;
            }

            self.pos += 1;
            const identifier = try self.addNode(.identifier, from);
            self.module.nodes.items[identifier].name = token.text;
            return identifier;
        }

        return self.parseUnknown();
    }

    /// `( ... )` is either an arrow function's parameter list or a grouping
    fn parseParenOrArrow(self: *Parser) anyerror!ir.NodeIndex {
        const from = self.begin();
        const close = self.matchingParen(self.pos);

        if (close) |close_index| {
            const after = if (close_index + 1 < self.tokens.len) self.tokens[close_index + 1] else null;
            const is_arrow = after != null and (after.?.isPunct("=>") or
                (after.?.isPunct(":") and self.hasArrowAfter(close_index + 1)));
            if (is_arrow) return self.parseArrow(from, true);
        }

        self.pos += 1;
        const node = try self.addNode(.paren, from);
        while (!self.atEnd() and !self.atPunct(")")) {
            if (self.atPunct(",")) {
                self.pos += 1;
                continue;
            }
            const inner = try self.parseExpression();
            self.module.appendChild(node, inner);
        }
        if (self.atPunct(")")) self.pos += 1;
        self.closeNode(node, from);
        return node;
    }

    /// a `)` at `open_index` that closes the list opened at `self.pos`
    fn matchingParen(self: *const Parser, open_index: usize) ?usize {
        var depth: usize = 0;
        var index = open_index;
        while (index < self.tokens.len) : (index += 1) {
            const token = self.tokens[index];
            if (token.kind != .punct or token.text.len != 1) continue;
            switch (token.text[0]) {
                '(' => depth += 1,
                ')' => {
                    depth -= 1;
                    if (depth == 0) return index;
                },
                else => {},
            }
        }
        return null;
    }

    /// the `>` that closes a type argument list opened at `open_index`, or null
    /// when the `<` is a comparison instead. only punctuation a type argument
    /// list can contain is accepted, so `a < b && c > (d)` cannot look like a
    /// generic call; `>>` and `>>>` close two and three levels, which is how
    /// nested generics tokenise
    fn matchingAngle(self: *const Parser, open_index: usize) ?usize {
        const type_argument_punctuation = [_][]const u8{
            ",", ".", "?.", "[", "]", "(", ")", "{", "}", "?", ":", "|", "&", "=>", "...",
        };
        var depth: usize = 0;
        var index = open_index;
        while (index < self.tokens.len) : (index += 1) {
            const token = self.tokens[index];
            if (token.kind == .word or token.isLiteral()) continue;
            if (token.kind != .punct) return null;
            if (token.isPunct("<")) {
                depth += 1;
                continue;
            }
            const closes = angleClosers(token.text);
            if (closes > 0) {
                if (depth <= closes) return index;
                depth -= closes;
                continue;
            }
            if (!contains(&type_argument_punctuation, token.text)) return null;
        }
        return null;
    }

    /// whether a `=>` follows a return-type annotation starting at `index`
    fn hasArrowAfter(self: *const Parser, index: usize) bool {
        var depth: usize = 0;
        var cursor = index;
        while (cursor < self.tokens.len) : (cursor += 1) {
            const token = self.tokens[cursor];
            if (token.kind == .punct) {
                const text = token.text;
                if (text.len == 1) {
                    switch (text[0]) {
                        '(', '[', '{' => {
                            depth += 1;
                            continue;
                        },
                        ')', ']', '}' => {
                            if (depth == 0) return false;
                            depth -= 1;
                            continue;
                        },
                        ';', '=' => {
                            if (depth == 0) return false;
                            continue;
                        },
                        else => {},
                    }
                } else if (depth == 0 and text.len == 2 and text[0] == '=' and text[1] == '>') {
                    return true;
                }
            }
            if (token.kind == .word and depth == 0 and token.isWord("as")) return false;
        }
        return false;
    }

    fn parseArrow(self: *Parser, from: usize, parenthesised: bool) anyerror!ir.NodeIndex {
        const node = try self.addNode(.arrow, from);

        if (parenthesised) {
            try self.parseParameterList(node);
        } else {
            const parameter = self.addNode(.identifier, self.begin()) catch return error.OutOfMemory;
            self.module.nodes.items[parameter].name = self.peek().?.text;
            self.module.nodes.items[parameter].binding = .parameter;
            self.module.appendChild(node, parameter);
            self.pos += 1;
        }

        if (self.atPunct(":")) {
            self.pos += 1;
            self.skipType(.brace_starts_object);
        }
        if (self.atPunct("=>")) self.pos += 1;

        if (self.atPunct("{")) {
            const body = try self.parseBlock();
            self.module.appendChild(node, body);
        } else if (!self.atEnd()) {
            const body = try self.parseExpression();
            self.module.appendChild(node, body);
        }
        self.closeNode(node, from);
        return node;
    }

    fn parseObjectLiteral(self: *Parser) anyerror!ir.NodeIndex {
        const from = self.begin();
        self.pos += 1;
        const node = try self.addNode(.object_literal, from);

        while (!self.atEnd() and !self.atPunct("}")) {
            if (self.atPunct(",")) {
                self.pos += 1;
                continue;
            }
            if (self.atPunct("...")) {
                self.pos += 1;
                const spread = try self.addNode(.spread, self.begin());
                const value = try self.parseExpression();
                self.module.appendChild(spread, value);
                self.module.appendChild(node, spread);
                continue;
            }

            const property_from = self.begin();

            // `async run() {}` / `get x() {}` / `*gen() {}`: the modifier is not
            // the key. `{ get() {} }`, a method with that name, keeps its name
            if (self.peek().?.kind == .word and
                (self.peek().?.isWord("get") or self.peek().?.isWord("set") or self.peek().?.isWord("async")))
            {
                const next = self.peekAt(1);
                const leads_a_member = next != null and
                    (next.?.kind == .word or next.?.isLiteral() or next.?.isPunct("[") or next.?.isPunct("*"));
                if (leads_a_member) {
                    self.pos += 1;
                    continue;
                }
            }
            if (self.atPunct("*")) {
                self.pos += 1;
                continue;
            }

            const key = self.peek().?;

            // `[expr]: value`
            if (key.isPunct("[")) {
                self.pos += 1;
                const computed = try self.parseExpression();
                self.module.appendChild(node, computed);
                if (self.atPunct("]")) self.pos += 1;
                if (self.atPunct(":")) {
                    self.pos += 1;
                    const value = try self.parseExpression();
                    self.module.appendChild(node, value);
                }
                continue;
            }

            if (key.kind == .word) {
                const next = self.peekAt(1);
                const is_method = next != null and next.?.isPunct("(");
                self.pos += 1;
                if (is_method) {
                    const method = try self.addNode(.function_expr, property_from);
                    self.module.appendChild(node, method);
                    try self.parseParameterList(method);
                    if (self.atPunct(":")) {
                        self.pos += 1;
                        self.skipType(.brace_starts_body);
                    }
                    if (self.atPunct("{")) {
                        const body = try self.parseBlock();
                        self.module.appendChild(method, body);
                    }
                    self.closeNode(method, property_from);
                    continue;
                }
                if (self.atPunct(":")) {
                    self.pos += 1;
                    const value = try self.parseExpression();
                    self.module.appendChild(node, value);
                    continue;
                }
                if (self.atPunct("=")) {
                    // a destructuring default inside an object pattern
                    self.pos += 1;
                    const value = try self.parseExpression();
                    self.module.appendChild(node, value);
                    continue;
                }
                continue;
            }

            if (key.isLiteral()) {
                self.pos += 1;
                if (self.atPunct(":")) {
                    self.pos += 1;
                    const value = try self.parseExpression();
                    self.module.appendChild(node, value);
                    continue;
                }
                continue;
            }

            _ = try self.parseUnknown();
        }

        if (self.atPunct("}")) self.pos += 1;
        self.closeNode(node, from);
        return node;
    }

    // -----------------------------------------------------------------------
    // types

    /// consume a type expression, stopping at a terminator at nesting depth 0.
    /// types are not modelled: their extent is all a rule needs
    fn skipType(self: *Parser, stop: TypeStop) void {
        var depth: usize = 0;
        while (!self.atEnd()) {
            const token = self.peek().?;
            if (token.kind == .punct) {
                const text = token.text;
                // at depth 0 a terminator has to be tested before the brackets:
                // `{` is both an object type and the body that follows a return
                // annotation, and reading the body as a type swallows the block
                if (depth == 0 and isTypeStop(stop, text)) return;

                if (text.len == 1 and (text[0] == '(' or text[0] == '[' or text[0] == '{' or text[0] == '<')) {
                    depth += 1;
                    self.pos += 1;
                    continue;
                }
                if (text.len == 1 and (text[0] == ')' or text[0] == ']' or text[0] == '}')) {
                    if (depth == 0) return;
                    depth -= 1;
                    self.pos += 1;
                    continue;
                }
                // `>` closes one level and `>>` / `>>>` two and three: nested
                // generics like `Promise<Outcome<X, Y[]>>` arrive as one token,
                // and closing one level leaves the `=>` that follows inside the
                // type, which then swallows the arrow's body
                const closes = angleClosers(text);
                if (closes > 0) {
                    if (depth < closes) return;
                    depth -= closes;
                    self.pos += 1;
                    continue;
                }
            }
            if (depth == 0 and token.kind == .word and token.isWord("as")) return;
            self.pos += 1;
        }
    }

    /// whether `next` begins a new statement rather than continuing a type
    /// alias that had no trailing `;`. an operator at the end of the previous
    /// line (`=`, `|`, `&`, ..., or `keyof`-style words) keeps the alias open
    fn endsTypeAlias(previous: Token, next: Token) bool {
        if (next.line == previous.line) return false;
        if (next.kind != .word) return false;
        if (!statement_handlers.has(next.text)) return false;
        if (previous.kind == .punct) return !contains(&type_continuation_punct, previous.text);
        return !contains(&type_continuation_words, previous.text);
    }

    /// `{` / `[` at `self.pos`, skipping to just past the matching closer
    fn skipBalanced(self: *Parser, opener: []const u8, closer: []const u8) !void {
        if (!self.atPunct(opener)) return;
        var depth: usize = 0;
        while (!self.atEnd()) {
            const token = self.peek().?;
            if (token.isPunct(opener)) depth += 1;
            if (token.isPunct(closer)) {
                depth -= 1;
                if (depth == 0) {
                    self.pos += 1;
                    return;
                }
            }
            self.pos += 1;
        }
    }
};

fn stripQuotes(text: []const u8) []const u8 {
    if (text.len < 2) return text;
    return text[1 .. text.len - 1];
}

fn isModifier(text: []const u8) bool {
    return contains(&member_modifiers, text);
}

fn isNonReference(text: []const u8) bool {
    return non_reference_lookup.has(text);
}

/// membership in a small literal set. the length and the first byte are compared
/// inline, so only a candidate that can still match pays for `std.mem.eql`: a
/// word token used to walk all 53 of `non_reference_words` through that call
inline fn contains(set: []const []const u8, text: []const u8) bool {
    for (set) |candidate| {
        if (candidate.len != text.len) continue;
        if (text.len != 0 and candidate[0] != text[0]) continue;
        if (std.mem.eql(u8, candidate, text)) return true;
    }
    return false;
}

test "parse models declarations, blocks and references" {
    const a = testing.allocator;
    const source =
        \\import { helper } from "./lib/helper";
        \\const total: number = helper(1);
        \\export function run(items: Item[]): number {
        \\  let sum = 0;
        \\  for (const item of items) {
        \\    sum += item.value;
        \\  }
        \\  return sum;
        \\}
        \\
    ;
    var module = try parse(a, source);
    defer module.deinit();

    try testing.expectEqual(@as(u32, 0), module.unsupported);
    try testing.expectEqual(@as(usize, 0), module.unknownCount());

    var imports: usize = 0;
    var declarations: usize = 0;
    var assignments: usize = 0;
    var identifiers: usize = 0;
    var walker = module.iterator();
    while (walker.next()) |index| {
        switch (module.kindOf(index)) {
            .import_decl => imports += 1,
            .variable_decl => declarations += 1,
            .assignment => assignments += 1,
            .identifier => identifiers += 1,
            else => {},
        }
    }
    try testing.expectEqual(@as(usize, 1), imports);
    try testing.expectEqual(@as(usize, 3), declarations);
    try testing.expectEqual(@as(usize, 1), assignments);
    try testing.expect(identifiers > 3);

    // the import keeps its module specifier and its binding
    var walker_again = module.iterator();
    while (walker_again.next()) |index| {
        if (module.kindOf(index) != .import_decl) continue;
        try testing.expectEqualStrings("./lib/helper", module.nodeOf(index).name);
        const binding = module.firstChildOf(index).?;
        try testing.expectEqualStrings("helper", module.nodeOf(binding).name);
    }
}

test "parse nests statements so unreachable code is visible" {
    const a = testing.allocator;
    const source =
        \\export const run = (): number => {
        \\  return 1;
        \\  return 2;
        \\};
        \\
    ;
    var module = try parse(a, source);
    defer module.deinit();

    try testing.expectEqual(@as(usize, 0), module.unknownCount());

    // the arrow body holds two return statements, in order
    var body: ?ir.NodeIndex = null;
    var walker = module.iterator();
    while (walker.next()) |index| {
        if (module.kindOf(index) != .block) continue;
        body = index;
        break;
    }
    try testing.expect(body != null);

    var returns: usize = 0;
    var child = module.firstChildOf(body.?);
    while (child) |current| : (child = module.nextSiblingOf(current)) {
        if (module.kindOf(current) == .return_stmt) returns += 1;
    }
    try testing.expectEqual(@as(usize, 2), returns);
}

test "parse sees literals in conditions and as-casts with their type" {
    const a = testing.allocator;
    const source =
        \\export const run = (value: unknown): number => {
        \\  if (true) {
        \\    return value as number;
        \\  }
        \\  return 0;
        \\};
        \\
    ;
    var module = try parse(a, source);
    defer module.deinit();

    try testing.expectEqual(@as(usize, 0), module.unknownCount());

    var saw_literal_condition = false;
    var saw_cast = false;
    var walker = module.iterator();
    while (walker.next()) |index| {
        if (module.kindOf(index) == .if_stmt) {
            const condition = module.firstChildOf(index).?;
            if (module.kindOf(condition) == .literal) saw_literal_condition = true;
        }
        if (module.kindOf(index) == .as_expr) {
            if (std.mem.eql(u8, module.nodeOf(index).name, "number")) saw_cast = true;
        }
    }
    try testing.expect(saw_literal_condition);
    try testing.expect(saw_cast);
}

test "parse keeps a function body that follows a return annotation" {
    const a = testing.allocator;
    const source =
        \\function total(): number { return 1; }
        \\
    ;
    var module = try parse(a, source);
    defer module.deinit();

    try testing.expectEqual(@as(usize, 0), module.unknownCount());

    // the annotation must not read the body as part of the type: one function
    // whose only child is the block, holding the return statement
    var function_index: ?ir.NodeIndex = null;
    var walker = module.iterator();
    while (walker.next()) |index| {
        if (module.kindOf(index) == .function_decl) function_index = index;
    }
    try testing.expect(function_index != null);
    const body = module.firstChildOf(function_index.?);
    try testing.expect(body != null);
    try testing.expectEqual(ir.Kind.block, module.kindOf(body.?));
    const statement = module.firstChildOf(body.?);
    try testing.expect(statement != null);
    try testing.expectEqual(ir.Kind.return_stmt, module.kindOf(statement.?));
}

test "parse ends a semicolon-less type alias at the next statement" {
    const a = testing.allocator;
    const source =
        \\type Bag = {
        \\  size: number;
        \\}
        \\export const empty: Bag = { size: 0 };
        \\
    ;
    var module = try parse(a, source);
    defer module.deinit();

    try testing.expectEqual(@as(usize, 0), module.unknownCount());

    // the alias owns the object type and stops there: the export is its own
    // declaration, not a continuation of the type
    var aliases: usize = 0;
    var declarations: usize = 0;
    var walker = module.iterator();
    while (walker.next()) |index| {
        switch (module.kindOf(index)) {
            .type_decl => aliases += 1,
            .variable_decl => declarations += 1,
            else => {},
        }
    }
    try testing.expectEqual(@as(usize, 1), aliases);
    try testing.expectEqual(@as(usize, 1), declarations);
}

test "parse models ternaries, spreads and generic calls" {
    const a = testing.allocator;
    const source =
        \\const label = ok ? "yes" : "no";
        \\const all = [...first, ...rest];
        \\const index = new Map<string, number>();
        \\
    ;
    var module = try parse(a, source);
    defer module.deinit();

    try testing.expectEqual(@as(usize, 0), module.unknownCount());

    var optionals: usize = 0;
    var spreads: usize = 0;
    var calls: usize = 0;
    var walker = module.iterator();
    while (walker.next()) |index| {
        switch (module.kindOf(index)) {
            .conditional => optionals += 1,
            .spread => spreads += 1,
            .call => calls += 1,
            else => {},
        }
    }
    try testing.expectEqual(@as(usize, 1), optionals);
    try testing.expectEqual(@as(usize, 2), spreads);
    try testing.expectEqual(@as(usize, 1), calls);

    // the conditional keeps all three operands, in order
    var walker_again = module.iterator();
    while (walker_again.next()) |index| {
        if (module.kindOf(index) != .conditional) continue;
        try testing.expectEqual(@as(usize, 3), module.childCount(index));
    }
}

test "parse models async arrows and a default-exported object literal" {
    const a = testing.allocator;
    const source =
        \\const run = async (env: Env, id: string): Promise<void> => {
        \\  return;
        \\};
        \\export default {
        \\  async fetch(request: Request): Promise<Response> {
        \\    return request.ok ? 1 : 0;
        \\  },
        \\};
        \\
    ;
    var module = try parse(a, source);
    defer module.deinit();

    // an annotation read as a call argument, or a `{` read as a block, is
    // exactly the unknown node this test exists to catch
    try testing.expectEqual(@as(usize, 0), module.unknownCount());

    var arrows: usize = 0;
    var methods: usize = 0;
    var objects: usize = 0;
    var optionals: usize = 0;
    var async_as_reference: usize = 0;
    var walker = module.iterator();
    while (walker.next()) |index| {
        switch (module.kindOf(index)) {
            .arrow => arrows += 1,
            .function_expr => methods += 1,
            .object_literal => objects += 1,
            .conditional => optionals += 1,
            .identifier => {
                if (std.mem.eql(u8, module.nodeOf(index).name, "async")) async_as_reference += 1;
            },
            else => {},
        }
    }
    try testing.expectEqual(@as(usize, 1), arrows);
    try testing.expectEqual(@as(usize, 1), objects);
    try testing.expectEqual(@as(usize, 1), methods);
    try testing.expectEqual(@as(usize, 1), optionals);
    // `async` must be the arrow's modifier, never a reference: reading it as an
    // identifier turns the parameter list into a call's arguments
    try testing.expectEqual(@as(usize, 0), async_as_reference);
}

test "parse models a generic arrow function" {
    const a = testing.allocator;
    const source =
        \\const pickRandom = <T>(options: readonly T[]): T => options[0];
        \\const head = async <T>(items: T[]): Promise<T> => items[0];
        \\const after = 1;
        \\
    ;
    var module = try parse(a, source);
    defer module.deinit();

    try testing.expectEqual(@as(usize, 0), module.unknownCount());

    // a generic arrow read as a type assertion swallows the rest of the file,
    // so the declarations after it must still be here
    var arrows: usize = 0;
    var declarations: usize = 0;
    var walker = module.iterator();
    while (walker.next()) |index| {
        switch (module.kindOf(index)) {
            .arrow => arrows += 1,
            .variable_decl => declarations += 1,
            else => {},
        }
    }
    try testing.expectEqual(@as(usize, 2), arrows);
    try testing.expectEqual(@as(usize, 3), declarations);
    try testing.expect(module.coveredEnd() == source.len - 1);
}

test "parse survives every committed corpus file" {
    const a = testing.allocator;
    const io = std.testing.io;
    var directory = try std.Io.Dir.cwd().openDir(io, "tests/lint-corpus", .{ .iterate = true });
    defer directory.close(io);

    var checked: usize = 0;
    var iterator = directory.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".ts")) continue;

        const source = try directory.readFileAlloc(io, entry.name, a, .limited(1 << 18));
        defer a.free(source);

        var module = parse(a, source) catch |err| {
            std.debug.print("{s}: parse failed: {s}\n", .{ entry.name, @errorName(err) });
            return err;
        };
        defer module.deinit();

        if (module.unknownCount() > 0) {
            std.debug.print("{s}: {d} unknown node(s)\n", .{ entry.name, module.unknownCount() });
            var walker = module.iterator();
            while (walker.next()) |index| {
                if (module.kindOf(index) != .unknown) continue;
                std.debug.print("  line {d}: {s}\n", .{ module.spanOf(index).line, module.textOf(index) });
                break;
            }
        }
        try testing.expectEqual(@as(usize, 0), module.unknownCount());
        checked += 1;
    }
    try testing.expect(checked > 100);
}

// parse every source file under the roots listed in `.auto/parse-sweep.txt`,
// which is how the parser's gaps are found against real projects instead of the
// committed corpus. run it while migrating a rule onto the IR; it fails while
// any file still has an unknown node. roots that do not exist on this machine
// are skipped, so the test is a no-op in a checkout without them
test "parse sweep over real projects" {
    const a = testing.allocator;
    const io = std.testing.io;

    const roots_list = std.Io.Dir.cwd().readFileAlloc(io, ".auto/parse-sweep.txt", a, .limited(1 << 16)) catch return;
    defer a.free(roots_list);

    var files: usize = 0;
    var unknown_files: usize = 0;
    var unknown_nodes: usize = 0;
    var parse_errors: usize = 0;
    var bytes: usize = 0;
    var roots_found: usize = 0;

    var line_iterator = std.mem.splitScalar(u8, roots_list, '\n');
    while (line_iterator.next()) |raw_line| {
        const root = std.mem.trim(u8, raw_line, " \t\r");
        if (root.len == 0 or root[0] == '#') continue;
        var directory = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch continue;
        defer directory.close(io);
        roots_found += 1;

        var walker = try directory.walk(a);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (std.mem.indexOf(u8, entry.path, "node_modules") != null) continue;
            if (!isSourceFile(entry.basename)) continue;

            const source = directory.readFileAlloc(io, entry.path, a, .limited(1 << 20)) catch |err| {
                std.debug.print("sweep: cannot read {s}: {s}\n", .{ entry.path, @errorName(err) });
                parse_errors += 1;
                continue;
            };
            defer a.free(source);
            bytes += source.len;
            files += 1;

            var module = parse(a, source) catch |err| {
                std.debug.print("sweep: {s}: parse failed: {s}\n", .{ entry.path, @errorName(err) });
                parse_errors += 1;
                continue;
            };
            defer module.deinit();

            const unknown = module.unknownCount();
            if (unknown == 0 and firstUncoveredByte(source, module.coveredEnd()) == null) continue;
            unknown_files += 1;
            unknown_nodes += unknown;
            if (unknown_files > 40) continue;
            if (unknown > 0) {
                std.debug.print("sweep: {s}: {d} unknown\n", .{ entry.path, unknown });
                var gaps = module.iterator();
                var shown: usize = 0;
                while (gaps.next()) |index| {
                    if (module.kindOf(index) != .unknown or shown == 3) continue;
                    std.debug.print("  line {d}: '{s}'\n", .{ module.spanOf(index).line, module.textOf(index) });
                    shown += 1;
                }
            }
            if (firstUncoveredByte(source, module.coveredEnd())) |byte| {
                std.debug.print("sweep: {s}: parsing stopped before byte {d} ({s})\n", .{ entry.path, byte, source[byte..@min(byte + 30, source.len)] });
            }
        }
    }

    // the summary is only printed when something is wrong: `zig build test`
    // multiplexes the runner's progress over stderr, so a passing sweep has to
    // stay silent to keep that channel intact
    if (unknown_files == 0 and parse_errors == 0) return;
    std.debug.print(
        "sweep: {d} roots, {d} files, {d} bytes, {d} unknown files, {d} unknown nodes, {d} parse errors\n",
        .{ roots_found, files, bytes, unknown_files, unknown_nodes, parse_errors },
    );
    if (roots_found == 0) return;
    try testing.expectEqual(@as(usize, 0), unknown_files + parse_errors);
}

/// the extensions `check` parses, matching what biome lints
fn isSourceFile(name: []const u8) bool {
    const extensions = [_][]const u8{ ".ts", ".tsx", ".js", ".jsx", ".mts", ".cts", ".mjs", ".cjs" };
    for (extensions) |extension| {
        if (std.mem.endsWith(u8, name, extension)) return true;
    }
    return false;
}

/// the first byte after `end` that is code rather than whitespace or a comment.
/// a parser that stops early leaves code here, which an unknown-node count alone
/// cannot see: the swallowed statements produce no unknown, they produce nothing
fn firstUncoveredByte(source: []const u8, end: u32) ?usize {
    var i: usize = end;
    while (i < source.len) {
        const byte = source[i];
        if (byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n') {
            i += 1;
            continue;
        }
        if (byte == '/' and i + 1 < source.len and source[i + 1] == '/') {
            while (i < source.len and source[i] != '\n') i += 1;
            continue;
        }
        if (byte == '/' and i + 1 < source.len and source[i + 1] == '*') {
            i += 2;
            while (i + 1 < source.len and !(source[i] == '*' and source[i + 1] == '/')) i += 1;
            i = @min(i + 2, source.len);
            continue;
        }
        return i;
    }
    return null;
}
