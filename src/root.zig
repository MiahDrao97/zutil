//! Various utilities that I find myself reusing across Zig codebases.
//! - MiahDrao97

/// Command line utilies
pub const cli = @import("cli.zig");
/// String utilities
pub const string = @import("string.zig");

/// A managed value is useful when memory won't be or can't be freed after doing the work to create said value.
/// However, when this managed value is freed, all memory allocated when it was created will also be freed.
pub fn Managed(comptime T: type) type {
    return struct {
        /// Value itself
        value: T,
        /// Arena used to create the managed value
        arena: ArenaAllocator,

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

            self.value = try initFn(context, self.arena.allocator());
            return self.*;
        }

        /// Destroy the managed value and all memory allocated when creating it.
        pub fn deinit(self: Managed(T)) void {
            self.arena.deinit();
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
/// Currently supports v3, v4, and v5
pub const Uuid = struct {
    /// Any 16 bytes are assumed to be a valid UUID.
    /// However, generating UUID's is what makes them special, as there are various methods to create them.
    /// v3 and v5 hash strings, while v4 is a completely random (apart from 2 special digits).
    bytes: [16]u8 align(16),

    /// Zero-valued UUID
    pub const empty: Uuid = .{ .bytes = @splat(0) };

    /// Maximum value a UUID can be
    pub const max: Uuid = .{ .bytes = @splat(0xff) };

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

    /// Concats `namespace` and `name` and creates a hash using the MD5 algorithm.
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
    pub fn v4Random(random: std.Random) Uuid {
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
    /// NOTE : This is not considered cryptographically safe.
    pub fn v5(gpa: Allocator, namespace: []const u8, name: []const u8) Allocator.Error!Uuid {
        // SHA1
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

    /// Parse a UUID from a string.
    /// The string is expected to be one of the following formats:
    /// - 16 raw bytes
    /// - 32 hex digits with no separators
    /// - 36 characters of 32 hex digits plus 4 separators at indices 8, 13, 18, and 23
    pub fn from(str: []const u8) ParseError!Uuid {
        return switch (str.len) {
            16 => raw_bytes: {
                var uuid: Uuid = undefined;
                @memcpy(&uuid.bytes, str[0..16]);
                break :raw_bytes uuid;
            },
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
                const separator: u8 = str[8];
                if (str[13] != separator and str[18] != separator and str[23] != separator) {
                    return error.MismatchedSeparators;
                }
                switch (separator) {
                    '-', '_', '.' => {},
                    else => return error.InvalidSeparator,
                }

                var uuid: Uuid = undefined;
                var i: usize = 0;
                for (0..4) |j| {
                    uuid.bytes[j] = try std.fmt.parseUnsigned(u8, str[i..][0..2], 16);
                    i += 2;
                }
                i += 1;
                for (4..6) |j| {
                    uuid.bytes[j] = try std.fmt.parseUnsigned(u8, str[i..][0..2], 16);
                    i += 2;
                }
                i += 1;
                for (6..8) |j| {
                    uuid.bytes[j] = try std.fmt.parseUnsigned(u8, str[i..][0..2], 16);
                    i += 2;
                }
                i += 1;
                for (8..10) |j| {
                    uuid.bytes[j] = try std.fmt.parseUnsigned(u8, str[i..][0..2], 16);
                    i += 2;
                }
                i += 1;
                for (10..16) |j| {
                    uuid.bytes[j] = try std.fmt.parseUnsigned(u8, str[i..][0..2], 16);
                    i += 2;
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
    /// This function is infallible due to enforcing the buffer's size in the function signature.
    /// Will write no more than 36 bytes.
    pub fn toString(
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

    test v4 {
        for (0..1000) |_| {
            const uuid: Uuid = .v4();
            try testing.expect(uuid.bytes[6] >= 0x40 and uuid.bytes[6] < 0x50);
            try testing.expect(uuid.bytes[8] >= 0x80 and uuid.bytes[8] < 0xc0);
        }
        const a: Uuid = .v4();
        const b: Uuid = .v4();

        try testing.expect(!a.eql(b));
    }
    test from {
        const uuid: Uuid = .v4();
        var buf: [36]u8 = undefined;
        // dashes
        {
            const uuid_str: []const u8 = uuid.toString(&buf, .{});
            const parsed: Uuid = try .from(uuid_str);
            try testing.expect(uuid.eql(parsed));
        }
        // no dashes
        {
            const uuid_str: []const u8 = uuid.toString(&buf, .{ .seperator = .none });
            const parsed: Uuid = try .from(uuid_str);
            try testing.expect(uuid.eql(parsed));
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
    testing.refAllDecls(@This());
}

const std = @import("std");
const log = std.log;
const Io = std.Io;
const crypto = std.crypto;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const SourceLocation = std.builtin.SourceLocation;
