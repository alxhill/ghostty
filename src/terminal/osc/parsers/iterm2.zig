const std = @import("std");

const assert = @import("../../../quirks.zig").inlineAssert;
const simd = @import("../../../simd/main.zig");

const Parser = @import("../../osc.zig").Parser;
const Command = @import("../../osc.zig").Command;

const log = std.log.scoped(.osc_iterm2);

const Key = enum {
    AddAnnotation,
    AddHiddenAnnotation,
    Block,
    Button,
    ClearCapturedOutput,
    ClearScrollback,
    Copy,
    CopyToClipboard,
    CurrentDir,
    CursorShape,
    Custom,
    Disinter,
    EndCopy,
    File,
    FileEnd,
    FilePart,
    HighlightCursorLine,
    MultipartFile,
    OpenURL,
    PopKeyLabels,
    PushKeyLabels,
    RemoteHost,
    ReportCellSize,
    ReportVariable,
    RequestAttention,
    RequestUpload,
    SetBackgroundImageFile,
    SetBadgeFormat,
    SetColors,
    SetKeyLabel,
    SetMark,
    SetProfile,
    SetUserVar,
    ShellIntegrationVersion,
    StealFocus,
    UnicodeVersion,
};

/// An iTerm2 annotation attaches a message to a range of cells.
///
/// Supported forms (value of AddAnnotation / AddHiddenAnnotation):
///
///   message
///   length|message
///   message|length|x|y
pub const Annotation = struct {
    message: [:0]const u8,

    /// The number of cells to annotate. Null means the rest of the line.
    length: ?u32 = null,

    /// The zero-based starting coordinate within the active area. Null
    /// means the cursor position.
    x: ?u32 = null,
    y: ?u32 = null,

    /// If true, the annotation is not shown when it is added.
    hidden: bool,
};

// Instead of using `std.meta.stringToEnum` we set up a StaticStringMap so
// that we can get ASCII case-insensitive lookups.
const Map = std.StaticStringMapWithEql(Key, std.ascii.eqlIgnoreCase);
const map: Map = .initComptime(
    map: {
        const fields = @typeInfo(Key).@"enum".fields;
        var tmp: [fields.len]struct { [:0]const u8, Key } = undefined;
        for (fields, 0..) |field, i| {
            tmp[i] = .{ field.name, @enumFromInt(field.value) };
        }
        break :map tmp;
    },
);

/// Parse OSC 1337
/// https://iterm2.com/documentation-escape-codes.html
pub fn parse(parser: *Parser, _: ?u8) ?*Command {
    assert(parser.state == .@"1337");

    const cap = if (parser.capture) |*c| c else {
        parser.state = .invalid;
        return null;
    };
    cap.writer.writeByte(0) catch {
        parser.state = .invalid;
        return null;
    };
    const data = cap.trailing();

    const key_str: [:0]u8, const value_: ?[:0]u8 = kv: {
        const index = std.mem.indexOfScalar(u8, data, '=') orelse {
            break :kv .{ data[0 .. data.len - 1 :0], null };
        };
        data[index] = 0;
        break :kv .{ data[0..index :0], data[index + 1 .. data.len - 1 :0] };
    };

    const key = map.get(key_str) orelse {
        parser.command = .invalid;
        return null;
    };

    switch (key) {
        .Copy => {
            var value = value_ orelse {
                parser.command = .invalid;
                return null;
            };

            // Sending a blank entry to clear the clipboard is an OSC 52-ism,
            // make sure that is invalid here.
            if (value.len == 0) {
                parser.command = .invalid;
                return null;
            }

            // base64 value must be prefixed by a colon
            if (value[0] != ':') {
                parser.command = .invalid;
                return null;
            }

            value = value[1..value.len :0];

            // Sending a blank entry to clear the clipboard is an OSC 52-ism,
            // make sure that is invalid here.
            if (value.len == 0) {
                parser.command = .invalid;
                return null;
            }

            // Sending a '?' to query the clipboard is an OSC 52-ism, make sure
            // that is invalid here.
            if (value.len == 1 and value[0] == '?') {
                parser.command = .invalid;
                return null;
            }

            // It would be better to check for valid base64 data here, but that
            // would mean parsing the base64 data twice in the "normal" case.

            parser.command = .{
                .clipboard_contents = .{
                    .kind = 'c',
                    .data = value,
                },
            };
            return &parser.command;
        },

        .CurrentDir => {
            const value = value_ orelse {
                parser.command = .invalid;
                return null;
            };
            if (value.len == 0) {
                parser.command = .invalid;
                return null;
            }
            parser.command = .{
                .report_pwd = .{
                    .value = value,
                },
            };
            return &parser.command;
        },

        .AddAnnotation, .AddHiddenAnnotation => {
            const value = value_ orelse {
                parser.command = .invalid;
                return null;
            };
            const annotation = parseAnnotation(
                value,
                key == .AddHiddenAnnotation,
            ) orelse {
                parser.command = .invalid;
                return null;
            };
            parser.command = .{ .iterm2_annotation = annotation };
            return &parser.command;
        },

        .Block,
        .Button,
        .ClearCapturedOutput,
        .ClearScrollback,
        .CopyToClipboard,
        .CursorShape,
        .Custom,
        .Disinter,
        .EndCopy,
        .File,
        .FileEnd,
        .FilePart,
        .HighlightCursorLine,
        .MultipartFile,
        .OpenURL,
        .PopKeyLabels,
        .PushKeyLabels,
        .RemoteHost,
        .ReportCellSize,
        .ReportVariable,
        .RequestAttention,
        .RequestUpload,
        .SetBackgroundImageFile,
        .SetBadgeFormat,
        .SetColors,
        .SetKeyLabel,
        .SetMark,
        .SetProfile,
        .SetUserVar,
        .ShellIntegrationVersion,
        .StealFocus,
        .UnicodeVersion,
        => {
            log.debug("unimplemented OSC 1337: {t}", .{key});
            parser.command = .invalid;
            return null;
        },
    }
    return &parser.command;
}

fn parseAnnotation(value: [:0]u8, hidden: bool) ?Annotation {
    var parts: [4][:0]u8 = undefined;
    var count: usize = 0;
    var start: usize = 0;
    for (value, 0..) |c, i| {
        if (c != '|') continue;
        if (count == parts.len - 1) break;
        value[i] = 0;
        parts[count] = value[start..i :0];
        count += 1;
        start = i + 1;
    }
    parts[count] = value[start..value.len :0];
    count += 1;

    const result: Annotation = switch (count) {
        1 => .{
            .message = parts[0],
            .hidden = hidden,
        },
        2 => .{
            .message = parts[1],
            .length = std.fmt.parseInt(u32, parts[0], 10) catch return null,
            .hidden = hidden,
        },
        4 => .{
            .message = parts[0],
            .length = std.fmt.parseInt(u32, parts[1], 10) catch return null,
            .x = std.fmt.parseInt(u32, parts[2], 10) catch return null,
            .y = std.fmt.parseInt(u32, parts[3], 10) catch return null,
            .hidden = hidden,
        },
        else => return null,
    };

    if (result.message.len == 0) return null;
    if (result.length) |len| if (len == 0) return null;
    return result;
}

test "OSC: 1337: test valid unimplemented key with no value" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "1337;SetBadgeFormat";
    for (input) |ch| p.next(ch);

    try testing.expect(p.end('\x1b') == null);
}

test "OSC: 1337: test valid unimplemented key with empty value" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "1337;SetBadgeFormat=";
    for (input) |ch| p.next(ch);

    try testing.expect(p.end('\x1b') == null);
}

test "OSC: 1337: test valid unimplemented key with non-empty value" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "1337;SetBadgeFormat=abc123";
    for (input) |ch| p.next(ch);

    try testing.expect(p.end('\x1b') == null);
}

test "OSC: 1337: test valid key with lower case and with no value" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "1337;setbadgeformat";
    for (input) |ch| p.next(ch);

    try testing.expect(p.end('\x1b') == null);
}

test "OSC: 1337: test valid key with lower case and with empty value" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "1337;setbadgeformat=";
    for (input) |ch| p.next(ch);

    try testing.expect(p.end('\x1b') == null);
}

test "OSC: 1337: test valid key with lower case and with non-empty value" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "1337;setbadgeformat=abc123";
    for (input) |ch| p.next(ch);

    try testing.expect(p.end('\x1b') == null);
}

test "OSC: 1337: test invalid key with no value" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "1337;BobrKurwa";
    for (input) |ch| p.next(ch);

    try testing.expect(p.end('\x1b') == null);
}

test "OSC: 1337: test invalid key with empty value" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "1337;BobrKurwa=";
    for (input) |ch| p.next(ch);

    try testing.expect(p.end('\x1b') == null);
}

test "OSC: 1337: test invalid key with non-empty value" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "1337;BobrKurwa=abc123";
    for (input) |ch| p.next(ch);

    try testing.expect(p.end('\x1b') == null);
}

test "OSC: 1337: test Copy with no value" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "1337;Copy";
    for (input) |ch| p.next(ch);

    try testing.expect(p.end('\x1b') == null);
}

test "OSC: 1337: test Copy with empty value" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "1337;Copy=";
    for (input) |ch| p.next(ch);

    try testing.expect(p.end('\x1b') == null);
}

test "OSC: 1337: test Copy with only prefix colon" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "1337;Copy=:";
    for (input) |ch| p.next(ch);

    try testing.expect(p.end('\x1b') == null);
}

test "OSC: 1337: test Copy with question mark" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "1337;Copy=:?";
    for (input) |ch| p.next(ch);

    try testing.expect(p.end('\x1b') == null);
}

test "OSC: 1337: test Copy with non-empty value that is invalid base64" {
    // For performance reasons, we don't check for valid base64 data
    // right now.
    return error.SkipZigTest;

    // const testing = std.testing;

    // var p: Parser = .init(testing.allocator);
    // defer p.deinit();

    // const input = "1337;Copy=:abc123";
    // for (input) |ch| p.next(ch);

    // try testing.expect(p.end('\x1b') == null);
}

test "OSC: 1337: test Copy with non-empty value that is valid base64 but not prefixed with a colon" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "1337;Copy=YWJjMTIz";
    for (input) |ch| p.next(ch);

    try testing.expect(p.end('\x1b') == null);
}

test "OSC: 1337: test Copy with non-empty value that is valid base64" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "1337;Copy=:YWJjMTIz";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .clipboard_contents);
    try testing.expectEqual('c', cmd.clipboard_contents.kind);
    try testing.expectEqualStrings("YWJjMTIz", cmd.clipboard_contents.data);
}

test "OSC: 1337: test CurrentDir with no value" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "1337;CurrentDir";
    for (input) |ch| p.next(ch);

    try testing.expect(p.end('\x1b') == null);
}

test "OSC: 1337: test CurrentDir with empty value" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "1337;CurrentDir=";
    for (input) |ch| p.next(ch);

    try testing.expect(p.end('\x1b') == null);
}

test "OSC: 1337: test CurrentDir with non-empty value" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "1337;CurrentDir=abc123";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .report_pwd);
    try testing.expectEqualStrings("abc123", cmd.report_pwd.value);
}

test "OSC: 1337: AddAnnotation with message" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "1337;AddAnnotation=hello world";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .iterm2_annotation);
    const v = cmd.iterm2_annotation;
    try testing.expectEqualStrings("hello world", v.message);
    try testing.expect(v.length == null);
    try testing.expect(v.x == null);
    try testing.expect(v.y == null);
    try testing.expect(!v.hidden);
}

test "OSC: 1337: AddHiddenAnnotation with length and message" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "1337;AddHiddenAnnotation=5|hello";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .iterm2_annotation);
    const v = cmd.iterm2_annotation;
    try testing.expectEqualStrings("hello", v.message);
    try testing.expectEqual(@as(?u32, 5), v.length);
    try testing.expect(v.x == null);
    try testing.expect(v.hidden);
}

test "OSC: 1337: AddAnnotation with message, length and coordinates" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "1337;AddAnnotation=hello|3|4|2";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .iterm2_annotation);
    const v = cmd.iterm2_annotation;
    try testing.expectEqualStrings("hello", v.message);
    try testing.expectEqual(@as(?u32, 3), v.length);
    try testing.expectEqual(@as(?u32, 4), v.x);
    try testing.expectEqual(@as(?u32, 2), v.y);
    try testing.expect(!v.hidden);
}

test "OSC: 1337: AddAnnotation invalid forms" {
    const testing = std.testing;

    const inputs = [_][]const u8{
        "1337;AddAnnotation",
        "1337;AddAnnotation=",
        "1337;AddAnnotation=abc|hello",
        "1337;AddAnnotation=0|hello",
        "1337;AddAnnotation=5|",
        "1337;AddAnnotation=a|1|2",
        "1337;AddAnnotation=a|1|2|z",
    };

    for (inputs) |input| {
        var p: Parser = .init(testing.allocator);
        defer p.deinit();
        for (input) |ch| p.next(ch);
        try testing.expect(p.end('\x1b') == null);
    }
}
