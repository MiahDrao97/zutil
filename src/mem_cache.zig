//! The purpose of a memory cache is to cache values that would otherwise take longer to fetch again.
//! Namely, this would be data from database queries or network calls that'd you rather not make very often or more than once.
//! However, because this memory cache can store data of any type, the memory allocated is fragmented and varied in size.
//! WARN : Only compiles on Zig master

/// All entries are aligned to this max alignment
pub fn MemCache(comptime max_alignment: Alignment) type {
    return struct {
        /// The cache of raw values
        cache: ValueCache,
        /// The cache of values containing the size of each value
        metadata_cache: MetadataCache,
        /// Io group that handles entry expirations
        expiration_group: Io.Group,
        /// Mutex that guards modifications to the cache
        mutex: Io.Mutex,

        pub const Error = Allocator.Error || Io.Cancelable || Io.ConcurrentError;

        const Self = @This();

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

        pub const init: Self = .{
            .cache = .empty,
            .metadata_cache = .empty,
            .expiration_group = .init,
            .mutex = .init,
        };

        /// Creates a new entry.
        /// Keys are not stored in this memory cache, so it's the responsibility of the caller to keep track of keys.
        /// The caller must also know the type/alignment of the stored values since they're agnostically stored as `[*]const u8`.
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
                try self.cache.put(gpa, k, v.ptr);
                errdefer debug.assert(self.cache.remove(k));

                try mine.stepOn(.insert_size_entry);
                try self.metadata_cache.put(gpa, k, @sizeOf(EntryType));
                errdefer debug.assert(self.metadata_cache.remove(k));

                try mine.stepOn(.start_expiration);
                switch (expiration) {
                    .none => {},
                    else => try self.expiration_group.concurrent(io, handleExpiration, .{ self, io, k, expiration }),
                }
            }
        }

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

            @memcpy(v, &entry_bytes);

            const k: StringHash = .fromStr(key);
            // critical section
            {
                try mine.stepOn(.lock_mutex);
                try self.mutex.lock(io);
                defer self.mutex.unlock(io);

                try mine.stepOn(.insert_value_entry);
                try self.cache.put(gpa, k, v.ptr);
                errdefer debug.assert(self.cache.remove(k));

                try mine.stepOn(.insert_size_entry);
                try self.metadata_cache.put(gpa, k, entry_bytes.len);
                errdefer debug.assert(self.metadata_cache.remove(k));

                try mine.stepOn(.start_expiration);
                switch (expiration) {
                    .none => {},
                    else => try self.expiration_group.concurrent(io, handleExpiration, .{ self, io, k, expiration }),
                }
            }
        }

        fn handleExpiration(
            self: *Self,
            io: Io,
            key: StringHash,
            expiration: Io.Timeout,
        ) Io.Cancelable!void {
            switch (expiration) {
                .none => unreachable,
                else => {},
            }

            expiration.sleep(io) catch |err| switch (err) {
                Io.SleepError.Canceled => {
                    // okay, we've hit our timeout: remove the cache entry
                },
                Io.SleepError.UnsupportedClock => @panic("Clock does not support timeout operation."),
                Io.SleepError.Unexpected => {
                    log.warn("Encountered unexpected error when removing expired entry (hash={d}). This entry will still be cleared.", .{key});
                    if (@errorReturnTrace()) |trace| debug.dumpStackTrace(trace);
                },
            };

            // if this returns `error.Canceled`, then the cache is being de-initialized,
            // so it doesn't matter if we remove the entry in the end or not
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);

            // this could have been removed already
            _ = self.cache.remove(key);
            _ = self.metadata_cache.remove(key);
        }

        pub fn getRaw(self: *Self, io: Io, key: []const u8) Io.Cancelable!?[]align(max_alignment.toByteUnits()) const u8 {
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);

            const k: StringHash = .fromStr(key);
            return if (self.cache.get(k)) |entry|
                entry[0..self.metadata_cache.get(k).?]
            else
                null;
        }

        pub fn get(
            self: *Self,
            comptime T: type,
            io: Io,
            key: []const u8,
        ) Io.Cancelable!?*align(max_alignment.toByteUnits()) const T {
            if (comptime max_alignment.compare(.lt, .of(T))) {
                @compileError(fmt.comptimePrint("Entries cannot exceed max alignment {d}. Found request to get entry with alignment {d} ({s})", .{
                    max_alignment.toByteUnits(),
                    @alignOf(T),
                    @typeName(T),
                }));
            }
            if (try self.getRaw(io, key)) |bytes| {
                const item: *align(max_alignment.toByteUnits()) const T = mem.bytesAsValue(T, bytes);
                return item;
            }
            return null;
        }

        pub fn getSlice(
            self: *Self,
            comptime T: type,
            io: Io,
            key: []const u8,
        ) Io.Cancelable!?[]align(max_alignment.toByteUnits()) const T {
            if (comptime max_alignment.compare(.lt, .of(T))) {
                @compileError(fmt.comptimePrint("Entries cannot exceed max alignment {d}. Found request to get slice entry with alignment {d} ([]const {s})", .{
                    max_alignment.toByteUnits(),
                    @alignOf(T),
                    @typeName(T),
                }));
            }
            if (try self.getRaw(io, key)) |bytes| {
                const slice: []align(max_alignment.toByteUnits()) const T = mem.bytesAsSlice(T, bytes);
                return slice;
            }
            return null;
        }

        pub fn remove(self: *Self, io: Io, key: []const u8) Io.Cancelable!bool {
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);

            const k: StringHash = .fromStr(key);
            if (self.cache.remove(k)) {
                debug.assert(self.metadata_cache.remove(k));
                return true;
            }
            debug.assert(self.metadata_cache.get(k) == null);
            return false;
        }

        pub fn clear(self: *Self, io: Io, gpa: Allocator) Io.Cancelable!bool {
            self.expiration_group.cancel(io);
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);

            var iter: ValueCache.Iterator = self.cache.iterator();

            debug.assert(self.cache.count() == self.metadata_cache.count());
            while (iter.next()) |x| {
                const len: u32 = self.metadata_cache.get(x.key_ptr.*).?;
                gpa.free(x.value_ptr.*[0..len]);
            }

            self.cache.clearRetainingCapacity();
            self.metadata_cache.clearRetainingCapacity();
        }

        pub fn deinit(self: *Self, io: Io, gpa: Allocator) void {
            self.expiration_group.cancel(io);
            debug.assert(self.cache.count() == self.metadata_cache.count());
            var iter: ValueCache.Iterator = self.cache.iterator();
            while (iter.next()) |x| {
                const len: u32 = self.metadata_cache.get(x.key_ptr.*).?;
                gpa.free(x.value_ptr.*[0..len]);
            }
            self.cache.deinit(gpa);
            self.metadata_cache.deinit(gpa);
            self.* = undefined;
        }

        test get {
            var mem_cache: MemCache(.@"8") = .init;
            defer mem_cache.deinit(testing.io, testing.allocator);

            const StructValue = struct {
                a: f32,
                b: u16,
            };

            const s: StructValue = .{ .a = 3.14, .b = 5 };
            try mem_cache.newEntry(testing.io, testing.allocator, "struct_val", s, .none);

            const entry: ?*const StructValue = try mem_cache.get(StructValue, testing.io, "struct_val");
            try testing.expect(entry != null);
            try testing.expectEqual(s.a, entry.?.a);
            try testing.expectEqual(s.b, entry.?.b);
        }

        /// Landmines to test with
        const mine = @import("minefield.zig").set(enum {
            alloc,
            copy_key,
            lock_mutex,
            insert_value_entry,
            insert_size_entry,
            start_expiration,
        }, newEntry);
        /// Cache representing the values as raw bytes
        const ValueCache = std.HashMapUnmanaged(
            StringHash,
            [*]align(max_alignment.toByteUnits()) const u8,
            StringHash.Context,
            80,
        );
        /// Cache that contains the size of the stored bytes
        const MetadataCache = std.HashMapUnmanaged(StringHash, u32, StringHash.Context, 80);
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
