const std = @import("std");

const wlr = @import("wlroots");

const PocoWM = @import("main.zig").PocoWM;

const XdgOutputMgr = @This();

allocator: std.mem.Allocator,
pocowm: *PocoWM,
xdg_output_manager: *wlr.XdgOutputManagerV1,

/// Depends on OutputMgr
pub fn init(self: *XdgOutputMgr, pocowm: *PocoWM, allocator: std.mem.Allocator) !void {
    self.* = .{
        .allocator = allocator,
        .pocowm = pocowm,
        .xdg_output_manager = try wlr.XdgOutputManagerV1.create(pocowm.wl_server, pocowm.output_mgr.output_layout),
    };
}
