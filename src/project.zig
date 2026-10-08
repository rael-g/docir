//! Walks the imports of a root file and reads the files it reaches.
//!
//! What is read is described as a set of modules, the way a build describes a compilation.
//! Each `Module` has a root file, the names it may import other modules by and the
//! directories its headers are looked for in. The first module of `Options.modules` is the
//! one being documented, and every file belongs to the module whose root reached it.
//!
//! A relative `@import` or `#include` is looked for beside the file that names it. A named
//! `@import` is looked up in `Module.imports` of the module of its file. A `@cInclude`, and
//! an `#include` not found beside its file, is looked for in each of `Module.include_dirs`
//! in order. What is not found stays in the list of imports of its file with an empty path,
//! and is not an error.
//!
//! The path a file gets in the document never names the machine it was read on. The root
//! file of a module is given relative to `Options.base` when it lies under it, and under
//! the name of its module otherwise. A file imported relatively is placed relative to its
//! importer, and an included file keeps the name it was included by.
//!
//! Every file reached is read, so that a reference into it resolves, but only a file under
//! one of `Options.documented_dirs` is marked as documented. The exception is a module that
//! is `Module.reference_only`: an import into it is given its path without the file being
//! read, and `Project.reference` reads one such file when a reference goes through it. Its
//! files are never documented, and the includes in them are not followed.

const std = @import("std");
const model = @import("model.zig");
const zig_source = @import("zig_source.zig");
const doxygen = @import("doxygen.zig");

const Allocator = std.mem.Allocator;

/// A name a module imports another one by. `module` indexes `Options.modules`.
pub const ModuleImport = struct {
    /// The name as it is written in an `@import`.
    name: []const u8,
    /// Position in `Options.modules` of the module the name stands for.
    module: usize,
};

/// The root file of a module and what its files may import.
pub const Module = struct {
    /// The directory the files of the module are shown under when its root lies outside
    /// `Options.base`. No two modules should share one.
    name: []const u8,
    /// Path of the root file on disk.
    path: []const u8,
    /// The modules the files of this one may import by name.
    imports: []const ModuleImport = &.{},
    /// The directories on disk a header included by this module is looked for in.
    include_dirs: []const []const u8 = &.{},
    /// Whether the files of the module are read only when a reference goes through them.
    reference_only: bool = false,
};

/// What to read. The first of `modules` is the one documented, and the directory of its
/// root file is always one of the documented directories.
pub const Options = struct {
    /// Every module that can be reached, the documented one first.
    modules: []const Module,
    /// Directory on disk that paths in the document are relative to.
    base: []const u8 = "",
    /// Directories on disk whose files are documented.
    documented_dirs: []const []const u8 = &.{},
};

/// The files reached from the root of the first module.
pub const Project = struct {
    /// Owns everything the project allocates, the files included.
    arena: Allocator,
    /// What the files are read through.
    io: std.Io,
    /// What `open` was given.
    options: Options,
    /// `Options.base` as an absolute path.
    base: []const u8 = "",
    /// The path of the root file in the document.
    root: []const u8 = "",
    /// The documented directories as absolute paths.
    documented: std.ArrayList([]const u8) = .empty,
    /// Path in the document of each file read by `open`, by its absolute path on disk.
    seen: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// The files read by `open`, dependencies before the files that import them.
    files: std.ArrayList(model.File) = .empty,
    /// Where on disk each file of a reference-only module is, by its path in the document.
    postponed: std.StringHashMapUnmanaged(Postponed) = .empty,
    /// What `reference` answered for each path it was asked.
    references: std.StringHashMapUnmanaged(?*const model.File) = .empty,
    /// The files `reference` read, in the order they were asked for.
    referenced: std.ArrayList(*const model.File) = .empty,

    const Postponed = struct {
        key: []const u8,
        module: usize,
    };

    /// Reads the root of the first module and everything it imports, dependencies first.
    /// Fails when there is no module or when the root cannot be read or parsed.
    pub fn open(arena: Allocator, io: std.Io, options: Options) !Project {
        if (options.modules.len == 0) return error.NoModule;
        var project: Project = .{ .arena = arena, .io = io, .options = options };
        const root_key = try std.fs.path.resolve(arena, &.{options.modules[0].path});
        try project.documented.append(arena, std.fs.path.dirname(root_key) orelse ".");
        for (options.documented_dirs) |dir| try project.documented.append(arena, try std.fs.path.resolve(arena, &.{dir}));

        project.base = try std.fs.path.resolve(arena, &.{options.base});
        project.root = try project.modulePath(0, root_key);
        try project.seen.put(arena, root_key, project.root);
        const root_file = try project.read(root_key, project.root);
        try project.files.append(arena, try project.link(root_key, 0, root_file, false));
        return project;
    }

    /// The file of a reference-only module that an import was given `path` for, read on
    /// the first call. Null when `path` is not such a file or it cannot be read.
    pub fn reference(self: *Project, path: []const u8) Allocator.Error!?*const model.File {
        if (self.references.get(path)) |known| return known;
        const postponed = self.postponed.get(path) orelse return null;
        try self.references.put(self.arena, path, null);
        const read_file = self.read(postponed.key, path) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return null,
        };
        const file = try self.arena.create(model.File);
        file.* = try self.link(postponed.key, postponed.module, read_file, true);
        try self.references.put(self.arena, path, file);
        try self.referenced.append(self.arena, file);
        return file;
    }

    fn modulePath(self: *Project, module: usize, key: []const u8) Allocator.Error![]const u8 {
        if (within(self.base, key)) |path| return path;
        return std.fs.path.join(self.arena, &.{ self.options.modules[module].name, std.fs.path.basename(key) });
    }

    fn read(self: *Project, key: []const u8, path: []const u8) !model.File {
        const source = try std.Io.Dir.cwd().readFileAllocOptions(self.io, key, self.arena, .unlimited, .of(u8), 0);
        const extension = std.fs.path.extension(key);
        if (std.mem.eql(u8, extension, ".zig")) return zig_source.read(self.arena, path, source);
        if (std.mem.eql(u8, extension, ".h") or std.mem.eql(u8, extension, ".c")) return doxygen.read(self.arena, path, source);
        return error.NoReaderForFile;
    }

    fn link(self: *Project, key: []const u8, module: usize, read_file: model.File, postpone: bool) Allocator.Error!model.File {
        var file = read_file;
        const imports = try self.arena.dupe(model.Import, file.imports);
        for (imports) |*import| import.path = try self.follow(key, file.path, module, import.*, postpone) orelse "";
        file.imports = imports;
        file.documented = false;
        if (postpone) return file;
        for (self.documented.items) |dir| {
            if (within(dir, key) != null) file.documented = true;
        }
        return file;
    }

    fn follow(self: *Project, importer_key: []const u8, importer_path: []const u8, module: usize, import: model.Import, postpone: bool) Allocator.Error!?[]const u8 {
        const importer_dir = std.fs.path.dirname(importer_key) orelse ".";
        const importer_path_dir = std.fs.path.dirname(importer_path) orelse "";
        switch (import.kind) {
            .file => return self.reach(
                try std.fs.path.resolve(self.arena, &.{ importer_dir, import.name }),
                try std.fs.path.resolve(self.arena, &.{ importer_path_dir, import.name }),
                module,
                postpone,
            ),
            .module => {
                for (self.options.modules[module].imports) |imported| {
                    if (!std.mem.eql(u8, imported.name, import.name)) continue;
                    const target = self.options.modules[imported.module];
                    const key = try std.fs.path.resolve(self.arena, &.{target.path});
                    return self.reach(key, try self.modulePath(imported.module, key), imported.module, postpone or target.reference_only);
                }
                return null;
            },
            .include => {
                if (postpone) return null;
                if (std.mem.endsWith(u8, importer_key, ".h") or std.mem.endsWith(u8, importer_key, ".c")) {
                    const beside = try self.visit(
                        try std.fs.path.resolve(self.arena, &.{ importer_dir, import.name }),
                        try std.fs.path.resolve(self.arena, &.{ importer_path_dir, import.name }),
                        module,
                    );
                    if (beside) |path| return path;
                }
                for (self.options.modules[module].include_dirs) |dir| {
                    const found = try self.visit(try std.fs.path.resolve(self.arena, &.{ dir, import.name }), import.name, module);
                    if (found) |path| return path;
                }
                return null;
            },
        }
    }

    fn reach(self: *Project, key: []const u8, path: []const u8, module: usize, postpone: bool) Allocator.Error!?[]const u8 {
        if (!postpone) return self.visit(key, path, module);
        if (self.seen.get(key)) |known| return known;
        try self.postponed.put(self.arena, path, .{ .key = key, .module = module });
        return path;
    }

    fn visit(self: *Project, key: []const u8, path: []const u8, module: usize) Allocator.Error!?[]const u8 {
        if (self.seen.get(key)) |known| return known;
        try self.seen.put(self.arena, key, path);
        const file = self.read(key, path) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                _ = self.seen.remove(key);
                return null;
            },
        };
        try self.files.append(self.arena, try self.link(key, module, file, false));
        return path;
    }
};

fn within(dir: []const u8, path: []const u8) ?[]const u8 {
    if (dir.len == 0 or std.mem.eql(u8, dir, ".")) return if (std.fs.path.isAbsolute(path)) null else path;
    if (path.len <= dir.len + 1 or !std.mem.startsWith(u8, path, dir) or !std.fs.path.isSep(path[dir.len])) return null;
    return path[dir.len + 1 ..];
}

fn writeFile(dir: std.Io.Dir, sub_path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(sub_path)) |parent| try dir.createDirPath(std.testing.io, parent);
    try dir.writeFile(std.testing.io, .{ .sub_path = sub_path, .data = data });
}

fn fileNamed(project: Project, path: []const u8) !model.File {
    for (project.files.items) |file| {
        if (std.mem.eql(u8, file.path, path)) return file;
    }
    return error.FileNotInDocument;
}

test "imports are followed by kind, and only the files under a documented directory are documented" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "plugin/src/main.zig",
        \\const helper = @import("helper.zig");
        \\const heap = @import("heap");
        \\const std = @import("std");
        \\const c = @cImport(@cInclude("pool/pool.h"));
    );
    try writeFile(tmp.dir, "plugin/src/helper.zig", "const main = @import(\"main.zig\");\n");
    try writeFile(tmp.dir, "common/heap.zig", "pub fn alloc() void {}\n");
    try writeFile(tmp.dir, "contracts/pool/pool.h", "#include <pool/error.h>\n#include \"local.h\"\nvoid stop(void);\n");
    try writeFile(tmp.dir, "contracts/pool/error.h", "typedef struct error error;\n");
    try writeFile(tmp.dir, "contracts/pool/local.h", "#define LOCAL 1\n");

    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena.allocator());
    const join = std.fs.path.join;
    const project = try Project.open(arena.allocator(), std.testing.io, .{
        .modules = &.{
            .{
                .name = "plugin",
                .path = try join(arena.allocator(), &.{ base, "plugin/src/main.zig" }),
                .imports = &.{.{ .name = "heap", .module = 1 }},
                .include_dirs = &.{try join(arena.allocator(), &.{ base, "contracts" })},
            },
            .{ .name = "heap", .path = try join(arena.allocator(), &.{ base, "common/heap.zig" }) },
        },
        .base = try join(arena.allocator(), &.{ base, "plugin" }),
        .documented_dirs = &.{try join(arena.allocator(), &.{ base, "contracts" })},
    });

    try std.testing.expectEqualStrings("src/main.zig", project.root);
    try std.testing.expectEqual(6, project.files.items.len);
    try std.testing.expectEqualStrings("src/main.zig", project.files.items[5].path);

    const main = try fileNamed(project, "src/main.zig");
    try std.testing.expectEqualStrings("src/helper.zig", main.imports[0].path);
    try std.testing.expectEqualStrings("heap/heap.zig", main.imports[1].path);
    try std.testing.expectEqualStrings("", main.imports[2].path);
    try std.testing.expectEqualStrings("pool/pool.h", main.imports[3].path);

    const pool = try fileNamed(project, "pool/pool.h");
    try std.testing.expectEqualStrings("pool/error.h", pool.imports[0].path);
    try std.testing.expectEqualStrings("pool/local.h", pool.imports[1].path);

    try std.testing.expect(main.documented);
    try std.testing.expect((try fileNamed(project, "src/helper.zig")).documented);
    try std.testing.expect(pool.documented);
    try std.testing.expect(!(try fileNamed(project, "heap/heap.zig")).documented);
}

test "a named import is looked up in the module of the file that names it" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "app/main.zig", "const util = @import(\"util\");\nconst inner = @import(\"inner\");\n");
    try writeFile(tmp.dir, "first/util.zig", "const util = @import(\"util\");\nconst c = @cImport(@cInclude(\"own.h\"));\n");
    try writeFile(tmp.dir, "first/include/own.h", "void own(void);\n");
    try writeFile(tmp.dir, "second/util.zig", "pub fn second() void {}\n");

    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena.allocator());
    const join = std.fs.path.join;
    const project = try Project.open(arena.allocator(), std.testing.io, .{
        .modules = &.{
            .{ .name = "app", .path = try join(arena.allocator(), &.{ base, "app/main.zig" }), .imports = &.{.{ .name = "util", .module = 1 }} },
            .{
                .name = "util",
                .path = try join(arena.allocator(), &.{ base, "first/util.zig" }),
                .imports = &.{.{ .name = "util", .module = 2 }},
                .include_dirs = &.{try join(arena.allocator(), &.{ base, "first/include" })},
            },
            .{ .name = "util-2", .path = try join(arena.allocator(), &.{ base, "second/util.zig" }) },
        },
        .base = try join(arena.allocator(), &.{ base, "app" }),
    });

    const main = try fileNamed(project, "main.zig");
    try std.testing.expectEqualStrings("util/util.zig", main.imports[0].path);
    try std.testing.expectEqualStrings("", main.imports[1].path);
    const first = try fileNamed(project, "util/util.zig");
    try std.testing.expectEqualStrings("util-2/util.zig", first.imports[0].path);
    try std.testing.expectEqualStrings("own.h", first.imports[1].path);
}

test "a file of a reference-only module is read only when a reference goes through it" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "app/main.zig", "const lib = @import(\"lib\");\n");
    try writeFile(tmp.dir, "lib/lib.zig", "pub const mem = @import(\"mem.zig\");\npub const gone = @import(\"gone.zig\");\n");
    try writeFile(tmp.dir, "lib/mem.zig", "pub fn copy() void {}\n");

    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena.allocator());
    const join = std.fs.path.join;
    var project = try Project.open(arena.allocator(), std.testing.io, .{
        .modules = &.{
            .{ .name = "app", .path = try join(arena.allocator(), &.{ base, "app/main.zig" }), .imports = &.{.{ .name = "lib", .module = 1 }} },
            .{ .name = "lib", .path = try join(arena.allocator(), &.{ base, "lib/lib.zig" }), .reference_only = true },
        },
        .base = try join(arena.allocator(), &.{ base, "app" }),
    });

    try std.testing.expectEqual(1, project.files.items.len);
    try std.testing.expectEqualStrings("lib/lib.zig", project.files.items[0].imports[0].path);
    try std.testing.expectEqual(0, project.referenced.items.len);

    const lib = (try project.reference("lib/lib.zig")).?;
    try std.testing.expect(!lib.documented);
    try std.testing.expectEqualStrings("lib/mem.zig", lib.imports[0].path);
    try std.testing.expectEqual(1, project.referenced.items.len);

    try std.testing.expectEqualStrings("copy", (try project.reference("lib/mem.zig")).?.decls[0].name);
    try std.testing.expectEqual(lib, (try project.reference("lib/lib.zig")).?);
    try std.testing.expectEqual(null, try project.reference("lib/gone.zig"));
    try std.testing.expectEqual(null, try project.reference("lib/never.zig"));
    try std.testing.expectEqual(2, project.referenced.items.len);
}

test "a root that cannot be read is an error" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena.allocator());
    const root = try std.fs.path.join(arena.allocator(), &.{ base, "missing.zig" });
    try std.testing.expectError(error.FileNotFound, Project.open(arena.allocator(), std.testing.io, .{ .modules = &.{.{ .name = "missing", .path = root }} }));
}
