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
    return tokens_mod.hasLettersAroundSpace(text);
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

/// how many distinct files must write one sentence before the copies are a defect
/// three rather than two, which is the detector's own choice: two files that mirror each
/// other's copy across a process boundary are deliberate, and the corpus's command
/// descriptions do exactly that
const duplicate_copy_file_threshold = 3;

/// a user-facing sentence written out in three or more files
///
/// the run's index holds the distinct files that write each sentence, so the verdict is one
/// lookup per literal, and every occurrence in a file that is judged is reported
///
/// a `.d.ts` is skipped HERE rather than at collection, which is the detector's own shape:
/// it walks every file for its owner index and returns early from `detect`, so a
/// declaration file's copy counts toward a sentence's files while producing no row itself
pub fn checkDuplicatedUserFacingCopy(
    allocator: std.mem.Allocator,
    index: *const root.FingerprintIndex,
    project: *const root.Project,
    path: []const u8,
    rule: *const root.Rule,
    findings: *std.ArrayList(root.Finding),
) std.mem.Allocator.Error!void {
    if (std.mem.endsWith(u8, path, ".d.ts")) return;

    for (project.copy_sites.items) |site| {
        const owners = index.copy_files.get(site.key) orelse continue;
        if (owners.files < duplicate_copy_file_threshold) continue;

        try findings.append(allocator, .{
            .path = try allocator.dupe(u8, path),
            .line = site.line,
            .message = try allocator.dupe(u8, rule.message),
            .layer = rule.layer.name(),
            .severity = rule.severity,
        });
    }
}

test "a sentence written in three files is reported in each of them, and the shapes the detector does not collect are not" {
    // every literal here is written in three files, so one that reports no row is one the
    // detector's own guards excluded rather than one that only appears in one file
    // the groups that report:
    //   `Nothing is playing here.` is exactly 24 UTF-16 units, which is the length gate's own
    //     boundary: a gate at 25 drops this row and one at 23 adds the `now.` row below
    //   a backtick literal with no substitution is a `StringLiteralLike`, so `Right now this
    //     one is idle.` is a site
    //   `Nothing is playing right now.` is written in two implementation files and a `.d.ts`,
    //     which pins the `.d.ts` exclusion as a REPORT-time test: the declaration file counts
    //     toward the three files while producing no row of its own, and a collection-time
    //     exclusion would leave two files and report nothing at all
    // the groups that do not:
    //   `Nothing is playing now.` is 23 units, one under the gate
    //   `Nothing is playing. 🎵` is 20 letters and a space plus one astral character, which
    //     is 22 UTF-16 units in 24 bytes: a gate measured in bytes, or read as the cooked
    //     byte length, admits it and three rows appear
    //   `Right now this one is busy.` is written twice in one file and once in another, which
    //     is two distinct files: the count is of FILES, so the repeat counts once
    //   a 31-unit literal of digits and a space holds no two letters around one
    //   `Right now this one is ${value} busy.` is a TemplateExpression, which
    //     `StringLiteralLike` is false of: its opening backtick is followed by the
    //     container's own token rather than by the closing one
    const message = root.duplicated_user_facing_copy;
    try probe.expectProject(.cosmetic, &.{
        .{ .path = "src/messages/a.service.ts", .content =
        \\export const atLimit = "Nothing is playing here.";
        \\export const underLimit = "Nothing is playing now.";
        \\export const repeated = "Right now this one is busy.";
        \\export const doubled = "Right now this one is busy.";
        \\export const identifiers = "123456789012345678901234567 890";
        \\export const plain = `Right now this one is idle.`;
        \\export const dynamic = `Right now this one is ${value} busy.`;
        \\export const emoji = "Nothing is playing. 🎵";
        \\export const shared = "Nothing is playing right now.";
        \\
        },
        .{ .path = "src/messages/b.service.ts", .content =
        \\export const atLimit = "Nothing is playing here.";
        \\export const underLimit = "Nothing is playing now.";
        \\export const repeated = "Right now this one is busy.";
        \\export const identifiers = "123456789012345678901234567 890";
        \\export const plain = `Right now this one is idle.`;
        \\export const dynamic = `Right now this one is ${value} busy.`;
        \\export const emoji = "Nothing is playing. 🎵";
        \\export const shared = "Nothing is playing right now.";
        \\
        },
        .{ .path = "src/messages/c.service.ts", .content =
        \\export const atLimit = "Nothing is playing here.";
        \\export const underLimit = "Nothing is playing now.";
        \\export const identifiers = "123456789012345678901234567 890";
        \\export const plain = `Right now this one is idle.`;
        \\export const dynamic = `Right now this one is ${value} busy.`;
        \\export const emoji = "Nothing is playing. 🎵";
        \\
        },
        .{ .path = "src/messages/copy.d.ts", .content =
        \\export declare const shared: "Nothing is playing right now.";
        \\
        },
    }, &.{
        "src/messages/a.service.ts:1: " ++ message,
        "src/messages/a.service.ts:6: " ++ message,
        "src/messages/a.service.ts:9: " ++ message,
        "src/messages/b.service.ts:1: " ++ message,
        "src/messages/b.service.ts:5: " ++ message,
        "src/messages/b.service.ts:8: " ++ message,
        "src/messages/c.service.ts:1: " ++ message,
        "src/messages/c.service.ts:4: " ++ message,
    });
}
