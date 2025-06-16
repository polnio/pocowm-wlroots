const std = @import("std");

pub fn find_index(comptime T: type, items: []T, value: T) ?usize {
    for (items, 0..) |*item, i| {
        if (item == &value) return i;
    }
    return null;
}

pub fn Geometry(comptime T: type) type {
    return struct {
        x: T,
        y: T,
        width: T,
        height: T,
    };
}
