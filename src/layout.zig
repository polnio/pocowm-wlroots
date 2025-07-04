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
root: Sublayout,
windows: std.AutoHashMap(*Toplevel, *Window),

pub fn init(self: *Layout, pocowm: *PocoWM, allocator: std.mem.Allocator) void {
    self.* = .{
        .allocator = allocator,
        .pocowm = pocowm,
        .root = .{
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
    };

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
        const sublayout = try Sublayout.create(window_.parent, kind, self.allocator);
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
        const sublayout = try Sublayout.create(&self.root, kind, self.allocator);
        try self.root.children.append(NodeChild{ .sublayout = sublayout });
        return sublayout;
    }
}

pub fn render(self: *Layout, output: *Output) void {
    const geometry = utils.Geometry(i32){
        .x = output.usable_area.x + GAP,
        .y = output.usable_area.y + GAP,
        .width = output.usable_area.width - (GAP * 2),
        .height = output.usable_area.height - (GAP * 2),
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

    fn render(self: NodeChild, geometry: utils.Geometry(i32)) void {
        switch (self) {
            inline else => |node| node.render(geometry),
        }
    }
};

const Window = struct {
    toplevel: *Toplevel,
    parent: *Sublayout,

    fn render(self: *Window, geometry: utils.Geometry(i32)) void {
        self.toplevel.setGeometry(geometry);
    }
};
pub const SublayoutKind = enum {
    horizontal,
    vertical,
};
const Sublayout = struct {
    allocator: std.mem.Allocator,
    parent: ?*Sublayout,
    kind: SublayoutKind,
    children: std.ArrayList(NodeChild),

    fn create(parent: ?*Sublayout, kind: SublayoutKind, allocator: std.mem.Allocator) !*Sublayout {
        const self = try allocator.create(Sublayout);
        self.* = .{
            .allocator = allocator,
            .parent = parent,
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

    fn render(self: *Sublayout, geometry: utils.Geometry(i32)) void {
        const len = self.children.items.len;
        for (self.children.items, 0..) |child, i| {
            const ii: i32 = @intCast(i);
            const ilen: i32 = @intCast(len);
            const subgeometry = switch (self.kind) {
                .horizontal => utils.Geometry(i32){
                    .x = geometry.x + @divTrunc((geometry.width + GAP) * ii, ilen),
                    .y = geometry.y,
                    .width = @divTrunc(geometry.width + GAP, ilen) - GAP,
                    .height = geometry.height,
                },
                .vertical => utils.Geometry(i32){
                    .x = geometry.x,
                    .y = geometry.y + @divTrunc((geometry.height + GAP) * ii, ilen),
                    .width = geometry.width,
                    .height = @divTrunc(geometry.height + GAP, ilen) - GAP,
                },
            };
            child.render(subgeometry);
        }
    }
};
