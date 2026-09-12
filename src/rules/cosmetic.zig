const std = @import("std");
const root = @import("../rules.zig");

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
