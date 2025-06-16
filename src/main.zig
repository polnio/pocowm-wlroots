const std = @import("std");

const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const xkb = @import("xkbcommon");

const InputMgr = @import("input.zig");
const Layout = @import("layout.zig");
const OutputMgr = @import("output.zig");
const Toplevel = @import("xdg_shell.zig").Toplevel;
const XdgShellMgr = @import("xdg_shell.zig");

const c = @cImport({
    @cInclude("stdlib.h");
});

pub fn main() anyerror!void {
    wlr.log.init(.debug, null);

    const allocator = std.heap.page_allocator;

    var pocowm: PocoWM = undefined;
    try pocowm.init(allocator);
    defer pocowm.deinit();

    try pocowm.start();
}

pub const PocoWM = struct {
    allocator: std.mem.Allocator,
    wl_server: *wl.Server,
    backend: *wlr.Backend,
    renderer: *wlr.Renderer,
    scene: *wlr.Scene,
    wlr_allocator: *wlr.Allocator,
    seat: *wlr.Seat,

    input_mgr: InputMgr,
    output_mgr: OutputMgr,
    xdg_shell_mgr: XdgShellMgr,
    layout: Layout,

    socket_buf: [11]u8 = undefined,
    socket: [:0]const u8 = undefined,

    fn init(self: *PocoWM, allocator: std.mem.Allocator) !void {
        self.* = .{
            .allocator = allocator,
            .wl_server = try wl.Server.create(),
            .backend = try wlr.Backend.autocreate(self.wl_server.getEventLoop(), null),
            .renderer = try wlr.Renderer.autocreate(self.backend),
            .scene = try wlr.Scene.create(),
            .seat = try wlr.Seat.create(self.wl_server, "default"),
            .wlr_allocator = try wlr.Allocator.autocreate(self.backend, self.renderer),
            .input_mgr = undefined,
            .output_mgr = undefined,
            .xdg_shell_mgr = undefined,
            .layout = undefined,
        };
        try self.output_mgr.init(self, allocator);
        try self.input_mgr.init(self, allocator);
        try self.xdg_shell_mgr.init(self, allocator);
        self.layout.init(allocator);

        try self.renderer.initServer(self.wl_server);

        _ = try wlr.Compositor.create(self.wl_server, 6, self.renderer);
        _ = try wlr.Subcompositor.create(self.wl_server);
        _ = try wlr.DataDeviceManager.create(self.wl_server);

        self.socket = try self.wl_server.addSocketAuto(&self.socket_buf);
    }

    fn start(self: *PocoWM) !void {
        try self.backend.start();
        _ = c.setenv("WAYLAND_DISPLAY", self.socket, 1);
        std.log.info("Running compositor on WAYLAND_DISPLAY={s}", .{self.socket});
        self.wl_server.run();
    }

    fn deinit(self: *PocoWM) void {
        self.wl_server.destroyClients();
        self.backend.destroy();
        self.wl_server.destroy();
        self.output_mgr.deinit();
        self.xdg_shell_mgr.deinit();
    }

    const ViewAtResult = struct {
        toplevel: *Toplevel,
        surface: *wlr.Surface,
        sx: f64,
        sy: f64,
    };

    pub fn viewAt(self: *PocoWM, x: f64, y: f64) ?ViewAtResult {
        var sx: f64 = undefined;
        var sy: f64 = undefined;
        const node = self.scene.tree.node.at(x, y, &sx, &sy) orelse return null;
        if (node.type != .buffer) return null;
        const scene_buffer = wlr.SceneBuffer.fromNode(node);
        const scene_surface = wlr.SceneSurface.tryFromBuffer(scene_buffer) orelse return null;

        var it = node.parent;
        while (it) |n| : (it = n.node.parent) {
            if (@as(?*Toplevel, @ptrFromInt(n.node.data))) |toplevel| {
                return ViewAtResult{
                    .toplevel = toplevel,
                    .surface = scene_surface.surface,
                    .sx = sx,
                    .sy = sy,
                };
            }
        }
        return null;
    }
};
