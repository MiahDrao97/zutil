//! Really, just a reskinning of Mitchell Hashimoto's [TripWire](https://mitchellh.com/writing/tripwire)
//! OG source code mimicked from here: https://github.com/ghostty-org/ghostty/blob/main/src/tripwire.zig
//!
//! This is was a convention created by Mitchell Hashimoto for the Ghostty project to ensure testing of `errdefer` paths.
//! Essentially, right before any failable function call, you can simply place a mine before.
//! If the mine is set to detonate when stepped on (or when stepped on a certain number of times),
//! the specified error will be returned, thereby testing the `errdefer` logic path.
//! It does not generate any machine code in non-test builds.

/// Setup a minefield:
/// `F` - a set of fuses (an enum that represents various error-testing scenarios)
/// `E` - an error set, error union, or failable function (the minefield we're planting mines in).
pub fn set(comptime F: type, comptime E: anytype) type {
    return struct {
        /// Expose `Fuse` back
        pub const Fuse = F;
        /// Expose `E` back
        pub const Error = err: {
            const T = if (@TypeOf(E) == type) E else @TypeOf(E);
            break :err switch (@typeInfo(T)) {
                .error_set => T,
                .error_union => |e| e.error_set,
                .@"fn" => |f| @typeInfo(f.return_type.?).error_union.error_set,
                else => @compileError("Expected error union, error set, or function but received " ++ @typeName(T)),
            };
        };
        comptime {
            debug.assert(@typeInfo(Fuse) == .@"enum");
            debug.assert(@typeInfo(Error) == .error_set);
        }

        pub const live: bool = builtin.is_test;

        // static map of mines
        var mine_map: MineMap = .{};

        /// Inline when not live so that no machine code will be produced
        const cc: std.builtin.CallingConvention = if (live) .auto else .@"inline";
        /// Map of all active fuses
        const MineMap = std.EnumMap(Fuse, Mine);
        /// The mine itself
        const Mine = struct {
            /// Detonation result
            err: Error,
            /// Number of times this has been reached
            reached: usize = 0,
            /// Number of times this fuse has been reached before detonating
            safety_threshold: usize = 0,
            /// True if detonated
            detonated: bool = false,

            fn step(self: *Mine) Error!void {
                self.reached += 1;
                if (self.reached > self.safety_threshold) {
                    self.detonated = true;
                    return self.err;
                }
            }
        };

        /// Step on a mine with a given fuse.
        /// It will only detonate if configured to.
        /// In non-test builds (releases and even debug), this function has no effect and doesn't even emit machine code.
        pub fn stepOn(fuse: Fuse) callconv(cc) Error!void {
            if (!comptime live) return;

            const m: *Mine = mine_map.getPtr(fuse) orelse return;
            try m.step();
        }

        /// Activates a mine with the corresponding fuse.
        /// A single step will detonate it.
        pub fn detonateOn(fuse: Fuse, err: Error) void {
            detonateAfter(fuse, err, 0);
        }

        /// Activates a mine with the corresponding fuse.
        /// If the threshold is exceeded, the mine will detonate.
        pub fn detonateAfter(fuse: Fuse, err: Error, threshold: usize) void {
            mine_map.put(fuse, .{ .err = err, .safety_threshold = threshold });
        }

        /// Ensure that all expected detonations were hit.
        /// Resets the mine map if desired; otherwise, the map stays the same.
        pub fn cleanup(reset_strategy: enum { reset, retain }) error{DetonationMissed}!void {
            var missed: bool = false;
            var iter: MineMap.Iterator = mine_map.iterator();
            while (iter.next()) |m| {
                if (!m.value.detonated) {
                    log.err("Un-detonated mine for fuse {t}", .{m.key});
                    missed = true;
                }
            }

            switch (reset_strategy) {
                .reset => reset(),
                .retain => {},
            }

            if (missed) return error.DetonationMissed;
        }

        /// Reset the mine map
        pub fn reset() void {
            mine_map = .{};
        }
    };
}

test set {
    const landmine = set(enum { alloc, open }, error{ OutOfMemory, OpenError });
    const testFunc = struct {
        fn testFunc(gpa: Allocator, str: []const u8) error{ OutOfMemory, OpenError }![]const u16 {
            try landmine.stepOn(.alloc);
            const wpath: []u16 = try gpa.alloc(u16, str.len);
            errdefer gpa.free(wpath);

            for (wpath, str) |*char, byte| char.* = byte;

            try landmine.stepOn(.open);
            // imagine we did some stuff with the wpath here
            return wpath;
        }
    }.testFunc;

    landmine.detonateOn(.alloc, error.OutOfMemory);
    try testing.expectError(error.OutOfMemory, testFunc(testing.allocator, "yayz"));
    try landmine.cleanup(.reset);

    landmine.detonateOn(.open, error.OpenError);
    try testing.expectError(error.OpenError, testFunc(testing.allocator, "yayz"));
    try landmine.cleanup(.reset);

    landmine.detonateAfter(.open, error.OpenError, 1);
    const wpath: []const u16 = try testFunc(testing.allocator, "yayz");
    defer testing.allocator.free(wpath);

    try testing.expectError(error.DetonationMissed, landmine.cleanup(.retain));
    const m: landmine.Mine = landmine.mine_map.get(.open) orelse return error.MineNotFound;
    try testing.expectEqual(1, m.safety_threshold);
    try testing.expectEqual(1, m.reached);

    try testing.expectError(error.OpenError, testFunc(testing.allocator, "blarf"));
    try landmine.cleanup(.reset);
}

const std = @import("std");
const builtin = @import("builtin");
const debug = std.debug;
const log = std.log.scoped(.minefield);
const testing = std.testing;
const Allocator = std.mem.Allocator;
