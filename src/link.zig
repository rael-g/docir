//! Resolves the names a document mentions into references to its symbols.
//!
//! Three things are resolved. The first is a mention: an `ir.Ref` that its reader left
//! without a target. The second is the target of an alias, which in Zig is an import or a
//! constant that names another declaration. The third is the target of a type: an
//! `ir.TypeRef` gets the first name written in it that resolves to a type or to an alias. In
//! a Zig file such a name is only looked for in the scopes around it, since Zig has no name
//! that a file did not declare or import. A type that declares its own members where it is
//! written, and one that names nothing in the sources, stay without a target and are no
//! problem.
//!
//! A symbol that asks for the documentation of another, through `ir.Symbol.inherits`, is
//! given what it does not say itself: the text, what is returned, what is raised, the
//! examples, and what is said of each parameter it has under the same name. The other
//! symbol is the one it names, or else the member of the same name in the first of the
//! types its own type derives from that has one, looked for upwards. A type that names none
//! takes from the first type it derives from.
//!
//! A name is one identifier or several joined by a dot or by `::`, optionally followed by
//! `()`. Its
//! first part is looked for in the scopes around the text, innermost first: the members of
//! the symbol being documented, its siblings, and outwards to the top of its file. Inside a
//! type, its own name is the type and not the constructor that shares it. When no
//! scope has it, every symbol of every file is searched, the file of the text first. Each
//! following part is looked for among the members of what the previous part named, going
//! through an import into the file it resolved to and through an alias into what it names.
//! An import may lead to a file that is not in the document, in which case a `Source` is
//! asked for it.
//!
//! A mention that resolves gets its target. One that names a parameter of the symbol being
//! documented becomes an `ir.Inline.param`. One that resolves to nothing is turned into
//! plain code when it appears in the signature of that symbol or is a word of the language,
//! when it is dotted and its first part is unknown, since it is then a file name or a name
//! from outside the sources, and when a part names something whose members are not known,
//! such as an import that was not followed. Every other mention is a `Problem` and stays a
//! mention without a target, and so is a documented parameter that the signature does not
//! have. A word of the language includes the names its own library is best known by, such
//! as the fixed-width integers of C and the common types of the C# base library, and a name
//! given in `Options.external` is taken the same way. Problems are only raised for documented files.
//!
//! What a `Source` supplied joins the document, in front, cut down to the members that a
//! reference names or reaches into.

const std = @import("std");
const ir = @import("ir.zig");
const markdown_text = @import("markdown_text.zig");

const Allocator = std.mem.Allocator;

/// One mention that names nothing.
pub const Problem = struct {
    /// Path of the file the mention is in.
    path: []const u8,
    /// Qualified name of the symbol whose documentation mentions.
    owner: []const u8,
    /// The name that was not found.
    citation: []const u8,
    /// What was expected to carry the name.
    kind: Kind,

    /// What a `Problem` is about.
    pub const Kind = enum {
        /// A mention that names no symbol.
        symbol,
        /// A documented parameter that the signature does not have.
        parameter,
    };
};

/// The linked document and what could not be resolved in it.
pub const Result = struct {
    /// The document, with `ir.Document.linked` set.
    document: ir.Document,
    /// One entry per mention of a documented file that names nothing.
    problems: []const Problem,
};

/// Supplies a file that an import leads to and that is not in the document.
pub const Source = struct {
    /// Passed back to `find` on every call.
    context: *anyopaque,
    /// What was read from the file at `path`, or null when there is none.
    find: *const fn (context: *anyopaque, path: []const u8) Allocator.Error!?*const ir.Unit,
};

/// What a linker is given besides the document.
pub const Options = struct {
    /// Supplies the files that imports lead to outside the document. Null to follow none.
    source: ?Source = null,
    /// Names declared outside the sources, such as the types of a library that is only
    /// used. A mention of one, or of something inside one, is code and no problem.
    external: []const []const u8 = &.{},
};

/// Links `document`. Each of its top-level symbols must stand for one of its files, the
/// way the readers of this package produce them, in the same order as the files.
pub fn link(arena: Allocator, document: ir.Document, options: Options) Allocator.Error!Result {
    const count = @min(document.files.len, document.symbols.len);
    const units = try arena.alloc(Scope, count);
    for (units, document.files[0..count], document.symbols[0..count]) |*unit, *file, *symbol| unit.* = .{ .file = file, .symbol = symbol };

    var linker: Linker = .{ .arena = arena, .units = units, .source = options.source, .external = options.external };
    const roots = try arena.alloc(ir.Symbol, count);
    for (roots, units) |*root, unit| {
        linker.unit = unit;
        linker.scopes.clearRetainingCapacity();
        linker.owners.clearRetainingCapacity();
        root.* = (try linker.symbols(unit.symbol[0..1]))[0];
    }

    const completed = try linker.inherited(roots, null, roots);

    var files: std.ArrayList(ir.File) = .empty;
    var symbols: std.ArrayList(ir.Symbol) = .empty;
    for (linker.fetched.items) |unit| {
        const kept = try linker.narrowed(unit.*) orelse continue;
        try files.append(arena, kept.file);
        try symbols.append(arena, kept.symbol);
    }
    try files.appendSlice(arena, document.files[0..count]);
    try symbols.appendSlice(arena, completed);

    var linked = document;
    linked.linked = true;
    linked.files = try files.toOwnedSlice(arena);
    linked.symbols = try symbols.toOwnedSlice(arena);
    return .{ .document = linked, .problems = try linker.problems.toOwnedSlice(arena) };
}

const max_indirections = 8;

const c_words = std.StaticStringMap(void).initComptime(.{
    .{"NULL"},     .{"true"},    .{"false"},    .{"void"},     .{"bool"},      .{"char"},
    .{"short"},    .{"int"},     .{"long"},     .{"float"},    .{"double"},    .{"signed"},
    .{"unsigned"}, .{"size_t"},  .{"intptr_t"}, .{"int8_t"},   .{"uintptr_t"}, .{"int16_t"},
    .{"int32_t"},  .{"int64_t"}, .{"uint8_t"},  .{"uint16_t"}, .{"uint32_t"},  .{"uint64_t"},
    .{"struct"},   .{"union"},   .{"enum"},     .{"typedef"},  .{"const"},     .{"static"},
    .{"extern"},   .{"inline"},  .{"volatile"}, .{"restrict"}, .{"sizeof"},    .{"return"},
    .{"if"},       .{"else"},    .{"for"},      .{"while"},    .{"do"},        .{"switch"},
    .{"case"},     .{"default"}, .{"break"},    .{"continue"}, .{"goto"},
});

const cpp_words = std.StaticStringMap(void).initComptime(.{
    .{"class"},     .{"namespace"}, .{"template"}, .{"typename"}, .{"public"},   .{"private"},
    .{"protected"}, .{"virtual"},   .{"override"}, .{"final"},    .{"nullptr"},  .{"this"},
    .{"auto"},      .{"operator"},  .{"new"},      .{"delete"},   .{"using"},    .{"friend"},
    .{"constexpr"}, .{"noexcept"},  .{"explicit"}, .{"mutable"},  .{"decltype"}, .{"throw"},
    .{"try"},       .{"catch"},     .{"wchar_t"},  .{"char8_t"},  .{"char16_t"}, .{"char32_t"},
});

const csharp_words = std.StaticStringMap(void).initComptime(.{
    .{"bool"},     .{"byte"},    .{"sbyte"},     .{"char"},     .{"short"},     .{"ushort"},
    .{"int"},      .{"uint"},    .{"long"},      .{"ulong"},    .{"nint"},      .{"nuint"},
    .{"float"},    .{"double"},  .{"decimal"},   .{"string"},   .{"object"},    .{"void"},
    .{"dynamic"},  .{"var"},     .{"null"},      .{"true"},     .{"false"},     .{"this"},
    .{"base"},     .{"default"}, .{"new"},       .{"ref"},      .{"out"},       .{"in"},
    .{"params"},   .{"scoped"},  .{"readonly"},  .{"unsafe"},   .{"static"},    .{"const"},
    .{"class"},    .{"struct"},  .{"enum"},      .{"delegate"}, .{"event"},     .{"using"},
    .{"typeof"},   .{"sizeof"},  .{"nameof"},    .{"async"},    .{"await"},     .{"return"},
    .{"throw"},    .{"try"},     .{"catch"},     .{"finally"},  .{"lock"},      .{"yield"},
    .{"is"},       .{"as"},      .{"if"},        .{"else"},     .{"foreach"},   .{"while"},
    .{"abstract"}, .{"virtual"}, .{"override"},  .{"sealed"},   .{"partial"},   .{"interface"},
    .{"public"},   .{"private"}, .{"protected"}, .{"internal"}, .{"namespace"}, .{"record"},
});

const csharp_library = std.StaticStringMap(void).initComptime(.{
    .{"Object"},                     .{"String"},                      .{"Type"},                      .{"Array"},
    .{"Enum"},                       .{"Attribute"},                   .{"Delegate"},                  .{"Nullable"},
    .{"Boolean"},                    .{"Byte"},                        .{"Char"},                      .{"Int16"},
    .{"Int32"},                      .{"Int64"},                       .{"UInt16"},                    .{"UInt32"},
    .{"UInt64"},                     .{"Single"},                      .{"Double"},                    .{"Decimal"},
    .{"IntPtr"},                     .{"UIntPtr"},                     .{"Guid"},                      .{"DateTime"},
    .{"TimeSpan"},                   .{"Math"},                        .{"MathF"},                     .{"Console"},
    .{"Environment"},                .{"GC"},                          .{"Action"},                    .{"Func"},
    .{"Predicate"},                  .{"Task"},                        .{"ValueTask"},                 .{"Thread"},
    .{"CancellationToken"},          .{"IDisposable"},                 .{"IAsyncDisposable"},          .{"IEnumerable"},
    .{"IEnumerator"},                .{"ICollection"},                 .{"IList"},                     .{"IDictionary"},
    .{"IReadOnlyCollection"},        .{"IReadOnlyList"},               .{"IReadOnlyDictionary"},       .{"IEquatable"},
    .{"IComparable"},                .{"List"},                        .{"Dictionary"},                .{"HashSet"},
    .{"Queue"},                      .{"Stack"},                       .{"Span"},                      .{"ReadOnlySpan"},
    .{"Memory"},                     .{"ReadOnlyMemory"},              .{"StringBuilder"},             .{"Stream"},
    .{"Marshal"},                    .{"Vector2"},                     .{"Vector3"},                   .{"Vector4"},
    .{"Quaternion"},                 .{"Matrix4x4"},                   .{"Exception"},                 .{"ArgumentException"},
    .{"ArgumentNullException"},      .{"ArgumentOutOfRangeException"}, .{"InvalidOperationException"}, .{"NotSupportedException"},
    .{"NotImplementedException"},    .{"ObjectDisposedException"},     .{"NullReferenceException"},    .{"IndexOutOfRangeException"},
    .{"KeyNotFoundException"},       .{"FormatException"},             .{"IOException"},               .{"FileNotFoundException"},
    .{"OperationCanceledException"}, .{"TimeoutException"},            .{"OutOfMemoryException"},      .{"DllNotFoundException"},
});

fn isCFamily(language: []const u8) bool {
    return std.mem.eql(u8, language, "c") or std.mem.eql(u8, language, "cpp");
}

const Scope = struct {
    file: *const ir.File,
    symbol: *const ir.Symbol,
};

const Outcome = union(enum) {
    linked: Scope,
    parameter,
    accepted,
    unknown,
};

fn isImport(symbol: *const ir.Symbol) bool {
    return symbol.kind == .alias and std.mem.eql(u8, symbol.form, "import");
}

const Linker = struct {
    arena: Allocator,
    units: []const Scope,
    source: ?Source,
    external: []const []const u8 = &.{},
    unit: Scope = undefined,
    scopes: std.ArrayList([]const ir.Symbol) = .empty,
    owners: std.ArrayList(*const ir.Symbol) = .empty,
    problems: std.ArrayList(Problem) = .empty,
    fetched: std.ArrayList(*const ir.Unit) = .empty,
    targets: std.StringHashMapUnmanaged(void) = .empty,
    lexical: bool = false,

    fn symbols(self: *Linker, list: []const ir.Symbol) Allocator.Error![]const ir.Symbol {
        const out = try self.arena.alloc(ir.Symbol, list.len);
        for (out, list) |*linked, *symbol| {
            linked.* = symbol.*;
            if (symbol.kind == .alias and symbol.target.len == 0) {
                const found = if (isImport(symbol))
                    try self.imported(self.unit, symbol.value)
                else
                    try self.expression(self.unit, symbol.value, max_indirections);
                if (found) |target| linked.target = try self.aim(target.symbol.id);
            }

            try self.scopes.append(self.arena, symbol.members);
            try self.owners.append(self.arena, symbol);
            linked.doc = try self.text(symbol.doc, symbol);
            linked.type = try self.typed(symbol.type, symbol);
            const bases = try self.arena.dupe(ir.TypeRef, symbol.bases);
            for (bases) |*base| base.* = try self.typed(base.*, symbol);
            linked.bases = bases;
            linked.returns = try self.text(symbol.returns, symbol);
            const params = try self.arena.dupe(ir.Param, symbol.params);
            for (params) |*param| {
                param.doc = try self.text(param.doc, symbol);
                param.type = try self.typed(param.type, symbol);
                const undeclared = param.type.text.len == 0 and isCFamily(self.unit.file.language);
                if (undeclared and symbol.kind != .macro and markdown_text.isName(param.name)) try self.report(symbol, param.name, .parameter);
            }
            linked.params = params;
            const type_params = try self.arena.dupe(ir.TypeParam, symbol.type_params);
            for (type_params) |*type_param| type_param.doc = try self.text(type_param.doc, symbol);
            linked.type_params = type_params;
            const raises = try self.arena.dupe(ir.Raised, symbol.raises);
            for (raises) |*raised| {
                raised.doc = try self.text(raised.doc, symbol);
                raised.type = try self.typed(raised.type, symbol);
            }
            linked.raises = raises;
            linked.members = try self.symbols(symbol.members);
            _ = self.scopes.pop();
            _ = self.owners.pop();
        }
        return out;
    }

    fn aim(self: *Linker, id: []const u8) Allocator.Error![]const u8 {
        try self.targets.put(self.arena, id, {});
        return id;
    }

    fn typed(self: *Linker, written: ir.TypeRef, owner: *const ir.Symbol) Allocator.Error!ir.TypeRef {
        if (written.target.len != 0) {
            _ = try self.aim(written.target);
            return written;
        }
        const text_of = written.text;
        if (std.mem.indexOfScalar(u8, text_of, '{') != null) return written;
        self.lexical = std.mem.eql(u8, self.unit.file.language, "zig");
        defer self.lexical = false;
        var at: usize = 0;
        while (at < text_of.len) {
            if (!isNameStart(text_of[at])) {
                at += 1;
                continue;
            }
            var end = at;
            while (end < text_of.len) {
                if (isNameStart(text_of[end]) or std.ascii.isDigit(text_of[end])) {
                    end += 1;
                } else if (text_of[end] == '.' and end + 1 < text_of.len and isNameStart(text_of[end + 1])) {
                    end += 1;
                } else if (std.mem.startsWith(u8, text_of[end..], "::") and end + 2 < text_of.len and isNameStart(text_of[end + 2])) {
                    end += 2;
                } else break;
            }
            const name = text_of[at..end];
            const member = at != 0 and (text_of[at - 1] == '.' or text_of[at - 1] == '@');
            at = end;
            if (member or self.isLanguageWord(name)) continue;
            const generic = for (owner.type_params) |param| {
                if (std.mem.eql(u8, param.name, name)) break true;
            } else false;
            if (generic) continue;
            switch (try self.cite(name, owner)) {
                .linked => |found| if (found.symbol.kind == .type or found.symbol.kind == .alias) {
                    return .{ .text = text_of, .target = try self.aim(found.symbol.id) };
                },
                else => {},
            }
        }
        return written;
    }

    fn inherited(self: *Linker, list: []const ir.Symbol, parent: ?*const ir.Symbol, all: []const ir.Symbol) Allocator.Error![]const ir.Symbol {
        const out = try self.arena.dupe(ir.Symbol, list);
        for (out, list) |*symbol, *original| {
            if (original.inherits != null) {
                if (try self.documented(original, parent, all, max_indirections)) |source| try self.take(symbol, source);
            }
            symbol.members = try self.inherited(original.members, original, all);
        }
        return out;
    }

    fn documented(self: *Linker, symbol: *const ir.Symbol, parent: ?*const ir.Symbol, all: []const ir.Symbol, budget: usize) Allocator.Error!?*const ir.Symbol {
        if (budget == 0) return null;
        const name = symbol.inherits orelse return null;
        var candidate: ?Place = null;
        if (name.len != 0) {
            switch (try self.cite(name, symbol)) {
                .linked => |found| candidate = within(all, null, found.symbol.id),
                else => {},
            }
        } else if (symbol.kind == .type) {
            for (symbol.bases) |base| {
                candidate = within(all, null, base.target) orelse continue;
                break;
            }
        } else if (parent) |owner| {
            candidate = try self.overridden(symbol, owner, all, budget);
        }
        const found = candidate orelse return null;
        if (found.symbol == symbol) return null;
        if (found.symbol.inherits != null and found.symbol.doc.isEmpty()) return self.documented(found.symbol, found.parent, all, budget - 1);
        return found.symbol;
    }

    fn overridden(self: *Linker, symbol: *const ir.Symbol, owner: *const ir.Symbol, all: []const ir.Symbol, budget: usize) Allocator.Error!?Place {
        if (budget == 0) return null;
        for (owner.bases) |base| {
            const place = within(all, null, base.target) orelse continue;
            var same: ?*const ir.Symbol = null;
            for (place.symbol.members) |*member| {
                if (!std.mem.eql(u8, member.name, symbol.name)) continue;
                if (same == null or member.params.len == symbol.params.len) same = member;
            }
            if (same) |member| return .{ .symbol = member, .parent = place.symbol };
            if (try self.overridden(symbol, place.symbol, all, budget - 1)) |deeper| return deeper;
        }
        return null;
    }

    fn take(self: *Linker, symbol: *ir.Symbol, source: *const ir.Symbol) Allocator.Error!void {
        if (symbol.doc.isEmpty()) symbol.doc = source.doc;
        if (symbol.returns.isEmpty()) symbol.returns = source.returns;
        if (symbol.raises.len == 0) symbol.raises = source.raises;
        if (symbol.examples.len == 0) symbol.examples = source.examples;
        const params = try self.arena.dupe(ir.Param, symbol.params);
        for (params) |*param| {
            if (!param.doc.isEmpty()) continue;
            for (source.params) |other| {
                if (std.mem.eql(u8, other.name, param.name)) param.doc = other.doc;
            }
        }
        symbol.params = params;
        const type_params = try self.arena.dupe(ir.TypeParam, symbol.type_params);
        for (type_params) |*param| {
            if (!param.doc.isEmpty()) continue;
            for (source.type_params) |other| {
                if (std.mem.eql(u8, other.name, param.name)) param.doc = other.doc;
            }
        }
        symbol.type_params = type_params;
    }

    fn report(self: *Linker, owner: *const ir.Symbol, citation: []const u8, kind: Problem.Kind) Allocator.Error!void {
        if (!self.unit.file.documented) return;
        try self.problems.append(self.arena, .{ .path = self.unit.file.path, .owner = owner.qualified_name, .citation = citation, .kind = kind });
    }

    fn text(self: *Linker, source: ir.Text, owner: *const ir.Symbol) Allocator.Error!ir.Text {
        return .{ .blocks = try self.blocks(source.blocks, owner) };
    }

    fn blocks(self: *Linker, list: []const ir.Block, owner: *const ir.Symbol) Allocator.Error![]const ir.Block {
        if (list.len == 0) return list;
        const out = try self.arena.dupe(ir.Block, list);
        for (out) |*block| switch (block.*) {
            .paragraph => |content| block.* = .{ .paragraph = try self.inlines(content, owner) },
            .heading => |heading| block.* = .{ .heading = .{ .level = heading.level, .content = try self.inlines(heading.content, owner) } },
            .list => |listed| {
                const items = try self.arena.dupe([]const ir.Block, listed.items);
                for (items) |*item| item.* = try self.blocks(item.*, owner);
                block.* = .{ .list = .{ .start = listed.start, .items = items } };
            },
            .quote => |quoted| block.* = .{ .quote = try self.blocks(quoted, owner) },
            .note => |note| block.* = .{ .note = .{ .label = note.label, .blocks = try self.blocks(note.blocks, owner) } },
            .table => |table| {
                const header = try self.arena.dupe([]const ir.Inline, table.header);
                for (header) |*cell| cell.* = try self.inlines(cell.*, owner);
                const rows = try self.arena.dupe([]const []const ir.Inline, table.rows);
                for (rows) |*row| {
                    const cells = try self.arena.dupe([]const ir.Inline, row.*);
                    for (cells) |*cell| cell.* = try self.inlines(cell.*, owner);
                    row.* = cells;
                }
                block.* = .{ .table = .{ .header = header, .rows = rows } };
            },
            .code, .rule => {},
        };
        return out;
    }

    fn inlines(self: *Linker, list: []const ir.Inline, owner: *const ir.Symbol) Allocator.Error![]const ir.Inline {
        const out = try self.arena.dupe(ir.Inline, list);
        for (out) |*piece| switch (piece.*) {
            .ref => |ref| {
                if (ref.target.len != 0) {
                    _ = try self.aim(ref.target);
                    continue;
                }
                switch (try self.cite(ref.text, owner)) {
                    .linked => |target| piece.* = .{ .ref = .{ .text = ref.text, .target = try self.aim(target.symbol.id) } },
                    .parameter => piece.* = .{ .param = ref.text },
                    .accepted => piece.* = .{ .code = ref.text },
                    .unknown => {
                        var reported = false;
                        for (self.problems.items) |problem| {
                            if (problem.kind == .symbol and std.mem.eql(u8, problem.citation, ref.text) and
                                std.mem.eql(u8, problem.owner, owner.qualified_name) and std.mem.eql(u8, problem.path, self.unit.file.path)) reported = true;
                        }
                        if (!reported) try self.report(owner, ref.text, .symbol);
                    },
                }
            },
            .emphasis => |content| piece.* = .{ .emphasis = try self.inlines(content, owner) },
            .strong => |content| piece.* = .{ .strong = try self.inlines(content, owner) },
            .link => |linked| piece.* = .{ .link = .{ .url = linked.url, .content = try self.inlines(linked.content, owner) } },
            else => {},
        };
        return out;
    }

    fn cite(self: *Linker, citation: []const u8, owner: *const ir.Symbol) Allocator.Error!Outcome {
        const name = if (std.mem.endsWith(u8, citation, "()")) citation[0 .. citation.len - 2] else citation;
        var parts: markdown_text.Parts = .{ .rest = name };
        const first = parts.next().?;
        const dotted = first.len != name.len;
        var current = self.inScope(first) orelse (if (self.lexical) null else self.anywhere(first)) orelse {
            if (!dotted) {
                for (owner.params) |param| {
                    if (std.mem.eql(u8, param.name, name)) return .parameter;
                }
            }
            if (dotted or hasIdentifier(owner.signature, name) or self.isLanguageWord(name)) return .accepted;
            for (self.external) |known| {
                if (std.mem.eql(u8, known, name)) return .accepted;
            }
            return .unknown;
        };
        while (parts.next()) |part| {
            current = try self.through(current, max_indirections);
            const members = current.symbol.members;
            if (named(members, part)) |member| {
                current = .{ .file = current.file, .symbol = member };
            } else if (current.symbol.kind == .namespace) {
                current = self.inNamespace(current.symbol.qualified_name, part) orelse return .accepted;
            } else return if (members.len == 0) .accepted else .unknown;
        }
        return .{ .linked = current };
    }

    fn inScope(self: *Linker, name: []const u8) ?Scope {
        var index = self.scopes.items.len;
        while (index > 0) {
            index -= 1;
            const symbol = named(self.scopes.items[index], name) orelse continue;
            const owner = self.owners.items[index];
            const constructs = owner.kind == .type and symbol.kind == .function and std.mem.eql(u8, owner.name, name);
            return .{ .file = self.unit.file, .symbol = if (constructs) owner else symbol };
        }
        return null;
    }

    fn anywhere(self: *Linker, name: []const u8) ?Scope {
        if (nested(self.unit.symbol.members, name)) |symbol| return .{ .file = self.unit.file, .symbol = symbol };
        for (self.units) |unit| {
            if (unit.symbol == self.unit.symbol) continue;
            if (nested(unit.symbol.members, name)) |symbol| return .{ .file = unit.file, .symbol = symbol };
        }
        return null;
    }

    fn inNamespace(self: *Linker, qualified_name: []const u8, name: []const u8) ?Scope {
        for (self.units) |unit| {
            if (spread(unit.symbol.members, qualified_name, name)) |symbol| return .{ .file = unit.file, .symbol = symbol };
        }
        return null;
    }

    fn through(self: *Linker, found: Scope, budget: usize) Allocator.Error!Scope {
        if (budget == 0 or found.symbol.kind != .alias) return found;
        if (isImport(found.symbol)) return try self.imported(found, found.symbol.value) orelse found;
        const target = try self.expression(found, found.symbol.value, budget - 1) orelse return found;
        return self.through(target, budget - 1);
    }

    fn imported(self: *Linker, from: Scope, name: []const u8) Allocator.Error!?Scope {
        if (name.len == 0) return null;
        for (from.file.imports) |import| {
            if (import.path.len == 0 or !std.mem.eql(u8, import.name, name)) continue;
            return self.unitAt(import.path);
        }
        return null;
    }

    fn expression(self: *Linker, from: Scope, source: []const u8, budget: usize) Allocator.Error!?Scope {
        var rest = source;
        var current: Scope = undefined;
        const open = "@import(\"";
        if (std.mem.startsWith(u8, rest, open)) {
            const close = std.mem.indexOf(u8, rest, "\")") orelse return null;
            current = try self.imported(from, rest[open.len..close]) orelse return null;
            rest = std.mem.trimStart(u8, rest[close + 2 ..], ".");
            if (rest.len == 0) return current;
        } else {
            const first_end = std.mem.indexOfScalar(u8, rest, '.') orelse rest.len;
            const root = self.rootOf(from.file) orelse return null;
            current = .{ .file = from.file, .symbol = named(root.members, rest[0..first_end]) orelse return null };
            if (first_end == rest.len) return current;
            rest = rest[first_end + 1 ..];
        }
        var parts = std.mem.splitScalar(u8, rest, '.');
        while (parts.next()) |part| {
            current = try self.through(current, budget);
            current = .{ .file = current.file, .symbol = named(current.symbol.members, part) orelse return null };
        }
        return current;
    }

    fn rootOf(self: *Linker, file: *const ir.File) ?*const ir.Symbol {
        for (self.units) |unit| {
            if (unit.file == file) return unit.symbol;
        }
        for (self.fetched.items) |unit| {
            if (&unit.file == file) return &unit.symbol;
        }
        return null;
    }

    fn unitAt(self: *Linker, path: []const u8) Allocator.Error!?Scope {
        for (self.units) |unit| {
            if (std.mem.eql(u8, unit.file.path, path)) return unit;
        }
        for (self.fetched.items) |unit| {
            if (std.mem.eql(u8, unit.file.path, path)) return .{ .file = &unit.file, .symbol = &unit.symbol };
        }
        const source = self.source orelse return null;
        const unit = try source.find(source.context, path) orelse return null;
        try self.fetched.append(self.arena, unit);
        return .{ .file = &unit.file, .symbol = &unit.symbol };
    }

    fn isLanguageWord(self: *Linker, name: []const u8) bool {
        const language = self.unit.file.language;
        if (std.mem.eql(u8, language, "zig")) return std.zig.Token.getKeyword(name) != null or std.zig.primitives.isPrimitive(name);
        if (std.mem.eql(u8, language, "c")) return c_words.has(name);
        if (std.mem.eql(u8, language, "cpp")) return c_words.has(name) or cpp_words.has(name);
        if (std.mem.eql(u8, language, "csharp")) return csharp_words.has(name) or csharp_library.has(name);
        return false;
    }

    fn wanted(self: *Linker, id: []const u8) bool {
        var targets = self.targets.keyIterator();
        while (targets.next()) |target| {
            if (!std.mem.startsWith(u8, target.*, id)) continue;
            if (target.len == id.len or target.*[id.len] == '.') return true;
        }
        return false;
    }

    fn narrowed(self: *Linker, unit: ir.Unit) Allocator.Error!?ir.Unit {
        var members: std.ArrayList(ir.Symbol) = .empty;
        var imports: std.ArrayList(ir.Import) = .empty;
        for (unit.symbol.members) |*member| {
            if (!self.wanted(member.id)) continue;
            var kept = member.*;
            if (isImport(member)) {
                for (unit.file.imports) |import| {
                    if (!std.mem.eql(u8, import.name, member.value)) continue;
                    try imports.append(self.arena, import);
                    for (self.fetched.items) |other| {
                        if (std.mem.eql(u8, other.file.path, import.path)) kept.target = other.symbol.id;
                    }
                    break;
                }
            }
            try members.append(self.arena, kept);
        }
        if (members.items.len == 0 and !self.targets.contains(unit.symbol.id)) return null;
        var out = unit;
        out.symbol.members = try members.toOwnedSlice(self.arena);
        out.file.imports = try imports.toOwnedSlice(self.arena);
        return out;
    }
};

const Place = struct {
    symbol: *const ir.Symbol,
    parent: ?*const ir.Symbol,
};

fn within(list: []const ir.Symbol, parent: ?*const ir.Symbol, id: []const u8) ?Place {
    if (id.len == 0) return null;
    for (list) |*symbol| {
        if (std.mem.eql(u8, symbol.id, id)) return .{ .symbol = symbol, .parent = parent };
        if (within(symbol.members, symbol, id)) |found| return found;
    }
    return null;
}

fn isNameStart(ch: u8) bool {
    return std.ascii.isAlphabetic(ch) or ch == '_';
}

fn named(list: []const ir.Symbol, name: []const u8) ?*const ir.Symbol {
    for (list) |*symbol| {
        if (std.mem.eql(u8, symbol.name, name)) return symbol;
    }
    return null;
}

fn spread(list: []const ir.Symbol, qualified_name: []const u8, name: []const u8) ?*const ir.Symbol {
    for (list) |*symbol| {
        if (symbol.kind != .namespace) continue;
        if (std.mem.eql(u8, symbol.qualified_name, qualified_name)) {
            if (named(symbol.members, name)) |found| return found;
        }
        if (spread(symbol.members, qualified_name, name)) |found| return found;
    }
    return null;
}

fn nested(list: []const ir.Symbol, name: []const u8) ?*const ir.Symbol {
    if (named(list, name)) |symbol| return symbol;
    for (list) |*symbol| {
        if (nested(symbol.members, name)) |found| return found;
    }
    return null;
}

fn hasIdentifier(haystack: []const u8, name: []const u8) bool {
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, at, name)) |found| {
        const stop = found + name.len;
        const starts = found == 0 or !(std.ascii.isAlphanumeric(haystack[found - 1]) or haystack[found - 1] == '_');
        const stops = stop == haystack.len or !(std.ascii.isAlphanumeric(haystack[stop]) or haystack[stop] == '_');
        if (starts and stops) return true;
        at = found + 1;
    }
    return false;
}

const zig_source = @import("zig_source.zig");
const c_source = @import("c_source.zig");
const csharp_source = @import("csharp_source.zig");

fn documentOf(arena: Allocator, units: []const ir.Unit) !ir.Document {
    const files = try arena.alloc(ir.File, units.len);
    const symbols = try arena.alloc(ir.Symbol, units.len);
    for (files, symbols, units) |*file, *symbol, unit| {
        file.* = unit.file;
        symbol.* = unit.symbol;
    }
    return .{ .files = files, .symbols = symbols };
}

fn linkZig(arena: Allocator, source: [:0]const u8) !Result {
    return link(arena, try documentOf(arena, &.{try zig_source.read(arena, "a.zig", source)}), .{});
}

fn pieces(text: ir.Text) []const ir.Inline {
    return text.blocks[0].paragraph;
}

fn targetOf(text: ir.Text, citation: []const u8) ?[]const u8 {
    for (pieces(text)) |piece| {
        if (piece == .ref and std.mem.eql(u8, piece.ref.text, citation)) return piece.ref.target;
    }
    return null;
}

test "a mention gets the symbol it names as its target, by plain or qualified name" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const result = try linkZig(arena.allocator(),
        \\//! See `Task`, `run`, `Task.run` and `wait()`.
        \\const Task = struct {
        \\    fn run() void {}
        \\};
        \\fn wait() void {}
    );
    try std.testing.expectEqual(0, result.problems.len);
    try std.testing.expect(result.document.linked);
    const doc = result.document.symbols[0].doc;
    try std.testing.expectEqualStrings("zig:a.zig#Task", targetOf(doc, "Task").?);
    try std.testing.expectEqualStrings("zig:a.zig#Task.run", targetOf(doc, "run").?);
    try std.testing.expectEqualStrings("zig:a.zig#Task.run", targetOf(doc, "Task.run").?);
    try std.testing.expectEqualStrings("zig:a.zig#wait", targetOf(doc, "wait()").?);
}

test "the nearest scope wins when a name is declared twice" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const result = try linkZig(arena.allocator(),
        \\fn run() void {}
        \\const Task = struct {
        \\    /// Calls `run`.
        \\    fn start() void {}
        \\    fn run() void {}
        \\};
    );
    const start = result.document.symbols[0].members[1].members[0];
    try std.testing.expectEqualStrings("zig:a.zig#Task.run", targetOf(start.doc, "run").?);
}

test "a mention that names nothing is reported once and stays a mention without a target" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const result = try linkZig(arena.allocator(),
        \\const Task = struct {
        \\    /// Calls `finish`, then `finish` again and `Task.stop`.
        \\    fn run() void {}
        \\};
    );
    try std.testing.expectEqual(2, result.problems.len);
    try std.testing.expectEqualStrings("finish", result.problems[0].citation);
    try std.testing.expectEqualStrings("Task.run", result.problems[0].owner);
    try std.testing.expectEqualStrings("Task.stop", result.problems[1].citation);
    const run = result.document.symbols[0].members[0].members[0];
    try std.testing.expectEqualStrings("", targetOf(run.doc, "finish").?);
}

test "a parameter becomes a parameter mention and a word of the language becomes code" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const result = try linkZig(arena.allocator(),
        \\/// Adds `left` as `u32`, never `null`, to a `Sum`.
        \\fn add(left: u32) Sum {
        \\    return left;
        \\}
    );
    try std.testing.expectEqual(0, result.problems.len);
    try std.testing.expectEqualDeep(@as([]const ir.Inline, &.{
        .{ .text = "Adds " },
        .{ .param = "left" },
        .{ .text = " as " },
        .{ .code = "u32" },
        .{ .text = ", never " },
        .{ .code = "null" },
        .{ .text = ", to a " },
        .{ .code = "Sum" },
        .{ .text = "." },
    }), pieces(result.document.symbols[0].members[0].doc));
}

test "a dotted name is accepted when its first part is unknown or was not followed" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const result = try linkZig(arena.allocator(),
        \\//! See `build.zig`, `error.OutOfMemory` and `std.mem.Allocator`.
        \\const std = @import("std");
    );
    try std.testing.expectEqual(0, result.problems.len);
    for (pieces(result.document.symbols[0].doc)) |piece| try std.testing.expect(piece != .ref);
}

test "an import and an alias lead to the symbol in the other file" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var main = try zig_source.read(allocator, "main.zig",
        \\//! Uses `model.Entry.name`, `Entry` and `Name`.
        \\const model = @import("model.zig");
        \\const Entry = model.Entry;
        \\const Name = @import("model.zig").Entry.name;
    );
    main.file.imports = &.{.{ .name = "model.zig", .kind = .file, .path = "model.zig" }};
    const other = try zig_source.read(allocator, "model.zig",
        \\pub const Entry = struct {
        \\    name: []const u8,
        \\};
    );
    const result = try link(allocator, try documentOf(allocator, &.{ other, main }), .{});
    try std.testing.expectEqual(0, result.problems.len);
    const linked = result.document.symbols[1];
    try std.testing.expectEqualStrings("zig:model.zig#Entry.name", targetOf(linked.doc, "model.Entry.name").?);
    try std.testing.expectEqualStrings("zig:model.zig", linked.members[0].target);
    try std.testing.expectEqualStrings("zig:model.zig#Entry", linked.members[1].target);
    try std.testing.expectEqualStrings("zig:model.zig#Entry.name", linked.members[2].target);
}

test "a name declared in a file of another language is found, and an undocumented file raises no problem" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const zig = try zig_source.read(allocator, "a.zig", "//! Fills a `ke_error` through `ke_pool.wait`.\n");
    var header = try c_source.read(allocator, .c, "pool.h",
        \\/** Cites `nothing_declared`. */
        \\typedef struct ke_error ke_error;
        \\typedef struct ke_pool { bool (*wait)(void); } ke_pool;
    , &.{});
    header.file.documented = false;
    const result = try link(allocator, try documentOf(allocator, &.{ header, zig }), .{});
    try std.testing.expectEqual(0, result.problems.len);
    try std.testing.expectEqualStrings("c:pool.h#ke_error", targetOf(result.document.symbols[1].doc, "ke_error").?);
    try std.testing.expectEqualStrings("c:pool.h#ke_pool.wait", targetOf(result.document.symbols[1].doc, "ke_pool.wait").?);
}

test "a documented parameter that the signature does not have is reported" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const header = try c_source.read(allocator, .c, "a.h",
        \\/**
        \\ * @param t The task, never `NULL`.
        \\ * @param timeout Unused.
        \\ */
        \\bool wait(task *t);
    , &.{});
    const result = try link(allocator, try documentOf(allocator, &.{header}), .{});
    try std.testing.expectEqual(1, result.problems.len);
    try std.testing.expectEqualStrings("timeout", result.problems[0].citation);
    try std.testing.expectEqual(Problem.Kind.parameter, result.problems[0].kind);
}

const Shelf = struct {
    unit: ir.Unit,
    asked: usize = 0,

    fn find(context: *anyopaque, path: []const u8) Allocator.Error!?*const ir.Unit {
        const shelf: *Shelf = @ptrCast(@alignCast(context));
        shelf.asked += 1;
        return if (std.mem.eql(u8, path, shelf.unit.file.path)) &shelf.unit else null;
    }
};

test "a name that leads outside the document is followed into what the source supplies, which joins the document cut down" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var main = try zig_source.read(allocator, "main.zig",
        \\//! Takes a `lib.Buffer`, never a `lib.Missing`. See `Buffer`.
        \\const lib = @import("lib");
        \\const Buffer = lib.Buffer;
    );
    main.file.imports = &.{.{ .name = "lib", .kind = .module, .path = "lib/lib.zig" }};
    var shelf: Shelf = .{ .unit = try zig_source.read(allocator, "lib/lib.zig", "pub const Buffer = struct {};\npub const Other = struct {};\n") };
    shelf.unit.file.documented = false;
    const result = try link(allocator, try documentOf(allocator, &.{main}), .{ .source = .{ .context = &shelf, .find = Shelf.find } });

    try std.testing.expectEqual(1, result.problems.len);
    try std.testing.expectEqualStrings("lib.Missing", result.problems[0].citation);
    try std.testing.expectEqual(1, shelf.asked);
    try std.testing.expectEqual(2, result.document.symbols.len);
    try std.testing.expectEqualStrings("lib/lib.zig", result.document.files[0].path);
    try std.testing.expectEqual(1, result.document.symbols[0].members.len);
    try std.testing.expectEqualStrings("Buffer", result.document.symbols[0].members[0].name);
    const linked = result.document.symbols[1];
    try std.testing.expectEqualStrings("zig:lib/lib.zig#Buffer", targetOf(linked.doc, "lib.Buffer").?);
    try std.testing.expectEqualStrings("zig:lib/lib.zig#Buffer", linked.members[1].target);
}

test "a type gets the first name written in it that is a type, and a name of nothing leaves it without a target" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const result = try linkZig(arena.allocator(),
        \\const Task = struct {};
        \\fn run() void {}
        \\fn take(task: ?*const Task, count: u32, other: run) []Task {
        \\    _ = .{ task, count, other };
        \\}
        \\fn write(writer: anytype, shape: struct { task: Task }) @TypeOf(writer).Task!void {
        \\    _ = shape;
        \\}
    );
    const write = result.document.symbols[0].members[3];
    try std.testing.expectEqualStrings("", write.params[1].type.target);
    try std.testing.expectEqualStrings("", write.type.target);
    try std.testing.expectEqual(0, result.problems.len);
    const take = result.document.symbols[0].members[2];
    try std.testing.expectEqualStrings("zig:a.zig#Task", take.params[0].type.target);
    try std.testing.expectEqualStrings("", take.params[1].type.target);
    try std.testing.expectEqualStrings("", take.params[2].type.target);
    try std.testing.expectEqualStrings("zig:a.zig#Task", take.type.target);
}

test "a mention written with the separator of C++ names the member, and a base gets its class" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const header = try c_source.read(allocator, .cpp, "pool.hpp",
        \\namespace ke {
        \\class Base {};
        \\/** Waits through `Pool::wait()` or `ke::Pool::wait`. */
        \\class Pool : public Base {
        \\public:
        \\    void wait();
        \\};
        \\}
    , &.{});
    const result = try link(allocator, try documentOf(allocator, &.{header}), .{});
    try std.testing.expectEqual(0, result.problems.len);
    const pool = result.document.symbols[0].members[0].members[1];
    try std.testing.expectEqualStrings("cpp:pool.hpp#ke::Pool::wait()", targetOf(pool.doc, "Pool::wait()").?);
    try std.testing.expectEqualStrings("cpp:pool.hpp#ke::Pool::wait()", targetOf(pool.doc, "ke::Pool::wait").?);
    try std.testing.expectEqualStrings("cpp:pool.hpp#ke::Base", pool.bases[0].target);
}

test "a name qualified by a namespace is found in whichever file declares it there" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const first = try csharp_source.read(allocator, "A.cs",
        \\namespace Ke.Tasks;
        \\/// <summary>Runs on a <see cref="Ke.Tasks.Worker"/>, see <see cref="Worker.Stop"/>.</summary>
        \\public class Pool {
        \\    public Worker Take(int index) => null;
        \\    /// <summary>Makes a <see cref="Pool"/>.</summary>
        \\    public Pool() { }
        \\}
    );
    const second = try csharp_source.read(allocator, "B.cs",
        \\namespace Ke.Tasks;
        \\public class Worker { public void Stop() { } }
    );
    const result = try link(allocator, try documentOf(allocator, &.{ first, second }), .{});
    try std.testing.expectEqual(0, result.problems.len);
    const pool = result.document.symbols[0].members[0].members[0].members[0];
    try std.testing.expectEqualStrings("csharp:A.cs#Ke.Tasks.Pool", targetOf(pool.members[1].doc, "Pool").?);
    try std.testing.expectEqualStrings("csharp:B.cs#Ke.Tasks.Worker", targetOf(pool.doc, "Ke.Tasks.Worker").?);
    try std.testing.expectEqualStrings("csharp:B.cs#Ke.Tasks.Worker.Stop()", targetOf(pool.doc, "Worker.Stop").?);
    try std.testing.expectEqualStrings("csharp:B.cs#Ke.Tasks.Worker", pool.members[0].type.target);
}

test "a symbol that asks for the documentation of another is given what it does not say itself" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const contract = try csharp_source.read(allocator, "IPool.cs",
        \\namespace Ke;
        \\/// <summary>Runs tasks.</summary>
        \\public interface IPool {
        \\    /// <summary>Runs one.</summary>
        \\    /// <param name="count">How many times.</param>
        \\    /// <returns>Whether it ran.</returns>
        \\    bool Run(int count);
        \\}
    );
    const made = try csharp_source.read(allocator, "Pool.cs",
        \\namespace Ke;
        \\/// <inheritdoc/>
        \\public class Pool : IPool {
        \\    /// <inheritdoc/>
        \\    /// <param name="count">Never zero.</param>
        \\    public bool Run(int count) => true;
        \\}
        \\public class Fast : Pool {
        \\    /// <inheritdoc/>
        \\    public bool Run(int count) => true;
        \\    /// <inheritdoc cref="IPool"/>
        \\    public void Other() { }
        \\}
    );
    const result = try link(allocator, try documentOf(allocator, &.{ contract, made }), .{});
    try std.testing.expectEqual(0, result.problems.len);
    const types = result.document.symbols[1].members[0].members;
    try std.testing.expectEqualStrings("Runs tasks.", pieces(types[0].doc)[0].text);
    const run = types[0].members[0];
    try std.testing.expectEqualStrings("Runs one.", pieces(run.doc)[0].text);
    try std.testing.expectEqualStrings("Never zero.", pieces(run.params[0].doc)[0].text);
    try std.testing.expectEqualStrings("Whether it ran.", pieces(run.returns)[0].text);
    try std.testing.expectEqualStrings("Runs one.", pieces(types[1].members[0].doc)[0].text);
    try std.testing.expectEqualStrings("How many times.", pieces(types[1].members[0].params[0].doc)[0].text);
    try std.testing.expectEqualStrings("Runs tasks.", pieces(types[1].members[1].doc)[0].text);
}

test "a name declared outside the sources is no problem when it is known to the language or was given as external" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const file = try csharp_source.read(allocator, "A.cs",
        \\/// <summary>Gives a <see cref="Task"/> a <see cref="TomlTable"/>, a <see cref="Toml.Parse"/> and a <see cref="Missing"/>.</summary>
        \\public class Pool { }
    );
    const result = try link(allocator, try documentOf(allocator, &.{file}), .{ .external = &.{ "TomlTable", "Toml" } });
    try std.testing.expectEqual(1, result.problems.len);
    try std.testing.expectEqualStrings("Missing", result.problems[0].citation);
}
