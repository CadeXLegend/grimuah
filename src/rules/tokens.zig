const std = @import("std");
const ts = @import("../lang/ts.zig");

/// token and literal-text helpers shared by the rules and the engine
///
/// these are the readers the rules were checked against the biome engine with
/// while it was the oracle, moved here
/// unchanged: the native engine in `src/lint.zig` is the reference the parity
/// test holds this engine to, so the helpers keep the same semantics

pub const Token = ts.Token;

/// the raw source slice of the literal site at `index`, spanning its delimiters, or null
/// when the token begins no literal the detectors' `ts.isStringLiteralLike` covers
///
/// a quoted literal is its own token, and a template with no substitution is a `.template`
/// followed by its closing `.template_end`, whose two spans together give the raw text in
/// full
/// a template that holds a substitution is NOT one site: its opening backtick is
/// followed by the container's own tokens, and `ts.isStringLiteral` is false of a
/// TemplateExpression as well
///
/// the caller decodes the slice with `ts.decodeStringLiteral`, whose destination must hold
/// `raw.len` bytes. it advances one token whatever the answer, because the token a site
/// ends on, a closing `.template_end`, is no site itself
pub fn literalSite(tokens: []const Token, source: []const u8, index: usize) ?[]const u8 {
    const token = tokens[index];
    switch (token.kind) {
        .string => return token.text,
        .template => {
            if (index + 1 >= tokens.len) return null;
            const closing = tokens[index + 1];
            if (closing.kind != .template_end) return null;
            return source[token.start..closing.end];
        },
        else => return null,
    }
}

/// the unicode spaces ``/\s/`` matches beyond the ASCII set: the no-break space, the ogham
/// space, the two line separators, the narrow no-break space, the medium mathematical
/// space, the ideographic space, and the byte-order mark
const java_script_spaces = [_]u21{ 0x00a0, 0x1680, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000, 0xfeff };

/// the last ASCII code point, and the en-to-hair space run JavaScript folds with the ASCII
/// whitespace. naming both keeps the two bounds of `isJavaScriptSpace` visible
const last_ascii_codepoint: u21 = 0x7f;
const first_en_space_codepoint: u21 = 0x2000;
const last_hair_space_codepoint: u21 = 0x200a;

/// whether `/\s/` matches a code point, which is the ASCII set the tokenizer's own predicate
/// covers plus the unicode spaces above and the en-to-hair space run
///
/// the detectors read a literal's text with JavaScript's `\s`, so a rule that keys, folds or
/// tests for whitespace has to use this set rather than the ASCII one: the engine's collapse
/// and the literal rules all read it here
pub fn isJavaScriptSpace(codepoint: u21) bool {
    if (codepoint <= last_ascii_codepoint) return std.ascii.isWhitespace(@intCast(codepoint));
    if (codepoint >= first_en_space_codepoint and codepoint <= last_hair_space_codepoint) return true;
    for (java_script_spaces) |candidate| {
        if (codepoint == candidate) return true;
    }
    return false;
}

/// `[a-zA-Z] [a-zA-Z]` anywhere in the text, which is the copy detectors' own test for a
/// sentence rather than a key: two letters separated by one space, so an enum value like
/// `nowplaying` or an identifier never counts
/// the space is the ASCII one the regex spells rather than any whitespace `\s` would match
pub fn hasLettersAroundSpace(text: []const u8) bool {
    var i: usize = 0;
    while (i + 2 < text.len) : (i += 1) {
        if (!std.ascii.isAlphabetic(text[i])) continue;
        if (text[i + 1] != ' ') continue;
        if (!std.ascii.isAlphabetic(text[i + 2])) continue;
        return true;
    }
    return false;
}

pub fn isPunct(token: Token, text: []const u8) bool {
    return token.isPunct(text);
}

pub fn isWord(token: Token, text: []const u8) bool {
    return token.isWord(text);
}

/// `o.throw`, `o.null` and friends are property accesses, not syntax
pub fn isMemberAccess(tokens: []const Token, i: usize) bool {
    if (i == 0) return false;
    const previous = tokens[i - 1];
    return isPunct(previous, ".") or isPunct(previous, "?.");
}

/// `{` / `(` / `[` at `open`, index of the matching closer, nested pairs skipped
pub fn matchingBracket(tokens: []const Token, open: usize) ?usize {
    const opener = tokens[open].text;
    const closer = if (std.mem.eql(u8, opener, "(")) ")" else if (std.mem.eql(u8, opener, "[")) "]" else if (std.mem.eql(u8, opener, "{")) "}" else return null;

    var depth: usize = 0;
    var i = open;
    while (i < tokens.len) : (i += 1) {
        const text = tokens[i].text;
        if (tokens[i].kind != .punct) continue;
        if (std.mem.eql(u8, text, opener)) depth += 1;
        if (std.mem.eql(u8, text, closer)) {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

/// the first occurrence of the punctuation `text` at or after `from`
pub fn nextPunct(tokens: []const Token, from: usize, text: []const u8) ?usize {
    var index = from;
    while (index < tokens.len) : (index += 1) {
        if (tokens[index].isPunct(text)) return index;
    }
    return null;
}

/// `;` between `open` and `close` that is not inside a nested bracket pair
pub fn countTopLevelSemicolons(tokens: []const Token, open: usize, close: usize) usize {
    var depth: usize = 0;
    var count: usize = 0;
    var i = open;
    while (i < close) : (i += 1) {
        if (tokens[i].kind != .punct) continue;
        const text = tokens[i].text;
        if (std.mem.eql(u8, text, "(") or std.mem.eql(u8, text, "[") or std.mem.eql(u8, text, "{")) {
            depth += 1;
        } else if (std.mem.eql(u8, text, ")") or std.mem.eql(u8, text, "]") or std.mem.eql(u8, text, "}")) {
            depth -= 1;
        } else if (std.mem.eql(u8, text, ";") and depth == 1) {
            count += 1;
        }
    }
    return count;
}

/// `as` tokens inside an `import { a as b }` or `export { a as b }` clause are
/// aliases, not casts. the clause is recognised by the keyword immediately
/// before the `{`
pub fn inImportClause(tokens: []const Token, i: usize) bool {
    var depth: usize = 0;
    var j = i;
    while (j > 0) {
        j -= 1;
        const token = tokens[j];
        if (token.kind != .punct) continue;
        if (isPunct(token, "}")) {
            depth += 1;
            continue;
        }
        if (!isPunct(token, "{")) continue;
        if (depth > 0) {
            depth -= 1;
            continue;
        }
        if (j == 0) return false;
        const before = tokens[j - 1];
        return isWord(before, "import") or isWord(before, "export") or isWord(before, "type");
    }
    return false;
}

/// `:` between two token indexes that is not inside a nested bracket pair
pub fn hasTopLevelColon(tokens: []const Token, start: usize, end: usize) bool {
    var depth: usize = 0;
    var i = start;
    while (i < end) : (i += 1) {
        const token = tokens[i];
        if (token.kind != .punct) continue;
        const text = token.text;
        if (std.mem.eql(u8, text, "(") or std.mem.eql(u8, text, "[") or std.mem.eql(u8, text, "{")) {
            depth += 1;
            continue;
        }
        if (std.mem.eql(u8, text, ")") or std.mem.eql(u8, text, "]") or std.mem.eql(u8, text, "}")) {
            if (depth == 0) return false;
            depth -= 1;
            continue;
        }
        if (depth == 0 and std.mem.eql(u8, text, ":")) return true;
    }
    return false;
}

/// from the token after an `as`, walk the type expression. returns the index of
/// a following `as` (a chain) or null when the type ends first
pub fn findAsEndingType(tokens: []const Token, start: usize) ?usize {
    var depth: usize = 0;
    var i = start;
    while (i < tokens.len) : (i += 1) {
        const token = tokens[i];
        if (token.kind == .punct) {
            const text = token.text;
            if (std.mem.eql(u8, text, "(") or std.mem.eql(u8, text, "[") or std.mem.eql(u8, text, "{")) {
                depth += 1;
                continue;
            }
            if (std.mem.eql(u8, text, ")") or std.mem.eql(u8, text, "]") or std.mem.eql(u8, text, "}")) {
                if (depth == 0) return null;
                depth -= 1;
                continue;
            }
            // `{ a: number }` is a type; a `:` at depth 0 is a different statement
            if (depth == 0 and type_terminators.contains(text)) return null;
            continue;
        }
        if (token.kind == .word) {
            if (std.mem.eql(u8, token.text, "as")) return i;
            if (depth == 0 and type_stop_keywords.contains(token.text)) return null;
            continue;
        }
        return null;
    }
    return null;
}

/// `$name = ` in `const $name = ...`, stopping at a type annotation
pub fn findDeclaratorEquals(tokens: []const Token, start: usize) ?usize {
    var depth: usize = 0;
    var i = start;
    while (i < tokens.len) : (i += 1) {
        const token = tokens[i];
        if (token.kind != .punct) continue;
        const text = token.text;
        if (std.mem.eql(u8, text, "(") or std.mem.eql(u8, text, "[") or std.mem.eql(u8, text, "{")) {
            depth += 1;
            continue;
        }
        if (std.mem.eql(u8, text, ")") or std.mem.eql(u8, text, "]") or std.mem.eql(u8, text, "}")) {
            if (depth == 0) return null;
            depth -= 1;
            continue;
        }
        if (depth != 0) continue;
        if (std.mem.eql(u8, text, ":")) return null;
        if (std.mem.eql(u8, text, "=")) return i;
        if (std.mem.eql(u8, text, ";")) return null;
    }
    return null;
}

pub const StringSet = struct {
    items: []const []const u8,

    pub fn contains(self: StringSet, text: []const u8) bool {
        for (self.items) |item| {
            if (std.mem.eql(u8, item, text)) return true;
        }
        return false;
    }
};

pub const type_terminators = StringSet{ .items = &.{
    ",", ";", "=", "=>", "?", ":", "==", "===", "!=", "!==", "&&", "||", "??", "+", "-", "*", "/", "%", "!", "~", "^", "=>=",
} };

/// keywords that can never appear inside a type, so they end it too
pub const type_stop_keywords = StringSet{ .items = &.{
    "const",   "let",     "var",        "return", "if",        "else",   "for",       "while",     "do",
    "switch",  "case",    "throw",      "try",    "catch",     "finally", "new",      "class",     "function",
    "import",  "export",  "await",      "yield",  "break",     "continue", "enum",    "interface", "namespace",
} };
