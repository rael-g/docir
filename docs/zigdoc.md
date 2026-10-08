# zigdoc

## `src/model.zig`

The language-neutral shape every reader produces and every writer consumes.

A reader turns one source file into a [`File`](#file): its documentation, what it imports and
every declaration it holds, documented or not. A [`Document`](#document) is a set of files reached
from one root, and it is the form the model takes outside the process: JSON whose fields
are the fields declared here, under the same names. Extraction ends in that JSON and a
writer starts from it, so a writer never reads a source file.

A declaration is identified by the path of its file, a `#`, and its name qualified by
the containers around it, as in `src/pool.zig#Pool.wait`. Every reference in the document,
a [`Link`](#link) or a [`Decl.target`](#decltarget), is such an identifier, or the path of a file.

### `format_version`

```zig
pub const format_version = 1
```

Version of the JSON layout. A file carrying another one is refused.

### `Document`

```zig
pub const Document = struct
```

The files reached from one root. The files that are only a target of references come
first, cut down to the declarations a reference names; the others follow, dependencies
before the files that import them.

#### `Document.format`

```zig
format: u32 = format_version
```

The [`format_version`](#format_version) the document was written in.

#### `Document.root`

```zig
root: []const u8
```

Path of the file the extraction started at.

#### `Document.files`

```zig
files: []const File
```

Every file of the document, each under a path no other has.

### `Language`

```zig
pub const Language = enum
```

The language of a source file, which is also the reader that read it.

#### `Language.zig`

```zig
zig
```

Read by `zig_source`.

#### `Language.c`

```zig
c
```

A C header or source file, read by `doxygen`.

### `File`

```zig
pub const File = struct
```

Everything one source file says about itself. A file that is not [`documented`](#filedocumented) was
reached through an import and is present only so that references into it resolve.

#### `File.path`

```zig
path: []const u8
```

Path of the file within the document, with `/` between its parts. It identifies the
file and never names the machine the file was read on.

#### `File.language`

```zig
language: Language
```

The language the file is written in.

#### `File.documented`

```zig
documented: bool = true
```

Whether the file is part of what is being documented.

#### `File.doc`

```zig
doc: Text = .{}
```

The documentation of the file as a whole: `//!` in Zig, a `@file` block in C.

#### `File.imports`

```zig
imports: []const Import = &.{}
```

What the file imports or includes, in source order.

#### `File.decls`

```zig
decls: []const Decl = &.{}
```

The top-level declarations of the file, in source order.

#### `File.behaviours`

```zig
behaviours: []const []const u8 = &.{}
```

The names of the tests of the file that are named by a sentence and not by a
declaration.

### `Text`

```zig
pub const Text = struct
```

Documentation text in Markdown, with the citations in it that resolved to a declaration.

#### `Text.markdown`

```zig
markdown: []const u8 = ""
```

The text as written, without the comment markers. Empty when there is none.

#### `Text.links`

```zig
links: []const Link = &.{}
```

One entry per distinct citation of [`markdown`](#textmarkdown) that resolved.

### `Link`

```zig
pub const Link = struct
```

A code span of a [`Text`](#text) and the identifier of the declaration it names.

#### `Link.citation`

```zig
citation: []const u8
```

The content of the code span, exactly as written between the backticks.

#### `Link.target`

```zig
target: []const u8
```

Identifier of the declaration the citation names.

### `Import`

```zig
pub const Import = struct
```

Something a file pulls in. [`path`](#importpath) is the path of the [`File`](#file) it resolved to, or empty
when it lies outside what was given to the extraction. A path into a module that is
only a target of references names a file that is in the document when a reference names
a declaration of it.

#### `Import.name`

```zig
name: []const u8
```

The name as written in the source: a relative path, a module name or a header name.

#### `Import.kind`

```zig
kind: ImportKind
```

How the name is looked for.

#### `Import.path`

```zig
path: []const u8 = ""
```

Path of the file the name resolved to.

### `ImportKind`

```zig
pub const ImportKind = enum
```

How the name of an [`Import`](#import) is looked for.

#### `ImportKind.file`

```zig
file
```

An `@import` of a path, looked for beside the importing file.

#### `ImportKind.module`

```zig
module
```

An `@import` of a module name, looked up in what the build gave the module.

#### `ImportKind.include`

```zig
include
```

A `@cInclude` or an `#include`, looked for in the include directories.

### `Param`

```zig
pub const Param = struct
```

One parameter of a function-like declaration.

#### `Param.name`

```zig
name: []const u8
```

The name of the parameter, empty when the source gives it none.

#### `Param.type_name`

```zig
type_name: []const u8 = ""
```

The type as written. Empty for a parameter that was documented in C and that the
signature does not have.

#### `Param.doc`

```zig
doc: Text = .{}
```

What the documentation says about the parameter.

### `Kind`

```zig
pub const Kind = enum
```

What a declaration is.

#### `Kind.function`

```zig
function
```

A function, or in C a function prototype.

#### `Kind.type_function`

```zig
type_function
```

A Zig function that returns a container, which is read as that container.

#### `Kind.@"struct"`

```zig
@"struct"
```

A struct.

#### `Kind.@"enum"`

```zig
@"enum"
```

An enum.

#### `Kind.@"union"`

```zig
@"union"
```

A union.

#### `Kind.@"opaque"`

```zig
@"opaque"
```

A Zig opaque type.

#### `Kind.error_set`

```zig
error_set
```

A Zig error set.

#### `Kind.error_value`

```zig
error_value
```

One error of an error set.

#### `Kind.constant`

```zig
constant
```

A Zig `const` that is none of the other kinds.

#### `Kind.variable`

```zig
variable
```

A Zig `var`, or a C variable.

#### `Kind.field`

```zig
field
```

A field of a container, or one value of a Zig enum. In C, a field that is a
function pointer carries parameters and a return type like a function.

#### `Kind.enumerator`

```zig
enumerator
```

One value of a C enum.

#### `Kind.import`

```zig
import
```

A Zig `const` whose value is an `@import` or a `@cImport`.

#### `Kind.alias`

```zig
alias
```

A Zig `const` whose value is a path to another declaration.

#### `Kind.typedef`

```zig
typedef
```

A C [`typedef`](#kindtypedef) that declares no container.

#### `Kind.macro`

```zig
macro
```

A C `#define`.

### `Decl`

```zig
pub const Decl = struct
```

One declaration. [`value`](#declvalue) is the initial value of a constant or the default of a field,
the imported name of an [`import`](#kindimport) and the aliased expression of an [`alias`](#kindalias). [`target`](#decltarget) is
the path of the file an [`import`](#kindimport) resolved to, or the identifier of the declaration an
[`alias`](#kindalias) names. An example is source code that uses the declaration, taken from a test.

#### `Decl.id`

```zig
id: []const u8
```

Identifier of the declaration, unique in the document.

#### `Decl.name`

```zig
name: []const u8
```

The name of the declaration alone, without its containers.

#### `Decl.kind`

```zig
kind: Kind
```

What the declaration is.

#### `Decl.public`

```zig
public: bool = true
```

Whether the declaration is visible outside its file. Everything in C is.

#### `Decl.line`

```zig
line: u32 = 0
```

First line of the declaration in its file, counted from 1.

#### `Decl.end_line`

```zig
end_line: u32 = 0
```

Last line of the declaration in its file.

#### `Decl.signature`

```zig
signature: []const u8 = ""
```

The declaration as written, without its body.

#### `Decl.doc`

```zig
doc: Text = .{}
```

The documentation of the declaration, without what is said of its parameters and
of what it returns.

#### `Decl.params`

```zig
params: []const Param = &.{}
```

The parameters of a function-like declaration, in order.

#### `Decl.return_type`

```zig
return_type: []const u8 = ""
```

The return type of a function-like declaration, as written.

#### `Decl.returns`

```zig
returns: Text = .{}
```

What the documentation says is returned.

#### `Decl.type_name`

```zig
type_name: []const u8 = ""
```

The type of a field, a constant or a variable, as written, when the source states it.

#### `Decl.value`

```zig
value: []const u8 = ""
```

An expression of the source whose meaning depends on [`kind`](#declkind).

#### `Decl.target`

```zig
target: []const u8 = ""
```

What an [`import`](#kindimport) or an [`alias`](#kindalias) leads to. Empty when it leads outside the document.

#### `Decl.examples`

```zig
examples: []const []const u8 = &.{}
```

The bodies of the tests named after the declaration.

#### `Decl.members`

```zig
members: []const Decl = &.{}
```

The declarations inside a container, in source order.

### `qualifiedName`

```zig
pub fn qualifiedName(id: []const u8) []const u8
```

The name of a declaration qualified by its containers, which is its identifier without
the path of its file.

### `writeJson`

```zig
pub fn writeJson(writer: *std.Io.Writer, document: Document) std.Io.Writer.Error!void
```

Writes [`document`](#extractiondocument) as indented JSON.

### `readJson`

```zig
pub fn readJson(arena: std.mem.Allocator, bytes: []const u8) !Document
```

Reads a [`Document`](#document) back. Fails with `error.UnsupportedFormat` when the file was written
in another [`format_version`](#format_version), and with the JSON parser's error when it is not a document.

### Verified behaviour

- a document survives the trip through JSON
- a document written in another format version is refused
- the qualified name of a declaration is its identifier without the file

## `src/zig_source.zig`

Reads a Zig source file through the compiler's own parser.

Every declaration of the file is recorded, with the `///` block above it when there is
one, and the `//!` block that opens the file becomes the documentation of the file. A
container is walked recursively, so a method is a member of its container. The members
of an error set are read like the fields of a container. A function that returns a
container written in its own body, the way a generic type is declared, is treated as
that container: what the returned container declares becomes the members of the function.

A `test` named by a string contributes its name as a verified behaviour of the file. A
`test` named after a declaration contributes its body as an example of that declaration
when the two sit in the same container.

Every `@import` and `@cInclude` of the file is listed as an import, wherever it is written.

### `read`

```zig
pub fn read(arena: Allocator, path: []const u8, source: [:0]const u8) !model.File
```

Extracts one Zig file. `path` becomes the path of the file in the document and the
first part of the identifier of each declaration. Fails with `error.InvalidZigSource`
when the file does not parse.

### Verified behaviour

- the block that opens a file becomes its documentation
- a function carries its prototype, parameters, return type, visibility and lines
- a container holds its fields and methods as members qualified by its name
- test names are collected in source order, including the ones inside a container
- a constant keeps its type and value, and a value that spans lines is left out
- imports and aliases are told apart from constants
- a function that returns a container is read as that container
- a test named after a declaration becomes an example of it
- the members of an error set are read with their documentation
- a file that does not parse is refused

## `src/doxygen.zig`

Reads the Doxygen comments and the declarations of a C header.

The reader does not parse C. It walks the text one declaration at a time: a declaration
ends at a `;` outside parentheses, at a `,` inside an enumeration, or at the `}` that
closes its braces. A braced declaration is a container, and its body is walked the same
way, so a field or a vtable slot becomes a member of its struct. An `extern "C"` block
is transparent: what it holds belongs to the scope around it. Every declaration is
recorded, documented or not, and every `#include` is listed as an import.

A comment is documentation when it opens with `/**`, `/*!`, `///` or `//!`. It belongs to
the declaration that follows it, unless the marker is followed by `<`, in which case it
belongs to the declaration before it. A comment that carries `@file` documents the file.

Inside a comment, `@brief`, `@param`, `@return` and their backslash forms are understood;
`@note`, `@warning` and the like become a labelled paragraph; `@c`, `@p`, `@a` and `@ref`
mark the next word as code.

The parameters of a function, of a function pointer and of a callback type are taken
from its signature, with name and type, and each `@param` is attached to the parameter
it names. A `@param` that names no parameter is kept, with no type.

### `read`

```zig
pub fn read(arena: Allocator, path: []const u8, source: []const u8) Allocator.Error!model.File
```

Extracts one C header. `path` becomes the path of the file in the document and the
first part of the identifier of each declaration.

### Verified behaviour

- a function carries its name, parameters, return type and documentation
- the slots of a vtable are members named after the function pointer
- a callback typedef is named after the pointer it declares
- a trailing comment documents the declaration before it
- enumerators are split at commas and the last one needs none
- an extern block is transparent, and includes and macros are recorded
- a file comment documents the file and a note becomes a labelled paragraph
- plain comments and banner comments are not documentation
- an inline function body is skipped and the next declaration is still read

## `src/project.zig`

Walks the imports of a root file and reads the files it reaches.

What is read is described as a set of modules, the way a build describes a compilation.
Each [`Module`](#module) has a root file, the names it may import other modules by and the
directories its headers are looked for in. The first module of [`Options.modules`](#optionsmodules) is the
one being documented, and every file belongs to the module whose root reached it.

A relative `@import` or `#include` is looked for beside the file that names it. A named
`@import` is looked up in [`Module.imports`](#moduleimports) of the module of its file. A `@cInclude`, and
an `#include` not found beside its file, is looked for in each of [`Module.include_dirs`](#moduleinclude_dirs)
in order. What is not found stays in the list of imports of its file with an empty path,
and is not an error.

The path a file gets in the document never names the machine it was read on. The root
file of a module is given relative to [`Options.base`](#optionsbase) when it lies under it, and under
the name of its module otherwise. A file imported relatively is placed relative to its
importer, and an included file keeps the name it was included by.

Every file reached is read, so that a reference into it resolves, but only a file under
one of [`Options.documented_dirs`](#optionsdocumented_dirs) is marked as documented. The exception is a module that
is [`Module.reference_only`](#modulereference_only): an import into it is given its path without the file being
read, and [`Project.reference`](#projectreference) reads one such file when a reference goes through it. Its
files are never documented, and the includes in them are not followed.

### `ModuleImport`

```zig
pub const ModuleImport = struct
```

A name a module imports another one by. [`module`](#moduleimportmodule) indexes [`Options.modules`](#optionsmodules).

#### `ModuleImport.name`

```zig
name: []const u8
```

The name as it is written in an `@import`.

#### `ModuleImport.module`

```zig
module: usize
```

Position in [`Options.modules`](#optionsmodules) of the module the name stands for.

### `Module`

```zig
pub const Module = struct
```

The root file of a module and what its files may import.

#### `Module.name`

```zig
name: []const u8
```

The directory the files of the module are shown under when its root lies outside
[`Options.base`](#optionsbase). No two modules should share one.

#### `Module.path`

```zig
path: []const u8
```

Path of the root file on disk.

#### `Module.imports`

```zig
imports: []const ModuleImport = &.{}
```

The modules the files of this one may import by name.

#### `Module.include_dirs`

```zig
include_dirs: []const []const u8 = &.{}
```

The directories on disk a header included by this module is looked for in.

#### `Module.reference_only`

```zig
reference_only: bool = false
```

Whether the files of the module are read only when a reference goes through them.

### `Options`

```zig
pub const Options = struct
```

What to read. The first of [`modules`](#optionsmodules) is the one documented, and the directory of its
root file is always one of the documented directories.

#### `Options.modules`

```zig
modules: []const Module
```

Every module that can be reached, the documented one first.

#### `Options.base`

```zig
base: []const u8 = ""
```

Directory on disk that paths in the document are relative to.

#### `Options.documented_dirs`

```zig
documented_dirs: []const []const u8 = &.{}
```

Directories on disk whose files are documented.

### `Project`

```zig
pub const Project = struct
```

The files reached from the root of the first module.

#### `Project.arena`

```zig
arena: Allocator
```

Owns everything the project allocates, the files included.

#### `Project.io`

```zig
io: std.Io
```

What the files are read through.

#### `Project.options`

```zig
options: Options
```

What [`open`](#projectopen) was given.

#### `Project.base`

```zig
base: []const u8 = ""
```

[`Options.base`](#optionsbase) as an absolute path.

#### `Project.root`

```zig
root: []const u8 = ""
```

The path of the root file in the document.

#### `Project.documented`

```zig
documented: std.ArrayList([]const u8) = .empty
```

The documented directories as absolute paths.

#### `Project.seen`

```zig
seen: std.StringHashMapUnmanaged([]const u8) = .empty
```

Path in the document of each file read by [`open`](#projectopen), by its absolute path on disk.

#### `Project.files`

```zig
files: std.ArrayList(model.File) = .empty
```

The files read by [`open`](#projectopen), dependencies before the files that import them.

#### `Project.postponed`

```zig
postponed: std.StringHashMapUnmanaged(Postponed) = .empty
```

Where on disk each file of a reference-only module is, by its path in the document.

#### `Project.references`

```zig
references: std.StringHashMapUnmanaged(?*const model.File) = .empty
```

What [`reference`](#projectreference) answered for each path it was asked.

#### `Project.referenced`

```zig
referenced: std.ArrayList(*const model.File) = .empty
```

The files [`reference`](#projectreference) read, in the order they were asked for.

#### `Project.open`

```zig
pub fn open(arena: Allocator, io: std.Io, options: Options) !Project
```

Reads the root of the first module and everything it imports, dependencies first.
Fails when there is no module or when the root cannot be read or parsed.

#### `Project.reference`

```zig
pub fn reference(self: *Project, path: []const u8) Allocator.Error!?*const model.File
```

The file of a reference-only module that an import was given [`path`](#modulepath) for, read on
the first call. Null when [`path`](#modulepath) is not such a file or it cannot be read.

### Verified behaviour

- imports are followed by kind, and only the files under a documented directory are documented
- a named import is looked up in the module of the file that names it
- a file of a reference-only module is read only when a reference goes through it
- a root that cannot be read is an error

## `src/resolve.zig`

Turns the names a document mentions into references to its declarations.

Two things are resolved. The first is a citation: a code span, text between single
backticks, that has the shape of a name, which is one identifier or several joined by
dots, optionally followed by `()`. Anything else in backticks, such as an expression, a
command line or an operator, is not a citation. The second is the target of an [`import`](#kindimport)
or of an [`alias`](#kindalias) declaration.

The first part of a name is looked for in the scopes around the text, innermost first:
the members of the declaration being documented, its siblings, and outwards to the top
of its file. When no scope has it, every declaration of every file is searched, the
file of the text first. Each following part is looked for among the members of what the
previous part named, going through an import into the file it resolved to and through
an alias into what it names. An import may lead to a file that is not among the ones
being resolved, in which case a [`Source`](#source) is asked for it.

A citation that resolves becomes a [`model.Link`](#link). A plain name that resolves to nothing
is still accepted when it appears in the signature of the declaration being documented,
which is how a parameter is cited, or when it is a word of the language. A dotted name is
accepted when its first part is unknown, since it is then a file name or a name from
outside the sources, and when a part names something whose members are not known, such
as an import that was not followed. Every other citation is a [`Problem`](#problem), and so is a
documented parameter that the signature does not have. Problems are only raised for
documented files.

### `Problem`

```zig
pub const Problem = struct
```

One citation that names nothing.

#### `Problem.path`

```zig
path: []const u8
```

Path of the file the citation is in.

#### `Problem.owner`

```zig
owner: []const u8
```

Qualified name of the declaration whose documentation cites, or a description of
the file when it is the documentation of the file.

#### `Problem.citation`

```zig
citation: []const u8
```

The name that was not found.

#### `Problem.kind`

```zig
kind: Kind
```

What was expected to carry the name.

#### `Problem.Kind`

```zig
pub const Kind = enum
```

What a [`Problem`](#problem) is about.

##### `Problem.Kind.symbol`

```zig
symbol
```

A citation that names no declaration.

##### `Problem.Kind.parameter`

```zig
parameter
```

A documented parameter that the signature does not have.

### `Result`

```zig
pub const Result = struct
```

The files with their links and targets filled in, and what could not be resolved.

#### `Result.files`

```zig
files: []const model.File
```

The files given, in the same order.

#### `Result.problems`

```zig
problems: []const Problem
```

One entry per citation of a documented file that names nothing.

### `Source`

```zig
pub const Source = struct
```

Supplies a file that an import leads to and that is not among the files being resolved.

#### `Source.context`

```zig
context: *anyopaque
```

Passed back to [`find`](#sourcefind) on every call.

#### `Source.find`

```zig
find: *const fn (context: *anyopaque, path: []const u8) Allocator.Error!?*const model.File
```

The file at [`path`](#problempath), or null when there is none.

### `resolve`

```zig
pub fn resolve(arena: Allocator, files: []const model.File, source: ?Source) Allocator.Error!Result
```

Resolves the citations and the import and alias targets of [`files`](#resultfiles) against each other.
A name that leads through an import to a file outside [`files`](#resultfiles) is followed into what
`source` supplies for it.

### `CodeSpans`

```zig
pub const CodeSpans = struct
```

Iterates the code spans of Markdown text that sit on one line and outside a fenced block.

#### `CodeSpans.text`

```zig
text: []const u8
```

The Markdown text being read.

#### `CodeSpans.at`

```zig
at: usize = 0
```

Offset the search for the next span starts at.

#### `CodeSpans.fenced`

```zig
fenced: bool = false
```

Whether that offset is inside a fenced block.

#### `CodeSpans.Span`

```zig
pub const Span = struct
```

One code span and where it sits in the text.

##### `CodeSpans.Span.start`

```zig
start: usize
```

Offset of the opening backtick.

##### `CodeSpans.Span.end`

```zig
end: usize
```

Offset just past the closing backtick.

##### `CodeSpans.Span.content`

```zig
content: []const u8
```

What is written between the backticks.

#### `CodeSpans.next`

```zig
pub fn next(spans: *CodeSpans) ?Span
```

The next span delimited by single backticks, or null at the end of the text.

### Verified behaviour

- a citation links to the declaration it names, by plain or qualified name
- the nearest scope wins when a name is declared twice
- a citation that names nothing is reported with the declaration that cites it
- a parameter and a word of the language are accepted without a link
- a code span that is not a name is not a citation
- a dotted name is accepted when its first part is unknown or was not followed
- an import and an alias lead to the declaration in the other file
- a name declared in another file is found, and a problem in an undocumented file is not raised
- a documented parameter that the signature does not have is reported
- a name that leads outside the files is followed into what the source supplies

## `src/markdown.zig`

Writes a document as one plain Markdown file.

Only documented files are written, and of those only the ones with something to say. A
declaration gets a section when it carries documentation of any kind or an example, or
when one of its members does. With a single file the sections are second-level; with several, each
file gets a second-level section named after its path and its declarations move one
level down. A member is headed by its qualified name, so a heading is unambiguous when
read out of context. Test names close each file as a list under "Verified behaviour".

A citation that resolved to a declaration with a section becomes a link to that section.
The link target is the anchor a Markdown renderer derives from the heading: its text in
lower case, without punctuation, with a counter appended when the same text was already
used. No anchor is written into the file.

### `Error`

```zig
pub const Error = Allocator.Error || Writer.Error
```

What writing can fail with: the arena or the writer.

### `write`

```zig
pub fn write(arena: Allocator, writer: *Writer, title: []const u8, document: model.Document) Error!void
```

Renders [`document`](#extractiondocument) under a first-level heading carrying `title`.

### Verified behaviour

- a single file is written flat, with an example and its test names as a closing list
- a member is headed by its qualified name and only documented parameters are listed
- a citation links to the section of its target, across files and with repeated headings numbered

## `src/root.zig`

zigdoc turns the documentation written in source code into data, and that data into text.

[`extract`](#extract) starts at the root file of a module, follows its imports as `project`
describes, reads each file with `zig_source` or `doxygen`, and has `resolve` turn every
name the documentation mentions into a reference. The result is a [`model.Document`](#document), which [`model.writeJson`](#writejson)
stores. [`markdown.write`](#write) renders a document read back with [`model.readJson`](#readjson).

Nothing here is a command. A build asks for documentation through the step the
`build.zig` of this package offers, which takes what [`extract`](#extract) needs from the module it
is given.

### `Extraction`

```zig
pub const Extraction = struct
```

A document, and the citations in it that name nothing.

#### `Extraction.document`

```zig
document: model.Document
```

Everything that was read, resolved.

#### `Extraction.problems`

```zig
problems: []const resolve.Problem
```

Empty when every citation of a documented file names something.

### `extract`

```zig
pub fn extract(arena: std.mem.Allocator, io: std.Io, options: project.Options) !Extraction
```

Reads the root of [`options`](#projectoptions) and everything it imports into one resolved document. A
file of a reference-only module comes first and holds only the top-level declarations
that a reference names or reaches into, and the imports those declarations make.

### Verified behaviour

- a referenced file keeps only what a reference names or reaches into

## `build.zig`

The build side of zigdoc, which is the whole of its interface.

A build that depends on this package reaches these declarations with `@import("zigdoc")`
in its own `build.zig`. [`addDocsStep`](#adddocsstep) is the short form: one call at the end of a build
function documents every artifact that build installs. [`addDocs`](#adddocs) documents one module
chosen by the caller. Both take what there is to read from the modules themselves: the
root source file, the imports and the include directories each was given.

A step writes two files per module, `<name>.json` and then `<name>.md`, the second
rendered from the first after reading it back.

### `Options`

```zig
pub const Options = struct
```

How the documentation of one module is produced.

#### `Options.name`

```zig
name: []const u8
```

Base name of the two files written, `<name>.json` and `<name>.md`.

#### `Options.title`

```zig
title: ?[]const u8 = null
```

First-level heading of the Markdown file. Defaults to [`name`](#optionsname).

#### `Options.strict`

```zig
strict: bool = false
```

Fails the step, writing nothing, when a citation names nothing.

#### `Options.documented_dirs`

```zig
documented_dirs: []const std.Build.LazyPath = &.{}
```

Directories whose files are documented, besides the build root of the module.

#### `Options.install_subdir`

```zig
install_subdir: []const u8 = "docs"
```

Directory under the install prefix that receives the files.

#### `Options.output_dir`

```zig
output_dir: ?std.Build.LazyPath = null
```

Directory that receives the files instead of one under the install prefix.

### `StepOptions`

```zig
pub const StepOptions = struct
```

How the documentation of every installed artifact is produced.

#### `StepOptions.strict`

```zig
strict: bool = false
```

Fails the step when a citation names nothing.

#### `StepOptions.documented_dirs`

```zig
documented_dirs: []const std.Build.LazyPath = &.{}
```

Directories whose files are documented, besides the build root of each module.

#### `StepOptions.install_subdir`

```zig
install_subdir: []const u8 = "docs"
```

Directory under the install prefix that receives the files.

#### `StepOptions.output_dir`

```zig
output_dir: ?std.Build.LazyPath = null
```

Directory that receives the files instead of one under the install prefix.

### `addDocsStep`

```zig
pub fn addDocsStep(b: *std.Build, options: StepOptions) *std.Build.Step
```

Registers the top-level step run by `zig build docs`, which documents the root module of every
artifact `b` installs, each under the name of its artifact, and returns it. An artifact
whose root module has no Zig source is left out. Only the artifacts installed before
the call are seen, so it belongs at the end of a build function.

### `addDocs`

```zig
pub fn addDocs(b: *std.Build, module: *std.Build.Module, options: Options) *std.Build.Step
```

Returns a step that documents [`module`](#importkindmodule): its root source file, the files that file
imports, the modules reachable through its imports, each with its own imports, and the
headers found in the include directories of each. The standard library is a target of
references and is not documented. The step writes a JSON document and the Markdown
rendered from it. Imports given to a module after the call are not seen.

### `build`

```zig
pub fn build(b: *std.Build) void
```

The build of zigdoc itself: its module, its tests and its own documentation.
