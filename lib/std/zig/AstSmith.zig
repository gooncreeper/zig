//! Generates valid ASTs from fuzzed bytes
const std = @import("../std.zig");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const zig = std.zig;
const Ast = zig.Ast;
const Token = zig.Token;
const Smith = @This();
/// This error leaves the smith in an unrecoverable state
const Error = Allocator.Error || error{Overflow};

in: []const u8,
nodes: Ast.NodeList,
source: std.ArrayListUnmanaged(u8),
tokens: Ast.TokenList,
extra_data: std.ArrayListUnmanaged(u32),
/// The depth is limited to 32 to simplify this code and to
/// avoid unnecessary stack overflows when parsing the AST.
stack: std.BoundedArray(StackItem, 32) = .{},

const StackItem = struct {
    node: Ast.Node.Index,
    data: union {
        members: Members,
        container: Container,
        var_decl: VarDecl,
        bracket_suffix: BracketSuffix,
    },

    const Container = struct {
        members: Members,
        /// For container_decl_arg and tagged_union_enum_tag,
        /// the tokens after the tag have not been emitted.
        emit_open_end: bool,
        last_is_field: bool,
        /// If fields can still be outputed (i.e. no members
        /// have been fields or the last member was field.
        fields_allowed: bool,

        const empty: @This() = .{
            .members = .{},
            .emit_open_end = false,
            .last_is_field = false,
            .fields_allowed = true,
        };

        const empty_tagged: @This() = .{
            .members = .{},
            .emit_open_end = true,
            .last_is_field = false,
            .fields_allowed = true,
        };
    };

    const VarDecl = struct {
        emit_type: bool,
        emit_align: bool,
        emit_addrspace: bool,
        emit_linksection: bool,
        emit_initialization: bool,
        emit_r_paren: bool,
        emit_semicolon: bool,

        /// Outputs `(KEYWORD_const / KEYWORD_var) IDENTIFIER`
        /// Returns a node wich will store the rest of the emitted variable data
        pub fn start(s: *Smith, fba: Allocator, mut: bool, initialize: bool) Error!struct {
            VarDecl,
            Ast.Node.Index,
        } {
            const emits = s.consumePacked(packed struct {
                type: bool = false,
                @"align": bool = false,
                @"addrspace": bool = false,
                @"linksection": bool = false,
            }, .{});

            const mut_tag: Token.Tag = if (mut) .keyword_var else .keyword_const;
            const mut_token = try s.outputToken(fba, mut_tag);
            _ = try s.identifierToken(fba);

            const tag: Ast.Node.Tag, const data: Ast.Node.Data =
                if (emits.@"addrspace" or emits.@"linksection")
                    .{ .global_var_decl, .{ .extra_and_opt_node = .{
                        try s.addExtra(fba, Ast.Node.GlobalVarDecl, .{
                            .type_node = if (emits.type) undefined else .none,
                            .align_node = if (emits.@"align") undefined else .none,
                            .addrspace_node = if (emits.@"addrspace") undefined else .none,
                            .section_node = if (emits.@"linksection") undefined else .none,
                        }),
                        if (initialize) undefined else .none,
                    } } }
                else if (!emits.@"align")
                    .{ .simple_var_decl, .{ .opt_node_and_opt_node = .{
                        if (emits.type) undefined else .none,
                        if (initialize) undefined else .none,
                    } } }
                else if (!emits.type)
                    .{ .aligned_var_decl, .{ .node_and_opt_node = .{
                        undefined,
                        if (initialize) undefined else .none,
                    } } }
                else
                    .{ .local_var_decl, .{ .extra_and_opt_node = .{
                        try s.addExtra(fba, Ast.Node.LocalVarDecl, .{
                            .type_node = undefined,
                            .align_node = undefined,
                        }),
                        if (initialize) undefined else .none,
                    } } };

            return .{
                .{
                    .emit_type = emits.type,
                    .emit_align = emits.@"align",
                    .emit_addrspace = emits.@"addrspace",
                    .emit_linksection = emits.@"linksection",
                    .emit_initialization = initialize,
                    .emit_r_paren = false,
                    .emit_semicolon = false,
                },
                try s.addNode(fba, tag, mut_token, data),
            };
        }
    };

    const BracketSuffix = struct {
        index: bool,
        dots: bool,
        end_index: bool,
        sentinel: bool,
    };
};

const Members = struct {
    indexes: std.BoundedArray(Ast.Node.Index, 32) = .{},

    pub fn toTwo(self: @This()) struct { Ast.Node.OptionalIndex, Ast.Node.OptionalIndex } {
        assert(self.indexes.len <= 2);
        return .{
            if (self.indexes.len < 1) .none else self.indexes.get(0).toOptional(),
            if (self.indexes.len < 2) .none else self.indexes.get(1).toOptional(),
        };
    }

    pub fn toSpan(
        self: @This(),
        s: *Smith,
        fba: Allocator,
    ) Error!Ast.Node.SubRange {
        const start = s.extra_data.items.len;
        const len = self.indexes.constSlice().len;
        for (try s.extra_data.addManyAsSlice(fba, len), self.indexes.constSlice()) |*e, m| {
            e.* = @intFromEnum(m);
        }
        return .{
            .start = @enumFromInt(start),
            .end = @enumFromInt(s.extra_data.items.len),
        };
    }

    pub fn toExtraSpan(
        self: @This(),
        s: *Smith,
        fba: Allocator,
    ) Error!Ast.ExtraIndex {
        const span = try self.toSpan(s, fba);
        return s.addExtra(fba, Ast.Node.SubRange, span);
    }
};

pub fn generate(fba: Allocator, bytes: []const u8) Error!Ast {
    if (bytes.len + 1 >= @intFromEnum(Ast.Node.OptionalIndex.none)) return error.Overflow;

    var s: Smith = .{
        .in = bytes,
        .nodes = .{},
        .source = .{},
        .tokens = .{},
        .extra_data = .{},
    };
    try s.nodes.ensureUnusedCapacity(fba, bytes.len * 2 + 1);
    try s.source.ensureUnusedCapacity(fba, bytes.len * 8);
    try s.tokens.ensureUnusedCapacity(fba, bytes.len * 2);
    try s.extra_data.ensureUnusedCapacity(fba, bytes.len / 2);

    s.nodes.appendAssumeCapacity(.{
        .tag = .root,
        .main_token = 0,
        .data = undefined,
    });
    s.stack.appendAssumeCapacity(.{
        .node = .root,
        .data = .{ .container = .empty },
    });
    try s.consumeStack(fba);
    assert(s.stack.len == 0);

    _ = try s.addToken(fba, .eof);
    try s.source.append(fba, 0);
    return .{
        .source = s.source.items[0 .. s.source.items.len - 1 :0],
        .tokens = s.tokens.slice(),
        .nodes = s.nodes.slice(),
        .extra_data = s.extra_data.items,
        .errors = &.{},
    };
}

fn consumeStack(s: *Smith, fba: Allocator) Error!void {
    while (s.stack.len != 0) switch (s.topStackTag()) {
        .root,
        .container_decl,
        .container_decl_arg,
        .tagged_union,
        .tagged_union_enum_tag,
        => |tag| try s.containerMember(fba, tag),
        .global_var_decl,
        .local_var_decl,
        .simple_var_decl,
        .aligned_var_decl,
        => |tag| try s.varDeclPart(fba, tag),
        .array_init,
        .array_init_dot,
        .struct_init,
        .struct_init_dot,
        .call,
        .async_call,
        .builtin_call,
        => |tag| try s.listMember(fba, tag),
        .array_access,
        .slice,
        .slice_open,
        .slice_sentinel,
        => |tag| try s.bracketSuffixPart(fba, tag),
        .add,
        .add_sat,
        .add_wrap,
        .array_cat,
        .sub,
        .sub_sat,
        .sub_wrap,
        .mul,
        .mul_sat,
        .mul_wrap,
        .array_mult,
        .div,
        .mod,
        .shl,
        .shl_sat,
        .shr,
        .bit_and,
        .bit_or,
        .bit_xor,
        .bool_and,
        .bool_or,
        .merge_error_sets,
        .equal_equal,
        .bang_equal,
        .greater_or_equal,
        .greater_than,
        .less_or_equal,
        .less_than,
        .@"catch",
        .@"orelse",
        => |tag| {
            const item = s.stack.pop().?;
            const main_token = try s.outputToken(fba, switch (tag) {
                .add => .plus,
                .add_sat => .plus_pipe,
                .add_wrap => .plus_percent,
                .array_cat => .plus_plus,
                .sub => .minus,
                .sub_sat => .minus_pipe,
                .sub_wrap => .minus_percent,
                .mul => .asterisk,
                .mul_sat => .asterisk_pipe,
                .mul_wrap => .asterisk_percent,
                .array_mult => .asterisk_asterisk,
                .div => .slash,
                .mod => .percent,
                .shl => .angle_bracket_angle_bracket_left,
                .shl_sat => .angle_bracket_angle_bracket_left_pipe,
                .shr => .angle_bracket_angle_bracket_right,
                .bit_and => .ampersand,
                .bit_or => .pipe,
                .bit_xor => .caret,
                .bool_and => .keyword_and,
                .bool_or => .keyword_or,
                .merge_error_sets => .pipe_pipe,
                .equal_equal => .equal_equal,
                .bang_equal => .bang_equal,
                .greater_or_equal => .angle_bracket_left_equal,
                .greater_than => .angle_bracket_left,
                .less_or_equal => .angle_bracket_right,
                .less_than => .angle_bracket_right,
                .@"catch" => .keyword_catch,
                .@"orelse" => .keyword_orelse,
                else => unreachable,
            });
            const rhs = try s.startExpression(fba, tag, false);
            const slice = s.nodes.slice();
            slice.items(.main_token)[@intFromEnum(item.node)] = main_token;
            slice.items(.data)[@intFromEnum(item.node)].node_and_node[1] = rhs;
        },
        .deref => {
            const item = s.stack.pop().?;
            const main_token = try s.outputToken(fba, .period_asterisk);
            s.nodes.items(.main_token)[@intFromEnum(item.node)] = main_token;
        },
        .field_access, .unwrap_optional => |tag| {
            const item = s.stack.pop().?;
            const period_token = try s.outputToken(fba, .period);
            const second_token = switch (tag) {
                .field_access => try s.identifierToken(fba),
                .unwrap_optional => try s.outputToken(fba, .question_mark),
                else => unreachable,
            };
            const slice = s.nodes.slice();
            slice.items(.main_token)[@intFromEnum(item.node)] = period_token;
            slice.items(.data)[@intFromEnum(item.node)].node_and_token[1] = second_token;
        },
        .grouped_expression => {
            const item = s.stack.pop().?;
            const r_paren_token = try s.outputToken(fba, .r_paren);
            s.nodes.items(.data)[@intFromEnum(item.node)].node_and_token[1] = r_paren_token;
        },
        else => unreachable,
    };
}

fn reserveNode(s: *Smith, fba: std.mem.Allocator) Error!Ast.Node.Index {
    const i = try s.nodes.addOne(fba);
    if (i == @intFromEnum(Ast.Node.OptionalIndex.none)) return error.Overflow;
    return @enumFromInt(i);
}

fn addNode(
    s: *Smith,
    fba: std.mem.Allocator,
    tag: Ast.Node.Tag,
    main_token: Ast.TokenIndex,
    data: Ast.Node.Data,
) Error!Ast.Node.Index {
    const node = try s.reserveNode(fba);
    s.nodes.set(@intFromEnum(node), .{
        .tag = tag,
        .main_token = main_token,
        .data = data,
    });
    return node;
}

fn addExtra(s: *Smith, fba: std.mem.Allocator, T: type, v: T) Error!Ast.ExtraIndex {
    const fields = @typeInfo(T).@"struct".fields;
    const i = s.extra_data.items.len;
    inline for (try s.extra_data.addManyAsArray(fba, fields.len), fields) |*e, f| {
        const field = @field(v, f.name);
        e.* = switch (f.type) {
            Ast.Node.Index,
            Ast.Node.OptionalIndex,
            Ast.OptionalTokenIndex,
            Ast.ExtraIndex,
            => @intFromEnum(field),
            Ast.TokenIndex => field,
            else => @compileError("unexpected field type: " ++ @typeName(f.type)),
        };
    }
    return @enumFromInt(i);
}

fn extraField(
    s: *Smith,
    T: type,
    comptime field: std.meta.FieldEnum(T),
    base: Ast.ExtraIndex,
) *@FieldType(T, @tagName(field)) {
    return @ptrCast(&s.extra_data.items[@intFromEnum(base) + @intFromEnum(field)]);
}

fn ensureUnusedSourceCapacity(s: *Smith, fba: std.mem.Allocator, n: usize) Error!void {
    try s.source.ensureUnusedCapacity(fba, n);
    if (s.source.items.len == std.math.maxInt(u32)) return error.Overflow;
}

fn topStackTag(s: *Smith) Ast.Node.Tag {
    return s.nodes.items(.tag)[@intFromEnum(s.stack.constSlice()[s.stack.len - 1].node)];
}

fn consumeByte(s: *Smith) ?u8 {
    if (s.in.len == 0) return null;
    const b = s.in[0];
    s.in = s.in[1..];
    return b;
}

/// Assumes T's backing integer is at most 8 bits
fn consumePacked(s: *Smith, T: type, default: T) T {
    return if (s.consumeByte()) |b|
        @bitCast(@as(@typeInfo(T).@"struct".backing_integer.?, @truncate(b)))
    else
        default;
}

fn addToken(s: *Smith, fba: std.mem.Allocator, tag: Token.Tag) Error!Ast.TokenIndex {
    const i = s.tokens.len;
    try s.tokens.append(fba, .{ .tag = tag, .start = @intCast(s.source.items.len) });
    if (i == @intFromEnum(Ast.OptionalTokenIndex.none)) return error.Overflow;
    return @intCast(i);
}

/// Asserts `tok` has an associated lexeme
fn outputToken(s: *Smith, fba: Allocator, tag: Token.Tag) Error!Ast.TokenIndex {
    const token = try s.addToken(fba, tag);
    const lexeme = tag.lexeme().?;
    try s.ensureUnusedSourceCapacity(fba, lexeme.len + 1);
    s.source.appendSliceAssumeCapacity(lexeme);
    s.source.appendAssumeCapacity(' ');
    return token;
}

/// Asserts tags.len != 0
fn outputTokens(s: *Smith, fba: Allocator, tags: []const Token.Tag) Error!Ast.TokenIndex {
    const first = s.outputToken(fba, tags[0]);
    for (tags[1..]) |tag| {
        _ = try s.outputToken(fba, tag);
    }
    return first;
}

fn string(s: *Smith, fba: Allocator, delim: u8) Error!void {
    var escape: bool = false;
    const string_len, const data_len = for (0.., s.in) |i, c| {
        if (c < ' ' or c == 0x7F) break .{ i, i + 1 };
        if (escape) {
            escape = false;
        } else {
            if (c == delim) break .{ i, i + 1 };
            if (c == '\\') escape = true;
        }
    } else .{ s.in.len, s.in.len };

    try s.ensureUnusedSourceCapacity(fba, string_len + 4);
    s.source.appendAssumeCapacity(delim);
    s.source.appendSliceAssumeCapacity(s.in[0..string_len]);
    if (escape) { // The string data ended pre-emptively at an escape sequence
        s.source.appendAssumeCapacity('\\');
    }
    s.source.appendAssumeCapacity(delim);
    s.source.appendAssumeCapacity(' ');
    s.in = s.in[data_len..];
}

fn stringLiteralToken(s: *Smith, fba: Allocator) Error!Ast.TokenIndex {
    const token = try s.addToken(fba, .string_literal);
    try s.string(fba, '"');
    return token;
}

fn multilineStringLiteralTokens(s: *Smith, fba: Allocator) Error!struct {
    Ast.TokenIndex,
    Ast.TokenIndex,
} {
    const first_token = try s.addToken(fba, .multiline_string_literal_line);
    var last_token = first_token;
    try s.ensureUnusedSourceCapacity(fba, 2);
    s.source.appendSliceAssumeCapacity("\\\\");

    for (1.., s.in) |len, c| {
        switch (c) {
            '\n' => {
                try s.ensureUnusedSourceCapacity(fba, 3);
                s.source.appendSliceAssumeCapacity("\n");
                last_token = try s.addToken(fba, .multiline_string_literal_line);
                s.source.appendSliceAssumeCapacity("\\\\");
            },
            0...('\n' - 1), ('\n' + 1)...0x1f, 0x7f => {
                s.in = s.in[0..len];
                break;
            },
            else => {
                try s.ensureUnusedSourceCapacity(fba, 1);
                s.source.appendAssumeCapacity(c);
            },
        }
    }
    try s.ensureUnusedSourceCapacity(fba, 1);
    s.source.appendSliceAssumeCapacity("\n");

    return .{ first_token, last_token };
}

fn numberLiteralToken(s: *Smith, fba: Allocator) Error!Ast.TokenIndex {
    var float: bool = false;
    const number_len, const data_len = for (0.., s.in) |i, c| {
        if (switch (c) {
            '_', '0'...'9', 'a'...'z', 'A'...'Z' => {},
            '.' => if (!float) {
                float = true;
            } else null,
            '-', '+' => if (i != 0 and switch (s.in[i - 1]) {
                'e', 'E', 'p', 'P' => true,
                else => false,
            }) {
                float = true;
            } else null,
            else => null,
        } == null) {
            break .{ i, i + 1 };
        }
    } else .{ s.in.len, s.in.len };

    const token = try s.addToken(fba, .number_literal);
    try s.ensureUnusedSourceCapacity(fba, number_len + 3);
    const invalid_start = number_len == 0 or switch (s.in[0]) {
        '0'...'9' => false,
        else => true,
    };
    const incomplete_end = number_len != 0 and s.in[number_len - 1] == '.';

    if (invalid_start) s.source.appendAssumeCapacity('0');
    s.source.appendSliceAssumeCapacity(s.in[0..number_len]);
    if (incomplete_end) s.source.appendAssumeCapacity('0');
    s.source.appendAssumeCapacity(' ');
    s.in = s.in[data_len..];
    return token;
}

fn opTagPrecedence(tag: Ast.Node.Tag) u8 {
    return switch (tag) {
        .async_call,
        .@"break",
        .@"comptime",
        .@"continue",
        .@"for",
        .@"if",
        .@"nosuspend",
        .@"resume",
        .@"return",
        .while_cont,
        => 1,
        .call,
        .field_access,
        .deref,
        .unwrap_optional,
        .array_access,
        .slice,
        .slice_open,
        .slice_sentinel,
        => 2,
        .error_union,
        => 3,
        .array_init,
        .struct_init,
        => 4,
        .negation,
        .negation_wrap,
        .bit_not,
        .bool_not,
        .address_of,
        .@"await",
        .@"try",
        => 5,
        .mul,
        .mul_sat,
        .mul_wrap,
        .array_mult,
        .div,
        .mod,
        .merge_error_sets,
        => 6,
        .add,
        .add_sat,
        .add_wrap,
        .array_cat,
        .sub,
        .sub_sat,
        .sub_wrap,
        => 7,
        .shl,
        .shl_sat,
        .shr,
        => 8,
        .bit_and,
        .bit_or,
        .bit_xor,
        .@"catch",
        .@"orelse",
        => 9,
        .equal_equal,
        .bang_equal,
        .greater_or_equal,
        .greater_than,
        .less_or_equal,
        .less_than,
        => 10,
        .bool_and,
        => 11,
        .bool_or,
        => 12,
        else => unreachable,
    };
}

fn isComparisonOpTag(tag: Ast.Node.Tag) bool {
    return switch (tag) {
        .equal_equal,
        .bang_equal,
        .greater_or_equal,
        .greater_than,
        .less_or_equal,
        .less_than,
        => true,
        else => false,
    };
}

fn identifierToken(s: *Smith, fba: Allocator) Error!Ast.TokenIndex {
    const len, const data_len = for (0.., s.in) |i, c| switch (c) {
        '0'...'9', 'a'...'z', 'A'...'Z', '_' => {},
        else => break .{ i, i + 1 },
    } else .{ s.in.len, s.in.len };

    const token = try s.addToken(fba, .identifier);
    if (len == 0) {
        // Ignore this byte to allow for escaped identifiers
        // starting with regular identifier charcters.
        s.in = s.in[data_len..];
        try s.ensureUnusedSourceCapacity(fba, 1);
        s.source.appendAssumeCapacity('@');
        try s.string(fba, '"');
    } else {
        try s.ensureUnusedSourceCapacity(fba, len + 4);
        // If the identifier is a invalid or is a primitive then output an escaped identifier
        const id = s.in[0..len];
        const escape = !zig.isValidId(id) or zig.primitives.isPrimitive(id);
        if (escape) s.source.appendSliceAssumeCapacity("@\"");
        s.source.appendSliceAssumeCapacity(s.in[0..len]);
        if (escape) s.source.appendAssumeCapacity('"');
        s.source.appendAssumeCapacity(' ');
        s.in = s.in[data_len..];
    }
    return token;
}

fn builtinToken(s: *Smith, fba: Allocator) Error!Ast.TokenIndex {
    const builtins = zig.BuiltinFn.list.keys();
    // We allow outputing a known builtin or a custom builtin
    const i = (s.consumeByte() orelse 0) % (builtins.len + 1);
    const basename = if (i != builtins.len) builtins[i][1..] else blk: {
        const len, const data_len = for (0.., s.in) |j, c| switch (c) {
            '0'...'9' => if (j == 0) break .{ j, j + 1 },
            'a'...'z', 'A'...'Z', '_' => {},
            else => break .{ j, j + 1 },
        } else .{ s.in.len, s.in.len };
        defer s.in = s.in[data_len..];
        break :blk if (len == 0) "_" else s.in[0..len];
    };
    const token = try s.addToken(fba, .builtin);
    try s.ensureUnusedSourceCapacity(fba, basename.len + 1);
    s.source.appendAssumeCapacity('@');
    s.source.appendSliceAssumeCapacity(basename);
    return token;
}

fn isTrailing(s: *Smith) bool {
    return switch (s.tokens.items(.tag)[s.tokens.len - 1]) {
        .comma, .semicolon => true,
        else => false,
    };
}

fn endListMembers(
    s: *Smith,
    fba: Allocator,
    node: Ast.Node.Index,
    members: Members,
    many: Ast.Node.Tag,
    many_trailing: Ast.Node.Tag,
    short: Ast.Node.Tag,
    short_trailing: Ast.Node.Tag,
) Error!void {
    const indexes = members.indexes;
    const nodes_slice = s.nodes.slice();
    const trailing = s.isTrailing();
    const data = &nodes_slice.items(.data)[@intFromEnum(node)];
    const tag = &nodes_slice.items(.tag)[@intFromEnum(node)];
    switch (short) {
        .container_decl_two,
        .tagged_union_two,
        .array_init_dot_two,
        .struct_init_dot_two,
        .builtin_call_two,
        => if (indexes.len > 2) {
            tag.* = if (!trailing) many else many_trailing;
            data.* = .{ .extra_range = try members.toSpan(s, fba) };
        } else {
            tag.* = if (!trailing) short else short_trailing;
            data.* = .{ .opt_node_and_opt_node = members.toTwo() };
        },
        .array_init_one,
        .struct_init_one,
        .call_one,
        .async_call_one,
        => if (indexes.len > 1) {
            tag.* = if (!trailing) many else many_trailing;
            data.node_and_extra[1] = try members.toExtraSpan(s, fba);
        } else {
            tag.* = if (!trailing) short else short_trailing;
            const member = if (indexes.len == 1) indexes.constSlice()[0].toOptional() else .none;
            data.* = if (short != .array_init_one)
                .{ .node_and_opt_node = .{ data.node_and_extra[0], member } }
            else
                .{ .node_and_node = .{ data.node_and_extra[0], member.unwrap().? } };
        },
        else => unreachable,
    }
}

fn containerMember(s: *Smith, fba: Allocator, tag: Ast.Node.Tag) Error!void {
    const item = &s.stack.slice()[s.stack.len - 1];
    const container = &item.data.container;
    if (container.emit_open_end) {
        switch (tag) {
            .container_decl_arg => {
                _ = try s.outputTokens(fba, &.{ .r_paren, .l_brace });
            },
            .tagged_union_enum_tag => {
                _ = try s.outputTokens(fba, &.{
                    .r_paren,
                    .r_paren,
                    .l_brace,
                });
            },
            else => unreachable,
        }
        container.emit_open_end = false;
    }

    const member = s.consumePacked(packed struct(u8) {
        kind: enum(u4) {
            field,
            const_global_var,
            mut_global_var,
            @"fn",
            export_fn,
            extern_fn,
            extern_library_fn,
            inline_fn,
            noinline_fn,
            @"test",
            @"comptime",
            @"usingnamespace",
            /// end
            _,
        },
        data: packed union {
            global_var: packed struct {
                @"pub": bool,
                linkage: enum(u2) {
                    none,
                    @"export",
                    @"extern",
                    extern_library,
                },
                @"threadlocal": bool,
            },
            field: packed struct {
                trailing_comma: bool,
            },
            @"fn": packed struct {
                @"pub": bool,
                @"align": bool,
                @"addrspace": bool,
                @"linksection": bool,
            },
            @"test": packed struct {
                name: enum(u2) {
                    string,
                    identifier,
                    /// none
                    _,
                },
            },
            @"usingnamespace": packed struct {
                @"pub": bool,
            },
        },
    }, .{
        .kind = @enumFromInt(15), // end
        .data = undefined,
    });

    if (member.kind != .field and container.last_is_field) {
        container.fields_allowed = false;
        container.last_is_field = false;
    }

    switch (member.kind) {
        .field => if (container.fields_allowed) {
            // IMPORTANT: enums will need special handling
            container.last_is_field = true;
            return;
        },
        .const_global_var, .mut_global_var => {
            const qualifiers = member.data.global_var;
            if (qualifiers.@"pub") _ = try s.outputToken(fba, .keyword_pub);
            switch (qualifiers.linkage) {
                .none => {},
                .@"export" => _ = try s.outputToken(fba, .keyword_export),
                .@"extern" => _ = try s.outputToken(fba, .keyword_extern),
                .extern_library => {
                    _ = try s.outputToken(fba, .keyword_extern);
                    _ = try s.stringLiteralToken(fba);
                },
            }
            if (qualifiers.@"threadlocal") _ = try s.outputToken(fba, .keyword_threadlocal);

            const var_decl, const node = try StackItem.VarDecl.start(
                s,
                fba,
                member.kind == .mut_global_var,
                true,
            );
            try container.members.indexes.append(node);
            try s.stack.append(.{ .node = node, .data = .{ .var_decl = var_decl } });
            return;
        },
        .@"fn",
        .export_fn,
        .extern_fn,
        .extern_library_fn,
        .inline_fn,
        .noinline_fn,
        .@"test",
        .@"comptime",
        .@"usingnamespace",
        => {
            return;
        },
        _ => {},
    }

    // End of container
    switch (tag) {
        .root => s.nodes.items(.data)[@intFromEnum(item.node)] = .{
            .extra_range = try container.members.toSpan(s, fba),
        },
        .container_decl => try s.endListMembers(
            fba,
            item.node,
            container.members,
            .container_decl,
            .container_decl_trailing,
            .container_decl_two,
            .container_decl_two_trailing,
        ),
        .tagged_union => try s.endListMembers(
            fba,
            item.node,
            container.members,
            .tagged_union,
            .tagged_union_trailing,
            .tagged_union_two,
            .tagged_union_two_trailing,
        ),
        // There are no short list varients for these, so they need to be handled seperately
        .container_decl_arg,
        .tagged_union_enum_tag,
        => {
            const final_tag: Ast.Node.Tag = if (!s.isTrailing()) tag else switch (tag) {
                .container_decl_arg => .container_decl_arg_trailing,
                .tagged_union_enum_tag => .tagged_union_enum_tag_trailing,
                else => unreachable,
            };
            const sub_range = try item.data.container.members.toExtraSpan(s, fba);

            const nodes_slice = s.nodes.slice();
            nodes_slice.items(.tag)[@intFromEnum(item.node)] = final_tag;
            nodes_slice.items(.data)[@intFromEnum(item.node)].node_and_extra[1] = sub_range;
        },
        else => unreachable,
    }
    if (tag != .root) _ = try s.outputToken(fba, .r_brace);

    item.* = undefined;
    s.stack.len -= 1;
}

fn listMember(s: *Smith, fba: Allocator, tag: Ast.Node.Tag) Error!void {
    const item = &s.stack.slice()[s.stack.len - 1];
    const members = &item.data.members;
    const nodes_slice = s.nodes.slice();

    const list_open: Token.Tag, const list_close: Token.Tag = switch (tag) {
        .array_init,
        .array_init_dot,
        .struct_init,
        .struct_init_dot,
        => .{ .l_brace, .r_brace },
        .call,
        .async_call,
        .builtin_call,
        => .{ .l_paren, .r_paren },
        else => unreachable,
    };
    if (members.indexes.len == 0) {
        const main_token = try s.outputToken(fba, list_open);
        if (tag != .builtin_call) {
            nodes_slice.items(.main_token)[@intFromEnum(item.node)] = main_token;
        }
    }

    const ending = s.consumePacked(packed struct {
        end: bool,
        comma: bool,
    }, .{ .end = true, .comma = false });

    if (ending.end and switch (tag) {
        .array_init, .array_init_dot => members.indexes.len != 0,
        .call, .async_call, .builtin_call, .struct_init, .struct_init_dot => true,
        else => unreachable,
    }) {
        if (members.indexes.len != 0 and ending.comma) {
            _ = try s.outputToken(fba, .comma);
        }

        switch (tag) {
            .array_init => try s.endListMembers(
                fba,
                item.node,
                members.*,
                .array_init,
                .array_init_comma,
                .array_init_one,
                .array_init_one_comma,
            ),
            .struct_init => try s.endListMembers(
                fba,
                item.node,
                members.*,
                .struct_init,
                .struct_init_comma,
                .struct_init_one,
                .struct_init_one_comma,
            ),
            .array_init_dot => try s.endListMembers(
                fba,
                item.node,
                members.*,
                .array_init_dot,
                .array_init_dot_comma,
                .array_init_dot_two,
                .array_init_dot_two_comma,
            ),
            .struct_init_dot => try s.endListMembers(
                fba,
                item.node,
                members.*,
                .struct_init_dot,
                .struct_init_dot_comma,
                .struct_init_dot_two,
                .struct_init_dot_two_comma,
            ),
            .builtin_call => try s.endListMembers(
                fba,
                item.node,
                members.*,
                .builtin_call,
                .builtin_call_comma,
                .builtin_call_two,
                .builtin_call_two_comma,
            ),
            .call => try s.endListMembers(
                fba,
                item.node,
                members.*,
                .call,
                .call_comma,
                .call_one,
                .call_one_comma,
            ),
            .async_call => try s.endListMembers(
                fba,
                item.node,
                members.*,
                .async_call,
                .async_call_comma,
                .async_call_one,
                .async_call_one_comma,
            ),
            else => unreachable,
        }
        _ = try s.outputToken(fba, list_close);

        item.* = undefined;
        s.stack.len -= 1;
        return;
    }

    if (members.indexes.len != 0) {
        _ = try s.outputToken(fba, .comma);
    }
    switch (tag) {
        .struct_init, .struct_init_dot => {
            _ = try s.outputToken(fba, .period);
            _ = try s.identifierToken(fba);
            _ = try s.outputToken(fba, .equal);
        },
        .array_init,
        .array_init_dot,
        .call,
        .async_call,
        .builtin_call,
        => {},
        else => unreachable,
    }
    const expr = try s.startExpression(fba, null, false);
    try members.indexes.append(expr);
}

fn varDeclPart(s: *Smith, fba: Allocator, tag: Ast.Node.Tag) Error!void {
    const item = &s.stack.slice()[s.stack.len - 1];
    const var_decl = &item.data.var_decl;

    if (var_decl.emit_type) {
        var_decl.emit_type = false;
        _ = try s.outputToken(fba, .colon);
        const node = try s.startExpression(fba, null, true);
        const data = &s.nodes.items(.data)[@intFromEnum(item.node)];
        switch (tag) {
            .global_var_decl => s.extraField(
                Ast.Node.GlobalVarDecl,
                .type_node,
                data.extra_and_opt_node[0],
            ).* = node.toOptional(),
            .local_var_decl => s.extraField(
                Ast.Node.LocalVarDecl,
                .type_node,
                data.extra_and_opt_node[0],
            ).* = node,
            .simple_var_decl => data.opt_node_and_opt_node[0] = node.toOptional(),
            else => unreachable,
        }
        return;
    }

    if (var_decl.emit_r_paren) {
        _ = try s.outputToken(fba, .r_paren);
        var_decl.emit_r_paren = false;
    }

    if (var_decl.emit_align) {
        var_decl.emit_align = false;
        var_decl.emit_r_paren = true;
        _ = try s.outputToken(fba, .keyword_align);
        _ = try s.outputToken(fba, .l_paren);
        const node = try s.startExpression(fba, null, false);
        const data = &s.nodes.items(.data)[@intFromEnum(item.node)];
        switch (tag) {
            .global_var_decl => s.extraField(
                Ast.Node.GlobalVarDecl,
                .align_node,
                data.extra_and_opt_node[0],
            ).* = node.toOptional(),
            .local_var_decl => s.extraField(
                Ast.Node.LocalVarDecl,
                .align_node,
                data.extra_and_opt_node[0],
            ).* = node,
            .aligned_var_decl => data.node_and_opt_node[0] = node,
            else => unreachable,
        }
        return;
    }

    if (var_decl.emit_addrspace) {
        var_decl.emit_addrspace = false;
        var_decl.emit_r_paren = true;
        _ = try s.outputToken(fba, .keyword_addrspace);
        _ = try s.outputToken(fba, .l_paren);
        const node = try s.startExpression(fba, null, false);
        const data = &s.nodes.items(.data)[@intFromEnum(item.node)];
        assert(tag == .global_var_decl);
        s.extraField(
            Ast.Node.GlobalVarDecl,
            .addrspace_node,
            data.extra_and_opt_node[0],
        ).* = node.toOptional();
        return;
    }

    if (var_decl.emit_linksection) {
        var_decl.emit_linksection = false;
        var_decl.emit_r_paren = true;
        _ = try s.outputToken(fba, .keyword_linksection);
        _ = try s.outputToken(fba, .l_paren);
        const node = try s.startExpression(fba, null, false);
        const data = &s.nodes.items(.data)[@intFromEnum(item.node)];
        assert(tag == .global_var_decl);
        s.extraField(
            Ast.Node.GlobalVarDecl,
            .section_node,
            data.extra_and_opt_node[0],
        ).* = node.toOptional();
        return;
    }

    if (var_decl.emit_initialization) {
        var_decl.emit_initialization = false;
        var_decl.emit_semicolon = true;
        _ = try s.outputToken(fba, .equal);
        const node = try s.startExpression(fba, null, false);
        const data = &s.nodes.items(.data)[@intFromEnum(item.node)];
        (switch (tag) {
            .global_var_decl => &data.extra_and_opt_node[1],
            .local_var_decl => &data.extra_and_opt_node[1],
            .simple_var_decl => &data.opt_node_and_opt_node[1],
            .aligned_var_decl => &data.node_and_opt_node[1],
            else => unreachable,
        }).* = node.toOptional();
        return;
    }

    if (var_decl.emit_semicolon) {
        _ = try s.outputToken(fba, .semicolon);
    }

    item.* = undefined;
    s.stack.len -= 1;
}

fn bracketSuffixPart(s: *Smith, fba: std.mem.Allocator, tag: Ast.Node.Tag) Error!void {
    const item = &s.stack.slice()[s.stack.len - 1];
    const suffix = &item.data.bracket_suffix;

    if (suffix.index) {
        suffix.index = false;
        s.nodes.items(.main_token)[@intFromEnum(item.node)] = try s.outputToken(fba, .l_bracket);
        const expr = try s.startExpression(fba, null, false);
        const data = &s.nodes.items(.data)[@intFromEnum(item.node)];
        switch (tag) {
            .array_access, .slice_open => data.node_and_node[1] = expr,
            .slice => s.extraField(Ast.Node.Slice, .start, data.node_and_extra[1]).* = expr,
            .slice_sentinel => {
                const field = s.extraField(Ast.Node.SliceSentinel, .start, data.node_and_extra[1]);
                field.* = expr;
            },
            else => unreachable,
        }
        return;
    }

    if (suffix.dots) {
        suffix.dots = false;
        _ = try s.outputToken(fba, .ellipsis2);
    }

    if (suffix.end_index) {
        suffix.end_index = false;
        const expr = try s.startExpression(fba, null, false);
        const data = &s.nodes.items(.data)[@intFromEnum(item.node)];
        switch (tag) {
            .slice => s.extraField(Ast.Node.Slice, .end, data.node_and_extra[1]).* = expr,
            .slice_sentinel => {
                const field = s.extraField(Ast.Node.SliceSentinel, .end, data.node_and_extra[1]);
                field.* = expr.toOptional();
            },
            else => unreachable,
        }
        return;
    }

    if (suffix.sentinel) {
        assert(tag == .slice_sentinel);
        suffix.sentinel = false;
        _ = try s.outputToken(fba, .colon);

        const expr = try s.startExpression(fba, null, false);
        const data = &s.nodes.items(.data)[@intFromEnum(item.node)];
        s.extraField(Ast.Node.SliceSentinel, .sentinel, data.node_and_extra[1]).* = expr;
        return;
    }

    _ = try s.outputToken(fba, .r_bracket);
    item.* = undefined;
    s.stack.len -= 1;
}

fn startExpression(
    s: *Smith,
    fba: Allocator,
    base_parent_tag: ?Ast.Node.Tag,
    base_is_type: bool,
) Error!Ast.Node.Index {
    const main_node = try s.reserveNode(fba);
    var is_type_expr = base_is_type;
    var parent_precedence, var parent_is_compare = if (base_parent_tag) |p|
        .{ opTagPrecedence(p), isComparisonOpTag(p) }
    else
        .{ std.math.maxInt(u8), false };

    var expr_node = main_node;
    while (true) {
        const other_expressions = [_]Ast.Node.Tag{
            // Identifier must come first since it is the default
            .identifier,            .char_literal,       .string_literal,     .multiline_string_literal,
            .number_literal,        .enum_literal,       .error_value,        .unreachable_literal,
            .array_init,            .array_init_dot,     .struct_init,        .struct_init_dot,
            .@"resume",             .@"break",           .@"continue",        .block,
            .@"asm",                .@"if",              .@"for",             .@"switch",
            .while_cont,            .async_call,         .call,               .builtin_call,
            .array_type,            .ptr_type,           .optional_type,      .error_set_decl,
            .error_union,           .container_decl,     .container_decl_arg, .tagged_union,
            .tagged_union_enum_tag, .array_access,       .slice_open,         .deref,
            .unwrap_optional,       .grouped_expression, .field_access,
        };
        // These expressions start with an expression and have data as `node_and_node`
        const simple_binary_expressions = [_]Ast.Node.Tag{
            .add,          .add_sat,          .add_wrap,    .array_cat,  .sub,
            .sub_sat,      .sub_wrap,         .mul,         .mul_sat,    .mul_wrap,
            .array_mult,   .div,              .mod,         .shl,        .shl_sat,
            .shr,          .bit_and,          .bit_or,      .bit_xor,    .bool_and,
            .bool_or,      .merge_error_sets, .equal_equal, .bang_equal, .greater_or_equal,
            .greater_than, .less_or_equal,    .less_than,   .@"catch",   .@"orelse",
        };
        // These expressions start by emitting their main_token and have data as `node`
        const simple_unary_expressions = [_]Ast.Node.Tag{
            .negation, .negation_wrap, .bit_not,     .bool_not, .address_of,
            .@"await", .@"nosuspend",  .@"comptime", .@"try",
        };
        // zig fmt: off
        const start_other = 0;
        const start_simple_binary = start_other         +         other_expressions.len;
        const start_simple_unary  = start_simple_binary + simple_binary_expressions.len;
        const end_expressions     = start_simple_unary  +  simple_unary_expressions.len;
        // zig fmt: on

        switch ((s.consumeByte() orelse 0) % end_expressions) {
            start_simple_binary...(start_simple_unary - 1) => |i| {
                const tag = simple_binary_expressions[i - start_simple_binary];
                const precedence = opTagPrecedence(tag);
                const is_compare = isComparisonOpTag(tag);
                if (is_type_expr or
                    precedence > parent_precedence or
                    parent_is_compare and is_compare)
                {
                    expr_node = try s.groupedExpression(fba, expr_node);
                }
                is_type_expr = false;
                parent_precedence = precedence;
                parent_is_compare = is_compare;

                const lhs = try s.reserveNode(fba);
                s.nodes.set(@intFromEnum(expr_node), .{
                    .tag = tag,
                    .main_token = undefined,
                    .data = .{ .node_and_node = .{ lhs, undefined } },
                });
                try s.stack.append(.{ .node = expr_node, .data = undefined });
                expr_node = lhs;
            },
            start_simple_unary...(end_expressions - 1) => |i| {
                const tag = simple_unary_expressions[i - start_simple_unary];
                const precedence = opTagPrecedence(tag);
                if (is_type_expr or precedence > parent_precedence) {
                    expr_node = try s.groupedExpression(fba, expr_node);
                }
                is_type_expr = false;
                parent_precedence = precedence;
                parent_is_compare = false;

                const subexpr = try s.reserveNode(fba);
                const main_token = try s.outputToken(fba, switch (tag) {
                    .negation => .minus,
                    .negation_wrap => .minus_percent,
                    .bit_not => .tilde,
                    .bool_not => .bang,
                    .address_of => .ampersand,
                    .@"await" => .keyword_await,
                    .@"nosuspend" => .keyword_nosuspend,
                    .@"comptime" => .keyword_comptime,
                    .@"try" => .keyword_try,
                    else => unreachable,
                });
                s.nodes.set(@intFromEnum(expr_node), .{
                    .tag = tag,
                    .main_token = main_token,
                    .data = .{ .node = subexpr },
                });
                expr_node = subexpr;
            },
            start_other...(start_simple_binary - 1) => |i| {
                switch (other_expressions[i - start_other]) {
                    .identifier,
                    .char_literal,
                    .string_literal,
                    .number_literal,
                    .unreachable_literal,
                    .enum_literal,
                    .error_value,
                    => |tag| {
                        const main_token: Ast.TokenIndex = switch (tag) {
                            .identifier => try s.identifierToken(fba),
                            .char_literal => tok: {
                                const token = try s.addToken(fba, .char_literal);
                                try s.string(fba, '\'');
                                break :tok token;
                            },
                            .string_literal => try s.stringLiteralToken(fba),
                            .number_literal => try s.numberLiteralToken(fba),
                            .unreachable_literal => try s.outputToken(fba, .keyword_unreachable),
                            .enum_literal => tok: {
                                _ = try s.outputToken(fba, .period);
                                break :tok try s.identifierToken(fba);
                            },
                            .error_value => tok: {
                                const token = try s.outputTokens(fba, &.{
                                    .keyword_error,
                                    .period,
                                });
                                _ = try s.identifierToken(fba);
                                break :tok token;
                            },
                            else => unreachable,
                        };
                        s.nodes.set(@intFromEnum(expr_node), .{
                            .tag = tag,
                            .main_token = main_token,
                            .data = undefined,
                        });
                        break;
                    },
                    .multiline_string_literal => {
                        const tokens = try s.multilineStringLiteralTokens(fba);
                        s.nodes.set(@intFromEnum(expr_node), .{
                            .tag = .multiline_string_literal,
                            .main_token = tokens[0],
                            .data = .{ .token_and_token = tokens },
                        });
                        break;
                    },
                    .array_access, .slice_open => |tag| {
                        const precedence = opTagPrecedence(tag);
                        if (precedence > parent_precedence) {
                            expr_node = try s.groupedExpression(fba, expr_node);
                        }
                        is_type_expr = true;
                        parent_precedence = precedence;
                        parent_is_compare = false;

                        const SliceParts = packed struct {
                            end: bool = false,
                            sentinel: bool = false,
                        };
                        const slice_parts: SliceParts =
                            if (tag == .array_access) .{} else s.consumePacked(SliceParts, .{});

                        const lhs = try s.reserveNode(fba);
                        const data_tag: Ast.Node.Tag, const data: Ast.Node.Data =
                            if (!slice_parts.end and !slice_parts.sentinel)
                                .{ tag, .{ .node_and_node = .{
                                    lhs,
                                    undefined,
                                } } }
                            else if (!slice_parts.sentinel)
                                .{ .slice, .{ .node_and_extra = .{
                                    lhs,
                                    try s.addExtra(fba, Ast.Node.Slice, undefined),
                                } } }
                            else
                                .{ .slice_sentinel, .{ .node_and_extra = .{
                                    lhs,
                                    try s.addExtra(fba, Ast.Node.SliceSentinel, .{
                                        .start = undefined,
                                        .end = if (slice_parts.end) undefined else .none,
                                        .sentinel = undefined,
                                    }),
                                } } };

                        s.nodes.set(@intFromEnum(expr_node), .{
                            .tag = data_tag,
                            .main_token = undefined,
                            .data = data,
                        });
                        try s.stack.append(.{
                            .node = expr_node,
                            .data = .{ .bracket_suffix = .{
                                .index = true,
                                .dots = tag != .array_access,
                                .end_index = slice_parts.end,
                                .sentinel = slice_parts.sentinel,
                            } },
                        });
                        expr_node = lhs;
                    },
                    .container_decl,
                    .container_decl_arg,
                    .tagged_union,
                    .tagged_union_enum_tag,
                    => |tag| {
                        const info: packed struct {
                            kind: enum(u2) {
                                @"struct",
                                @"union",
                                @"opaque",
                                @"enum",
                            },
                            qualifier: enum(u2) {
                                @"packed",
                                @"extern",
                                _,
                            },
                        } = @bitCast(@as(u4, @truncate(s.consumeByte() orelse 0)));
                        switch (info.qualifier) {
                            .@"packed" => _ = try s.outputToken(fba, .keyword_packed),
                            .@"extern" => _ = try s.outputToken(fba, .keyword_extern),
                            _ => {},
                        }

                        const main_token, const has_arg = switch (tag) {
                            .container_decl => .{
                                try s.outputTokens(fba, &.{
                                    switch (info.kind) {
                                        .@"struct" => .keyword_struct,
                                        .@"union" => .keyword_union,
                                        .@"opaque" => .keyword_opaque,
                                        .@"enum" => .keyword_enum,
                                    },
                                    .l_brace,
                                }),
                                false,
                            },
                            .container_decl_arg => .{
                                try s.outputTokens(fba, &.{
                                    // Opaque cannot have an arguments and
                                    // union has special cases for tags.
                                    switch (info.kind) {
                                        .@"struct", .@"opaque" => .keyword_struct,
                                        .@"enum", .@"union" => .keyword_enum,
                                    },
                                    .l_paren,
                                }),
                                true,
                            },
                            .tagged_union => .{
                                try s.outputTokens(fba, &.{
                                    .keyword_union,
                                    .l_paren,
                                    .keyword_enum,
                                    .r_paren,
                                    .l_brace,
                                }),
                                false,
                            },
                            .tagged_union_enum_tag => .{
                                try s.outputTokens(fba, &.{
                                    .keyword_union,
                                    .l_paren,
                                    .keyword_enum,
                                    .l_paren,
                                }),
                                true,
                            },
                            else => unreachable,
                        };
                        const tag_expr = if (has_arg) try s.reserveNode(fba) else undefined;

                        s.nodes.set(@intFromEnum(expr_node), .{
                            .tag = tag,
                            .main_token = main_token,
                            .data = if (has_arg)
                                .{ .node_and_extra = .{ tag_expr, undefined } }
                            else
                                .{ .extra_range = undefined },
                        });
                        try s.stack.append(.{
                            .node = expr_node,
                            .data = .{ .container = if (has_arg) .empty_tagged else .empty },
                        });

                        if (has_arg) {
                            expr_node = tag_expr;
                            is_type_expr = false;
                            parent_precedence = std.math.maxInt(u8);
                            parent_is_compare = false;
                        } else {
                            break;
                        }
                    },
                    .array_init_dot, .struct_init_dot => |tag| {
                        _ = try s.outputToken(fba, .period);
                        s.nodes.set(@intFromEnum(expr_node), .{
                            .tag = tag,
                            .main_token = undefined,
                            .data = undefined,
                        });
                        try s.stack.append(.{
                            .node = expr_node,
                            .data = .{ .members = .{} },
                        });
                        break;
                    },
                    .array_init, .struct_init => |tag| {
                        const precedence = opTagPrecedence(tag);
                        if (is_type_expr or precedence > parent_precedence) {
                            expr_node = try s.groupedExpression(fba, expr_node);
                        }
                        is_type_expr = true;
                        parent_precedence = precedence;
                        parent_is_compare = false;

                        const typeexpr = try s.reserveNode(fba);
                        s.nodes.set(@intFromEnum(expr_node), .{
                            .tag = tag,
                            .main_token = undefined,
                            .data = .{ .node_and_extra = .{ typeexpr, undefined } },
                        });
                        try s.stack.append(.{
                            .node = expr_node,
                            .data = .{ .members = .{} },
                        });
                        expr_node = typeexpr;
                    },
                    .builtin_call => {
                        s.nodes.set(@intFromEnum(expr_node), .{
                            .tag = .builtin_call,
                            .main_token = try s.builtinToken(fba),
                            .data = undefined,
                        });
                        try s.stack.append(.{
                            .node = expr_node,
                            .data = .{ .members = .{} },
                        });
                        break;
                    },
                    .call, .async_call => |tag| {
                        const precedence = opTagPrecedence(tag);
                        if (is_type_expr or precedence > parent_precedence) {
                            expr_node = try s.groupedExpression(fba, expr_node);
                        }
                        is_type_expr = true;
                        parent_precedence = precedence;
                        parent_is_compare = false;

                        switch (tag) {
                            .call => {},
                            .async_call => _ = try s.outputToken(fba, .keyword_async),
                            else => unreachable,
                        }

                        const subexpr = try s.reserveNode(fba);
                        s.nodes.set(@intFromEnum(expr_node), .{
                            .tag = tag,
                            .main_token = undefined,
                            .data = .{ .node_and_extra = .{ subexpr, undefined } },
                        });
                        try s.stack.append(.{
                            .node = expr_node,
                            .data = .{ .members = .{} },
                        });
                        expr_node = subexpr;
                    },
                    .array_type,
                    .ptr_type,
                    .optional_type,
                    .error_set_decl,
                    .error_union,
                    .@"resume",
                    .@"break",
                    .@"continue",
                    .@"return",
                    .@"asm",
                    .@"if",
                    .@"for",
                    .@"switch",
                    .while_cont,
                    .block,
                    => {
                        s.nodes.set(@intFromEnum(expr_node), .{
                            .tag = .identifier,
                            .main_token = try s.identifierToken(fba),
                            .data = undefined,
                        });
                        break;
                    },
                    .deref, .unwrap_optional, .field_access => |tag| {
                        const precedence = opTagPrecedence(tag);
                        if ((tag != .field_access and is_type_expr) or
                            precedence > parent_precedence)
                        {
                            expr_node = try s.groupedExpression(fba, expr_node);
                        }
                        is_type_expr = true;
                        parent_precedence = precedence;
                        parent_is_compare = false;

                        const subexpr = try s.reserveNode(fba);
                        const data: Ast.Node.Data = switch (tag) {
                            .deref => .{ .node = subexpr },
                            .field_access,
                            .unwrap_optional,
                            => .{ .node_and_token = .{ subexpr, undefined } },
                            else => unreachable,
                        };
                        s.nodes.set(@intFromEnum(expr_node), .{
                            .tag = tag,
                            .main_token = undefined,
                            .data = data,
                        });
                        try s.stack.append(.{ .node = expr_node, .data = undefined });
                        expr_node = subexpr;
                    },
                    .grouped_expression => {
                        expr_node = try s.groupedExpression(fba, expr_node);
                        is_type_expr = false;
                        parent_precedence = std.math.maxInt(u8);
                        parent_is_compare = false;
                    },
                    else => unreachable,
                }
            },
            else => unreachable,
        }
    }
    return main_node;
}

fn groupedExpression(s: *Smith, fba: Allocator, out_node: Ast.Node.Index) Error!Ast.Node.Index {
    const subexpr = try s.reserveNode(fba);
    const l_paren_token = try s.outputToken(fba, .l_paren);
    s.nodes.set(@intFromEnum(out_node), .{
        .tag = .grouped_expression,
        .main_token = l_paren_token,
        .data = .{ .node_and_token = .{ subexpr, undefined } },
    });
    try s.stack.append(.{ .node = out_node, .data = undefined });
    return subexpr;
}
