const std = @import("std");
const config = @import("config.zig");

/// grimuah's own rules enforced in-process. they once shipped as GritQL plugin
/// files, and biome charged one full syntax-tree traversal per plugin file per
/// source file (~300-900us, measured) whether or not the pattern could match,
/// which was ~64% of biome's CPU on a lint run. biome is gone, so the plugin
/// engine and its files are too
///
/// the semantics were pinned to biome 2.5.11 while it was the oracle, and
/// `tests/oracle/` holds the findings it validated. three behaviours are worth
/// knowing:
///
///   - `cosmetic-em-dash`, `resilience-let` and `resilience-switch` matched
///     nothing at all in biome 2.5.11: its GritQL subset could not compile those
///     patterns and discarded them without a word (12 variants measured, every
///     one silently ignored) while real files are full of em-dashes, `let` and
///     `switch`. this module enforces all three
///   - `let` is matched as a declaration (`let x`, `let {a}`, `let [a]`). a
///     declaration with no initializer carries no value to bind, and the rule
///     bans the keyword. `o.let` and the `let` key in `{ let: string }` are not
///     declarations and stay silent
///   - findings carry their original severities. errors fail the check, warnings
///     do not, and a warnings-only project still prints nothing

pub const Severity = enum { err, warn };

pub const Finding = struct {
    path: []u8,
    line: u32,
    message: []const u8,
    layer: []const u8,
    severity: Severity,
};

/// messages are the ones the GritQL `register_diagnostic` calls carried, so a
/// project that ran the plugin engine before reads the same text today
const msg = struct {
    const null_literal = "do not use null; use undefined. null only at third-party boundaries (DB, RegExp)";
    const imperative_for = "do not use imperative for loops; use map, filter, reduce, or for..of instead";
    const double_equals = "use === instead of == to avoid type coercion bugs";
    const as_any = "'as any' bypasses type safety entirely; use a proper type instead";
    const chained_cast = "chained 'as' casts bypass type safety; use a single cast only";
    const reexport = "do not proxy re-export; every export must originate from the file that defines it";
    const as_const = "use enum instead of const + as const; enum gives you both value and type in one declaration";
    const throw_stmt = "do not use throw; all errors must flow through OperationOutcome. see lib/outcome.ts";
    const bare_catch = "do not use bare catch with silent failure; log the error or return an Outcome";
    const silent_catch = "catch block must handle or log the error, not silently discard it";
    const em_dash = "do not use em-dashes; use commas, colons, or sentence breaks instead";
    const let_decl = "do not use let; use const. only let at module-level mutable caches";
    const switch_stmt = "do not use switch; use a dispatch table (Record/Map) instead";
};

/// scan every lintable source file under `project_root` and return the findings
pub fn runAll(
    io: std.Io,
    allocator: std.mem.Allocator,
    cfg: *const config.Config,
    project_root: []const u8,
) ![]Finding {
    var findings: std.ArrayList(Finding) = .empty;
    errdefer freeFindings(allocator, findings.items);

    var dir = std.Io.Dir.cwd().openDir(io, project_root, .{ .iterate = true }) catch return findings.toOwnedSlice(allocator);
    defer dir.close(io);

    try walkDir(io, allocator, cfg, &findings, dir, "", project_root, 0);
    return findings.toOwnedSlice(allocator);
}

pub fn freeFindings(allocator: std.mem.Allocator, findings: []Finding) void {
    for (findings) |finding| allocator.free(finding.path);
    allocator.free(findings);
}

/// biome lints `**` minus node_modules, so the walk only prunes what biome
/// prunes. symlinks are never followed: the bench repos carry node_modules as a
/// symlink and following it would walk the whole install
fn walkDir(
    io: std.Io,
    allocator: std.mem.Allocator,
    cfg: *const config.Config,
    findings: *std.ArrayList(Finding),
    dir: std.Io.Dir,
    rel_prefix: []const u8,
    project_root: []const u8,
    depth: u32,
) !void {
    if (depth > 32) return;

    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const rel = try std.fmt.bufPrint(&path_buf, "{s}{s}", .{ rel_prefix, entry.name });

        switch (entry.kind) {
            .directory => {
                if (std.mem.eql(u8, entry.name, "node_modules")) continue;
                if (std.mem.eql(u8, entry.name, ".git")) continue;

                var child = dir.openDir(io, entry.name, .{ .iterate = true }) catch continue;
                defer child.close(io);

                var child_prefix_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
                const child_prefix = try std.fmt.bufPrint(&child_prefix_buf, "{s}/", .{rel});
                try walkDir(io, allocator, cfg, findings, child, child_prefix, project_root, depth + 1);
            },
            .file => {
                if (!isLintableSource(entry.name)) continue;
                try scanFile(io, allocator, cfg, findings, rel, project_root);
            },
            else => {},
        }
    }
}

/// extensions biome's JS/TS linter handles. JSON is excluded on purpose: the
/// TS-shaped GritQL patterns never match a JSON tree (verified)
fn isLintableSource(name: []const u8) bool {
    const extensions = [_][]const u8{ ".ts", ".tsx", ".mts", ".cts", ".js", ".jsx", ".mjs", ".cjs" };
    for (extensions) |extension| {
        if (std.mem.endsWith(u8, name, extension)) return true;
    }
    return false;
}

/// every live rule needs one of these in the source, so a file without any of
/// them cannot produce a finding and never needs tokenising. this is a fast path
/// in front of the tokeniser, nothing more: it may only over-include, and
/// `tests/oracle/` plus the bench prove that no file it skips carried a finding
/// each needle is the literal its rule matches, so keep the two in step
fn maybeTrigger(content: []const u8) bool {
    if (containsWord(content, "null")) return true;
    if (containsWord(content, "let")) return true;
    if (containsWord(content, "switch")) return true;
    if (std.mem.indexOf(u8, content, "\u{2014}") != null) return true;
    if (containsWord(content, "for")) return true;
    if (containsWord(content, "as")) return true;
    if (containsWord(content, "throw")) return true;
    if (containsWord(content, "catch")) return true;
    if (std.mem.indexOf(u8, content, "==") != null) return true;
    return containsExportClause(content);
}

/// `word` bounded by non-identifier bytes, so `class` does not answer for `as`
fn containsWord(content: []const u8, word: []const u8) bool {
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, content, pos, word)) |found| {
        pos = found + 1;
        if (found > 0 and isIdentifierContinue(content[found - 1])) continue;
        const after = found + word.len;
        if (after < content.len and isIdentifierContinue(content[after])) continue;
        return true;
    }
    return false;
}

/// `export` followed by whitespace or comments then `{`, the shape the re-export
/// rule needs. `export type {` and `export * from` do not answer here, which can
/// only cost a file that has no re-export to find
fn containsExportClause(content: []const u8) bool {
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, content, pos, "export")) |found| {
        pos = found + 1;
        if (found > 0 and isIdentifierContinue(content[found - 1])) continue;

        var i = found + "export".len;
        if (i < content.len and isIdentifierContinue(content[i])) continue;

        while (i < content.len) {
            const char = content[i];
            if (char == ' ' or char == '\t' or char == '\r' or char == '\n') {
                i += 1;
                continue;
            }
            if (char == '/' and i + 1 < content.len and content[i + 1] == '/') {
                i += 2;
                while (i < content.len and content[i] != '\n') i += 1;
                continue;
            }
            if (char == '/' and i + 1 < content.len and content[i + 1] == '*') {
                i += 2;
                while (i + 1 < content.len and !(content[i] == '*' and content[i + 1] == '/')) i += 1;
                i = @min(i + 2, content.len);
                continue;
            }
            break;
        }
        if (i < content.len and content[i] == '{') return true;
    }
    return false;
}

fn scanFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    cfg: *const config.Config,
    findings: *std.ArrayList(Finding),
    rel_path: []const u8,
    project_root: []const u8,
) !void {
    const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ project_root, rel_path });
    defer allocator.free(full_path);

    const content = std.Io.Dir.cwd().readFileAlloc(io, full_path, allocator, .limited(1 << 21)) catch return;
    defer allocator.free(content);
    if (!maybeTrigger(content)) return;

    try lintContent(allocator, cfg, findings, rel_path, content);
}

/// tokenise `content` and append every finding the enabled layers produce
pub fn lintContent(
    allocator: std.mem.Allocator,
    cfg: *const config.Config,
    findings: *std.ArrayList(Finding),
    rel_path: []const u8,
    content: []const u8,
) !void {
    var number_line: u32 = 1;
    const tokens = try tokenize(allocator, content, &number_line);
    defer allocator.free(tokens);
    _ = &number_line;

    const ctx = Ctx{ .allocator = allocator, .cfg = cfg, .findings = findings, .path = rel_path };

    if (cfg.layers.cosmetic) try checkEmDash(ctx, content);

    if (cfg.layers.resilience) {
        try checkNullLiteral(ctx, tokens);
        try checkLetDeclaration(ctx, tokens);
        try checkSwitchStatement(ctx, tokens);
        try checkImperativeFor(ctx, tokens);
        try checkDoubleEquals(ctx, tokens);
        try checkAsAny(ctx, tokens);
        try checkChainedCast(ctx, tokens);
        try checkReexport(ctx, tokens);
        try checkAsConst(ctx, tokens);
    }

    if (cfg.layers.behavioural) {
        try checkThrow(ctx, tokens);
        try checkCatchClauses(ctx, tokens);
    }
}

const Ctx = struct {
    allocator: std.mem.Allocator,
    cfg: *const config.Config,
    findings: *std.ArrayList(Finding),
    path: []const u8,

    fn report(self: Ctx, line: u32, layer: []const u8, message: []const u8, severity: Severity) !void {
        try self.findings.append(self.allocator, .{
            .path = try self.allocator.dupe(u8, self.path),
            .line = line,
            .message = message,
            .layer = layer,
            .severity = severity,
        });
    }
};

// ---------------------------------------------------------------------------
// rules
// ---------------------------------------------------------------------------

/// `` `null` `` matches the literal keyword anywhere in code, including property
/// names (`o.null`, `{ null: 1 }`) and type positions (`| null`). strings,
/// templates text and comments never match
fn checkNullLiteral(ctx: Ctx, tokens: []const Token) !void {
    for (tokens) |token| {
        if (token.kind != .word) continue;
        if (!std.mem.eql(u8, token.text, "null")) continue;
        try ctx.report(token.line, "resilience", msg.null_literal, .err);
    }
}

/// the em-dash rule is the one rule that reads raw bytes rather than tokens,
/// because it has to reach inside strings, templates and comments, and biome's
/// tree matcher cannot (see the module doc). every occurrence is its own finding
fn checkEmDash(ctx: Ctx, content: []const u8) !void {
    const em_dash = "\u{2014}";
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, content, pos, em_dash)) |found| {
        try ctx.report(lineAt(content, found), "cosmetic", msg.em_dash, .err);
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

/// a `let` declaration: the keyword followed by a binding. `let` in a string or
/// comment never reaches the token stream, and a `let` used as a name (`o.let`,
/// `{ let: string }`, `let(x)`) is not a declaration
fn checkLetDeclaration(ctx: Ctx, tokens: []const Token) !void {
    for (tokens, 0..) |token, i| {
        if (!isWord(token, "let")) continue;
        if (isMemberAccess(tokens, i)) continue;
        if (i + 1 >= tokens.len) continue;

        const binding = tokens[i + 1];
        const declares = binding.kind == .word or isPunct(binding, "[") or isPunct(binding, "{");
        if (!declares) continue;

        try ctx.report(token.line, "resilience", msg.let_decl, .err);
    }
}

/// `switch ($expr) { ... }` -- a property or method named switch is not the
/// statement, and `switch` in a string or comment never reaches the tokens
fn checkSwitchStatement(ctx: Ctx, tokens: []const Token) !void {
    for (tokens, 0..) |token, i| {
        if (!isWord(token, "switch")) continue;
        if (isMemberAccess(tokens, i)) continue;
        if (i + 1 >= tokens.len or !isPunct(tokens[i + 1], "(")) continue;

        try ctx.report(token.line, "resilience", msg.switch_stmt, .err);
    }
}

/// `for ($init; $cond; $update) { $body }` -- C-style only. for..of and for..in
/// have no second `;` and are left alone
fn checkImperativeFor(ctx: Ctx, tokens: []const Token) !void {
    for (tokens, 0..) |token, i| {
        if (token.kind != .word) continue;
        if (!std.mem.eql(u8, token.text, "for")) continue;
        if (isMemberAccess(tokens, i)) continue;

        const open = i + 1;
        if (open >= tokens.len or !isPunct(tokens[open], "(")) continue;

        const close = matchingBracket(tokens, open) orelse continue;
        if (countTopLevelSemicolons(tokens, open, close) != 2) continue;
        if (close + 1 >= tokens.len or !isPunct(tokens[close + 1], "{")) continue;

        try ctx.report(token.line, "resilience", msg.imperative_for, .err);
    }
}

/// `` `$left == $right` ``. the tokeniser keeps `==` distinct from `===`/`!==`
fn checkDoubleEquals(ctx: Ctx, tokens: []const Token) !void {
    for (tokens) |token| {
        if (token.kind != .punct) continue;
        if (!std.mem.eql(u8, token.text, "==")) continue;
        try ctx.report(token.line, "resilience", msg.double_equals, .err);
    }
}

/// `` `$expr as any` `` -- the cast names `any`, whether it stands alone
/// (`as any`), carries a collection (`as any[]`) or joins a union
/// (`as any | T`). `: any` annotations and `import type` clauses are not casts
fn checkAsAny(ctx: Ctx, tokens: []const Token) !void {
    for (tokens, 0..) |token, i| {
        if (!isWord(token, "as")) continue;
        if (inImportClause(tokens, i)) continue;
        if (i + 1 >= tokens.len or !isWord(tokens[i + 1], "any")) continue;
        try ctx.report(token.line, "resilience", msg.as_any, .err);
    }
}

/// `` `$expr as $t1 as $t2` `` -- nested as-expressions with nothing between the
/// type and the next `as`. a parenthesis, comma or statement terminator ends the
/// search, which is why `(x as A) as B` and `f(x as A) as B` do not match
fn checkChainedCast(ctx: Ctx, tokens: []const Token) !void {
    for (tokens, 0..) |token, i| {
        if (!isWord(token, "as")) continue;
        if (inImportClause(tokens, i)) continue;

        const as_index = findAsEndingType(tokens, i + 1) orelse continue;
        try ctx.report(token.line, "resilience", msg.chained_cast, .err);
        _ = as_index;
    }
}

/// `` `export { $names } from $module` `` and `` `export * from $module` ``.
/// `export type { ... } from` and a local `export { a }` stay silent
fn checkReexport(ctx: Ctx, tokens: []const Token) !void {
    for (tokens, 0..) |token, i| {
        if (!isWord(token, "export")) continue;
        if (isMemberAccess(tokens, i)) continue;
        if (i + 1 >= tokens.len) continue;

        if (isPunct(tokens[i + 1], "*")) {
            try ctx.report(token.line, "resilience", msg.reexport, .err);
            continue;
        }
        if (!isPunct(tokens[i + 1], "{")) continue;

        const close = matchingBracket(tokens, i + 1) orelse continue;
        if (close + 1 >= tokens.len or !isWord(tokens[close + 1], "from")) continue;

        try ctx.report(token.line, "resilience", msg.reexport, .err);
    }
}

/// `` `const $name = { $members } as const` ``. a type annotation on the name
/// (`const X: T = { ... } as const`) does not match, a binding pattern
/// (`const { a } = { ... } as const`) does
fn checkAsConst(ctx: Ctx, tokens: []const Token) !void {
    for (tokens, 0..) |token, i| {
        if (!isWord(token, "const")) continue;
        if (isMemberAccess(tokens, i)) continue;

        const eq = findDeclaratorEquals(tokens, i + 1) orelse continue;
        if (eq + 1 >= tokens.len or !isPunct(tokens[eq + 1], "{")) continue;

        const obj_close = matchingBracket(tokens, eq + 1) orelse continue;
        if (obj_close + 2 >= tokens.len) continue;
        if (!isWord(tokens[obj_close + 1], "as")) continue;
        if (!isWord(tokens[obj_close + 2], "const")) continue;

        try ctx.report(token.line, "resilience", msg.as_const, .err);
    }
}

/// `` `throw $expr` ``. a property named throw (`{ throw: 1 }`, `o.throw`) is
/// not a throw statement
fn checkThrow(ctx: Ctx, tokens: []const Token) !void {
    for (tokens, 0..) |token, i| {
        if (!isWord(token, "throw")) continue;
        if (isMemberAccess(tokens, i)) continue;
        if (i + 1 < tokens.len and isPunct(tokens[i + 1], ":")) continue;
        try ctx.report(token.line, "behavioural", msg.throw_stmt, .err);
    }
}

/// the three catch rules, which all key off the same clause:
///   `try { } catch {}`      -> bare catch (error)
///   `try { } catch (e) {}`  -> bound catch (warning)
///   `try { } catch { body }` with no return/throw/console -> silent catch (warning)
/// an empty body trips both the error and the warning, exactly as the two
/// separate plugin files do
fn checkCatchClauses(ctx: Ctx, tokens: []const Token) !void {
    for (tokens, 0..) |token, i| {
        if (!isWord(token, "catch")) continue;
        if (isMemberAccess(tokens, i)) continue;

        var body_open = i + 1;
        var bound = false;
        if (body_open < tokens.len and isPunct(tokens[body_open], "(")) {
            const params_close = matchingBracket(tokens, body_open) orelse continue;
            // biome's `catch ($err)` pattern does not match a parameter with a
            // type annotation, so `catch (e: unknown) { ... }` produces nothing
            if (hasTopLevelColon(tokens, body_open + 1, params_close)) continue;
            body_open = params_close + 1;
            bound = true;
        }
        if (body_open >= tokens.len or !isPunct(tokens[body_open], "{")) continue;

        const body_close = matchingBracket(tokens, body_open) orelse continue;
        const body = tokens[body_open + 1 .. body_close];

        if (!bound and body.len == 0) {
            try ctx.report(token.line, "behavioural", msg.bare_catch, .err);
        }
        if (!handlesError(body)) {
            try ctx.report(token.line, "behavioural", msg.silent_catch, .warn);
        }
    }
}

/// `not contains return|throw|console`. `return;` counts, a string "return"
/// does not, since strings never reach the token stream
fn handlesError(body: []const Token) bool {
    for (body) |token| {
        if (token.kind != .word) continue;
        if (std.mem.eql(u8, token.text, "return")) return true;
        if (std.mem.eql(u8, token.text, "throw")) return true;
        if (std.mem.eql(u8, token.text, "console")) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// token helpers
// ---------------------------------------------------------------------------

fn isPunct(token: Token, text: []const u8) bool {
    return token.kind == .punct and std.mem.eql(u8, token.text, text);
}

fn isWord(token: Token, text: []const u8) bool {
    return token.kind == .word and std.mem.eql(u8, token.text, text);
}

/// `o.throw`, `o.null` and friends are property accesses, not syntax
fn isMemberAccess(tokens: []const Token, i: usize) bool {
    if (i == 0) return false;
    const previous = tokens[i - 1];
    return isPunct(previous, ".") or isPunct(previous, "?.");
}

/// `{` / `(` / `[` at `open`, index of the matching closer, nested pairs skipped
fn matchingBracket(tokens: []const Token, open: usize) ?usize {
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

/// `;` between `open` and `close` that is not inside a nested bracket pair
fn countTopLevelSemicolons(tokens: []const Token, open: usize, close: usize) usize {
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
fn inImportClause(tokens: []const Token, i: usize) bool {
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
fn hasTopLevelColon(tokens: []const Token, start: usize, end: usize) bool {
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
fn findAsEndingType(tokens: []const Token, start: usize) ?usize {
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
fn findDeclaratorEquals(tokens: []const Token, start: usize) ?usize {
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

const StringSet = struct {
    items: []const []const u8,

    fn contains(self: StringSet, text: []const u8) bool {
        for (self.items) |item| {
            if (std.mem.eql(u8, item, text)) return true;
        }
        return false;
    }
};

/// punctuation that ends a type expression
const type_terminators = StringSet{ .items = &.{
    ",", ";", "=", "=>", "?", ":", "==", "===", "!=", "!==", "&&", "||", "??", "+", "-", "*", "/", "%", "!", "~", "^", "=>=",
} };

/// keywords that can never appear inside a type, so they end it too
const type_stop_keywords = StringSet{ .items = &.{
    "const",  "let",   "var",    "return", "if",      "else",   "for",  "while", "do",
    "switch", "case",  "throw",  "try",    "catch",   "finally", "new", "class", "function",
    "import", "export", "await", "yield",  "break",   "continue", "enum", "interface", "namespace",
} };

// ---------------------------------------------------------------------------
// tokeniser
// ---------------------------------------------------------------------------

const TokenKind = enum { word, number, punct };

const Token = struct {
    text: []const u8,
    line: u32,
    kind: TokenKind,
};

const Lexer = struct {
    source: []const u8,
    pos: usize = 0,
    line_number: u32 = 1,
    tokens: std.ArrayList(Token) = .empty,
    allocator: std.mem.Allocator,
    /// `/` starts a regex when the previous token cannot end an expression
    regex_allowed: bool = true,

    fn push(self: *Lexer, kind: TokenKind, start: usize, end: usize, line: u32) !void {
        try self.tokens.append(self.allocator, .{ .text = self.source[start..end], .line = line, .kind = kind });
    }

    fn advanceLine(self: *Lexer) void {
        self.line_number += 1;
    }
};

fn tokenize(allocator: std.mem.Allocator, source: []const u8, line_out: *u32) ![]Token {
    var lexer = Lexer{ .source = source, .allocator = allocator };
    try lex(&lexer, .end_of_input);
    line_out.* = lexer.line_number;
    return lexer.tokens.toOwnedSlice(allocator);
}

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
            lexer.pos += 1;
            skipQuoted(lexer, char);
            continue;
        }

        if (char == '`') {
            lexer.pos += 1;
            try lexTemplate(lexer);
            continue;
        }

        if (char == '/' and lexer.regex_allowed) {
            lexer.pos += 1;
            skipRegex(lexer);
            lexer.regex_allowed = false;
            continue;
        }

        if (char == '<' and lexer.regex_allowed and looksLikeJsx(source, lexer.pos)) {
            if (try skipJsx(lexer)) continue;
        }

        if (char == '}') {
            if (stop == .brace_close) {
                lexer.pos += 1;
                return;
            }
            try lexer.push(.punct, lexer.pos, lexer.pos + 1, lexer.line_number);
            lexer.pos += 1;
            lexer.regex_allowed = false;
            continue;
        }

        if (isIdentifierStart(char)) {
            const start = lexer.pos;
            const line = lexer.line_number;
            lexer.pos += 1;
            while (lexer.pos < source.len and isIdentifierContinue(source[lexer.pos])) lexer.pos += 1;
            try lexer.push(.word, start, lexer.pos, line);
            lexer.regex_allowed = !canEndExpression(lexer.tokens.items[lexer.tokens.items.len - 1].text);
            continue;
        }

        if (char >= '0' and char <= '9') {
            const start = lexer.pos;
            const line = lexer.line_number;
            lexer.pos += 1;
            while (lexer.pos < source.len and (isIdentifierContinue(source[lexer.pos]) or source[lexer.pos] == '.')) lexer.pos += 1;
            try lexer.push(.number, start, lexer.pos, line);
            lexer.regex_allowed = false;
            continue;
        }

        const matched = matchPunctuation(source, lexer.pos);
        try lexer.push(.punct, lexer.pos, lexer.pos + matched.len, lexer.line_number);
        lexer.pos += matched.len;
        lexer.regex_allowed = !canEndExpression(matched);
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
/// them is skipped, exactly as grit's tree matching skips it
fn lexTemplate(lexer: *Lexer) LexError!void {
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
            lexer.regex_allowed = false;
            return;
        }
        if (char == '$' and lexer.pos + 1 < source.len and source[lexer.pos + 1] == '{') {
            lexer.pos += 2;
            lexer.regex_allowed = true;
            try lex(lexer, .brace_close);
            continue;
        }
        lexer.pos += 1;
    }
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
    const start_regex_allowed = lexer.regex_allowed;
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
                    lexer.regex_allowed = true;
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
            lexer.regex_allowed = true;
            try lex(lexer, .brace_close);
            i = lexer.pos;
            continue;
        }
        i += 1;
    }

    // an element that is still open at end of source was not an element: a
    // generic arrow's `<T>` reads as an opening tag, and accepting it swallows
    // everything that follows, which silently hides every finding in the rest of
    // the file. self-closing elements leave depth at 0, so both shapes that
    // really are JSX satisfy this
    if (!saw_element or depth != 0) {
        lexer.pos = start_pos;
        lexer.line_number = start_line;
        // a `{ ... }` container scanned before the element proved false already
        // pushed its tokens, so the fallback has to drop them too
        lexer.tokens.shrinkRetainingCapacity(start_tokens);
        lexer.regex_allowed = start_regex_allowed;
        return false;
    }

    lexer.pos = i;
    lexer.regex_allowed = false;
    return true;
}

fn isIdentifierStart(char: u8) bool {
    return (char >= 'a' and char <= 'z') or (char >= 'A' and char <= 'Z') or char == '_' or char == '$' or char >= 0x80;
}

fn isIdentifierContinue(char: u8) bool {
    return isIdentifierStart(char) or (char >= '0' and char <= '9');
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

/// longest match first, so `===` never becomes `==` + `=`
const punctuation = [_][]const u8{
    ">>>=", "===", "!==", "**=", "&&=", "||=", "??=", "...", ">>>", "==",  "!=",
    "<=",   ">=",  "&&",  "||",  "??",  "?.",  "++",  "--",  "+=",  "-=",  "*=",
    "/=",   "%=",  "<<=", ">>=", "**",  "=>",  "|=",  "&=",  "^=",  "<<",  ">>",
    "(",    ")",   "{",   "}",   "[",   "]",   ";",   ",",   ":",   "?",   ".",
    "=",    "+",   "-",   "*",   "/",   "%",   "<",   ">",   "!",   "~",   "&",
    "|",    "^",   "@",   "#",
};

fn matchPunctuation(source: []const u8, pos: usize) []const u8 {
    for (punctuation) |candidate| {
        if (pos + candidate.len > source.len) continue;
        if (std.mem.eql(u8, source[pos .. pos + candidate.len], candidate)) return candidate;
    }
    return source[pos .. pos + 1];
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

/// the three native-only rules have no biome oracle to diff against, so their
/// semantics are pinned to the committed corpus instead: `tests/lint-corpus`
/// documents which shapes are and are not a violation
const NativeOnlyExpectation = struct {
    file: []const u8,
    em_dash: usize = 0,
    let_decl: usize = 0,
    switch_stmt: usize = 0,
};

const native_only_expectations = [_]NativeOnlyExpectation{
    .{ .file = "emdash-comment.ts", .em_dash = 1 },
    .{ .file = "emdash-string.ts", .em_dash = 1 },
    .{ .file = "emdash-template.ts", .em_dash = 1 },
    .{ .file = "let-init.ts", .let_decl = 1 },
    .{ .file = "let-noinit.ts", .let_decl = 1 },
    .{ .file = "let-destructure.ts", .let_decl = 1 },
    .{ .file = "let-typed.ts", .let_decl = 1 },
    .{ .file = "let-var.ts", .let_decl = 1 },
    .{ .file = "switch-basic.ts", .switch_stmt = 1 },
    .{ .file = "switch-stmt.ts", .switch_stmt = 1 },
    // a comment, a property name, a member access and a regex are not syntax
    .{ .file = "let-comment.ts" },
    .{ .file = "let-prop.ts" },
    .{ .file = "switch-comment.ts" },
    .{ .file = "switch-prop.ts" },
    .{ .file = "regex-switch.ts" },
    // these carry their own rule's finding plus a `let` accumulator, and the
    // run-14 dead-rule fixture has one of each
    .{ .file = "d-for-nested.ts", .let_decl = 2 },
    .{ .file = "for-cstyle.ts", .let_decl = 2 },
    .{ .file = "for-in.ts", .let_decl = 1 },
    .{ .file = "for-of.ts", .let_decl = 1 },
    .{ .file = "y-dead-only.ts", .em_dash = 2, .let_decl = 1, .switch_stmt = 1 },
};

test "native-only rules match the committed corpus expectations" {
    const a = testing.allocator;
    for (native_only_expectations) |expectation| {
        const path = try std.fmt.allocPrint(a, "tests/lint-corpus/{s}", .{expectation.file});
        defer a.free(path);

        const content = std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, a, .limited(1 << 16)) catch |err| {
            std.debug.print("could not read {s}: {s}\n", .{ path, @errorName(err) });
            return err;
        };
        defer a.free(content);

        const findings = try lintTest(a, content);
        defer freeFindings(a, findings);

        testing.expectEqual(expectation.em_dash, countFindings(findings, msg.em_dash)) catch |err| {
            std.debug.print("{s}: em-dash count mismatch\n", .{expectation.file});
            return err;
        };
        testing.expectEqual(expectation.let_decl, countFindings(findings, msg.let_decl)) catch |err| {
            std.debug.print("{s}: let count mismatch\n", .{expectation.file});
            return err;
        };
        testing.expectEqual(expectation.switch_stmt, countFindings(findings, msg.switch_stmt)) catch |err| {
            std.debug.print("{s}: switch count mismatch\n", .{expectation.file});
            return err;
        };
    }
}

const testing = std.testing;

const all_layers = config.Config{
    .surfaces = &.{},
    .layers = .{ .cosmetic = true, .structural = true, .resilience = true, .behavioural = true },
};

fn lintTest(allocator: std.mem.Allocator, source: []const u8) ![]Finding {
    var findings: std.ArrayList(Finding) = .empty;
    try lintContent(allocator, &all_layers, &findings, "test.ts", source);
    return findings.toOwnedSlice(allocator);
}

fn countFindings(findings: []const Finding, message: []const u8) usize {
    var total: usize = 0;
    for (findings) |finding| {
        if (std.mem.eql(u8, finding.message, message)) total += 1;
    }
    return total;
}

fn expectCount(allocator: std.mem.Allocator, source: []const u8, message: []const u8, expected: usize) !void {
    const findings = try lintTest(allocator, source);
    defer freeFindings(allocator, findings);
    try testing.expectEqual(expected, countFindings(findings, message));
}

test "null literal is flagged in code but not in strings, comments or regexes" {
    const a = testing.allocator;
    try expectCount(a, "export const x = null;\n", msg.null_literal, 1);
    try expectCount(a, "export const o = { null: 1 };\n", msg.null_literal, 1);
    try expectCount(a, "export const v = o.null;\n", msg.null_literal, 1);
    try expectCount(a, "export type T = { a: number } | null;\n", msg.null_literal, 1);
    try expectCount(a, "export const s = \"null\";\n", msg.null_literal, 0);
    try expectCount(a, "// null\nexport const s = 1;\n", msg.null_literal, 0);
    try expectCount(a, "export const s = /null/;\n", msg.null_literal, 0);
    try expectCount(a, "export const s = `null ${1}`;\n", msg.null_literal, 0);
}

test "imperative for is flagged, for..of and for..in are not" {
    const a = testing.allocator;
    try expectCount(a, "for (let i = 0; i < 3; i++) {\n  total += i;\n}\n", msg.imperative_for, 1);
    try expectCount(a, "for (;;) {\n  break;\n}\n", msg.imperative_for, 1);
    try expectCount(a, "for (const x of xs) {\n  total += x;\n}\n", msg.imperative_for, 0);
    try expectCount(a, "for (const k in o) {\n  total += o[k];\n}\n", msg.imperative_for, 0);
    try expectCount(a, "o.for(() => undefined);\n", msg.imperative_for, 0);
}

test "double equals is flagged, === and != are not" {
    const a = testing.allocator;
    try expectCount(a, "export const f = (a: number, b: number): boolean => a == b;\n", msg.double_equals, 1);
    try expectCount(a, "export const f = (a: number, b: number): boolean => a === b;\n", msg.double_equals, 0);
    try expectCount(a, "export const f = (a: number, b: number): boolean => a !== b;\n", msg.double_equals, 0);
    try expectCount(a, "export const s = \"a == b\";\n", msg.double_equals, 0);
}

test "as any matches the type the cast names, and not an annotation" {
    const a = testing.allocator;
    try expectCount(a, "export const f = (y: unknown): string => y as any;\n", msg.as_any, 1);
    try expectCount(a, "export const f = (y: unknown): string[] => y as any[];\n", msg.as_any, 1);
    try expectCount(a, "export const f = (y: unknown): string | number => y as any | number;\n", msg.as_any, 1);
    try expectCount(a, "export const f = (y: unknown): string => y as any as string;\n", msg.as_any, 1);
    try expectCount(a, "export const f = (x: any): any => x;\n", msg.as_any, 0);
    try expectCount(a, "export type T = any;\n", msg.as_any, 0);
    try expectCount(a, "import { a as any } from \"./a\";\n", msg.as_any, 0);
    try expectCount(a, "export { a as any } from \"./a\";\n", msg.as_any, 0);
}

test "chained casts only match nested as-expressions" {
    const a = testing.allocator;
    try expectCount(a, "export const f = (y: unknown): number => y as unknown as number;\n", msg.chained_cast, 1);
    try expectCount(a, "export const f = (y: unknown): number => (y as unknown) as number;\n", msg.chained_cast, 0);
    try expectCount(a, "export const f = (y: unknown): number => g(y as string) as number;\n", msg.chained_cast, 0);
    try expectCount(a, "export const f = (y: unknown): number => x as { a: number } as number;\n", msg.chained_cast, 1);
    try expectCount(a, "export const f = (y: unknown): number => x as NS.Foo as number;\n", msg.chained_cast, 1);
    try expectCount(a, "export const a = (x: unknown): string => x as string;\nexport const c = (y: unknown): number => y as number as number;\n", msg.chained_cast, 1);
}

test "proxy re-exports are flagged, a local export and a type export are not" {
    const a = testing.allocator;
    try expectCount(a, "export { a } from \"./a\";\n", msg.reexport, 1);
    try expectCount(a, "export {\n  a,\n} from \"./a\";\n", msg.reexport, 1);
    try expectCount(a, "export { a as b } from \"./a\";\n", msg.reexport, 1);
    try expectCount(a, "export {} from \"./a\";\n", msg.reexport, 1);
    try expectCount(a, "export * from \"./a\";\n", msg.reexport, 1);
    try expectCount(a, "export * as ns from \"./a\";\n", msg.reexport, 1);
    try expectCount(a, "export type { A } from \"./a\";\n", msg.reexport, 0);
    try expectCount(a, "const a = 1;\nexport { a };\n", msg.reexport, 0);
}

test "const as const needs an object literal initializer" {
    const a = testing.allocator;
    try expectCount(a, "export const X = { a: 1 } as const;\n", msg.as_const, 1);
    try expectCount(a, "export const X = {\n  a: 1,\n} as const;\n", msg.as_const, 1);
    try expectCount(a, "const q = { a: 1 } as const;\n", msg.as_const, 1);
    try expectCount(a, "export const f = (o: { a: number }): void => {\n  const { a } = { a: 1 } as const;\n};\n", msg.as_const, 1);
    try expectCount(a, "export const X: Record<string, number> = { a: 1 } as const;\n", msg.as_const, 0);
    try expectCount(a, "export const Y = 1 as const;\n", msg.as_const, 0);
    try expectCount(a, "export const W = [1, 2] as const;\n", msg.as_const, 0);
    try expectCount(a, "export const Z = { a: { b: 1 } as const };\n", msg.as_const, 0);
}

test "throw statements are flagged, property names are not" {
    const a = testing.allocator;
    try expectCount(a, "export const f = (): void => {\n  throw new Error(\"x\");\n};\n", msg.throw_stmt, 1);
    try expectCount(a, "export const f = (b: boolean): void => {\n  if (b) throw new Error(\"x\");\n};\n", msg.throw_stmt, 1);
    try expectCount(a, "export const o = { throw: 1 };\nexport const v = o.throw;\n", msg.throw_stmt, 0);
    try expectCount(a, "export const s = \"throw new Error()\";\n", msg.throw_stmt, 0);
    try expectCount(a, "export const re = /throw/;\n", msg.throw_stmt, 0);
}

test "bare catch is an error and an empty catch body also warns" {
    const a = testing.allocator;
    try expectCount(a, "try {\n  JSON.parse(\"{}\");\n} catch {}\n", msg.bare_catch, 1);
    try expectCount(a, "try {\n  JSON.parse(\"{}\");\n} catch {\n  // TODO\n}\n", msg.bare_catch, 1);
    try expectCount(a, "try {\n  JSON.parse(\"{}\");\n} catch {} \n", msg.silent_catch, 1);
    try expectCount(a, "try {\n  JSON.parse(\"{}\");\n} catch (e) {}\n", msg.bare_catch, 0);
}

test "catch bodies that return, throw or log are left alone" {
    const a = testing.allocator;
    try expectCount(a, "try {\n  JSON.parse(\"{}\");\n} catch {\n  return;\n}\n", msg.silent_catch, 0);
    try expectCount(a, "try {\n  JSON.parse(\"{}\");\n} catch (e) {\n  throw new Error(String(e));\n}\n", msg.silent_catch, 0);
    try expectCount(a, "try {\n  JSON.parse(\"{}\");\n} catch {\n  console.error(\"bad\");\n}\n", msg.silent_catch, 0);
    try expectCount(a, "try {\n  JSON.parse(\"{}\");\n} catch (e: unknown) {\n  void e;\n}\n", msg.silent_catch, 0);
    try expectCount(a, "try {\n  JSON.parse(\"{}\");\n} catch (e: unknown) {}\n", msg.bare_catch, 0);
    try expectCount(a, "try {\n  JSON.parse(\"{}\");\n} catch {\n  void 0;\n}\n", msg.silent_catch, 1);
    try expectCount(a, "promise.catch(() => undefined);\n", msg.silent_catch, 0);
    try expectCount(a, "try {\n  JSON.parse(\"{}\");\n} catch {\n  void \"return 1\";\n}\n", msg.silent_catch, 1);
}

test "jsx text is never matched but jsx expressions are" {
    const a = testing.allocator;
    const jsx =
        "export const C = (): unknown => (\n" ++
        "  <div>\n" ++
        "    null and switch and throw and let\n" ++
        "  </div>\n" ++
        ");\n";
    try expectCount(a, jsx, msg.null_literal, 0);
    try expectCount(a, jsx, msg.throw_stmt, 0);

    const jsx_expression =
        "export const C = (p: { readonly n: unknown }): unknown => (\n" ++
        "  <div attr=\"x\">\n" ++
        "    {p.n as any}\n" ++
        "  </div>\n" ++
        ");\n";
    try expectCount(a, jsx_expression, msg.as_any, 1);
}

test "the three rules biome 2.5.11 cannot compile are enforced natively" {
    const a = testing.allocator;
    const findings = try lintTest(a, "let x = 1;\nswitch (x) {\n  case 1: break;\n}\n// \xe2\x80\x94\n");
    defer freeFindings(a, findings);
    try testing.expectEqual(@as(usize, 3), findings.len);
    try testing.expectEqual(@as(usize, 1), countFindings(findings, msg.let_decl));
    try testing.expectEqual(@as(usize, 1), countFindings(findings, msg.switch_stmt));
    try testing.expectEqual(@as(usize, 1), countFindings(findings, msg.em_dash));
}

test "em-dash is found in code, strings, templates and comments" {
    const a = testing.allocator;
    try expectCount(a, "export const s = \"a \xe2\x80\x94 b\";\n", msg.em_dash, 1);
    try expectCount(a, "export const t = `a \xe2\x80\x94 b`;\n", msg.em_dash, 1);
    try expectCount(a, "// a comment \xe2\x80\x94 here\nexport const x = 1;\n", msg.em_dash, 1);
    try expectCount(a, "/* block \xe2\x80\x94 here */\nexport const x = 1;\n", msg.em_dash, 1);
    try expectCount(a, "export const a = \"\xe2\x80\x94\xe2\x80\x94\";\n", msg.em_dash, 2);
    // an en-dash or a hyphen is not an em-dash
    try expectCount(a, "export const a = \"a \xe2\x80\x93 b\";\n", msg.em_dash, 0);

    const findings = try lintTest(a, "export const x = 1;\n// one \xe2\x80\x94\nexport const y = 2;\n// two \xe2\x80\x94\n");
    defer freeFindings(a, findings);
    try testing.expectEqual(@as(u32, 2), findings[0].line);
    try testing.expectEqual(@as(u32, 4), findings[1].line);
}

test "let declarations are flagged, let as a name is not" {
    const a = testing.allocator;
    try expectCount(a, "let x = 1;\n", msg.let_decl, 1);
    try expectCount(a, "let x;\n", msg.let_decl, 1);
    try expectCount(a, "let { a, b } = o;\n", msg.let_decl, 1);
    try expectCount(a, "let [a, b] = xs;\n", msg.let_decl, 1);
    try expectCount(a, "for (let i = 0; i < 3; i++) {}\n", msg.let_decl, 1);
    try expectCount(a, "declare let x: number;\n", msg.let_decl, 1);
    // not declarations
    try expectCount(a, "export const v = o.let;\n", msg.let_decl, 0);
    try expectCount(a, "export const v = o?.let;\n", msg.let_decl, 0);
    try expectCount(a, "export type T = { let: string };\n", msg.let_decl, 0);
    try expectCount(a, "export const s = \"let x = 1\";\n", msg.let_decl, 0);
    try expectCount(a, "// let x = 1\nexport const x = 1;\n", msg.let_decl, 0);
}

test "switch statements are flagged, a switch property is not" {
    const a = testing.allocator;
    try expectCount(a, "switch (x) {\n  case 1: break;\n}\n", msg.switch_stmt, 1);
    try expectCount(a, "switch (x) {}\n", msg.switch_stmt, 1);
    try expectCount(a, "export const v = o.switch(x);\n", msg.switch_stmt, 0);
    try expectCount(a, "export const v = o?.switch(x);\n", msg.switch_stmt, 0);
    try expectCount(a, "export const s = \"switch (x)\";\n", msg.switch_stmt, 0);
    try expectCount(a, "// switch (x)\nexport const x = 1;\n", msg.switch_stmt, 0);
}

test "layers gate their rules" {
    const a = testing.allocator;
    const resilience_off = config.Config{
        .surfaces = &.{},
        .layers = .{ .cosmetic = true, .structural = true, .resilience = false, .behavioural = false },
    };
    var findings: std.ArrayList(Finding) = .empty;
    try lintContent(a, &resilience_off, &findings, "test.ts", "export const x = null;\nthrow new Error(\"x\");\n");
    defer {
        for (findings.items) |finding| a.free(finding.path);
        findings.deinit(a);
    }
    try testing.expectEqual(@as(usize, 0), findings.items.len);
}

test "the trigger fast path only over-includes" {
    // files a live rule can never fire in
    try testing.expect(!maybeTrigger("export const total = (items: Item[]): number =>\n  items.reduce((sum, item) => sum + item.value, 1);\n"));
    try testing.expect(!maybeTrigger("import { lib1 } from \"../../lib/lib1\";\n"));
    try testing.expect(!maybeTrigger("export type Item = { readonly id: string };\n"));
    // substrings that are not words
    try testing.expect(!maybeTrigger("export const klass = (asset: string): string => format(asset);\n"));
    try testing.expect(!maybeTrigger("export type { A } from \"./a\";\n"));
    try testing.expect(!maybeTrigger("export * from \"./a\";\n"));

    // every live rule's own literal has to answer
    try testing.expect(maybeTrigger("export const x = null;\n"));
    try testing.expect(maybeTrigger("// let x = 1 and switch (x) {}\n"));
    try testing.expect(maybeTrigger("export const s = \"\xe2\x80\x94\";\n"));
    try testing.expect(maybeTrigger("for (let i = 0; i < 3; i++) {}\n"));
    try testing.expect(maybeTrigger("export const f = (a: number, b: number): boolean => a == b;\n"));
    try testing.expect(maybeTrigger("export const f = (y: unknown): string => y as any;\n"));
    try testing.expect(maybeTrigger("throw new Error(\"x\");\n"));
    try testing.expect(maybeTrigger("try {\n} catch {}\n"));
    try testing.expect(maybeTrigger("export { a } from \"./a\";\n"));
    try testing.expect(maybeTrigger("export\n{\n  a,\n} from \"./a\";\n"));
    try testing.expect(maybeTrigger("export /* c */ { a } from \"./a\";\n"));
    try testing.expect(maybeTrigger("export // c\n{ a } from \"./a\";\n"));
}

test "tokenizer keeps operators distinct" {
    const a = testing.allocator;
    var line: u32 = 1;
    const tokens = try tokenize(a, "a === b == c !== d = e => f", &line);
    defer a.free(tokens);
    const expected = [_][]const u8{ "a", "===", "b", "==", "c", "!==", "d", "=", "e", "=>", "f" };
    try testing.expectEqual(expected.len, tokens.len);
    for (expected, 0..) |want, i| try testing.expectEqualStrings(want, tokens[i].text);
}

test "tokenizer descends into template substitutions" {
    const a = testing.allocator;
    var line: u32 = 1;
    const tokens = try tokenize(a, "const a = `x ${null} y ${`n ${throw}`}`;\n", &line);
    defer a.free(tokens);
    var saw_null = false;
    var saw_throw = false;
    for (tokens) |token| {
        if (std.mem.eql(u8, token.text, "null")) saw_null = true;
        if (std.mem.eql(u8, token.text, "throw")) saw_throw = true;
    }
    try testing.expect(saw_null);
    try testing.expect(saw_throw);
}

test "tokenizer tracks line numbers" {
    const a = testing.allocator;
    var line: u32 = 1;
    const tokens = try tokenize(a, "a\n\nb\nc", &line);
    defer a.free(tokens);
    try testing.expectEqual(@as(u32, 1), tokens[0].line);
    try testing.expectEqual(@as(u32, 3), tokens[1].line);
    try testing.expectEqual(@as(u32, 4), tokens[2].line);
}
