//! Various utilities that I find myself reusing across Zig codebases.
//! - MiahDrao97

/// Command line utilies namespace
pub const cli = @import("cli.zig");
/// String utilities namespace
pub const string = struct {
    /// Casing utilities
    pub const Casing = @import("string/Casing.zig");
};
/// Minefield namespace for testing error paths, exactly like M. Hashimoto's Tripwire
pub const minefield = @import("minefield.zig");
/// Meta-programming utilities
pub const meta = @import("meta.zig");
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

comptime {
    _ = string.Casing;
    _ = cli;
    _ = minefield;
    _ = Uuid;
    _ = Managed(void);
    _ = MemCache;
}

const std = @import("std");
const mem_cache = @import("mem_cache.zig");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
