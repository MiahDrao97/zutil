//! Use this for writing various date formats
pub const DateFormat = @This();

/// Timestamp itself
timestamp: Io.Timestamp,
/// Ordering of the fields and separator characters
order: EnumMap(DateTimeElement, FullFormat),

const DateTimeElement = enum {
    year,
    month,
    day,
    hour,
    minute,
    second,
    subsecond,

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
                    3 => .abbrevation,
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
    /// Hour display strategy
    hour: enum { natural, zero_filled },
    /// Minute display strategy
    minute: enum { natural, zero_filled },
    /// Second display strategy
    second: enum { natural, zero_filled },
    /// Number of places to show
    subsecond: u3,
};

const FullFormat = struct {
    fmt: DateTimeElementFormat,
    fill: []const u8,
};

/// Format like `yyyy-MM-ddThh:mm:ss.fffZ`
pub fn iso(timestamp: Io.Timestamp) DateFormat {
    return .fmt("yyyy-MM-ddThh:mm:ss.fffZ", timestamp);
}

pub fn fmt(comptime format_str: []const u8, timestamp: Io.Timestamp) DateFormat {
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
                'h' => .hour,
                'm' => .minute,
                's' => .second,
                'f' => .subsecond,
                'T', 'Z', '-', ':', ' ', '.' => null, // separator characters or 'Z' for UTC timezone indication
                // TODO : Timezone crap (should be runtime)
                else => @compileError("Unexpected character '" ++ @as([]const u8, &.{char}) ++ "' in date-time format."),
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
            if (next == null and i + 1 == format_str.len) {
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
    return .{ .timestamp = timestamp, .order = order };
}

pub fn format(self: DateFormat, writer: *Io.Writer) Io.Writer.Error!void {
    const ms_now: i64 = self.timestamp.toMilliseconds();
    const sec_now: i64 = @divFloor(ms_now, 1000);
    const minutes_now: i64 = @divFloor(sec_now, 60);
    const hours_now: i64 = @divFloor(minutes_now, 60);

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
        .subsecond => |s| switch (s) {
            0 => {}, // ignore
            inline 1...7 => |places| {
                // write all nanoseconds to a buffer and strategically truncate
                var buf: [32]u8 = undefined;
                var full_ns_writer: Io.Writer = .fixed(&buf);
                full_ns_writer.print("{d}", .{self.timestamp.nanoseconds}) catch unreachable;

                // get the last 9 characters
                const full_ns: []const u8 = full_ns_writer.buffered();
                const subseconds: []const u8 = full_ns[full_ns.len - 9 ..];

                try writer.print("{s}{s}", .{ subseconds[0..places], x.value.fill });
            },
        }
    };
}

test "number 1" {
    const nanoseconds: i96 = 1779486527036758700; // Friday, May 22, 2026 at 9:48:47.036 PM (UTC)

    var stream: Io.Writer.Allocating = .init(testing.allocator);
    defer stream.deinit();
    try stream.writer.print("{f}", .{DateFormat.iso(.fromNanoseconds(nanoseconds))});

    try testing.expectEqualStrings("2026-05-22T21:48:47.036Z", stream.written());
}

const std = @import("std");
const debug = std.debug;
const testing = std.testing;
const comptimePrint = std.fmt.comptimePrint;
const Io = std.Io;
const EpochSeconds = std.time.epoch.EpochSeconds;
const EpochDay = std.time.epoch.EpochDay;
const YearAndDay = std.time.epoch.YearAndDay;
const MonthAndDay = std.time.epoch.MonthAndDay;
const EnumMap = std.EnumMap;
