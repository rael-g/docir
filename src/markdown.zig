//! Writes units as one plain Markdown document.
//!
//! A document with a single unit is flat: its entries are second-level sections. With
//! several units, each unit gets a second-level section named after its path and its
//! entries move one level down. A member is headed by its qualified name, so a heading
//! is unambiguous when read out of context. An example follows the text of its entry as a
//! fenced block. Test names close each unit as a list under "Verified behaviour".

const std = @import("std");
const model = @import("model.zig");

const Writer = std.Io.Writer;
const deepest_heading = 6;

/// Renders `units` under a first-level heading carrying `title`.
pub fn write(writer: *Writer, title: []const u8, units: []const model.Unit) Writer.Error!void {
    try writer.print("# {s}\n", .{title});
    const grouped = units.len > 1;
    for (units) |unit| {
        const level: usize = if (grouped) 3 else 2;
        if (grouped) try writer.print("\n## `{s}`\n", .{unit.path});
        if (unit.intro.len != 0) try writer.print("\n{s}\n", .{unit.intro});
        for (unit.entries) |entry| try writeEntry(writer, unit.language, "", entry, level);
        if (unit.behaviours.len != 0) {
            try heading(writer, level);
            try writer.writeAll("Verified behaviour\n\n");
            for (unit.behaviours) |behaviour| try writer.print("- {s}\n", .{behaviour});
        }
    }
}

fn writeEntry(writer: *Writer, language: []const u8, parent: []const u8, entry: model.Entry, level: usize) Writer.Error!void {
    try heading(writer, level);
    if (parent.len != 0) try writer.print("`{s}.{s}`\n", .{ parent, entry.name }) else try writer.print("`{s}`\n", .{entry.name});
    try writer.print("\n```{s}\n{s}\n```\n", .{ language, entry.signature });
    if (entry.text.len != 0) try writer.print("\n{s}\n", .{entry.text});
    if (entry.params.len != 0) {
        try writer.writeAll("\n| Parameter | Description |\n|---|---|\n");
        for (entry.params) |param| {
            try writer.print("| `{s}` | ", .{param.name});
            try writeCell(writer, param.text);
            try writer.writeAll(" |\n");
        }
    }
    if (entry.returns.len != 0) try writer.print("\n**Returns:** {s}\n", .{entry.returns});
    for (entry.examples) |example| try writer.print("\n**Example:**\n\n```{s}\n{s}\n```\n", .{ language, example });
    var qualified_buffer: [512]u8 = undefined;
    const qualified = if (parent.len == 0)
        entry.name
    else
        std.fmt.bufPrint(&qualified_buffer, "{s}.{s}", .{ parent, entry.name }) catch entry.name;
    for (entry.members) |member| try writeEntry(writer, language, qualified, member, level + 1);
}

fn heading(writer: *Writer, level: usize) Writer.Error!void {
    try writer.writeByte('\n');
    try writer.splatByteAll('#', @min(level, deepest_heading));
    try writer.writeByte(' ');
}

fn writeCell(writer: *Writer, text: []const u8) Writer.Error!void {
    for (text) |ch| switch (ch) {
        '\n' => try writer.writeByte(' '),
        '|' => try writer.writeAll("\\|"),
        else => try writer.writeByte(ch),
    };
}

fn render(units: []const model.Unit) ![]u8 {
    var out: Writer.Allocating = .init(std.testing.allocator);
    errdefer out.deinit();
    try write(&out.writer, "Title", units);
    return out.toOwnedSlice();
}

test "a single unit is written flat, with its test names as a closing list" {
    const text = try render(&.{.{
        .path = "a.zig",
        .language = "zig",
        .intro = "How it works.",
        .entries = &.{.{ .name = "run", .signature = "fn run() void", .text = "Runs.", .examples = &.{"run();"} }},
        .behaviours = &.{ "it runs", "it stops" },
    }});
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings(
        \\# Title
        \\
        \\How it works.
        \\
        \\## `run`
        \\
        \\```zig
        \\fn run() void
        \\```
        \\
        \\Runs.
        \\
        \\**Example:**
        \\
        \\```zig
        \\run();
        \\```
        \\
        \\## Verified behaviour
        \\
        \\- it runs
        \\- it stops
        \\
    , text);
}

test "a member is headed by its qualified name one level below its container" {
    const text = try render(&.{.{
        .path = "a.h",
        .language = "c",
        .entries = &.{.{
            .name = "pool",
            .signature = "typedef struct pool",
            .members = &.{.{
                .name = "wait",
                .signature = "bool (*wait)(pool *self)",
                .params = &.{.{ .name = "self", .text = "The pool | borrowed,\nnever NULL." }},
                .returns = "False on failure.",
            }},
        }},
    }});
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings(
        \\# Title
        \\
        \\## `pool`
        \\
        \\```c
        \\typedef struct pool
        \\```
        \\
        \\### `pool.wait`
        \\
        \\```c
        \\bool (*wait)(pool *self)
        \\```
        \\
        \\| Parameter | Description |
        \\|---|---|
        \\| `self` | The pool \| borrowed, never NULL. |
        \\
        \\**Returns:** False on failure.
        \\
    , text);
}

test "several units are each given a section named after their path" {
    const text = try render(&.{
        .{ .path = "a.zig", .language = "zig", .intro = "First." },
        .{ .path = "b.zig", .language = "zig", .behaviours = &.{"it holds"} },
    });
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings(
        \\# Title
        \\
        \\## `a.zig`
        \\
        \\First.
        \\
        \\## `b.zig`
        \\
        \\### Verified behaviour
        \\
        \\- it holds
        \\
    , text);
}
