//! zigdoc turns the documentation written in source code into data, and that data into text.
//!
//! `extract` starts at the root file of a module, follows its imports as `project`
//! describes, reads each file with `zig_source` or `doxygen`, and has `resolve` turn every
//! name the documentation mentions into a reference. The result is a `model.Document`, which `model.writeJson`
//! stores. `markdown.write` renders a document read back with `model.readJson`.
//!
//! Nothing here is a command. A build asks for documentation through the step the
//! `build.zig` of this package offers, which takes what `extract` needs from the module it
//! is given.

const std = @import("std");

pub const model = @import("model.zig");
pub const project = @import("project.zig");
pub const resolve = @import("resolve.zig");
pub const markdown = @import("markdown.zig");
pub const zig_source = @import("zig_source.zig");
pub const doxygen = @import("doxygen.zig");

/// A document, and the citations in it that name nothing.
pub const Extraction = struct {
    /// Everything that was read, resolved.
    document: model.Document,
    /// Empty when every citation of a documented file names something.
    problems: []const resolve.Problem,
};

/// Reads the root of `options` and everything it imports into one resolved document. A
/// file of a reference-only module comes first and holds only the top-level declarations
/// that a reference names or reaches into, and the imports those declarations make.
pub fn extract(arena: std.mem.Allocator, io: std.Io, options: project.Options) !Extraction {
    var loaded = try project.Project.open(arena, io, options);
    const resolved = try resolve.resolve(arena, loaded.files.items, .{ .context = &loaded, .find = find });
    var targets: std.StringHashMapUnmanaged(void) = .empty;
    for (resolved.files) |file| {
        try collect(arena, &targets, file.doc);
        try collectDecls(arena, &targets, file.decls);
    }
    var files: std.ArrayList(model.File) = .empty;
    for (loaded.referenced.items) |file| {
        if (try narrowed(arena, targets, file.*)) |kept| try files.append(arena, kept);
    }
    try files.appendSlice(arena, resolved.files);
    return .{
        .document = .{ .root = loaded.root, .files = try files.toOwnedSlice(arena) },
        .problems = resolved.problems,
    };
}

fn find(context: *anyopaque, path: []const u8) std.mem.Allocator.Error!?*const model.File {
    const loaded: *project.Project = @ptrCast(@alignCast(context));
    return loaded.reference(path);
}

fn collect(arena: std.mem.Allocator, targets: *std.StringHashMapUnmanaged(void), text: model.Text) std.mem.Allocator.Error!void {
    for (text.links) |link| try targets.put(arena, link.target, {});
}

fn collectDecls(arena: std.mem.Allocator, targets: *std.StringHashMapUnmanaged(void), decls: []const model.Decl) std.mem.Allocator.Error!void {
    for (decls) |decl| {
        if (decl.target.len != 0) try targets.put(arena, decl.target, {});
        try collect(arena, targets, decl.doc);
        try collect(arena, targets, decl.returns);
        for (decl.params) |param| try collect(arena, targets, param.doc);
        try collectDecls(arena, targets, decl.members);
    }
}

fn narrowed(arena: std.mem.Allocator, targets: std.StringHashMapUnmanaged(void), file: model.File) std.mem.Allocator.Error!?model.File {
    var decls: std.ArrayList(model.Decl) = .empty;
    var imports: std.ArrayList(model.Import) = .empty;
    for (file.decls) |decl| {
        var names = targets.keyIterator();
        const wanted = while (names.next()) |target| {
            if (!std.mem.startsWith(u8, target.*, decl.id)) continue;
            if (target.len == decl.id.len or target.*[decl.id.len] == '.') break true;
        } else false;
        if (!wanted) continue;
        var kept = decl;
        if (decl.kind == .import) {
            for (file.imports) |import| {
                if (!std.mem.eql(u8, import.name, decl.value)) continue;
                kept.target = import.path;
                try imports.append(arena, import);
                break;
            }
        }
        try decls.append(arena, kept);
    }
    if (decls.items.len == 0 and !targets.contains(file.path)) return null;
    var out = file;
    out.decls = try decls.toOwnedSlice(arena);
    out.imports = try imports.toOwnedSlice(arena);
    return out;
}

test "a referenced file keeps only what a reference names or reaches into" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var targets: std.StringHashMapUnmanaged(void) = .empty;
    try targets.put(allocator, "lib/lib.zig#Pool.wait", {});
    try targets.put(allocator, "lib/lib.zig#mem", {});

    var file = try zig_source.read(allocator, "lib/lib.zig",
        \\pub const mem = @import("mem.zig");
        \\pub const fs = @import("fs.zig");
        \\pub const Pool = struct {
        \\    pub fn wait() void {}
        \\};
        \\pub const Pooled = struct {};
    );
    file.imports = &.{
        .{ .name = "mem.zig", .kind = .file, .path = "lib/mem.zig" },
        .{ .name = "fs.zig", .kind = .file, .path = "lib/fs.zig" },
    };
    const kept = (try narrowed(allocator, targets, file)).?;
    try std.testing.expectEqual(2, kept.decls.len);
    try std.testing.expectEqualStrings("mem", kept.decls[0].name);
    try std.testing.expectEqualStrings("lib/mem.zig", kept.decls[0].target);
    try std.testing.expectEqualStrings("Pool", kept.decls[1].name);
    try std.testing.expectEqual(1, kept.imports.len);

    const other = try zig_source.read(allocator, "lib/other.zig", "pub const Pool = struct {};\n");
    try std.testing.expectEqual(null, try narrowed(allocator, targets, other));
}

test {
    std.testing.refAllDecls(@This());
}
