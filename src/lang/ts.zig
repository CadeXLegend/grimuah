const std = @import("std");
const ir = @import("../ir.zig");
const typecount = @import("typecount.zig");

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

    // how many brace pairs the walk has opened inside a `${...}` container. the
    // container's own closing brace is implied by the `${` and is no token, while a
    // brace pair inside it is an object literal or a block whose `{` and its `}` are
    // both tokens, so the walk returns at the brace that closes the CONTAINER rather
    // than at the first one it meets. without the count, `${g({})}` ends the
    // container at the object literal's `}`, and every token after it strands
    var container_depth: usize = 0;

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

        if (char == '{' and stop == .brace_close) {
            container_depth += 1;
            try lexer.push(.punct, lexer.pos, lexer.pos + 1, lexer.line_number);
            lexer.pos += 1;
            lexer.regex_state = .allowed;
            continue;
        }

        if (char == '}') {
            if (stop == .brace_close) {
                if (container_depth == 0) {
                    lexer.pos += 1;
                    return;
                }
                container_depth -= 1;
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
    "new",       "in",      "of",    "instanceof", "as",     "return",   "throw",     "if",         "else",      "for",      "while",
    "do",        "switch",  "case",  "default",    "break",  "continue", "try",       "catch",      "finally",   "function", "class",
    "const",     "let",     "var",   "import",     "export", "from",     "extends",   "implements", "interface", "type",     "enum",
    "namespace", "declare", "async", "abstract",   "keyof",  "infer",    "satisfies", "is",         "asserts",
};

/// the same set as a comptime lookup. the parser asks whether a word token is a
/// keyword about 60 times per file, and the linear scan answered with 53 length
/// comparisons every time, which measured 3.5% of a run
const non_reference_lookup = std.StaticStringMap(void).initComptime(init: {
    var entries: [non_reference_words.len]struct { []const u8 } = undefined;
    for (non_reference_words, 0..) |word, index| entries[index] = .{word};
    break :init entries;
});

/// where a type expression ends at depth 0. the stop sets differ in two places: a
/// `{` *starts* an object type in most positions but starts the body after a
/// return annotation, and a `=>` ends the type wherever it does not belong to a
/// function type. an object *type* in a body position (`(): {a: number} => x`) is
/// read as a body instead, a known gap the corpus records
///
/// a type can spell a `=>` of its own, because that is how a function type is
/// written, so "ends at a `=>`" is only true of the one annotation whose `=>`
/// really does own the body
const TypeStop = enum {
    /// an annotation a value can follow: a declarator's own (`const x: T = value`), a
    /// parameter's default, or a member's initializer
    /// its `{` is an object type like any other annotation's, and it ends at the `=`
    /// that introduces the value, so a `=>` inside it is a function type's arrow
    annotation_before_value,
    /// a return annotation, where the `{` after the type starts the body rather than an
    /// object type
    /// a `=>` inside it is still a function type's arrow, because the token that owns
    /// the body is the brace
    return_annotation,
    /// a type in every other position, where `{` starts an object type
    brace_starts_object,
    /// the one place a `=>` owns the body: an arrow's own return annotation, where what
    /// follows the type is the arrow that introduces the body rather than a brace
    ///
    /// an arrow cannot read `return_annotation`, because `(x): (y: number) => number => y`
    /// spells its own annotation with a `=>` too and telling the type's arrow from the
    /// body's needs the type grammar rather than the token stream, so the token reader's
    /// reading stays and the shape is a known gap. an `implements` clause reads this too,
    /// and reads the same either way, because a `=>` cannot stand in a heritage list at
    /// depth 0
    brace_starts_body,
};

/// how many type-parameter levels a `>`-family token closes: one for `>`, two for
/// `>>`, three for `>>>`, nothing for `>=`, `>>=`, `>>>=` and every other token.
/// a hand-rolled length test got `>>=` wrong once, so this is one function that
/// spells all six forms out
///
/// `src/lang/typemodel.zig` reads a type's members from an extent the same way,
/// and shares this rather than spelling the six forms out a second time
pub fn angleClosers(text: []const u8) usize {
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
        // `=` introduces a value, and a `=>` is one token further in: only an annotation
        // whose `=` really does introduce a value stops at the bare `=`, so the shapes
        // that hold a function type run past the type's own arrow
        '=' => switch (stop) {
            .annotation_before_value, .return_annotation => text.len == 1,
            .brace_starts_object, .brace_starts_body => text.len <= 3,
        },
        '!' => text.len <= 3, // `!`, `!=`, `!==`
        '&' => text.len == 2, // `&&`; `&` is a type operator
        '|' => text.len == 2, // `||`; `|` is a type operator
        // a brace opens an object type wherever the body cannot follow, and starts the body
        // in the two positions where it can
        '{' => switch (stop) {
            .return_annotation, .brace_starts_body => true,
            .annotation_before_value, .brace_starts_object => false,
        },
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

/// the TypeScript nodes the front-end deliberately does not build, one constant per
/// shape it drops. each is recorded on the node that stands in for the TypeScript node
/// around it, and `ir.Module.descendantsOf` sums them over the finished tree
///
/// they are named rather than inlined because several are recorded from more than one
/// place, and a reader has to be able to tell a delta that counts dropped nodes from
/// one that takes back a node the tree added
/// a member access's name. `a.b` is a `PropertyAccessExpression` over the receiver and
/// an `Identifier`, and the tree keeps the name as the member's own `name`
const member_name_node: i32 = 1;

/// the `QuestionDotToken` a `?.` stands for. no token rule may see it, so the tree
/// drops it
const question_dot_node: i32 = 1;

/// a binary expression's operator token, which the tree keeps as the node's own
/// `operator`
const operator_token_node: i32 = 1;

/// a conditional's `?` and `:`, the two tokens the tree keeps beside the branches
const conditional_token_nodes: i32 = 2;

/// `x!` is a `NonNullExpression` and `x++` a `PostfixUnaryExpression`: one node above
/// the operand, and neither carries a token of its own
const postfix_wrapper_node: i32 = 1;

/// `new Foo(a)` is one `NewExpression` over the callee and the arguments, while the
/// tree puts a `.call` between them. the construction takes that extra node back
const construction_wrapper_node: i32 = -1;

/// one object entry: the `PropertyAssignment` (or `ShorthandPropertyAssignment`) node
/// and the key it holds, both of which the tree keeps in the literal's own source text
const property_entry_nodes: i32 = 2;

/// a key computed in brackets is that entry's node plus the `ComputedPropertyName` the
/// brackets are
const computed_key_nodes: i32 = 2;

/// a hole in an array literal. typescript writes an `OmittedExpression`, and the tree
/// writes nothing
const omitted_element_node: i32 = 1;

/// a substitution in a template literal: the `TemplateSpan` over it and the literal
/// that closes it
const template_span_nodes: i32 = 2;

/// the `TemplateHead` a template with at least one substitution opens with
const template_head_node: i32 = 1;

/// the `...` of a rest parameter, the `?` of an optional one and the `readonly` of a
/// constructor's, each one node of the `Parameter` beside the binding
const parameter_token_node: i32 = 1;

/// a comma expression between parentheses: one `BinaryExpression` and its `CommaToken`
/// per operand past the first
const comma_operand_nodes: i32 = 2;

/// a dynamic `import("m")` is a `CallExpression` whose callee is the `import` keyword
/// rather than a name, and the tree records neither the keyword nor the specifier
const dynamic_import_nodes: i32 = 2;

/// the `async` keyword and the `*` of a generator, each one node beside the parameters
/// and the body
const modifier_node: i32 = 1;

/// a named callable's name, which the tree keeps as the node's own `name`
const function_name_node: i32 = 1;

/// an arrow's `=>`, the one token between its parameters and its body
const arrow_token_node: i32 = 1;

/// the `Parameter` node typescript wraps a bound name, an annotation and the `?` in,
/// while the tree hangs the binding off the callable directly
const parameter_node: i32 = 1;

/// the `VariableDeclarationList` a declaration *statement* wraps, which the tree's
/// own node stands in for. a `for` header holds the same list directly under the
/// loop's node, where nothing wraps it
const declaration_list_node: i32 = 1;

/// the `VariableDeclaration` each declarator is: typescript puts the name, the
/// annotation and the initializer under it, and the tree hangs all three off the
/// declaration itself
const declarator_node: i32 = 1;

/// one entry of a binding pattern: the `BindingElement` node, the `PropertyName` a
/// `{ a: b }` entry names its property with, the `DotDotDotToken` a `...rest`
/// carries, and the `Identifier` of a nested pattern's brackets. the tree binds
/// the names and keeps none of the four
const binding_element_node: i32 = 1;
const binding_property_name_node: i32 = 1;
const binding_rest_token_node: i32 = 1;
const binding_pattern_node: i32 = 1;

/// the `Identifier` a name the tree declines to bind still is: `{ type }`, `{ a: type }`
/// and a `type: T` parameter all name words the binding list leaves out, and typescript
/// builds one node for each
const declined_name_node: i32 = 1;

/// the `Block` a `finally` clause is written as. typescript hangs that block off the
/// `TryStatement` itself, while the tree wraps it in a node of its own beside the
/// one it already builds for the body
const finally_clause_node: i32 = -1;

/// the initializer a pattern entry's `=` introduces, which the tree drops whole.
/// the entry's own `Identifier` is one node of it, and the initializer's own nodes
/// are recorded as a gap beside this one
const binding_default_node: i32 = 1;

/// the `VariableDeclaration` a `catch` clause wraps its caught binding in
const catch_binding_node: i32 = 1;

/// the `CaseBlock` a `switch` holds its clauses in, which the tree flattens
const case_block_node: i32 = 1;

/// the `AwaitKeyword` a `for await` carries
const for_await_token_node: i32 = 1;

/// a class's own name, which the tree keeps as the node's own `name`
const class_name_node: i32 = 1;

/// an `extends` clause: the `HeritageClause` node, and the
/// `ExpressionWithTypeArguments` that wraps the base the tree already holds
const extends_clause_nodes: i32 = 2;

/// a modifier, wherever it is written: `abstract` on a declaration, `static` or
/// `readonly` on a class member, and the `*` of a generator method. `get` and `set`
/// are the accessor kinds typescript declares rather than modifiers, so neither is
/// one of these
const declaration_modifier_node: i32 = 1;

/// a class member: the `PropertyDeclaration` node typescript wraps a field in, the
/// name node that field or any method is declared under, and the `?` of an optional
/// one. a method's own wrapper is the callable node the tree already builds
const class_member_node: i32 = 1;
const class_member_name_node: i32 = 1;
const optional_member_token_node: i32 = 1;

/// where a declaration is written, which decides what its node stands in for:
/// typescript wraps a declaration *statement* in a `VariableStatement` over a
/// `VariableDeclarationList`, while a `for` header holds the declaration list
/// directly, with nothing between it and its declarators
const DeclarationPosition = enum { statement, loop_header };

const Parser = struct {
    tokens: []const Token,
    module: *ir.Module,
    source: []const u8,
    pos: usize = 0,
    /// a class heritage clause is a type reference, so a `<` inside it opens a
    /// type argument list and is never the comparison operator
    in_heritage: bool = false,

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
                            self.module.nodes.items[binding].binding = .named_import_binding;
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
        return self.parseVariableDeclaration(.@"const", .statement);
    }

    fn parseLet(self: *Parser) !ir.NodeIndex {
        return self.parseVariableDeclaration(.let, .statement);
    }

    fn parseVar(self: *Parser) !ir.NodeIndex {
        return self.parseVariableDeclaration(.@"var", .statement);
    }

    fn parseVariableDeclaration(self: *Parser, declaration_kind: ir.DeclKind, position: DeclarationPosition) !ir.NodeIndex {
        const from = self.begin();
        const keyword = self.advance();
        const node = try self.addNode(.variable_decl, from);
        self.module.nodes.items[node].decl_kind = declaration_kind;
        self.module.nodes.items[node].operator = keyword.text;
        // a statement's own node stands in for the `VariableStatement`, and a `for`
        // header's for the declaration list itself: only the statement has a list
        // between it and its declarators
        if (position == .statement) self.module.addDescendants(node, declaration_list_node);

        while (!self.atEnd()) {
            // every declarator is one `VariableDeclaration` over its name, its
            // annotation and its initializer
            self.module.addDescendants(node, declarator_node);
            try self.parseBindingTarget(node);
            if (self.atPunct(":")) {
                self.pos += 1;
                self.skipTypeCounting(node, .annotation_before_value);
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

        if (position == .statement and self.atPunct(";")) self.pos += 1;
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
            // whether the cursor stands at the head of an entry, where a bracket pair
            // opens a nested pattern rather than continuing the one above it: after the
            // opener, after a `,` and after the `:` that introduces a `{ a: { b } }`
            var at_entry_start = true;
            // a default's value is an expression, and the loop reads it as bare names
            // like the rest of the pattern: nothing inside it is a `BindingElement`, a
            // key or a nested pattern, and the brackets the value opens are what tell
            // the `,` between two members from the one that ends the entry. all three
            // kinds are counted, not only the parentheses: `depth` sees one bracket kind
            // alone, so it reads the comma inside `{ a = [1, 2] }` as the entry's own
            var in_default = false;
            var default_brackets: usize = 0;
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
                // a default's value is an expression the loop reads as bare names, and the
                // nodes inside it are the tree's business: what the value holds beyond the
                // names the tree binds is the recorded gap below, so nothing inside it is
                // counted as an entry, a key or a pattern
                if (in_default and (current.isPunct("(") or current.isPunct("[") or current.isPunct("{"))) default_brackets += 1;
                if (in_default and (current.isPunct(")") or current.isPunct("]") or current.isPunct("}")) and default_brackets > 0) default_brackets -= 1;
                if (in_default and current.isPunct(",") and depth == 1 and default_brackets == 0) in_default = false;
                const counting = !in_default;

                if (current.kind == .word) {
                    const next = if (self.pos + 1 < self.tokens.len) self.tokens[self.pos + 1] else null;
                    const is_key = next != null and next.?.isPunct(":");
                    if (counting and is_key) {
                        // a `{ a: b }` entry names its property as well as its binding
                        self.module.addDescendants(pattern, binding_property_name_node);
                    } else if (!is_key and !previous_was_key and !isNonReference(current.text)) {
                        const binding = try self.addNode(.identifier, self.begin());
                        self.module.nodes.items[binding].name = current.text;
                        self.module.nodes.items[binding].binding = .variable;
                        self.module.appendChild(pattern, binding);
                        // every bound name is one `BindingElement`
                        if (counting) self.module.addDescendants(pattern, binding_element_node);
                    } else if (counting) {
                        // a name typescript binds and this list leaves out, because the word
                        // is keyword-shaped: it is still an entry's own `Identifier`
                        self.module.addDescendants(pattern, binding_element_node + declined_name_node);
                    }
                    previous_was_key = is_key;
                    at_entry_start = false;
                } else {
                    previous_was_key = false;
                }
                if (counting and current.isPunct("...")) self.module.addDescendants(pattern, binding_rest_token_node);
                if (counting and current.isPunct("=")) {
                    // the initializer node, which the tree drops whole. a value that is one
                    // bare name is the node the tree already counts, because the loop binds
                    // that word, while a value with anything above its names (`= ""`,
                    // `= f(x)`, `= a + b`) is a node it does not build
                    //
                    // ponytail: a value with more than one node above its names
                    // (`= f(x).b`, `= { x: 1 }`, `= [1, 2]`) is counted short by the rest.
                    // measured over the corpus: one pattern default in 246 files, and it is
                    // `= ""`, which this counts
                    const value = if (self.pos + 1 < self.tokens.len) self.tokens[self.pos + 1] else null;
                    const after_value = if (self.pos + 2 < self.tokens.len) self.tokens[self.pos + 2] else null;
                    const bare_name = value != null and value.?.kind == .word and !isNonReference(value.?.text) and
                        (after_value == null or after_value.?.isPunct(",") or after_value.?.isPunct(closer));
                    self.module.addDescendants(pattern, binding_default_node - @as(i32, @intFromBool(bare_name)));
                    in_default = true;
                    default_brackets = 0;
                } else if (current.isPunct(":")) {
                    at_entry_start = true;
                } else if (current.isPunct(",")) {
                    // `[a, , b]` writes a hole typescript keeps as an `OmittedExpression`
                    const previous = if (self.pos > 0) self.tokens[self.pos - 1] else null;
                    if (counting and previous != null and (previous.?.isPunct("[") or previous.?.isPunct(","))) {
                        self.module.addDescendants(pattern, omitted_element_node);
                    }
                    at_entry_start = true;
                } else if (counting and (current.isPunct("{") or current.isPunct("[")) and at_entry_start) {
                    // a nested pattern is a node of its own, and the entry that holds it is
                    // a `BindingElement` beside the bound names rather than above one
                    self.module.addDescendants(pattern, binding_pattern_node + binding_element_node);
                    // ponytail: an object pattern's brackets hold a computed name rather
                    // than a nested pattern, and this counts them as the two a nested
                    // pattern and its entry would take. measured: `{ [k]: v }` reads 2
                    // over typescript's count and `{ [f(a)]: v }` 2 over, because the tree
                    // reads the brackets' expression as bare names. closing it needs the
                    // entry's `BindingElement` counted once per entry and the
                    // `ComputedPropertyName` beside it, which is the state machine this
                    // reads instead of
                    // measured over the corpus: no object pattern holds a computed name at
                    // all, 0 of 246 files and 0 of the 5126 differential cases
                } else if (counting and at_entry_start and current.isLiteral()) {
                    // a literal key, which is a `PropertyName` and never a name this list
                    // could bind: `{ "s": v }` and `{ 1: v }`
                    self.module.addDescendants(pattern, binding_property_name_node);
                    at_entry_start = false;
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
        // `abstract` and `async` are each one node beside the declaration
        var declaration_modifiers: i32 = 0;
        if (self.atWord("abstract")) {
            declaration_modifiers += declaration_modifier_node;
            self.pos += 1;
        }
        if (self.atWord("async")) {
            declaration_modifiers += declaration_modifier_node;
            self.pos += 1;
        }
        const node = try self.addNode(.function_decl, from);
        if (self.atWord("function")) {
            self.pos += 1;
            if (self.atPunct("*")) {
                declaration_modifiers += declaration_modifier_node;
                self.pos += 1;
            }
            if (!self.atEnd() and self.peek().?.kind == .word) {
                self.module.nodes.items[node].name = self.peek().?.text;
                declaration_modifiers += function_name_node;
                self.pos += 1;
            }
        }
        if (declaration_modifiers != 0) self.module.addDescendants(node, declaration_modifiers);
        if (self.atPunct("<")) {
            self.module.addDescendants(node, self.typeParameterNodesAt(self.pos));
            // the extent this skips runs past the `>` into the parameter list that
            // follows, and that list is a recorded gap below
            self.skipType(.brace_starts_object);
        }
        try self.parseParameterList(node);
        if (self.atPunct(":")) {
            self.pos += 1;
            self.skipTypeCounting(node, .return_annotation);
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
        // the brackets of a destructuring parameter. they tell the `,` that separates
        // two bindings inside a pattern from the one that ends the parameter, which is
        // where the `Parameter` node's own count is recorded
        var square_depth: usize = 0;
        // whether the token under the cursor opens a parameter: typescript wraps every
        // one in a `Parameter` node, and the tree hangs the binding off the callable
        // instead
        //
        // ponytail: a parameter's name is read as the one identifier the tree binds,
        // which is exact for a simple one and short by the pattern's own nodes for a
        // destructuring pattern. measured over the corpus: 10 of 4944 sites hold a
        // destructuring parameter, the smallest count among them is 22 against a gate
        // of 7, and none is a reported row (measured, sleepy's src, lib and gateway)
        var opens_parameter = !self.atPunct(")");
        while (!self.atEnd() and depth > 0) {
            if (opens_parameter) {
                opens_parameter = false;
                if (!self.atPunct(")")) self.module.addDescendants(parent, parameter_node);
            }
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
            if (self.atPunct("[")) square_depth += 1;
            if (self.atPunct("]")) {
                if (square_depth > 0) square_depth -= 1;
            }
            const token = self.peek().?;
            if (token.isPunct(":") or token.isPunct("=")) {
                const is_default = token.isPunct("=");
                self.pos += 1;
                if (is_default) {
                    const value = try self.parseExpression();
                    self.module.appendChild(parent, value);
                } else {
                    self.skipTypeCounting(parent, .annotation_before_value);
                }
                continue;
            }
            if (token.isPunct(",") and depth == 1 and brace_depth == 0 and square_depth == 0) {
                opens_parameter = true;
                self.pos += 1;
                continue;
            }
            if (token.isPunct("...") or token.isPunct("?") or token.isWord("readonly")) {
                self.module.addDescendants(parent, parameter_token_node);
            }
            if (token.kind == .word) {
                const next = if (self.pos + 1 < self.tokens.len) self.tokens[self.pos + 1] else null;
                const is_key = brace_depth > 0 and next != null and next.?.isPunct(":");
                if (!is_key and !isNonReference(token.text)) {
                    const binding = try self.addNode(.identifier, self.begin());
                    self.module.nodes.items[binding].name = token.text;
                    self.module.nodes.items[binding].binding = .parameter;
                    self.module.appendChild(parent, binding);
                } else if (!is_key) {
                    // a parameter typescript names and this list leaves out, because the
                    // word is keyword-shaped: it is still the `Parameter`'s own `Identifier`
                    self.module.addDescendants(parent, declined_name_node);
                }
            }
            self.pos += 1;
        }
    }

    fn parseClassDeclaration(self: *Parser) !ir.NodeIndex {
        const from = self.begin();
        // `abstract` and `declare` are each one node beside the declaration
        var declaration_modifiers: i32 = 0;
        if (self.atWord("abstract") or self.atWord("declare")) {
            declaration_modifiers = declaration_modifier_node;
            self.pos += 1;
        }
        const node = try self.addNode(.class_decl, from);
        if (declaration_modifiers != 0) self.module.addDescendants(node, declaration_modifiers);
        if (self.atWord("class")) {
            self.pos += 1;
            // a class expression may have no name at all, so `extends` and
            // `implements` are not one: `const K = class extends Base<T> {}`
            // would otherwise record `extends` as the class's own name and
            // leave the heritage to be parsed as whatever comes next
            if (!self.atEnd() and (self.peek().?).kind == .word and
                !self.atWord("extends") and !self.atWord("implements"))
            {
                self.module.nodes.items[node].name = (self.peek().?).text;
                self.module.addDescendants(node, class_name_node);
                self.pos += 1;
            }
        }
        if (self.atPunct("<")) {
            self.module.addDescendants(node, self.typeParameterNodesAt(self.pos));
            self.skipType(.brace_starts_object);
        }
        if (self.atWord("extends")) {
            self.pos += 1;
            // the base is a type reference (`Base`, `ns.Base`) or a call that
            // returns one (`mixin(Base)`), and its `<` opens type arguments.
            // without that known, `class K extends Base<{ a: string; b: number }>
            // {}` reads the `<` as a comparison and corrupts the tree
            const was_in_heritage = self.in_heritage;
            self.in_heritage = true;
            defer self.in_heritage = was_in_heritage;

            const base = try self.parseExpression();
            self.module.appendChild(node, base);
            // the clause, and the wrapper the base is held in: the tree puts the base's
            // own node where both of them are
            self.module.addDescendants(node, extends_clause_nodes);
        }
        if (self.atWord("implements")) {
            self.pos += 1;
            const heritage_from = self.pos;
            self.skipType(.brace_starts_body);
            self.module.addDescendants(node, self.heritageNodes(heritage_from, self.pos));
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
            // every modifier a member is written with is a node of its own, and `get`
            // and `set` are not modifiers at all
            while (!self.atEnd() and self.peek().?.kind == .word and isModifier(self.peek().?.text)) {
                if (isModifierNode(self.peek().?.text)) self.module.addDescendants(parent, declaration_modifier_node);
                self.pos += 1;
            }
            while (!self.atEnd() and self.peek().?.isPunct("*")) {
                self.module.addDescendants(parent, declaration_modifier_node);
                self.pos += 1;
            }

            if (self.atEnd() or self.atPunct("}")) break;

            // the name the member is declared under. a computed one is a
            // `ComputedPropertyName` over the expression the tree keeps, a plain one an
            // `Identifier` the tree drops, and `constructor` is the one member
            // typescript declares with no name node at all
            if (self.atPunct("[")) {
                self.module.addDescendants(parent, class_member_name_node);
                self.pos += 1;
                const computed = try self.parseExpression();
                self.module.appendChild(parent, computed);
                if (self.atPunct("]")) self.pos += 1;
            } else if (self.peek().?.kind == .word or (self.peek().?).isLiteral()) {
                if (!self.peek().?.isWord("constructor")) self.module.addDescendants(parent, class_member_name_node);
                self.pos += 1;
            } else {
                _ = try self.parseUnknown();
                continue;
            }

            if (self.atPunct("?")) {
                self.module.addDescendants(parent, optional_member_token_node);
                self.pos += 1;
            }
            if (self.atPunct("<")) {
                self.module.addDescendants(parent, self.typeParameterNodesAt(self.pos));
                self.skipType(.brace_starts_object);
            }

            if (self.atPunct("(")) {
                // a method, an accessor or a constructor: the callable node the tree
                // builds is what stands in for the `MethodDeclaration`, `GetAccessor`,
                // `SetAccessor` or `Constructor` wrapper, so only the name is missing
                const member = try self.addNode(.function_decl, from);
                self.module.appendChild(parent, member);
                try self.parseParameterList(member);
                if (self.atPunct(":")) {
                    self.pos += 1;
                    self.skipTypeCounting(member, .return_annotation);
                }
                if (self.atPunct("{")) {
                    const body = try self.parseBlock();
                    self.module.appendChild(member, body);
                }
                self.closeNode(member, from);
                continue;
            }

            // a field: typescript wraps it in a `PropertyDeclaration` over its name and
            // its initializer, and the tree hangs the initializer off the class itself
            self.module.addDescendants(parent, class_member_node);
            if (self.atPunct(":")) {
                self.pos += 1;
                self.skipTypeCounting(parent, .annotation_before_value);
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
            const declaration = try self.parseFunctionDeclaration();
            // the `async` this handler consumed is the declaration's own modifier node,
            // and the handler is where the token left the stream
            self.module.addDescendants(declaration, declaration_modifier_node);
            return declaration;
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
        const is_await = self.atWord("await");
        if (is_await) self.pos += 1;
        const node = try self.addNode(.for_stmt, from);
        // `for await` carries the `AwaitKeyword` beside the declaration and the iterable
        if (is_await) self.module.addDescendants(node, for_await_token_node);

        if (self.atPunct("(")) {
            self.pos += 1;

            if (self.atWord("const") or self.atWord("let") or self.atWord("var")) {
                const declaration_kind = ir.DeclKind.fromKeyword(self.peek().?.text);
                const declaration = try self.parseVariableDeclaration(declaration_kind, .loop_header);
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
        // typescript holds every clause in a `CaseBlock` above them, and the tree hangs
        // the clauses off the statement itself
        self.module.addDescendants(node, case_block_node);

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
            // `finally` is not a clause typescript declares: the block after the keyword
            // is the `try`'s own `finallyBlock`, and the tree wraps it in one more node
            if (!is_catch) self.module.addDescendants(clause, finally_clause_node);
            if (is_catch and self.atPunct("(")) {
                self.pos += 1;
                // typescript wraps the caught binding in a `VariableDeclaration`
                self.module.addDescendants(clause, catch_binding_node);
                try self.parseBindingTarget(clause);
                if (self.atPunct(":")) {
                    self.pos += 1;
                    self.skipTypeCounting(clause, .brace_starts_object);
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
            self.module.addDescendants(node, conditional_token_nodes);
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
        self.module.addDescendants(node, operator_token_node);
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
            // a recorded gap: `satisfies` is absent from `isBinaryOperator`, so
            // `x satisfies T` splits here and the tail is read as a statement of its own.
            // the site's subtree is then not the one typescript walks, and the count is
            // short by the type it names. measured over the corpus: one site holds one
            // (`src/services/xp.service.ts:120`, count 18) and it is not a reported row.
            // taking it in means building a node typescript has and the tree does not,
            // which is a tree change and can move a shipped rule's rows
            const is_operator = isBinaryOperator(token);
            const is_cast = token.isWord("as");
            if (!is_operator and !is_cast) break;

            const from = if (self.pos > 0) self.pos - 1 else 0;
            self.pos += 1;

            if (is_cast) {
                const cast = try self.addNode(.as_expr, from);
                const type_from = self.begin();
                self.module.addDescendants(cast, self.skipTypeNodes(.brace_starts_object));
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
            self.module.addDescendants(node, operator_token_node);
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
        // the type arguments of a `f<T>(x)` call and the `?.` of a `f?.(x)` or a
        // `a?.[b]`: both are consumed here and belong to the node the next token
        // builds rather than to the chain the cursor already holds
        var type_arguments: i32 = 0;
        var orphan_question_dot: i32 = 0;

        while (!self.atEnd()) {
            const token = self.peek().?;

            if (token.isPunct(".") or token.isPunct("?.")) {
                const optional = token.isPunct("?.");
                const from = if (self.pos > 0) self.pos - 1 else 0;
                self.pos += 1;
                if (self.atEnd() or (self.peek().?).kind != .word) {
                    // a `?.` before a call or an index: typescript writes it as the
                    // call's or the access's own token, and the tree drops it here
                    orphan_question_dot += @intFromBool(optional);
                    continue;
                }
                const name = self.peek().?.text;
                self.pos += 1;
                const member = try self.addNode(.member, from);
                self.module.nodes.items[member].name = name;
                self.module.appendChild(member, expression);
                self.module.addDescendants(member, member_name_node + if (optional) question_dot_node else 0);
                self.closeNode(member, from);
                expression = member;
                continue;
            }

            if (token.isPunct("(")) {
                const from = if (self.pos > 0) self.pos - 1 else 0;
                self.pos += 1;
                const call = try self.addNode(.call, from);
                self.module.addDescendants(call, type_arguments + orphan_question_dot);
                type_arguments = 0;
                orphan_question_dot = 0;
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
                self.module.addDescendants(index, orphan_question_dot);
                orphan_question_dot = 0;
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

            // `!` non-null assertion and `++` / `--` postfix. typescript wraps the
            // operand in a `NonNullExpression` or a `PostfixUnaryExpression`, neither
            // of which carries a token of its own, and the tree writes nothing
            if (token.isPunct("!") or token.isPunct("++") or token.isPunct("--")) {
                self.module.addDescendants(expression, postfix_wrapper_node);
                self.pos += 1;
                continue;
            }

            // `f<T>(x)` generic call and `new Map<string, T>()`: the type
            // arguments are not part of the value. a heritage clause is a type
            // reference, so its `<` owns type arguments whatever follows them
            if (token.isPunct("<")) {
                if (self.matchingAngle(self.pos)) |close_index| {
                    const after = if (close_index + 1 < self.tokens.len) self.tokens[close_index + 1] else null;
                    const is_type_arguments = self.in_heritage or
                        (after != null and
                            (after.?.isPunct("(") or after.?.isPunct(".") or after.?.isPunct("?.") or after.?.isPunct("[")));
                    if (is_type_arguments) {
                        type_arguments += self.typeArgumentNodes(self.pos, close_index + 1);
                        self.pos = close_index + 1;
                        continue;
                    }
                }
                break;
            }
            break;
        }
        // a `<...>` list with no call or index after it is a heritage clause's type
        // arguments, which belong to the base the chain already holds
        self.module.addDescendants(expression, type_arguments);
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
            // a substitution is one `TemplateSpan` over its expression and the literal
            // that closes it, above the `TemplateHead` the literal opens with. a
            // template with no substitution is one token to typescript and an empty
            // node to the tree
            var substitutions: i32 = 0;
            while (!self.atEnd() and !self.atPunct("`")) {
                if ((self.peek().?).kind == .template_end) {
                    self.pos += 1;
                    break;
                }
                const expression = try self.parseExpression();
                self.module.appendChild(node, expression);
                substitutions += 1;
                if (self.pos == from + 1) self.pos += 1;
            }
            if (substitutions > 0) {
                self.module.addDescendants(node, template_head_node + substitutions * template_span_nodes);
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
                    // `[a, , b]` writes a hole typescript keeps as an `OmittedExpression`,
                    // and the tree writes nothing. a `,` straight after the bracket or
                    // after another `,` is what leaves one
                    const previous = if (self.pos > 0) self.tokens[self.pos - 1] else null;
                    if (previous != null and (previous.?.isPunct("[") or previous.?.isPunct(","))) {
                        self.module.addDescendants(node, omitted_element_node);
                    }
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
                const angle_open = self.pos;
                const after_angle = if (angle_close + 1 < self.tokens.len) self.tokens[angle_close + 1] else null;
                if (after_angle != null and after_angle.?.isPunct("(")) {
                    if (self.matchingParen(angle_close + 1)) |params_close| {
                        const after_params = if (params_close + 1 < self.tokens.len) self.tokens[params_close + 1] else null;
                        const is_arrow = after_params != null and (after_params.?.isPunct("=>") or
                            (after_params.?.isPunct(":") and self.hasArrowAfter(params_close + 1)));
                        if (is_arrow) {
                            self.pos = angle_close + 1;
                            const arrow = try self.parseArrow(from, true, false);
                            self.module.addDescendants(arrow, self.typeParameterNodes(angle_open, angle_close + 1));
                            return arrow;
                        }
                    }
                }
            }

            // a type assertion `<T>value`, which typescript calls a
            // `TypeAssertionExpression` over the type and the operand
            self.pos += 1;
            const asserted_type = self.skipTypeNodes(.brace_starts_object);
            const operand = try self.parsePostfix();
            const node = try self.addNode(.as_expr, from);
            self.module.nodes.items[node].operator = "asserts";
            self.module.addDescendants(node, asserted_type);
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
                // `new Foo(a)` is one `NewExpression` over the callee and the arguments,
                // while the tree puts a `.call` between them and hangs the arguments off
                // it. `new Foo` and `new Foo.bar` build no call, so there is no extra
                // node to take back
                if (token.isWord("new") and self.constructionCall(operand)) {
                    self.module.addDescendants(node, construction_wrapper_node);
                }
                self.closeNode(node, from);
                return node;
            }

            if (token.isWord("function") or (token.isWord("async") and self.peekAt(1) != null and self.peekAt(1).?.isWord("function"))) {
                // `async function` is the same expression, the modifier is
                // consumed so the name lands on the node
                const functions_async = token.isWord("async");
                if (functions_async) self.pos += 1;
                self.pos += 1;
                const node = try self.addNode(.function_expr, from);
                // an `async` function expression, a named one and the `*` of a generator
                // are each a node beside the parameters and the body
                if (functions_async) self.module.addDescendants(node, modifier_node);
                if (self.atPunct("*")) {
                    self.module.addDescendants(node, modifier_node);
                    self.pos += 1;
                }
                if (!self.atEnd() and (self.peek().?).kind == .word) {
                    self.module.addDescendants(node, function_name_node);
                    self.pos += 1;
                }
                if (self.atPunct("<")) self.skipTypeCounting(node, .brace_starts_object);
                try self.parseParameterList(node);
                if (self.atPunct(":")) {
                    self.pos += 1;
                    self.skipTypeCounting(node, .return_annotation);
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
                // a dynamic `import(...)`, whose callee is the `import` keyword rather
                // than a name: typescript keeps the keyword and the specifier as the
                // call's own children, and the tree keeps neither
                self.pos += 1;
                const node = try self.addNode(.call, from);
                if (self.atPunct("(")) {
                    self.pos += 1;
                    self.module.addDescendants(node, dynamic_import_nodes);
                }
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
                    return self.parseArrow(from, false, true);
                }
                if (next != null and next.?.isPunct("(")) {
                    if (self.matchingParen(self.pos + 1)) |close_index| {
                        const after = if (close_index + 1 < self.tokens.len) self.tokens[close_index + 1] else null;
                        const is_arrow = after != null and (after.?.isPunct("=>") or
                            (after.?.isPunct(":") and self.hasArrowAfter(close_index + 1)));
                        if (is_arrow) {
                            self.pos += 1;
                            return self.parseArrow(from, true, true);
                        }
                    }
                }
                // `async <T>(x: T) => x`: the type parameters come first
                if (next != null and next.?.isPunct("<")) {
                    if (self.matchingAngle(self.pos + 1)) |angle_close| {
                        const angle_open = self.pos + 1;
                        const after_angle = if (angle_close + 1 < self.tokens.len) self.tokens[angle_close + 1] else null;
                        if (after_angle != null and after_angle.?.isPunct("(")) {
                            if (self.matchingParen(angle_close + 1)) |params_close| {
                                const after_params = if (params_close + 1 < self.tokens.len) self.tokens[params_close + 1] else null;
                                const is_arrow = after_params != null and (after_params.?.isPunct("=>") or
                                    (after_params.?.isPunct(":") and self.hasArrowAfter(params_close + 1)));
                                if (is_arrow) {
                                    self.pos = angle_close + 1;
                                    const arrow = try self.parseArrow(from, true, true);
                                    self.module.addDescendants(arrow, self.typeParameterNodes(angle_open, angle_close + 1));
                                    return arrow;
                                }
                            }
                        }
                    }
                }
            }

            // a single-parameter arrow: `x => ...`
            if (self.pos + 1 < self.tokens.len and self.tokens[self.pos + 1].isPunct("=>")) {
                return self.parseArrow(from, false, false);
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
            if (is_arrow) return self.parseArrow(from, true, false);
        }

        self.pos += 1;
        const node = try self.addNode(.paren, from);
        var operands: i32 = 0;
        while (!self.atEnd() and !self.atPunct(")")) {
            if (self.atPunct(",")) {
                self.pos += 1;
                continue;
            }
            const inner = try self.parseExpression();
            self.module.appendChild(node, inner);
            operands += 1;
        }
        if (self.atPunct(")")) self.pos += 1;
        // `(a, b)` is a `ParenthesizedExpression` over a comma expression, and one
        // `BinaryExpression` and its `CommaToken` sit between each pair of operands
        if (operands > 1) self.module.addDescendants(node, (operands - 1) * comma_operand_nodes);
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
            // `;` separates the members of a type literal, which a type argument
            // may hold: `f<{ a: string; b: number }>()` matches its angle, and
            // without it the `<` is read as a comparison and the tree grows a
            // node the walk order cannot account for
            ",", ";", ".", "?.", "[", "]", "(", ")", "{", "}", "?", ":", "|", "&", "=>", "...",
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

    fn parseArrow(self: *Parser, from: usize, parenthesised: bool, is_async: bool) anyerror!ir.NodeIndex {
        const node = try self.addNode(.arrow, from);
        // an arrow carries the `=>` itself, and an `async` in front of it is a modifier
        self.module.addDescendants(node, arrow_token_node);
        if (is_async) self.module.addDescendants(node, modifier_node);

        if (parenthesised) {
            try self.parseParameterList(node);
        } else {
            const parameter = self.addNode(.identifier, self.begin()) catch return error.OutOfMemory;
            self.module.nodes.items[parameter].name = self.peek().?.text;
            self.module.nodes.items[parameter].binding = .parameter;
            self.module.appendChild(node, parameter);
            // a bare parameter is a `Parameter` node in typescript too
            self.module.addDescendants(node, parameter_node);
            self.pos += 1;
        }

        if (self.atPunct(":")) {
            self.pos += 1;
            self.skipTypeCounting(node, .brace_starts_object);
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
        // the `async` and `*` an entry is written with, consumed one turn of the loop
        // apart: typescript keeps each as a node beside the method's name, the tree keeps
        // neither, and the loop takes `property_from` again after the `continue`, so the
        // count has to be carried across the turn that consumed it
        var method_modifiers: i32 = 0;

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
                    // `get` and `set` are the accessor's own kind rather than a node
                    if (self.peek().?.isWord("async")) method_modifiers += modifier_node;
                    self.pos += 1;
                    continue;
                }
            }
            if (self.atPunct("*")) {
                method_modifiers += modifier_node;
                self.pos += 1;
                continue;
            }

            // whatever this entry carried is settled here, method or not
            const entry_modifiers = method_modifiers;
            method_modifiers = 0;

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
                    // the entry's node and the `ComputedPropertyName` the brackets are
                    self.module.addDescendants(node, computed_key_nodes);
                }
                continue;
            }

            if (key.kind == .word) {
                const next = self.peekAt(1);
                const is_method = next != null and next.?.isPunct("(");
                self.pos += 1;
                if (is_method) {
                    // `async run() {}` and `*gen() {}` are `MethodDeclaration`s whose
                    // modifier is a node beside the name
                    const method = try self.addNode(.function_expr, property_from);
                    self.module.addDescendants(method, function_name_node + entry_modifiers);
                    self.module.appendChild(node, method);
                    try self.parseParameterList(method);
                    if (self.atPunct(":")) {
                        self.pos += 1;
                        self.skipTypeCounting(method, .return_annotation);
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
                    self.module.addDescendants(node, property_entry_nodes);
                    continue;
                }
                if (self.atPunct("=")) {
                    // a destructuring default inside an object pattern
                    self.pos += 1;
                    const value = try self.parseExpression();
                    self.module.appendChild(node, value);
                    self.module.addDescendants(node, property_entry_nodes);
                    continue;
                }
                // a shorthand `{ a }`, whose name and its `ShorthandPropertyAssignment`
                // node the tree keeps only in the literal's own source text
                self.module.addDescendants(node, property_entry_nodes);
                continue;
            }

            if (key.isLiteral()) {
                self.pos += 1;
                if (self.atPunct(":")) {
                    self.pos += 1;
                    const value = try self.parseExpression();
                    self.module.appendChild(node, value);
                    self.module.addDescendants(node, property_entry_nodes);
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

    /// whether a `new` operand's chain holds the call its callee's argument list built.
    /// the chain below a `new` runs down its first child: `new Set(x).size` puts the
    /// member above the `new` and the call below it, and `new Foo.bar` builds no call at
    /// all
    fn constructionCall(self: *const Parser, operand: ir.NodeIndex) bool {
        var current = operand;
        while (true) {
            switch (self.module.kindOf(current)) {
                .call => return true,
                .member => current = self.module.firstChildOf(current) orelse return false,
                else => return false,
            }
        }
    }

    /// consume a type expression and return the TypeScript nodes it stands for: the
    /// tree keeps a type as an extent, and the count the gate compares includes every
    /// node inside it
    fn skipTypeNodes(self: *Parser, stop: TypeStop) i32 {
        const type_from = self.pos;
        self.skipType(stop);
        if (type_from == self.pos) return 0;
        return @intCast(typecount.subtreeSize(self.source, self.tokens, type_from, self.pos));
    }

    /// consume a type expression and record its nodes on the node that owns it
    fn skipTypeCounting(self: *Parser, owner: ir.NodeIndex, stop: TypeStop) void {
        self.module.addDescendants(owner, self.skipTypeNodes(stop));
    }

    /// the nodes a `<...>` type-argument list stands for, which no node wraps: the
    /// list is the callee's own `typeArguments`, and the tree drops it whole
    fn typeArgumentNodes(self: *Parser, open: usize, limit: usize) i32 {
        return @intCast(typecount.typeArgumentCount(self.source, self.tokens, open, limit));
    }

    /// the `TypeParameter` nodes a `<...>` list stands for. the extent `skipType` walks
    /// is bounded by the tokens that follow it, while a type-parameter list is bounded
    /// by its own `>`, so the closer is found from the `<` here instead
    fn typeParameterNodes(self: *Parser, open: usize, limit: usize) i32 {
        return @intCast(typecount.typeParameterCount(self.source, self.tokens, open, limit));
    }

    /// the nodes a `<...>` list at the cursor stands for, for the callers that then walk
    /// the extent `skipType` sees: that extent runs on past the `>` into whatever
    /// follows, so the closer is found from the `<` and never from the extent
    fn typeParameterNodesAt(self: *Parser, open: usize) i32 {
        const close = self.matchingAngle(open) orelse return 0;
        return self.typeParameterNodes(open, close + 1);
    }

    /// the nodes an `implements` clause stands for: the `HeritageClause` over one
    /// `ExpressionWithTypeArguments` per type, which is the count the type counter
    /// reads from the clause's own extent
    fn heritageNodes(self: *Parser, from: usize, to: usize) i32 {
        return @intCast(typecount.heritageCount(self.source, self.tokens, from, to));
    }

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

/// one code point of a UTF-8 slice and the bytes it occupies
pub const Codepoint = struct {
    codepoint: u21,
    width: usize,
};

/// the code point at `index`, or the byte itself when it begins no sequence the
/// encoding accepts. a source the lexer accepted is walked without the fallback,
/// which is what keeps a malformed byte from shortening the walk
///
/// the encoding read is the one that also holds a surrogate, because
/// `decodeStringLiteral` writes a lone `\uD800` as the three bytes it stands
/// for, and a reader that stopped at the byte after it would count a literal's
/// length wrong
pub fn decodeCodepoint(text: []const u8, index: usize) Codepoint {
    const width = std.unicode.utf8ByteSequenceLength(text[index]) catch return .{ .codepoint = text[index], .width = 1 };
    if (index + width > text.len) return .{ .codepoint = text[index], .width = 1 };
    const codepoint = std.unicode.wtf8Decode(text[index..][0..width]) catch return .{ .codepoint = text[index], .width = 1 };
    return .{ .codepoint = codepoint, .width = width };
}

/// the last code point below the astral planes, and the two counts a JavaScript
/// string can hold for one code point: one UTF-16 code unit, or the surrogate
/// pair the astral planes are held as
const last_basic_plane_codepoint: u21 = 0xffff;
const utf16_basic_units: usize = 1;
const utf16_astral_units: usize = 2;

/// the UTF-16 code units one code point occupies, which is what a JavaScript
/// string's own `length` reads
pub fn utf16Units(codepoint: u21) usize {
    return if (codepoint > last_basic_plane_codepoint) utf16_astral_units else utf16_basic_units;
}

/// a cooked string literal's byte length and its length in UTF-16 code units
pub const Cooked = struct {
    len: usize,
    units: usize,
};

/// what one escape sequence contributes to a cooked value
const Escape = struct {
    kind: Kind = .dropped,
    /// the code point the sequence stands for, when it stands for one
    codepoint: u21 = 0,
    /// the characters the sequence reads as when it stands for no code point,
    /// which is the sequence without its backslash
    text: []const u8 = "",
    /// how many bytes of the raw text the sequence occupies
    length: usize = minimum_escape_length,

    const Kind = enum { dropped, codepoint, text };
};

const escape_marker = '\\';
const escape_marker_length = 1;
/// the shortest escape there is: a backslash and the character it stands for
const minimum_escape_length = escape_marker_length + 1;
const maximum_codepoint_width = 4;
const last_codepoint: u21 = 0x10ffff;
const maximum_braced_digits = 6;
/// the two line separators outside the ASCII set, which end a line rather than
/// standing for themselves when a backslash precedes them
const line_separator_codepoint: u21 = 0x2028;
const paragraph_separator_codepoint: u21 = 0x2029;

/// the value a string literal's raw source slice cooks to, with every escape
/// replaced by the character it stands for
///
/// `raw` spans the delimiters, so a quoted literal passes its whole token text
/// and a template passes the source from its opening backtick to its closing one
/// `destination` must hold `raw.len` bytes, which is the longest a cooked value
/// can be: every escape is at least as long as the character it stands for
///
/// the units count is what a JavaScript string's own `length` reads, and a
/// rule's length gate is measured in those rather than in bytes, so a literal
/// holding an astral character counts it twice
///
/// a lone surrogate is kept as the three bytes it stands for rather than
/// replaced, so two different lone surrogates never cook to one value
///
/// the lexer accepts text the language does not, so a malformed escape reads as
/// its own characters rather than aborting the walk
pub fn decodeStringLiteral(destination: []u8, raw: []const u8) Cooked {
    const delimiter_width = 1;
    const content = if (raw.len >= 2 * delimiter_width) raw[delimiter_width .. raw.len - delimiter_width] else raw[0..0];

    var written: usize = 0;
    var units: usize = 0;
    var index: usize = 0;
    while (index < content.len) {
        if (content[index] == escape_marker) {
            const escape = readEscape(content, index);
            switch (escape.kind) {
                .dropped => {},
                .codepoint => appendCodepoint(destination, &written, &units, escape.codepoint),
                .text => appendText(destination, &written, &units, escape.text),
            }
            index += escape.length;
            continue;
        }
        const decoded = decodeCodepoint(content, index);
        appendText(destination, &written, &units, content[index..][0..decoded.width]);
        index += decoded.width;
    }
    return .{ .len = written, .units = units };
}

/// the escape sequence beginning at the backslash at `start`, read the way the
/// language reads it: the single character escapes, `\xHH`, `\uHHHH`, `\u{...}`,
/// a backslash that ends a line contributing nothing, and any other character
/// standing for itself
///
/// a high surrogate escape followed by a low surrogate escape spells one code
/// point, which is what the two code units together are to a JavaScript string:
/// a key that held them apart would read a character and its escaped spelling as
/// two different values
fn readEscape(content: []const u8, start: usize) Escape {
    const escape = readSingleEscape(content, start);
    if (escape.kind != .codepoint) return escape;
    if (!isHighSurrogate(escape.codepoint)) return escape;

    const next_start = start + escape.length;
    if (next_start >= content.len or content[next_start] != escape_marker) return escape;
    const next = readSingleEscape(content, next_start);
    if (next.kind != .codepoint or !isLowSurrogate(next.codepoint)) return escape;

    return .{
        .kind = .codepoint,
        .codepoint = combineSurrogates(escape.codepoint, next.codepoint),
        .length = escape.length + next.length,
    };
}

/// the first ten bits of a surrogate pair and the offset its halves carry
const surrogate_shift: u21 = 10;
const high_surrogate_start: u21 = 0xd800;
const low_surrogate_start: u21 = 0xdc00;
const low_surrogate_end: u21 = 0xdfff;
/// where the astral planes begin, which is what a pair spells above the ten bits
/// each half carries
const astral_base: u21 = 0x10000;

fn isHighSurrogate(codepoint: u21) bool {
    return codepoint >= high_surrogate_start and codepoint < low_surrogate_start;
}

fn isLowSurrogate(codepoint: u21) bool {
    return codepoint >= low_surrogate_start and codepoint <= low_surrogate_end;
}

/// the code point a high surrogate and the low surrogate after it spell
fn combineSurrogates(high: u21, low: u21) u21 {
    return astral_base + ((high - high_surrogate_start) << surrogate_shift) + (low - low_surrogate_start);
}

/// one escape sequence, without the pairing above
fn readSingleEscape(content: []const u8, start: usize) Escape {
    if (start + minimum_escape_length > content.len) return readStandaloneEscape(content, start);

    return switch (content[start + escape_marker_length]) {
        'n' => Escape{ .kind = .codepoint, .codepoint = '\n' },
        't' => Escape{ .kind = .codepoint, .codepoint = '\t' },
        'r' => Escape{ .kind = .codepoint, .codepoint = '\r' },
        'b' => Escape{ .kind = .codepoint, .codepoint = 0x08 },
        'f' => Escape{ .kind = .codepoint, .codepoint = 0x0c },
        'v' => Escape{ .kind = .codepoint, .codepoint = 0x0b },
        '0' => Escape{ .kind = .codepoint, .codepoint = 0 },
        'x' => readHexEscape(content, start),
        'u' => readUnicodeEscape(content, start),
        // a backslash at the end of a line contributes nothing, and a carriage
        // return carries its newline with it
        '\r' => Escape{ .kind = .dropped, .length = if (start + 3 <= content.len and content[start + 2] == '\n') 3 else 2 },
        '\n' => Escape{ .kind = .dropped, .length = 2 },
        // any other character stands for itself, which covers the quotes, the
        // backslash itself and a digit an octal escape would have used
        else => readStandaloneEscape(content, start),
    };
}

/// `\xHH`, exactly two hexadecimal digits
fn readHexEscape(content: []const u8, start: usize) Escape {
    const prefix_length = "\\x".len;
    const digit_count = 2;
    const value = readHexDigits(content, start + prefix_length, digit_count) orelse return readStandaloneEscape(content, start);
    return .{ .kind = .codepoint, .codepoint = value, .length = prefix_length + digit_count };
}

/// `\uHHHH` or `\u{H...}`, the two spellings the language accepts, the second
/// naming one code point in one to six digits
///
/// a braced escape past the last code point is not one the encoding can hold, so
/// it reads as its own characters, and this is the only arm that has to say so:
/// no other spelling of an escape reaches above the last code unit, and the pair
/// of two surrogates spells at most the last code point
fn readUnicodeEscape(content: []const u8, start: usize) Escape {
    const prefix_length = "\\u".len;
    const digits_start = start + prefix_length;
    if (digits_start >= content.len or content[digits_start] != '{') {
        const digit_count = 4;
        const value = readHexDigits(content, digits_start, digit_count) orelse return readStandaloneEscape(content, start);
        return .{ .kind = .codepoint, .codepoint = value, .length = prefix_length + digit_count };
    }

    const braced_start = digits_start + 1;
    const closing = std.mem.indexOfScalarPos(u8, content, braced_start, '}') orelse return readStandaloneEscape(content, start);
    const digit_count = closing - braced_start;
    if (digit_count == 0 or digit_count > maximum_braced_digits) return readStandaloneEscape(content, start);
    const value = readHexDigits(content, braced_start, digit_count) orelse return readStandaloneEscape(content, start);
    if (value > last_codepoint) return readStandaloneEscape(content, start);
    return .{ .kind = .codepoint, .codepoint = value, .length = closing + 1 - start };
}

/// `count` hexadecimal digits at `start`, or null when the text holds no such run
fn readHexDigits(content: []const u8, start: usize, count: usize) ?u21 {
    if (start + count > content.len) return null;
    var value: u21 = 0;
    for (content[start..][0..count]) |digit| {
        const nibble = std.fmt.charToDigit(digit, 16) catch return null;
        value = value * 16 + nibble;
    }
    return value;
}

/// a backslash with no escape of its own: the character after it stands for
/// itself, which is also what the characters of a malformed escape are read as
///
/// a line separator after the backslash ends the line instead and contributes
/// nothing, the way the newline and the carriage return above do
fn readStandaloneEscape(content: []const u8, start: usize) Escape {
    const text_start = start + escape_marker_length;
    if (text_start >= content.len) return .{ .kind = .dropped, .length = content.len - start };
    const decoded = decodeCodepoint(content, text_start);
    const length = escape_marker_length + decoded.width;
    if (decoded.codepoint == line_separator_codepoint or decoded.codepoint == paragraph_separator_codepoint) {
        return .{ .kind = .dropped, .length = length };
    }
    return .{ .kind = .text, .text = content[text_start..][0..decoded.width], .length = length };
}

/// write `text` and count the UTF-16 units a JavaScript string adds for it
fn appendText(destination: []u8, written: *usize, units: *usize, text: []const u8) void {
    @memcpy(destination[written.*..][0..text.len], text);
    written.* += text.len;
    var index: usize = 0;
    while (index < text.len) {
        const decoded = decodeCodepoint(text, index);
        units.* += utf16Units(decoded.codepoint);
        index += decoded.width;
    }
}

/// write one code point and count its UTF-16 units, keeping a code point the
/// encoding holds only as a surrogate
///
/// the four bytes it may write are inside the buffer: a cooked value is never
/// longer than the raw text it came from, so `written` sits at least the
/// escape's own two bytes below the end of a buffer that holds the whole raw
/// slice
///
/// the encoder refuses nothing: `readUnicodeEscape` is where an escape past the
/// last code point stops being one, and every other reading of an escape is at
/// most a code unit
fn appendCodepoint(destination: []u8, written: *usize, units: *usize, codepoint: u21) void {
    const width = std.unicode.wtf8Encode(codepoint, destination[written.*..][0..maximum_codepoint_width]) catch return;
    written.* += width;
    units.* += utf16Units(codepoint);
}

/// the cooked value of `raw`, allocated, with the caller's side of the decoder's
/// contract checked as it goes
fn cookedValue(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    const buffer = try allocator.alloc(u8, raw.len);
    defer allocator.free(buffer);
    const cooked = decodeStringLiteral(buffer, raw);
    // a cooked value is never longer than the raw text, in bytes or in UTF-16
    // units, which is what lets the decoder write one code point at a time into
    // a buffer the size of the raw slice
    try testing.expect(cooked.len <= raw.len);
    try testing.expect(cooked.units <= cooked.len);
    return allocator.dupe(u8, buffer[0..cooked.len]);
}

/// the UTF-16 length the decoder reads for `raw`
fn cookedUnits(allocator: std.mem.Allocator, raw: []const u8) !usize {
    const buffer = try allocator.alloc(u8, raw.len);
    defer allocator.free(buffer);
    return decodeStringLiteral(buffer, raw).units;
}

test "the decoder reads every escape the language spells" {
    const a = testing.allocator;
    const cases = [_]struct { raw: []const u8, cooked: []const u8 }{
        // the delimiters come off, whichever the literal was written with
        .{ .raw = "'plain'", .cooked = "plain" },
        .{ .raw = "\"plain\"", .cooked = "plain" },
        .{ .raw = "`plain`", .cooked = "plain" },
        .{ .raw = "''", .cooked = "" },
        // the single character escapes
        .{ .raw = "'a\\nb'", .cooked = "a\nb" },
        .{ .raw = "'a\\tb'", .cooked = "a\tb" },
        .{ .raw = "'a\\rb'", .cooked = "a\rb" },
        .{ .raw = "'a\\bb'", .cooked = "a\x08b" },
        .{ .raw = "'a\\fb'", .cooked = "a\x0cb" },
        .{ .raw = "'a\\vb'", .cooked = "a\x0bb" },
        .{ .raw = "'a\\0b'", .cooked = "a\x00b" },
        // the two digit and the four digit spellings, and the braced one, which
        // names a code point rather than a code unit
        .{ .raw = "'\\x41\\x7a'", .cooked = "Az" },
        .{ .raw = "'\\u0041\\u007a'", .cooked = "Az" },
        .{ .raw = "'\\u{41}\\u{7a}'", .cooked = "Az" },
        .{ .raw = "'\\u{1f600}'", .cooked = "\u{1f600}" },
        // a backslash before a character with no escape of its own stands for
        // that character, which covers the quotes, the backslash, and a digit an
        // octal escape would have used
        .{ .raw = "'\\\\'", .cooked = "\\" },
        .{ .raw = "'\\''", .cooked = "'" },
        .{ .raw = "\"\\\"\"", .cooked = "\"" },
        .{ .raw = "`\\``", .cooked = "`" },
        .{ .raw = "'\\q'", .cooked = "q" },
        .{ .raw = "'\\8'", .cooked = "8" },
        // a backslash ending a line contributes nothing, carriage return
        // included, and so does one before a line separator
        .{ .raw = "'a\\\nb'", .cooked = "ab" },
        .{ .raw = "'a\\\r\nb'", .cooked = "ab" },
        .{ .raw = "'a\\\u{2028}b'", .cooked = "ab" },
        // a code point written directly is the code point
        .{ .raw = "'caf\u{e9}'", .cooked = "caf\u{e9}" },
    };
    for (cases) |case| {
        const cooked = try cookedValue(a, case.raw);
        defer a.free(cooked);
        try testing.expectEqualStrings(case.cooked, cooked);
    }
}

test "the decoder counts a literal's length in UTF-16 units" {
    const a = testing.allocator;
    const cases = [_]struct { raw: []const u8, units: usize }{
        .{ .raw = "''", .units = 0 },
        .{ .raw = "'abcd'", .units = 4 },
        // an escape contributes the character it stands for rather than the
        // bytes it is written with
        .{ .raw = "'a\\nb'", .units = 3 },
        .{ .raw = "'\\u0041'", .units = 1 },
        // one code point written directly, in two bytes and in four
        .{ .raw = "'\u{e9}'", .units = 1 },
        .{ .raw = "'\u{1f600}'", .units = 2 },
        // the astral planes by each spelling: a braced escape, a surrogate pair
        // of two escapes, and a lone surrogate, which is one unit
        .{ .raw = "'\\u{1f600}'", .units = 2 },
        .{ .raw = "'\\u{10ffff}'", .units = 2 },
        .{ .raw = "'\\uD83D\\uDE00'", .units = 2 },
        .{ .raw = "'\\uD83D'", .units = 1 },
    };
    for (cases) |case| {
        try testing.expectEqual(case.units, try cookedUnits(a, case.raw));
    }
}

test "the decoder reads one value from either spelling of one literal" {
    const a = testing.allocator;
    const double_quoted = try cookedValue(a, "\"It's done.\"");
    defer a.free(double_quoted);
    const single_quoted = try cookedValue(a, "'It\\'s done.'");
    defer a.free(single_quoted);

    // a detector keying on the cooked value sees one string here, and a rule
    // comparing the raw slices would see two
    const expected = "It's done.";
    try testing.expectEqualStrings(expected, double_quoted);
    try testing.expectEqualStrings(expected, single_quoted);
}

test "the decoder keeps a lone surrogate as the three bytes it stands for" {
    const a = testing.allocator;
    const first = try cookedValue(a, "'\\uD800'");
    defer a.free(first);
    const second = try cookedValue(a, "'\\uD801'");
    defer a.free(second);

    const surrogate_bytes = 3;
    try testing.expectEqual(surrogate_bytes, first.len);
    try testing.expectEqual(surrogate_bytes, second.len);
    // two lone surrogates are two values, which one replacement character for
    // either of them would not produce
    try testing.expect(!std.mem.eql(u8, first, second));

    // and the two halves of a pair are not two characters: they spell one code
    // point, in four bytes and two units
    const pair = try cookedValue(a, "'\\uD83D\\uDE00'");
    defer a.free(pair);
    const astral_bytes = 4;
    try testing.expectEqual(astral_bytes, pair.len);
    try testing.expectEqualStrings("\u{1f600}", pair);
}

test "a malformed escape reads as its own characters rather than aborting the walk" {
    const a = testing.allocator;
    // the lexer skips an escape without reading it, so text the language rejects
    // reaches the decoder, which reads it the way a reader of the source would
    const cases = [_]struct { raw: []const u8, cooked: []const u8 }{
        .{ .raw = "'\\xZZ'", .cooked = "xZZ" },
        .{ .raw = "'\\x4'", .cooked = "x4" },
        .{ .raw = "'\\uZZZZ'", .cooked = "uZZZZ" },
        .{ .raw = "'\\u12'", .cooked = "u12" },
        .{ .raw = "'\\u{}'", .cooked = "u{}" },
        .{ .raw = "'\\u{'", .cooked = "u{" },
        .{ .raw = "'\\u{110000}'", .cooked = "u{110000}" },
        .{ .raw = "'\\u{1234567}'", .cooked = "u{1234567}" },
        // a backslash with nothing after it stands for nothing
        .{ .raw = "'\\", .cooked = "" },
    };
    for (cases) |case| {
        const cooked = try cookedValue(a, case.raw);
        defer a.free(cooked);
        try testing.expectEqualStrings(case.cooked, cooked);
    }
}

fn isModifier(text: []const u8) bool {
    return contains(&member_modifiers, text);
}

/// which member modifiers are nodes of their own: `get` and `set` are the accessor kinds
/// rather than modifiers, so neither adds a node
fn isModifierNode(text: []const u8) bool {
    return !std.mem.eql(u8, text, "get") and !std.mem.eql(u8, text, "set");
}

/// whether a word token is a keyword rather than a name. the parser asks this to
/// tell a reference from a modifier, and the project pass asks it to tell the
/// names a file mentions from the keywords it is written with
pub fn isNonReference(text: []const u8) bool {
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

test "parse keeps a declarator's initializer when its own annotation spells a function type" {
    const allocator = testing.allocator;
    // the annotation holds a `=>` of its own, and the `=` that introduces the value is the
    // only terminator that ends it
    // reading the annotation's `=>` as the one that owns a body left the declaration
    // ending at its type, re-parsed the arrow as a stray statement and reported an
    // unmodelled node
    const source =
        \\const assert: (condition: boolean, message: string) => asserts condition = (
        \\  condition,
        \\  message,
        \\) => {
        \\  if (!condition) {
        \\    fail(message);
        \\  }
        \\};
        \\
    ;
    var module = try parse(allocator, source);
    defer module.deinit();

    try testing.expectEqual(@as(usize, 0), module.unknownCount());

    // one declaration, whose children are the declarator's name and the arrow, and the
    // arrow's last child is the block the body is
    var declaration: ?ir.NodeIndex = null;
    var walker = module.iterator();
    while (walker.next()) |index| {
        if (module.kindOf(index) == .variable_decl) declaration = index;
    }
    try testing.expect(declaration != null);
    try testing.expectEqual(@as(usize, 2), module.childCount(declaration.?));

    const name = module.firstChildOf(declaration.?);
    try testing.expectEqual(ir.Kind.identifier, module.kindOf(name.?));
    try testing.expectEqualStrings("assert", module.nodeOf(name.?).name);

    const initializer = module.nextSiblingOf(name.?);
    try testing.expectEqual(ir.Kind.arrow, module.kindOf(initializer.?));
    try testing.expectEqual(ir.Kind.block, module.kindOf(module.bodyOf(initializer.?).?));

    // and the declared type still runs to its own last token, so the declaration's extent
    // is the whole statement
    try testing.expectEqualStrings(source[0 .. source.len - 1], module.textOf(declaration.?));
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

test "parse reads a return annotation that spells a function type, and still stops at the body" {
    const allocator = testing.allocator;
    // the annotation holds a `=>` of its own, because that is how a function type is
    // spelled, and the token that owns the body is still the `{`
    // reading the annotation's `=>` as the body's ended the type at the arrow, left the
    // method without a body and re-parsed what followed as class member syntax, which
    // orphaned a node and took the whole process down in `walkOrder`
    //
    // `unsupported` is the assertion that catches an orphan: `unknownCount` reaches only
    // what hangs off the root, and the unmodelled `=>` was never appended to a parent
    const source =
        \\class Ledger {
        \\  private handler: (value: number) => number;
        \\
        \\  private formatter: (value: number) => string = (value) => String(value);
        \\
        \\  m(): (value: number) => number {
        \\    return (value) => value + 1;
        \\  }
        \\}
        \\
        \\function returnsFn(): (value: number) => number {
        \\  return (value) => value + 1;
        \\}
        \\
    ;
    var module = try parse(allocator, source);
    defer module.deinit();

    try testing.expectEqual(@as(u32, 0), module.unsupported);
    try testing.expectEqual(@as(usize, 0), module.unknownCount());

    // the member's own annotation is a type rather than a body, so the class holds exactly
    // the one block its method declares
    var blocks: usize = 0;
    var declarations: usize = 0;
    var walker = module.iterator();
    while (walker.next()) |index| {
        if (module.kindOf(index) == .block) blocks += 1;
        if (module.kindOf(index) != .function_decl) continue;
        declarations += 1;
        const body = module.bodyOf(index);
        try testing.expect(body != null);
        try testing.expectEqual(ir.Kind.block, module.kindOf(body.?));
        const statement = module.firstChildOf(body.?);
        try testing.expect(statement != null);
        try testing.expectEqual(ir.Kind.return_stmt, module.kindOf(statement.?));
    }
    try testing.expectEqual(@as(usize, 2), declarations);
    try testing.expectEqual(@as(usize, 2), blocks);

    // and the annotation runs to its own last token, so the member that carries one keeps
    // the arrow its `=` introduces
    var initializer: ?ir.NodeIndex = null;
    var second = module.iterator();
    while (second.next()) |index| {
        if (module.kindOf(index) == .arrow) {
            if (initializer == null) initializer = index;
        }
    }
    try testing.expect(initializer != null);
    const default_body = module.bodyOf(initializer.?) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("String(value)", module.expressionText(default_body));
}

test "parse consumes a parameter's function-type annotation, and names no binding from it" {
    const allocator = testing.allocator;
    // the annotation ends at the `=` that introduces the default, and the `=>` inside it is
    // the type's own arrow
    // stopping at the arrow left the type's tail to the parameter list, which read
    // `string` as a second parameter's name
    const source =
        \\function withDefault(
        \\  formatter: (value: number) => string = (value) => String(value),
        \\): string {
        \\  return formatter(1);
        \\}
        \\
    ;
    var module = try parse(allocator, source);
    defer module.deinit();

    try testing.expectEqual(@as(u32, 0), module.unsupported);
    try testing.expectEqual(@as(usize, 0), module.unknownCount());

    // `formatter` is the parameter and `value` belongs to the default's own arrow: the
    // declared type contributes no name at all
    // the array takes more than the two are, so a third name fails the
    // count rather than a bounds guard
    var names: [4][]const u8 = undefined;
    var found: usize = 0;
    var walker = module.iterator();
    while (walker.next()) |index| {
        const node = module.nodeOf(index);
        if (node.binding != .parameter) continue;
        try testing.expect(found < names.len);
        names[found] = node.name;
        found += 1;
    }
    try testing.expectEqual(@as(usize, 2), found);
    std.mem.sort([]const u8, names[0..found], {}, struct {
        fn lessThan(_: void, left: []const u8, right: []const u8) bool {
            return std.mem.lessThan(u8, left, right);
        }
    }.lessThan);
    try testing.expectEqualStrings("formatter", names[0]);
    try testing.expectEqualStrings("value", names[1]);
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

test "parse models a type argument that holds a multi-member type literal" {
    const allocator = testing.allocator;
    const source =
        \\const widest = list.reduce<{ readonly url: string; readonly width: number } | undefined>((w, c) => w, undefined);
        \\const grouped = new Map<{ channel: string; tag: string }, number>();
        \\
    ;
    var module = try parse(allocator, source);
    defer module.deinit();

    try testing.expectEqual(@as(usize, 0), module.unknownCount());

    var calls: usize = 0;
    var walker = module.iterator();
    while (walker.next()) |index| {
        if (module.kindOf(index) == .call) calls += 1;
    }
    // one call each, so the `<` opened type arguments rather than a comparison
    try testing.expectEqual(@as(usize, 2), calls);

    // the walk visits every node exactly once, which an unmatched angle broke:
    // the assert inside `walkOrder` is what the regression reported
    const order = try module.walkOrder(allocator);
    defer allocator.free(order);
    try testing.expect(order.len > 0);
}

test "parse models a type argument in a class heritage clause" {
    const allocator = testing.allocator;
    const source =
        \\class First extends Base<{ readonly url: string; readonly width: number } | undefined> {}
        \\class Second extends Base<string, number> {}
        \\const Third = class extends Base<{ a: string; b: number }> {};
        \\
    ;
    var module = try parse(allocator, source);
    defer module.deinit();

    try testing.expectEqual(@as(usize, 0), module.unknownCount());

    var classes: usize = 0;
    var walker = module.iterator();
    while (walker.next()) |index| {
        if (module.kindOf(index) == .class_decl) classes += 1;
    }
    try testing.expectEqual(@as(usize, 3), classes);

    // the walk visits every node exactly once, which an unmatched angle broke
    const order = try module.walkOrder(allocator);
    defer allocator.free(order);
    try testing.expect(order.len > 0);
}

test "parse reads a brace pair inside a template's substitution" {
    const allocator = testing.allocator;
    const source =
        \\const empty = `${ {} }`;
        \\const built = `${gifOf({ name: "x" })}`;
        \\const nested = `${f({ a: { b: 1 } })}`;
        \\const counted = parse(`${fileTextOf([pressOf({})])}\n`).length;
        \\
    ;
    var module = try parse(allocator, source);
    defer module.deinit();

    // `unsupported` rather than `unknownCount` alone: the container used to end at
    // the object literal's `}`, which left the rest of the substitution, the
    // template's own closing backtick and the statement's `;` as nodes
    // `parseUnknown` added without a parent. `unknownCount` walks from the root, so
    // it cannot reach an orphan, and the walk's own node-count assert is what
    // reported this one instead: `grimuah check` aborted before it printed a row
    try testing.expectEqual(@as(usize, 0), module.unsupported);
    try testing.expectEqual(@as(usize, 0), module.unknownCount());

    // four templates, each holding its substitution's own expression
    var templates: usize = 0;
    var objects: usize = 0;
    var walker = module.iterator();
    while (walker.next()) |index| {
        if (module.kindOf(index) == .template) {
            templates += 1;
            try testing.expectEqual(@as(usize, 1), module.childCount(index));
        }
        if (module.kindOf(index) == .object_literal) objects += 1;
    }
    try testing.expectEqual(@as(usize, 4), templates);
    // one for three of the substitutions and two for the nested one, whose inner
    // pair is its own object literal
    const object_literals: usize = 5;
    try testing.expectEqual(object_literals, objects);
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
            // the orphan test is not the unknown count again: an orphaned node is
            // unreachable from the root, so a file whose container lexing truncated
            // its tokens reads as `unknown == 0` here and takes the assert inside
            // `walkOrder` down at lint time instead. `grimuah check` aborted on
            // sleepy's gateway before this test could say a word about it
            const orphaned = module.hasOrphanedNode();
            if (!orphaned and unknown == 0 and firstUncoveredByte(source, module.coveredEnd()) == null) continue;
            unknown_files += 1;
            unknown_nodes += unknown;
            if (unknown_files > 40) continue;
            if (orphaned) {
                std.debug.print("sweep: {s}: an orphaned node, which no unknown count sees\n", .{entry.path});
                continue;
            }
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

/// the descendants typescript reports for one expression, read from typescript 6.0.3
/// with the detector's own `countNodes`, which is `ts.forEachChild` over the node. the
/// front-end has to report the same number for the node it builds in the expression's
/// place, because the rule's gate is a floor over that count
const subtree_rows = [_]struct { expression: []const u8, count: u32 }{
    .{ .expression = "a", .count = 0 },
    .{ .expression = "1", .count = 0 },
    .{ .expression = "\"s\"", .count = 0 },
    .{ .expression = "true", .count = 0 },
    .{ .expression = "this", .count = 0 },
    .{ .expression = "null", .count = 0 },
    .{ .expression = "/x/", .count = 0 },
    .{ .expression = "a.b", .count = 2 },
    .{ .expression = "a?.b", .count = 3 },
    .{ .expression = "a[b]", .count = 2 },
    .{ .expression = "a[b.c]", .count = 4 },
    .{ .expression = "a.b.c", .count = 4 },
    .{ .expression = "a.b!.c", .count = 5 },
    .{ .expression = "a!", .count = 1 },
    .{ .expression = "a++", .count = 1 },
    .{ .expression = "++a", .count = 1 },
    .{ .expression = "-a", .count = 1 },
    .{ .expression = "!a", .count = 1 },
    .{ .expression = "typeof a", .count = 1 },
    .{ .expression = "void a", .count = 1 },
    .{ .expression = "delete a.b", .count = 3 },
    .{ .expression = "await a", .count = 1 },
    .{ .expression = "f()", .count = 1 },
    .{ .expression = "f(a)", .count = 2 },
    .{ .expression = "f(a, b)", .count = 3 },
    .{ .expression = "a.b(c)", .count = 4 },
    .{ .expression = "f<T>(a)", .count = 4 },
    .{ .expression = "f<Map<string, number>>(a)", .count = 6 },
    .{ .expression = "import(\"m\")", .count = 2 },
    .{ .expression = "new Foo", .count = 1 },
    .{ .expression = "new Foo(1)", .count = 2 },
    .{ .expression = "new Foo<T>(1)", .count = 4 },
    .{ .expression = "a + b", .count = 3 },
    .{ .expression = "a = b", .count = 3 },
    .{ .expression = "a += b", .count = 3 },
    .{ .expression = "a ?? b", .count = 3 },
    .{ .expression = "a instanceof b", .count = 3 },
    .{ .expression = "a ? b : c", .count = 5 },
    .{ .expression = "a as T", .count = 3 },
    .{ .expression = "a as Map<string, number>", .count = 5 },
    .{ .expression = "a as const", .count = 3 },
    .{ .expression = "`a${b}c`", .count = 4 },
    .{ .expression = "`${a}${b}`", .count = 7 },
    .{ .expression = "`abc`", .count = 0 },
    .{ .expression = "(a)", .count = 1 },
    .{ .expression = "((a))", .count = 2 },
    .{ .expression = "(a, b)", .count = 4 },
    .{ .expression = "(a, b, c)", .count = 7 },
    .{ .expression = "[a, b]", .count = 2 },
    .{ .expression = "[]", .count = 0 },
    .{ .expression = "[a, ...b]", .count = 3 },
    .{ .expression = "[, a]", .count = 2 },
    .{ .expression = "[a, , b]", .count = 3 },
    .{ .expression = "f(...a)", .count = 3 },
    .{ .expression = "({ a: 1 })", .count = 4 },
    .{ .expression = "({ a })", .count = 3 },
    .{ .expression = "({ a, b })", .count = 5 },
    .{ .expression = "({ a: b, c: d })", .count = 7 },
    .{ .expression = "({ ...a })", .count = 3 },
    .{ .expression = "({ [a]: b })", .count = 5 },
    .{ .expression = "({ [a.b]: c })", .count = 7 },
    .{ .expression = "({ a() {} })", .count = 4 },
    .{ .expression = "({ get x() { return 1; } })", .count = 6 },
    .{ .expression = "({ async run() {} })", .count = 5 },
    .{ .expression = "({ *gen() {} })", .count = 5 },
    .{ .expression = "({ async *gen() {} })", .count = 6 },
    .{ .expression = "({ async() {} })", .count = 4 },
    .{ .expression = "({ a: () => b })", .count = 6 },
    .{ .expression = "a => a", .count = 4 },
    .{ .expression = "(a) => a", .count = 4 },
    .{ .expression = "() => a", .count = 2 },
    .{ .expression = "(a: T) => a", .count = 6 },
    .{ .expression = "(a: T, b: U) => a", .count = 10 },
    .{ .expression = "(...a: T[]) => a", .count = 8 },
    .{ .expression = "(a = 1) => a", .count = 5 },
    .{ .expression = "(a?: T) => a", .count = 7 },
    .{ .expression = "(a): T => a", .count = 6 },
    .{ .expression = "async (a) => a", .count = 5 },
    .{ .expression = "async a => a", .count = 5 },
    .{ .expression = "<T>(a: T) => a", .count = 8 },
    .{ .expression = "function () {}", .count = 1 },
    .{ .expression = "function named() {}", .count = 2 },
    .{ .expression = "function (a) { return a; }", .count = 5 },
    .{ .expression = "function (a: T): U { return a; }", .count = 9 },
    .{ .expression = "async function () {}", .count = 2 },

    // statements and declarations. these are the shapes a site's subtree reaches only
    // through a callable body, and the deltas they need are checked by the same rows
    .{ .expression = "f(() => { const x = 1; return x; })", .count = 11 },
    .{ .expression = "(() => { const x = 1; return x; })", .count = 10 },
    .{ .expression = "(() => { const x = 1, y = 2; return x + y; })", .count = 16 },
    .{ .expression = "(() => { let x: string = \"a\"; return x; })", .count = 11 },
    .{ .expression = "(() => { const { a, b } = c; return a; })", .count = 14 },
    .{ .expression = "(() => { const { a: c } = d; return c; })", .count = 13 },
    .{ .expression = "(() => { const { type } = c; return 1; })", .count = 12 },
    .{ .expression = "((type: T) => g(type))", .count = 9 },
    .{ .expression = "(() => { const { a: type } = c; return a; })", .count = 13 },
    .{ .expression = "(() => { const { a: { b } } = c; return b; })", .count = 15 },
    .{ .expression = "(() => { const [a, b] = c; return a; })", .count = 14 },
    .{ .expression = "(() => { const [a, , b] = c; return a; })", .count = 15 },
    .{ .expression = "(() => { const [a, ...rest] = c; return a; })", .count = 15 },
    .{ .expression = "(() => { const { a = 1 } = c; return a; })", .count = 13 },
    .{ .expression = "(() => { const { ...rest } = c; return rest; })", .count = 13 },
    .{ .expression = "(() => { const { \"s\": v } = c; return v; })", .count = 13 },
    .{ .expression = "(() => { const [a, [b]] = c; return b; })", .count = 16 },
    .{ .expression = "(() => { try { g(); } catch (error) { return error; } })", .count = 14 },
    .{ .expression = "(() => { try { g(); } catch (error: unknown) { return error; } })", .count = 15 },
    .{ .expression = "(() => { try { g(); } catch ({ message }) { return message; } finally { h(); } })", .count = 20 },
    .{ .expression = "(() => { try { g(); } finally { h(); } })", .count = 12 },
    .{ .expression = "(() => { for (const item of items) { g(item); } })", .count = 13 },
    .{ .expression = "(() => { for (let i = 0; i < n; i++) { g(i); } })", .count = 19 },
    .{ .expression = "(() => { for (const key in record) { g(key); } })", .count = 13 },
    .{ .expression = "(() => { for await (const item of items) { g(item); } })", .count = 14 },
    .{ .expression = "(() => { for (const { id } of items) { g(id); } })", .count = 15 },
    .{ .expression = "(() => { switch (x) { case 1: return 1; default: return 2; } })", .count = 13 },
    .{ .expression = "(() => { if (x) { g(); } else { h(); } })", .count = 13 },
    .{ .expression = "(() => { while (x) { g(); } })", .count = 9 },
    .{ .expression = "(() => { do { g(); } while (x); })", .count = 9 },
    .{ .expression = "(() => { function g(a) { return a; } return g(1); })", .count = 14 },
    .{ .expression = "(() => { async function g() { return 1; } return g(); })", .count = 12 },
    .{ .expression = "(() => { function* g() { yield 1; } return g(); })", .count = 13 },

    // classes, their heritage and the members a body holds
    .{ .expression = "(() => { class K {} return K; })", .count = 7 },
    .{ .expression = "(() => { class K { x = 1; } return K; })", .count = 10 },
    .{ .expression = "(() => { class K { m() { return 1; } } return K; })", .count = 12 },
    .{ .expression = "(() => { class K extends Base {} return K; })", .count = 10 },
    .{ .expression = "(() => { class K implements I {} return K; })", .count = 10 },
    .{ .expression = "(class K extends Base implements I { x = 1; m() {} })", .count = 14 },
    .{ .expression = "(class K extends Base<T> implements I {})", .count = 10 },
    .{ .expression = "(class K { constructor() {} static y = 3; readonly z = 1; })", .count = 12 },
    .{ .expression = "(class K { [k] = 1; [j]() {} })", .count = 10 },
    .{ .expression = "(class K { get z() { return 4; } set z(v) {} })", .count = 12 },
    .{ .expression = "(class K { async m() {} *gen() {} })", .count = 10 },
    .{ .expression = "(class K { x?: number; \"s\": number = 1; })", .count = 10 },
    .{ .expression = "(class K { m(a, b) { return a; } })", .count = 11 },
};

test "a node's count is the one typescript reports for its subtree" {
    for (subtree_rows) |row| try expectCount(row.expression, row.count);
}

test "a pattern default's value is read for its names, not built" {
    const allocator = testing.allocator;
    // the loop walks a default's tokens because a value holds references that a scope pass
    // wants, and HEAD's walk binds a name only where its own entry structure says so: `x`
    // here is a key of an object literal inside the default, and no name comes of it
    const source = "const { a = { x: 1 } } = o;\nconst [b = c ? y : 1] = p;\n";
    var module = try parse(allocator, source);
    defer module.deinit();

    try testing.expectEqual(@as(usize, 0), module.unknownCount());

    // every name the walk binds, which is the tree's own reading of the two declarations:
    // `a`, `b`, `o` and `p` are the names the entries declare, and `c` is the default's own
    // reference, which this walk binds because that is what it has always done
    var bound: [6][]const u8 = undefined;
    var found: usize = 0;
    var walker = module.iterator();
    while (walker.next()) |index| {
        if (module.kindOf(index) != .identifier) continue;
        try testing.expect(found < bound.len);
        bound[found] = module.nodeOf(index).name;
        found += 1;
    }
    try testing.expectEqual(bound.len - 1, found);
    var names = std.ArrayList([]const u8).empty;
    defer names.deinit(allocator);
    for (bound[0..found]) |name| try names.append(allocator, name);
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, left: []const u8, right: []const u8) bool {
            return std.mem.lessThan(u8, left, right);
        }
    }.lessThan);
    try testing.expectEqualStrings("a", names.items[0]);
    try testing.expectEqualStrings("b", names.items[1]);
    try testing.expectEqualStrings("c", names.items[2]);
    try testing.expectEqualStrings("o", names.items[3]);
    try testing.expectEqualStrings("p", names.items[4]);

    // and `x` is the key of the object literal inside the first default: no entry reads it,
    // so no name comes of it, which is the tree this slice must leave alone
    for (names.items) |name| try testing.expect(!std.mem.eql(u8, name, "x"));
}

fn expectCount(expression: []const u8, expected: u32) !void {
    const source = try std.fmt.allocPrint(testing.allocator, "const __x = {s};", .{expression});
    defer testing.allocator.free(source);

    var module = try parse(testing.allocator, source);
    defer module.deinit();

    const declaration = module.firstChildOf(module.root) orelse return error.TestUnexpectedResult;
    const initializer = module.lastChildOf(declaration) orelse return error.TestUnexpectedResult;
    const actual = module.descendantsOf(initializer);
    if (actual != expected) {
        std.debug.print("count '{s}': want {d}, got {d}\n", .{ expression, expected, actual });
        return error.TestUnexpectedResult;
    }
}
