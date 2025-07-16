const std = @import("std");

pub fn find_index(comptime T: type, items: []T, value: T) ?usize {
    for (items, 0..) |item, i| {
        if (item == value) return i;
    }
    return null;
}

pub fn parseColor(str: []const u8) ![4]f32 {
    var color: [4]f32 = undefined;
    if (str.len == 0 or str[0] != '#') return error.InvalidColor;
    const rstr = str.ptr[1..str.len];
    switch (rstr.len) {
        3 => {
            for (rstr, 0..) |c, i| {
                const chex = try std.fmt.parseInt(u8, &.{c}, 16);
                const v: f32 = @floatFromInt(chex * 16 + chex);
                color[i] = v / 255.0;
            }
            color[3] = 1.0;
        },
        4 => {
            for (rstr, 0..) |c, i| {
                const chex = try std.fmt.parseInt(u8, &.{c}, 16);
                const v: f32 = @floatFromInt(chex * 16 + chex);
                color[i] = v / 255.0;
            }
        },
        6 => {
            for (0..3) |i| {
                const shex = try std.fmt.parseInt(u16, rstr[i * 2 .. i * 2 + 2], 16);
                const v: f32 = @floatFromInt(shex * 16 + shex);
                color[i] = v / 255.0;
            }
            color[3] = 1.0;
        },
        8 => {
            for (0..3) |i| {
                const shex = try std.fmt.parseInt(u16, rstr[i * 2 .. i * 2 + 2], 16);
                const v: f32 = @floatFromInt(shex * 16 + shex);
                color[i] = v / 255.0;
            }
        },
        else => return error.InvalidColor,
    }
    return color;
}

pub fn Geometry(comptime T: type) type {
    return struct {
        x: T,
        y: T,
        width: T,
        height: T,
    };
}
