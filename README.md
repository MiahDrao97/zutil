# Zutil
Library of quick utilities that I find myself copying and pasting in various Zig projects.
I made this primarily for myself, but perhaps others can find it useful.
There are likely some bugs in here, but I've tried to make everything as general as possible.
It's been a great learning excercise for lots of different things, and I'll continue to modify this library as I learn more.

# Installation

You can use the `zig fetch` command like so:

v0.1.0, which targets Zig 0.16.0:
```
zig fetch https://github.com/MiahDrao97/zutil/archive/refs/tags/v0.1.0.tar.gz --save
```

Main branch:
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

# `Managed(T)`
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

# UUID
Currently supporting v3, v4, v5, and v7 for UUID generation.
Assumes any 16 bytes can be a valid UUID, but provides parsing and some printing/formatting options.

Example usage:
```zig
const std = @import("std");
const gpa: std.Allocator = std.testing.allocator;

const uuid: Uuid = .v4(std.testing.io);
std.debug.print("UUID: {f}\n", .{uuid}); // formatted like xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx (lower-case) by default
const uuid_str: []const u8 = try std.fmt.allocPrint(gpa, "{f}", .{uuid.fmt(.{ .casing = .upper, .separator = .none })}); // can pass in format options
defer gpa.free(uuid_str);

const parsed: Uuid = try .from(uuid_str); // still parses to the same UUID value
try std.testing.expect(uuid.eql(parsed));
```

# `cli` Namespace
This namespace contains structures useful for parsing CLI args.
Use `Arg` for arguments that will be assigned a value.

Example usage of `Arg`:
```zig
const MyEnum = enum { asdf, blarf };

// yes I'm on Windows :P
const args: std.process.Args = .{ .vector = std.unicode.utf8ToUtf16LeStringLiteral("MyProgram.exe --some-val asdf") };

var iter: std.process.Args.Iterator = try args.iterateAllocator(testing.allocator);
defer iter.deinit();

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
const args: std.process.Args = .{ .vector = std.unicode.utf8ToUtf16LeStringLiteral("MyProgram.exe -a") };

var iter: std.process.Args.Iterator = try args.iterateAllocator(testing.allocator);
defer iter.deinit();

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

# `string` Namespace
Currently have casing utilies (convert a string to camel case, title case, kebab, snake, and screaming snake) and
date-time formatting/parsing utilies.

## Casing

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
Title case, camel case, kebab case, snake case, and screaming snake case are supported.
Naively assumes ASCII encoding.

## DateTimeFormat
Format a `Io.Timestamp` into a date-time, and parse a date-time from a string.
This is a work in progress as I'm certain there is still more work to be done here.

A `DateTimeFormat` consists of a `Io.Timestamp`, a `Formatting`, and a `UtcOffset`.
The `Formatting` struct contains the complex formatting details.
Initialize with a comptime format string using the `fmtStr()` function (e.g. "yyyy-MM-dd hh:mm:ss.fffZ").
The `Formatting` struct can parse a date-time string with the exact format or write a string with that format.

```zig
const std = @import("std");
const zutil = @import("zutil");
const testing = std.testing;
const Io = std.Io;
const DateTimeFormat = zutil.string.DateTimeFormat;

const nanoseconds: i96 = 1779486527036758700; // Friday, May 22, 2026 at 9:48:47.0367587 PM (UTC)

var stream: Io.Writer.Allocating = .init(testing.allocator);
defer stream.deinit();
// this is the ISO format, which you can simply use `DateTimeFormat.iso()` as shorthand for this
try stream.writer.print("{f}", .{DateTimeFormat.fmt(.fmtStr("yyyy-MM-ddThh:mm:ss.fffZ"), .fromNanoseconds(nanoseconds), .utc)});
try testing.expectEqualStrings("2026-05-22T21:48:47.036Z", stream.written());
```

### Format guide:
#### Year (y or Y)
y - Get the current year without leading zero

yy - Display the last 2 digits of the year

yyy - Display the last 3 digits of the year

yyyy - Display the last 4 digits of the year

yyyyy - Include 5 digits for the year (adds leading zero)

---

#### Month (M)
M - Represent the month without leading zero

MM - Adds leading zero

MMM - Abreviated name of the month (e.g. "Jan", "Feb", etc.)

MMMM - Full name of the month (e.g. "January", "February", etc.)

---

#### Day (d)
d - Represent the day of the month without leading zero

dd - Adds leading zero

---

#### Weekday (D)
D - abbreviated weekday (e.g. "Mon", "Tue", etc)

DD - full week day name (e.g. "Monday", "Tuesday", etc)

---

#### Hour (h or H)
h - Represent hours without leading zero

hh - Adds leading zero

---

#### Minute (m)
m - Represent minutes without leading zero

mm - Adds leading zero

---

#### Second (s)
s - Represent seconds without leading zero

ss - Adds leading zero

---

#### Sub-second (f)
Represent up to 9 places (note that numbers are truncated, not rounded):
"f" for 1 place, "ff" for 2 places, etc.
As a quick reference:

fff yields milliseconds

ffffff yields microseconds

fffffffff yields nanoseconds

---

#### UTC Offset (z)
z - Represent +/- hours from UTC

zz - Adds leading zero to +/- hours from UTC

zzz - Includes quarter hours (not colon-separated) (e.g. -0715 for -7 hours and 15 minutes from UTC time)

zzzz - ISO 8601 format, which includes quarter hours that are colon-separated (.e.g "-07:15" for -7 hours and 15 minutes from UTC time)

Z - ISO 8601 format (shorthand for zzzz)

---

#### AM/PM (n or N, for "noon")
n - a for AM, p for PM

N - A for AM, P for PM

nn - am/pm

NN - AM/PM

The accepted separator characters are: ' ', '/', '-', '+', '_', '.', ',', ':', 'T'.
If there are any trailing separator characters, those will be trimmed.

If a UTC offset is directly preceeded by a '+' or a '-', it will include a '+' in positive offsets, replacing the fill with the correct sign.
If a UTC offset is not directly preceed by a '+' or a '-', positive offsets will simply start with a space.

### Parsing
There are 2 parse methods, `parse()` and `parseExact()`:
```zig
const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const DateTimeFormat = @import("zutil").string.DateTimeFormat;

test parseExact {
    const date_str: []const u8 = "Friday, May 22, 2026 09:48:47.0367587 PM"; // <-- the subseconds are expected to be truncated when parsed
    const date_time: DateTimeFormat = try .parseExact(date_str, .fmtStr("DD, MMMM dd, yyyy hh:mm:ss.fff NN"));
    try testing.expectEqual(1779486527036000000, date_time.timestamp.nanoseconds);
    // The resulting DateTimeFormat will have a non-empty `formatting` member, which matches what you pass into `parseExact()`.
}
test parse {
    // Unlike `parseExact()`, this simply requires the order of date-time elements, allowing any fill between elements.
    // If more string remains after filling out all the elements, will simply ignore the rest of the string.
    const date_str: []const u8 = "2026-05-22T21:48:47.036Z";
    var date_time: DateTimeFormat = try .parse(date_str, &.{ .year, .month, .day, .hour, .minute, .second, .subsecond, .utc_offset });
    try testing.expectEqual(1779486527036000000, date_time.timestamp.nanoseconds);

    date_time = try .parse(date_str, &.{ .year, .month, .day }); // <-- we only want the date, so the time is ignored here
    try testing.expectEqual(1779408000000000000, date_time.timestamp.nanoseconds);

    var stream: Io.Writer.Allocating = .init(testing.allocator);
    defer stream.deinit();

    // NOTE : `formatting` is empty when you use `parse()` because `parse()` is intentionally flexible, so we can't assume the formatting.
    date_time.formatting = .fmtStr("MM/dd/yyyy");
    try stream.writer.print("{f}", .{date_time});
    try testing.expectEqualStrings("05/22/2026", stream.written()); // re-formatted date

    stream.clearRetainingCapacity();
    // let's change our format again...
    date_time.formatting = .fmtStr("MM/dd/yyyy hh:mm:ss.fff");
    try stream.writer.print("{f}", .{date_time});
    try testing.expectEqualStrings("05/22/2026 00:00:00.000", stream.written());

    stream.clearRetainingCapacity();

    // Parsing time without a date...
    date_time = try .parse("21:48:47.036", &.{ .hour, .minute, .second, .subsecond });
    try testing.expectEqual(78527036000000, date_time.timestamp.nanoseconds);

    // change formatting again
    date_time.formatting = .fmtStr("hh:mm:ss.fff");
    try stream.writer.print("{f}", .{date_time});
    try testing.expectEqualStrings("21:48:47.036", stream.written());
}
```

### Io.Timestamp Best Practice
Keep in mind that an `Io.Timestamp` is really just a count of nanoseconds.
It is up to the developer to understand if that timestamp includes any UTC offsets.
If you parse a string as a `DateTimeFormat` and apply a UTC offset to it, it will *add or subtract* from the timestamp's value when formatted.
Generally, keep instances of `Io.Timestamp` with a UTC offset of 0.
Only apply locality in reporting/user interactions.

NOTE - Pre-Unix Epoch date-times are not yet supported. If that ever comes up, I have a lovely error log you'll encounter. Send patches!

# `MemCache` and `MemCacheAligned`
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

var mem_cache: MemCache = try .init(gpa, .{});
defer mem_cache.deinit();

const StructValue = struct {
    a: f32,
    b: u16,
};

const s: StructValue = .{ .a = 3.14, .b = 5 };
// create a new entry in the memory cache with an expiration
try mem_cache.newEntry(io, "struct_val", s, .lifetime(.{ .duration = .fromSeconds(15) }, .no_callback));

// uses atomic reference counting to ensure that an entry cannot be removed or modified while there are active readers
const reader: MemCache.Reader = (try mem_cache.reader(io, "struct_val"))).?;
defer reader.release(&mem_cache); // don't forget to release the reader to decrement the reference count

const entry: *const StructValue = reader.entry.read(StructValue);
// use entry...
```

There are more methods available, but the most useful pattern would be something like the following:
```zig
// assume io: Io and gpa: Allocator exist in this context

const DatabaseRow = struct {
    id: u64,
    name: []const u8,
    timestamp: i64,
};

var mem_cache: MemCache = try .init(gpa, .{});
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
// either creates a new entry or returns an existing one: returns a `SafeReader` for the entry regardless
const reader: MemCache.SafeReader = try mem_cache.getOrPutEntry(
    Allocator.Error!DatabaseRow,
    io,
    "DbRow(1)",
    .lifetime(.{ .duration = .fromSeconds(15) }, .callback(EntryManager.cleanup)), // 15-second lifetime with callback that will be run on removal/expiration
    entry_manager,
    EntryManager.createEntry,
);
defer reader.release(&mem_cache);

const entry: *const DatabaseRow = reader.entry.read(DatabaseRow);
// use entry...
```

Keep in mind that `MemCache` is an alias for `mem_cache.Default`, and `MemCacheAligned` is an alias for `mem_cache.Aligned`.
This data structure is _managed_ by necessity because atomic reference counting makes for some difficult lifetimes.
It also gives the caller the ability to use a different allocator when creating an entry and freeing it through a callback.
If an entry is removed either by expiration or explicit removal, that entry is considered "tombstoned."
That memory remains valid until the last reader sets the reference count to 0, which then prompts the memory cache to free that memory.
This has the side effect of multiple "generations" of a cache entry being possible, so keep that in mind.
If you are diligent about releasing readers quickly, this shouldn't be something you run into very often.
Expiration is evaluated on `read()`, where if an entry is determined to be expired, it will be tombstoned instead of returning a reader.
The memory cache will only open new readers for the active generation; tombstoned entries cannot have new readers.
Keep in mind that `deinit()` will panic if there are any active readers.

Internally, the memory cache uses a `std.heap.MemoryPool` for creating entries.
You can set a comptime upper-bound on entries with the aligned type function, which will pre-allocate that much space when `.init(...)` is called.
Additionally, you can set the max number of readers with the runtime options passed into `.init(...)`.
Keep in mind that the hard limit is `std.math.maxInt(u16)` readers on a single entry.
Each entry cannot exceed `std.math.maxInt(u16)` bytes.
I feel like that's pretty reasonable, especially since entries are shallow copies.
If you run into this limitation, maybe you can heap allocate portions of the entry;
again, you can always pass in a callback to free that memory on expiration.
