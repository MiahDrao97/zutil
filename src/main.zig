var debug_allocator: DebugAllocator(.{}) = .init;
const gpa: Allocator = switch (@import("builtin").mode) {
    .Debug => debug_allocator.allocator(),
    else => std.heap.smp_allocator,
};

pub fn main() !void {
    defer if (comptime @import("builtin").mode == .Debug)
        std.debug.assert(debug_allocator.deinit() == .ok);

    var arg_iter: ArgIter = try std.process.argsWithAllocator(gpa);
    defer arg_iter.deinit();

    var required: Arg = .unassigned;
    var optional: Arg = .defaultValue("not_overriden");
    var flag: Flag = .off;
    var other: Flag = .off;

    const all_flags = [_]Flag.Named{
        flag.alias('f'),
        other.alias('o'),
    };
    var buf: [FlagSet.requiredCapacityBytes(all_flags.len)]u8 = undefined;
    var set: FlagSet = .initBounded(all_flags.len, all_flags, &buf);

    _ = arg_iter.next(); // skip first arg (that's the .exe)
    while (arg_iter.next()) |n| {
        if (try required.parseFor(&.{ "--required", "-r" }, n, &arg_iter)) continue;
        if (try optional.parseFor(&.{"--optional"}, n, &arg_iter)) continue;
        if (try flag.toggleOn(&.{"--flag"}, n)) continue;
        if (try other.toggleOn(&.{"--other"}, n)) continue;
        if (try set.toggleMultiple(n)) continue;

        print("ERR: Unrecognized argument '{s}'\n", .{n});
        return error.UnrecognizedArgument;
    }

    if (required.to(MyEnum)) |r| {
        print(
            \\Arguments:
            \\  Required: {t}
            \\  Optional: {s}
            \\  Flag: {any}
            \\  Other: {any}
            \\
        , .{ r, optional.value.?, flag.value, other.value });
        return;
    } else |err| {
        switch (err) {
            Arg.ConvertError.ConvertFailure => print("ERR: Cannot convert argument 'required' (value='{s}') to {s}\n", .{ required.value.?, @typeName(MyEnum) }),
            Arg.ConvertError.Unassigned => print("ERR: Argument 'required' was unassigned\n", .{}),
        }
        return err;
    }
}

const MyEnum = enum { cake, watermelon, pickles };

const std = @import("std");
const zutil = @import("zutil");
const Arg = zutil.cli.Arg;
const Flag = zutil.cli.Flag;
const FlagSet = zutil.cli.FlagSet;
const Allocator = std.mem.Allocator;
const DebugAllocator = std.heap.DebugAllocator;
const ArgIter = std.process.ArgIterator;
const print = std.debug.print;
