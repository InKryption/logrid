const std = @import("std");
const assert = std.debug.assert;

pub fn BackingInt(comptime T: type) ?type {
    return switch (@typeInfo(T)) {
        .@"enum" => |enum_info| enum_info.tag_type,
        .@"struct" => |struct_info| struct_info.backing_integer,
        else => null,
    };
}

pub fn backingInt(value: anytype) (BackingInt(@TypeOf(value)) orelse @TypeOf(value)) {
    return switch (@typeInfo(@TypeOf(value))) {
        .@"enum" => @intFromEnum(value),
        .@"struct" => @bitCast(value),
        else => value,
    };
}

/// Returns the input but with `T = BackingInt(T)`.
pub fn backingIntPtr(
    /// `*T` | `[*]T` | `[]T` | `*[n]T` | `*@Vector(n, T)`
    ptr: anytype,
) AsBackingPtr(@TypeOf(ptr)) {
    return @ptrCast(ptr);
}

pub fn AsBackingPtr(comptime Ptr: type) type {
    const ptr_info = @typeInfo(Ptr).pointer;
    switch (ptr_info.size) {
        .One => switch (@typeInfo(ptr_info.child)) {
            .array => |array_info| {
                var new_ptr_info = ptr_info;
                new_ptr_info.child = @Type(.{ .array = .{
                    .len = array_info.len,
                    .child = BackingInt(array_info.child) orelse array_info.child,
                    .sentinel = s: {
                        const s = array_info.sentinel orelse break :s null;
                        break :s constTypeErase(backingInt(constReinterpret(array_info.child, s)));
                    },
                } });
                return @Type(.{ .pointer = new_ptr_info });
            },
            .vector => |vector_info| {
                var new_ptr_info = ptr_info;
                new_ptr_info.child = @Type(.{ .vector = .{
                    .len = vector_info.len,
                    .child = BackingInt(vector_info.child) orelse vector_info.child,
                } });
                return @Type(.{ .pointer = new_ptr_info });
            },
            else => @compileError("Expected `*[n]T` or `*@Vector(n, T)`, got " ++ @typeName(Ptr)),
        },
        .Many, .Slice => {
            var new_ptr_info = ptr_info;
            new_ptr_info.sentinel = if (ptr_info.sentinel) |s| constTypeErase(backingInt(constReinterpret(ptr_info.child, s))) else null;
            new_ptr_info.child = BackingInt(ptr_info.child) orelse ptr_info.child;
            return @Type(.{ .pointer = new_ptr_info });
        },
        else => @compileError("Expected `*T`, `[*]T`, `[]T`, `*[n]T`, or `*@Vector(n, T)`, got " ++ @typeName(Ptr)),
    }
}

/// Returns the first index `i` where `a[i] == b[i]`.
/// Opposite of `std.mem.indexOfDiff`.
pub fn indexOfEqual(
    comptime T: type,
    a: []const T,
    b: []const T,
) ?usize {
    if (BackingInt(T)) |Int| return @call(.always_inline, indexOfEqual, .{
        Int, backingIntPtr(a), backingIntPtr(b),
    });

    const smallest_len = @min(a.len, b.len);

    const start: usize = if (std.simd.suggestVectorLength(T)) |vec_len| simd_blk: {
        if (smallest_len < vec_len) break :simd_blk 0;
        var start: usize = 0;

        while (start + vec_len <= smallest_len) : (start += vec_len) {
            const block_a: @Vector(vec_len, T) = a[start..][0..vec_len].*;
            const block_b: @Vector(vec_len, T) = b[start..][0..vec_len].*;
            const offset_of_eq = std.simd.firstTrue(block_a == block_b) orelse continue;
            return start + offset_of_eq;
        }

        break :simd_blk start;
    } else 0;

    return for (a[start..], b[start..], start..) |val_a, val_b, idx| {
        if (val_a == val_b) break idx;
    } else null;
}

/// Accepts enums and packed structs, re-interpreting them as their backing integer.
pub fn indexOfEqualOrGreaterPos(
    comptime T: type,
    haystack: []const T,
    start_index: usize,
    needle: T,
) ?usize {
    if (BackingInt(T)) |Int| return @call(.always_inline, indexOfEqualOrGreaterPos, .{
        Int, backingIntPtr(haystack), start_index, backingInt(needle),
    });

    const start: usize = if (std.simd.suggestVectorLength(T)) |vec_len| simd_blk: {
        if (haystack.len - start_index < vec_len) break :simd_blk start_index;
        var start = start_index;

        const needle_splat: @Vector(vec_len, T) = @splat(needle);
        while (start + vec_len <= haystack.len) : (start += vec_len) {
            const block: @Vector(vec_len, T) = haystack[start..][0..vec_len].*;
            const offset_of_gteq = std.simd.firstTrue(block >= needle_splat) orelse continue;
            return start + offset_of_gteq;
        }

        break :simd_blk start;
    } else 0;

    return for (haystack[start..], start..) |value, category_idx| {
        if (value < needle) continue;
        break category_idx;
    } else null;
}

pub fn countScalar(
    comptime T: type,
    haystack: []const T,
    needle: T,
) usize {
    if (BackingInt(T)) |Int| return @call(.always_inline, countScalar, .{
        Int, backingIntPtr(haystack), backingInt(needle),
    });

    var n: usize = 0;

    const start: usize = if (std.simd.suggestVectorLength(T)) |vec_len| simd_blk: {
        if (haystack.len < vec_len) break :simd_blk 0;
        var start: usize = 0;

        const needle_splat: @Vector(vec_len, T) = @splat(needle);
        const one_splat: @Vector(vec_len, T) = @splat(1);
        const zero_splat: @Vector(vec_len, T) = @splat(0);
        while (start + vec_len <= haystack.len) : (start += vec_len) {
            const block: @Vector(vec_len, T) = haystack[start..][0..vec_len].*;
            const masked_ones = @select(usize, block == needle_splat, one_splat, zero_splat);
            n += @reduce(.Add, masked_ones);
        }

        break :simd_blk start;
    } else 0;

    for (haystack[start..]) |value| {
        n += @intFromBool(value == needle);
    }
    return n;
}

pub inline fn constTypeErase(
    comptime value: anytype,
) *const anyopaque {
    comptime {
        const caster = .{value};
        const caster_info = @typeInfo(@TypeOf(caster)).@"struct";
        return caster_info.fields[0].default_value.?;
    }
}

pub inline fn constReinterpret(
    comptime T: type,
    comptime ptr: *const anyopaque,
) T {
    const Caster = @Type(.{ .@"struct" = .{
        .layout = .auto,
        .backing_integer = null,
        .is_tuple = false,
        .decls = &.{},
        .fields = &.{.{
            .is_comptime = true,
            .name = "casted",
            .type = T,
            .alignment = 0,
            .default_value = ptr,
        }},
    } });
    const caster: Caster = .{};
    return caster.casted;
}

pub fn SliceAsArrayPtr(comptime len: usize, comptime Slice: type) type {
    var info = @typeInfo(Slice).pointer;
    const T = info.child;

    if (info.size != .Slice) unreachable;
    info.size = .One;

    const maybe_sentinel: ?T = s: {
        const s_ptr_erased = info.sentinel orelse break :s null;
        break :s constReinterpret(T, s_ptr_erased);
    };
    info.sentinel = null;

    info.child = if (maybe_sentinel) |s| [len:s]T else [len]T;
    return @Type(.{ .pointer = info });
}
