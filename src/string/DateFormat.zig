//! Use this for writing various date formats
pub const DateFormat = @This();

timestamp: Io.Timestamp,
order: std.EnumArray(DateTimeElement, []const u8),

const DateTimeElement = enum {
    year,
    month,
    day,
    hour,
    minute,
    second,
    subsecond,
};

/// Format like `yyyy-MM-dd hh:MM:ss.fffZ`
pub fn iso(timestamp: Io.Timestamp) DateFormat {
    return .fmt("yyyy-MM-dd hh:MM:ss.fffZ", timestamp);
}

pub fn fmt(comptime format_str: []const u8, timestamp: Io.Timestamp) DateFormat {
    // TODO : validate

    comptime var year_places: u3 = 0; // max is 5
    comptime var month_fmt: enum { digit, full, abbr } = .digit;
    comptime var day_fmt: enum { natural, zero_filled, abbr, full_name } = .natural;
    comptime var subsecond_places: u3 = 0; // max is 7

    _ = &year_places;
    _ = &month_fmt;
    _ = &day_fmt;
    _ = &subsecond_places;

    var i: usize = 0;
    var current_element: DateTimeElement = undefined;
    var current_fmt_indicator: u8 = 0;
    var current_fmt_indicator_count: u8 = 0;

    for (format_str) |char| {
        if (char != current_fmt_indicator) {
            current_fmt_indicator = char;
            current_fmt_indicator_count = 0;
            i += 1;
        } else {
            current_fmt_indicator_count += 1;
        }
        switch (char) {
            'y' => current_element = .year,
            'M' => current_element = .month,
            'd' => current_element = .day,
            'h' => current_element = .hour,
            'm' => current_element = .minute,
            's' => current_element = .second,
            'f' => current_element = .subsecond,
            'Z' => {}, // UTC time indicator for ISO format
            '-', ':', ' ', '.' => {}, // separator characters
            else => @compileError("Unexpected character '" ++ @as([]const u8, &.{char}) ++ "' in date-time format."),
        }
    }
    return .{ .timestamp = timestamp };
}

pub fn format(self: DateFormat, writer: *Io.Writer) Io.Writer.Error!void {
    const ms_now: i64 = self.timestamp.toMilliseconds();
    const sec_now: i64 = @divFloor(ms_now, 1000);
    const minutes_now: i64 = @divFloor(sec_now, 60);
    const hours_now: i64 = @divFloor(minutes_now, 60);

    const ms: i64 = @mod(ms_now, 1000);
    const sec: i64 = @mod(sec_now, 60);
    const min: i64 = @mod(minutes_now, 60);
    const hour: i64 = @mod(hours_now, 24);

    _ = ms;
    _ = sec;
    _ = min;
    _ = hour;

    const epoch_seconds: EpochSeconds = .{ .secs = @bitCast(sec_now) };
    const epoch_day: EpochDay = epoch_seconds.getEpochDay();
    const year_day: YearAndDay = epoch_day.calculateYearDay();
    const month_day: MonthAndDay = year_day.calculateMonthDay();
    _ = month_day;

    _ = writer;

    var is_first: bool = true;
    var iter = self.order.iterator();
    while (iter.next()) |x| : (is_first = false) switch (x.key.*) {
        else => {}, // TODO
    };
}

test "number 1" {
    if (true) {
        return error.SkipZigTest;
    }
    std.debug.print("{f}", .{DateFormat.iso(.now(std.testing.io, .real))});
}

const std = @import("std");
const comptimePrint = std.fmt.comptimePrint;
const Io = std.Io;
const EpochSeconds = std.time.epoch.EpochSeconds;
const EpochDay = std.time.epoch.EpochDay;
const YearAndDay = std.time.epoch.YearAndDay;
const MonthAndDay = std.time.epoch.MonthAndDay;
