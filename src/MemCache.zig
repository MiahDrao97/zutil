//! WARN : Only compiles on Zig master
const MemCache = @This();

/// The cache itself
cache: Cache,
/// Io group that handles entry expirations
expiration_group: Io.Group,
/// Mutex that guards modifications to the cache
mutex: Io.Mutex,
/// Arena strictly use for creating values
/// We have to use an arena because we don't necessarily know the size of the pointer/slice we remove from the cache in the event of expiration.
/// OPTIMIZE : See if we can get away with a growing byte array or something because an arena pattern like this won't reuse free bytes
value_arena: ArenaAllocator,

pub const Error = Allocator.Error || Io.Cancelable || Io.ConcurrentError;

pub fn init(gpa: Allocator) MemCache {
    return .{
        .cache = .empty,
        .expiration_group = .init,
        .mutex = .init,
        .value_arena = .init(gpa),
    };
}

/// Creates a new entry.
/// The key is copied when there is an expiration provided.
/// Otherwise, on no expiration, it's assumed that the key is long-lived.
/// If entry is already a pointer or slice, then the pointer will be stored directly in the cache.
/// Otherwise, a pointer will be created and assigned the value of `entry`.
pub fn newEntry(
    self: *MemCache,
    io: Io,
    gpa: Allocator,
    key: []const u8,
    entry: anytype,
    expiration: Io.Timeout,
) Error!void {
    const EntryType, const t: enum { ptr, slice, value } = switch (@typeInfo(@TypeOf(entry))) {
        .pointer => |p| .{
            p.child, switch (p.size) {
                .slice => .slice,
                else => .ptr,
            },
        },
        else => .{ @TypeOf(entry), .value },
    };

    try mine.stepOn(.create_ptr);
    const entry_ptr: [*]const EntryType = switch (comptime t) {
        .ptr => @ptrCast(entry),
        .slice => entry.ptr,
        .value => create_entry: {
            const ptr: *EntryType = try self.value_arena.allocator().create(EntryType);
            ptr.* = entry;
            break :create_entry @ptrCast(ptr);
        },
    };
    errdefer if (!comptime t == .value) gpa.destroy(&entry_ptr[0]);

    try mine.stepOn(.copy_key);
    const k: []const u8 = switch (expiration) {
        .none => key,
        else => try gpa.dupe(u8, key),
    };
    errdefer switch (expiration) {
        .none => {},
        else => gpa.free(k),
    };

    // critical section
    {
        try mine.stepOn(.lock_mutex);
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);

        try mine.stepOn(.insert_entry);
        try self.cache.put(gpa, k, &entry_ptr[0]);
    }
    errdefer debug.assert(self.cache.remove(k));

    try mine.stepOn(.start_expiration);
    switch (expiration) {
        .none => {},
        else => try self.expiration_group.concurrent(io, handleExpiration, .{ self, io, gpa, k, expiration }),
    }
}

fn handleExpiration(
    self: *MemCache,
    io: Io,
    gpa: Allocator,
    key: []const u8,
    expiration: Io.Timeout,
) Io.Cancelable!void {
    switch (expiration) {
        .none => unreachable,
        else => {},
    }
    // don't wanna leak memory; this must be freed no matter what
    defer gpa.free(key);

    expiration.sleep(io) catch |err| switch (err) {
        Io.SleepError.Canceled => {
            // okay, we've hit our timeout: remove the cache entry
        },
        Io.SleepError.UnsupportedClock => @panic("Clock does not support timeout operation."),
        Io.SleepError.Unexpected => {
            log.warn("Encountered unexpected error when removing expired entry {s}. This entry will still be cleared.", .{key});
            if (@errorReturnTrace()) |trace| debug.dumpStackTrace(trace);
        },
    };

    // if this returns `error.Canceled`, then the cache is being de-initialized,
    // so it doesn't matter if we remove the entry in the end or not
    try self.mutex.lock(io);
    defer self.mutex.unlock(io);

    // this could have been removed already
    _ = self.cache.remove(key);
}

pub fn getRaw(self: *MemCache, io: Io, key: []const u8) Io.Cancelable!?*const anyopaque {
    try self.mutex.lock(io);
    defer self.mutex.unlock(io);

    return self.cache.get(key);
}

pub fn get(self: *MemCache, comptime T: type, io: Io, key: []const u8) Io.Cancelable!?*const T {
    return if (try self.getRaw(io, key)) |entry|
        @ptrCast(@alignCast(entry))
    else
        null;
}

pub fn getMany(self: *MemCache, comptime T: type, io: Io, key: []const u8) Io.Cancelable!?[*]const T {
    return if (try self.getRaw(io, key)) |entry|
        @ptrCast(@alignCast(entry))
    else
        null;
}

pub fn getSlice(self: *MemCache, comptime T: type, io: Io, key: []const u8, len: usize) Io.Cancelable!?[]const T {
    return if (try self.getMany(io, key)) |entry|
        entry[0..len]
    else
        null;
}

pub fn remove(self: *MemCache, io: Io, key: []const u8) Io.Cancelable!bool {
    try self.mutex.lock(io);
    defer self.mutex.unlock(io);

    return self.cache.remove(key);
}

pub fn deinit(self: *MemCache, io: Io, gpa: Allocator) void {
    self.expiration_group.cancel(io);
    self.cache.deinit(gpa);
    self.value_arena.deinit();
    self.* = undefined;
}

test get {
    var mem_cache: MemCache = .init(testing.allocator);
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

const mine = @import("minefield.zig").set(enum {
    create_ptr,
    copy_key,
    lock_mutex,
    insert_entry,
    start_expiration,
}, newEntry);

const std = @import("std");
const debug = std.debug;
const testing = std.testing;
const log = std.log.scoped(.MemCache);
const Cache = std.StringHashMapUnmanaged(*const anyopaque);
const Allocator = std.mem.Allocator;
const Io = std.Io;
const ArenaAllocator = std.heap.ArenaAllocator;
