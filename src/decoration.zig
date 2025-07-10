const std = @import("std");

const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");

const PocoWM = @import("main.zig").PocoWM;
const Toplevel = @import("xdg_shell.zig").Toplevel;
const utils = @import("utils.zig");

pub const BORDER_SIZE: i32 = 5;
pub const BORDER_COLOR: [4]f32 = .{ 0.0, 0.0, 1.0, 1.0 }; // Blue
pub const TITLEBAR_HEIGHT: i32 = 30;
pub const TITLEBAR_COLOR: [4]f32 = .{ 1.0, 1.0, 1.0, 1.0 }; // White
pub const BUTTON_SIZE: i32 = 20;
pub const CLOSE_BUTTON_COLOR: [4]f32 = .{ 1.0, 0.0, 0.0, 1.0 }; // Red
pub const MAXIMIZE_BUTTON_COLOR: [4]f32 = .{ 0.0, 1.0, 0.0, 1.0 }; // Green
pub const BUTTON_GAP: i32 = (TITLEBAR_HEIGHT - BUTTON_SIZE) / 2;

const DecorationMgr = @This();

allocator: std.mem.Allocator,
pocowm: *PocoWM,
xdg_decoration_mgr: *wlr.XdgDecorationManagerV1,
toplevel_decorations: std.ArrayList(*ToplevelDecoration),

on_new_toplevel_decoration: wl.Listener(*wlr.XdgToplevelDecorationV1) = .init(onNewToplevelDecoration),

pub fn init(self: *DecorationMgr, pocowm: *PocoWM, allocator: std.mem.Allocator) !void {
    self.* = .{
        .allocator = allocator,
        .pocowm = pocowm,
        .xdg_decoration_mgr = try wlr.XdgDecorationManagerV1.create(pocowm.wl_server),
        .toplevel_decorations = std.ArrayList(*ToplevelDecoration).init(allocator),
    };

    self.xdg_decoration_mgr.events.new_toplevel_decoration.add(&self.on_new_toplevel_decoration);
}

pub fn deinit(self: *DecorationMgr) void {
    self.on_new_toplevel_decoration.link.remove();
    for (self.toplevel_decorations.items) |toplevel_decoration| {
        toplevel_decoration.destroy();
    }
}

fn onNewToplevelDecoration(listener: *wl.Listener(*wlr.XdgToplevelDecorationV1), xdg_toplevel_decoration: *wlr.XdgToplevelDecorationV1) void {
    const self: *DecorationMgr = @fieldParentPtr("on_new_toplevel_decoration", listener);
    const toplevel = self.pocowm.xdg_shell_mgr.getToplevel(xdg_toplevel_decoration.toplevel) orelse return;
    toplevel.decoration.attach_xdg_toplevel_decoration(xdg_toplevel_decoration);
}

const DecorationMode = enum { client_side, server_side };

pub const ToplevelDecoration = struct {
    allocator: std.mem.Allocator,
    pocowm: *PocoWM,
    toplevel: *Toplevel,
    mode: DecorationMode = .client_side, // Hack for gnome apps
    has_xdg_toplevel_decoration_attached: bool = false,

    titlebar: struct {
        all: *wlr.SceneRect,
        close_button: *wlr.SceneRect,
        maximize_button: *wlr.SceneRect,
    },
    borders: struct {
        top: *wlr.SceneRect,
        bottom: *wlr.SceneRect,
        left: *wlr.SceneRect,
        right: *wlr.SceneRect,
    },

    on_request_mode: wl.Listener(*wlr.XdgToplevelDecorationV1) = .init(onRequestMode),

    pub fn create(
        pocowm: *PocoWM,
        toplevel: *Toplevel,
        allocator: std.mem.Allocator,
    ) !*ToplevelDecoration {
        const self = try allocator.create(ToplevelDecoration);
        self.* = .{
            .allocator = allocator,
            .pocowm = pocowm,
            .toplevel = toplevel,

            .titlebar = .{
                .all = try toplevel.scene_tree.createSceneRect(0, 0, &TITLEBAR_COLOR),
                .close_button = try toplevel.scene_tree.createSceneRect(0, 0, &CLOSE_BUTTON_COLOR),
                .maximize_button = try toplevel.scene_tree.createSceneRect(0, 0, &MAXIMIZE_BUTTON_COLOR),
            },
            .borders = .{
                .top = try toplevel.scene_tree.createSceneRect(0, 0, &BORDER_COLOR),
                .bottom = try toplevel.scene_tree.createSceneRect(0, 0, &BORDER_COLOR),
                .left = try toplevel.scene_tree.createSceneRect(0, 0, &BORDER_COLOR),
                .right = try toplevel.scene_tree.createSceneRect(0, 0, &BORDER_COLOR),
            },
        };

        toplevel.decoration = self;
        self.draw();

        try pocowm.decoration_mgr.toplevel_decorations.append(self);
        return self;
    }

    pub fn destroy(self: *ToplevelDecoration) void {
        if (self.has_xdg_toplevel_decoration_attached) {
            self.on_request_mode.link.remove();
        }
        const index = utils.find_index(*ToplevelDecoration, self.pocowm.decoration_mgr.toplevel_decorations.items, self) orelse return;
        _ = self.pocowm.decoration_mgr.toplevel_decorations.swapRemove(index);
        self.allocator.destroy(self);
    }

    pub fn isTitlebarShown(self: *ToplevelDecoration) bool {
        return self.mode == .server_side and !self.toplevel.xdg_toplevel.current.fullscreen;
    }

    pub fn isBoderShown(self: *ToplevelDecoration) bool {
        return !self.toplevel.xdg_toplevel.current.maximized and !self.toplevel.xdg_toplevel.current.fullscreen;
    }

    fn attach_xdg_toplevel_decoration(self: *ToplevelDecoration, xdg_toplevel_decoration: *wlr.XdgToplevelDecorationV1) void {
        xdg_toplevel_decoration.events.request_mode.add(&self.on_request_mode);
        self.has_xdg_toplevel_decoration_attached = true;
    }

    pub fn onPointerButton(self: *ToplevelDecoration, rx: i32, ry: i32) void {
        const geometry = self.toplevel.getSurfaceGeometry();
        const is_titlebar_shown = self.isTitlebarShown();
        const offset: i32 = if (is_titlebar_shown) TITLEBAR_HEIGHT else 0;
        if (rx < -BORDER_SIZE or rx > geometry.width + BORDER_SIZE) return;
        if (ry < -BORDER_SIZE - offset or ry > geometry.height + BORDER_SIZE) return;

        var resize_edges = std.mem.zeroes(wlr.Edges);
        resize_edges.left = rx < 0;
        resize_edges.right = rx > geometry.width;
        resize_edges.top = ry < -offset;
        resize_edges.bottom = ry > geometry.height;
        // if (@as(u32, resize_edges) > 0) {
        if (@as(u32, @bitCast(resize_edges)) > 0) {
            self.toplevel.startResize(resize_edges);
            return;
        }

        if (!is_titlebar_shown) return;
        if (ry > 0) return;
        if (ry > -BUTTON_GAP) {
            self.toplevel.startMove();
            return;
        }
        if (ry > -BUTTON_GAP - BUTTON_SIZE) {
            if (rx < BUTTON_GAP) {
                self.toplevel.startMove();
                return;
            }
            if (rx < BUTTON_GAP + BUTTON_SIZE) {
                self.toplevel.xdg_toplevel.sendClose();
                return;
            }
            if (rx < BUTTON_GAP * 2 + BUTTON_SIZE) {
                self.toplevel.startMove();
                return;
            }
            if (rx < BUTTON_GAP * 2 + BUTTON_SIZE * 2) {
                _, const window = self.pocowm.output_mgr.getOutputAndWindow(self.toplevel) orelse return;
                window.toggleMaximized();
                return;
            }
        }
        self.toplevel.startMove();
        return;
    }

    pub fn draw(self: *ToplevelDecoration) void {
        const box = self.toplevel.getSurfaceGeometry();
        var offset: i32 = 0;
        if (self.isTitlebarShown()) {
            offset = TITLEBAR_HEIGHT;
            self.drawPart(self.titlebar.all, .{
                .x = 0,
                .y = -TITLEBAR_HEIGHT,
                .width = box.width,
                .height = TITLEBAR_HEIGHT,
            });
            self.drawPart(self.titlebar.close_button, .{
                .x = BUTTON_GAP,
                .y = -BUTTON_GAP - BUTTON_SIZE,
                .width = BUTTON_SIZE,
                .height = BUTTON_SIZE,
            });
            self.drawPart(self.titlebar.maximize_button, .{
                .x = BUTTON_GAP * 2 + BUTTON_SIZE,
                .y = -BUTTON_GAP - BUTTON_SIZE,
                .width = BUTTON_SIZE,
                .height = BUTTON_SIZE,
            });
        } else {
            self.hidePart(self.titlebar.all);
            self.hidePart(self.titlebar.close_button);
            self.hidePart(self.titlebar.maximize_button);
        }
        if (self.isBoderShown()) {
            self.drawPart(self.borders.top, .{
                .x = 0,
                .y = -BORDER_SIZE - offset,
                .width = box.width,
                .height = BORDER_SIZE,
            });
            self.drawPart(self.borders.bottom, .{
                .x = 0,
                .y = box.height,
                .width = box.width,
                .height = BORDER_SIZE,
            });
            self.drawPart(self.borders.left, .{
                .x = -BORDER_SIZE,
                .y = -offset - BORDER_SIZE,
                .width = BORDER_SIZE,
                .height = box.height + offset + BORDER_SIZE * 2,
            });
            self.drawPart(self.borders.right, .{
                .x = box.width,
                .y = -offset - BORDER_SIZE,
                .width = BORDER_SIZE,
                .height = box.height + offset + BORDER_SIZE * 2,
            });
        } else {
            self.hidePart(self.borders.top);
            self.hidePart(self.borders.bottom);
            self.hidePart(self.borders.left);
            self.hidePart(self.borders.right);
        }
    }

    fn drawPart(_: *ToplevelDecoration, part: *wlr.SceneRect, box: wlr.Box) void {
        part.node.setEnabled(true);
        part.node.setPosition(box.x, box.y);
        part.setSize(box.width, box.height);
    }

    fn hidePart(_: *ToplevelDecoration, part: *wlr.SceneRect) void {
        part.node.setEnabled(false);
    }

    fn onRequestMode(listener: *wl.Listener(*wlr.XdgToplevelDecorationV1), xdg_toplevel_decoration: *wlr.XdgToplevelDecorationV1) void {
        const self: *ToplevelDecoration = @fieldParentPtr("on_request_mode", listener);
        self.mode = switch (xdg_toplevel_decoration.requested_mode) {
            .client_side => .client_side,
            .server_side => .server_side,
            .none => .server_side,
        };
        const xdg_mode: wlr.XdgToplevelDecorationV1.Mode = switch (self.mode) {
            .client_side => .client_side,
            .server_side => .server_side,
        };
        _ = xdg_toplevel_decoration.setMode(xdg_mode);
    }
};
