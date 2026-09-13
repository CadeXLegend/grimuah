const std = @import("std");

/// the file-name predicates the rules that judge a module by its name share
///
/// grimuah names a module for what it is: a surface module is
/// `<name>.<kind>.ts`, an innate member is `<name>.<member>.ts`, and a module at
/// the top of the tree is the shared root library or a process entry point
/// rather than a surface's own code. three rules read those names today and the
/// placement group adds more, so the predicates live here rather than once per
/// rule file

/// the last `/`-separated segment of a root-relative path
pub fn fileNameOf(path: []const u8) []const u8 {
    return if (std.mem.lastIndexOfScalar(u8, path, '/')) |separator| path[separator + 1 ..] else path;
}

/// the file name without its final extension, so `a.repo.ts` is `a.repo`
pub fn stemOf(file_name: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, file_name, '.') orelse return file_name;
    return file_name[0..dot];
}

/// how many `.`-separated parts the stem has: 2 for `a.repo.ts`, 1 for `a.ts`
pub fn stemPartCount(file_name: []const u8) usize {
    return 1 + std.mem.count(u8, stemOf(file_name), ".");
}

/// the last part of the stem: `kind` for `a.kind.ts`, `a` for `a.ts`
pub fn stemLastOf(file_name: []const u8) []const u8 {
    const stem = stemOf(file_name);
    const dot = std.mem.lastIndexOfScalar(u8, stem, '.') orelse return stem;
    return stem[dot + 1 ..];
}

/// the parts a declaration module is named with rather than a behaviour kind.
/// `d` is the `*.d.ts` case, so a rule reads no separate extension test for it:
/// the last stem part of a declaration file is `d` exactly when the name ends in
/// `.d.ts`
///
/// the convention is the research's own rather than the config's innate members,
/// which list `.regex-patterns.ts` as well: a regex-patterns module is a
/// behaviour module for placement purposes, and the config's list is about which
/// imports a surface's own file may make rather than about where a declaration
/// belongs
const DECLARATION_STEM_PARTS = [_][]const u8{ "types", "config", "spec", "d" };

/// whether the module follows the declaration naming rather than the surface's
/// behaviour kind
pub fn isDeclarationModule(file_name: []const u8) bool {
    const last = stemLastOf(file_name);
    for (DECLARATION_STEM_PARTS) |part| {
        if (std.mem.eql(u8, last, part)) return true;
    }
    return false;
}

/// the last part of the stem dropped: `accounts` for `accounts.repo.ts`, which is
/// the name the file's sibling declaration modules are named with, so the type file
/// of a surface module is `accounts.types.ts`
pub fn stemParentOf(file_name: []const u8) []const u8 {
    const stem = stemOf(file_name);
    const dot = std.mem.lastIndexOfScalar(u8, stem, '.') orelse return stem;
    return stem[0..dot];
}

/// a module named for a behaviour kind: `<name>.<kind>.ts`, where the kind is not
/// one a declaration module is named with
///
/// the name alone decides. whether a module at the top of the tree is in scope is
/// each rule's own question: `require-enum-in-config-file` leaves the shared root
/// library alone, and `require-shared-type-placement` reads it
const IMPLEMENTATION_MODULE_MIN_STEM_PARTS = 2;

pub fn isImplementationModule(file_name: []const u8) bool {
    if (!std.mem.endsWith(u8, file_name, ".ts")) return false;
    if (stemPartCount(file_name) < IMPLEMENTATION_MODULE_MIN_STEM_PARTS) return false;
    return !isDeclarationModule(file_name);
}

/// a module in the tree's top-level directory, or in the root itself, which is
/// the shared root library or a process entry point rather than a surface's own
/// module. `src/db/accounts.repo.ts` is two directories deep and out of this
/// test, while `lib/accounts.repo.ts` and `accounts.repo.ts` are both in it
pub fn isRootModule(path: []const u8) bool {
    return std.mem.count(u8, path, "/") <= 1;
}
