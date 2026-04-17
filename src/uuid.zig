/// Universally unique identifier
/// Currently supports v3, v4, v5, and v7
pub const Uuid = extern struct {
    /// Any 16 bytes are assumed to be a valid UUID.
    /// However, generating UUID's is what makes them special, as there are various methods to create them.
    /// v3 and v5 hash strings, while v4 is a completely random (apart from 2 special digits).
    bytes: [16]u8 align(16),

    /// Zero-valued UUID
    pub const empty: Uuid = .{ .bytes = @splat(0) };

    /// Maximum value a UUID can be
    pub const max: Uuid = .{ .bytes = @splat(0xff) };

    /// Default comparer if used in any sorting algorithm in `std.mem`
    pub const comparer: struct {
        pub fn lessThan(_: @This(), a: Uuid, b: Uuid) bool {
            return a.lessThan(b);
        }
    } = .{};

    /// Format options when printing
    pub const FormatOptions = struct {
        /// Grouped like 8-4-4-4-12, with a given separator (defaulting to dashes)
        seperator: Separator = .dashes,
        /// Casing on the values
        casing: enum { lower, upper } = .lower,

        /// Supported separators or no separators
        pub const Separator = enum {
            dashes,
            underscores,
            periods,
            none,

            fn char(self: @This()) ?u8 {
                return switch (self) {
                    .dashes => '-',
                    .underscores => '_',
                    .periods => '.',
                    .none => null,
                };
            }
        };
    };

    /// Possible errors when parsing a UUID (see `from()`)
    pub const ParseError = std.fmt.ParseIntError || error{
        /// This indicates the string's length is not correct:
        /// Expecting either 16 raw bytes, 32 characters with no separators, or 36 characters including separators
        InvalidFormat,
        /// The bytes at indices 8, 13, 18, and/or 23 did not match (these are expected to be separators)
        MismatchedSeparators,
        /// The separator character is invalid (only supporting dashes, underscores, and periods)
        InvalidSeparator,
    };

    /// Create a value from any 16 bytes
    pub fn raw(bytes: *const [16]u8) Uuid {
        var uuid: Uuid = undefined;
        @memcpy(&uuid.bytes, bytes);
        return uuid;
    }

    /// Concats `namespace` and `name` and creates a hash using the MD5 algorithm.
    /// `gpa` is only for the above concatenation, which is freed on scope exit.
    /// NOTE : This is not considered cryptographically safe.
    pub fn v3(gpa: Allocator, namespace: []const u8, name: []const u8) Allocator.Error!Uuid {
        const to_hash: []u8 = try gpa.alloc(u8, namespace.len + name.len);
        defer gpa.free(to_hash);
        @memcpy(to_hash[0..namespace.len], namespace);
        @memcpy(to_hash[namespace.len..], name);

        var md5: crypto.hash.Md5 = .init(.{});
        md5.update(to_hash);

        var uuid: Uuid = undefined;
        md5.final(&uuid.bytes);

        return uuid;
    }

    /// Create a UUIDv4
    pub fn v4(io: Io) Uuid {
        var uuid: Uuid = undefined;
        io.random(&uuid.bytes);

        // since this is v4, the 7th byte must start with 4
        uuid.bytes[6] &= 0x0f;
        uuid.bytes[6] |= 0x40;

        // the 9th byte must start with 8, 9, a, or b
        const mod: u8 = 0x80 + (@as(u8, @as(u2, @truncate(uuid.bytes[8]))) * 0x10);
        uuid.bytes[8] &= 0x0f;
        uuid.bytes[8] |= mod;

        return uuid;
    }

    /// Concats `namespace` and `name` and creates a hash using the SHA1 algorithm.
    /// `gpa` is only for the above concatenation, which is freed on scope exit.
    /// NOTE : This is not considered cryptographically safe.
    pub fn v5(gpa: Allocator, namespace: []const u8, name: []const u8) Allocator.Error!Uuid {
        const to_hash: []u8 = try gpa.alloc(u8, namespace.len + name.len);
        defer gpa.free(to_hash);
        @memcpy(to_hash[0..namespace.len], namespace);
        @memcpy(to_hash[namespace.len..], name);

        var sha1: crypto.hash.Sha1 = .init(.{});
        sha1.update(to_hash);

        var out: [20]u8 = undefined;
        sha1.final(&out);

        var uuid: Uuid = undefined;
        @memcpy(&uuid.bytes, out[0..16]);

        return uuid;
    }

    /// The first 6 bytes represent a millisecond timestamp, which provides a sense of time-based ordering to the identifier.
    /// The 7th byte starts with a 0x7 since this is version 7 and the rest is random
    pub fn v7(io: Io) Uuid {
        var uuid: Uuid = undefined;

        const timestamp: Io.Timestamp = .now(io, .real);
        const ms: i48 = @truncate(timestamp.toMilliseconds());
        // These need to be represented as big endian
        const ms_bytes: *const [6]u8 = switch (@import("builtin").target.cpu.arch.endian()) {
            .little => little_endian: {
                var ms_big: [6]u8 = undefined;
                const ms_little: *const [6]u8 = @ptrCast(&ms);
                for (&ms_big, 1..) |*b, i| b.* = ms_little[6 - i];
                break :little_endian &ms_big;
            },
            .big => @ptrCast(&ms),
        };
        @memcpy(uuid.bytes[0..6], ms_bytes);

        io.random(uuid.bytes[6..]);

        // since this is v7 the 7th byte must start with 7
        uuid.bytes[6] &= 0x0f;
        uuid.bytes[6] |= 0x70;

        return uuid;
    }

    /// Parse a UUID from a string.
    /// The string is expected to be one of the following formats:
    /// - 16 raw bytes (infallible if this is the case)
    /// - 32 hex digits with no separators
    /// - 36 characters of 32 hex digits plus 4 separators at indices 8, 13, 18, and 23
    pub fn from(str: []const u8) ParseError!Uuid {
        return switch (str.len) {
            16 => raw(str[0..16]),
            32 => hex_digits_no_separators: {
                var uuid: Uuid = undefined;
                var i: usize = 0;
                for (0..16) |j| {
                    uuid.bytes[j] = try std.fmt.parseUnsigned(u8, str[i..][0..2], 16);
                    i += 2;
                }
                break :hex_digits_no_separators uuid;
            },
            36 => hex_digits_with_separators: {
                const separator_indices: [4]usize = .{ 8, 13, 18, 23 };
                var separators: [4]u8 = undefined;
                for (&separators, separator_indices) |*s, i| s.* = str[i];

                const first: u8 = separators[0];
                if (@reduce(.And, @as(@Vector(4, u8), separators)) != first) {
                    return error.MismatchedSeparators;
                }
                switch (first) {
                    '-', '_', '.' => {},
                    else => return error.InvalidSeparator,
                }

                var uuid: Uuid = undefined;
                var i: usize = 0;
                for (0..16) |j| {
                    uuid.bytes[j] = try std.fmt.parseUnsigned(u8, str[i..][0..2], 16);
                    i += 2;
                    const current: @Vector(4, usize) = @splat(i);
                    if (@reduce(.Or, current == separator_indices)) {
                        i += 1;
                    }
                }
                break :hex_digits_with_separators uuid;
            },
            else => error.InvalidFormat,
        };
    }

    /// So that a UUID can be printed with the `{f}` specifier.
    /// Writes the default lower-case format with dashes for separators.
    /// If you want to write this UUID in a different format, use `writeTo()`.
    pub fn format(self: Uuid, writer: *Io.Writer) Io.Writer.Error!void {
        try self.writeTo(writer, .{});
    }

    /// Writes to a buffer.
    /// This function is infallible due to enforcing the buffer's size in the function signature (will not write more than 36 bytes).
    pub fn toStringBuf(
        self: Uuid,
        buf: *[36]u8,
        fmt_opts: FormatOptions,
    ) []const u8 {
        var writer: Io.Writer = .fixed(buf);
        self.writeTo(&writer, fmt_opts) catch unreachable;
        return writer.buffered();
    }

    /// Format the UUID, allocating the resulting string
    pub fn toStringAlloc(
        self: Uuid,
        gpa: Allocator,
        fmt_opts: FormatOptions,
    ) Allocator.Error![]const u8 {
        var stream: Io.Writer.Allocating = .init(gpa);
        defer stream.deinit();

        self.writeTo(&stream.writer, fmt_opts) catch return Allocator.Error.OutOfMemory;
        return try stream.toOwnedSlice();
    }

    /// Format the UUID to a writer
    pub fn writeTo(
        self: Uuid,
        writer: *Io.Writer,
        fmt_opts: FormatOptions,
    ) Io.Writer.Error!void {
        switch (fmt_opts.seperator) {
            .none => switch (fmt_opts.casing) {
                .lower => try writer.print("{x}", .{self.bytes}),
                .upper => try writer.print("{X}", .{self.bytes}),
            },
            // 8-4-4-4-12 format, or whichever separator
            inline else => |x| {
                const char: u8 = x.char().?;
                switch (fmt_opts.casing) {
                    .lower => try writer.print("{x}{c}{x}{c}{x}{c}{x}{c}{x}", .{
                        self.bytes[0..4],
                        char,
                        self.bytes[4..][0..2],
                        char,
                        self.bytes[6..][0..2],
                        char,
                        self.bytes[8..][0..2],
                        char,
                        self.bytes[10..],
                    }),
                    .upper => try writer.print("{X}{c}{X}{c}{X}{c}{X}{c}{X}", .{
                        self.bytes[0..4],
                        char,
                        self.bytes[4..][0..2],
                        char,
                        self.bytes[6..][0..2],
                        char,
                        self.bytes[8..][0..2],
                        char,
                        self.bytes[10..],
                    }),
                }
            },
        }
    }

    /// Test if two UUID's are equal
    pub fn eql(a: Uuid, b: Uuid) bool {
        const vec_a: @Vector(16, u8) = a.bytes;
        const vec_b: @Vector(16, u8) = b.bytes;

        return @reduce(.And, vec_a == vec_b);
    }

    /// Use this to sort UUIDs.
    /// Generally, sorting doesn't make much sense outside of generating UUIDs with v7, since those begin with a ms timestamp of their creation time.
    pub fn lessThan(a: Uuid, b: Uuid) bool {
        return for (&a.bytes, &b.bytes) |x, y| {
            if (x < y) break true;
            if (x > y) break false;
        } else false;
    }

    test lessThan {
        const a: Uuid = try .from("019b3d7e-cfd2-7eef-ee0d-aa4f305fcf22");
        const b: Uuid = try .from("019b3d7e-cfe2-7b6f-ff94-876ee3312800");
        try testing.expect(a.lessThan(b));
    }
    test v4 {
        var prev: ?Uuid = null;
        for (0..20) |_| {
            const uuid: Uuid = .v4(testing.io);
            defer prev = uuid;

            try testing.expect(uuid.bytes[6] >= 0x40 and uuid.bytes[6] < 0x50);
            try testing.expect(uuid.bytes[8] >= 0x80 and uuid.bytes[8] < 0xc0);
            if (prev) |p| {
                try testing.expect(!uuid.eql(p));
            }
        }
    }
    test v7 {
        var prev: ?Uuid = null;
        for (0..20) |_| {
            const uuid: Uuid = .v7(testing.io);
            defer prev = uuid;

            try testing.expect(uuid.bytes[6] >= 0x70 and uuid.bytes[6] < 0x80);
            if (prev) |p| {
                try testing.expect(!uuid.eql(p));
                try testing.expect(p.lessThan(uuid));
            }

            // need to guarantee they're spaced out by at least 1ms, or else the `lessThan()` check fails
            try testing.io.sleep(.fromMilliseconds(1), .awake);
        }
    }
    test from {
        const uuid: Uuid = .v4(testing.io);
        var buf: [36]u8 = undefined;
        // dashes
        {
            const uuid_str: []const u8 = uuid.toStringBuf(&buf, .{});
            const parsed: Uuid = try .from(uuid_str);
            try testing.expect(uuid.eql(parsed));
        }
        // no dashes
        {
            const uuid_str: []const u8 = uuid.toStringBuf(&buf, .{ .seperator = .none });
            const parsed: Uuid = try .from(uuid_str);
            try testing.expect(uuid.eql(parsed));
        }
        // raw
        {
            const raw_bytes: [16]u8 = @splat('a');
            const parsed: Uuid = try .from(&raw_bytes);
            for (&parsed.bytes) |b| {
                try testing.expect(b == 'a');
            }
            const raw_uuid: Uuid = .raw(&raw_bytes);
            for (&raw_uuid.bytes) |b| {
                try testing.expect(b == 'a');
            }
        }
    }
    test toStringAlloc {
        const uuid: Uuid = .v4(testing.io);
        const uuid_str: []const u8 = try uuid.toStringAlloc(testing.allocator, .{});
        defer testing.allocator.free(uuid_str);

        const parsed: Uuid = try .from(uuid_str);
        try testing.expect(uuid.eql(parsed));
    }
    test "alignment" {
        var bytes: [16]u8 align(16) = @splat(0);
        const uuid: *const Uuid = @ptrCast(&bytes);
        try testing.expect(uuid.eql(.empty));
        try testing.expect(@alignOf(Uuid) == 16);
    }
};

const std = @import("std");
const testing = std.testing;
const crypto = std.crypto;
const Allocator = std.mem.Allocator;
const Io = std.Io;
