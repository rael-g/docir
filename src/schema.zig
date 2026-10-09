//! Describes the JSON of a document as a JSON Schema.
//!
//! The schema is not written by hand: it is derived from the types of `ir`, the same ones
//! the document is written from and read into, so it cannot say something else than they do.
//! It follows the 2020-12 draft. Every struct, enum and union of the model gets a definition
//! under its own name, and the schema as a whole is the definition of `ir.Document`.
//!
//! A struct is an object that admits no other property than its fields, of which those
//! without a default are required. An enum is the name of one of its values. A union is an
//! object with a single property, named after the alternative it holds, and an alternative
//! that holds nothing has an empty object as its value. A slice of bytes is a string, any
//! other slice an array, and an optional admits null.

const std = @import("std");
const ir = @import("ir.zig");

const Stringify = std.json.Stringify;

/// The address the schema declares itself to follow.
pub const dialect = "https://json-schema.org/draft/2020-12/schema";

/// Writes the schema of `ir.Document` as indented JSON.
pub fn write(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    var json: Stringify = .{ .writer = writer, .options = .{ .whitespace = .indent_2 } };
    try json.beginObject();
    try json.objectField("$schema");
    try json.write(dialect);
    try json.objectField("title");
    try json.write(std.fmt.comptimePrint("docir document, format {d}", .{ir.format_version}));
    try json.objectField("$ref");
    try json.write("#/$defs/" ++ comptime nameOf(ir.Document));
    try json.objectField("$defs");
    try json.beginObject();
    inline for (comptime definitions()) |Defined| {
        try json.objectField(comptime nameOf(Defined));
        try define(&json, Defined);
    }
    try json.endObject();
    try json.endObject();
    try writer.writeByte('\n');
}

fn nameOf(comptime T: type) []const u8 {
    const full = @typeName(T);
    const dot = std.mem.lastIndexOfScalar(u8, full, '.') orelse return full;
    return full[dot + 1 ..];
}

fn isDefined(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"enum", .@"union" => true,
        else => false,
    };
}

fn definitions() []const type {
    var found: []const type = &.{};
    gather(ir.Document, &found);
    return found;
}

fn gather(comptime T: type, comptime found: *[]const type) void {
    switch (@typeInfo(T)) {
        .optional => |optional| gather(optional.child, found),
        .pointer => |pointer| gather(pointer.child, found),
        .@"struct", .@"union" => {
            for (found.*) |known| {
                if (known == T) return;
            }
            found.* = found.* ++ &[_]type{T};
            for (std.meta.fields(T)) |field| gather(field.type, found);
        },
        .@"enum" => {
            for (found.*) |known| {
                if (known == T) return;
            }
            found.* = found.* ++ &[_]type{T};
        },
        else => {},
    }
}

fn define(json: *Stringify, comptime T: type) std.Io.Writer.Error!void {
    try json.beginObject();
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            try json.objectField("type");
            try json.write("object");
            try json.objectField("properties");
            try json.beginObject();
            inline for (info.fields) |field| {
                try json.objectField(field.name);
                try describe(json, field.type);
            }
            try json.endObject();
            try json.objectField("required");
            try json.beginArray();
            inline for (info.fields) |field| {
                if (field.default_value_ptr == null) try json.write(field.name);
            }
            try json.endArray();
            try json.objectField("additionalProperties");
            try json.write(false);
        },
        .@"enum" => |info| {
            try json.objectField("enum");
            try json.beginArray();
            inline for (info.fields) |field| try json.write(field.name);
            try json.endArray();
        },
        .@"union" => |info| {
            try json.objectField("oneOf");
            try json.beginArray();
            inline for (info.fields) |field| {
                try json.beginObject();
                try json.objectField("type");
                try json.write("object");
                try json.objectField("properties");
                try json.beginObject();
                try json.objectField(field.name);
                try describe(json, field.type);
                try json.endObject();
                try json.objectField("required");
                try json.beginArray();
                try json.write(field.name);
                try json.endArray();
                try json.objectField("additionalProperties");
                try json.write(false);
                try json.endObject();
            }
            try json.endArray();
        },
        else => comptime unreachable,
    }
    try json.endObject();
}

fn describe(json: *Stringify, comptime T: type) std.Io.Writer.Error!void {
    try json.beginObject();
    if (comptime isDefined(T)) {
        try json.objectField("$ref");
        try json.write("#/$defs/" ++ comptime nameOf(T));
    } else switch (@typeInfo(T)) {
        .bool => {
            try json.objectField("type");
            try json.write("boolean");
        },
        .int => |info| {
            try json.objectField("type");
            try json.write("integer");
            if (info.signedness == .unsigned) {
                try json.objectField("minimum");
                try json.write(0);
            }
        },
        .void => {
            try json.objectField("type");
            try json.write("object");
            try json.objectField("maxProperties");
            try json.write(0);
        },
        .optional => |optional| {
            try json.objectField("anyOf");
            try json.beginArray();
            try describe(json, optional.child);
            try json.beginObject();
            try json.objectField("type");
            try json.write("null");
            try json.endObject();
            try json.endArray();
        },
        .pointer => |pointer| if (pointer.child == u8) {
            try json.objectField("type");
            try json.write("string");
        } else {
            try json.objectField("type");
            try json.write("array");
            try json.objectField("items");
            try describe(json, pointer.child);
        },
        else => @compileError("the document model holds a " ++ @typeName(T) ++ ", which the schema has no words for"),
    }
    try json.endObject();
}

test "the schema is JSON that defines every type of the model, with the fields that have no default required" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var out: std.Io.Writer.Allocating = .init(arena.allocator());
    try write(&out.writer);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), out.written(), .{});
    try std.testing.expectEqualStrings(dialect, parsed.object.get("$schema").?.string);
    try std.testing.expectEqualStrings("#/$defs/Document", parsed.object.get("$ref").?.string);
    const defs = parsed.object.get("$defs").?.object;
    inline for (.{ ir.Document, ir.File, ir.Symbol, ir.Text, ir.Block, ir.Inline, ir.Kind, ir.TypeRef, ir.Location }) |Defined| {
        try std.testing.expect(defs.contains(nameOf(Defined)));
    }
    const symbol = defs.get("Symbol").?.object;
    try std.testing.expectEqual(@as(usize, std.meta.fields(ir.Symbol).len), symbol.get("properties").?.object.count());
    try std.testing.expectEqual(4, symbol.get("required").?.array.items.len);
    try std.testing.expectEqualStrings("#/$defs/Symbol", symbol.get("properties").?.object.get("members").?.object.get("items").?.object.get("$ref").?.string);
    try std.testing.expectEqual(std.meta.fields(ir.Block).len, defs.get("Block").?.object.get("oneOf").?.array.items.len);
    try std.testing.expectEqualStrings("string", symbol.get("properties").?.object.get("name").?.object.get("type").?.string);
}
