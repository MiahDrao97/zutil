//! Use this for writing various date formats
pub fn DateFormat(comptime format_str: []const u8) type {
    // TODO : validate
    _ = format_str;

    return struct {
        timestamp: Io.Timestamp,

        const Self = @This();

        pub fn fmt(timestamp: Io.Timestamp) Self {
            return .{ .timestamp = timestamp };
        }

        pub fn format(self: Self, writer: *Io.Writer) Io.Writer.Error!void {
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
        }
    };
}

const std = @import("std");
const Io = std.Io;
const EpochSeconds = std.time.epoch.EpochSeconds;
const EpochDay = std.time.epoch.EpochDay;
const YearAndDay = std.time.epoch.YearAndDay;
const MonthAndDay = std.time.epoch.MonthAndDay;
