//! The language-neutral shape every reader produces and every writer consumes.
//!
//! A reader turns one source file into a `Unit`. Nothing in a `Unit` remembers which
//! language it came from except `language`, which only labels the code fences.
//!
//! A `Document` is the form the model takes outside the process: JSON whose fields are
//! the fields declared here, under the same names. Extraction ends in that file and
//! every writer starts from it, so a writer never reads a source file.

const std = @import("std");

/// Version of the JSON layout. A file carrying another one is refused.
pub const format_version = 1;

/// The units extracted by one run, as written to and read from JSON.
pub const Document = struct {
    format: u32 = format_version,
    units: []const Unit,
};

/// Writes `document` as indented JSON.
pub fn writeJson(writer: *std.Io.Writer, document: Document) std.Io.Writer.Error!void {
    try std.json.Stringify.value(document, .{ .whitespace = .indent_2 }, writer);
    try writer.writeByte('\n');
}

/// Reads a `Document` back. Fails with `error.UnsupportedFormat` when the file was written
/// in another `format_version`, and with the JSON parser's error when it is not a document.
pub fn readJson(arena: std.mem.Allocator, bytes: []const u8) !Document {
    const document = try std.json.parseFromSliceLeaky(Document, arena, bytes, .{});
    if (document.format != format_version) return error.UnsupportedFormat;
    return document;
}

/// One documented parameter of a function-like declaration.
pub const Param = struct {
    name: []const u8,
    text: []const u8,
};

/// One declaration worth a section: it carries documentation, an example, or holds members
/// that do. An example is source code that uses the declaration, taken from a test.
pub const Entry = struct {
    name: []const u8,
    signature: []const u8,
    text: []const u8 = "",
    params: []const Param = &.{},
    returns: []const u8 = "",
    examples: []const []const u8 = &.{},
    members: []const Entry = &.{},
};

/// Everything one source file says about itself. `symbols` names every declaration of the
/// file, documented or not, with a member qualified by its container as `Container.member`.
pub const Unit = struct {
    path: []const u8,
    language: []const u8,
    intro: []const u8 = "",
    entries: []const Entry = &.{},
    behaviours: []const []const u8 = &.{},
    symbols: []const []const u8 = &.{},
};

test "a document survives the trip through JSON" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const original: Document = .{ .units = &.{.{
        .path = "a.h",
        .language = "c",
        .intro = "Line one.\n\"Quoted\" line.",
        .entries = &.{.{
            .name = "pool",
            .signature = "typedef struct pool",
            .members = &.{.{
                .name = "wait",
                .signature = "bool (*wait)(pool *self)",
                .text = "Waits.",
                .params = &.{.{ .name = "self", .text = "The pool." }},
                .returns = "False on failure.",
                .examples = &.{"try pool.wait();"},
            }},
        }},
        .behaviours = &.{"it waits"},
        .symbols = &.{ "pool", "pool.wait" },
    }} };

    var out: std.Io.Writer.Allocating = .init(arena.allocator());
    try writeJson(&out.writer, original);
    const copy = try readJson(arena.allocator(), out.written());

    try std.testing.expectEqualDeep(original, copy);
}

test "a document written in another format version is refused" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.UnsupportedFormat, readJson(arena.allocator(), "{\"format\": 0, \"units\": []}"));
}
