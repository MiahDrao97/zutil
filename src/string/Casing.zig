//! Currently supports:
//! - TitleCase
//! - camelCase
//! - kebab-case
//! - snake_case
//! - SCREAMING_SNAKE_CASE
//!
//! Assumes that any non-alpha numeric characters in native string must be omitted
//! Also naively assumes ASCII encoding.
//! This struct conveniently allows you to wrap a string, specifying which casing you'd like.
//! Use the `{f}` format specifier.
const Casing = @This();

/// Original string
str: []const u8,
/// Casing strategy
strategy: enum { title, camel, kebab, snake, screaming_snake },

/// Write `str` in TitleCase
pub fn titleCase(str: []const u8) Casing {
    return .{ .str = str, .strategy = .title };
}

/// Write `str` in camelCase
pub fn camelCase(str: []const u8) Casing {
    return .{ .str = str, .strategy = .camel };
}

/// Write `str` in kebab-case
pub fn kebabCase(str: []const u8) Casing {
    return .{ .str = str, .strategy = .kebab };
}

/// Write `str` in snake_case
pub fn snakeCase(str: []const u8) Casing {
    return .{ .str = str, .strategy = .snake };
}

/// Write `str` in SCREAMING_SNAKE_CASE
pub fn screamingSnakeCase(str: []const u8) Casing {
    return .{ .str = str, .strategy = .screaming_snake };
}

/// This method allows you to use the `{f}` format specificer or format to a writer directly.
pub fn format(self: Casing, writer: *Io.Writer) Io.Writer.Error!void {
    try switch (self.strategy) {
        .title => titleOrCamelCase(writer, self.str, .upper),
        .camel => titleOrCamelCase(writer, self.str, .lower),
        .kebab => separatedCase(writer, self.str, '-', .lower),
        .snake => separatedCase(writer, self.str, '_', .lower),
        .screaming_snake => separatedCase(writer, self.str, '_', .upper),
    };
}

fn titleOrCamelCase(writer: *Io.Writer, str: []const u8, comptime initial_casing: Case) Io.Writer.Error!void {
    comptime std.debug.assert(initial_casing != .either);

    var has_written: bool = false;
    var handle_next: Case = initial_casing;
    for (str, 0..) |char, i| switch (char) {
        '0'...'9', 'a'...'z', 'A'...'Z' => {
            switch (handle_next) {
                .upper => {
                    try writer.writeByte(ascii.toUpper(char));
                    handle_next = .lower;
                },
                .lower => {
                    const next_is_lower: bool = has_written and
                        ascii.isUpper(char) and
                        i + 1 < str.len and
                        ascii.isLower(str[i + 1]);

                    if (!ascii.isUpper(char) or next_is_lower) {
                        handle_next = .either;
                    }
                    try writer.writeByte(if (next_is_lower) char else ascii.toLower(char));
                },
                .either => {
                    try writer.writeByte(char);
                    if (ascii.isUpper(char)) {
                        handle_next = .lower;
                    }
                },
            }
            has_written = true;
        },
        else => {
            // skip (these don't belong here)
            if (ascii.isPrint(char) and has_written) {
                handle_next = .upper;
            }
        },
    };
}

fn separatedCase(
    writer: *Io.Writer,
    str: []const u8,
    separator: u8,
    comptime casing: Case,
) Io.Writer.Error!void {
    comptime std.debug.assert(casing != .either);

    var last: ?u8 = null;
    for (str, 0..) |char, i| switch (char) {
        '0'...'9' => {
            const next_is_digit: bool = i + 1 < str.len and ascii.isDigit(str[i + 1]);
            if (last) |l|
                if (!next_is_digit or (l != separator and !ascii.isDigit(l))) {
                    try writer.writeByte(separator);
                };
            try writer.writeByte(char);
            last = char;
        },
        'A'...'Z', 'a'...'z' => {
            const next_is_upper: bool = i + 1 < str.len and
                (ascii.isUpper(str[i + 1]) or !ascii.isAlphabetic(str[i + 1]));
            const prev_is_upper: bool = i > 0 and ascii.isUpper(str[i - 1]);
            if (ascii.isUpper(char))
                if (last != null and last != separator)
                    if (!prev_is_upper or ((!next_is_upper and i + 1 < str.len))) {
                        try writer.writeByte(separator);
                    };
            const c: u8 = switch (casing) {
                .upper => ascii.toUpper(char),
                .lower => ascii.toLower(char),
                .either => unreachable,
            };
            try writer.writeByte(c);
            last = c;
        },
        else => {
            if (last != null and last != separator) {
                try writer.writeByte(separator);
                last = separator;
            }
        }
    };
}

const Case = enum {
    upper,
    lower,
    either,
};

test titleCase {
    var stream: Io.Writer.Allocating = .init(testing.allocator);
    defer stream.deinit();
    {
        defer stream.clearRetainingCapacity();
        try stream.writer.print("{f}", .{Casing.titleCase("IsTitleCase")});
        try testing.expectEqualStrings("IsTitleCase", stream.written());
    }
    {
        defer stream.clearRetainingCapacity();
        try stream.writer.print("{f}", .{Casing.titleCase("productID")});
        try testing.expectEqualStrings("ProductId", stream.written());
    }
    {
        defer stream.clearRetainingCapacity();
        try Casing.titleCase("SomeExcitingURL").format(&stream.writer);
        try testing.expectEqualStrings("SomeExcitingUrl", stream.written());
    }
    {
        defer stream.clearRetainingCapacity();
        try stream.writer.print("{f}", .{Casing.titleCase("IMBCode")});
        try testing.expectEqualStrings("ImbCode", stream.written());
    }
    {
        defer stream.clearRetainingCapacity();
        try stream.writer.print("{f}", .{Casing.titleCase("kebab-case")});
        try testing.expectEqualStrings("KebabCase", stream.written());
    }
    {
        defer stream.clearRetainingCapacity();
        try stream.writer.print("{f}", .{Casing.titleCase("snake_case")});
        try testing.expectEqualStrings("SnakeCase", stream.written());
    }
    {
        defer stream.clearRetainingCapacity();
        try stream.writer.print("{f}", .{Casing.titleCase("SCREAMING_SNAKE")});
        try testing.expectEqualStrings("ScreamingSnake", stream.written());
    }
    {
        defer stream.clearRetainingCapacity();
        try stream.writer.print("{f}", .{Casing.titleCase("this$Contains2Oddballs")});
        try testing.expectEqualStrings("ThisContains2Oddballs", stream.written());
    }
    {
        defer stream.clearRetainingCapacity();
        try stream.writer.print("{f}", .{Casing.titleCase("$$doubleDollars")});
        try testing.expectEqualStrings("DoubleDollars", stream.written());
    }
}

test camelCase {
    var stream: Io.Writer.Allocating = .init(testing.allocator);
    defer stream.deinit();
    {
        defer stream.clearRetainingCapacity();
        try stream.writer.print("{f}", .{Casing.camelCase("isCamelCase")});
        try testing.expectEqualStrings("isCamelCase", stream.written());
    }
    {
        defer stream.clearRetainingCapacity();
        try stream.writer.print("{f}", .{Casing.camelCase("productID")});
        try testing.expectEqualStrings("productId", stream.written());
    }
    {
        defer stream.clearRetainingCapacity();
        try Casing.camelCase("SomeExcitingURL").format(&stream.writer);
        try testing.expectEqualStrings("someExcitingUrl", stream.written());
    }
    {
        defer stream.clearRetainingCapacity();
        try stream.writer.print("{f}", .{Casing.camelCase("IMBCode")});
        try testing.expectEqualStrings("imbCode", stream.written());
    }
    {
        defer stream.clearRetainingCapacity();
        try stream.writer.print("{f}", .{Casing.camelCase("kebab-case")});
        try testing.expectEqualStrings("kebabCase", stream.written());
    }
    {
        defer stream.clearRetainingCapacity();
        try stream.writer.print("{f}", .{Casing.camelCase("snake_case")});
        try testing.expectEqualStrings("snakeCase", stream.written());
    }
    {
        defer stream.clearRetainingCapacity();
        try stream.writer.print("{f}", .{Casing.camelCase("SCREAMING_SNAKE")});
        try testing.expectEqualStrings("screamingSnake", stream.written());
    }
    {
        defer stream.clearRetainingCapacity();
        try stream.writer.print("{f}", .{Casing.camelCase("this$Contains2Oddballs")});
        try testing.expectEqualStrings("thisContains2Oddballs", stream.written());
    }
    {
        defer stream.clearRetainingCapacity();
        try stream.writer.print("{f}", .{Casing.camelCase("$$doubleDollars")});
        try testing.expectEqualStrings("doubleDollars", stream.written());
    }
}

test kebabCase {
    var stream: Io.Writer.Allocating = .init(testing.allocator);
    defer stream.deinit();
    {
        defer stream.clearRetainingCapacity();
        try stream.writer.print("{f}", .{Casing.kebabCase("isCamelCase")});
        try testing.expectEqualStrings("is-camel-case", stream.written());
    }
    {
        defer stream.clearRetainingCapacity();
        try stream.writer.print("{f}", .{Casing.kebabCase("productID")});
        try testing.expectEqualStrings("product-id", stream.written());
    }
    {
        defer stream.clearRetainingCapacity();
        try Casing.kebabCase("SomeExcitingURL").format(&stream.writer);
        try testing.expectEqualStrings("some-exciting-url", stream.written());
    }
    {
        defer stream.clearRetainingCapacity();
        try stream.writer.print("{f}", .{Casing.kebabCase("IMBCode")});
        try testing.expectEqualStrings("imb-code", stream.written());
    }
    {
        defer stream.clearRetainingCapacity();
        try stream.writer.print("{f}", .{Casing.kebabCase("kebab-case")});
        try testing.expectEqualStrings("kebab-case", stream.written());
    }
    {
        defer stream.clearRetainingCapacity();
        try stream.writer.print("{f}", .{Casing.kebabCase("snake_case")});
        try testing.expectEqualStrings("snake-case", stream.written());
    }
    {
        defer stream.clearRetainingCapacity();
        try stream.writer.print("{f}", .{Casing.kebabCase("SCREAMING_SNAKE")});
        try testing.expectEqualStrings("screaming-snake", stream.written());
    }
    {
        defer stream.clearRetainingCapacity();
        try stream.writer.print("{f}", .{Casing.kebabCase("this$Contains2Oddballs")});
        try testing.expectEqualStrings("this-contains-2-oddballs", stream.written());
    }
    {
        defer stream.clearRetainingCapacity();
        try stream.writer.print("{f}", .{Casing.kebabCase("$$doubleDollars")});
        try testing.expectEqualStrings("double-dollars", stream.written());
    }
}

test snakeCase {
    var stream: Io.Writer.Allocating = .init(testing.allocator);
    defer stream.deinit();
    {
        defer stream.clearRetainingCapacity();
        try stream.writer.print("{f}", .{Casing.snakeCase("isCamelCase")});
        try testing.expectEqualStrings("is_camel_case", stream.written());
    }
    {
        defer stream.clearRetainingCapacity();
        try stream.writer.print("{f}", .{Casing.snakeCase("productID")});
        try testing.expectEqualStrings("product_id", stream.written());
    }
    {
        defer stream.clearRetainingCapacity();
        try Casing.snakeCase("SomeExcitingURL").format(&stream.writer);
        try testing.expectEqualStrings("some_exciting_url", stream.written());
    }
    {
        defer stream.clearRetainingCapacity();
        try stream.writer.print("{f}", .{Casing.snakeCase("IMBCode")});
        try testing.expectEqualStrings("imb_code", stream.written());
    }
    {
        defer stream.clearRetainingCapacity();
        try stream.writer.print("{f}", .{Casing.snakeCase("kebab-case")});
        try testing.expectEqualStrings("kebab_case", stream.written());
    }
    {
        defer stream.clearRetainingCapacity();
        try stream.writer.print("{f}", .{Casing.snakeCase("snake_case")});
        try testing.expectEqualStrings("snake_case", stream.written());
    }
    {
        defer stream.clearRetainingCapacity();
        try stream.writer.print("{f}", .{Casing.snakeCase("SCREAMING_SNAKE")});
        try testing.expectEqualStrings("screaming_snake", stream.written());
    }
    {
        defer stream.clearRetainingCapacity();
        try stream.writer.print("{f}", .{Casing.snakeCase("this$Contains2Oddballs")});
        try testing.expectEqualStrings("this_contains_2_oddballs", stream.written());
    }
    {
        defer stream.clearRetainingCapacity();
        try stream.writer.print("{f}", .{Casing.snakeCase("$$doubleDollars")});
        try testing.expectEqualStrings("double_dollars", stream.written());
    }
}

test screamingSnakeCase {
    var stream: Io.Writer.Allocating = .init(testing.allocator);
    defer stream.deinit();
    {
        defer stream.clearRetainingCapacity();
        try stream.writer.print("{f}", .{Casing.screamingSnakeCase("isCamelCase")});
        try testing.expectEqualStrings("IS_CAMEL_CASE", stream.written());
    }
    {
        defer stream.clearRetainingCapacity();
        try stream.writer.print("{f}", .{Casing.screamingSnakeCase("productID")});
        try testing.expectEqualStrings("PRODUCT_ID", stream.written());
    }
    {
        defer stream.clearRetainingCapacity();
        try Casing.screamingSnakeCase("SomeExcitingURL").format(&stream.writer);
        try testing.expectEqualStrings("SOME_EXCITING_URL", stream.written());
    }
    {
        defer stream.clearRetainingCapacity();
        try stream.writer.print("{f}", .{Casing.screamingSnakeCase("IMBCode")});
        try testing.expectEqualStrings("IMB_CODE", stream.written());
    }
    {
        defer stream.clearRetainingCapacity();
        try stream.writer.print("{f}", .{Casing.screamingSnakeCase("kebab-case")});
        try testing.expectEqualStrings("KEBAB_CASE", stream.written());
    }
    {
        defer stream.clearRetainingCapacity();
        try stream.writer.print("{f}", .{Casing.screamingSnakeCase("snake_case")});
        try testing.expectEqualStrings("SNAKE_CASE", stream.written());
    }
    {
        defer stream.clearRetainingCapacity();
        try stream.writer.print("{f}", .{Casing.screamingSnakeCase("SCREAMING_SNAKE")});
        try testing.expectEqualStrings("SCREAMING_SNAKE", stream.written());
    }
    {
        defer stream.clearRetainingCapacity();
        try stream.writer.print("{f}", .{Casing.screamingSnakeCase("this$Contains2Oddballs")});
        try testing.expectEqualStrings("THIS_CONTAINS_2_ODDBALLS", stream.written());
    }
    {
        defer stream.clearRetainingCapacity();
        try stream.writer.print("{f}", .{Casing.screamingSnakeCase("$$doubleDollars")});
        try testing.expectEqualStrings("DOUBLE_DOLLARS", stream.written());
    }
}

const std = @import("std");
const Io = std.Io;
const ascii = std.ascii;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const BufPrintError = std.fmt.BufPrintError;
