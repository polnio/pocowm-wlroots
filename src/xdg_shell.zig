const std = @import("std");

const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");

const PocoWM = @import("main.zig").PocoWM;
const utils = @import("utils.zig");

const XdgShellMgr = @This();

allocator: std.mem.Allocator,
pocowm: *PocoWM,
xdg_shell: *wlr.XdgShell,

on_new_toplevel: wl.Listener(*wlr.XdgToplevel) = .init(onNewToplevel),
on_new_popup: wl.Listener(*wlr.XdgPopup) = .init(onNewPopup),

toplevels: std.ArrayList(*Toplevel),

pub fn init(self: *XdgShellMgr, pocowm: *PocoWM, allocator: std.mem.Allocator) !void {
    self.* = .{
        .allocator = allocator,
        .pocowm = pocowm,
        .xdg_shell = try wlr.XdgShell.create(pocowm.wl_server, 2),
        .toplevels = std.ArrayList(*Toplevel).init(allocator),
    };
    self.xdg_shell.events.new_toplevel.add(&self.on_new_toplevel);
    self.xdg_shell.events.new_popup.add(&self.on_new_popup);
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
    _ = Toplevel.create(self.pocowm, xdg_toplevel, self.allocator) catch {
        std.log.err("failed to allocate new toplevel", .{});
        return;
    };
}

fn onNewPopup(listener: *wl.Listener(*wlr.XdgPopup), xdg_popup: *wlr.XdgPopup) void {
    _ = listener;
    _ = xdg_popup;
}

pub const Toplevel = struct {
    pocowm: *PocoWM,
    xdg_toplevel: *wlr.XdgToplevel,
    scene_tree: *wlr.SceneTree,

    is_mapped: bool = false,

    // TODO: implement events handlers
    on_surface_commit: wl.Listener(*wlr.Surface) = .init(onSurfaceCommit),
    on_surface_map: wl.Listener(void) = .init(onSurfaceMap),
    on_surface_unmap: wl.Listener(void) = .init(onSurfaceUnmap),
    on_destroy: wl.Listener(void) = .init(onDestroy),
    // on_request_move: wl.Listener(void) = .init(onRequestMove),
    // on_request_resize: wl.Listener(void) = .init(onRequestResize),

    fn create(pocowm: *PocoWM, xdg_toplevel: *wlr.XdgToplevel, allocator: std.mem.Allocator) !*Toplevel {
        const self = try allocator.create(Toplevel);
        errdefer allocator.destroy(self);
        const xdg_shell_mgr = &pocowm.xdg_shell_mgr;
        self.* = .{
            .pocowm = pocowm,
            .xdg_toplevel = xdg_toplevel,
            .scene_tree = try pocowm.scene.tree.createSceneXdgSurface(xdg_toplevel.base),
        };

        self.scene_tree.node.data = @intFromPtr(self);
        xdg_toplevel.base.data = @intFromPtr(self.scene_tree);
        xdg_toplevel.base.surface.events.map.add(&self.on_surface_map);
        xdg_toplevel.base.surface.events.unmap.add(&self.on_surface_unmap);
        xdg_toplevel.base.surface.events.commit.add(&self.on_surface_commit);
        xdg_toplevel.events.destroy.add(&self.on_destroy);

        try xdg_shell_mgr.toplevels.append(self);
        _ = try self.pocowm.layout.addWindow(self, &self.pocowm.layout.root);
        return self;
    }
    fn destroy(self: *Toplevel) void {
        const xdg_shell_mgr = &self.pocowm.xdg_shell_mgr;
        if (self.pocowm.layout.getWindow(self)) |window| {
            self.pocowm.layout.removeWindow(window);
        }
        const index = utils.find_index(*Toplevel, xdg_shell_mgr.toplevels.items, self) orelse return;
        _ = xdg_shell_mgr.toplevels.swapRemove(index);
    }

    pub fn isFocused(self: *Toplevel) bool {
        const previous_surface = self.pocowm.seat.keyboard_state.focused_surface orelse return false;
        return previous_surface == self.xdg_toplevel.base.surface;
    }

    pub fn focus(self: *Toplevel, surface: *wlr.Surface) void {
        if (self.pocowm.seat.keyboard_state.focused_surface) |previous_surface| {
            if (previous_surface == surface) return;
            if (wlr.XdgSurface.tryFromWlrSurface(previous_surface)) |xdg_surface| {
                _ = xdg_surface.role_data.toplevel.?.setActivated(false);
            }
        }

        self.scene_tree.node.raiseToTop();

        _ = self.xdg_toplevel.setActivated(true);

        if (self.pocowm.seat.getKeyboard()) |keyboard| {
            self.pocowm.seat.keyboardNotifyEnter(surface, keyboard.keycodes[0..keyboard.num_keycodes], &keyboard.modifiers);
        }
    }

    fn onSurfaceCommit(listener: *wl.Listener(*wlr.Surface), xdg_surface: *wlr.Surface) void {
        _ = xdg_surface;
        const self: *Toplevel = @fieldParentPtr("on_surface_commit", listener);
        if (self.xdg_toplevel.base.initial_commit) {
            _ = self.xdg_toplevel.setSize(0, 0);
        }
    }

    fn onSurfaceMap(listener: *wl.Listener(void)) void {
        const self: *Toplevel = @fieldParentPtr("on_surface_map", listener);
        self.is_mapped = true;
        self.focus(self.xdg_toplevel.base.surface);
    }

    fn onSurfaceUnmap(listener: *wl.Listener(void)) void {
        const self: *Toplevel = @fieldParentPtr("on_surface_unmap", listener);
        self.is_mapped = true;
    }

    fn onDestroy(listener: *wl.Listener(void)) void {
        const self: *Toplevel = @fieldParentPtr("on_destroy", listener);
        self.destroy();
    }
};
