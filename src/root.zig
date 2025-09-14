//! Various utilities that I find myself reusing across Zig codebases.
//! - MiahDrao97

/// Represents a command line argument value.
/// Can be given a default value or `unassigned`.
pub const Arg = struct {
    /// Value of the argument
    value: ?[]const u8,
    /// If false, this value has not been overwritten
    dirty: bool = false,

    pub const unassigned: Arg = .{ .value = null };

    pub fn defaultValue(value: []const u8) Arg {
        return .{ .value = value };
    }

    /// Errors returned while parsing the argument value
    pub const ParseError = error{
        /// No value returned from `iter`
        NoValueProvided,
        /// Returned if this argument has been written to already
        AlreadyAssigned,
    };

    /// Errors returned while converting the argument to another type
    pub const ConvertError = error{
        /// The argument is not assigned any value
        Unassigned,
        /// The argument's value failed to be converted to the given type
        ConvertFailure,
    };

    /// If `arg` matches any of the `arg_names` provided, we'll get the next value from `iter`, assign it to this argument's value, and return `true`.
    /// Otherwise, if we have a matching argument name but no next value, returns `error.NoValueProvided`.
    /// If this argument has already been written to, returns `error.AlreadyAssigned`.
    ///
    /// Finally, if `arg` does not match anything in `arg_names`, returns `false`.
    pub fn parseFor(
        self: *Arg,
        arg_names: []const []const u8,
        arg: []const u8,
        iter: *ArgIterator,
    ) ParseError!bool {
        return for (arg_names) |name| {
            if (std.mem.eql(u8, name, arg)) {
                if (iter.next()) |val| {
                    if (self.dirty) {
                        log.err("Argument '{s}' has already been assigned value: {?s}", .{ arg, self.value });
                        return ParseError.AlreadyAssigned;
                    }
                    self.dirty = true;

                    self.value = val;
                    break true;
                }
                log.err("No value provided for argument '{s}'", .{arg});
                return ParseError.NoValueProvided;
            }
        } else false;
    }

    /// Attempt to convert the argument's value to a given type.
    /// The supported types available for this operation are:
    /// - integers (signed or unsigned in base 2, 8, 10, or 16)
    /// - floats
    /// - enums (tag name or integer value)
    pub fn to(self: Arg, comptime T: type) ConvertError!T {
        if (self.value) |v| {
            return switch (@typeInfo(T)) {
                .int => |i| switch (i.signedness) {
                    .signed => std.fmt.parseInt(T, v, 0) catch return ConvertError.ConvertFailure,
                    .unsigned => std.fmt.parseUnsigned(T, v, 0) catch return ConvertError.ConvertFailure,
                },
                .float => std.fmt.parseFloat(T, v) catch return ConvertError.ConvertFailure,
                .@"enum" => |e| std.meta.stringToEnum(T, v) orelse
                    std.enums.fromInt(T, try self.to(e.tag_type)) orelse
                    return ConvertError.ConvertFailure,
                else => @compileError("Cannot convert to type `" ++ @typeName(T) ++ "`. Can only convert to integer, float, boolean, or enum."),
            };
        }
        return ConvertError.Unassigned;
    }
};

/// Flag argument
pub const Flag = struct {
    value: bool,
    dirty: bool = false,

    /// Initialize with value=false
    pub const off: Flag = .{ .value = false };

    /// Initialize with value=true
    pub const on: Flag = .{ .value = true };

    pub const Named = struct {
        flag: *Flag,
        name: u8,
    };

    /// Alias a flag as a single character representation
    pub fn alias(self: *Flag, name: u8) Named {
        return .{ .flag = self, .name = name };
    }

    /// If `arg` matches any of the `arg_names` provided, toggles `self.value` and returns `true`.
    ///
    /// If none of the above, returns `false`.
    pub fn parseFor(self: *Flag, arg_names: []const []const u8, arg: []const u8) error{AlreadyToggled}!bool {
        return for (arg_names) |name| {
            if (std.mem.eql(u8, name, arg)) {
                self.toggle() catch |err| {
                    log.err("Flag '{s}' has already been set.", .{name});
                    return err;
                };
                break true;
            }
        } else false;
    }

    fn toggle(self: *Flag) error{AlreadyToggled}!void {
        if (self.dirty) return error.AlreadyToggled;
        self.dirty = true;
        self.value = !self.value;
    }
};

pub const FlagSet = struct {
    set: Set,

    const Self = @This();
    const Set = std.AutoArrayHashMapUnmanaged(u8, *Flag);

    pub fn initSlice(gpa: Allocator, flags: []const Flag.Named) Allocator.Error!Self {
        var set: Set = .empty;
        try set.ensureTotalCapacity(gpa, flags.len);
        for (flags) |f| {
            const put: Set.GetOrPutResult = set.getOrPutAssumeCapacity(f.name);
            if (put.found_existing) {
                var panic_buf: [64]u8 = undefined;
                @panic(std.fmt.bufPrint(&panic_buf, "'{c}' has already been assigned to a flag.", .{f.name}) catch &panic_buf);
            }
            put.value_ptr.* = f.flag;
        }
        return .{ .set = set };
    }

    pub fn initArr(n: comptime_int, flags: [n]Flag.Named, buf: *[requiredCapacityBytes(n)]u8) Self {
        var fba: FixedBufferAllocator = .init(buf);
        return initSlice(fba.allocator(), &flags) catch unreachable;
    }

    pub fn requiredCapacityBytes(n: usize) usize {
        var bytes: usize = 0;
        while (true) {
            bytes +|= bytes / 2 + std.atomic.cache_line;
            if (bytes >= n) break;
        }
        return std.MultiArrayList(Set.Data).capacityInBytes(bytes);
    }

    /// Parse for any group of flags.
    /// Use this method if you allow a client to pass in all flags grouped together in a single argument (e.g. "-ab" would have flags "a" and "b" toggled)
    /// This argument is expected to start with a single dash and have no repeated values (repeated values results in `error.AlreadyToggled`).
    /// Call this parse function last because it assumes that all characters present (after the dash) are known flag values.
    pub fn parseAny(
        self: *Self,
        arg: []const u8,
    ) error{ AlreadyToggled, UnknownFlag }!bool {
        if (arg.len > 1 and arg[0] == '-' and arg[1] != '-') {
            for (arg[1..]) |f| {
                if (self.set.get(f)) |flag| {
                    flag.toggle() catch |err| {
                        log.err("Flag '{c}' already set.", .{f});
                        return err;
                    };
                } else {
                    log.err("Unknown flag '{c}'.", .{f});
                    return error.UnknownFlag;
                }
            }
            return true;
        }
        return false;
    }

    pub fn deinit(self: *Self, gpa: Allocator) void {
        self.set.deinit(gpa);
    }
};

const std = @import("std");
const ArgIterator = std.process.ArgIterator;
const log = std.log.scoped(.zutil);
const FixedBufferAllocator = std.heap.FixedBufferAllocator;
const Allocator = std.mem.Allocator;
