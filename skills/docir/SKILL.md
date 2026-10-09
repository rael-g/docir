---
name: docir
description: Look up what a codebase's own documentation says about a symbol, a file or an idea, from the terminal, with `docir query`. Use it before reading source to learn what a function, type or file is for, where it is declared and what it holds, and to find where a concept is explained when no symbol is named after it. Works on Zig, C, C++ and C# sources that carry doc comments.
---

# docir

`docir query` answers from the doc comments of a source tree. It reads the sources each
time it is asked, so nothing has to be generated first and the answer is never older than
the code.

## Ask

| Question | Command |
|---|---|
| What is this symbol? | `docir query <name>` |
| Where is this idea explained? | `docir query --text "<words>"` |
| What does this file, type or namespace hold? | `docir query --members <name>` |
| What is there to ask about? | `docir query --list` |

Each form reads the Zig, C, C++ and C# files under the current directory. Give it a
narrower directory, or one file, to read less and answer faster: `docir query <name> src/pool`.
Leave out what is not the project's own code with `--excluded-name <name>`, once for each
directory or file name to skip wherever it is, such as a vendored tree or a build output.
Directories whose name starts with a dot are never entered.

A name is matched in full first, then as the end of a qualified name (`Pool.wait` finds
`ke.Pool.wait`), then as a piece of one without regard to case. When no symbol has the
name, the words are looked for in the documentation instead, and each answer carries the
paragraph that holds all of them; `--text` goes there directly.

A file is a symbol too, named by its path: `docir query src/pool.zig` prints what the file
says of itself, which is where a file explains how it works as a whole, and lists what it
declares.

Up to five symbols are printed in full: what each is, where it is declared, its signature,
its documentation and one line for each member. More than that are printed one line each;
narrow the name, or pass `--full`. `--json` prints the symbols as data.

## A document made once

When the project is large, or already writes a document in its build, ask that document
instead of the sources. A document is a `.json` file; a directory of them is read as one.

```bash
docir read <directory> --base <directory> | docir link -o project.json
docir query <name> project.json
```

Such a document is as old as the last time it was made. Make it again after the sources
change, or ask the sources.

## Read the answer for what it is

- A symbol printed with a signature and no text has no doc comment. That is a fact about
  the code, not a failure of the tool: read the source at the location given.
- The documentation is a claim made by whoever wrote it. When a decision depends on what
  the code does, read the code at the location the answer gives and cite that.
- `docir help query` lists every option.
