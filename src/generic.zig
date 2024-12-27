const std = @import("std");
const assert = std.debug.assert;

const mem = @import("mem.zig");

comptime {
    if (@import("builtin").is_test) {
        const bit_sizes = [_]u16{ 8, 16, 32, 64 };
        for (bit_sizes) |index_bits| {
            if (index_bits > @bitSizeOf(usize)) continue;
            _ = Generic(index_bits);
        }
    }
}

pub fn Generic(comptime index_bits: u16) type {
    {
        const usize_bits_str = uintBase10StrLit(@bitSizeOf(usize));
        if (index_bits < 8 or index_bits > @bitSizeOf(usize)) @compileError(
            "property_bits (" ++ uintBase10StrLit(index_bits) ++ ") must be greater than or equal to 8, and less than or equal to `@bitSizeOf(usize)` (" ++ usize_bits_str ++ ")",
        );
    }

    return struct {
        pub const Int = std.meta.Int(.unsigned, index_bits);

        /// A strictly typed alias for `Int`, representing a property index.
        pub const Property = enum(Int) {
            null = std.math.maxInt(Int),
            _,

            pub fn init(value: Int) Property {
                return @enumFromInt(value);
            }

            pub const Location = struct {
                entry: Entry,
                category: Category,
            };
        };

        /// A strictly typed alias for `Int`, representing a category index.
        pub const Category = enum(Int) {
            null = std.math.maxInt(Int),
            _,

            pub fn init(value: Int) Category {
                return @enumFromInt(value);
            }
        };

        /// A strictly typed alias for `Int`, representing an entry index.
        pub const Entry = enum(Int) {
            null = std.math.maxInt(Int),
            _,

            pub fn init(value: Int) Entry {
                return @enumFromInt(value);
            }
        };

        pub const Dimensions = struct {
            /// The number of entries.
            entries: Int,
            /// The number of categories (values per entry).
            categories: Int,

            pub const OneStride = union(enum) {
                entries: Int,
                categories: Int,
            };

            pub const InitStridedPropertiesError = error{
                /// The specified stride did not evenly divide the property count into the other stride.
                InexactStride,
                /// There must be more than one entry.
                TooFewEntries,
                /// There must be more than one category.
                TooFewCategories,
            };
            pub fn initStridedProperties(
                one_stride: OneStride,
                property_count: Int,
            ) InitStridedPropertiesError!Dimensions {
                return switch (one_stride) {
                    inline .entries, .categories => |stride, tag| blk: {
                        if (stride < 2) switch (tag) {
                            .entries => return error.TooFewEntries,
                            .categories => return error.TooFewCategories,
                        };
                        if (property_count % stride != 0) {
                            return error.InexactStride;
                        }

                        const other_stride: @FieldType(OneStride, @tagName(tag)) = @divExact(property_count, stride);
                        break :blk switch (tag) {
                            // zig fmt: off
                            .entries    => .{ .entries = stride,       .categories = other_stride },
                            .categories => .{ .entries = other_stride, .categories = stride       },
                            // zig fmt: on
                        };
                    },
                };
            }

            pub fn totalPropertyCount(dim: Dimensions) Int {
                return @as(Int, dim.entries) * dim.categories;
            }

            pub fn indexToLocation(
                dim: Dimensions,
                prop_buf_index: Int,
            ) Property.Location {
                return .{
                    .entry = .init(prop_buf_index / dim.categories),
                    .category = .init(prop_buf_index % dim.categories),
                };
            }

            pub fn locationToIndex(
                dim: Dimensions,
                location: Property.Location,
            ) Int {
                return @intFromEnum(location.entry) * dim.categories + @intFromEnum(location.category);
            }
        };

        pub fn Table(comptime mutability: enum { mutable, immutable }) type {
            return struct {
                dim: Dimensions,
                /// An array of entries with a stride determined by `categories`.
                property_value_buffer: PropertyValueBuffer,
                const Self = @This();

                const PropertyValueBuffer = switch (mutability) {
                    .mutable => [*]Property,
                    .immutable => [*]const Property,
                };

                const Slice = switch (mutability) {
                    .mutable => []Property,
                    .immutable => []const Property,
                };

                /// See `Dimensions.initStridedProperties`.
                pub fn init(
                    one_stride: Dimensions.OneStride,
                    data: Slice,
                ) Dimensions.InitStridedPropertiesError!Self {
                    return .{
                        .dim = try .initStridedProperties(one_stride, @intCast(data.len)),
                        .property_value_buffer = data.ptr,
                    };
                }

                pub fn asConst(table: Self) Table(.immutable) {
                    return .{
                        .entries = table.entries,
                        .categories = table.categories,
                        .property_value_buffer = table.property_value_buffer,
                    };
                }

                pub fn getPropertySlice(table: Self) Slice {
                    return table.property_value_buffer[0..table.dim.totalPropertyCount()];
                }
            };
        }

        pub const TableStatus = union(enum) {
            ok,
            invalid_property: Property.Location,
            duplicate_property: DuplicateProperty,

            pub const DuplicateProperty = struct {
                entry_a: Entry,
                entry_b: Entry,
                category: Category,
            };
        };

        pub fn tableValidate(table: Table(.immutable)) TableStatus {
            const all_properties: []const Property = table.getPropertySlice();

            if (mem.indexOfEqualOrGreaterPos(Property, all_properties, 0, .init(table.dim.entries))) |prop_buf_index| {
                return .{ .invalid_property = table.dim.indexToLocation(@intCast(prop_buf_index)) };
            }

            for (0..table.dim.entries) |entry_val| {
                const entry_props = all_properties[entry_val * table.dim.categories ..][0..table.dim.categories];

                for (entry_val + 1..table.dim.entries) |other_entry_val| {
                    const other_entry_props = all_properties[other_entry_val * table.dim.categories ..][0..table.dim.categories];
                    if (mem.indexOfEqual(Property, entry_props, other_entry_props)) |category_val| {
                        return .{ .duplicate_property = .{
                            .entry_a = .init(@intCast(entry_val)),
                            .entry_b = .init(@intCast(other_entry_val)),
                            .category = .init(@intCast(category_val)),
                        } };
                    }
                }
            }

            return .ok;
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

        /// Assumes `tableValidate(table) == .ok`.
        /// ASsumes `desc.entries.len == table.dim.entries`.
        /// ASsumes `desc.categories.len == table.dim.categories`.
        /// ASsumes `desc.categories[n].properties == table.dim.entries`.
        pub fn tableRenderCsv(
            table: Table(.immutable),
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
                        .entry = .init(@intCast(entry_val)),
                        .category = .init(@intCast(category_val)),
                    });
                    const value = table.getPropertySlice()[value_idx];
                    try writeCsvString(category_desc.properties[@intFromEnum(value)], writer);
                }
            }
        }

        fn testTableWriteCsv(table: Table(.immutable), desc: TableDesc, expected: []const u8) !void {
            try std.testing.expectEqual(.ok, tableValidate(table));

            var actual_string: std.ArrayListUnmanaged(u8) = .empty;
            defer actual_string.deinit(std.testing.allocator);
            try tableRenderCsv(table, desc, actual_string.writer(std.testing.allocator));
            try std.testing.expectEqualStrings(expected, actual_string.items);
        }

        test tableRenderCsv {
            try testTableWriteCsv(
                try .init(.{ .entries = 5 }, &.{
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

            for (0.., [_]struct { Table(.immutable), []const u8 }{
                .{
                    try .init(.{ .categories = 2 }, &.{
                        .init(0), .init(0),
                        .init(1), .init(1),
                        .init(2), .init(2),
                        .init(3), .init(3),
                    }),
                    \\person,Score,Deaths
                    \\Alex     ,10,30
                    \\Sandy    ,20,20
                    \\Cassandra,30,10
                    \\Freddy   ,40,00
                },
                .{
                    try .init(.{ .categories = 2 }, &.{
                        .init(1), .init(0),
                        .init(0), .init(1),
                        .init(2), .init(2),
                        .init(3), .init(3),
                    }),
                    \\person,Score,Deaths
                    \\Alex     ,20,30
                    \\Sandy    ,10,20
                    \\Cassandra,30,10
                    \\Freddy   ,40,00
                },
                .{
                    try .init(.{ .categories = 2 }, &.{
                        .init(2), .init(2),
                        .init(0), .init(3),
                        .init(1), .init(1),
                        .init(3), .init(0),
                    }),
                    \\person,Score,Deaths
                    \\Alex     ,30,10
                    \\Sandy    ,10,00
                    \\Cassandra,20,20
                    \\Freddy   ,40,30
                },
            }) |i, pair| {
                errdefer std.log.err("{s}@L{}: Failed on test case {d}", .{ @src().fn_name, @src().line, i });
                const table, const expected = pair;
                try testTableWriteCsv(table, .{
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
                }, expected);
            }
        }
    };
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

inline fn uintBase10StrLit(comptime int: anytype) [:0]const u8 {
    comptime return @typeInfo(@TypeOf(.{{}} ** (int + 1))).@"struct".fields[int].name;
}
