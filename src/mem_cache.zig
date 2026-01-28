//! The purpose of a memory cache is to cache values that would otherwise take longer to fetch again.
//! Namely, this would be data from database queries or network calls that'd you rather not make very often or more than once.
//! However, because this memory cache can store data of any type, the memory allocated is fragmented and varied in size.
//! As a result, do not treat this cache as a data-oriented design technique.
//! Rather, this is meant to save on network/IO/SYSCALLs that would be more expensive than RAM usage.
//! WARN : Only compiles on Zig master

/// Aligned to cache line alignment boundary to prevent CPU cache invalidation.
/// It's expected for memory in this cache to be accessed via RAM rather than CPU caches.
pub const MemCache = MemCacheAligned(.fromByteUnits(std.atomic.cache_line));

/// All entries are aligned to this max alignment.
pub fn MemCacheAligned(comptime max_alignment: Alignment) type {
    return struct {
        /// The cache of raw values
        value_cache: ValueCache,
        /// The cache containing the length of each value
        len_cache: LenCache,
        /// Io group that handles entry expirations
        expiration_group: Io.Group,
        /// Mutex that guards modifications to the cache
        mutex: Io.Mutex,

        /// Possible errors returned when adding a new entry
        pub const Error =
            Allocator.Error ||
            Io.Cancelable ||
            Io.ConcurrentError ||
            error{
                /// This error is returned when a new entry would clobber an existing one
                CacheClobber,
            };

        const Self = @This();

        /// Landmines to test with
        const mine = @import("minefield.zig").set(enum {
            alloc,
            lock_mutex,
            insert_value_entry,
            insert_size_entry,
            start_expiration,
        }, newEntry);

        /// Cache representing the values as raw bytes
        const ValueCache = std.HashMapUnmanaged(
            StringHash,
            [*]align(max_alignment.toByteUnits()) u8,
            StringHash.Context,
            80,
        );

        /// Cache that contains the size of the stored bytes
        const LenCache = std.HashMapUnmanaged(StringHash, u32, StringHash.Context, 80);

        /// Represents a string hash
        const StringHash = enum(u32) {
            _,

            fn fromStr(k: []const u8) StringHash {
                return @enumFromInt(
                    @as(u32, @truncate(std.hash.Wyhash.hash(0, k))),
                );
            }

            const Context = struct {
                pub fn hash(_: Context, k: StringHash) u32 {
                    // this already repesents a hash, so just return the u32 value
                    return @intFromEnum(k);
                }

                pub fn eql(_: Context, a: StringHash, b: StringHash) bool {
                    return a == b;
                }
            };
        };

        /// Initialize empty cache
        pub const init: Self = .{
            .value_cache = .empty,
            .len_cache = .empty,
            .expiration_group = .init,
            .mutex = .init,
        };

        /// Creates a new entry.
        /// Ensure that `gpa` is thread-safe.
        ///
        /// Keys are not stored in this memory cache, so it's the responsibility of the caller to keep track of keys.
        /// The caller must also know the type/alignment of the stored values since they're agnostically stored as `[*]const u8`.
        /// Note that this entry is saved as a shallow copy, which means that pointer members are not dereferenced and saved into the cache.
        /// Use `newSliceEntry()` to cache a slice.
        pub fn newEntry(
            self: *Self,
            io: Io,
            gpa: Allocator,
            key: []const u8,
            entry: anytype,
            expiration: Io.Timeout,
        ) Error!void {
            const EntryType = @TypeOf(entry);
            if (comptime max_alignment.compare(.lt, .of(EntryType))) {
                @compileError(fmt.comptimePrint("Max alignment is {d}, but alignment of entry was {d} ({s}).", .{
                    max_alignment.toByteUnits(),
                    @alignOf(EntryType),
                    @typeName(EntryType),
                }));
            }

            try mine.stepOn(.alloc);
            const v: []align(max_alignment.toByteUnits()) u8 = try gpa.alignedAlloc(u8, max_alignment, @sizeOf(EntryType));
            errdefer gpa.free(v);

            const entry_bytes: [@sizeOf(EntryType)]u8 align(@alignOf(EntryType)) = mem.toBytes(entry);
            @memcpy(v, &entry_bytes);

            const k: StringHash = .fromStr(key);
            // critical section
            {
                try mine.stepOn(.lock_mutex);
                try self.mutex.lock(io);
                defer self.mutex.unlock(io);

                try mine.stepOn(.insert_value_entry);
                const value_gop: ValueCache.GetOrPutResult = try self.value_cache.getOrPut(gpa, k);
                if (value_gop.found_existing) return error.CacheClobber;
                value_gop.value_ptr.* = v.ptr;
                errdefer debug.assert(self.value_cache.remove(k));

                try mine.stepOn(.insert_size_entry);
                try self.len_cache.putNoClobber(gpa, k, @sizeOf(EntryType));
                errdefer debug.assert(self.len_cache.remove(k));

                try mine.stepOn(.start_expiration);
                switch (expiration) {
                    .none => {},
                    else => try self.expiration_group.concurrent(io, handleExpiration, .{ self, io, gpa, k, expiration }),
                }
            }
        }

        /// Save a slice into the memory cache.
        /// Ensure that `gpa` is thread-safe.
        pub fn newSliceEntry(
            self: *Self,
            comptime T: type,
            io: Io,
            gpa: Allocator,
            key: []const u8,
            entry: []const T,
            expiration: Io.Timeout,
        ) Error!void {
            if (comptime max_alignment.compare(.lt, .of(T))) {
                @compileError(fmt.comptimePrint("Max alignment is {d}, but alignment of slice entry was {d} ([]const {s}).", .{
                    max_alignment.toByteUnits(),
                    @alignOf(T),
                    @typeName(T),
                }));
            }
            const entry_bytes: []align(@alignOf(T)) const u8 = mem.sliceAsBytes(entry);

            try mine.stepOn(.alloc);
            const v: []align(max_alignment.toByteUnits()) u8 = try gpa.alignedAlloc(u8, max_alignment, entry_bytes.len);
            errdefer gpa.free(v);

            @memcpy(v, entry_bytes);

            const k: StringHash = .fromStr(key);
            // critical section
            {
                try mine.stepOn(.lock_mutex);
                try self.mutex.lock(io);
                defer self.mutex.unlock(io);

                try mine.stepOn(.insert_value_entry);
                const value_gop: ValueCache.GetOrPutResult = try self.value_cache.getOrPut(gpa, k);
                if (value_gop.found_existing) return error.CacheClobber;
                value_gop.value_ptr.* = v.ptr;
                errdefer debug.assert(self.value_cache.remove(k));

                try mine.stepOn(.insert_size_entry);
                try self.len_cache.putNoClobber(gpa, k, @intCast(entry_bytes.len));
                errdefer debug.assert(self.len_cache.remove(k));

                try mine.stepOn(.start_expiration);
                switch (expiration) {
                    .none => {},
                    else => try self.expiration_group.concurrent(io, handleExpiration, .{ self, io, gpa, k, expiration }),
                }
            }
        }

        /// Waits for the expiration to complete before removing the entries and freeing related memory
        fn handleExpiration(
            self: *Self,
            io: Io,
            gpa: Allocator,
            key: StringHash,
            expiration: Io.Timeout,
        ) Io.Cancelable!void {
            switch (expiration) {
                .none => unreachable,
                else => {},
            }

            expiration.sleep(io) catch |err| switch (err) {
                // okay, we've received a cancellation request, which means we're probably clearing the cache or de-initializing
                Io.SleepError.Canceled => |canceled| return canceled,
                Io.SleepError.UnsupportedClock => @panic("Clock does not support timeout operation."),
                Io.SleepError.Unexpected => {
                    log.warn("Encountered unexpected error when removing expired entry (hash={d}). This entry will still be cleared.", .{key});
                    if (@errorReturnTrace()) |trace| debug.dumpStackTrace(trace);
                    // I guess we keep going?
                },
            };

            // if this returns `error.Canceled`, then the cache is being de-initialized or cleared,
            // so it doesn't matter if we remove the entry in the end or not
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);

            // this could have been removed already
            if (self.value_cache.fetchRemove(key)) |entry| {
                const len: u32 = self.len_cache.fetchRemove(key).?.value;
                gpa.free(entry.value[0..len]);
            } else debug.assert(self.len_cache.get(key) == null);
        }

        /// Get the cache entry as a raw slice of bytes
        pub fn getRaw(self: *Self, io: Io, key: []const u8) Io.Cancelable!?[]align(max_alignment.toByteUnits()) u8 {
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);

            const k: StringHash = .fromStr(key);
            return if (self.value_cache.get(k)) |entry|
                entry[0..self.len_cache.get(k).?]
            else
                null;
        }

        /// Get the cache entry as `*T`
        pub fn get(
            self: *Self,
            comptime T: type,
            io: Io,
            key: []const u8,
        ) Io.Cancelable!?*align(max_alignment.toByteUnits()) T {
            if (comptime max_alignment.compare(.lt, .of(T))) {
                @compileError(fmt.comptimePrint("Entries cannot exceed max alignment {d}. Found request to get entry with alignment {d} ({s})", .{
                    max_alignment.toByteUnits(),
                    @alignOf(T),
                    @typeName(T),
                }));
            }
            if (try self.getRaw(io, key)) |bytes| {
                const item: *align(max_alignment.toByteUnits()) T = mem.bytesAsValue(T, bytes);
                return item;
            }
            return null;
        }

        /// Get the cache entry as `[]T`
        pub fn getSlice(
            self: *Self,
            comptime T: type,
            io: Io,
            key: []const u8,
        ) Io.Cancelable!?[]align(max_alignment.toByteUnits()) T {
            if (comptime max_alignment.compare(.lt, .of(T))) {
                @compileError(fmt.comptimePrint("Entries cannot exceed max alignment {d}. Found request to get slice entry with alignment {d} ([]const {s})", .{
                    max_alignment.toByteUnits(),
                    @alignOf(T),
                    @typeName(T),
                }));
            }
            if (try self.getRaw(io, key)) |bytes| {
                const slice: []align(max_alignment.toByteUnits()) T = mem.bytesAsSlice(T, bytes);
                return slice;
            }
            return null;
        }

        /// Remove a cache entry, freeing the cached value in the process.
        pub fn remove(self: *Self, io: Io, gpa: Allocator, key: []const u8) Io.Cancelable!bool {
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);

            const k: StringHash = .fromStr(key);
            if (self.value_cache.fetchRemove(k)) |entry| {
                const len: u32 = self.len_cache.fetchRemove(k).?.value;
                gpa.free(entry.value[0..len]);
                return true;
            }
            debug.assert(self.len_cache.get(k) == null);
            return false;
        }

        /// Clear all entries from the cache, freeing the memory created for the cached values.
        pub fn clear(self: *Self, io: Io, gpa: Allocator) Io.Cancelable!void {
            self.expiration_group.cancel(io);
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);

            var iter: ValueCache.Iterator = self.value_cache.iterator();

            debug.assert(self.value_cache.count() == self.len_cache.count());
            while (iter.next()) |entry| {
                const len: u32 = self.len_cache.get(entry.key_ptr.*).?;
                gpa.free(entry.value_ptr.*[0..len]);
            }

            self.value_cache.clearRetainingCapacity();
            self.len_cache.clearRetainingCapacity();
        }

        /// Deinitialize the memory cache, freeing all entries.
        /// This method is not thread-safe, while the rest of these methods are.
        pub fn deinit(self: *Self, io: Io, gpa: Allocator) void {
            self.expiration_group.cancel(io);

            debug.assert(self.value_cache.count() == self.len_cache.count());
            var iter: ValueCache.Iterator = self.value_cache.iterator();
            while (iter.next()) |entry| {
                const len: u32 = self.len_cache.get(entry.key_ptr.*).?;
                gpa.free(entry.value_ptr.*[0..len]);
            }
            self.value_cache.deinit(gpa);
            self.len_cache.deinit(gpa);
            self.* = undefined;
        }

        test get {
            var mem_cache: MemCache = .init;
            defer mem_cache.deinit(testing.io, testing.allocator);

            const StructValue = struct {
                a: f32,
                b: u16,
            };

            const s: StructValue = .{ .a = 3.14, .b = 5 };
            try mem_cache.newEntry(testing.io, testing.allocator, "struct_val", s, .none);

            const entry: ?*StructValue = try mem_cache.get(StructValue, testing.io, "struct_val");
            try testing.expect(entry != null);
            try testing.expectEqual(s.a, entry.?.a);
            try testing.expectEqual(s.b, entry.?.b);

            entry.?.b = 2;

            const fetched_again: ?*const StructValue = try mem_cache.get(StructValue, testing.io, "struct_val");
            try testing.expect(fetched_again != null);
            try testing.expectEqual(s.a, fetched_again.?.a);
            try testing.expectEqual(2, fetched_again.?.b);

            const num: u32 = 90;
            try testing.expectError(
                error.CacheClobber,
                mem_cache.newEntry(testing.io, testing.allocator, "struct_val", num, .none),
            );
            try testing.expectError(
                error.CacheClobber,
                mem_cache.newSliceEntry(u8, testing.io, testing.allocator, "struct_val", "oh my", .none),
            );
        }

        test handleExpiration {
            var mem_cache: MemCache = .init;
            defer mem_cache.deinit(testing.io, testing.allocator);

            const StructValue = struct {
                a: f32,
                b: u16,
            };

            const s: StructValue = .{ .a = 3.14, .b = 5 };
            const expiration: Io.Timeout = .{
                .duration = .{
                    .raw = .fromMilliseconds(1),
                    .clock = .real,
                },
            };
            try mem_cache.newEntry(testing.io, testing.allocator, "struct_val", s, expiration);
            try testing.expect(try mem_cache.getRaw(testing.io, "struct_val") != null);
            try testing.io.sleep(.fromMilliseconds(20), .awake); // give this a good buffer of time to let this expire (flaky test if sleep time is too close to expiration time)

            try testing.expect(try mem_cache.getRaw(testing.io, "struct_val") == null);
        }

        test newEntry {
            var mem_cache: MemCache = .init;
            defer mem_cache.deinit(testing.io, testing.allocator);

            const StructValue = struct {
                a: f32,
                b: u16,
            };
            const s: StructValue = .{ .a = 3.14, .b = 5 };

            mine.detonateOn(.alloc, Allocator.Error.OutOfMemory);
            try testing.expectError(
                Allocator.Error.OutOfMemory,
                mem_cache.newEntry(testing.io, testing.allocator, "struct_value", s, .none),
            );
            try mine.cleanup(.reset);
            try testing.expectEqual(0, mem_cache.value_cache.count());
            try testing.expectEqual(0, mem_cache.len_cache.count());

            mine.detonateOn(.lock_mutex, Io.Cancelable.Canceled);
            try testing.expectError(
                Io.Cancelable.Canceled,
                mem_cache.newEntry(testing.io, testing.allocator, "struct_value", s, .none),
            );
            try mine.cleanup(.reset);
            try testing.expectEqual(0, mem_cache.value_cache.count());
            try testing.expectEqual(0, mem_cache.len_cache.count());

            mine.detonateOn(.insert_value_entry, Allocator.Error.OutOfMemory);
            try testing.expectError(
                Allocator.Error.OutOfMemory,
                mem_cache.newEntry(testing.io, testing.allocator, "struct_value", s, .none),
            );
            try mine.cleanup(.reset);
            try testing.expectEqual(0, mem_cache.value_cache.count());
            try testing.expectEqual(0, mem_cache.len_cache.count());

            mine.detonateOn(.insert_size_entry, Allocator.Error.OutOfMemory);
            try testing.expectError(
                Allocator.Error.OutOfMemory,
                mem_cache.newEntry(testing.io, testing.allocator, "struct_value", s, .none),
            );
            try mine.cleanup(.reset);
            try testing.expectEqual(0, mem_cache.value_cache.count());
            try testing.expectEqual(0, mem_cache.len_cache.count());

            mine.detonateOn(.start_expiration, Io.Cancelable.Canceled);
            try testing.expectError(
                Io.Cancelable.Canceled,
                mem_cache.newEntry(testing.io, testing.allocator, "struct_value", s, .none),
            );
            try mine.cleanup(.reset);
            try testing.expectEqual(0, mem_cache.value_cache.count());
            try testing.expectEqual(0, mem_cache.len_cache.count());
        }

        test newSliceEntry {
            var mem_cache: MemCache = .init;
            defer mem_cache.deinit(testing.io, testing.allocator);

            const arr: [3]u32 = .{ 1, 2, 3 };

            mine.detonateOn(.alloc, Allocator.Error.OutOfMemory);
            try testing.expectError(
                Allocator.Error.OutOfMemory,
                mem_cache.newSliceEntry(u32, testing.io, testing.allocator, "my_slice", &arr, .none),
            );
            try mine.cleanup(.reset);
            try testing.expectEqual(0, mem_cache.value_cache.count());
            try testing.expectEqual(0, mem_cache.len_cache.count());

            mine.detonateOn(.lock_mutex, Io.Cancelable.Canceled);
            try testing.expectError(
                Io.Cancelable.Canceled,
                mem_cache.newSliceEntry(u32, testing.io, testing.allocator, "my_slice", &arr, .none),
            );
            try mine.cleanup(.reset);
            try testing.expectEqual(0, mem_cache.value_cache.count());
            try testing.expectEqual(0, mem_cache.len_cache.count());

            mine.detonateOn(.insert_value_entry, Allocator.Error.OutOfMemory);
            try testing.expectError(
                Allocator.Error.OutOfMemory,
                mem_cache.newSliceEntry(u32, testing.io, testing.allocator, "my_slice", &arr, .none),
            );
            try mine.cleanup(.reset);
            try testing.expectEqual(0, mem_cache.value_cache.count());
            try testing.expectEqual(0, mem_cache.len_cache.count());

            mine.detonateOn(.insert_size_entry, Allocator.Error.OutOfMemory);
            try testing.expectError(
                Allocator.Error.OutOfMemory,
                mem_cache.newSliceEntry(u32, testing.io, testing.allocator, "my_slice", &arr, .none),
            );
            try mine.cleanup(.reset);
            try testing.expectEqual(0, mem_cache.value_cache.count());
            try testing.expectEqual(0, mem_cache.len_cache.count());

            mine.detonateOn(.start_expiration, Io.Cancelable.Canceled);
            try testing.expectError(
                Io.Cancelable.Canceled,
                mem_cache.newSliceEntry(u32, testing.io, testing.allocator, "my_slice", &arr, .none),
            );
            try mine.cleanup(.reset);
            try testing.expectEqual(0, mem_cache.value_cache.count());
            try testing.expectEqual(0, mem_cache.len_cache.count());
        }

        test getSlice {
            var mem_cache: MemCache = .init;
            defer mem_cache.deinit(testing.io, testing.allocator);

            const arr: [3]u32 = .{ 1, 2, 3 };
            try mem_cache.newSliceEntry(u32, testing.io, testing.allocator, "my_slice", &arr, .none);

            const entry: ?[]u32 = try mem_cache.getSlice(u32, testing.io, "my_slice");
            try testing.expect(entry != null);
            try testing.expectEqualSlices(u32, &arr, entry.?);

            entry.?[0] = 8;

            const fetched_again: ?[]u32 = try mem_cache.getSlice(u32, testing.io, "my_slice");
            try testing.expect(fetched_again != null);
            try testing.expectEqualSlices(u32, &.{ 8, 2, 3 }, fetched_again.?);

            const num: u32 = 90;
            try testing.expectError(
                error.CacheClobber,
                mem_cache.newEntry(testing.io, testing.allocator, "my_slice", num, .none),
            );
            try testing.expectError(
                error.CacheClobber,
                mem_cache.newSliceEntry(u8, testing.io, testing.allocator, "my_slice", "oh my", .none),
            );
        }

        test remove {
            var mem_cache: MemCache = .init;
            defer mem_cache.deinit(testing.io, testing.allocator);

            const arr: [3]u32 = .{ 1, 2, 3 };
            try mem_cache.newSliceEntry(u32, testing.io, testing.allocator, "my_slice", &arr, .none);
            const entry: ?[]u32 = try mem_cache.getSlice(u32, testing.io, "my_slice");
            try testing.expect(entry != null);

            try testing.expect(try mem_cache.remove(testing.io, testing.allocator, "my_slice"));
            const fetched_again: ?[]u32 = try mem_cache.getSlice(u32, testing.io, "my_slice");
            try testing.expect(fetched_again == null);
        }

        test clear {
            var mem_cache: MemCache = .init;
            defer mem_cache.deinit(testing.io, testing.allocator);

            const StructValue = struct {
                a: f32,
                b: u16,
            };

            const s: StructValue = .{ .a = 3.14, .b = 5 };
            const arr: [3]u32 = .{ 1, 2, 3 };
            try mem_cache.newSliceEntry(u32, testing.io, testing.allocator, "my_slice", &arr, .none);
            try mem_cache.newEntry(testing.io, testing.allocator, "struct_value", s, .none);

            try testing.expect(try mem_cache.getRaw(testing.io, "my_slice") != null);
            try testing.expect(try mem_cache.getRaw(testing.io, "struct_value") != null);

            try mem_cache.clear(testing.io, testing.allocator);

            try testing.expect(try mem_cache.getRaw(testing.io, "my_slice") == null);
            try testing.expect(try mem_cache.getRaw(testing.io, "struct_value") == null);

            const expiration: Io.Timeout = .{
                .duration = .{
                    .raw = .fromMilliseconds(5),
                    .clock = .real,
                },
            };
            // re-add with expiration
            try mem_cache.newSliceEntry(u32, testing.io, testing.allocator, "my_slice", &arr, expiration);
            try mem_cache.newEntry(testing.io, testing.allocator, "struct_value", s, expiration);

            // clear before expiration, which should cancel the expiration tasks
            try mem_cache.clear(testing.io, testing.allocator);

            try testing.expect(try mem_cache.getRaw(testing.io, "my_slice") == null);
            try testing.expect(try mem_cache.getRaw(testing.io, "struct_value") == null);

            // re-add AGAIN... to make sure we can cancel again and free everything as expected
            try mem_cache.newSliceEntry(u32, testing.io, testing.allocator, "my_slice", &arr, expiration);
            try mem_cache.newEntry(testing.io, testing.allocator, "struct_value", s, expiration);
        }
    };
}

const std = @import("std");
const debug = std.debug;
const testing = std.testing;
const mem = std.mem;
const fmt = std.fmt;
const log = std.log.scoped(.MemCache);
const Allocator = mem.Allocator;
const Io = std.Io;
const Alignment = mem.Alignment;
