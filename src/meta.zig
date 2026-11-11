//! Module to assist with meta-programming

pub fn unionAs(comptime T: type, @"union": anytype) ?T {
    const TUnion = @TypeOf(@"union");
    switch (@typeInfo(TUnion)) {
        .@"union" => {
            const active_tag: [:0]const u8 = @tagName(@"union");
            return if (@FieldType(TUnion, active_tag) == T)
                @field(@"union", active_tag)
            else
                null;
        },
        else => @compileError("Expected union type, but received " ++ @typeName(TUnion)),
    }
}

/// `TSubset` must be a subset of `struct`'s type (strictly looking at the names and types of struct members).
/// Create an instance of `TSubset` from `struct`'s members.
pub fn structSubset(comptime TSubset: type, @"struct": anytype) TSubset {
    const SourceType = @TypeOf(@"struct");
    switch (@typeInfo(SourceType)) {
        .@"struct" => switch (@typeInfo(TSubset)) {
            .@"struct" => |to| {
                var result: TSubset = undefined;
                inline for (to.field_names, to.field_types) |field, FieldType| {
                    if (@hasField(SourceType, field)) {
                        if (@FieldType(SourceType, field) == FieldType) {
                            @field(result, field) = @field(@"struct", field);
                        } else {
                            @compileError("Expected type `" ++ @typeName(FieldType) ++ "` on field `" ++ field ++ "`, but found `" ++ @typeName(@FieldType(SourceType, field)) ++ "`.");
                        }
                    } else @compileError("Field `" ++ field ++ "` not found on type `" ++ @typeName(SourceType) ++ "`.");
                }
                return result;
            },
            else => @compileError("`" ++ @typeName(TSubset) ++ "` is not a struct."),
        },
        .pointer => |ptr| return structSubset(ptr.child, @"struct".*),
        else => @compileError("`" ++ @typeName(SourceType) ++ "` is not a struct."),
    }
}

/// Extracts the error component of a function's return type, error union, or error set.
/// If `T` is neither of the above, returns `error{}`.
pub fn ErrorComponent(comptime TReturn: type) type {
    return switch (@typeInfo(TReturn)) {
        .@"fn" => |f| switch (@typeInfo(f.return_type.?)) {
            .error_union => |e| e.error_set,
            .error_set => f.return_type.?,
            else => error{},
        },
        .error_union => |e| e.error_set,
        .error_set => TReturn,
        else => error{},
    };
}

/// Extracts the non-error component of a function's return type or error union.
/// If `T` is neither of the above, simply returns `T` (except error sets produce a compile error).
pub fn OkComponent(comptime TReturn: type) type {
    return switch (@typeInfo(TReturn)) {
        .@"fn" => |f| switch (@typeInfo(f.return_type.?)) {
            .error_union => |e| e.payload,
            .error_set => @compileError("Return type must be an error union or a non-error-set value."),
            else => f.return_type.?,
        },
        .error_union => |e| e.payload,
        .error_set => @compileError("Return type must be an error union or a non-error-set value."),
        else => TReturn,
    };
}

test structSubset {
    const A = struct {
        a: u8,
        b: []const u8,
    };

    const B = struct {
        a: u8,
        b: []const u8,
        c: f64,
    };

    const b: B = .{ .a = 'a', .b = "blarf", .c = 3.14 };
    const a: A = structSubset(A, b);

    try std.testing.expectEqual('a', a.a);
    try std.testing.expectEqualStrings("blarf", a.b);
}

const std = @import("std");
