const std = @import("std");
const config = @import("config.zig");
const ir = @import("ir.zig");
const ts = @import("lang/ts.zig");
const cosmetic = @import("rules/cosmetic.zig");
const resilience = @import("rules/resilience.zig");
const behavioural = @import("rules/behavioural.zig");
const complexity = @import("rules/complexity.zig");
const hygiene = @import("rules/hygiene.zig");
const structural = @import("rules/structural.zig");
const scope = @import("scope.zig");

/// grimuah's rules, as data plus a matcher
///
/// every rule declares the layer it belongs to, its severity, the message a
/// finding carries, the languages it is written for, and whether it reads the
/// token stream or the parsed tree. the engine (`src/engine.zig`) does discovery
/// and per-file work; a rule only decides whether a file violates it.
///
/// a rule that needs structure sets `syntax = .ir` and reads `context.module`.
/// the engine parses the file only when an enabled rule asks for it, because the
/// parse is the expensive half of the front-end (measured: 1243ms for 5000
/// files against 734ms to tokenise) and the token-shaped rules do not need it.
///
/// the messages are the ones the shipped plugin files carried, and
/// `tests/oracle/` freezes the findings they produced

pub const Severity = enum { err, warn };

pub const Finding = struct {
    path: []u8,
    line: u32,
    /// owned by the finding: a hygiene rule reports the name of the declaration
    message: []u8,
    layer: []const u8,
    severity: Severity,
};

pub const Layer = enum {
    cosmetic,
    structural,
    resilience,
    behavioural,
    /// the curated native equivalent of biome's `recommended` built-in ruleset
    /// these are not a config layer: they are on whenever the engine runs
    hygiene,

    pub fn name(self: Layer) []const u8 {
        return @tagName(self);
    }
};

/// how a rule reads a file
pub const Syntax = enum {
    /// the token stream, which is what the lexer always produces
    tokens,
    /// the parsed tree, which costs a parse of every file the rule can match
    ir,
};

/// `ts` is the only front-end today. a rule that is language-agnostic (no
/// syntax-shaped keyword like `let` or `switch`) runs on any front-end that
/// produces the same tree
pub const Language = enum {
    ts,

    pub fn name(self: Language) []const u8 {
        return @tagName(self);
    }
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    cfg: *const config.Config,
    findings: *std.ArrayList(Finding),
    path: []const u8,
    source: []const u8,
    tokens: []const ts.Token,
    /// null unless an enabled rule declared `syntax = .ir`
    module: ?*const ir.Module,
    /// the declarations and references of the file, null unless the hygiene
    /// rules are on. they are the only rules that read it, and the pass costs a
    /// walk of the file per rule that asked for it, so the engine builds it once
    scopes: ?*const scope.Table = null,
    /// every node in walk order, built once per file by the engine. a rule that
    /// visits the whole tree reads this instead of chasing links, which is what
    /// seven rules and the scope pass used to do separately
    walk: []const ir.WalkEntry = &.{},
    /// whether the hygiene rules run. the parity test and the hygiene corpus
    /// turn them off to isolate the architecture rules
    hygiene: bool = true,

    pub fn report(self: *const Context, line: u32, layer: Layer, message: []const u8, severity: Severity) !void {
        try self.findings.append(self.allocator, .{
            .path = try self.allocator.dupe(u8, self.path),
            .line = line,
            .message = try self.allocator.dupe(u8, message),
            .layer = layer.name(),
            .severity = severity,
        });
    }
};

pub const Rule = struct {
    layer: Layer,
    severity: Severity,
    message: []const u8,
    syntax: Syntax = .tokens,
    languages: []const Language = &.{.ts},
    /// `src/lint.zig`, the token engine the native one replaced, implements this
    /// rule, so `src/rules/parity.zig` can compare the two over real code. a rule
    /// added after the migration has no twin there: the corpus in
    /// `tests/oracle/` is what pins it instead, which is why the guard reads
    /// this field rather than assuming every rule is covered
    oracle: bool = true,
    match: *const fn (*const Context) anyerror!void,
};

pub const em_dash = "do not use em-dashes; use commas, colons, or sentence breaks instead";
pub const null_literal = "do not use null; use undefined. null only at third-party boundaries (DB, RegExp)";
pub const let_decl = "do not use let; use const. only let at module-level mutable caches";
pub const switch_stmt = "do not use switch; use a dispatch table (Record/Map) instead";
pub const imperative_for = "do not use imperative for loops; use map, filter, reduce, or for..of instead";
pub const double_equals = "use === instead of == to avoid type coercion bugs";
pub const as_any = "'as any' bypasses type safety entirely; use a proper type instead";
pub const any_type = "This `any` type bypasses type safety. Write the type you mean instead.";
pub const chained_cast = "chained 'as' casts bypass type safety; use a single cast only";
pub const reexport = "do not proxy re-export; every export must originate from the file that defines it";
pub const as_const = "use enum instead of const + as const; enum gives you both value and type in one declaration";
pub const throw_stmt = "do not use throw; all errors must flow through OperationOutcome. see lib/outcome.ts";
pub const bare_catch = "do not use bare catch with silent failure; log the error or return an Outcome";
pub const silent_catch = "catch block must handle or log the error, not silently discard it";

/// the rules added from the rule research (`docs/rule-candidates/catalogue.md`).
/// they are user-facing sentences, so they carry the capital and the full stop
/// the shipped messages predate
pub const max_nesting_depth = "This block is nested {d} levels deep. Return early or extract a helper.";
pub const max_parameters = "This function takes {d} parameters. Group them into a named readonly type, or split the function.";
pub const lowercase_copy = "This copy starts lowercase. Capitalise the first letter of the sentence.";
pub const boolean_flag_argument = "This call passes a bare boolean literal. Name the behaviour instead, or pass a named enum value.";
pub const max_function_lines = "This function body is {d} lines long. Extract each distinct job into a named function.";
pub const nested_ternary = "This conditional expression contains another conditional expression. Extract the inner decision into a named helper or a lookup.";
pub const max_file_lines = "This file is {d} lines long. Split it along the responsibilities its sections already show.";
pub const await_in_loop = "This loop awaits inside its body, so every iteration runs in sequence. Map the items to promises and await Promise.all once.";
pub const max_cyclomatic_complexity = "This function has a cyclomatic complexity of {d}. Extract each decision into a named predicate or a lookup.";
pub const unbounded_collection_read = "This query reads a collection with no LIMIT, so it returns every matching row. Add an explicit LIMIT and paginate when the caller needs everything.";
pub const for_of_accumulation = "This for..of loop builds an array by pushing into it. Use map, filter, flatMap or reduce instead.";
pub const config_behaviour = "This .config.ts file declares a function. Move the behaviour into the surface's own module.";
pub const if_chain_dispatch = "These {d} branches dispatch on one subject. Declare a Record or Map from the subject's value to the handler.";
pub const literal_union_enum = "This union of {d} string literals carries no runtime value. Declare a string enum and use its members as the discriminant.";

/// the hygiene layer. the wording is biome's own, so a project that ran the
/// biome step before reads the same message from the native engine
pub const unused_import = "This import is unused.";
pub const unused_variable = "This variable {s} is unused.";
pub const unused_function = "This function {s} is unused.";
pub const unused_class = "This class {s} is unused.";
pub const use_const = "This let declares a variable that is only assigned once.";
pub const constant_condition = "This condition always evaluates to the same value.";
pub const unreachable_code = "This code will never be reached.";

/// every rule, in the order findings are reported
pub const all = [_]Rule{
    .{
        .layer = .cosmetic,
        .severity = .err,
        .message = em_dash,
        .match = cosmetic.checkEmDash,
    },
    .{
        .layer = .resilience,
        .severity = .err,
        .message = null_literal,
        .match = resilience.checkNullLiteral,
    },
    .{
        .layer = .resilience,
        .severity = .err,
        .message = let_decl,
        .syntax = .ir,
        .match = resilience.checkLetDeclaration,
    },
    .{
        .layer = .resilience,
        .severity = .err,
        .message = switch_stmt,
        .syntax = .ir,
        .match = resilience.checkSwitchStatement,
    },
    .{
        .layer = .resilience,
        .severity = .err,
        .message = imperative_for,
        .syntax = .ir,
        .match = resilience.checkImperativeFor,
    },
    .{
        .layer = .resilience,
        .severity = .err,
        .message = double_equals,
        .match = resilience.checkDoubleEquals,
    },
    .{
        .layer = .resilience,
        .severity = .err,
        .message = as_any,
        .match = resilience.checkAsAny,
    },
    .{
        .layer = .resilience,
        .severity = .err,
        .message = any_type,
        .oracle = false,
        .match = resilience.checkAnyType,
    },
    .{
        .layer = .resilience,
        .severity = .err,
        .message = chained_cast,
        .match = resilience.checkChainedCast,
    },
    .{
        .layer = .resilience,
        .severity = .err,
        .message = reexport,
        .match = resilience.checkReexport,
    },
    .{
        .layer = .resilience,
        .severity = .err,
        .message = as_const,
        .match = resilience.checkAsConst,
    },
    .{
        .layer = .behavioural,
        .severity = .err,
        .message = throw_stmt,
        .match = behavioural.checkThrow,
    },
    .{
        .layer = .behavioural,
        .severity = .err,
        .message = bare_catch,
        .match = behavioural.checkBareCatch,
    },
    .{
        .layer = .behavioural,
        .severity = .warn,
        .message = silent_catch,
        .match = behavioural.checkSilentCatch,
    },
    .{
        .layer = .resilience,
        .severity = .warn,
        .message = max_nesting_depth,
        .syntax = .ir,
        .oracle = false,
        .match = complexity.checkMaxNestingDepth,
    },
    .{
        .layer = .resilience,
        .severity = .warn,
        .message = max_parameters,
        .syntax = .ir,
        .oracle = false,
        .match = complexity.checkMaxParameters,
    },
    .{
        .layer = .cosmetic,
        .severity = .warn,
        .message = lowercase_copy,
        .oracle = false,
        .match = cosmetic.checkLowercaseCopy,
    },
    .{
        .layer = .resilience,
        .severity = .warn,
        .message = boolean_flag_argument,
        .syntax = .ir,
        .oracle = false,
        .match = resilience.checkBooleanFlagArgument,
    },
    .{
        .layer = .resilience,
        .severity = .warn,
        .message = max_function_lines,
        .syntax = .ir,
        .oracle = false,
        .match = complexity.checkMaxFunctionLines,
    },
    .{
        .layer = .resilience,
        .severity = .warn,
        .message = nested_ternary,
        .syntax = .ir,
        .oracle = false,
        .match = complexity.checkNestedTernary,
    },
    .{
        .layer = .resilience,
        .severity = .warn,
        .message = max_file_lines,
        .oracle = false,
        .match = complexity.checkMaxFileLines,
    },
    .{
        .layer = .behavioural,
        .severity = .warn,
        .message = await_in_loop,
        .syntax = .ir,
        .oracle = false,
        .match = behavioural.checkAwaitInLoop,
    },
    .{
        .layer = .resilience,
        .severity = .warn,
        .message = max_cyclomatic_complexity,
        .syntax = .ir,
        .oracle = false,
        .match = complexity.checkMaxCyclomaticComplexity,
    },
    .{
        .layer = .resilience,
        .severity = .warn,
        .message = unbounded_collection_read,
        .syntax = .ir,
        .oracle = false,
        .match = resilience.checkUnboundedCollectionRead,
    },
    .{
        .layer = .resilience,
        .severity = .err,
        .message = for_of_accumulation,
        .syntax = .ir,
        .oracle = false,
        .match = resilience.checkForOfAccumulation,
    },
    .{
        .layer = .structural,
        .severity = .warn,
        .message = config_behaviour,
        .syntax = .ir,
        .oracle = false,
        .match = structural.checkConfigBehaviour,
    },
    .{
        .layer = .resilience,
        .severity = .warn,
        .message = if_chain_dispatch,
        .syntax = .ir,
        .oracle = false,
        .match = resilience.checkIfChainDispatch,
    },
    .{
        .layer = .resilience,
        .severity = .warn,
        .message = literal_union_enum,
        .syntax = .ir,
        .oracle = false,
        .match = resilience.checkLiteralUnionEnum,
    },
    .{
        .layer = .hygiene,
        .severity = .warn,
        .message = unused_import,
        .syntax = .ir,
        .match = hygiene.checkUnusedImports,
    },
    .{
        .layer = .hygiene,
        .severity = .warn,
        .message = unused_variable,
        .syntax = .ir,
        .match = hygiene.checkUnusedVariables,
    },
    .{
        .layer = .hygiene,
        .severity = .warn,
        .message = use_const,
        .syntax = .ir,
        .match = hygiene.checkUseConst,
    },
    .{
        .layer = .hygiene,
        .severity = .err,
        .message = constant_condition,
        .syntax = .ir,
        .match = hygiene.checkConstantCondition,
    },
    .{
        .layer = .hygiene,
        .severity = .err,
        .message = unreachable_code,
        .syntax = .ir,
        .match = hygiene.checkUnreachable,
    },
};

/// whether an enabled rule needs the parsed tree, so the engine knows whether
/// paying for the parse can produce anything
pub fn needsTree(cfg: *const config.Config, with_hygiene: bool) bool {
    for (all) |rule| {
        if (rule.syntax != .ir) continue;
        if (rule.layer == .hygiene and !with_hygiene) continue;
        if (enabled(cfg, rule.layer)) return true;
    }
    return false;
}

/// whether every file must be linted regardless of its text. the hygiene rules
/// match a declaration the file may have anywhere, so no word-boundary pre-test
/// can rule a file out
pub fn lintsEveryFile(cfg: *const config.Config, with_hygiene: bool) bool {
    if (with_hygiene) return true;
    return needsTree(cfg, with_hygiene);
}

pub fn enabled(cfg: *const config.Config, layer: Layer) bool {
    return switch (layer) {
        .cosmetic => cfg.layers.cosmetic,
        .structural => cfg.layers.structural,
        .resilience => cfg.layers.resilience,
        .behavioural => cfg.layers.behavioural,
        .hygiene => true,
    };
}

/// run every enabled rule over one file, in table order
pub fn run(context: *const Context) !void {
    for (all) |rule| {
        if (rule.layer == .hygiene and !context.hygiene) continue;
        if (!enabled(context.cfg, rule.layer)) continue;
        if (rule.syntax == .ir and context.module == null) continue;
        try rule.match(context);
    }
}
