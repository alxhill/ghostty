//! Runtime-accessible metadata describing every configuration option.
//! This lets consumers such as a settings UI enumerate, display, and
//! edit the configuration generically without hardcoding each key.

const std = @import("std");
const Allocator = std.mem.Allocator;
const help_strings = @import("help_strings");
const Config = @import("Config.zig");
const RepeatableStringMap = @import("RepeatableStringMap.zig");
const io = @import("io.zig");
const path = @import("path.zig");
const formatter = @import("formatter.zig");
const Key = @import("key.zig").Key;

/// The broad kind of value an option accepts. Consumers can use this to
/// pick an appropriate editing control. Anything that doesn't fit one of
/// the more specific kinds is a `string`, which is always a valid way to
/// edit an option since it's the format used in configuration files.
///
/// ghostty_config_option_kind_e
pub const Kind = enum(c_int) {
    bool,
    int,
    float,

    /// A single value from `choices`.
    @"enum",

    /// A comma-separated set of `choices` where each can be prefixed
    /// with `no-` to disable it.
    flags,

    /// A color, typically formatted as `#rrggbb`. Some color options
    /// accept additional special values.
    color,

    string,
};

pub const Option = struct {
    key: Key,
    help: [:0]const u8,
    kind: Kind,

    /// True if the option can be unset, in which case it has no value.
    optional: bool,

    /// True if the option can be specified multiple times, with each
    /// occurrence adding a value.
    repeatable: bool,

    /// The valid values for `enum` and `flags` kinds. Empty otherwise.
    choices: []const [*:0]const u8,

    /// ghostty_config_option_s
    pub const C = extern struct {
        name: [*:0]const u8,
        help: [*:0]const u8,
        kind: Kind,
        optional: bool,
        repeatable: bool,
        choices: [*]const [*:0]const u8,
        choices_len: usize,
    };

    pub fn name(self: *const Option) [:0]const u8 {
        return @tagName(self.key);
    }

    pub fn cval(self: *const Option) C {
        return .{
            .name = self.name().ptr,
            .help = self.help.ptr,
            .kind = self.kind,
            .optional = self.optional,
            .repeatable = self.repeatable,
            .choices = self.choices.ptr,
            .choices_len = self.choices.len,
        };
    }
};

/// All configuration options in the order they're declared in Config.
pub const options: []const Option = options: {
    @setEvalBranchQuota(100_000);
    const fields = @typeInfo(Key).@"enum".fields;
    var result: [fields.len]Option = undefined;
    for (fields, &result) |field, *opt| {
        opt.* = option(@field(Key, field.name));
    }

    const final = result;
    break :options &final;
};

/// Returns the option with the given name, if it exists.
pub fn find(name: []const u8) ?*const Option {
    const key = std.meta.stringToEnum(Key, name) orelse return null;
    return &options[@intFromEnum(key)];
}

/// Format the value of the given key as it would be written in a
/// configuration file, excluding the key itself. Repeatable options
/// produce one value per line. Unset options produce an empty string.
pub fn formatValue(
    alloc: Allocator,
    config: *const Config,
    key: Key,
) Allocator.Error![:0]const u8 {
    @setEvalBranchQuota(100_000);

    // Format each entry with an empty name so every line is " = value".
    var entries: std.Io.Writer.Allocating = .init(alloc);
    defer entries.deinit();
    switch (key) {
        inline else => |tag| {
            const value = @field(config, @tagName(tag));
            formatter.formatEntry(
                @TypeOf(value),
                "",
                value,
                &entries.writer,
            ) catch return error.OutOfMemory;
        },
    }

    var result: std.Io.Writer.Allocating = .init(alloc);
    errdefer result.deinit();
    const prefix = " = ";
    var lines = std.mem.splitScalar(u8, entries.written(), '\n');
    var first = true;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (!first) result.writer.writeByte('\n') catch return error.OutOfMemory;
        first = false;
        const value = if (std.mem.startsWith(u8, line, prefix))
            line[prefix.len..]
        else
            line;
        result.writer.writeAll(value) catch return error.OutOfMemory;
    }

    return try result.toOwnedSliceSentinel(0);
}

/// Returns true if the value of the given key differs between configs.
pub fn changed(a: *const Config, b: *const Config, key: Key) bool {
    @setEvalBranchQuota(100_000);
    switch (key) {
        inline else => |tag| return a.changed(b, tag),
    }
}

fn option(comptime key: Key) Option {
    const name = @tagName(key);
    const Field = @FieldType(Config, name);
    const optional = @typeInfo(Field) == .optional;
    const T = if (optional) @typeInfo(Field).optional.child else Field;
    const kind = kindOf(T);
    return .{
        .key = key,
        .help = if (@hasDecl(help_strings.Config, name))
            @field(help_strings.Config, name)
        else
            "",
        .kind = kind,
        .optional = optional,
        .repeatable = isRepeatable(T),
        .choices = switch (kind) {
            .@"enum", .flags => choices(T),
            else => &.{},
        },
    };
}

fn kindOf(comptime T: type) Kind {
    if (T == bool) return .bool;
    switch (T) {
        Config.Color,
        Config.TerminalColor,
        Config.BoldColor,
        => return .color,
        else => {},
    }

    return switch (@typeInfo(T)) {
        .int => .int,
        .float => .float,
        .@"enum" => .@"enum",
        .@"struct" => |info| if (!@hasDecl(T, "formatEntry") and
            info.layout == .@"packed" and
            allBool(info.fields)) .flags else .string,
        else => .string,
    };
}

fn allBool(comptime fields: []const std.builtin.Type.StructField) bool {
    for (fields) |field| if (field.type != bool) return false;
    return true;
}

fn isRepeatable(comptime T: type) bool {
    return switch (T) {
        Config.Keybinds,
        Config.Palette,
        Config.RepeatableClipboardCodepointMap,
        Config.RepeatableCodepointMap,
        Config.RepeatableCommand,
        Config.RepeatableFontVariation,
        Config.RepeatableLink,
        Config.RepeatableString,
        RepeatableStringMap,
        io.RepeatableReadableIO,
        path.RepeatablePath,
        @FieldType(Config, "key-remap"),
        => true,
        else => false,
    };
}

fn choices(comptime T: type) []const [*:0]const u8 {
    const fields = switch (@typeInfo(T)) {
        .@"enum" => |info| info.fields,
        .@"struct" => |info| info.fields,
        else => @compileError("choices only supported for enums and structs"),
    };

    var result: [fields.len][*:0]const u8 = undefined;
    for (fields, &result) |field, *choice| choice.* = field.name.ptr;
    const final = result;
    return &final;
}

test "options cover every key in order" {
    const testing = std.testing;
    const fields = @typeInfo(Key).@"enum".fields;
    try testing.expectEqual(fields.len, options.len);
    for (options, 0..) |opt, i| {
        try testing.expectEqual(i, @intFromEnum(opt.key));
    }
}

test "every Repeatable type is marked repeatable" {
    @setEvalBranchQuota(100_000);
    const testing = std.testing;
    inline for (@typeInfo(Config).@"struct".fields) |field| {
        if (field.name[0] == '_') continue;
        const T = switch (@typeInfo(field.type)) {
            .optional => |info| info.child,
            else => field.type,
        };
        if (comptime std.mem.indexOf(u8, @typeName(T), "Repeatable") != null) {
            const opt = find(field.name).?;
            try testing.expect(opt.repeatable);
        }
    }
}

test "option kinds" {
    const testing = std.testing;

    try testing.expectEqual(Kind.bool, find("maximize").?.kind);
    try testing.expectEqual(Kind.float, find("font-size").?.kind);
    try testing.expectEqual(Kind.int, find("window-height").?.kind);
    try testing.expectEqual(Kind.color, find("background").?.kind);
    try testing.expectEqual(Kind.color, find("cursor-color").?.kind);
    try testing.expectEqual(Kind.string, find("font-family").?.kind);
    try testing.expectEqual(Kind.string, find("theme").?.kind);

    const blink = find("cursor-style-blink").?;
    try testing.expectEqual(Kind.bool, blink.kind);
    try testing.expect(blink.optional);

    const theme = find("window-theme").?;
    try testing.expectEqual(Kind.@"enum", theme.kind);
    try testing.expect(theme.choices.len > 0);
    var found = false;
    for (theme.choices) |choice| {
        if (std.mem.eql(u8, std.mem.span(choice), "dark")) found = true;
    }
    try testing.expect(found);

    const features = find("shell-integration-features").?;
    try testing.expectEqual(Kind.flags, features.kind);
    try testing.expect(features.choices.len > 0);

    try testing.expect(find("font-family").?.repeatable);
    try testing.expect(find("keybind").?.repeatable);
    try testing.expect(find("palette").?.repeatable);
    try testing.expect(find("key-remap").?.repeatable);
    try testing.expect(!find("font-size").?.repeatable);

    try testing.expect(find("font-size").?.help.len > 0);
    try testing.expect(find("not-a-real-key") == null);
}

test "formatValue" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    cfg.@"font-size" = 14.5;
    cfg.@"window-theme" = .dark;
    try cfg.@"font-family".parseCLI(cfg._arena.?.allocator(), "Fira Code");
    try cfg.@"font-family".parseCLI(cfg._arena.?.allocator(), "Symbols Nerd Font");

    {
        const v = try formatValue(alloc, &cfg, .@"font-size");
        defer alloc.free(v);
        try testing.expectEqualStrings("14.5", v);
    }
    {
        const v = try formatValue(alloc, &cfg, .@"window-theme");
        defer alloc.free(v);
        try testing.expectEqualStrings("dark", v);
    }
    {
        const v = try formatValue(alloc, &cfg, .@"font-family");
        defer alloc.free(v);
        try testing.expectEqualStrings("Fira Code\nSymbols Nerd Font", v);
    }
    {
        const v = try formatValue(alloc, &cfg, .@"font-family-bold");
        defer alloc.free(v);
        try testing.expectEqualStrings("", v);
    }
    {
        const v = try formatValue(alloc, &cfg, .title);
        defer alloc.free(v);
        try testing.expectEqualStrings("", v);
    }
    {
        // Values containing " = " must be preserved intact.
        const v = try formatValue(alloc, &cfg, .palette);
        defer alloc.free(v);
        try testing.expect(std.mem.startsWith(u8, v, "0=#"));
        try testing.expectEqual(256, std.mem.count(u8, v, "\n") + 1);
    }
}

test "every option can be formatted" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    for (options) |opt| {
        const v = try formatValue(alloc, &cfg, opt.key);
        alloc.free(v);
    }
}

test "changed" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var a = try Config.default(alloc);
    defer a.deinit();
    var b = try Config.default(alloc);
    defer b.deinit();

    try testing.expect(!changed(&a, &b, .@"font-size"));
    b.@"font-size" = 42;
    try testing.expect(changed(&a, &b, .@"font-size"));
    try testing.expect(!changed(&a, &b, .maximize));
}

test "finalized default config has no changes from itself" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var a = try Config.default(alloc);
    defer a.deinit();
    try a.finalize();
    var b = try Config.default(alloc);
    defer b.deinit();
    try b.finalize();

    for (options) |opt| {
        if (changed(&a, &b, opt.key)) {
            std.log.err("unexpected change key={s}", .{opt.name()});
            return error.TestUnexpectedResult;
        }
    }
}
