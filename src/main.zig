//! Command line of zigdoc. Documentation is produced in two steps, with a JSON file between them.
//!
//! `zigdoc extract --out <file.json> [--strict] [--symbols <source>]... <source>...`
//!
//! Reads each source with the reader its extension selects, `.zig` by the Zig reader and
//! `.h` or `.c` by the Doxygen reader, and writes what they say as one JSON document, the
//! sources in the order they were given.
//!
//! Every citation in the sources is resolved first, and each one that names nothing is
//! reported. A source given with `--symbols` only lends its declarations to that check and
//! is left out of the document. Documentation written for the compiler's own generator
//! uses code spans freely, for a libc function or an example value, so a report does not
//! stop the run unless `--strict` is given; with it, nothing is written and the exit code
//! is 1.
//!
//! `zigdoc markdown --title <title> --out <file.md> <file.json>...`
//!
//! Writes the units of the given JSON documents as one Markdown file. It reads no source.

const std = @import("std");
const model = @import("model.zig");
const zig_source = @import("zig_source.zig");
const doxygen = @import("doxygen.zig");
const markdown = @import("markdown.zig");
const references = @import("references.zig");

const usage =
    \\usage: zigdoc extract --out <file.json> [--strict] [--symbols <source>]... <source>...
    \\       zigdoc markdown --title <title> --out <file.md> <file.json>...
    \\
;
const usage_exit_code = 2;
const unresolved_exit_code = 1;

const Arguments = struct {
    title: ?[]const u8 = null,
    out: ?[]const u8 = null,
    strict: bool = false,
    symbols: std.ArrayList([]const u8) = .empty,
    inputs: std.ArrayList([]const u8) = .empty,
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) fail("", .{});

    var parsed: Arguments = .{};
    var index: usize = 2;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--title") or std.mem.eql(u8, arg, "--out") or std.mem.eql(u8, arg, "--symbols")) {
            index += 1;
            if (index == args.len) fail("{s} needs a value\n", .{arg});
            if (std.mem.eql(u8, arg, "--title")) {
                parsed.title = args[index];
            } else if (std.mem.eql(u8, arg, "--out")) {
                parsed.out = args[index];
            } else {
                try parsed.symbols.append(arena, args[index]);
            }
        } else if (std.mem.eql(u8, arg, "--strict")) {
            parsed.strict = true;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            fail("unknown option {s}\n", .{arg});
        } else {
            try parsed.inputs.append(arena, arg);
        }
    }
    const out_path = parsed.out orelse fail("--out is required\n", .{});
    if (parsed.inputs.items.len == 0) fail("nothing to read\n", .{});

    var output: std.Io.Writer.Allocating = .init(arena);
    if (std.mem.eql(u8, args[1], "extract")) {
        if (parsed.title != null) fail("extract takes no --title\n", .{});
        try extract(arena, init.io, parsed, &output.writer);
    } else if (std.mem.eql(u8, args[1], "markdown")) {
        if (parsed.symbols.items.len != 0 or parsed.strict) fail("markdown takes neither --symbols nor --strict\n", .{});
        const title = parsed.title orelse fail("--title is required\n", .{});
        try renderMarkdown(arena, init.io, title, parsed.inputs.items, &output.writer);
    } else {
        fail("unknown command {s}\n", .{args[1]});
    }

    const cwd = std.Io.Dir.cwd();
    if (std.fs.path.dirname(out_path)) |directory| try cwd.createDirPath(init.io, directory);
    try cwd.writeFile(init.io, .{ .sub_path = out_path, .data = output.written() });
}

fn extract(arena: std.mem.Allocator, io: std.Io, parsed: Arguments, writer: *std.Io.Writer) !void {
    var units: std.ArrayList(model.Unit) = .empty;
    for (parsed.inputs.items) |path| try units.append(arena, try readSource(arena, io, path));
    var extra: std.ArrayList(model.Unit) = .empty;
    for (parsed.symbols.items) |path| try extra.append(arena, try readSource(arena, io, path));

    const problems = try references.check(arena, units.items, extra.items);
    for (problems) |problem| switch (problem.kind) {
        .symbol => std.debug.print("{s}: `{s}`, cited by {s}, is not declared\n", .{ problem.path, problem.citation, problem.owner }),
        .parameter => std.debug.print("{s}: {s} documents a parameter `{s}` it does not have\n", .{ problem.path, problem.owner, problem.citation }),
    };
    if (problems.len != 0 and parsed.strict) std.process.exit(unresolved_exit_code);

    try model.writeJson(writer, .{ .units = units.items });
}

fn renderMarkdown(arena: std.mem.Allocator, io: std.Io, title: []const u8, paths: []const []const u8, writer: *std.Io.Writer) !void {
    var units: std.ArrayList(model.Unit) = .empty;
    for (paths) |path| {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited);
        const document = model.readJson(arena, bytes) catch |err| fail("{s}: not a zigdoc document ({t})\n", .{ path, err });
        try units.appendSlice(arena, document.units);
    }
    try markdown.write(writer, title, units.items);
}

fn readSource(arena: std.mem.Allocator, io: std.Io, path: []const u8) !model.Unit {
    const source = try std.Io.Dir.cwd().readFileAllocOptions(io, path, arena, .unlimited, .of(u8), 0);
    const extension = std.fs.path.extension(path);
    if (std.mem.eql(u8, extension, ".zig")) return zig_source.read(arena, path, source);
    if (std.mem.eql(u8, extension, ".h") or std.mem.eql(u8, extension, ".c")) return doxygen.read(arena, path, source);
    fail("no reader for {s}\n", .{path});
}

fn fail(comptime format: []const u8, args: anytype) noreturn {
    std.debug.print(format ++ usage, args);
    std.process.exit(usage_exit_code);
}

test {
    std.testing.refAllDecls(@This());
}
