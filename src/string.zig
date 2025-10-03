/// Convert a string to title case (naively ignoring non-alphanumeric characters)
/// Free the resulting string with `gpa`.
pub fn titleCase(gpa: Allocator, str: []const u8) Allocator.Error![]const u8 {
    return try titleOrCamelCase(gpa, str, .upper);
}

/// Convert a string to camel case (naively ignoring non-alphanumeric characters)
/// Free the resulting string with `gpa`.
pub fn camelCase(gpa: Allocator, str: []const u8) Allocator.Error![]const u8 {
    return try titleOrCamelCase(gpa, str, .lower);
}

fn titleOrCamelCase(gpa: Allocator, str: []const u8, initial_casing: Casing) Allocator.Error![]const u8 {
    std.debug.assert(initial_casing != .either);

    var list: ArrayList(u8) = try .initCapacity(gpa, str.len);
    defer list.deinit(gpa);

    var handle_next: Casing = initial_casing;
    for (str, 0..) |char, i| switch (char) {
        '0'...'9', 'a'...'z', 'A'...'Z' => {
            switch (handle_next) {
                .upper => {
                    list.appendAssumeCapacity(ascii.toUpper(char));
                    handle_next = .lower;
                },
                .lower => {
                    const next_is_lower: bool = list.items.len > 0 and
                        ascii.isUpper(char) and
                        i + 1 < str.len and
                        ascii.isLower(str[i + 1]);

                    if (!ascii.isUpper(char) or next_is_lower) {
                        handle_next = .either;
                    }
                    list.appendAssumeCapacity(if (next_is_lower) char else ascii.toLower(char));
                },
                .either => {
                    list.appendAssumeCapacity(char);
                    if (ascii.isUpper(char)) {
                        handle_next = .lower;
                    }
                },
            }
        },
        else => {
            // skip (these don't belong here)
            if (ascii.isPrint(char) and list.items.len > 0) {
                handle_next = .upper;
            }
        },
    };
    return try list.toOwnedSlice(gpa);
}

/// Convert a string to kebab case (naively ignoring non-alphanumeric characters)
/// Free the resulting string with `gpa`.
pub fn kebabCase(gpa: Allocator, str: []const u8) Allocator.Error![]const u8 {
    return try separatedCase(gpa, str, '-', .lower);
}

/// Convert a string to snake case (naively ignoring non-alphanumeric characters)
/// Free the resulting string with `gpa`.
pub fn snakeCase(gpa: Allocator, str: []const u8) Allocator.Error![]const u8 {
    return try separatedCase(gpa, str, '_', .lower);
}

/// Convert a string to screaming snake case (naively ignoring non-alphanumeric characters)
/// Free the resulting string with `gpa`.
pub fn screamingSnakeCase(gpa: Allocator, str: []const u8) Allocator.Error![]const u8 {
    return try separatedCase(gpa, str, '_', .upper);
}

fn separatedCase(
    gpa: Allocator,
    str: []const u8,
    separator: u8,
    casing: Casing,
) Allocator.Error![]const u8 {
    std.debug.assert(casing != .either);

    var list: ArrayList(u8) = try .initCapacity(gpa, str.len * 2);
    defer list.deinit(gpa);

    for (str, 0..) |char, i| switch (char) {
        '0'...'9' => {
            const next_is_digit: bool = i + 1 < str.len and ascii.isDigit(str[i + 1]);
            if (list.getLastOrNull()) |last|
                if ((last != separator and !ascii.isDigit(last)) or !next_is_digit) {
                    list.appendAssumeCapacity(separator);
                };
            list.appendAssumeCapacity(char);
        },
        'A'...'Z', 'a'...'z' => {
            const next_is_upper: bool = i + 1 < str.len and (ascii.isUpper(str[i + 1]) or !ascii.isAlphabetic(str[i + 1]));
            const prev_is_upper: bool = i > 0 and ascii.isUpper(str[i - 1]);
            if (ascii.isUpper(char))
                if (list.getLastOrNull()) |last|
                    if (last != separator and ((!next_is_upper and i + 1 < str.len) or !prev_is_upper)) {
                        list.appendAssumeCapacity(separator);
                    };
            list.appendAssumeCapacity(switch (casing) {
                .upper => ascii.toUpper(char),
                .lower => ascii.toLower(char),
                .either => unreachable,
            });
        },
        else => {
            if (list.getLastOrNull()) |last| if (last != separator) {
                list.appendAssumeCapacity(separator);
            };
        }
    };

    return try list.toOwnedSlice(gpa);
}

const Casing = enum {
    upper,
    lower,
    either,
};

test titleCase {
    {
        const str: []const u8 = "IsTitleCase";
        const case_result: []const u8 = try titleCase(testing.allocator, str);
        defer testing.allocator.free(case_result);

        try testing.expectEqualStrings(str, case_result);
    }
    {
        const str: []const u8 = "productID";
        const case_result: []const u8 = try titleCase(testing.allocator, str);
        defer testing.allocator.free(case_result);

        try testing.expectEqualStrings("ProductId", case_result);
    }
    {
        const str: []const u8 = "SomeExcitingURL";
        const case_result: []const u8 = try titleCase(testing.allocator, str);
        defer testing.allocator.free(case_result);

        try testing.expectEqualStrings("SomeExcitingUrl", case_result);
    }
    {
        const str: []const u8 = "IMBCode";
        const case_result: []const u8 = try titleCase(testing.allocator, str);
        defer testing.allocator.free(case_result);

        try testing.expectEqualStrings("ImbCode", case_result);
    }
    {
        const str: []const u8 = "kebab-case";
        const case_result: []const u8 = try titleCase(testing.allocator, str);
        defer testing.allocator.free(case_result);

        try testing.expectEqualStrings("KebabCase", case_result);
    }
    {
        const str: []const u8 = "snake_case";
        const case_result: []const u8 = try titleCase(testing.allocator, str);
        defer testing.allocator.free(case_result);

        try testing.expectEqualStrings("SnakeCase", case_result);
    }
    {
        const str: []const u8 = "SCREAMING_SNAKE";
        const case_result: []const u8 = try titleCase(testing.allocator, str);
        defer testing.allocator.free(case_result);

        try testing.expectEqualStrings("ScreamingSnake", case_result);
    }
    {
        const str: []const u8 = "this$Contains2Oddballs";
        const case_result: []const u8 = try titleCase(testing.allocator, str);
        defer testing.allocator.free(case_result);

        try testing.expectEqualStrings("ThisContains2Oddballs", case_result);
    }
    {
        const str: []const u8 = "$$doubleDollars";
        const case_result: []const u8 = try titleCase(testing.allocator, str);
        defer testing.allocator.free(case_result);

        try testing.expectEqualStrings("DoubleDollars", case_result);
    }
}
test camelCase {
    {
        const str: []const u8 = "isCamelCase";
        const case_result: []const u8 = try camelCase(testing.allocator, str);
        defer testing.allocator.free(case_result);

        try testing.expectEqualStrings(str, case_result);
    }
    {
        const str: []const u8 = "productID";
        const case_result: []const u8 = try camelCase(testing.allocator, str);
        defer testing.allocator.free(case_result);

        try testing.expectEqualStrings("productId", case_result);
    }
    {
        const str: []const u8 = "SomeExcitingURL";
        const case_result: []const u8 = try camelCase(testing.allocator, str);
        defer testing.allocator.free(case_result);

        try testing.expectEqualStrings("someExcitingUrl", case_result);
    }
    {
        const str: []const u8 = "IMBCode";
        const case_result: []const u8 = try camelCase(testing.allocator, str);
        defer testing.allocator.free(case_result);

        try testing.expectEqualStrings("imbCode", case_result);
    }
    {
        const str: []const u8 = "kebab-case";
        const case_result: []const u8 = try camelCase(testing.allocator, str);
        defer testing.allocator.free(case_result);

        try testing.expectEqualStrings("kebabCase", case_result);
    }
    {
        const str: []const u8 = "snake_case";
        const case_result: []const u8 = try camelCase(testing.allocator, str);
        defer testing.allocator.free(case_result);

        try testing.expectEqualStrings("snakeCase", case_result);
    }
    {
        const str: []const u8 = "SCREAMING_SNAKE";
        const case_result: []const u8 = try camelCase(testing.allocator, str);
        defer testing.allocator.free(case_result);

        try testing.expectEqualStrings("screamingSnake", case_result);
    }
    {
        const str: []const u8 = "this$Contains2Oddballs";
        const case_result: []const u8 = try camelCase(testing.allocator, str);
        defer testing.allocator.free(case_result);

        try testing.expectEqualStrings("thisContains2Oddballs", case_result);
    }
    {
        const str: []const u8 = "$$doubleDollars";
        const case_result: []const u8 = try camelCase(testing.allocator, str);
        defer testing.allocator.free(case_result);

        try testing.expectEqualStrings("doubleDollars", case_result);
    }
}

test kebabCase {
    {
        const str: []const u8 = "productId";
        const case_result: []const u8 = try kebabCase(testing.allocator, str);
        defer testing.allocator.free(case_result);

        try testing.expectEqualStrings("product-id", case_result);
    }
    {
        const str: []const u8 = "SomeExcitingURL";
        const case_result: []const u8 = try kebabCase(testing.allocator, str);
        defer testing.allocator.free(case_result);

        try testing.expectEqualStrings("some-exciting-url", case_result);
    }
    {
        const str: []const u8 = "IMBCode";
        const case_result: []const u8 = try kebabCase(testing.allocator, str);
        defer testing.allocator.free(case_result);

        try testing.expectEqualStrings("imb-code", case_result);
    }
    {
        const str: []const u8 = "kebab-case";
        const case_result: []const u8 = try kebabCase(testing.allocator, str);
        defer testing.allocator.free(case_result);

        try testing.expectEqualStrings("kebab-case", case_result);
    }
    {
        const str: []const u8 = "snake_case";
        const case_result: []const u8 = try kebabCase(testing.allocator, str);
        defer testing.allocator.free(case_result);

        try testing.expectEqualStrings("snake-case", case_result);
    }
    {
        const str: []const u8 = "SCREAMING_SNAKE";
        const case_result: []const u8 = try kebabCase(testing.allocator, str);
        defer testing.allocator.free(case_result);

        try testing.expectEqualStrings("screaming-snake", case_result);
    }
    {
        const str: []const u8 = "this$Contains2Oddballs";
        const case_result: []const u8 = try kebabCase(testing.allocator, str);
        defer testing.allocator.free(case_result);

        try testing.expectEqualStrings("this-contains-2-oddballs", case_result);
    }
    {
        const str: []const u8 = "$$doubleDollars";
        const case_result: []const u8 = try kebabCase(testing.allocator, str);
        defer testing.allocator.free(case_result);

        try testing.expectEqualStrings("double-dollars", case_result);
    }
}

test snakeCase {
    {
        const str: []const u8 = "productId";
        const case_result: []const u8 = try snakeCase(testing.allocator, str);
        defer testing.allocator.free(case_result);

        try testing.expectEqualStrings("product_id", case_result);
    }
    {
        const str: []const u8 = "SomeExcitingURL";
        const case_result: []const u8 = try snakeCase(testing.allocator, str);
        defer testing.allocator.free(case_result);

        try testing.expectEqualStrings("some_exciting_url", case_result);
    }
    {
        const str: []const u8 = "IMBCode";
        const case_result: []const u8 = try snakeCase(testing.allocator, str);
        defer testing.allocator.free(case_result);

        try testing.expectEqualStrings("imb_code", case_result);
    }
    {
        const str: []const u8 = "kebab-case";
        const case_result: []const u8 = try snakeCase(testing.allocator, str);
        defer testing.allocator.free(case_result);

        try testing.expectEqualStrings("kebab_case", case_result);
    }
    {
        const str: []const u8 = "snake_case";
        const case_result: []const u8 = try snakeCase(testing.allocator, str);
        defer testing.allocator.free(case_result);

        try testing.expectEqualStrings("snake_case", case_result);
    }
    {
        const str: []const u8 = "SCREAMING_SNAKE";
        const case_result: []const u8 = try snakeCase(testing.allocator, str);
        defer testing.allocator.free(case_result);

        try testing.expectEqualStrings("screaming_snake", case_result);
    }
    {
        const str: []const u8 = "this$Contains2Oddballs";
        const case_result: []const u8 = try snakeCase(testing.allocator, str);
        defer testing.allocator.free(case_result);

        try testing.expectEqualStrings("this_contains_2_oddballs", case_result);
    }
    {
        const str: []const u8 = "$$doubleDollars";
        const case_result: []const u8 = try snakeCase(testing.allocator, str);
        defer testing.allocator.free(case_result);

        try testing.expectEqualStrings("double_dollars", case_result);
    }
}

test screamingSnakeCase {
    {
        const str: []const u8 = "productId";
        const case_result: []const u8 = try screamingSnakeCase(testing.allocator, str);
        defer testing.allocator.free(case_result);

        try testing.expectEqualStrings("PRODUCT_ID", case_result);
    }
    {
        const str: []const u8 = "SomeExcitingURL";
        const case_result: []const u8 = try screamingSnakeCase(testing.allocator, str);
        defer testing.allocator.free(case_result);

        try testing.expectEqualStrings("SOME_EXCITING_URL", case_result);
    }
    {
        const str: []const u8 = "IMBCode";
        const case_result: []const u8 = try screamingSnakeCase(testing.allocator, str);
        defer testing.allocator.free(case_result);

        try testing.expectEqualStrings("IMB_CODE", case_result);
    }
    {
        const str: []const u8 = "kebab-case";
        const case_result: []const u8 = try screamingSnakeCase(testing.allocator, str);
        defer testing.allocator.free(case_result);

        try testing.expectEqualStrings("KEBAB_CASE", case_result);
    }
    {
        const str: []const u8 = "snake_case";
        const case_result: []const u8 = try screamingSnakeCase(testing.allocator, str);
        defer testing.allocator.free(case_result);

        try testing.expectEqualStrings("SNAKE_CASE", case_result);
    }
    {
        const str: []const u8 = "SCREAMING_SNAKE";
        const case_result: []const u8 = try screamingSnakeCase(testing.allocator, str);
        defer testing.allocator.free(case_result);

        try testing.expectEqualStrings("SCREAMING_SNAKE", case_result);
    }
    {
        const str: []const u8 = "this$Contains2Oddballs";
        const case_result: []const u8 = try screamingSnakeCase(testing.allocator, str);
        defer testing.allocator.free(case_result);

        try testing.expectEqualStrings("THIS_CONTAINS_2_ODDBALLS", case_result);
    }
    {
        const str: []const u8 = "$$doubleDollars";
        const case_result: []const u8 = try screamingSnakeCase(testing.allocator, str);
        defer testing.allocator.free(case_result);

        try testing.expectEqualStrings("DOUBLE_DOLLARS", case_result);
    }
}

const std = @import("std");
const ascii = std.ascii;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
