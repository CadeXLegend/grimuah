const std = @import("std");
const root = @import("../rules.zig");
const tokens_mod = @import("tokens.zig");

const Token = tokens_mod.Token;

/// short strings are keys and ids, not sentences
const minimum_copy_length = 12;

/// user-facing copy in a `.config.ts` file, which must start with a capital
///
/// this stays on the token stream: the copy lives in string literals and
/// template heads, and the tree models neither an enum member nor a type alias
/// body, so a tree version would stop seeing `export enum Message { ... }`,
/// which is where most of a project's copy actually lives
///
/// only the first chunk of a template is read, which is what the rule means by
/// a sentence: a placeholder in the first position would swallow the capital
pub fn checkLowercaseCopy(context: *const root.Context) !void {
    if (!std.mem.endsWith(u8, context.path, ".config.ts")) return;
    for (context.tokens) |token| {
        const copy = copyChunk(context.source, token) orelse continue;
        if (!isLowercaseCopy(copy)) continue;
        try context.report(token.line, .cosmetic, root.lowercase_copy, .warn);
    }
}

/// the copy a token carries: a quoted literal without its quotes, or the head
/// of a template before its first `${`. every other token carries no copy
fn copyChunk(source: []const u8, token: Token) ?[]const u8 {
    return switch (token.kind) {
        .string => if (token.text.len >= 2) token.text[1 .. token.text.len - 1] else null,
        .template => templateHead(source, token.start + 1),
        else => null,
    };
}

/// the text of a template up to its first `${` or its closing backtick
fn templateHead(source: []const u8, start: usize) []const u8 {
    var i = start;
    while (i < source.len) : (i += 1) {
        const byte = source[i];
        if (byte == '\\') {
            i += 1;
            continue;
        }
        if (byte == '`') break;
        if (byte == '$' and i + 1 < source.len and source[i + 1] == '{') break;
    }
    return source[start..@min(i, source.len)];
}

/// a sentence rather than a key: long enough to be one, two letters separated
/// by a space so an enum value like `nowplaying` or an id never counts, and a
/// lowercase first letter
fn isLowercaseCopy(text: []const u8) bool {
    if (text.len < minimum_copy_length) return false;
    if (!std.ascii.isLower(text[0])) return false;
    return hasLettersAroundSpace(text);
}

/// `[a-zA-Z] [a-zA-Z]` anywhere in the text
fn hasLettersAroundSpace(text: []const u8) bool {
    var i: usize = 0;
    while (i + 2 < text.len) : (i += 1) {
        if (!std.ascii.isAlphabetic(text[i])) continue;
        if (text[i + 1] != ' ') continue;
        if (!std.ascii.isAlphabetic(text[i + 2])) continue;
        return true;
    }
    return false;
}

/// the em-dash rule is the one rule that reads raw bytes rather than tokens,
/// because it has to reach inside strings, templates and comments, and biome's
/// tree matcher cannot. every occurrence is its own finding
pub fn checkEmDash(context: *const root.Context) !void {
    const em_dash = "\u{2014}";
    const source = context.source;

    // the sequence starts with a byte no ASCII source contains, so hopping to
    // that byte clears the file in a vectorised scan instead of comparing three
    // bytes at every offset (measured: 3.5% of a run on a 250-file repo)
    var pos: usize = 0;
    while (std.mem.indexOfScalarPos(u8, source, pos, em_dash[0])) |found| {
        pos = found + 1;
        if (found + em_dash.len > source.len) break;
        if (!std.mem.eql(u8, source[found .. found + em_dash.len], em_dash)) continue;

        try context.report(lineAt(source, found), .cosmetic, root.em_dash, .err);
        pos = found + em_dash.len;
    }
}

/// 1-based line of `offset`, counting the newlines before it
fn lineAt(content: []const u8, offset: usize) u32 {
    var line: u32 = 1;
    for (content[0..offset]) |byte| {
        if (byte == '\n') line += 1;
    }
    return line;
}

const probe = @import("probe.zig");

test "copy in a config file that starts lowercase is reported" {
    const source =
        \\export enum Message {
        \\  StraySpirit = "stray spirit",
        \\  Short = "queued",
        \\  Titled = "Stray spirit drifts in.",
        \\  SingleWord = "singlewordhere",
        \\}
        \\
        \\export const Head = `and ${hiddenCount} more queued`;
        \\
        \\export const Whole = `and three more queued`;
        \\
    ;
    try probe.expect(.cosmetic, "probe.config.ts", source, &.{
        "2: This copy starts lowercase. Capitalise the first letter of the sentence.",
        "10: This copy starts lowercase. Capitalise the first letter of the sentence.",
    });
}

test "the same copy outside a config file is left alone" {
    const source =
        \\export const Whole = `and three more queued`;
        \\
    ;
    try probe.expect(.cosmetic, "probe.ts", source, &.{});
}
