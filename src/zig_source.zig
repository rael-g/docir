//! Reads a Zig source file through the compiler's own parser.
//!
//! Four things are taken from the syntax tree: the `//!` block that opens the file, every
//! declaration that carries a `///` block, the name of every `test` named by a string, and
//! the body of every `test` named after a declaration, which becomes an example of that
//! declaration when the two sit in the same container. The members of an error set are
//! read like the fields of a container. A container is
//! walked recursively, so a documented method becomes a member of its container, and a
//! container with no documentation of its own is still kept when one of its members has some.
//! A function that returns a container written in its own body, the way a generic type is
//! declared, is treated as that container: what the returned container declares becomes the
//! members of the function.

const std = @import("std");
const model = @import("model.zig");

const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;

/// Extracts the documentation of one Zig file. Fails with `error.InvalidZigSource` when the
/// file does not parse.
pub fn read(arena: Allocator, path: []const u8, source: [:0]const u8) !model.Unit {
    const tree = try Ast.parse(arena, source, .zig);
    if (tree.errors.len != 0) return error.InvalidZigSource;
    var reader: Reader = .{ .arena = arena, .tree = &tree };
    const entries = try reader.members(tree.rootDecls(), "");
    return .{
        .path = path,
        .language = "zig",
        .intro = try reader.containerDoc(),
        .entries = entries,
        .behaviours = try reader.behaviours.toOwnedSlice(arena),
        .symbols = try reader.symbols.toOwnedSlice(arena),
    };
}

const Reader = struct {
    arena: Allocator,
    tree: *const Ast,
    behaviours: std.ArrayList([]const u8) = .empty,
    symbols: std.ArrayList([]const u8) = .empty,

    fn declare(self: *Reader, prefix: []const u8, name: []const u8) Allocator.Error![]const u8 {
        const qualified = if (prefix.len == 0) name else try std.mem.concat(self.arena, u8, &.{ prefix, ".", name });
        try self.symbols.append(self.arena, qualified);
        return qualified;
    }

    fn members(self: *Reader, nodes: []const Ast.Node.Index, prefix: []const u8) Allocator.Error![]const model.Entry {
        const tree = self.tree;
        var out: std.ArrayList(model.Entry) = .empty;
        for (nodes) |node| {
            if (tree.nodeTag(node) == .test_decl) {
                try self.behaviour(node);
                continue;
            }
            const examples = try self.examplesOf(nodes, node);
            var fn_buffer: [1]Ast.Node.Index = undefined;
            if (tree.fullFnProto(&fn_buffer, node)) |proto| {
                const name_token = proto.name_token orelse continue;
                const qualified = try self.declare(prefix, tree.tokenSlice(name_token));
                const text = try self.docBefore(proto.firstToken());
                const is_definition = tree.nodeTag(node) == .fn_decl;
                const inner = if (is_definition) try self.returnedMembers(tree.nodeData(node).node_and_node[1], qualified) else &.{};
                if (text.len == 0 and inner.len == 0 and examples.len == 0) continue;
                const proto_node = if (is_definition) tree.nodeData(node).node_and_node[0] else node;
                try out.append(self.arena, .{
                    .name = tree.tokenSlice(name_token),
                    .signature = tree.getNodeSource(proto_node),
                    .text = text,
                    .examples = examples,
                    .members = inner,
                });
                continue;
            }
            if (tree.fullVarDecl(node)) |decl| {
                const first = decl.firstToken();
                const name = tree.tokenSlice(decl.ast.mut_token + 1);
                const qualified = try self.declare(prefix, name);
                const text = try self.docBefore(first);
                const start = tree.tokenStart(first);
                var signature = tree.getNodeSource(node);
                var inner: []const model.Entry = &.{};
                if (decl.ast.init_node.unwrap()) |init_node| {
                    var container_buffer: [2]Ast.Node.Index = undefined;
                    if (tree.fullContainerDecl(&container_buffer, init_node)) |container| {
                        const keyword = container.ast.main_token;
                        signature = tree.source[start .. tree.tokenStart(keyword) + tree.tokenSlice(keyword).len];
                        inner = try self.members(container.ast.members, qualified);
                    } else if (tree.nodeTag(init_node) == .error_set_decl) {
                        const braces = tree.nodeData(init_node).token_and_token;
                        signature = tree.source[start..tree.tokenStart(braces[0])];
                        signature = std.mem.trimEnd(u8, signature, " ");
                        inner = try self.errors(braces[0], braces[1], qualified);
                    } else if (std.mem.indexOfScalar(u8, signature, '\n') != null) {
                        const head = tree.source[start..tree.tokenStart(tree.firstToken(init_node))];
                        signature = std.mem.trimEnd(u8, head, " =\t\r\n");
                    }
                }
                if (text.len == 0 and inner.len == 0 and examples.len == 0) continue;
                try out.append(self.arena, .{
                    .name = name,
                    .signature = signature,
                    .text = text,
                    .examples = examples,
                    .members = inner,
                });
                continue;
            }
            if (tree.fullContainerField(node)) |field| {
                _ = try self.declare(prefix, tree.tokenSlice(field.ast.main_token));
                const text = try self.docBefore(field.firstToken());
                if (text.len == 0) continue;
                try out.append(self.arena, .{
                    .name = tree.tokenSlice(field.ast.main_token),
                    .signature = tree.getNodeSource(node),
                    .text = text,
                });
            }
        }
        return out.toOwnedSlice(self.arena);
    }

    fn errors(self: *Reader, open: Ast.TokenIndex, close: Ast.TokenIndex, prefix: []const u8) Allocator.Error![]const model.Entry {
        const tree = self.tree;
        var out: std.ArrayList(model.Entry) = .empty;
        var token = open + 1;
        while (token < close) : (token += 1) {
            if (tree.tokenTag(token) != .identifier) continue;
            const name = tree.tokenSlice(token);
            _ = try self.declare(prefix, name);
            const text = try self.docBefore(token);
            if (text.len != 0) try out.append(self.arena, .{ .name = name, .signature = name, .text = text });
        }
        return out.toOwnedSlice(self.arena);
    }

    fn examplesOf(self: *Reader, siblings: []const Ast.Node.Index, node: Ast.Node.Index) Allocator.Error![]const []const u8 {
        const tree = self.tree;
        var fn_buffer: [1]Ast.Node.Index = undefined;
        const name_token = if (tree.fullFnProto(&fn_buffer, node)) |proto|
            proto.name_token orelse return &.{}
        else if (tree.fullVarDecl(node)) |decl|
            decl.ast.mut_token + 1
        else
            return &.{};
        const name = tree.tokenSlice(name_token);

        var out: std.ArrayList([]const u8) = .empty;
        for (siblings) |sibling| {
            if (tree.nodeTag(sibling) != .test_decl) continue;
            const data = tree.nodeData(sibling).opt_token_and_node;
            const test_name = data[0].unwrap() orelse continue;
            if (tree.tokenTag(test_name) != .identifier or !std.mem.eql(u8, tree.tokenSlice(test_name), name)) continue;
            try out.append(self.arena, try self.blockBody(data[1]));
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

    fn returnedMembers(self: *Reader, body: Ast.Node.Index, prefix: []const u8) Allocator.Error![]const model.Entry {
        const tree = self.tree;
        var block_buffer: [2]Ast.Node.Index = undefined;
        const statements = tree.blockStatements(&block_buffer, body) orelse return &.{};
        for (statements) |statement| {
            if (tree.nodeTag(statement) != .@"return") continue;
            const returned = tree.nodeData(statement).opt_node.unwrap() orelse continue;
            var container_buffer: [2]Ast.Node.Index = undefined;
            const container = tree.fullContainerDecl(&container_buffer, returned) orelse continue;
            return self.members(container.ast.members, prefix);
        }
        return &.{};
    }

    fn behaviour(self: *Reader, node: Ast.Node.Index) Allocator.Error!void {
        const tree = self.tree;
        const name_token = tree.nodeData(node).opt_token_and_node[0].unwrap() orelse return;
        if (tree.tokenTag(name_token) != .string_literal) return;
        const literal = tree.tokenSlice(name_token);
        const name = std.zig.string_literal.parseAlloc(self.arena, literal) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidLiteral => std.mem.trim(u8, literal, "\""),
        };
        try self.behaviours.append(self.arena, name);
    }

    fn containerDoc(self: *Reader) Allocator.Error![]const u8 {
        const tree = self.tree;
        var end: Ast.TokenIndex = 0;
        while (end < tree.tokens.len and tree.tokenTag(end) == .container_doc_comment) end += 1;
        return self.joinLines(0, end);
    }

    fn docBefore(self: *Reader, token: Ast.TokenIndex) Allocator.Error![]const u8 {
        var first = token;
        while (first > 0 and self.tree.tokenTag(first - 1) == .doc_comment) first -= 1;
        return self.joinLines(first, token);
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

fn readForTest(arena: Allocator, source: [:0]const u8) !model.Unit {
    return read(arena, "sample.zig", source);
}

test "the block that opens a file becomes its introduction" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const unit = try readForTest(arena.allocator(),
        \\//! First line.
        \\//!
        \\//! Second paragraph.
        \\const x = 1;
    );
    try std.testing.expectEqualStrings("First line.\n\nSecond paragraph.", unit.intro);
}

test "a documented function is kept with its prototype and an undocumented one is dropped" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const unit = try readForTest(arena.allocator(),
        \\/// Adds two numbers.
        \\pub fn add(a: u32, b: u32) u32 {
        \\    return a + b;
        \\}
        \\fn hidden() void {}
    );
    try std.testing.expectEqual(1, unit.entries.len);
    try std.testing.expectEqualStrings("add", unit.entries[0].name);
    try std.testing.expectEqualStrings("pub fn add(a: u32, b: u32) u32", unit.entries[0].signature);
    try std.testing.expectEqualStrings("Adds two numbers.", unit.entries[0].text);
}

test "a container keeps its documented fields and methods as members" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const unit = try readForTest(arena.allocator(),
        \\/// A unit of work.
        \\const Task = struct {
        \\    /// Set once the body returned.
        \\    done: bool,
        \\    other: u8,
        \\    /// Runs the body.
        \\    fn run(self: *Task) void {
        \\        _ = self;
        \\    }
        \\};
    );
    try std.testing.expectEqual(1, unit.entries.len);
    const task = unit.entries[0];
    try std.testing.expectEqualStrings("const Task = struct", task.signature);
    try std.testing.expectEqual(2, task.members.len);
    try std.testing.expectEqualStrings("done", task.members[0].name);
    try std.testing.expectEqualStrings("done: bool", task.members[0].signature);
    try std.testing.expectEqualStrings("run", task.members[1].name);
}

test "an undocumented container survives when one of its members is documented" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const unit = try readForTest(arena.allocator(),
        \\const State = struct {
        \\    /// Number of live tasks.
        \\    count: u32,
        \\};
        \\const Empty = struct { a: u8 };
    );
    try std.testing.expectEqual(1, unit.entries.len);
    try std.testing.expectEqualStrings("State", unit.entries[0].name);
    try std.testing.expectEqualStrings("", unit.entries[0].text);
}

test "test names are collected in source order, including the ones inside a container" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const unit = try readForTest(arena.allocator(),
        \\test "first rule" {}
        \\const Box = struct {
        \\    test "a rule \"quoted\" inside" {}
        \\};
        \\test {}
        \\test "last rule" {}
    );
    try std.testing.expectEqual(3, unit.behaviours.len);
    try std.testing.expectEqualStrings("first rule", unit.behaviours[0]);
    try std.testing.expectEqualStrings("a rule \"quoted\" inside", unit.behaviours[1]);
    try std.testing.expectEqualStrings("last rule", unit.behaviours[2]);
}

test "a declaration whose value spans lines is cut before the value" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const unit = try readForTest(arena.allocator(),
        \\/// The slots.
        \\const table: [2]u8 = .{
        \\    1,
        \\    2,
        \\};
    );
    try std.testing.expectEqualStrings("const table: [2]u8", unit.entries[0].signature);
}

test "a file that does not parse is refused" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.InvalidZigSource, readForTest(arena.allocator(), "fn ("));
}

test "every declaration is a symbol, documented or not, and a member is qualified by its container" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const unit = try readForTest(arena.allocator(),
        \\const std = @import("std");
        \\const Task = struct {
        \\    done: bool,
        \\    fn run() void {}
        \\};
        \\fn wait() void {}
    );
    const expected: []const []const u8 = &.{ "std", "Task", "Task.done", "Task.run", "wait" };
    try std.testing.expectEqual(expected.len, unit.symbols.len);
    for (expected, unit.symbols) |want, got| try std.testing.expectEqualStrings(want, got);
}

test "a function that returns a container is read as that container" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const unit = try readForTest(arena.allocator(),
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
    try std.testing.expectEqual(1, unit.entries.len);
    try std.testing.expectEqualStrings("pub fn List(comptime T: type) type", unit.entries[0].signature);
    try std.testing.expectEqualStrings("append", unit.entries[0].members[0].name);
    try std.testing.expectEqualStrings("append grows the list", unit.behaviours[0]);
    const expected: []const []const u8 = &.{ "List", "List.items", "List.append", "plain" };
    try std.testing.expectEqual(expected.len, unit.symbols.len);
    for (expected, unit.symbols) |want, got| try std.testing.expectEqualStrings(want, got);
}

test "a test named after a declaration becomes an example of it, documented or not" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const unit = try readForTest(arena.allocator(),
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
    try std.testing.expectEqual(1, unit.entries.len);
    try std.testing.expectEqual(1, unit.entries[0].examples.len);
    try std.testing.expectEqualStrings(
        \\const sum = add(1, 2);
        \\if (sum != 3) {
        \\    return error.Wrong;
        \\}
    , unit.entries[0].examples[0]);
    try std.testing.expectEqual(0, unit.behaviours.len);
}

test "the documented members of an error set are read and every member is a symbol" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const unit = try readForTest(arena.allocator(),
        \\pub const ReadError = error{
        \\    /// The file does not parse.
        \\    InvalidSource,
        \\    Truncated,
        \\};
    );
    try std.testing.expectEqual(1, unit.entries.len);
    try std.testing.expectEqualStrings("pub const ReadError = error", unit.entries[0].signature);
    try std.testing.expectEqual(1, unit.entries[0].members.len);
    try std.testing.expectEqualStrings("InvalidSource", unit.entries[0].members[0].name);
    try std.testing.expectEqualStrings("The file does not parse.", unit.entries[0].members[0].text);
    try std.testing.expectEqual(3, unit.symbols.len);
    try std.testing.expectEqualStrings("ReadError.Truncated", unit.symbols[2]);
}
