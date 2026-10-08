const std = @import("std");
const zigdoc = @import("src/root.zig");

/// How the documentation of one module is produced.
pub const Options = struct {
    /// Base name of the two files written, `<name>.json` and `<name>.md`.
    name: []const u8,
    /// First-level heading of the Markdown file. Defaults to `name`.
    title: ?[]const u8 = null,
    /// Fails the step, writing nothing, when a citation names nothing.
    strict: bool = false,
    /// Directories whose files are documented, besides the build root of the module.
    documented_dirs: []const std.Build.LazyPath = &.{},
    /// Directory under the install prefix that receives the files.
    install_subdir: []const u8 = "docs",
};

/// How the documentation of every installed artifact is produced.
pub const StepOptions = struct {
    /// Fails the step when a citation names nothing.
    strict: bool = false,
    /// Directories whose files are documented, besides the build root of each module.
    documented_dirs: []const std.Build.LazyPath = &.{},
    /// Directory under the install prefix that receives the files.
    install_subdir: []const u8 = "docs",
};

/// Registers a top-level step named `docs` that documents the root module of every
/// artifact `b` installs, each under the name of its artifact, and returns it. An artifact
/// whose root module has no Zig source is left out. Only the artifacts installed before
/// the call are seen, so it belongs at the end of a build function.
pub fn addDocsStep(b: *std.Build, options: StepOptions) *std.Build.Step {
    const all = b.step("docs", "Write the documentation of every installed artifact");
    var documented: std.ArrayList(*std.Build.Module) = .empty;
    for (b.getInstallStep().dependencies.items) |dependency| {
        const install = dependency.cast(std.Build.Step.InstallArtifact) orelse continue;
        const module = install.artifact.root_module;
        if (module.root_source_file == null) continue;
        if (std.mem.indexOfScalar(*std.Build.Module, documented.items, module) != null) continue;
        documented.append(b.allocator, module) catch @panic("OOM");
        all.dependOn(addDocs(b, module, .{
            .name = install.artifact.name,
            .strict = options.strict,
            .documented_dirs = options.documented_dirs,
            .install_subdir = options.install_subdir,
        }));
    }
    return all;
}

/// Returns a step that documents `module`: its root source file, the files that file
/// imports, the modules reachable through its imports, each with its own imports, and the
/// headers found in the include directories of each. The standard library is a target of
/// references and is not documented. The step writes a JSON document and the Markdown
/// rendered from it. Imports given to a module after the call are not seen.
pub fn addDocs(b: *std.Build, module: *std.Build.Module, options: Options) *std.Build.Step {
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

    const docs = b.allocator.create(DocsStep) catch @panic("OOM");
    docs.* = .{
        .step = .init(.{ .id = .custom, .name = b.fmt("zigdoc {s}", .{options.name}), .owner = b, .makeFn = DocsStep.make }),
        .graph = graph.items,
        .options = options,
    };
    for (options.documented_dirs) |dir| dir.addStepDependencies(&docs.step);
    for (graph.items) |member| {
        if (member.root_source_file) |root| root.addStepDependencies(&docs.step);
        for (member.include_dirs.items) |include_dir| {
            if (includePath(include_dir)) |path| path.addStepDependencies(&docs.step);
        }
    }
    return &docs.step;
}

fn includePath(include_dir: std.Build.Module.IncludeDir) ?std.Build.LazyPath {
    return switch (include_dir) {
        .path, .path_system, .path_after => |path| path,
        else => null,
    };
}

const DocsStep = struct {
    step: std.Build.Step,
    graph: []const *std.Build.Module,
    options: Options,

    fn make(step: *std.Build.Step, _: std.Build.Step.MakeOptions) anyerror!void {
        const docs: *DocsStep = @fieldParentPtr("step", step);
        const b = step.owner;
        const arena = b.allocator;
        const io = b.graph.io;
        const graph = docs.graph;
        const options = docs.options;

        const root_file = graph[0].root_source_file orelse return step.fail("the module has no root source file", .{});
        const root = root_file.getPath2(graph[0].owner, step);
        const build_root = graph[0].owner.build_root.path orelse ".";

        const names = try arena.alloc(?[]const u8, graph.len);
        @memset(names, null);
        names[0] = options.name;
        for (graph) |member| {
            for (member.import_table.keys(), member.import_table.values()) |name, imported| {
                const index = std.mem.indexOfScalar(*std.Build.Module, graph, imported) orelse continue;
                if (names[index] != null) continue;
                const taken = for (names) |other| {
                    if (other != null and std.mem.eql(u8, other.?, name)) break true;
                } else false;
                names[index] = if (taken) b.fmt("{s}-{d}", .{ name, index }) else name;
            }
        }

        const library = b.graph.zig_lib_directory.path;
        var modules: std.ArrayList(zigdoc.project.Module) = .empty;
        for (graph, names) |member, name| {
            var imports: std.ArrayList(zigdoc.project.ModuleImport) = .empty;
            for (member.import_table.keys(), member.import_table.values()) |import_name, imported| {
                const index = std.mem.indexOfScalar(*std.Build.Module, graph, imported) orelse continue;
                try imports.append(arena, .{ .name = import_name, .module = index });
            }
            if (library != null and !member.import_table.contains("std")) try imports.append(arena, .{ .name = "std", .module = graph.len });
            var include_dirs: std.ArrayList([]const u8) = .empty;
            for (member.include_dirs.items) |include_dir| {
                if (includePath(include_dir)) |path| try include_dirs.append(arena, path.getPath2(member.owner, step));
            }
            try modules.append(arena, .{
                .name = name.?,
                .path = member.root_source_file.?.getPath2(member.owner, step),
                .imports = imports.items,
                .include_dirs = include_dirs.items,
            });
        }
        if (library) |directory| try modules.append(arena, .{
            .name = "std",
            .path = b.pathJoin(&.{ directory, "std", "std.zig" }),
            .reference_only = true,
        });

        var documented_dirs: std.ArrayList([]const u8) = .empty;
        try documented_dirs.append(arena, build_root);
        for (options.documented_dirs) |dir| try documented_dirs.append(arena, dir.getPath2(b, step));

        const extraction = zigdoc.extract(arena, io, .{
            .modules = modules.items,
            .base = build_root,
            .documented_dirs = documented_dirs.items,
        }) catch |err| return step.fail("cannot document {s}: {t}", .{ root, err });

        for (extraction.problems) |problem| {
            const message = switch (problem.kind) {
                .symbol => b.fmt("{s}: `{s}`, cited by {s}, is not declared", .{ problem.path, problem.citation, problem.owner }),
                .parameter => b.fmt("{s}: {s} documents a parameter `{s}` it does not have", .{ problem.path, problem.owner, problem.citation }),
            };
            if (options.strict) try step.addError("{s}", .{message}) else std.log.warn("{s}", .{message});
        }
        if (options.strict and extraction.problems.len != 0) return error.MakeFailed;

        var json: std.Io.Writer.Allocating = .init(arena);
        try zigdoc.model.writeJson(&json.writer, extraction.document);
        const json_path = b.getInstallPath(.prefix, b.pathJoin(&.{ options.install_subdir, b.fmt("{s}.json", .{options.name}) }));
        const cwd = std.Io.Dir.cwd();
        try cwd.createDirPath(io, std.fs.path.dirname(json_path).?);
        try cwd.writeFile(io, .{ .sub_path = json_path, .data = json.written() });

        const stored = try cwd.readFileAlloc(io, json_path, arena, .unlimited);
        const document = try zigdoc.model.readJson(arena, stored);
        var text: std.Io.Writer.Allocating = .init(arena);
        try zigdoc.markdown.write(arena, &text.writer, options.title orelse options.name, document);
        const markdown_path = b.getInstallPath(.prefix, b.pathJoin(&.{ options.install_subdir, b.fmt("{s}.md", .{options.name}) }));
        try cwd.writeFile(io, .{ .sub_path = markdown_path, .data = text.written() });
    }
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("zigdoc", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tests = b.addTest(.{ .root_module = mod });
    b.step("test", "Run the tests").dependOn(&b.addRunArtifact(tests).step);

    b.step("docs", "Document zigdoc with itself").dependOn(addDocs(b, mod, .{ .name = "zigdoc", .strict = true }));
}
