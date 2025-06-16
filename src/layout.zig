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
            .parent = null,
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
        if (child.window == window) break i;
    } else return;
    _ = window.parent.children.orderedRemove(index);
    _ = self.windows.remove(window.toplevel);
    if (had_focus and window.parent.children.items.len > 0) {
        const new_index = if (index == 0) 0 else index - 1;
        const new_window = window.parent.children.items[new_index].window;
        new_window.toplevel.focus(new_window.toplevel.xdg_toplevel.base.surface);
    }
}

pub fn getWindow(self: *Layout, toplevel: *Toplevel) ?*Window {
    return self.windows.get(toplevel);
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
const Sublayout = struct {
    parent: ?*Sublayout,
    children: std.ArrayList(NodeChild),

    fn render(self: *Sublayout, scene_output: *wlr.SceneOutput, geometry: utils.Geometry(i32)) void {
        const len = self.children.items.len;
        for (self.children.items, 0..) |child, i| {
            const ii: i32 = @intCast(i);
            const ilen: i32 = @intCast(len);
            const subgeometry = utils.Geometry(i32){
                .x = geometry.x + @divTrunc(geometry.width * ii, ilen),
                .y = geometry.y,
                .width = @divTrunc(geometry.width, ilen),
                .height = geometry.height,
            };
            switch (child) {
                .window => |window| window.render(scene_output, subgeometry),
                .sublayout => |sublayout| sublayout.render(scene_output, subgeometry),
            }
        }
    }
};
