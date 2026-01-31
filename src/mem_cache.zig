//! The purpose of a memory cache is to cache values that would otherwise take longer to fetch again.
//! Namely, this would be data from database queries or network calls that'd you rather not make very often or more than once.
//! However, because this memory cache can store data of any type, the memory allocated is fragmented and varied in size.
//! As a result, do not treat this cache as a data-oriented design technique, since the cached entries are almost guaranteed to use RAM.
//! Rather, this is meant to save on network/IO/SYSCALLs that would be more expensive than RAM usage.

/// Aligned to cache line alignment boundary to prevent CPU cache invalidation.
/// It's expected for memory in this cache to be accessed via RAM rather than CPU caches.
pub const MemCache = MemCacheAligned(.fromByteUnits(std.atomic.cache_line));

/// All entries are aligned to this max alignment.
pub fn MemCacheAligned(comptime max_alignment: Alignment) type {
    return struct {
        /// The cache of raw values
        value_cache: ValueCache,
        /// The cache containing the length of each value and its reference count
        metadata_cache: MetadataCache,
        /// Io group that handles entry expirations
        expiration_group: Io.Group,
        /// Mutex that guards reads/writes to the cache
        mutex: Io.Mutex,

        const Self = @This();

        /// Possible errors returned when adding a new entry
        pub const Error = Allocator.Error || Io.Cancelable || Io.ConcurrentError;

        /// Allows one to pull an entry from the cache and have it safely read until `release()` is called on this reader.
        /// Each active reader represents one unit on the entry's reference_count (max active references for an entry is 127).
        pub const SafeReader = struct {
            /// Reference count for the number of references to this particular cache entry
            ref_count: *Atomic(RefCount),
            /// Raw cache entry as bytes
            raw_value: []align(max_alignment.toByteUnits()) const u8,

            /// After this call, the entry is no longer safe to read
            pub fn release(self: SafeReader) void {
                const count_as_int: *Atomic(i8) = @ptrCast(self.ref_count);
                const prev_count: RefCount = @enumFromInt(count_as_int.fetchSub(1, .release));
                // The previous ref count must be some value between 1 and 127.
                // Otherwise, something's broken...
                debug.assert(prev_count.compare(.gt, .zero));
                debug.assert(prev_count.compare(.lte, .max));
            }

            /// Read this entry as `*const T
            pub fn readEntry(self: SafeReader, comptime T: type) *align(max_alignment.toByteUnits()) const T {
                debug.assert(@sizeOf(T) == self.raw_value.len);
                return mem.bytesAsValue(T, self.raw_value);
            }

            /// Read this entry as `[]const T`
            pub fn readSliceEntry(self: SafeReader, comptime T: type) []align(max_alignment.toByteUnits()) const T {
                debug.assert(@rem(self.raw_value.len, @sizeOf(T)) == 0);
                return mem.bytesAsSlice(T, self.raw_value);
            }
        };

        /// Initialize empty cache
        pub const init: Self = .{
            .value_cache = .empty,
            .metadata_cache = .empty,
            .expiration_group = .init,
            .mutex = .init,
        };

        /// Creates a new entry, returning `error.CacheClobber` if an entry with this `key` already exists.
        /// Ensure that `gpa` is thread-safe.
        ///
        /// Keys are not stored in this memory cache, so it's the responsibility of the caller to keep track of keys.
        /// The caller must also know the type of the stored values since they're agnostically stored as `[*]const u8`.
        /// Note that this entry is saved as a shallow copy, which means that pointer members are not dereferenced and saved into the cache.
        /// Use `newSliceEntry()` to cache a slice.
        pub fn newEntry(
            self: *Self,
            io: Io,
            gpa: Allocator,
            key: []const u8,
            entry: anytype,
            expiration: Io.Timeout,
        ) (error{CacheClobber} || Error)!void {
            const v: []align(max_alignment.toByteUnits()) u8 = try createEntryValue(gpa, entry);
            errdefer gpa.free(v);
            try self.putEntry(io, gpa, key, v, expiration, .no_clobber);
        }

        /// Creates or overwrites an entry.
        /// Ensure that `gpa` is thread-safe.
        ///
        /// Keys are not stored in this memory cache, so it's the responsibility of the caller to keep track of keys.
        /// The caller must also know the type of the stored values since they're agnostically stored as `[*]const u8`.
        /// Note that this entry is saved as a shallow copy, which means that pointer members are not dereferenced and saved into the cache.
        ///
        /// Use `overwriteSliceEntry()` to create/overwrite a slice.
        pub fn overwriteEntry(
            self: *Self,
            io: Io,
            gpa: Allocator,
            key: []const u8,
            entry: anytype,
            expiration: Io.Timeout,
        ) Error!void {
            const v: []align(max_alignment.toByteUnits()) u8 = try createEntryValue(gpa, entry);
            errdefer gpa.free(v);
            try self.putEntry(io, gpa, key, v, expiration, .replace);
        }

        /// Reads the cache for an entry matching the `key`.
        /// If none exists, then `entry` will be written in, and a `SafeReader` for that entry will be returned.
        /// Assumes that the duration of `expiration` is longer than the time it takes to lock a reader.
        ///
        /// Keys are not stored in this memory cache, so it's the responsibility of the caller to keep track of keys.
        /// Note that this entry is saved as a shallow copy, which means that pointer members are not dereferenced and saved into the cache.
        ///
        /// Use `getOrPutSliceEntry()` for slices.
        pub fn getOrPutEntry(
            self: *Self,
            io: Io,
            gpa: Allocator,
            key: []const u8,
            expiration: Io.Timeout,
            createEntryFn: anytype,
            args: ArgsTuple(@TypeOf(createEntryFn)),
        ) (ErrorType(@TypeOf(createEntryFn)) || Error || error{TooManyOpenReaders})!SafeReader {
            if (try self.lockReader(io, key)) |reader| {
                return reader;
            }

            const call = struct {
                fn call(a: ArgsTuple(@TypeOf(createEntryFn))) ErrorType(@TypeOf(createEntryFn))!ReturnType(@TypeOf(createEntryFn)) {
                    return @call(.auto, createEntryFn, a);
                }
            }.call;

            const v: []align(max_alignment.toByteUnits()) u8 = try createEntryValue(gpa, try call(args));
            errdefer gpa.free(v);
            self.putEntry(io, gpa, key, v, expiration, .no_clobber) catch |err| switch (err) {
                // shouldn't be possible, but if it's better to crash and investigate than pretend everything's fine
                error.CacheClobber => unreachable,
                else => |e| return e,
            };

            return (try self.lockReader(io, key)).?;
        }

        /// Creates a new slice entry, returning `error.CacheClobber` if an entry with this `key` already exists.
        /// Ensure that `gpa` is thread-safe.
        pub fn newSliceEntry(
            self: *Self,
            comptime T: type,
            io: Io,
            gpa: Allocator,
            key: []const u8,
            entry: []const T,
            expiration: Io.Timeout,
        ) (error{CacheClobber} || Error)!void {
            const v: []align(max_alignment.toByteUnits()) u8 = try allocSliceEntryValue(T, gpa, entry);
            errdefer gpa.free(v);
            try self.putEntry(io, gpa, key, v, expiration, .no_clobber);
        }

        /// Creates or overwrites a slice entry.
        /// Ensure that `gpa` is thread-safe.
        pub fn overwriteSliceEntry(
            self: *Self,
            comptime T: type,
            io: Io,
            gpa: Allocator,
            key: []const u8,
            entry: []const T,
            expiration: Io.Timeout,
        ) Error!void {
            const v: []align(max_alignment.toByteUnits()) u8 = try allocSliceEntryValue(T, gpa, entry);
            errdefer gpa.free(v);
            try self.putEntry(io, gpa, key, v, expiration, .replace);
        }

        /// Reads the cache for an entry matching the `key`.
        /// If none exists, then `entry` will be written in, and a `SafeReader` for that entry will be returned.
        /// Assumes that the duration of `expiration` is longer than the time it takes to lock a reader.
        pub fn getOrPutSliceEntry(
            self: *Self,
            io: Io,
            gpa: Allocator,
            key: []const u8,
            expiration: Io.Timeout,
            createEntryFn: anytype,
            args: ArgsTuple(@TypeOf(createEntryFn)),
        ) (ErrorType(@TypeOf(createEntryFn)) || Error || error{TooManyOpenReaders})!SafeReader {
            const SliceType = switch (@typeInfo(@typeInfo(@TypeOf(createEntryFn)).@"fn".return_type.?)) {
                .error_union => |e| switch (@typeInfo(e.payload)) {
                    .pointer => |p| switch (p.size) {
                        .slice => p.child,
                        else => @compileError("Expected `createEntryFn` to have a return type coercible to `TError![]const T`"),
                    },
                    else => @compileError("Expected `createEntryFn` to have a return type coercible to `TError![]const T`"),
                },
                .pointer => |p| switch (p.size) {
                    .slice => p.child,
                    else => @compileError("Expected `createEntryFn` to have a return type coercible to `TError![]const T`"),
                },
                else => @compileError("Expected `createEntryFn` to have a return type coercible to `TError![]const T`"),
            };
            const call = struct {
                fn call(a: ArgsTuple(@TypeOf(createEntryFn))) ErrorType(@TypeOf(createEntryFn))!ReturnType(@TypeOf(createEntryFn)) {
                    return @call(.auto, createEntryFn, a);
                }
            }.call;

            if (try self.lockReader(io, key)) |reader| {
                return reader;
            }
            const v: []align(max_alignment.toByteUnits()) u8 = try allocSliceEntryValue(SliceType, gpa, try call(args));
            errdefer gpa.free(v);
            self.putEntry(io, gpa, key, v, expiration, .no_clobber) catch |err| switch (err) {
                // shouldn't be possible, but if it's better to crash and investigate than pretend everything's fine
                error.CacheClobber => unreachable,
                else => |e| return e,
            };

            return (try self.lockReader(io, key)).?;
        }

        fn createEntryValue(gpa: Allocator, entry: anytype) Allocator.Error![]align(max_alignment.toByteUnits()) u8 {
            const EntryType = @TypeOf(entry);
            if (comptime max_alignment.compare(.lt, .of(EntryType))) {
                @compileError(fmt.comptimePrint("Max alignment is {d}, but alignment of slice entry was {d} ([]const {s}).", .{
                    max_alignment.toByteUnits(),
                    @alignOf(EntryType),
                    @typeName(EntryType),
                }));
            }
            const entry_bytes: [@sizeOf(EntryType)]u8 = mem.toBytes(entry);

            try mine.stepOnSubset(.alloc, Allocator.Error);
            const v: []align(max_alignment.toByteUnits()) u8 = try gpa.alignedAlloc(u8, max_alignment, entry_bytes.len);
            @memcpy(v, &entry_bytes);
            log.debug("Created new entry {*}, len {d} with Allocator impl {*}", .{ v.ptr, v.len, gpa.ptr });

            return v;
        }

        fn allocSliceEntryValue(comptime T: type, gpa: Allocator, entry: []const T) Allocator.Error![]align(max_alignment.toByteUnits()) u8 {
            if (comptime max_alignment.compare(.lt, .of(T))) {
                @compileError(fmt.comptimePrint("Max alignment is {d}, but alignment of slice entry was {d} ([]const {s}).", .{
                    max_alignment.toByteUnits(),
                    @alignOf(T),
                    @typeName(T),
                }));
            }
            const entry_bytes: []align(@alignOf(T)) const u8 = mem.sliceAsBytes(entry);

            try mine.stepOnSubset(.alloc, Allocator.Error);
            const v: []align(max_alignment.toByteUnits()) u8 = try gpa.alignedAlloc(u8, max_alignment, entry_bytes.len);
            @memcpy(v, entry_bytes);
            log.debug("Created new entry {*}, len {d} with Allocator impl {*}", .{ v.ptr, v.len, gpa.ptr });

            return v;
        }

        fn putEntry(
            self: *MemCache,
            io: Io,
            gpa: Allocator,
            key: []const u8,
            v: []align(max_alignment.toByteUnits()) u8,
            expiration: Io.Timeout,
            comptime put_behavior: PutBehavior,
        ) switch (put_behavior) {
            .replace => Error,
            .no_clobber => error{CacheClobber} || Error,
        }!void {
            const k: StringHash = .fromStr(key);

            // critical section
            {
                try mine.stepOn(.lock_mutex);
                try self.mutex.lock(io);
                defer self.mutex.unlock(io);

                try mine.stepOn(.insert_value_entry);
                const value_gop: ValueCache.GetOrPutResult = try self.value_cache.getOrPut(gpa, k);
                if (value_gop.found_existing) switch (comptime put_behavior) {
                    .no_clobber => return error.CacheClobber,
                    .replace => {
                        const metadata: *Metadata = self.metadata_cache.getPtr(k).?;
                        while (!try metadata.safeSwap(io)) {
                            // spin until we can safely swap
                        }
                        // free the previous value
                        gpa.free(value_gop.value_ptr.*[0..metadata.len]);
                        // replace...
                        value_gop.value_ptr.* = v.ptr;
                        metadata.len = @intCast(v.len);
                        // let other threads know that this can be safely read
                        metadata.ref_count.store(.zero, .release);
                    }
                } else {
                    value_gop.value_ptr.* = v.ptr;
                    errdefer debug.assert(self.value_cache.remove(k));

                    try mine.stepOn(.insert_size_entry);
                    try self.metadata_cache.putNoClobber(gpa, k, .init(@intCast(v.len)));
                }
            }
            errdefer {
                debug.assert(self.value_cache.remove(k));
                debug.assert(self.metadata_cache.remove(k));
            }

            try mine.stepOn(.start_expiration);
            switch (expiration) {
                .none => {},
                else => try self.expiration_group.concurrent(io, handleExpiration, .{ self, io, gpa, key, expiration }),
            }
        }

        /// Waits for the expiration to complete before removing the entries and freeing related memory
        fn handleExpiration(
            self: *Self,
            io: Io,
            gpa: Allocator,
            key: []const u8,
            expiration: Io.Timeout,
        ) Io.Cancelable!void {
            debug.assert(expiration != .none);

            expiration.sleep(io) catch |err| switch (err) {
                // okay, we've received a cancellation request, which means we're probably clearing the cache or de-initializing
                Io.SleepError.Canceled => |canceled| return canceled,
                Io.SleepError.UnsupportedClock => @panic("Clock does not support timeout operation."),
                Io.SleepError.Unexpected => {
                    log.warn("Encountered unexpected error when removing expired entry `{s}`. This entry will still be cleared.", .{key});
                    if (@errorReturnTrace()) |trace| debug.dumpStackTrace(trace);
                    // I guess we keep going?
                },
            };

            // this could have been removed before the expiration is reached
            _ = try self.remove(io, gpa, key);
        }

        /// Lock an entry, producing a `SafeReader` that repesents an active read on the entry.
        /// Until the `SafeReader` is released, this entry is safe to read.
        /// Returns null if no entry exists with this key.
        /// Returns `error.TooManyOpenReaders` if the ref count would exceed 127.
        ///
        /// WARN : If the caller fails to call `release()` on the reader, that may produce a deadlock or segmentation fault later in the program.
        pub fn lockReader(self: *Self, io: Io, key: []const u8) (error{TooManyOpenReaders} || Io.Cancelable)!?SafeReader {
            const k: StringHash = .fromStr(key);

            var metadata: ?*Metadata = null;
            {
                try self.mutex.lock(io);
                defer self.mutex.unlock(io);

                metadata = self.metadata_cache.getPtr(k);
            }

            log.debug("Metadata for key {x} was {s}.", .{ k, if (metadata == null) "found" else "not found" });
            if (metadata) |m| switch (try m.safeRead(io)) {
                .safe => return .{
                    .raw_value = self.value_cache.get(k).?[0..m.len],
                    .ref_count = &m.ref_count,
                },
                .swapping => while (switch (try m.safeRead(io)) {
                    .swapping => true, // wait for swap operation to complete
                    .safe => return .{
                        .raw_value = self.value_cache.get(k).?[0..m.len],
                        .ref_count = &m.ref_count,
                    },
                    .destroying => return null,
                }) {},
                .destroying => {}, // welp, this entry is currently being destroyed
            };
            return null;
        }

        /// Call this function instead of `lockReader()` so you don't have to handle `error.TooManyOpenReaders`.
        /// In the event that the max number of readers are open, will simply wait until the next reader is released.
        /// Until the resulting `SafeReader` is released, this entry is safe to read.
        /// Returns null if no entry exists with this key.
        ///
        /// WARN : If the caller fails to call `release()` on the reader, that may produce a deadlock or segmentation fault later in the program.
        pub fn waitForReaderLock(self: *Self, io: Io, key: []const u8) Io.Cancelable!?SafeReader {
            while (true) {
                if (self.lockReader(io, key) catch |err| switch (err) {
                    Io.Cancelable.Canceled => |canceled| return canceled,
                    error.TooManyOpenReaders => continue,
                }) |reader| {
                    return reader;
                } else return null;
            }
        }

        /// Remove a cache entry, freeing the cached value in the process.
        pub fn remove(self: *Self, io: Io, gpa: Allocator, key: []const u8) Io.Cancelable!bool {
            const k: StringHash = .fromStr(key);

            try self.mutex.lock(io);
            defer self.mutex.unlock(io);

            if (self.metadata_cache.getPtr(k)) |m| {
                while (!try m.safeDestroy(io)) {
                    // spin until ref count reaches 0...
                }

                const entry: [*]align(max_alignment.toByteUnits()) const u8 = self.value_cache.fetchRemove(k).?.value;
                log.debug("Freeing entry {*}, len {d} with Allocator impl {*}", .{ entry, m.len, gpa.ptr });
                gpa.free(entry[0..m.len]);
                debug.assert(self.metadata_cache.remove(k));
                return true;
            }
            return false;
        }

        /// Clear all entries from the cache, freeing the memory created for the cached values.
        /// NOTE : This method is thread-safe, but `deinit()` is not,
        /// so you may want to call this at the end of your application loop/execution scope.
        pub fn clear(self: *Self, io: Io, gpa: Allocator) Io.Cancelable!void {
            self.expiration_group.cancel(io);

            debug.assert(self.value_cache.count() == self.metadata_cache.count());

            try self.mutex.lock(io);
            defer self.mutex.unlock(io);

            var iter: ValueCache.Iterator = self.value_cache.iterator();
            while (iter.next()) |entry| {
                const metadata: *Metadata = self.metadata_cache.getPtr(entry.key_ptr.*).?;
                while (!try metadata.safeDestroy(io)) {
                    // spin until ref count reaches 0...
                }
                gpa.free(entry.value_ptr.*[0..metadata.len]);
            }

            self.value_cache.clearRetainingCapacity();
            self.metadata_cache.clearRetainingCapacity();
        }

        /// Dumps the contents of the cache.
        /// NOT thread-safe, but this method needs to be public so that `Io.Writer` can leverage the `{f}` specifier in `print()`.
        pub fn format(self: *const Self, writer: *Io.Writer) Io.Writer.Error!void {
            var value_iter: ValueCache.Iterator = self.value_cache.iterator();
            try writer.writeAll("Values:\n");
            while (value_iter.next()) |val| {
                try writer.print("{{ key = {x}, value = {*} }} ", .{ val.key_ptr.*, val.value_ptr.* });
            }
            var metadata_iter: MetadataCache.Iterator = self.metadata_cache.iterator();
            try writer.writeAll("\nMetadata:\n");
            while (metadata_iter.next()) |val| {
                try writer.print("{{ key = {x}, value = {f} }} ", .{ val.key_ptr.*, val.value_ptr.* });
            }
            try writer.writeAll("\n\n");
        }

        /// Dumps the contents of the mem cache to a writer in a thread-safe way.
        pub fn threadsafeDump(self: *Self, io: Io, writer: *Io.Writer) (Io.Writer.Error || Io.Cancelable)!void {
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);

            try self.format(writer);
        }

        /// Deinitialize the memory cache, freeing all entries.
        /// WARN : This method is not thread-safe.
        /// It's simply meant for freeing memory on application shutdown (hopefully by then, all readers have been released).
        /// In order to avoid potential seg faults because of other threads waiting on the mutex or ref counts,
        /// call `clear()` at the end of your application's run loop/execution scope.
        pub fn deinit(self: *Self, io: Io, gpa: Allocator) void {
            self.expiration_group.cancel(io);

            debug.assert(self.value_cache.count() == self.metadata_cache.count());
            var iter: ValueCache.Iterator = self.value_cache.iterator();
            while (iter.next()) |entry| {
                const len: u32 = self.metadata_cache.get(entry.key_ptr.*).?.len;
                gpa.free(entry.value_ptr.*[0..len]);
            }
            self.value_cache.deinit(gpa);
            self.metadata_cache.deinit(gpa);
            self.* = undefined;
        }

        /// Landmines to test with
        const mine = @import("minefield.zig").set(enum {
            alloc,
            lock_mutex,
            insert_value_entry,
            insert_size_entry,
            start_expiration,
        }, Error);

        /// Metadata on a cache entry, containg the length of the entry and its reference count
        const Metadata = struct {
            /// Length of the cache entry
            len: u32,
            /// Number of references reading this cache entry
            ref_count: Atomic(RefCount),

            fn init(len: u32) Metadata {
                return .{ .len = len, .ref_count = .init(.zero) };
            }

            fn safeSwap(self: *Metadata, io: Io) Io.Cancelable!bool {
                try io.checkCancel();
                var safe: bool = true;
                if (self.ref_count.cmpxchgWeak(.zero, .swapping, .acq_rel, .monotonic)) |count| {
                    log.debug("{*} is {d}. Not yet safe to swap value.", .{ &self.ref_count, count });
                    safe = false;
                }
                return safe;
            }

            fn safeDestroy(self: *Metadata, io: Io) Io.Cancelable!bool {
                try io.checkCancel();
                var safe: bool = true;
                if (self.ref_count.cmpxchgWeak(.zero, .destroying, .acq_rel, .monotonic)) |count| {
                    log.debug("{*} is {d}. Not yet safe to destroy value.", .{ &self.ref_count, count });
                    safe = false;
                }
                return safe;
            }

            fn safeRead(self: *Metadata, io: Io) (error{TooManyOpenReaders} || Io.Cancelable)!enum { safe, swapping, destroying } {
                var refs: RefCount = self.ref_count.load(.monotonic);
                switch (refs) {
                    .destroying => return .destroying,
                    .max => return error.TooManyOpenReaders,
                    else => |x| if (x.compare(.lt, .zero)) return .swapping, // assuming all other negative values are a swap
                }

                while (self.ref_count.cmpxchgWeak(refs, refs.plusOne(), .acquire, .monotonic)) |count| : (refs = count) {
                    log.debug("{*} is {d}. May not be safe to read.", .{ &self.ref_count, count });
                    switch (count) {
                        .destroying => return .destroying,
                        .max => return error.TooManyOpenReaders,
                        else => |x| if (x.compare(.lt, .zero)) return .swapping,
                    }
                    try io.checkCancel();
                }
                return .safe;
            }

            pub fn format(self: *const Metadata, writer: *Io.Writer) Io.Writer.Error!void {
                try writer.print("{{ .len = {d}, .ref_count = {d} }}", .{ self.len, self.ref_count.load(.monotonic) });
            }
        };

        /// Cache representing the values as raw bytes
        const ValueCache = std.HashMapUnmanaged(
            StringHash,
            [*]align(max_alignment.toByteUnits()) u8,
            StringHash.Context,
            80,
        );

        /// Cache that contains the size of the stored bytes
        const MetadataCache = std.HashMapUnmanaged(StringHash, Metadata, StringHash.Context, 80);

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

        /// Used to count references on an entry
        const RefCount = enum(i8) {
            swapping = -2,
            destroying = -1,
            zero = 0,
            one = 1,
            max = 127,
            _,

            fn compare(lh: RefCount, op: std.math.CompareOperator, rh: RefCount) bool {
                const lh_int: i8 = @intFromEnum(lh);
                const rh_int: i8 = @intFromEnum(rh);

                return switch (op) {
                    .lt => lh_int < rh_int,
                    .lte => lh_int <= rh_int,
                    .eq => lh_int == rh_int,
                    .gte => lh_int >= rh_int,
                    .gt => lh_int > rh_int,
                    .neq => lh_int != rh_int,
                };
            }

            fn plusOne(count: RefCount) RefCount {
                return @enumFromInt(@intFromEnum(count) + 1);
            }

            fn minusOne(count: RefCount) RefCount {
                return @enumFromInt(@intFromEnum(count) - 1);
            }
        };

        /// Determines behavior when a key already exists
        const PutBehavior = enum {
            /// No clobbering allowed
            no_clobber,
            /// Replace a previous entry, if it exists
            replace,
        };

        test lockReader {
            var mem_cache: MemCache = .init;
            defer mem_cache.deinit(testing.io, testing.allocator);

            const StructValue = struct {
                a: f32,
                b: u16,
            };

            const s: StructValue = .{ .a = 3.14, .b = 5 };
            try mem_cache.newEntry(testing.io, testing.allocator, "struct_val", s, .none);

            if (try mem_cache.lockReader(testing.io, "struct_val")) |reader| {
                try testing.expectEqual(.one, reader.ref_count.raw); // normally this should be accessed atomically, but we're in a test

                const entry: *const StructValue = reader.readEntry(StructValue);
                try testing.expectEqual(s.a, entry.a);
                try testing.expectEqual(s.b, entry.b);

                reader.release(); // normally, you'd want to call this in a defer at the top of your scope
                try testing.expectEqual(.zero, reader.ref_count.raw); // normally this should be accessed atomically, but we're in a test
            } else return error.NoEntry;

            const num: u32 = 90;
            try testing.expectError(
                error.CacheClobber,
                mem_cache.newEntry(testing.io, testing.allocator, "struct_val", num, .none),
            );
            try testing.expectError(
                error.CacheClobber,
                mem_cache.newSliceEntry(u8, testing.io, testing.allocator, "struct_val", "oh my", .none),
            );

            const arr: [3]u32 = .{ 1, 2, 3 };
            try mem_cache.newSliceEntry(u32, testing.io, testing.allocator, "slice", &arr, .none);
            if (try mem_cache.lockReader(testing.io, "slice")) |reader| {
                try testing.expectEqual(.one, reader.ref_count.raw); // normally this should be accessed atomically, but we're in a test

                const entry: []const u32 = reader.readSliceEntry(u32);
                try testing.expectEqualSlices(u32, &arr, entry);

                reader.release(); // normally, you'd want to call this in a defer at the top of your scope
                try testing.expectEqual(.zero, reader.ref_count.raw); // normally this should be accessed atomically, but we're in a test
            } else return error.NoEntry;

            try testing.expectError(
                error.CacheClobber,
                mem_cache.newEntry(testing.io, testing.allocator, "slice", num, .none),
            );
            try testing.expectError(
                error.CacheClobber,
                mem_cache.newSliceEntry(u8, testing.io, testing.allocator, "slice", "oh my", .none),
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
                    .clock = .awake,
                },
            };

            try mem_cache.newEntry(testing.io, testing.allocator, "struct_val", s, expiration);

            if (try mem_cache.lockReader(testing.io, "struct_val")) |reader| {
                try testing.expectEqual(.one, reader.ref_count.raw); // normally this should be accessed atomically, but we're in a test
                reader.release();
                try testing.expectEqual(.zero, reader.ref_count.raw); // normally this should be accessed atomically, but we're in a test
            } else return error.NoEntry;
            try testing.io.sleep(.fromMilliseconds(20), .awake); // give this a good buffer of time to let this expire (flaky test if sleep time is too close to expiration time)

            if (try mem_cache.lockReader(testing.io, "struct_val")) |_| return error.ExpectedNoEntry;
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
            try testing.expectEqual(0, mem_cache.metadata_cache.count());

            mine.detonateOn(.lock_mutex, Io.Cancelable.Canceled);
            try testing.expectError(
                Io.Cancelable.Canceled,
                mem_cache.newEntry(testing.io, testing.allocator, "struct_value", s, .none),
            );
            try mine.cleanup(.reset);
            try testing.expectEqual(0, mem_cache.value_cache.count());
            try testing.expectEqual(0, mem_cache.metadata_cache.count());

            mine.detonateOn(.insert_value_entry, Allocator.Error.OutOfMemory);
            try testing.expectError(
                Allocator.Error.OutOfMemory,
                mem_cache.newEntry(testing.io, testing.allocator, "struct_value", s, .none),
            );
            try mine.cleanup(.reset);
            try testing.expectEqual(0, mem_cache.value_cache.count());
            try testing.expectEqual(0, mem_cache.metadata_cache.count());

            mine.detonateOn(.insert_size_entry, Allocator.Error.OutOfMemory);
            try testing.expectError(
                Allocator.Error.OutOfMemory,
                mem_cache.newEntry(testing.io, testing.allocator, "struct_value", s, .none),
            );
            try mine.cleanup(.reset);
            try testing.expectEqual(0, mem_cache.value_cache.count());
            try testing.expectEqual(0, mem_cache.metadata_cache.count());

            mine.detonateOn(.start_expiration, Io.Cancelable.Canceled);
            try testing.expectError(
                Io.Cancelable.Canceled,
                mem_cache.newEntry(testing.io, testing.allocator, "struct_value", s, .none),
            );
            try mine.cleanup(.reset);
            try testing.expectEqual(0, mem_cache.value_cache.count());
            try testing.expectEqual(0, mem_cache.metadata_cache.count());
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
            try testing.expectEqual(0, mem_cache.metadata_cache.count());

            mine.detonateOn(.lock_mutex, Io.Cancelable.Canceled);
            try testing.expectError(
                Io.Cancelable.Canceled,
                mem_cache.newEntry(testing.io, testing.allocator, "my_slice", &arr, .none),
            );
            try mine.cleanup(.reset);
            try testing.expectEqual(0, mem_cache.value_cache.count());
            try testing.expectEqual(0, mem_cache.metadata_cache.count());

            mine.detonateOn(.insert_value_entry, Allocator.Error.OutOfMemory);
            try testing.expectError(
                Allocator.Error.OutOfMemory,
                mem_cache.newSliceEntry(u32, testing.io, testing.allocator, "my_slice", &arr, .none),
            );
            try mine.cleanup(.reset);
            try testing.expectEqual(0, mem_cache.value_cache.count());
            try testing.expectEqual(0, mem_cache.metadata_cache.count());

            mine.detonateOn(.insert_size_entry, Allocator.Error.OutOfMemory);
            try testing.expectError(
                Allocator.Error.OutOfMemory,
                mem_cache.newSliceEntry(u32, testing.io, testing.allocator, "my_slice", &arr, .none),
            );
            try mine.cleanup(.reset);
            try testing.expectEqual(0, mem_cache.value_cache.count());
            try testing.expectEqual(0, mem_cache.metadata_cache.count());

            mine.detonateOn(.start_expiration, Io.Cancelable.Canceled);
            try testing.expectError(
                Io.Cancelable.Canceled,
                mem_cache.newSliceEntry(u32, testing.io, testing.allocator, "my_slice", &arr, .none),
            );
            try mine.cleanup(.reset);
            try testing.expectEqual(0, mem_cache.value_cache.count());
            try testing.expectEqual(0, mem_cache.metadata_cache.count());
        }

        test remove {
            var mem_cache: MemCache = .init;
            defer mem_cache.deinit(testing.io, testing.allocator);

            const arr: [3]u32 = .{ 1, 2, 3 };
            try mem_cache.newSliceEntry(u32, testing.io, testing.allocator, "my_slice", &arr, .none);
            if (try mem_cache.lockReader(testing.io, "my_slice")) |reader|
                reader.release()
            else
                return error.NoEntry;

            try testing.expect(try mem_cache.remove(testing.io, testing.allocator, "my_slice"));
            if (try mem_cache.lockReader(testing.io, "my_slice")) |_| return error.ExpectedNoEntry;
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
            try mem_cache.newEntry(testing.io, testing.allocator, "struct_val", s, .none);

            if (try mem_cache.lockReader(testing.io, "my_slice")) |reader|
                reader.release()
            else
                return error.NoEntry;
            if (try mem_cache.lockReader(testing.io, "struct_val")) |reader|
                reader.release()
            else
                return error.NoEntry;

            try mem_cache.clear(testing.io, testing.allocator);

            if (try mem_cache.lockReader(testing.io, "my_slice")) |_| return error.ExpectedNoEntry;
            if (try mem_cache.lockReader(testing.io, "struct_val")) |_| return error.ExpectedNoEntry;

            const expiration: Io.Timeout = .{
                .duration = .{
                    .raw = .fromMilliseconds(5),
                    .clock = .awake,
                },
            };
            // re-add with expiration
            try mem_cache.newSliceEntry(u32, testing.io, testing.allocator, "my_slice", &arr, expiration);
            try mem_cache.newEntry(testing.io, testing.allocator, "struct_value", s, expiration);

            // clear before expiration, which should cancel the expiration tasks
            try mem_cache.clear(testing.io, testing.allocator);

            if (try mem_cache.lockReader(testing.io, "my_slice")) |_| return error.ExpectedNoEntry;
            if (try mem_cache.lockReader(testing.io, "struct_val")) |_| return error.ExpectedNoEntry;

            // re-add AGAIN... to make sure we can cancel again and free everything as expected
            try mem_cache.newSliceEntry(u32, testing.io, testing.allocator, "my_slice", &arr, expiration);
            try mem_cache.newEntry(testing.io, testing.allocator, "struct_value", s, expiration);
        }

        test overwriteEntry {
            var mem_cache: MemCache = .init;
            defer mem_cache.deinit(testing.io, testing.allocator);

            const num: i32 = 64;
            const num2: i32 = -72;

            try mem_cache.overwriteEntry(testing.io, testing.allocator, "my_entry", num, .none);
            try mem_cache.overwriteEntry(testing.io, testing.allocator, "my_entry", num2, .none);

            if (try mem_cache.lockReader(testing.io, "my_entry")) |reader| {
                defer reader.release();

                try testing.expectEqual(num2, reader.readEntry(i32).*);
            }
        }

        test overwriteSliceEntry {
            var mem_cache: MemCache = .init;
            defer mem_cache.deinit(testing.io, testing.allocator);

            const slice1: []const u8 = "asdf";
            const slice2: []const u8 = "blarf";

            try mem_cache.overwriteSliceEntry(u8, testing.io, testing.allocator, "my_slice", slice1, .none);
            try mem_cache.overwriteSliceEntry(u8, testing.io, testing.allocator, "my_slice", slice2, .none);

            if (try mem_cache.lockReader(testing.io, "my_slice")) |reader| {
                defer reader.release();

                try testing.expectEqualStrings(slice2, reader.readSliceEntry(u8));
            }
        }

        test "muliple removes" {
            debug.assert(!builtin.single_threaded);

            var mem_cache: MemCache = .init;
            defer mem_cache.deinit(testing.io, testing.allocator);

            const slice: []const u8 = "asdf";
            try mem_cache.overwriteSliceEntry(u8, testing.io, testing.allocator, "my_slice", slice, .none);

            const removeEntry = struct {
                fn removeEntry(start: *Atomic(bool), cache: *MemCache, io: Io, gpa: Allocator, key: []const u8) Io.Cancelable!void {
                    while (!start.load(.monotonic)) {}
                    _ = try cache.remove(io, gpa, key);
                }
            }.removeEntry;

            var start: Atomic(bool) = .init(false);
            var group: Io.Group = .init;
            group.async(testing.io, removeEntry, .{ &start, &mem_cache, testing.io, testing.allocator, "my_slice" });
            group.async(testing.io, removeEntry, .{ &start, &mem_cache, testing.io, testing.allocator, "my_slice" });
            group.async(testing.io, removeEntry, .{ &start, &mem_cache, testing.io, testing.allocator, "my_slice" });

            start.store(true, .release);
            try group.await(testing.io);

            if (try mem_cache.lockReader(testing.io, "my_slice")) |_| return error.ExpectedNoEntry;
        }

        test "read and remove conflict" {
            debug.assert(!builtin.single_threaded);

            var mem_cache: MemCache = .init;
            defer mem_cache.deinit(testing.io, testing.allocator);

            const slice: []const u8 = "asdf";
            try mem_cache.overwriteSliceEntry(u8, testing.io, testing.allocator, "my_slice", slice, .none);

            const removeEntry = struct {
                fn removeEntry(start: *Atomic(bool), cache: *MemCache, io: Io, gpa: Allocator, key: []const u8) Io.Cancelable!void {
                    while (!start.load(.monotonic)) {}
                    _ = try cache.remove(io, gpa, key);
                }
            }.removeEntry;

            const readEntry = struct {
                fn readEntry(start: *Atomic(bool), cache: *MemCache, io: Io, key: []const u8) Io.Cancelable!void {
                    while (!start.load(.monotonic)) {}
                    if (cache.lockReader(io, key) catch |err| switch (err) {
                        Io.Cancelable.Canceled => |canceled| return canceled,
                        error.TooManyOpenReaders => unreachable,
                    }) |reader| {
                        defer reader.release();
                        testing.expectEqualStrings(slice, reader.readSliceEntry(u8)) catch unreachable;
                    }
                }
            }.readEntry;

            var start: Atomic(bool) = .init(false);
            var group: Io.Group = .init;
            group.async(testing.io, readEntry, .{ &start, &mem_cache, testing.io, "my_slice" });
            group.async(testing.io, removeEntry, .{ &start, &mem_cache, testing.io, testing.allocator, "my_slice" });

            start.store(true, .release);
            try group.await(testing.io);

            if (try mem_cache.lockReader(testing.io, "my_slice")) |_| return error.ExpectedNoEntry;

            start.store(false, .release);
            group.async(testing.io, removeEntry, .{ &start, &mem_cache, testing.io, testing.allocator, "my_slice" });
            group.async(testing.io, readEntry, .{ &start, &mem_cache, testing.io, "my_slice" });

            start.store(true, .release);
            try group.await(testing.io);

            if (try mem_cache.lockReader(testing.io, "my_slice")) |_| return error.ExpectedNoEntry;
        }

        test "too many open readers" {
            debug.assert(!builtin.single_threaded);

            var mem_cache: MemCache = .init;
            defer mem_cache.deinit(testing.io, testing.allocator);

            const slice: []const u8 = "asdf";
            try mem_cache.overwriteSliceEntry(u8, testing.io, testing.allocator, "my_slice", slice, .none);

            var readers: [@intFromEnum(RefCount.max)]SafeReader = undefined;

            // in the following blocks of code, ref count should not be accessed like this, but we're in a test ^_^

            var ref_count: RefCount = .zero;
            for (&readers) |*reader| reader.* = lock_reader: {
                if (try mem_cache.lockReader(testing.io, "my_slice")) |r| {
                    ref_count = ref_count.plusOne();
                    try testing.expectEqual(
                        ref_count,
                        mem_cache.metadata_cache.getPtr(StringHash.fromStr("my_slice")).?.ref_count.raw,
                    );
                    break :lock_reader r;
                } else return error.NoEntry;
            };

            try testing.expectEqual(.max, ref_count);
            try testing.expectError(error.TooManyOpenReaders, mem_cache.lockReader(testing.io, "my_slice"));

            // release them all so `clear()` doesn't deadlock
            for (readers) |reader| {
                reader.release();
                ref_count = ref_count.minusOne();
                try testing.expectEqual(
                    ref_count,
                    mem_cache.metadata_cache.getPtr(StringHash.fromStr("my_slice")).?.ref_count.raw,
                );
            }

            try mem_cache.clear(testing.io, testing.allocator);
        }

        test getOrPutEntry {
            var mem_cache: MemCache = .init;
            defer mem_cache.deinit(testing.io, testing.allocator);

            {
                // no error and no args in createEntry()
                const reader: SafeReader = mem_cache.getOrPutEntry(testing.io, testing.allocator, "my_val", .none, struct {
                    fn createEntry() i32 {
                        return 64;
                    }
                }.createEntry, .{}) catch |err| switch (err) {
                    // I have this here to exemplify how to pivot to wait for a lock if there are too many readers open
                    error.TooManyOpenReaders => (try mem_cache.waitForReaderLock(testing.io, "my_val")).?,
                    else => |e| return e,
                };
                defer reader.release();

                try testing.expectEqual(64, reader.readEntry(i32).*);
            }
            {
                var arena: std.heap.ArenaAllocator = .init(testing.allocator);
                defer arena.deinit();
                const reader: SafeReader = try mem_cache.getOrPutEntry(testing.io, testing.allocator, "my_other_val", .none, struct {
                    fn createEntry(a: Allocator) Allocator.Error!*const u32 {
                        // imagine this is some DB query or something...
                        // idk why we have to create a pointer, but just imagine with me
                        const val: *u32 = try a.create(u32);
                        val.* = 25;
                        return val;
                    }
                }.createEntry, .{arena.allocator()});
                defer reader.release();

                // funky edge case here
                try testing.expectEqual(25, reader.readEntry(*const u32).*.*);
            }
        }

        test getOrPutSliceEntry {
            var mem_cache: MemCache = .init;
            defer mem_cache.deinit(testing.io, testing.allocator);

            {
                // no error and no args in createEntry()
                const reader: SafeReader = try mem_cache.getOrPutSliceEntry(testing.io, testing.allocator, "my_val", .none, struct {
                    fn createEntry() []const u8 {
                        return "blarf";
                    }
                }.createEntry, .{});
                defer reader.release();

                try testing.expectEqualStrings("blarf", reader.readSliceEntry(u8));
            }
            {
                var arena: std.heap.ArenaAllocator = .init(testing.allocator);
                defer arena.deinit();

                const reader: SafeReader = try mem_cache.getOrPutSliceEntry(testing.io, testing.allocator, "my_other_val", .none, struct {
                    fn createEntry(a: Allocator) Allocator.Error![]const u8 {
                        return try a.dupe(u8, "whoa");
                    }
                }.createEntry, .{arena.allocator()});
                defer reader.release();

                try testing.expectEqualStrings("whoa", reader.readSliceEntry(u8));
            }
        }

        test waitForReaderLock {
            var mem_cache: MemCache = .init;
            defer mem_cache.deinit(testing.io, testing.allocator);

            const slice: []const u8 = "asdf";
            try mem_cache.overwriteSliceEntry(u8, testing.io, testing.allocator, "my_slice", slice, .none);

            var readers: [@intFromEnum(RefCount.max)]SafeReader = undefined;

            // in the following blocks of code, ref count should not be accessed like this, but we're in a test ^_^

            var ref_count: RefCount = .zero;
            for (&readers) |*reader| reader.* = lock_reader: {
                if (try mem_cache.lockReader(testing.io, "my_slice")) |r| {
                    ref_count = ref_count.plusOne();
                    try testing.expectEqual(
                        ref_count,
                        mem_cache.metadata_cache.getPtr(StringHash.fromStr("my_slice")).?.ref_count.raw,
                    );
                    break :lock_reader r;
                } else return error.NoEntry;
            };

            try testing.expectEqual(.max, ref_count);

            var read_future: Io.Future(Io.Cancelable!?SafeReader) = try testing.io.concurrent(waitForReaderLock, .{ &mem_cache, testing.io, "my_slice" });
            defer _ = read_future.cancel(testing.io) catch {};

            // release the first reader so that we can await our future
            readers[0].release();
            if (try read_future.await(testing.io)) |final_reader| {
                defer {
                    final_reader.release();
                    ref_count = ref_count.minusOne();
                }
                try testing.expectEqual(
                    ref_count,
                    mem_cache.metadata_cache.getPtr(StringHash.fromStr("my_slice")).?.ref_count.raw,
                );
            } else return error.NoEntry;

            // release the rest so `clear()` doesn't deadlock
            for (readers[1..]) |reader| {
                reader.release();
                ref_count = ref_count.minusOne();
                try testing.expectEqual(
                    ref_count,
                    mem_cache.metadata_cache.getPtr(StringHash.fromStr("my_slice")).?.ref_count.raw,
                );
            }

            try mem_cache.clear(testing.io, testing.allocator);
        }
    };
}

const std = @import("std");
const builtin = @import("builtin");
const meta = @import("meta.zig");
const debug = std.debug;
const testing = std.testing;
const mem = std.mem;
const fmt = std.fmt;
const log = std.log.scoped(.MemCache);
const Allocator = mem.Allocator;
const Io = std.Io;
const Alignment = mem.Alignment;
const Atomic = std.atomic.Value;
const ArgsTuple = std.meta.ArgsTuple;
const ErrorType = meta.ErrorType;
const ReturnType = meta.ReturnType;
