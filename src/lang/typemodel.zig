const std = @import("std");
const ts = @import("ts.zig");
const ir = @import("../ir.zig");

pub const Token = ts.Token;

/// a type's structure, read from the token stream
///
/// the front-end models a type only as an extent: `skipType` walks one and
/// records nothing, and `type_decl` documents "its span is exact, its children
/// are empty". the detectors the type rules are ported from walk a real
/// TypeScript AST, so they read a union's members, an array's element and an
/// object literal's member list, none of which the tree carries.
///
/// this module recovers that structure from the extent instead, which keeps the
/// parser, the IR and the frozen token oracle (`src/lint.zig`) untouched: a rule
/// reads the file's tree for the declaration shapes the tree already models, and
/// reads its types here.
///
/// the front-end's own type scanner is not reusable for it. `skipType` answers
/// only where a type stops, and it is tuned for that question: it treats a `{`
/// as a body when the caller says a body may follow, and it stops at a `?` and a
/// `:` because they end a type inside a parameter list. reading members needs
/// the opposite, because a `?` and a `:` are the member's own punctuation

/// where an annotation sits. a detector reports a different node per position,
/// which is why the position travels with the annotation rather than being
/// recomputed by every rule
pub const Position = enum {
    /// `type X = <here>`
    alias_type,
    /// `const x: <here> = ...`
    variable_type,
    /// `(name: <here>)` on a function, method, arrow, signature or constructor
    parameter_type,
    /// `(): <here> => ...` on any function-like
    return_type,
    /// `{ name: <here> }` in an object type
    property_type,
};

/// the object type a member belongs to
pub const ObjectKind = enum {
    /// `{ a: T }`, the shape `require-readonly-type-members` walks
    type_literal,
    /// the body of an `interface`. its members are property signatures, so
    /// `no-optional-properties` reads them, and they are not inside a type
    /// literal, which is the narrowing that rule's detector records
    interface_body,
};

pub const Annotation = struct {
    position: Position,
    /// first token of the type expression
    type_start: usize,
    /// one past the type expression's last token
    type_end: usize,
    /// the token a detector reports for this position, which is the node's own
    /// `getStart()`. for a member it is the member's first token, a leading
    /// `readonly` included, and for a parameter it is the parameter's
    report_start: usize,
    /// the enclosing object type, for `property_type`
    object: ?ObjectKind = null,
    /// the `?` of a property signature. a parameter's `?` is not one: a
    /// parameter is not a member of an object type, and the detector that bans
    /// optional properties reports no parameter
    optional: bool = false,
    /// a `readonly` modifier on the member, which is what
    /// `require-readonly-type-members` reads
    readonly: bool = false,
};

/// every annotation in one file, in source order
pub const Table = struct {
    arena: std.heap.ArenaAllocator,
    items: []const Annotation = &.{},

    pub fn deinit(self: *Table) void {
        self.arena.deinit();
    }
};

/// read every type annotation the type rules can report
///
/// ponytail: each rule builds its own table, so a file is scanned once per
/// enabled type rule rather than once. the scan is a walk of the token list with
/// no parse, four rules read it today, and a profile has not shown it. if it
/// ever does, the fix is one lazily-built field on `rules.Context`, beside the
/// `walk` and `scopes` the engine already shares
pub fn analyze(
    allocator: std.mem.Allocator,
    tokens: []const Token,
    module: *const ir.Module,
    walk: []const ir.WalkEntry,
) !Table {
    var table = Table{ .arena = std.heap.ArenaAllocator.init(allocator) };
    const arena = table.arena.allocator();

    var list: std.ArrayList(Annotation) = .empty;
    var reader = Reader{ .arena = arena, .tokens = tokens, .list = &list };

    for (walk) |entry| {
        const span = module.spanOf(entry.index);
        const bounds = Bounds.around(tokens, span.start, span.end);
        switch (entry.kind) {
            .type_decl => try reader.readTypeDeclaration(bounds),
            .variable_decl => try reader.readVariableDeclaration(bounds),
            // a class method reaches the tree as a function_decl child of its
            // class_decl, so this covers methods without naming them, and a
            // class field arrives as a `.member` node, which is the detector's
            // own class-field exclusion
            .function_decl, .function_expr, .arrow => try reader.readCallable(bounds),
            else => {},
        }
    }

    std.mem.sort(Annotation, list.items, {}, annotationBefore);
    table.items = try arena.dupe(Annotation, list.items);
    return table;
}

/// the number of members of a union type whose every member is a string
/// literal, or 0 when the extent is not such a union
///
/// two is the floor the detector applies, and a mixed union returns 0: every
/// member has to be a literal, not merely one of them. a parenthesised literal
/// is a different node to the detector, and it is a different extent here
pub fn stringLiteralUnionCount(tokens: []const Token, start: usize, end: usize) usize {
    if (start >= end) return 0;
    var count: usize = 0;
    var cursor = start;
    while (cursor < end) {
        const separator = findAtTop(tokens, cursor, end, "|") orelse end;
        if (!isStringLiteralExtent(tokens, cursor, separator)) return 0;
        count += 1;
        cursor = separator + 1;
    }
    return if (count >= 2) count else 0;
}

/// `T[]` or `Array<T>` with no `readonly` operator wrapping it
///
/// a detector reads `readonly T[]` as a type operator over an array rather than
/// an array, so the `readonly` prefix makes it immutable and out of scope, and
/// `ReadonlyArray<T>` fails the exact-name test. the reference has to cover the
/// whole extent: `Array<T> | U` is a union to the detector, not a reference
pub fn isMutableArrayType(tokens: []const Token, start: usize, end: usize) bool {
    if (start >= end) return false;
    const first = tokens[start];
    if (first.kind == .word and first.isWord("readonly")) return false;

    if (isPunct(tokens[end - 1], "]")) {
        const open = matchingOpener(tokens, end - 1, start) orelse return false;
        if (open > start) return true;
    }

    if (first.kind == .word and first.isWord("Array")) {
        if (start + 1 == end) return true;
        if (isPunct(tokens[start + 1], "<")) {
            const close = matchingAngleClose(tokens, start + 1, end) orelse return false;
            return close + 1 == end;
        }
    }
    return false;
}

const Bounds = struct {
    start: usize,
    end: usize,

    fn around(tokens: []const Token, from: u32, to: u32) Bounds {
        return .{
            .start = tokenAtOrAfter(tokens, from),
            .end = tokenAtOrAfter(tokens, to),
        };
    }
};

/// the only failure a read can report: the annotation list growing. the walk
/// itself is total, because a construct it cannot read is skipped rather than
/// reported as a violation
const ReadError = std.mem.Allocator.Error;

const Reader = struct {
    arena: std.mem.Allocator,
    tokens: []const Token,
    list: *std.ArrayList(Annotation),

    fn add(self: *Reader, annotation: Annotation) ReadError!void {
        try self.list.append(self.arena, annotation);
    }

    /// `type X = T`, `interface X { ... }`, and the declarations that carry no
    /// annotation at all (`enum`, `namespace`)
    fn readTypeDeclaration(self: *Reader, bounds: Bounds) ReadError!void {
        const tokens = self.tokens;
        var start = bounds.start;
        const end = trimEnd(tokens, bounds.start, bounds.end);
        while (start < end and tokens[start].kind == .word and
            (tokens[start].isWord("declare") or tokens[start].isWord("export") or tokens[start].isWord("default")))
        {
            start += 1;
        }
        if (start >= end) return;

        if (tokens[start].isWord("type")) {
            // `type X<T = string> = T`: the alias `=` is the one the type
            // parameters do not own, which is why the search is angle-aware
            const equals = findAtTop(tokens, start + 1, end, "=") orelse return;
            const type_start = equals + 1;
            if (type_start >= end) return;
            try self.add(.{
                .position = .alias_type,
                .type_start = type_start,
                .type_end = end,
                .report_start = type_start,
            });
            try self.readTypeExtent(type_start, end);
            return;
        }

        if (tokens[start].isWord("interface")) {
            const open = findAtTop(tokens, start + 1, end, "{") orelse return;
            try self.readObjectLiteral(open, .interface_body);
        }
    }

    /// `x: T = value`, and the destructured forms, whose `:` the brace depth
    /// tells from an object key
    ///
    /// the colon is searched only before the declarator's `=`, so a ternary in
    /// the initializer cannot be read as an annotation
    fn readVariableDeclaration(self: *Reader, bounds: Bounds) ReadError!void {
        const tokens = self.tokens;
        const end = trimEnd(tokens, bounds.start, bounds.end);
        const equals = findAtTop(tokens, bounds.start, end, "=") orelse end;
        const colon = findAtTop(tokens, bounds.start, equals, ":") orelse return;
        const type_start = colon + 1;
        if (type_start >= equals) return;

        try self.add(.{
            .position = .variable_type,
            .type_start = type_start,
            .type_end = equals,
            .report_start = type_start,
        });
        try self.readTypeExtent(type_start, equals);
    }

    /// `function f(a: T): R { ... }`, the arrow forms, and a class method
    fn readCallable(self: *Reader, bounds: Bounds) ReadError!void {
        const tokens = self.tokens;
        const end = bounds.end;
        const open = findParameterList(tokens, bounds.start, end) orelse return;
        const close = matchingCloser(tokens, open, end) orelse return;
        try self.readParameters(open + 1, close);

        if (close + 1 >= end or !isPunct(tokens[close + 1], ":")) return;
        const type_start = close + 2;
        if (type_start >= end) return;
        // the front-end's own return-type walk stops at a `{`, so a function
        // whose return type is an object literal parses its type as a body. this
        // reader does not inherit that gap: it tells the two apart by what
        // precedes the brace, and a type operator before it means the type
        // continues
        const type_end = trimEnd(tokens, type_start, endOfType(tokens, type_start, end));
        if (type_start >= type_end) return;

        try self.add(.{
            .position = .return_type,
            .type_start = type_start,
            .type_end = type_end,
            .report_start = type_start,
        });
        try self.readTypeExtent(type_start, type_end);
    }

    /// the annotations between a parameter list's brackets
    fn readParameters(self: *Reader, start: usize, end: usize) ReadError!void {
        var chunk_start = start;
        while (nextSeparator(self.tokens, chunk_start, end)) |separator| {
            try self.readParameter(chunk_start, separator);
            chunk_start = separator + 1;
        }
        try self.readParameter(chunk_start, end);
    }

    /// `name: T`, `name?: T`, `...rest: T[]`, `{ a }: T` and `x: T = default`
    ///
    /// the whole parameter is the reported node, so the reported token is the
    /// parameter's first one, a leading `...` or `readonly` included. a `?` here
    /// is never an optional property: a parameter is not a member of an object
    fn readParameter(self: *Reader, start: usize, end: usize) ReadError!void {
        const tokens = self.tokens;
        const parameter_end = trimEnd(tokens, start, end);
        if (start >= parameter_end) return;
        const colon = findAtTop(tokens, start, parameter_end, ":") orelse return;
        const type_start = colon + 1;
        const type_end = findAtTop(tokens, type_start, parameter_end, "=") orelse parameter_end;
        if (type_start >= type_end) return;

        try self.add(.{
            .position = .parameter_type,
            .type_start = type_start,
            .type_end = type_end,
            .report_start = start,
        });
        try self.readTypeExtent(type_start, type_end);
    }

    /// the members between an object type's braces
    fn readObjectLiteral(self: *Reader, open: usize, object: ObjectKind) ReadError!void {
        const tokens = self.tokens;
        const close = matchingCloser(tokens, open, tokens.len) orelse return;
        var chunk_start = open + 1;
        while (nextSeparator(tokens, chunk_start, close)) |separator| {
            try self.readMember(chunk_start, separator, object);
            chunk_start = separator + 1;
        }
        try self.readMember(chunk_start, close, object);
    }

    /// one member of an object type
    ///
    /// only a property signature produces a `property_type`, which is how the
    /// two member rules keep the detector's narrowing instead of re-deciding it:
    /// a method, a call signature, a construct signature, an index signature and
    /// a mapped type are all read for the parameters and the return type they
    /// hold, and none of them is ever read as a property
    fn readMember(self: *Reader, start: usize, end: usize, object: ObjectKind) ReadError!void {
        const tokens = self.tokens;
        const member_end = trimEnd(tokens, start, end);
        if (start >= member_end) return;

        var cursor = start;
        var readonly = false;
        if (tokens[cursor].kind == .word and tokens[cursor].isWord("readonly")) {
            readonly = true;
            cursor += 1;
        }
        if (cursor >= member_end) return;

        if (isPunct(tokens[cursor], "[")) {
            const close = matchingCloser(tokens, cursor, member_end) orelse return;
            // a `:` inside the brackets is what makes `[key: string]: T` an
            // index signature, and `in` is what makes `[K in keyof T]: U` a
            // mapped type. neither is a property signature
            if (hasTopLevelPunct(tokens, cursor + 1, close, ":")) return;
            if (hasTopLevelWord(tokens, cursor + 1, close, "in")) return;
            cursor = close + 1;
        } else if (isPunct(tokens[cursor], "(") or isPunct(tokens[cursor], "<")) {
            try self.readSignature(cursor, member_end);
            return;
        } else if (tokens[cursor].kind == .word and tokens[cursor].isWord("new")) {
            try self.readSignature(cursor + 1, member_end);
            return;
        } else {
            cursor += 1;
        }

        if (cursor < member_end and isPunct(tokens[cursor], "?")) cursor += 1;
        if (cursor >= member_end) return;
        if (isPunct(tokens[cursor], ":")) {
            const type_start = cursor + 1;
            if (type_start >= member_end) return;
            try self.add(.{
                .position = .property_type,
                .type_start = type_start,
                .type_end = member_end,
                .report_start = start,
                .object = object,
                .optional = cursor > start and isPunct(tokens[cursor - 1], "?"),
                .readonly = readonly,
            });
            try self.readTypeExtent(type_start, member_end);
            return;
        }
        try self.readSignature(cursor, member_end);
    }

    /// `m(a: T): R` inside an object type, and the `new (...) => R` form. the
    /// member is not a property, so only its parameters and its return are read
    fn readSignature(self: *Reader, start: usize, end: usize) ReadError!void {
        const tokens = self.tokens;
        if (start >= end) return;
        const open = if (isPunct(tokens[start], "("))
            start
        else
            (findAtTop(tokens, start, end, "(") orelse return);
        const close = matchingCloser(tokens, open, end) orelse return;
        try self.readParameters(open + 1, close);
        if (close + 1 >= end or !isPunct(tokens[close + 1], ":")) return;
        const type_start = close + 2;
        if (type_start >= end) return;

        try self.add(.{
            .position = .return_type,
            .type_start = type_start,
            .type_end = end,
            .report_start = type_start,
        });
        try self.readTypeExtent(type_start, end);
    }

    /// the annotations nested in a type expression: a function type's parameter
    /// list and return, and every object type literal at any depth
    ///
    /// inside a type every balanced `{...}` is an object type, so one scan
    /// covers a union member, an intersection member, a generic argument and a
    /// member's own annotation without splitting on `|` and `&` first
    fn readTypeExtent(self: *Reader, start: usize, end: usize) ReadError!void {
        const tokens = self.tokens;
        var cursor = start;
        while (cursor < end and tokens[cursor].kind == .word and
            (tokens[cursor].isWord("readonly") or tokens[cursor].isWord("new")))
        {
            cursor += 1;
        }
        if (cursor >= end) return;

        if (isPunct(tokens[cursor], "(")) {
            const close = matchingCloser(tokens, cursor, end) orelse return;
            // `(a: T) => R` is a function type, so its parameter list and its
            // return are annotations. `(A | B)[]` is a parenthesised type whose
            // element is still worth reading
            if (close + 1 < end and isPunct(tokens[close + 1], "=>")) {
                try self.readParameters(cursor + 1, close);
                const type_start = close + 2;
                if (type_start < end) {
                    try self.add(.{
                        .position = .return_type,
                        .type_start = type_start,
                        .type_end = end,
                        .report_start = type_start,
                    });
                    try self.readTypeExtent(type_start, end);
                }
                return;
            }
            try self.readTypeExtent(cursor + 1, close);
            cursor = close + 1;
        }

        while (cursor < end) : (cursor += 1) {
            if (!isPunct(tokens[cursor], "{")) continue;
            const close = matchingCloser(tokens, cursor, end) orelse return;
            try self.readObjectLiteral(cursor, .type_literal);
            cursor = close;
        }
    }
};

fn annotationBefore(_: void, left: Annotation, right: Annotation) bool {
    if (left.type_start != right.type_start) return left.type_start < right.type_start;
    return left.report_start < right.report_start;
}

fn isPunct(token: Token, text: []const u8) bool {
    return token.kind == .punct and token.isPunct(text);
}

fn isOpener(text: []const u8) bool {
    if (text.len != 1) return false;
    return text[0] == '(' or text[0] == '[' or text[0] == '{';
}

fn isCloser(text: []const u8) bool {
    if (text.len != 1) return false;
    return text[0] == ')' or text[0] == ']' or text[0] == '}';
}

/// the first token that starts at or after `offset`, or the token count
fn tokenAtOrAfter(tokens: []const Token, offset: u32) usize {
    var low: usize = 0;
    var high: usize = tokens.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (tokens[middle].start < offset) low = middle + 1 else high = middle;
    }
    return low;
}

/// `end` without the `;` and `,` a declaration may leave behind it
fn trimEnd(tokens: []const Token, start: usize, end: usize) usize {
    var result = end;
    while (result > start and
        (isPunct(tokens[result - 1], ";") or isPunct(tokens[result - 1], ",")))
    {
        result -= 1;
    }
    return result;
}

/// the index of the closer matching the opener at `open`, searching to `limit`
fn matchingCloser(tokens: []const Token, open: usize, limit: usize) ?usize {
    if (open >= limit) return null;
    if (!isOpener(tokens[open].text)) return null;

    var depth: usize = 0;
    var i = open;
    while (i < limit) : (i += 1) {
        if (tokens[i].kind != .punct) continue;
        const text = tokens[i].text;
        if (isOpener(text)) {
            depth += 1;
            continue;
        }
        if (!isCloser(text)) continue;
        if (depth == 0) return null;
        depth -= 1;
        if (depth == 0) return i;
    }
    return null;
}

/// the index of the opener matching the closer at `close`, searching down to `limit`
fn matchingOpener(tokens: []const Token, close: usize, limit: usize) ?usize {
    var depth: usize = 0;
    var i = close + 1;
    while (i > limit) {
        i -= 1;
        if (tokens[i].kind != .punct) continue;
        const text = tokens[i].text;
        if (isCloser(text)) {
            depth += 1;
            continue;
        }
        if (!isOpener(text)) continue;
        depth -= 1;
        if (depth == 0) return i;
    }
    return null;
}

/// the token that closes the type arguments opened at `open`, whatever depth
fn matchingAngleClose(tokens: []const Token, open: usize, limit: usize) ?usize {
    var depth: usize = 0;
    var i = open;
    while (i < limit) : (i += 1) {
        const token = tokens[i];
        if (token.kind != .punct) continue;
        const text = token.text;
        if (text.len == 1 and text[0] == '<') {
            depth += 1;
            continue;
        }
        const closes = ts.angleClosers(text);
        if (closes == 0) continue;
        if (depth < closes) return null;
        depth -= closes;
        if (depth == 0) return i;
    }
    return null;
}

/// the next `,` or `;` that belongs to the region rather than to a nested
/// bracket pair or a type argument list
fn nextSeparator(tokens: []const Token, from: usize, to: usize) ?usize {
    var depth: usize = 0;
    var angle: usize = 0;
    var i = from;
    while (i < to) : (i += 1) {
        const token = tokens[i];
        if (token.kind != .punct) continue;
        const text = token.text;
        if (isOpener(text)) {
            depth += 1;
            continue;
        }
        if (isCloser(text)) {
            if (depth == 0) return null;
            depth -= 1;
            continue;
        }
        if (depth != 0) continue;
        if (text.len == 1 and text[0] == '<') {
            angle += 1;
            continue;
        }
        const closes = ts.angleClosers(text);
        if (closes > 0) {
            if (angle >= closes) angle -= closes;
            continue;
        }
        if (angle != 0) continue;
        if (std.mem.eql(u8, text, ",") or std.mem.eql(u8, text, ";")) return i;
    }
    return null;
}

/// the first `needle` in the region that no nested bracket pair and no type
/// argument list owns
fn findAtTop(tokens: []const Token, from: usize, to: usize, needle: []const u8) ?usize {
    var depth: usize = 0;
    var angle: usize = 0;
    var i = from;
    while (i < to) : (i += 1) {
        const token = tokens[i];
        if (token.kind != .punct) continue;
        const text = token.text;
        // the needle is tested before the brackets: a caller may be looking for
        // an opener itself (`interface X { ... }` looks for its body)
        if (depth == 0 and angle == 0 and std.mem.eql(u8, text, needle)) return i;
        if (isOpener(text)) {
            depth += 1;
            continue;
        }
        if (isCloser(text)) {
            if (depth == 0) return null;
            depth -= 1;
            continue;
        }
        if (depth != 0) continue;
        if (text.len == 1 and text[0] == '<') {
            angle += 1;
            continue;
        }
        const closes = ts.angleClosers(text);
        if (closes > 0) {
            if (angle >= closes) angle -= closes;
            continue;
        }
    }
    return null;
}

/// whether the region holds `needle` with no bracket pair around it. this is
/// what tells an index signature's `[key: string]` from a computed key's `[expr]`
fn hasTopLevelPunct(tokens: []const Token, from: usize, to: usize, needle: []const u8) bool {
    return findAtTop(tokens, from, to, needle) != null;
}

/// whether the region holds the word `needle` with no bracket pair around it,
/// which is what tells a mapped type's `[K in keyof T]` from a computed key
fn hasTopLevelWord(tokens: []const Token, from: usize, to: usize, needle: []const u8) bool {
    var depth: usize = 0;
    var i = from;
    while (i < to) : (i += 1) {
        const token = tokens[i];
        if (token.kind == .punct) {
            if (isOpener(token.text)) {
                depth += 1;
                continue;
            }
            if (isCloser(token.text)) {
                if (depth > 0) depth -= 1;
                continue;
            }
            continue;
        }
        if (depth == 0 and token.isWord(needle)) return true;
    }
    return false;
}

/// where a type ends inside a declaration, by the punctuation that cannot be
/// part of it: a body, an arrow, or the declaration that follows
fn endOfType(tokens: []const Token, from: usize, to: usize) usize {
    var depth: usize = 0;
    var angle: usize = 0;
    var i = from;
    while (i < to) : (i += 1) {
        const token = tokens[i];
        if (token.kind != .punct) continue;
        const text = token.text;
        if (isCloser(text)) {
            if (depth == 0) return i;
            depth -= 1;
            continue;
        }
        if (depth == 0 and isPunct(token, ";")) return i;
        if (depth == 0 and std.mem.eql(u8, text, "=>")) return i;
        // `(): Widget { ... }` ends the type at the body, while
        // `(): A | { b: 1 } { ... }` does not: a `{` after a complete type is
        // the body, and after a type operator it continues the type
        if (depth == 0 and isPunct(token, "{")) {
            const previous = if (i > from) tokens[i - 1] else token;
            if (!braceContinuesType(previous)) return i;
        }
        if (isOpener(text)) {
            depth += 1;
            continue;
        }
        if (depth != 0) continue;
        if (text.len == 1 and text[0] == '<') {
            angle += 1;
            continue;
        }
        const closes = ts.angleClosers(text);
        if (closes > 0) {
            if (angle >= closes) angle -= closes;
            continue;
        }
    }
    return to;
}

/// whether a `{` that follows `previous` is still part of the type
///
/// a type operator cannot end a type, so the brace has to be its operand. a
/// complete type can, so the brace is the body that follows it
fn braceContinuesType(previous: Token) bool {
    if (previous.kind == .word) {
        return previous.isWord("extends") or
            previous.isWord("keyof") or
            previous.isWord("readonly") or
            previous.isWord("new") or
            previous.isWord("typeof") or
            previous.isWord("in") or
            previous.isWord("is");
    }
    if (previous.kind != .punct) return false;
    const text = previous.text;
    if (text.len == 1) switch (text[0]) {
        '|', '&', ':', '=', '?', '(', '[', '{', '<', ',' => return true,
        else => {},
    };
    return std.mem.eql(u8, text, "=>") or std.mem.eql(u8, text, "&&") or std.mem.eql(u8, text, "||");
}

/// the `(` that opens a declaration's parameter list. a generic clause may hold
/// one of its own (`function f<T extends () => void>(x: T)`), so the scan is
/// angle-aware, and an arrow met first means the parameters are unparenthesised
/// and carry no annotation at all
fn findParameterList(tokens: []const Token, from: usize, to: usize) ?usize {
    var angle: usize = 0;
    var i = from;
    while (i < to) : (i += 1) {
        const token = tokens[i];
        if (token.kind != .punct) continue;
        const text = token.text;
        if (text.len == 1 and text[0] == '<') {
            angle += 1;
            continue;
        }
        const closes = ts.angleClosers(text);
        if (closes > 0) {
            if (angle >= closes) angle -= closes;
            continue;
        }
        if (std.mem.eql(u8, text, "=>")) return null;
        if (angle == 0 and std.mem.eql(u8, text, "(")) return i;
    }
    return null;
}

/// a string literal, including a template with no substitution, which the
/// detector's own string-literal test accepts
fn isStringLiteralExtent(tokens: []const Token, start: usize, end: usize) bool {
    if (start >= end) return false;
    if (tokens[start].kind == .string) return start + 1 == end;
    if (tokens[start].kind == .template) {
        return start + 2 == end and tokens[start + 1].kind == .template_end;
    }
    return false;
}

/// the annotations of `source`, one `line position optional readonly object` row
/// each, so a test pins a shape without naming a token index
fn annotationsOf(allocator: std.mem.Allocator, source: []const u8) ![]const []const u8 {
    var line: u32 = 1;
    const tokens = try ts.tokenize(allocator, source, &line);
    defer allocator.free(tokens);
    var module = try ts.parseTokens(allocator, source, tokens);
    defer module.deinit();
    const walk = try module.walkOrder(allocator);
    defer allocator.free(walk);

    var table = try analyze(allocator, tokens, &module, walk);
    defer table.deinit();

    var rows: std.ArrayList([]const u8) = .empty;
    errdefer rows.deinit(allocator);
    for (table.items) |item| {
        try rows.append(allocator, try std.fmt.allocPrint(allocator, "{d} {s} optional={} readonly={} {s}", .{
            tokens[item.report_start].line,
            @tagName(item.position),
            item.optional,
            item.readonly,
            if (item.object) |object| @tagName(object) else "-",
        }));
    }
    return rows.toOwnedSlice(allocator);
}

fn expectRows(
    allocator: std.mem.Allocator,
    source: []const u8,
    expected: []const []const u8,
) !void {
    const rows = try annotationsOf(allocator, source);
    defer {
        for (rows) |row| allocator.free(row);
        allocator.free(rows);
    }
    for (expected, 0..) |want, index| {
        if (index >= rows.len) {
            std.debug.print("missing annotation: {s}\n", .{want});
            return error.TestUnexpectedResult;
        }
        if (!std.mem.eql(u8, want, rows[index])) {
            std.debug.print("annotation {d}: want '{s}', got '{s}'\n", .{ index, want, rows[index] });
            return error.TestUnexpectedResult;
        }
    }
    if (rows.len != expected.len) {
        for (rows[expected.len..]) |extra| std.debug.print("unexpected annotation: {s}\n", .{extra});
        return error.TestUnexpectedResult;
    }
}

test "the four positions a literal union can sit in" {
    const allocator = std.testing.allocator;
    const source =
        \\type Direction = "up" | "down";
        \\let chosen: "left" | "right" = "left";
        \\const pick = (where: "home" | "away") => where;
        \\
    ;
    try expectRows(allocator, source, &.{
        "1 alias_type optional=false readonly=false -",
        "2 variable_type optional=false readonly=false -",
        "3 parameter_type optional=false readonly=false -",
    });
}

test "a union of literals is counted, a mixed union is not" {
    try expectUnionCount("\"a\" | \"b\"", 2);
    try expectUnionCount("\"a\" | \"b\" | \"c\"", 3);
    try expectUnionCount("\"a\"", 0);
    try expectUnionCount("\"a\" | string", 0);
    try expectUnionCount("1 | 2", 0);
    try expectUnionCount("(\"a\") | \"b\"", 0);
    try expectUnionCount("`a` | `b`", 2);
    try expectUnionCount("A | \"b\"", 0);
}

fn expectUnionCount(type_text: []const u8, expected: usize) !void {
    const allocator = std.testing.allocator;
    const source = try std.fmt.allocPrint(allocator, "type Union = {s};\n", .{type_text});
    defer allocator.free(source);
    var line: u32 = 1;
    const tokens = try ts.tokenize(allocator, source, &line);
    defer allocator.free(tokens);
    var module = try ts.parseTokens(allocator, source, tokens);
    defer module.deinit();
    const walk = try module.walkOrder(allocator);
    defer allocator.free(walk);
    var table = try analyze(allocator, tokens, &module, walk);
    defer table.deinit();

    try std.testing.expectEqual(@as(usize, 1), table.items.len);
    const unioned = table.items[0];
    try std.testing.expectEqual(expected, stringLiteralUnionCount(tokens, unioned.type_start, unioned.type_end));
}

test "a mutable array is an array type or an Array reference, and a readonly one is neither" {
    try expectMutableArray("T[]", true);
    try expectMutableArray("Array<T>", true);
    try expectMutableArray("Array", true);
    try expectMutableArray("readonly T[]", false);
    try expectMutableArray("ReadonlyArray<T>", false);
    try expectMutableArray("T[] | U", false);
    try expectMutableArray("Array<T> | U", false);
    try expectMutableArray("globalThis.Array<T>", false);
    try expectMutableArray("A.B[]", true);
}

fn expectMutableArray(type_text: []const u8, expected: bool) !void {
    const allocator = std.testing.allocator;
    const source = try std.fmt.allocPrint(allocator, "let value: {s};\n", .{type_text});
    defer allocator.free(source);
    var line: u32 = 1;
    const tokens = try ts.tokenize(allocator, source, &line);
    defer allocator.free(tokens);
    var module = try ts.parseTokens(allocator, source, tokens);
    defer module.deinit();
    const walk = try module.walkOrder(allocator);
    defer allocator.free(walk);
    var table = try analyze(allocator, tokens, &module, walk);
    defer table.deinit();

    try std.testing.expectEqual(@as(usize, 1), table.items.len);
    const annotation = table.items[0];
    try std.testing.expectEqual(expected, isMutableArrayType(tokens, annotation.type_start, annotation.type_end));
}

test "an optional property is a member, an optional parameter is not" {
    const allocator = std.testing.allocator;
    const source =
        \\interface Bridge {
        \\  readonly t?: string;
        \\  d: unknown;
        \\}
        \\type Inline = { a?: number; b: string };
        \\function send(t?: string): void {}
        \\
    ;
    try expectRows(allocator, source, &.{
        "2 property_type optional=true readonly=true interface_body",
        "3 property_type optional=false readonly=false interface_body",
        "5 alias_type optional=false readonly=false -",
        "5 property_type optional=true readonly=false type_literal",
        "5 property_type optional=false readonly=false type_literal",
        "6 parameter_type optional=false readonly=false -",
        "6 return_type optional=false readonly=false -",
    });
}

test "a nested object type is a type literal even inside an interface" {
    const allocator = std.testing.allocator;
    const source =
        \\interface Outer {
        \\  inner: {
        \\    deep: number;
        \\  };
        \\}
        \\
    ;
    try expectRows(allocator, source, &.{
        "2 property_type optional=false readonly=false interface_body",
        "3 property_type optional=false readonly=false type_literal",
    });
}

test "an index signature, a method, a mapped type and a call signature are not properties" {
    const allocator = std.testing.allocator;
    const source =
        \\type Shape = {
        \\  [key: string]: number;
        \\  run(step: number): boolean;
        \\  (input: string): void;
        \\  readonly [index: number]: string;
        \\};
        \\
    ;
    try expectRows(allocator, source, &.{
        "1 alias_type optional=false readonly=false -",
        "3 parameter_type optional=false readonly=false -",
        "3 return_type optional=false readonly=false -",
        "4 parameter_type optional=false readonly=false -",
        "4 return_type optional=false readonly=false -",
    });
}

test "a class field is left alone and a class method is not" {
    const allocator = std.testing.allocator;
    const source =
        \\class Service {
        \\  private readonly name: string = "x";
        \\  run(step: number): boolean {
        \\    return step > 0;
        \\  }
        \\}
        \\
    ;
    try expectRows(allocator, source, &.{
        "3 parameter_type optional=false readonly=false -",
        "3 return_type optional=false readonly=false -",
    });
}

test "a function type's parameter list and return are annotations" {
    const allocator = std.testing.allocator;
    const source =
        \\type Mapper = (value: string) => number;
        \\
    ;
    try expectRows(allocator, source, &.{
        "1 alias_type optional=false readonly=false -",
        "1 parameter_type optional=false readonly=false -",
        "1 return_type optional=false readonly=false -",
    });
}

test "a destructured binding and a default value bound the annotation" {
    const allocator = std.testing.allocator;
    const source =
        \\const { userId } = record;
        \\const carried: string = pick();
        \\function send({ body }: Request, delay: number = 5) {}
        \\
    ;
    try expectRows(allocator, source, &.{
        "2 variable_type optional=false readonly=false -",
        "3 parameter_type optional=false readonly=false -",
        "3 parameter_type optional=false readonly=false -",
    });
}

test "a return type's own object literal is read, and its body is not" {
    const allocator = std.testing.allocator;
    const source =
        \\function build(): { ready: boolean } {
        \\  return { ready: true };
        \\}
        \\
    ;
    try expectRows(allocator, source, &.{
        "1 return_type optional=false readonly=false -",
        "1 property_type optional=false readonly=false type_literal",
    });
}
