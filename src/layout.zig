const std = @import("std");

const wlr = @import("wlroots");

const Output = @import("output.zig").Output;
const PocoWM = @import("main.zig").PocoWM;
const Toplevel = @import("xdg_shell.zig").Toplevel;
const utils = @import("utils.zig");

const GAP: i32 = 30;

const Layout = @This();
allocator: std.mem.Allocator,
pocowm: *PocoWM,
output: *Output,
root: Sublayout,
windows: std.AutoHashMap(*Toplevel, *Window),

pub fn init(self: *Layout, pocowm: *PocoWM, output: *Output, allocator: std.mem.Allocator) void {
    self.* = .{
        .allocator = allocator,
        .pocowm = pocowm,
        .output = output,
        .root = .{
            .layout = self,
            .allocator = allocator,
            .parent = null,
            .kind = .horizontal,
            .children = std.ArrayList(NodeChild).init(allocator),
        },
        .windows = std.AutoHashMap(*Toplevel, *Window).init(allocator),
    };
}

pub fn addWindow(self: *Layout, toplevel: *Toplevel, parent: *Sublayout) !*Window {
    const window = try self.allocator.create(Window);
    window.* = .{
        .toplevel = toplevel,
        .parent = parent,
        .state = .tiled,
        .old_state = .tiled,
        .floating_box = undefined,
    };
    toplevel.xdg_toplevel.base.getGeometry(&window.floating_box);

    try parent.children.append(NodeChild{ .window = window });
    try self.windows.put(toplevel, window);
    return window;
}

pub fn removeWindow(self: *Layout, window: *Window) void {
    const had_focus = window.toplevel.isFocused();
    const index = for (window.parent.children.items, 0..) |child, i| {
        switch (child) {
            .window => |w| if (w == window) break i,
            else => continue,
        }
    } else unreachable;
    _ = window.parent.children.orderedRemove(index);
    _ = self.windows.remove(window.toplevel);
    if (window.parent.children.items.len == 0) {
        self.removeSublayout(window.parent);
    }
    if (had_focus and window.parent.children.items.len > 0) {
        const new_index = if (index == 0) 0 else index - 1;
        if (window.parent.children.items[new_index].getWindow()) |new_window| {
            new_window.toplevel.focus(null);
        }
    }
}

fn removeSublayout(self: *Layout, sublayout: *Sublayout) void {
    const parent = sublayout.parent orelse return;
    const index = for (parent.children.items, 0..) |child, i| {
        switch (child) {
            .sublayout => |sl| if (sl == sublayout) break i,
            else => continue,
        }
    } else unreachable;
    _ = parent.children.orderedRemove(index);
    if (parent.children.items.len == 0) {
        self.removeSublayout(parent);
    }
}

pub fn getWindow(self: *Layout, toplevel: *Toplevel) ?*Window {
    return self.windows.get(toplevel);
}

pub fn addSublayout(self: *Layout, window: ?*Window, kind: SublayoutKind) !*Sublayout {
    if (window) |window_| {
        const sublayout = try Sublayout.create(self, window_.parent, kind, self.allocator);
        const index = for (window_.parent.children.items, 0..) |child, i| {
            switch (child) {
                .window => |w| if (w == window_) break i,
                else => continue,
            }
        } else unreachable;
        const node = window_.parent.children.items[index];
        window_.parent.children.items[index] = NodeChild{ .sublayout = sublayout };
        try sublayout.children.append(node);
        window_.parent = sublayout;
        return sublayout;
    } else if (self.root.children.items.len == 0) {
        self.root.kind = kind;
        return &self.root;
    } else {
        const sublayout = try Sublayout.create(self, &self.root, kind, self.allocator);
        try self.root.children.append(NodeChild{ .sublayout = sublayout });
        return sublayout;
    }
}

pub fn render(self: *Layout) void {
    const geometry = wlr.Box{
        .x = self.output.usable_area.x + GAP,
        .y = self.output.usable_area.y + GAP,
        .width = self.output.usable_area.width - (GAP * 2),
        .height = self.output.usable_area.height - (GAP * 2),
    };

    for (self.pocowm.layer_shell_mgr.surfaces.items) |layer_surface| {
        const state = &layer_surface.scene_layer_surface.layer_surface.current;
        if (state.exclusive_zone < 0) continue;
    }

    self.root.render(geometry);
}

const NodeChild = union(enum) {
    window: *Window,
    sublayout: *Sublayout,

    fn getWindow(self: *NodeChild) ?*Window {
        return switch (self.*) {
            .window => |window| window,
            // TODO: use last focused instead of first
            .sublayout => |sublayout| if (sublayout.children.items.len > 0) sublayout.children.items[0].getWindow() else null,
        };
    }

    fn destroy(self: *NodeChild) void {
        switch (self.*) {
            inline else => |node| node.destroy(),
        }
    }

    fn render(self: NodeChild, geometry: wlr.Box) void {
        switch (self) {
            inline else => |node| node.render(geometry),
        }
    }
};

const WindowState = enum { tiled, floating, maximized, fullscreen };

pub const Window = struct {
    toplevel: *Toplevel,
    parent: *Sublayout,
    state: WindowState,
    old_state: WindowState,
    floating_box: wlr.Box,

    pub fn render(self: *Window, geometry: wlr.Box) void {
        switch (self.state) {
            .tiled => self.toplevel.setGeometry(geometry),
            .floating => self.toplevel.setGeometry(self.floating_box),
            .maximized => self.toplevel.setGeometry(self.parent.layout.output.usable_area),
            .fullscreen => self.toplevel.setGeometry(self.parent.layout.output.fullArea()),
        }
        self.toplevel.render();
    }
    pub fn makeFloating(self: *Window) void {
        _ = self.toplevel.xdg_toplevel.setMaximized(false);
        _ = self.toplevel.xdg_toplevel.setFullscreen(false);
        if (self.state == .floating) return;
        const floating_views = self.parent.layout.pocowm.layer_shell_mgr.layers.floating_views;
        self.toplevel.scene_tree.node.reparent(floating_views.scene_tree);
        self.state = .floating;
    }
    pub fn makeTiled(self: *Window) void {
        _ = self.toplevel.xdg_toplevel.setMaximized(false);
        _ = self.toplevel.xdg_toplevel.setFullscreen(false);
        if (self.state == .tiled) return;
        const tiled_views = self.parent.layout.output.layers.tiled_views;
        self.toplevel.scene_tree.node.reparent(tiled_views.scene_tree);
        self.state = .tiled;
    }
    pub fn makeMaximized(self: *Window) void {
        _ = self.toplevel.xdg_toplevel.setFullscreen(false);
        _ = self.toplevel.xdg_toplevel.setMaximized(true);
        if (self.state == .maximized) return;
        const maximized_views = self.parent.layout.output.layers.maximized_views;
        self.toplevel.scene_tree.node.reparent(maximized_views.scene_tree);
        self.old_state = self.state;
        self.state = .maximized;
    }
    pub fn makeFullscreen(self: *Window) void {
        _ = self.toplevel.xdg_toplevel.setMaximized(false);
        _ = self.toplevel.xdg_toplevel.setFullscreen(true);
        if (self.state == .fullscreen) return;
        const fullscreen_views = self.parent.layout.output.layers.fullscreen_views;
        self.toplevel.scene_tree.node.reparent(fullscreen_views.scene_tree);
        self.old_state = self.state;
        self.state = .fullscreen;
    }
    pub fn restoreOldState(self: *Window) void {
        switch (self.old_state) {
            .tiled => self.makeTiled(),
            .floating => self.makeFloating(),
            .maximized => self.makeTiled(),
            .fullscreen => self.makeFullscreen(),
        }
    }
    pub fn toggleFloating(self: *Window) void {
        switch (self.state) {
            .tiled => self.makeFloating(),
            .floating => self.makeTiled(),
            .maximized => {},
            .fullscreen => {},
        }
    }
    pub fn toggleMaximized(self: *Window) void {
        switch (self.state) {
            .tiled => self.makeMaximized(),
            .floating => self.makeMaximized(),
            .maximized => self.restoreOldState(),
            .fullscreen => {},
        }
    }
    pub fn setMaximized(self: *Window, maximized: bool) void {
        if (maximized and self.state == .maximized) return;
        if (!maximized and self.state != .maximized) return;
        self.toggleMaximized();
    }
    pub fn toggleFullscreen(self: *Window) void {
        switch (self.state) {
            .tiled => self.makeFullscreen(),
            .floating => self.makeFullscreen(),
            .maximized => {},
            .fullscreen => self.restoreOldState(),
        }
    }
    pub fn setFullscreen(self: *Window, fullscreen: bool) void {
        if (fullscreen and self.state == .fullscreen) return;
        if (!fullscreen and self.state != .fullscreen) return;
        self.toggleFullscreen();
    }
};
pub const SublayoutKind = enum {
    horizontal,
    vertical,

    pub fn fromString(str: []const u8) ?SublayoutKind {
        inline for (std.meta.fields(SublayoutKind)) |field| {
            if (std.mem.eql(u8, field.name, str)) return @field(SublayoutKind, field.name);
        }
        return null;
    }
};
const Sublayout = struct {
    allocator: std.mem.Allocator,
    parent: ?*Sublayout,
    layout: *Layout,
    kind: SublayoutKind,
    children: std.ArrayList(NodeChild),

    fn create(layout: *Layout, parent: ?*Sublayout, kind: SublayoutKind, allocator: std.mem.Allocator) !*Sublayout {
        const self = try allocator.create(Sublayout);
        self.* = .{
            .allocator = allocator,
            .parent = parent,
            .layout = layout,
            .kind = kind,
            .children = std.ArrayList(NodeChild).init(allocator),
        };
        return self;
    }

    fn destroy(self: *Sublayout) void {
        for (self.children.items) |child| {
            child.destroy();
        }
        self.children.deinit();
        self.allocator.destroy(self);
    }

    fn render(self: *Sublayout, geometry: wlr.Box) void {
        var len: i32 = 0;
        for (self.children.items) |child| {
            switch (child) {
                .window => |window| if (window.state != .tiled) continue,
                else => {},
            }
            len += 1;
        }
        if (len == 0) {
            for (self.children.items) |child| {
                child.render(geometry);
            }
            return;
        }
        var i: i32 = 0;
        for (self.children.items) |child| {
            const subgeometry = switch (self.kind) {
                .horizontal => wlr.Box{
                    .x = geometry.x + @divTrunc((geometry.width + GAP) * i, len),
                    .y = geometry.y,
                    .width = @divTrunc(geometry.width + GAP, len) - GAP,
                    .height = geometry.height,
                },
                .vertical => wlr.Box{
                    .x = geometry.x,
                    .y = geometry.y + @divTrunc((geometry.height + GAP) * i, len),
                    .width = geometry.width,
                    .height = @divTrunc(geometry.height + GAP, len) - GAP,
                },
            };
            switch (child) {
                .window => |window| if (window.state == .tiled) {
                    i += 1;
                },
                else => {
                    i += 1;
                },
            }
            child.render(subgeometry);
        }
    }
};
