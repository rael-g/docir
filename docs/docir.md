# docir

## `src/ir.zig`

The intermediate representation: what every reader produces and every writer consumes.

A [`Document`](#document) is a tree of symbols and the list of files they were read from. A reader
turns sources of one language into a document, a linker joins several documents and
resolves the names they mention, and a writer renders the result. Outside a process the
document is JSON whose fields are the fields declared here, under the same names.

Nothing here belongs to one language or to one output. A [`Symbol`](#symbol) carries the words of
its language verbatim, in [`Symbol.signature`](#symbolsignature), [`Symbol.form`](#symbolform) and [`Symbol.modifiers`](#symbolmodifiers), and a
neutral [`Kind`](#kind) beside them for a writer that does not know the language. Documentation
is a [`Text`](#text): a tree of blocks and inlines with no markup in it. A reader parses the
markup of its language into that tree, whatever that markup is, and a writer produces
the markup of its output from it.

A symbol is identified by an opaque string that its reader chooses and that is unique in
the document. Readers prefix it with their language and use the name the language itself
gives the symbol when there is one. Every reference in a document is such an identifier.

### `format_version`

```zig
pub const format_version = 2
```

Version of the JSON layout. A document carrying another one is refused.

### `Document`

```zig
pub const Document = struct
```

The symbols read from a set of sources.

#### `Document.format`

```zig
format: u32 = format_version
```

The [`format_version`](#format_version) the document was written in.

#### `Document.linked`

```zig
linked: bool = false
```

Whether a linker went over the document. Before that, a reference has a target only
where the reader knew it.

#### `Document.source_root`

```zig
source_root: []const u8 = ""
```

Directory on disk that every [`File.path`](#filepath) is relative to. Empty when the document is
not meant to name the machine it was read on.

#### `Document.files`

```zig
files: []const File = &.{}
```

Every file that was read, each under a path no other has.

#### `Document.symbols`

```zig
symbols: []const Symbol = &.{}
```

The symbols that sit inside no other.

### `File`

```zig
pub const File = struct
```

One source file.

#### `File.path`

```zig
path: []const u8
```

Path of the file, with `/` between its parts. It identifies the file.

#### `File.language`

```zig
language: []const u8
```

The language of the file, in lower case, as its reader names it.

#### `File.documented`

```zig
documented: bool = true
```

Whether the file is part of what is being documented. A file that is not was read
only so that references into it resolve.

#### `File.imports`

```zig
imports: []const Import = &.{}
```

What the file imports or includes, in source order.

### `Import`

```zig
pub const Import = struct
```

Something a file pulls in.

#### `Import.name`

```zig
name: []const u8
```

The name as written in the source.

#### `Import.kind`

```zig
kind: ImportKind
```

How the name is looked for.

#### `Import.path`

```zig
path: []const u8 = ""
```

Path of the [`File`](#file) the name resolved to, or empty when it lies outside the document.

### `ImportKind`

```zig
pub const ImportKind = enum
```

How the name of an [`Import`](#import) is looked for.

#### `ImportKind.file`

```zig
file
```

A path, looked for beside the importing file.

#### `ImportKind.module`

```zig
module
```

A name the build of the project gives a meaning to.

#### `ImportKind.include`

```zig
include
```

A path looked for in a list of directories.

### `Unit`

```zig
pub const Unit = struct
```

What a reader makes of one file: the file, and the symbol that stands for it with
everything the file declares as its members.

#### `Unit.file`

```zig
file: File
```

The file.

#### `Unit.symbol`

```zig
symbol: Symbol
```

The symbol of the file.

### `Location`

```zig
pub const Location = struct
```

A place a symbol is declared at. A symbol declared in parts has one per part.

#### `Location.file`

```zig
file: []const u8
```

Path of the [`File`](#file).

#### `Location.line`

```zig
line: u32 = 0
```

First line of the declaration, counted from 1.

#### `Location.end_line`

```zig
end_line: u32 = 0
```

Last line of the declaration.

### `Kind`

```zig
pub const Kind = enum
```

What a symbol is, for a writer that does not know its language.

#### `Kind.namespace`

```zig
namespace
```

A name that only groups other symbols and may be declared in many files.

#### `Kind.module`

```zig
module
```

A source file taken as a symbol, in a language where a file is a scope of its own.

#### `Kind.type`

```zig
type
```

Anything that can be the type of a value: a struct, a class, an interface, an enum.

#### `Kind.function`

```zig
function
```

Anything that is called: a function, a method, a constructor.

#### `Kind.field`

```zig
field
```

Data stored in each value of a type.

#### `Kind.property`

```zig
property
```

Data of a type that is reached through code, such as a C# property.

#### `Kind.event`

```zig
event
```

A notification a type lets others subscribe to.

#### `Kind.constant`

```zig
constant
```

A named value that does not change.

#### `Kind.variable`

```zig
variable
```

A named value that changes.

#### `Kind.enumerator`

```zig
enumerator
```

One of the values of an enumerated type, or one error of an error set.

#### `Kind.alias`

```zig
alias
```

Another name for a symbol declared elsewhere.

#### `Kind.macro`

```zig
macro
```

A substitution made on the source before it is compiled.

### `Visibility`

```zig
pub const Visibility = enum
```

Who may use a symbol.

#### `Visibility.public`

```zig
public
```

Anyone.

#### `Visibility.protected`

```zig
protected
```

The type that declares it and the types derived from it.

#### `Visibility.internal`

```zig
internal
```

The unit that is compiled together with it.

#### `Visibility.private`

```zig
private
```

The scope that declares it.

### `TypeRef`

```zig
pub const TypeRef = struct
```

A type as written in the source, and the symbol it names when that is known.

#### `TypeRef.text`

```zig
text: []const u8 = ""
```

The type as written.

#### `TypeRef.target`

```zig
target: []const u8 = ""
```

Identifier of the symbol the type names. Empty when it names none in the document.

### `Param`

```zig
pub const Param = struct
```

One parameter of a callable symbol.

#### `Param.name`

```zig
name: []const u8
```

The name of the parameter, empty when the source gives it none.

#### `Param.type`

```zig
type: TypeRef = .{}
```

The type of the parameter. Its text is empty for a parameter that was documented
and that the signature does not have.

#### `Param.doc`

```zig
doc: Text = .{}
```

What the documentation says about the parameter.

### `TypeParam`

```zig
pub const TypeParam = struct
```

One parameter that stands for a type.

#### `TypeParam.name`

```zig
name: []const u8
```

The name of the parameter.

#### `TypeParam.constraint`

```zig
constraint: []const u8 = ""
```

What a type must satisfy to be given, as written.

#### `TypeParam.doc`

```zig
doc: Text = .{}
```

What the documentation says about the parameter.

### `Raised`

```zig
pub const Raised = struct
```

A failure a callable symbol is documented to raise or return.

#### `Raised.type`

```zig
type: TypeRef = .{}
```

The type or the name of the failure.

#### `Raised.doc`

```zig
doc: Text = .{}
```

When it happens.

### `Example`

```zig
pub const Example = struct
```

Source code that uses a symbol.

#### `Example.language`

```zig
language: []const u8 = ""
```

The language of the code, as a fenced block would name it.

#### `Example.code`

```zig
code: []const u8
```

The code.

### `Symbol`

```zig
pub const Symbol = struct
```

One declared thing.

#### `Symbol.id`

```zig
id: []const u8
```

Identifier of the symbol, unique in the document.

#### `Symbol.name`

```zig
name: []const u8
```

The name of the symbol alone.

#### `Symbol.qualified_name`

```zig
qualified_name: []const u8
```

The name of the symbol with the names of the symbols around it, as its language
writes a path to it.

#### `Symbol.kind`

```zig
kind: Kind
```

What the symbol is.

#### `Symbol.form`

```zig
form: []const u8 = ""
```

What the symbol is in the words of its language: a struct, an interface, a
constructor. Empty when [`kind`](#symbolkind) says it all.

#### `Symbol.visibility`

```zig
visibility: Visibility = .public
```

Who may use the symbol.

#### `Symbol.modifiers`

```zig
modifiers: []const []const u8 = &.{}
```

The other words its language puts on the declaration, such as "static" or "unsafe".

#### `Symbol.locations`

```zig
locations: []const Location = &.{}
```

Where the symbol is declared.

#### `Symbol.signature`

```zig
signature: []const u8 = ""
```

The declaration as written, without its body.

#### `Symbol.doc`

```zig
doc: Text = .{}
```

The documentation of the symbol, without what is said of its parameters, of what it
returns and of what it raises.

#### `Symbol.inherits`

```zig
inherits: ?[]const u8 = null
```

The name of the symbol whose documentation this one asks to be given, as written.
Empty when it asks for that of the member it overrides or implements, and null when
it asks for none. A linker answers it by filling what the symbol does not say itself.

#### `Symbol.type_params`

```zig
type_params: []const TypeParam = &.{}
```

The parameters that stand for types, in order.

#### `Symbol.params`

```zig
params: []const Param = &.{}
```

The parameters of a callable symbol, in order.

#### `Symbol.type`

```zig
type: TypeRef = .{}
```

The type of a field, a property, a constant or a variable, and the type a callable
symbol returns.

#### `Symbol.returns`

```zig
returns: Text = .{}
```

What the documentation says is returned.

#### `Symbol.raises`

```zig
raises: []const Raised = &.{}
```

The failures the documentation says are raised.

#### `Symbol.bases`

```zig
bases: []const TypeRef = &.{}
```

The types a type is derived from or implements.

#### `Symbol.value`

```zig
value: []const u8 = ""
```

The initial value of a constant, the default of a field, the expansion of a macro or
the expression an alias stands for, as written.

#### `Symbol.target`

```zig
target: []const u8 = ""
```

Identifier of the symbol an alias stands for. Empty when it lies outside the document.

#### `Symbol.examples`

```zig
examples: []const Example = &.{}
```

Code that uses the symbol.

#### `Symbol.verified`

```zig
verified: []const []const u8 = &.{}
```

Sentences that the tests beside the symbol state and check.

#### `Symbol.members`

```zig
members: []const Symbol = &.{}
```

The symbols declared inside this one, in source order.

#### `Symbol.hasDocumentation`

```zig
pub fn hasDocumentation(symbol: Symbol) bool
```

Whether the symbol, or a symbol inside it, carries documentation of any kind or an
example. A writer for people leaves out the symbols for which this is false.

### `Text`

```zig
pub const Text = struct
```

Documentation as structure: a sequence of blocks.

#### `Text.blocks`

```zig
blocks: []const Block = &.{}
```

The blocks, in order. None when there is no documentation.

#### `Text.isEmpty`

```zig
pub fn isEmpty(text: Text) bool
```

Whether there is nothing to read.

### `Block`

```zig
pub const Block = union
```

A piece of text that stands on its own lines.

#### `Block.paragraph`

```zig
paragraph: []const Inline
```

Running text.

#### `Block.heading`

```zig
heading: Heading
```

A title inside the text.

#### `Block.code`

```zig
code: Code
```

Source code, kept verbatim.

#### `Block.list`

```zig
list: List
```

A sequence of items.

#### `Block.quote`

```zig
quote: []const Block
```

Text quoted from elsewhere.

#### `Block.note`

```zig
note: Note
```

Text set apart under a label, such as a note or a warning.

#### `Block.table`

```zig
table: Table
```

Rows of cells.

#### `Block.rule`

```zig
rule
```

A separation between two parts of the text.

### `Heading`

```zig
pub const Heading = struct
```

A title and how deep it sits.

#### `Heading.level`

```zig
level: u8
```

Between 1, the outermost, and 6.

#### `Heading.content`

```zig
content: []const Inline
```

The title.

### `Code`

```zig
pub const Code = struct
```

A block of source code.

#### `Code.language`

```zig
language: []const u8 = ""
```

The language of the code, empty when it is not stated.

#### `Code.text`

```zig
text: []const u8
```

The code, without a trailing line ending.

### `List`

```zig
pub const List = struct
```

A list and the blocks of each of its items.

#### `List.start`

```zig
start: ?u32 = null
```

The number of the first item, or null when the items are not numbered.

#### `List.items`

```zig
items: []const []const Block
```

The items, each a sequence of blocks.

### `Note`

```zig
pub const Note = struct
```

Blocks under a label.

#### `Note.label`

```zig
label: []const u8
```

The label, as its reader names it, such as "note" or "warning".

#### `Note.blocks`

```zig
blocks: []const Block
```

What the note says.

### `Table`

```zig
pub const Table = struct
```

A table. Every row has one cell per column.

#### `Table.header`

```zig
header: []const []const Inline = &.{}
```

The cells of the heading row. None when the table has no heading.

#### `Table.rows`

```zig
rows: []const []const []const Inline = &.{}
```

The other rows.

### `Inline`

```zig
pub const Inline = union
```

A piece of text inside a line.

#### `Inline.text`

```zig
text: []const u8
```

Plain characters.

#### `Inline.code`

```zig
code: []const u8
```

Characters of source code that name no symbol.

#### `Inline.ref`

```zig
ref: Ref
```

A mention of a symbol.

#### `Inline.param`

```zig
param: []const u8
```

A mention of a parameter of the symbol being documented, by its name.

#### `Inline.emphasis`

```zig
emphasis: []const Inline
```

Text that is stressed.

#### `Inline.strong`

```zig
strong: []const Inline
```

Text that is stressed more.

#### `Inline.link`

```zig
link: Link
```

Text that leads somewhere outside the document.

#### `Inline.image`

```zig
image: Link
```

A picture, by where it is and what stands for it when it cannot be shown.

#### `Inline.line_break`

```zig
line_break
```

The end of a line that the author asked to be kept.

### `Ref`

```zig
pub const Ref = struct
```

A mention of a symbol by the name the author wrote.

#### `Ref.text`

```zig
text: []const u8
```

The name as written.

#### `Ref.target`

```zig
target: []const u8 = ""
```

Identifier of the symbol. Empty when the name was not resolved.

### `Link`

```zig
pub const Link = struct
```

Text and the address it leads to.

#### `Link.url`

```zig
url: []const u8
```

The address.

#### `Link.content`

```zig
content: []const Inline = &.{}
```

What is shown.

### `plainText`

```zig
pub fn plainText(arena: std.mem.Allocator, text: Text) std.mem.Allocator.Error![]const u8
```

The characters of [`text`](#typereftext) with nothing of its structure: the blocks one after another,
a blank line between two, and a mention shown as the name that was written.

### `writeJson`

```zig
pub fn writeJson(writer: *std.Io.Writer, document: Document) std.Io.Writer.Error!void
```

Writes `document` as indented JSON.

### `readJson`

```zig
pub fn readJson(arena: std.mem.Allocator, bytes: []const u8) !Document
```

Reads a [`Document`](#document) back. Fails with `error.UnsupportedFormat` when it was written in
another [`format_version`](#format_version), and with the JSON parser's error when it is not a document.

### Verified behaviour

- a document survives the trip through JSON
- plain text keeps the characters and drops the structure
- a document written in another format version is refused

## `src/markdown_text.zig`

Reads Markdown into a [`ir.Text`](#text).

Markdown is the markup an author writes in a Zig doc comment, and the dialect read here
is the one Zig's own documentation generator reads: the parser under `markdown/` is the
one it ships, unchanged. Everything that parser recognizes has a place in the tree, so
nothing of the text is kept as markup. The alignment of table columns is the one thing
dropped.

A code span whose content has the shape of a name, which is one identifier or several
joined by a dot or by `::`, optionally followed by `()`, is read as a mention of a symbol
and becomes an [`ir.Ref`](#ref) with no target. Any other code span is plain code.

### `parse`

```zig
pub fn parse(arena: Allocator, source: []const u8) Allocator.Error!ir.Text
```

Parses `source`, whose lines end in `\n`, into a text allocated in `arena`.

### `isName`

```zig
pub fn isName(span: []const u8) bool
```

Whether `span` has the shape of a name that can mention a symbol.

### `Parts`

```zig
pub const Parts = struct
```

The identifiers of a name, which a dot or `::` separates.

#### `Parts.rest`

```zig
rest: ?[]const u8
```

What is left of the name. Null once the last part was given.

#### `Parts.next`

```zig
pub fn next(self: *Parts) ?[]const u8
```

The next identifier, or null after the last one.

### Verified behaviour

- a paragraph keeps its words, its stress and its links, and a name in backticks mentions a symbol
- blocks are told apart: heading, code, lists, quote, table and rule
- text with nothing in it has no blocks
- the shape of a name

## `src/zig_source.zig`

Reads a Zig source file through the compiler's own parser.

The file becomes a symbol of kind [`ir.Kind.module`](#kindmodule), documented by the `//!` block that
opens it, and every declaration of the file becomes a member of it, with the `///` block
above it when there is one. A container is walked recursively, so a method is a member
of its container. The members of an error set are read like the fields of a container.
A function that returns a container written in its own body, the way a generic type is
declared, is read as that container: what the returned container declares becomes the
members of the function.

Doc comments are Markdown, read by `markdown_text`.

A `test` named by a string contributes its name to [`ir.Symbol.verified`](#symbolverified) of the file. A
`test` named after a declaration contributes its body as an example of that declaration
when the two sit in the same container.

Every `@import` and `@cInclude` of the file is listed as an import, wherever it is written.

### `language`

```zig
pub const language = "zig"
```

The language name this reader gives its files, and the prefix of its identifiers.

### `read`

```zig
pub fn read(arena: Allocator, path: []const u8, source: [:0]const u8) !ir.Unit
```

Extracts one Zig file. `path` becomes the path of the file in the document. The symbol
of the file is identified by `zig:` followed by that path, and a declaration by that,
a `#`, and its name qualified by the containers around it. Fails with
`error.InvalidZigSource` when the file does not parse.

### Verified behaviour

- the file is a module documented by the block that opens it
- a function carries its prototype, parameters, return type, visibility and lines
- a container holds its fields and methods as members qualified by its name
- test names are collected in source order, including the ones inside a container
- a constant keeps its type and value, and a value that spans lines is left out
- imports and aliases are told apart from constants
- a function that returns a container is read as that container
- a test named after a declaration becomes an example of it
- the members of an error set are read with their documentation
- a file that does not parse is refused

## `src/doxygen_comment.zig`

Reads a documentation comment written the way Doxygen reads it.

A comment is documentation when it opens with `/**`, `/*!`, `///` or `//!`, which is
what [`shape`](#shape-1) tells. When the marker is followed by `<` the comment is about the
declaration before it and not the one after.

Inside a comment, `@brief`, `@param`, `@return` and their backslash forms are understood,
at the start of a line or after other text on it. `@note`, `@warning` and the like open
an [`ir.Note`](#note) that runs to the next blank line. `@file` marks the comment as being about
the file. `@c` marks the next word as code, `@p` and `@a` as a parameter and `@ref` as a
mention of a symbol. The rest of the text is Markdown, as Doxygen accepts it, read by
`markdown_text`.

No language is known here: which declaration a comment belongs to is for the reader of
that language to say.

### `DocParam`

```zig
pub const DocParam = struct
```

What a comment says of one parameter.

#### `DocParam.name`

```zig
name: []const u8
```

The name the comment gives the parameter.

#### `DocParam.text`

```zig
text: ir.Text
```

What is said of it.

### `Comment`

```zig
pub const Comment = struct
```

What was read from one comment.

#### `Comment.blocks`

```zig
blocks: []const ir.Block = &.{}
```

The text, without what is said of parameters and of the value returned.

#### `Comment.params`

```zig
params: []const DocParam = &.{}
```

What is said of each parameter, in the order of the comment.

#### `Comment.returns`

```zig
returns: ir.Text = .{}
```

What is said of the value returned.

#### `Comment.is_file`

```zig
is_file: bool = false
```

Whether the comment is about the file it is in.

### `Shape`

```zig
pub const Shape = struct
```

How a documentation comment is written.

#### `Shape.block`

```zig
block: bool
```

Whether it is a `/** */` comment and not lines of `///`.

#### `Shape.trailing`

```zig
trailing: bool
```

Whether it is about the declaration before it.

### `shape`

```zig
pub fn shape(text: []const u8) ?Shape
```

The shape of the comment [`text`](#docparamtext), or null when it is not documentation: a plain comment,
or a banner such as `/*****/` and `////`.

### `parse`

```zig
pub fn parse(arena: Allocator, raw: []const u8, block: bool) Allocator.Error!Comment
```

Reads the documentation comment `raw`, which is the whole comment with its markers. A
comment written as several lines of `///` or `//!` is given as those lines, one after
another. [`block`](#shapeblock) says whether it is a `/** */` comment.

### Verified behaviour

- a comment is documentation by the way it opens
- parameters, the value returned and notes are taken out of the text
- lines of comment are one comment, and one that names the file is about the file
- the word after an inline command is code, a parameter or a mention

## `src/c_source.zig`

Reads the declarations of a C or C++ file and the documentation written on them.

The parser is tree-sitter, with its C grammar or its C++ grammar as [`Dialect`](#dialect) says, and
this file only turns the tree into the document model. The C++ grammar extends the C one,
so one reader serves both. Every declaration is recorded, documented or not: a function,
a type, a variable, a macro, and inside a struct, a union or a class each member, with
one symbol per name when a line declares several. An `extern "C"` block and a conditional
of the preprocessor are transparent: what they hold belongs to the scope around them.
The file becomes a symbol of kind [`ir.Kind.module`](#kindmodule) and what it declares becomes its
members.

The grammar reads the source before the preprocessor runs, so a macro in front of a
declaration, the way a library marks what it exports, is not valid to it. When a
declaration fails to parse and opens with the name of a macro the same file defines
without parameters, that name is put out of the way and the file is parsed again. The
same is done for such a name among the parameters of a declaration that fails to parse,
and for the names [`read`](#read-1) is told other files define, which [`outline`](#outline-1) finds in a
file without reading the rest of it. The signature of the symbol still shows the name,
since it is taken from the source as written.

The identifier of a symbol is its language, a colon, the path of its file, a `#` and its
name qualified by what is around it: `c:pool.h#pool.wait`, with a dot between the parts
in C, and `cpp:pool.hpp#ke::Pool::wait(int)`, with two colons in C++, where a function
also carries the types of its parameters, since the language lets a name be declared
once per list of them. A struct or an enum that
is defined through a typedef is one symbol under the name of the typedef, and so is one
that a typedef of the same name announces before it is defined. A struct or union
without a name, inside another, is named after what it is. The macro that guards a
header against a second inclusion is not a symbol. What the grammar reads as a declaration
without a name is not a symbol either, and what it holds belongs to the scope around it,
as the values of an enum without a name do.

In C++, a namespace is a symbol of kind [`ir.Kind.namespace`](#kindnamespace) with what it holds as its
members, a class or struct lists what it derives from, a member carries the visibility
its section gives it, and a template carries its parameters. A member function is a
function, and so are a constructor, a destructor and an operator, under the name they
are written with. A member defined outside its class, as `void Pool::stop() {}`, is a
function named after its last part and qualified by the rest, and [`join`](#join) gives it back to
the declaration its class has of it.

What a comment means is read by `doxygen_comment`. A comment belongs to the declaration
that follows it, or to the one before it when it says so, and a comment that names the
file documents the file. The parameters of a function, of a function pointer and of a
callback type are taken from the declaration, with name and type, and what a comment
says of a parameter is attached to the one it names. A parameter that only a comment
names is kept, with no type.

### `Dialect`

```zig
pub const Dialect = enum
```

Which grammar a file is read with. A `.h` file says C by its extension, and [`Dialect.detect`](#dialectdetect)
tells whether it is C++ all the same. The name of each is the language its files are
given and the prefix of their identifiers.

#### `Dialect.c`

```zig
c
```

C.

#### `Dialect.cpp`

```zig
cpp
```

C++.

#### `Dialect.of`

```zig
pub fn of(extension: []const u8) ?Dialect
```

The dialect a file with `extension`, dot included, is read with, or null when the
file is neither C nor C++. A `.h` file is taken as C.

#### `Dialect.detect`

```zig
pub fn detect(source: []const u8) error{GrammarRejected}!Dialect
```

Which grammar a header is read with when its extension does not say, as with `.h`.
It is C++ when the C++ grammar reads in it something C does not have, which is a
namespace, a class, a template, a section of a class or a using declaration, unless the C
grammar makes sense of all of it and the C++ grammar does not. Otherwise it is C.
Fails with
`error.GrammarRejected` when the parser does not take a grammar.

### `Error`

```zig
pub const Error = Allocator.Error || error{GrammarRejected}
```

What [`read`](#read-1) fails with.

### `Outline`

```zig
pub const Outline = struct
```

What a C file pulls in and defines, found without reading its declarations.

#### `Outline.includes`

```zig
includes: []const []const u8
```

The name of every file it includes, in source order.

#### `Outline.macros`

```zig
macros: []const []const u8
```

The name of every macro it defines without parameters.

### `outline`

```zig
pub fn outline(arena: Allocator, dialect: Dialect, source: []const u8) Error!Outline
```

Finds the includes of a file and the macros it defines without parameters. Fails with
`error.GrammarRejected` when the parser does not take the grammar.

### `read`

```zig
pub fn read(arena: Allocator, dialect: Dialect, path: []const u8, source: []const u8, macros: []const []const u8) Error!ir.Unit
```

Reads one file. `path` becomes the path of the file in the document. The symbol of the
file is identified by the name of `dialect`, a colon and that path, and a declaration by
that, a `#`, and its name qualified by what is around it. [`macros`](#outlinemacros) names the macros without parameters
that other files define and this one may use in front of a declaration. What the grammar
cannot make sense of is left out, and the declarations around it are still read. Fails
with `error.GrammarRejected` when the parser does not take the grammar this package was
built with.

### `join`

```zig
pub fn join(arena: Allocator, units: []ir.Unit) Allocator.Error!void
```

Joins every member that a C++ file of [`units`](#projectunits) defines outside its class to the
declaration that class has of it, in whichever of the files it is. The declaration
receives the place of the definition, and its documentation when it has none of its own,
and the definition leaves its file. A definition whose class is in none of the files
stays where it is.

### Verified behaviour

- a function carries its name, parameters, return type and documentation
- a macro another file defines is put out of the way too, and an outline finds what a file defines
- the slots of a vtable are members named after the function pointer
- a callback typedef is named after the pointer it declares
- a trailing comment documents the declaration before it, and each name on a line is a field
- enumerators carry their values and their own lines
- an extern block is transparent, includes and macros are recorded and the guard is not
- a file comment documents the file and a parameter only a comment names is kept
- plain comments and banner comments are not documentation
- a function with a body and a table with its values are read without what follows the declaration
- a union without a name is named after what it is, and one that types a field lends it its members
- a namespace, a class, its members and what it derives from are read from a C++ file
- a file is read as C or as C++ by its extension
- a member defined outside its class is joined to the declaration it has there
- a header is taken for C++ when only the C++ grammar makes sense of it
- a macro among the parameters of a declaration is put out of the way like one in front of it

## `src/xml_comment.zig`

Reads the XML a C# documentation comment is written in into the document model.

What is read is the text of the comment with its `///` already taken off each line. The
elements that stand at the top say what each part is about: `<summary>`, `<remarks>` and
`<value>` are the documentation itself, in the order they are written, `<param>` and
`<typeparam>` document the parameter their `name=` gives, `<returns>` what is returned,
`<exception>` a failure whose type its `cref=` gives, and each `<code>` inside an
`<example>` is an example, the words around it joining the documentation. Text that
stands in no element is documentation too, so a comment without any element is read
whole. `<inheritdoc>` asks for the documentation of another symbol, the one its `cref=`
names when it has one.

Inside a part, `<para>` is a paragraph, and so is text set apart by an empty line.
`<code>` is a block of code kept as written, `<list>` a list with one item per `<item>`,
numbered when its `type=` is "number", and a `<term>` is joined to its `<description>` by
a colon. In a line, `<see>` and `<seealso>` with a `cref=` mention a symbol, with a
`langword=` are code and with an `href=` are a link, `<paramref>` mentions a parameter,
`<typeparamref>` and `<c>` are code, `<b>` and `<strong>` stress more than `<i>` and
`<em>`, and `<br>` ends a line. An element not listed here is read for what it holds.

The name in a `cref=` loses what the compiler does not need to find it by name: the
letter and colon in front, the list of parameters, and the type arguments in braces.

Markup that is not well formed does not fail. A `<` that opens nothing is a character,
and an element left open ends where its parent does.

### `Named`

```zig
pub const Named = struct
```

What a comment says about something it names.

#### `Named.name`

```zig
name: []const u8
```

The name of the parameter, or the type of the failure.

#### `Named.text`

```zig
text: ir.Text
```

What is said.

### `Comment`

```zig
pub const Comment = struct
```

What one comment says.

#### `Comment.blocks`

```zig
blocks: []const ir.Block = &.{}
```

The documentation.

#### `Comment.params`

```zig
params: []const Named = &.{}
```

What is said of each parameter, in the order written.

#### `Comment.type_params`

```zig
type_params: []const Named = &.{}
```

What is said of each parameter that stands for a type.

#### `Comment.returns`

```zig
returns: ir.Text = .{}
```

What is said to be returned.

#### `Comment.raises`

```zig
raises: []const Named = &.{}
```

The failures said to be raised, each under the name of its type.

#### `Comment.examples`

```zig
examples: []const ir.Example = &.{}
```

The code given as examples.

#### `Comment.inherits`

```zig
inherits: ?[]const u8 = null
```

The name of the symbol whose documentation is asked for, empty when none is named,
and null when the comment asks for none.

### `parse`

```zig
pub fn parse(arena: Allocator, raw: []const u8) Allocator.Error!Comment
```

Reads `raw`, the lines of a comment joined by `\n` without their `///`.

### `nameOf`

```zig
pub fn nameOf(arena: Allocator, cref: []const u8) Allocator.Error![]const u8
```

The name a `cref=` gives, without the prefix, the parameters and the type arguments the
compiler writes around it.

### Verified behaviour

- the parts of a comment are told apart by the element that holds them
- inline elements become mentions, code, parameters, stress and links
- paragraphs, code and lists are blocks, and the code of an example is an example
- a comment without elements is documentation, and markup that is not well formed is read for what it holds

## `src/csharp_source.zig`

Reads the declarations of a C# file and the documentation written on them.

The parser is tree-sitter with its C# grammar, and this file only turns the tree into the
document model. Every declaration is recorded, documented or not, with the visibility it
states or the one the language gives it when it states none. The file becomes a symbol of
kind [`ir.Kind.module`](#kindmodule) and what it declares becomes its members. A namespace is a symbol
of kind [`ir.Kind.namespace`](#kindnamespace), one per part of its name, so `namespace Ke.Tasks` is "Tasks"
inside "Ke", and a namespace declared for the whole file holds what follows it. A conditional of
the preprocessor is transparent: what it holds belongs to the scope around it.

A class, a struct, an interface, a record, an enum and a delegate are types, told apart
by [`ir.Symbol.form`](#symbolform). A method, a constructor, a destructor and an operator are functions,
a property and an indexer are properties, and a field declared `const` is a constant. A
line that declares several fields or events gives one symbol per name. Each parameter a
record is declared with is also a property of it, as the language makes it one, carrying
what the comment of the record says of that parameter.

The identifier of a symbol is `csharp:`, the path of its file, a `#` and its name
qualified by what is around it. Since C# lets a name be declared more than once, a type
with parameters has their count after a grave accent, and what takes parameters has their
types between parentheses: `csharp:Pool.cs#Ke.Pool.Run(int,string)`.

A documentation comment is the run of `///` lines in front of a declaration, or a
`/** */` block there, and what it means is read by `xml_comment`. What it says of a
parameter is attached to the one it names, and a comment that asks for the documentation
of another symbol leaves that request in [`ir.Symbol.inherits`](#symbolinherits) for the linker.

[`join`](#join-1) makes one symbol of a type declared in parts, in several files.

### `Error`

```zig
pub const Error = Allocator.Error || error{GrammarRejected}
```

What [`read`](#read-2) fails with.

### `language`

```zig
pub const language = "csharp"
```

The name [`ir.File.language`](#filelanguage) carries for a file read here.

### `reads`

```zig
pub fn reads(extension: []const u8) bool
```

Whether a file with this extension is read here.

### `read`

```zig
pub fn read(arena: Allocator, path: []const u8, source: []const u8) Error!ir.Unit
```

Reads one file. `path` becomes the path of the file in the document. What the grammar
cannot make sense of is left out, and the declarations around it are still read. Fails
with `error.GrammarRejected` when the parser does not take the grammar this package was
built with.

### `join`

```zig
pub fn join(arena: Allocator, units: []ir.Unit) Allocator.Error!void
```

Makes one symbol of every type that [`units`](#projectunits) declare in parts, in more than one place.
The first part met keeps the symbol and receives the members, the places and the bases
of the others, and their documentation when it has none. The other parts leave their
files, and what moved is identified under the file of the part that stayed.

### Verified behaviour

- a namespace, a class, its members and what it derives from are read
- a type declared in parts in several files becomes one symbol in the file of its first part
- the parameters a record is declared with are properties of it

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

The path a file gets in the document never names the machine it was read on, and has `/`
between its parts whatever the system it was read on writes there. The root
file of a module is given relative to [`Options.base`](#optionsbase) when it lies under it, and under
the name of its module otherwise. The root of a reference-only module is always given
under the name of its module, so that its path does not depend on where it was read from. A file imported relatively is placed relative to its
importer, and an included file keeps the name it was included by.

A file is read by the reader its extension names. A `.h` file is read as C or as C++,
whichever [`c_source.Dialect.detect`](#dialectdetect) finds it to be.

A C file has the files it includes read before it, so that a macro one of them defines is
known when it stands in front of a declaration, the way a library marks what it exports.

When the path of the first module is a directory there is no root file: every file under
it that a reader exists for is read, in the order of their paths, and the directory is
documented. The macros of every C and C++ file among them are known to all of them, since
nothing says where their headers are looked for. A directory whose name starts with a dot
is not entered, and neither is one
of [`Options.excluded_dirs`](#optionsexcluded_dirs). The parts of a C# type declared in parts are then joined
into one symbol, and a C++ member defined outside its class is joined to its declaration.

Every file reached is read into an [`ir.Unit`](#unit), so that a reference into it resolves, but only a file under
one of [`Options.documented_dirs`](#optionsdocumented_dirs), and under none of [`Options.excluded_dirs`](#optionsexcluded_dirs), is marked as
documented. The exception is a module that
is [`Module.reference_only`](#modulereference_only): an import into it is given its path without the file being
read, and [`Project.reference`](#projectreference) reads one such file when a reference goes through it. Its
files are never documented, and the includes in them are not followed.

[`Project.references`](#projectreferences) opens reference-only modules alone and reads nothing. It serves a
linker that was handed a document read elsewhere, since the paths it answers for are the
ones [`Project.open`](#projectopen) gave the imports of that document.

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

#### `Options.excluded_dirs`

```zig
excluded_dirs: []const []const u8 = &.{}
```

Directories on disk whose files are not documented, whatever contains them.

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

#### `Project.excluded`

```zig
excluded: std.ArrayList([]const u8) = .empty
```

The excluded directories as absolute paths.

#### `Project.seen`

```zig
seen: std.StringHashMapUnmanaged([]const u8) = .empty
```

Path in the document of each file read by [`open`](#projectopen), by its absolute path on disk.

#### `Project.units`

```zig
units: std.ArrayList(ir.Unit) = .empty
```

What [`open`](#projectopen) read, dependencies before the files that import them.

#### `Project.postponed`

```zig
postponed: std.StringHashMapUnmanaged(Postponed) = .empty
```

Where on disk each file of a reference-only module is, by its path in the document.

#### `Project.answers`

```zig
answers: std.StringHashMapUnmanaged(?*const ir.Unit) = .empty
```

What [`reference`](#projectreference) answered for each path it was asked.

#### `Project.macros`

```zig
macros: std.ArrayList([]const u8) = .empty
```

The macros without parameters that the C files read so far define.

#### `Project.referenced`

```zig
referenced: std.ArrayList(*const ir.Unit) = .empty
```

What [`reference`](#projectreference) read, in the order it was asked for.

#### `Project.open`

```zig
pub fn open(arena: Allocator, io: std.Io, options: Options) !Project
```

Reads the root of the first module and everything it imports, dependencies first,
or every file under that root when it is a directory. Fails when there is no module
or when a root file cannot be read or parsed.

#### `Project.references`

```zig
pub fn references(arena: Allocator, io: std.Io, modules: []const Module) Allocator.Error!Project
```

Takes every one of [`modules`](#optionsmodules) as reference-only, whatever [`Module.reference_only`](#modulereference_only)
says, and reads none of them. [`ModuleImport.module`](#moduleimportmodule) indexes [`modules`](#optionsmodules).

#### `Project.reference`

```zig
pub fn reference(self: *Project, path: []const u8) Allocator.Error!?*const ir.Unit
```

The file of a reference-only module that an import was given [`path`](#modulepath) for, read on
the first call. Null when [`path`](#modulepath) is not such a file or it cannot be read.

### Verified behaviour

- imports are followed by kind, and only the files under a documented directory are documented
- a file under an excluded directory is read and not documented
- a named import is looked up in the module of the file that names it
- a file of a reference-only module is read only when a reference goes through it
- reference-only modules opened alone answer for the paths an import was given
- a root that cannot be read is an error
- a directory given as the root has every file a reader exists for read, with partial types joined

## `src/link.zig`

Resolves the names a document mentions into references to its symbols.

Three things are resolved. The first is a mention: an [`ir.Ref`](#ref) that its reader left
without a target. The second is the target of an alias, which in Zig is an import or a
constant that names another declaration. The third is the target of a type: an
[`ir.TypeRef`](#typeref) gets the first name written in it that resolves to a type or to an alias. In
a Zig file such a name is only looked for in the scopes around it, since Zig has no name
that a file did not declare or import. A type that declares its own members where it is
written, and one that names nothing in the sources, stay without a target and are no
problem.

A symbol that asks for the documentation of another, through [`ir.Symbol.inherits`](#symbolinherits), is
given what it does not say itself: the text, what is returned, what is raised, the
examples, and what is said of each parameter it has under the same name. The other
symbol is the one it names, or else the member of the same name in the first of the
types its own type derives from that has one, looked for upwards. A type that names none
takes from the first type it derives from.

A name is one identifier or several joined by a dot or by `::`, optionally followed by
`()`. Its
first part is looked for in the scopes around the text, innermost first: the members of
the symbol being documented, its siblings, and outwards to the top of its file. Inside a
type, its own name is the type and not the constructor that shares it. When no
scope has it, every symbol of every file is searched, the file of the text first. Each
following part is looked for among the members of what the previous part named, going
through an import into the file it resolved to and through an alias into what it names.
An import may lead to a file that is not in the document, in which case a [`Source`](#source) is
asked for it.

A mention that resolves gets its target. One that names a parameter of the symbol being
documented becomes an [`ir.Inline.param`](#inlineparam). One that resolves to nothing is turned into
plain code when it appears in the signature of that symbol or is a word of the language,
when it is dotted and its first part is unknown, since it is then a file name or a name
from outside the sources, and when a part names something whose members are not known,
such as an import that was not followed. Every other mention is a [`Problem`](#problem) and stays a
mention without a target, and so is a documented parameter that the signature does not
have. A word of the language includes the names its own library is best known by, such
as the fixed-width integers of C and the common types of the C# base library, and a name
given in [`Options.external`](#optionsexternal) is taken the same way. Problems are only raised for documented files.

What a [`Source`](#source) supplied joins the document, in front, cut down to the members that a
reference names or reaches into.

### `Problem`

```zig
pub const Problem = struct
```

One mention that names nothing.

#### `Problem.path`

```zig
path: []const u8
```

Path of the file the mention is in.

#### `Problem.owner`

```zig
owner: []const u8
```

Qualified name of the symbol whose documentation mentions.

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

A mention that names no symbol.

##### `Problem.Kind.parameter`

```zig
parameter
```

A documented parameter that the signature does not have.

### `Result`

```zig
pub const Result = struct
```

The linked document and what could not be resolved in it.

#### `Result.document`

```zig
document: ir.Document
```

The document, with [`ir.Document.linked`](#documentlinked) set.

#### `Result.problems`

```zig
problems: []const Problem
```

One entry per mention of a documented file that names nothing.

### `Source`

```zig
pub const Source = struct
```

Supplies a file that an import leads to and that is not in the document.

#### `Source.context`

```zig
context: *anyopaque
```

Passed back to [`find`](#sourcefind) on every call.

#### `Source.find`

```zig
find: *const fn (context: *anyopaque, path: []const u8) Allocator.Error!?*const ir.Unit
```

What was read from the file at [`path`](#problempath), or null when there is none.

### `Options`

```zig
pub const Options = struct
```

What a linker is given besides the document.

#### `Options.source`

```zig
source: ?Source = null
```

Supplies the files that imports lead to outside the document. Null to follow none.

#### `Options.external`

```zig
external: []const []const u8 = &.{}
```

Names declared outside the sources, such as the types of a library that is only
used. A mention of one, or of something inside one, is code and no problem.

### `link`

```zig
pub fn link(arena: Allocator, document: ir.Document, options: Options) Allocator.Error!Result
```

Links [`document`](#resultdocument). Each of its top-level symbols must stand for one of its files, the
way the readers of this package produce them, in the same order as the files.

### Verified behaviour

- a mention gets the symbol it names as its target, by plain or qualified name
- the nearest scope wins when a name is declared twice
- a mention that names nothing is reported once and stays a mention without a target
- a parameter becomes a parameter mention and a word of the language becomes code
- a dotted name is accepted when its first part is unknown or was not followed
- an import and an alias lead to the symbol in the other file
- a name declared in a file of another language is found, and an undocumented file raises no problem
- a documented parameter that the signature does not have is reported
- a name that leads outside the document is followed into what the source supplies, which joins the document cut down
- a type gets the first name written in it that is a type, and a name of nothing leaves it without a target
- a mention written with the separator of C++ names the member, and a base gets its class
- a name qualified by a namespace is found in whichever file declares it there
- a symbol that asks for the documentation of another is given what it does not say itself
- a name declared outside the sources is no problem when it is known to the language or was given as external

## `src/schema.zig`

Describes the JSON of a document as a JSON Schema.

The schema is not written by hand: it is derived from the types of `ir`, the same ones
the document is written from and read into, so it cannot say something else than they do.
It follows the 2020-12 draft. Every struct, enum and union of the model gets a definition
under its own name, and the schema as a whole is the definition of [`ir.Document`](#document).

A struct is an object that admits no other property than its fields, of which those
without a default are required. An enum is the name of one of its values. A union is an
object with a single property, named after the alternative it holds, and an alternative
that holds nothing has an empty object as its value. A slice of bytes is a string, any
other slice an array, and an optional admits null.

### `dialect`

```zig
pub const dialect = "https://json-schema.org/draft/2020-12/schema"
```

The address the schema declares itself to follow.

### `write`

```zig
pub fn write(writer: *std.Io.Writer) std.Io.Writer.Error!void
```

Writes the schema of [`ir.Document`](#document) as indented JSON.

### Verified behaviour

- the schema is JSON that defines every type of the model, with the fields that have no default required

## `src/markdown.zig`

Writes a document as one plain Markdown file.

Only the symbols of documented files are written, and of those only the ones with
something to say. A symbol gets a section when it carries documentation of any kind or
an example, or when one of its members does. With a single file the sections are
second-level; with several, each file gets a second-level section named after its path
and its symbols move one level down. A member is headed by its qualified name, so a
heading is unambiguous when read out of context. A namespace without documentation of its
own gets no section: what it holds is written in its place. A file that says nothing
itself and holds only namespaces gets no section either: what its namespaces hold is
written under one section per namespace, named after it, after the sections of the other
files and in the order of the names, so that a namespace spread over many files reads as
one. The sentences a file
verifies close it as a list under "Verified behaviour".

Documentation arrives as an [`ir.Text`](#text) and is written out as Markdown here: this is the
only place of the package that produces that markup. A mention whose target has a
section becomes a link to it. The link target is the anchor a Markdown renderer derives
from the heading: its text in lower case, without punctuation, with a counter appended
when the same text was already used. No anchor is written into the file.

[`writePages`](#writepages) writes the same document as a directory of smaller files, for a tool that
makes a site of them: one for each file or namespace, one for each type with documented
members, an index and a table of contents.

### `Error`

```zig
pub const Error = Allocator.Error || Writer.Error
```

What writing can fail with: the arena or the writer.

### `write`

```zig
pub fn write(arena: Allocator, writer: *Writer, title: []const u8, document: ir.Document) Error!void
```

Renders `document` under a first-level heading carrying `title`.

### `Page`

```zig
pub const Page = struct
```

One file of a document written as several.

#### `Page.path`

```zig
path: []const u8
```

Name of the file, with no directory in it.

#### `Page.text`

```zig
text: []const u8
```

What the file holds.

### `writePages`

```zig
pub fn writePages(arena: Allocator, title: []const u8, document: ir.Document) Error![]const Page
```

Renders `document` as several files meant for one directory: a page per section that
[`write`](#write-1) would give a file or a namespace, a page per type of it that has documented
members, `index.md` listing the first under `title`, and `toc.yml`, which is the same
list with the types under each, as a sequence of entries with a name, the file it leads to
and the entries under it. A page is
named after what it documents, in lower case. A mention links across pages.

### Verified behaviour

- a single file is written flat, with an example and its verified sentences as a closing list
- a member is headed by its qualified name, only documented parameters are listed and a type links to its section
- a mention links to the section of its target, across files and with repeated headings numbered
- every kind of block and inline is written as the markup that reads back the same
- files that hold only namespaces are written as one section per namespace
- a document written as pages has a page per section and per type, an index and a table of contents

## `src/text.zig`

Writes a document, or one symbol of it, as plain text for a terminal.

Nothing here is markup: the text is meant to be read as it is printed. A symbol opens
with its qualified name on a line of its own, followed by what it is and where it is
declared, its signature, and its documentation indented under them, with paragraphs
broken at [`Options.width`](#optionswidth) columns. Code keeps its lines. A mention, a parameter and code
inside a line are set between grave accents, and a link is followed by its address
between parentheses.

[`write`](#write-2) prints every symbol of the documented files that [`ir.Symbol.hasDocumentation`](#symbolhasdocumentation),
which is what the Markdown writer gives a section to. [`writeSymbol`](#writesymbol) prints one symbol in
full, whether it is documented or not, and closes it with one line per member, so that
what is inside it can be asked for next.

### `Error`

```zig
pub const Error = Allocator.Error || Writer.Error
```

What writing can fail with: the arena or the writer.

### `Options`

```zig
pub const Options = struct
```

How the text is laid out.

#### `Options.width`

```zig
width: usize = 80
```

The column a paragraph is broken before.

### `write`

```zig
pub fn write(arena: Allocator, writer: *Writer, title: []const u8, document: ir.Document, options: Options) Error!void
```

Prints `title`, then every documented symbol of the documented files of `document`.

### `writeSymbol`

```zig
pub fn writeSymbol(arena: Allocator, writer: *Writer, symbol: ir.Symbol, options: Options) Error!void
```

Prints `symbol` in full and one line for each of its members.

### Verified behaviour

- one symbol is printed in full, with a line for each member
- a document is printed with its documented symbols only

## `src/query.zig`

Finds the symbols of a document that a name asks for.

A name is looked for three ways, and the first that finds anything answers. It is first
taken as an identifier or a qualified name, written in full. Then as the end of a
qualified name: "Pool.wait" finds "ke.Pool.wait", and "wait" finds every symbol of that
name, whichever separator its language writes between the parts. Last, as a piece of a
name, without regard to case, which is what answers a name that is only half remembered.

### `find`

```zig
pub fn find(arena: Allocator, document: ir.Document, name: []const u8) Allocator.Error![]const ir.Symbol
```

The symbols of `document` that [`name`](#importname) asks for, in the order of the document. None when
no name holds it.

### Verified behaviour

- a name is found in full, then as the end of a qualified name, then as a piece of one

## `src/cli.zig`

The stages as the commands of a program.

[`read`](#topicread) turns sources into a document, [`link`](#topiclink) resolves the mentions of one or several
documents, and [`write`](#topicwrite) renders a document. Each takes its document from a file or from
standard input and gives its result to a file or to standard output, so the three can be
joined by pipes or kept apart by the files between them.

[`parse`](#parse-3) turns arguments into a [`Command`](#command) and [`run`](#run) carries one out. A [`Read`](#read-3) describes
its modules by name, and [`options`](#options-3) turns those names into what [`project.Project.open`](#projectopen)
takes.

### `Topic`

```zig
pub const Topic = enum
```

What `docir help` can be asked about.

#### `Topic.all`

```zig
all
```

Every command.

#### `Topic.read`

```zig
read
```

`docir read`.

#### `Topic.link`

```zig
link
```

`docir link`.

#### `Topic.write`

```zig
write
```

`docir write`.

#### `Topic.query`

```zig
query
```

`docir query`.

#### `Topic.schema`

```zig
schema
```

`docir schema`.

### `usage`

```zig
pub const usage
```

What `docir help` prints: every command and its options.

### `usageOf`

```zig
pub fn usageOf(topic: Topic) []const u8
```

What `docir help` prints about `topic`.

### `Named`

```zig
pub const Named = struct
```

A name and what it was given, as in `--module name=file`.

#### `Named.name`

```zig
name: []const u8
```

What stands before the `=`.

#### `Named.value`

```zig
value: []const u8
```

What stands after it.

### `Import`

```zig
pub const Import = struct
```

One `--import`: [`module`](#importmodule) may import [`target`](#importtarget) by writing [`name`](#importname-1).

#### `Import.module`

```zig
module: []const u8
```

Name of the importing module. Empty for the root one.

#### `Import.name`

```zig
name: []const u8
```

The name as an `@import` writes it.

#### `Import.target`

```zig
target: []const u8
```

Name of the module that is imported.

### `Read`

```zig
pub const Read = struct
```

The arguments of `docir read`.

#### `Read.root`

```zig
root: []const u8
```

Path of the root file of the module that is documented, or of a directory whose
files are.

#### `Read.name`

```zig
name: []const u8 = ""
```

Name of that module. Empty to take it from the name of [`root`](#readroot).

#### `Read.base`

```zig
base: []const u8 = ""
```

Directory that paths in the document are relative to.

#### `Read.modules`

```zig
modules: []const Named = &.{}
```

Every other module with its root file.

#### `Read.imports`

```zig
imports: []const Import = &.{}
```

Which module may import which.

#### `Read.includes`

```zig
includes: []const Named = &.{}
```

Include directories, each under the name of its module, empty for the root one.

#### `Read.references`

```zig
references: []const Named = &.{}
```

The reference-only modules with their root files.

#### `Read.documented`

```zig
documented: []const []const u8 = &.{}
```

Directories documented besides that of [`root`](#readroot).

#### `Read.excluded`

```zig
excluded: []const []const u8 = &.{}
```

Directories that are not documented.

#### `Read.depfile`

```zig
depfile: ?[]const u8 = null
```

Where the list of the files read goes, as the rule of a makefile, for a build
system to know when to read again. Null to write none.

#### `Read.output`

```zig
output: ?[]const u8 = null
```

Where the document goes. Null for standard output.

### `Link`

```zig
pub const Link = struct
```

The arguments of `docir link`.

#### `Link.inputs`

```zig
inputs: []const []const u8 = &.{}
```

The documents to link as one. Empty to read one from standard input.

#### `Link.references`

```zig
references: []const Named = &.{}
```

The reference-only modules with their root files.

#### `Link.external`

```zig
external: []const []const u8 = &.{}
```

Names declared outside the sources, which a mention may use.

#### `Link.strict`

```zig
strict: bool = false
```

Whether a mention that names nothing is a failure.

#### `Link.output`

```zig
output: ?[]const u8 = null
```

Where the linked document goes. Null for standard output.

### `Format`

```zig
pub const Format = enum
```

What `docir write` renders a document as.

#### `Format.markdown`

```zig
markdown
```

One Markdown file.

#### `Format.text`

```zig
text
```

Plain text for a terminal.

### `Write`

```zig
pub const Write = struct
```

The arguments of `docir write`.

#### `Write.format`

```zig
format: Format = .markdown
```

What the document is rendered as.

#### `Write.input`

```zig
input: ?[]const u8 = null
```

The document to render. Null to read it from standard input.

#### `Write.title`

```zig
title: []const u8 = "Reference"
```

First heading of what is written.

#### `Write.width`

```zig
width: usize = 80
```

The column text is broken before.

#### `Write.pages`

```zig
pages: bool = false
```

Whether Markdown is written as a directory of pages, which [`output`](#writeoutput) then names.

#### `Write.output`

```zig
output: ?[]const u8 = null
```

Where the text goes. Null for standard output.

### `Query`

```zig
pub const Query = struct
```

The arguments of `docir query`.

#### `Query.name`

```zig
name: []const u8
```

The name asked for.

#### `Query.input`

```zig
input: ?[]const u8 = null
```

The document to look in. Null to read it from standard input.

#### `Query.json`

```zig
json: bool = false
```

Whether the symbols found are printed as JSON.

#### `Query.width`

```zig
width: usize = 80
```

The column text is broken before.

#### `Query.output`

```zig
output: ?[]const u8 = null
```

Where the answer goes. Null for standard output.

### `Command`

```zig
pub const Command = union
```

What the program was asked to do.

#### `Command.help`

```zig
help: Topic
```

Print what [`usageOf`](#usageof) says of a topic.

#### `Command.version`

```zig
version
```

Print the version.

#### `Command.read`

```zig
read: Read
```

Read sources into a document.

#### `Command.link`

```zig
link: Link
```

Link documents.

#### `Command.write`

```zig
write: Write
```

Render a document.

#### `Command.query`

```zig
query: Query
```

Print the symbols a name asks for.

#### `Command.schema`

```zig
schema: ?[]const u8
```

Print the JSON Schema of a document, to the file named or to standard output.

### `parse`

```zig
pub fn parse(arena: Allocator, args: []const [:0]const u8, message: *[]const u8) error{ Invalid, OutOfMemory }!Command
```

Turns the arguments after the program name into a [`Command`](#command). An option takes its value
as the next argument or after an `=`, an argument that does not open with a dash is
positional wherever it stands, and so is every argument after `--`. `--help` or `-h`
after a command asks for the help of that command. Fails with `error.Invalid`, after
setting `message` to what is wrong, when the arguments cannot be followed.

### `options`

```zig
pub fn options(arena: Allocator, command: Read, message: *[]const u8) error{ Invalid, OutOfMemory }!docir.project.Options
```

The modules `command` describes as [`project.Project.open`](#projectopen) takes them: the root one, then
each of [`Read.modules`](#readmodules), then each of [`Read.references`](#readreferences). A reference-only module can be
imported by its own name from every module that gives that name to no other. Fails with
`error.Invalid`, after setting `message`, when a module is named that was not declared.

### `run`

```zig
pub fn run(arena: Allocator, io: std.Io, args: []const [:0]const u8) !u8
```

Carries out the command that `args`, the arguments after the program name, ask for, and
returns the exit code of the program: 0 when it was done, 1 when it could not be, and 2
when the arguments name no command. What went wrong is said on standard error.

### Verified behaviour

- read arguments become the modules of a project
- the root module is named after its file when no name is given
- arguments that cannot be followed say why
- link and write take their documents and options
- an option takes its value after an equals sign, and a double dash ends the options
- help is asked for by name or after a command, and the version by its own word

## `src/root.zig`

docir turns the documentation written in source code into data, and that data into text.

The work is done in three stages around one representation, `ir`. A reader turns the
sources of one language into it: `zig_source` reads Zig, `c_source` reads C and C++ and
`csharp_source` reads C#, and `project` decides which files they read, by following
imports from the root file of a module or by taking every file of a directory. `link` resolves the names the documentation mentions into references. A writer
renders the result: `markdown` writes one Markdown file and `text` writes for a terminal,
where `query` finds the symbols a name asks for. Between stages the representation is
JSON, written by [`ir.writeJson`](#writejson) and read back by [`ir.readJson`](#readjson), so a stage may as well
be another program, and `schema` describes that JSON to one.

[`read`](#read-4), [`combine`](#combine) and [`resolve`](#resolve) are the first two stages as functions. `cli` offers the
three stages as the commands of the program, and the build file of this package runs
that program as the steps of a build, with what [`read`](#read-4) needs taken from a module.

### `read`

```zig
pub fn read(arena: std.mem.Allocator, io: std.Io, options: project.Options) !ir.Document
```

Reads the root of [`options`](#projectoptions) and everything it imports into a document that is not
linked. An import into a reference-only module keeps the path of the file it leads to,
and that file is not in the document.

### `documentOf`

```zig
pub fn documentOf(arena: std.mem.Allocator, loaded: project.Project) std.mem.Allocator.Error!ir.Document
```

The document of what `loaded` read, not linked.

### `combine`

```zig
pub fn combine(arena: std.mem.Allocator, documents: []const ir.Document) std.mem.Allocator.Error!ir.Document
```

The files of every one of `documents` in one document that is not linked. A file that
several of them hold is taken from the first, except that it is documented when any of
them documents it.

### `resolve`

```zig
pub fn resolve(arena: std.mem.Allocator, io: std.Io, document: ir.Document, references: []const project.Module, external: []const []const u8) std.mem.Allocator.Error!link.Result
```

Links `document`. A reference that goes through an import into one of [`references`](#projectreferences) is
followed into the sources of that module, which are read from disk as they are reached.
What was reached comes first in the linked document and holds only the symbols that a
reference names or reaches into. A mention of one of [`external`](#optionsexternal) is no problem.

### `describe`

```zig
pub fn describe(arena: std.mem.Allocator, problem: link.Problem) std.mem.Allocator.Error![]const u8
```

One line saying what `problem` is, for the person who wrote the documentation.

### Verified behaviour

- combined documents hold each file once

## `src/main.zig`

The `docir` program: the commands of `docir.cli` given the arguments of the process.

### `main`

```zig
pub fn main(init: std.process.Init) !void
```

Runs the command the arguments ask for and exits with the code it answered.
