/// the committed fixtures the corpus gates read
///
/// the parser gate in `src/lang/ts.zig` and the rule differential in
/// `src/rules/parity.zig` both walk this tree, so naming it once is what keeps
/// them from drifting onto different fixtures. every file is in the repository,
/// which is what makes `zig build test` answer the same on every machine: the
/// differential used to read a gitignored list of live checkouts, so the gate
/// was green in CI only because the list was absent and green locally only while
/// whoever ran it happened to have the same trees
pub const root = "tests/lint-corpus";
