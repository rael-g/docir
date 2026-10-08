# zigdoc

Turns the documentation written in source code into a JSON document, and that document into
plain Markdown. It reads Zig sources and, because Zig projects usually carry C, the Doxygen
comments of C headers.

There is no command to install and no site to host. A build asks for documentation with one
line in its `build.zig`, and gets one `.json` and one `.md` per module.

## What it does

- Reads `//!` and `///` comments in the style Zig's own autodoc reads, so nothing has to be
  rewritten. Declarations that are not `pub` are documented too when their author wrote a
  comment on them.
- Reads Doxygen comments in C headers: `/** */`, `///`, `@brief`, `@param`, `@return` and
  the trailing `///<` form.
- Follows `@import`, `@cInclude` and `#include` from the root file of a module, using the
  imports and include directories the build gave that module. A header reached through
  `@cImport` lands in the same document as the Zig code that implements it.
- Turns a name between backticks into a link to the declaration it names, across files and
  across languages, and reports the ones that name nothing. A name that leads into the
  standard library is resolved as well.
- Takes a `test` named after a declaration as an example of it, and lists the tests named
  by a sentence as the verified behaviour of their file.
- Stores everything in JSON before rendering. The Markdown writer reads only that JSON, and
  so can any other writer.

## Use

Requires Zig 0.16. Add the package to a project:

```bash
zig fetch --save git+https://github.com/rael-g/zigdoc
```

Then, at the end of the project's `build.zig`:

```zig
const std = @import("std");
const zigdoc = @import("zigdoc");

pub fn build(b: *std.Build) void {
    // ... the build, with its installed artifacts ...
    _ = zigdoc.addDocsStep(b, .{});
}
```

```bash
zig build docs
```

This writes `zig-out/docs/<artifact>.json` and `zig-out/docs/<artifact>.md` for every
artifact the build installs.

To document one module chosen by hand, or to change where the files go:

```zig
const docs = zigdoc.addDocs(b, module, .{
    .name = "scheduler",
    .strict = true,
    .documented_dirs = &.{b.path("include")},
    .output_dir = b.path("docs"),
});
b.step("docs", "Write the documentation").dependOn(docs);
```

| Option | Meaning |
|---|---|
| `name` | Base name of the two files. |
| `title` | First heading of the Markdown file. Defaults to `name`. |
| `strict` | Fail the step when a citation names nothing. Otherwise it is a warning. |
| `documented_dirs` | Directories documented besides the build root of the module. |
| `install_subdir` | Directory under the install prefix. Defaults to `docs`. |
| `output_dir` | Directory that receives the files instead of the install prefix. |

Files outside the documented directories are still read, so that a name pointing into them
resolves, but they get no section of their own.

## What gets a section

A declaration appears in the Markdown when it has documentation or an example, or when one
of its members does. Everything else stays in the JSON only, which holds every declaration
of every file with its signature, its lines and its visibility.

## Limits

- Both readers work on syntax. A declaration that only exists after `comptime` evaluation
  is not seen, which is also true of Zig's autodoc.
- The C reader is a scanner for declarations and their comments, not a C parser. Headers
  that build declarations out of macros are beyond it.

## Reference

[docs/zigdoc.md](docs/zigdoc.md) is zigdoc documenting itself, starting from its own
`build.zig`. It is regenerated with `zig build docs` and describes the JSON layout in
`src/model.zig`.

## License

MIT. See [LICENSE](LICENSE).
