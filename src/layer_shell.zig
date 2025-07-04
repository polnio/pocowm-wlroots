// https://github.com/labwc/labwc

const std = @import("std");

const wayland = @import("wayland");
const wl = wayland.server.wl;
const wlr = @import("wlroots");
const zwlr = wayland.server.zwlr;

const PocoWM = @import("main.zig").PocoWM;
const BaseSurface = @import("main.zig").BaseSurface;
const Output = @import("output.zig").Output;
const utils = @import("utils.zig");

const LayerShellMgr = @This();

allocator: std.mem.Allocator,
pocowm: *PocoWM,
layer_shell: *wlr.LayerShellV1,
surfaces: std.ArrayList(*LayerSurface),

on_new_surface: wl.Listener(*wlr.LayerSurfaceV1) = .init(onNewSurface),
on_destroy: wl.Listener(*wlr.LayerShellV1) = .init(onDestroy),

pub fn init(self: *LayerShellMgr, pocowm: *PocoWM, allocator: std.mem.Allocator) !void {
    self.* = .{
        .allocator = allocator,
        .pocowm = pocowm,
        .layer_shell = try wlr.LayerShellV1.create(pocowm.wl_server, 4),
        .surfaces = std.ArrayList(*LayerSurface).init(allocator),
    };
    self.layer_shell.events.new_surface.add(&self.on_new_surface);
    self.layer_shell.events.destroy.add(&self.on_destroy);
}

pub fn deinit(self: *LayerShellMgr) void {
    self.surfaces.deinit();
}

fn updateLayer(
    self: *LayerShellMgr,
    output: *Output,
    full_area: *const wlr.Box,
    usable_area: *wlr.Box,
    layer: *Layer,
    exclusive: bool,
) void {
    _ = layer;
    // var it = layer.scene_tree.children.iterator(.forward);
    // while (it.next()) |node| {
    //     node.data
    //     // const surface = node.addons.find(owner: ?*const anyopaque, impl: *const Addon.Interface)
    // }
    for (self.surfaces.items) |surface| {
        if (!surface.scene_layer_surface.layer_surface.initialized) continue;
        const o = surface.scene_layer_surface.layer_surface.output orelse continue;
        if (o != output.wlr_output) continue;
        if ((surface.scene_layer_surface.layer_surface.current.exclusive_zone > 0) != exclusive) continue;
        surface.scene_layer_surface.configure(full_area, usable_area);
    }
}

pub fn update(self: *LayerShellMgr, output: *Output) void {
    const full_area = output.fullArea();
    var usable_area = full_area;
    self.updateLayer(output, &full_area, &usable_area, output.layers.background, true);
    self.updateLayer(output, &full_area, &usable_area, output.layers.background, false);
    if (!std.meta.eql(output.usable_area, usable_area)) {
        output.usable_area = usable_area;
    }
    self.pocowm.layout.render(output);
}

fn onNewSurface(listener: *wl.Listener(*wlr.LayerSurfaceV1), surface: *wlr.LayerSurfaceV1) void {
    const self: *LayerShellMgr = @fieldParentPtr("on_new_surface", listener);
    _ = LayerSurface.create(self.pocowm, surface, self.allocator) catch |err| {
        std.log.err("failed to create new layer surface: {s}", .{@errorName(err)});
    };
}

fn onDestroy(listener: *wl.Listener(*wlr.LayerShellV1), _: *wlr.LayerShellV1) void {
    const self: *LayerShellMgr = @fieldParentPtr("on_destroy", listener);
    self.deinit();
}

pub const LayerSurface = struct {
    base: BaseSurface,
    allocator: std.mem.Allocator,
    pocowm: *PocoWM,
    scene_layer_surface: *wlr.SceneLayerSurfaceV1,
    output: *Output,

    on_surface_destroy: wl.Listener(*wlr.Surface) = .init(onSurfaceDestroy),

    fn create(pocowm: *PocoWM, layer_surface: *wlr.LayerSurfaceV1, allocator: std.mem.Allocator) !*LayerSurface {
        const self = try allocator.create(LayerSurface);
        const wlr_output = layer_surface.output orelse return error.OutputNotFound;
        const output = pocowm.output_mgr.getOutput(wlr_output) orelse return error.OutputNotFound;
        const layer = output.layers.getLayer(layer_surface.current.layer) orelse return error.LayerNotFound;
        const scene_layer_surface = try layer.scene_tree.createSceneLayerSurfaceV1(layer_surface);
        self.* = .{
            .base = .{ .parent = .{ .layer = self } },
            .allocator = allocator,
            .pocowm = pocowm,
            .scene_layer_surface = scene_layer_surface,
            .output = output,
        };
        scene_layer_surface.tree.node.data = @intFromPtr(&self.base);
        // layer_surface.data = @intFromPtr(self.scene_layer_surface);
        layer_surface.surface.events.destroy.add(&self.on_surface_destroy);
        try pocowm.layer_shell_mgr.surfaces.append(self);
        return self;
    }

    fn destroy(self: *LayerSurface) void {
        self.on_surface_commit.link.remove();
        self.on_surface_destroy.link.remove();
        self.on_surface_map.link.remove();
        self.on_surface_unmap.link.remove();
        self.on_destroy.link.remove();

        const index = utils.find_index(*LayerSurface, self.pocowm.layer_shell_mgr.surfaces.items, self) orelse return;
        _ = self.pocowm.layer_shell_mgr.surfaces.swapRemove(index);
        self.allocator.destroy(self);
    }

    fn onSurfaceDestroy(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
        const self: *LayerSurface = @fieldParentPtr("on_surface_destroy", listener);
        self.destroy();
    }
};

pub const Layer = struct {
    scene_tree: *wlr.SceneTree,
    layer_surface: *LayerSurface,
    layer_type: zwlr.LayerShellV1.Layer,

    fn create(parent: *wlr.SceneTree, layer_type: zwlr.LayerShellV1.Layer, allocator: std.mem.Allocator) !*Layer {
        const self = try allocator.create(Layer);
        const scene_tree = try wlr.SceneTree.createSceneTree(parent);
        self.* = .{
            .scene_tree = scene_tree,
            .layer_surface = undefined,
            .layer_type = layer_type,
        };
        scene_tree.node.data = @intFromPtr(self);
        return self;
    }
};

pub const Layers = struct {
    background: *Layer,
    bottom: *Layer,
    top: *Layer,
    overlay: *Layer,

    pub fn init(pocowm: *PocoWM, allocator: std.mem.Allocator) !Layers {
        return Layers{
            .background = try Layer.create(&pocowm.scene.tree, .background, allocator),
            .bottom = try Layer.create(&pocowm.scene.tree, .bottom, allocator),
            .top = try Layer.create(&pocowm.scene.tree, .top, allocator),
            .overlay = try Layer.create(&pocowm.scene.tree, .overlay, allocator),
        };
    }

    pub fn getLayer(self: *Layers, layer_type: zwlr.LayerShellV1.Layer) ?*Layer {
        switch (layer_type) {
            .background => return self.background,
            .bottom => return self.bottom,
            .overlay => return self.overlay,
            .top => return self.top,
            _ => return null,
        }
    }
};
