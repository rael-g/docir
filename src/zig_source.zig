//! Reads a Zig source file through the compiler's own parser.
//!
//! The file becomes a symbol of kind `ir.Kind.module`, documented by the `//!` block that
//! opens it, and every declaration of the file becomes a member of it, with the `///` block
//! above it when there is one. A container is walked recursively, so a method is a member
//! of its container. The members of an error set are read like the fields of a container.
//! A function that returns a container written in its own body, the way a generic type is
//! declared, is read as that container: what the returned container declares becomes the
//! members of the function.
//!
//! Doc comments are Markdown, read by `markdown_text`.
//!
//! A `test` named by a string contributes its name to `ir.Symbol.verified` of the file. A
//! `test` named after a declaration contributes its body as an example of that declaration
//! when the two sit in the same container.
//!
//! Every `@import` and `@cInclude` of the file is listed as an import, wherever it is written.

const std = @import("std");
const ir = @import("ir.zig");
const markdown_text = @import("markdown_text.zig");

const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;

/// The language name this reader gives its files, and the prefix of its identifiers.
pub const language = "zig";

/// Extracts one Zig file. `path` becomes the path of the file in the document. The symbol
/// of the file is identified by `zig:` followed by that path, and a declaration by that,
/// a `#`, and its name qualified by the containers around it. Fails with
/// `error.InvalidZigSource` when the file does not parse.
pub fn read(arena: Allocator, path: []const u8, source: [:0]const u8) !ir.Unit {
    const tree = try Ast.parse(arena, source, .zig);
    if (tree.errors.len != 0) return error.InvalidZigSource;

    var line_starts: std.ArrayList(usize) = .empty;
    try line_starts.append(arena, 0);
    for (source, 0..) |ch, offset| {
        if (ch == '\n') try line_starts.append(arena, offset + 1);
    }

    var reader: Reader = .{ .arena = arena, .tree = &tree, .path = path, .line_starts = line_starts.items };
    const members = try reader.members(tree.rootDecls(), "", false);
    return .{
        .file = .{ .path = path, .language = language, .imports = try reader.imports() },
        .symbol = .{
            .id = try std.mem.concat(arena, u8, &.{ language, ":", path }),
            .name = std.fs.path.stem(path),
            .qualified_name = path,
            .kind = .module,
            .locations = try arena.dupe(ir.Location, &.{.{ .file = path, .line = 1, .end_line = @intCast(line_starts.items.len) }}),
            .doc = try reader.containerDoc(),
            .verified = try reader.behaviours.toOwnedSlice(arena),
            .members = members,
        },
    };
}

const import_builtins = std.StaticStringMap(ir.ImportKind).initComptime(.{
    .{ "@import", .file },
    .{ "@cInclude", .include },
});

const Reader = struct {
    arena: Allocator,
    tree: *const Ast,
    path: []const u8,
    line_starts: []const usize,
    behaviours: std.ArrayList([]const u8) = .empty,

    fn qualify(self: *Reader, prefix: []const u8, name: []const u8) Allocator.Error![]const u8 {
        if (prefix.len == 0) return name;
        return std.mem.concat(self.arena, u8, &.{ prefix, ".", name });
    }

    fn idOf(self: *Reader, qualified: []const u8) Allocator.Error![]const u8 {
        return std.mem.concat(self.arena, u8, &.{ language, ":", self.path, "#", qualified });
    }

    fn lineOf(self: *Reader, token: Ast.TokenIndex) u32 {
        const offset = self.tree.tokenStart(token);
        var low: usize = 0;
        var high: usize = self.line_starts.len;
        while (high - low > 1) {
            const middle = low + (high - low) / 2;
            if (self.line_starts[middle] <= offset) low = middle else high = middle;
        }
        return @intCast(low + 1);
    }

    fn span(self: *Reader, first: Ast.TokenIndex, last: Ast.TokenIndex) Allocator.Error![]const ir.Location {
        return self.arena.dupe(ir.Location, &.{.{ .file = self.path, .line = self.lineOf(first), .end_line = self.lineOf(last) }});
    }

    fn members(self: *Reader, nodes: []const Ast.Node.Index, prefix: []const u8, enumerated: bool) Allocator.Error![]const ir.Symbol {
        const tree = self.tree;
        var out: std.ArrayList(ir.Symbol) = .empty;
        for (nodes) |node| {
            if (tree.nodeTag(node) == .test_decl) {
                try self.behaviour(node);
                continue;
            }
            const examples = try self.examplesOf(nodes, node);
            const locations = try self.span(tree.firstToken(node), tree.lastToken(node));

            var fn_buffer: [1]Ast.Node.Index = undefined;
            if (tree.fullFnProto(&fn_buffer, node)) |proto| {
                const name = tree.tokenSlice(proto.name_token orelse continue);
                const qualified = try self.qualify(prefix, name);
                const is_definition = tree.nodeTag(node) == .fn_decl;
                const returned = if (is_definition) try self.returnedMembers(tree.nodeData(node).node_and_node[1], qualified) else null;
                try out.append(self.arena, .{
                    .id = try self.idOf(qualified),
                    .name = name,
                    .qualified_name = qualified,
                    .kind = if (returned == null) .function else .type,
                    .form = if (returned == null) "" else "type function",
                    .visibility = if (proto.visib_token != null) .public else .private,
                    .locations = locations,
                    .signature = tree.getNodeSource(if (is_definition) tree.nodeData(node).node_and_node[0] else node),
                    .doc = try self.docBefore(proto.firstToken()),
                    .params = try self.params(proto),
                    .type = .{ .text = if (proto.ast.return_type.unwrap()) |return_type| tree.getNodeSource(return_type) else "" },
                    .examples = examples,
                    .members = returned orelse &.{},
                });
                continue;
            }
            if (tree.fullVarDecl(node)) |decl| {
                var entry = try self.variable(decl, node, prefix);
                entry.locations = locations;
                entry.examples = examples;
                try out.append(self.arena, entry);
                continue;
            }
            if (tree.fullContainerField(node)) |field| {
                const name = tree.tokenSlice(field.ast.main_token);
                const qualified = try self.qualify(prefix, name);
                try out.append(self.arena, .{
                    .id = try self.idOf(qualified),
                    .name = name,
                    .qualified_name = qualified,
                    .kind = if (enumerated) .enumerator else .field,
                    .locations = locations,
                    .signature = tree.getNodeSource(node),
                    .doc = try self.docBefore(field.firstToken()),
                    .type = .{ .text = if (field.ast.type_expr.unwrap()) |type_expr| tree.getNodeSource(type_expr) else "" },
                    .value = if (field.ast.value_expr.unwrap()) |value_expr| tree.getNodeSource(value_expr) else "",
                });
            }
        }
        return out.toOwnedSlice(self.arena);
    }

    fn variable(self: *Reader, decl: Ast.full.VarDecl, node: Ast.Node.Index, prefix: []const u8) Allocator.Error!ir.Symbol {
        const tree = self.tree;
        const first = decl.firstToken();
        const start = tree.tokenStart(first);
        const name = tree.tokenSlice(decl.ast.mut_token + 1);
        const qualified = try self.qualify(prefix, name);
        var entry: ir.Symbol = .{
            .id = try self.idOf(qualified),
            .name = name,
            .qualified_name = qualified,
            .kind = if (tree.tokenTag(decl.ast.mut_token) == .keyword_var) .variable else .constant,
            .visibility = if (decl.visib_token != null) .public else .private,
            .signature = tree.getNodeSource(node),
            .doc = try self.docBefore(first),
            .type = .{ .text = if (decl.ast.type_node.unwrap()) |type_node| tree.getNodeSource(type_node) else "" },
        };
        const init_node = decl.ast.init_node.unwrap() orelse return entry;
        const init_source = tree.getNodeSource(init_node);

        var container_buffer: [2]Ast.Node.Index = undefined;
        if (tree.fullContainerDecl(&container_buffer, init_node)) |container| {
            const keyword = container.ast.main_token;
            entry.kind = .type;
            entry.form = tree.tokenSlice(keyword);
            entry.signature = tree.source[start .. tree.tokenStart(keyword) + tree.tokenSlice(keyword).len];
            entry.members = try self.members(container.ast.members, qualified, tree.tokenTag(keyword) == .keyword_enum);
        } else if (tree.nodeTag(init_node) == .error_set_decl) {
            const braces = tree.nodeData(init_node).token_and_token;
            entry.kind = .type;
            entry.form = "error set";
            entry.signature = std.mem.trimEnd(u8, tree.source[start..tree.tokenStart(braces[0])], " ");
            entry.members = try self.errors(braces[0], braces[1], qualified);
        } else if (importedName(init_source)) |imported| {
            entry.kind = .alias;
            entry.form = "import";
            entry.value = imported;
        } else if (std.mem.startsWith(u8, init_source, "@cImport(")) {
            entry.kind = .alias;
            entry.form = "import";
            entry.signature = std.mem.trimEnd(u8, tree.source[start..tree.tokenStart(tree.firstToken(init_node))], " =\t\r\n");
        } else if (isPath(init_source)) {
            entry.kind = .alias;
            entry.value = init_source;
        } else if (std.mem.indexOfScalar(u8, init_source, '\n') == null) {
            entry.value = init_source;
        } else {
            entry.signature = std.mem.trimEnd(u8, tree.source[start..tree.tokenStart(tree.firstToken(init_node))], " =\t\r\n");
        }
        return entry;
    }

    fn params(self: *Reader, proto: Ast.full.FnProto) Allocator.Error![]const ir.Param {
        const tree = self.tree;
        var out: std.ArrayList(ir.Param) = .empty;
        var iterator = proto.iterate(tree);
        while (iterator.next()) |param| {
            var doc: ir.Text = .{};
            if (param.first_doc_comment) |first| {
                var end = first;
                while (tree.tokenTag(end) == .doc_comment) end += 1;
                doc = try self.text(first, end);
            }
            try out.append(self.arena, .{
                .name = if (param.name_token) |token| tree.tokenSlice(token) else "",
                .type = .{ .text = if (param.type_expr) |type_expr|
                    tree.getNodeSource(type_expr)
                else if (param.anytype_ellipsis3) |token|
                    tree.tokenSlice(token)
                else
                    "" },
                .doc = doc,
            });
        }
        return out.toOwnedSlice(self.arena);
    }

    fn errors(self: *Reader, open: Ast.TokenIndex, close: Ast.TokenIndex, prefix: []const u8) Allocator.Error![]const ir.Symbol {
        const tree = self.tree;
        var out: std.ArrayList(ir.Symbol) = .empty;
        var token = open + 1;
        while (token < close) : (token += 1) {
            if (tree.tokenTag(token) != .identifier) continue;
            const name = tree.tokenSlice(token);
            const qualified = try self.qualify(prefix, name);
            try out.append(self.arena, .{
                .id = try self.idOf(qualified),
                .name = name,
                .qualified_name = qualified,
                .kind = .enumerator,
                .form = "error",
                .locations = try self.span(token, token),
                .signature = name,
                .doc = try self.docBefore(token),
            });
        }
        return out.toOwnedSlice(self.arena);
    }

    fn examplesOf(self: *Reader, siblings: []const Ast.Node.Index, node: Ast.Node.Index) Allocator.Error![]const ir.Example {
        const tree = self.tree;
        var fn_buffer: [1]Ast.Node.Index = undefined;
        const name_token = if (tree.fullFnProto(&fn_buffer, node)) |proto|
            proto.name_token orelse return &.{}
        else if (tree.fullVarDecl(node)) |decl|
            decl.ast.mut_token + 1
        else
            return &.{};
        const name = tree.tokenSlice(name_token);

        var out: std.ArrayList(ir.Example) = .empty;
        for (siblings) |sibling| {
            if (tree.nodeTag(sibling) != .test_decl) continue;
            const data = tree.nodeData(sibling).opt_token_and_node;
            const test_name = data[0].unwrap() orelse continue;
            if (tree.tokenTag(test_name) != .identifier or !std.mem.eql(u8, tree.tokenSlice(test_name), name)) continue;
            try out.append(self.arena, .{ .language = "zig", .code = try self.blockBody(data[1]) });
        }
        return out.toOwnedSlice(self.arena);
    }

    fn blockBody(self: *Reader, block: Ast.Node.Index) Allocator.Error![]const u8 {
        const source = self.tree.getNodeSource(block);
        const inside = std.mem.trim(u8, source[1 .. source.len - 1], "\r\n");
        var indent: usize = std.math.maxInt(usize);
        var lines = std.mem.splitScalar(u8, inside, '\n');
        while (lines.next()) |line| {
            if (std.mem.trim(u8, line, " \t\r").len == 0) continue;
            indent = @min(indent, line.len - std.mem.trimStart(u8, line, " \t").len);
        }
        var out: std.ArrayList(u8) = .empty;
        lines.reset();
        while (lines.next()) |line| {
            if (out.items.len != 0) try out.append(self.arena, '\n');
            const kept = std.mem.trimEnd(u8, line, " \t\r");
            if (kept.len > indent) try out.appendSlice(self.arena, kept[indent..]);
        }
        return std.mem.trim(u8, try out.toOwnedSlice(self.arena), " \t");
    }

    fn returnedMembers(self: *Reader, body: Ast.Node.Index, prefix: []const u8) Allocator.Error!?[]const ir.Symbol {
        const tree = self.tree;
        var block_buffer: [2]Ast.Node.Index = undefined;
        const statements = tree.blockStatements(&block_buffer, body) orelse return null;
        for (statements) |statement| {
            if (tree.nodeTag(statement) != .@"return") continue;
            const returned = tree.nodeData(statement).opt_node.unwrap() orelse continue;
            var container_buffer: [2]Ast.Node.Index = undefined;
            const container = tree.fullContainerDecl(&container_buffer, returned) orelse continue;
            return try self.members(container.ast.members, prefix, tree.tokenTag(container.ast.main_token) == .keyword_enum);
        }
        return null;
    }

    fn behaviour(self: *Reader, node: Ast.Node.Index) Allocator.Error!void {
        const tree = self.tree;
        const name_token = tree.nodeData(node).opt_token_and_node[0].unwrap() orelse return;
        if (tree.tokenTag(name_token) != .string_literal) return;
        try self.behaviours.append(self.arena, try self.stringOf(name_token));
    }

    fn stringOf(self: *Reader, token: Ast.TokenIndex) Allocator.Error![]const u8 {
        const literal = self.tree.tokenSlice(token);
        return std.zig.string_literal.parseAlloc(self.arena, literal) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidLiteral => std.mem.trim(u8, literal, "\""),
        };
    }

    fn imports(self: *Reader) Allocator.Error![]const ir.Import {
        const tree = self.tree;
        var out: std.ArrayList(ir.Import) = .empty;
        var token: Ast.TokenIndex = 0;
        next: while (token + 2 < tree.tokens.len) : (token += 1) {
            if (tree.tokenTag(token) != .builtin or tree.tokenTag(token + 2) != .string_literal) continue;
            const builtin_kind = import_builtins.get(tree.tokenSlice(token)) orelse continue;
            const name = try self.stringOf(token + 2);
            const kind: ir.ImportKind = if (builtin_kind == .file and std.fs.path.extension(name).len == 0) .module else builtin_kind;
            for (out.items) |seen| {
                if (seen.kind == kind and std.mem.eql(u8, seen.name, name)) continue :next;
            }
            try out.append(self.arena, .{ .name = name, .kind = kind });
        }
        return out.toOwnedSlice(self.arena);
    }

    fn containerDoc(self: *Reader) Allocator.Error!ir.Text {
        const tree = self.tree;
        var end: Ast.TokenIndex = 0;
        while (end < tree.tokens.len and tree.tokenTag(end) == .container_doc_comment) end += 1;
        return self.text(0, end);
    }

    fn docBefore(self: *Reader, token: Ast.TokenIndex) Allocator.Error!ir.Text {
        var first = token;
        while (first > 0 and self.tree.tokenTag(first - 1) == .doc_comment) first -= 1;
        return self.text(first, token);
    }

    fn text(self: *Reader, first: Ast.TokenIndex, end: Ast.TokenIndex) Allocator.Error!ir.Text {
        return markdown_text.parse(self.arena, try self.joinLines(first, end));
    }

    fn joinLines(self: *Reader, first: Ast.TokenIndex, end: Ast.TokenIndex) Allocator.Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        var token = first;
        while (token < end) : (token += 1) {
            const line = self.tree.tokenSlice(token)[3..];
            if (out.items.len != 0) try out.append(self.arena, '\n');
            try out.appendSlice(self.arena, std.mem.trimEnd(u8, if (std.mem.startsWith(u8, line, " ")) line[1..] else line, " \t\r"));
        }
        return std.mem.trim(u8, try out.toOwnedSlice(self.arena), "\n");
    }
};

fn importedName(init_source: []const u8) ?[]const u8 {
    const open = "@import(\"";
    if (!std.mem.startsWith(u8, init_source, open) or !std.mem.endsWith(u8, init_source, "\")")) return null;
    const name = init_source[open.len .. init_source.len - 2];
    return if (std.mem.indexOfScalar(u8, name, '"') == null) name else null;
}

fn isPath(expression: []const u8) bool {
    var rest = expression;
    const open = "@import(\"";
    if (std.mem.startsWith(u8, rest, open)) {
        const close = std.mem.indexOf(u8, rest, "\").") orelse return false;
        rest = rest[close + 3 ..];
    }
    if (rest.len == 0) return false;
    var parts = std.mem.splitScalar(u8, rest, '.');
    while (parts.next()) |part| {
        if (part.len == 0 or std.ascii.isDigit(part[0])) return false;
        for (part) |ch| {
            if (!std.ascii.isAlphanumeric(ch) and ch != '_') return false;
        }
    }
    return std.zig.Token.getKeyword(rest) == null and !std.zig.primitives.isPrimitive(rest);
}

fn readForTest(arena: Allocator, source: [:0]const u8) !ir.Symbol {
    return (try read(arena, "sample.zig", source)).symbol;
}

fn find(symbols: []const ir.Symbol, name: []const u8) !ir.Symbol {
    for (symbols) |symbol| {
        if (std.mem.eql(u8, symbol.name, name)) return symbol;
    }
    return error.SymbolNotFound;
}

fn plain(arena: Allocator, text: ir.Text) ![]const u8 {
    return ir.plainText(arena, text);
}

test "the file is a module documented by the block that opens it" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const unit = try read(arena.allocator(), "src/sample.zig",
        \\//! First line with `x`.
        \\//!
        \\//! Second paragraph.
        \\const x = 1;
    );
    try std.testing.expectEqualStrings("src/sample.zig", unit.file.path);
    try std.testing.expectEqualStrings("zig", unit.file.language);
    try std.testing.expectEqualStrings("zig:src/sample.zig", unit.symbol.id);
    try std.testing.expectEqualStrings("sample", unit.symbol.name);
    try std.testing.expectEqual(ir.Kind.module, unit.symbol.kind);
    try std.testing.expectEqual(2, unit.symbol.doc.blocks.len);
    try std.testing.expectEqualDeep(ir.Inline{ .ref = .{ .text = "x" } }, unit.symbol.doc.blocks[0].paragraph[1]);
    try std.testing.expectEqualStrings("First line with x.\n\nSecond paragraph.", try plain(arena.allocator(), unit.symbol.doc));
}

test "a function carries its prototype, parameters, return type, visibility and lines" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const file = try readForTest(arena.allocator(),
        \\/// Adds two numbers.
        \\pub fn add(
        \\    /// The left side.
        \\    a: u32,
        \\    b: anytype,
        \\) u32 {
        \\    return a + b;
        \\}
        \\fn hidden() void {}
    );
    try std.testing.expectEqual(2, file.members.len);
    const add = file.members[0];
    try std.testing.expectEqualStrings("zig:sample.zig#add", add.id);
    try std.testing.expectEqual(ir.Kind.function, add.kind);
    try std.testing.expectEqual(ir.Visibility.public, add.visibility);
    try std.testing.expectEqualDeep(@as([]const ir.Location, &.{.{ .file = "sample.zig", .line = 2, .end_line = 8 }}), add.locations);
    try std.testing.expectEqualStrings("Adds two numbers.", try plain(arena.allocator(), add.doc));
    try std.testing.expectEqualStrings("u32", add.type.text);
    try std.testing.expectEqualStrings("a", add.params[0].name);
    try std.testing.expectEqualStrings("u32", add.params[0].type.text);
    try std.testing.expectEqualStrings("The left side.", try plain(arena.allocator(), add.params[0].doc));
    try std.testing.expectEqualStrings("anytype", add.params[1].type.text);
    try std.testing.expectEqual(ir.Visibility.private, file.members[1].visibility);
    try std.testing.expect(file.members[1].doc.isEmpty());
}

test "a container holds its fields and methods as members qualified by its name" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const file = try readForTest(arena.allocator(),
        \\/// A unit of work.
        \\const Task = struct {
        \\    /// Set once the body returned.
        \\    done: bool = false,
        \\    fn run(self: *Task) void {
        \\        _ = self;
        \\    }
        \\};
        \\const Mode = enum { fast, slow };
        \\const Either = union { a: u8, b: u16 };
    );
    const task = file.members[0];
    try std.testing.expectEqual(ir.Kind.type, task.kind);
    try std.testing.expectEqualStrings("struct", task.form);
    try std.testing.expectEqualStrings("const Task = struct", task.signature);
    try std.testing.expectEqual(2, task.members.len);
    const done = task.members[0];
    try std.testing.expectEqualStrings("zig:sample.zig#Task.done", done.id);
    try std.testing.expectEqualStrings("Task.done", done.qualified_name);
    try std.testing.expectEqual(ir.Kind.field, done.kind);
    try std.testing.expectEqualStrings("bool", done.type.text);
    try std.testing.expectEqualStrings("false", done.value);
    try std.testing.expectEqualStrings("Set once the body returned.", try plain(arena.allocator(), done.doc));
    try std.testing.expectEqualStrings("zig:sample.zig#Task.run", task.members[1].id);
    try std.testing.expectEqualStrings("enum", file.members[1].form);
    try std.testing.expectEqual(ir.Kind.enumerator, file.members[1].members[1].kind);
    try std.testing.expectEqualStrings("slow", file.members[1].members[1].name);
    try std.testing.expectEqualStrings("union", file.members[2].form);
    try std.testing.expectEqual(ir.Kind.field, file.members[2].members[0].kind);
}

test "test names are collected in source order, including the ones inside a container" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const file = try readForTest(arena.allocator(),
        \\test "first rule" {}
        \\const Box = struct {
        \\    test "a rule \"quoted\" inside" {}
        \\};
        \\test {}
        \\test "last rule" {}
    );
    try std.testing.expectEqual(3, file.verified.len);
    try std.testing.expectEqualStrings("first rule", file.verified[0]);
    try std.testing.expectEqualStrings("a rule \"quoted\" inside", file.verified[1]);
    try std.testing.expectEqualStrings("last rule", file.verified[2]);
}

test "a constant keeps its type and value, and a value that spans lines is left out" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const file = try readForTest(arena.allocator(),
        \\const limit: usize = 4;
        \\var counter: u8 = 0;
        \\const table: [2]u8 = .{
        \\    1,
        \\    2,
        \\};
    );
    try std.testing.expectEqual(ir.Kind.constant, file.members[0].kind);
    try std.testing.expectEqualStrings("usize", file.members[0].type.text);
    try std.testing.expectEqualStrings("4", file.members[0].value);
    try std.testing.expectEqual(ir.Kind.variable, file.members[1].kind);
    try std.testing.expectEqualStrings("const table: [2]u8", file.members[2].signature);
    try std.testing.expectEqualStrings("", file.members[2].value);
}

test "imports and aliases are told apart from constants" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const unit = try read(arena.allocator(), "sample.zig",
        \\const std = @import("std");
        \\const model = @import("model.zig");
        \\const c = @cImport({
        \\    @cInclude("pool/pool.h");
        \\});
        \\const Allocator = std.mem.Allocator;
        \\const Entry = @import("model.zig").Entry;
        \\const answer = 42;
        \\const nothing = null;
    );
    const members = unit.symbol.members;
    try std.testing.expectEqual(ir.Kind.alias, (try find(members, "std")).kind);
    try std.testing.expectEqualStrings("import", (try find(members, "std")).form);
    try std.testing.expectEqualStrings("model.zig", (try find(members, "model")).value);
    try std.testing.expectEqualStrings("import", (try find(members, "c")).form);
    try std.testing.expectEqual(ir.Kind.alias, (try find(members, "Allocator")).kind);
    try std.testing.expectEqualStrings("", (try find(members, "Allocator")).form);
    try std.testing.expectEqualStrings("std.mem.Allocator", (try find(members, "Allocator")).value);
    try std.testing.expectEqual(ir.Kind.alias, (try find(members, "Entry")).kind);
    try std.testing.expectEqual(ir.Kind.constant, (try find(members, "answer")).kind);
    try std.testing.expectEqual(ir.Kind.constant, (try find(members, "nothing")).kind);

    const imports = unit.file.imports;
    try std.testing.expectEqual(3, imports.len);
    try std.testing.expectEqual(ir.ImportKind.module, imports[0].kind);
    try std.testing.expectEqualStrings("std", imports[0].name);
    try std.testing.expectEqual(ir.ImportKind.file, imports[1].kind);
    try std.testing.expectEqual(ir.ImportKind.include, imports[2].kind);
    try std.testing.expectEqualStrings("pool/pool.h", imports[2].name);
}

test "a function that returns a container is read as that container" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const file = try readForTest(arena.allocator(),
        \\/// A growable list.
        \\pub fn List(comptime T: type) type {
        \\    return struct {
        \\        items: []T,
        \\        /// Adds one item.
        \\        pub fn append(self: *@This(), item: T) void {
        \\            _ = self;
        \\            _ = item;
        \\        }
        \\        test "append grows the list" {}
        \\    };
        \\}
        \\fn plain() u8 {
        \\    return 1;
        \\}
    );
    const list = file.members[0];
    try std.testing.expectEqual(ir.Kind.type, list.kind);
    try std.testing.expectEqualStrings("type function", list.form);
    try std.testing.expectEqualStrings("pub fn List(comptime T: type) type", list.signature);
    try std.testing.expectEqualStrings("zig:sample.zig#List.append", list.members[1].id);
    try std.testing.expectEqualStrings("append grows the list", file.verified[0]);
    try std.testing.expectEqual(ir.Kind.function, file.members[1].kind);
}

test "a test named after a declaration becomes an example of it" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const file = try readForTest(arena.allocator(),
        \\fn add(a: u32, b: u32) u32 {
        \\    return a + b;
        \\}
        \\test add {
        \\    const sum = add(1, 2);
        \\    if (sum != 3) {
        \\        return error.Wrong;
        \\    }
        \\}
        \\test missing {}
    );
    try std.testing.expectEqual(1, file.members[0].examples.len);
    try std.testing.expectEqualStrings("zig", file.members[0].examples[0].language);
    try std.testing.expectEqualStrings(
        \\const sum = add(1, 2);
        \\if (sum != 3) {
        \\    return error.Wrong;
        \\}
    , file.members[0].examples[0].code);
    try std.testing.expectEqual(0, file.verified.len);
}

test "the members of an error set are read with their documentation" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const file = try readForTest(arena.allocator(),
        \\pub const ReadError = error{
        \\    /// The file does not parse.
        \\    InvalidSource,
        \\    Truncated,
        \\};
    );
    const set = file.members[0];
    try std.testing.expectEqual(ir.Kind.type, set.kind);
    try std.testing.expectEqualStrings("error set", set.form);
    try std.testing.expectEqualStrings("pub const ReadError = error", set.signature);
    try std.testing.expectEqual(2, set.members.len);
    try std.testing.expectEqual(ir.Kind.enumerator, set.members[0].kind);
    try std.testing.expectEqualStrings("The file does not parse.", try plain(arena.allocator(), set.members[0].doc));
    try std.testing.expectEqualStrings("zig:sample.zig#ReadError.Truncated", set.members[1].id);
}

test "a file that does not parse is refused" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.InvalidZigSource, read(arena.allocator(), "sample.zig", "fn ("));
}
