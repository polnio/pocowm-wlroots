const std = @import("std");

const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");

const PocoWM = @import("main.zig").PocoWM;
const BaseSurface = @import("main.zig").BaseSurface;
const utils = @import("utils.zig");

const XdgShellMgr = @This();

allocator: std.mem.Allocator,
pocowm: *PocoWM,
xdg_shell: *wlr.XdgShell,

on_new_toplevel: wl.Listener(*wlr.XdgToplevel) = .init(onNewToplevel),
on_destroy: wl.Listener(*wlr.XdgShell) = .init(onMgrDestroy),

toplevels: std.ArrayList(*Toplevel),
focused_toplevel: ?*Toplevel = null,

pub fn init(self: *XdgShellMgr, pocowm: *PocoWM, allocator: std.mem.Allocator) !void {
    self.* = .{
        .allocator = allocator,
        .pocowm = pocowm,
        .xdg_shell = try wlr.XdgShell.create(pocowm.wl_server, 2),
        .toplevels = std.ArrayList(*Toplevel).init(allocator),
    };
    self.xdg_shell.events.new_toplevel.add(&self.on_new_toplevel);
    self.xdg_shell.events.destroy.add(&self.on_destroy);
}

pub fn deinit(self: *XdgShellMgr) void {
    _ = self;
}

pub fn updateFocus(self: *XdgShellMgr) void {
    const previous_surface = self.pocowm.input_mgr.getFocus() orelse return;
    const xdg_surface = wlr.XdgSurface.tryFromWlrSurface(previous_surface) orelse return;
    for (self.pocowm.xdg_shell_mgr.toplevels.items) |toplevel| {
        if (toplevel.xdg_toplevel.base == xdg_surface) {
            self.focused_toplevel = toplevel;
            return;
        }
    }
}

fn onNewToplevel(listener: *wl.Listener(*wlr.XdgToplevel), xdg_toplevel: *wlr.XdgToplevel) void {
    const self: *XdgShellMgr = @fieldParentPtr("on_new_toplevel", listener);
    _ = Toplevel.create(self.pocowm, xdg_toplevel, self.allocator) catch |err| {
        std.log.err("failed to allocate new toplevel: {s}", .{@errorName(err)});
        return;
    };
}

fn onMgrDestroy(listener: *wl.Listener(*wlr.XdgShell), _: *wlr.XdgShell) void {
    const self: *XdgShellMgr = @fieldParentPtr("on_destroy", listener);
    self.on_new_toplevel.link.remove();
    self.on_destroy.link.remove();
}

pub const Toplevel = struct {
    base: BaseSurface,
    allocator: std.mem.Allocator,
    pocowm: *PocoWM,
    xdg_toplevel: *wlr.XdgToplevel,
    scene_tree: *wlr.SceneTree,

    // TODO: implement events handlers
    on_new_popup: wl.Listener(*wlr.XdgPopup) = .init(onNewPopup),
    on_surface_commit: wl.Listener(*wlr.Surface) = .init(onSurfaceCommit),
    on_request_move: wl.Listener(*wlr.XdgToplevel.event.Move) = .init(onRequestMove),
    on_request_resize: wl.Listener(*wlr.XdgToplevel.event.Resize) = .init(onRequestResize),
    on_request_maximize: wl.Listener(void) = .init(onRequestMaximize),
    on_request_fullscreen: wl.Listener(void) = .init(onRequestFullscreen),
    on_destroy: wl.Listener(void) = .init(onDestroy),

    fn create(pocowm: *PocoWM, xdg_toplevel: *wlr.XdgToplevel, allocator: std.mem.Allocator) !*Toplevel {
        const output, const focused = pocowm.getOutputAndFocusedWindow();
        const self = try allocator.create(Toplevel);
        errdefer allocator.destroy(self);
        const xdg_shell_mgr = &pocowm.xdg_shell_mgr;
        self.* = .{
            .base = .{ .parent = .{ .xdg_toplevel = self } },
            .allocator = allocator,
            .pocowm = pocowm,
            .xdg_toplevel = xdg_toplevel,
            .scene_tree = try output.layers.tiled_views.scene_tree.createSceneXdgSurface(xdg_toplevel.base),
        };

        self.scene_tree.node.data = @intFromPtr(&self.base);
        xdg_toplevel.base.surface.data = @intFromPtr(self.scene_tree);
        xdg_toplevel.base.events.new_popup.add(&self.on_new_popup);
        xdg_toplevel.base.surface.events.commit.add(&self.on_surface_commit);
        xdg_toplevel.events.request_move.add(&self.on_request_move);
        xdg_toplevel.events.request_resize.add(&self.on_request_resize);
        xdg_toplevel.events.request_maximize.add(&self.on_request_maximize);
        xdg_toplevel.events.request_fullscreen.add(&self.on_request_fullscreen);
        xdg_toplevel.events.destroy.add(&self.on_destroy);

        try xdg_shell_mgr.toplevels.append(self);
        const sublayout = if (focused) |f| f.parent else &output.layout.root;
        const window = try output.layout.addWindow(self, sublayout);
        var output_box: wlr.Box = undefined;
        self.pocowm.output_mgr.output_layout.getBox(output.wlr_output, &output_box);
        window.floating_box = wlr.Box{
            .x = @divTrunc(output_box.width, 4),
            .y = @divTrunc(output_box.height, 4),
            .width = @divTrunc(output_box.width, 2),
            .height = @divTrunc(output_box.height, 2),
        };
        self.focus(null);
        return self;
    }
    fn destroy(self: *Toplevel) void {
        if (self.xdg_toplevel.base.initial_commit) {
            self.on_surface_commit.link.remove();
        }
        self.on_new_popup.link.remove();
        self.on_request_move.link.remove();
        self.on_request_resize.link.remove();
        self.on_request_maximize.link.remove();
        self.on_request_fullscreen.link.remove();
        self.on_destroy.link.remove();

        const xdg_shell_mgr = &self.pocowm.xdg_shell_mgr;
        if (self.pocowm.output_mgr.getOutputAndWindow(self)) |r| {
            const output, const window = r;
            output.layout.removeWindow(window);
        }
        const index = utils.find_index(*Toplevel, xdg_shell_mgr.toplevels.items, self) orelse return;
        _ = xdg_shell_mgr.toplevels.swapRemove(index);
        self.allocator.destroy(self);
    }

    pub fn getEdgeAt(self: *Toplevel, x: i32, y: i32) wlr.Edges {
        const width = self.xdg_toplevel.current.width;
        const height = self.xdg_toplevel.current.height;
        const edges = wlr.Edges{
            .left = x << 1 < width,
            .right = x << 1 > width,
            .top = y << 1 < height,
            .bottom = y << 1 > height,
        };
        return edges;
    }

    pub fn setGeometry(self: *Toplevel, geometry: wlr.Box) void {
        self.scene_tree.node.setPosition(geometry.x, geometry.y);
        _ = self.xdg_toplevel.setSize(geometry.width, geometry.height);
    }

    pub fn isFocused(self: *Toplevel) bool {
        const previous_surface = self.pocowm.seat.keyboard_state.focused_surface orelse return false;
        return previous_surface == self.xdg_toplevel.base.surface;
    }

    pub fn focus(self: *Toplevel, surface: ?*wlr.Surface) void {
        const surface_ = surface orelse self.xdg_toplevel.base.surface;
        if (self.pocowm.xdg_shell_mgr.focused_toplevel == self) return;
        if (self.pocowm.input_mgr.getFocus()) |previous_surface| {
            if (previous_surface == surface_) return;
            if (wlr.XdgSurface.tryFromWlrSurface(previous_surface)) |xdg_surface| {
                _ = xdg_surface.role_data.toplevel.?.setActivated(false);
            }
        }
        self.pocowm.xdg_shell_mgr.focused_toplevel = self;

        self.scene_tree.node.raiseToTop();

        _ = self.xdg_toplevel.setActivated(true);

        if (self.pocowm.seat.getKeyboard()) |keyboard| {
            self.pocowm.seat.keyboardNotifyEnter(surface_, keyboard.keycodes[0..keyboard.num_keycodes], &keyboard.modifiers);
        }
    }

    pub fn startMove(self: *Toplevel) void {
        _, const window = self.pocowm.output_mgr.getOutputAndWindow(self) orelse return;
        if (window.state != .floating) return;

        var cursor = &self.pocowm.input_mgr.cursor;

        cursor.mode = .move;
        cursor.grab = .{
            .grab_x = cursor.wlr_cursor.x,
            .grab_y = cursor.wlr_cursor.y,
            .old_box = window.floating_box,
            .resize_edges = undefined,
            .toplevel = self,
        };
    }

    pub fn startResize(self: *Toplevel, edges: wlr.Edges) void {
        _, const window = self.pocowm.output_mgr.getOutputAndWindow(self) orelse return;
        if (window.state != .floating) return;

        var cursor = &self.pocowm.input_mgr.cursor;

        var box: wlr.Box = undefined;
        self.xdg_toplevel.base.getGeometry(&box);

        cursor.mode = .resize;
        cursor.grab = .{
            .grab_x = cursor.wlr_cursor.x,
            .grab_y = cursor.wlr_cursor.y,
            .old_box = window.floating_box,
            .resize_edges = edges,
            .toplevel = self,
        };
    }

    pub fn onNewPopup(listener: *wl.Listener(*wlr.XdgPopup), xdg_popup: *wlr.XdgPopup) void {
        const self: *Toplevel = @fieldParentPtr("on_new_popup", listener);
        _ = Popup.create(self.pocowm, xdg_popup, self.scene_tree, self.allocator) catch |err| {
            std.log.err("failed to create new popup: {s}", .{@errorName(err)});
        };
    }

    fn onSurfaceCommit(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
        const self: *Toplevel = @fieldParentPtr("on_surface_commit", listener);
        if (self.xdg_toplevel.base.initial_commit) {
            _ = self.xdg_toplevel.setSize(0, 0);
            self.on_surface_commit.link.remove();
        }
    }

    fn onRequestMove(listener: *wl.Listener(*wlr.XdgToplevel.event.Move), _: *wlr.XdgToplevel.event.Move) void {
        const self: *Toplevel = @fieldParentPtr("on_request_move", listener);
        self.startMove();
    }

    fn onRequestResize(listener: *wl.Listener(*wlr.XdgToplevel.event.Resize), event: *wlr.XdgToplevel.event.Resize) void {
        const self: *Toplevel = @fieldParentPtr("on_request_resize", listener);
        self.startResize(event.edges);
    }

    fn onRequestMaximize(listener: *wl.Listener(void)) void {
        const self: *Toplevel = @fieldParentPtr("on_request_maximize", listener);
        _, const window = self.pocowm.output_mgr.getOutputAndWindow(self) orelse return;
        window.toggleMaximized();
    }

    fn onRequestFullscreen(listener: *wl.Listener(void)) void {
        const self: *Toplevel = @fieldParentPtr("on_request_fullscreen", listener);
        _, const window = self.pocowm.output_mgr.getOutputAndWindow(self) orelse return;
        window.toggleFullscreen();
    }

    fn onDestroy(listener: *wl.Listener(void)) void {
        const self: *Toplevel = @fieldParentPtr("on_destroy", listener);
        self.destroy();
    }
};

pub const Popup = struct {
    base: BaseSurface,
    allocator: std.mem.Allocator,
    pocowm: *PocoWM,
    xdg_popup: *wlr.XdgPopup,
    scene_tree: *wlr.SceneTree,

    on_new_popup: wl.Listener(*wlr.XdgPopup) = .init(onNewPopup),
    on_surface_commit: wl.Listener(*wlr.Surface) = .init(onSurfaceCommit),
    on_destroy: wl.Listener(void) = .init(onDestroy),

    pub fn create(pocowm: *PocoWM, xdg_popup: *wlr.XdgPopup, parent: *wlr.SceneTree, allocator: std.mem.Allocator) !*Popup {
        const self = try allocator.create(Popup);
        self.* = .{
            .base = .{ .parent = .{ .xdg_popup = self } },
            .allocator = allocator,
            .pocowm = pocowm,
            .xdg_popup = xdg_popup,
            .scene_tree = try parent.createSceneXdgSurface(xdg_popup.base),
        };

        self.scene_tree.node.data = @intFromPtr(&self.base);
        xdg_popup.base.surface.data = @intFromPtr(self.scene_tree);
        xdg_popup.events.destroy.add(&self.on_destroy);
        xdg_popup.base.surface.events.commit.add(&self.on_surface_commit);
        return self;
    }

    pub fn destroy(self: *Popup) void {
        self.on_destroy.link.remove();
        self.allocator.destroy(self);
    }

    fn onNewPopup(listener: *wl.Listener(*wlr.XdgPopup), xdg_popup: *wlr.XdgPopup) void {
        const self: *Popup = @fieldParentPtr("on_new_popup", listener);
        _ = Popup.create(self.pocowm, xdg_popup, self.scene_tree, self.allocator) catch |err| {
            std.log.err("failed to create new popup: {s}", .{@errorName(err)});
        };
    }

    fn onSurfaceCommit(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
        const self: *Popup = @fieldParentPtr("on_surface_commit", listener);
        if (self.xdg_popup.base.initial_commit) {
            const parent = self.xdg_popup.parent orelse return;
            const mparent_tree: ?*wlr.SceneTree = @ptrFromInt(parent.data);
            const parent_tree = mparent_tree orelse return;

            var lx: c_int = undefined;
            var ly: c_int = undefined;
            var output_box: wlr.Box = undefined;
            _ = parent_tree.node.coords(&lx, &ly);
            self.pocowm.output_mgr.output_layout.getBox(null, &output_box);

            const box = wlr.Box{
                .x = output_box.x - lx,
                .y = output_box.y - ly,
                .width = output_box.width,
                .height = output_box.height,
            };
            self.xdg_popup.unconstrainFromBox(&box);

            self.on_surface_commit.link.remove();
        }
    }

    fn onDestroy(listener: *wl.Listener(void)) void {
        const self: *Popup = @fieldParentPtr("on_destroy", listener);
        self.destroy();
    }
};
