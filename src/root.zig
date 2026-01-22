//! Various utilities that I find myself reusing across Zig codebases.
//! - MiahDrao97

/// Command line utilies namespace
pub const cli = @import("cli.zig");
/// String utilities namespace
pub const string = struct {
    pub const Casing = @import("string/Casing.zig");
};
/// Minefield namespace for testing error paths, exactly like M. Hashimoto's Tripwire
pub const minefield = @import("minefield.zig");

/// A managed value is useful when memory won't be or can't be freed after doing the work to create said value.
/// However, when this managed value is freed, all memory allocated when it was created will also be freed.
pub fn Managed(comptime T: type) type {
    return struct {
        /// Value itself
        value: T,
        /// Arena used to create the managed value
        arena: ArenaAllocator,

        const mine = minefield.landmine(enum { init }, create);

        /// Create a new managed value.
        /// Returns `self.*` (usually because you're returning this managed value or passing it as an argument).
        /// This requires a 2-step initialization. Example:
        /// ```zig
        /// var managed: Managed(T) = undefined;
        /// _ = try managed.create(gpa, ctx, @TypeOf(ctx).initValue);
        /// ```
        pub fn create(
            self: *Managed(T),
            gpa: Allocator,
            context: anytype,
            initFn: fn (@TypeOf(context), Allocator) anyerror!T,
        ) !Managed(T) {
            self.arena = .init(gpa);
            errdefer self.arena.deinit();

            try mine.stepOn(.init);
            self.value = try initFn(context, self.arena.allocator());
            return self.*;
        }

        /// Destroy the managed value and all memory allocated when creating it.
        pub fn deinit(self: Managed(T)) void {
            self.arena.deinit();
        }

        test Managed {
            const Value = struct {
                str: []const u8,
            };
            const init_ctx: struct {
                fn initValue(_: @This(), gpa: Allocator) anyerror!Value {
                    return .{ .str = try gpa.dupe(u8, "test") };
                }
            } = .{};

            // success
            {
                var val: Managed(Value) = undefined;
                _ = try val.create(testing.allocator, init_ctx, @TypeOf(init_ctx).initValue);
                defer val.deinit();

                try testing.expectEqualStrings("test", val.value.str);
            }
            // failure
            {
                mine.detonateOn(.init, error.OutOfMemory);

                var val: Managed(Value) = undefined;
                try testing.expectError(
                    error.OutOfMemory,
                    val.create(testing.allocator, init_ctx, @TypeOf(init_ctx).initValue),
                );
                try mine.cleanup(.reset);
            }
        }
    };
}

/// `TSubset` must be a subset of `struct`'s type (strictly looking at the names and types of struct members).
/// Create an instance of `TSubset` from `struct`'s members.
pub fn structSubset(comptime TSubset: type, @"struct": anytype) TSubset {
    const SourceType = @TypeOf(@"struct");
    switch (@typeInfo(SourceType)) {
        .@"struct" => switch (@typeInfo(TSubset)) {
            .@"struct" => |to| {
                var result: TSubset = undefined;
                inline for (to.fields) |field| {
                    if (@hasField(SourceType, field.name)) {
                        if (@FieldType(SourceType, field.name) == field.type) {
                            @field(result, field.name) = @field(@"struct", field.name);
                        } else {
                            @compileError("Expected type `" ++ @typeName(field.type) ++ "` on field `" ++ field.name ++ "`, but found `" ++ @typeName(@FieldType(SourceType, field.name)) ++ "`.");
                        }
                    } else @compileError("Field `" ++ field.Name ++ "` not found on type `" ++ @typeName(SourceType) ++ "`.");
                }
                return result;
            },
            else => @compileError("`" ++ @typeName(TSubset) ++ "` is not a struct."),
        },
        .pointer => |ptr| return structSubset(ptr.child, @"struct".*),
        else => @compileError("`" ++ @typeName(SourceType) ++ "` is not a struct."),
    }
}

/// Universally unique identifier
/// Currently supports v3, v4, v5, and v7
pub const Uuid = struct {
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

    /// Create a UUIDv4 using a specific implementation of `std.Random`
    pub fn v4Random(random: Random) Uuid {
        var uuid: Uuid = undefined;
        random.bytes(&uuid.bytes);

        // since this is v4, the 7th byte must start with 4
        uuid.bytes[6] &= 0x0f;
        uuid.bytes[6] |= 0x40;

        // the 9th byte must start with 8, 9, a, or b
        const mod: u8 = 0x80 + (@as(u8, random.int(u2)) * 0x10);
        uuid.bytes[8] &= 0x0f;
        uuid.bytes[8] |= mod;

        return uuid;
    }

    /// Uses `std.crypto.random` as default implementation
    pub fn v4() Uuid {
        return v4Random(crypto.random);
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
    pub fn v7Random(random: Random) Uuid {
        var uuid: Uuid = undefined;

        const ms: i48 = @truncate(std.time.milliTimestamp());
        // These need to be represented as big endian
        const ms_bytes: *const [6]u8 = switch (@import("builtin").target.cpu.arch.endian()) {
            .little => little_endian: {
                var ms_big: [6]u8 = undefined;
                const ms_little: *const [6]u8 = @ptrCast(&ms);
                inline for (&ms_big, 1..) |*b, i| b.* = ms_little[6 - i];
                break :little_endian &ms_big;
            },
            .big => @ptrCast(&ms),
        };
        @memcpy(uuid.bytes[0..6], ms_bytes);

        random.bytes(uuid.bytes[6..]);

        // since this is v7 the 7th byte must start with 7
        uuid.bytes[6] &= 0x0f;
        uuid.bytes[6] |= 0x70;

        return uuid;
    }

    /// Uses `std.crypto.random` as default implementation
    pub fn v7() Uuid {
        return v7Random(crypto.random);
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
                comptime var i: usize = 0;
                inline for (0..16) |j| {
                    uuid.bytes[j] = try std.fmt.parseUnsigned(u8, str[i..][0..2], 16);
                    i += 2;
                }
                break :hex_digits_no_separators uuid;
            },
            36 => hex_digits_with_separators: {
                const separator_indices: [4]usize = .{ 8, 13, 18, 23 };
                var separators: [4]u8 = undefined;
                inline for (&separators, separator_indices) |*s, i| s.* = str[i];

                const first: u8 = separators[0];
                if (@reduce(.And, @as(@Vector(4, u8), separators)) != first) {
                    return error.MismatchedSeparators;
                }
                switch (first) {
                    '-', '_', '.' => {},
                    else => return error.InvalidSeparator,
                }

                var uuid: Uuid = undefined;
                comptime var i: usize = 0;
                inline for (0..16) |j| {
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
        return inline for (&a.bytes, &b.bytes) |x, y| {
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
        for (0..100) |_| {
            const uuid: Uuid = .v4();
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
        for (0..100) |_| {
            const uuid: Uuid = .v7();
            defer prev = uuid;

            std.debug.print("{f}\n", .{uuid});

            try testing.expect(uuid.bytes[6] >= 0x70 and uuid.bytes[6] < 0x80);
            if (prev) |p| {
                try testing.expect(!uuid.eql(p));
                try testing.expect(p.lessThan(uuid));
            }

            // need to guarantee they're spaced out by at least 1ms, or else the `lessThan()` check fails
            std.Thread.sleep(1_000_000);
        }
    }
    test from {
        const uuid: Uuid = .v4();
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
        const uuid: Uuid = .v4();
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

comptime {
    _ = string.Casing;
    _ = cli;
}

const std = @import("std");
const log = std.log;
const Io = std.Io;
const crypto = std.crypto;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const SourceLocation = std.builtin.SourceLocation;
const Random = std.Random;
