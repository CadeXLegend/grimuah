const std = @import("std");
const config = @import("config.zig");
const ir = @import("ir.zig");
const ts = @import("lang/ts.zig");
const typemodel = @import("lang/typemodel.zig");
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
    /// every file of the run, in walk order. a rule whose verdict depends on the run
    /// rather than on the file in front of it reads this: a rule that has to pick the
    /// one file a whole-surface finding is anchored at, and cannot know which file
    /// that is from its own path
    paths: []const []const u8 = &.{},
    /// whether the hygiene rules run. the parity test and the hygiene corpus
    /// turn them off to isolate the architecture rules
    hygiene: bool = true,
    /// the project-wide pass this file takes part in. null unless an enabled rule
    /// declared `needs_project`
    project: ?*Project = null,
    /// the rule `run` is dispatching to, so a rule that defers a call site does not
    /// restate the layer, the severity and the message its table entry already
    /// carries
    rule: ?*const Rule = null,

    pub fn report(self: *const Context, line: u32, layer: Layer, message: []const u8, severity: Severity) !void {
        try self.findings.append(self.allocator, .{
            .path = try self.allocator.dupe(u8, self.path),
            .line = line,
            .message = try self.allocator.dupe(u8, message),
            .layer = layer.name(),
            .severity = severity,
        });
    }

    /// record a call site whose verdict needs the whole project, for the engine to
    /// report once every file has been read, with the layer, the severity and the
    /// message of the rule that deferred it
    ///
    /// a rule that forgets `needs_project` finds no project here, defers nothing,
    /// and reports nothing: the rule's own test is what catches that, rather than a
    /// verdict the run could not have reached
    ///
    /// the name is copied, because it points into this file's own memory and the
    /// file is gone by the time the run resolves the call site
    pub fn deferToProject(self: *const Context, name: []const u8, line: u32, passes: *const fn (declared_return: []const u8) bool) !void {
        const project = self.project orelse return;
        const rule = self.rule orelse return;

        try project.deferred.append(self.allocator, .{
            .name = try self.allocator.dupe(u8, name),
            .line = line,
            .passes = passes,
            .layer = rule.layer,
            .severity = rule.severity,
            .message = rule.message,
        });
    }
};

/// a call site whose verdict waits for the whole project
///
/// a rule reads the call site out of its own file, but whether the call is a
/// violation depends on how the callee is declared, and the declaration can sit in
/// any file of the run. the rule records the call site with its own test over a
/// declared return type, and the engine reports it once every declaration of that
/// name has passed the test
pub const Candidate = struct {
    /// the callee's name as the call spells it: an identifier, or the last name
    /// of a member access
    name: []const u8,
    /// the line to report, which is the statement's own start
    line: u32,
    /// the rule's test over a declared return type. two `read` helpers, one
    /// returning an outcome and one a boolean, say nothing about the call in
    /// front of them, so only a name every declaration agrees on is reported
    passes: *const fn (declared_return: []const u8) bool,
    /// the deferring rule's own table entry, so a finding this produces carries
    /// the same layer, severity and message as one the rule reports inline
    layer: Layer,
    severity: Severity,
    message: []const u8,
};

/// one static import statement of one file, as the project pass collects it
pub const ImportEdge = struct {
    /// the module specifier as the statement writes it, e.g. `../db/accounts.repo`
    specifier: []const u8,
    /// the line the statement starts on
    line: u32,
    /// the local names a named clause binds: `{ a, b as c }` gives `a` and `c`.
    /// the default and namespace forms bind a name of their own shape and
    /// contribute none, because a rule that reads imported names reads the ones a
    /// clause lists
    names: []const []const u8 = &.{},
};

/// the cycle a file belongs to, in `ProjectIndex.cycle_of`, when it belongs to none
pub const no_cycle: u32 = std.math.maxInt(u32);

/// one import statement of one file, with the file it turned out to name
///
/// the merge resolves every specifier against the files of the run before an edge
/// exists, so a target is always a file index and the graph holds no dangling one
pub const ResolvedImport = struct {
    /// the index of the file this import points at in the run
    target: u32,
    /// the line the statement starts on, which is the line a cycle reports on
    line: u32,
    /// the local names a named clause binds, as `ImportEdge.names`
    names: []const []const u8 = &.{},
};

/// who imports one file of the run, and under which local names
pub const Importer = struct {
    /// the index of the file that imports
    file: u32,
    /// the names that file bound from a named clause
    names: []const []const u8 = &.{},
};

/// the kinds of declaration a rule can judge by where they live
pub const ExportKind = enum {
    /// `export type X = ...`
    type_alias,
    /// `export enum X { ... }`, the `const`, `declare` and bare forms alike
    @"enum",
};

/// one declaration a file exports
///
/// the front-end models `interface`, `type`, `enum`, `namespace` and `declare` as
/// one node kind with no name and no children, so the merge reads the keyword and
/// the name off the declaration's own leading words
pub const ExportedDeclaration = struct {
    name: []const u8,
    kind: ExportKind,
    /// the line the declaration starts on, which is where a rule reports it
    line: u32,
};

/// the run's import graph, its reverse, and the declarations each file exports
///
/// a file can be reached from another file of the same dagOrder, so the surface
/// firewall cannot see a cycle, and the run has to read every file before it can
/// decide. the graph is the merge's, not one file's: it outlives every
/// contribution, because the verdict for the first file needs the last file's
/// edges
pub const ProjectIndex = struct {
    /// the index's own memory: every file's imports, names and labels outlive the
    /// file they were read from, because the last file's verdict needs the first
    /// file's
    arena: std.heap.ArenaAllocator,
    /// every file of the run, in walk order. a rule that has to sort the run, or ask
    /// whether two files sit in one directory, reads this
    paths: []const []const u8 = &.{},
    /// every file's own imports, in statement order, indexed by file
    imports: []const []const ResolvedImport = &.{},
    /// the reverse of `imports`: who imports each file, and under which names
    importers: []const []const Importer = &.{},
    /// the declarations each file exports, indexed by file
    exports: []const []const ExportedDeclaration = &.{},
    /// the component a file sits in, when that component holds two files or more,
    /// and `no_cycle` otherwise. two files share an id exactly when they are in
    /// one strongly connected component of two or more
    cycle_of: []const u32 = &.{},

    pub fn deinit(self: *ProjectIndex) void {
        self.arena.deinit();
    }
};

/// one file's import cycle, as the table's rule declares it
///
/// the merge builds the graph and calls every enabled rule's verdict per file, so
/// a rule decides only what the file's own row is. it reports through the table
/// entry it is handed, which is where the layer, the severity and the message
/// stay stated once
pub const IndexVerdict = *const fn (
    allocator: std.mem.Allocator,
    graph: *const ProjectIndex,
    file: usize,
    path: []const u8,
    rule: *const Rule,
    findings: *std.ArrayList(Finding),
) std.mem.Allocator.Error!void;

/// the project-wide pass, as one file sees it: the return types this file declares,
/// the call sites this file's rules defer, and the imports the merge resolves into
/// the run's graph
///
/// the engine keeps one per file, in path order, so a worker writes only its own
/// and the run resolves them in walk order once every file has been read
pub const Project = struct {
    declared_returns: std.ArrayList(typemodel.DeclaredReturn) = .empty,
    deferred: std.ArrayList(Candidate) = .empty,
    imports: std.ArrayList(ImportEdge) = .empty,
    exports: std.ArrayList(ExportedDeclaration) = .empty,

    /// free what this file contributed, with the allocator it was built on
    pub fn deinit(self: *Project, allocator: std.mem.Allocator) void {
        for (self.declared_returns.items) |declared| {
            allocator.free(declared.name);
            allocator.free(declared.type_text);
        }
        self.declared_returns.deinit(allocator);
        for (self.deferred.items) |candidate| allocator.free(candidate.name);
        self.deferred.deinit(allocator);
        for (self.imports.items) |import| {
            allocator.free(import.specifier);
            for (import.names) |name| allocator.free(name);
            if (import.names.len > 0) allocator.free(import.names);
        }
        self.imports.deinit(allocator);
        for (self.exports.items) |exported| allocator.free(exported.name);
        self.exports.deinit(allocator);
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
    /// this rule reports through the project index rather than per file, so the
    /// engine collects every file's declared return types as it reads them and
    /// resolves the rule's call sites once the scan is done
    needs_project: bool = false,
    /// this rule reads the run's import graph, so the merge resolves every file's
    /// imports and runs the component pass before any verdict. the pass is over the
    /// whole project, so a config that enables no graph rule must not pay for it
    needs_project_index: bool = false,
    /// the verdict this rule reaches over the import graph. a rule that declared
    /// `needs_project_index` must have one, or it would drive the pass and report
    /// nothing
    resolve_index: ?IndexVerdict = null,
    /// the per-file matcher. a rule whose only verdict is the import graph has
    /// none, because that verdict needs every file of the run rather than the one
    /// in front of it
    match: ?*const fn (*const Context) anyerror!void = null,
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
pub const optional_property = "This property is optional. Make it required and default it at the boundary, or model the states as a discriminated union.";
pub const readonly_collection_signature = "This signature hands over a mutable array. Declare it as `readonly T[]` or `ReadonlyArray<T>`.";
pub const readonly_type_member = "This property is mutable. Add `readonly`, and build a new object when a layer needs a changed copy.";
pub const scalar_failure_return = "This async operation reports its failure as a bare boolean or number, so a caller cannot tell the answer from the error. Return an outcome value that names the failure reason.";
pub const discarded_outcome = "This call returns an Outcome and nothing reads the result, so its failure branch is unreachable. Assign the result and narrow `succeeded`, or log the failure where the call is best effort.";
pub const unread_scalar_result = "This call's declared result is a bare boolean or number and nothing reads it, so the failure channel exists only in the signature. Read the result and act on it, or narrow the callee to a `void` result.";
pub const enum_placement = "This enum is a configuration constant declared in an implementation module. Move it to the surface's .config.ts file.";
pub const import_cycle = "This import closes a cycle: the file it names imports back into this one, so module initialisation order decides what this file sees. Lift the shared symbols into a module at or above the shallower of the two, or invert one direction with a callback.";
pub const shared_type_placement = "This type is imported from another directory, so this module's behaviour is coupled to it. Declare it in {s}.types.ts instead.";
pub const redundant_allowed_import = "Surface '{s}' (dagOrder {d}) grants '{s}' (dagOrder {d}), which the dag already permits. Delete the entry from its allowedImports list.";

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
        .layer = .resilience,
        .severity = .warn,
        .message = optional_property,
        .syntax = .ir,
        .oracle = false,
        .match = resilience.checkOptionalProperties,
    },
    .{
        .layer = .resilience,
        .severity = .warn,
        .message = readonly_collection_signature,
        .syntax = .ir,
        .oracle = false,
        .match = resilience.checkReadonlyCollectionSignatures,
    },
    .{
        .layer = .resilience,
        .severity = .warn,
        .message = readonly_type_member,
        .syntax = .ir,
        .oracle = false,
        .match = resilience.checkReadonlyTypeMembers,
    },
    .{
        .layer = .resilience,
        .severity = .warn,
        .message = scalar_failure_return,
        .syntax = .ir,
        .oracle = false,
        .match = resilience.checkScalarFailureReturn,
    },
    .{
        .layer = .behavioural,
        .severity = .warn,
        .message = discarded_outcome,
        .syntax = .ir,
        .oracle = false,
        .needs_project = true,
        .match = behavioural.checkDiscardedOutcome,
    },
    .{
        .layer = .behavioural,
        .severity = .warn,
        .message = unread_scalar_result,
        .syntax = .ir,
        .oracle = false,
        .needs_project = true,
        .match = behavioural.checkUnreadScalarResult,
    },
    .{
        .layer = .structural,
        .severity = .warn,
        .message = enum_placement,
        .syntax = .ir,
        .oracle = false,
        .match = structural.checkEnumPlacement,
    },
    .{
        .layer = .structural,
        .severity = .err,
        .message = import_cycle,
        .syntax = .ir,
        .oracle = false,
        .needs_project_index = true,
        .resolve_index = structural.resolveImportCycle,
    },
    .{
        .layer = .structural,
        .severity = .warn,
        .message = redundant_allowed_import,
        .oracle = false,
        .match = structural.checkRedundantAllowedImport,
    },
    .{
        .layer = .structural,
        .severity = .warn,
        .message = shared_type_placement,
        .syntax = .ir,
        .oracle = false,
        .needs_project_index = true,
        .resolve_index = structural.checkSharedTypePlacement,
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

/// whether an enabled rule needs the whole project's declared return types, so the
/// engine knows to collect them as it reads each file
pub fn needsProject(cfg: *const config.Config, with_hygiene: bool) bool {
    for (all) |rule| {
        if (!rule.needs_project) continue;
        if (rule.layer == .hygiene and !with_hygiene) continue;
        if (enabled(cfg, rule.layer)) return true;
    }
    return false;
}

/// whether an enabled rule reads the run's import graph, so the merge knows to
/// collect every file's imports, resolve them and run the component pass
///
/// the pass reads the whole project and costs a walk of every file's imports plus
/// a component pass over the graph, so a project that enables no graph rule must
/// not pay it
pub fn needsProjectIndex(cfg: *const config.Config, with_hygiene: bool) bool {
    for (all) |rule| {
        if (!rule.needs_project_index) continue;
        if (rule.layer == .hygiene and !with_hygiene) continue;
        if (enabled(cfg, rule.layer)) return true;
    }
    return false;
}

/// reach every enabled graph rule's verdict for one file of the run
///
/// the merge builds the graph once and calls this as it walks the files, so a
/// rule's own resolver decides only what that file's row is, and the layer, the
/// severity and the message come off the table entry the resolver is handed
pub fn resolveIndex(
    allocator: std.mem.Allocator,
    graph: *const ProjectIndex,
    file: usize,
    path: []const u8,
    cfg: *const config.Config,
    with_hygiene: bool,
    findings: *std.ArrayList(Finding),
) std.mem.Allocator.Error!void {
    for (&all) |*rule| {
        if (!rule.needs_project_index) continue;
        const verdict = rule.resolve_index orelse continue;
        if (rule.layer == .hygiene and !with_hygiene) continue;
        if (!enabled(cfg, rule.layer)) continue;
        try verdict(allocator, graph, file, path, rule, findings);
    }
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
///
/// the context is copied per rule so the rule's own table entry travels with the
/// dispatch: `Context.deferToProject` reads the layer, the severity and the
/// message from it rather than from the rule's own restatement of them
pub fn run(context: *const Context) !void {
    for (&all) |*rule| {
        if (rule.layer == .hygiene and !context.hygiene) continue;
        if (!enabled(context.cfg, rule.layer)) continue;
        if (rule.syntax == .ir and context.module == null) continue;
        const matcher = rule.match orelse continue;

        var dispatched = context.*;
        dispatched.rule = rule;
        try matcher(&dispatched);
    }
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

// the two flags a rule can reach its verdict through are not independent, and the
// table is where a mistake in them is silent: a rule with neither reports nothing
// for the whole run, a rule that drives the graph pass without a verdict pays for
// the pass and reports nothing, and a rule with a verdict but no flag never reads
// a graph
test "every rule has a verdict, and the graph flag and the graph verdict agree" {
    for (all) |rule| {
        try testing.expect(rule.match != null or rule.resolve_index != null);
        try testing.expect(rule.needs_project_index == (rule.resolve_index != null));
    }
}

// the graph dispatch reaches a rule only when its own layer is on, and the row it
// appends carries the layer, the severity and the message of the table entry it was
// handed rather than a restatement at the call site. a graph rule has no per-file
// matcher to report through, so this is the only path its rows take

test "a graph verdict is reached only for a rule whose layer is on, and reports through the table" {
    const allocator = testing.allocator;

    var arena = std.heap.ArenaAllocator.init(allocator);
    const graph_allocator = arena.allocator();
    // every allocation through the arena happens before the literal copies it
    // every slot the index holds has one entry, because every rule that reads the
    // index reads the slot of the file it was handed
    const paths = try graph_allocator.alloc([]const u8, 1);
    paths[0] = "src/db/a.repo.ts";
    const own_imports = try graph_allocator.alloc(ResolvedImport, 1);
    own_imports[0] = .{ .target = 0, .line = 7 };
    const imports = try graph_allocator.alloc([]const ResolvedImport, 1);
    imports[0] = own_imports;
    const importers = try graph_allocator.alloc([]const Importer, 1);
    importers[0] = &.{};
    const exports = try graph_allocator.alloc([]const ExportedDeclaration, 1);
    exports[0] = &.{};
    const cycle_of = try graph_allocator.alloc(u32, 1);
    cycle_of[0] = 0;
    var graph = ProjectIndex{
        .arena = arena,
        .paths = paths,
        .imports = imports,
        .importers = importers,
        .exports = exports,
        .cycle_of = cycle_of,
    };
    defer graph.deinit();

    var findings: std.ArrayList(Finding) = .empty;
    defer {
        for (findings.items) |finding| {
            allocator.free(finding.path);
            allocator.free(finding.message);
        }
        findings.deinit(allocator);
    }

    const graph_layer_off = config.Config{ .surfaces = &.{}, .layers = .{ .cosmetic = true, .structural = false, .resilience = true, .behavioural = true } };
    try resolveIndex(allocator, &graph, 0, "src/db/a.repo.ts", &graph_layer_off, false, &findings);
    try testing.expectEqual(@as(usize, 0), findings.items.len);

    const graph_layer_on = config.Config{ .surfaces = &.{}, .layers = .{ .cosmetic = true, .structural = true, .resilience = false, .behavioural = false } };
    try resolveIndex(allocator, &graph, 0, "src/db/a.repo.ts", &graph_layer_on, false, &findings);
    try testing.expectEqual(@as(usize, 1), findings.items.len);
    try testing.expectEqual(@as(u32, 7), findings.items[0].line);
    try testing.expectEqualStrings("structural", findings.items[0].layer);
    try testing.expectEqual(Severity.err, findings.items[0].severity);
    try testing.expectEqualStrings(import_cycle, findings.items[0].message);
}
