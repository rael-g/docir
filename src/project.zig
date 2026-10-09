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
//! The path a file gets in the document never names the machine it was read on, and has `/`
//! between its parts whatever the system it was read on writes there. The root
//! file of a module is given relative to `Options.base` when it lies under it, and under
//! the name of its module otherwise. The root of a reference-only module is always given
//! under the name of its module, so that its path does not depend on where it was read from. A file imported relatively is placed relative to its
//! importer, and an included file keeps the name it was included by.
//!
//! A file is read by the reader its extension names. A `.h` file is read as C or as C++,
//! whichever `c_source.Dialect.detect` finds it to be.
//!
//! A C file has the files it includes read before it, so that a macro one of them defines is
//! known when it stands in front of a declaration, the way a library marks what it exports.
//!
//! When the path of the first module is a directory there is no root file: every file under
//! it that a reader exists for is read, in the order of their paths, and the directory is
//! documented. The macros of every C and C++ file among them are known to all of them, since
//! nothing says where their headers are looked for. A directory whose name starts with a dot
//! is not entered, and neither is one
//! of `Options.excluded_dirs`, and neither it nor a file is read when its name is one of
//! `Options.excluded_names`. The parts of a C# type declared in parts are then joined
//! into one symbol, and a C++ member defined outside its class is joined to its declaration.
//!
//! In a directory there are no include directories to look in, so an include that is found
//! nowhere else is taken for the one file of the directory whose path ends with its name,
//! and for none when several do.
//!
//! Every file reached is read into an `ir.Unit`, so that a reference into it resolves, but only a file under
//! one of `Options.documented_dirs`, under none of `Options.excluded_dirs` and with none of
//! `Options.excluded_names` in its path, is marked as
//! documented. The exception is a module that
//! is `Module.reference_only`: an import into it is given its path without the file being
//! read, and `Project.reference` reads one such file when a reference goes through it. Its
//! files are never documented, and the includes in them are not followed.
//!
//! `Project.references` opens reference-only modules alone and reads nothing. It serves a
//! linker that was handed a document read elsewhere, since the paths it answers for are the
//! ones `Project.open` gave the imports of that document.

const std = @import("std");
const ir = @import("ir.zig");
const zig_source = @import("zig_source.zig");
const c_source = @import("c_source.zig");
const csharp_source = @import("csharp_source.zig");

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
    /// Directories on disk whose files are not documented, whatever contains them.
    excluded_dirs: []const []const u8 = &.{},
    /// Names of files and directories that are not documented, wherever they are, and that a
    /// directory read does not read or enter.
    excluded_names: []const []const u8 = &.{},
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
    /// The excluded directories as absolute paths.
    excluded: std.ArrayList([]const u8) = .empty,
    /// Path in the document of each file read by `open`, by its absolute path on disk.
    seen: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// What `open` read, dependencies before the files that import them.
    units: std.ArrayList(ir.Unit) = .empty,
    /// Where on disk each file of a reference-only module is, by its path in the document.
    postponed: std.StringHashMapUnmanaged(Postponed) = .empty,
    /// What `reference` answered for each path it was asked.
    answers: std.StringHashMapUnmanaged(?*const ir.Unit) = .empty,
    /// The macros without parameters that the C files read so far define.
    macros: std.ArrayList([]const u8) = .empty,
    /// What `reference` read, in the order it was asked for.
    referenced: std.ArrayList(*const ir.Unit) = .empty,
    /// Every file a directory read found, before any of them is read.
    walked: std.ArrayList(Walked) = .empty,

    const Walked = struct {
        key: []const u8,
        path: []const u8,
    };

    const Postponed = struct {
        key: []const u8,
        module: usize,
    };

    /// Reads the root of the first module and everything it imports, dependencies first,
    /// or every file under that root when it is a directory. Fails when there is no module
    /// or when a root file cannot be read or parsed.
    pub fn open(arena: Allocator, io: std.Io, options: Options) !Project {
        if (options.modules.len == 0) return error.NoModule;
        var project: Project = .{ .arena = arena, .io = io, .options = options };
        const root_key = try std.fs.path.resolve(arena, &.{options.modules[0].path});
        for (options.documented_dirs) |dir| try project.documented.append(arena, try std.fs.path.resolve(arena, &.{dir}));
        for (options.excluded_dirs) |dir| try project.excluded.append(arena, try std.fs.path.resolve(arena, &.{dir}));
        if (std.Io.Dir.cwd().openDir(io, root_key, .{ .iterate = true })) |opened| {
            var dir = opened;
            defer dir.close(io);
            try project.documented.append(arena, root_key);
            project.base = try std.fs.path.resolve(arena, &.{options.base});
            project.root = try project.slashed(within(project.base, root_key) orelse options.modules[0].name);
            try project.walk(dir, root_key);
            return project;
        } else |_| {}
        try project.documented.append(arena, std.fs.path.dirname(root_key) orelse ".");

        project.base = try std.fs.path.resolve(arena, &.{options.base});
        project.root = try project.modulePath(0, root_key);
        try project.seen.put(arena, root_key, project.root);
        const root_file = try project.read(root_key, project.root, 0, false);
        try project.units.append(arena, try project.link(root_key, 0, root_file, false));
        return project;
    }

    /// Takes every one of `modules` as reference-only, whatever `Module.reference_only`
    /// says, and reads none of them. `ModuleImport.module` indexes `modules`.
    pub fn references(arena: Allocator, io: std.Io, modules: []const Module) Allocator.Error!Project {
        const kept = try arena.dupe(Module, modules);
        for (kept) |*module| module.reference_only = true;
        var project: Project = .{ .arena = arena, .io = io, .options = .{ .modules = kept } };
        for (kept, 0..) |module, index| {
            const key = try std.fs.path.resolve(arena, &.{module.path});
            try project.postponed.put(arena, try project.modulePath(index, key), .{ .key = key, .module = index });
        }
        return project;
    }

    /// The file of a reference-only module that an import was given `path` for, read on
    /// the first call. Null when `path` is not such a file or it cannot be read.
    pub fn reference(self: *Project, path: []const u8) Allocator.Error!?*const ir.Unit {
        if (self.answers.get(path)) |known| return known;
        const postponed = self.postponed.get(path) orelse return null;
        try self.answers.put(self.arena, path, null);
        const read_file = self.read(postponed.key, path, postponed.module, true) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return null,
        };
        const unit = try self.arena.create(ir.Unit);
        unit.* = try self.link(postponed.key, postponed.module, read_file, true);
        try self.answers.put(self.arena, path, unit);
        try self.referenced.append(self.arena, unit);
        return unit;
    }

    fn walk(self: *Project, dir: std.Io.Dir, root_key: []const u8) !void {
        var found: std.ArrayList([]const u8) = .empty;
        var walker = try dir.walk(self.arena);
        defer walker.deinit();
        next: while (try walker.next(self.io)) |entry| {
            if (entry.kind != .file) continue;
            const extension = std.fs.path.extension(entry.basename);
            const readable = std.mem.eql(u8, extension, ".zig") or c_source.Dialect.of(extension) != null or csharp_source.reads(extension);
            if (!readable) continue;
            var parts = std.mem.tokenizeAny(u8, entry.path, "/\\");
            while (parts.next()) |part| {
                if (part[0] == '.' or self.isExcludedName(part)) continue :next;
            }
            const key = try std.fs.path.join(self.arena, &.{ root_key, entry.path });
            for (self.excluded.items) |excluded| {
                if (within(excluded, key) != null) continue :next;
            }
            try found.append(self.arena, key);
        }
        std.mem.sort([]const u8, found.items, {}, struct {
            fn before(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.before);
        for (found.items) |key| {
            const extension = std.fs.path.extension(key);
            const by_extension = c_source.Dialect.of(extension) orelse continue;
            const source = std.Io.Dir.cwd().readFileAllocOptions(self.io, key, self.arena, .unlimited, .of(u8), 0) catch continue;
            const dialect = if (std.mem.eql(u8, extension, ".h")) c_source.Dialect.detect(source) catch continue else by_extension;
            const outlined = c_source.outline(self.arena, dialect, source) catch continue;
            try self.macros.appendSlice(self.arena, outlined.macros);
        }
        for (found.items) |key| {
            const path = within(self.base, key) orelse try std.fs.path.join(self.arena, &.{ self.options.modules[0].name, within(root_key, key).? });
            try self.walked.append(self.arena, .{ .key = key, .path = try self.slashed(path) });
        }
        for (self.walked.items) |file| _ = try self.visit(file.key, file.path, 0);
        try csharp_source.join(self.arena, self.units.items);
        try c_source.join(self.arena, self.units.items);
    }

    fn slashed(self: *Project, path: []const u8) Allocator.Error![]const u8 {
        const out = try self.arena.dupe(u8, path);
        if (std.fs.path.sep != '/') std.mem.replaceScalar(u8, out, std.fs.path.sep, '/');
        return out;
    }

    fn modulePath(self: *Project, module: usize, key: []const u8) Allocator.Error![]const u8 {
        const described = self.options.modules[module];
        if (!described.reference_only) {
            if (within(self.base, key)) |path| return self.slashed(path);
        }
        return self.slashed(try std.fs.path.join(self.arena, &.{ described.name, std.fs.path.basename(key) }));
    }

    fn read(self: *Project, key: []const u8, path: []const u8, module: usize, postpone: bool) !ir.Unit {
        const source = try std.Io.Dir.cwd().readFileAllocOptions(self.io, key, self.arena, .unlimited, .of(u8), 0);
        const extension = std.fs.path.extension(key);
        if (std.mem.eql(u8, extension, ".zig")) return zig_source.read(self.arena, path, source);
        if (csharp_source.reads(extension)) return csharp_source.read(self.arena, path, source);
        const by_extension = c_source.Dialect.of(extension) orelse return error.NoReaderForFile;
        const dialect = if (std.mem.eql(u8, extension, ".h")) try c_source.Dialect.detect(source) else by_extension;
        const found = try c_source.outline(self.arena, dialect, source);
        for (found.includes) |name| _ = try self.follow(key, path, module, .{ .name = name, .kind = .include }, postpone);
        try self.macros.appendSlice(self.arena, found.macros);
        return c_source.read(self.arena, dialect, path, source, self.macros.items);
    }

    fn link(self: *Project, key: []const u8, module: usize, read_unit: ir.Unit, postpone: bool) Allocator.Error!ir.Unit {
        var unit = read_unit;
        const imports = try self.arena.dupe(ir.Import, unit.file.imports);
        for (imports) |*import| import.path = try self.follow(key, unit.file.path, module, import.*, postpone) orelse "";
        unit.file.imports = imports;
        unit.file.documented = false;
        if (postpone) return unit;
        for (self.documented.items) |dir| {
            if (within(dir, key) != null) unit.file.documented = true;
        }
        for (self.excluded.items) |dir| {
            if (within(dir, key) != null) unit.file.documented = false;
        }
        var parts = std.mem.tokenizeAny(u8, key, "/\\");
        while (parts.next()) |part| {
            if (self.isExcludedName(part)) unit.file.documented = false;
        }
        return unit;
    }

    fn isExcludedName(self: *const Project, part: []const u8) bool {
        for (self.options.excluded_names) |name| {
            if (std.mem.eql(u8, name, part)) return true;
        }
        return false;
    }

    fn follow(self: *Project, importer_key: []const u8, importer_path: []const u8, module: usize, import: ir.Import, postpone: bool) Allocator.Error!?[]const u8 {
        const importer_dir = std.fs.path.dirname(importer_key) orelse ".";
        const importer_path_dir = std.fs.path.dirname(importer_path) orelse "";
        switch (import.kind) {
            .file => return self.reach(
                try std.fs.path.resolve(self.arena, &.{ importer_dir, import.name }),
                try self.slashed(try std.fs.path.resolve(self.arena, &.{ importer_path_dir, import.name })),
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
                if (c_source.Dialect.of(std.fs.path.extension(importer_key)) != null) {
                    const beside = try self.visit(
                        try std.fs.path.resolve(self.arena, &.{ importer_dir, import.name }),
                        try self.slashed(try std.fs.path.resolve(self.arena, &.{ importer_path_dir, import.name })),
                        module,
                    );
                    if (beside) |path| return path;
                }
                for (self.options.modules[module].include_dirs) |dir| {
                    const found = try self.visit(try std.fs.path.resolve(self.arena, &.{ dir, import.name }), try self.slashed(import.name), module);
                    if (found) |path| return path;
                }
                var only: ?Walked = null;
                for (self.walked.items) |file| {
                    if (file.path.len <= import.name.len or !std.mem.endsWith(u8, file.path, import.name)) continue;
                    if (file.path[file.path.len - import.name.len - 1] != '/') continue;
                    if (only != null) return null;
                    only = file;
                }
                const named = only orelse return null;
                return self.visit(named.key, named.path, module);
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
        const file = self.read(key, path, module, false) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                _ = self.seen.remove(key);
                return null;
            },
        };
        try self.units.append(self.arena, try self.link(key, module, file, false));
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

fn fileNamed(project: Project, path: []const u8) !ir.File {
    for (project.units.items) |unit| {
        if (std.mem.eql(u8, unit.file.path, path)) return unit.file;
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
    try std.testing.expectEqual(6, project.units.items.len);
    try std.testing.expectEqualStrings("src/main.zig", project.units.items[5].file.path);

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

test "a file under an excluded directory is read and not documented" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "app/main.zig", "const other = @import(\"vendor/other.zig\");\n");
    try writeFile(tmp.dir, "app/vendor/other.zig", "pub fn theirs() void {}\n");

    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena.allocator());
    const join = std.fs.path.join;
    const project = try Project.open(arena.allocator(), std.testing.io, .{
        .modules = &.{.{ .name = "app", .path = try join(arena.allocator(), &.{ base, "app/main.zig" }) }},
        .base = try join(arena.allocator(), &.{ base, "app" }),
        .excluded_dirs = &.{try join(arena.allocator(), &.{ base, "app/vendor" })},
    });
    try std.testing.expect((try fileNamed(project, "main.zig")).documented);
    try std.testing.expect(!(try fileNamed(project, "vendor/other.zig")).documented);
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

    try std.testing.expectEqual(1, project.units.items.len);
    try std.testing.expectEqualStrings("lib/lib.zig", project.units.items[0].file.imports[0].path);
    try std.testing.expectEqual(0, project.referenced.items.len);

    const lib = (try project.reference("lib/lib.zig")).?;
    try std.testing.expect(!lib.file.documented);
    try std.testing.expectEqualStrings("lib/mem.zig", lib.file.imports[0].path);
    try std.testing.expectEqual(1, project.referenced.items.len);

    try std.testing.expectEqualStrings("copy", (try project.reference("lib/mem.zig")).?.symbol.members[0].name);
    try std.testing.expectEqual(lib, (try project.reference("lib/lib.zig")).?);
    try std.testing.expectEqual(null, try project.reference("lib/gone.zig"));
    try std.testing.expectEqual(null, try project.reference("lib/never.zig"));
    try std.testing.expectEqual(2, project.referenced.items.len);
}

test "reference-only modules opened alone answer for the paths an import was given" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "lib/lib.zig", "pub const mem = @import(\"mem.zig\");\n");
    try writeFile(tmp.dir, "lib/mem.zig", "pub fn copy() void {}\n");

    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena.allocator());
    var project = try Project.references(arena.allocator(), std.testing.io, &.{
        .{ .name = "lib", .path = try std.fs.path.join(arena.allocator(), &.{ base, "lib/lib.zig" }) },
    });
    try std.testing.expectEqual(0, project.units.items.len);
    const lib = (try project.reference("lib/lib.zig")).?;
    try std.testing.expectEqualStrings("lib/mem.zig", lib.file.imports[0].path);
    try std.testing.expectEqualStrings("copy", (try project.reference("lib/mem.zig")).?.symbol.members[0].name);
    try std.testing.expectEqual(null, try project.reference("other/lib.zig"));
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

test "a directory given as the root has every file a reader exists for read, with partial types joined" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "lib/Pool.cs", "namespace Ke { public partial class Pool { public void Start() { } } }\n");
    try writeFile(tmp.dir, "lib/Parts/Pool.Stop.cs", "namespace Ke { public partial class Pool { public void Stop() { } } }\n");
    try writeFile(tmp.dir, "lib/obj/Generated.cs", "class Generated { }\n");
    try writeFile(tmp.dir, "lib/.hidden/Hidden.cs", "class Hidden { }\n");
    try writeFile(tmp.dir, "lib/notes.txt", "nothing\n");

    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena.allocator());
    const join = std.fs.path.join;
    const project = try Project.open(arena.allocator(), std.testing.io, .{
        .modules = &.{.{ .name = "lib", .path = try join(arena.allocator(), &.{ base, "lib" }) }},
        .base = base,
        .excluded_dirs = &.{try join(arena.allocator(), &.{ base, "lib/obj" })},
    });

    try std.testing.expectEqual(2, project.units.items.len);
    try std.testing.expectEqualStrings("lib/Parts/Pool.Stop.cs", project.units.items[0].file.path);
    try std.testing.expect(project.units.items[0].file.documented);
    const pool = project.units.items[0].symbol.members[0].members[0];
    try std.testing.expectEqual(2, pool.members.len);
    try std.testing.expectEqual(0, project.units.items[1].symbol.members[0].members.len);
}

test "in a directory an include is the one file whose path ends with its name" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "lib/c/pool/ke/pool.h", "void stop(void);\n");
    try writeFile(tmp.dir, "lib/c/a/ke/twice.h", "void a(void);\n");
    try writeFile(tmp.dir, "lib/c/b/ke/twice.h", "void b(void);\n");
    try writeFile(tmp.dir, "lib/zig/main.zig",
        \\const c = @cImport({
        \\    @cInclude("ke/pool.h");
        \\    @cInclude("ke/twice.h");
        \\    @cInclude("e/pool.h");
        \\});
    );

    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena.allocator());
    const project = try Project.open(arena.allocator(), std.testing.io, .{
        .modules = &.{.{ .name = "lib", .path = try std.fs.path.join(arena.allocator(), &.{ base, "lib" }) }},
        .base = base,
    });

    try std.testing.expectEqual(4, project.units.items.len);
    const main = try fileNamed(project, "lib/zig/main.zig");
    try std.testing.expectEqualStrings("lib/c/pool/ke/pool.h", main.imports[0].path);
    try std.testing.expectEqualStrings("", main.imports[1].path);
    try std.testing.expectEqualStrings("", main.imports[2].path);
}

test "a file or a directory with an excluded name is left out of a directory read" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "lib/a/build.zig", "pub fn build() void {}\n");
    try writeFile(tmp.dir, "lib/a/src/main.zig", "pub fn run() void {}\n");
    try writeFile(tmp.dir, "lib/a/vendor/dep.zig", "pub fn dep() void {}\n");

    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena.allocator());
    const project = try Project.open(arena.allocator(), std.testing.io, .{
        .modules = &.{.{ .name = "lib", .path = try std.fs.path.join(arena.allocator(), &.{ base, "lib" }) }},
        .base = base,
        .excluded_names = &.{ "build.zig", "vendor" },
    });

    try std.testing.expectEqual(1, project.units.items.len);
    try std.testing.expectEqualStrings("lib/a/src/main.zig", project.units.items[0].file.path);
}
