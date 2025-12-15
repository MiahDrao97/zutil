/// Convert a string to title case (naively ignoring non-alphanumeric characters), writing to a buffer
pub fn titleCaseBuf(buf: []u8, str: []const u8) BufPrintError![]const u8 {
    var writer: Io.Writer = .fixed(buf);
    writeTitleCase(&writer, str) catch return BufPrintError.NoSpaceLeft;
    return writer.buffered();
}

/// Convert a string to title case (naively ignoring non-alphanumeric characters)
/// Free the resulting string with `gpa`.
pub fn titleCaseAlloc(gpa: Allocator, str: []const u8) Allocator.Error![]const u8 {
    var stream: Io.Writer.Allocating = try .initCapacity(gpa, str.len);
    defer stream.deinit();

    writeTitleCase(&stream.writer, str) catch return Allocator.Error.OutOfMemory;
    return try stream.toOwnedSlice();
}

/// Write `str` to `writer` in title case
pub fn writeTitleCase(writer: *Io.Writer, str: []const u8) Io.Writer.Error!void {
    try titleOrCamelCase(writer, str, .upper);
}

/// Convert a string to camel case (naively ignoring non-alphanumeric characters)
/// Free the resulting string with `gpa`.
pub fn camelCaseAlloc(gpa: Allocator, str: []const u8) Allocator.Error![]const u8 {
    var stream: Io.Writer.Allocating = try .initCapacity(gpa, str.len);
    defer stream.deinit();

    writeCamelCase(&stream.writer, str) catch return Allocator.Error.OutOfMemory;
    return try stream.toOwnedSlice();
}

/// Convert a string to camel case (naively ignoring non-alphanumeric characters), writing to a buffer
pub fn camelCaseBuf(buf: []u8, str: []const u8) BufPrintError![]const u8 {
    var writer: Io.Writer = .fixed(buf);
    writeCamelCase(&writer, str) catch return BufPrintError.NoSpaceLeft;
    return writer.buffered();
}

/// Write `str` to `writer` in camel case
pub fn writeCamelCase(writer: *Io.Writer, str: []const u8) Io.Writer.Error!void {
    try titleOrCamelCase(writer, str, .lower);
}

fn titleOrCamelCase(writer: *Io.Writer, str: []const u8, initial_casing: Casing) Io.Writer.Error!void {
    std.debug.assert(initial_casing != .either);

    var has_written: bool = false;
    var handle_next: Casing = initial_casing;
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

/// Convert a string to kebab case (naively ignoring non-alphanumeric characters)
/// Free the resulting string with `gpa`.
pub fn kebabCaseAlloc(gpa: Allocator, str: []const u8) Allocator.Error![]const u8 {
    var stream: Io.Writer.Allocating = try .initCapacity(gpa, str.len * 2);
    defer stream.deinit();

    writeKebabCase(&stream.writer, str) catch return Allocator.Error.OutOfMemory;
    return try stream.toOwnedSlice();
}

/// Convert a string to kebab case (naively ignoring non-alphanumeric characters), writing to a buffer
pub fn kebabCaseBuf(buf: []u8, str: []const u8) BufPrintError![]const u8 {
    var writer: Io.Writer = .fixed(buf);
    writeKebabCase(&writer, str) catch return BufPrintError.NoSpaceLeft;
    return writer.buffered();
}

/// Writes `str` to `writer` in kebab case
pub fn writeKebabCase(writer: *Io.Writer, str: []const u8) Io.Writer.Error!void {
    try separatedCase(writer, str, '-', .lower);
}

/// Convert a string to snake case (naively ignoring non-alphanumeric characters)
/// Free the resulting string with `gpa`.
pub fn snakeCaseAlloc(gpa: Allocator, str: []const u8) Allocator.Error![]const u8 {
    var stream: Io.Writer.Allocating = try .initCapacity(gpa, str.len * 2);
    defer stream.deinit();

    writeSnakeCase(&stream.writer, str) catch return Allocator.Error.OutOfMemory;
    return try stream.toOwnedSlice();
}

/// Convert a string to snake case (naively ignoring non-alphanumeric characters), writing to a buffer
pub fn snakeCaseBuf(buf: []u8, str: []const u8) BufPrintError![]const u8 {
    var writer: Io.Writer = .fixed(buf);
    writeSnakeCase(&writer, str) catch return BufPrintError.NoSpaceLeft;
    return writer.buffered();
}

/// Writes `str` to `writer` in snake case
pub fn writeSnakeCase(writer: *Io.Writer, str: []const u8) Io.Writer.Error!void {
    try separatedCase(writer, str, '_', .lower);
}

/// Convert a string to screaming snake case (naively ignoring non-alphanumeric characters)
/// Free the resulting string with `gpa`.
pub fn screamingSnakeCaseAlloc(gpa: Allocator, str: []const u8) Allocator.Error![]const u8 {
    var stream: Io.Writer.Allocating = try .initCapacity(gpa, str.len * 2);
    defer stream.deinit();

    writeScreamingSnakeCase(&stream.writer, str) catch return Allocator.Error.OutOfMemory;
    return try stream.toOwnedSlice();
}

/// Convert a string to screaming snake case (naively ignoring non-alphanumeric characters), writing to a buffer
pub fn screamSnakeCaseBuf(buf: []u8, str: []const u8) BufPrintError![]const u8 {
    var writer: Io.Writer = .fixed(buf);
    writeScreamingSnakeCase(&writer, str) catch return BufPrintError.NoSpaceLeft;
    return writer.buffered();
}

/// Writes `str` to `writer` in screaming snake case
pub fn writeScreamingSnakeCase(writer: *Io.Writer, str: []const u8) Io.Writer.Error!void {
    try separatedCase(writer, str, '_', .upper);
}

fn separatedCase(
    writer: *Io.Writer,
    str: []const u8,
    separator: u8,
    casing: Casing,
) Io.Writer.Error!void {
    std.debug.assert(casing != .either);

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

const Casing = enum {
    upper,
    lower,
    either,
};

test titleCaseAlloc {
    {
        const str: []const u8 = "IsTitleCase";
        const case_result: []const u8 = try titleCaseAlloc(testing.allocator, str);
        defer testing.allocator.free(case_result);

        try testing.expectEqualStrings(str, case_result);
    }
    {
        const str: []const u8 = "productID";
        const case_result: []const u8 = try titleCaseAlloc(testing.allocator, str);
        defer testing.allocator.free(case_result);

        try testing.expectEqualStrings("ProductId", case_result);
    }
    {
        const str: []const u8 = "SomeExcitingURL";
        const case_result: []const u8 = try titleCaseAlloc(testing.allocator, str);
        defer testing.allocator.free(case_result);

        try testing.expectEqualStrings("SomeExcitingUrl", case_result);
    }
    {
        const str: []const u8 = "IMBCode";
        const case_result: []const u8 = try titleCaseAlloc(testing.allocator, str);
        defer testing.allocator.free(case_result);

        try testing.expectEqualStrings("ImbCode", case_result);
    }
    {
        const str: []const u8 = "kebab-case";
        const case_result: []const u8 = try titleCaseAlloc(testing.allocator, str);
        defer testing.allocator.free(case_result);

        try testing.expectEqualStrings("KebabCase", case_result);
    }
    {
        const str: []const u8 = "snake_case";
        const case_result: []const u8 = try titleCaseAlloc(testing.allocator, str);
        defer testing.allocator.free(case_result);

        try testing.expectEqualStrings("SnakeCase", case_result);
    }
    {
        const str: []const u8 = "SCREAMING_SNAKE";
        const case_result: []const u8 = try titleCaseAlloc(testing.allocator, str);
        defer testing.allocator.free(case_result);

        try testing.expectEqualStrings("ScreamingSnake", case_result);
    }
    {
        const str: []const u8 = "this$Contains2Oddballs";
        const case_result: []const u8 = try titleCaseAlloc(testing.allocator, str);
        defer testing.allocator.free(case_result);

        try testing.expectEqualStrings("ThisContains2Oddballs", case_result);
    }
    {
        const str: []const u8 = "$$doubleDollars";
        const case_result: []const u8 = try titleCaseAlloc(testing.allocator, str);
        defer testing.allocator.free(case_result);

        try testing.expectEqualStrings("DoubleDollars", case_result);
    }
}
test camelCaseAlloc {
    {
        const str: []const u8 = "isCamelCase";
        const case_result: []const u8 = try camelCaseAlloc(testing.allocator, str);
        defer testing.allocator.free(case_result);

        try testing.expectEqualStrings(str, case_result);
    }
    {
        const str: []const u8 = "productID";
        const case_result: []const u8 = try camelCaseAlloc(testing.allocator, str);
        defer testing.allocator.free(case_result);

        try testing.expectEqualStrings("productId", case_result);
    }
    {
        const str: []const u8 = "SomeExcitingURL";
        const case_result: []const u8 = try camelCaseAlloc(testing.allocator, str);
        defer testing.allocator.free(case_result);

        try testing.expectEqualStrings("someExcitingUrl", case_result);
    }
    {
        const str: []const u8 = "IMBCode";
        const case_result: []const u8 = try camelCaseAlloc(testing.allocator, str);
        defer testing.allocator.free(case_result);

        try testing.expectEqualStrings("imbCode", case_result);
    }
    {
        const str: []const u8 = "kebab-case";
        const case_result: []const u8 = try camelCaseAlloc(testing.allocator, str);
        defer testing.allocator.free(case_result);

        try testing.expectEqualStrings("kebabCase", case_result);
    }
    {
        const str: []const u8 = "snake_case";
        const case_result: []const u8 = try camelCaseAlloc(testing.allocator, str);
        defer testing.allocator.free(case_result);

        try testing.expectEqualStrings("snakeCase", case_result);
    }
    {
        const str: []const u8 = "SCREAMING_SNAKE";
        const case_result: []const u8 = try camelCaseAlloc(testing.allocator, str);
        defer testing.allocator.free(case_result);

        try testing.expectEqualStrings("screamingSnake", case_result);
    }
    {
        const str: []const u8 = "this$Contains2Oddballs";
        const case_result: []const u8 = try camelCaseAlloc(testing.allocator, str);
        defer testing.allocator.free(case_result);

        try testing.expectEqualStrings("thisContains2Oddballs", case_result);
    }
    {
        const str: []const u8 = "$$doubleDollars";
        const case_result: []const u8 = try camelCaseAlloc(testing.allocator, str);
        defer testing.allocator.free(case_result);

        try testing.expectEqualStrings("doubleDollars", case_result);
    }
}

test kebabCaseAlloc {
    {
        const str: []const u8 = "productId";
        const case_result: []const u8 = try kebabCaseAlloc(testing.allocator, str);
        defer testing.allocator.free(case_result);

        try testing.expectEqualStrings("product-id", case_result);
    }
    {
        const str: []const u8 = "SomeExcitingURL";
        const case_result: []const u8 = try kebabCaseAlloc(testing.allocator, str);
        defer testing.allocator.free(case_result);

        try testing.expectEqualStrings("some-exciting-url", case_result);
    }
    {
        const str: []const u8 = "IMBCode";
        const case_result: []const u8 = try kebabCaseAlloc(testing.allocator, str);
        defer testing.allocator.free(case_result);

        try testing.expectEqualStrings("imb-code", case_result);
    }
    {
        const str: []const u8 = "kebab-case";
        const case_result: []const u8 = try kebabCaseAlloc(testing.allocator, str);
        defer testing.allocator.free(case_result);

        try testing.expectEqualStrings("kebab-case", case_result);
    }
    {
        const str: []const u8 = "snake_case";
        const case_result: []const u8 = try kebabCaseAlloc(testing.allocator, str);
        defer testing.allocator.free(case_result);

        try testing.expectEqualStrings("snake-case", case_result);
    }
    {
        const str: []const u8 = "SCREAMING_SNAKE";
        const case_result: []const u8 = try kebabCaseAlloc(testing.allocator, str);
        defer testing.allocator.free(case_result);

        try testing.expectEqualStrings("screaming-snake", case_result);
    }
    {
        const str: []const u8 = "this$Contains2Oddballs";
        const case_result: []const u8 = try kebabCaseAlloc(testing.allocator, str);
        defer testing.allocator.free(case_result);

        try testing.expectEqualStrings("this-contains-2-oddballs", case_result);
    }
    {
        const str: []const u8 = "$$doubleDollars";
        const case_result: []const u8 = try kebabCaseAlloc(testing.allocator, str);
        defer testing.allocator.free(case_result);

        try testing.expectEqualStrings("double-dollars", case_result);
    }
}

test snakeCaseAlloc {
    {
        const str: []const u8 = "productId";
        const case_result: []const u8 = try snakeCaseAlloc(testing.allocator, str);
        defer testing.allocator.free(case_result);

        try testing.expectEqualStrings("product_id", case_result);
    }
    {
        const str: []const u8 = "SomeExcitingURL";
        const case_result: []const u8 = try snakeCaseAlloc(testing.allocator, str);
        defer testing.allocator.free(case_result);

        try testing.expectEqualStrings("some_exciting_url", case_result);
    }
    {
        const str: []const u8 = "IMBCode";
        const case_result: []const u8 = try snakeCaseAlloc(testing.allocator, str);
        defer testing.allocator.free(case_result);

        try testing.expectEqualStrings("imb_code", case_result);
    }
    {
        const str: []const u8 = "kebab-case";
        const case_result: []const u8 = try snakeCaseAlloc(testing.allocator, str);
        defer testing.allocator.free(case_result);

        try testing.expectEqualStrings("kebab_case", case_result);
    }
    {
        const str: []const u8 = "snake_case";
        const case_result: []const u8 = try snakeCaseAlloc(testing.allocator, str);
        defer testing.allocator.free(case_result);

        try testing.expectEqualStrings("snake_case", case_result);
    }
    {
        const str: []const u8 = "SCREAMING_SNAKE";
        const case_result: []const u8 = try snakeCaseAlloc(testing.allocator, str);
        defer testing.allocator.free(case_result);

        try testing.expectEqualStrings("screaming_snake", case_result);
    }
    {
        const str: []const u8 = "this$Contains2Oddballs";
        const case_result: []const u8 = try snakeCaseAlloc(testing.allocator, str);
        defer testing.allocator.free(case_result);

        try testing.expectEqualStrings("this_contains_2_oddballs", case_result);
    }
    {
        const str: []const u8 = "$$doubleDollars";
        const case_result: []const u8 = try snakeCaseAlloc(testing.allocator, str);
        defer testing.allocator.free(case_result);

        try testing.expectEqualStrings("double_dollars", case_result);
    }
}

test screamingSnakeCaseAlloc {
    {
        const str: []const u8 = "productId";
        const case_result: []const u8 = try screamingSnakeCaseAlloc(testing.allocator, str);
        defer testing.allocator.free(case_result);

        try testing.expectEqualStrings("PRODUCT_ID", case_result);
    }
    {
        const str: []const u8 = "SomeExcitingURL";
        const case_result: []const u8 = try screamingSnakeCaseAlloc(testing.allocator, str);
        defer testing.allocator.free(case_result);

        try testing.expectEqualStrings("SOME_EXCITING_URL", case_result);
    }
    {
        const str: []const u8 = "IMBCode";
        const case_result: []const u8 = try screamingSnakeCaseAlloc(testing.allocator, str);
        defer testing.allocator.free(case_result);

        try testing.expectEqualStrings("IMB_CODE", case_result);
    }
    {
        const str: []const u8 = "kebab-case";
        const case_result: []const u8 = try screamingSnakeCaseAlloc(testing.allocator, str);
        defer testing.allocator.free(case_result);

        try testing.expectEqualStrings("KEBAB_CASE", case_result);
    }
    {
        const str: []const u8 = "snake_case";
        const case_result: []const u8 = try screamingSnakeCaseAlloc(testing.allocator, str);
        defer testing.allocator.free(case_result);

        try testing.expectEqualStrings("SNAKE_CASE", case_result);
    }
    {
        const str: []const u8 = "SCREAMING_SNAKE";
        const case_result: []const u8 = try screamingSnakeCaseAlloc(testing.allocator, str);
        defer testing.allocator.free(case_result);

        try testing.expectEqualStrings("SCREAMING_SNAKE", case_result);
    }
    {
        const str: []const u8 = "this$Contains2Oddballs";
        const case_result: []const u8 = try screamingSnakeCaseAlloc(testing.allocator, str);
        defer testing.allocator.free(case_result);

        try testing.expectEqualStrings("THIS_CONTAINS_2_ODDBALLS", case_result);
    }
    {
        const str: []const u8 = "$$doubleDollars";
        const case_result: []const u8 = try screamingSnakeCaseAlloc(testing.allocator, str);
        defer testing.allocator.free(case_result);

        try testing.expectEqualStrings("DOUBLE_DOLLARS", case_result);
    }
}

const std = @import("std");
const Io = std.Io;
const ascii = std.ascii;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const BufPrintError = std.fmt.BufPrintError;
