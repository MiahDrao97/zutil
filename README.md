# Zutil
Library of quick utilities that I find myself copying and pasting in various Zig projects.
I made this primarily for myself, but perhaps others can find it useful.

## Installation

You can use the `zig fetch` command like so:
```
zig fetch https://github.com/MiahDrao97/zutil/archive/main.tar.gz --save
```

Then add the import to your modules in your `build.zig`:
```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zutil_module = b.dependency("zutil", .{}).module("zutil");
    const my_module = b.addModule("my_module", .{
        .root_source_file = b.path("src/my_module/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zutil", .module = zutil_module },
        },
    });

    // rest of build def...
}
```

# Features

## `Managed(T)`
This is essentially an arena and a value of type `T`.
A managed value is incredibly useful when lots of memory is required to create a value,
resulting in situations where you can't (or event don't want to) free the resulting memory.
A common scenario I find myself using this pattern is with text-parsing or tree-like memory structures.

Example usage (just assume I've done my imports):
```zig
const Value = struct {
    // things that would presumbly require vast/complex memory
};

fn parse(gpa: Allocator, to_parse: []const u8) !Managed(Value) {
    const CreateValue = struct {
        str: []const u8,

        fn parseString(this: @This(), arena: Allocator) !Value {
            // do work to create the value...
            return .{};
        }
    };

    const ctx: CreateValue = .{ .str = to_parse };

    // 2-step initialization required here...
    var value: Managed(Value) = undefined;
    // calls the quasi-closure that we've assembled
    // if the closure returns an error, the arena under the hood will `deinit()`, so no leaks occur if the value fails to be created
    return try value.create(gpa, ctx, CreateValue.parseString);
}
```

## UUID
Currently supporting v3, v4, v5, and v7 for UUID generation.
Assumes any 16 bytes can be a valid UUID, but provides parsing and some printing/formatting options.

Example usage:
```zig
const std = @import("std");
const gpa: std.Allocator = std.testing.allocator;

const uuid: Uuid = .v4(std.testing.io);
std.debug.print("UUID: {f}\n", .{uuid}); // formatted like xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx (lower-case) by default
const uuid_str: []const u8 = try uuid.toStringAlloc(gpa, .{}); // can pass in format options
defer gpa.free(uuid_str);

const parsed: Uuid = try .from(uuid_str);
try std.testing.expect(uuid.eql(parsed));
```

## `cli` Namespace
This namespace contains structures useful for parsing CLI args.
Use `Arg` for arguments that will be assigned a value.

Example usage of `Arg`:
```zig
const MyEnum = enum { asdf, blarf };
const cmd: []const u8 = "MyProgram.exe --some-val asdf";
const cmd_line_w: []const u16 = try std.unicode.utf8ToUtf16LeAlloc(testing.allocator, cmd);
defer testing.allocator.free(cmd_line_w);

// yes, I'm on Windows :P
var iter_windows: ArgIteratorWindows = try .init(testing.allocator, cmd_line_w);
defer iter_windows.deinit();

var iter: ArgIterator = .{ .inner = iter_windows };
// this is the argument we'll store the value in
var some_value: Arg = .unassigned;
var optional_value: Arg = .defaultValue("foo");

// discard first argument because that's executable name
_ = iter.next();
while (iter.next()) |arg| {
    // which argument name(s) we're parsing for
    if (try some_value.parseFor(&.{"--some-val", "-s"}, arg, &iter)) continue;
    if (try optional_value.parseFor(&.{"--optional-value", "-o"}, arg, &iter)) continue;
    // return error for unknown arguments
    return error.UnrecognizedArgument;
}
// use the `to()` method to easily convert arguments to enums, integers, or floats
const as_enum: MyEnum = try some_value.to(MyEnum);
try testing.expectEqual(.asdf, as_enum);
```

For boolean values to switch on or off, use the `Flag` type.

Example usage:
```zig
const cmd: []const u8 = "MyProgram.exe -a";
const cmd_line_w: []const u16 = try std.unicode.utf8ToUtf16LeAlloc(testing.allocator, cmd);
defer testing.allocator.free(cmd_line_w);

var iter_windows: ArgIteratorWindows = try .init(testing.allocator, cmd_line_w);
defer iter_windows.deinit();

var iter: ArgIterator = .{ .inner = iter_windows };
var a: Flag = .off; // can alternatively default to `.on`: `.off` is a false value; `.on` is a true value
var b: Flag = .off;
var c: Flag = .off;

// create a flag set so the user can toggle any combination of flags as 1 argument (e.g. `-abc` toggles all 3 flags)
// note the set is opinionated as it assumes all args should start with a single leading dash
const flags = [_]Flag.Named{
    a.alias('a'),
    b.alias('b'),
    c.alias('c'),
};

var buffer: [FlagSet.requiredCapacityBytes(flags.len)]u8 = undefined;
var set: FlagSet = .initBounded(flags.len, flags, &buffer);

// discard first argument because that's executable name
_ = iter.next();
while (iter.next()) |arg| {
    if (set.toggleAny(arg)) continue;
    return error.UnrecognizedArgument;
}

try testing.expect(a.value);
try testing.expect(!b.value);
try testing.expect(!c.value);
```

## `string` Namespace
Currently only have casing utilies (convert a string to camel case, title case, kebab, snake, and screaming snake).
```zig
const std = @import("std");
const zutil = @import("zutil");
const Casing = zutil.string.Casing;

test {
    var stream: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stream.deinit();

    try stream.print("{f}", .{Casing.titleCase("something-to-case")});
    try std.testing.expectEqualStrings("SomethingToCase", stream.written());
}
```

## `MemCache` and `MemCacheAligned`
Used to memoize data of any type, presumably for the purpose of avoiding additional I/O calls.
Essentially functions as a dictionary with a string key type.
The value is stored agnostically as an array of bytes.
It's the caller's responsibility to interpret the value's type.
Additionally, the string keys are not stored in this data structure (only the hashes), so it's also the caller's responsibility to recreate the keys as they're needed.

This cache is intended to be shared between threads.
Entries can be read, exchanged, removed, or all entries can be cleared entirely.

This shows very basic usage of the memory cache:
```zig
// assume io: Io and gpa: Allocator exist in this context

var mem_cache: MemCache = .init;
defer mem_cache.deinit(io, gpa);

const StructValue = struct {
    a: f32,
    b: u16,
};

const s: StructValue = .{ .a = 3.14, .b = 5 };
const expiration: Io.Timeout = .{
    .duration = .{
        .raw = .fromSeconds(15),
        .clock = .awake,
    },
};
// create a new entry in the memory cache with an expiration
try mem_cache.newEntry(io, gpa, "struct_val", s, .{ .timeout = expiration });

// uses atomic reference counting to ensure that an entry cannot be removed or modified while there are active readers
const reader: MemCache.SafeReader = (try mem_cache.lockReader(io, "struct_val"))).?;
defer reader.release(); // don't forget to release the reader to decrement the reference count

const entry: *const StructValue = reader.entry.read(StructValue);
// use entry...
```

There are more methods available, but I suspect the most useful pattern would be something like the following:
```zig
// assume io: Io and gpa: Allocator exist in this context

const DatabaseRow = struct {
    id: u64,
    name: []const u8,
    timestamp: i64,
};

var mem_cache: MemCache = .init;
defer mem_cache.deinit(io, gpa);

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
    ) (Allocator.Error || Io.Clock.Error)!DatabaseRow {
        // imagine a database query takes place here...
        const timestamp: Io.Timestamp = try Io.Clock.real.now(this.io);
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

    fn cleanup(context: ?*anyopaque, entry: EntryReader) void {
        // cast the cleanup context into a pointer to this struct
        const this: *const @This() = @ptrCast(@alignCast(context.?));
        const row: *const DatabaseRow = entry.read(DatabaseRow);
        this.gpa.free(row.name);
        this.gpa.destroy(this);
    }
};

const entry_manager: EntryManager = .{
    .gpa = gpa,
    .io = io,
    .id = 1,
};
const expiration: MemCache.Expiration = .{
    .runCleanup = EntryManager.cleanup, // this will be run on removal/expiration
    .timeout = .{
        .duration = .{
            .raw = .fromSeconds(15),
            .clock = .real,
        },
    },
};
// either creates a new entry or returns an existing one: returns a `SafeReader` for the entry regardless
const reader: MemCache.SafeReader = try mem_cache.getOrPutEntry(
    (Allocator.Error || Io.Clock.Error)!DatabaseRow,
    io,
    gpa,
    "DbRow(1)",
    expiration,
    entry_manager,
    EntryManager.createEntry,
);
defer reader.release();

const entry: *const DatabaseRow = reader.entry.read(DatabaseRow);
// use entry...
```
