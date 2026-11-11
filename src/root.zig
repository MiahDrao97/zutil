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
pub const MemCache = mem_cache.Default;
/// Create a memory cache of any max alignment
pub const MemCacheAligned = mem_cache.Aligned;
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
pub fn InternedByteArrayAligned(comptime alignment: Alignment) type {
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
                @fromBackingInt(@intCast(next))
            else unaligned: {
                const diff: usize = alignment.forward(next) - next;
                try self.inner.appendNTimes(gpa, 0, diff);
                break :unaligned @fromBackingInt(@intCast(self.inner.items.len));
            };
            std.debug.assert(alignment.check(@backingInt(offset)));
            try self.inner.appendSlice(gpa, str);
            try self.inner.append(gpa, 0);
            self.segment_count += 1;
            return offset;
        }

        /// Get a segment.
        /// Each segment is aligned.
        /// Note that if more segments are appended, that may invalidate the returned pointer.
        pub fn get(self: *const Self, index: Index) []align(alignment.toByteUnits()) const u8 {
            return @alignCast(mem.sliceTo(self.inner.items[@backingInt(index)..], 0));
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
    try testing.expectEqual(0, @backingInt(idx));
    idx = try byte_array.append(testing.allocator, "hello");
    try testing.expectEqual(3, @backingInt(idx));

    try testing.expectEqual(2, byte_array.segment_count);

    const hello: []const u8 = byte_array.get(idx);
    try testing.expectEqualStrings("hello", hello);

    idx = try byte_array.append(testing.allocator, "");
    try testing.expectEqual(9, @backingInt(idx));
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
    try testing.expectEqual(0, @backingInt(idx));
    idx = try byte_array.append(testing.allocator, "hi");
    try testing.expectEqual(8, @backingInt(idx));
    idx = try byte_array.append(testing.allocator, "");
    try testing.expectEqual(12, @backingInt(idx));

    var iter: Aligned.Iterator = byte_array.iterator();
    var next_str: []align(4) const u8 = iter.next() orelse return error.ValueNotFound;
    try testing.expectEqualStrings("hello", next_str);

    next_str = iter.next() orelse return error.ValueNotFound;
    try testing.expectEqualStrings("hi", next_str);

    next_str = iter.next() orelse return error.ValueNotFound;
    try testing.expectEqualStrings("", next_str);

    // end
    try testing.expectEqual(null, iter.next());
}

pub fn RegionAllocator(comptime alignment: Alignment) type {
    return struct {
        bytes: [*]align(alignment.toByteUnits()) u8,
        regions: [*]Region,
        free_list: SinglyLinkedList,
        lock: std.atomic.Mutex,
        opts: Opts,

        const RegionAllocatorSelf = @This();

        const log = std.log.scoped(.RegionAllocator);

        pub fn init(self: *RegionAllocatorSelf, gpa: Allocator, opts: Opts) Allocator.Error!void {
            const bytes: []align(alignment.toByteUnits()) u8 = try gpa.alignedAlloc(u8, alignment, opts.totalSize());
            errdefer gpa.free(bytes);

            const regions: []Region = try gpa.alloc(Region, opts.region_count);
            errdefer comptime unreachable;

            for (regions, 0..) |*r, i| r.* = .{
                .start = i * opts.region_size,
                .node = .{ .next = if (i + 1 < regions.len) &regions[i + 1].node else null },
                .owner = self,
            };

            self.* = .{
                .bytes = bytes,
                .regions = regions,
                .free_list = .{ .first = &regions[0].node },
                .lock = .unlocked,
                .opts = opts,
            };
        }

        pub fn deinit(self: *RegionAllocatorSelf, gpa: Allocator) void {
            const slice: []align(alignment.toByteUnits()) u8 = self.bytes[0..self.opts.totalSize()];
            gpa.free(slice);
            gpa.free(self.regions[0..self.opts.region_count]);
        }

        pub fn claimRegion(self: *RegionAllocatorSelf) ?*Region {
            while (!self.lock.tryLock()) {}
            defer self.lock.unlock();

            const node: ?*SinglyLinkedList.Node = self.free_list.popFirst();
            return if (node) |n| found: {
                const region: *Region = @fieldParentPtr("node", n);
                // dissociate this from the chain since it's on its own to start
                region.node.next = null;
                break :found region;
            } else null;
        }

        fn extendRegion(self: *RegionAllocatorSelf, region: *Region) bool {
            std.debug.assert(region.node.next == null);
            return if (self.claimRegion()) |new| extended: {
                region.node.next = &new.node;
                break :extended true;
            } else false;
        }

        pub const Opts = struct {
            region_count: u16,
            region_size: u16,

            fn totalSize(self: Opts) usize {
                return self.region_size * self.region_count;
            }
        };

        pub const Region = struct {
            start: u32,
            node: SinglyLinkedList.Node,
            owner: *RegionAllocatorSelf,
            idx: Atomic(u16),

            const vtable: Allocator.VTable = .{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            };

            pub fn allocator(self: *Region) Allocator {
                return .{
                    .ptr = self,
                    .vtable = &vtable,
                };
            }

            fn nextRegion(self: *Region) ?*Region {
                return if (self.node.next) |n| @fieldParentPtr("node", n) else null;
            }

            /// Regions have a linked list structure where overflow goes to the next region.
            /// Whichever one is at the end is our current region.
            /// Ideally, region size should be large enough so that overflow never happens.
            fn resolve(
                self: *Region,
                pending_addition: usize,
                _alignment: Alignment,
            ) Allocator.Error!@Tuple(&.{ *Region, u16 }) {
                // sanity check
                if (_alignment.toByteUnits() > alignment.toByteUnits()) {
                    std.debug.panic("Object with alignment {d} is too large for the RegionAllocator's alignment of {d}", .{
                        _alignment.toByteUnits(),
                        alignment.toByteUnits(),
                    });
                }
                if (pending_addition > self.owner.opts.region_size) {
                    log.err("Object with size {d} cannot fit in any region. Region size is configured to be {d}.", .{
                        pending_addition,
                        self.owner.opts.region_size,
                    });
                    return error.OutOfMemory;
                }

                var current: *Region = self;
                var idx: u16 = current.idx.load(.acquire);
                var offset: u16 = @intCast(_alignment.forward(idx));
                const len: u16 = current.owner.opts.region_size;
                return while (true) {
                    const new_idx: u16 = @intCast(offset + pending_addition);
                    while (new_idx > len) {
                        if (current.nextRegion()) |n| {
                            // move down the chain
                            current = n;
                            idx = current.idx.load(.acquire);
                            offset = @intCast(_alignment.forward(idx));
                        } else {
                            // ope, we gotta extend our region, which links another region onto this one
                            if (!self.owner.extendRegion(current)) {
                                return error.OutOfMemory;
                            }
                            current = current.nextRegion().?;
                            idx = current.idx.load(.acquire);
                            offset = @intCast(_alignment.forward(idx));
                        }
                    }
                    if (current.idx.cmpxchgWeak(idx, new_idx, .release, .monotonic)) |actual| {
                        // another thread beat us here
                        idx = actual;
                    } else break .{ current, offset };
                };
            }

            fn reset(self: *Region) void {
                var current: ?*Region = self;
                while (current) |region| {
                    region.idx.store(0, .release);
                    current = region.nextRegion();
                }
            }

            fn alloc(ptr: *anyopaque, len: usize, _alignment: Alignment, ret_addr: usize) ?[*]u8 {
                _ = ret_addr;
                const self: *Region = @ptrCast(@alignCast(ptr));
                const resolved: *Region, const offset: u16 = self.resolve(len, _alignment) catch return null;
                const slice: []u8 = self.owner.bytes[resolved.start + offset ..];
                return slice.ptr;
            }

            /// Attempt to expand or shrink memory in place.
            ///
            /// `memory.len` must equal the length requested from the most recent
            /// successful call to `alloc`, `resize`, or `remap`. `alignment` must
            /// equal the same value that was passed as the `alignment` parameter to
            /// the original `alloc` call.
            ///
            /// A result of `true` indicates the resize was successful and the
            /// allocation now has the same address but a size of `new_len`. `false`
            /// indicates the resize could not be completed without moving the
            /// allocation to a different address.
            ///
            /// `new_len` must be greater than zero.
            ///
            /// `ret_addr` is optionally provided as the first return address of the
            /// allocation call stack. If the value is `0` it means no return address
            /// has been provided.
            fn resize(ptr: *anyopaque, memory: []u8, _alignment: Alignment, new_len: usize, ret_addr: usize) bool {
                std.debug.assert(new_len > 0);
                _ = ret_addr;
                _ = _alignment;
                const self: *Region = @ptrCast(@alignCast(ptr));
                // FIXME : Actually, don't resolve here... just get the last region in the chain
                const resolved: *Region, const offset: u16 = self.resolve(0, .@"1") catch return false;
                const addr: usize = @intFromPtr(memory.ptr);
                const next_addr_space: usize = @intFromPtr(resolved.owner.bytes + resolved.start + offset);
                if (next_addr_space - memory.len == addr) {
                    // TODO : cmpxchg loop to adjust the idx of the resolved region or return false
                }
                return false;
            }

            /// Attempt to expand or shrink memory, allowing relocation.
            ///
            /// `memory.len` must equal the length requested from the most recent
            /// successful call to `alloc`, `resize`, or `remap`. `alignment` must
            /// equal the same value that was passed as the `alignment` parameter to
            /// the original `alloc` call.
            ///
            /// A non-`null` return value indicates the resize was successful. The
            /// allocation may have same address, or may have been relocated. In either
            /// case, the allocation now has size of `new_len`. A `null` return value
            /// indicates that the resize would be equivalent to allocating new memory,
            /// copying the bytes from the old memory, and then freeing the old memory.
            /// In such case, it is more efficient for the caller to perform the copy.
            ///
            /// `new_len` must be greater than zero.
            ///
            /// `ret_addr` is optionally provided as the first return address of the
            /// allocation call stack. If the value is `0` it means no return address
            /// has been provided.
            fn remap(ptr: *anyopaque, memory: []u8, _alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
                std.debug.assert(new_len > 0);
                const self: *Region = @ptrCast(@alignCast(ptr));
                _ = self;
                _ = memory;
                _ = _alignment;
                _ = ret_addr;

                return null;
            }

            /// Free and invalidate a region of memory.
            ///
            /// `memory.len` must equal the length requested from the most recent
            /// successful call to `alloc`, `resize`, or `remap`. `alignment` must
            /// equal the same value that was passed as the `alignment` parameter to
            /// the original `alloc` call.
            ///
            /// `ret_addr` is optionally provided as the first return address of the
            /// allocation call stack. If the value is `0` it means no return address
            /// has been provided.
            fn free(ptr: *anyopaque, memory: []u8, _alignment: Alignment, ret_addr: usize) void {
                const self: *Region = @ptrCast(@alignCast(ptr));
                _ = self;
                _ = memory;
                _ = _alignment;
                _ = ret_addr;
            }
        };
    };
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
const Alignment = mem.Alignment;
const SinglyLinkedList = std.SinglyLinkedList;
const Atomic = std.atomic.Value;
