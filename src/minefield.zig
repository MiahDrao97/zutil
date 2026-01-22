//! Really, just a reskinning of Mitchell Hashimoto's [TripWire](https://mitchellh.com/writing/tripwire)
//! OG source code mimicked from here: https://github.com/ghostty-org/ghostty/blob/main/src/tripwire.zig
//!
//! This is was a convention created by Mitchel Hashimoto for the Ghostty project to ensure testing of `errdefer` paths.
//! Essentially, right before any failable function call, you can simply place a landmine before.
//! If the landmine is set to detonate when stepped on, the specified error will be returned, thereby testing the `errdefer` logic path.
//! It does not generate any machine code in non-test builds.

/// Setup a landmine with a set of fuses (error-testing scenarios) and an error set, error union, or failable function (the field we're planting mines in).
pub fn landmine(comptime Fuses: type, comptime ErrorField: anytype) type {
    return struct {
        /// Expose `Fuses` back
        pub const FuseLabels = Fuses;
        /// Expose `ErrorField` back
        pub const Error = err: {
            const T = if (@TypeOf(ErrorField) == type) ErrorField else @TypeOf(ErrorField);
            break :err switch (@typeInfo(T)) {
                .error_set => T,
                .error_union => |e| e.error_set,
                .@"fn" => |f| @typeInfo(f.return_type.?).error_union.error_set,
            };
        };
        comptime {
            debug.assert(@typeInfo(Fuses) == .@"enum");
            debug.assert(@typeInfo(Error) == .error_set);
        }

        pub const live: bool = builtin.is_test;

        // static map of mines
        var mine_map: MineMap = .{};

        /// Inline when not live so that no machine code will be produced
        const cc: std.builtin.CallingConvention = if (live) .auto else .@"inline";
        /// Map of all active fuses
        const MineMap = std.EnumMap(Fuses, Mine);
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
        /// In non-test builds (releases and even debug), this function has no effeect and doesn't even emit machine code.
        pub fn stepOn(fuse: Fuses) callconv(cc) Error!void {
            if (!comptime live) return;

            const m: *Mine = mine_map.getPtr(fuse) orelse return;
            try m.step();
        }

        /// Activates a mine with the corresponding fuse.
        /// A single step will detonate it.
        pub fn detonateOn(fuse: Fuses, err: Error) void {
            detonateAfter(fuse, err, 0);
        }

        /// Activates a mine with the corresponding fuse.
        /// If the threshold is exceeded, the mine will detonate.
        pub fn detonateAfter(fuse: Fuses, err: Error, threshold: usize) void {
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

    // TODO : unit-testing...
}

const std = @import("std");
const builtin = @import("builtin");
const debug = std.debug;
const log = std.log.scoped(.minefield);
