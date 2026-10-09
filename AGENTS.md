# AGENTS.md

Guidance for a coding agent working with the code in this repository.

## Commands

Zig 0.16.0. Every dependency is fetched from `build.zig.zon` and compiled by the build.

```bash
zig build                              # zig-out/bin/docir
zig build test                         # every test, in debug
zig build test -Doptimize=ReleaseSafe  # the same tests, optimized
zig build docs                         # regenerates docs/ from the sources, strict
zig fmt --check build.zig build.zig.zon src
```

The build exposes no test filter: `zig build test` runs all of them, in a few seconds.

CI (`.github/workflows/ci.yml`) runs the five commands above on Linux and Windows and fails
when `zig build docs` changes anything under `docs/`.

## What must hold after a change

- **Run the tests in both modes.** The C sources of the tree-sitter grammars are compiled
  with sanitizers in `ReleaseSafe`, and a failure there does not show in debug.
- **Run `zig build docs` and commit what it changes.** `docs/docir.md`, `docs/build.md` and
  `docs/docir.schema.json` are generated from the sources and versioned. The step is
  strict: it fails when a doc comment mentions, between backticks, a name that is not a
  declaration. Write a keyword, a flag or an XML element so that it does not have the shape
  of a name (`--strict`, `<summary>`, `cref=`), or without backticks.
- **No comments in source**, only doc comments (`//!`, `///`) on declarations. Every public
  declaration has one, and they are what `docs/` is generated from.
- **A local may not share its name with a function of the same file**: Zig rejects the
  shadowing, and the readers have many short method names.

## Architecture

docir is a compiler with a JSON intermediate representation between its stages:

```
sources ── read ──▶ ir.Document ── link ──▶ ir.Document (linked) ── write ──▶ output
```

`src/ir.zig` is the contract. Readers produce it, the linker rewrites it, writers consume
it, and between processes it is JSON with the same field names. `src/schema.zig` derives
the JSON Schema from those types by reflection, so a change to `ir.zig` changes the format,
the schema and `format_version` together.

**Readers** turn one file into an `ir.Unit` (the file plus a symbol of kind `module` that
stands for it):

- `zig_source.zig` walks `std.zig.Ast`.
- `c_source.zig` reads C and C++ from a tree-sitter tree. It blanks export macros out of a
  copy of the source and parses again, because the grammar sees the source before the
  preprocessor. A `.h` is C or C++ by `Dialect.detect`.
- `csharp_source.zig` reads C# from a tree-sitter tree.
- The markup of each language's comments is parsed by its own module into `ir.Text`, a tree
  with no markup left in it: `markdown_text.zig` (with the vendored parser under
  `src/markdown/`), `doxygen_comment.zig`, `xml_comment.zig`. No reader writes Markdown.

**`project.zig`** decides which files are read. Given the root file of a Zig module it
follows `@import`, `@cInclude` and `#include` through the modules, imports and include
directories it was told about. Given a directory it reads every file a reader exists for.
It then joins what a language declares in parts (`csharp_source.join`, `c_source.join`).
Paths in a document are relative, never name the machine, and use `/` on every system.

**`link.zig`** resolves mentions (`ir.Ref`), alias targets, type targets and inherited
documentation, and reports the mentions that name nothing. Symbols are identified by
strings the readers choose: `zig:path#name`, `c:path#a.b`, `cpp:path#a::b(int)`,
`csharp:path#A.B.C(int)`.

**Writers**: `markdown.zig` (one file, or pages with an index and a `toc.yml`), `text.zig`
(terminal), and `query.zig` to find symbols by name.

**`cli.zig`** is the program: one command per stage, a hand-written argument loop over
`std.process.Args`, the version read from `build.zig.zon` through `build_options`.

**`build.zig`** has two roles. It builds this package, and it is the API a consumer imports
in its own `build.zig` (`addDocs`, `addDocsStep`, `addSourceDocs`). A `build.zig` cannot
import a module of its dependency, so those functions do not call the library: they add
`Run` steps that execute the installed `docir` program, one per stage. Anything a build
needs from docir has to be reachable from the command line.

## Dependencies

tree-sitter and its Zig bindings come as packages with their own `build.zig`. The C++ and
C# grammars have none, so this `build.zig` compiles their `parser.c` and `scanner.c` into
the `docir` module, with `-fno-sanitize=function`: their scanner entry points are declared
without a prototype.

## Tests

Tests live in the file they cover and are named by a sentence stating the behaviour.
`src/root.zig` is the single test root and reaches every file through `refAllDecls`.

## Git

`main` only takes squash merges: work happens on a branch, and the branch lands as one
commit. Its message is a single line in Conventional Commits form. `feat` and `fix` are the
lines of the release notes, so a `fix` is only for a defect of a released version; a
defect of work that was never released belongs to the commit that brings that work.

A release is a commit that sets `.version` in `build.zig.zon`, tagged `v<version>`. The
`release` workflow checks the tag against `docir --version`, writes the notes from the
commits with git-cliff and creates the GitHub release. The version is written nowhere else.
