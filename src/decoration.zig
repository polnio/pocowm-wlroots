const std = @import("std");

const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");

const Config = @import("config.zig");
const PocoWM = @import("main.zig").PocoWM;
const Toplevel = @import("xdg_shell.zig").Toplevel;
const utils = @import("utils.zig");

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
        const decoration = &Config.instance.decoration;
        self.* = .{
            .allocator = allocator,
            .pocowm = pocowm,
            .toplevel = toplevel,

            .titlebar = .{
                .all = try toplevel.scene_tree.createSceneRect(0, 0, &decoration.titlebar_color),
                .close_button = try toplevel.scene_tree.createSceneRect(0, 0, &decoration.close_button_color),
                .maximize_button = try toplevel.scene_tree.createSceneRect(0, 0, &decoration.maximize_button_color),
            },
            .borders = .{
                .top = try toplevel.scene_tree.createSceneRect(0, 0, &decoration.border_color),
                .bottom = try toplevel.scene_tree.createSceneRect(0, 0, &decoration.border_color),
                .left = try toplevel.scene_tree.createSceneRect(0, 0, &decoration.border_color),
                .right = try toplevel.scene_tree.createSceneRect(0, 0, &decoration.border_color),
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
        const decoration = &Config.instance.decoration;
        const button_gap = decoration.buttonGap();
        const geometry = self.toplevel.getSurfaceGeometry();
        const is_titlebar_shown = self.isTitlebarShown();
        const offset: i32 = if (is_titlebar_shown) decoration.titlebar_height else 0;
        if (rx < -decoration.border_size or rx > geometry.width + decoration.border_size) return;
        if (ry < -decoration.border_size - offset or ry > geometry.height + decoration.border_size) return;

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
        if (ry > -button_gap) {
            self.toplevel.startMove();
            return;
        }
        if (ry > -button_gap - decoration.button_size) {
            if (rx < button_gap) {
                self.toplevel.startMove();
                return;
            }
            if (rx < button_gap + decoration.button_size) {
                self.toplevel.xdg_toplevel.sendClose();
                return;
            }
            if (rx < button_gap * 2 + decoration.button_size) {
                self.toplevel.startMove();
                return;
            }
            if (rx < button_gap * 2 + decoration.button_size * 2) {
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
        const decoration = &Config.instance.decoration;
        var offset: i32 = 0;
        if (self.isTitlebarShown()) {
            const button_gap = decoration.buttonGap();
            offset = decoration.titlebar_height;
            self.drawPart(self.titlebar.all, .{
                .x = 0,
                .y = -decoration.titlebar_height,
                .width = box.width,
                .height = decoration.titlebar_height,
            });
            self.drawPart(self.titlebar.close_button, .{
                .x = button_gap,
                .y = -button_gap - decoration.button_size,
                .width = decoration.button_size,
                .height = decoration.button_size,
            });
            self.drawPart(self.titlebar.maximize_button, .{
                .x = button_gap * 2 + decoration.button_size,
                .y = -button_gap - decoration.button_size,
                .width = decoration.button_size,
                .height = decoration.button_size,
            });
        } else {
            self.hidePart(self.titlebar.all);
            self.hidePart(self.titlebar.close_button);
            self.hidePart(self.titlebar.maximize_button);
        }
        if (self.isBoderShown()) {
            self.drawPart(self.borders.top, .{
                .x = 0,
                .y = -decoration.border_size - offset,
                .width = box.width,
                .height = decoration.border_size,
            });
            self.drawPart(self.borders.bottom, .{
                .x = 0,
                .y = box.height,
                .width = box.width,
                .height = decoration.border_size,
            });
            self.drawPart(self.borders.left, .{
                .x = -decoration.border_size,
                .y = -offset - decoration.border_size,
                .width = decoration.border_size,
                .height = box.height + offset + decoration.border_size * 2,
            });
            self.drawPart(self.borders.right, .{
                .x = box.width,
                .y = -offset - decoration.border_size,
                .width = decoration.border_size,
                .height = box.height + offset + decoration.border_size * 2,
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
