//! Various utilities that I find myself reusing across Zig codebases.
//! - MiahDrao97

/// Command line utilies namespace
pub const cli = @import("cli.zig");
/// String utilities namespace
pub const string = struct {
    /// Casing utilities
    pub const Casing = @import("string/Casing.zig");
    /// Date format utilities
    pub const DateTimeFormat = @import("string/DateTimeFormat.zig");
};
/// Minefield namespace for testing error paths, exactly like M. Hashimoto's Tripwire
pub const minefield = @import("minefield.zig");
/// Meta-programming utilities
pub const meta = @import("meta.zig");
/// Memory cache and related types
pub const mem_cache = @import("mem_cache.zig");
/// General-purpose memory cache for memoizing values
pub const MemCache = mem_cache.MemCache;
/// Create a memory cache of any max alignment
pub const MemCacheAligned = mem_cache.MemCacheAligned;
/// Universallty unique identifer
pub const Uuid = @import("uuid.zig").Uuid;

/// A managed value is useful when memory won't be or can't be freed after doing the work to create said value.
/// However, when this managed value is freed, all memory allocated when it was created will also be freed.
pub fn Managed(comptime T: type) type {
    return struct {
        /// Value itself
        value: T,
        /// Arena used to create the managed value
        arena: ArenaAllocator,

        const mine = minefield.set(enum { init }, anyerror);

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

        test create {
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

/// Intern segments of `[]const u8` for better memory storage.
/// Note that this structure is expected only to grow.
pub const InternedByteArray = InternedByteArrayAligned(.@"1");

/// Align the bytes, if desired.
/// Each segment will be aligned, according to whichever alignment you specify.
pub fn InternedByteArrayAligned(comptime alignment: std.mem.Alignment) type {
    return struct {
        inner: ArrayListAligned(u8, alignment),
        segment_count: u32,

        const Self = @This();

        pub const Index = enum(u32) { _ };

        pub const empty: Self = .{ .inner = .empty, .segment_count = 0 };

        pub fn deinit(self: *Self, gpa: Allocator) void {
            self.inner.deinit(gpa);
            self.* = undefined;
        }

        /// Intern a segment at the end of the byte array.
        /// Each segment is aligned, and padding will prepend any segment if needed.
        pub fn append(self: *Self, gpa: Allocator, str: []const u8) Allocator.Error!Index {
            const next: usize = self.inner.items.len;
            const offset: Index = if (alignment.check(next))
                @enumFromInt(next)
            else unaligned: {
                const diff: usize = alignment.forward(next) - next;
                try self.inner.appendNTimes(gpa, 0, diff);
                break :unaligned @enumFromInt(self.inner.items.len);
            };
            std.debug.assert(alignment.check(@intFromEnum(offset)));
            try self.inner.appendSlice(gpa, str);
            try self.inner.append(gpa, 0);
            self.segment_count += 1;
            return offset;
        }

        /// Get a segment.
        /// Each segment is aligned.
        /// Note that if more segments are appended, that may invalidate the returned pointer.
        pub fn get(self: *const Self, index: Index) []align(alignment.toByteUnits()) const u8 {
            return @alignCast(mem.sliceTo(self.inner.items[@intFromEnum(index)..], 0));
        }

        pub fn iterator(self: *const Self) Iterator {
            return .{ .offset = 0, .byte_array = self };
        }

        pub const Iterator = struct {
            offset: u32,
            byte_array: *const Self,

            pub fn next(self: *Iterator) ?[]align(alignment.toByteUnits()) const u8 {
                var result: ?[]align(alignment.toByteUnits()) const u8 = null;
                if (self.offset < self.byte_array.inner.items.len) {
                    std.debug.assert(alignment.check(self.offset));
                    result = @alignCast(mem.sliceTo(self.byte_array.inner.items[self.offset..], 0));
                    self.offset += @intCast(result.?.len + 1); // add 1 to include the sentinel value
                    // alignment check...
                    if (!alignment.check(self.offset)) {
                        self.offset = @intCast(alignment.forward(self.offset));
                    }
                }
                return result;
            }
        };
    };
}

test InternedByteArray {
    var byte_array: InternedByteArray = .empty;
    defer byte_array.deinit(testing.allocator);

    errdefer std.debug.print("Bytes: {s}\n    {x}\n", .{ byte_array.inner.items, byte_array.inner.items });

    var idx: InternedByteArray.Index = try byte_array.append(testing.allocator, "hi");
    try testing.expectEqual(0, @intFromEnum(idx));
    idx = try byte_array.append(testing.allocator, "hello");
    try testing.expectEqual(3, @intFromEnum(idx));

    try testing.expectEqual(2, byte_array.segment_count);

    const hello: []const u8 = byte_array.get(idx);
    try testing.expectEqualStrings("hello", hello);

    idx = try byte_array.append(testing.allocator, "");
    try testing.expectEqual(9, @intFromEnum(idx));
    try testing.expectEqual(3, byte_array.segment_count);

    var iter: InternedByteArray.Iterator = byte_array.iterator();
    try testing.expectEqualStrings("hi", iter.next().?);
    try testing.expectEqualStrings("hello", iter.next().?);
    try testing.expectEqualStrings("", iter.next().?);
    try testing.expectEqual(null, iter.next());
}
test InternedByteArrayAligned {
    const Aligned = InternedByteArrayAligned(.@"4");
    var byte_array: Aligned = .empty;
    defer byte_array.deinit(testing.allocator);

    errdefer std.debug.print("Bytes: {s}\n    {x}\n", .{ byte_array.inner.items, byte_array.inner.items });

    var idx: Aligned.Index = try byte_array.append(testing.allocator, "hello");
    try testing.expectEqual(0, @intFromEnum(idx));
    idx = try byte_array.append(testing.allocator, "hi");
    try testing.expectEqual(8, @intFromEnum(idx));
    idx = try byte_array.append(testing.allocator, "");
    try testing.expectEqual(12, @intFromEnum(idx));

    var iter: Aligned.Iterator = byte_array.iterator();
    try testing.expectEqualStrings("hello", iter.next().?);
    try testing.expectEqualStrings("hi", iter.next().?);
    try testing.expectEqualStrings("", iter.next().?);
    try testing.expectEqual(null, iter.next());
}

comptime {
    _ = string.Casing;
    _ = string.DateTimeFormat;
    _ = cli;
    _ = minefield;
    _ = Uuid;
    _ = Managed(void);
    _ = MemCache;
    _ = InternedByteArray;
}

const std = @import("std");
const testing = std.testing;
const mem = std.mem;
const Allocator = mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ArrayList = std.ArrayList;
const ArrayListAligned = std.array_list.Aligned;
