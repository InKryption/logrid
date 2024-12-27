const std = @import("std");
const assert = std.debug.assert;

const mem = @import("mem.zig");

const logrid = @import("logrid.zig");
const grid = logrid.grid;

pub const clue = struct {};

/// Simple helper for bundling an allocator with an unmanaged data structure in parameters.
fn Managed(comptime T: type) type {
    return struct {
        allocator: std.mem.Allocator,
        data: T,

        pub fn init(allocator: std.mem.Allocator, data: T) @This() {
            return .{
                .allocator = allocator,
                .data = data,
            };
        }
    };
}

pub fn generateMinimumClues(
    ref_table: grid.Table(.immutable),
    solve_table: grid.Table(.mutable),
    random: std.Random,
    clues: struct {
        equality: Managed(*std.ArrayListUnmanaged(clue.Equality)),
    },
) std.mem.Allocator.Error!void {
    _ = random;
    _ = clues;
    assert(solve_table.dim.entries == ref_table.dim.entries);
    assert(solve_table.dim.categories == ref_table.dim.categories);

    while (true) {
        @memset(solve_table.getPropertySlice(), .null);
        // for (clues.equality.data.items) |equality| {}
    }
}

test generateMinimumClues {
    if (true) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var xoshiro_prng: std.Random.Xoshiro256 = .init(123);
    const random = xoshiro_prng.random();

    const table_data = [_]grid.Property{
        .init(0), .init(4), .init(3),
        .init(2), .init(1), .init(0),
        .init(4), .init(3), .init(2),
        .init(1), .init(0), .init(4),
        .init(3), .init(2), .init(1),
    };
    const ref_table: grid.Table(.immutable) = try .init(.{ .entries = 5 }, &table_data);

    var solve_table_data: [table_data.len]grid.Property = .{.null} ** table_data.len;
    const solve_table: grid.Table(.mutable) = try .init(.{ .entries = 5 }, &solve_table_data);

    var equality: std.ArrayListUnmanaged(clue.Equality) = .empty;
    defer equality.deinit(allocator);

    try generateMinimumClues(ref_table, solve_table, random, .{
        .equality = .init(allocator, &equality),
    });
}
