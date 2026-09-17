const std = @import("std");
const ts = @import("ts.zig");

const Token = ts.Token;

/// the number of TypeScript nodes a type extent stands for
///
/// the front-end models a type only as an extent: `skipType` walks one and records
/// nothing, so every annotation a rule reads is a hole in the tree. the node-count gate the
/// expression-family rules test a site against counts TypeScript descendants, and a hole is
/// exactly where such a count goes wrong: a type inside a call argument is a subtree the
/// tree does not carry, the gate's floor sits at seven, and one node either way moves a site
/// in or out
///
/// so the extent is read back here, by a descent over the type grammar. `typemodel.zig` is
/// the closest precedent and is deliberately not reused: its readers answer the questions
/// the type rules ask, and every bracket- and angle-aware scanner they need is private to
/// it. inside a known extent the ambiguity those scanners exist to resolve (`<` as a type
/// argument list rather than a comparison, `(` as a parameter list rather than a grouping)
/// cannot arise, so the descent takes one thing from the front-end: `ts.angleClosers`, to
/// split `>>` and `>>>` across nested type-argument lists
///
/// every count includes the node the extent begins with, because that node is one of the
/// things TypeScript reports and the tree does not build. a caller that hands over a whole
/// type therefore adds the count as it stands, and a caller that hands over the contents of
/// a `<...>` list adds the sum of the items, since no node wraps the list
///
/// the module reads `ts.Token` and, for the one question a token list cannot answer on its
/// own, `ts.angleClosers`. its tests also build their tokens with `ts.tokenize`, as
/// `typemodel.zig`'s tests do: a hand-built token list would test the fixture rather than the
/// descent
///
/// the source travels with the tokens because the lexer keeps a template literal's text out
/// of the token stream: the `${` that opens each substitution of a template literal type is
/// in the source between two tokens and nowhere else
///
/// ponytail: four shapes are read as a recorded approximation rather than modelled, and each
/// was measured over the corpus rather than assumed absent. a parameter's default value
/// (`(a = 1) => T`) counts one node whatever it is, which is exact for a literal and short
/// for a call: no parameter default sits inside a function type in the corpus. a computed
/// member name that is not a name (`{ [foo()]: T }`) counts one node: the corpus's type
/// literals, classes and interfaces declare 1410 members and compute none of their names.
/// import attributes (`import("x", { with: {} }).T`) are not read: no type in the corpus
/// holds one. and a member shape the descent does not know (`{ abstract new () => T }`) is
/// read as the member scan sees it rather than as typescript reads it, which is one node over
/// for that one: a differential over the 2073 distinct type texts the corpus holds finds none
/// of the four
pub fn subtreeSize(source: []const u8, tokens: []const Token, start: usize, end: usize) u32 {
    var cursor = start;
    return parseType(source, tokens, &cursor, end);
}

/// a `<...>` type-argument list, for a call or a construction whose callee the tree already
/// holds. `open` is the `<` a caller has seen, and the `>` is found here, because the list
/// ends at a `>>` a caller would have to split for itself
pub fn typeArgumentCount(source: []const u8, tokens: []const Token, open: usize, limit: usize) u32 {
    const close = matchingAngle(tokens, open, limit) orelse return 0;
    return typeList(source, tokens, open + 1, close + 1);
}

/// a `<...>` type-parameter list on a callable. the extent a caller walked does not bound
/// it: `skipType` runs past the `>` into the parameter list that follows, which is why this
/// takes the `<` and a limit rather than an extent
pub fn typeParameterCount(source: []const u8, tokens: []const Token, open: usize, limit: usize) u32 {
    const close = matchingAngle(tokens, open, limit) orelse return 0;
    return typeParameterList(source, tokens, open + 1, close + 1);
}

/// an `implements` clause: one `HeritageClause` node over one `ExpressionWithTypeArguments`
/// per type, each of which stands for the type it wraps. every type in such a clause is a
/// name and its type arguments, and an `ExpressionWithTypeArguments` over one is the same
/// shape as the reference itself
pub fn heritageCount(source: []const u8, tokens: []const Token, start: usize, end: usize) u32 {
    return SELF + typeList(source, tokens, start, end);
}

/// one node standing for itself alone: a keyword type, a name, a parameter, a member
const SELF: u32 = 1;

/// `null`, `true`, `false` and a string or number literal type are a `LiteralType` node
/// over the token that spells it
const LITERAL_TYPE_NODES: u32 = 2;

/// `-1` is that pair under a `PrefixUnaryExpression`
const NEGATIVE_LITERAL_TYPE_NODES: u32 = 3;

/// the words that are a type node of their own with nothing under them
const keyword_types = [_][]const u8{
    "any",    "unknown", "never",   "void",   "undefined", "object",
    "string", "number",  "boolean", "symbol", "bigint",    "intrinsic",
    "this",
};

/// the words that take a type operand: `keyof T`, `readonly T[]`, `unique symbol`
const type_operators = [_][]const u8{ "keyof", "readonly", "unique" };

/// the words a type parameter may carry in front of its name, each a node of its own
const type_parameter_modifiers = [_][]const u8{ "in", "out", "const" };

/// the two bytes a substitution of a template literal type opens with, `${`
const SUBSTITUTION_MARKER_LEN: usize = 2;

// ------------------------------------------------------------------- the descent

/// the loosest level of the type grammar: a conditional wraps a union, and a union wraps an
/// intersection
fn parseType(source: []const u8, tokens: []const Token, cursor: *usize, end: usize) u32 {
    const checked = parseUnion(source, tokens, cursor, end);
    if (cursor.* >= end or !tokens[cursor.*].isWord("extends")) return checked;

    // a top-level `extends` has no other reading in a type: a constraint is written inside
    // the `<...>` its own parameter list opened, which this extent has already passed
    cursor.* += 1;
    const extended = parseUnion(source, tokens, cursor, end);
    if (cursor.* >= end or !tokens[cursor.*].isPunct("?")) return SELF + checked + extended;

    // both branches read a whole type, because either may hold a conditional of its own:
    // `A extends B ? C extends D ? E : F : G` puts one in the true branch, and the `:`
    // that is left over is the outer one
    cursor.* += 1;
    const when_true = parseType(source, tokens, cursor, end);
    if (cursor.* >= end or !tokens[cursor.*].isPunct(":")) return SELF + checked + extended + when_true;

    cursor.* += 1;
    const when_false = parseType(source, tokens, cursor, end);
    return SELF + checked + extended + when_true + when_false;
}

/// a `|` chain. one member is not a `UnionType`, so the node is counted from the second
/// member on
fn parseUnion(source: []const u8, tokens: []const Token, cursor: *usize, end: usize) u32 {
    // a union may open with its own `|`, which is how one broken over several lines is
    // written, and a list that opens with one is a `UnionType` even when a single member
    // follows it (measured: `| B` is a union, `B` is not)
    const opened = skipOperator(tokens, cursor, end, "|");
    var total = parseIntersection(source, tokens, cursor, end);
    var members: u32 = 1;
    while (cursor.* < end and tokens[cursor.*].isPunct("|")) {
        cursor.* += 1;
        total += parseIntersection(source, tokens, cursor, end);
        members += 1;
    }
    return if (members == 1 and !opened) total else total + SELF;
}

/// an `&` chain, which binds tighter than a `|`: `A | B & C` is a union of `A` and the
/// intersection of `B` and `C`
fn parseIntersection(source: []const u8, tokens: []const Token, cursor: *usize, end: usize) u32 {
    const opened = skipOperator(tokens, cursor, end, "&");
    var total = parsePostfix(source, tokens, cursor, end);
    var members: u32 = 1;
    while (cursor.* < end and tokens[cursor.*].isPunct("&")) {
        cursor.* += 1;
        total += parsePostfix(source, tokens, cursor, end);
        members += 1;
    }
    return if (members == 1 and !opened) total else total + SELF;
}

/// skip a run of one operator token at the cursor, reporting whether any was there
fn skipOperator(tokens: []const Token, cursor: *usize, end: usize, operator: []const u8) bool {
    var opened = false;
    while (cursor.* < end and tokens[cursor.*].isPunct(operator)) {
        opened = true;
        cursor.* += 1;
    }
    return opened;
}

/// `T[]`, `T[K]`, and any chain of them
fn parsePostfix(source: []const u8, tokens: []const Token, cursor: *usize, end: usize) u32 {
    var total = parsePrimary(source, tokens, cursor, end);
    while (cursor.* < end and tokens[cursor.*].isPunct("[")) {
        // a `[` continues a type only when nothing precedes it on its own line, which is
        // what tells a member that starts a line from an index into the type above it:
        // `{ value: string` newline `[key: string]: T }` is two members. the rule is
        // typescript's own, and the same on both sides of it: `Foo` newline `[T]` is the
        // reference alone to it as to this, and `Foo[` newline `T]` indexes (measured)
        if (cursor.* > 0 and tokens[cursor.*].line != tokens[cursor.* - 1].line) break;
        if (cursor.* + 1 < end and tokens[cursor.* + 1].isPunct("]")) {
            // `T[]` is an `ArrayType` above its element
            cursor.* += 2;
            total += SELF;
            continue;
        }
        // `T[K]` is an `IndexedAccessType`, whose object and index are both types
        const close = matching(tokens, cursor.*, end) orelse break;
        total += SELF + subtreeSize(source, tokens, cursor.* + 1, close);
        cursor.* = close + 1;
    }
    return total;
}

fn parsePrimary(source: []const u8, tokens: []const Token, cursor: *usize, end: usize) u32 {
    if (cursor.* >= end) return 0;
    const token = tokens[cursor.*];

    if (token.kind == .word) return parseWord(source, tokens, cursor, end, token);
    if (token.kind == .template) return parseTemplateType(source, tokens, cursor, end);
    if (token.kind == .string or token.kind == .number) {
        // a literal type is a `LiteralType` over the token that spells it
        cursor.* += 1;
        return LITERAL_TYPE_NODES;
    }
    if (token.isPunct("-")) {
        // a negative literal type wraps the literal
        cursor.* += 1;
        if (cursor.* < end and tokens[cursor.*].kind == .number) cursor.* += 1;
        return NEGATIVE_LITERAL_TYPE_NODES;
    }
    // a function type may open with its own type-parameter list: `<T>(a: T) => T`
    if (token.isPunct("(") or token.isPunct("<")) return parseParenOrFunction(source, tokens, cursor, end);
    if (token.isPunct("{")) return parseObjectOrMapped(source, tokens, cursor, end);
    if (token.isPunct("[")) return parseTupleType(source, tokens, cursor, end);

    // a shape the descent does not model still stands for the node it begins, which is the
    // one reading that keeps a count from drifting without saying so
    cursor.* += 1;
    return SELF;
}

/// a type that opens with a word: a keyword type, a literal, an operator over an operand, a
/// query, a name, or one of the words that introduce a shape of their own
fn parseWord(source: []const u8, tokens: []const Token, cursor: *usize, end: usize, token: Token) u32 {
    if (contains(&keyword_types, token.text)) {
        cursor.* += 1;
        return SELF;
    }
    if (token.isWord("null") or token.isWord("true") or token.isWord("false")) {
        cursor.* += 1;
        return LITERAL_TYPE_NODES;
    }
    if (token.isWord("asserts")) {
        cursor.* += 1;
        // `asserts value` and `asserts value is T` carry the keyword itself
        var total = SELF + SELF;
        total += parseName(tokens, cursor, end);
        if (cursor.* < end and tokens[cursor.*].isWord("is")) {
            cursor.* += 1;
            total += parseType(source, tokens, cursor, end);
        }
        return total;
    }
    if (contains(&type_operators, token.text)) {
        cursor.* += 1;
        return SELF + parsePostfix(source, tokens, cursor, end);
    }
    if (token.isWord("typeof")) return parseTypeQuery(source, tokens, cursor, end);
    if (token.isWord("infer")) return parseInferType(source, tokens, cursor, end);
    if (token.isWord("import")) return parseImportType(source, tokens, cursor, end);
    if (token.isWord("new") or token.isWord("abstract")) return parseConstructorType(source, tokens, cursor, end);

    // a name, qualified and possibly instantiated. `value is T` is a `TypePredicate` over
    // the name, which is a node of its own
    const total = parseName(tokens, cursor, end);
    if (cursor.* < end and tokens[cursor.*].isWord("is")) {
        cursor.* += 1;
        return SELF + total + parseType(source, tokens, cursor, end);
    }
    return SELF + total + parseTypeArguments(source, tokens, cursor, end);
}

/// a name: one node per identifier and one per `.` between them, because `A.B` is a
/// `QualifiedName` node above its two identifiers
fn parseName(tokens: []const Token, cursor: *usize, end: usize) u32 {
    var total: u32 = 0;
    while (cursor.* < end and tokens[cursor.*].kind == .word) {
        total += SELF;
        cursor.* += 1;
        if (cursor.* + 1 < end and tokens[cursor.*].isPunct(".") and tokens[cursor.* + 1].kind == .word) {
            total += SELF;
            cursor.* += 1;
            continue;
        }
        break;
    }
    return total;
}

/// `typeof x` and `typeof x.y`
///
/// `typeof import("x").T` is not one of these: typescript writes it as the `import` type
/// with `isTypeOf` set, so it is that node and not a query over it (measured: the `typeof`
/// adds no node there)
fn parseTypeQuery(source: []const u8, tokens: []const Token, cursor: *usize, end: usize) u32 {
    cursor.* += 1;
    if (cursor.* < end and tokens[cursor.*].isWord("import")) return parseImportType(source, tokens, cursor, end);
    return SELF + parseName(tokens, cursor, end) + parseTypeArguments(source, tokens, cursor, end);
}

/// `infer T`, and the `infer T extends U` form, whose `TypeParameter` holds the name and
/// the constraint
fn parseInferType(source: []const u8, tokens: []const Token, cursor: *usize, end: usize) u32 {
    cursor.* += 1;
    return SELF + parseTypeParameter(source, tokens, cursor, end);
}

/// `import("x")`, `import("x").T` and the `typeof import("x").T` form. the argument is a
/// `LiteralType`, the qualifier a name
///
/// ponytail: a second argument, an import attribute clause, is not read and stands for
/// nothing here (measured: no type extent in the corpus holds one)
fn parseImportType(source: []const u8, tokens: []const Token, cursor: *usize, end: usize) u32 {
    cursor.* += 1;
    var total: u32 = SELF;
    const close = matching(tokens, cursor.*, end) orelse {
        cursor.* += 1;
        return total;
    };
    if (cursor.* + 1 < close) {
        var argument = cursor.* + 1;
        total += parseType(source, tokens, &argument, close);
    }
    cursor.* = close + 1;
    if (cursor.* + 1 < end and tokens[cursor.*].isPunct(".") and tokens[cursor.* + 1].kind == .word) {
        cursor.* += 1;
        total += parseName(tokens, cursor, end);
    }
    return total + parseTypeArguments(source, tokens, cursor, end);
}

/// `new (a: T) => R`, and the `abstract new` form, whose modifier is a node of its own
fn parseConstructorType(source: []const u8, tokens: []const Token, cursor: *usize, end: usize) u32 {
    var total: u32 = SELF;
    if (tokens[cursor.*].isWord("abstract")) {
        total += SELF;
        cursor.* += 1;
    }
    if (cursor.* < end and tokens[cursor.*].isWord("new")) cursor.* += 1;
    total += parseTypeParameters(source, tokens, cursor, end);
    total += parseParameters(source, tokens, cursor, end);
    if (cursor.* < end and tokens[cursor.*].isPunct("=>")) {
        cursor.* += 1;
        total += parseType(source, tokens, cursor, end);
    }
    return total;
}

/// `(a: T) => R`, `()`, `(T)`, and either of them behind a `<...>` clause
fn parseParenOrFunction(source: []const u8, tokens: []const Token, cursor: *usize, end: usize) u32 {
    var total: u32 = 0;
    if (tokens[cursor.*].isPunct("<")) {
        total += parseTypeParameters(source, tokens, cursor, end);
        if (cursor.* >= end or !tokens[cursor.*].isPunct("(")) return SELF + total;
    }

    const open = cursor.*;
    const close = matching(tokens, open, end) orelse {
        cursor.* += 1;
        return SELF + total;
    };
    if (close + 1 < end and tokens[close + 1].isPunct("=>")) {
        // a function type: the parameters, then the return
        cursor.* = close + 2;
        return SELF + total + parseParameterList(source, tokens, open + 1, close) + parseType(source, tokens, cursor, end);
    }
    // a parenthesised type, whose parentheses are a node of their own
    cursor.* = close + 1;
    return SELF + total + subtreeSize(source, tokens, open + 1, close);
}

/// a `<...>` clause, read from the `<` when the cursor is on one
fn parseTypeParameters(source: []const u8, tokens: []const Token, cursor: *usize, end: usize) u32 {
    if (cursor.* >= end or !tokens[cursor.*].isPunct("<")) return 0;
    const close = matchingAngle(tokens, cursor.*, end) orelse return 0;
    const total = typeParameterList(source, tokens, cursor.* + 1, close + 1);
    cursor.* = close + 1;
    return total;
}

/// a parameter list, read from the `(` when the cursor is on one
fn parseParameters(source: []const u8, tokens: []const Token, cursor: *usize, end: usize) u32 {
    if (cursor.* >= end or !tokens[cursor.*].isPunct("(")) return 0;
    const close = matching(tokens, cursor.*, end) orelse return 0;
    const total = parseParameterList(source, tokens, cursor.* + 1, close);
    cursor.* = close + 1;
    return total;
}

/// a type reference's type arguments, read from the `<` when the cursor is on one. no node
/// wraps the list, so it stands for the sum of its arguments
fn parseTypeArguments(source: []const u8, tokens: []const Token, cursor: *usize, end: usize) u32 {
    if (cursor.* >= end or !tokens[cursor.*].isPunct("<")) return 0;
    const close = matchingAngle(tokens, cursor.*, end) orelse return 0;
    const total = typeList(source, tokens, cursor.* + 1, close + 1);
    cursor.* = close + 1;
    return total;
}

/// a `: T` return annotation, which is the type alone
fn parseReturnType(source: []const u8, tokens: []const Token, cursor: *usize, end: usize) u32 {
    if (cursor.* >= end or !tokens[cursor.*].isPunct(":")) return 0;
    cursor.* += 1;
    return parseType(source, tokens, cursor, end);
}

/// a `TypeParameter` node: the modifiers in front of it, its name, its constraint and its
/// default
fn parseTypeParameter(source: []const u8, tokens: []const Token, cursor: *usize, end: usize) u32 {
    var total: u32 = SELF;
    while (cursor.* < end and tokens[cursor.*].kind == .word and contains(&type_parameter_modifiers, tokens[cursor.*].text)) {
        total += SELF;
        cursor.* += 1;
    }
    total += parseName(tokens, cursor, end);
    if (cursor.* < end and tokens[cursor.*].isWord("extends")) {
        cursor.* += 1;
        total += parseType(source, tokens, cursor, end);
    }
    if (cursor.* < end and tokens[cursor.*].isPunct("=")) {
        cursor.* += 1;
        total += parseType(source, tokens, cursor, end);
    }
    return total;
}

/// the parameters between a `<...>` list's brackets, one `TypeParameter` each
fn typeParameterList(source: []const u8, tokens: []const Token, start: usize, end: usize) u32 {
    var cursor = start;
    var total: u32 = 0;
    while (cursor < end) {
        if (ts.angleClosers(tokens[cursor].text) > 0) break;
        if (tokens[cursor].isPunct(",")) {
            cursor += 1;
            continue;
        }
        const before = cursor;
        total += parseTypeParameter(source, tokens, &cursor, end);
        if (cursor == before) cursor += 1;
    }
    return total;
}

/// `name: T`, `name?: T`, `...rest: T[]`, `readonly name: T`, `name = value`, and the
/// destructured forms. the dots, the `?` and the `readonly` are one node each
fn parseParameter(source: []const u8, tokens: []const Token, cursor: *usize, end: usize) u32 {
    var total: u32 = SELF;
    if (cursor.* < end and tokens[cursor.*].isWord("readonly")) {
        total += SELF;
        cursor.* += 1;
    }
    if (cursor.* < end and tokens[cursor.*].isPunct("...")) {
        total += SELF;
        cursor.* += 1;
    }
    total += parseBindingName(source, tokens, cursor, end);
    if (cursor.* < end and tokens[cursor.*].isPunct("?")) {
        total += SELF;
        cursor.* += 1;
    }
    if (cursor.* < end and tokens[cursor.*].isPunct(":")) {
        cursor.* += 1;
        total += parseType(source, tokens, cursor, end);
    }
    if (cursor.* < end and tokens[cursor.*].isPunct("=")) {
        // ponytail: a default value counts one node whatever it is, which is exact for a
        // literal and short for a call (measured: no parameter default sits inside a
        // function type in the corpus)
        cursor.* += 1;
        total += SELF;
        while (cursor.* < end and !tokens[cursor.*].isPunct(",")) cursor.* += 1;
    }
    return total;
}

/// the parameters between a parameter list's brackets
fn parseParameterList(source: []const u8, tokens: []const Token, start: usize, end: usize) u32 {
    var cursor = start;
    var total: u32 = 0;
    while (cursor < end) {
        if (tokens[cursor].isPunct(",")) {
            cursor += 1;
            continue;
        }
        const before = cursor;
        total += parseParameter(source, tokens, &cursor, end);
        if (cursor == before) cursor += 1;
    }
    return total;
}

/// a parameter's name: an identifier, or a binding pattern, whose elements are
/// `BindingElement` nodes over the names they bind
fn parseBindingName(source: []const u8, tokens: []const Token, cursor: *usize, end: usize) u32 {
    if (cursor.* >= end) return 0;
    if (tokens[cursor.*].kind == .word) {
        cursor.* += 1;
        return SELF;
    }
    if (tokens[cursor.*].isPunct("{") or tokens[cursor.*].isPunct("[")) {
        const close = matching(tokens, cursor.*, end) orelse return 0;
        const total = SELF + parseBindingElements(source, tokens, cursor.* + 1, close);
        cursor.* = close + 1;
        return total;
    }
    return 0;
}

/// the elements between a binding pattern's brackets
fn parseBindingElements(source: []const u8, tokens: []const Token, start: usize, end: usize) u32 {
    var cursor = start;
    var total: u32 = 0;
    while (cursor < end) {
        if (tokens[cursor].isPunct(",")) {
            cursor += 1;
            continue;
        }
        const before = cursor;
        total += SELF;
        if (cursor < end and tokens[cursor].isPunct("...")) {
            total += SELF;
            cursor += 1;
        }
        total += parseBindingName(source, tokens, &cursor, end);
        if (cursor < end and tokens[cursor].isPunct(":")) {
            // `{ a: b }` names the property and the binding
            cursor += 1;
            total += parseBindingName(source, tokens, &cursor, end);
        }
        if (cursor < end and tokens[cursor].isPunct("=")) {
            cursor += 1;
            total += SELF;
            while (cursor < end and !tokens[cursor].isPunct(",")) cursor += 1;
        }
        if (cursor == before) cursor += 1;
    }
    return total;
}

/// `{ a: T }` and `{ [K in T]: U }`, which differ in what the brackets hold: `in` inside
/// them makes the whole literal one `MappedType`, and the modifier in front of it is a node
/// of its own
fn parseObjectOrMapped(source: []const u8, tokens: []const Token, cursor: *usize, end: usize) u32 {
    const open = cursor.*;
    const close = matching(tokens, open, end) orelse {
        cursor.* += 1;
        return SELF;
    };

    const mapped = mappedBrackets(tokens, open + 1, close);
    if (mapped) |brackets| return parseMappedType(source, tokens, open, brackets, close);

    cursor.* = close + 1;
    return SELF + parseMembers(source, tokens, open + 1, close);
}

/// the brackets of a mapped type's `[K in T]`, or null when the literal opens with anything
/// else. the modifiers in front of the brackets are skipped, since `readonly [K in T]` and
/// `-readonly [K in T]` are mapped types too
fn mappedBrackets(tokens: []const Token, start: usize, end: usize) ?usize {
    var cursor = start;
    if (cursor < end and (tokens[cursor].isPunct("+") or tokens[cursor].isPunct("-"))) cursor += 1;
    if (cursor < end and tokens[cursor].isWord("readonly")) cursor += 1;
    if (cursor >= end or !tokens[cursor].isPunct("[")) return null;

    const brackets = matching(tokens, cursor, end) orelse return null;
    if (!hasTopLevelWord(tokens, cursor + 1, brackets, "in")) return null;
    return brackets;
}

/// `{ [K in T]: U }` with its modifier, its optional `as` name and its optional `?`. each
/// modifier is one node, and the `in` clause is a `TypeParameter` over the name and the
/// constraint
fn parseMappedType(source: []const u8, tokens: []const Token, open: usize, brackets: usize, close: usize) u32 {
    var total: u32 = SELF;
    var cursor = open + 1;

    // `readonly`, `+readonly` and `-readonly` are one node each, and the `+` or `-` takes
    // the `readonly` with it
    if (cursor < close and (tokens[cursor].isPunct("+") or tokens[cursor].isPunct("-"))) {
        total += SELF;
        cursor += 1;
        if (cursor < close and tokens[cursor].isWord("readonly")) cursor += 1;
    } else if (cursor < close and tokens[cursor].isWord("readonly")) {
        total += SELF;
        cursor += 1;
    }

    // `[K in T]`, and the `as X` a name type adds to it
    if (cursor < brackets) {
        var parameter = cursor + 1;
        var inner: u32 = SELF + parseName(tokens, &parameter, brackets);
        if (parameter < brackets and tokens[parameter].isWord("in")) {
            parameter += 1;
            inner += parseType(source, tokens, &parameter, brackets);
        }
        if (parameter < brackets and tokens[parameter].isWord("as")) {
            parameter += 1;
            inner += parseType(source, tokens, &parameter, brackets);
        }
        total += inner;
    }
    cursor = brackets + 1;

    // the optionality modifier, which is one node however it is written
    if (cursor < close and tokens[cursor].isPunct("?")) {
        total += SELF;
        cursor += 1;
    } else if (cursor < close and (tokens[cursor].isPunct("+") or tokens[cursor].isPunct("-"))) {
        total += SELF;
        cursor += 1;
        if (cursor < close and tokens[cursor].isPunct("?")) cursor += 1;
    }

    if (cursor < close and tokens[cursor].isPunct(":")) {
        cursor += 1;
        total += parseType(source, tokens, &cursor, close);
    }
    return total;
}

/// the members between an object type's braces
fn parseMembers(source: []const u8, tokens: []const Token, start: usize, end: usize) u32 {
    var cursor = start;
    var total: u32 = 0;
    while (cursor < end) {
        if (tokens[cursor].isPunct(";") or tokens[cursor].isPunct(",")) {
            cursor += 1;
            continue;
        }
        const before = cursor;
        total += parseMember(source, tokens, &cursor, end);
        if (cursor == before) cursor += 1;
    }
    return total;
}

/// one member of an object type: a property, a method, an index signature, a call
/// signature, a construct signature or an accessor
fn parseMember(source: []const u8, tokens: []const Token, cursor: *usize, end: usize) u32 {
    var total: u32 = 0;
    // `readonly` is the one modifier a member carries, and it is a node of its own
    while (cursor.* < end and tokens[cursor.*].isWord("readonly")) {
        total += SELF;
        cursor.* += 1;
    }
    if (cursor.* >= end) return total;

    if (tokens[cursor.*].isPunct("(") or tokens[cursor.*].isPunct("<")) return total + parseSignature(source, tokens, cursor, end);
    if (tokens[cursor.*].isWord("new") and cursor.* + 1 < end and
        (tokens[cursor.* + 1].isPunct("(") or tokens[cursor.* + 1].isPunct("<")))
    {
        return total + parseSignature(source, tokens, cursor, end);
    }
    // `get a(): T` and `set a(v: T)`, whose keyword and name are one node each
    if ((tokens[cursor.*].isWord("get") or tokens[cursor.*].isWord("set")) and cursor.* + 1 < end and
        tokens[cursor.* + 1].kind == .word)
    {
        cursor.* += 2;
        total += SELF + SELF;
        return total + parseParameters(source, tokens, cursor, end) + parseReturnType(source, tokens, cursor, end);
    }

    // the name the member is declared under
    total += SELF;
    if (tokens[cursor.*].isPunct("[")) {
        const close = matching(tokens, cursor.*, end) orelse {
            cursor.* += 1;
            return total;
        };
        if (hasTopLevelPunct(tokens, cursor.* + 1, close, ":")) {
            // an index signature: its parameter holds the key's name and the key's type
            total += indexParameter(tokens, cursor.* + 1, close);
            cursor.* = close + 1;
            return total + parseReturnType(source, tokens, cursor, end);
        }
        // otherwise the brackets hold a computed name, which is a node over what it
        // computes
        total += SELF + computedName(tokens, cursor.* + 1, close);
        cursor.* = close + 1;
    } else if (tokens[cursor.*].kind == .word or tokens[cursor.*].kind == .string or tokens[cursor.*].kind == .number) {
        total += SELF;
        cursor.* += 1;
    } else {
        cursor.* += 1;
        return total;
    }

    if (cursor.* < end and tokens[cursor.*].isPunct("?")) {
        total += SELF;
        cursor.* += 1;
    }
    total += parseTypeParameters(source, tokens, cursor, end);
    total += parseParameters(source, tokens, cursor, end);
    return total + parseReturnType(source, tokens, cursor, end);
}

/// the parameter an index signature declares, which holds the key's name and its type
fn indexParameter(tokens: []const Token, start: usize, end: usize) u32 {
    var total: u32 = SELF;
    var cursor = start;
    total += parseName(tokens, &cursor, end);
    if (cursor < end and tokens[cursor].isPunct(":")) {
        cursor += 1;
        total += parseName(tokens, &cursor, end);
    }
    return total;
}

/// what a computed member name computes: a name stands for itself, and anything else is one
/// node (measured: no computed member name in the corpus is anything else)
fn computedName(tokens: []const Token, start: usize, end: usize) u32 {
    if (start >= end) return 0;
    if (tokens[start].kind == .word) {
        var cursor = start;
        return parseName(tokens, &cursor, end);
    }
    return SELF;
}

/// a member's signature: the optional `new`, the optional type parameters, the parameters
/// and the return type
fn parseSignature(source: []const u8, tokens: []const Token, cursor: *usize, end: usize) u32 {
    var total: u32 = SELF;
    if (cursor.* < end and tokens[cursor.*].isWord("new")) cursor.* += 1;
    total += parseTypeParameters(source, tokens, cursor, end);
    total += parseParameters(source, tokens, cursor, end);
    return total + parseReturnType(source, tokens, cursor, end);
}

/// `[A, B]`, `[]`, `[a: A]`, `[A?]` and `[...A[]]`
fn parseTupleType(source: []const u8, tokens: []const Token, cursor: *usize, end: usize) u32 {
    const open = cursor.*;
    const close = matching(tokens, open, end) orelse {
        cursor.* += 1;
        return SELF;
    };
    cursor.* = close + 1;
    return SELF + parseTupleElements(source, tokens, open + 1, close);
}

/// the elements between a tuple's brackets
fn parseTupleElements(source: []const u8, tokens: []const Token, start: usize, end: usize) u32 {
    var cursor = start;
    var total: u32 = 0;
    while (cursor < end) {
        if (tokens[cursor].isPunct(",")) {
            cursor += 1;
            continue;
        }
        const before = cursor;
        total += parseTupleElement(source, tokens, &cursor, end);
        if (cursor == before) cursor += 1;
    }
    return total;
}

/// one tuple element: a named member (`a: A`, `a?: A`, `...a: A`), a rest (`...A[]`), an
/// optional (`A?`) or a plain type
fn parseTupleElement(source: []const u8, tokens: []const Token, cursor: *usize, end: usize) u32 {
    const dotted = cursor.* < end and tokens[cursor.*].isPunct("...");
    const name = cursor.* + @intFromBool(dotted);
    // a named member reads its own name before the annotation, and the annotation is what
    // tells it from a plain type: `A` is a reference, `a: A` is a member
    const named = name < end and tokens[name].kind == .word and
        (tokenIsPunct(tokens, name + 1, end, ":") or
            (tokenIsPunct(tokens, name + 1, end, "?") and tokenIsPunct(tokens, name + 2, end, ":")));

    var total: u32 = 0;
    if (named) {
        total += SELF + SELF;
        if (dotted) {
            total += SELF;
            cursor.* += 1;
        }
        cursor.* += 1;
        if (cursor.* < end and tokens[cursor.*].isPunct("?")) {
            total += SELF;
            cursor.* += 1;
        }
        if (cursor.* < end and tokens[cursor.*].isPunct(":")) {
            cursor.* += 1;
            total += parseType(source, tokens, cursor, end);
        }
        return total;
    }

    if (dotted) {
        // `...A[]` is a `RestType` over the type
        cursor.* += 1;
        total += SELF;
    }
    total += parseType(source, tokens, cursor, end);
    if (cursor.* < end and tokens[cursor.*].isPunct("?")) {
        // `A?` is an `OptionalType` over the type
        cursor.* += 1;
        total += SELF;
    }
    return total;
}

/// a template literal type: the head, then one span per `${...}` substitution, each holding
/// the type it substitutes and the literal that closes it
///
/// the lexer keeps the literal's text out of the token stream, so the `${` that opens each
/// substitution is found in the source between the tokens: without it two substitutions in
/// a row (`${A}${B}`) are one run of tokens and read as one
fn parseTemplateType(source: []const u8, tokens: []const Token, cursor: *usize, end: usize) u32 {
    const head = cursor.*;
    var tail = head + 1;
    while (tail < end and tokens[tail].kind != .template_end) tail += 1;
    if (tail >= end) {
        cursor.* = end;
        return SELF;
    }
    cursor.* = tail + 1;

    // the head is a node, and so are the span and the closing literal of each substitution
    var total: u32 = SELF + SELF;
    var item = head + 1;
    var scan: usize = tokens[head].end;
    const literal_end: usize = tokens[tail].start;
    while (findSubstitution(source, scan, literal_end)) |dollar| {
        const content_start = dollar + SUBSTITUTION_MARKER_LEN;
        const content_end = findSubstitution(source, content_start, literal_end) orelse literal_end;
        const type_start = tokenAtOrAfter(tokens, item, tail, content_start);
        const type_end = tokenAtOrAfter(tokens, type_start, tail, content_end);
        total += SELF + subtreeSize(source, tokens, type_start, type_end) + SELF;
        item = type_end;
        scan = content_start;
    }
    return total;
}

/// the offset of the next `${` in `source[from..to]`, or null when there is none. a `${` a
/// backslash escapes is literal text, so it opens no substitution
fn findSubstitution(source: []const u8, from: usize, to: usize) ?usize {
    var index = from;
    while (index + 1 < to) : (index += 1) {
        if (source[index] == '\\') {
            index += 1;
            continue;
        }
        if (source[index] == '$' and source[index + 1] == '{') return index;
    }
    return null;
}

/// the first token at or after a source offset, searched from `from` up to `limit`
fn tokenAtOrAfter(tokens: []const Token, from: usize, limit: usize, offset: usize) usize {
    var index = from;
    while (index < limit and @as(usize, tokens[index].start) < offset) index += 1;
    return index;
}

/// the sum of the types in a comma-separated list, which is what a list no node wraps stands
/// for
fn typeList(source: []const u8, tokens: []const Token, start: usize, end: usize) u32 {
    var cursor = start;
    var total: u32 = 0;
    while (cursor < end) {
        // a `>`-family token the extent still holds closes the list this one sits in, and
        // one token closes as many levels as its length: `Foo<Bar<Baz>>` ends at the `>>`
        // that closed two lists at once, which is why a list reads to one past its closer
        if (ts.angleClosers(tokens[cursor].text) > 0) break;
        if (tokens[cursor].isPunct(",")) {
            cursor += 1;
            continue;
        }
        const before = cursor;
        total += parseType(source, tokens, &cursor, end);
        if (cursor == before) cursor += 1;
    }
    return total;
}

// --------------------------------------------------------------------- scanners

/// whether the token at `index` is `text`, with `end` bounding the search
fn tokenIsPunct(tokens: []const Token, index: usize, end: usize, text: []const u8) bool {
    return index < end and tokens[index].isPunct(text);
}

/// the index of the closer matching the opener at `open`, searching to `limit`. a
/// well-formed extent nests its brackets, so one depth over all three kinds is enough
fn matching(tokens: []const Token, open: usize, limit: usize) ?usize {
    if (open >= limit or !isOpener(tokens[open].text)) return null;

    var depth: usize = 0;
    var index = open;
    while (index < limit) : (index += 1) {
        if (tokens[index].kind != .punct) continue;
        const text = tokens[index].text;
        if (isOpener(text)) {
            depth += 1;
            continue;
        }
        if (!isCloser(text)) continue;
        if (depth == 0) return null;
        depth -= 1;
        if (depth == 0) return index;
    }
    return null;
}

/// the token that closes the type-argument list opened at `open`, whatever depth
fn matchingAngle(tokens: []const Token, open: usize, limit: usize) ?usize {
    if (open >= limit or !tokens[open].isPunct("<")) return null;

    var depth: usize = 0;
    var index = open;
    while (index < limit) : (index += 1) {
        const token = tokens[index];
        if (token.kind != .punct) continue;
        if (token.isPunct("<")) {
            depth += 1;
            continue;
        }
        const closes = ts.angleClosers(token.text);
        if (closes == 0) continue;
        // a `>>` closes two levels at once, so a token that closes more levels than this
        // search has open still holds the `>` that closes the list the search began at
        if (depth <= closes) return index;
        depth -= closes;
    }
    return null;
}

/// whether the region holds `needle` outside every bracket pair and type-argument list
fn hasTopLevelPunct(tokens: []const Token, from: usize, to: usize, needle: []const u8) bool {
    return findAtTop(tokens, from, to, needle) != null;
}

/// whether the region holds the word `needle` outside every bracket pair, which is what
/// tells a mapped type's `[K in T]` from a computed name
fn hasTopLevelWord(tokens: []const Token, from: usize, to: usize, needle: []const u8) bool {
    var depth: usize = 0;
    var index = from;
    while (index < to) : (index += 1) {
        const token = tokens[index];
        if (token.kind == .punct) {
            if (isOpener(token.text)) {
                depth += 1;
                continue;
            }
            if (isCloser(token.text) and depth > 0) depth -= 1;
            continue;
        }
        if (depth == 0 and token.isWord(needle)) return true;
    }
    return false;
}

/// the first `needle` in the region that no bracket pair and no type-argument list owns
fn findAtTop(tokens: []const Token, from: usize, to: usize, needle: []const u8) ?usize {
    var depth: usize = 0;
    var angle: usize = 0;
    var index = from;
    while (index < to) : (index += 1) {
        const token = tokens[index];
        if (token.kind != .punct) continue;
        const text = token.text;
        if (depth == 0 and angle == 0 and std.mem.eql(u8, text, needle)) return index;
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
        if (closes > 0 and angle >= closes) angle -= closes;
    }
    return null;
}

fn isOpener(text: []const u8) bool {
    if (text.len != 1) return false;
    return text[0] == '(' or text[0] == '[' or text[0] == '{';
}

fn isCloser(text: []const u8) bool {
    if (text.len != 1) return false;
    return text[0] == ')' or text[0] == ']' or text[0] == '}';
}

/// whether a word set holds a token's text
fn contains(list: []const []const u8, text: []const u8) bool {
    for (list) |entry| {
        if (std.mem.eql(u8, entry, text)) return true;
    }
    return false;
}

// ------------------------------------------------------------------------ tests

/// the source a subtree row is read from: a type alias whose right-hand side is the type
const alias_prefix = "type __T = ";

/// the tokens before the type in `alias_prefix`: `type`, `__T` and `=`
const TYPE_START = 3;

/// the counts below are measured, not derived: every row was read from typescript 6.0.3
/// with the detector's own `countNodes` over the type, plus the one for the node itself
const subtree_rows = [_]struct { text: []const u8, subtree: u32 }{
    .{ .text = "string", .subtree = 1 },
    .{ .text = "number", .subtree = 1 },
    .{ .text = "boolean", .subtree = 1 },
    .{ .text = "any", .subtree = 1 },
    .{ .text = "unknown", .subtree = 1 },
    .{ .text = "never", .subtree = 1 },
    .{ .text = "void", .subtree = 1 },
    .{ .text = "undefined", .subtree = 1 },
    .{ .text = "null", .subtree = 2 },
    .{ .text = "object", .subtree = 1 },
    .{ .text = "symbol", .subtree = 1 },
    .{ .text = "bigint", .subtree = 1 },
    .{ .text = "intrinsic", .subtree = 1 },
    .{ .text = "true", .subtree = 2 },
    .{ .text = "false", .subtree = 2 },
    .{ .text = "this", .subtree = 1 },
    .{ .text = "Foo", .subtree = 2 },
    .{ .text = "A.B", .subtree = 4 },
    .{ .text = "A.B.C", .subtree = 6 },
    .{ .text = "Foo<Bar>", .subtree = 4 },
    .{ .text = "A<B, C>", .subtree = 6 },
    .{ .text = "A<B<C>, D>", .subtree = 8 },
    .{ .text = "Promise<Outcome<X, Y[]>>", .subtree = 9 },
    .{ .text = "Array<Array<T>>", .subtree = 6 },
    .{ .text = "T[]", .subtree = 3 },
    .{ .text = "T[][]", .subtree = 4 },
    .{ .text = "(A | B)[]", .subtree = 7 },
    .{ .text = "readonly T[]", .subtree = 4 },
    .{ .text = "keyof T", .subtree = 3 },
    .{ .text = "typeof x", .subtree = 2 },
    .{ .text = "typeof x.y", .subtree = 4 },
    .{ .text = "unique symbol", .subtree = 2 },
    .{ .text = "unique symbol[]", .subtree = 3 },
    .{ .text = "T[K]", .subtree = 5 },
    .{ .text = "A[\"b\"]", .subtree = 5 },
    .{ .text = "readonly string[]", .subtree = 3 },
    .{ .text = "[A, B]", .subtree = 5 },
    .{ .text = "[]", .subtree = 1 },
    .{ .text = "[A, ...B[]]", .subtree = 7 },
    .{ .text = "[a: A, b: B]", .subtree = 9 },
    .{ .text = "[a?: A]", .subtree = 6 },
    .{ .text = "[...rest: A[]]", .subtree = 7 },
    .{ .text = "readonly [A, B]", .subtree = 6 },
    .{ .text = "[A?]", .subtree = 4 },
    .{ .text = "[a: A, ...rest: B[]]", .subtree = 11 },
    .{ .text = "[a, b?]", .subtree = 6 },
    .{ .text = "A | B", .subtree = 5 },
    .{ .text = "A & B", .subtree = 5 },
    .{ .text = "A | B & C", .subtree = 8 },
    .{ .text = "(A | B) & C", .subtree = 9 },
    .{ .text = "A | B | C", .subtree = 7 },
    .{ .text = "keyof A | B", .subtree = 6 },
    .{ .text = "A & B | C", .subtree = 8 },
    .{ .text = "typeof A | B", .subtree = 5 },
    .{ .text = "unique symbol | string", .subtree = 4 },
    .{ .text = "(A)", .subtree = 3 },
    .{ .text = "((A))", .subtree = 4 },
    .{ .text = "() => void", .subtree = 2 },
    .{ .text = "(a, b) => R", .subtree = 7 },
    .{ .text = "(a: T) => R", .subtree = 7 },
    .{ .text = "(readonly a: T) => R", .subtree = 8 },
    .{ .text = "(a?: T) => R", .subtree = 8 },
    .{ .text = "(...rest: T[]) => R", .subtree = 9 },
    .{ .text = "<T>(a: T) => T", .subtree = 9 },
    .{ .text = "<T extends U = V>(a: T) => T", .subtree = 13 },
    .{ .text = "<const T>(a: T) => T", .subtree = 10 },
    .{ .text = "<in T>(a: T) => T", .subtree = 10 },
    .{ .text = "<T, U extends V>(a: T) => U", .subtree = 13 },
    .{ .text = "new () => T", .subtree = 3 },
    .{ .text = "new (a: T) => R", .subtree = 7 },
    .{ .text = "new <T>(a: T) => T", .subtree = 9 },
    .{ .text = "abstract new () => T", .subtree = 4 },
    .{ .text = "(a: T) => (b: U) => R", .subtree = 12 },
    .{ .text = "(this: void, ...rest: T[]) => void", .subtree = 11 },
    .{ .text = "({ a }: T) => R", .subtree = 9 },
    .{ .text = "({ a, b }: T) => R", .subtree = 11 },
    .{ .text = "({ a: c }: T) => R", .subtree = 10 },
    .{ .text = "({ a = 1 }: T) => R", .subtree = 10 },
    .{ .text = "({ a: { b } }: T) => R", .subtree = 12 },
    .{ .text = "([a, b]: T) => R", .subtree = 11 },
    .{ .text = "(a: T = 1) => R", .subtree = 8 },
    .{ .text = "{ a: T }", .subtree = 5 },
    .{ .text = "{ a?: T }", .subtree = 6 },
    .{ .text = "{ readonly a: T }", .subtree = 6 },
    .{ .text = "{ a: T; b: U }", .subtree = 9 },
    .{ .text = "{ a: T, b: U }", .subtree = 9 },
    .{ .text = "{ a: T\n b: U }", .subtree = 9 },
    .{ .text = "{}", .subtree = 1 },
    .{ .text = "{ a: T\n | U }", .subtree = 8 },
    .{ .text = "{ a: T\n (x: U): V }", .subtree = 12 },
    .{ .text = "{ a: () =>\n T }", .subtree = 6 },
    .{ .text = "{ value: string\n [key: string]: unknown }", .subtree = 9 },
    .{ .text = "{ m(a: T): R }", .subtree = 9 },
    .{ .text = "{ m?(): R }", .subtree = 6 },
    .{ .text = "{ (a: T): R }", .subtree = 8 },
    .{ .text = "{ new (a: T): R }", .subtree = 8 },
    .{ .text = "{ <T>(a: T): R }", .subtree = 10 },
    .{ .text = "{ [k: string]: T }", .subtree = 7 },
    .{ .text = "{ readonly [k: string]: T }", .subtree = 8 },
    .{ .text = "{ get a(): T }", .subtree = 5 },
    .{ .text = "{ set a(v: T) }", .subtree = 7 },
    .{ .text = "{ a: { b: T } }", .subtree = 8 },
    .{ .text = "{ a: () => T }", .subtree = 6 },
    .{ .text = "readonly { a: T }", .subtree = 6 },
    .{ .text = "{ m(a: T): R; n: U }", .subtree = 13 },
    .{ .text = "{ [K in keyof T]: U }", .subtree = 8 },
    .{ .text = "{ [K in T]?: U }", .subtree = 8 },
    .{ .text = "{ [K in keyof T as X]: U }", .subtree = 10 },
    .{ .text = "{ +readonly [K in keyof T]: U }", .subtree = 9 },
    .{ .text = "{ -readonly [K in keyof T]-?: U }", .subtree = 10 },
    .{ .text = "{ readonly [K in keyof T]: U }", .subtree = 9 },
    .{ .text = "{ [K in T]-?: U }", .subtree = 8 },
    .{ .text = "A extends B ? C : D", .subtree = 9 },
    .{ .text = "A extends Array<infer U> ? U : never", .subtree = 11 },
    .{ .text = "A extends B ? C extends D ? E : F : G", .subtree = 16 },
    .{ .text = "A extends B ? C : D | E", .subtree = 12 },
    .{ .text = "`a${T}b`", .subtree = 6 },
    .{ .text = "`${T}`", .subtree = 6 },
    .{ .text = "`a${T}${U}b`", .subtree = 10 },
    .{ .text = "`${number}`", .subtree = 5 },
    .{ .text = "`a${string}b${boolean}c`", .subtree = 8 },
    .{ .text = "`plain`", .subtree = 2 },
    .{ .text = "import(\"x\").T", .subtree = 4 },
    .{ .text = "import(\"x\")", .subtree = 3 },
    .{ .text = "typeof import(\"x\").T", .subtree = 4 },
    .{ .text = "-1", .subtree = 3 },
    .{ .text = "([...a]: T) => R", .subtree = 10 },
    .{ .text = "({ ...rest }: T) => R", .subtree = 10 },
    .{ .text = "{ [Symbol.iterator](): T }", .subtree = 8 },
    .{ .text = "{ [\"a\"]: T }", .subtree = 6 },
    .{ .text = "(...args: (A | B)[]) => void", .subtree = 12 },
    .{ .text = "(value: unknown) => value is string", .subtree = 7 },
    .{ .text = "(value: unknown) => asserts value", .subtree = 7 },
    .{ .text = "(value: unknown) => asserts value is Foo<Bar>", .subtree = 11 },
    .{ .text = "(value: unknown) => value is string[]", .subtree = 8 },
    .{ .text = "`\\${T}`", .subtree = 2 },
    .{ .text = "`a\\${T}b${U}`", .subtree = 6 },
    .{ .text = "A<B<C>>", .subtree = 6 },
    .{ .text = "Foo<A.B.C>", .subtree = 8 },
    .{ .text = "{ a: readonly T[] }", .subtree = 7 },
    .{ .text = "A | undefined", .subtree = 4 },
    .{ .text = "Array<T> | null | undefined", .subtree = 8 },
    .{ .text = "| B", .subtree = 3 },
    .{ .text = "| B | C", .subtree = 5 },
    .{ .text = "| readonly B<T>[]\n  | undefined", .subtree = 8 },
    .{ .text = "& B", .subtree = 3 },
    .{ .text = "& B & C", .subtree = 5 },
    .{ .text = "| B & C", .subtree = 6 },
};

test "a type's count is the one typescript reports for it" {
    for (subtree_rows) |row| try expectSubtree(row.text, row.subtree);
}

test "a type-argument list counts the sum of its arguments and no wrapper" {
    try expectArgumentCount("Foo<Bar>", 2);
    try expectArgumentCount("A<B, C>", 4);
    try expectArgumentCount("Map<string, Foo<Bar>>", 5);
    try expectArgumentCount("A<{ x: T }>", 5);
    try expectArgumentCount("A<() => void>", 2);
    try expectArgumentCount("A<[B, C] | D>", 8);
}

test "a type-parameter list counts a parameter node over its name, constraint and default" {
    try expectParameterCount("<T>(a: T) => T", 2);
    try expectParameterCount("<T extends U = V>(a: T) => T", 6);
    try expectParameterCount("<T, U extends V>(a: T) => U", 6);
    try expectParameterCount("<T extends keyof U>(a: T) => T", 5);
}

test "an implements clause counts the clause node and one wrapper per type" {
    try expectClauseCount("class __C implements A {}", "implements", 3);
    try expectClauseCount("class __C implements A, B {}", "implements", 5);
    try expectClauseCount("class __C implements B<T> {}", "implements", 5);
    try expectClauseCount("class __C implements A.B.C {}", "implements", 7);
    try expectClauseCount("class __C implements A.B<T> {}", "implements", 7);
    try expectClauseCount("class __C implements A, B, C<T> {}", "implements", 9);
    try expectClauseCount("class __C extends Base implements A {}", "extends", 3);
    try expectClauseCount("class __C extends Base implements A {}", "implements", 3);
    try expectClauseCount("interface __I extends A, B {}", "extends", 5);
    try expectClauseCount("interface __I extends A.B<T>, C {}", "extends", 9);
}

test "an index signature on a line of its own is a member, not an index into the type above" {
    // the `[` opens a member on its own line, which is what typescript reads it as
    try expectSubtree("{ value: string\n [key: string]: unknown }", 9);
    // while a `[` on the same line indexes the type above it
    try expectSubtree("T[keyof T]", 6);
}

fn expectSubtree(type_text: []const u8, expected: u32) !void {
    const source = try aliasedSource(type_text);
    defer std.testing.allocator.free(source);
    var line: u32 = 1;
    const tokens = try ts.tokenize(std.testing.allocator, source, &line);
    defer std.testing.allocator.free(tokens);

    const actual = subtreeSize(source, tokens, TYPE_START, tokens.len - 1);
    if (actual != expected) {
        std.debug.print("subtree '{s}': want {d}, got {d}\n", .{ type_text, expected, actual });
        return error.TestUnexpectedResult;
    }
}

fn expectArgumentCount(type_text: []const u8, expected: u32) !void {
    const source = try aliasedSource(type_text);
    defer std.testing.allocator.free(source);
    var line: u32 = 1;
    const tokens = try ts.tokenize(std.testing.allocator, source, &line);
    defer std.testing.allocator.free(tokens);

    const open = firstPunct(tokens, "<") orelse {
        std.debug.print("no type-argument list in '{s}'\n", .{type_text});
        return error.TestUnexpectedResult;
    };
    const actual = typeArgumentCount(source, tokens, open, tokens.len - 1);
    if (actual != expected) {
        std.debug.print("arguments '{s}': want {d}, got {d}\n", .{ type_text, expected, actual });
        return error.TestUnexpectedResult;
    }
}

fn expectParameterCount(type_text: []const u8, expected: u32) !void {
    const source = try aliasedSource(type_text);
    defer std.testing.allocator.free(source);
    var line: u32 = 1;
    const tokens = try ts.tokenize(std.testing.allocator, source, &line);
    defer std.testing.allocator.free(tokens);

    const open = firstPunct(tokens, "<") orelse {
        std.debug.print("no type-parameter list in '{s}'\n", .{type_text});
        return error.TestUnexpectedResult;
    };
    const actual = typeParameterCount(source, tokens, open, tokens.len - 1);
    if (actual != expected) {
        std.debug.print("parameters '{s}': want {d}, got {d}\n", .{ type_text, expected, actual });
        return error.TestUnexpectedResult;
    }
}

fn expectClauseCount(class_text: []const u8, keyword: []const u8, expected: u32) !void {
    var line: u32 = 1;
    const tokens = try ts.tokenize(std.testing.allocator, class_text, &line);
    defer std.testing.allocator.free(tokens);

    var start: usize = 0;
    var found = false;
    for (tokens, 0..) |token, index| {
        if (token.isWord(keyword)) {
            start = index + 1;
            found = true;
        }
    }
    if (!found) {
        std.debug.print("no {s} clause in '{s}'\n", .{ keyword, class_text });
        return error.TestUnexpectedResult;
    }

    // the clause runs to the body, or to the keyword of the clause after it
    var stop = tokens.len;
    var index = start;
    while (index < tokens.len) : (index += 1) {
        if (tokens[index].isPunct("{")) {
            stop = index;
            break;
        }
        if (tokens[index].isWord("extends") or tokens[index].isWord("implements")) {
            stop = index;
            break;
        }
    }

    const actual = heritageCount(class_text, tokens, start, stop);
    if (actual != expected) {
        std.debug.print("clause {s} of '{s}': want {d}, got {d}\n", .{ keyword, class_text, expected, actual });
        return error.TestUnexpectedResult;
    }
}

/// a type alias whose right-hand side is the type under test
fn aliasedSource(type_text: []const u8) ![]const u8 {
    return std.fmt.allocPrint(std.testing.allocator, "{s}{s};", .{ alias_prefix, type_text });
}

/// the index of the first `text` token at or after the type's own first token
fn firstPunct(tokens: []const Token, text: []const u8) ?usize {
    var index: usize = TYPE_START;
    while (index < tokens.len) : (index += 1) {
        if (tokens[index].isPunct(text)) return index;
    }
    return null;
}
