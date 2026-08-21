//! The purpose of a memory cache is to memoize values that would otherwise take longer to fetch again.
//! Namely, this would be data from database queries or network calls that'd you rather not make very often or more than once.
//! However, because this memory cache can store data of any type, the memory allocated is fragmented and varied in size.
//! As a result, do not treat this cache as a data-oriented design technique, since the cached entries are almost guaranteed to use RAM.
//! Rather, this is meant to save on network/IO/SYSCALLs that would be more expensive than RAM usage.
//! Cache entries cannot exceed `std.math.max(u16)` bytes.
//! Note that all cache entries are shallow copies, so if you need to get around this limitation, just heap-allocate and cache the pointer.

/// Aligned to cache line alignment boundary to prevent CPU cache invalidation.
/// It's expected for memory in this cache to be accessed via RAM rather than CPU caches.
pub const Default = Aligned(.fromByteUnits(std.atomic.cache_line), null);

/// `max_alignment` - All entry values are aligned to this max alignment.
/// `max_entries` - No more than this number of entries will be allowed, and the pool will be pre-allocated when calling `init()`.
pub fn Aligned(comptime max_alignment: Alignment, comptime max_entries: ?usize) type {
    return struct {
        /// All active entries -
        /// Once an entry is tombstoned, it disappears from this map until the last reader is released, which frees the memory.
        active_entries: EntryMap,
        /// For quickly creating instances of `EntryData`
        entry_pool: EntryPool,
        /// RW lock that guards reads/writes to the cache
        lock: Io.RwLock,
        /// For internal memory operations
        allocator: Allocator,
        /// Configurable behavior
        opts: Options,

        const MemCacheSelf = @This();

        /// Note that the MemCache is a managed data structure (i.e. it stores its own allocator).
        /// The reason for this is the complex lifetimes required for reference counting.
        pub fn init(gpa: Allocator, opts: Options) Allocator.Error!MemCacheSelf {
            return .{
                .active_entries = .empty,
                .lock = .init,
                .entry_pool = if (max_entries) |max| try .initCapacity(gpa, max) else .empty,
                .allocator = gpa,
                .opts = opts,
            };
        }

        /// Creates a new entry, returning `error.CacheClobber` if an entry with this `key` already exists.
        ///
        /// Keys are not stored in this memory cache, so it's the responsibility of the caller to keep track of keys.
        /// The caller must also know the type of the stored values since they're agnostically stored as `[*]const u8`.
        /// This means entries are saved as shallow copies, which means that pointer members are not dereferenced and saved into the cache.
        ///
        /// Use `newSliceEntry()` to cache a slice.
        pub fn newEntry(
            self: *MemCacheSelf,
            io: Io,
            key: []const u8,
            entry: anytype,
            expiration: Expiration,
        ) NewEntryError!void {
            comptime checkTypeCompatibility(@TypeOf(entry));

            const v: []align(max_alignment.toByteUnits()) const u8 = try self.createEntryValue(&mem.toBytes(entry));
            errdefer self.allocator.free(v);
            try self.putEntry(io, key, v, expiration, .no_clobber);
        }

        /// Creates or overwrites an entry.
        /// Runs `expiration.cleanup()` on error.
        ///
        /// Keys are not stored in this memory cache, so it's the responsibility of the caller to keep track of keys.
        /// The caller must also know the type of the stored values since they're agnostically stored as `[*]const u8`.
        /// This means entries are saved as shallow copies, which means that pointer members are not dereferenced and saved into the cache.
        ///
        /// Use `overwriteSliceEntry()` to create/overwrite a slice.
        pub fn overwriteEntry(
            self: *MemCacheSelf,
            io: Io,
            key: []const u8,
            entry: anytype,
            expiration: Expiration,
        ) OverwriteEntryError!void {
            comptime checkTypeCompatibility(@TypeOf(entry));

            const v: []align(max_alignment.toByteUnits()) const u8 = try self.createEntryValue(&mem.toBytes(entry));
            errdefer self.allocator.free(v);
            try self.putEntry(io, key, v, expiration, .replace);
        }

        /// First checks if the entry exists.
        /// If a `Reader` can be obtained from an existing entry, it is returned.
        /// Otherwise, creates an entry using the `createEntryFn` and passed-in context and returns a `Reader` to the new entry.
        /// Be sure to call `release()` on the `Reader`.
        ///
        /// If this cache is at maximum entries, will still generate the value and return a `Reader` for it, but it will not be cached.
        /// If the expiration passed in is shorter than the time it takes to create this entry, will still generate the value and return a `Reader` for it, but the entry will no longer exist in the cache.
        ///
        /// Keys are not stored in this memory cache, so it's the responsibility of the caller to keep track of keys.
        /// The caller must also know the type of the stored values since they're agnostically stored as `[*]const u8`.
        /// This means entries are saved as shallow copies, which means that pointer members are not dereferenced and saved into the cache.
        ///
        /// Use `getOrPutSliceEntry()` for slices.
        pub fn getOrPutEntry(
            self: *MemCacheSelf,
            comptime TReturn: type,
            io: Io,
            key: []const u8,
            expiration: Expiration,
            create_entry_ctx: anytype,
            createEntryFn: fn (@TypeOf(create_entry_ctx), *Expiration.CleanupContext) TReturn,
        ) (ErrorComponent(TReturn) || GetOrPutError)!Reader {
            comptime checkTypeCompatibility(OkComponent(TReturn));

            if (try self.read(io, key)) |reader| {
                return reader;
            }

            var expiration_cpy: Expiration = expiration;
            var val: OkComponent(TReturn) = try @as(
                ErrorComponent(TReturn)!OkComponent(TReturn),
                createEntryFn(create_entry_ctx, &expiration_cpy.cleanup_context),
            );

            var entry_reader: Entry = .{ .raw_value = &mem.toBytes(val) };
            errdefer expiration_cpy.cleanup(entry_reader);

            var v: []align(max_alignment.toByteUnits()) const u8 = try self.createEntryValue(entry_reader.raw_value);
            errdefer self.allocator.free(v);

            self.putEntry(io, key, v, expiration_cpy, .no_clobber) catch |err| switch (err) {
                // Some other thread could have beat us here... An entry must exist then.
                error.CacheClobber => log.debug("Encountered cache clobber with key '{s}', even though this entry should be completely new. Assuming multiple threads are calling this method.", .{key}),
                // can't cache - we'll still return the value
                error.ReachedMaxEntries => return .{
                    .entry = .{ .raw_value = v },
                    .release_strategy = .{
                        .not_cached = .{
                            .ctx = expiration_cpy.cleanup_context.ctx,
                            .runCleanup = expiration_cpy.cleanup_context.runCleanup,
                        },
                    },
                },
                else => |e| return e,
            };

            return (try self.read(io, key)) orelse contigency: {
                log.warn("Finished performing `getOrPutEntry` with key '{s}', but the entry was not found. Was the expiration long enough to create the entry? - {f}", .{ key, expiration.timeout });
                // Well, we know at this point our entry and everything therein was freed from the `read()` call,
                // so we need to create everything again.
                val = try @as(
                    ErrorComponent(TReturn)!OkComponent(TReturn),
                    createEntryFn(create_entry_ctx, &expiration_cpy.cleanup_context),
                );
                entry_reader = .{ .raw_value = &mem.toBytes(val) };
                errdefer expiration_cpy.cleanup(entry_reader);

                v = try self.createEntryValue(entry_reader.raw_value);
                errdefer comptime unreachable;

                break :contigency .{
                    .entry = .{ .raw_value = v },
                    .release_strategy = .{
                        .not_cached = .{
                            .ctx = expiration_cpy.cleanup_context.ctx,
                            .runCleanup = expiration_cpy.cleanup_context.runCleanup,
                        },
                    },
                };
            };
        }

        /// Creates a new slice entry, returning `error.CacheClobber` if an entry with this `key` already exists.
        /// The caller must also know the slice type since it's agnostically converted into a slice of bytes.
        /// Runs `expiration.cleanup()` on error.
        pub fn newSliceEntry(
            self: *MemCacheSelf,
            comptime T: type,
            io: Io,
            key: []const u8,
            entry: []const T,
            expiration: Expiration,
        ) NewEntryError!void {
            comptime checkTypeCompatibility([]const T);

            const v: []align(max_alignment.toByteUnits()) const u8 = try self.createEntryValue(mem.sliceAsBytes(entry));
            errdefer self.allocator.free(v);
            try self.putEntry(io, key, v, expiration, .no_clobber);
        }

        /// Creates or overwrites a slice entry.
        /// The caller must also know the slice type since it's agnostically converted into a slice of bytes.
        /// Runs `expiration.cleanup()` on error.
        pub fn overwriteSliceEntry(
            self: *MemCacheSelf,
            comptime T: type,
            io: Io,
            key: []const u8,
            entry: []const T,
            expiration: Expiration,
        ) OverwriteEntryError!void {
            comptime checkTypeCompatibility([]const T);

            const v: []align(max_alignment.toByteUnits()) const u8 = try self.createEntryValue(mem.sliceAsBytes(entry));
            errdefer self.allocator.free(v);
            try self.putEntry(io, key, v, expiration, .replace);
        }

        /// First checks if the entry exists.
        /// If a `Reader` can be obtained from an existing entry, it is returned.
        /// Otherwise, creates an entry using the `createEntryFn` and passed-in context and returns a `Reader` to the new entry.
        /// Be sure to call `release()` on the `Reader`.
        /// The caller must also know the slice type since it's agnostically converted into a slice of bytes.
        ///
        /// If this cache is at maximum entries, will still generate the value and return a `Reader` for it, but it will not be cached.
        /// If the expiration passed in is shorter than the time it takes to create this entry, will still generate the value and return a `Reader` for it, but the entry will no longer exist in the cache.
        pub fn getOrPutSliceEntry(
            self: *MemCacheSelf,
            comptime TReturn: type,
            io: Io,
            key: []const u8,
            expiration: Expiration,
            create_entry_ctx: anytype,
            createEntryFn: fn (@TypeOf(create_entry_ctx), *Expiration.CleanupContext) TReturn,
        ) (ErrorComponent(TReturn) || GetOrPutError || OpenReaderError)!Reader {
            const SliceType = switch (@typeInfo(OkComponent(TReturn))) {
                .pointer => |p| switch (p.size) {
                    .slice => p.child,
                    else => @compileError("Expected `createEntryFn` to have a return type coercible to `TError![]const T`"),
                },
                else => @compileError("Expected `createEntryFn` to have a return type coercible to `TError![]const T`"),
            };
            comptime checkTypeCompatibility([]const SliceType);

            if (try self.read(io, key)) |reader| {
                return reader;
            }

            var expiration_cpy: Expiration = expiration;
            var val: []const SliceType = try @as(
                ErrorComponent(TReturn)![]const SliceType,
                createEntryFn(create_entry_ctx, &expiration_cpy.cleanup_context),
            );
            var entry_reader: Entry = .{ .raw_value = mem.sliceAsBytes(val) };
            errdefer expiration_cpy.cleanup(entry_reader);
            var v: []align(max_alignment.toByteUnits()) const u8 = try self.createEntryValue(entry_reader.raw_value);
            errdefer self.allocator.free(v);

            self.putEntry(io, key, v, expiration_cpy, .no_clobber) catch |err| switch (err) {
                // Some other thread could have beat us here... An entry must exist then.
                error.CacheClobber => log.debug("Encountered cache clobber with key '{s}', even though this entry should be completely new. Assuming multiple threads are calling this method.", .{key}),
                // can't cache - we'll still return the value
                error.ReachedMaxEntries => return .{
                    .entry = .{ .raw_value = v },
                    .release_strategy = .{
                        .not_cached = .{
                            .ctx = expiration_cpy.cleanup_context.ctx,
                            .runCleanup = expiration_cpy.cleanup_context.runCleanup,
                        },
                    },
                },
                else => |e| return e,
            };

            return (try self.read(io, key)) orelse contigency: {
                log.warn("Finished performing `getOrPutSliceEntry` with key '{s}', but the entry was not found. Was the expiration long enough to create the entry? - {f}", .{ key, expiration.timeout });
                // Well, we know at this point our entry and everything therein was freed from the `read()` call,
                // so we need to create everything again.
                val = try @as(
                    ErrorComponent(TReturn)![]const SliceType,
                    createEntryFn(create_entry_ctx, &expiration_cpy.cleanup_context),
                );
                entry_reader = .{ .raw_value = mem.sliceAsBytes(val) };
                errdefer expiration_cpy.cleanup(entry_reader);

                v = try self.createEntryValue(entry_reader.raw_value);
                errdefer comptime unreachable;

                break :contigency .{
                    .entry = .{ .raw_value = v },
                    .release_strategy = .{
                        .not_cached = .{
                            .ctx = expiration_cpy.cleanup_context.ctx,
                            .runCleanup = expiration_cpy.cleanup_context.runCleanup,
                        },
                    },
                };
            };
        }

        inline fn checkTypeCompatibility(comptime T: type) void {
            if (comptime max_alignment.compare(.lt, .of(T))) {
                @compileError(fmt.comptimePrint("Max alignment is {d}, but alignment of entry was {d} ({s}).", .{
                    max_alignment.toByteUnits(),
                    @alignOf(T),
                    @typeName(T),
                }));
            }
        }

        fn createEntryValue(self: *const MemCacheSelf, bytes: []const u8) Allocator.Error![]align(max_alignment.toByteUnits()) u8 {
            try minefield.stepOnSubset(.alloc, Allocator.Error);
            const v: []align(max_alignment.toByteUnits()) u8 = try self.allocator.alignedAlloc(u8, max_alignment, bytes.len);
            @memcpy(v, bytes);
            log.debug("Created tentative entry value {*}, len {d}", .{ v.ptr, v.len });

            return v;
        }

        fn putEntry(
            self: *MemCacheSelf,
            io: Io,
            key: []const u8,
            v: []align(max_alignment.toByteUnits()) const u8,
            expiration: Expiration,
            comptime put_behavior: PutBehavior,
        ) PutError(put_behavior)!void {
            const k: StringHash = .hashStr(key);

            try minefield.stepOn(.lock_mutex);
            // critical section
            try self.lock.lock(io);
            defer self.lock.unlock(io);

            try minefield.stepOn(.insert_entry);
            const gop: EntryMap.GetOrPutResult = try self.active_entries.getOrPut(self.allocator, k);
            if (gop.found_existing) switch (comptime put_behavior) {
                .no_clobber => return error.CacheClobber,
                .replace => {
                    const old_data: *EntryData = gop.value_ptr.*;
                    try minefield.stepOn(.create_entry);
                    // create a new entry
                    const new_data: *EntryData = self.entry_pool.create(self.allocator) catch return error.ReachedMaxEntries;
                    errdefer comptime unreachable;

                    // Replace so that new readers get the new entry.
                    // Existing readers on the old entry will destroy that memory when the last reader is released.
                    old_data.tombstone(self);
                    new_data.* = .init(v, expiration, .now(io, .real));
                    gop.value_ptr.* = new_data;
                    log.debug("Successfully replaced entry key '{s}' (hash=0x{x}) with {f} expiration.", .{ key, k, new_data.expiration.timeout });
                }
            } else {
                errdefer debug.assert(self.active_entries.swapRemove(k));

                try minefield.stepOn(.create_entry);
                const data: *EntryData = self.entry_pool.create(self.allocator) catch return error.ReachedMaxEntries;
                errdefer comptime unreachable;

                data.* = .init(v, expiration, .now(io, .real));
                gop.value_ptr.* = data;
                log.debug("Successfully created entry for key '{s}' (hash=0x{x}) with {f} expiration.", .{ key, k, data.expiration.timeout });
            }
        }

        /// Read an entry, producing a `Reader` that repesents an active read on the entry.
        /// Until the `Reader` is released, this entry is safe to read.
        /// Returns null if no entry exists with this key or if the entry has expired.
        /// Returns `error.TooManyOpenReaders` if the ref count would exceed max (configurable on `init()`, but defaults to the hard limit of `std.math.maxInt(u16)`).
        ///
        /// WARN : If the caller fails to call `release()` exactly once on the reader, it may produce a panic or segmentation fault later in the program.
        pub fn read(self: *MemCacheSelf, io: Io, key: []const u8) OpenReaderError!?Reader {
            const k: StringHash = .hashStr(key);

            try self.lock.lockShared(io);
            defer self.lock.unlockShared(io);

            const data: ?*EntryData = self.active_entries.get(k);
            log.debug("Entry for key '{s}' (hash=0x{x}) was {s}.", .{ key, k, if (data == null) "not found" else "found" });
            if (data) |d| {
                // confirm this is a valid entry (i.e. not expired or tombstoned)
                if (d.isExpired(io)) {
                    log.debug("Entry with key '{s}' (hash=0x{x}) is expired (expiration={f}). Now tombstoning entry...", .{ key, k, d.expiration.timeout });
                    d.tombstone(self);
                    debug.assert(self.active_entries.swapRemove(k));
                    return null;
                }
                return try d.openReader(io, @enumFromInt(self.opts.max_readers));
            }
            return null;
        }

        /// Call this function instead of `read()` so you don't have to handle `error.TooManyOpenReaders`.
        /// In the event that the max number of readers are open, will simply wait until the next reader is released.
        /// Until the resulting `Reader` is released, this entry is safe to read.
        /// Returns null if no entry exists with this key or if the entry has expired.
        ///
        /// WARN : If the caller fails to call `release()` exactly once on the reader, it may produce a panic or segmentation fault later in the program.
        pub fn waitForReader(self: *MemCacheSelf, io: Io, key: []const u8) Io.Future(Io.Cancelable!?Reader) {
            const waitForReaderLock = struct {
                fn wait(_self: *MemCacheSelf, _io: Io, _key: []const u8) Io.Cancelable!?Reader {
                    while (true) {
                        if (_self.read(_io, _key) catch |err| switch (err) {
                            error.Canceled => |canceled| return canceled,
                            error.TooManyOpenReaders => continue,
                        }) |reader| {
                            return reader;
                        } else return null;
                    }
                }
            }.wait;
            // TODO : Introduce timeout maybe?
            return io.async(waitForReaderLock, .{ self, io, key });
        }

        /// If true, an active entry was tombstoned and no longer able to be read.
        /// If no active entry was found, returns false.
        /// In a cancellation scenario, nothing has been removed; we were simply waiting for the lock.
        pub fn remove(self: *MemCacheSelf, io: Io, key: []const u8) Io.Cancelable!bool {
            const k: StringHash = .hashStr(key);

            try self.lock.lock(io);
            defer self.lock.unlock(io);

            if (self.active_entries.fetchSwapRemove(k)) |entry| {
                log.debug("Found entry '{s}' (hash=0x{x}) for removal; preparing to tombstone...", .{ key, k });
                entry.value.tombstone(self);
                return true;
            }
            return false;
        }

        /// Tombstones all active entries from the cache.
        /// In a cancellation scenario, nothing has been removed; we were simply waiting for the lock.
        pub fn clear(self: *MemCacheSelf, io: Io) Io.Cancelable!void {
            try self.lock.lock(io);
            defer self.lock.unlock(io);

            for (self.active_entries.values()) |entry| {
                entry.tombstone(self);
            }
            self.active_entries.clearRetainingCapacity();
        }

        fn unsafeClear(self: *MemCacheSelf) void {
            var iter: EntryMap.Iterator = self.active_entries.iterator();
            while (iter.next()) |entry| {
                const ref_count: RefCount = entry.value_ptr.*.ref_count.load(.acquire);
                if (ref_count != .zero) {
                    debug.panic("Found {d} active readers associated with hash 0x{x} while attempting to free memory.", .{ ref_count, entry.key_ptr.* });
                }
                const val: []align(max_alignment.toByteUnits()) const u8 = entry.value_ptr.*.value();
                entry.value_ptr.*.expiration.cleanup(.{ .raw_value = val });
                self.allocator.free(val);
                self.entry_pool.destroy(entry.value_ptr.*);
            }
            self.active_entries.clearRetainingCapacity();
        }

        /// Dumps the contents of the cache.
        /// NOT thread-safe, but this method needs to be public so that `Io.Writer` can leverage the `{f}` specifier in `print()`.
        pub fn format(self: *const MemCacheSelf, writer: *Io.Writer) Io.Writer.Error!void {
            var iter: EntryMap.Iterator = self.active_entries.iterator();
            try writer.writeByte('\n');
            while (iter.next()) |val| {
                try writer.print("{{ key = {x}, value = {f} }} ", .{ val.key_ptr.*, val.value_ptr.* });
            }
            try writer.writeAll("\n\n");
        }

        /// Dumps the contents of the mem cache to a writer in a thread-safe way.
        pub fn threadsafeDump(self: *MemCacheSelf, io: Io, writer: *Io.Writer) (Io.Writer.Error || Io.Cancelable)!void {
            try self.lock.lockShared(io);
            defer self.lock.unlockShared(io);

            try self.format(writer);
        }

        /// Deinitialize the memory cache, freeing all entries.
        /// WARN : Only call this during shutdown.
        /// Will panic or produce a segmentation fault if any active readers are found.
        pub fn deinit(self: *MemCacheSelf) void {
            log.debug("WARNING: Preparing to destroy self!!!\n{f}", .{self});
            self.unsafeClear();
            self.active_entries.deinit(self.allocator);
            self.entry_pool.deinit(self.allocator);
            self.* = undefined;
        }

        /// Allows one to pull an entry from the cache and have it safely read until `release()` is called on this reader.
        /// Each active reader represents one unit on the entry's reference count (max active references is configurable).
        pub const Reader = struct {
            /// The entry
            entry: Entry,
            /// What happens when `release()` is called.
            /// These values are used internally - do not modify
            release_strategy: ReleaseStrategy,

            /// After this call, the entry is no longer safe to read.
            pub fn release(self: Reader, cache: *MemCacheSelf) void {
                switch (self.release_strategy) {
                    .arc => |ref_count| {
                        const count_as_int: *Atomic(u16) = @ptrCast(ref_count);
                        const prev_count: RefCount = @enumFromInt(count_as_int.fetchSub(1, .release));
                        // The previous ref count must be some value between 1 and the max.
                        // Otherwise, something's broken...
                        debug.assert(prev_count.compare(.gt, .zero));
                        debug.assert(prev_count.compare(.lte, @enumFromInt(cache.opts.max_readers)));
                        if (prev_count == .one) {
                            const data: *EntryData = @alignCast(@fieldParentPtr("ref_count", ref_count));
                            // Tombstoned entries have been removed the cache; so this is just a floating reference.
                            // We've confirmed we're the last reader, so it's up to us to destroy this metadata.
                            if (data.expiration.timeout == .tombstoned) {
                                log.debug("Removing reader for value {*}, len={d}", .{ self.entry.raw_value.ptr, self.entry.raw_value.len });
                                debug.assert(ref_count.raw == .zero);
                                data.expiration.cleanup(self.entry);
                                cache.allocator.free(data.value());
                                cache.entry_pool.destroy(data);
                            }
                        }
                    },
                    .not_cached => |c| {
                        c.runCleanup(c.ctx, self.entry);
                        cache.allocator.free(@as([]align(max_alignment.toByteUnits()) const u8, @alignCast(self.entry.raw_value)));
                    },
                }
            }
        };

        /// Landmines to test with
        const minefield = @import("minefield.zig").set(enum {
            alloc,
            lock_mutex,
            insert_entry,
            create_entry,
        }, GetOrPutError);

        /// A full cache entry, containing the value as well as its reference count, expiration, and created timestamp
        const EntryData = struct {
            /// Entry expiration
            expiration: Expiration,
            /// Pointer to the value
            ptr: [*]align(max_alignment.toByteUnits()) const u8,
            /// Length of the cache entry
            len: u16,
            /// Number of references reading this cache entry
            ref_count: Atomic(RefCount),
            /// When the entry was created
            created_at: Io.Timestamp,

            fn init(val: []align(max_alignment.toByteUnits()) const u8, expiration: Expiration, created_at: Io.Timestamp) EntryData {
                return .{
                    .expiration = expiration,
                    .ptr = val.ptr,
                    .len = @intCast(val.len),
                    .ref_count = .init(.zero),
                    .created_at = created_at,
                };
            }

            fn value(self: *const EntryData) []align(max_alignment.toByteUnits()) const u8 {
                return self.ptr[0..self.len];
            }

            /// Atomically increment the reference count
            fn openReader(self: *EntryData, io: Io, max_readers: RefCount) OpenReaderError!Reader {
                defer debug.assert(self.expiration.timeout != .tombstoned);
                var refs: RefCount = self.ref_count.load(.monotonic);
                if (refs == max_readers) {
                    return error.TooManyOpenReaders;
                }
                while (self.ref_count.cmpxchgWeak(refs, refs.plusOne(), .release, .acquire)) |count| : (try io.checkCancel()) {
                    refs = count;
                    if (refs == max_readers) {
                        return error.TooManyOpenReaders;
                    }
                }
                return .{
                    .entry = .{ .raw_value = self.value() },
                    .release_strategy = .{ .arc = &self.ref_count },
                };
            }

            fn isExpired(self: *EntryData, io: Io) bool {
                const expiry_ns: i96 = switch (self.expiration.timeout) {
                    .deadline => |deadline| deadline.nanoseconds,
                    .duration => |duration| self.created_at.addDuration(duration).nanoseconds,
                    .tombstoned => return true,
                    .indefinite => return false,
                };
                return Io.Timestamp.now(io, .real).nanoseconds >= expiry_ns;
            }

            fn tombstone(self: *EntryData, cache: *MemCacheSelf) void {
                self.expiration.timeout = .tombstoned;
                const ref_count: RefCount = self.ref_count.load(.acquire);
                if (ref_count == .zero) {
                    const val: []align(max_alignment.toByteUnits()) const u8 = self.value();
                    self.expiration.cleanup(.{ .raw_value = val });
                    cache.allocator.free(val);
                    cache.entry_pool.destroy(self);
                    log.debug("Zero active readers found; successfully destroyed entry.", .{});
                } else {
                    log.debug("{d} active readers found; entry not reader to be destroyed.", .{ref_count});
                }
            }

            pub fn format(self: *const EntryData, writer: *Io.Writer) Io.Writer.Error!void {
                try writer.print("{{ .ptr = {*}, .len = {d}, .ref_count = {d}, .expiration_timeout = {f} }}", .{
                    self.ptr,
                    self.len,
                    self.ref_count.load(.monotonic),
                    self.expiration.timeout,
                });
            }
        };

        const EntryPool = std.heap.MemoryPoolExtra(EntryData, .{ .growable = max_entries == null });

        const EntryMap = std.ArrayHashMapUnmanaged(StringHash, *EntryData, StringHash.context, false);

        test read {
            var mem_cache: Default = try .init(testing.allocator, .{});
            defer mem_cache.deinit();

            const StructValue = struct {
                a: f32,
                b: u16,
            };

            const s: StructValue = .{ .a = 3.14, .b = 5 };
            try mem_cache.newEntry(testing.io, "struct_val", s, .no_expiration);

            if (try mem_cache.read(testing.io, "struct_val")) |reader| {
                var should_free: bool = true;
                defer if (should_free) reader.release(&mem_cache);
                try testing.expectEqual(.one, reader.release_strategy.arc.load(.monotonic));

                const entry: *const StructValue = reader.entry.read(StructValue);
                try testing.expectEqual(s.a, entry.a);
                try testing.expectEqual(s.b, entry.b);

                reader.release(&mem_cache);
                should_free = false;
                try testing.expectEqual(.zero, reader.release_strategy.arc.load(.monotonic));
            } else return error.NoEntry;

            const num: u32 = 90;
            try testing.expectError(
                error.CacheClobber,
                mem_cache.newEntry(testing.io, "struct_val", num, .no_expiration),
            );
            try testing.expectError(
                error.CacheClobber,
                mem_cache.newSliceEntry(u8, testing.io, "struct_val", "oh my", .no_expiration),
            );

            const arr: [3]u32 = .{ 1, 2, 3 };
            try mem_cache.newSliceEntry(u32, testing.io, "slice", &arr, .no_expiration);
            if (try mem_cache.read(testing.io, "slice")) |reader| {
                var should_free: bool = true;
                defer if (should_free) reader.release(&mem_cache);
                try testing.expectEqual(.one, reader.release_strategy.arc.load(.monotonic));

                const entry: []const u32 = reader.entry.readSlice(u32);
                try testing.expectEqualSlices(u32, &arr, entry);

                reader.release(&mem_cache);
                should_free = false;
                try testing.expectEqual(.zero, reader.release_strategy.arc.load(.monotonic));
            } else return error.NoEntry;

            try testing.expectError(
                error.CacheClobber,
                mem_cache.newEntry(testing.io, "slice", num, .no_expiration),
            );
            try testing.expectError(
                error.CacheClobber,
                mem_cache.newSliceEntry(u8, testing.io, "slice", "oh my", .no_expiration),
            );
        }

        test "handle expiration" {
            var mem_cache: Default = try .init(testing.allocator, .{});
            defer mem_cache.deinit();

            const StructValue = struct {
                a: f32,
                b: u16,
            };

            const s: StructValue = .{ .a = 3.14, .b = 5 };
            try mem_cache.newEntry(testing.io, "struct_val", s, .lifetime(.{ .duration = .fromMilliseconds(5) }, .no_callback));

            if (try mem_cache.read(testing.io, "struct_val")) |reader| {
                try testing.expectEqual(.one, reader.release_strategy.arc.load(.monotonic));
                reader.release(&mem_cache);
                try testing.expectEqual(.zero, reader.release_strategy.arc.load(.monotonic));
            } else return error.NoEntry;
            try testing.io.sleep(.fromMilliseconds(10), .awake); // give this a good buffer of time to let this expire (flaky test if sleep time is too close to expiration time)

            if (try mem_cache.read(testing.io, "struct_val")) |_| return error.ExpectedNoEntry;
        }

        test newEntry {
            var mem_cache: Default = try .init(testing.allocator, .{});
            defer mem_cache.deinit();

            const StructValue = struct {
                a: f32,
                b: u16,
            };
            const s: StructValue = .{ .a = 3.14, .b = 5 };

            minefield.detonateOn(.alloc, error.OutOfMemory);
            try testing.expectError(
                error.OutOfMemory,
                mem_cache.newEntry(testing.io, "struct_value", s, .no_expiration),
            );
            try minefield.cleanup(.reset);
            try testing.expectEqual(0, mem_cache.active_entries.count());

            minefield.detonateOn(.lock_mutex, error.Canceled);
            try testing.expectError(
                error.Canceled,
                mem_cache.newEntry(testing.io, "struct_value", s, .no_expiration),
            );
            try minefield.cleanup(.reset);
            try testing.expectEqual(0, mem_cache.active_entries.count());

            minefield.detonateOn(.insert_entry, error.OutOfMemory);
            try testing.expectError(
                error.OutOfMemory,
                mem_cache.newEntry(testing.io, "struct_value", s, .no_expiration),
            );
            try minefield.cleanup(.reset);
            try testing.expectEqual(0, mem_cache.active_entries.count());
        }

        test newSliceEntry {
            var mem_cache: Default = try .init(testing.allocator, .{});
            defer mem_cache.deinit();

            const arr: [3]u32 = .{ 1, 2, 3 };

            minefield.detonateOn(.alloc, error.OutOfMemory);
            try testing.expectError(
                error.OutOfMemory,
                mem_cache.newSliceEntry(u32, testing.io, "my_slice", &arr, .no_expiration),
            );
            try minefield.cleanup(.reset);
            try testing.expectEqual(0, mem_cache.active_entries.count());

            minefield.detonateOn(.lock_mutex, error.Canceled);
            try testing.expectError(
                error.Canceled,
                mem_cache.newEntry(testing.io, "my_slice", &arr, .no_expiration),
            );
            try minefield.cleanup(.reset);
            try testing.expectEqual(0, mem_cache.active_entries.count());

            minefield.detonateOn(.insert_entry, error.OutOfMemory);
            try testing.expectError(
                error.OutOfMemory,
                mem_cache.newSliceEntry(u32, testing.io, "my_slice", &arr, .no_expiration),
            );
            try minefield.cleanup(.reset);
            try testing.expectEqual(0, mem_cache.active_entries.count());
        }

        test remove {
            var mem_cache: Default = try .init(testing.allocator, .{});
            defer mem_cache.deinit();

            // basic test
            {
                const arr: [3]u32 = .{ 1, 2, 3 };
                try mem_cache.newSliceEntry(u32, testing.io, "my_slice", &arr, .no_expiration);
                if (try mem_cache.read(testing.io, "my_slice")) |reader|
                    reader.release(&mem_cache)
                else
                    return error.NoEntry;

                try testing.expect(try mem_cache.remove(testing.io, "my_slice"));
                if (try mem_cache.read(testing.io, "my_slice")) |_| return error.ExpectedNoEntry;
            }
            // remove while reader is still active
            {
                const arr: [3]u32 = .{ 1, 2, 3 };
                try mem_cache.newSliceEntry(u32, testing.io, "my_slice", &arr, .no_expiration);
                const reader: Default.Reader = (try mem_cache.read(testing.io, "my_slice")) orelse return error.NoEntry;
                defer reader.release(&mem_cache);

                // remove while reader is still active...
                try testing.expect(try mem_cache.remove(testing.io, "my_slice"));
                // confirm we CAN'T get a new reader now that it's tombstoned
                if (try mem_cache.read(testing.io, "my_slice")) |_| return error.ExpectedNoEntry;

                // the active reader should still be able to read the contents of the tombstoned entry
                try testing.expectEqualSlices(u32, &arr, reader.entry.readSlice(u32));

                // on the deferred release, memory should get freed then
            }
        }

        test clear {
            var mem_cache: Default = try .init(testing.allocator, .{});
            defer mem_cache.deinit();

            const StructValue = struct {
                a: f32,
                b: u16,
            };

            const s: StructValue = .{ .a = 3.14, .b = 5 };
            const arr: [3]u32 = .{ 1, 2, 3 };
            try mem_cache.newSliceEntry(u32, testing.io, "my_slice", &arr, .no_expiration);
            try mem_cache.newEntry(testing.io, "struct_val", s, .no_expiration);

            if (try mem_cache.read(testing.io, "my_slice")) |reader|
                reader.release(&mem_cache)
            else
                return error.NoEntry;
            if (try mem_cache.read(testing.io, "struct_val")) |reader|
                reader.release(&mem_cache)
            else
                return error.NoEntry;

            try mem_cache.clear(testing.io);

            if (try mem_cache.read(testing.io, "my_slice")) |_| return error.ExpectedNoEntry;
            if (try mem_cache.read(testing.io, "struct_val")) |_| return error.ExpectedNoEntry;

            const expiration: Expiration = .lifetime(.{ .duration = .fromMilliseconds(5) }, .no_callback);
            // re-add with expiration
            try mem_cache.newSliceEntry(u32, testing.io, "my_slice", &arr, expiration);
            try mem_cache.newEntry(testing.io, "struct_value", s, expiration);

            // clear before expiration, which should cancel the expiration tasks
            try mem_cache.clear(testing.io);

            if (try mem_cache.read(testing.io, "my_slice")) |_| return error.ExpectedNoEntry;
            if (try mem_cache.read(testing.io, "struct_val")) |_| return error.ExpectedNoEntry;

            // re-add AGAIN... to make sure we can cancel again and free everything as expected
            try mem_cache.newSliceEntry(u32, testing.io, "my_slice", &arr, expiration);
            try mem_cache.newEntry(testing.io, "struct_value", s, expiration);
        }

        test overwriteEntry {
            var mem_cache: Default = try .init(testing.allocator, .{});
            defer mem_cache.deinit();

            // basic test case...
            {
                const num1: i32 = 64;
                const num2: i32 = -72;

                try mem_cache.overwriteEntry(testing.io, "my_entry", num1, .no_expiration);
                try mem_cache.overwriteEntry(testing.io, "my_entry", num2, .no_expiration);

                if (try mem_cache.read(testing.io, "my_entry")) |reader| {
                    defer reader.release(&mem_cache);

                    try testing.expectEqual(num2, reader.entry.read(i32).*);
                }
            }
            // more complex with 2 readers, reading from different generations
            {
                const num1: i32 = 64;
                const num2: i32 = -72;

                try mem_cache.overwriteEntry(testing.io, "my_entry", num1, .no_expiration);
                const reader_a: Default.Reader = (try mem_cache.read(testing.io, "my_entry")) orelse return error.NoEntry;
                defer reader_a.release(&mem_cache);

                try mem_cache.overwriteEntry(testing.io, "my_entry", num2, .no_expiration);
                const reader_b: Default.Reader = (try mem_cache.read(testing.io, "my_entry")) orelse return error.NoEntry;
                defer reader_b.release(&mem_cache);

                try testing.expectEqual(num1, reader_a.entry.read(i32).*);
                try testing.expectEqual(num2, reader_b.entry.read(i32).*);
            }
        }

        test overwriteSliceEntry {
            var mem_cache: Default = try .init(testing.allocator, .{});
            defer mem_cache.deinit();

            const slice1: []const u8 = "asdf";
            const slice2: []const u8 = "blarf";

            try mem_cache.overwriteSliceEntry(u8, testing.io, "my_slice", slice1, .no_expiration);
            try mem_cache.overwriteSliceEntry(u8, testing.io, "my_slice", slice2, .no_expiration);

            if (try mem_cache.read(testing.io, "my_slice")) |reader| {
                defer reader.release(&mem_cache);

                try testing.expectEqualStrings(slice2, reader.entry.readSlice(u8));
            }
        }

        test "muliple removes" {
            if (builtin.single_threaded) {
                return error.SkipZigTest;
            }

            var mem_cache: Default = try .init(testing.allocator, .{});
            defer mem_cache.deinit();

            const slice: []const u8 = "asdf";
            try mem_cache.overwriteSliceEntry(u8, testing.io, "my_slice", slice, .no_expiration);

            const removeEntry = struct {
                fn removeEntry(start: *Atomic(bool), cache: *Default, io: Io, key: []const u8) Io.Cancelable!void {
                    while (!start.load(.monotonic)) {}
                    _ = try cache.remove(io, key);
                }
            }.removeEntry;

            var start: Atomic(bool) = .init(false);
            var group: Io.Group = .init;
            defer group.cancel(testing.io);

            group.async(testing.io, removeEntry, .{ &start, &mem_cache, testing.io, "my_slice" });
            group.async(testing.io, removeEntry, .{ &start, &mem_cache, testing.io, "my_slice" });
            group.async(testing.io, removeEntry, .{ &start, &mem_cache, testing.io, "my_slice" });

            start.store(true, .release);
            try group.await(testing.io);

            if (try mem_cache.read(testing.io, "my_slice")) |_| return error.ExpectedNoEntry;
        }

        test "read and remove conflict" {
            if (builtin.single_threaded) {
                return error.SkipZigTest;
            }

            var mem_cache: Default = try .init(testing.allocator, .{});
            defer mem_cache.deinit();

            const slice: []const u8 = "asdf";
            try mem_cache.overwriteSliceEntry(u8, testing.io, "my_slice", slice, .no_expiration);

            const removeEntry = struct {
                fn removeEntry(start: *Atomic(bool), cache: *Default, io: Io, key: []const u8) Io.Cancelable!void {
                    while (!start.load(.monotonic)) {}
                    _ = try cache.remove(io, key);
                }
            }.removeEntry;

            const readEntry = struct {
                fn readEntry(start: *Atomic(bool), cache: *Default, io: Io, key: []const u8) Io.Cancelable!void {
                    while (!start.load(.monotonic)) {}
                    if (cache.read(io, key) catch |err| switch (err) {
                        error.Canceled => |canceled| return canceled,
                        error.TooManyOpenReaders => unreachable,
                    }) |reader| {
                        defer reader.release(cache);
                        testing.expectEqualStrings(slice, reader.entry.readSlice(u8)) catch unreachable;
                    }
                }
            }.readEntry;

            var start: Atomic(bool) = .init(false);
            var group: Io.Group = .init;
            defer group.cancel(testing.io);

            group.async(testing.io, readEntry, .{ &start, &mem_cache, testing.io, "my_slice" });
            group.async(testing.io, removeEntry, .{ &start, &mem_cache, testing.io, "my_slice" });

            start.store(true, .release);
            try group.await(testing.io);

            if (try mem_cache.read(testing.io, "my_slice")) |_| return error.ExpectedNoEntry;

            start.store(false, .release);
            group.async(testing.io, removeEntry, .{ &start, &mem_cache, testing.io, "my_slice" });
            group.async(testing.io, readEntry, .{ &start, &mem_cache, testing.io, "my_slice" });

            start.store(true, .release);
            try group.await(testing.io);

            if (try mem_cache.read(testing.io, "my_slice")) |_| return error.ExpectedNoEntry;
        }

        test "too many open readers" {
            if (builtin.single_threaded) {
                return error.SkipZigTest;
            }

            var mem_cache: Default = try .init(testing.allocator, .{ .max_readers = 1 });
            defer mem_cache.deinit();

            const slice: []const u8 = "asdf";
            try mem_cache.overwriteSliceEntry(u8, testing.io, "my_slice", slice, .no_expiration);

            const reader: Default.Reader = (try mem_cache.read(testing.io, "my_slice")) orelse return error.NoEntry;
            defer reader.release(&mem_cache);

            // we configured the cache to have at most 1 reader
            try testing.expectError(error.TooManyOpenReaders, mem_cache.read(testing.io, "my_slice"));
        }

        test getOrPutEntry {
            var mem_cache: Default = try .init(testing.allocator, .{});
            defer mem_cache.deinit();

            {
                // no error and no args in createEntry()
                const reader: Default.Reader = try mem_cache.getOrPutEntry(i32, testing.io, "my_val", .no_expiration, {}, struct {
                    fn createEntry(_: void, _: *Expiration.CleanupContext) i32 {
                        return 64;
                    }
                }.createEntry);
                defer reader.release(&mem_cache);

                try testing.expectEqual(64, reader.entry.read(i32).*);
            }
            {
                // this test exemplifies a pattern for creating an entry and the cleanup that may be required when the entry is removed

                const EntryManager = struct {
                    gpa: Allocator,

                    fn createEntry(this: @This(), cleanup_ctx_out: *Expiration.CleanupContext) Allocator.Error!*const u32 {
                        // In general, this pattern is best for when you have a structure with 1 or more pointer members.
                        // The pointer members can be allocated like so when creating the entry, and a shallow copy of the structure works perfectly.
                        // The pointer(s) remain valid until the entry is cleaned up, which at that point, the pointer(s) can be deallocated.

                        // create a pointer to the entry manager and assign it to `cleanup_ctx_out`
                        const this_cpy: *@This() = try this.gpa.create(@This());
                        errdefer this.gpa.destroy(this_cpy);
                        this_cpy.* = this;
                        cleanup_ctx_out.setContext(this_cpy);

                        const val: *u32 = try this_cpy.gpa.create(u32);
                        val.* = 25;
                        return val;
                    }

                    fn cleanup(context: *anyopaque, entry: Entry) void {
                        const this: *const @This() = @ptrCast(@alignCast(context));
                        // read returns a *const T, and in this case T = *const u32, so `entry.read()` returns `*const *const u32`
                        this.gpa.destroy(entry.read(*const u32).*);
                        this.gpa.destroy(this);
                    }
                };

                const entry_manager: EntryManager = .{ .gpa = testing.allocator };
                const reader: Default.Reader = try mem_cache.getOrPutEntry(
                    Allocator.Error!*const u32,
                    testing.io,
                    "my_other_val",
                    .lifetime(.indefinite, .callback(EntryManager.cleanup)),
                    entry_manager,
                    EntryManager.createEntry,
                );
                defer reader.release(&mem_cache);

                // funky edge case here
                try testing.expectEqual(25, reader.entry.read(*const u32).*.*);
            }
        }

        test getOrPutSliceEntry {
            var mem_cache: Default = try .init(testing.allocator, .{});
            defer mem_cache.deinit();

            {
                // no error and no args in createEntry()
                const reader: Default.Reader = try mem_cache.getOrPutSliceEntry([]const u8, testing.io, "my_val", .no_expiration, {}, struct {
                    fn createEntry(_: void, _: *Expiration.CleanupContext) []const u8 {
                        return "blarf";
                    }
                }.createEntry);
                defer reader.release(&mem_cache);

                try testing.expectEqualStrings("blarf", reader.entry.readSlice(u8));
            }
            {
                // this test exemplifies a pattern for creating a slice entry and the cleanup that may be required when the entry is removed

                const EntryManager = struct {
                    gpa: Allocator,
                    created_slice: []const u8 = undefined,

                    fn createEntry(this: @This(), cleanup_ctx_out: *Expiration.CleanupContext) Allocator.Error![]const u8 {
                        const this_cpy: *@This() = try this.gpa.create(@This());
                        errdefer this.gpa.destroy(this_cpy);

                        this_cpy.* = this;
                        cleanup_ctx_out.setContext(this_cpy);

                        this_cpy.created_slice = try this_cpy.gpa.dupe(u8, "whoa");
                        return this_cpy.created_slice;
                    }

                    fn cleanup(context: *anyopaque, entry: Entry) void {
                        _ = entry; // when a slice is entered in the cache, it's copied, so we have to track the slice on this structure
                        const this: *const @This() = @ptrCast(@alignCast(context));
                        this.gpa.free(this.created_slice);
                        this.gpa.destroy(this);
                    }
                };

                const entry_manager: EntryManager = .{ .gpa = testing.allocator };
                const reader: Default.Reader = try mem_cache.getOrPutSliceEntry(
                    Allocator.Error![]const u8,
                    testing.io,
                    "my_other_val",
                    .lifetime(.indefinite, .callback(EntryManager.cleanup)),
                    entry_manager,
                    EntryManager.createEntry,
                );
                defer reader.release(&mem_cache);

                try testing.expectEqualStrings("whoa", reader.entry.readSlice(u8));
            }

            // expiration too short
            {
                const EntryManager = struct {
                    gpa: Allocator,
                    created_slice: []const u8 = undefined,

                    fn createEntry(this: @This(), cleanup_ctx_out: *Expiration.CleanupContext) Allocator.Error![]const u8 {
                        const this_cpy: *@This() = try this.gpa.create(@This());
                        errdefer this.gpa.destroy(this_cpy);

                        this_cpy.* = this;
                        cleanup_ctx_out.setContext(this_cpy);

                        this_cpy.created_slice = try this_cpy.gpa.dupe(u8, "whoa");
                        return this_cpy.created_slice;
                    }

                    fn cleanup(context: *anyopaque, entry: Entry) void {
                        _ = entry; // when a slice is entered in the cache, it's copied, so we have to track the slice on this structure
                        const this: *const @This() = @ptrCast(@alignCast(context));
                        this.gpa.free(this.created_slice);
                        this.gpa.destroy(this);
                    }
                };

                testing.log_level = .err;
                defer testing.log_level = .warn;

                const entry_manager: EntryManager = .{ .gpa = testing.allocator };
                const reader: Default.Reader = try mem_cache.getOrPutSliceEntry(
                    Allocator.Error![]const u8,
                    testing.io,
                    "too_short",
                    .lifetime(.tombstoned, .callback(EntryManager.cleanup)), // <-- this entry will never be valid
                    entry_manager,
                    EntryManager.createEntry,
                );
                defer reader.release(&mem_cache);

                try testing.expect(reader.release_strategy == .not_cached);
                try testing.expectEqualStrings("whoa", reader.entry.readSlice(u8));
            }
        }

        test waitForReader {
            var mem_cache: Default = try .init(testing.allocator, .{});
            defer mem_cache.deinit();

            const slice: []const u8 = "asdf";
            try mem_cache.overwriteSliceEntry(u8, testing.io, "my_slice", slice, .no_expiration);

            // deliberately interfere with the data cuz I don't wanna make 32K references just for a unit test
            mem_cache.active_entries.get(StringHash.hashStr("my_slice")).?.ref_count.store(.max, .release);

            var read_future: Io.Future(Io.Cancelable!?Default.Reader) = mem_cache.waitForReader(testing.io, "my_slice");
            defer if (read_future.cancel(testing.io)) |maybe_reader| {
                if (maybe_reader) |reader| reader.release(&mem_cache);
            } else |_| {};

            // pretend that a reader was just released
            mem_cache.active_entries.get(StringHash.hashStr("my_slice")).?.ref_count.store(RefCount.max.minusOne(), .release);
            if (try read_future.await(testing.io)) |final_reader| {
                defer final_reader.release(&mem_cache);
                try testing.expectEqual(
                    RefCount.max,
                    mem_cache.active_entries.get(StringHash.hashStr("my_slice")).?.ref_count.load(.monotonic),
                );
            } else return error.NoEntry;

            try testing.expectEqual(
                RefCount.max.minusOne(),
                mem_cache.active_entries.get(StringHash.hashStr("my_slice")).?.ref_count.load(.monotonic),
            );

            // set this back so `clear()` doesn't deadlock
            mem_cache.active_entries.get(StringHash.hashStr("my_slice")).?.ref_count.store(.zero, .release);
            try mem_cache.clear(testing.io);
        }

        test "probably the most useful pattern" {
            const DatabaseRow = struct {
                id: u64,
                name: []const u8,
                timestamp: i64,
            };

            var mem_cache: Default = try .init(testing.allocator, .{});
            defer mem_cache.deinit();

            const EntryManager = struct {
                gpa: Allocator,
                io: Io,
                id: u64,

                /// Creates the entry if it doesn't already exist.
                /// Presumably, we're creating memory we won't have access to later, so we need to track allocations,
                /// which is the purpose of this struct.
                /// Assign a pointer to this struct to the cleanup context output parameter.
                /// See `cleanup()` to see how the cleanup context will be used.
                fn createEntry(
                    this: @This(),
                    cleanup_ctx_out: *Expiration.CleanupContext,
                ) Allocator.Error!DatabaseRow {
                    // imagine a database query takes place here...
                    const timestamp: Io.Timestamp = .now(this.io, .real);
                    const row: DatabaseRow = .{
                        .id = this.id,
                        .name = try this.gpa.dupe(u8, "NameColumn"),
                        .timestamp = timestamp.toMilliseconds(),
                    };
                    errdefer this.gpa.free(row.name);

                    // create a pointer to this structure to assign to the cleanup context output parameter
                    const this_cpy: *@This() = try this.gpa.create(@This());
                    this_cpy.* = this;
                    cleanup_ctx_out.setContext(this_cpy);

                    return row;
                }

                fn cleanup(context: *anyopaque, entry: Entry) void {
                    // cast the cleanup context into a pointer to this struct
                    const this: *const @This() = @ptrCast(@alignCast(context));
                    const row: *const DatabaseRow = entry.read(DatabaseRow);
                    this.gpa.free(row.name);
                    this.gpa.destroy(this);
                }
            };

            const entry_manager: EntryManager = .{
                .gpa = testing.allocator,
                .io = testing.io,
                .id = 1,
            };
            const expiration: Expiration = .lifetime(
                .{ .duration = .fromSeconds(15) },
                .callback(EntryManager.cleanup), // this will be run on removal/expiration
            );
            const reader: Default.Reader = try mem_cache.getOrPutEntry(
                Allocator.Error!DatabaseRow,
                testing.io,
                "DbRow(1)",
                expiration,
                entry_manager,
                EntryManager.createEntry,
            );
            defer reader.release(&mem_cache);

            const entry: *const DatabaseRow = reader.entry.read(DatabaseRow);
            try testing.expectEqual(1, entry.id);
            try testing.expectEqualStrings("NameColumn", entry.name);
        }

        test "Reached Max Entries" {
            // only 1 entry allowed
            const SpecialMemCache = Aligned(.fromByteUnits(std.atomic.cache_line), 1);
            var mem_cache: SpecialMemCache = try .init(testing.allocator, .{});
            defer mem_cache.deinit();

            const DatabaseRow = struct {
                id: u64,
                name: []const u8,
                timestamp: i64,
            };

            const EntryManager = struct {
                gpa: Allocator,
                io: Io,
                id: u64,

                /// Creates the entry if it doesn't already exist.
                /// Presumably, we're creating memory we won't have access to later, so we need to track allocations,
                /// which is the purpose of this struct.
                /// Assign a pointer to this struct to the cleanup context output parameter.
                /// See `cleanup()` to see how the cleanup context will be used.
                fn createEntry(
                    this: @This(),
                    cleanup_ctx_out: *Expiration.CleanupContext,
                ) Allocator.Error!DatabaseRow {
                    // imagine a database query takes place here...
                    const timestamp: Io.Timestamp = .now(this.io, .real);
                    const row: DatabaseRow = .{
                        .id = this.id,
                        .name = try fmt.allocPrint(this.gpa, "NameColumn_{d}", .{this.id}),
                        .timestamp = timestamp.toMilliseconds(),
                    };
                    errdefer this.gpa.free(row.name);

                    // create a pointer to this structure to assign to the cleanup context output parameter
                    const this_cpy: *@This() = try this.gpa.create(@This());
                    this_cpy.* = this;
                    cleanup_ctx_out.setContext(this_cpy);

                    return row;
                }

                fn cleanup(context: *anyopaque, entry: Entry) void {
                    // cast the cleanup context into a pointer to this struct
                    const this: *const @This() = @ptrCast(@alignCast(context));
                    const row: *const DatabaseRow = entry.read(DatabaseRow);
                    this.gpa.free(row.name);
                    this.gpa.destroy(this);
                }
            };

            const entry_manager_1: EntryManager = .{
                .gpa = testing.allocator,
                .io = testing.io,
                .id = 1,
            };
            const expiration: Expiration = .lifetime(
                .{ .duration = .fromSeconds(15) },
                .callback(EntryManager.cleanup), // this will be run on removal/expiration
            );
            const reader_a: SpecialMemCache.Reader = try mem_cache.getOrPutEntry(
                Allocator.Error!DatabaseRow,
                testing.io,
                "DbRow(1)",
                expiration,
                entry_manager_1,
                EntryManager.createEntry,
            );
            defer reader_a.release(&mem_cache);

            const entry_a: *const DatabaseRow = reader_a.entry.read(DatabaseRow);
            try testing.expectEqual(1, entry_a.id);
            try testing.expectEqualStrings("NameColumn_1", entry_a.name);

            const entry_manager_2: EntryManager = .{
                .gpa = testing.allocator,
                .io = testing.io,
                .id = 2,
            };
            const reader_b: SpecialMemCache.Reader = try mem_cache.getOrPutEntry(
                Allocator.Error!DatabaseRow,
                testing.io,
                "DbRow(2)",
                expiration,
                entry_manager_2,
                EntryManager.createEntry,
            );
            defer reader_b.release(&mem_cache);
            try testing.expect(reader_b.release_strategy == .not_cached);

            const entry_b: *const DatabaseRow = reader_b.entry.read(DatabaseRow);
            try testing.expectEqual(2, entry_b.id);
            try testing.expectEqualStrings("NameColumn_2", entry_b.name);
        }

        test "getOrPutEntry - expiration too short" {
            testing.log_level = .err;
            defer testing.log_level = .warn;

            const DatabaseRow = struct {
                id: u64,
                name: []const u8,
                timestamp: i64,
            };

            var mem_cache: Default = try .init(testing.allocator, .{});
            defer mem_cache.deinit();

            const EntryManager = struct {
                gpa: Allocator,
                io: Io,
                id: u64,

                fn createEntry(
                    this: @This(),
                    cleanup_ctx_out: *Expiration.CleanupContext,
                ) Allocator.Error!DatabaseRow {
                    const timestamp: Io.Timestamp = .now(this.io, .real);
                    const row: DatabaseRow = .{
                        .id = this.id,
                        .name = try this.gpa.dupe(u8, "NameColumn"),
                        .timestamp = timestamp.toMilliseconds(),
                    };
                    errdefer this.gpa.free(row.name);

                    // create a pointer to this structure to assign to the cleanup context output parameter
                    const this_cpy: *@This() = try this.gpa.create(@This());
                    this_cpy.* = this;
                    cleanup_ctx_out.setContext(this_cpy);

                    return row;
                }

                fn cleanup(context: *anyopaque, entry: Entry) void {
                    // cast the cleanup context into a pointer to this struct
                    const this: *const @This() = @ptrCast(@alignCast(context));
                    const row: *const DatabaseRow = entry.read(DatabaseRow);
                    this.gpa.free(row.name);
                    this.gpa.destroy(this);
                }
            };

            const entry_manager: EntryManager = .{
                .gpa = testing.allocator,
                .io = testing.io,
                .id = 1,
            };
            const expiration: Expiration = .lifetime(
                .tombstoned, // this entry will never be valid
                .callback(EntryManager.cleanup), // this will be run on removal/expiration
            );
            const reader: Default.Reader = try mem_cache.getOrPutEntry(
                Allocator.Error!DatabaseRow,
                testing.io,
                "DbRow(1)",
                expiration,
                entry_manager,
                EntryManager.createEntry,
            );
            defer reader.release(&mem_cache);

            try testing.expect(reader.release_strategy == .not_cached);
            const entry: *const DatabaseRow = reader.entry.read(DatabaseRow);
            try testing.expectEqual(1, entry.id);
            try testing.expectEqualStrings("NameColumn", entry.name);
        }
    };
}

/// Error that can be returned writing an entry (assuming that we're under max entries or we simply fetch the value without caching)
pub const GetOrPutError = OpenReaderError || Allocator.Error;

/// Possible errors returned when adding a new entry
pub const OverwriteEntryError = error{ReachedMaxEntries} || GetOrPutError;

/// Possible errors erturn when writing or overwriting an entry
pub const NewEntryError = error{CacheClobber} || OverwriteEntryError;

/// Possible errors while attempting to open a reader to an entry
pub const OpenReaderError = error{TooManyOpenReaders} || Io.Cancelable;

fn PutError(comptime put_behavior: PutBehavior) type {
    return switch (put_behavior) {
        .no_clobber => NewEntryError,
        .replace => OverwriteEntryError,
    };
}

/// Configuration when initializing a memory cache
pub const Options = struct {
    /// Maximum readers allowed before returning `error.TooManyOpenReaders`.
    /// This cache leverages atomic reference counting to ensure that cache entries are not destroyed before all references have dropped it.
    max_readers: u16 = @intFromEnum(RefCount.max),
};

/// Simple reader
pub const Entry = struct {
    /// Raw cache entry as bytes
    raw_value: []const u8,

    /// Read this entry as `*const T
    pub fn read(self: Entry, comptime T: type) *const T {
        debug.assert(@sizeOf(T) == self.raw_value.len);
        return @alignCast(mem.bytesAsValue(T, self.raw_value));
    }

    /// Read this entry as `[]const T`
    pub fn readSlice(self: Entry, comptime T: type) []const T {
        debug.assert(@rem(self.raw_value.len, @sizeOf(T)) == 0);
        return @alignCast(mem.bytesAsSlice(T, self.raw_value));
    }
};

/// These values are used internally - do not modify
pub const ReleaseStrategy = union(enum) {
    /// Atomic reference counting - the usual strategy
    arc: *Atomic(RefCount),
    /// In this scenario, we've copied the entry value and we simply free it when the reader is released.
    /// This should only be the case if we hit max entries and can't cache the value.
    not_cached: Expiration.CleanupContext,
};

/// An entry's expiration
pub const Expiration = struct {
    /// Entry's lifetime
    timeout: Timeout,
    /// Cleanup callback
    cleanup_context: CleanupContext,

    /// Defines a callback to run when an entry is removed
    pub const CleanupContext = struct {
        /// Optional cleanup context to be passed `runCleanup` (run when the entry is removed).
        ctx: *anyopaque,
        /// Cleanup function to be run when the entry is removed.
        runCleanup: *const fn (context: *anyopaque, entry: Entry) void,

        /// No callback configured => this is a no-op
        pub const no_callback: CleanupContext = .{
            .ctx = @constCast(&@as(u8, 0xAA)),
            .runCleanup = Expiration.noopCleanup,
        };

        /// Assumes the callback does not read the first parameter or the context will be set when creating the entry
        /// (see `getOrPutEntry` and `getOrPutSliceEntry`).
        pub fn callback(runCleanup: *const fn (_: *anyopaque, entry: Entry) void) CleanupContext {
            return .{
                .ctx = @constCast(&@as(u8, 0xAA)),
                .runCleanup = runCleanup,
            };
        }

        /// Set the cleanup context to any pointer
        pub fn setContext(self: *CleanupContext, any_ptr: *anyopaque) void {
            self.ctx = any_ptr;
        }
    };

    /// No expiration: assumes that nothing needs to be run when the entry is removed
    pub const no_expiration: Expiration = .{
        .timeout = .indefinite,
        .cleanup_context = .no_callback,
    };

    pub fn lifetime(timeout: Timeout, cleanup_context: CleanupContext) Expiration {
        return .{
            .timeout = timeout,
            .cleanup_context = cleanup_context,
        };
    }

    /// No-op cleanup function
    pub fn noopCleanup(_: *anyopaque, _: Entry) void {}

    fn cleanup(self: Expiration, entry: Entry) void {
        self.cleanup_context.runCleanup(self.cleanup_context.ctx, entry);
    }
};

/// Configurable timeout for setting an entries expiration
pub const Timeout = union(enum) {
    /// The entry lives only this long after creation
    duration: Io.Duration,
    /// Timestamp when entry becomes
    deadline: Io.Timestamp,
    /// Used internally to mark an entry as dead, either by explicit removal or expiration
    tombstoned,
    /// No timeout
    indefinite,

    pub fn format(self: Timeout, writer: *Io.Writer) Io.Writer.Error!void {
        switch (self) {
            .duration => |d| try writer.print("{t}: {d}", .{ self, d.nanoseconds }),
            .deadline => |d| try writer.print("{t}: {d}", .{ self, d.nanoseconds }),
            .tombstoned, .indefinite => try writer.writeAll(@tagName(self)),
        }
    }
};

/// Represents a string hash
const StringHash = enum(u32) {
    _,

    fn hashStr(k: []const u8) StringHash {
        return @enumFromInt(
            @as(u32, @truncate(std.hash.Wyhash.hash(0, k))),
        );
    }

    const context = struct {
        pub fn hash(_: context, k: StringHash) u32 {
            // this already repesents a hash, so just return the u32 value
            return @intFromEnum(k);
        }

        pub fn eql(_: context, a: StringHash, b: StringHash, _: usize) bool {
            return a == b;
        }
    };
};

/// Used to count references on an entry
const RefCount = enum(u16) {
    zero = 0,
    one = 1,
    max = std.math.maxInt(u16),
    _,

    fn compare(lh: RefCount, op: std.math.CompareOperator, rh: RefCount) bool {
        const lh_int: u16 = @intFromEnum(lh);
        const rh_int: u16 = @intFromEnum(rh);

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
const ErrorComponent = meta.ErrorComponent;
const OkComponent = meta.OkComponent;
