//! Use this for writing various date/time formats
pub const DateTimeFormat = @This();

/// Timestamp itself
timestamp: Io.Timestamp,
/// Formatting of the fields and separator characters in the order they would appear
formatting: Formatting,
/// Time zone
utc_offset: UtcOffset,

/// Offset from UTC time
pub const UtcOffset = packed struct(u8) {
    /// Positive or negative offset in hours
    hours: i6,
    /// Possible quarter hours (0, 1, 2, or 3 for xx:00, xx:15, xx:30, and xx:45 respectively)
    quarter_hours: u2,

    /// Zero-offset (aka UTC time)
    pub const utc: UtcOffset = .{ .hours = 0, .quarter_hours = 0 };

    pub fn format(self: UtcOffset, writer: *Io.Writer) Io.Writer.Error!void {
        // TODO : This was the easy way, but I think we should allow more formats such as:
        // +00:00
        // +0
        // 0200
        if (self == utc) {
            try writer.writeByte('Z');
            return;
        }
        try writer.print("{d:0>2}:{d:0>2}", .{ self.hours, @as(u16, self.quarter_hours) * 15 });
    }

    pub fn asDuration(self: UtcOffset) Io.Duration {
        var ns: i96 = 0;
        ns += self.hours * time.ns_per_hour;
        ns += self.quarter_hours * if (self.hours < 0) -1 else 1 * 15 * time.ns_per_min;
        return .fromNanoseconds(ns);
    }

    fn parse(tokenizer: *Tokenizer) error{InvalidUtcOffset}!UtcOffset {
        var offset: UtcOffset = .utc;
        var next: Tokenizer.Token = tokenizer.expectOneOf(&.{
            .{ .exactly = "Z" },
            .{ .exactly = "-" },
            .{ .exactly = "+" },
            .{ .category = .numeric },
        }) catch return error.InvalidUtcOffset;

        var substring: []const u8 = "";
        switch (next.category) {
            .alpha => return offset,
            .numeric => offset.hours = std.fmt.parseInt(i6, next.value, 10) catch return error.InvalidUtcOffset,
            .separator => substring = next.value,
        }

        if (substring.len > 0) {
            next = tokenizer.expectOneOf(&.{.{ .category = .numeric }}) catch return error.InvalidUtcOffset;
            substring.len += next.value.len;
            offset.hours = std.fmt.parseInt(i6, substring, 10) catch |err| switch (err) {
                error.InvalidCharacter => return error.InvalidUtcOffset,
                error.Overflow => {
                    // this could be the situation where we're parsing 0000 format (with or without leading sign)
                    if ((substring[0] == '+' or substring[0] == '-') and substring.len == 5) {
                        offset.hours = std.fmt.parseInt(i6, substring[0..3], 10) catch return error.InvalidUtcOffset;
                        const minutes: []const u8 = substring[3..];
                        assert(minutes.len == 2);
                        if (parseMinutes(minutes)) |m| {
                            offset.quarter_hours = m;
                            return offset;
                        }
                    } else if (substring.len == 4) {
                        offset.hours = std.fmt.parseInt(i6, substring[0..2], 10) catch return error.InvalidUtcOffset;
                        const minutes: []const u8 = substring[2..];
                        assert(minutes.len == 2);
                        if (parseMinutes(minutes)) |m| {
                            offset.quarter_hours = m;
                            return offset;
                        }
                    }
                    return error.InvalidUtcOffset;
                }
            };
        }

        // now we have hours, so whatever we can't parse must simply be the end of this date-time element
        if (tokenizer.expectOneOf(&.{.{ .exactly = ":" }})) |colon| {
            if (tokenizer.expectOneOf(&.{.{ .category = .numeric }})) |minutes| {
                if (parseMinutes(minutes.value)) |m| {
                    offset.quarter_hours = m;
                } else {
                    tokenizer.rollback(minutes);
                    tokenizer.rollback(colon);
                }
            } else |_| tokenizer.rollback(colon);
        } else |_| {}
        return offset;
    }

    fn parseMinutes(slice: []const u8) ?u2 {
        const MinuteSlice = enum(u2) {
            @"00" = 0,
            @"15" = 1,
            @"30" = 2,
            @"45" = 3,
        };
        return if (std.meta.stringToEnum(MinuteSlice, slice)) |m| @intFromEnum(m) else null;
    }
};

/// Various possible parse errors that could be returned from `parse(...)`
pub const ParseError = error{
    UnexpectedCharacter,
    UnrecognizedSegment,
    InvalidYear,
    InvalidMonth,
    InvalidDay,
    InvalidHour,
    InvalidMinute,
    InvalidSecond,
    InvalidSubsecond,
    InvalidUtcOffset,
    MissingYear,
    MissingMonth,
};

pub const WeekDay = enum(u4) {
    Sunday,
    Monday,
    Tuesday,
    Wednesday,
    Thursday,
    Friday,
    Saturday,

    pub fn fromTimestamp(timestamp: Io.Timestamp) WeekDay {
        // Fun fact: Jan. 1, 1970 was a Thursday, so we need add Thursday as an offset
        const days: u64 = @divTrunc(@abs(timestamp.toSeconds()), time.s_per_day) + @intFromEnum(WeekDay.Thursday);
        return @enumFromInt(@mod(days, 7));
    }

    /// Abbreviate to the first 3 letters
    pub fn abbreviate(self: WeekDay) []const u8 {
        return @tagName(self)[0..3];
    }

    test fromTimestamp {
        const nanoseconds: i96 = 1779486527036758700; // Friday, May 22, 2026 at 9:48:47.0367587 PM (UTC)
        const day_of_week: WeekDay = .fromTimestamp(.fromNanoseconds(nanoseconds));
        try testing.expectEqual(WeekDay.Friday, day_of_week);
    }
};

/// Element of a date-time
pub const Element = enum {
    /// Year
    year,
    /// Month
    month,
    /// Day of the month
    day,
    /// Day of the week (its name)
    weekday,
    /// Hours
    hour,
    /// Minutes
    minute,
    /// Seconds
    second,
    /// Subseconds, represented in up to 7 places
    subsecond,
    /// UTC offset
    utc_offset,

    fn toFormat(self: Element, elem_len: comptime_int) ElementFormat {
        return switch (self) {
            .year => if (elem_len <= 5)
                .{ .year = elem_len }
            else
                @compileError(comptimePrint("Year can only display up to 5 places. Found {d}.", .{elem_len})),
            .month => .{
                .month = switch (elem_len) {
                    0, 1 => .natural,
                    2 => .zero_filled,
                    3 => .abbreviation,
                    4 => .full_name,
                    else => @compileError(comptimePrint("Invalid month format '{s}'", .{&@as([elem_len]u8, @splat('M'))})),
                },
            },
            .day => .{
                .day = switch (elem_len) {
                    0, 1 => .natural,
                    2 => .zero_filled,
                    else => @compileError(comptimePrint("Invalid day format '{s}'", .{&@as([elem_len]u8, @splat('d'))})),
                },
            },
            .weekday => .{
                .weekday = switch (elem_len) {
                    0, 1 => .abbreviation,
                    2 => .full_name,
                    else => @compileError(comptimePrint("Invalid weekday format '{s}'", .{&@as([elem_len]u8, @splat('D'))})),
                },
            },
            .hour => .{
                .hour = switch (elem_len) {
                    0, 1 => .natural,
                    2 => .zero_filled,
                    else => @compileError(comptimePrint("Invalid hour format '{s}'", .{&@as([elem_len]u8, @splat('h'))})),
                },
            },
            .minute => .{
                .minute = switch (elem_len) {
                    0, 1 => .natural,
                    2 => .zero_filled,
                    else => @compileError(comptimePrint("Invalid minute format '{s}'", .{&@as([elem_len]u8, @splat('m'))})),
                },
            },
            .second => .{
                .second = switch (elem_len) {
                    0, 1 => .natural,
                    2 => .zero_filled,
                    else => @compileError(comptimePrint("Invalid second format '{s}'", .{&@as([elem_len]u8, @splat('s'))})),
                },
            },
            .subsecond => .{ .subsecond = elem_len },
            .utc_offset => .utc_offset,
        };
    }
};

pub const ElementFormat = union(Element) {
    /// The number of places to show
    year: u3,
    /// Month display strategy
    month: enum { natural, zero_filled, abbreviation, full_name },
    /// Day display strategy
    day: enum { natural, zero_filled },
    /// Day of the week display strategy
    weekday: enum { abbreviation, full_name },
    /// Hour display strategy
    hour: enum { natural, zero_filled },
    /// Minute display strategy
    minute: enum { natural, zero_filled },
    /// Second display strategy
    second: enum { natural, zero_filled },
    /// Number of places to show
    subsecond: u3,
    /// UTC offset format, whether or not to include
    utc_offset,
};

pub const FullFormat = struct {
    fmt: ElementFormat,
    fill: []const u8,
};

pub const Formatting = struct {
    map: EnumMap(Element, FullFormat),
    ordering: [@typeInfo(Element).@"enum".fields.len]?Element,

    pub const init: Formatting = .{
        .map = .init(.{}),
        .ordering = @splat(null),
    };

    pub inline fn fromFormatString(comptime format_str: []const u8) Formatting {
        comptime {
            var formatting: Formatting = .init;
            var current_element: ?Element = null;
            var elem_len: usize = 0;
            var fill_start: ?usize = null;
            var current_fmt: FullFormat = undefined;

            for (format_str, 0..) |char, i| {
                const next: ?Element = switch (char) {
                    'y' => .year,
                    'M' => .month,
                    'd' => .day,
                    'D' => .weekday,
                    'h' => .hour,
                    'm' => .minute,
                    's' => .second,
                    'f' => .subsecond,
                    'Z', 'z' => .utc_offset,
                    else => if (mem.findScalar(u8, separator_characters, char)) |_|
                        null
                    else
                        @compileError("Unexpected character '" ++ @as([]const u8, &.{char}) ++ "' in date-time format."),
                };
                if (current_element) |current| {
                    if (next == current) {
                        // more of the same
                        elem_len += 1;
                    } else if (next == null) {
                        // we're finishing off the current segment since we encountered a separator
                        if (fill_start == null) {
                            fill_start = i;
                            // capture the current
                            current_fmt = .{
                                .fmt = current.toFormat(elem_len),
                                .fill = format_str[i..][0..1],
                            };
                            if (i + 1 < format_str.len) {
                                elem_len = 1;
                            }
                        } else if (fill_start) |_| current_fmt.fill.len += 1;
                    } else if (next) |n| {
                        fill_start = null;
                        if (current_fmt.fmt != current) {
                            // this is a quick turnaround where we don't have a separator between elements, so fill is empty
                            current_fmt = .{
                                .fmt = current.toFormat(elem_len),
                                .fill = "",
                            };
                        }
                        if (formatting.fetchPut(current, current_fmt)) |_| {
                            @compileError(comptimePrint("Found redundant formatting for {t}: '{s}'", .{ current, format_str }));
                        }
                        // we're starting a new segment
                        current_element = n;
                        elem_len = 1;
                    }
                } else if (next) |n| {
                    current_element = n;
                    elem_len = 1;
                }

                // we're at the end with no separator
                if (next != null and i + 1 == format_str.len) {
                    if (current_element) |current| {
                        current_fmt = .{
                            .fmt = current.toFormat(elem_len),
                            .fill = if (fill_start) |f| format_str[f..][0..1] else "",
                        };
                        if (formatting.fetchPut(current, current_fmt)) |_| {
                            @compileError(comptimePrint("Found redundant formatting for {t}: '{s}'", .{ current, format_str }));
                        }
                    }
                }
            }
            assert(formatting.map.count() > 0);
            return formatting;
        }
    }

    pub fn fetchPut(self: *Formatting, key: Element, value: FullFormat) ?[]const u8 {
        if (self.map.fetchPut(key, value)) |old_value| {
            return old_value;
        }
        const next_idx: usize = mem.indexOfScalar(?Element, &self.ordering, null).?;
        self.ordering[next_idx] = key;
        return null;
    }

    pub fn iterator(self: Formatting) Iterator {
        return .{ .order = self, .idx = 0 };
    }

    pub const Entry = EnumMap(Element, FullFormat).Entry;

    pub const Iterator = struct {
        order: Formatting,
        idx: usize,

        pub fn next(self: *Iterator) ?Entry {
            if (self.idx < self.order.ordering.len) {
                if (self.order.ordering[self.idx]) |key| {
                    defer self.idx += 1;
                    return .{ .key = key, .value = self.order.map.getPtr(key).? };
                }
            }
            return null;
        }
    };
};

const Tokenizer = struct {
    str: []const u8,
    idx: usize,

    const Category = enum { numeric, alpha, separator };
    const Token = struct {
        value: []const u8,
        category: Category,
    };

    fn init(str: []const u8) Tokenizer {
        return .{
            .str = str,
            .idx = 0,
        };
    }

    fn next(self: *Tokenizer) error{UnexpectedCharacter}!?Token {
        if (self.idx >= self.str.len) {
            return null;
        }

        var sub_str: []const u8 = self.str[self.idx..][0..1];
        var categories: EnumSet(Category) = categorize(sub_str[0]) catch |err| {
            log.err("Unexpected character '{c}' at index {d} in date-time string '{s}'.", .{ sub_str[0], self.idx, self.str });
            return err;
        };

        self.idx += 1;
        while (self.idx < self.str.len) : (self.idx += 1) {
            const next_char: u8 = self.str[self.idx];
            const next_category_set: EnumSet(Category) = categorize(next_char) catch |err| {
                log.err("Unexpected character '{c}' at index {d} in date-time string '{s}'.", .{ next_char, self.idx, self.str });
                return err;
            };
            if (categories.intersectWith(next_category_set).count() == 0) {
                return .{
                    .value = sub_str,
                    .category = if (categories.count() == 1) category: {
                        var iter: EnumSet(Category).Iterator = categories.iterator();
                        break :category iter.next().?;
                    } else if (categories.contains(.separator))
                        .separator
                    else
                        unreachable,
                };
            } else {
                sub_str.len += 1;
                categories = categories.intersectWith(next_category_set);
            }
        }
        return .{
            .value = sub_str,
            .category = if (categories.count() == 1) category: {
                var iter: EnumSet(Category).Iterator = categories.iterator();
                break :category iter.next().?;
            } else if (categories.contains(.separator))
                .separator
            else
                unreachable,
        };
    }

    /// Expect a token in a category or a specific string.
    /// If not matched, then the tokenizer will roll back.
    fn expectOneOf(
        self: *Tokenizer,
        possible: []const union(enum) { category: Category, exactly: []const u8 },
    ) error{ NoMatch, UnexpectedCharacter, EndOfIteration }!Token {
        if (try self.next()) |n| {
            errdefer self.idx -= n.value.len;
            for (possible) |p| switch (p) {
                .category => |c| if (c == n.category) return n,
                .exactly => |e| if (mem.eql(u8, e, mem.trim(u8, n.value, &ascii.whitespace))) return n,
            };
            return error.NoMatch;
        }
        return error.EndOfIteration;
    }

    fn rollback(self: *Tokenizer, tok: Token) void {
        self.idx -= tok.value.len;
    }

    fn categorize(char: u8) error{UnexpectedCharacter}!EnumSet(Category) {
        return switch (char) {
            'a'...'z', 'A'...'S', 'U'...'Z' => .initOne(.alpha),
            'T' => .initMany(&.{ .alpha, .separator }), // 'T' is the only character valid as both a separator and an alpha token
            '0'...'9' => .initOne(.numeric),
            else => if (mem.findScalar(u8, separator_characters, char)) |_| .initOne(.separator) else error.UnexpectedCharacter,
        };
    }
};

/// Expected/allowed separator characters between the various elements.
const separator_characters: []const u8 = &.{ ' ', '/', '-', '+', '_', '.', ',', ':', 'T' };

const log = if (@import("builtin").is_test) struct {
    fn debug(comptime fmt_str: []const u8, args: anytype) void {
        if (testing.log_level == .debug) {
            std.debug.print(fmt_str ++ "\n", args);
        } else {
            var null_writer: Io.Writer.Discarding = .init(&.{});
            null_writer.writer.print(fmt_str, args) catch {};
        }
    }

    fn err(comptime fmt_str: []const u8, args: anytype) void {
        if (testing.log_level == .debug) {
            std.debug.print(fmt_str ++ @as([]const u8, &.{'\n'}), args);
        } else {
            var null_writer: Io.Writer.Discarding = .init(&.{});
            null_writer.writer.print(fmt_str, args) catch {};
        }
    }
} else std.log.scoped(.DateTimeFormat);

/// Format like `yyyy-MM-ddThh:mm:ss.fffZ`
pub fn iso(timestamp: Io.Timestamp) DateTimeFormat {
    return .fmt("yyyy-MM-ddThh:mm:ss.fffZ", timestamp, .utc);
}

/// Assumes that the timestamp is already UTC.
/// Then we'll apply the offset to the existing `timestamp`.
pub fn fmt(comptime format_str: []const u8, timestamp: Io.Timestamp, utc_offset: UtcOffset) DateTimeFormat {
    return .{
        .timestamp = timestamp,
        .formatting = .fromFormatString(format_str),
        .utc_offset = utc_offset,
    };
}

pub fn format(self: DateTimeFormat, writer: *Io.Writer) Io.Writer.Error!void {
    const ms_now: i64 = self.timestamp.toMilliseconds();
    const sec_now: i64 = @divTrunc(ms_now, 1000);
    const minutes_now: i64 = @divTrunc(sec_now, 60);
    const hours_now: i64 = @divTrunc(minutes_now, 60);

    const sec: i64 = @mod(sec_now, 60);
    const min: i64 = @mod(minutes_now, 60);
    const hour: i64 = @mod(hours_now, 24);

    const epoch_seconds: EpochSeconds = .{ .secs = @bitCast(sec_now) };
    const epoch_day: EpochDay = epoch_seconds.getEpochDay();
    const year_day: YearAndDay = epoch_day.calculateYearDay();
    const month_day: MonthAndDay = year_day.calculateMonthDay();

    var iter: Formatting.Iterator = self.formatting.iterator();
    while (iter.next()) |x| switch (x.value.fmt) {
        .year => |y| switch (y) {
            1 => try writer.print("{d}{s}", .{ year_day.year, x.value.fill }),
            2 => try writer.print("{d:0>2}{s}", .{ year_day.year, x.value.fill }),
            3 => try writer.print("{d:0>3}{s}", .{ year_day.year, x.value.fill }),
            4 => try writer.print("{d:0>4}{s}", .{ year_day.year, x.value.fill }),
            5 => try writer.print("{d:0>5}{s}", .{ year_day.year, x.value.fill }),
            else => unreachable,
        },
        .month => |m| switch (m) {
            .natural => try writer.print("{d}{s}", .{ month_day.month, x.value.fill }),
            .zero_filled => try writer.print("{d:0>2}{s}", .{ month_day.month, x.value.fill }),
            .abbreviation => {
                var buf: [3]u8 = undefined;
                var formatter: Io.Writer = .fixed(&buf);
                formatter.print("{t}", .{month_day.month}) catch unreachable;
                buf[0] = ascii.toUpper(buf[0]);
                try writer.print("{s}{s}", .{ formatter.buffered(), x.value.fill });
            },
            .full_name => try writer.print("{s}{s}", .{ switch (month_day.month) {
                .jan => "January",
                .feb => "February",
                .mar => "March",
                .apr => "April",
                .may => "May",
                .jun => "June",
                .jul => "July",
                .aug => "August",
                .sep => "September",
                .oct => "October",
                .nov => "November",
                .dec => "December",
            }, x.value.fill }),
        },
        .day => |d| switch (d) {
            // day index starts at 0
            .natural => try writer.print("{d}{s}", .{ month_day.day_index + 1, x.value.fill }),
            .zero_filled => try writer.print("{d:0>2}{s}", .{ month_day.day_index + 1, x.value.fill }),
        },
        .weekday => |w| switch (w) {
            .abbreviation => {
                const weekday: WeekDay = .fromTimestamp(self.timestamp);
                try writer.print("{s}{s}", .{ weekday.abbreviate(), x.value.fill });
            },
            .full_name => {
                const weekday: WeekDay = .fromTimestamp(self.timestamp);
                try writer.print("{t}{s}", .{ weekday, x.value.fill });
            },
        },
        .hour => |h| switch (h) {
            .natural => try writer.print("{d}{s}", .{ @abs(hour), x.value.fill }),
            .zero_filled => try writer.print("{d:0>2}{s}", .{ @abs(hour), x.value.fill }),
        },
        .minute => |m| switch (m) {
            .natural => try writer.print("{d}{s}", .{ @abs(min), x.value.fill }),
            .zero_filled => try writer.print("{d:0>2}{s}", .{ @abs(min), x.value.fill }),
        },
        .second => |s| switch (s) {
            .natural => try writer.print("{d}{s}", .{ @abs(sec), x.value.fill }),
            .zero_filled => try writer.print("{d:0>2}{s}", .{ @abs(sec), x.value.fill }),
        },
        .subsecond => |places| if (places > 0) {
            // write all nanoseconds to a buffer and strategically truncate
            var buf: [32]u8 = undefined;
            const full_ns: []const u8 = std.fmt.bufPrint(&buf, "{d}", .{self.timestamp.nanoseconds}) catch unreachable;
            // get the last 9 characters
            const subseconds: []const u8 = full_ns[full_ns.len - 9 ..];

            try writer.print("{s}{s}", .{ subseconds[0..places], x.value.fill });
        },
        .utc_offset => try writer.print("{f}", .{self.utc_offset}),
    };
}

/// A more flexible parsing strategy, where `expected_elements` lists the elements we expect and which order we expect them.
/// This parser doesn't look for specific separators.
/// Once all expected elements have been filled out, we will ignore whatever remains of the string.
/// NOTE: The returned `DateTimeFormat` will have empty formatting and assumes UTC by default.
pub fn parse(str: []const u8, expected_elements: []const Element) ParseError!DateTimeFormat {
    assert(expected_elements.len > 0);

    var utc_offset: UtcOffset = .utc;
    var map: EnumMap(Element, []const u8) = .init(.{});
    var tokenizer: Tokenizer = .init(mem.trim(u8, str, &ascii.whitespace));
    var element_idx: usize = 0;
    while (try tokenizer.next()) |tok| {
        switch (tok.category) {
            .separator => log.debug("Ignoring separator '{s}'.", .{tok.value}),
            else => {
                if (tok.value.len > 0) {
                    if (element_idx >= expected_elements.len) break;
                    defer element_idx += 1;
                    if (expected_elements[element_idx] == .utc_offset) {
                        tokenizer.rollback(tok); // roll back this token
                        utc_offset = try .parse(&tokenizer);
                    } else if (map.fetchPut(expected_elements[element_idx], tok.value)) |_| {
                        panic("Date-time element {t} was present more than once in the slice of expected elements.", .{expected_elements[element_idx]});
                    }
                    log.debug("Segment {d} ({t}): '{s}'", .{ element_idx, expected_elements[element_idx], tok.value });
                }
                // ignore empty strings
            }
        }
    }
    const timestamp: Io.Timestamp = try parseInner(&map);
    return .{
        .timestamp = timestamp,
        .formatting = .init,
        .utc_offset = utc_offset,
    };
}

/// Parse an exactly-formatted date-time string.
/// NOTE: Assumes UTC by default
pub fn parseExact(str: []const u8, comptime format_str: []const u8) (ParseError || error{ UnrecognizedSegment, MismatchedSeparator })!DateTimeFormat {
    const formatting: Formatting = .fromFormatString(format_str);
    var map: EnumMap(Element, []const u8) = .init(.{});

    var utc_offset: UtcOffset = .utc;
    var expected_elements: Formatting.Iterator = formatting.iterator();
    var tokenizer: Tokenizer = .init(mem.trim(u8, str, &ascii.whitespace));
    var current_element: Formatting.Entry = expected_elements.next() orelse unreachable;
    while (try tokenizer.next()) |tok| {
        switch (tok.category) {
            .separator => {
                if (!mem.eql(u8, tok.value, current_element.value.fill)) {
                    log.err("Separator following element {t} did not match. Expected: '{s}', Received: '{s}'", .{ current_element.key, current_element.value.fill, tok.value });
                    return error.MismatchedSeparator;
                }
                log.debug("Matched expected separator '{s}'. Getting next segment.", .{tok.value});
                current_element = expected_elements.next() orelse break;
            },
            else => {
                if (tok.value.len > 0) {
                    if (current_element.key == .utc_offset) {
                        tokenizer.rollback(tok);
                        utc_offset = try .parse(&tokenizer);
                    } else {
                        if (map.fetchPut(current_element.key, tok.value)) |_| {
                            panic("Date-time element {t} was present more than once. Attempting to add segment '{s}'.", .{ current_element.key, tok.value });
                        }
                        log.debug("Segment ({t}): '{s}'", .{ current_element.key, tok.value });
                        if (current_element.value.fill.len == 0) {
                            // if there's no fill, then we need to switch to the next element
                            current_element = expected_elements.next() orelse break;
                        }
                    }
                }
                // ignore empty strings
            }
        }
    }
    if (try tokenizer.next()) |tok| {
        log.err("Expected elements have been filled, but the date-time string has another segment '{s}'.", .{tok.value});
        return error.UnrecognizedSegment;
    }
    const timestamp: Io.Timestamp = try parseInner(&map);
    return .{
        .timestamp = timestamp,
        .formatting = formatting,
        .utc_offset = utc_offset,
    };
}

fn parseInner(map: *EnumMap(Element, []const u8)) ParseError!Io.Timestamp {
    var nanoseconds: i96 = 0;
    var iter: EnumMap(Element, []const u8).Iterator = map.iterator();
    while (iter.next()) |kvp| switch (kvp.key) {
        .year => {
            const year: u16 = parseUnsigned(u16, kvp.value.*, 10) catch return error.InvalidYear;
            if (year < 1970) {
                log.err("Year {d} predates UNIX epoch. I haven't implemented date-time parsing for years before the UNIX epoch. You can open an issue or I might get around to it later. :) -MiahDrao97", .{year});
                return error.InvalidYear;
            }
            for (1970..year) |y| {
                nanoseconds += (@as(i96, @intCast(time.epoch.getDaysInYear(@intCast(y)))) * time.ns_per_day);
            }
        },
        .month => {
            const month: Month = try parseMonth(kvp.value.*);
            const year_slice: []const u8 = map.get(.year) orelse return error.MissingYear;
            const year: u16 = parseUnsigned(u16, year_slice, 10) catch return error.InvalidYear;
            // this loop intentionally stops before the present month since the "days" value informs us how far into the present month we are
            for (@intFromEnum(Month.jan)..@intFromEnum(month)) |m| {
                nanoseconds += (@as(i96, @intCast(time.epoch.getDaysInMonth(year, @enumFromInt(m)))) * time.ns_per_day);
            }
        },
        .day => {
            const day: u5 = parseUnsigned(u5, kvp.value.*, 10) catch return error.InvalidDay;
            const year_slice: []const u8 = map.get(.year) orelse return error.MissingYear;
            const year: u16 = parseUnsigned(u16, year_slice, 10) catch return error.InvalidYear;
            const month: Month = try parseMonth(map.get(.month) orelse return error.MissingMonth);
            if (day < 1 or day > time.epoch.getDaysInMonth(year, month)) return error.InvalidDay;
            // have to subtract one because the day you're ON might not be complete
            nanoseconds += (@as(i96, @intCast(day - 1)) * time.ns_per_day);
        },
        .weekday => {
            // this has no bearing on the actual timestamp
        },
        .hour => {
            const hour: u5 = parseUnsigned(u5, kvp.value.*, 10) catch return error.InvalidHour;
            if (hour > 23) return error.InvalidHour;
            nanoseconds += (@as(i96, @intCast(hour)) * time.ns_per_hour);
        },
        .minute => {
            const minute: u6 = parseUnsigned(u6, kvp.value.*, 10) catch return error.InvalidMinute;
            if (minute > 59) return error.InvalidMinute;
            nanoseconds += (@as(i96, @intCast(minute)) * time.ns_per_min);
        },
        .second => {
            const second: u6 = parseUnsigned(u6, kvp.value.*, 10) catch return error.InvalidSecond;
            if (second > 59) return error.InvalidSecond;
            nanoseconds += (@as(i96, @intCast(second)) * time.ns_per_s);
        },
        .subsecond => {
            // okay, we have to determine the length of the slice to how many places we're talking about
            const power: u64 = switch (kvp.value.len) {
                1...9 => |x| 9 - x,
                else => |invalid| {
                    log.err("Length of subsecond segment must be at least 1 and up to 9. Found {d}.", .{invalid});
                    return error.InvalidSubsecond;
                }
            };
            const subseconds: u64 = std.math.pow(u64, 10, power) * (parseUnsigned(u64, kvp.value.*, 10) catch return error.InvalidSubsecond);
            nanoseconds += subseconds;
        },
        .utc_offset => unreachable,
    };

    return .fromNanoseconds(nanoseconds);
}

fn parseMonth(slice: []const u8) error{InvalidMonth}!Month {
    if (parseUnsigned(u4, slice, 10)) |month| {
        return std.enums.fromInt(Month, month) orelse return error.InvalidMonth;
    } else |_| {
        const FullMonth = enum(u4) {
            January = 1,
            February,
            March,
            April,
            May,
            June,
            July,
            August,
            September,
            October,
            November,
            December,
        };
        const AbbreviatedMonth = enum(u4) {
            Jan = 1,
            Feb,
            Mar,
            Apr,
            May,
            Jun,
            Jul,
            Aug,
            Sep,
            Oct,
            Nov,
            Dec,
        };
        if (std.meta.stringToEnum(FullMonth, slice)) |month| {
            return @enumFromInt(@intFromEnum(month));
        }
        if (std.meta.stringToEnum(AbbreviatedMonth, slice)) |month| {
            return @enumFromInt(@intFromEnum(month));
        }
        if (std.meta.stringToEnum(Month, slice)) |month| {
            return month;
        }
        log.err("Invalid month '{s}'", .{slice});
        return error.InvalidMonth;
    }
}

test iso {
    const nanoseconds: i96 = 1779486527036758700; // Friday, May 22, 2026 at 9:48:47.0367587 PM (UTC)

    var stream: Io.Writer.Allocating = .init(testing.allocator);
    defer stream.deinit();
    try stream.writer.print("{f}", .{DateTimeFormat.iso(.fromNanoseconds(nanoseconds))});

    // this is a good test case because the milliseconds start with a leading zero
    try testing.expectEqualStrings("2026-05-22T21:48:47.036Z", stream.written());
}
test "max i96 buf" {
    var buf: [32]u8 = undefined;
    var writer: Io.Writer = .fixed(&buf);
    try writer.print("{d}", .{std.math.maxInt(i96)});
    try testing.expectEqual(29, writer.buffered().len);
}
test parseExact {
    const date_str = "2026-05-22T21:48:47.036Z";
    const date_time: DateTimeFormat = try .parseExact(date_str, "yyyy-MM-ddThh:mm:ss.fffZ");

    try testing.expectEqual(1779486527036000000, date_time.timestamp.nanoseconds);
}
test parse {
    const date_str = "2026-05-22T21:48:47.036Z";
    var date_time: DateTimeFormat = try .parse(date_str, &.{ .year, .month, .day, .hour, .minute, .second, .subsecond, .utc_offset });
    try testing.expectEqual(1779486527036000000, date_time.timestamp.nanoseconds);

    // what if we only want the date?
    date_time = try .parse(date_str, &.{ .year, .month, .day });
    try testing.expectEqual(1779408000000000000, date_time.timestamp.nanoseconds);

    var stream: Io.Writer.Allocating = .init(testing.allocator);
    defer stream.deinit();

    date_time.formatting = .fromFormatString("MM/dd/yyyy");
    try stream.writer.print("{f}", .{date_time});
    try testing.expectEqualStrings("05/22/2026", stream.written());

    stream.clearRetainingCapacity();

    // what if we only want time?
    date_time = try .parse("21:48:47.036", &.{ .hour, .minute, .second, .subsecond });
    try testing.expectEqual(78527036000000, date_time.timestamp.nanoseconds);

    date_time.formatting = .fromFormatString("hh:mm:ss.fff");
    try stream.writer.print("{f}", .{date_time});
    try testing.expectEqualStrings("21:48:47.036", stream.written());
}
test parseMonth {
    try testing.expectEqual(Month.nov, try parseMonth("11"));
    try testing.expectEqual(Month.nov, try parseMonth("nov"));
    try testing.expectEqual(Month.nov, try parseMonth("Nov"));
    try testing.expectEqual(Month.nov, try parseMonth("November"));
    try testing.expectError(error.InvalidMonth, parseMonth("Nove"));
}

comptime {
    _ = WeekDay;
}

const std = @import("std");
const testing = std.testing;
const time = std.time;
const mem = std.mem;
const ascii = std.ascii;
const comptimePrint = std.fmt.comptimePrint;
const parseUnsigned = std.fmt.parseUnsigned;
const assert = std.debug.assert;
const panic = std.debug.panic;
const Io = std.Io;
const EpochSeconds = time.epoch.EpochSeconds;
const EpochDay = time.epoch.EpochDay;
const YearAndDay = time.epoch.YearAndDay;
const MonthAndDay = time.epoch.MonthAndDay;
const Month = time.epoch.Month;
const EnumMap = std.EnumMap;
const EnumSet = std.EnumSet;
