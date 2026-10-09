//! Reads the declarations of a C# file and the documentation written on them.
//!
//! The parser is tree-sitter with its C# grammar, and this file only turns the tree into the
//! document model. Every declaration is recorded, documented or not, with the visibility it
//! states or the one the language gives it when it states none. The file becomes a symbol of
//! kind `ir.Kind.module` and what it declares becomes its members. A namespace is a symbol
//! of kind `ir.Kind.namespace`, one per part of its name, so `namespace Ke.Tasks` is "Tasks"
//! inside "Ke", and a namespace declared for the whole file holds what follows it. A conditional of
//! the preprocessor is transparent: what it holds belongs to the scope around it.
//!
//! A class, a struct, an interface, a record, an enum and a delegate are types, told apart
//! by `ir.Symbol.form`. A method, a constructor, a destructor and an operator are functions,
//! a property and an indexer are properties, and a field declared `const` is a constant. A
//! line that declares several fields or events gives one symbol per name. Each parameter a
//! record is declared with is also a property of it, as the language makes it one, carrying
//! what the comment of the record says of that parameter.
//!
//! The identifier of a symbol is `csharp:`, the path of its file, a `#` and its name
//! qualified by what is around it. Since C# lets a name be declared more than once, a type
//! with parameters has their count after a grave accent, and what takes parameters has their
//! types between parentheses: `csharp:Pool.cs#Ke.Pool.Run(int,string)`.
//!
//! A documentation comment is the run of `///` lines in front of a declaration, or a
//! `/** */` block there, and what it means is read by `xml_comment`. What it says of a
//! parameter is attached to the one it names, and a comment that asks for the documentation
//! of another symbol leaves that request in `ir.Symbol.inherits` for the linker.
//!
//! `join` makes one symbol of a type declared in parts, in several files.

const std = @import("std");
const tree_sitter = @import("tree_sitter");
const ir = @import("ir.zig");
const xml_comment = @import("xml_comment.zig");

const Allocator = std.mem.Allocator;
const Node = tree_sitter.Node;

extern fn tree_sitter_c_sharp() callconv(.c) *const anyopaque;

/// What `read` fails with.
pub const Error = Allocator.Error || error{GrammarRejected};

/// The name `ir.File.language` carries for a file read here.
pub const language = "csharp";

/// Whether a file with this extension is read here.
pub fn reads(extension: []const u8) bool {
    return std.mem.eql(u8, extension, ".cs");
}

/// Reads one file. `path` becomes the path of the file in the document. What the grammar
/// cannot make sense of is left out, and the declarations around it are still read. Fails
/// with `error.GrammarRejected` when the parser does not take the grammar this package was
/// built with.
pub fn read(arena: Allocator, path: []const u8, source: []const u8) Error!ir.Unit {
    const parser = tree_sitter.Parser.create();
    defer parser.destroy();
    parser.setLanguage(@ptrCast(@alignCast(tree_sitter_c_sharp()))) catch return error.GrammarRejected;
    const tree = parser.parseString(source, null) orelse return error.GrammarRejected;
    defer tree.destroy();

    const id = try std.mem.concat(arena, u8, &.{ language, ":", path });
    var reader: Reader = .{ .arena = arena, .source = source, .path = path, .root = id };
    var members: std.ArrayList(ir.Symbol) = .empty;
    try reader.declarations(tree.rootNode(), &members, "", .namespace);
    return .{
        .file = .{ .path = path, .language = language },
        .symbol = .{
            .id = id,
            .name = std.fs.path.stem(path),
            .qualified_name = path,
            .kind = .module,
            .locations = try arena.dupe(ir.Location, &.{.{ .file = path, .line = 1, .end_line = @intCast(std.mem.count(u8, source, "\n") + 1) }}),
            .members = try members.toOwnedSlice(arena),
        },
    };
}

/// Makes one symbol of every type that `units` declare in parts, in more than one place.
/// The first part met keeps the symbol and receives the members, the places and the bases
/// of the others, and their documentation when it has none. The other parts leave their
/// files, and what moved is identified under the file of the part that stayed.
pub fn join(arena: Allocator, units: []ir.Unit) Allocator.Error!void {
    var joiner: Joiner = .{ .arena = arena };
    for (units) |unit| {
        if (!std.mem.eql(u8, unit.file.language, language)) continue;
        try joiner.collect(unit.symbol.members, unit.symbol.id);
    }
    for (units) |*unit| {
        if (!std.mem.eql(u8, unit.file.language, language)) continue;
        unit.symbol.members = try joiner.rebuilt(unit.symbol.members, unit.symbol.id);
    }
}

const Part = struct {
    symbol: ir.Symbol,
    root: []const u8,
};

const Parts = struct {
    members: std.ArrayList(Part) = .empty,
    locations: std.ArrayList(ir.Location) = .empty,
    bases: std.ArrayList(ir.TypeRef) = .empty,
    doc: ir.Text = .{},
    count: usize = 0,
    emitted: bool = false,
};

const Joiner = struct {
    arena: Allocator,
    parts: std.StringHashMapUnmanaged(Parts) = .empty,

    fn keyOf(symbol: ir.Symbol, root: []const u8) ?[]const u8 {
        if (symbol.kind != .type) return null;
        for (symbol.modifiers) |modifier| {
            if (std.mem.eql(u8, modifier, "partial")) return symbol.id[@min(symbol.id.len, root.len)..];
        }
        return null;
    }

    fn collect(self: *Joiner, list: []const ir.Symbol, root: []const u8) Allocator.Error!void {
        for (list) |symbol| {
            if (keyOf(symbol, root)) |key| {
                const entry = try self.parts.getOrPut(self.arena, key);
                if (!entry.found_existing) entry.value_ptr.* = .{};
                const parts = entry.value_ptr;
                parts.count += 1;
                for (symbol.members) |member| try parts.members.append(self.arena, .{ .symbol = member, .root = root });
                try parts.locations.appendSlice(self.arena, symbol.locations);
                for (symbol.bases) |base| {
                    const known = for (parts.bases.items) |other| {
                        if (std.mem.eql(u8, other.text, base.text)) break true;
                    } else false;
                    if (!known) try parts.bases.append(self.arena, base);
                }
                if (parts.doc.isEmpty()) parts.doc = symbol.doc;
            }
            try self.collect(symbol.members, root);
        }
    }

    fn rooted(self: *Joiner, symbol: ir.Symbol, from: []const u8, root: []const u8) Allocator.Error!ir.Symbol {
        if (std.mem.eql(u8, from, root)) return symbol;
        var out = symbol;
        out.id = try std.mem.concat(self.arena, u8, &.{ root, symbol.id[@min(symbol.id.len, from.len)..] });
        const members = try self.arena.alloc(ir.Symbol, symbol.members.len);
        for (members, symbol.members) |*member, original| member.* = try self.rooted(original, from, root);
        out.members = members;
        return out;
    }

    fn rebuilt(self: *Joiner, list: []const ir.Symbol, root: []const u8) Allocator.Error![]const ir.Symbol {
        var out: std.ArrayList(ir.Symbol) = .empty;
        for (list) |original| {
            var symbol = original;
            if (keyOf(symbol, root)) |key| {
                const parts = self.parts.getPtr(key).?;
                if (parts.emitted) continue;
                parts.emitted = true;
                if (parts.count > 1) {
                    const members = try self.arena.alloc(ir.Symbol, parts.members.items.len);
                    for (members, parts.members.items) |*member, part| member.* = try self.rooted(part.symbol, part.root, root);
                    symbol.members = members;
                    symbol.locations = parts.locations.items;
                    symbol.bases = parts.bases.items;
                    symbol.doc = parts.doc;
                }
            }
            symbol.members = try self.rebuilt(symbol.members, root);
            try out.append(self.arena, symbol);
        }
        return out.toOwnedSlice(self.arena);
    }
};

fn is(kind: []const u8, name: []const u8) bool {
    return std.mem.eql(u8, kind, name);
}

fn text(source: []const u8, node: Node) []const u8 {
    return source[node.startByte()..node.endByte()];
}

const Owner = enum { namespace, type, interface, enumeration };

const type_forms = std.StaticStringMap([]const u8).initComptime(.{
    .{ "class_declaration", "class" },
    .{ "struct_declaration", "struct" },
    .{ "interface_declaration", "interface" },
    .{ "record_declaration", "record" },
    .{ "enum_declaration", "enum" },
});

const Pending = struct {
    raw: std.ArrayList(u8) = .empty,
    last_row: u32 = 0,
    block: bool = false,
};

const Reader = struct {
    arena: Allocator,
    source: []const u8,
    path: []const u8,
    root: []const u8,
    ids: []const u8 = "",

    fn declarations(self: *Reader, node: Node, out: *std.ArrayList(ir.Symbol), prefix: []const u8, owner: Owner) Allocator.Error!void {
        var pending: Pending = .{};
        try self.scope(node, out, prefix, owner, &pending);
    }

    fn scope(self: *Reader, node: Node, out: *std.ArrayList(ir.Symbol), prefix: []const u8, owner: Owner, pending: *Pending) Allocator.Error!void {
        var target = out;
        var inner: std.ArrayList(ir.Symbol) = .empty;
        var inner_prefix = prefix;
        var whole_file: ?Node = null;
        const ids_around = self.ids;
        defer self.ids = ids_around;
        var index: u32 = 0;
        while (index < node.namedChildCount()) : (index += 1) {
            const child = node.namedChild(index).?;
            const kind = child.kind();
            if (is(kind, "comment")) {
                try self.comment(child, pending);
                continue;
            }
            if (std.mem.startsWith(u8, kind, "preproc_if") or is(kind, "preproc_else") or is(kind, "preproc_elif") or is(kind, "preproc_region")) {
                try self.scope(child, target, inner_prefix, owner, pending);
                continue;
            }
            const said = try xml_comment.parse(self.arena, pending.raw.items);
            pending.* = .{};
            if (is(kind, "file_scoped_namespace_declaration")) {
                if (whole_file != null) continue;
                const name = child.childByFieldName("name") orelse continue;
                whole_file = child;
                target = &inner;
                inner_prefix = try self.qualified(prefix, try self.tidy(text(self.source, name)));
                self.ids = inner_prefix;
            } else if (is(kind, "namespace_declaration")) {
                const name = child.childByFieldName("name") orelse continue;
                const body = child.childByFieldName("body") orelse continue;
                var members: std.ArrayList(ir.Symbol) = .empty;
                const ids_outside = self.ids;
                self.ids = try self.qualified(inner_prefix, try self.tidy(text(self.source, name)));
                try self.declarations(body, &members, self.ids, .namespace);
                self.ids = ids_outside;
                try target.append(self.arena, try self.namespace(child, text(self.source, name), inner_prefix, try members.toOwnedSlice(self.arena)));
            } else if (type_forms.get(kind)) |form| {
                try target.append(self.arena, try self.container(child, form, inner_prefix, owner, said));
            } else if (is(kind, "delegate_declaration")) {
                try target.append(self.arena, try self.callable(child, .type, "delegate", inner_prefix, owner, said));
            } else if (is(kind, "method_declaration")) {
                try target.append(self.arena, try self.callable(child, .function, "", inner_prefix, owner, said));
            } else if (is(kind, "constructor_declaration")) {
                try target.append(self.arena, try self.callable(child, .function, "constructor", inner_prefix, owner, said));
            } else if (is(kind, "destructor_declaration")) {
                try target.append(self.arena, try self.callable(child, .function, "destructor", inner_prefix, owner, said));
            } else if (is(kind, "operator_declaration") or is(kind, "conversion_operator_declaration")) {
                try target.append(self.arena, try self.callable(child, .function, "operator", inner_prefix, owner, said));
            } else if (is(kind, "property_declaration") or is(kind, "event_declaration")) {
                try target.append(self.arena, try self.property(child, if (is(kind, "event_declaration")) .event else .property, "", inner_prefix, owner, said));
            } else if (is(kind, "indexer_declaration")) {
                try target.append(self.arena, try self.property(child, .property, "indexer", inner_prefix, owner, said));
            } else if (is(kind, "field_declaration") or is(kind, "event_field_declaration")) {
                try self.fields(child, target, is(kind, "event_field_declaration"), inner_prefix, owner, said);
            } else if (is(kind, "enum_member_declaration")) {
                const name = child.childByFieldName("name") orelse continue;
                var symbol = try self.named(child, text(self.source, name), inner_prefix, self.ids, "");
                symbol.kind = .enumerator;
                symbol.signature = try self.tidy(text(self.source, child));
                if (child.childByFieldName("value")) |value| symbol.value = text(self.source, value);
                try self.document(&symbol, said);
                try target.append(self.arena, symbol);
            }
        }
        if (whole_file) |declared| {
            const name = declared.childByFieldName("name").?;
            try out.append(self.arena, try self.namespace(declared, text(self.source, name), prefix, try inner.toOwnedSlice(self.arena)));
        }
    }

    fn comment(self: *Reader, node: Node, pending: *Pending) Allocator.Error!void {
        const raw = text(self.source, node);
        const row = node.startPoint().row;
        if (std.mem.startsWith(u8, raw, "/**") and raw.len >= 5) {
            pending.* = .{ .block = true, .last_row = node.endPoint().row };
            var lines = std.mem.splitScalar(u8, raw[3 .. raw.len - 2], '\n');
            while (lines.next()) |line| {
                var content = std.mem.trimStart(u8, line, " \t");
                if (std.mem.startsWith(u8, content, "*")) content = content[1..];
                if (std.mem.startsWith(u8, content, " ")) content = content[1..];
                try pending.raw.appendSlice(self.arena, std.mem.trimEnd(u8, content, " \t\r"));
                try pending.raw.append(self.arena, '\n');
            }
            return;
        }
        if (!std.mem.startsWith(u8, raw, "///") or std.mem.startsWith(u8, raw, "////")) {
            pending.* = .{};
            return;
        }
        if (pending.block or (pending.raw.items.len != 0 and row != pending.last_row + 1)) pending.* = .{};
        var content = raw[3..];
        if (std.mem.startsWith(u8, content, " ")) content = content[1..];
        try pending.raw.appendSlice(self.arena, std.mem.trimEnd(u8, content, " \t\r"));
        try pending.raw.append(self.arena, '\n');
        pending.last_row = row;
    }

    fn qualified(self: *Reader, prefix: []const u8, name: []const u8) Allocator.Error![]const u8 {
        if (prefix.len == 0) return name;
        return std.mem.concat(self.arena, u8, &.{ prefix, ".", name });
    }

    fn place(self: *Reader, node: Node) Allocator.Error![]const ir.Location {
        return self.arena.dupe(ir.Location, &.{.{ .file = self.path, .line = node.startPoint().row + 1, .end_line = node.endPoint().row + 1 }});
    }

    fn named(self: *Reader, node: Node, name: []const u8, prefix: []const u8, ids: []const u8, suffix: []const u8) Allocator.Error!ir.Symbol {
        const path = try self.qualified(prefix, name);
        return .{
            .id = try std.mem.concat(self.arena, u8, &.{ self.root, "#", try self.qualified(ids, name), suffix }),
            .name = name,
            .qualified_name = path,
            .kind = .type,
            .locations = try self.place(node),
        };
    }

    fn namespace(self: *Reader, node: Node, name: []const u8, prefix: []const u8, members: []const ir.Symbol) Allocator.Error!ir.Symbol {
        var held = members;
        var rest = name;
        while (true) {
            const cut = std.mem.lastIndexOfScalar(u8, rest, '.');
            const last = std.mem.trim(u8, if (cut) |at| rest[at + 1 ..] else rest, " \t\n");
            const before = if (cut) |at| try self.qualified(prefix, try self.tidy(rest[0..at])) else prefix;
            var symbol = try self.named(node, last, before, before, "");
            symbol.kind = .namespace;
            symbol.signature = try std.mem.concat(self.arena, u8, &.{ "namespace ", symbol.qualified_name });
            symbol.members = held;
            if (cut == null) return symbol;
            held = try self.arena.dupe(ir.Symbol, &.{symbol});
            rest = rest[0..cut.?];
        }
    }

    fn container(self: *Reader, node: Node, form: []const u8, prefix: []const u8, owner: Owner, said: xml_comment.Comment) Allocator.Error!ir.Symbol {
        const name_node = node.childByFieldName("name") orelse return self.named(node, "", prefix, self.ids, "");
        const name = text(self.source, name_node);
        const type_params = try self.typeParams(node);
        const suffix = if (type_params.len == 0) "" else try std.fmt.allocPrint(self.arena, "`{d}", .{type_params.len});
        var symbol = try self.named(node, name, prefix, self.ids, suffix);
        symbol.form = form;
        symbol.type_params = type_params;
        try self.modifiers(node, &symbol, owner);
        const body = node.childByFieldName("body");
        symbol.signature = try self.head(node, if (body) |found| found.startByte() else node.endByte());
        var bases: std.ArrayList(ir.TypeRef) = .empty;
        var index: u32 = 0;
        while (index < node.namedChildCount()) : (index += 1) {
            const child = node.namedChild(index).?;
            if (is(child.kind(), "parameter_list")) symbol.params = try self.parameters(child);
            if (!is(child.kind(), "base_list")) continue;
            var at: u32 = 0;
            while (at < child.namedChildCount()) : (at += 1) {
                const base = child.namedChild(at).?;
                if (is(base.kind(), "argument_list")) continue;
                const written = if (is(base.kind(), "primary_constructor_base_type")) base.namedChild(0) orelse base else base;
                try bases.append(self.arena, .{ .text = try self.tidy(text(self.source, written)) });
            }
        }
        symbol.bases = try bases.toOwnedSlice(self.arena);
        if (body) |found| {
            var members: std.ArrayList(ir.Symbol) = .empty;
            const inside: Owner = if (is(form, "interface")) .interface else if (is(form, "enum")) .enumeration else .type;
            const ids_outside = self.ids;
            self.ids = symbol.id[self.root.len + 1 ..];
            try self.declarations(found, &members, symbol.qualified_name, inside);
            self.ids = ids_outside;
            symbol.members = try members.toOwnedSlice(self.arena);
        }
        try self.document(&symbol, said);
        if (is(form, "record") and symbol.params.len != 0) {
            var members: std.ArrayList(ir.Symbol) = .empty;
            for (symbol.params) |param| {
                if (param.type.text.len == 0) continue;
                const declared = for (symbol.members) |member| {
                    if (is(member.name, param.name)) break true;
                } else false;
                if (declared) continue;
                var positional = try self.named(node, param.name, symbol.qualified_name, symbol.id[self.root.len + 1 ..], "");
                positional.kind = .property;
                positional.form = "positional";
                positional.type = param.type;
                positional.signature = try std.mem.concat(self.arena, u8, &.{ param.type.text, " ", param.name });
                positional.doc = param.doc;
                try members.append(self.arena, positional);
            }
            try members.appendSlice(self.arena, symbol.members);
            symbol.members = try members.toOwnedSlice(self.arena);
        }
        return symbol;
    }

    fn callable(self: *Reader, node: Node, kind: ir.Kind, form: []const u8, prefix: []const u8, owner: Owner, said: xml_comment.Comment) Allocator.Error!ir.Symbol {
        const node_kind = node.kind();
        const returned = node.childByFieldName("returns") orelse node.childByFieldName("type");
        const name = if (node.childByFieldName("name")) |found|
            if (is(form, "destructor")) try std.mem.concat(self.arena, u8, &.{ "~", text(self.source, found) }) else text(self.source, found)
        else if (is(node_kind, "operator_declaration"))
            try std.mem.concat(self.arena, u8, &.{ "operator ", if (node.childByFieldName("operator")) |operator| text(self.source, operator) else "" })
        else
            try std.mem.concat(self.arena, u8, &.{ "operator ", if (returned) |written| try self.tidy(text(self.source, written)) else "" });
        const params = if (node.childByFieldName("parameters")) |list| try self.parameters(list) else &.{};
        const type_params = try self.typeParams(node);
        var suffix: std.ArrayList(u8) = .empty;
        if (type_params.len != 0) try suffix.print(self.arena, "`{d}", .{type_params.len});
        if (kind == .function) {
            try suffix.append(self.arena, '(');
            for (params, 0..) |param, index| {
                if (index != 0) try suffix.append(self.arena, ',');
                try suffix.appendSlice(self.arena, param.type.text);
            }
            try suffix.append(self.arena, ')');
        }
        var symbol = try self.named(node, name, prefix, self.ids, suffix.items);
        symbol.kind = kind;
        symbol.form = form;
        symbol.params = params;
        symbol.type_params = type_params;
        if (returned) |written| symbol.type = .{ .text = try self.tidy(text(self.source, written)) };
        try self.modifiers(node, &symbol, owner);
        var end = if (node.childByFieldName("body")) |body| body.startByte() else node.endByte();
        var index: u32 = 0;
        while (index < node.namedChildCount()) : (index += 1) {
            const child = node.namedChild(index).?;
            if (is(child.kind(), "constructor_initializer")) end = @min(end, child.startByte());
        }
        symbol.signature = try self.head(node, end);
        try self.document(&symbol, said);
        return symbol;
    }

    fn property(self: *Reader, node: Node, kind: ir.Kind, form: []const u8, prefix: []const u8, owner: Owner, said: xml_comment.Comment) Allocator.Error!ir.Symbol {
        const name = if (node.childByFieldName("name")) |found| text(self.source, found) else "this[]";
        const params = if (node.childByFieldName("parameters")) |list| try self.parameters(list) else &.{};
        var suffix: std.ArrayList(u8) = .empty;
        if (params.len != 0) {
            try suffix.append(self.arena, '(');
            for (params, 0..) |param, index| {
                if (index != 0) try suffix.append(self.arena, ',');
                try suffix.appendSlice(self.arena, param.type.text);
            }
            try suffix.append(self.arena, ')');
        }
        var symbol = try self.named(node, name, prefix, self.ids, suffix.items);
        symbol.kind = kind;
        symbol.form = form;
        symbol.params = params;
        if (node.childByFieldName("type")) |written| symbol.type = .{ .text = try self.tidy(text(self.source, written)) };
        try self.modifiers(node, &symbol, owner);
        const accessors = node.childByFieldName("accessors");
        const value = node.childByFieldName("value");
        const end = if (accessors) |list| list.startByte() else if (value) |written| written.startByte() else node.endByte();
        var signature: std.ArrayList(u8) = .empty;
        try signature.appendSlice(self.arena, std.mem.trimEnd(u8, try self.head(node, end), " ="));
        if (accessors) |list| {
            try signature.appendSlice(self.arena, " {");
            var index: u32 = 0;
            while (index < list.namedChildCount()) : (index += 1) {
                const accessor = list.namedChild(index).?;
                if (!is(accessor.kind(), "accessor_declaration")) continue;
                const stop = if (accessor.childByFieldName("body")) |body| body.startByte() else accessor.endByte();
                try signature.print(self.arena, " {s};", .{std.mem.trimEnd(u8, try self.head(accessor, stop), " ;")});
            }
            try signature.appendSlice(self.arena, " }");
        } else if (value != null and kind == .property) {
            try signature.appendSlice(self.arena, " { get; }");
        }
        symbol.signature = try signature.toOwnedSlice(self.arena);
        try self.document(&symbol, said);
        return symbol;
    }

    fn fields(self: *Reader, node: Node, out: *std.ArrayList(ir.Symbol), event: bool, prefix: []const u8, owner: Owner, said: xml_comment.Comment) Allocator.Error!void {
        var index: u32 = 0;
        while (index < node.namedChildCount()) : (index += 1) {
            const declaration = node.namedChild(index).?;
            if (!is(declaration.kind(), "variable_declaration")) continue;
            const written = declaration.childByFieldName("type") orelse continue;
            const head_text = try self.head(node, written.endByte());
            var at: u32 = 0;
            while (at < declaration.namedChildCount()) : (at += 1) {
                const declarator = declaration.namedChild(at).?;
                if (!is(declarator.kind(), "variable_declarator")) continue;
                const name_node = declarator.childByFieldName("name") orelse continue;
                if (name_node.startByte() == name_node.endByte()) continue;
                var symbol = try self.named(node, text(self.source, name_node), prefix, self.ids, "");
                try self.modifiers(node, &symbol, owner);
                const constant = for (symbol.modifiers) |modifier| {
                    if (is(modifier, "const")) break true;
                } else false;
                symbol.kind = if (event) .event else if (constant) .constant else .field;
                symbol.type = .{ .text = try self.tidy(text(self.source, written)) };
                symbol.signature = try std.mem.concat(self.arena, u8, &.{ head_text, " ", symbol.name });
                const after = self.source[name_node.endByte()..declarator.endByte()];
                if (std.mem.indexOfScalar(u8, after, '=')) |equals| symbol.value = try self.tidy(after[equals + 1 ..]);
                try self.document(&symbol, said);
                try out.append(self.arena, symbol);
            }
        }
    }

    fn parameters(self: *Reader, list: Node) Allocator.Error![]const ir.Param {
        var out: std.ArrayList(ir.Param) = .empty;
        var index: u32 = 0;
        while (index < list.namedChildCount()) : (index += 1) {
            const child = list.namedChild(index).?;
            if (!is(child.kind(), "parameter")) continue;
            const name = child.childByFieldName("name") orelse continue;
            const written = child.childByFieldName("type");
            const from = startOf(child);
            const type_end = if (written) |found| found.endByte() else name.startByte();
            try out.append(self.arena, .{
                .name = text(self.source, name),
                .type = .{ .text = try self.tidy(self.source[@min(from, type_end)..type_end]) },
            });
        }
        return out.toOwnedSlice(self.arena);
    }

    fn typeParams(self: *Reader, node: Node) Allocator.Error![]const ir.TypeParam {
        var out: std.ArrayList(ir.TypeParam) = .empty;
        var index: u32 = 0;
        while (index < node.namedChildCount()) : (index += 1) {
            const child = node.namedChild(index).?;
            if (is(child.kind(), "type_parameter_list")) {
                var at: u32 = 0;
                while (at < child.namedChildCount()) : (at += 1) {
                    const param = child.namedChild(at).?;
                    if (!is(param.kind(), "type_parameter")) continue;
                    const name = param.childByFieldName("name") orelse continue;
                    try out.append(self.arena, .{ .name = text(self.source, name) });
                }
            } else if (is(child.kind(), "type_parameter_constraints_clause")) {
                const clause = text(self.source, child);
                const colon = std.mem.indexOfScalar(u8, clause, ':') orelse continue;
                const constrained = std.mem.trim(u8, clause[@min(clause.len, "where".len)..colon], " \t\n");
                for (out.items) |*param| {
                    if (is(param.name, constrained)) param.constraint = try self.tidy(clause[colon + 1 ..]);
                }
            }
        }
        return out.toOwnedSlice(self.arena);
    }

    fn startOf(node: Node) usize {
        var index: u32 = 0;
        while (index < node.childCount()) : (index += 1) {
            const child = node.child(index).?;
            const kind = child.kind();
            if (is(kind, "attribute_list") or is(kind, "comment") or std.mem.startsWith(u8, kind, "preproc_")) continue;
            return child.startByte();
        }
        return node.startByte();
    }

    fn head(self: *Reader, node: Node, end: usize) Allocator.Error![]const u8 {
        const from = startOf(node);
        if (end <= from) return "";
        return self.tidy(std.mem.trimEnd(u8, self.source[from..end], " \t\r\n;"));
    }

    fn modifiers(self: *Reader, node: Node, symbol: *ir.Symbol, owner: Owner) Allocator.Error!void {
        var words: std.ArrayList([]const u8) = .empty;
        var public = false;
        var protected = false;
        var internal = false;
        var private = false;
        var index: u32 = 0;
        while (index < node.namedChildCount()) : (index += 1) {
            const child = node.namedChild(index).?;
            if (!is(child.kind(), "modifier")) continue;
            const word = text(self.source, child);
            if (is(word, "public")) public = true else if (is(word, "protected")) protected = true else if (is(word, "internal")) internal = true else if (is(word, "private")) private = true else try words.append(self.arena, word);
        }
        symbol.modifiers = try words.toOwnedSlice(self.arena);
        symbol.visibility = if (public) .public else if (protected) .protected else if (internal) .internal else if (private) .private else switch (owner) {
            .namespace => .internal,
            .interface, .enumeration => .public,
            .type => .private,
        };
    }

    fn document(self: *Reader, symbol: *ir.Symbol, said: xml_comment.Comment) Allocator.Error!void {
        symbol.doc = .{ .blocks = said.blocks };
        symbol.returns = said.returns;
        symbol.examples = said.examples;
        symbol.inherits = said.inherits;
        if (said.raises.len != 0) {
            const raises = try self.arena.alloc(ir.Raised, said.raises.len);
            for (raises, said.raises) |*raised, entry| raised.* = .{ .type = .{ .text = entry.name }, .doc = entry.text };
            symbol.raises = raises;
        }
        if (said.params.len != 0) {
            var listed: std.ArrayList(ir.Param) = .empty;
            try listed.appendSlice(self.arena, symbol.params);
            for (said.params) |entry| {
                const known = for (listed.items) |*param| {
                    if (is(param.name, entry.name)) break param;
                } else null;
                if (known) |param| param.doc = entry.text else try listed.append(self.arena, .{ .name = entry.name, .doc = entry.text });
            }
            symbol.params = try listed.toOwnedSlice(self.arena);
        }
        if (said.type_params.len != 0) {
            const listed = try self.arena.dupe(ir.TypeParam, symbol.type_params);
            for (said.type_params) |entry| {
                for (listed) |*param| {
                    if (is(param.name, entry.name)) param.doc = entry.text;
                }
            }
            symbol.type_params = listed;
        }
    }

    fn tidy(self: *Reader, written: []const u8) Allocator.Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        var spaced = true;
        for (written) |ch| {
            if (std.ascii.isWhitespace(ch)) {
                if (!spaced) try out.append(self.arena, ' ');
                spaced = true;
            } else {
                try out.append(self.arena, ch);
                spaced = false;
            }
        }
        return std.mem.trimEnd(u8, try out.toOwnedSlice(self.arena), " ");
    }
};

fn memberNamed(list: []const ir.Symbol, name: []const u8) !ir.Symbol {
    for (list) |symbol| {
        if (std.mem.eql(u8, symbol.name, name)) return symbol;
    }
    return error.NoSuchMember;
}

test "a namespace, a class, its members and what it derives from are read" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const unit = try read(arena.allocator(), "Pool.cs",
        \\using System;
        \\namespace Ke.Tasks;
        \\
        \\/// <summary>Runs tasks on <see cref="Worker"/> threads.</summary>
        \\/// <typeparam name="T">What a task yields.</typeparam>
        \\[Serializable]
        \\public sealed class Pool<T> : Base, IDisposable where T : class, new()
        \\{
        \\    private const int Limit = 4;
        \\    internal int first, second;
        \\
        \\    /// <summary>Starts with <paramref name="count"/> workers.</summary>
        \\    /// <param name="count">How many.</param>
        \\    public Pool(int count) : base(count) { }
        \\
        \\    /// <summary>How many workers there are.</summary>
        \\    public int Count { get; private set; }
        \\
        \\    public T this[int index] => items[index];
        \\
        \\    /// <summary>Runs one task.</summary>
        \\    /// <returns>What it yielded.</returns>
        \\    /// <exception cref="InvalidOperationException">When stopped.</exception>
        \\    public static async Task<T> Run(Func<T> body, int priority = 0)
        \\    {
        \\        return body();
        \\    }
        \\
        \\    public void Run() { }
        \\    public event Action? Stopped;
        \\    public static Pool<T> operator +(Pool<T> a, Pool<T> b) => a;
        \\    void IDisposable.Dispose() { }
        \\}
        \\
        \\public enum Mode { Idle, Busy = 2 }
        \\public delegate void Done(int code);
        \\public interface IWorker { void Work(); }
    );
    try std.testing.expectEqualStrings("csharp", unit.file.language);
    const ke = unit.symbol.members[0];
    try std.testing.expectEqual(ir.Kind.namespace, ke.kind);
    try std.testing.expectEqualStrings("Ke", ke.name);
    const tasks = ke.members[0];
    try std.testing.expectEqualStrings("Ke.Tasks", tasks.qualified_name);
    try std.testing.expectEqual(4, tasks.members.len);

    const pool = tasks.members[0];
    try std.testing.expectEqualStrings("csharp:Pool.cs#Ke.Tasks.Pool`1", pool.id);
    try std.testing.expectEqualStrings("class", pool.form);
    try std.testing.expectEqualStrings("public sealed class Pool<T> : Base, IDisposable where T : class, new()", pool.signature);
    try std.testing.expectEqualStrings("sealed", pool.modifiers[0]);
    try std.testing.expectEqual(2, pool.bases.len);
    try std.testing.expectEqualStrings("IDisposable", pool.bases[1].text);
    try std.testing.expectEqualStrings("class, new()", pool.type_params[0].constraint);
    try std.testing.expect(!pool.type_params[0].doc.isEmpty());
    try std.testing.expectEqualStrings("Worker", pool.doc.blocks[0].paragraph[1].ref.text);
    try std.testing.expectEqual(11, pool.members.len);

    const limit = (try memberNamed(pool.members, "Limit"));
    try std.testing.expectEqual(ir.Kind.constant, limit.kind);
    try std.testing.expectEqual(ir.Visibility.private, limit.visibility);
    try std.testing.expectEqualStrings("4", limit.value);
    try std.testing.expectEqualStrings("internal int second", (try memberNamed(pool.members, "second")).signature);

    const constructor = (try memberNamed(pool.members, "Pool"));
    try std.testing.expectEqualStrings("constructor", constructor.form);
    try std.testing.expectEqualStrings("public Pool(int count)", constructor.signature);
    try std.testing.expect(!constructor.params[0].doc.isEmpty());

    const count = (try memberNamed(pool.members, "Count"));
    try std.testing.expectEqual(ir.Kind.property, count.kind);
    try std.testing.expectEqualStrings("public int Count { get; private set; }", count.signature);
    const indexer = (try memberNamed(pool.members, "this[]"));
    try std.testing.expectEqualStrings("public T this[int index] { get; }", indexer.signature);
    try std.testing.expectEqualStrings("csharp:Pool.cs#Ke.Tasks.Pool`1.this[](int)", indexer.id);

    const run = (try memberNamed(pool.members, "Run"));
    try std.testing.expectEqualStrings("csharp:Pool.cs#Ke.Tasks.Pool`1.Run(Func<T>,int)", run.id);
    try std.testing.expectEqualStrings("public static async Task<T> Run(Func<T> body, int priority = 0)", run.signature);
    try std.testing.expectEqualStrings("Task<T>", run.type.text);
    try std.testing.expectEqualStrings("priority", run.params[1].name);
    try std.testing.expectEqualStrings("InvalidOperationException", run.raises[0].type.text);
    try std.testing.expect(!run.returns.isEmpty());
    try std.testing.expectEqualStrings("csharp:Pool.cs#Ke.Tasks.Pool`1.Run()", pool.members[7].id);
    try std.testing.expectEqual(ir.Kind.event, (try memberNamed(pool.members, "Stopped")).kind);
    try std.testing.expectEqualStrings("operator", (try memberNamed(pool.members, "operator +")).form);
    try std.testing.expectEqual(ir.Visibility.private, (try memberNamed(pool.members, "Dispose")).visibility);

    const mode = tasks.members[1];
    try std.testing.expectEqualStrings("enum", mode.form);
    try std.testing.expectEqual(ir.Kind.enumerator, mode.members[1].kind);
    try std.testing.expectEqualStrings("2", mode.members[1].value);
    try std.testing.expectEqualStrings("delegate", tasks.members[2].form);
    try std.testing.expectEqualStrings("code", tasks.members[2].params[0].name);
    try std.testing.expectEqual(ir.Visibility.public, tasks.members[3].members[0].visibility);
}

test "a type declared in parts in several files becomes one symbol in the file of its first part" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var units = [_]ir.Unit{
        try read(allocator, "A.cs",
            \\namespace Ke {
            \\    public partial class Pool : Base { public void Start() { } }
            \\}
        ),
        try read(allocator, "B.cs",
            \\namespace Ke {
            \\    /// <summary>Runs tasks.</summary>
            \\    public partial class Pool : IDisposable { public void Stop() { } }
            \\    public class Other { }
            \\}
        ),
    };
    try join(allocator, &units);
    const pool = units[0].symbol.members[0].members[0];
    try std.testing.expectEqual(2, pool.members.len);
    try std.testing.expectEqualStrings("csharp:A.cs#Ke.Pool.Stop()", pool.members[1].id);
    try std.testing.expectEqual(2, pool.locations.len);
    try std.testing.expectEqualStrings("B.cs", pool.locations[1].file);
    try std.testing.expectEqual(2, pool.bases.len);
    try std.testing.expect(!pool.doc.isEmpty());
    try std.testing.expectEqual(1, units[1].symbol.members[0].members.len);
    try std.testing.expectEqualStrings("Other", units[1].symbol.members[0].members[0].name);
}

test "the parameters a record is declared with are properties of it" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const unit = try read(arena.allocator(), "Slot.cs",
        \\/// <param name="Name">What it is called.</param>
        \\public record Slot(string Name, int Size)
        \\{
        \\    /// <summary>Twice <see cref="Size"/>.</summary>
        \\    public int Double => Size * 2;
        \\    public int Size { get; } = Size;
        \\}
    );
    const slot = unit.symbol.members[0];
    try std.testing.expectEqual(3, slot.members.len);
    try std.testing.expectEqualStrings("Name", slot.members[0].name);
    try std.testing.expectEqual(ir.Kind.property, slot.members[0].kind);
    try std.testing.expectEqualStrings("string Name", slot.members[0].signature);
    try std.testing.expectEqualStrings("csharp:Slot.cs#Slot.Name", slot.members[0].id);
    try std.testing.expect(!slot.members[0].doc.isEmpty());
    try std.testing.expectEqualStrings("Size", slot.members[2].name);
}
