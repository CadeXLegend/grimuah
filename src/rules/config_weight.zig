const std = @import("std");
const ts = @import("../lang/ts.zig");
const tokens_mod = @import("tokens.zig");

const Token = tokens_mod.Token;

/// the question every rule that names a `.config.ts` as a destination answers before it speaks:
/// would this file's own vocabulary fill one
///
/// two facts answer it: what the file would hand a config, which `entries` counts, and whether
/// the run already holds a config beside it, which `siblingConfigExists` finds. `earnsConfig`
/// is the pair in the form the rules ask it, and `justifiesConfig` is the same verdict for a
/// rule that reads the two facts off the file's own contribution rather than off its tokens

/// how many entries a `.config.ts` has to hold before the file that would fill it earns
/// having one
///
/// a config of three entries is indirection around three constants a reader finds faster
/// where they are used, so the rules that name a config as the destination make work for
/// nobody at that size
///
/// four rather than five, so no count is left unstated: three and below is a throwaway and
/// four is already a set with a vocabulary. this is the bar the ENTRY count is read against
/// rather than the bare size of a file, and `entries` is what counts
const minimum_config_entries: u32 = 4;

/// the suffix a config file carries, which is the declaration module's suffix with `config`
/// in front of it
const config_suffix = ".config.ts";

/// the suffix the file a config declares values for carries
const module_suffix = ".ts";

/// the entries one file would hand to its surface's `.config.ts`: every member of an enum it
/// declares, plus every string literal it writes outside an enum body
///
/// an enum MEMBER is the entry rather than the literal it assigns, which is what makes
/// `NotFound = "not-found"` one entry rather than two: the member is the name a consumer
/// references and the literal is part of the member's own declaration
///
/// a string outside an enum is an entry whether or not it reads as a sentence, because a
/// config holds the ids, the slugs, the routes and the copy alike, and a sentence is a string
/// like any other here
///
/// an unexported enum counts like an exported one: the question is what the file's vocabulary
/// weighs, not what a consumer can reach today, and a nested enum is the same vocabulary
pub fn entries(tokens: []const Token, source: []const u8) u32 {
    var count: u32 = 0;
    var index: usize = 0;
    while (index < tokens.len) {
        if (tokens[index].isWord("enum")) {
            if (enumBody(tokens, index)) |body| {
                count += memberCount(tokens, body.open, body.close);
                // the body is skipped whole, which is the second half of counting a member
                // rather than its literal: the scan resumes past the closing brace, so no
                // literal inside reaches the count below
                index = body.close + 1;
                continue;
            }
        }
        if (tokens_mod.literalSite(tokens, source, index) != null) count += 1;
        index += 1;
    }
    return count;
}

/// whether a `.config.ts` is the right destination for a file: it would hold enough entries to
/// earn one, or the surface already holds a config beside the file, which is the case where
/// nothing new is created and the vocabulary belongs with its siblings whatever it weighs
///
/// the second half is why this is not a plain count: the rule that moves an enum into a config
/// is about placing what the surface already has, and a config that already exists is the
/// resting place for it
pub fn justifiesConfig(entry_count: u32, sibling_exists: bool) bool {
    return sibling_exists or entry_count >= minimum_config_entries;
}

/// whether the file at `path` earns the config a rule would move its vocabulary into, which is
/// the whole question its two halves answer: what the file weighs, and whether the run holds
/// its own `.config.ts` already
///
/// the three rules that name a config as a destination ask it here rather than restating the
/// pair, so a change to what earns a config reaches all three at once
pub fn earnsConfig(tokens: []const Token, source: []const u8, run_paths: []const []const u8, path: []const u8) bool {
    return justifiesConfig(entries(tokens, source), siblingConfigExists(run_paths, path));
}

/// whether the run holds the `.config.ts` that sits beside `path`
///
/// the pair is found by STEM rather than by directory, which is the convention every config
/// rule already reads: `afk.service.ts` and `afk.service.config.ts` are one surface, so a
/// neighbour's config declares nothing for this file and is no destination for it
pub fn siblingConfigExists(paths: []const []const u8, path: []const u8) bool {
    if (!std.mem.endsWith(u8, path, module_suffix)) return false;
    const stem = path[0 .. path.len - module_suffix.len];

    for (paths) |candidate| {
        // the length pins the pair to one file name, so the two prefix and suffix tests are
        // what remains of the comparison
        if (candidate.len != stem.len + config_suffix.len) continue;
        if (!std.mem.startsWith(u8, candidate, stem)) continue;
        if (!std.mem.endsWith(u8, candidate, config_suffix)) continue;
        return true;
    }
    return false;
}

const EnumBody = struct {
    open: usize,
    close: usize,
};

/// the braces of the enum a `enum` keyword opens, or null when the keyword opens none
///
/// a reader that walks the tokens finds the keyword wherever it stands, a `declare module`
/// block included, which the tree cannot do: the front-end models `enum` as one childless
/// declaration, so a member is only ever a token
///
/// `enum` is reserved and can never be a name, but a property KEY may spell it: `{ enum: 1 }`,
/// `{ enum }` and `shape.enum` are all legal JavaScript, and the name the declaration carries
/// is always the next token, so a keyword followed by anything else opens no body
fn enumBody(tokens: []const Token, keyword: usize) ?EnumBody {
    const name = keyword + 1;
    if (name >= tokens.len or tokens[name].kind != .word) return null;
    const open = tokens_mod.nextPunct(tokens, name + 1, "{") orelse return null;
    const close = tokens_mod.matchingBracket(tokens, open) orelse return null;
    return .{ .open = open, .close = close };
}

/// how many members an enum body declares: one per run of tokens the commas and semicolons at
/// the body's own depth separate
///
/// the depth is what keeps a call's or an object's own comma from splitting a member in two:
/// `X = pick("a", "b")` is one member to TypeScript, and a split at the nested comma would read
/// a member no declaration holds
fn memberCount(tokens: []const Token, open: usize, close: usize) u32 {
    var count: u32 = 0;
    var depth: usize = 0;
    var member_start = open + 1;
    var index = open + 1;
    while (index < close) : (index += 1) {
        const token = tokens[index];
        if (token.kind != .punct) continue;
        if (opensBracket(token)) {
            depth += 1;
            continue;
        }
        if (closesBracket(token)) {
            if (depth > 0) depth -= 1;
            continue;
        }
        if (depth != 0) continue;
        if (!separatesMembers(token)) continue;
        if (index > member_start) count += 1;
        member_start = index + 1;
    }
    // the run after the last separator, which is empty when the body closes on one
    if (close > member_start) count += 1;
    return count;
}

fn opensBracket(token: Token) bool {
    return token.isPunct("(") or token.isPunct("[") or token.isPunct("{");
}

fn closesBracket(token: Token) bool {
    return token.isPunct(")") or token.isPunct("]") or token.isPunct("}");
}

/// whether the punctuation `text` separates two members of an enum body. TypeScript builds
/// `node.members` from either a comma or a semicolon, and a semicolon is a parse error the
/// compiler recovers from with both members intact, so both spell a boundary
fn separatesMembers(token: Token) bool {
    return token.isPunct(",") or token.isPunct(";");
}

fn expectWeight(expected: u32, source: []const u8) !void {
    const allocator = std.testing.allocator;
    var number_line: u32 = 1;
    const lexed = try ts.tokenizeAll(allocator, source, &number_line);
    defer {
        allocator.free(lexed.tokens);
        allocator.free(lexed.jsx_names);
    }
    try std.testing.expectEqual(expected, entries(lexed.tokens, source));
}

test "the weight is an enum's members plus the string literals outside its body" {
    try expectWeight(4,
        \\export enum Reason {
        \\  NotFound = "not-found",
        \\  Gone = "gone",
        \\}
        \\
        \\export const heading = "Now playing.";
        \\export const footer = `Nothing else.`;
        \\
    );
}

test "an enum's own member separators are read, and its members' literals are not counted twice" {
    // one member, a trailing comma, and a semicolon boundary
    try expectWeight(1, "export enum Only { Gone = \"gone\", }");
    try expectWeight(2, "export enum Pair { Gone = \"gone\"; Back = \"back\" }");
    // a nested comma inside a member's own call is no boundary: two members, not three
    try expectWeight(2, "export enum Called { One = pick(\"a\", \"b\"), Two = \"two\" }");
    // a `const enum` is read like any other declaration, and a `declare module` block's
    // own specifier is a string outside an enum body, so it counts beside the member
    try expectWeight(1, "export const enum Fast { Gone = \"gone\" }");
    try expectWeight(2, "declare module \"remote\" { export enum Nested { Gone = \"gone\" } }");
    // an empty body declares no member
    try expectWeight(0, "export enum Empty {}");
}

test "a literal outside an enum is an entry, and the two shapes that are no literal are not" {
    try expectWeight(1, "export const id = \"not-found\";");
    try expectWeight(1, "export const whole = `Nothing else.`;");
    // a number is no config value, and a template that holds a substitution is no
    // `StringLiteralLike`, so neither is an entry
    try expectWeight(0, "export const limit = 42;");
    try expectWeight(0, "export const split = `and ${count} more`;");
}

test "a property key spelled `enum` opens no body, so the block after it is read as it stands" {
    // `enum` is reserved and can never be a name, but a property key may spell it. a scan that
    // followed the keyword here would read `pick`'s body as an enum body and count its one
    // statement as a member of a declaration this file does not have
    try expectWeight(0,
        \\export const option = { enum: true };
        \\export function pick() {
        \\  const { first, second } = source;
        \\}
        \\
    );
}

test "a config is justified at four entries, or beside a config the run already holds" {
    try std.testing.expect(!justifiesConfig(3, false));
    try std.testing.expect(justifiesConfig(4, false));
    try std.testing.expect(justifiesConfig(0, true));
}

test "the sibling is found by stem, so a neighbour's config is no destination" {
    const paths = [_][]const u8{
        "src/commands/music.command.ts",
        "src/commands/music.command.config.ts",
        "src/commands/other.command.ts",
    };
    try std.testing.expect(siblingConfigExists(&paths, "src/commands/music.command.ts"));
    try std.testing.expect(!siblingConfigExists(&paths, "src/commands/other.command.ts"));
    // a config one directory down declares another surface's values
    try std.testing.expect(!siblingConfigExists(&paths, "src/tasks/music.command.ts"));
    // a path with no module suffix has no config beside it to find
    try std.testing.expect(!siblingConfigExists(&paths, "src/commands/README.md"));
    // a config is no module with a config of its own
    try std.testing.expect(!siblingConfigExists(&paths, "src/commands/music.command.config.ts"));
}
