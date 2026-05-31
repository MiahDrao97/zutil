//! Use this for writing various date/time formats
pub const DateTimeFormat = @This();

/// Timestamp itself
timestamp: Io.Timestamp,
/// Ordering of the fields and separator characters
order: EnumMap(DateTimeElement, FullFormat),
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
};

/// Various possible parse errors that could be returned from `parse(...)`
pub const ParseError = error{
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
    MissingDay,
    MissingHour,
    MissingSecond,
    MissingSubsecond,
    MissingUtcOffset,
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
    pub fn abbreviate(self: WeekDay, buf: *[3]u8) []const u8 {
        return if (std.fmt.bufPrint(buf, "{t}", .{self})) |_| unreachable else |_| buf;
    }

    test fromTimestamp {
        const nanoseconds: i96 = 1779486527036758700; // Friday, May 22, 2026 at 9:48:47.0367587 PM (UTC)
        const day_of_week: WeekDay = .fromTimestamp(.fromNanoseconds(nanoseconds));
        try testing.expectEqual(WeekDay.Friday, day_of_week);
    }
    test abbreviate {
        var buf: [3]u8 = undefined;

        var day_of_week: WeekDay = .Sunday;
        try testing.expectEqualStrings("Sun", day_of_week.abbreviate(&buf));

        day_of_week = .Monday;
        try testing.expectEqualStrings("Mon", day_of_week.abbreviate(&buf));

        day_of_week = .Tuesday;
        try testing.expectEqualStrings("Tue", day_of_week.abbreviate(&buf));

        day_of_week = .Wednesday;
        try testing.expectEqualStrings("Wed", day_of_week.abbreviate(&buf));

        day_of_week = .Thursday;
        try testing.expectEqualStrings("Thu", day_of_week.abbreviate(&buf));

        day_of_week = .Friday;
        try testing.expectEqualStrings("Fri", day_of_week.abbreviate(&buf));

        day_of_week = .Saturday;
        try testing.expectEqualStrings("Sat", day_of_week.abbreviate(&buf));
    }
};

/// Element of a date-time
pub const DateTimeElement = enum {
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

    fn toFormat(self: DateTimeElement, elem_len: comptime_int) DateTimeElementFormat {
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

const DateTimeElementFormat = union(DateTimeElement) {
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

const FullFormat = struct {
    fmt: DateTimeElementFormat,
    fill: []const u8,
};

/// Expected/allowed separator characters between the various elements.
/// 'Z' is not exactly a "separator", but it can usually be found to indicate that the date-time is UTC.
const separator_characters: []const u8 = &.{ ' ', '/', '-', '+', '_', '.', ',', ':', 'T', 'Z' };

const log = if (@import("builtin").is_test) struct {
    fn err(comptime fmt_str: []const u8, args: anytype) void {
        if (testing.log_level == .debug) {
            debug.print(fmt_str ++ @as([]const u8, &.{'\n'}), args);
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
    comptime var order: EnumMap(DateTimeElement, FullFormat) = .init(.{});
    comptime {
        var current_element: ?DateTimeElement = null;
        var elem_len: usize = 0;
        var fill_start: ?usize = null;
        var current_fmt: FullFormat = undefined;

        for (format_str, 0..) |char, i| {
            const next: ?DateTimeElement = switch (char) {
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
                    if (order.fetchPut(current, current_fmt)) |_| {
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
                    if (order.fetchPut(current, current_fmt)) |_| {
                        @compileError(comptimePrint("Found redundant formatting for {t}: '{s}'", .{ current, format_str }));
                    }
                }
            }
        }
    }
    return .{
        .timestamp = timestamp,
        .order = order,
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

    var order_cpy: EnumMap(DateTimeElement, FullFormat) = self.order;
    var iter: EnumMap(DateTimeElement, FullFormat).Iterator = order_cpy.iterator();
    while (iter.next()) |x| switch (x.value.fmt) {
        .year => |y| switch (y) {
            0 => {}, // ignore
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
                buf[0] = std.ascii.toUpper(buf[0]);
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
                var buf: [3]u8 = undefined;
                try writer.print("{s}{s}", .{ weekday.abbreviate(&buf), x.value.fill });
            },
            .full_name => {
                const weekday: WeekDay = .fromTimestamp(self.timestamp);
                try writer.print("{t}{s}", .{ weekday, x.value.fill });
            },
        },
        .hour => |h| switch (h) {
            // day index starts at 0
            .natural => try writer.print("{d}{s}", .{ @abs(hour), x.value.fill }),
            .zero_filled => try writer.print("{d:0>2}{s}", .{ @abs(hour), x.value.fill }),
        },
        .minute => |m| switch (m) {
            // day index starts at 0
            .natural => try writer.print("{d}{s}", .{ @abs(min), x.value.fill }),
            .zero_filled => try writer.print("{d:0>2}{s}", .{ @abs(min), x.value.fill }),
        },
        .second => |s| switch (s) {
            // day index starts at 0
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

pub fn parse(str: []const u8, expected_elements: []const DateTimeElement) ParseError!Io.Timestamp {
    debug.assert(expected_elements.len > 0);

    var map: EnumMap(DateTimeElement, []const u8) = .init(.{});

    // The downside of tokenizing like this is the potential of NO separator characters between elements...
    // Although, whoever formats dates like that is insane.
    var tokenizer: mem.TokenIterator(u8, .any) = mem.tokenizeAny(u8, str, separator_characters);
    var element_idx: usize = 0;
    while (tokenizer.next()) |segment| : (element_idx += 1) {
        if (segment.len > 0) {
            if (element_idx >= expected_elements.len) break;
            if (map.fetchPut(expected_elements[element_idx], segment)) |_| {
                debug.panic("Date-time element {t} was present more than once in the slice of expected elements.", .{expected_elements[element_idx]});
            }
            debug.print("Segment {d}: '{s}'\n", .{ element_idx, segment });
        }
        // ignore empty strings
    }
    return try parseInner(&map);
}

/// Like `parse(...)`, but will return an error when there are more parsable segments after assigning segmenets to each of the expected elements.
pub fn parseExact(str: []const u8, expected_elements: []const DateTimeElement) (ParseError || error{UnrecognizedSegment})!Io.Timestamp {
    debug.assert(expected_elements.len > 0);

    var map: EnumMap(DateTimeElement, []const u8) = .init(.{});

    var tokenizer: mem.TokenIterator(u8, .any) = mem.tokenizeAny(u8, str, separator_characters);
    var element_idx: usize = 0;
    while (tokenizer.next()) |segment| : (element_idx += 1) {
        if (segment.len > 0) {
            if (element_idx >= expected_elements.len) {
                log.err("Unrecognized segment '{s}' in date-time string '{s}'. This occurs when there are more parsable segments than expected. Assigned segments are:", .{ segment, str });
                var iter: EnumMap(DateTimeElement, []const u8).Iterator = map.iterator();
                while (iter.next()) |kvp| log.err("  {t}: '{s}'", .{ kvp.key, kvp.value.* });
                return error.UnrecognizedSegment;
            }
            if (map.fetchPut(expected_elements[element_idx], segment)) |_| {
                debug.panic("Date-time element {t} was present more than once in the slice of expected elements.", .{expected_elements[element_idx]});
            }
            debug.print("Segment {d}: '{s}'\n", .{ element_idx, segment });
        }
        // ignore empty strings
    }
    return try parseInner(&map);
}

fn parseInner(map: *EnumMap(DateTimeElement, []const u8)) ParseError!Io.Timestamp {
    var nanoseconds: i96 = 0;
    var iter: EnumMap(DateTimeElement, []const u8).Iterator = map.iterator();
    while (iter.next()) |kvp| switch (kvp.key) {
        .year => {
            const year: u16 = parseUnsigned(u16, kvp.value.*, 10) catch return error.InvalidYear;
            nanoseconds += (@as(i96, @intCast(time.epoch.getDaysInYear(year))) * time.ns_per_day);
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
            nanoseconds += (@as(i96, @intCast(day)) * time.ns_per_day);
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
        .utc_offset => {
            // TODO :
        }
    };

    return .fromNanoseconds(nanoseconds);
}

fn parseMonth(slice: []const u8) error{InvalidMonth}!Month {
    // TODO : Parse as string
    const month: u4 = parseUnsigned(u4, slice, 10) catch return error.InvalidMonth;
    return std.enums.fromInt(Month, month) orelse return error.InvalidMonth;
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
test parse {
    testing.log_level = .debug;
    defer testing.log_level = .warn;

    const date_str = "2026-05-22T21:48:47.036Z";
    const timestamp: Io.Timestamp = try DateTimeFormat.parse(date_str, &.{ .year, .month, .day, .hour, .minute, .second, .subsecond });
    errdefer debug.print("Expected: {d}, Actual: {d}, Diff: {d}\n", .{ 1779486527036000000, timestamp.nanoseconds, @abs(1779486527036000000 - timestamp.nanoseconds) });

    try testing.expectEqual(1779486527036000000, timestamp.nanoseconds);
}

comptime {
    _ = WeekDay;
}

const std = @import("std");
const debug = std.debug;
const testing = std.testing;
const time = std.time;
const mem = std.mem;
const comptimePrint = std.fmt.comptimePrint;
const parseUnsigned = std.fmt.parseUnsigned;
const Io = std.Io;
const EpochSeconds = time.epoch.EpochSeconds;
const EpochDay = time.epoch.EpochDay;
const YearAndDay = time.epoch.YearAndDay;
const MonthAndDay = time.epoch.MonthAndDay;
const Month = time.epoch.Month;
const EnumMap = std.EnumMap;
