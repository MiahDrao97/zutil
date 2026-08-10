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
    /// Offset is positive or negative
    sign: enum(u1) { positive, negative },
    /// Offset hours
    hours: u5,
    /// Possible quarter hours (0, 1, 2, or 3 for xx:00, xx:15, xx:30, and xx:45 respectively)
    quarter_hours: u2,

    /// Zero-offset (aka UTC time)
    pub const utc: UtcOffset = .{ .sign = .positive, .hours = 0, .quarter_hours = 0 };

    /// Uses a signed 6-bit integer to determine hours offset and if it's positive/negative.
    /// Omits quarter hours.
    pub fn fromHours(hours: i6) UtcOffset {
        return .{
            .sign = if (hours < 0) .negative else .positive,
            .hours = @abs(@as(i5, @truncate(hours))),
            .quarter_hours = 0,
        };
    }

    pub fn asDuration(self: UtcOffset) Io.Duration {
        var ns: i96 = 0;
        ns += self.hours * time.ns_per_hour;
        ns += self.quarter_hours * 15 * time.ns_per_min;
        if (self.sign == .negative) {
            ns *= -1;
        }
        return .fromNanoseconds(ns);
    }

    pub fn isZero(self: UtcOffset) bool {
        return switch (self) {
            .utc, .{ .sign = .negative, .hours = 0, .quarter_hours = 0 } => true,
            else => false,
        };
    }

    fn parse(tokenizer: *Tokenizer) error{InvalidUtcOffset}!UtcOffset {
        var offset: UtcOffset = .utc;
        var next: Tokenizer.Token = tokenizer.expectOneOf(&.{
            .{ .exactly = "Z" },
            .{ .exactly = "-" },
            .{ .exactly = "+" },
            .{ .category = .numeric },
        }) catch |err| {
            switch (err) {
                error.NoMatch => log.err("Expected 'Z', '-', '+', or numeric token. Instead found: '{f}'", .{tokenizer.peek().?}),
                error.EndOfIteration => log.err("No more tokens. UTC offset is incomplete.", .{}),
                error.UnexpectedCharacter => {},
            }
            return error.InvalidUtcOffset;
        };

        var substring: []const u8 = "";
        switch (next.category) {
            .alpha => return offset,
            .numeric => {
                if (next.value.len == 4) {
                    // 4 characters: assuming first 2 are hours and second 2 are quarter hours
                    offset.hours = std.fmt.parseInt(u5, next.value[0..2], 10) catch |err| {
                        log.err("Could not parse u5 for hours offset from string '{s}': {t}", .{ next.value[0..2], err });
                        return error.InvalidUtcOffset;
                    };
                    const minutes: []const u8 = next.value[2..];
                    assert(minutes.len == 2);
                    if (parseMinutes(minutes)) |m| {
                        offset.quarter_hours = m;
                    } else {
                        log.err("Could not parse quarter hours from string '{s}'", .{minutes});
                        return error.InvalidUtcOffset;
                    }
                } else {
                    offset.hours = std.fmt.parseInt(u5, next.value, 10) catch |err| {
                        log.err("Could not parse u5 for hours offset from string '{s}': {t}", .{ next.value[0..2], err });
                        return error.InvalidUtcOffset;
                    };
                }
            },
            .separator => substring = next.value,
        }

        if (substring.len > 0) {
            next = tokenizer.expectOneOf(&.{.{ .category = .numeric }}) catch |err| {
                switch (err) {
                    error.NoMatch => log.err("Expected numeric token but instead found: '{f}'", .{tokenizer.peek().?}),
                    error.EndOfIteration => log.err("No more tokens. UTC offset is incomplete.", .{}),
                    error.UnexpectedCharacter => {},
                }
                return error.InvalidUtcOffset;
            };
            substring.len += next.value.len;
            switch (substring[0]) {
                '-' => offset.sign = .negative,
                '+' => {}, // already positive in .utc
                else => unreachable,
            }
            substring = substring[1..];
            if (substring.len == 4) {
                // 4 characters: assuming first 2 are hours and second 2 are quarter hours
                offset.hours = std.fmt.parseInt(u5, substring[0..2], 10) catch |err| {
                    log.err("Could not parse u5 for hours offset from string '{s}': {t}", .{ substring[0..2], err });
                    return error.InvalidUtcOffset;
                };
                const minutes: []const u8 = substring[2..];
                assert(minutes.len == 2);
                if (parseMinutes(minutes)) |m| {
                    offset.quarter_hours = m;
                } else {
                    log.err("Could not parse quarter hours from string '{s}'", .{minutes});
                    return error.InvalidUtcOffset;
                }
            } else {
                // we're assuming that quarter hours are not a thing here
                offset.hours = std.fmt.parseInt(u5, substring, 10) catch |err| {
                    log.err("Could not parse u5 for hours offset from string '{s}': {t}", .{ substring[0..2], err });
                    return error.InvalidUtcOffset;
                };
            }
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

        // check for "negative" 0:
        if (offset.hours + offset.quarter_hours == 0 and offset.sign == .negative) {
            offset.sign = .positive; // just to ensure that we're consistent here
        }
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

    test "UtcOffset.parse" {
        var tokenizer: Tokenizer = undefined;
        {
            tokenizer = .init("");
            // empty string
            try testing.expectError(error.InvalidUtcOffset, UtcOffset.parse(&tokenizer));

            // invalid string
            tokenizer = .init("asdf");
            try testing.expectError(error.InvalidUtcOffset, UtcOffset.parse(&tokenizer));

            // invalid quarter hours
            tokenizer = .init("+0110");
            try testing.expectError(error.InvalidUtcOffset, UtcOffset.parse(&tokenizer));
        }
        // zero-formats
        {
            const zero_formats: []const []const u8 = &.{ "0000", "+0000", "-0000", "+00:00", "-00:00", "Z", "0" };
            for (zero_formats) |zf| {
                tokenizer = .init(zf);
                try testing.expectEqual(UtcOffset.utc, try UtcOffset.parse(&tokenizer));
            }
        }
        // nonzero formats
        {
            const formats: []const struct { fmt: []const u8, expected: UtcOffset } = &.{
                .{ .fmt = "00:15", .expected = .{ .sign = .positive, .hours = 0, .quarter_hours = 1 } },
                .{ .fmt = "0015", .expected = .{ .sign = .positive, .hours = 0, .quarter_hours = 1 } },
                .{ .fmt = "-0015", .expected = .{ .sign = .negative, .hours = 0, .quarter_hours = 1 } },
                .{ .fmt = "-00:15", .expected = .{ .sign = .negative, .hours = 0, .quarter_hours = 1 } },
                .{ .fmt = "-07:30", .expected = .{ .sign = .negative, .hours = 7, .quarter_hours = 2 } },
                .{ .fmt = "+07:45", .expected = .{ .sign = .positive, .hours = 7, .quarter_hours = 3 } },
            };
            for (formats) |f| {
                tokenizer = .init(f.fmt);
                try testing.expectEqual(f.expected, try UtcOffset.parse(&tokenizer));
            }
        }
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
    InvalidAmPm,
    MissingYear,
    MissingMonth,
};

/// Various parse errors that could be returned from `parseExact(...)`
pub const ParseExactError = ParseError || error{
    UnrecognizedSegment,
    MismatchedSeparator,
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
    /// Subseconds, represented in up to 9 places
    subsecond,
    /// UTC offset
    utc_offset,
    /// Ante meridiem or post merdiem
    /// The presence of this element puts the time in a twelve-hour clock
    am_pm,

    fn toFormat(self: Element, char: u8, elem_len: comptime_int) ElementFormat {
        // cap Z is shorthand for ISO-formatted UTC offset
        if (char == 'Z' and elem_len == 1) {
            return .{ .utc_offset = .iso };
        }
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
            .subsecond => if (elem_len <= 9) .{ .subsecond = elem_len } else @compileError(
                comptimePrint("Up to 9 places are allowed for subseconds. Found '{s}'.", .{&@as([elem_len]u8, @splat('f'))}),
            ),
            .utc_offset => .{
                .utc_offset = switch (elem_len) {
                    0 => .iso,
                    1 => .hours_only,
                    2 => .hours_only_zero_filled,
                    3 => .hours_and_minutes,
                    4 => .iso,
                    else => @compileError(comptimePrint("Invalid utc offset format '{s}'", .{&@as([elem_len]u8, @splat('z'))})),
                },
            },
            .am_pm => .{
                .am_pm = .{
                    .upper = switch (char) {
                        'n' => false,
                        'N' => true,
                        else => unreachable,
                    },
                    .both_letters = switch (elem_len) {
                        1 => false,
                        2 => true,
                        else => @compileError(comptimePrint("Invalid AM/PM format '{s}'", .{&@as([elem_len]u8, @splat(char))})),
                    },
                },
            },
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
    subsecond: u4,
    /// UTC offset format, whether or not to include
    utc_offset: enum { hours_only, hours_only_zero_filled, hours_and_minutes, iso },
    /// Represent AM or PM in 4 different combinations
    am_pm: packed struct(u2) { upper: bool, both_letters: bool },
};

pub const FullFormat = struct {
    /// The fill preceding the element
    fill: []const u8,
    /// The element and its format
    fmt: ElementFormat,

    pub fn format(self: FullFormat, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.print("fill: '{s}' ", .{self.fill});
        switch (self.fmt) {
            .year => |y| try writer.print("year places: {d}", .{y}),
            .subsecond => |s| try writer.print("subsecond places: {d}", .{s}),
            .am_pm => try writer.print("AM/PM", .{}),
            inline else => |x| try writer.print("{t}: {t}", .{ self.fmt, x }),
        }
    }
};

/// This defines how a date-time string is formatted:
/// Which elements are represented, which separator character(s) sit between elements, and which order elements appear.
pub const Formatting = struct {
    /// Which elements are present and separator character(s) come after them
    map: EnumMap(Element, FullFormat),
    /// Since `EnumMap` does not give you the order elements appear, we need this additional array
    ordering: [@typeInfo(Element).@"enum".fields.len]?Element,

    pub const init: Formatting = .{
        .map = .init(.{}),
        .ordering = @splat(null),
    };

    /// Format guide:
    /// Year (y or Y)
    /// y - Get the current year without leading zero
    /// yy - Display the last 2 digits of the year
    /// yyy - Display the last 3 digits of the year
    /// yyyy - Display the last 4 digits of the year
    /// yyyyy - Include 5 digits for the year (adds leading zero)
    ///
    /// Month (M)
    /// M - Represent the month without leading zero
    /// MM - Adds leading zero
    /// MMM - Abreviated name of the month (e.g. "Jan", "Feb", etc.)
    /// MMMM - Full name of the month (e.g. "January", "February", etc.)
    ///
    /// Day (d)
    /// d - Represent the day of the month without leading zero
    /// dd - Adds leading zero
    ///
    /// Weekday (D)
    /// D - abbreviated weekday (e.g. "Mon", "Tue", etc)
    /// DD - full week day name (e.g. "Monday", "Tuesday", etc)
    ///
    /// Hour (h or H)
    /// h - Represent hours without leading zero
    /// hh - Adds leading zero
    ///
    /// Minute (m)
    /// m - Represent minutes without leading zero
    /// mm - Adds leading zero
    ///
    /// Second (s)
    /// s - Represent seconds without leading zero
    /// ss - Adds leading zero
    ///
    /// Sub-second (f)
    /// Represent up to 9 places (note that these numbers are truncated, not rounded):
    /// fff => for milliseconds
    /// ffffff => for microseconds
    /// fffffffff => for nanoseconds
    ///
    /// UTC Offset (z)
    /// z - Represent +/- hours from UTC
    /// zz - Adds leading zero to +/- hours from UTC
    /// zzz - Includes quarter hours (not colon-separated) (e.g. -0715 for -7 hours and 15 minutes from UTC time)
    /// zzzz - ISO 8601 format, which includes quarter hours that are colon-separated (.e.g "-07:15" for -7 hours and 15 minutes from UTC time)
    /// Z - ISO 8601 format (shorthand for zzzz)
    ///
    /// AM/PM (n or N, for "noon")
    /// n - first letter, lower case
    /// N - first letter, upper case
    /// nn - both letters, lower case
    /// NN - both letters, upper case
    ///
    /// The accepted separator characters are: ' ', '/', '-', '+', '_', '.', ',', ':', 'T'
    /// If there are any trailing separator characters, those will be trimmed.
    /// If a UTC offset is directly preceeded by a '+' or a '-', it will include a '+' in positive offsets, replacing the fill with the correct sign.
    /// If a UTC offset is not directly preceed by a '+' or a '-', positive offsets will simply start with a space.
    pub inline fn fmtStr(comptime format_str: []const u8) Formatting {
        @setEvalBranchQuota(1200);
        comptime {
            const ElementOrFill = union(enum) {
                element: Element,
                fill: []const u8,

                const empty: @This() = .{ .fill = "" };
            };

            var formatting: Formatting = .init;
            var current_fmt: FullFormat = undefined;
            var elem_len: usize = 0;
            var current: ElementOrFill = .empty;
            for (format_str, 0..) |char, i| {
                const next: ElementOrFill = switch (char) {
                    'Y', 'y' => .{ .element = .year },
                    'M' => .{ .element = .month },
                    'd' => .{ .element = .day },
                    'D' => .{ .element = .weekday },
                    'H', 'h' => .{ .element = .hour },
                    'm' => .{ .element = .minute },
                    's' => .{ .element = .second },
                    'f' => .{ .element = .subsecond },
                    'N', 'n' => .{ .element = .am_pm },
                    'Z', 'z' => .{ .element = .utc_offset },
                    else => if (mem.findScalar(u8, separator_characters, char)) |_|
                        .{ .fill = format_str[i..][0..1] }
                    else
                        @compileError("Unexpected character '" ++ @as([]const u8, &.{char}) ++ "' in date-time format."),
                };
                switch (next) {
                    .fill => |new_fill| switch (current) {
                        .fill => |*f| f.len += 1,
                        .element => |e| {
                            // We're on an element, and we just encountered fill; finish off this element and save it.
                            current_fmt.fmt = e.toFormat(format_str[i -| 1], elem_len);
                            if (formatting.fetchPut(e, current_fmt)) |_| {
                                @compileError(comptimePrint("Found redundant formatting for {t}: '{s}'", .{ e, format_str }));
                            }
                            // start fresh
                            current_fmt.fill = "";
                            current = .{ .fill = new_fill };
                        },
                    },
                    .element => |new_element| {
                        switch (current) {
                            .fill => |f| {
                                // We're on fill, and we just encountered the beginning of an element;
                                current_fmt.fill = f;
                                elem_len = 1;
                                current = .{ .element = new_element };
                            },
                            .element => |e| {
                                if (e == new_element) {
                                    elem_len += 1;
                                } else {
                                    // No fill; this is simply a new element.
                                    current_fmt.fmt = e.toFormat(format_str[i -| 1], elem_len);
                                    if (formatting.fetchPut(e, current_fmt)) |_| {
                                        @compileError(comptimePrint("Found redundant formatting for {t}: '{s}'", .{ e, format_str }));
                                    }
                                    // start fresh
                                    current_fmt.fill = "";
                                    elem_len = 1;
                                    current = .{ .element = new_element };
                                }
                            }
                        }

                        // if we're at the end, we need to check if we currently have an element and put it into our formatting
                        if (i == format_str.len - 1) {
                            switch (current) {
                                .element => |e| {
                                    current_fmt.fmt = e.toFormat(format_str[i], elem_len);
                                    if (formatting.fetchPut(e, current_fmt)) |_| {
                                        @compileError(comptimePrint("Found redundant formatting for {t}: '{s}'", .{ e, format_str }));
                                    }
                                },
                                .fill => {
                                    // WARN : This has the side effect of trimming fill at the end of the format.
                                    // This has implications for `parseExact(...)`, so this should be documented.
                                },
                            }
                        }
                    },
                }
            }
            assert(formatting.map.count() > 0);
            return formatting;
        }
    }

    /// Format like `yyyy-MM-ddThh:mm:ss.fffZ`
    pub const iso: Formatting = .fmtStr(iso_format_str);

    pub fn fetchPut(self: *Formatting, key: Element, value: FullFormat) ?FullFormat {
        if (self.map.fetchPut(key, value)) |old_value| {
            return old_value;
        }
        const next_idx: usize = mem.indexOfScalar(?Element, &self.ordering, null).?;
        self.ordering[next_idx] = key;
        return null;
    }

    pub fn count(self: Formatting) usize {
        return self.map.count();
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

        pub fn format(self: Token, writer: *Io.Writer) Io.Writer.Error!void {
            try writer.writeAll(self.value);
        }
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

    fn peek(self: *Tokenizer) ?Token {
        if (self.next() catch return null) |tok| {
            defer self.rollback(tok);
            return tok;
        }
        return null;
    }

    /// Expect a token in a category or a specific string.
    /// If not matched, then the tokenizer will roll back.
    fn expectOneOf(
        self: *Tokenizer,
        possible: []const union(enum) { category: Category, exactly: []const u8 },
    ) error{ NoMatch, UnexpectedCharacter, EndOfIteration }!Token {
        if (try self.next()) |tok| {
            errdefer self.rollback(tok);
            for (possible) |p| switch (p) {
                .category => |c| if (c == tok.category) return tok,
                .exactly => |e| if (mem.eql(u8, e, mem.trim(u8, tok.value, &ascii.whitespace))) return tok,
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

pub const iso_format_str: []const u8 = "yyyy-MM-ddThh:mm:ss.fffZ";

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
            std.debug.print(fmt_str ++ "\n", args);
        } else {
            var null_writer: Io.Writer.Discarding = .init(&.{});
            null_writer.writer.print(fmt_str, args) catch {};
        }
    }
} else std.log.scoped(.DateTimeFormat);

/// Assumes that the timestamp is already UTC.
/// Then we'll apply the offset to the existing `timestamp`.
pub fn fmt(formatting: Formatting, timestamp: Io.Timestamp, utc_offset: UtcOffset) DateTimeFormat {
    return .{
        .timestamp = timestamp,
        .formatting = formatting,
        .utc_offset = utc_offset,
    };
}

/// Format like `yyyy-MM-ddThh:mm:ss.fffZ`
pub fn iso(timestamp: Io.Timestamp) DateTimeFormat {
    return .fmt(.iso, timestamp, .utc);
}

pub fn format(self: DateTimeFormat, writer: *Io.Writer) Io.Writer.Error!void {
    assert(self.formatting.map.count() > 0); // flag this: this is a dev mistake

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

    var formatting: Formatting = self.formatting;
    if (formatting.count() == 0) {
        formatting = .fmtStr(iso_format_str);
    }
    var iter: Formatting.Iterator = formatting.iterator();
    while (iter.next()) |x| {
        var fill: []const u8 = x.value.fill;
        switch (x.value.fmt) {
            .year => |y| switch (y) {
                1 => try writer.print("{s}{d}", .{ fill, year_day.year }),
                2 => try writer.print("{s}{d:0>2}", .{ fill, year_day.year }),
                3 => try writer.print("{s}{d:0>3}", .{ fill, year_day.year }),
                4 => try writer.print("{s}{d:0>4}", .{ fill, year_day.year }),
                5 => try writer.print("{s}{d:0>5}", .{ fill, year_day.year }),
                else => unreachable,
            },
            .month => |m| switch (m) {
                .natural => try writer.print("{s}{d}", .{ fill, month_day.month }),
                .zero_filled => try writer.print("{s}{d:0>2}", .{ fill, month_day.month }),
                .abbreviation => {
                    var buf: [3]u8 = undefined;
                    var formatter: Io.Writer = .fixed(&buf);
                    formatter.print("{t}", .{month_day.month}) catch unreachable;
                    buf[0] = ascii.toUpper(buf[0]);
                    try writer.print("{s}{s}", .{ fill, formatter.buffered() });
                },
                .full_name => try writer.print("{s}{s}", .{ fill, switch (month_day.month) {
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
                } }),
            },
            .day => |d| switch (d) {
                // day index starts at 0
                .natural => try writer.print("{s}{d}", .{ fill, month_day.day_index + 1 }),
                .zero_filled => try writer.print("{s}{d:0>2}", .{ fill, month_day.day_index + 1 }),
            },
            .weekday => |w| switch (w) {
                .abbreviation => {
                    const weekday: WeekDay = .fromTimestamp(self.timestamp);
                    try writer.print("{s}{s}", .{ fill, weekday.abbreviate() });
                },
                .full_name => {
                    const weekday: WeekDay = .fromTimestamp(self.timestamp);
                    try writer.print("{s}{t}", .{ fill, weekday });
                },
            },
            .hour => |h| {
                assert(hour >= 0 and hour < 24);
                var hour_inner: u5 = @intCast(hour);
                if (self.formatting.map.contains(.am_pm)) {
                    switch (hour) {
                        0 => hour_inner = 12, // midnight is 12 am
                        13...23 => hour_inner -= 12, // past noon, we start over at 1
                        else => unreachable,
                    }
                    assert(hour_inner >= 1 and hour_inner <= 12);
                }
                switch (h) {
                    .natural => try writer.print("{s}{d}", .{ fill, hour_inner }),
                    .zero_filled => try writer.print("{s}{d:0>2}", .{ fill, hour_inner }),
                }
            },
            .minute => |m| switch (m) {
                .natural => try writer.print("{s}{d}", .{ fill, @abs(min) }),
                .zero_filled => try writer.print("{s}{d:0>2}", .{ fill, @abs(min) }),
            },
            .second => |s| switch (s) {
                .natural => try writer.print("{s}{d}", .{ fill, @abs(sec) }),
                .zero_filled => try writer.print("{s}{d:0>2}", .{ fill, @abs(sec) }),
            },
            .subsecond => |places| if (places > 0) {
                // write all nanoseconds to a buffer and strategically truncate
                var buf: [32]u8 = undefined;
                const full_ns: []const u8 = std.fmt.bufPrint(&buf, "{d}", .{self.timestamp.nanoseconds}) catch unreachable;
                // get the last 9 characters
                const subseconds: []const u8 = full_ns[full_ns.len - 9 ..];

                try writer.print("{s}{s}", .{ fill, subseconds[0..places] });
            },
            .utc_offset => |offset_fmt| {
                if (self.utc_offset.isZero() and offset_fmt == .iso) {
                    try writer.print("{s}Z", .{fill});
                } else {
                    const last_fill_char: u8 = fill[fill.len - 1];
                    const sign_char: u8, const is_plus_or_minus: bool = switch (self.utc_offset.sign) {
                        .positive => switch (last_fill_char) {
                            '-', '+' => .{ '+', true },
                            else => .{ ' ', false },
                        },
                        .negative => .{ '-', true },
                    };
                    if (last_fill_char == sign_char or (is_plus_or_minus and switch (last_fill_char) {
                        '+', '-' => true,
                        else => false,
                    })) {
                        fill = fill[0 .. fill.len - 1];
                    }
                    switch (offset_fmt) {
                        .hours_only => try writer.print("{s}{c}{d}", .{ fill, sign_char, self.utc_offset.hours }),
                        .hours_only_zero_filled => try writer.print("{s}{c}{d:0>2}", .{ fill, sign_char, self.utc_offset.hours }),
                        .hours_and_minutes => try writer.print("{s}{c}{d:0>2}{d:0>2}", .{ fill, sign_char, self.utc_offset.hours, @as(u16, self.utc_offset.quarter_hours) * 15 }),
                        .iso => try writer.print("{s}{c}{d:0>2}:{d:0>2}", .{ fill, sign_char, self.utc_offset.hours, @as(u16, self.utc_offset.quarter_hours) * 15 }),
                    }
                }
            },
            .am_pm => |meridiem| {
                var am_pm_str: [2]u8 = switch (hour) {
                    0...11 => "am".*,
                    12...23 => "pm".*,
                    else => unreachable,
                };
                if (meridiem.upper) {
                    am_pm_str[0] = ascii.toUpper(am_pm_str[0]);
                    am_pm_str[1] = ascii.toUpper(am_pm_str[1]);
                }
                try writer.print("{s}{s}", .{ fill, am_pm_str[0..if (meridiem.both_letters) 2 else 1] });
            },
        }
    }
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
pub fn parseExact(str: []const u8, formatting: Formatting) ParseExactError!DateTimeFormat {
    var map: EnumMap(Element, []const u8) = .init(.{});

    var utc_offset: UtcOffset = .utc;
    var expected_elements: Formatting.Iterator = formatting.iterator();
    var tokenizer: Tokenizer = .init(mem.trim(u8, str, &ascii.whitespace));
    var current_element: Formatting.Entry = expected_elements.next() orelse unreachable;
    while (try tokenizer.next()) |tok| {
        switch (tok.category) {
            .separator => {
                if (!mem.eql(u8, tok.value, current_element.value.fill)) {
                    log.err("Separator preceeding element {t} did not match. Expected: '{s}', Received: '{s}'", .{ current_element.key, current_element.value.fill, tok.value });
                    return error.MismatchedSeparator;
                }
                log.debug("Matched expected separator '{s}'. Getting next segment.", .{tok.value});
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
                    }
                    current_element = expected_elements.next() orelse break;
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
        .am_pm => {
            switch (kvp.value.len) {
                1 => {},
                2 => if (ascii.toLower(kvp.value.*[1]) != 'm') {
                    log.err("AM/PM has an invalid second character. Found '{s}'", .{kvp.value.*});
                    return error.InvalidAmPm;
                },
                else => {
                    log.err("AM/PM cannot exceed 2 characters. Found '{s}'", .{kvp.value.*});
                    return error.InvalidAmPm;
                },
            }
            var capital: bool = undefined;
            switch (kvp.value.*[0]) {
                'A', 'P' => {
                    if (kvp.value.len == 2 and kvp.value.*[1] != 'M') {
                        log.err("Both letters in AM/PM must be capitalized or lowercase. Found '{s}'", .{kvp.value.*});
                        return error.InvalidAmPm;
                    }
                    capital = true;
                },
                'a', 'p' => {
                    if (kvp.value.len == 2 and kvp.value.*[1] != 'm') {
                        log.err("Both letters in AM/PM must be capitalized or lowercase. Found '{s}'", .{kvp.value.*});
                        return error.InvalidAmPm;
                    }
                    capital = false;
                },
                else => {
                    log.err("AM/PM does not start with a lower/upper 'a' or 'm'. Found '{s}'", .{kvp.value.*});
                    return error.InvalidAmPm;
                }
            }
            // TODO : any bearing on the timestamp?
        },
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
    const datetime_fmt: DateTimeFormat = .iso(.fromNanoseconds(nanoseconds));
    try stream.writer.print("{f}", .{datetime_fmt});

    errdefer {
        var iter: Formatting.Iterator = datetime_fmt.formatting.iterator();
        while (iter.next()) |entry| {
            std.debug.print("  Formatting {f}\n", .{entry.value.*});
        }
    }

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
    const date_time: DateTimeFormat = try .parseExact(date_str, .iso);

    errdefer {
        var iter: Formatting.Iterator = date_time.formatting.iterator();
        while (iter.next()) |entry| {
            std.debug.print("  Formatting {f}\n", .{entry.value.*});
        }
    }

    try testing.expectEqual(1779486527036000000, date_time.timestamp.nanoseconds);
    try testing.expect(date_time.formatting.map.contains(.utc_offset));
}
test parse {
    const date_str = "2026-05-22T21:48:47.036Z";
    var date_time: DateTimeFormat = try .parse(date_str, &.{ .year, .month, .day, .hour, .minute, .second, .subsecond, .utc_offset });
    try testing.expectEqual(1779486527036000000, date_time.timestamp.nanoseconds);

    errdefer {
        var iter: Formatting.Iterator = date_time.formatting.iterator();
        while (iter.next()) |entry| {
            std.debug.print("  Formatting {f}\n", .{entry.value.*});
        }
    }

    // what if we only want the date?
    date_time = try .parse(date_str, &.{ .year, .month, .day });
    try testing.expectEqual(1779408000000000000, date_time.timestamp.nanoseconds);

    var stream: Io.Writer.Allocating = .init(testing.allocator);
    defer stream.deinit();

    date_time.formatting = .fmtStr("MM/dd/yyyy");
    try stream.writer.print("{f}", .{date_time});
    try testing.expectEqualStrings("05/22/2026", stream.written());

    stream.clearRetainingCapacity();

    // what if we only want time?
    date_time = try .parse("21:48:47.036", &.{ .hour, .minute, .second, .subsecond });
    try testing.expectEqual(78527036000000, date_time.timestamp.nanoseconds);

    date_time.formatting = .fmtStr("hh:mm:ss.fff");
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
test format {
    const nanoseconds: i96 = 1779486527036758700; // Friday, May 22, 2026 at 9:48:47.0367587 PM (UTC)

    var stream: Io.Writer.Allocating = .init(testing.allocator);
    defer stream.deinit();
    var datetime_fmt: DateTimeFormat = .{
        .formatting = .fmtStr("D, MMMM d, yyyy h:mm:ss.ffffff zzz"),
        .timestamp = .fromNanoseconds(nanoseconds),
        .utc_offset = .fromHours(2),
    };

    errdefer {
        var iter: Formatting.Iterator = datetime_fmt.formatting.iterator();
        while (iter.next()) |entry| {
            std.debug.print("  Formatting {f}\n", .{entry.value.*});
        }
    }

    {
        defer stream.clearRetainingCapacity();
        try stream.writer.print("{f}", .{datetime_fmt});
        try testing.expectEqualStrings("Fri, May 22, 2026 21:48:47.036758 0200", stream.written());
    }
    {
        defer stream.clearRetainingCapacity();
        datetime_fmt.utc_offset.sign = .negative;
        try stream.writer.print("{f}", .{datetime_fmt});
        try testing.expectEqualStrings("Fri, May 22, 2026 21:48:47.036758 -0200", stream.written());
    }
    {
        defer stream.clearRetainingCapacity();
        datetime_fmt.formatting = .fmtStr("D, MMMM d, yyyy h:mm:ss.ffffff +zzz");
        try stream.writer.print("{f}", .{datetime_fmt});
        try testing.expectEqualStrings("Fri, May 22, 2026 21:48:47.036758 -0200", stream.written());
    }
    {
        defer stream.clearRetainingCapacity();
        datetime_fmt.utc_offset.sign = .positive;
        try stream.writer.print("{f}", .{datetime_fmt});
        try testing.expectEqualStrings("Fri, May 22, 2026 21:48:47.036758 +0200", stream.written());
    }
    {
        defer stream.clearRetainingCapacity();
        datetime_fmt.formatting = .fmtStr("D, MMMM d, yyyy h:mm:ss.ffffff -zzz");
        try stream.writer.print("{f}", .{datetime_fmt});
        try testing.expectEqualStrings("Fri, May 22, 2026 21:48:47.036758 +0200", stream.written());
    }
    {
        defer stream.clearRetainingCapacity();
        datetime_fmt.formatting = .fmtStr("D, MMMM d, yyyy h:mm:ss.ffffff nn -zzz");
        try stream.writer.print("{f}", .{datetime_fmt});
        try testing.expectEqualStrings("Fri, May 22, 2026 9:48:47.036758 pm +0200", stream.written());
    }
}

comptime {
    _ = UtcOffset;
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
