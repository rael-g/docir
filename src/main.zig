//! The `docir` program: the commands of `docir.cli` given the arguments of the process.

const std = @import("std");
const docir = @import("docir");

/// Runs the command the arguments ask for and exits with the code it answered.
pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const code = try docir.cli.run(arena, init.io, args[@min(1, args.len)..]);
    if (code != 0) std.process.exit(code);
}
