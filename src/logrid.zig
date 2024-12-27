const generic = @import("generic.zig");
pub const Generic = generic.Generic;
pub const native = Generic(@bitSizeOf(usize));

comptime {
    _ = generic;
    _ = native;
}
