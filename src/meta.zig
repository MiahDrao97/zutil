//! Module to assist with meta-programming

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

/// Extracts the error component of a function's return type, error union, or error set.
/// If `T` is neither of the above, returns `error{}`.
pub fn ErrorType(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .@"fn" => |f| switch (@typeInfo(f.return_type.?)) {
            .error_union => |e| e.error_set,
            .error_set => f.return_type.?,
            else => error{},
        },
        .error_union => |e| e.error_set,
        .error_set => T,
        else => error{},
    };
}

/// Extracts the non-error component of a function's return type,
/// or, if it doesn't return an error union, simply the return type.
pub fn ReturnType(comptime Func: type) type {
    const TReturn = @typeInfo(Func).@"fn".return_type.?;
    return switch (@typeInfo(TReturn)) {
        .error_union => |e| e.payload,
        .error_set => @compileError("Return type must be an error union or a non-error-set value."),
        else => TReturn,
    };
}
