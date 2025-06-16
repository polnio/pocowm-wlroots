const std = @import("std");

const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");

const PocoWM = @import("main.zig").PocoWM;

const OutputMgr = @This();

allocator: std.mem.Allocator,
pocowm: *PocoWM,
output_layout: *wlr.OutputLayout,
scene_output_layout: *wlr.SceneOutputLayout,
outputs: std.ArrayList(*Output),

on_new_output: wl.Listener(*wlr.Output) = .init(onNewOutput),

pub fn init(self: *OutputMgr, pocowm: *PocoWM, allocator: std.mem.Allocator) !void {
    self.* = .{
        .allocator = allocator,
        .pocowm = pocowm,
        .output_layout = try wlr.OutputLayout.create(pocowm.wl_server),
        .scene_output_layout = try pocowm.scene.attachOutputLayout(self.output_layout),
        .outputs = std.ArrayList(*Output).init(allocator),
    };
    pocowm.backend.events.new_output.add(&self.on_new_output);
}

pub fn deinit(self: *OutputMgr) void {
    self.outputs.deinit();
}

fn onNewOutput(listener: *wl.Listener(*wlr.Output), wlr_output: *wlr.Output) void {
    const self: *OutputMgr = @fieldParentPtr("on_new_output", listener);

    if (!wlr_output.initRender(self.pocowm.wlr_allocator, self.pocowm.renderer)) return;

    var state = wlr.Output.State.init();
    defer state.finish();

    state.setEnabled(true);
    if (wlr_output.preferredMode()) |mode| {
        state.setMode(mode);
    }
    if (!wlr_output.commitState(&state)) return;

    _ = Output.create(self.pocowm, wlr_output, self.allocator) catch {
        std.log.err("failed to allocate new output", .{});
        wlr_output.destroy();
        return;
    };
}

const Output = struct {
    pocowm: *PocoWM,
    wlr_output: *wlr.Output,

    on_frame: wl.Listener(*wlr.Output) = .init(onFrame),
    on_request_state: wl.Listener(*wlr.Output.event.RequestState) = .init(onRequestState),
    on_destroy: wl.Listener(*wlr.Output) = .init(onDestroy),

    fn create(pocowm: *PocoWM, wlr_output: *wlr.Output, allocator: std.mem.Allocator) !*Output {
        var self = try allocator.create(Output);
        const output_mgr = &pocowm.output_mgr;
        self.* = .{
            .pocowm = pocowm,
            .wlr_output = wlr_output,
        };

        wlr_output.events.frame.add(&self.on_frame);
        wlr_output.events.request_state.add(&self.on_request_state);
        wlr_output.events.destroy.add(&self.on_destroy);

        const layout_output = try output_mgr.output_layout.addAuto(wlr_output);
        const scene_output = try self.pocowm.scene.createSceneOutput(wlr_output);
        output_mgr.scene_output_layout.addOutput(layout_output, scene_output);
        try output_mgr.outputs.append(self);
        return self;
    }

    fn destroy(self: *Output) void {
        const output_mgr = &self.pocowm.output_mgr;
        self.on_frame.link.remove();
        self.on_destroy.link.remove();

        const index = for (output_mgr.outputs.items, 0..) |output, i| {
            if (output == self) break i;
        } else unreachable;
        _ = output_mgr.outputs.swapRemove(index);
    }

    fn onFrame(listener: *wl.Listener(*wlr.Output), _: *wlr.Output) void {
        const self: *Output = @fieldParentPtr("on_frame", listener);

        const scene_output = self.pocowm.scene.getSceneOutput(self.wlr_output).?;
        _ = scene_output.commit(null);

        var now = std.posix.clock_gettime(std.posix.CLOCK.MONOTONIC) catch @panic("CLOCK_MONOTONIC not supported");
        scene_output.sendFrameDone(&now);
    }

    fn onRequestState(listener: *wl.Listener(*wlr.Output.event.RequestState), event: *wlr.Output.event.RequestState) void {
        const self: *Output = @fieldParentPtr("on_request_state", listener);

        _ = self.wlr_output.commitState(event.state);
    }

    fn onDestroy(listener: *wl.Listener(*wlr.Output), _: *wlr.Output) void {
        const self: *Output = @fieldParentPtr("on_destroy", listener);
        self.destroy();
    }
};
