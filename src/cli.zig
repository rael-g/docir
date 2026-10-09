//! The stages as the commands of a program.
//!
//! `read` turns sources into a document, `link` resolves the mentions of one or several
//! documents, and `write` renders a document. Each takes its document from a file or from
//! standard input and gives its result to a file or to standard output, so the three can be
//! joined by pipes or kept apart by the files between them.
//!
//! `parse` turns arguments into a `Command` and `run` carries one out. A `Read` describes
//! its modules by name, and `options` turns those names into what `project.Project.open`
//! takes.

const std = @import("std");
const docir = @import("root.zig");

const Allocator = std.mem.Allocator;

/// What `docir help` can be asked about.
pub const Topic = enum {
    /// Every command.
    all,
    /// `docir read`.
    read,
    /// `docir link`.
    link,
    /// `docir write`.
    write,
    /// `docir query`.
    query,
    /// `docir schema`.
    schema,
};

const usage_read =
    \\  docir read <root> [options]            read sources into a document, from the root
    \\                                         file of a module or from a directory
    \\      --name <name>                      name of the root module (default: its file name)
    \\      --base <dir>                       directory the paths in the document are relative to
    \\      --module <name>=<file>             another module, by its root file
    \\      --import [<module>:]<as>=<name>    let a module import another under a name
    \\      --include [<module>=]<dir>         directory the headers of a module are looked for in
    \\      --reference <name>=<file>          module that is linked to and not documented
    \\      --documented <dir>                 document a directory besides that of the root file
    \\      --excluded <dir>                   do not document a directory, and do not enter it
    \\                                         when the root is a directory
    \\      --excluded-name <name>             do the same to every file and directory of
    \\                                         that name, wherever it is
    \\      --depfile <file>                   write the files that were read, as a make rule
    \\
;

const usage_link =
    \\  docir link [document]... [options]     resolve what the documentation mentions
    \\      --reference <name>=<file>          follow references into the sources of a module
    \\      --external <name>                  a name declared outside the sources
    \\      --strict                           fail when a mention names nothing
    \\
;

const usage_write =
    \\  docir write <format> [document]        render a document as markdown or as text
    \\      --title <text>                     first heading (default: Reference)
    \\      --width <columns>                  where text breaks its lines (default: 80)
    \\      --pages                            markdown as a directory of pages, named by -o,
    \\                                         with an index.md and a toc.yml
    \\      --order <prefix>                   files under this directory, or this file, come
    \\                                         before the others; repeat for what comes next
    \\
;

const usage_query =
    \\  docir query <name> [document...]       print the symbols a name asks for, as text,
    \\                                         or those whose documentation holds the words
    \\                                         when no symbol has the name
    \\      --text                             look in the documentation and not in the names
    \\      --members                          print one line for each member of the symbols
    \\                                         found, and not what they say
    \\  docir query --list [document...]       print the files and namespaces of a document
    \\                                         a document may be a directory, for every
    \\                                         .json file in it, and several are read as one
    \\                                         a directory with no document in it, or a
    \\                                         source file, is read and linked on the spot
    \\                                         with no document the current directory is
    \\                                         taken, and - reads one from standard input
    \\      --excluded-name <name>             leave out of the sources read on the spot every
    \\                                         file and directory of that name
    \\      --full                             print every symbol in full, however many
    \\      --limit-full <count>               print one line a symbol when there are more
    \\                                         than this many (default: 5)
    \\      --json                             print them as JSON instead
    \\      --width <columns>                  where text breaks its lines (default: 80)
    \\
;

const usage_schema =
    \\  docir schema                           print the JSON Schema of a document
    \\
;

const usage_common =
    \\  -o, --output <file>                    write there instead of standard output
    \\  -h, --help                             print this
    \\
    \\A document that is not given is read from standard input. Where --import and --include
    \\name no module, they are about the root one. An option takes its value as the next
    \\argument or after an `=`, and `--` ends the options.
    \\
;

/// What `docir help` prints: every command and its options.
pub const usage = "usage: docir <command> [options]\n\n" ++ usage_read ++ "\n" ++ usage_link ++ "\n" ++ usage_write ++ "\n" ++
    usage_query ++ "\n" ++ usage_schema ++ "\n" ++
    "  docir help [command]                   print this, or the options of one command\n" ++
    "  docir version                          print the version\n\n" ++ usage_common;

/// What `docir help` prints about `topic`.
pub fn usageOf(topic: Topic) []const u8 {
    return switch (topic) {
        .all => usage,
        .read => "usage:\n" ++ usage_read ++ "\n" ++ usage_common,
        .link => "usage:\n" ++ usage_link ++ "\n" ++ usage_common,
        .write => "usage:\n" ++ usage_write ++ "\n" ++ usage_common,
        .query => "usage:\n" ++ usage_query ++ "\n" ++ usage_common,
        .schema => "usage:\n" ++ usage_schema ++ "\n" ++ usage_common,
    };
}

/// A name and what it was given, as in `--module name=file`.
pub const Named = struct {
    /// What stands before the `=`.
    name: []const u8,
    /// What stands after it.
    value: []const u8,
};

/// One `--import`: `module` may import `target` by writing `name`.
pub const Import = struct {
    /// Name of the importing module. Empty for the root one.
    module: []const u8,
    /// The name as an `@import` writes it.
    name: []const u8,
    /// Name of the module that is imported.
    target: []const u8,
};

/// The arguments of `docir read`.
pub const Read = struct {
    /// Path of the root file of the module that is documented, or of a directory whose
    /// files are.
    root: []const u8,
    /// Name of that module. Empty to take it from the name of `root`.
    name: []const u8 = "",
    /// Directory that paths in the document are relative to.
    base: []const u8 = "",
    /// Every other module with its root file.
    modules: []const Named = &.{},
    /// Which module may import which.
    imports: []const Import = &.{},
    /// Include directories, each under the name of its module, empty for the root one.
    includes: []const Named = &.{},
    /// The reference-only modules with their root files.
    references: []const Named = &.{},
    /// Directories documented besides that of `root`.
    documented: []const []const u8 = &.{},
    /// Directories that are not documented.
    excluded: []const []const u8 = &.{},
    /// Names of files and directories that are not documented, wherever they are.
    excluded_names: []const []const u8 = &.{},
    /// Where the list of the files read goes, as the rule of a makefile, for a build
    /// system to know when to read again. Null to write none.
    depfile: ?[]const u8 = null,
    /// Where the document goes. Null for standard output.
    output: ?[]const u8 = null,
};

/// The arguments of `docir link`.
pub const Link = struct {
    /// The documents to link as one. Empty to read one from standard input.
    inputs: []const []const u8 = &.{},
    /// The reference-only modules with their root files.
    references: []const Named = &.{},
    /// Names declared outside the sources, which a mention may use.
    external: []const []const u8 = &.{},
    /// Whether a mention that names nothing is a failure.
    strict: bool = false,
    /// Where the linked document goes. Null for standard output.
    output: ?[]const u8 = null,
};

/// What `docir write` renders a document as.
pub const Format = enum {
    /// One Markdown file.
    markdown,
    /// Plain text for a terminal.
    text,
};

/// The arguments of `docir write`.
pub const Write = struct {
    /// What the document is rendered as.
    format: Format = .markdown,
    /// The document to render. Null to read it from standard input.
    input: ?[]const u8 = null,
    /// First heading of what is written.
    title: []const u8 = "Reference",
    /// The column text is broken before.
    width: usize = 80,
    /// Whether Markdown is written as a directory of pages, which `output` then names.
    pages: bool = false,
    /// Directories and files of the document, each coming before the next and all of them
    /// before the files under none.
    order: []const []const u8 = &.{},
    /// Where the text goes. Null for standard output.
    output: ?[]const u8 = null,
};

/// The arguments of `docir query`.
pub const Query = struct {
    /// The name asked for.
    name: []const u8,
    /// What to look in: documents, directories of them, source files and directories of
    /// sources, and "-" for a document on standard input. None for the current directory.
    inputs: []const []const u8 = &.{},
    /// Names of files and directories left out of the sources that are read on the spot.
    excluded_names: []const []const u8 = &.{},
    /// Whether the symbols found are printed as JSON.
    json: bool = false,
    /// Whether the words are looked for in the documentation without trying the names.
    text: bool = false,
    /// Whether the members of the symbols found are printed, a line each, and nothing else.
    members: bool = false,
    /// Whether the files and namespaces of the document are printed, with no name asked.
    list: bool = false,
    /// How many symbols are still printed in full. Above it each gets one line. Null to
    /// print all of them in full.
    limit_full: ?usize = 5,
    /// The column text is broken before.
    width: usize = 80,
    /// Where the answer goes. Null for standard output.
    output: ?[]const u8 = null,
};

/// What the program was asked to do.
pub const Command = union(enum) {
    /// Print what `usageOf` says of a topic.
    help: Topic,
    /// Print the version.
    version,
    /// Read sources into a document.
    read: Read,
    /// Link documents.
    link: Link,
    /// Render a document.
    write: Write,
    /// Print the symbols a name asks for.
    query: Query,
    /// Print the JSON Schema of a document, to the file named or to standard output.
    schema: ?[]const u8,
};

/// Turns the arguments after the program name into a `Command`. An option takes its value
/// as the next argument or after an `=`, an argument that does not open with a dash is
/// positional wherever it stands, and so is every argument after `--`. `--help` or `-h`
/// after a command asks for the help of that command. Fails with `error.Invalid`, after
/// setting `message` to what is wrong, when the arguments cannot be followed.
pub fn parse(arena: Allocator, args: []const [:0]const u8, message: *[]const u8) error{ Invalid, OutOfMemory }!Command {
    if (args.len == 0) return .{ .help = .all };
    const name = args[0];
    var arguments: Arguments = .{ .arena = arena, .rest = args[1..], .message = message };
    if (is(name, "--version") or is(name, "version")) return .version;
    if (is(name, "help") or is(name, "--help") or is(name, "-h")) {
        const asked = if (args.len > 1) args[1] else return .{ .help = .all };
        const topic = std.meta.stringToEnum(Topic, asked) orelse return arguments.invalid("there is no command `{s}`", .{asked});
        return .{ .help = topic };
    }
    const topic = std.meta.stringToEnum(Topic, name) orelse return arguments.invalid("there is no command `{s}`", .{name});
    arguments.command = name;
    const command = arguments.dispatch(topic) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Invalid => return if (arguments.help) .{ .help = topic } else error.Invalid,
    };
    return if (arguments.help) .{ .help = topic } else command;
}

fn is(text: []const u8, flag: []const u8) bool {
    return std.mem.eql(u8, text, flag);
}

const Arguments = struct {
    arena: Allocator,
    rest: []const [:0]const u8,
    message: *[]const u8,
    command: []const u8 = "",
    positional: std.ArrayList([]const u8) = .empty,
    attached: ?[]const u8 = null,
    literal: bool = false,
    help: bool = false,

    const Failure = error{ Invalid, OutOfMemory };

    fn invalid(self: *Arguments, comptime format: []const u8, values: anytype) Failure {
        self.message.* = try std.fmt.allocPrint(self.arena, format, values);
        return error.Invalid;
    }

    fn dispatch(self: *Arguments, topic: Topic) Failure!Command {
        return switch (topic) {
            .all => self.invalid("there is no command `{s}`", .{self.command}),
            .read => .{ .read = try self.read() },
            .link => .{ .link = try self.link() },
            .write => .{ .write = try self.write() },
            .query => .{ .query = try self.query() },
            .schema => .{ .schema = try self.schema() },
        };
    }

    fn option(self: *Arguments) Failure!?[]const u8 {
        if (self.attached) |unused| return self.invalid("an option of {s} was given `{s}` and takes no value", .{ self.command, unused });
        while (self.rest.len != 0) {
            const argument: []const u8 = self.rest[0];
            self.rest = self.rest[1..];
            if (self.literal or argument.len < 2 or argument[0] != '-') {
                try self.positional.append(self.arena, argument);
            } else if (is(argument, "--")) {
                self.literal = true;
            } else if (is(argument, "--help") or is(argument, "-h")) {
                self.help = true;
            } else if (std.mem.startsWith(u8, argument, "--")) {
                const equals = std.mem.indexOfScalar(u8, argument, '=') orelse return argument;
                self.attached = argument[equals + 1 ..];
                return argument[0..equals];
            } else return argument;
        }
        return null;
    }

    fn unknown(self: *Arguments, flag: []const u8) Failure {
        return self.invalid("{s} has no option `{s}`", .{ self.command, flag });
    }

    fn value(self: *Arguments, flag: []const u8) Failure![]const u8 {
        if (self.attached) |given| {
            self.attached = null;
            return given;
        }
        if (self.rest.len == 0) return self.invalid("{s} needs a value", .{flag});
        defer self.rest = self.rest[1..];
        return self.rest[0];
    }

    fn named(self: *Arguments, flag: []const u8) Failure!Named {
        const text = try self.value(flag);
        const equals = std.mem.indexOfScalar(u8, text, '=') orelse return self.invalid("{s} takes <name>=<value>, not `{s}`", .{ flag, text });
        if (equals == 0 or equals + 1 == text.len) return self.invalid("{s} takes <name>=<value>, not `{s}`", .{ flag, text });
        return .{ .name = text[0..equals], .value = text[equals + 1 ..] };
    }

    fn columns(self: *Arguments, flag: []const u8) Failure!usize {
        const written = try self.value(flag);
        return std.fmt.parseInt(usize, written, 10) catch self.invalid("{s} takes a number, not `{s}`", .{ flag, written });
    }

    fn atMost(self: *Arguments, count: usize, what: []const u8) Failure!void {
        if (self.positional.items.len > count) return self.invalid("{s} takes {s}, and was given `{s}` as well", .{ self.command, what, self.positional.items[count] });
    }

    fn read(self: *Arguments) Failure!Read {
        var command: Read = .{ .root = "" };
        var modules: std.ArrayList(Named) = .empty;
        var imports: std.ArrayList(Import) = .empty;
        var includes: std.ArrayList(Named) = .empty;
        var references: std.ArrayList(Named) = .empty;
        var documented: std.ArrayList([]const u8) = .empty;
        var excluded: std.ArrayList([]const u8) = .empty;
        var excluded_names: std.ArrayList([]const u8) = .empty;
        while (try self.option()) |flag| {
            if (is(flag, "--name")) {
                command.name = try self.value(flag);
            } else if (is(flag, "--base")) {
                command.base = try self.value(flag);
            } else if (is(flag, "--module")) {
                try modules.append(self.arena, try self.named(flag));
            } else if (is(flag, "--reference")) {
                try references.append(self.arena, try self.named(flag));
            } else if (is(flag, "--import")) {
                const pair = try self.named(flag);
                const colon = std.mem.indexOfScalar(u8, pair.name, ':');
                try imports.append(self.arena, .{
                    .module = if (colon) |at| pair.name[0..at] else "",
                    .name = if (colon) |at| pair.name[at + 1 ..] else pair.name,
                    .target = pair.value,
                });
            } else if (is(flag, "--include")) {
                const text = try self.value(flag);
                const equals = std.mem.indexOfScalar(u8, text, '=');
                try includes.append(self.arena, .{
                    .name = if (equals) |at| text[0..at] else "",
                    .value = if (equals) |at| text[at + 1 ..] else text,
                });
            } else if (is(flag, "--documented")) {
                try documented.append(self.arena, try self.value(flag));
            } else if (is(flag, "--excluded")) {
                try excluded.append(self.arena, try self.value(flag));
            } else if (is(flag, "--excluded-name")) {
                try excluded_names.append(self.arena, try self.value(flag));
            } else if (is(flag, "--depfile")) {
                command.depfile = try self.value(flag);
            } else if (is(flag, "-o") or is(flag, "--output")) {
                command.output = try self.value(flag);
            } else return self.unknown(flag);
        }
        try self.atMost(1, "one root");
        if (self.positional.items.len == 0) return self.invalid("read needs the root file of a module or a directory", .{});
        command.root = self.positional.items[0];
        command.modules = try modules.toOwnedSlice(self.arena);
        command.imports = try imports.toOwnedSlice(self.arena);
        command.includes = try includes.toOwnedSlice(self.arena);
        command.references = try references.toOwnedSlice(self.arena);
        command.documented = try documented.toOwnedSlice(self.arena);
        command.excluded = try excluded.toOwnedSlice(self.arena);
        command.excluded_names = try excluded_names.toOwnedSlice(self.arena);
        return command;
    }

    fn link(self: *Arguments) Failure!Link {
        var command: Link = .{};
        var references: std.ArrayList(Named) = .empty;
        var external: std.ArrayList([]const u8) = .empty;
        while (try self.option()) |flag| {
            if (is(flag, "--external")) {
                try external.append(self.arena, try self.value(flag));
            } else if (is(flag, "--strict")) {
                command.strict = true;
            } else if (is(flag, "--reference")) {
                try references.append(self.arena, try self.named(flag));
            } else if (is(flag, "-o") or is(flag, "--output")) {
                command.output = try self.value(flag);
            } else return self.unknown(flag);
        }
        command.inputs = self.positional.items;
        command.external = try external.toOwnedSlice(self.arena);
        command.references = try references.toOwnedSlice(self.arena);
        return command;
    }

    fn write(self: *Arguments) Failure!Write {
        var command: Write = .{};
        var order: std.ArrayList([]const u8) = .empty;
        while (try self.option()) |flag| {
            if (is(flag, "--title")) {
                command.title = try self.value(flag);
            } else if (is(flag, "--width")) {
                command.width = try self.columns(flag);
            } else if (is(flag, "--pages")) {
                command.pages = true;
            } else if (is(flag, "--order")) {
                try order.append(self.arena, try self.value(flag));
            } else if (is(flag, "-o") or is(flag, "--output")) {
                command.output = try self.value(flag);
            } else return self.unknown(flag);
        }
        command.order = try order.toOwnedSlice(self.arena);
        try self.atMost(2, "a format and one document");
        if (self.positional.items.len == 0) return self.invalid("write needs a format: markdown or text", .{});
        const format = self.positional.items[0];
        if (is(format, "markdown") or is(format, "md")) {
            command.format = .markdown;
        } else if (is(format, "text")) {
            command.format = .text;
        } else return self.invalid("write has no format `{s}`: there are markdown and text", .{format});
        if (self.positional.items.len == 2) command.input = self.positional.items[1];
        if (command.pages and command.format != .markdown) return self.invalid("--pages is for markdown", .{});
        if (command.pages and command.output == null) return self.invalid("--pages needs -o with the directory the pages go to", .{});
        return command;
    }

    fn query(self: *Arguments) Failure!Query {
        var command: Query = .{ .name = "" };
        var excluded_names: std.ArrayList([]const u8) = .empty;
        while (try self.option()) |flag| {
            if (is(flag, "--json")) {
                command.json = true;
            } else if (is(flag, "--text")) {
                command.text = true;
            } else if (is(flag, "--excluded-name")) {
                try excluded_names.append(self.arena, try self.value(flag));
            } else if (is(flag, "--members")) {
                command.members = true;
            } else if (is(flag, "--list")) {
                command.list = true;
            } else if (is(flag, "--full")) {
                command.limit_full = null;
            } else if (is(flag, "--limit-full")) {
                command.limit_full = try self.columns(flag);
            } else if (is(flag, "--width")) {
                command.width = try self.columns(flag);
            } else if (is(flag, "-o") or is(flag, "--output")) {
                command.output = try self.value(flag);
            } else return self.unknown(flag);
        }
        command.excluded_names = try excluded_names.toOwnedSlice(self.arena);
        if (command.list) {
            if (command.text or command.members) return self.invalid("--list asks for no name, so it goes with neither --text nor --members", .{});
            command.inputs = self.positional.items;
            return command;
        }
        if (command.text and command.members) return self.invalid("--members lists what symbols hold, and --text finds none by name", .{});
        if (self.positional.items.len == 0) return self.invalid("query needs the name to look for", .{});
        command.name = self.positional.items[0];
        command.inputs = self.positional.items[1..];
        return command;
    }

    fn schema(self: *Arguments) Failure!?[]const u8 {
        var output: ?[]const u8 = null;
        while (try self.option()) |flag| {
            if (is(flag, "-o") or is(flag, "--output")) {
                output = try self.value(flag);
            } else return self.unknown(flag);
        }
        try self.atMost(0, "no argument");
        return output;
    }
};

/// The modules `command` describes as `project.Project.open` takes them: the root one, then
/// each of `Read.modules`, then each of `Read.references`. A reference-only module can be
/// imported by its own name from every module that gives that name to no other. Fails with
/// `error.Invalid`, after setting `message`, when a module is named that was not declared.
pub fn options(arena: Allocator, command: Read, message: *[]const u8) error{ Invalid, OutOfMemory }!docir.project.Options {
    const count = 1 + command.modules.len + command.references.len;
    const names = try arena.alloc([]const u8, count);
    const modules = try arena.alloc(docir.project.Module, count);
    names[0] = if (command.name.len != 0) command.name else std.fs.path.stem(command.root);
    modules[0] = .{ .name = names[0], .path = command.root };
    for (command.modules, 1..) |module, index| {
        names[index] = module.name;
        modules[index] = .{ .name = module.name, .path = module.value };
    }
    for (command.references, 1 + command.modules.len..) |module, index| {
        names[index] = module.name;
        modules[index] = .{ .name = module.name, .path = module.value, .reference_only = true };
    }

    for (modules, 0..) |*module, index| {
        var imports: std.ArrayList(docir.project.ModuleImport) = .empty;
        for (command.imports) |import| {
            if (try position(arena, names, import.module, message) != index) continue;
            try imports.append(arena, .{ .name = import.name, .module = try position(arena, names, import.target, message) });
        }
        for (command.references, 1 + command.modules.len..) |reference, target| {
            const taken = for (imports.items) |import| {
                if (std.mem.eql(u8, import.name, reference.name)) break true;
            } else false;
            if (!taken) try imports.append(arena, .{ .name = reference.name, .module = target });
        }
        var include_dirs: std.ArrayList([]const u8) = .empty;
        for (command.includes) |include| {
            if (try position(arena, names, include.name, message) == index) try include_dirs.append(arena, include.value);
        }
        module.imports = try imports.toOwnedSlice(arena);
        module.include_dirs = try include_dirs.toOwnedSlice(arena);
    }

    return .{
        .modules = modules,
        .base = command.base,
        .documented_dirs = command.documented,
        .excluded_dirs = command.excluded,
        .excluded_names = command.excluded_names,
    };
}

fn position(arena: Allocator, names: []const []const u8, name: []const u8, message: *[]const u8) error{ Invalid, OutOfMemory }!usize {
    if (name.len == 0) return 0;
    for (names, 0..) |known, index| {
        if (std.mem.eql(u8, known, name)) return index;
    }
    message.* = try std.fmt.allocPrint(arena, "no module is named `{s}`", .{name});
    return error.Invalid;
}

fn referenceModules(arena: Allocator, references: []const Named) Allocator.Error![]const docir.project.Module {
    const modules = try arena.alloc(docir.project.Module, references.len);
    for (modules, references) |*module, reference| module.* = .{ .name = reference.name, .path = reference.value, .reference_only = true };
    return modules;
}

/// Carries out the command that `args`, the arguments after the program name, ask for, and
/// returns the exit code of the program: 0 when it was done, 1 when it could not be, and 2
/// when the arguments name no command. What went wrong is said on standard error.
pub fn run(arena: Allocator, io: std.Io, args: []const [:0]const u8) !u8 {
    var message: []const u8 = "";
    const command = parse(arena, args, &message) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Invalid => {
            const known = args.len != 0 and std.meta.stringToEnum(Topic, args[0]) != null and !is(args[0], "all");
            try complain(arena, io, "docir: {s}\ntry `docir help{s}{s}`\n", .{ message, if (known) " " else "", if (known) args[0] else "" });
            return 2;
        },
    };
    switch (command) {
        .help => |topic| {
            try emit(io, null, usageOf(topic));
            return 0;
        },
        .version => {
            try emit(io, null, "docir " ++ @import("build_options").version ++ "\n");
            return 0;
        },
        .read => |read| {
            const described = options(arena, read, &message) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Invalid => {
                    try complain(arena, io, "docir: {s}\n", .{message});
                    return 2;
                },
            };
            const loaded = docir.project.Project.open(arena, io, described) catch |err| {
                try complain(arena, io, "docir: cannot read {s}: {t}\n", .{ read.root, err });
                return 1;
            };
            try emitDocument(arena, io, read.output, try docir.documentOf(arena, loaded));
            if (read.depfile) |path| {
                var rule: std.Io.Writer.Allocating = .init(arena);
                try escaped(&rule.writer, read.output orelse "document");
                try rule.writer.writeByte(':');
                var inputs = loaded.seen.keyIterator();
                while (inputs.next()) |input| {
                    try rule.writer.writeByte(' ');
                    try escaped(&rule.writer, input.*);
                }
                try rule.writer.writeByte('\n');
                try emit(io, path, rule.written());
            }
            return 0;
        },
        .link => |link| {
            var documents: std.ArrayList(docir.ir.Document) = .empty;
            if (link.inputs.len == 0) {
                try documents.append(arena, try take(arena, io, null) orelse return 1);
            }
            for (link.inputs) |input| {
                try documents.append(arena, try take(arena, io, input) orelse return 1);
            }
            const combined = try docir.combine(arena, documents.items);
            const result = try docir.resolve(arena, io, combined, try referenceModules(arena, link.references), link.external);
            const severity = if (link.strict) "error" else "warning";
            for (result.problems) |problem| {
                try complain(arena, io, "{s}: {s}\n", .{ severity, try docir.describe(arena, problem) });
            }
            if (link.strict and result.problems.len != 0) return 1;
            try emitDocument(arena, io, link.output, result.document);
            return 0;
        },
        .write => |write| {
            const document = try docir.ordered(arena, try take(arena, io, write.input) orelse return 1, write.order);
            if (write.pages) {
                for (try docir.markdown.writePages(arena, write.title, document)) |page| {
                    try emit(io, try std.fs.path.join(arena, &.{ write.output.?, page.path }), page.text);
                }
                return 0;
            }
            var text: std.Io.Writer.Allocating = .init(arena);
            switch (write.format) {
                .markdown => try docir.markdown.write(arena, &text.writer, write.title, document),
                .text => try docir.text.write(arena, &text.writer, write.title, document, .{ .width = write.width }),
            }
            try emit(io, write.output, text.written());
            return 0;
        },
        .schema => |output| {
            var text: std.Io.Writer.Allocating = .init(arena);
            try docir.schema.write(&text.writer);
            try emit(io, output, text.written());
            return 0;
        },
        .query => |query| {
            const document = try takeAll(arena, io, query.inputs, query.excluded_names) orelse return 1;
            var text: std.Io.Writer.Allocating = .init(arena);
            if (query.list) {
                const roots = try docir.query.roots(arena, document);
                if (query.json) {
                    try std.json.Stringify.value(roots, .{ .whitespace = .indent_2 }, &text.writer);
                    try text.writer.writeByte('\n');
                } else for (roots) |root| try docir.text.writeLine(arena, &text.writer, root, .{ .width = query.width });
                try emit(io, query.output, text.written());
                return 0;
            }
            const found: []const docir.ir.Symbol = if (query.text) &.{} else try docir.query.find(arena, document, query.name);
            if (query.members and found.len != 0 and !query.json) {
                for (found, 0..) |symbol, index| {
                    if (index != 0) try text.writer.writeByte('\n');
                    try docir.text.writeMembers(arena, &text.writer, symbol, .{ .width = query.width });
                }
                try emit(io, query.output, text.written());
                return 0;
            }
            if (found.len == 0) {
                const hits = try docir.query.search(arena, document, query.name);
                if (hits.len == 0) {
                    try complain(arena, io, "docir: nothing is named `{s}` and no documentation says it\n", .{query.name});
                    return 1;
                }
                if (query.json) {
                    try std.json.Stringify.value(hits, .{ .whitespace = .indent_2 }, &text.writer);
                    try text.writer.writeByte('\n');
                } else for (hits, 0..) |hit, index| {
                    if (index != 0) try text.writer.writeByte('\n');
                    try docir.text.writeHit(arena, &text.writer, hit.symbol, hit.paragraph, .{ .width = query.width });
                }
                try emit(io, query.output, text.written());
                return 0;
            }
            if (query.json) {
                try std.json.Stringify.value(found, .{ .whitespace = .indent_2 }, &text.writer);
                try text.writer.writeByte('\n');
            } else for (found, 0..) |symbol, index| {
                const brief = if (query.limit_full) |limit| found.len > limit else false;
                if (brief) {
                    try docir.text.writeLine(arena, &text.writer, symbol, .{ .width = query.width });
                    continue;
                }
                if (index != 0) try text.writer.writeByte('\n');
                try docir.text.writeSymbol(arena, &text.writer, symbol, .{ .width = query.width });
            }
            try emit(io, query.output, text.written());
            return 0;
        },
    }
}

fn escaped(writer: *std.Io.Writer, path: []const u8) std.Io.Writer.Error!void {
    for (path) |ch| {
        if (ch == ' ' or ch == '#') try writer.writeByte('\\');
        if (ch == '$') try writer.writeByte('$');
        try writer.writeByte(ch);
    }
}

fn take(arena: Allocator, io: std.Io, path: ?[]const u8) !?docir.ir.Document {
    const shown = path orelse "standard input";
    const bytes = if (path) |file|
        std.Io.Dir.cwd().readFileAlloc(io, file, arena, .unlimited) catch |err| {
            try complain(arena, io, "docir: cannot read {s}: {t}\n", .{ shown, err });
            return null;
        }
    else bytes: {
        var buffer: [4096]u8 = undefined;
        var reader = std.Io.File.stdin().reader(io, &buffer);
        break :bytes try reader.interface.allocRemaining(arena, .unlimited);
    };
    return docir.ir.readJson(arena, bytes) catch |err| {
        try complain(arena, io, "docir: {s} is not a document this version reads: {t}\n", .{ shown, err });
        return null;
    };
}

fn takeAll(arena: Allocator, io: std.Io, inputs: []const []const u8, excluded_names: []const []const u8) !?docir.ir.Document {
    var documents: std.ArrayList(docir.ir.Document) = .empty;
    const given: []const []const u8 = if (inputs.len == 0) &.{"."} else inputs;
    for (given) |input| {
        if (is(input, "-")) {
            try documents.append(arena, try take(arena, io, null) orelse return null);
            continue;
        }
        var dir = std.Io.Dir.cwd().openDir(io, input, .{ .iterate = true }) catch {
            if (std.mem.endsWith(u8, input, ".json")) {
                try documents.append(arena, try take(arena, io, input) orelse return null);
            } else try documents.append(arena, try sources(arena, io, input, excluded_names) orelse return null);
            continue;
        };
        defer dir.close(io);
        var inside: std.ArrayList([]const u8) = .empty;
        var entries = dir.iterate();
        while (try entries.next(io)) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".json")) continue;
            try inside.append(arena, try std.fs.path.join(arena, &.{ input, entry.name }));
        }
        std.mem.sort([]const u8, inside.items, {}, struct {
            fn before(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.before);
        var held: usize = 0;
        for (inside.items) |path| {
            const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited) catch continue;
            try documents.append(arena, docir.ir.readJson(arena, bytes) catch continue);
            held += 1;
        }
        if (held == 0) try documents.append(arena, try sources(arena, io, input, excluded_names) orelse return null);
    }
    if (documents.items.len == 1) return documents.items[0];
    return try docir.combine(arena, documents.items);
}

fn sources(arena: Allocator, io: std.Io, root: []const u8, excluded_names: []const []const u8) !?docir.ir.Document {
    const here = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", arena);
    const unlinked = docir.read(arena, io, .{
        .modules = &.{.{ .name = std.fs.path.stem(root), .path = try std.fs.path.resolve(arena, &.{ here, root }) }},
        .base = here,
        .excluded_names = excluded_names,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try complain(arena, io, "docir: cannot read {s}: {t}\n", .{ root, err });
            return null;
        },
    };
    return (try docir.resolve(arena, io, unlinked, &.{}, &.{})).document;
}

fn emitDocument(arena: Allocator, io: std.Io, path: ?[]const u8, document: docir.ir.Document) !void {
    var json: std.Io.Writer.Allocating = .init(arena);
    try docir.ir.writeJson(&json.writer, document);
    try emit(io, path, json.written());
}

fn emit(io: std.Io, path: ?[]const u8, data: []const u8) !void {
    if (path) |file| {
        const cwd = std.Io.Dir.cwd();
        if (std.fs.path.dirname(file)) |parent| try cwd.createDirPath(io, parent);
        try cwd.writeFile(io, .{ .sub_path = file, .data = data });
        return;
    }
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writerStreaming(io, &buffer);
    writer.interface.writeAll(data) catch |err| return if (closedByReader(writer)) {} else err;
    writer.interface.flush() catch |err| return if (closedByReader(writer)) {} else err;
}

fn closedByReader(writer: std.Io.File.Writer) bool {
    return if (writer.err) |cause| cause == error.BrokenPipe else false;
}

fn complain(arena: Allocator, io: std.Io, comptime format: []const u8, values: anytype) !void {
    var buffer: [512]u8 = undefined;
    var writer = std.Io.File.stderr().writerStreaming(io, &buffer);
    try writer.interface.writeAll(try std.fmt.allocPrint(arena, format, values));
    try writer.interface.flush();
}

test "read arguments become the modules of a project" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var message: []const u8 = "";
    const command = try parse(arena.allocator(), &.{
        "read",         "src/main.zig",         "--name",      "plugin",
        "--module",     "heap=common/heap.zig", "--import",    "heap=heap",
        "--import",     "heap:base=plugin",     "--include",   "contracts",
        "--include",    "heap=common/include",  "--reference", "std=lib/std/std.zig",
        "--documented", "contracts",            "-o",          "out.json",
    }, &message);
    try std.testing.expectEqualStrings("out.json", command.read.output.?);

    const described = try options(arena.allocator(), command.read, &message);
    try std.testing.expectEqual(3, described.modules.len);
    const plugin = described.modules[0];
    try std.testing.expectEqualStrings("plugin", plugin.name);
    try std.testing.expectEqualStrings("heap", plugin.imports[0].name);
    try std.testing.expectEqual(1, plugin.imports[0].module);
    try std.testing.expectEqualStrings("std", plugin.imports[1].name);
    try std.testing.expectEqual(2, plugin.imports[1].module);
    try std.testing.expectEqualStrings("contracts", plugin.include_dirs[0]);
    const heap = described.modules[1];
    try std.testing.expectEqualStrings("base", heap.imports[0].name);
    try std.testing.expectEqual(0, heap.imports[0].module);
    try std.testing.expectEqualStrings("common/include", heap.include_dirs[0]);
    try std.testing.expect(described.modules[2].reference_only);
    try std.testing.expectEqualStrings("contracts", described.documented_dirs[0]);
}

test "the root module is named after its file when no name is given" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var message: []const u8 = "";
    const command = try parse(arena.allocator(), &.{ "read", "src/scheduler.zig" }, &message);
    const described = try options(arena.allocator(), command.read, &message);
    try std.testing.expectEqualStrings("scheduler", described.modules[0].name);
}

test "arguments that cannot be followed say why" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var message: []const u8 = "";
    try std.testing.expectError(error.Invalid, parse(arena.allocator(), &.{"render"}, &message));
    try std.testing.expectEqualStrings("there is no command `render`", message);
    try std.testing.expectError(error.Invalid, parse(arena.allocator(), &.{"read"}, &message));
    try std.testing.expectError(error.Invalid, parse(arena.allocator(), &.{ "read", "a.zig", "--module", "heap" }, &message));
    try std.testing.expectError(error.Invalid, parse(arena.allocator(), &.{ "write", "html" }, &message));
    try std.testing.expectError(error.Invalid, parse(arena.allocator(), &.{ "link", "--fast" }, &message));

    const command = try parse(arena.allocator(), &.{ "read", "a.zig", "--import", "heap=missing" }, &message);
    try std.testing.expectError(error.Invalid, options(arena.allocator(), command.read, &message));
    try std.testing.expectEqualStrings("no module is named `missing`", message);
}

test "link and write take their documents and options" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var message: []const u8 = "";
    const link = (try parse(arena.allocator(), &.{ "link", "a.json", "b.json", "--strict", "--reference", "std=std.zig" }, &message)).link;
    try std.testing.expectEqual(2, link.inputs.len);
    try std.testing.expect(link.strict);
    try std.testing.expectEqualStrings("std", link.references[0].name);

    const write = (try parse(arena.allocator(), &.{ "write", "markdown", "a.json", "--title", "Scheduler", "--order", "src", "--order=include" }, &message)).write;
    try std.testing.expectEqual(2, write.order.len);
    try std.testing.expectEqualStrings("include", write.order[1]);
    try std.testing.expectEqualStrings("a.json", write.input.?);
    try std.testing.expectEqualStrings("Scheduler", write.title);
    try std.testing.expectEqual(Topic.all, (try parse(arena.allocator(), &.{}, &message)).help);
}

test "an option takes its value after an equals sign, and a double dash ends the options" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var message: []const u8 = "";
    const read = (try parse(arena.allocator(), &.{ "read", "--name=plugin", "--module=heap=common/heap.zig", "-o", "out.json", "--", "--odd.zig" }, &message)).read;
    try std.testing.expectEqualStrings("plugin", read.name);
    try std.testing.expectEqualStrings("heap", read.modules[0].name);
    try std.testing.expectEqualStrings("common/heap.zig", read.modules[0].value);
    try std.testing.expectEqualStrings("--odd.zig", read.root);
    try std.testing.expectError(error.Invalid, parse(arena.allocator(), &.{ "link", "--strict=yes" }, &message));
    try std.testing.expectError(error.Invalid, parse(arena.allocator(), &.{ "read", "a.zig", "b.zig" }, &message));
    try std.testing.expectEqualStrings("read takes one root, and was given `b.zig` as well", message);
}

test "help is asked for by name or after a command, and the version by its own word" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var message: []const u8 = "";
    try std.testing.expectEqual(Topic.link, (try parse(arena.allocator(), &.{ "help", "link" }, &message)).help);
    try std.testing.expectEqual(Topic.read, (try parse(arena.allocator(), &.{ "read", "--help" }, &message)).help);
    try std.testing.expectEqual(Topic.write, (try parse(arena.allocator(), &.{ "write", "-h" }, &message)).help);
    try std.testing.expectEqual(Command.version, try parse(arena.allocator(), &.{"--version"}, &message));
    try std.testing.expectError(error.Invalid, parse(arena.allocator(), &.{ "help", "render" }, &message));
    try std.testing.expect(std.mem.indexOf(u8, usageOf(.link), "--strict") != null);
    try std.testing.expect(std.mem.indexOf(u8, usageOf(.link), "--pages") == null);
}

test "query takes a name and any number of documents, or lists with no name" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var message: []const u8 = "";
    const asked = (try parse(arena.allocator(), &.{ "query", "Pool.wait", "a.json", "docs", "--text", "--limit-full", "2" }, &message)).query;
    try std.testing.expectEqualStrings("Pool.wait", asked.name);
    try std.testing.expectEqual(2, asked.inputs.len);
    try std.testing.expect(asked.text);
    try std.testing.expectEqual(2, asked.limit_full.?);
    try std.testing.expectEqual(null, (try parse(arena.allocator(), &.{ "query", "Pool", "--full" }, &message)).query.limit_full);
    const direct = (try parse(arena.allocator(), &.{ "query", "Pool", "--excluded-name", "vendor", "--excluded-name=build.zig" }, &message)).query;
    try std.testing.expectEqual(0, direct.inputs.len);
    try std.testing.expectEqual(2, direct.excluded_names.len);
    try std.testing.expectEqualStrings("build.zig", direct.excluded_names[1]);
    const listed = (try parse(arena.allocator(), &.{ "query", "--list", "docs" }, &message)).query;
    try std.testing.expect(listed.list);
    try std.testing.expectEqual(1, listed.inputs.len);
    try std.testing.expectError(error.Invalid, parse(arena.allocator(), &.{ "query", "--list", "--text" }, &message));
    try std.testing.expectError(error.Invalid, parse(arena.allocator(), &.{ "query", "Pool", "--text", "--members" }, &message));
    try std.testing.expectError(error.Invalid, parse(arena.allocator(), &.{"query"}, &message));
}
