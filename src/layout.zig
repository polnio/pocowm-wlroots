const std = @import("std");

const wlr = @import("wlroots");

const Toplevel = @import("xdg_shell.zig").Toplevel;
const utils = @import("utils.zig");

const Layout = @This();
allocator: std.mem.Allocator,
root: Sublayout,
windows: std.AutoHashMap(*Toplevel, *Window),

pub fn init(self: *Layout, allocator: std.mem.Allocator) void {
    self.* = .{
        .allocator = allocator,
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

pub fn render(self: *Layout, scene_output: *wlr.SceneOutput) void {
    const geometry = utils.Geometry(i32){
        .x = scene_output.x,
        .y = scene_output.y,
        .width = scene_output.output.width,
        .height = scene_output.output.height,
    };
    self.root.render(scene_output, geometry);
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
            .window => |window| window.destroy(),
            .sublayout => |sublayout| sublayout.destroy(),
        }
    }

    fn render(self: NodeChild, scene_output: *wlr.SceneOutput, geometry: utils.Geometry(i32)) void {
        switch (self) {
            .window => |window| window.render(scene_output, geometry),
            .sublayout => |sublayout| sublayout.render(scene_output, geometry),
        }
    }
};

const Window = struct {
    toplevel: *Toplevel,
    parent: *Sublayout,

    fn render(self: *Window, scene_output: *wlr.SceneOutput, geometry: utils.Geometry(i32)) void {
        _ = scene_output;
        self.toplevel.scene_tree.node.setPosition(geometry.x, geometry.y);
        _ = self.toplevel.xdg_toplevel.setSize(geometry.width, geometry.height);
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

    fn render(self: *Sublayout, scene_output: *wlr.SceneOutput, geometry: utils.Geometry(i32)) void {
        const len = self.children.items.len;
        for (self.children.items, 0..) |child, i| {
            const ii: i32 = @intCast(i);
            const ilen: i32 = @intCast(len);
            const subgeometry = switch (self.kind) {
                .horizontal => utils.Geometry(i32){
                    .x = geometry.x + @divTrunc(geometry.width * ii, ilen),
                    .y = geometry.y,
                    .width = @divTrunc(geometry.width, ilen),
                    .height = geometry.height,
                },
                .vertical => utils.Geometry(i32){
                    .x = geometry.x,
                    .y = geometry.y + @divTrunc(geometry.height * ii, ilen),
                    .width = geometry.width,
                    .height = @divTrunc(geometry.height, ilen),
                },
            };
            child.render(scene_output, subgeometry);
        }
    }
};
