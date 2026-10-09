# docir, in a build

The build side of docir.

A build that depends on this package reaches these declarations with `@import("docir")`
in its own `build.zig`. [`addDocsStep`](#adddocsstep) is the short form: one call at the end of a build
function documents every artifact that build installs. [`addDocs`](#adddocs) documents one module
chosen by the caller. Both take what there is to read from the modules themselves: the
root source file, the imports and the include directories each was given. [`addSourceDocs`](#addsourcedocs)
documents a directory of sources that no module of the build describes.

Nothing is read by the build itself. The steps run the program of this package, once per
stage, reading, then linking, then writing. The caller hands that program over, which in a
build that depends on this package is `b.dependency("docir", .{}).artifact("docir")`.
Two files come out per module, `<name>.json` and `<name>.md`, the second rendered from
the first.

## `Options`

```zig
pub const Options = struct
```

How the documentation of one module is produced.

### `Options.name`

```zig
name: []const u8
```

Base name of the two files written, `<name>.json` and `<name>.md`.

### `Options.title`

```zig
title: ?[]const u8 = null
```

First-level heading of the Markdown file. Defaults to [`name`](#optionsname).

### `Options.strict`

```zig
strict: bool = false
```

Fails the step, writing nothing, when a mention names nothing.

### `Options.external_names`

```zig
external_names: []const []const u8 = &.{}
```

Names declared outside the sources, such as the types of a library that is only
used, which a mention may use without being a problem.

### `Options.documented_dirs`

```zig
documented_dirs: []const std.Build.LazyPath = &.{}
```

Directories whose files are documented, besides the build root of the module.

### `Options.excluded_dirs`

```zig
excluded_dirs: []const std.Build.LazyPath = &.{}
```

Directories whose files are read and not documented, such as vendored code.

### `Options.install_subdir`

```zig
install_subdir: []const u8 = "docs"
```

Directory under the install prefix that receives the files.

### `Options.source_dir`

```zig
source_dir: ?[]const u8 = null
```

Directory of the source tree, relative to the build root, that receives the files
instead of one under the install prefix.

### `Options.pages`

```zig
pages: bool = false
```

Also writes the Markdown as a directory of pages, `<name>/` under [`install_subdir`](#optionsinstall_subdir),
with an `index.md` and a `toc.yml`, for a tool that makes a site of them.

## `StepOptions`

```zig
pub const StepOptions = struct
```

How the documentation of every installed artifact is produced.

### `StepOptions.strict`

```zig
strict: bool = false
```

Fails the step when a mention names nothing.

### `StepOptions.documented_dirs`

```zig
documented_dirs: []const std.Build.LazyPath = &.{}
```

Directories whose files are documented, besides the build root of each module.

### `StepOptions.excluded_dirs`

```zig
excluded_dirs: []const std.Build.LazyPath = &.{}
```

Directories whose files are read and not documented, such as vendored code.

### `StepOptions.install_subdir`

```zig
install_subdir: []const u8 = "docs"
```

Directory under the install prefix that receives the files.

### `StepOptions.source_dir`

```zig
source_dir: ?[]const u8 = null
```

Directory of the source tree, relative to the build root, that receives the files
instead of one under the install prefix.

## `addDocsStep`

```zig
pub fn addDocsStep(b: *std.Build, program: *std.Build.Step.Compile, options: StepOptions) *std.Build.Step
```

Registers the top-level step run by `zig build docs`, which documents the root module of
every artifact `b` installs, each under the name of its artifact, and returns it. The
work is done by running `program`. An artifact whose root module has no Zig source is
left out, and so is `program` itself. Only the artifacts installed before the call are
seen, so it belongs at the end of a build function.

## `addDocs`

```zig
pub fn addDocs(b: *std.Build, program: *std.Build.Step.Compile, module: *std.Build.Module, options: Options) *std.Build.Step
```

Returns a step that documents `module` by running `program`: its root source file, the
files that file imports, the modules reachable through its imports, each with its own
imports, and the headers found in the include directories of each. The standard library
is a target of references and is not documented. The step leaves a JSON document and the
Markdown rendered from it where `options` says. Imports given to a module after the call
are not seen.

## `addSourceDocs`

```zig
pub fn addSourceDocs(b: *std.Build, program: *std.Build.Step.Compile, directory: std.Build.LazyPath, options: Options) *std.Build.Step
```

Returns a step that documents every source file under `directory` that a reader exists
for, by running `program`. This is how sources that no module of the build describes are
documented, such as a C# project. The directories of [`Options.excluded_dirs`](#optionsexcluded_dirs) are not
entered. The step leaves a JSON document and the Markdown rendered from it where
`options` says.

## `build`

```zig
pub fn build(b: *std.Build) void
```

The build of docir itself: its module, its program, its tests and its own documentation.
