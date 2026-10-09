//! Reads the declarations of a C or C++ file and the documentation written on them.
//!
//! The parser is tree-sitter, with its C grammar or its C++ grammar as `Dialect` says, and
//! this file only turns the tree into the document model. The C++ grammar extends the C one,
//! so one reader serves both. Every declaration is recorded, documented or not: a function,
//! a type, a variable, a macro, and inside a struct, a union or a class each member, with
//! one symbol per name when a line declares several. An `extern "C"` block and a conditional
//! of the preprocessor are transparent: what they hold belongs to the scope around them.
//! The file becomes a symbol of kind `ir.Kind.module` and what it declares becomes its
//! members.
//!
//! The grammar reads the source before the preprocessor runs, so a macro in front of a
//! declaration, the way a library marks what it exports, is not valid to it. When a
//! declaration fails to parse and opens with the name of a macro the same file defines
//! without parameters, that name is put out of the way and the file is parsed again. The
//! same is done for such a name among the parameters of a declaration that fails to parse,
//! and for the names `read` is told other files define, which `outline` finds in a
//! file without reading the rest of it. The signature of the symbol still shows the name,
//! since it is taken from the source as written.
//!
//! The identifier of a symbol is its language, a colon, the path of its file, a `#` and its
//! name qualified by what is around it: `c:pool.h#pool.wait`, with a dot between the parts
//! in C, and `cpp:pool.hpp#ke::Pool::wait(int)`, with two colons in C++, where a function
//! also carries the types of its parameters, since the language lets a name be declared
//! once per list of them. A struct or an enum that
//! is defined through a typedef is one symbol under the name of the typedef, and so is one
//! that a typedef of the same name announces before it is defined. A struct or union
//! without a name, inside another, is named after what it is. The macro that guards a
//! header against a second inclusion is not a symbol. What the grammar reads as a declaration
//! without a name is not a symbol either, and what it holds belongs to the scope around it,
//! as the values of an enum without a name do.
//!
//! In C++, a namespace is a symbol of kind `ir.Kind.namespace` with what it holds as its
//! members, a class or struct lists what it derives from, a member carries the visibility
//! its section gives it, and a template carries its parameters. A member function is a
//! function, and so are a constructor, a destructor and an operator, under the name they
//! are written with. A member defined outside its class, as `void Pool::stop() {}`, is a
//! function named after its last part and qualified by the rest, and `join` gives it back to
//! the declaration its class has of it.
//!
//! What a comment means is read by `doxygen_comment`. A comment belongs to the declaration
//! that follows it, or to the one before it when it says so, and a comment that names the
//! file documents the file. The parameters of a function, of a function pointer and of a
//! callback type are taken from the declaration, with name and type, and what a comment
//! says of a parameter is attached to the one it names. A parameter that only a comment
//! names is kept, with no type.

const std = @import("std");
const tree_sitter = @import("tree_sitter");
const grammar = @import("tree_sitter_c");
const ir = @import("ir.zig");
const doxygen_comment = @import("doxygen_comment.zig");

const Allocator = std.mem.Allocator;
const Node = tree_sitter.Node;

/// Which grammar a file is read with. A `.h` file says C by its extension, and `Dialect.detect`
/// tells whether it is C++ all the same. The name of each is the language its files are
/// given and the prefix of their identifiers.
pub const Dialect = enum {
    /// C.
    c,
    /// C++.
    cpp,

    /// The dialect a file with `extension`, dot included, is read with, or null when the
    /// file is neither C nor C++. A `.h` file is taken as C.
    pub fn of(extension: []const u8) ?Dialect {
        for ([_][]const u8{ ".h", ".c" }) |known| {
            if (std.mem.eql(u8, extension, known)) return .c;
        }
        for ([_][]const u8{ ".hpp", ".hh", ".hxx", ".cpp", ".cc", ".cxx" }) |known| {
            if (std.mem.eql(u8, extension, known)) return .cpp;
        }
        return null;
    }

    /// Which grammar a header is read with when its extension does not say, as with `.h`.
    /// It is C++ when the C++ grammar reads in it something C does not have, which is a
    /// namespace, a class, a template, a section of a class or a using declaration, unless the C
    /// grammar makes sense of all of it and the C++ grammar does not. Otherwise it is C.
    /// Fails with
    /// `error.GrammarRejected` when the parser does not take a grammar.
    pub fn detect(source: []const u8) error{GrammarRejected}!Dialect {
        const as_c = try Reading.of(.c, source);
        const hinted = for ([_][]const u8{ "class", "namespace", "template", "using", "::" }) |word| {
            if (std.mem.indexOf(u8, source, word) != null) break true;
        } else false;
        if (!hinted) return .c;
        const as_cpp = try Reading.of(.cpp, source);
        const only_c_is_clean = as_c.mistakes == 0 and as_cpp.mistakes != 0;
        return if (as_cpp.beyond_c and !only_c_is_clean) .cpp else .c;
    }

    const Reading = struct {
        mistakes: usize,
        beyond_c: bool,

        fn of(dialect: Dialect, source: []const u8) error{GrammarRejected}!Reading {
            const parser = tree_sitter.Parser.create();
            defer parser.destroy();
            parser.setLanguage(dialect.grammarOf()) catch return error.GrammarRejected;
            const tree = parser.parseString(source, null) orelse return error.GrammarRejected;
            defer tree.destroy();
            return .{ .mistakes = mistaken(tree.rootNode()), .beyond_c = dialect == .cpp and beyondC(tree.rootNode()) };
        }
    };

    fn grammarOf(self: Dialect) *const tree_sitter.Language {
        return @ptrCast(@alignCast(switch (self) {
            .c => grammar.language(),
            .cpp => tree_sitter_cpp(),
        }));
    }

    fn separator(self: Dialect) []const u8 {
        return switch (self) {
            .c => ".",
            .cpp => "::",
        };
    }
};

extern fn tree_sitter_cpp() callconv(.c) *const anyopaque;

/// What `read` fails with.
pub const Error = Allocator.Error || error{GrammarRejected};

const byte_order_mark = "\xEF\xBB\xBF";
const max_passes = 8;

/// What a C file pulls in and defines, found without reading its declarations.
pub const Outline = struct {
    /// The name of every file it includes, in source order.
    includes: []const []const u8,
    /// The name of every macro it defines without parameters.
    macros: []const []const u8,
};

/// Finds the includes of a file and the macros it defines without parameters. Fails with
/// `error.GrammarRejected` when the parser does not take the grammar.
pub fn outline(arena: Allocator, dialect: Dialect, source: []const u8) Error!Outline {
    const parser = tree_sitter.Parser.create();
    defer parser.destroy();
    parser.setLanguage(dialect.grammarOf()) catch return error.GrammarRejected;
    const tree = parser.parseString(source, null) orelse return error.GrammarRejected;
    defer tree.destroy();

    var includes: std.ArrayList([]const u8) = .empty;
    try includedNames(arena, tree.rootNode(), source, &includes);
    var macros: std.StringHashMapUnmanaged(void) = .empty;
    try defined(arena, tree.rootNode(), source, &macros);
    var names: std.ArrayList([]const u8) = .empty;
    var each = macros.keyIterator();
    while (each.next()) |name| try names.append(arena, try arena.dupe(u8, name.*));
    return .{ .includes = try includes.toOwnedSlice(arena), .macros = try names.toOwnedSlice(arena) };
}

fn includedNames(arena: Allocator, node: Node, source: []const u8, out: *std.ArrayList([]const u8)) Allocator.Error!void {
    var index: u32 = 0;
    while (index < node.namedChildCount()) : (index += 1) {
        const child = node.namedChild(index).?;
        const kind = child.kind();
        if (is(kind, "preproc_include")) {
            const path = child.childByFieldName("path") orelse continue;
            const name = std.mem.trim(u8, text(source, path), "<>\"");
            if (name.len != 0) try out.append(arena, try arena.dupe(u8, name));
        } else if (std.mem.startsWith(u8, kind, "preproc_") or is(kind, "linkage_specification") or is(kind, "declaration_list")) {
            try includedNames(arena, child, source, out);
        }
    }
}

/// Reads one file. `path` becomes the path of the file in the document. The symbol of the
/// file is identified by the name of `dialect`, a colon and that path, and a declaration by
/// that, a `#`, and its name qualified by what is around it. `macros` names the macros without parameters
/// that other files define and this one may use in front of a declaration. What the grammar
/// cannot make sense of is left out, and the declarations around it are still read. Fails
/// with `error.GrammarRejected` when the parser does not take the grammar this package was
/// built with.
pub fn read(arena: Allocator, dialect: Dialect, path: []const u8, source: []const u8, macros: []const []const u8) Error!ir.Unit {
    const parsed = try arena.dupe(u8, source);
    if (std.mem.startsWith(u8, parsed, byte_order_mark)) @memset(parsed[0..byte_order_mark.len], ' ');

    const parser = tree_sitter.Parser.create();
    defer parser.destroy();
    parser.setLanguage(dialect.grammarOf()) catch return error.GrammarRejected;

    var tree = parser.parseString(parsed, null) orelse return error.GrammarRejected;
    defer tree.destroy();
    var known: std.StringHashMapUnmanaged(void) = .empty;
    for (macros) |name| try known.put(arena, name, {});
    try defined(arena, tree.rootNode(), source, &known);
    var cleared: std.ArrayList(Span) = .empty;
    var pass: usize = 0;
    while (pass < max_passes) : (pass += 1) {
        const macros_known = &known;
        const before = cleared.items.len;
        try clear(arena, tree.rootNode(), parsed, macros_known, &cleared);
        if (cleared.items.len == before) break;
        const again = parser.parseString(parsed, null) orelse return error.GrammarRejected;
        tree.destroy();
        tree = again;
    }

    const language = @tagName(dialect);
    var reader: Reader = .{ .arena = arena, .source = source, .path = path, .dialect = dialect, .cleared = cleared.items, .macros = &known };
    var top: Scope = .{};
    try reader.statements(tree.rootNode(), &top, "", false, null);
    try reader.close(&top);
    return .{
        .file = .{ .path = path, .language = language, .imports = try reader.imports.toOwnedSlice(arena) },
        .symbol = .{
            .id = try std.mem.concat(arena, u8, &.{ language, ":", path }),
            .name = std.fs.path.stem(path),
            .qualified_name = path,
            .kind = .module,
            .form = if (std.mem.endsWith(u8, path, ".h")) "header" else "",
            .locations = try arena.dupe(ir.Location, &.{.{ .file = path, .line = 1, .end_line = @intCast(std.mem.count(u8, source, "\n") + 1) }}),
            .doc = .{ .blocks = try reader.intro.toOwnedSlice(arena) },
            .members = try top.symbols.toOwnedSlice(arena),
        },
    };
}

/// Joins every member that a C++ file of `units` defines outside its class to the
/// declaration that class has of it, in whichever of the files it is. The declaration
/// receives the place of the definition, and its documentation when it has none of its own,
/// and the definition leaves its file. A definition whose class is in none of the files
/// stays where it is.
pub fn join(arena: Allocator, units: []ir.Unit) Allocator.Error!void {
    var joiner: Joiner = .{ .arena = arena };
    for (units) |unit| {
        if (std.mem.eql(u8, unit.file.language, "cpp")) try joiner.declared(unit.symbol.members, unit.symbol.id.len);
    }
    for (units) |*unit| {
        if (std.mem.eql(u8, unit.file.language, "cpp")) unit.symbol.members = try joiner.without(unit.symbol.members, unit.symbol.id.len);
    }
    if (joiner.moved.count() == 0) return;
    for (units) |*unit| {
        if (std.mem.eql(u8, unit.file.language, "cpp")) unit.symbol.members = try joiner.completed(unit.symbol.members);
    }
}

const Joiner = struct {
    arena: Allocator,
    exact: std.StringHashMapUnmanaged([]const u8) = .empty,
    named: std.StringHashMapUnmanaged(?[]const u8) = .empty,
    moved: std.StringHashMapUnmanaged(std.ArrayList(ir.Symbol)) = .empty,

    fn isDefinition(symbol: ir.Symbol) bool {
        return symbol.kind == .function and std.mem.eql(u8, symbol.form, "definition");
    }

    fn declared(self: *Joiner, list: []const ir.Symbol, root: usize) Allocator.Error!void {
        for (list) |symbol| {
            if (symbol.kind == .function and !isDefinition(symbol)) {
                try self.exact.put(self.arena, symbol.id[root..], symbol.id);
                const entry = try self.named.getOrPut(self.arena, symbol.qualified_name);
                entry.value_ptr.* = if (entry.found_existing) null else symbol.id;
            }
            try self.declared(symbol.members, root);
        }
    }

    fn without(self: *Joiner, list: []const ir.Symbol, root: usize) Allocator.Error![]const ir.Symbol {
        var out: std.ArrayList(ir.Symbol) = .empty;
        for (list) |original| {
            var symbol = original;
            if (isDefinition(symbol)) {
                const target = self.exact.get(symbol.id[root..]) orelse (self.named.get(symbol.qualified_name) orelse null);
                if (target) |id| {
                    const entry = try self.moved.getOrPut(self.arena, id);
                    if (!entry.found_existing) entry.value_ptr.* = .empty;
                    try entry.value_ptr.append(self.arena, symbol);
                    continue;
                }
            }
            symbol.members = try self.without(symbol.members, root);
            try out.append(self.arena, symbol);
        }
        return out.toOwnedSlice(self.arena);
    }

    fn completed(self: *Joiner, list: []const ir.Symbol) Allocator.Error![]const ir.Symbol {
        const out = try self.arena.dupe(ir.Symbol, list);
        for (out) |*symbol| {
            if (self.moved.get(symbol.id)) |definitions| {
                for (definitions.items) |definition| {
                    symbol.locations = try std.mem.concat(self.arena, ir.Location, &.{ symbol.locations, definition.locations });
                    if (symbol.doc.isEmpty()) symbol.doc = definition.doc;
                    if (symbol.returns.isEmpty()) symbol.returns = definition.returns;
                    const params = try self.arena.dupe(ir.Param, symbol.params);
                    for (params) |*param| {
                        if (!param.doc.isEmpty()) continue;
                        for (definition.params) |other| {
                            if (std.mem.eql(u8, other.name, param.name)) param.doc = other.doc;
                        }
                    }
                    symbol.params = params;
                }
            }
            symbol.members = try self.completed(symbol.members);
        }
        return out;
    }
};

fn defined(arena: Allocator, node: Node, source: []const u8, out: *std.StringHashMapUnmanaged(void)) Allocator.Error!void {
    var index: u32 = 0;
    while (index < node.namedChildCount()) : (index += 1) {
        const child = node.namedChild(index).?;
        const kind = child.kind();
        if (is(kind, "preproc_def")) {
            if (child.childByFieldName("name")) |name| try out.put(arena, text(source, name), {});
        } else if (std.mem.startsWith(u8, kind, "preproc_") or is(kind, "linkage_specification") or is(kind, "declaration_list")) {
            try defined(arena, child, source, out);
        }
    }
}

fn clear(arena: Allocator, node: Node, source: []u8, macros: *const std.StringHashMapUnmanaged(void), cleared: *std.ArrayList(Span)) Allocator.Error!void {
    var index: u32 = 0;
    while (index < node.namedChildCount()) : (index += 1) {
        const child = node.namedChild(index).?;
        if (!child.hasError()) continue;
        const kind = child.kind();
        const before = cleared.items.len;
        if (is(kind, "declaration") or is(kind, "field_declaration") or is(kind, "function_definition") or is(kind, "ERROR")) {
            var at: u32 = 0;
            while (at < child.namedChildCount()) : (at += 1) {
                const part = child.namedChild(at).?;
                if (is(part.kind(), "storage_class_specifier") or is(part.kind(), "type_qualifier")) continue;
                if (!is(part.kind(), "type_identifier") and !is(part.kind(), "identifier")) break;
                if (!macros.contains(source[part.startByte()..part.endByte()])) break;
                @memset(source[part.startByte()..part.endByte()], ' ');
                try cleared.append(arena, .{ .start = part.startByte(), .end = part.endByte() });
                break;
            }
        }
        if (cleared.items.len == before) try clear(arena, child, source, macros, cleared);
        if (cleared.items.len == before and (is(kind, "declaration") or is(kind, "field_declaration") or is(kind, "function_definition"))) {
            _ = try clearAmongParameters(arena, child, source, macros, cleared, false);
        }
    }
}

fn clearAmongParameters(arena: Allocator, node: Node, source: []u8, macros: *const std.StringHashMapUnmanaged(void), cleared: *std.ArrayList(Span), among: bool) Allocator.Error!bool {
    const kind = node.kind();
    if (is(kind, "compound_statement")) return false;
    if (among and (is(kind, "type_identifier") or is(kind, "identifier")) and macros.contains(source[node.startByte()..node.endByte()])) {
        @memset(source[node.startByte()..node.endByte()], ' ');
        try cleared.append(arena, .{ .start = node.startByte(), .end = node.endByte() });
        return true;
    }
    var found = false;
    var index: u32 = 0;
    while (index < node.namedChildCount()) : (index += 1) {
        if (try clearAmongParameters(arena, node.namedChild(index).?, source, macros, cleared, among or is(kind, "parameter_list"))) found = true;
    }
    return found;
}

fn mistaken(node: Node) usize {
    if (node.isMissing()) return 1;
    if (!node.hasError()) return 0;
    var count: usize = if (is(node.kind(), "ERROR")) 1 else 0;
    var index: u32 = 0;
    while (index < node.childCount()) : (index += 1) count += mistaken(node.child(index).?);
    return count;
}

fn beyondC(node: Node) bool {
    const kind = node.kind();
    for ([_][]const u8{ "namespace_definition", "class_specifier", "template_declaration", "access_specifier", "using_declaration", "alias_declaration", "namespace_alias_definition" }) |only| {
        if (is(kind, only)) return true;
    }
    if (is(kind, "compound_statement")) return false;
    var index: u32 = 0;
    while (index < node.namedChildCount()) : (index += 1) {
        if (beyondC(node.namedChild(index).?)) return true;
    }
    return false;
}

fn is(kind: []const u8, name: []const u8) bool {
    return std.mem.eql(u8, kind, name);
}

fn text(source: []const u8, node: Node) []const u8 {
    return source[node.startByte()..node.endByte()];
}

const Span = struct {
    start: u32,
    end: u32,
};

const Pending = struct {
    raw: std.ArrayList(u8) = .empty,
    block: bool = false,
    last_row: u32 = 0,

    fn isEmpty(self: Pending) bool {
        return self.raw.items.len == 0;
    }
};

const Scope = struct {
    symbols: std.ArrayList(ir.Symbol) = .empty,
    leading: Pending = .{},
    trailing: Pending = .{},
    group: usize = 0,
    visibility: ir.Visibility = .public,
    type_params: []const ir.TypeParam = &.{},
};

const Declared = struct {
    name: ?Node = null,
    function: ?Node = null,
};

const Reader = struct {
    arena: Allocator,
    source: []const u8,
    path: []const u8,
    dialect: Dialect = .c,
    cleared: []const Span = &.{},
    macros: ?*const std.StringHashMapUnmanaged(void) = null,
    imports: std.ArrayList(ir.Import) = .empty,
    intro: std.ArrayList(ir.Block) = .empty,

    fn statements(self: *Reader, node: Node, scope: *Scope, prefix: []const u8, in_record: bool, guard: ?[]const u8) Allocator.Error!void {
        var index: u32 = 0;
        while (index < node.namedChildCount()) : (index += 1) {
            const child = node.namedChild(index).?;
            const kind = child.kind();
            if (is(kind, "comment")) {
                try self.comment(child, scope);
            } else if (is(kind, "preproc_include")) {
                try self.close(scope);
                const included = child.childByFieldName("path") orelse continue;
                const name = std.mem.trim(u8, text(self.source, included), "<>\"");
                if (name.len != 0) try self.imports.append(self.arena, .{ .name = name, .kind = .include });
            } else if (is(kind, "preproc_def") or is(kind, "preproc_function_def")) {
                try self.close(scope);
                try self.macro(child, scope, prefix, guard);
            } else if (is(kind, "preproc_ifdef")) {
                const tested = if (child.childByFieldName("name")) |name| text(self.source, name) else null;
                const opens_with_not = std.mem.startsWith(u8, std.mem.trimStart(u8, text(self.source, child), " \t#"), "ifndef");
                try self.statements(child, scope, prefix, in_record, if (opens_with_not) tested else guard);
            } else if (std.mem.startsWith(u8, kind, "preproc_if") or std.mem.startsWith(u8, kind, "preproc_el") or is(kind, "linkage_specification") or is(kind, "declaration_list")) {
                try self.statements(child, scope, prefix, in_record, guard);
            } else if (is(kind, "namespace_definition")) {
                try self.close(scope);
                try self.namespace(child, scope, prefix);
            } else if (is(kind, "template_declaration")) {
                try self.close(scope);
                scope.type_params = if (child.childByFieldName("parameters")) |list| try self.typeParameters(list) else &.{};
                try self.statements(child, scope, prefix, in_record, guard);
                scope.type_params = &.{};
            } else if (is(kind, "access_specifier")) {
                try self.close(scope);
                scope.visibility = visibilityOf(text(self.source, child));
            } else if (is(kind, "alias_declaration")) {
                try self.close(scope);
                try self.alias(child, scope, prefix);
            } else if (is(kind, "type_definition")) {
                try self.close(scope);
                try self.typeDefinition(child, scope, prefix);
            } else if (is(kind, "declaration") or is(kind, "function_definition") or is(kind, "field_declaration")) {
                try self.close(scope);
                try self.declaration(child, scope, prefix, in_record);
            } else if (isRecord(child)) {
                try self.close(scope);
                const body = child.childByFieldName("body") orelse continue;
                const name = child.childByFieldName("name") orelse {
                    if (is(kind, "enum_specifier")) try self.statements(body, scope, prefix, false, null);
                    continue;
                };
                try self.container(child, body, text(self.source, name), text(self.source, child)[0 .. body.startByte() - child.startByte()], child, scope, prefix);
            } else if (is(kind, "enumerator")) {
                try self.close(scope);
                try self.enumerator(child, scope, prefix);
            }
        }
    }

    fn comment(self: *Reader, node: Node, scope: *Scope) Allocator.Error!void {
        const raw = text(self.source, node);
        const shape = doxygen_comment.shape(raw) orelse return;
        const row = node.startPoint().row;
        const target = if (shape.trailing) &scope.trailing else &scope.leading;
        const continues = !target.isEmpty() and !target.block and !shape.block and row == target.last_row + 1;
        if (shape.trailing and !continues) try self.close(scope);
        if (!continues) {
            if (!shape.trailing and !target.isEmpty()) try self.orphan(target);
            target.* = .{ .block = shape.block };
        } else {
            try target.raw.append(self.arena, '\n');
        }
        try target.raw.appendSlice(self.arena, raw);
        target.last_row = node.endPoint().row;
    }

    fn orphan(self: *Reader, pending: *Pending) Allocator.Error!void {
        const parsed = try doxygen_comment.parse(self.arena, pending.raw.items, pending.block);
        if (parsed.is_file) try self.intro.appendSlice(self.arena, parsed.blocks);
        pending.* = .{};
    }

    fn close(self: *Reader, scope: *Scope) Allocator.Error!void {
        if (scope.trailing.isEmpty()) return;
        const parsed = try doxygen_comment.parse(self.arena, scope.trailing.raw.items, scope.trailing.block);
        scope.trailing = .{};
        for (scope.symbols.items[scope.group..]) |*symbol| try self.document(symbol, parsed);
    }

    fn take(self: *Reader, scope: *Scope) Allocator.Error!doxygen_comment.Comment {
        if (scope.leading.isEmpty()) return .{};
        const parsed = try doxygen_comment.parse(self.arena, scope.leading.raw.items, scope.leading.block);
        scope.leading = .{};
        if (!parsed.is_file) return parsed;
        try self.intro.appendSlice(self.arena, parsed.blocks);
        return .{};
    }

    fn document(self: *Reader, symbol: *ir.Symbol, said: doxygen_comment.Comment) Allocator.Error!void {
        if (said.blocks.len != 0) symbol.doc = .{ .blocks = try std.mem.concat(self.arena, ir.Block, &.{ symbol.doc.blocks, said.blocks }) };
        if (!said.returns.isEmpty()) symbol.returns = said.returns;
        if (said.params.len == 0) return;
        var params: std.ArrayList(ir.Param) = .empty;
        try params.appendSlice(self.arena, symbol.params);
        for (said.params) |entry| {
            const known = for (params.items) |*param| {
                if (std.mem.eql(u8, param.name, entry.name)) break param;
            } else null;
            if (known) |param| param.doc = entry.text else try params.append(self.arena, .{ .name = entry.name, .doc = entry.text });
        }
        symbol.params = try params.toOwnedSlice(self.arena);
    }

    fn add(self: *Reader, scope: *Scope, symbol: ir.Symbol, said: doxygen_comment.Comment, starts_group: bool) Allocator.Error!void {
        if (std.mem.trim(u8, symbol.name, " \t\r\n").len == 0) {
            try scope.symbols.appendSlice(self.arena, symbol.members);
            return;
        }
        if (starts_group) scope.group = scope.symbols.items.len;
        var made = symbol;
        made.visibility = scope.visibility;
        if (scope.type_params.len != 0) {
            made.type_params = scope.type_params;
            scope.type_params = &.{};
        }
        try self.document(&made, said);
        for (scope.symbols.items, 0..) |*existing, at| {
            if (!std.mem.eql(u8, existing.id, made.id)) continue;
            const announced = existing.members.len == 0 and std.mem.eql(u8, existing.form, "typedef");
            const announces = made.members.len == 0 and std.mem.eql(u8, made.form, "typedef");
            if (!announced and !announces) continue;
            if (announced) {
                if (made.doc.isEmpty()) made.doc = existing.doc;
                _ = scope.symbols.orderedRemove(at);
                if (starts_group) scope.group = scope.symbols.items.len;
                try scope.symbols.append(self.arena, made);
            } else if (existing.doc.isEmpty()) {
                existing.doc = made.doc;
            }
            return;
        }
        try scope.symbols.append(self.arena, made);
    }

    fn qualify(self: *Reader, prefix: []const u8, name: []const u8) Allocator.Error![]const u8 {
        if (prefix.len == 0) return name;
        return std.mem.concat(self.arena, u8, &.{ prefix, self.dialect.separator(), name });
    }

    fn scoped(self: *Reader, written: []const u8) Allocator.Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        var depth: usize = 0;
        for (written) |ch| switch (ch) {
            '<' => depth += 1,
            '>' => depth -|= 1,
            ' ', '\t', '\n', '\r' => {},
            else => if (depth == 0) try out.append(self.arena, ch),
        };
        return out.toOwnedSlice(self.arena);
    }

    fn identify(self: *Reader, qualified: []const u8) Allocator.Error![]const u8 {
        return std.mem.concat(self.arena, u8, &.{ @tagName(self.dialect), ":", self.path, "#", qualified });
    }

    fn place(self: *Reader, node: Node) Allocator.Error![]const ir.Location {
        return self.arena.dupe(ir.Location, &.{.{ .file = self.path, .line = node.startPoint().row + 1, .end_line = node.endPoint().row + 1 }});
    }

    fn tidy(self: *Reader, written: []const u8) Allocator.Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        var spaced = false;
        for (written) |ch| {
            if (ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n') {
                spaced = out.items.len != 0;
                continue;
            }
            if (spaced and ch != ',' and ch != ';' and ch != ')' and ch != '[' and out.items[out.items.len - 1] != '(') try out.append(self.arena, ' ');
            spaced = false;
            try out.append(self.arena, ch);
        }
        return out.toOwnedSlice(self.arena);
    }

    fn macro(self: *Reader, node: Node, scope: *Scope, prefix: []const u8, guard: ?[]const u8) Allocator.Error!void {
        const name = text(self.source, node.childByFieldName("name") orelse return);
        const value_node = node.childByFieldName("value");
        const expansion = if (value_node) |found| text(self.source, found) else "";
        const remark = std.mem.indexOf(u8, expansion, "//") orelse std.mem.indexOf(u8, expansion, "/*") orelse expansion.len;
        const value = std.mem.trim(u8, expansion[0..remark], " \t\r\n");
        const said = try self.take(scope);
        if (value.len == 0 and guard != null and std.mem.eql(u8, guard.?, name)) return;
        var params: std.ArrayList(ir.Param) = .empty;
        if (node.childByFieldName("parameters")) |list| {
            var index: u32 = 0;
            while (index < list.namedChildCount()) : (index += 1) try params.append(self.arena, .{ .name = text(self.source, list.namedChild(index).?) });
        }
        const qualified = try self.qualify(prefix, name);
        try self.add(scope, .{
            .id = try self.identify(qualified),
            .name = name,
            .qualified_name = qualified,
            .kind = .macro,
            .locations = try self.place(node),
            .signature = try self.tidy(self.source[node.startByte()..(if (value_node) |found| found.startByte() + remark else node.endByte())]),
            .params = try params.toOwnedSlice(self.arena),
            .value = value,
        }, said, true);
        const rest = std.mem.trim(u8, expansion[remark..], " \t\r\n");
        const shape = doxygen_comment.shape(rest) orelse return;
        if (!shape.trailing) return;
        scope.trailing = .{ .block = shape.block, .last_row = node.startPoint().row };
        try scope.trailing.raw.appendSlice(self.arena, rest);
    }

    fn enumerator(self: *Reader, node: Node, scope: *Scope, prefix: []const u8) Allocator.Error!void {
        const name = text(self.source, node.childByFieldName("name") orelse return);
        const qualified = try self.qualify(prefix, name);
        try self.add(scope, .{
            .id = try self.identify(qualified),
            .name = name,
            .qualified_name = qualified,
            .kind = .enumerator,
            .locations = try self.place(node),
            .signature = try self.tidy(text(self.source, node)),
            .value = if (node.childByFieldName("value")) |value| try self.tidy(text(self.source, value)) else "",
        }, try self.take(scope), true);
    }

    fn container(self: *Reader, specifier: Node, body: Node, name: []const u8, head: []const u8, whole: Node, scope: *Scope, prefix: []const u8) Allocator.Error!void {
        const said = try self.take(scope);
        const qualified = try self.qualify(prefix, name);
        var inner: Scope = .{ .visibility = if (is(specifier.kind(), "class_specifier")) .private else .public };
        try self.statements(body, &inner, qualified, !is(specifier.kind(), "enum_specifier"), null);
        try self.close(&inner);
        try self.add(scope, .{
            .id = try self.identify(qualified),
            .name = name,
            .qualified_name = qualified,
            .kind = .type,
            .form = formOf(specifier),
            .locations = try self.place(whole),
            .signature = try self.tidy(head),
            .bases = try self.bases(specifier),
            .members = try inner.symbols.toOwnedSlice(self.arena),
        }, said, true);
    }

    fn bases(self: *Reader, specifier: Node) Allocator.Error![]const ir.TypeRef {
        var found: std.ArrayList(ir.TypeRef) = .empty;
        var index: u32 = 0;
        while (index < specifier.namedChildCount()) : (index += 1) {
            const clause = specifier.namedChild(index).?;
            if (!is(clause.kind(), "base_class_clause")) continue;
            var at: u32 = 0;
            while (at < clause.namedChildCount()) : (at += 1) {
                const base = clause.namedChild(at).?;
                if (is(base.kind(), "access_specifier") or is(base.kind(), "attribute_declaration")) continue;
                try found.append(self.arena, .{ .text = try self.tidy(text(self.source, base)) });
            }
        }
        return found.toOwnedSlice(self.arena);
    }

    fn namespace(self: *Reader, node: Node, scope: *Scope, prefix: []const u8) Allocator.Error!void {
        const body = node.childByFieldName("body") orelse return;
        const said = try self.take(scope);
        const name_node = node.childByFieldName("name") orelse return self.statements(body, scope, prefix, false, null);
        const name = text(self.source, name_node);
        const qualified = try self.qualify(prefix, name);
        var inner: Scope = .{};
        try self.statements(body, &inner, qualified, false, null);
        try self.close(&inner);
        try self.add(scope, .{
            .id = try self.identify(qualified),
            .name = name,
            .qualified_name = qualified,
            .kind = .namespace,
            .locations = try self.place(node),
            .signature = try self.tidy(self.source[node.startByte()..body.startByte()]),
            .members = try inner.symbols.toOwnedSlice(self.arena),
        }, said, true);
    }

    fn alias(self: *Reader, node: Node, scope: *Scope, prefix: []const u8) Allocator.Error!void {
        const name = text(self.source, node.childByFieldName("name") orelse return);
        const aliased = if (node.childByFieldName("type")) |found| try self.tidy(text(self.source, found)) else "";
        const qualified = try self.qualify(prefix, name);
        try self.add(scope, .{
            .id = try self.identify(qualified),
            .name = name,
            .qualified_name = qualified,
            .kind = .type,
            .form = "alias",
            .locations = try self.place(node),
            .signature = try self.tidy(std.mem.trimEnd(u8, text(self.source, node), "; \t\r\n")),
            .type = .{ .text = aliased },
            .value = aliased,
        }, try self.take(scope), true);
    }

    fn typeParameters(self: *Reader, list: Node) Allocator.Error![]const ir.TypeParam {
        var found: std.ArrayList(ir.TypeParam) = .empty;
        var index: u32 = 0;
        while (index < list.namedChildCount()) : (index += 1) {
            const param = list.namedChild(index).?;
            const declarator = param.childByFieldName("declarator") orelse param.childByFieldName("name");
            if (declarator) |named| {
                const name = analyse(named).name orelse named;
                const constraint = if (param.childByFieldName("type")) |written| try self.tidy(text(self.source, written)) else "";
                try found.append(self.arena, .{ .name = text(self.source, name), .constraint = constraint });
                continue;
            }
            var at = param.namedChildCount();
            while (at > 0) : (at -= 1) {
                const part = param.namedChild(at - 1).?;
                if (!is(part.kind(), "type_identifier") and !is(part.kind(), "identifier")) continue;
                try found.append(self.arena, .{ .name = text(self.source, part) });
                break;
            }
        }
        return found.toOwnedSlice(self.arena);
    }

    fn typeDefinition(self: *Reader, node: Node, scope: *Scope, prefix: []const u8) Allocator.Error!void {
        const specifier = node.childByFieldName("type") orelse return;
        const body = if (isRecord(specifier)) specifier.childByFieldName("body") else null;
        var first = true;
        var index: u32 = 0;
        while (index < node.childCount()) : (index += 1) {
            if (!is(node.fieldNameForChild(index) orelse "", "declarator")) continue;
            const declarator = node.child(index).?;
            const declared = analyse(declarator);
            const name = text(self.source, declared.name orelse continue);
            defer first = false;
            if (body != null and declared.function == null) {
                const head = self.source[node.startByte()..body.?.startByte()];
                try self.container(specifier, body.?, name, head, node, scope, prefix);
                continue;
            }
            const qualified = try self.qualify(prefix, name);
            var symbol: ir.Symbol = .{
                .id = try self.identify(qualified),
                .name = name,
                .qualified_name = qualified,
                .kind = .type,
                .form = "typedef",
                .locations = try self.place(node),
                .signature = try self.tidy(try std.mem.concat(self.arena, u8, &.{ self.source[node.startByte()..specifier.endByte()], " ", text(self.source, declarator) })),
            };
            if (declared.function) |function| {
                symbol.params = try self.parameters(function);
                symbol.type = .{ .text = try self.resultType(node, specifier, declarator, function) };
            } else if (declared.name) |named| {
                symbol.type = .{ .text = try self.valueType(node, specifier, declarator, named) };
            }
            try self.add(scope, symbol, try self.take(scope), first);
        }
    }

    fn declaration(self: *Reader, node: Node, scope: *Scope, prefix: []const u8, in_record: bool) Allocator.Error!void {
        const specifier = node.childByFieldName("type");
        const said = try self.take(scope);
        const body = if (specifier != null and isRecord(specifier.?)) specifier.?.childByFieldName("body") else null;
        var first = true;
        var count: usize = 0;
        var index: u32 = 0;
        while (index < node.childCount()) : (index += 1) {
            if (!is(node.fieldNameForChild(index) orelse "", "declarator")) continue;
            const declarator = node.child(index).?;
            const declared = analyse(declarator);
            const written_name = text(self.source, declared.name orelse continue);
            const outside = self.dialect == .cpp and is(declared.name.?.kind(), "qualified_identifier");
            const last_scope = if (outside) std.mem.lastIndexOf(u8, written_name, "::") else null;
            const name = if (last_scope) |at| written_name[at + 2 ..] else written_name;
            defer first = false;
            const head_end = if (body) |braces| braces.startByte() else if (count == 0) declarator.startByte() else if (specifier) |written| written.endByte() else declarator.startByte();
            count += 1;
            const qualified = try self.qualify(prefix, if (outside) try self.scoped(written_name) else name);
            const shown = if (declarator.childByFieldName("value")) |value| self.source[declarator.startByte()..value.startByte()] else text(self.source, declarator);
            const pure = if (declared.function != null) node.childByFieldName("default_value") else null;
            var symbol: ir.Symbol = .{
                .id = try self.identify(qualified),
                .name = name,
                .qualified_name = qualified,
                .kind = if (in_record) .field else .variable,
                .locations = try self.place(node),
                .signature = try self.tidy(try std.mem.concat(self.arena, u8, &.{
                    self.source[self.startOf(node)..head_end],
                    if (std.mem.endsWith(u8, std.mem.trimEnd(u8, self.source[self.startOf(node)..head_end], " \t"), "~")) "" else " ",
                    std.mem.trimEnd(u8, shown, " \t\r\n="),
                    if (pure != null) " = " else "",
                    if (pure) |value| text(self.source, value) else "",
                })),
                .modifiers = try self.storage(node),
            };
            if (declared.function) |function| {
                const called = function.childByFieldName("declarator");
                if (called != null and !is(called.?.kind(), "parenthesized_declarator")) symbol.kind = .function;
                if (symbol.kind == .field) symbol.form = "function pointer";
                symbol.params = try self.parameters(function);
                if (specifier) |written| symbol.type = .{ .text = try self.resultType(node, written, declarator, function) };
                if (self.macros) |known| {
                    if (known.contains(symbol.type.text)) symbol.type = .{};
                }
                if (outside and symbol.kind == .function and is(node.kind(), "function_definition")) symbol.form = "definition";
                if (self.dialect == .cpp and symbol.kind == .function) {
                    var overload: std.ArrayList(u8) = .empty;
                    try overload.appendSlice(self.arena, symbol.id);
                    try overload.append(self.arena, '(');
                    for (symbol.params, 0..) |param, position| {
                        if (position != 0) try overload.append(self.arena, ',');
                        try overload.appendSlice(self.arena, param.type.text);
                    }
                    try overload.append(self.arena, ')');
                    symbol.id = try overload.toOwnedSlice(self.arena);
                }
            } else if (specifier) |written| {
                symbol.type = .{ .text = try self.valueType(node, written, declarator, declared.name.?) };
            }
            if (body != null) {
                var inner: Scope = .{};
                try self.statements(body.?, &inner, qualified, !is(specifier.?.kind(), "enum_specifier"), null);
                try self.close(&inner);
                symbol.members = try inner.symbols.toOwnedSlice(self.arena);
            }
            try self.add(scope, symbol, said, first);
        }
        if (count != 0 or body == null) return;
        const record = specifier.?;
        if (record.childByFieldName("name")) |name| {
            scope.leading = .{};
            const made = scope.symbols.items.len;
            try self.container(record, body.?, text(self.source, name), self.source[node.startByte()..body.?.startByte()], node, scope, prefix);
            if (scope.symbols.items.len > made) try self.document(&scope.symbols.items[scope.symbols.items.len - 1], said);
            return;
        }
        if (is(record.kind(), "enum_specifier")) return self.statements(body.?, scope, prefix, false, null);
        if (!in_record) return;
        const form = formOf(record);
        const head = self.source[node.startByte()..body.?.startByte()];
        const qualified = try self.qualify(prefix, form);
        var inner: Scope = .{};
        try self.statements(body.?, &inner, qualified, true, null);
        try self.close(&inner);
        try self.add(scope, .{
            .id = try self.identify(qualified),
            .name = form,
            .qualified_name = qualified,
            .kind = .type,
            .form = form,
            .locations = try self.place(node),
            .signature = try self.tidy(head),
            .members = try inner.symbols.toOwnedSlice(self.arena),
        }, said, true);
    }

    fn startOf(self: *Reader, node: Node) u32 {
        var start = node.startByte();
        var moved = true;
        while (moved) {
            moved = false;
            for (self.cleared) |span| {
                if (span.end > start or span.start >= start) continue;
                if (std.mem.trim(u8, self.source[span.end..start], " \t\r\n").len != 0) continue;
                start = span.start;
                moved = true;
            }
        }
        return start;
    }

    fn storage(self: *Reader, node: Node) Allocator.Error![]const []const u8 {
        var words: std.ArrayList([]const u8) = .empty;
        var index: u32 = 0;
        while (index < node.childCount()) : (index += 1) {
            const child = node.child(index).?;
            if (is(node.fieldNameForChild(index) orelse "", "declarator")) break;
            const kind = child.kind();
            const written = text(self.source, child);
            const counts = is(kind, "storage_class_specifier") or is(kind, "explicit_function_specifier") or is(kind, "virtual") or
                (is(kind, "type_qualifier") and std.mem.eql(u8, written, "constexpr"));
            if (counts) try words.append(self.arena, written);
        }
        return words.toOwnedSlice(self.arena);
    }

    fn typeStart(node: Node, specifier: Node) u32 {
        var start = specifier.startByte();
        var index: u32 = 0;
        while (index < node.namedChildCount()) : (index += 1) {
            const child = node.namedChild(index).?;
            if (child.startByte() >= start) break;
            if (is(child.kind(), "type_qualifier")) {
                start = child.startByte();
                break;
            }
        }
        return start;
    }

    fn typeEnd(node: Node, specifier: Node) u32 {
        var end = specifier.endByte();
        var index: u32 = 0;
        while (index < node.childCount()) : (index += 1) {
            const child = node.child(index).?;
            if (is(node.fieldNameForChild(index) orelse "", "declarator")) break;
            if (child.startByte() >= end and is(child.kind(), "type_qualifier")) end = child.endByte();
        }
        return end;
    }

    fn writtenType(self: *Reader, node: Node, specifier: Node) []const u8 {
        if (isRecord(specifier)) {
            if (specifier.childByFieldName("body")) |body| return std.mem.trimEnd(u8, self.source[typeStart(node, specifier)..body.startByte()], " \t\r\n");
        }
        return self.source[typeStart(node, specifier)..typeEnd(node, specifier)];
    }

    fn valueType(self: *Reader, node: Node, specifier: Node, declarator: Node, name: Node) Allocator.Error![]const u8 {
        const end = if (declarator.childByFieldName("value")) |value| value.startByte() else declarator.endByte();
        const around = try std.mem.concat(self.arena, u8, &.{
            self.source[declarator.startByte()..name.startByte()],
            std.mem.trimEnd(u8, self.source[name.endByte()..end], " \t\r\n="),
        });
        return self.join(self.writtenType(node, specifier), around);
    }

    fn resultType(self: *Reader, node: Node, specifier: Node, declarator: Node, function: Node) Allocator.Error![]const u8 {
        const around = try std.mem.concat(self.arena, u8, &.{
            self.source[declarator.startByte()..function.startByte()],
            self.source[function.endByte()..declarator.endByte()],
        });
        return self.join(self.writtenType(node, specifier), around);
    }

    fn join(self: *Reader, written: []const u8, around: []const u8) Allocator.Error![]const u8 {
        const rest = std.mem.trim(u8, around, " \t\r\n");
        if (rest.len == 0) return self.tidy(written);
        return self.tidy(try std.mem.concat(self.arena, u8, &.{ written, if (rest[0] == '[') "" else " ", rest }));
    }

    fn parameters(self: *Reader, function: Node) Allocator.Error![]const ir.Param {
        const list = function.childByFieldName("parameters") orelse return &.{};
        var params: std.ArrayList(ir.Param) = .empty;
        var index: u32 = 0;
        while (index < list.childCount()) : (index += 1) {
            const param = list.child(index).?;
            const kind = param.kind();
            if (is(kind, "variadic_parameter") or is(kind, "...")) {
                try params.append(self.arena, .{ .name = "", .type = .{ .text = "..." } });
                continue;
            }
            if (!is(kind, "parameter_declaration") and !is(kind, "optional_parameter_declaration")) continue;
            const end = if (param.childByFieldName("default_value")) |value| value.startByte() else param.endByte();
            const whole = std.mem.trimEnd(u8, self.source[param.startByte()..end], " \t\r\n=");
            const declarator = param.childByFieldName("declarator");
            const name = if (declarator) |found| analyse(found).name else null;
            if (name == null) {
                const written = try self.tidy(whole);
                if (!std.mem.eql(u8, written, "void")) try params.append(self.arena, .{ .name = "", .type = .{ .text = written } });
                continue;
            }
            try params.append(self.arena, .{
                .name = text(self.source, name.?),
                .type = .{ .text = try self.tidy(try std.mem.concat(self.arena, u8, &.{
                    self.source[param.startByte()..name.?.startByte()],
                    self.source[name.?.endByte() .. param.startByte() + @as(u32, @intCast(whole.len))],
                })) },
            });
        }
        return params.toOwnedSlice(self.arena);
    }
};

fn isRecord(specifier: Node) bool {
    const kind = specifier.kind();
    return is(kind, "struct_specifier") or is(kind, "union_specifier") or is(kind, "enum_specifier") or is(kind, "class_specifier");
}

fn formOf(specifier: Node) []const u8 {
    const kind = specifier.kind();
    if (is(kind, "struct_specifier")) return "struct";
    if (is(kind, "union_specifier")) return "union";
    if (is(kind, "class_specifier")) return "class";
    return "enum";
}

fn visibilityOf(written: []const u8) ir.Visibility {
    if (std.mem.startsWith(u8, written, "private")) return .private;
    if (std.mem.startsWith(u8, written, "protected")) return .protected;
    return .public;
}

fn analyse(declarator: Node) Declared {
    var declared: Declared = .{};
    var node = declarator;
    while (true) {
        const kind = node.kind();
        for ([_][]const u8{ "identifier", "field_identifier", "type_identifier", "destructor_name", "operator_name", "qualified_identifier", "template_function" }) |leaf| {
            if (!is(kind, leaf)) continue;
            declared.name = node;
            return declared;
        }
        if (is(kind, "function_declarator")) declared.function = node;
        if (node.childByFieldName("declarator")) |inner| {
            node = inner;
            continue;
        }
        if (is(kind, "parenthesized_declarator") or is(kind, "reference_declarator")) {
            node = node.namedChild(node.namedChildCount() -| 1) orelse return declared;
            continue;
        }
        return declared;
    }
}

fn plain(arena: Allocator, written: ir.Text) ![]const u8 {
    return ir.plainText(arena, written);
}

fn readForTest(arena: Allocator, source: []const u8) !ir.Unit {
    return read(arena, .c, "sample.h", source, &.{});
}

test "a function carries its name, parameters, return type and documentation" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const file = try readForTest(arena.allocator(),
        \\#define MY_API
        \\/**
        \\ * @brief Creates a scheduler.
        \\ * @param out_error Receives the failure.
        \\ * @return Handle whose @c ref is NULL on failure.
        \\ */
        \\MY_API my_handle my_create(uint32_t workers, struct my_error **out_error);
        \\void undocumented(void);
    );
    try std.testing.expectEqual(3, file.symbol.members.len);
    const create = file.symbol.members[1];
    try std.testing.expectEqualStrings("c:sample.h#my_create", create.id);
    try std.testing.expectEqual(ir.Kind.function, create.kind);
    try std.testing.expectEqual(7, create.locations[0].line);
    try std.testing.expectEqualStrings("MY_API my_handle my_create(uint32_t workers, struct my_error **out_error)", create.signature);
    try std.testing.expectEqualStrings("my_handle", create.type.text);
    try std.testing.expectEqualStrings("Creates a scheduler.", try plain(arena.allocator(), create.doc));
    try std.testing.expectEqual(2, create.params.len);
    try std.testing.expectEqualStrings("workers", create.params[0].name);
    try std.testing.expectEqualStrings("uint32_t", create.params[0].type.text);
    try std.testing.expectEqualStrings("", try plain(arena.allocator(), create.params[0].doc));
    try std.testing.expectEqualStrings("out_error", create.params[1].name);
    try std.testing.expectEqualStrings("struct my_error **", create.params[1].type.text);
    try std.testing.expectEqualStrings("Receives the failure.", try plain(arena.allocator(), create.params[1].doc));
    try std.testing.expectEqualStrings("Handle whose ref is NULL on failure.", try plain(arena.allocator(), create.returns));
    try std.testing.expectEqual(0, file.symbol.members[2].params.len);
    try std.testing.expectEqualStrings("void", file.symbol.members[2].type.text);
}

test "a macro another file defines is put out of the way too, and an outline finds what a file defines" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const found = try outline(arena.allocator(), .c,
        \\#include <pool/export.h>
        \\#ifndef POOL_API
        \\#define POOL_API POOL_EXPORT
        \\#endif
        \\#define TWICE(x) ((x) * 2)
    );
    try std.testing.expectEqual(1, found.includes.len);
    try std.testing.expectEqualStrings("pool/export.h", found.includes[0]);
    try std.testing.expectEqual(1, found.macros.len);
    try std.testing.expectEqualStrings("POOL_API", found.macros[0]);

    const source = "static POOL_API const pool *pool_last(void);\n";
    const alone = try read(arena.allocator(), .c, "sample.h", source, &.{});
    try std.testing.expect(!std.mem.eql(u8, "const pool *", alone.symbol.members[0].type.text));
    const told = try read(arena.allocator(), .c, "sample.h", source, found.macros);
    try std.testing.expectEqualStrings("pool_last", told.symbol.members[0].name);
    try std.testing.expectEqualStrings("const pool *", told.symbol.members[0].type.text);
    try std.testing.expectEqualStrings("static POOL_API const pool *pool_last(void)", told.symbol.members[0].signature);
}

test "the slots of a vtable are members named after the function pointer" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const file = try readForTest(arena.allocator(),
        \\typedef struct pool pool;
        \\typedef struct task task;
        \\/// Dispatches work.
        \\///
        \\/// Through a pool of threads.
        \\typedef struct pool
        \\{
        \\    void *handle;
        \\    /**
        \\     * Schedules a task.
        \\     * @param func Entry point,
        \\     *             run on a worker.
        \\     */
        \\    task *(*dispatch)(struct pool *self,
        \\                      task_func func);
        \\    uint32_t (*count)(struct pool *self);
        \\} pool;
    );
    try std.testing.expectEqual(2, file.symbol.members.len);
    try std.testing.expectEqualStrings("task", file.symbol.members[0].name);
    const pool = file.symbol.members[1];
    try std.testing.expectEqualStrings("struct", pool.form);
    try std.testing.expectEqualStrings("typedef struct pool", pool.signature);
    try std.testing.expectEqualStrings("Dispatches work.\n\nThrough a pool of threads.", try plain(arena.allocator(), pool.doc));
    try std.testing.expectEqual(6, pool.locations[0].line);
    try std.testing.expectEqual(17, pool.locations[0].end_line);
    try std.testing.expectEqual(3, pool.members.len);
    try std.testing.expectEqualStrings("void *", pool.members[0].type.text);
    const dispatch = pool.members[1];
    try std.testing.expectEqualStrings("c:sample.h#pool.dispatch", dispatch.id);
    try std.testing.expectEqual(ir.Kind.field, dispatch.kind);
    try std.testing.expectEqualStrings("task *(*dispatch)(struct pool *self, task_func func)", dispatch.signature);
    try std.testing.expectEqualStrings("task *", dispatch.type.text);
    try std.testing.expectEqualStrings("self", dispatch.params[0].name);
    try std.testing.expectEqualStrings("struct pool *", dispatch.params[0].type.text);
    try std.testing.expectEqualStrings("Entry point, run on a worker.", try plain(arena.allocator(), dispatch.params[1].doc));
    try std.testing.expectEqualStrings("count", pool.members[2].name);
    try std.testing.expectEqualStrings("uint32_t", pool.members[2].type.text);
}

test "a callback typedef is named after the pointer it declares" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const file = try readForTest(arena.allocator(),
        \\/// Body of a task.
        \\/// Runs on a worker.
        \\typedef void (*task_func)(void *data, void (*done)(int code), ...);
        \\typedef struct task task;
    );
    const callback = file.symbol.members[0];
    try std.testing.expectEqualStrings("typedef", callback.form);
    try std.testing.expectEqualStrings("task_func", callback.name);
    try std.testing.expectEqualStrings("void", callback.type.text);
    try std.testing.expectEqualStrings("typedef void (*task_func)(void *data, void (*done)(int code), ...)", callback.signature);
    try std.testing.expectEqualStrings("Body of a task.\nRuns on a worker.", try plain(arena.allocator(), callback.doc));
    try std.testing.expectEqual(3, callback.params.len);
    try std.testing.expectEqualStrings("done", callback.params[1].name);
    try std.testing.expectEqualStrings("void (*)(int code)", callback.params[1].type.text);
    try std.testing.expectEqualStrings("...", callback.params[2].type.text);
    try std.testing.expectEqualStrings("task", file.symbol.members[1].name);
}

test "a trailing comment documents the declaration before it, and each name on a line is a field" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const file = try readForTest(arena.allocator(),
        \\typedef struct params
        \\{
        \\    uint32_t width;  ///< Width in pixels.
        \\    uint32_t height; /**< Height in pixels. */
        \\    uint32_t depth;
        \\    char name[16];   ///< Shown in captures,
        \\                     ///< copied by the call.
        \\    float x, y; ///< A position.
        \\    const char *label;
        \\} params;
    );
    const members = file.symbol.members[0].members;
    try std.testing.expectEqual(7, members.len);
    try std.testing.expectEqualStrings("width", members[0].name);
    try std.testing.expectEqualStrings("Width in pixels.", try plain(arena.allocator(), members[0].doc));
    try std.testing.expectEqualStrings("Height in pixels.", try plain(arena.allocator(), members[1].doc));
    try std.testing.expectEqualStrings("", try plain(arena.allocator(), members[2].doc));
    try std.testing.expectEqualStrings("name", members[3].name);
    try std.testing.expectEqualStrings("char[16]", members[3].type.text);
    try std.testing.expectEqualStrings("Shown in captures,\ncopied by the call.", try plain(arena.allocator(), members[3].doc));
    try std.testing.expectEqualStrings("x", members[4].name);
    try std.testing.expectEqualStrings("c:sample.h#params.y", members[5].id);
    try std.testing.expectEqualStrings("float y", members[5].signature);
    try std.testing.expectEqualStrings("float", members[5].type.text);
    try std.testing.expectEqualStrings("A position.", try plain(arena.allocator(), members[4].doc));
    try std.testing.expectEqualStrings("A position.", try plain(arena.allocator(), members[5].doc));
    try std.testing.expectEqualStrings("const char *", members[6].type.text);
}

test "enumerators carry their values and their own lines" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const file = try readForTest(arena.allocator(),
        \\/** How a face is culled. */
        \\typedef enum cull_mode
        \\{
        \\    CULL_NONE = 0, ///< Draws both faces.
        \\    /** Drops the back face. */
        \\    CULL_BACK = 1,
        \\    CULL_FRONT ///< Drops the front face.
        \\} cull_mode;
    );
    try std.testing.expectEqual(1, file.symbol.members.len);
    try std.testing.expectEqualStrings("enum", file.symbol.members[0].form);
    try std.testing.expectEqualStrings("typedef enum cull_mode", file.symbol.members[0].signature);
    const members = file.symbol.members[0].members;
    try std.testing.expectEqual(3, members.len);
    try std.testing.expectEqual(ir.Kind.enumerator, members[0].kind);
    try std.testing.expectEqualStrings("CULL_NONE", members[0].name);
    try std.testing.expectEqualStrings("0", members[0].value);
    try std.testing.expectEqualStrings("Draws both faces.", try plain(arena.allocator(), members[0].doc));
    try std.testing.expectEqualStrings("Drops the back face.", try plain(arena.allocator(), members[1].doc));
    try std.testing.expectEqual(6, members[1].locations[0].line);
    try std.testing.expectEqualStrings("c:sample.h#cull_mode.CULL_FRONT", members[2].id);
    try std.testing.expectEqualStrings("Drops the front face.", try plain(arena.allocator(), members[2].doc));
}

test "an extern block is transparent, includes and macros are recorded and the guard is not" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const file = try readForTest(arena.allocator(), byte_order_mark ++
        \\#ifndef GUARD_H_
        \\#define GUARD_H_
        \\#include <pool/error.h>
        \\#include "local.h"
        \\#ifdef __cplusplus
        \\extern "C"
        \\{
        \\#endif
        \\    /** The answer. */
        \\    #define ANSWER 42
        \\    #define LIMIT 0x10u ///< The most there can be.
        \\    #define TWICE(x) ((x) * 2)
        \\    /** Stops the pool. */
        \\    void stop(void);
        \\#ifdef __cplusplus
        \\}
        \\#endif
        \\#endif
    );
    try std.testing.expectEqual(2, file.file.imports.len);
    try std.testing.expectEqualStrings("pool/error.h", file.file.imports[0].name);
    try std.testing.expectEqualStrings("local.h", file.file.imports[1].name);
    try std.testing.expectEqual(4, file.symbol.members.len);
    try std.testing.expectEqual(ir.Kind.macro, file.symbol.members[0].kind);
    try std.testing.expectEqualStrings("#define ANSWER 42", file.symbol.members[0].signature);
    try std.testing.expectEqualStrings("42", file.symbol.members[0].value);
    try std.testing.expectEqualStrings("The answer.", try plain(arena.allocator(), file.symbol.members[0].doc));
    try std.testing.expectEqualStrings("#define LIMIT 0x10u", file.symbol.members[1].signature);
    try std.testing.expectEqualStrings("0x10u", file.symbol.members[1].value);
    try std.testing.expectEqualStrings("The most there can be.", try plain(arena.allocator(), file.symbol.members[1].doc));
    try std.testing.expectEqualStrings("x", file.symbol.members[2].params[0].name);
    try std.testing.expectEqualStrings("stop", file.symbol.members[3].name);
    try std.testing.expectEqualStrings("Stops the pool.", try plain(arena.allocator(), file.symbol.members[3].doc));
}

test "a file comment documents the file and a parameter only a comment names is kept" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const file = try readForTest(arena.allocator(),
        \\/**
        \\ * @file sample.h
        \\ * Contracts of the pool.
        \\ */
        \\/**
        \\ * Waits for a task.
        \\ * @param timeout Unused.
        \\ */
        \\bool wait(task *t);
    );
    try std.testing.expectEqualStrings("Contracts of the pool.", try plain(arena.allocator(), file.symbol.doc));
    const wait = file.symbol.members[0];
    try std.testing.expectEqualStrings("Waits for a task.", try plain(arena.allocator(), wait.doc));
    try std.testing.expectEqual(2, wait.params.len);
    try std.testing.expectEqualStrings("task *", wait.params[0].type.text);
    try std.testing.expectEqualStrings("timeout", wait.params[1].name);
    try std.testing.expectEqualStrings("", wait.params[1].type.text);
}

test "plain comments and banner comments are not documentation" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const file = try readForTest(arena.allocator(),
        \\/* plain */
        \\int a;
        \\// plain
        \\int b;
        \\/*** banner ***/
        \\int c;
        \\//// banner
        \\int d;
    );
    try std.testing.expectEqual(4, file.symbol.members.len);
    for (file.symbol.members) |decl| {
        try std.testing.expectEqual(ir.Kind.variable, decl.kind);
        try std.testing.expectEqualStrings("", try plain(arena.allocator(), decl.doc));
    }
}

test "a function with a body and a table with its values are read without what follows the declaration" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const file = try readForTest(arena.allocator(),
        \\/** Squares a number. */
        \\static inline int square(int x) { struct { int y; } s; s.y = x; return s.y * x; }
        \\/** Field count. */
        \\static const int count[] = { 1, 2 };
    );
    try std.testing.expectEqual(2, file.symbol.members.len);
    const square = file.symbol.members[0];
    try std.testing.expectEqualStrings("square", square.name);
    try std.testing.expectEqual(ir.Kind.function, square.kind);
    try std.testing.expectEqualStrings("static inline int square(int x)", square.signature);
    try std.testing.expectEqualStrings("x", square.params[0].name);
    try std.testing.expectEqualStrings("static", square.modifiers[0]);
    const count = file.symbol.members[1];
    try std.testing.expectEqual(ir.Kind.variable, count.kind);
    try std.testing.expectEqualStrings("static const int count[]", count.signature);
    try std.testing.expectEqualStrings("const int[]", count.type.text);
    try std.testing.expectEqualStrings("Field count.", try plain(arena.allocator(), count.doc));
}

test "a union without a name is named after what it is, and one that types a field lends it its members" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const file = try readForTest(arena.allocator(),
        \\typedef struct variant
        \\{
        \\    int kind;
        \\    union
        \\    {
        \\        float f; ///< As a number.
        \\        int i;
        \\    };
        \\    struct { float depth; int stencil; } clear;
        \\} variant;
    );
    const variant = file.symbol.members[0];
    try std.testing.expectEqual(3, variant.members.len);
    const anonymous = variant.members[1];
    try std.testing.expectEqualStrings("union", anonymous.name);
    try std.testing.expectEqualStrings("union", anonymous.form);
    try std.testing.expectEqualStrings("c:sample.h#variant.union.f", anonymous.members[0].id);
    try std.testing.expectEqualStrings("As a number.", try plain(arena.allocator(), anonymous.members[0].doc));
    const clear_field = variant.members[2];
    try std.testing.expectEqual(ir.Kind.field, clear_field.kind);
    try std.testing.expectEqualStrings("struct", clear_field.type.text);
    try std.testing.expectEqualStrings("c:sample.h#variant.clear.stencil", clear_field.members[1].id);
}

test "a namespace, a class, its members and what it derives from are read from a C++ file" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const file = try read(arena.allocator(), .cpp, "pool.hpp",
        \\namespace ke::pool {
        \\/// Runs tasks.
        \\template <typename T, int N = 4>
        \\class Pool : public Base, private Other<T> {
        \\    int hidden;
        \\public:
        \\    /// Starts @p workers threads.
        \\    explicit Pool(int workers = 2);
        \\    virtual ~Pool();
        \\    /// Waits for a task.
        \\    virtual bool wait(const Task &task, T &&value, ...) const noexcept = 0;
        \\    static Pool *create();
        \\    template <class U> U as() const;
        \\    bool operator==(const Pool &other) const;
        \\    int count = 0; ///< How many ran.
        \\    using Handle = int;
        \\    enum class State { idle, busy };
        \\    inline int size() const { return 1; }
        \\protected:
        \\    void (*on_done)(int code);
        \\};
        \\using Id = unsigned;
        \\void stop(Id id);
        \\}
    , &.{});
    try std.testing.expectEqualStrings("cpp", file.file.language);
    try std.testing.expectEqualStrings("cpp:pool.hpp", file.symbol.id);
    try std.testing.expectEqual(1, file.symbol.members.len);
    const space = file.symbol.members[0];
    try std.testing.expectEqual(ir.Kind.namespace, space.kind);
    try std.testing.expectEqualStrings("ke::pool", space.name);
    try std.testing.expectEqual(3, space.members.len);

    const pool = space.members[0];
    try std.testing.expectEqualStrings("cpp:pool.hpp#ke::pool::Pool", pool.id);
    try std.testing.expectEqualStrings("class", pool.form);
    try std.testing.expectEqualStrings("class Pool : public Base, private Other<T>", pool.signature);
    try std.testing.expectEqualStrings("Runs tasks.", try plain(arena.allocator(), pool.doc));
    try std.testing.expectEqual(2, pool.type_params.len);
    try std.testing.expectEqualStrings("T", pool.type_params[0].name);
    try std.testing.expectEqualStrings("N", pool.type_params[1].name);
    try std.testing.expectEqualStrings("int", pool.type_params[1].constraint);
    try std.testing.expectEqual(2, pool.bases.len);
    try std.testing.expectEqualStrings("Base", pool.bases[0].text);
    try std.testing.expectEqualStrings("Other<T>", pool.bases[1].text);
    try std.testing.expectEqual(12, pool.members.len);

    try std.testing.expectEqualStrings("hidden", pool.members[0].name);
    try std.testing.expectEqual(ir.Visibility.private, pool.members[0].visibility);

    const constructor = pool.members[1];
    try std.testing.expectEqual(ir.Kind.function, constructor.kind);
    try std.testing.expectEqual(ir.Visibility.public, constructor.visibility);
    try std.testing.expectEqualStrings("explicit Pool(int workers = 2)", constructor.signature);
    try std.testing.expectEqualStrings("explicit", constructor.modifiers[0]);
    try std.testing.expectEqualStrings("", constructor.type.text);
    try std.testing.expectEqualStrings("workers", constructor.params[0].name);
    try std.testing.expectEqualStrings("int", constructor.params[0].type.text);
    try std.testing.expectEqualDeep(ir.Inline{ .param = "workers" }, constructor.doc.blocks[0].paragraph[1]);

    try std.testing.expectEqualStrings("~Pool", pool.members[2].name);
    try std.testing.expectEqualStrings("virtual ~Pool()", pool.members[2].signature);
    try std.testing.expectEqualStrings("virtual", pool.members[2].modifiers[0]);

    const wait = pool.members[3];
    try std.testing.expectEqualStrings("cpp:pool.hpp#ke::pool::Pool::wait(const Task &,T &&,...)", wait.id);
    try std.testing.expectEqual(ir.Kind.function, wait.kind);
    try std.testing.expectEqualStrings("virtual bool wait(const Task &task, T &&value, ...) const noexcept = 0", wait.signature);
    try std.testing.expectEqualStrings("bool", wait.type.text);
    try std.testing.expectEqual(3, wait.params.len);
    try std.testing.expectEqualStrings("task", wait.params[0].name);
    try std.testing.expectEqualStrings("const Task &", wait.params[0].type.text);
    try std.testing.expectEqualStrings("T &&", wait.params[1].type.text);
    try std.testing.expectEqualStrings("...", wait.params[2].type.text);

    try std.testing.expectEqualStrings("static", pool.members[4].modifiers[0]);
    try std.testing.expectEqualStrings("Pool *", pool.members[4].type.text);
    try std.testing.expectEqualStrings("as", pool.members[5].name);
    try std.testing.expectEqualStrings("U", pool.members[5].type_params[0].name);
    try std.testing.expectEqualStrings("operator==", pool.members[6].name);
    try std.testing.expectEqual(ir.Kind.field, pool.members[7].kind);
    try std.testing.expectEqualStrings("How many ran.", try plain(arena.allocator(), pool.members[7].doc));
    try std.testing.expectEqualStrings("alias", pool.members[8].form);
    try std.testing.expectEqualStrings("int", pool.members[8].value);
    try std.testing.expectEqualStrings("cpp:pool.hpp#ke::pool::Pool::State::busy", pool.members[9].members[1].id);
    try std.testing.expectEqualStrings("size", pool.members[10].name);
    try std.testing.expectEqual(0, pool.members[10].type_params.len);
    try std.testing.expectEqualStrings("on_done", pool.members[11].name);
    try std.testing.expectEqual(ir.Kind.field, pool.members[11].kind);
    try std.testing.expectEqual(ir.Visibility.protected, pool.members[11].visibility);
    try std.testing.expectEqualStrings("code", pool.members[11].params[0].name);

    try std.testing.expectEqualStrings("Id", space.members[1].name);
    try std.testing.expectEqual(ir.Visibility.public, space.members[1].visibility);
    try std.testing.expectEqualStrings("void stop(Id id)", space.members[2].signature);
}

test "a file is read as C or as C++ by its extension" {
    try std.testing.expectEqual(Dialect.c, Dialect.of(".h").?);
    try std.testing.expectEqual(Dialect.cpp, Dialect.of(".hpp").?);
    try std.testing.expectEqual(Dialect.cpp, Dialect.of(".cc").?);
    try std.testing.expectEqual(null, Dialect.of(".zig"));
}

test "a member defined outside its class is joined to the declaration it has there" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var units = [_]ir.Unit{
        try read(allocator, .cpp, "pool.hpp",
            \\namespace ke {
            \\template <typename T> class Pool {
            \\public:
            \\    /** Stops it. */
            \\    void stop(int code);
            \\    void stop();
            \\    void wait();
            \\};
            \\}
        , &.{}),
        try read(allocator, .cpp, "pool.cpp",
            \\namespace ke {
            \\template <typename T> void Pool<T>::stop(int code) {}
            \\/** Waits for every task. */
            \\template <typename T> void Pool<T>::wait() {}
            \\}
            \\void ke::Other::run() {}
        , &.{}),
    };
    try join(allocator, &units);
    const pool = units[0].symbol.members[0].members[0];
    try std.testing.expectEqual(3, pool.members.len);
    try std.testing.expectEqual(2, pool.members[0].locations.len);
    try std.testing.expectEqualStrings("pool.cpp", pool.members[0].locations[1].file);
    try std.testing.expectEqualStrings("Stops it.", try plain(allocator, pool.members[0].doc));
    try std.testing.expectEqual(1, pool.members[1].locations.len);
    try std.testing.expectEqualStrings("Waits for every task.", try plain(allocator, pool.members[2].doc));
    try std.testing.expectEqual(0, units[1].symbol.members[0].members.len);
    const run = units[1].symbol.members[1];
    try std.testing.expectEqualStrings("run", run.name);
    try std.testing.expectEqualStrings("ke::Other::run", run.qualified_name);
    try std.testing.expectEqualStrings("definition", run.form);
}

test "a header is taken for C++ when only the C++ grammar makes sense of it" {
    try std.testing.expectEqual(Dialect.c, try Dialect.detect("typedef struct pool { int count; } pool;\nMY_API void stop(pool *self);\n"));
    try std.testing.expectEqual(Dialect.c, try Dialect.detect("#ifdef __cplusplus\nextern \"C\" {\n#endif\nvoid stop(void);\n#ifdef __cplusplus\n}\n#endif\n"));
    try std.testing.expectEqual(Dialect.cpp, try Dialect.detect("namespace ke {\nclass Pool {\npublic:\n    void stop();\n};\n}\n"));
    try std.testing.expectEqual(Dialect.cpp, try Dialect.detect("template <typename T> T twice(T value) { return value + value; }\n"));
}

test "a macro among the parameters of a declaration is put out of the way like one in front of it" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const file = try readForTest(arena.allocator(),
        \\#define MY_API
        \\#define MY_PURE
        \\#define MY_NOESCAPE
        \\MY_API MY_PURE unsigned long hash(MY_NOESCAPE const void* input, size_t length, MY_NOESCAPE const void* seed);
    );
    const hash = file.symbol.members[3];
    try std.testing.expectEqualStrings("hash", hash.name);
    try std.testing.expectEqual(ir.Kind.function, hash.kind);
    try std.testing.expectEqual(3, hash.params.len);
    try std.testing.expectEqualStrings("length", hash.params[1].name);
    try std.testing.expectEqualStrings("seed", hash.params[2].name);
}

test "a field that points to a function says so in its form" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const file = try readForTest(arena.allocator(),
        \\typedef struct pool {
        \\    void (*stop)(void);
        \\    int count;
        \\} pool;
    );
    const pool = file.symbol.members[0];
    try std.testing.expectEqual(ir.Kind.field, pool.members[0].kind);
    try std.testing.expectEqualStrings("function pointer", pool.members[0].form);
    try std.testing.expectEqualStrings("", pool.members[1].form);
}

test "a typedef of a type that is not a function carries the type it names" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const file = try readForTest(arena.allocator(),
        \\typedef uint64_t handle;
        \\typedef struct pool pool;
        \\typedef const char *name;
        \\typedef void (*stop)(void);
    );
    try std.testing.expectEqualStrings("uint64_t", file.symbol.members[0].type.text);
    try std.testing.expectEqualStrings("struct pool", file.symbol.members[1].type.text);
    try std.testing.expectEqualStrings("const char *", file.symbol.members[2].type.text);
    try std.testing.expectEqualStrings("void", file.symbol.members[3].type.text);
}
