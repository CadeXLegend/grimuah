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
    /// `export const X = ...`, and the `let` and `var` forms. one per declarator,
    /// so `export const a = 1, b = 2` contributes two
    variable,
    /// `export function X() { ... }`
    function,
    /// `export class X { ... }`
    class,
};

/// one declaration a file exports
///
/// the front-end models `interface`, `type`, `enum`, `namespace` and `declare` as
/// one node kind with no name and no children, so a type or an enum declaration's name
/// is read off its own leading words, while a function, a class and a variable
/// statement carry theirs on the node
pub const ExportedDeclaration = struct {
    name: []const u8,
    kind: ExportKind,
    /// the line the declared name sits on, which is where the detector reports and
    /// where a rule anchors its row
    line: u32,
};

/// the run's import graph, its reverse, the declarations each file exports, and
/// the names each file mentions
///
/// a file can be reached from another file of the same dagOrder, so the surface
/// firewall cannot see a cycle, and the run has to read every file before it can
/// decide. the graph is the merge's, not one file's: it outlives every
/// contribution, because the verdict for the first file needs the last file's
/// edges
///
/// the mention counts are what a rule asks when the question is who else knows a
/// name: an exported declaration whose name no other file spells promises an
/// audience it does not have
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
    /// how many distinct files of the run spell each name, whatever the name is
    /// spelled for. a rule whose verdict is "no other file knows this name" reads
    /// it, and the count is what lets it ask that of every export in one pass
    /// rather than walking the run's names once per file
    mention_files: std.StringHashMapUnmanaged(u32) = .empty,

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

/// the one byte `BodyFingerprint.key` puts between the declared name and the collapsed body
/// text, which is a byte a name cannot hold
/// both ends of that layout read it: the engine builds the key, and a rule that groups bodies by
/// their text alone takes the name back off it
pub const body_key_separator_length: usize = 1;

/// one function body a file offers to the run's fingerprint index
pub const BodyFingerprint = struct {
    /// the declared name, which is the row's subject
    /// it is a view into `key` rather than a
    /// second allocation: the key opens with the name, and the separator is a byte a name
    /// cannot hold
    name: []const u8,
    /// `name|collapsed body text`, which is the detector's own key for "the same helper
    /// written twice"
    /// the name is part of it, which is what makes the accepted rule for an
    /// identical body exact, and a body copied into another file under a new name is a
    /// different key
    key: []const u8,
    /// the line the body starts on, which is where the detector reports
    line: u32,
    /// the node the body is, which is what a rule that has to tell whether a site sits
    /// inside this body walks against: the key is text, and the tree is gone by the time a
    /// verdict runs
    body: ir.NodeIndex,
    /// the `key` of the innermost other body of the same file that contains this one, or
    /// null when no collected body encloses it
    /// it is a view into the same file's own list, and it is what carries a renamed body's
    /// coverage up through the bodies that enclose it: a body nested inside another one is
    /// judged by the outer body's text as well, which is what the detector's own walk of the
    /// first copy's body finds when it descends into a nested declaration
    enclosing_body: ?[]const u8 = null,

    /// the collapsed body text alone, which is `key` without the name and its separator
    /// it is the renamed body rule's own key: a copy whose author changed the declaration's
    /// name keeps this text and loses the name the sibling body rule keys on
    pub fn bodyText(self: BodyFingerprint) []const u8 {
        return self.key[self.name.len + body_key_separator_length ..];
    }
};

/// how many distinct files of the run hold one fingerprint, and which file was counted last
/// the count is of files rather than sites: one file that writes the same body twice holds
/// one copy of the defect, and the detector's own test is `files.size >= 2`
/// the last-file
/// guard is what makes the count say so while the run walks one file's sites at a time,
/// which needs neither a per-file set nor a second pass over the run
pub const FingerprintFiles = struct {
    files: u32 = 0,
    last_file: u32 = std.math.maxInt(u32),
};

/// one statement literal a file offers to the run's statement index
pub const StatementSite = struct {
    /// the COOKED value with every run of whitespace folded to one space and both ends
    /// trimmed, which is the detector's own key: two copies that differ only in how they
    /// are wrapped, or only in the escapes they spell their whitespace with, are one
    /// statement
    key: []const u8,
    /// the line the literal starts on, which is where the detector reports
    line: u32,
};

/// one user-facing copy literal a file offers to the run's copy index
pub const CopySite = struct {
    /// the COOKED value with nothing folded, which is the detector's own key: it keys on
    /// `node.text` itself, so two copies that differ only in the whitespace they are
    /// written with are two sentences
    key: []const u8,
    /// the line the literal starts on, which is where the detector reports
    line: u32,
};

/// one computation expression a file offers to the run's computation index
pub const ComputationSite = struct {
    /// the expression's own text with every run of whitespace folded to one space and both
    /// ends trimmed, which is the detector's own key: two copies wrapped differently are one
    /// computation
    key: []const u8,
    /// the line the expression's leftmost token sits on, which is where the detector reports
    /// a front-end span begins each member and call of a chain at the token before it, so
    /// the node's own span starts lower down than the expression does
    line: u32,
    /// the key of the innermost collected function body around this site, or null when no
    /// collected body encloses it
    /// it is a view into the file's own `body_fingerprints`, which outlives the verdict that
    /// reads it, and it is what keeps this rule quiet where the sibling duplicate-body rule
    /// already reports the same line
    enclosing_body: ?[]const u8 = null,
    /// the node the expression is
    /// the key is text and the tree is gone by the time a verdict runs, and this is what tells
    /// a site that IS a body from a site inside one: an arrow's expression body is the
    /// expression itself, so `body` and the site are one node, which is a body no ancestor
    /// walk from the site can reach
    node: ir.NodeIndex,
};

/// one body text the run declares under more than one name, which is the blind spot of the
/// accepted body rule: that rule keys a declaration on its name beside its body, so a copy
/// whose author renamed the declaration is a different key and reports nothing there
pub const RenamedBody = struct {
    /// the distinct files that declare this body, which is the detector's own count of files
    /// rather than of declarations
    files: FingerprintFiles = .{},
    /// how many declarations write it, which is the detector's own site count and what the
    /// row's "declared {d} times" reads
    sites: u32 = 0,
    /// the first two distinct files that declare this body, in the order the run meets them
    /// the row names the first file other than the one it reports in, so the pair is kept
    /// rather than derived from a count: the file a report happens in can be the first one
    first_file: ?[]const u8 = null,
    second_file: ?[]const u8 = null,
    /// the distinct names the body is declared under, in the order the run meets them
    /// they are the index's own copies, because the merge frees a file's fingerprints as soon
    /// as its rows are reported while this group answers for every file after it
    names: std.ArrayListUnmanaged([]const u8) = .empty,
    /// whether the sibling computation rule already owns a defect inside this body, which is
    /// the detector's own suppression: two rules reporting one defect at one line is one
    /// finding too many, and the row that survives names the expression that actually moves
    covered: bool = false,
};

/// one string value an enum of a `.config.ts` file declares
pub const ConfigEnumValue = struct {
    /// the COOKED value the member assigns, which is what a consumer's own literal has to
    /// match
    value: []const u8,
    /// the member's name beside its enum's, as `EnumName.MemberName`, which is what a row
    /// names
    owner: []const u8,
};

/// one string literal of a file, which is what a config's values are compared against
pub const LiteralValue = struct {
    /// the COOKED value, because the detector compares two cooked literals
    value: []const u8,
    /// the line the literal starts on, which is where the detector reports
    line: u32,
};

/// the enum members that declare one config value, in the order the configs were read
pub const ConfigValueOwners = struct {
    owners: std.ArrayListUnmanaged([]const u8) = .empty,
};

/// one surface's config values, keyed by the value's cooked text
/// the surface is the config's own path minus `.config.ts`, which is a naming convention
/// rather than a directory: `afk.service.config.ts` declares the values of `afk.service.ts`
/// and of nothing else
pub const ConfigValues = std.StringHashMapUnmanaged(ConfigValueOwners);

/// the run's text fingerprints: what every file's declarations say, so a rule can ask
/// whether one implementation is written in two files
/// it is the run's rather than one file's, and it is built from every file's own
/// contribution before the first file's verdict, because the last file of the run can hold
/// the copy the first file's declaration duplicates
/// it is kept apart from `ProjectIndex` because the two cost very different amounts: the
/// graph's pass resolves every import and runs a component pass, while a fingerprint is the
/// collapsed text of a declaration, so a project that enables one of the two must not pay
/// for the other
pub const FingerprintIndex = struct {
    /// the index's own memory: every fingerprint outlives the file it was read from,
    /// because the last file's verdict needs the first file's
    arena: std.heap.ArenaAllocator,
    /// the distinct files that declare each function body, keyed by `name|body text`
    body_files: std.StringHashMapUnmanaged(FingerprintFiles) = .empty,
    /// how many times the run writes each statement, keyed by the collapsed cooked text
    /// the count is of OCCURRENCES rather than distinct files, because the detector's own
    /// test is `count >= 2` and two copies in one file are the whole defect, which is what
    /// makes this map its own rather than a `FingerprintFiles`
    statement_occurrences: std.StringHashMapUnmanaged(u32) = .empty,
    /// the distinct files that write each user-facing sentence, keyed by the cooked text
    /// the count is of files rather than occurrences, which is the detector's own test, so
    /// this family reads the same `FingerprintFiles` shape the body family does: one file
    /// that writes a sentence twice holds one copy of the defect
    copy_files: std.StringHashMapUnmanaged(FingerprintFiles) = .empty,
    /// the config values each surface declares, keyed by the surface and then by the value's
    /// cooked text
    /// the value key is the index's own copy of what a file declared, because the merge frees
    /// a file's declarations as soon as its rows are reported, while the surface key is a view
    /// into the run's own path list, which outlives the index
    config_values: std.StringHashMapUnmanaged(ConfigValues) = .empty,
    /// the distinct files that write each computation, keyed by the expression's collapsed
    /// text
    /// the count is of files rather than occurrences, which is the detector's own test, so
    /// this family reads the same `FingerprintFiles` shape the body family does: one file
    /// that writes the same expression twice holds one copy of the defect
    computation_files: std.StringHashMapUnmanaged(FingerprintFiles) = .empty,
    /// the bodies the run declares under more than one name, keyed by the collapsed body text
    /// alone
    /// the text is the key rather than `name|body`, because a renamed copy is exactly the
    /// case the name is not part of
    renamed_bodies: std.StringHashMapUnmanaged(RenamedBody) = .empty,

    pub fn deinit(self: *FingerprintIndex) void {
        self.arena.deinit();
    }
};

/// the run's fingerprints, as one file sees it: the count of files that hold each
/// fingerprint, and the contributing file's own sites
/// the sites come with it because the
/// rows to report and the lines to report them at are the file's rather than the run's
pub const FingerprintVerdict = *const fn (
    allocator: std.mem.Allocator,
    index: *const FingerprintIndex,
    project: *const Project,
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
    /// the distinct names this file's code spells, whatever it spells them for.
    /// a name is here once however often the file writes it, because the run's
    /// question is which files know a name rather than how often one does
    mentions: std.StringHashMapUnmanaged(void) = .empty,
    /// every function body this file offers to the run's fingerprint index, in the order
    /// the declarations appear, which is the order the rows are reported in
    body_fingerprints: std.ArrayList(BodyFingerprint) = .empty,
    /// every statement literal this file offers to the run's statement index, in the order
    /// the literals appear, which is the order the rows are reported in
    statement_sites: std.ArrayList(StatementSite) = .empty,
    /// every user-facing copy literal this file offers to the run's copy index, in the order
    /// the literals appear, which is the order the rows are reported in
    copy_sites: std.ArrayList(CopySite) = .empty,
    /// every string value an enum of this file declares, which is empty unless the file is a
    /// `.config.ts`
    config_values: std.ArrayList(ConfigEnumValue) = .empty,
    /// every string literal this file holds, in the order the literals appear, which is the
    /// order its rows are reported in
    literal_values: std.ArrayList(LiteralValue) = .empty,
    /// every computation expression this file offers to the run's computation index, in the
    /// order the expressions appear, which is the order the rows are reported in
    computation_sites: std.ArrayList(ComputationSite) = .empty,
    /// the entries this file would hand to its surface's `.config.ts`: the members of the
    /// enums it declares and the string literals it writes outside them
    /// it travels with the copy sites, which is the gate that collects it, because the copy
    /// rule is its only reader
    config_weight: u32 = 0,
    /// whether the run holds this file's own `.config.ts`, which is what makes a config the
    /// right destination for the file's vocabulary whatever that vocabulary weighs
    config_sibling_exists: bool = false,

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
        var names = self.mentions.keyIterator();
        while (names.next()) |name| allocator.free(name.*);
        self.mentions.deinit(allocator);
        for (self.body_fingerprints.items) |fingerprint| allocator.free(fingerprint.key);
        self.body_fingerprints.deinit(allocator);
        for (self.statement_sites.items) |site| allocator.free(site.key);
        self.statement_sites.deinit(allocator);
        for (self.copy_sites.items) |site| allocator.free(site.key);
        self.copy_sites.deinit(allocator);
        for (self.config_values.items) |declared| {
            allocator.free(declared.value);
            allocator.free(declared.owner);
        }
        self.config_values.deinit(allocator);
        for (self.literal_values.items) |literal| allocator.free(literal.value);
        self.literal_values.deinit(allocator);
        for (self.computation_sites.items) |site| allocator.free(site.key);
        self.computation_sites.deinit(allocator);
    }
};

pub const Rule = struct {
    /// the name a config turns this rule on or off with, so the key a user types
    /// is the table's own declaration rather than a spelling in the docs or the
    /// schema beside it
    /// `architecture.schema.json` lists every one of these, and the test below
    /// keeps the two from drifting
    name: []const u8,
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
    /// this rule's verdict needs the run's function-body fingerprints, so the engine
    /// collects every declaration's body text as it reads each file and the merge builds
    /// the index before any verdict
    /// the collection copies text rather than the graph's names, which is an order of
    /// magnitude more of it, so the families are gated apart from `needs_project_index`: a
    /// project that enables only one family pays only for it
    needs_body_fingerprints: bool = false,
    /// this rule's verdict needs every statement literal the run holds, so the engine
    /// collects them as it reads each file and the merge counts them before any verdict
    /// it is a family of its own beside `needs_body_fingerprints` rather than a share of
    /// it, because the two read the same run for different text and a project that enables
    /// only one of them must not pay for the other's walk
    needs_statement_text: bool = false,
    /// this rule's verdict needs every user-facing copy literal the run holds, so the engine
    /// collects them as it reads each file and the merge counts the files that write each
    /// sentence before any verdict
    /// it is a family of its own for the same reason the statement's is
    needs_copy_owners: bool = false,
    /// this rule's verdict needs every config file's declared values and every file's own
    /// string literals, so the engine collects both as it reads each file
    /// it is a family of its own for the same reason the others are
    needs_config_values: bool = false,
    /// this rule's verdict needs every computation expression the run holds, so the engine
    /// collects them as it reads each file and the merge counts the files that write each
    /// one before any verdict
    /// it is a family of its own for the same reason the others are
    needs_computation_sites: bool = false,
    /// this rule's verdict needs the run's bodies grouped by their text alone, so the merge
    /// builds that grouping and the coverage test beside it before any verdict
    /// the bodies themselves come from `needs_body_fingerprints`, which this rule declares as
    /// well: the grouping is a reading of the same collection rather than a second one, and a
    /// project that enables only the sibling body rule never pays for it
    needs_renamed_bodies: bool = false,
    /// the verdict this rule reaches over the run's fingerprints
    /// its table entry must
    /// declare a family flag, or the collection it reads was never made
    resolve_fingerprints: ?FingerprintVerdict = null,
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

/// the rules added from the rule research (the catalogue at commit 4a390e5).
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
pub const export_without_consumer = "`{s}` is exported but no other module names it. Drop the `export` keyword, or have another module name it.";
pub const duplicated_function_body = "`{s}` has a byte-identical body in another file. Lift the implementation into one shared declaration and import it from both call sites.";
pub const duplicated_statement_text = "This statement is written more than once in the run. Declare it once as a module-level constant, or as one exported helper both call sites call.";
pub const duplicated_user_facing_copy = "This sentence is written in three or more files. Declare it once in the owning surface's `.config.ts` and import it, or lift it to the shared module when several surfaces need it.";
pub const repeated_inline_copy = "This sentence is written more than once in this file. Declare it once as a module-level constant, or as an entry in the owning `.config.ts`, and name it at both sites.";

/// the two copy rules name the surface's `.config.ts` as the destination, and a config the
/// file would fill with three entries is no destination at all. these are the messages those
/// rules carry when the file's own vocabulary does not earn one and the surface holds no
/// config beside it
///
/// the finding itself is unchanged: the sentence is still written more than once, so the row
/// stays and only the place the reader is sent changes, which is why these repeat the opening
/// sentence rather than reword it
pub const duplicated_user_facing_copy_without_config = "This sentence is written in three or more files. Declare it once as a named constant the other files import, or lift it to the shared module when several surfaces need it.";
pub const repeated_inline_copy_without_config = "This sentence is written more than once in this file. Declare it once as a module-level constant and name it at both sites.";
pub const literal_duplicating_config_value = "This literal duplicates `{s}`, which the surface's own `.config.ts` already declares. Reference the enum member instead.";
pub const duplicated_computation = "This computation `{s}` is written in {d} other file{s}. Extract it into a shared function both call sites import.";
pub const renamed_duplicate_body = "`{s}` is a byte-identical body, also declared {d} times across {d} files as {s}, for example {s}. Lift the implementation into one shared declaration and import it from both call sites.";

/// the shortest cooked copy the duplicate-copy rule counts, in UTF-16 code units, which is
/// what a JavaScript string's own `length` reads. it is the detector's own gate, and the
/// collection is the only place that reads it: a sentence under it never reaches the index
pub const minimum_duplicated_copy_length: u32 = 24;

/// the shortest collapsed body text the duplicate-body rule counts, which is the detector's
/// own gate
/// the collection and the verdict read the same number, because a body the
/// collection skipped is not a group any verdict can find
pub const minimum_body_length: u32 = 30;

/// the fewest TypeScript descendants a computation must have to be a site, which is the
/// detector's own gate (`MINIMUM_NODES = 7`)
/// the count is what `Module.descendantsOf` reports, so this constant is the one place the
/// rule and the counter have to agree
pub const minimum_computation_nodes: u32 = 7;

/// the fewest distinct files that must hold one fingerprint for a duplicate to be a defect
/// it is every detector's own `files.size >= 2` test, and the two places that read it here are
/// the renamed body rule's verdict and the coverage test the merge runs against it
pub const minimum_duplicate_files: u32 = 2;

/// the fewest distinct names one body text must be declared under for the copies to be
/// renamed ones
/// the sibling body rule owns a group whose declarations all keep one name, so this gate is
/// what tells the two rules apart rather than a second opinion on the same defect
pub const minimum_renamed_body_names: u32 = 2;

/// the suffix of a smoke module
/// it is out of scope to both rules whose detector skips one: the computation rule excludes
/// it once, at collection, because its sites serve the run's index and its own rows alike,
/// while the renamed body rule excludes it at both ends, because the bodies it groups are the
/// ones the sibling body rule reads, and that rule reads a smoke module like any other
pub const smoke_module_suffix = ".smoke.ts";

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
        .name = "em-dash",
        .layer = .cosmetic,
        .severity = .err,
        .message = em_dash,
        .match = cosmetic.checkEmDash,
    },
    .{
        .name = "null-literal",
        .layer = .resilience,
        .severity = .err,
        .message = null_literal,
        .match = resilience.checkNullLiteral,
    },
    .{
        .name = "let-declaration",
        .layer = .resilience,
        .severity = .err,
        .message = let_decl,
        .syntax = .ir,
        .match = resilience.checkLetDeclaration,
    },
    .{
        .name = "switch-statement",
        .layer = .resilience,
        .severity = .err,
        .message = switch_stmt,
        .syntax = .ir,
        .match = resilience.checkSwitchStatement,
    },
    .{
        .name = "imperative-for-loop",
        .layer = .resilience,
        .severity = .err,
        .message = imperative_for,
        .syntax = .ir,
        .match = resilience.checkImperativeFor,
    },
    .{
        .name = "loose-equality",
        .layer = .resilience,
        .severity = .err,
        .message = double_equals,
        .match = resilience.checkDoubleEquals,
    },
    .{
        .name = "as-any",
        .layer = .resilience,
        .severity = .err,
        .message = as_any,
        .match = resilience.checkAsAny,
    },
    .{
        .name = "any-type",
        .layer = .resilience,
        .severity = .err,
        .message = any_type,
        .oracle = false,
        .match = resilience.checkAnyType,
    },
    .{
        .name = "chained-cast",
        .layer = .resilience,
        .severity = .err,
        .message = chained_cast,
        .match = resilience.checkChainedCast,
    },
    .{
        .name = "proxy-reexport",
        .layer = .resilience,
        .severity = .err,
        .message = reexport,
        .match = resilience.checkReexport,
    },
    .{
        .name = "as-const",
        .layer = .resilience,
        .severity = .err,
        .message = as_const,
        .match = resilience.checkAsConst,
    },
    .{
        .name = "throw-statement",
        .layer = .behavioural,
        .severity = .err,
        .message = throw_stmt,
        .match = behavioural.checkThrow,
    },
    .{
        .name = "bare-catch",
        .layer = .behavioural,
        .severity = .err,
        .message = bare_catch,
        .match = behavioural.checkBareCatch,
    },
    .{
        .name = "silent-catch",
        .layer = .behavioural,
        .severity = .warn,
        .message = silent_catch,
        .match = behavioural.checkSilentCatch,
    },
    .{
        .name = "max-nesting-depth",
        .layer = .resilience,
        .severity = .warn,
        .message = max_nesting_depth,
        .syntax = .ir,
        .oracle = false,
        .match = complexity.checkMaxNestingDepth,
    },
    .{
        .name = "max-parameters",
        .layer = .resilience,
        .severity = .warn,
        .message = max_parameters,
        .syntax = .ir,
        .oracle = false,
        .match = complexity.checkMaxParameters,
    },
    .{
        .name = "lowercase-copy",
        .layer = .cosmetic,
        .severity = .warn,
        .message = lowercase_copy,
        .oracle = false,
        .match = cosmetic.checkLowercaseCopy,
    },
    .{
        .name = "boolean-flag-argument",
        .layer = .resilience,
        .severity = .warn,
        .message = boolean_flag_argument,
        .syntax = .ir,
        .oracle = false,
        .match = resilience.checkBooleanFlagArgument,
    },
    .{
        .name = "max-function-lines",
        .layer = .resilience,
        .severity = .warn,
        .message = max_function_lines,
        .syntax = .ir,
        .oracle = false,
        .match = complexity.checkMaxFunctionLines,
    },
    .{
        .name = "nested-ternary",
        .layer = .resilience,
        .severity = .warn,
        .message = nested_ternary,
        .syntax = .ir,
        .oracle = false,
        .match = complexity.checkNestedTernary,
    },
    .{
        .name = "max-file-lines",
        .layer = .resilience,
        .severity = .warn,
        .message = max_file_lines,
        .oracle = false,
        .match = complexity.checkMaxFileLines,
    },
    .{
        .name = "await-in-loop",
        .layer = .behavioural,
        .severity = .warn,
        .message = await_in_loop,
        .syntax = .ir,
        .oracle = false,
        .match = behavioural.checkAwaitInLoop,
    },
    .{
        .name = "max-cyclomatic-complexity",
        .layer = .resilience,
        .severity = .warn,
        .message = max_cyclomatic_complexity,
        .syntax = .ir,
        .oracle = false,
        .match = complexity.checkMaxCyclomaticComplexity,
    },
    .{
        .name = "unbounded-collection-read",
        .layer = .resilience,
        .severity = .warn,
        .message = unbounded_collection_read,
        .syntax = .ir,
        .oracle = false,
        .match = resilience.checkUnboundedCollectionRead,
    },
    .{
        .name = "for-of-accumulation",
        .layer = .resilience,
        .severity = .err,
        .message = for_of_accumulation,
        .syntax = .ir,
        .oracle = false,
        .match = resilience.checkForOfAccumulation,
    },
    .{
        .name = "config-behaviour",
        .layer = .structural,
        .severity = .warn,
        .message = config_behaviour,
        .syntax = .ir,
        .oracle = false,
        .match = structural.checkConfigBehaviour,
    },
    .{
        .name = "if-chain-dispatch",
        .layer = .resilience,
        .severity = .warn,
        .message = if_chain_dispatch,
        .syntax = .ir,
        .oracle = false,
        .match = resilience.checkIfChainDispatch,
    },
    .{
        .name = "literal-union-enum",
        .layer = .resilience,
        .severity = .warn,
        .message = literal_union_enum,
        .syntax = .ir,
        .oracle = false,
        .match = resilience.checkLiteralUnionEnum,
    },
    .{
        .name = "optional-property",
        .layer = .resilience,
        .severity = .warn,
        .message = optional_property,
        .syntax = .ir,
        .oracle = false,
        .match = resilience.checkOptionalProperties,
    },
    .{
        .name = "readonly-collection-signature",
        .layer = .resilience,
        .severity = .warn,
        .message = readonly_collection_signature,
        .syntax = .ir,
        .oracle = false,
        .match = resilience.checkReadonlyCollectionSignatures,
    },
    .{
        .name = "readonly-type-member",
        .layer = .resilience,
        .severity = .warn,
        .message = readonly_type_member,
        .syntax = .ir,
        .oracle = false,
        .match = resilience.checkReadonlyTypeMembers,
    },
    .{
        .name = "scalar-failure-return",
        .layer = .resilience,
        .severity = .warn,
        .message = scalar_failure_return,
        .syntax = .ir,
        .oracle = false,
        .match = resilience.checkScalarFailureReturn,
    },
    .{
        .name = "discarded-outcome",
        .layer = .behavioural,
        .severity = .warn,
        .message = discarded_outcome,
        .syntax = .ir,
        .oracle = false,
        .needs_project = true,
        .match = behavioural.checkDiscardedOutcome,
    },
    .{
        .name = "unread-scalar-result",
        .layer = .behavioural,
        .severity = .warn,
        .message = unread_scalar_result,
        .syntax = .ir,
        .oracle = false,
        .needs_project = true,
        .match = behavioural.checkUnreadScalarResult,
    },
    .{
        .name = "enum-placement",
        .layer = .structural,
        .severity = .warn,
        .message = enum_placement,
        .syntax = .ir,
        .oracle = false,
        .match = structural.checkEnumPlacement,
    },
    .{
        .name = "import-cycle",
        .layer = .structural,
        .severity = .err,
        .message = import_cycle,
        .syntax = .ir,
        .oracle = false,
        .needs_project_index = true,
        .resolve_index = structural.resolveImportCycle,
    },
    .{
        .name = "redundant-allowed-import",
        .layer = .structural,
        .severity = .warn,
        .message = redundant_allowed_import,
        .oracle = false,
        .match = structural.checkRedundantAllowedImport,
    },
    .{
        .name = "shared-type-placement",
        .layer = .structural,
        .severity = .warn,
        .message = shared_type_placement,
        .syntax = .ir,
        .oracle = false,
        .needs_project_index = true,
        .resolve_index = structural.checkSharedTypePlacement,
    },
    .{
        .name = "export-without-consumer",
        .layer = .structural,
        .severity = .warn,
        .message = export_without_consumer,
        .syntax = .ir,
        .oracle = false,
        .needs_project_index = true,
        .resolve_index = structural.checkExportWithoutConsumer,
    },
    .{
        .name = "duplicated-function-body",
        .layer = .resilience,
        .severity = .warn,
        .message = duplicated_function_body,
        .syntax = .ir,
        .oracle = false,
        .needs_body_fingerprints = true,
        .resolve_fingerprints = resilience.checkDuplicatedFunctionBody,
    },
    .{
        .name = "duplicated-statement-text",
        .layer = .resilience,
        .severity = .warn,
        .message = duplicated_statement_text,
        .syntax = .ir,
        .oracle = false,
        .needs_statement_text = true,
        .resolve_fingerprints = resilience.checkDuplicatedStatementText,
    },
    .{
        .name = "duplicated-user-facing-copy",
        .layer = .cosmetic,
        .severity = .warn,
        .message = duplicated_user_facing_copy,
        .syntax = .ir,
        .oracle = false,
        .needs_copy_owners = true,
        .resolve_fingerprints = cosmetic.checkDuplicatedUserFacingCopy,
    },
    .{
        .name = "repeated-inline-copy",
        .layer = .cosmetic,
        .severity = .warn,
        .message = repeated_inline_copy,
        .syntax = .ir,
        .oracle = false,
        .match = cosmetic.checkRepeatedInlineCopy,
    },
    .{
        .name = "literal-duplicating-config-value",
        .layer = .cosmetic,
        .severity = .warn,
        .message = literal_duplicating_config_value,
        .syntax = .ir,
        .oracle = false,
        .needs_config_values = true,
        .resolve_fingerprints = cosmetic.checkLiteralDuplicatingConfigValue,
    },
    .{
        .name = "duplicated-computation",
        .layer = .resilience,
        .severity = .warn,
        .message = duplicated_computation,
        .syntax = .ir,
        .oracle = false,
        .needs_computation_sites = true,
        .resolve_fingerprints = resilience.checkDuplicatedComputation,
    },
    .{
        .name = "renamed-duplicate-body",
        .layer = .resilience,
        .severity = .warn,
        .message = renamed_duplicate_body,
        .syntax = .ir,
        .oracle = false,
        .needs_body_fingerprints = true,
        .needs_renamed_bodies = true,
        .resolve_fingerprints = resilience.checkRenamedDuplicateBody,
    },
    .{
        .name = "unused-import",
        .layer = .hygiene,
        .severity = .warn,
        .message = unused_import,
        .syntax = .ir,
        .match = hygiene.checkUnusedImports,
    },
    .{
        .name = "unused-variable",
        .layer = .hygiene,
        .severity = .warn,
        .message = unused_variable,
        .syntax = .ir,
        .match = hygiene.checkUnusedVariables,
    },
    .{
        .name = "prefer-const",
        .layer = .hygiene,
        .severity = .warn,
        .message = use_const,
        .syntax = .ir,
        .match = hygiene.checkUseConst,
    },
    .{
        .name = "constant-condition",
        .layer = .hygiene,
        .severity = .err,
        .message = constant_condition,
        .syntax = .ir,
        .match = hygiene.checkConstantCondition,
    },
    .{
        .name = "unreachable-code",
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
    for (&all, 0..) |*rule, rule_index| {
        if (rule.syntax != .ir) continue;
        if (rule.layer == .hygiene and !with_hygiene) continue;
        if (enabled(cfg, rule_index)) return true;
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
    for (&all, 0..) |*rule, rule_index| {
        if (!rule.needs_project) continue;
        if (rule.layer == .hygiene and !with_hygiene) continue;
        if (enabled(cfg, rule_index)) return true;
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
    for (&all, 0..) |*rule, rule_index| {
        if (!rule.needs_project_index) continue;
        if (rule.layer == .hygiene and !with_hygiene) continue;
        if (enabled(cfg, rule_index)) return true;
    }
    return false;
}

/// whether an enabled rule reads a family of the run's fingerprints, so the merge knows
/// whether to build the fingerprint index
pub fn needsFingerprints(cfg: *const config.Config, with_hygiene: bool) bool {
    for (&all, 0..) |*rule, rule_index| {
        if (!declaresFingerprintFamily(rule.*)) continue;
        if (rule.layer == .hygiene and !with_hygiene) continue;
        if (enabled(cfg, rule_index)) return true;
    }
    return false;
}

/// whether an enabled rule needs every file's function bodies, so the engine knows whether
/// to collect them as it reads each file
/// it is separate from `needsFingerprints` because the families are collected apart: a
/// project that enables only the statement or the copy rules builds the index without ever
/// walking a body
pub fn needsBodyFingerprints(cfg: *const config.Config, with_hygiene: bool) bool {
    for (&all, 0..) |*rule, rule_index| {
        if (!rule.needs_body_fingerprints) continue;
        if (rule.layer == .hygiene and !with_hygiene) continue;
        if (enabled(cfg, rule_index)) return true;
    }
    return false;
}

/// whether an enabled rule needs every statement literal of the run, so the engine knows
/// whether to collect them as it reads each file
/// it is separate from `needsFingerprints` because the families are collected apart, and
/// separate from `needsBodyFingerprints` because the statement sites come off the token
/// stream rather than out of a parsed body, which is the cheap half of the two
pub fn needsStatementText(cfg: *const config.Config, with_hygiene: bool) bool {
    for (&all, 0..) |*rule, rule_index| {
        if (!rule.needs_statement_text) continue;
        if (rule.layer == .hygiene and !with_hygiene) continue;
        if (enabled(cfg, rule_index)) return true;
    }
    return false;
}

/// whether an enabled rule needs every user-facing copy literal of the run, so the engine
/// knows whether to collect them as it reads each file
pub fn needsCopyOwners(cfg: *const config.Config, with_hygiene: bool) bool {
    for (&all, 0..) |*rule, rule_index| {
        if (!rule.needs_copy_owners) continue;
        if (rule.layer == .hygiene and !with_hygiene) continue;
        if (enabled(cfg, rule_index)) return true;
    }
    return false;
}

/// whether an enabled rule needs the run's config values and the literals that might retype
/// them, so the engine knows whether to collect both as it reads each file
pub fn needsConfigValues(cfg: *const config.Config, with_hygiene: bool) bool {
    for (&all, 0..) |*rule, rule_index| {
        if (!rule.needs_config_values) continue;
        if (rule.layer == .hygiene and !with_hygiene) continue;
        if (enabled(cfg, rule_index)) return true;
    }
    return false;
}

/// whether an enabled rule needs every computation expression of the run, so the engine
/// knows whether to collect them as it reads each file
pub fn needsComputationSites(cfg: *const config.Config, with_hygiene: bool) bool {
    for (&all, 0..) |*rule, rule_index| {
        if (!rule.needs_computation_sites) continue;
        if (rule.layer == .hygiene and !with_hygiene) continue;
        if (enabled(cfg, rule_index)) return true;
    }
    return false;
}

/// whether an enabled rule needs the run's bodies grouped by their text alone, so the merge
/// knows whether to build that grouping
/// it is separate from `needsBodyFingerprints` because the two are different readings of one
/// collection: the grouping copies the body text of every declaration, and a project that
/// enables only the sibling body rule never pays for that walk
pub fn needsRenamedBodies(cfg: *const config.Config, with_hygiene: bool) bool {
    for (&all, 0..) |*rule, rule_index| {
        if (!rule.needs_renamed_bodies) continue;
        if (rule.layer == .hygiene and !with_hygiene) continue;
        if (enabled(cfg, rule_index)) return true;
    }
    return false;
}

/// whether a rule reads a family of the run's fingerprints
/// the families are ported one at a time, and this is the one place a new one is declared:
/// a family that is not named here never reaches its verdict
fn declaresFingerprintFamily(rule: Rule) bool {
    return rule.needs_body_fingerprints or rule.needs_statement_text or rule.needs_copy_owners or rule.needs_config_values or rule.needs_computation_sites or rule.needs_renamed_bodies;
}

comptime {
    @setEvalBranchQuota(20_000);
    // the table is the one place a rule is declared, so the config keys are checked
    // where they are written: a duplicate name would make one rule unreachable by
    // name, a name that is not kebab case would not autocomplete from the schema
    // as it is spelled here, and a table wider than the config's mask would drop
    // a toggle in silence
    if (all.len > config.rule_mask_capacity) @compileError("the rule table is wider than the config's toggle mask");
    for (all, 0..) |rule, rule_index| {
        if (rule.name.len == 0) @compileError("a rule needs a name, because that is the key a config turns it off with");
        for (rule.name) |character| {
            const is_kebab_character = (character >= 'a' and character <= 'z') or character == '-';
            if (!is_kebab_character) @compileError("a rule name is lower case letters and dashes");
        }
        for (all[rule_index + 1 ..]) |other| {
            if (std.mem.eql(u8, rule.name, other.name)) @compileError("two rules share a name, so one of them is unreachable by name");
        }
    }
}

/// the index of the rule a config names, or null when the table has no such rule
fn ruleIndexNamed(name: []const u8) ?usize {
    for (&all, 0..) |*rule, rule_index| {
        if (std.mem.eql(u8, rule.name, name)) return rule_index;
    }
    return null;
}

/// turn the config's named toggles into the mask the scan reads, once per run
///
/// returns the first name the table does not have, or null when every name
/// resolved. a name that matches nothing is a typo that would leave the rule it
/// meant to silence running, so it is the caller's to report rather than a silent
/// no-op
pub fn resolveToggles(cfg: *config.Config) ?[]const u8 {
    // the mask is derived state rather than a second source of truth, so the
    // resolver owns it whole: a config that reached it some other way keeps only
    // the bits the names here set
    cfg.disabledRules = config.DisabledRules.empty;
    for (cfg.rules.entries) |toggle| {
        const rule_index = ruleIndexNamed(toggle.name) orelse return toggle.name;
        if (toggle.enabled) {
            cfg.disabledRules.unset(rule_index);
        } else {
            cfg.disabledRules.set(rule_index);
        }
    }
    return null;
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
    for (&all, 0..) |*rule, rule_index| {
        if (!rule.needs_project_index) continue;
        const verdict = rule.resolve_index orelse continue;
        if (rule.layer == .hygiene and !with_hygiene) continue;
        if (!enabled(cfg, rule_index)) continue;
        try verdict(allocator, graph, file, path, rule, findings);
    }
}

/// reach every enabled fingerprint rule's verdict for one file of the run
/// the merge builds the run's fingerprints once and calls this as it walks the files, so a
/// rule's own resolver decides only what that file's row is, and the layer, the severity
/// and the message come off the table entry the resolver is handed
pub fn resolveFingerprints(
    allocator: std.mem.Allocator,
    index: *const FingerprintIndex,
    project: *const Project,
    path: []const u8,
    cfg: *const config.Config,
    with_hygiene: bool,
    findings: *std.ArrayList(Finding),
) std.mem.Allocator.Error!void {
    for (&all, 0..) |*rule, rule_index| {
        const verdict = rule.resolve_fingerprints orelse continue;
        if (rule.layer == .hygiene and !with_hygiene) continue;
        if (!enabled(cfg, rule_index)) continue;
        try verdict(allocator, index, project, path, rule, findings);
    }
}

/// whether the config runs a layer. the four layer toggles carry one layer each,
/// and the hygiene layer is on wherever the caller asked for hygiene at all
fn layerEnabled(cfg: *const config.Config, layer: Layer) bool {
    return switch (layer) {
        .cosmetic => cfg.layers.cosmetic,
        .structural => cfg.layers.structural,
        .resilience => cfg.layers.resilience,
        .behavioural => cfg.layers.behavioural,
        .hygiene => true,
    };
}

/// whether the config runs the rule at `rule_index` of the table: its layer must
/// be on, and the config must not have named it off
///
/// the index is the table's own order, which is what `resolveToggles` writes into
/// the mask, so this is a shift and a test rather than a lookup by name on the
/// path every file walks 50 times
pub fn enabled(cfg: *const config.Config, rule_index: usize) bool {
    if (!layerEnabled(cfg, all[rule_index].layer)) return false;
    return !cfg.disabledRules.isSet(rule_index);
}

/// run every enabled rule over one file, in table order
///
/// the context is copied per rule so the rule's own table entry travels with the
/// dispatch: `Context.deferToProject` reads the layer, the severity and the
/// message from it rather than from the rule's own restatement of them
pub fn run(context: *const Context) !void {
    for (&all, 0..) |*rule, rule_index| {
        if (rule.layer == .hygiene and !context.hygiene) continue;
        if (!enabled(context.cfg, rule_index)) continue;
        if (rule.syntax == .ir and context.module == null) continue;
        const matcher = rule.match orelse continue;

        var dispatched = context.*;
        // the entry's address, so the context the matcher is handed names the
        // table row the engine resolved rather than a copy of it
        dispatched.rule = rule;
        try matcher(&dispatched);
    }
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

// the flags a rule can reach its verdict through are not independent, and the table is
// where a mistake in them is silent: a rule with no verdict reports nothing for the whole
// run, a rule that drives a pass without a verdict pays for the pass and reports nothing,
// and a rule with a verdict but no flag never reads the index it needs
test "every rule has a verdict, and the index flags and the index verdicts agree" {
    for (all) |rule| {
        try testing.expect(rule.match != null or rule.resolve_index != null or rule.resolve_fingerprints != null);
        try testing.expect(rule.needs_project_index == (rule.resolve_index != null));
        try testing.expect(declaresFingerprintFamily(rule) == (rule.resolve_fingerprints != null));
    }
}

/// the two toggles a config test hands a config that names rules, one that
/// silences a rule and one that names a rule the table does not have
fn testToggles(allocator: std.mem.Allocator, names: []const []const u8) ![]config.RuleToggle {
    const entries = try allocator.alloc(config.RuleToggle, names.len);
    for (names, 0..) |name, entry_index| {
        // every other name is turned on, so the resolver is seen to reach the
        // dropped rule in front of it
        entries[entry_index] = .{ .name = try allocator.dupe(u8, name), .enabled = entry_index % 2 == 1 };
    }
    return entries;
}

// the config names rules, the table holds indices, and the one place the two meet
// is the resolver, so this is where a name that matches nothing has to surface

test "resolveToggles maps the names a config carries onto the table, and reports a name it has no rule for" {
    const allocator = testing.allocator;

    var cfg = config.Config{
        .surfaces = &.{},
        .layers = .{ .cosmetic = true, .structural = true, .resilience = true, .behavioural = true },
        .rules = .{ .entries = try testToggles(allocator, &.{ "em-dash", "switch-statement" }) },
    };
    defer cfg.deinit(allocator);
    var unknown_cfg = config.Config{
        .surfaces = &.{},
        .layers = .{ .cosmetic = true, .structural = true, .resilience = true, .behavioural = true },
        .rules = .{ .entries = try testToggles(allocator, &.{"em-dashes"}) },
    };
    defer unknown_cfg.deinit(allocator);

    const em_dash_index = ruleIndexNamed("em-dash").?;
    const switch_index = ruleIndexNamed("switch-statement").?;

    // a config that names rules still runs them until the names are resolved
    try testing.expect(enabled(&cfg, em_dash_index));

    try testing.expect(resolveToggles(&cfg) == null);
    try testing.expect(!enabled(&cfg, em_dash_index));
    // the second name is spelled on, which clears a bit rather than setting one
    try testing.expect(enabled(&cfg, switch_index));
    // and the rule the config never named keeps running
    try testing.expect(enabled(&cfg, ruleIndexNamed("null-literal").?));

    // a name the table does not have is handed back rather than resolved to
    // nothing, because the rule it meant to silence would keep reporting
    try testing.expectEqualStrings("em-dashes", resolveToggles(&unknown_cfg).?);
    try testing.expect(enabled(&unknown_cfg, em_dash_index));
}

// the layer toggle and the rule toggle have to compose: a rule named off inside a
// layer that is off stays off either way, and a rule named off inside a layer that
// is on is the case the config exists for

test "a rule named off stops reporting while the rules beside it keep reporting" {
    const allocator = testing.allocator;
    const source = "const title = \"a \u{2014} b\";\n";

    var line: u32 = 1;
    const tokens = try ts.tokenize(allocator, source, &line);
    defer allocator.free(tokens);

    var off_cfg = config.Config{
        .surfaces = &.{},
        .layers = .{ .cosmetic = true, .structural = true, .resilience = true, .behavioural = true },
        .rules = .{ .entries = try testToggles(allocator, &.{"em-dash"}) },
    };
    defer off_cfg.deinit(allocator);
    try testing.expect(resolveToggles(&off_cfg) == null);

    const on_cfg = config.Config{
        .surfaces = &.{},
        .layers = .{ .cosmetic = true, .structural = true, .resilience = true, .behavioural = true },
    };

    var turned_off: std.ArrayList(Finding) = .empty;
    defer {
        for (turned_off.items) |finding| {
            allocator.free(finding.path);
            allocator.free(finding.message);
        }
        turned_off.deinit(allocator);
    }
    var turned_on: std.ArrayList(Finding) = .empty;
    defer {
        for (turned_on.items) |finding| {
            allocator.free(finding.path);
            allocator.free(finding.message);
        }
        turned_on.deinit(allocator);
    }

    const path = "src/a.util.ts";
    try run(&Context{ .allocator = allocator, .cfg = &off_cfg, .findings = &turned_off, .path = path, .source = source, .tokens = tokens, .module = null, .hygiene = false });
    try testing.expectEqual(@as(usize, 0), turned_off.items.len);

    try run(&Context{ .allocator = allocator, .cfg = &on_cfg, .findings = &turned_on, .path = path, .source = source, .tokens = tokens, .module = null, .hygiene = false });
    try testing.expectEqual(@as(usize, 1), turned_on.items.len);
    try testing.expectEqualStrings(em_dash, turned_on.items[0].message);
}

// the schema beside the tool is what a user's editor autocompletes a rule name
// from, so a rule it does not list is a name nobody can find and a name it lists
// that the table dropped is one no config can use

test "the schema names every rule in the table, and no rule the table does not have" {
    const allocator = testing.allocator;
    // the schema the binary embeds and ships is the one beside this file, which is
    // the one a project's editor autocompletes a rule name from
    const schema_source = @embedFile("architecture.schema.json");

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, schema_source, .{});
    defer parsed.deinit();

    const section = parsed.value.object.get("properties").?.object.get("rules").?.object;
    // a key the table does not have would autocomplete a name the run then rejects
    try testing.expect(!section.get("additionalProperties").?.bool);
    const listed = section.get("properties").?.object;

    var matched: usize = 0;
    for (all) |rule| {
        const entry = listed.get(rule.name) orelse continue;
        try testing.expectEqualStrings("boolean", entry.object.get("type").?.string);
        try testing.expect(entry.object.get("default").?.bool);
        try testing.expect(entry.object.get("description").?.string.len > 0);
        matched += 1;
    }
    try testing.expectEqual(all.len, matched);
    try testing.expectEqual(all.len, listed.count());
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
