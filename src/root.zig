//! Various utilities that I find myself reusing across Zig codebases.
//! - MiahDrao97

/// Command line utilies
pub const cli = @import("cli.zig");

/// Use to return a managed object.
/// This strategy is useful when memory won't be or can't be freed after creating a given value.
/// However, when this managed object is freed, all memory allocated beforehand when creating it will also be freed.
pub fn Managed(comptime T: type) type {
    return struct {
        /// Value itself
        value: T,
        /// Arena used to create the managed value
        arena: ArenaAllocator,

        /// Create a new managed value.
        /// Returns `self.*` (usually because you're returning this managed value or passing it as an argument).
        /// This requires a 2-step initialization. Example:
        /// ```zig
        /// var managed: Managed(T) = undefined;
        /// _ = try managed.create(gpa, ctx, @TypeOf(ctx).initValue);
        /// ```
        pub fn create(
            self: *Managed(T),
            gpa: Allocator,
            context: anytype,
            initFn: fn (@TypeOf(context), Allocator) anyerror!T,
        ) !Managed(T) {
            self.arena = .init(gpa);
            errdefer self.arena.deinit();

            self.value = try initFn(context, self.arena.allocator());
            return self.*;
        }

        /// Destroy the managed value and all memory allocated beforehand when creating it.
        pub fn deinit(self: Managed(T)) void {
            self.arena.deinit();
        }
    };
}

/// `TSubset` must be a subset of `struct`'s type (strictly looking at the names and types of struct members).
/// Create an instance of `TSubset` from `struct`'s members.
pub fn structSubset(comptime TSubset: type, @"struct": anytype) TSubset {
    const SourceType = @TypeOf(@"struct");
    switch (@typeInfo(SourceType)) {
        .@"struct" => switch (@typeInfo(TSubset)) {
            .@"struct" => |to| {
                var result: TSubset = undefined;
                inline for (to.fields) |field| {
                    if (@hasField(SourceType, field.name)) {
                        if (@FieldType(SourceType, field.name) == field.type) {
                            @field(result, field.name) = @field(@"struct", field.name);
                        } else {
                            @compileError("Expected type `" ++ @typeName(field.type) ++ "` on field `" ++ field.name ++ "`, but found `" ++ @typeName(@FieldType(SourceType, field.name)) ++ "`.");
                        }
                    } else @compileError("Field `" ++ field.Name ++ "` not found on type `" ++ @typeName(SourceType) ++ "`.");
                }
                return result;
            },
            else => @compileError("`" ++ @typeName(TSubset) ++ "` is not a struct."),
        },
        .pointer => |ptr| return structSubset(ptr.child, @"struct".*),
        else => @compileError("`" ++ @typeName(SourceType) ++ "` is not a struct."),
    }
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
