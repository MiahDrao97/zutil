//! The purpose of a memory cache is to memoize values that would otherwise take longer to fetch again.
//! Namely, this would be data from database queries or network calls that'd you rather not make very often or more than once.
//! However, because this memory cache can store data of any type, the memory allocated is fragmented and varied in size.
//! As a result, do not treat this cache as a data-oriented design technique, since the cached entries are almost guaranteed to use RAM.
//! Rather, this is meant to save on network/IO/SYSCALLs that would be more expensive than RAM usage.
//! Cache entries cannot exceed `std.math.max(u16)` bytes.
//! Note that all cache entries are shallow copies, so if you need to get around this limitation, just heap-allocate and cache the pointer.
//!
//! Here is a convo I started with Claude for some implementation considerations after inspecting C#'s Microsoft.Extensions.Caching.Memory.MemoryCache:
//!
//! # Me:
//! How does C#'s MemoryCache internally work regarding entries reaching their expiration?
//! The naive assumption I had was that each entry with an expiration would begin a new future that simply slept until the deadline and removed the entry after waking up.
//! However, I could imagine this would be resource-intensive to have a background task for every entry.
//! So this prompted me to wonder how MemoryCache actually does this.
//! I'm currently trying to implement a memory cache in Zig since nothing like that currently exists, and this is one of the things that I'm scrutinizing in my naive implementation.
//!
//! # Claudius Maximus:
//! Your naive assumption was reasonable, but MemoryCache does something more interesting — and honestly a bit more surprising — than "one timer per entry" *or* "one shared timer for the whole cache."
//! It has **no dedicated timer object at all**.
//! The MemoryCache doesn't have a timer to check for expiration; it tests if an expiry scan is needed each time it is accessed.
//!
//! **The two mechanisms**
//!
//! 1. **Lazy check-on-access.**
//! Every `TryGetValue`/`Set` call runs the entry it touches through `CheckExpired(now)`.
//! If an entry is past its absolute/sliding deadline, it's treated as a miss and queued for removal right then — no waiting for any sweep.
//! This is essentially free: you're already touching the entry's memory for the lookup, so the expiration check just rides along.
//!
//! 2. **Piggybacked periodic sweep.**
//! Separately, on *every* cache operation, MemoryCache checks how long it's been since the last full sweep:
//! ```csharp
//! if (_options.ExpirationScanFrequency < utcNow - _lastExpirationScan)
//! {
//!     ScheduleTask(utcNow);
//! }
//! ``` where `ScheduleTask` does `_lastExpirationScan = utcNow; Task.Factory.StartNew(() => ScanForExpiredItems(...))`.
//! `ExpirationScanFrequency` defaults to `TimeSpan.FromMinutes(1)`.
//! The scan itself is a brute-force linear walk:
//! ```csharp
//! foreach (KeyValuePair<object, CacheEntry> item in cache._entries)
//! {
//!     CacheEntry entry = item.Value;
//!     if (entry.CheckExpired(now))
//!     {
//!         cache.RemoveEntry(entry);
//!     }
//! }
//! ``` — a full O(n) pass over the `ConcurrentDictionary<object, CacheEntry>` backing store, dispatched onto the thread pool via `Task.Factory.StartNew` so it doesn't block the caller that happened to trigger it.
//!
//! So the "background task" you imagined does exist — but there's at most one in flight at a time (in theory).
//! It's not scheduled by a timer; it's opportunistically kicked off by whatever thread happens to call into the cache after the interval has elapsed, and it sweeps *everything* rather than targeting the one entry that's actually due.
//!
//! **Notable consequence for your design:**
//! Because the sweep is entirely piggybacked on cache traffic, a cache that goes completely idle after entries expire will never reclaim that memory — there's nothing driving cleanup except calls into the cache.
//! If you want a guarantee that expired entries get evicted even without traffic, MemoryCache doesn't give you that; you'd need your own idle timer for it.
//!
//! **Expiration tokens are different — push, not pull.**
//! `IChangeToken`-based expiration (e.g. `CancellationChangeToken`) registers a callback via `RegisterChangeCallback` at entry-creation time.
//! When the token fires, the callback runs immediately and evicts the entry — that part *is* genuinely event-driven/push-based, not polled.
//! It's really only time-based (`AbsoluteExpiration`/`SlidingExpiration`) that's handled via the pull model above.
//!
//! **Known rough edges worth knowing before you copy the design:**
//! - The check-and-set on `_lastExpirationScan` isn't guarded by a lock, so under concurrent load multiple full-dictionary scans can get scheduled at once — this method doesn't check if the scan isn't underway, and there is a possibility that ScanForExpiredItems will be invoked many times concurrently, which is exactly the kind of thundering-herd bug you'd want to avoid in a from-scratch implementation.
//! - At high entry turnover with eviction callbacks registered, each eviction gets its own `Task.Factory.StartNew` for the callback, which can flood the thread pool — ScanForExpiredItems calls CacheEntry.InvokeEvictionCallbacks() for each expired entry, and this routine uses Task.Factory.StartNew() to queue each eviction callback as a thread pool work item, causing queueing/backpressure under sustained load.
//!
//! **For your Zig implementation**, given you're explicitly performance-focused, I'd flag the O(n) linear sweep as the part *not* worth imitating.
//! MemoryCache gets away with it because sweeps are rate-limited to once a minute and most workloads don't have millions of resident entries,
//! but a full dictionary walk is a poor fit if you care about predictable latency or very large entry counts. The classic alternatives, in ascending order of complexity:
//!
//! - **Min-heap keyed by expiration deadline** — pop-while-expired is O(log n) per eviction, and you only touch entries that are actually near expiry, not the whole table.
//! - **Hierarchical timing wheel** (what Redis/Kafka/Netty use) — O(1) amortized insert and expiry-bucket advancement, at the cost of some coarser time-resolution and bucket bookkeeping.
//! - **Sorted skip-list/BTreeMap by deadline** if you want range queries over expiration times too.
//!
//! Any of these lets you decouple "how many entries exist" from "cost of finding what's expired," which the dictionary-scan approach explicitly doesn't do.
//! Combining that structure with the same lazy check-on-access trick (cheap, no reason to drop it) gives you the best of both:
//! O(1) amortized proactive eviction *and* zero-cost correctness on the read path even if the sweep hasn't caught something yet.
//!
//! # Me:
//! Okay, the in-place expiration evaluation totally makes sense.
//! Presumably a memory cache should have a lot of hits (otherwise, why are you using a cache?), so it should be rare to see an idle entry.
//! Another interesting issue that I found myself running into was more specific to memory management.
//! An issue arises when we reach expiration and other threads could be holding a reference to that memory.
//! It would be unsafe to free memory related to that expired entry without ensuring that there are no active references to it.
//! Thus, I attempted to handroll my own atomic reference-counting, but there could be an issue of contention when it's time to let an entry expire.
//! Here is the code as it exists right now: https://github.com/MiahDrao97/zutil/blob/main/src/mem_cache.zig#L394.
//! I have an open branch to address these concerns I've been having (I'm using spin locks, which aren't great for the CPU in high-contention scenarios).
//! One idea I had was to have the memory cache copy the entry's memory with the `SafeReader` struct so that ref-counting becomes unnecessary.
//! At the very least, we can setup a lock whenever a reader needs to copy an entry and then go from there. It becomes complex when an entry contains strings or other pointers since this could involve nested copying.
//! What are some of your thoughts?
//!
//! # Claudester:
//! Good — I pulled up the file. The relevant bit is the `Metadata.safeSwap`/`safeDestroy`/`safeRead` trio and the way `putEntry` (replace path) and `remove`/`clear` consume them:
//!
//! ```zig
//! while (!try metadata.safeSwap(io)) {}          // in putEntry's .replace branch
//! while (!m.safeDestroy()) : (try io.checkCancel()) {}   // in remove() / clear()
//! ```
//!
//! **Where the actual CPU cost is coming from**
//!
//! The CAS retry loop inside `safeRead` (incrementing the ref count) isn't really your problem —
//! that's a normal, cheap CAS-retry-on-contention pattern that every lock-free counter has, and it resolves in a handful of iterations.
//!
//! The expensive part is `safeSwap`/`safeDestroy`: they require `ref_count == 0` *before* the transition succeeds, and the calling code spins synchronously until that's true.
//! Under a read-heavy workload (which, as you said, a cache should be), there's no fairness mechanism —
//! a writer trying to swap or destroy can be starved indefinitely by a steady stream of readers, each of which is free to increment the count again the instant it drops toward zero.
//! That's a genuine livelock risk, not just "CAS retries are a little wasteful," and it's exactly the failure mode classic readers-writer spinlocks have when they favor readers.
//!
//! **Copy-on-read trades one cost for a worse one**
//!
//! Before getting to the fix — I'd push back a little on the copy-into-`SafeReader` idea as the primary solution.
//! It removes the ref-count contention, sure, but it reintroduces an allocation + memcpy on *every single read*, which for a cache whose entire purpose is "avoid doing expensive work repeatedly" is a strange trade:
//! you'd be guaranteeing an alloc on the hot path to avoid an atomic increment on the hot path.
//! For large entries especially, that's very likely a net loss.
//! And you've already found the sharp edge yourself — nested pointers force a real ownership-aware deep clone, which is a much bigger problem than the concurrency issue you're actually trying to solve.
//!
//! Worth noting: your doc comment already says entries are stored as **shallow copies** — pointer members aren't dereferenced.
//! That's a design decision you've already made at the `newEntry`/`overwriteEntry` layer.
//! I'd lean into that rather than fight it: keep MemCache scoped to POD/flat-layout values (which is what `mem.toBytes`/`bytesAsValue` already assumes),
//! and push ownership of anything with nested pointers onto the caller via the `Expiration.runCleanup` callback you already have.
//! Trying to make the cache itself deep-clone-aware is solving a problem your API surface has arguably already declined to take on.
//!
//! **The fix that fits your existing design: tombstone + last-reader-frees**
//!
//! Rather than requiring the writer to wait for `ref_count == 0` before transitioning, decouple "mark this entry as going away" from "free the memory":
//!
//! 1. **Removal/replace initiates a tombstone immediately** — no spin, no waiting for zero.
//! Just one atomic store (e.g. set a `.retiring` state), which either succeeds (you're the one responsible for this entry's fate) or fails because someone else already retired it —
//! same single-winner CAS you already do, just without looping on the *count* condition.
//! 2. **New readers reject a retiring entry** — `safeRead` already has a place for this:
//! `.destroying => return .destroying` (or a new `.retiring` variant) simply means "treat as a miss," same as today.
//! No new readers join once retirement starts.
//! 3. **Whoever's decrement crosses zero does the free.**
//! This is the key trick: `fetchSub` returns the *previous* value.
//! Exactly one thread's decrement will ever observe "previous was 1" (i.e., it just brought the count to zero) — that's a mathematical guarantee, not a race you need to guard with another CAS.
//! So: in `release()`, after the `fetchSub`, check if the entry is retiring *and* the previous count was 1.
//! If both, that release() call is now responsible for the actual `gpa.free()` + cleanup callback — not the thread that called `remove()`.
//! 4. **The retiring thread itself just needs to handle the case where the count was already zero** at the moment it set the tombstone (no active readers) —
//! then it does the free itself, synchronously, no spin required either way.
//!
//! This is the same "last one out turns off the lights" pattern used in refcounted lock-free structures generally (Linux `kref_put`, Rust `Arc`'s drop).
//! It keeps your existing `RefCount` atomic and CAS machinery almost entirely intact — you're just moving *when* the free happens (from "writer waits, then frees" to "whoever's decrement empties it, frees") rather than replacing the whole scheme.
//!
//! For the `.replace` path specifically, this maps naturally onto an RCU-style publish:
//! swap the value pointer in `ValueCache` first (so new readers immediately see the new value), then treat the *old* value+metadata as a retiring generation subject to the same last-reader-frees rule.
//! You're already halfway there — you just currently gate the pointer swap behind the zero-wait instead of doing it first and deferring cleanup.
//!
//! **One more thing worth checking:** since every `read` call does an atomic RMW on `ref_count`, make sure `Metadata` isn't sharing a cache line with neighboring entries' metadata in `MetadataCache`'s backing array —
//! if `Metadata` isn't padded to `std.atomic.cache_line`, hot concurrent reads across *different* keys can false-share and bounce cache lines between cores even though logically they're touching unrelated entries.
//! Given you're already cache-line-aligning the value storage, the metadata array is the one place I'd double check.
//!
//! If you want to go further than this later — say, if you find even the tombstone-CAS has too much contention under really hot key churn —
//! epoch-based reclamation (à la Crossbeam's `epoch` crate or RCU) is the "proper" general answer to this whole class of problem,
//! since it eliminates the per-read atomic write entirely in favor of readers just recording an epoch they're "in." But that's a meaningfully bigger redesign, and I don't think you need it yet.
//! The tombstone approach should kill the livelock with a much smaller diff against what you already have.
//!
//! # Me:
//! Interesting note on the padding of `Metadata`.
//! Are you saying that the backing array of the hashmap should always be padded to `std.atomic.cache_line`, regardless of the alignment value passed in to `Aligned()`?
//! The intent behind that alignment was for the max alignment of an entry so that I can cast the aligned byte array to the entry type without any thought given to the `Metadata` map.
//!
//! # Claudeface:
//! Good distinction to draw out — no, `max_alignment` and the padding concern are unrelated, and I should've been clearer about that.
//!
//! `max_alignment` governs the **value buffer's** alignment —
//! it exists so that `mem.bytesAsValue`/`bytesAsSlice` can safely reinterpret the `[]u8` cache storage as `*const T` without UB, regardless of what `T` the caller stashes in.
//! That's a correctness requirement tied to the type being cached, and it has nothing to do with how `Metadata` structs sit in `MetadataCache`'s backing array.
//!
//! The false-sharing concern is a separate, purely mechanical one:
//! `std.ArrayHashMapUnmanaged` stores its values as a **dense, tightly packed array**.
//! `Metadata` instances for different keys sit back-to-back in memory with no gaps, in insertion order. Your `Metadata` is roughly:
//!
//! ```
//! expiration: Expiration   // Io.Timeout + a fn ptr + a context ptr — probably 24-32 bytes
//! len: u32
//! ref_count: Atomic(RefCount)  // u16
//! ```
//!
//! That's easily 2-3 `Metadata` instances per 64-byte cache line.
//! So if two threads are concurrently incrementing/decrementing `ref_count` for two *different* keys that happen to land in adjacent slots,
//! you get cache-line ping-pong between cores even though there's zero logical contention between those two operations.
//! That's textbook false sharing, and it's independent of anything the caller's `T` looks like.
//!
//! **Should you always pad `Metadata` to a full cache line regardless of `max_alignment`?**
//! I'd stop short of "always" — it's a real tradeoff, not a free win:
//!
//! - **Cost of padding everything:** if `Metadata` is naturally ~24-32 bytes, forcing it to 64 means roughly doubling the size of the metadata table.
//! That directly hurts the thing dense packing was buying you — good locality when you scan (`format()`/`threadsafeDump()`,
//! and implicitly whenever `getPtr` walks probe sequences) — and for a cache with many entries but modest concurrency, that memory/locality cost may not be worth paying.
//! - **Whether it even bites depends on your workload:**
//! false sharing here only matters when two *hot* keys happen to land in adjacent slots and get hit concurrently from different cores.
//! Since the array is insertion-ordered (not sparse), that's essentially incidental — a function of insertion order relative to which keys turn out to be hot.
//! A cache with a handful of very hot keys inserted early and mostly-cold keys after has a decent chance of avoiding it entirely;
//! a cache under heavy concurrent churn across many hot keys is much more likely to hit it.
//! This is genuinely a "profile before you pay for it" situation — `perf c2c` (cache-to-cache transfer analysis) would tell you concretely whether it's happening rather than guessing.
//!
//! **If you do want to fix it, I'd do it surgically rather than blanket-padding `Metadata`.**
//! The only field under concurrent *write* pressure is `ref_count` — `len` and `expiration` are read-heavy/write-rare (only touched on create/replace). So split them:
//!
//! ```zig
//! // Hot, mutated every read/release — isolate to its own cache line per entry
//! const RefCountCell = struct {
//!     ref_count: Atomic(RefCount),
//!     _pad: [std.atomic.cache_line - @sizeOf(Atomic(RefCount))]u8 = undefined,
//! };
//!
//! // Cold, stable after creation — keep this densely packed for scan locality
//! const Metadata = struct {
//!     expiration: Expiration,
//!     len: u32,
//! };
//! ```
//!
//! with a parallel array (or a second `ArrayHashMapUnmanaged` keyed the same way,
//! or just a plain `std.ArrayListUnmanaged(RefCountCell)` indexed by the same slot index the hashmap already assigns) holding the `RefCountCell`s.
//! That gets you cache-line isolation exactly where the false sharing risk actually lives, without bloating the part of the metadata table that benefits from staying small and densely packed.
//! It's a bit more bookkeeping (you now need to keep two structures' indices in sync, or store an index/pointer from one into the other), but it avoids the blunt "pad everything to 64 bytes" cost.
//!
//! Given the tombstone rework we just discussed also touches this same struct, it's probably worth doing both changes together rather than in two passes —
//! the `RefCountCell` split gives you a natural place to put the retiring flag too, right next to the count it gates.
//!
//! # Me:
//! So let's think about the "epoch" approach as well.
//! In my own usage of memory caches, they usually will re-fetch the data in an interval of 30 seconds to 5 minutes, re-caching the new data with the same key.
//! One thing I'm worried about with tombstoning is that if we know we're retiring an entry and new readers attempt to get the entry,
//! there could be an overlap of old readers still on the old tomb-stoned entry while new readers will be on a new entry with the same key.
//! I feel this necessitates the epoch pattern so that we know entries with key X are now on the epoch,
//! and that should be the entry new readers return while the old one is still being de-commissioned until the final reader turns out the light.
//! Is that an accurate mental model of the problem?
//!
//! # Claudalicious:
//! Yes — that's exactly the bug, and it's worth being precise about *why*, because it changes what the fix needs to be.
//!
//! **The real problem: two generations sharing one identity**
//!
//! In your current code (and in my tombstone sketch as I described it, if taken literally), there's one `Metadata` struct per key, and `safeSwap` reuses it in place:
//! it CASes `ref_count` back to `.zero` and swaps the value pointer underneath.
//! The bug is that `SafeReader.ref_count` is just `*Atomic(RefCount)` — a raw pointer into that one shared struct.
//! If an old reader is still holding a `SafeReader` from *before* the swap, its eventual `release()` call does `fetchSub` on that same atomic — which, post-swap, is now counting *new*-generation readers.
//! An old reader releasing decrements the new generation's count;
//! a burst of old releases could even drive the new generation's count to zero (or negative, into your sentinel range) while new readers are still actively using it.
//! That's a correctness bug, not just a performance one — refcount corruption across generations, potentially freeing memory a live reader still holds a slice to.
//!
//! So yes: **a single ref_count field cannot represent two overlapping generations of the same key.** Your instinct is right.
//!
//! **But the fix is generation-scoping, not necessarily full epoch reclamation — those are two different granularities of the same idea, and it's worth separating them:**
//!
//! *Lightweight fix — per-key generations:*
//! On replace, don't touch the old `Metadata` in place at all.
//! Allocate a **new** `Metadata` (fresh `ref_count` starting at `.zero`) for the new value, and atomically swap the hashmap's pointer/slot so that new lookups of key X immediately resolve to the new generation.
//! The old `Metadata` — with whatever `ref_count` it's sitting at — becomes an orphan: unreachable from any new lookup, but still valid for any `SafeReader`s that already captured a pointer to it before the swap.
//! It just needs to sit somewhere (a small retire list, or an async task in your `expiration_group`) waiting for its own `ref_count` to hit zero via the same last-reader-frees rule,
//! completely independent of whatever the new generation's counter is doing.
//!
//! This is really just: give every generation its own identity, so cross-generation corruption is structurally impossible rather than something you have to reason your way out of.
//! No global epoch counter required.
//! Given your workload — refetch every 30s–5min, so at any instant you'll typically have at most one old generation lingering briefly while its last readers finish.
//! The number of concurrently-live generations per key is almost always 1, occasionally 2.
//! A tiny retire list per key (or even just an `Io.Group.concurrent` task holding the orphaned `Metadata` + buffer by value/pointer until it can free itself) handles that fine.
//!
//! *The heavier tool — true epoch-based reclamation (RCU/Crossbeam-style):*
//! This is a different mechanism solving a different pain point.
//! Its point isn't "which generation does this reader belong to" (per-key concept) — it's **eliminating the atomic RMW on every read entirely**, cache-wide.
//! Readers don't touch a shared counter at all; they just stamp a per-thread epoch value on entry/exit (a plain, uncontended store — no cross-core cache-line traffic),
//! and a background reclaimer periodically checks "have all threads advanced past epoch E" before freeing anything retired in epoch E.
//! That's the mechanism you'd reach for if profiling showed that even the cheap `fetchAdd`/`fetchSub` pair in `safeRead`/`release` —
//! not the wait-for-zero spin, which the tombstone fix already kills, but the *steady-state* increment/decrement itself — was the bottleneck, typically under very high core counts hammering the same hot key.
//!
//! Given your actual numbers — reads dominating, writes every 30s-5min, a handful of overlapping generations at most —
//! I'd bet the per-key generation fix resolves the correctness issue and the earlier livelock issue without needing to bring in epochs at all.
//! Epochs buy you lower per-read cost at the price of real complexity (thread registration, deferred/batched frees, a background epoch-advancing reclaimer) and deferred reclamation latency (memory isn't freed the instant the last reader's gone — it's freed once the global epoch advances past it, which is coarser).
//! I'd treat it as the escalation path if you later find the per-read atomic itself shows up in a profile, not the default starting point.

/// Aligned to cache line alignment boundary to prevent CPU cache invalidation.
/// It's expected for memory in this cache to be accessed via RAM rather than CPU caches.
pub const Default = Aligned(.fromByteUnits(std.atomic.cache_line), null);

/// All entries are aligned to this max alignment.
pub fn Aligned(comptime max_alignment: Alignment, comptime max_entries: ?u32) type {
    return struct {
        /// All active entries -
        /// Once an entry is tombstoned, it disappears from this map until the last reader is released, which frees the memory.
        active_entries: EntryMap,
        /// For quickly creating instances of `EntryData`
        entry_pool: EntryPool,
        /// Mutex that guards reads/writes to the cache
        mutex: Io.Mutex,
        /// For internal memory operations
        allocator: Allocator,
        /// Configurable behavior
        opts: Options,

        const MemCacheSelf = @This();

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

        /// Note that the MemCache is a managed data structure (i.e. it stores its own allocator).
        /// The reason for this is the complex lifetimes required for reference counting.
        pub fn init(gpa: Allocator, opts: Options) Allocator.Error!MemCacheSelf {
            return .{
                .active_entries = .empty,
                .mutex = .init,
                .entry_pool = if (max_entries) |m| try .initCapacity(gpa, m) else .empty,
                .allocator = gpa,
                .opts = opts,
            };
        }

        /// Creates a new entry, returning `error.CacheClobber` if an entry with this `key` already exists.
        /// Ensure that `gpa` is thread-safe.
        ///
        /// Keys are not stored in this memory cache, so it's the responsibility of the caller to keep track of keys.
        /// The caller must also know the type of the stored values since they're agnostically stored as `[*]const u8`.
        /// Note that this entry is saved as a shallow copy, which means that pointer members are not dereferenced and saved into the cache.
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
        /// Ensure that `gpa` is thread-safe.
        /// Runs `expiration.cleanup()` on error.
        ///
        /// Keys are not stored in this memory cache, so it's the responsibility of the caller to keep track of keys.
        /// The caller must also know the type of the stored values since they're agnostically stored as `[*]const u8`.
        /// Note that this entry is saved as a shallow copy, which means that pointer members are not dereferenced and saved into the cache.
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
        /// If a `SafeReader` can be obtained from an existing entry, it is returned.
        /// Otherwise, creates an entry using the `createEntryFn` and passed-in context and returns a `SafeReader` to the new entry.
        /// Be sure to call `release()` on the `SafeReader`.
        /// Assumes that the duration of `expiration` is longer than the time it takes to lock a reader.
        ///
        /// Keys are not stored in this memory cache, so it's the responsibility of the caller to keep track of keys.
        /// Note that this entry is saved as a shallow copy, which means that pointer members are not dereferenced and saved into the cache.
        ///
        /// Use `getOrPutSliceEntry()` for slices.
        pub fn getOrPutEntry(
            self: *MemCacheSelf,
            comptime TReturn: type,
            io: Io,
            key: []const u8,
            expiration: Expiration,
            create_entry_ctx: anytype,
            createEntryFn: fn (@TypeOf(create_entry_ctx), Expiration.CleanupContextOut) TReturn,
        ) (ErrorComponent(TReturn) || GetOrPutError)!Reader {
            comptime checkTypeCompatibility(OkComponent(TReturn));

            if (try self.read(io, key)) |reader| {
                return reader;
            }

            var expiration_cpy: Expiration = expiration;
            const val: OkComponent(TReturn) = try @as(
                ErrorComponent(TReturn)!OkComponent(TReturn),
                createEntryFn(create_entry_ctx, .{ .ctx = &expiration_cpy.cleanup_context.ctx }),
            );

            const entry_reader: Entry = .{ .raw_value = &mem.toBytes(val) };
            errdefer expiration_cpy.cleanup(entry_reader);

            const v: []align(max_alignment.toByteUnits()) const u8 = try self.createEntryValue(entry_reader.raw_value);
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

            return (try self.read(io, key)) orelse // should be impossible...
                debug.panic("Finished performing `getOrPutEntry` with key '{s}', but the entry was not found.", .{key});
        }

        /// Creates a new slice entry, returning `error.CacheClobber` if an entry with this `key` already exists.
        /// Ensure that `gpa` is thread-safe.
        /// The contents of the entry are copied to the cache.
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
        /// Ensure that `gpa` is thread-safe.
        /// The contents of the entry are copied to the cache.
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
        /// If a `SafeReader` can be obtained from an existing entry, it is returned.
        /// Otherwise, creates an entry using the `createEntryFn` and passed-in context and returns a `SafeReader` to the new entry.
        /// Be sure to call `release()` on the `SafeReader`.
        /// Assumes that the reader can be locked before the expiration is up.
        /// The contents of the entry are copied to the cache.
        pub fn getOrPutSliceEntry(
            self: *MemCacheSelf,
            comptime TReturn: type,
            io: Io,
            key: []const u8,
            expiration: Expiration,
            create_entry_ctx: anytype,
            createEntryFn: fn (@TypeOf(create_entry_ctx), Expiration.CleanupContextOut) TReturn,
        ) (ErrorComponent(TReturn) || GetOrPutError || OpenReaderError)!Reader {
            const SliceType = switch (@typeInfo(OkComponent(TReturn))) {
                .pointer => |p| switch (p.size) {
                    .slice => p.child,
                    else => @compileError("Expected `createEntryFn` to have a return type coercible to `TError![]const T`"),
                },
                else => @compileError("Expected `createEntryFn` to have a return type coercible to `TError![]const T`"),
            };
            comptime checkTypeCompatibility([]const SliceType);

            var expiration_cpy: Expiration = expiration;
            const val: []const SliceType = try @as(
                ErrorComponent(TReturn)![]const SliceType,
                createEntryFn(create_entry_ctx, .{ .ctx = &expiration_cpy.cleanup_context.ctx }),
            );
            const entry_reader: Entry = .{ .raw_value = mem.sliceAsBytes(val) };
            errdefer expiration_cpy.cleanup(entry_reader);

            if (try self.read(io, key)) |reader| {
                return reader;
            }
            const v: []align(max_alignment.toByteUnits()) const u8 = try self.createEntryValue(entry_reader.raw_value);
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

            return (try self.read(io, key)) orelse // should be impossible...
                debug.panic("Finished performing `getOrPutSliceEntry` with key '{s}', but the entry was not found.", .{key});
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
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);

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

        /// Read an entry, producing a `SafeReader` that repesents an active read on the entry.
        /// Until the `SafeReader` is released, this entry is safe to read.
        /// Returns null if no entry exists with this key.
        /// Returns `error.TooManyOpenReaders` if the ref count would exceed max (which is max u16 - 1).
        ///
        /// WARN : If the caller fails to call `release()` on the reader, it may produce a deadlock or segmentation fault later in the program.
        pub fn read(self: *MemCacheSelf, io: Io, key: []const u8) OpenReaderError!?Reader {
            const k: StringHash = .hashStr(key);

            try self.mutex.lock(io);
            defer self.mutex.unlock(io);

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
        /// Until the resulting `SafeReader` is released, this entry is safe to read.
        /// Returns null if no entry exists with this key.
        ///
        /// WARN : If the caller fails to call `release()` on the reader, it may produce a deadlock or segmentation fault later in the program.
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

        /// Remove a cache entry, freeing the cached value in the process.
        pub fn remove(self: *MemCacheSelf, io: Io, key: []const u8) Io.Cancelable!bool {
            const k: StringHash = .hashStr(key);

            try self.mutex.lock(io);
            defer self.mutex.unlock(io);

            if (self.active_entries.fetchSwapRemove(k)) |entry| {
                log.debug("Found entry '{s}' (hash=0x{x}) for removal; preparing to tombstone...", .{ key, k });
                entry.value.tombstone(self);
                return true;
            }
            return false;
        }

        /// Clear all entries from the cache, freeing the memory created for the cached values.
        /// In a cancellation scenario, nothing has been removed; we were simply waiting for the lock.
        pub fn clear(self: *MemCacheSelf, io: Io) Io.Cancelable!void {
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);

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
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);

            try self.format(writer);
        }

        /// Deinitialize the memory cache, freeing all entries.
        /// WARN : Only call this during shutdown.
        /// Will panic if any active readers are found.
        pub fn deinit(self: *MemCacheSelf) void {
            log.debug("WARNING: Preparing to destroy self!!!\n{f}", .{self});
            self.unsafeClear();
            self.active_entries.deinit(self.allocator);
            self.entry_pool.deinit(self.allocator);
            self.* = undefined;
        }

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
                    .none => return false,
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
            try mem_cache.newEntry(testing.io, "struct_val", s, .none);

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
                mem_cache.newEntry(testing.io, "struct_val", num, .none),
            );
            try testing.expectError(
                error.CacheClobber,
                mem_cache.newSliceEntry(u8, testing.io, "struct_val", "oh my", .none),
            );

            const arr: [3]u32 = .{ 1, 2, 3 };
            try mem_cache.newSliceEntry(u32, testing.io, "slice", &arr, .none);
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
                mem_cache.newEntry(testing.io, "slice", num, .none),
            );
            try testing.expectError(
                error.CacheClobber,
                mem_cache.newSliceEntry(u8, testing.io, "slice", "oh my", .none),
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
            const expiration: Timeout = .{
                .duration = .fromMilliseconds(5),
            };

            try mem_cache.newEntry(testing.io, "struct_val", s, .init(expiration, .{}));

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
                mem_cache.newEntry(testing.io, "struct_value", s, .none),
            );
            try minefield.cleanup(.reset);
            try testing.expectEqual(0, mem_cache.active_entries.count());

            minefield.detonateOn(.lock_mutex, error.Canceled);
            try testing.expectError(
                error.Canceled,
                mem_cache.newEntry(testing.io, "struct_value", s, .none),
            );
            try minefield.cleanup(.reset);
            try testing.expectEqual(0, mem_cache.active_entries.count());

            minefield.detonateOn(.insert_entry, error.OutOfMemory);
            try testing.expectError(
                error.OutOfMemory,
                mem_cache.newEntry(testing.io, "struct_value", s, .none),
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
                mem_cache.newSliceEntry(u32, testing.io, "my_slice", &arr, .none),
            );
            try minefield.cleanup(.reset);
            try testing.expectEqual(0, mem_cache.active_entries.count());

            minefield.detonateOn(.lock_mutex, error.Canceled);
            try testing.expectError(
                error.Canceled,
                mem_cache.newEntry(testing.io, "my_slice", &arr, .none),
            );
            try minefield.cleanup(.reset);
            try testing.expectEqual(0, mem_cache.active_entries.count());

            minefield.detonateOn(.insert_entry, error.OutOfMemory);
            try testing.expectError(
                error.OutOfMemory,
                mem_cache.newSliceEntry(u32, testing.io, "my_slice", &arr, .none),
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
                try mem_cache.newSliceEntry(u32, testing.io, "my_slice", &arr, .none);
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
                try mem_cache.newSliceEntry(u32, testing.io, "my_slice", &arr, .none);
                const reader: Default.Reader = (try mem_cache.read(testing.io, "my_slice")) orelse return error.NoEntry;
                defer reader.release(&mem_cache);

                // remove while reader is still active...
                try testing.expect(try mem_cache.remove(testing.io, "my_slice"));
                // confirm we CAN'T get a new reader now that it's tombstoned
                if (try mem_cache.read(testing.io, "my_slice")) |_| return error.ExpectedNoEntry;

                // on the deferred release, memory should get freed
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
            try mem_cache.newSliceEntry(u32, testing.io, "my_slice", &arr, .none);
            try mem_cache.newEntry(testing.io, "struct_val", s, .none);

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

            const expiration: Expiration = .init(.{ .duration = .fromMilliseconds(5) }, .{});
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

                try mem_cache.overwriteEntry(testing.io, "my_entry", num1, .none);
                try mem_cache.overwriteEntry(testing.io, "my_entry", num2, .none);

                if (try mem_cache.read(testing.io, "my_entry")) |reader| {
                    defer reader.release(&mem_cache);

                    try testing.expectEqual(num2, reader.entry.read(i32).*);
                }
            }
            // more complex with 2 readers, reading from different generations
            {
                const num1: i32 = 64;
                const num2: i32 = -72;

                try mem_cache.overwriteEntry(testing.io, "my_entry", num1, .none);
                const reader_a: Default.Reader = (try mem_cache.read(testing.io, "my_entry")) orelse return error.NoEntry;
                defer reader_a.release(&mem_cache);

                try mem_cache.overwriteEntry(testing.io, "my_entry", num2, .none);
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

            try mem_cache.overwriteSliceEntry(u8, testing.io, "my_slice", slice1, .none);
            try mem_cache.overwriteSliceEntry(u8, testing.io, "my_slice", slice2, .none);

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
            try mem_cache.overwriteSliceEntry(u8, testing.io, "my_slice", slice, .none);

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
            try mem_cache.overwriteSliceEntry(u8, testing.io, "my_slice", slice, .none);

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
            try mem_cache.overwriteSliceEntry(u8, testing.io, "my_slice", slice, .none);

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
                const reader: Default.Reader = try mem_cache.getOrPutEntry(i32, testing.io, "my_val", .none, {}, struct {
                    fn createEntry(_: void, _: Expiration.CleanupContextOut) i32 {
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

                    fn createEntry(this: @This(), cleanup_ctx_out: Expiration.CleanupContextOut) Allocator.Error!*const u32 {
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
                    .init(.none, .{ .runCleanup = EntryManager.cleanup }),
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
                const reader: Default.Reader = try mem_cache.getOrPutSliceEntry([]const u8, testing.io, "my_val", .none, {}, struct {
                    fn createEntry(_: void, _: Expiration.CleanupContextOut) []const u8 {
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

                    fn createEntry(this: @This(), cleanup_ctx_out: Expiration.CleanupContextOut) Allocator.Error![]const u8 {
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
                    .{ .timeout = .none, .cleanup_context = .{ .runCleanup = EntryManager.cleanup } },
                    entry_manager,
                    EntryManager.createEntry,
                );
                defer reader.release(&mem_cache);

                try testing.expectEqualStrings("whoa", reader.entry.readSlice(u8));
            }
        }

        test waitForReader {
            var mem_cache: Default = try .init(testing.allocator, .{});
            defer mem_cache.deinit();

            const slice: []const u8 = "asdf";
            try mem_cache.overwriteSliceEntry(u8, testing.io, "my_slice", slice, .none);

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
                    cleanup_ctx_out: Expiration.CleanupContextOut,
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
            const expiration: Expiration = .init(
                .{ .duration = .fromSeconds(15) },
                .{ .runCleanup = EntryManager.cleanup }, // this will be run on removal/expiration
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
                    cleanup_ctx_out: Expiration.CleanupContextOut,
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
            const expiration: Expiration = .init(
                .{ .duration = .fromSeconds(15) },
                .{ .runCleanup = EntryManager.cleanup }, // this will be run on removal/expiration
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
        ctx: *anyopaque = @constCast(&@as(u8, 0xAA)),
        /// Cleanup function to be run when the entry is removed.
        runCleanup: *const fn (context: *anyopaque, entry: Entry) void = noopCleanup,
    };

    /// Assign a context to this out parameter when creating an entry
    pub const CleanupContextOut = struct {
        ctx: **anyopaque,

        /// Set the cleanup context to any pointer
        pub fn setContext(self: CleanupContextOut, any_ptr: *anyopaque) void {
            self.ctx.* = any_ptr;
        }
    };

    /// No expiration: assumes that nothing needs to be run when the entry is removed
    pub const none: Expiration = .{
        .timeout = .none,
        .cleanup_context = .{},
    };

    pub fn init(timeout: Timeout, cleanup_context: CleanupContext) Expiration {
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
    none,

    pub fn format(self: Timeout, writer: *Io.Writer) Io.Writer.Error!void {
        switch (self) {
            .duration => |d| try writer.print("{t}: {d}", .{ self, d.nanoseconds }),
            .deadline => |d| try writer.print("{t}: {d}", .{ self, d.nanoseconds }),
            .tombstoned, .none => try writer.writeAll(@tagName(self)),
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
    max = std.math.maxInt(u16) - 1,
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
