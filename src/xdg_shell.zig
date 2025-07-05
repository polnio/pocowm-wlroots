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

pub fn getFocus(self: *XdgShellMgr) ?*Toplevel {
    const previous_surface = self.pocowm.seat.keyboard_state.focused_surface orelse return null;
    const xdg_surface = wlr.XdgSurface.tryFromWlrSurface(previous_surface) orelse return null;
    for (self.pocowm.xdg_shell_mgr.toplevels.items) |toplevel| {
        if (toplevel.xdg_toplevel.base == xdg_surface) return toplevel;
    }
    return null;
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
    on_destroy: wl.Listener(void) = .init(onDestroy),
    // on_request_move: wl.Listener(void) = .init(onRequestMove),
    // on_request_resize: wl.Listener(void) = .init(onRequestResize),

    fn create(pocowm: *PocoWM, xdg_toplevel: *wlr.XdgToplevel, allocator: std.mem.Allocator) !*Toplevel {
        const self = try allocator.create(Toplevel);
        errdefer allocator.destroy(self);
        const xdg_shell_mgr = &pocowm.xdg_shell_mgr;
        self.* = .{
            .base = .{ .parent = .{ .xdg_toplevel = self } },
            .allocator = allocator,
            .pocowm = pocowm,
            .xdg_toplevel = xdg_toplevel,
            .scene_tree = try pocowm.layer_shell_mgr.layers.normal.scene_tree.createSceneXdgSurface(xdg_toplevel.base),
        };

        self.scene_tree.node.data = @intFromPtr(&self.base);
        xdg_toplevel.base.surface.data = @intFromPtr(self.scene_tree);
        xdg_toplevel.base.surface.events.commit.add(&self.on_surface_commit);
        xdg_toplevel.events.destroy.add(&self.on_destroy);

        try xdg_shell_mgr.toplevels.append(self);
        const focused_ = if (self.pocowm.xdg_shell_mgr.getFocus()) |f| self.pocowm.layout.getWindow(f) else null;
        if (focused_) |focused| {
            _ = try self.pocowm.layout.addWindow(self, focused.parent);
        } else {
            _ = try self.pocowm.layout.addWindow(self, &self.pocowm.layout.root);
        }
        self.focus(null);
        return self;
    }
    fn destroy(self: *Toplevel) void {
        if (self.xdg_toplevel.base.initial_commit) {
            self.on_surface_commit.link.remove();
        }
        self.on_destroy.link.remove();

        const xdg_shell_mgr = &self.pocowm.xdg_shell_mgr;
        if (self.pocowm.layout.getWindow(self)) |window| {
            self.pocowm.layout.removeWindow(window);
        }
        const index = utils.find_index(*Toplevel, xdg_shell_mgr.toplevels.items, self) orelse return;
        _ = xdg_shell_mgr.toplevels.swapRemove(index);
        self.allocator.destroy(self);
    }

    pub fn setGeometry(self: *Toplevel, geometry: utils.Geometry(i32)) void {
        self.scene_tree.node.setPosition(geometry.x, geometry.y);
        _ = self.xdg_toplevel.setSize(geometry.width, geometry.height);
    }

    pub fn isFocused(self: *Toplevel) bool {
        const previous_surface = self.pocowm.seat.keyboard_state.focused_surface orelse return false;
        return previous_surface == self.xdg_toplevel.base.surface;
    }

    pub fn focus(self: *Toplevel, surface: ?*wlr.Surface) void {
        const surface_ = surface orelse self.xdg_toplevel.base.surface;
        if (self.pocowm.seat.keyboard_state.focused_surface) |previous_surface| {
            if (previous_surface == surface_) return;
            if (wlr.XdgSurface.tryFromWlrSurface(previous_surface)) |xdg_surface| {
                _ = xdg_surface.role_data.toplevel.?.setActivated(false);
            }
        }

        self.scene_tree.node.raiseToTop();

        _ = self.xdg_toplevel.setActivated(true);

        if (self.pocowm.seat.getKeyboard()) |keyboard| {
            self.pocowm.seat.keyboardNotifyEnter(surface_, keyboard.keycodes[0..keyboard.num_keycodes], &keyboard.modifiers);
        }
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
