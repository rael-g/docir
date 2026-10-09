---
name: docir
description: Look up what a codebase's own documentation says about a symbol, a file or an idea, from the terminal, with `docir query`. Use it before reading source to learn what a function, type or file is for, where it is declared and what it holds, and to find where a concept is explained when no symbol is named after it. Works on Zig, C, C++ and C# sources that carry doc comments.
---

# docir

`docir` reads the doc comments of a source tree into a JSON document and answers questions
from it. It answers from what the code says about itself, so the answer is as current as
the document: make the document again after the sources change.

## Make the document

Skip this when the project already writes one in its build; ask the build for it instead
(for a Zig build that uses docir, `zig build docs`).

```bash
docir read <directory> --base <directory> -o project.json
docir link project.json -o project.linked.json
```

`read` takes a directory and reads every Zig, C, C++ and C# file under it. Leave out what
is not the project's own code with `--excluded <directory>` or, for a name that repeats
across the tree, `--excluded-name <name>`. `link` prints a warning for each name a doc
comment mentions that nothing declares.

## Ask

Every form takes one or more documents, or a directory holding them, and reads them as one.

| Question | Command |
|---|---|
| What is this symbol? | `docir query <name> project.linked.json` |
| Where is this idea explained? | `docir query --text "<words>" project.linked.json` |
| What does this file, type or namespace hold? | `docir query --members <name> project.linked.json` |
| What is in this document at all? | `docir query --list project.linked.json` |

A name is matched in full first, then as the end of a qualified name (`Pool.wait` finds
`ke.Pool.wait`), then as a piece of one without regard to case. When no symbol has the
name, the words are looked for in the documentation instead, and each answer carries the
paragraph that holds all of them; `--text` goes there directly.

A file is a symbol too, named by its path: `docir query src/pool.zig project.linked.json`
prints what the file says of itself, which is where a file explains how it works as a
whole, and lists what it declares.

Up to five symbols are printed in full: what each is, where it is declared, its signature,
its documentation and one line for each member. More than that are printed one line each;
narrow the name, or pass `--full`. `--json` prints the symbols as data.

## Read the answer for what it is

- A symbol printed with a signature and no text has no doc comment. That is a fact about
  the code, not a failure of the tool: read the source at the location given.
- The documentation is a claim made by whoever wrote it. When a decision depends on what
  the code does, read the code at the location the answer gives and cite that.
- `docir help query` lists every option.
