//! The build side of docir.
//!
//! A build that depends on this package reaches these declarations with `@import("docir")`
//! in its own `build.zig`. `addDocsStep` is the short form: one call at the end of a build
//! function documents every artifact that build installs. `addDocs` documents one module
//! chosen by the caller. Both take what there is to read from the modules themselves: the
//! root source file, the imports and the include directories each was given. `addSourceDocs`
//! documents a directory of sources that no module of the build describes.
//!
//! Nothing is read by the build itself. The steps run the program of this package, once per
//! stage, reading, then linking, then writing. The caller hands that program over, which in a
//! build that depends on this package is `b.dependency("docir", .{}).artifact("docir")`.
//! Two files come out per module, `<name>.json` and `<name>.md`, the second rendered from
//! the first.

const std = @import("std");

/// How the documentation of one module is produced.
pub const Options = struct {
    /// Base name of the two files written, `<name>.json` and `<name>.md`.
    name: []const u8,
    /// First-level heading of the Markdown file. Defaults to `name`.
    title: ?[]const u8 = null,
    /// Fails the step, writing nothing, when a mention names nothing.
    strict: bool = false,
    /// Names declared outside the sources, such as the types of a library that is only
    /// used, which a mention may use without being a problem.
    external_names: []const []const u8 = &.{},
    /// Directories whose files are documented, besides the build root of the module.
    documented_dirs: []const std.Build.LazyPath = &.{},
    /// Directories whose files are read and not documented, such as vendored code.
    excluded_dirs: []const std.Build.LazyPath = &.{},
    /// Directory under the install prefix that receives the files.
    install_subdir: []const u8 = "docs",
    /// Directory of the source tree, relative to the build root, that receives the files
    /// instead of one under the install prefix.
    source_dir: ?[]const u8 = null,
    /// Also writes the Markdown as a directory of pages, `<name>/` under `install_subdir`,
    /// with an `index.md` and a `toc.yml`, for a tool that makes a site of them.
    pages: bool = false,
    /// Directories and files, as the document names them, each written before the next and
    /// all of them before the files under none. Empty for the order of the paths.
    order: []const []const u8 = &.{},
};

/// How the documentation of every installed artifact is produced.
pub const StepOptions = struct {
    /// Fails the step when a mention names nothing.
    strict: bool = false,
    /// Directories whose files are documented, besides the build root of each module.
    documented_dirs: []const std.Build.LazyPath = &.{},
    /// Directories whose files are read and not documented, such as vendored code.
    excluded_dirs: []const std.Build.LazyPath = &.{},
    /// Directory under the install prefix that receives the files.
    install_subdir: []const u8 = "docs",
    /// Directory of the source tree, relative to the build root, that receives the files
    /// instead of one under the install prefix.
    source_dir: ?[]const u8 = null,
    /// Directories and files, as the document names them, each written before the next and
    /// all of them before the files under none. Empty for the order of the paths.
    order: []const []const u8 = &.{},
};

/// Registers the top-level step run by `zig build docs`, which documents the root module of
/// every artifact `b` installs, each under the name of its artifact, and returns it. The
/// work is done by running `program`. An artifact whose root module has no Zig source is
/// left out, and so is `program` itself. Only the artifacts installed before the call are
/// seen, so it belongs at the end of a build function.
pub fn addDocsStep(b: *std.Build, program: *std.Build.Step.Compile, options: StepOptions) *std.Build.Step {
    const all = b.step("docs", "Write the documentation of every installed artifact");
    var documented: std.ArrayList(*std.Build.Module) = .empty;
    for (b.getInstallStep().dependencies.items) |dependency| {
        const install = dependency.cast(std.Build.Step.InstallArtifact) orelse continue;
        if (install.artifact == program) continue;
        const module = install.artifact.root_module;
        if (module.root_source_file == null) continue;
        if (std.mem.indexOfScalar(*std.Build.Module, documented.items, module) != null) continue;
        documented.append(b.allocator, module) catch @panic("OOM");
        all.dependOn(addDocs(b, program, module, .{
            .name = install.artifact.name,
            .strict = options.strict,
            .documented_dirs = options.documented_dirs,
            .excluded_dirs = options.excluded_dirs,
            .install_subdir = options.install_subdir,
            .source_dir = options.source_dir,
            .order = options.order,
        }));
    }
    return all;
}

/// Returns a step that documents `module` by running `program`: its root source file, the
/// files that file imports, the modules reachable through its imports, each with its own
/// imports, and the headers found in the include directories of each. The standard library
/// is a target of references and is not documented. The step leaves a JSON document and the
/// Markdown rendered from it where `options` says. Imports given to a module after the call
/// are not seen.
pub fn addDocs(b: *std.Build, program: *std.Build.Step.Compile, module: *std.Build.Module, options: Options) *std.Build.Step {
    var graph: std.ArrayList(*std.Build.Module) = .empty;
    graph.append(b.allocator, module) catch @panic("OOM");
    var next: usize = 0;
    while (next < graph.items.len) : (next += 1) {
        for (graph.items[next].import_table.values()) |imported| {
            if (imported.root_source_file == null) continue;
            if (std.mem.indexOfScalar(*std.Build.Module, graph.items, imported) != null) continue;
            graph.append(b.allocator, imported) catch @panic("OOM");
        }
    }

    const names = b.allocator.alloc(?[]const u8, graph.items.len) catch @panic("OOM");
    @memset(names, null);
    names[0] = options.name;
    for (graph.items) |member| {
        for (member.import_table.keys(), member.import_table.values()) |name, imported| {
            const index = std.mem.indexOfScalar(*std.Build.Module, graph.items, imported) orelse continue;
            if (names[index] != null) continue;
            const taken = for (names) |other| {
                if (other != null and std.mem.eql(u8, other.?, name)) break true;
            } else false;
            names[index] = if (taken) b.fmt("{s}-{d}", .{ name, index }) else name;
        }
    }

    const library: ?std.Build.LazyPath = if (b.graph.zig_lib_directory.path) |directory|
        .{ .cwd_relative = b.pathJoin(&.{ directory, "std", "std.zig" }) }
    else
        null;

    const read = b.addRunArtifact(program);
    read.addArg("read");
    read.addFileArg(module.root_source_file.?);
    read.addArg("--depfile");
    _ = read.addDepFileOutputArg("read.d");
    read.addArgs(&.{ "--name", options.name });
    read.addArg("--base");
    read.addDirectoryArg(module.owner.path(""));
    read.addArg("--documented");
    read.addDirectoryArg(module.owner.path(""));
    for (graph.items, names, 0..) |member, name, index| {
        if (index != 0) {
            read.addArg("--module");
            read.addPrefixedFileArg(b.fmt("{s}=", .{name.?}), member.root_source_file.?);
        }
        for (member.import_table.keys(), member.import_table.values()) |import_name, imported| {
            const target = std.mem.indexOfScalar(*std.Build.Module, graph.items, imported) orelse continue;
            read.addArgs(&.{ "--import", b.fmt("{s}:{s}={s}", .{ name.?, import_name, names[target].? }) });
        }
        for (member.include_dirs.items) |include_dir| {
            const path = switch (include_dir) {
                .path, .path_system, .path_after => |path| path,
                else => continue,
            };
            read.addArg("--include");
            read.addPrefixedDirectoryArg(b.fmt("{s}=", .{name.?}), path);
        }
    }
    if (library) |root| {
        read.addArg("--reference");
        read.addPrefixedFileArg("std=", root);
    }
    return finish(b, program, read, library, options);
}

/// Returns a step that documents every source file under `directory` that a reader exists
/// for, by running `program`. This is how sources that no module of the build describes are
/// documented, such as a C# project. The directories of `Options.excluded_dirs` are not
/// entered. The step leaves a JSON document and the Markdown rendered from it where
/// `options` says.
pub fn addSourceDocs(b: *std.Build, program: *std.Build.Step.Compile, directory: std.Build.LazyPath, options: Options) *std.Build.Step {
    const read = b.addRunArtifact(program);
    read.has_side_effects = true;
    read.addArg("read");
    read.addDirectoryArg(directory);
    read.addArgs(&.{ "--name", options.name });
    read.addArg("--base");
    read.addDirectoryArg(directory);
    return finish(b, program, read, null, options);
}

fn finish(b: *std.Build, program: *std.Build.Step.Compile, read: *std.Build.Step.Run, library: ?std.Build.LazyPath, options: Options) *std.Build.Step {
    for (options.documented_dirs) |dir| {
        read.addArg("--documented");
        read.addDirectoryArg(dir);
    }
    for (options.excluded_dirs) |dir| {
        read.addArg("--excluded");
        read.addDirectoryArg(dir);
    }
    read.addArg("-o");
    const unlinked = read.addOutputFileArg(b.fmt("{s}.json", .{options.name}));

    const link = b.addRunArtifact(program);
    link.addArg("link");
    link.addFileArg(unlinked);
    if (library) |root| {
        link.addArg("--reference");
        link.addPrefixedFileArg("std=", root);
    }
    for (options.external_names) |name| link.addArgs(&.{ "--external", name });
    if (options.strict) link.addArg("--strict");
    link.addArg("-o");
    const linked = link.addOutputFileArg(b.fmt("{s}.json", .{options.name}));

    const write = b.addRunArtifact(program);
    write.addArgs(&.{ "write", "markdown" });
    write.addFileArg(linked);
    for (options.order) |prefix| write.addArgs(&.{ "--order", prefix });
    write.addArgs(&.{ "--title", options.title orelse options.name, "-o" });
    const rendered = write.addOutputFileArg(b.fmt("{s}.md", .{options.name}));

    var paged: ?*std.Build.Step = null;
    if (options.pages) {
        const split = b.addRunArtifact(program);
        split.addArgs(&.{ "write", "markdown" });
        split.addFileArg(linked);
        for (options.order) |prefix| split.addArgs(&.{ "--order", prefix });
        split.addArgs(&.{ "--title", options.title orelse options.name, "--pages", "-o" });
        const directory = split.addOutputDirectoryArg(options.name);
        paged = &b.addInstallDirectory(.{
            .source_dir = directory,
            .install_dir = .prefix,
            .install_subdir = b.pathJoin(&.{ options.install_subdir, options.name }),
        }).step;
    }

    const json_name = b.fmt("{s}.json", .{options.name});
    const markdown_name = b.fmt("{s}.md", .{options.name});
    if (options.source_dir) |dir| {
        const update = b.addUpdateSourceFiles();
        update.addCopyFileToSource(linked, b.pathJoin(&.{ dir, json_name }));
        update.addCopyFileToSource(rendered, b.pathJoin(&.{ dir, markdown_name }));
        if (paged) |step| update.step.dependOn(step);
        return &update.step;
    }
    const done = b.allocator.create(std.Build.Step) catch @panic("OOM");
    done.* = .init(.{ .id = .custom, .name = b.fmt("docir {s}", .{options.name}), .owner = b });
    done.dependOn(&b.addInstallFile(linked, b.pathJoin(&.{ options.install_subdir, json_name })).step);
    done.dependOn(&b.addInstallFile(rendered, b.pathJoin(&.{ options.install_subdir, markdown_name })).step);
    if (paged) |step| done.dependOn(step);
    return done;
}

/// The build of docir itself: its module, its program, its tests and its own documentation.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const tree_sitter = b.dependency("tree_sitter", .{ .target = target, .optimize = optimize });
    const tree_sitter_c = b.dependency("tree_sitter_c", .{ .target = target, .optimize = optimize, .@"build-shared" = false });

    const mod = b.addModule("docir", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "tree_sitter", .module = tree_sitter.module("tree_sitter") },
            .{ .name = "tree_sitter_c", .module = tree_sitter_c.module("tree-sitter-c") },
        },
    });

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", @import("build.zig.zon").version);
    mod.addOptions("build_options", build_options);

    const tree_sitter_cpp = b.dependency("tree_sitter_cpp", .{});
    mod.addCSourceFiles(.{
        .root = tree_sitter_cpp.path("src"),
        .files = &.{ "parser.c", "scanner.c" },
        .flags = &.{ "-std=c11", "-fno-sanitize=function" },
    });
    mod.addIncludePath(tree_sitter_cpp.path("src"));
    const tree_sitter_c_sharp = b.dependency("tree_sitter_c_sharp", .{});
    mod.addCSourceFiles(.{
        .root = tree_sitter_c_sharp.path("src"),
        .files = &.{ "parser.c", "scanner.c" },
        .flags = &.{ "-std=c11", "-fno-sanitize=function" },
    });
    mod.addIncludePath(tree_sitter_c_sharp.path("src"));
    mod.link_libc = true;

    const program = b.addExecutable(.{
        .name = "docir",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "docir", .module = mod }},
        }),
    });
    b.installArtifact(program);

    const tests = b.addTest(.{ .root_module = mod });
    b.step("test", "Run the tests").dependOn(&b.addRunArtifact(tests).step);

    const docs_step = b.step("docs", "Document docir with itself");
    docs_step.dependOn(addDocs(b, program, program.root_module, .{
        .name = "docir",
        .strict = true,
        .excluded_dirs = &.{ b.path("src/markdown"), b.path("zig-pkg") },
        .source_dir = "docs",
    }));
    const schema = b.addRunArtifact(program);
    schema.addArgs(&.{ "schema", "-o" });
    const schema_file = schema.addOutputFileArg("docir.schema.json");
    const schema_update = b.addUpdateSourceFiles();
    schema_update.addCopyFileToSource(schema_file, "docs/docir.schema.json");
    docs_step.dependOn(&schema_update.step);
    docs_step.dependOn(addDocs(b, program, b.createModule(.{ .root_source_file = b.path("build.zig") }), .{
        .name = "build",
        .title = "docir, in a build",
        .strict = true,
        .source_dir = "docs",
    }));
}
