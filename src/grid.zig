//! This file defines how the logic grid table is represented, validated, and rendered to CSV.

const std = @import("std");
const assert = std.debug.assert;

const mem = @import("mem.zig");

/// A strictly typed alias for an integer, representing a property index.
pub const Property = enum(Int) {
    pub const Int = usize;
    null = std.math.maxInt(Int),
    _,

    pub fn init(value: Int) Property {
        return @enumFromInt(value);
    }
};

/// A strictly typed alias for an integer, representing a category index.
pub const Category = enum(Int) {
    pub const Int = usize;
    null = std.math.maxInt(Int),
    _,

    pub fn init(value: Int) Category {
        return @enumFromInt(value);
    }
};

/// A strictly typed alias for an integer, representing an entry index.
pub const Entry = enum(Int) {
    pub const Int = usize;
    null = std.math.maxInt(Int),
    _,

    pub fn init(value: Int) Entry {
        return @enumFromInt(value);
    }
};

pub const Location = struct {
    entry: Entry,
    category: Category,

    pub const Int = usize;
};

pub const Dimensions = struct {
    /// The number of entries.
    entries: Entry.Int,
    /// The number of categories (properties per entry).
    categories: Category.Int,

    pub const OneStride = union(enum) {
        entries: Entry.Int,
        categories: Category.Int,
    };

    pub const InitStridedPropertiesError = error{
        /// There must be more than one entry.
        TooFewEntries,
        /// There must be more than one category.
        TooFewCategories,
        /// There were fewer properties than could be divided by the stride.
        TooFewProperties,
        /// The specified stride did not evenly divide the property count into the other stride.
        InexactStride,
    };

    pub fn initStridedProperties(
        property_count: Location.Int,
        one_stride: OneStride,
    ) InitStridedPropertiesError!Dimensions {
        return switch (one_stride) {
            inline .entries, .categories => |stride, tag| blk: {
                if (stride < 2) switch (tag) {
                    .entries => return error.TooFewEntries,
                    .categories => return error.TooFewCategories,
                };
                if (stride > property_count) {
                    return error.TooFewProperties;
                }
                if (property_count % stride != 0) {
                    return error.InexactStride;
                }

                const OtherStride = switch (tag) {
                    .entries => Category.Int,
                    .categories => Entry.Int,
                };
                const other_stride: OtherStride = @divExact(property_count, stride);
                break :blk switch (tag) {
                    // zig fmt: off
                    .entries    => .{ .entries = stride,       .categories = other_stride },
                    .categories => .{ .entries = other_stride, .categories = stride       },
                    // zig fmt: on
                };
            },
        };
    }

    pub fn totalPropertyCount(dim: Dimensions) Location.Int {
        return dim.entries * dim.categories;
    }

    /// Returns the index to the first property belonging to the given `entry`.
    /// The subsequent `dim.categories` properties belong to the `entry`.
    /// Ie: `property_array[getEntryStart(dim, entry)..][0..dim.categories]` is
    /// the slice of properties belonging to `entry`.
    pub fn getEntryStart(dim: Dimensions, entry: Entry) Location.Int {
        return @intFromEnum(entry) * dim.categories;
    }

    pub fn indexToLocation(
        dim: Dimensions,
        prop_buf_index: Location.Int,
    ) Location {
        assert(prop_buf_index < dim.totalPropertyCount());
        return .{
            .entry = .init(prop_buf_index / dim.categories),
            .category = .init(prop_buf_index % dim.categories),
        };
    }

    pub fn locationToIndex(
        dim: Dimensions,
        location: Location,
    ) Location.Int {
        return @intFromEnum(location.entry) * dim.categories + @intFromEnum(location.category);
    }
};

pub const Table = struct {
    dim: Dimensions,
    data: []const Property,

    pub fn table(
        dim: Dimensions,
        data: []const Property,
    ) Table {
        assert(dim.totalPropertyCount() == data.len);
        return .{
            .dim = dim,
            .data = data,
        };
    }
};

pub const ValidationStatus = union(enum) {
    ok,
    unsolved,
    invalid_property: Location,
    duplicate_property: DuplicateProperty,

    pub const DuplicateProperty = struct {
        entry_a: Entry,
        entry_b: Entry,
        category: Category,
    };
};

pub fn validate(table: Table) ValidationStatus {
    const solved = solved: {
        var solved = true;

        var start: usize = 0;
        while (mem.indexOfEqualOrGreaterPos(
            Property,
            table.data,
            start,
            .init(table.dim.entries),
        )) |prop_buf_index| : (start = prop_buf_index + 1) {
            if (table.data[prop_buf_index] == .null) {
                solved = false;
            } else {
                return .{ .invalid_property = table.dim.indexToLocation(prop_buf_index) };
            }
        }

        break :solved solved;
    };

    for (0..table.dim.entries) |entry_val_a| {
        const entry_data_a = table.data[table.dim.getEntryStart(.init(entry_val_a))..][0..table.dim.categories];

        for (entry_val_a + 1..table.dim.entries) |entry_val_b| {
            const entry_data_b = table.data[table.dim.getEntryStart(.init(entry_val_b))..][0..table.dim.categories];

            var start: usize = 0;
            while (mem.indexOfEqual(
                Property,
                entry_data_a[start..],
                entry_data_b[start..],
            )) |offs| : (start += offs + 1) {
                const category: Category = .init(start + offs);

                if (entry_data_a[@intFromEnum(category)] == .null) {
                    assert(!solved);
                    continue;
                }

                return .{ .duplicate_property = .{
                    .entry_a = .init(entry_val_a),
                    .entry_b = .init(entry_val_b),
                    .category = category,
                } };
            }
        }
    }

    return if (solved) .ok else .unsolved;
}

test validate {
    try std.testing.expectEqual(
        .ok,
        validate(.table(try .initStridedProperties(8, .{ .categories = 2 }), &.{
            .init(0), .init(0),
            .init(1), .init(1),
            .init(2), .init(2),
            .init(3), .init(3),
        })),
    );

    try std.testing.expectEqual(
        .unsolved,
        validate(.table(try .initStridedProperties(8, .{ .categories = 2 }), &.{
            .null,    .init(0),
            .init(1), .init(1),
            .init(2), .init(2),
            .init(3), .init(3),
        })),
    );

    try std.testing.expectEqual(
        .unsolved,
        validate(.table(try .initStridedProperties(8, .{ .categories = 2 }), &.{
            .null,    .init(0),
            .init(1), .init(1),
            .init(2), .init(2),
            .init(3), .init(3),
        })),
    );

    try std.testing.expectEqual(
        ValidationStatus{ .invalid_property = .{
            .entry = .init(3),
            .category = .init(1),
        } },
        validate(.table(try .initStridedProperties(8, .{ .categories = 2 }), &.{
            .null,    .init(0),
            .init(1), .init(1),
            .init(2), .init(2),
            .init(3), .init(4),
        })),
    );

    try std.testing.expectEqual(
        ValidationStatus{ .duplicate_property = .{
            .entry_a = .init(1),
            .entry_b = .init(2),
            .category = .init(0),
        } },
        validate(.table(try .initStridedProperties(8, .{ .categories = 2 }), &.{
            .null,    .init(0),
            .init(1), .init(1),
            .init(1), .init(2),
            .init(3), .init(3),
        })),
    );
}

pub const TableDesc = struct {
    entry_kind: []const u8,
    entries: []const []const u8,
    categories: []const CategoryDesc,

    pub const CategoryDesc = struct {
        name: []const u8,
        properties: []const []const u8,
    };
};

/// Outputs the full table information in CSV format.
/// Does not output a trailing newline.
///
/// Assumes `tableValidate(data, dim) == .ok`.
/// ASsumes `desc.entries.len == dim.entries`.
/// ASsumes `desc.categories.len == dim.categories`.
/// ASsumes `desc.categories[n].properties == dim.entries`.
pub fn tableRenderCsv(
    table: Table,
    desc: TableDesc,
    /// `std.io.GenericWriter(...)` | `std.io.AnyWriter`
    writer: anytype,
) @TypeOf(writer).Error!void {
    try writeCsvString(desc.entry_kind, writer);
    for (desc.categories, 0..table.dim.categories) |category_val, _| {
        try writer.writeByte(',');
        try writeCsvString(category_val.name, writer);
    }

    for (desc.entries, 0..table.dim.entries) |entry_name, entry_val| {
        try writer.writeByte('\n');
        try writeCsvString(entry_name, writer);

        for (desc.categories, 0..table.dim.categories) |category_desc, category_val| {
            assert(category_desc.properties.len == table.dim.entries);
            try writer.writeByte(',');
            const value_idx = table.dim.locationToIndex(.{
                .entry = .init(entry_val),
                .category = .init(category_val),
            });
            const value = table.data[value_idx];
            try writeCsvString(category_desc.properties[@intFromEnum(value)], writer);
        }
    }
}

fn writeCsvString(
    string: []const u8,
    writer: anytype,
) @TypeOf(writer).Error!void {
    var need_quotes = false;
    var index: usize = 0;
    while (true) {
        const start_index = index;
        const end_index = std.mem.indexOfAnyPos(u8, string, start_index, &.{ ',', '"' }) orelse {
            try writer.writeAll(string[start_index..]);
            break;
        };

        index = end_index + 1;

        if (!need_quotes) {
            assert(start_index == 0);
            try writer.writeByte('"');
        }

        need_quotes = true;

        try writer.writeAll(string[start_index..index]);

        switch (string[end_index]) {
            ',' => assert(need_quotes),
            '"' => try writer.writeByte('"'),
            else => unreachable,
        }
    }
    if (need_quotes) {
        try writer.writeByte('"');
    }
}

fn testTableWriteCsv(
    table: Table,
    desc: TableDesc,
    expected: []const u8,
) !void {
    try std.testing.expectEqual(.ok, validate(table));

    var actual_string: std.ArrayListUnmanaged(u8) = .empty;
    defer actual_string.deinit(std.testing.allocator);
    try tableRenderCsv(table, desc, actual_string.writer(std.testing.allocator));
    try std.testing.expectEqualStrings(expected, actual_string.items);
}

test tableRenderCsv {
    try testTableWriteCsv(
        .table(try .initStridedProperties(15, .{ .categories = 3 }), &.{
            .init(0), .init(4), .init(3),
            .init(2), .init(1), .init(0),
            .init(4), .init(3), .init(2),
            .init(1), .init(0), .init(4),
            .init(3), .init(2), .init(1),
        }),
        .{
            .entry_kind = "OO",
            .entries = &.{ "D_", "E_", "F_", "G_", "H_" },
            .categories = &.{
                .{ .name = "_A", .properties = &.{ "DA", "GA", "EA", "HA", "FA" } },
                .{ .name = "_B", .properties = &.{ "GB", "EB", "HB", "FB", "DB" } },
                .{ .name = "_C", .properties = &.{ "EC", "HC", "FC", "DC", "GC" } },
            },
        },
        \\OO,_A,_B,_C
        \\D_,DA,DB,DC
        \\E_,EA,EB,EC
        \\F_,FA,FB,FC
        \\G_,GA,GB,GC
        \\H_,HA,HB,HC
        ,
    );
    // \/
    //    _A _B
    // _C ++ ++
    // _B ++
    //
    // \/
    //
    //   ┃DA┃GA┃EA┃HA┃FA│GB┃EB┃HB┃FB┃DB│
    // ━━╋━━╋━━╋━━╋━━╋━━│━━╋━━╋━━╋━━╋━━│
    // EC┃--┃--┃OO┃--┃--│--┃OO┃--┃--┃--│
    // ━━╋━━╋━━╋━━╋━━╋━━│━━╋━━╋━━╋━━╋━━│
    // HC┃--┃--┃--┃OO┃--│--┃--┃OO┃--┃--│
    // ━━╋━━╋━━╋━━╋━━╋━━│━━╋━━╋━━╋━━╋━━│
    // FC┃--┃--┃--┃--┃OO│--┃--┃--┃OO┃--│
    // ━━╋━━╋━━╋━━╋━━╋━━│━━╋━━╋━━╋━━╋━━│
    // DC┃OO┃--┃--┃--┃--│--┃--┃--┃--┃OO│
    // ━━╋━━╋━━╋━━╋━━╋━━│━━╋━━╋━━╋━━╋━━│
    // GC┃--┃OO┃--┃--┃--│OO┃--┃--┃--┃--│
    // ─────────────────┼──────────────┘
    // GB┃--┃OO┃--┃--┃--│
    // ━━╋━━╋━━╋━━╋━━╋━━│
    // EB┃--┃--┃OO┃--┃--│
    // ━━╋━━╋━━╋━━╋━━╋━━│
    // HB┃--┃--┃--┃OO┃--│
    // ━━╋━━╋━━╋━━╋━━╋━━│
    // FB┃--┃--┃--┃--┃OO│
    // ━━╋━━╋━━╋━━╋━━╋━━│
    // DB┃OO┃--┃--┃--┃--│
    // ─────────────────┘

    {
        const table_desc: TableDesc = .{
            .entry_kind = "person",
            .entries = &.{
                "Alex     ",
                "Sandy    ",
                "Cassandra",
                "Freddy   ",
            },
            .categories = &.{
                .{ .name = "Score", .properties = &.{ "10", "20", "30", "40" } },
                .{ .name = "Deaths", .properties = &.{ "30", "20", "10", "00" } },
            },
        };

        const s10: Property = .init(0);
        const s20: Property = .init(1);
        const s30: Property = .init(2);
        const s40: Property = .init(3);

        const d30: Property = .init(0);
        const d20: Property = .init(1);
        const d10: Property = .init(2);
        const d00: Property = .init(3);

        const table_dim: Dimensions = try .initStridedProperties(
            table_desc.entries.len * table_desc.categories.len,
            .{ .categories = 2 },
        );

        const test_cases = [_]struct { []const Property, []const u8 }{
            .{
                &.{
                    s10, d30,
                    s20, d20,
                    s30, d10,
                    s40, d00,
                },
                \\person,Score,Deaths
                \\Alex     ,10,30
                \\Sandy    ,20,20
                \\Cassandra,30,10
                \\Freddy   ,40,00
            },
            .{
                &.{
                    s20, d30,
                    s10, d20,
                    s30, d10,
                    s40, d00,
                },
                \\person,Score,Deaths
                \\Alex     ,20,30
                \\Sandy    ,10,20
                \\Cassandra,30,10
                \\Freddy   ,40,00
            },
            .{
                &.{
                    s30, d10,
                    s10, d00,
                    s20, d20,
                    s40, d30,
                },
                \\person,Score,Deaths
                \\Alex     ,30,10
                \\Sandy    ,10,00
                \\Cassandra,20,20
                \\Freddy   ,40,30
            },
            .{
                &.{
                    s40, d00,
                    s30, d10,
                    s20, d20,
                    s10, d30,
                },
                \\person,Score,Deaths
                \\Alex     ,40,00
                \\Sandy    ,30,10
                \\Cassandra,20,20
                \\Freddy   ,10,30
            },
        };

        for (test_cases, 0..) |pair, i| {
            errdefer std.log.err("{s}@L{}: Failed on test case {d}", .{ @src().fn_name, @src().line, i });
            const table_data, const expected = pair;
            try testTableWriteCsv(
                .table(table_dim, table_data),
                table_desc,
                expected,
            );
        }
    }
}

inline fn uintBase10StrLit(comptime int: anytype) [:0]const u8 {
    comptime return @typeInfo(@TypeOf(.{{}} ** (int + 1))).@"struct".fields[int].name;
}
