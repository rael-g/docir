//! Writes a document as one plain Markdown file.
//!
//! Only documented files are written, and of those only the ones with something to say. A
//! declaration gets a section when it carries documentation of any kind or an example, or
//! when one of its members does. With a single file the sections are second-level; with several, each
//! file gets a second-level section named after its path and its declarations move one
//! level down. A member is headed by its qualified name, so a heading is unambiguous when
//! read out of context. Test names close each file as a list under "Verified behaviour".
//!
//! A citation that resolved to a declaration with a section becomes a link to that section.
//! The link target is the anchor a Markdown renderer derives from the heading: its text in
//! lower case, without punctuation, with a counter appended when the same text was already
//! used. No anchor is written into the file.

const std = @import("std");
const model = @import("model.zig");
const CodeSpans = @import("resolve.zig").CodeSpans;

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const deepest_heading = 6;

/// What writing can fail with: the arena or the writer.
pub const Error = Allocator.Error || Writer.Error;

/// Renders `document` under a first-level heading carrying `title`.
pub fn write(arena: Allocator, writer: *Writer, title: []const u8, document: model.Document) Error!void {
    var files: std.ArrayList(model.File) = .empty;
    for (document.files) |file| {
        if (file.documented and hasContent(file)) try files.append(arena, file);
    }

    var renderer: Renderer = .{ .arena = arena, .files = files.items, .title = title };
    var discarding: Writer.Discarding = .init(&.{});
    renderer.writer = &discarding.writer;
    renderer.collecting = true;
    try renderer.run();

    renderer.writer = writer;
    renderer.collecting = false;
    renderer.used.clearRetainingCapacity();
    try renderer.run();
}

fn hasContent(file: model.File) bool {
    if (file.doc.markdown.len != 0 or file.behaviours.len != 0) return true;
    for (file.decls) |decl| {
        if (hasSection(decl)) return true;
    }
    return false;
}

fn hasSection(decl: model.Decl) bool {
    if (decl.doc.markdown.len != 0 or decl.returns.markdown.len != 0 or decl.examples.len != 0) return true;
    for (decl.params) |param| {
        if (param.doc.markdown.len != 0) return true;
    }
    for (decl.members) |member| {
        if (hasSection(member)) return true;
    }
    return false;
}

const Renderer = struct {
    arena: Allocator,
    files: []const model.File,
    title: []const u8,
    writer: *Writer = undefined,
    collecting: bool = false,
    used: std.StringHashMapUnmanaged(usize) = .empty,
    anchors: std.StringHashMapUnmanaged([]const u8) = .empty,

    fn run(self: *Renderer) Error!void {
        const writer = self.writer;
        try self.heading(1, self.title, false, null);
        const grouped = self.files.len > 1;
        const level: usize = if (grouped) 3 else 2;
        for (self.files) |file| {
            const language = @tagName(file.language);
            if (grouped) try self.heading(2, file.path, true, file.path);
            if (file.doc.markdown.len != 0) {
                try writer.writeByte('\n');
                try self.text(file.doc);
                try writer.writeByte('\n');
            }
            for (file.decls) |entry| try self.section(language, entry, level);
            if (file.behaviours.len != 0) {
                try self.heading(level, "Verified behaviour", false, null);
                try writer.writeByte('\n');
                for (file.behaviours) |behaviour| try writer.print("- {s}\n", .{behaviour});
            }
        }
    }

    fn section(self: *Renderer, language: []const u8, entry: model.Decl, level: usize) Error!void {
        if (!hasSection(entry)) return;
        const writer = self.writer;
        try self.heading(level, model.qualifiedName(entry.id), true, entry.id);
        try writer.print("\n```{s}\n{s}\n```\n", .{ language, entry.signature });
        if (entry.kind == .alias) {
            if (self.anchors.get(entry.target)) |anchor| {
                try writer.print("\nAlias of [`{s}`](#{s}).\n", .{ model.qualifiedName(entry.target), anchor });
            }
        }
        if (entry.doc.markdown.len != 0) {
            try writer.writeByte('\n');
            try self.text(entry.doc);
            try writer.writeByte('\n');
        }
        var table_open = false;
        for (entry.params) |param| {
            if (param.doc.markdown.len == 0) continue;
            if (!table_open) try writer.writeAll("\n| Parameter | Type | Description |\n|---|---|---|\n");
            table_open = true;
            try writer.print("| `{s}` | ", .{param.name});
            if (param.type_name.len != 0) {
                try writer.writeByte('`');
                try cell(writer, param.type_name);
                try writer.writeByte('`');
            }
            try writer.writeAll(" | ");
            var linked: Writer.Allocating = .init(self.arena);
            const outer = self.writer;
            self.writer = &linked.writer;
            try self.text(param.doc);
            self.writer = outer;
            try cell(writer, linked.written());
            try writer.writeAll(" |\n");
        }
        if (entry.returns.markdown.len != 0) {
            try writer.writeAll("\n**Returns:** ");
            try self.text(entry.returns);
            try writer.writeByte('\n');
        }
        for (entry.examples) |example| try writer.print("\n**Example:**\n\n```{s}\n{s}\n```\n", .{ language, example });
        for (entry.members) |member| try self.section(language, member, level + 1);
    }

    fn heading(self: *Renderer, level: usize, label: []const u8, code: bool, id: ?[]const u8) Error!void {
        const writer = self.writer;
        if (level != 1) try writer.writeByte('\n');
        try writer.splatByteAll('#', @min(level, deepest_heading));
        if (code) try writer.print(" `{s}`\n", .{label}) else try writer.print(" {s}\n", .{label});

        var slug: std.ArrayList(u8) = .empty;
        for (label) |ch| {
            if (std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-') {
                try slug.append(self.arena, std.ascii.toLower(ch));
            } else if (ch == ' ') {
                try slug.append(self.arena, '-');
            }
        }
        const entry = try self.used.getOrPut(self.arena, slug.items);
        if (entry.found_existing) {
            entry.value_ptr.* += 1;
        } else {
            entry.value_ptr.* = 0;
        }
        if (!self.collecting) return;
        const target = id orelse return;
        const anchor = if (entry.value_ptr.* == 0) slug.items else try std.fmt.allocPrint(self.arena, "{s}-{d}", .{ slug.items, entry.value_ptr.* });
        try self.anchors.put(self.arena, target, anchor);
    }

    fn text(self: *Renderer, source: model.Text) Error!void {
        const writer = self.writer;
        var written: usize = 0;
        var spans: CodeSpans = .{ .text = source.markdown };
        while (spans.next()) |span| {
            const anchor = for (source.links) |link| {
                if (std.mem.eql(u8, link.citation, span.content)) break self.anchors.get(link.target) orelse continue;
            } else continue;
            try writer.writeAll(source.markdown[written..span.start]);
            try writer.print("[`{s}`](#{s})", .{ span.content, anchor });
            written = span.end;
        }
        try writer.writeAll(source.markdown[written..]);
    }
};

fn cell(writer: *Writer, content: []const u8) Writer.Error!void {
    for (content) |ch| switch (ch) {
        '\n' => try writer.writeByte(' '),
        '|' => try writer.writeAll("\\|"),
        else => try writer.writeByte(ch),
    };
}

fn render(arena: Allocator, files: []const model.File) ![]const u8 {
    var out: Writer.Allocating = .init(arena);
    try write(arena, &out.writer, "Title", .{ .root = "", .files = files });
    return out.written();
}

test "a single file is written flat, with an example and its test names as a closing list" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const text = try render(arena.allocator(), &.{.{
        .path = "a.zig",
        .language = .zig,
        .doc = .{ .markdown = "How it works." },
        .decls = &.{
            .{ .id = "a.zig#run", .name = "run", .kind = .function, .signature = "fn run() void", .doc = .{ .markdown = "Runs." }, .examples = &.{"run();"} },
            .{ .id = "a.zig#hidden", .name = "hidden", .kind = .function, .signature = "fn hidden() void" },
        },
        .behaviours = &.{ "it runs", "it stops" },
    }});
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

test "a member is headed by its qualified name and only documented parameters are listed" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const text = try render(arena.allocator(), &.{.{
        .path = "a.h",
        .language = .c,
        .decls = &.{.{
            .id = "a.h#pool",
            .name = "pool",
            .kind = .@"struct",
            .signature = "typedef struct pool",
            .members = &.{.{
                .id = "a.h#pool.wait",
                .name = "wait",
                .kind = .field,
                .signature = "bool (*wait)(pool *self, int code)",
                .params = &.{
                    .{ .name = "self", .type_name = "pool *", .doc = .{ .markdown = "The pool | borrowed,\nnever NULL." } },
                    .{ .name = "code", .type_name = "int" },
                },
                .returns = .{ .markdown = "False on failure." },
            }},
        }},
    }});
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
        \\bool (*wait)(pool *self, int code)
        \\```
        \\
        \\| Parameter | Type | Description |
        \\|---|---|---|
        \\| `self` | `pool *` | The pool \| borrowed, never NULL. |
        \\
        \\**Returns:** False on failure.
        \\
    , text);
}

test "a citation links to the section of its target, across files and with repeated headings numbered" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const text = try render(arena.allocator(), &.{
        .{
            .path = "pool.h",
            .language = .c,
            .decls = &.{.{ .id = "pool.h#wait", .name = "wait", .kind = .function, .signature = "bool wait(void)", .doc = .{ .markdown = "Waits." } }},
        },
        .{
            .path = "hidden.zig",
            .language = .zig,
            .documented = false,
            .decls = &.{.{ .id = "hidden.zig#secret", .name = "secret", .kind = .function, .signature = "fn secret() void", .doc = .{ .markdown = "Hidden." } }},
        },
        .{
            .path = "pool.zig",
            .language = .zig,
            .doc = .{
                .markdown = "Implements `wait` with `Pool.wait`, never `secret`.",
                .links = &.{
                    .{ .citation = "wait", .target = "pool.h#wait" },
                    .{ .citation = "Pool.wait", .target = "pool.zig#wait" },
                    .{ .citation = "secret", .target = "hidden.zig#secret" },
                },
            },
            .decls = &.{.{ .id = "pool.zig#wait", .name = "wait", .kind = .function, .signature = "fn wait() bool", .doc = .{ .markdown = "Waits too." } }},
        },
    });
    try std.testing.expectEqualStrings(
        \\# Title
        \\
        \\## `pool.h`
        \\
        \\### `wait`
        \\
        \\```c
        \\bool wait(void)
        \\```
        \\
        \\Waits.
        \\
        \\## `pool.zig`
        \\
        \\Implements [`wait`](#wait) with [`Pool.wait`](#wait-1), never `secret`.
        \\
        \\### `wait`
        \\
        \\```zig
        \\fn wait() bool
        \\```
        \\
        \\Waits too.
        \\
    , text);
}
