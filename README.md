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
