const std = @import("std");

const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const xkb = @import("xkbcommon");

const Output = @import("output.zig").Output;
const Window = @import("layout.zig").Window;
const PocoWM = @import("main.zig").PocoWM;
const SublayoutKind = @import("layout.zig").SublayoutKind;
const Toplevel = @import("xdg_shell.zig").Toplevel;
const utils = @import("utils.zig");

const InputMgr = @This();

allocator: std.mem.Allocator,
pocowm: *PocoWM,
keyboards: std.ArrayList(*Keyboard),
cursor: Cursor,

on_new_input: wl.Listener(*wlr.InputDevice) = .init(onNewInput),

/// Depends on OutputMgr
pub fn init(self: *InputMgr, pocowm: *PocoWM, allocator: std.mem.Allocator) !void {
    self.* = .{
        .allocator = allocator,
        .pocowm = pocowm,
        .keyboards = std.ArrayList(*Keyboard).init(allocator),
        .cursor = undefined,
    };
    try self.cursor.init(pocowm);
    pocowm.backend.events.new_input.add(&self.on_new_input);
}

pub fn deinit(self: *InputMgr) void {
    self.on_new_input.link.remove();
    self.cursor.deinit();
}

pub fn getFocus(self: *InputMgr) ?*wlr.Surface {
    return self.pocowm.seat.keyboard_state.focused_surface;
}

fn onNewInput(listener: *wl.Listener(*wlr.InputDevice), device: *wlr.InputDevice) void {
    const self: *InputMgr = @fieldParentPtr("on_new_input", listener);
    switch (device.type) {
        .keyboard => _ = Keyboard.create(self.pocowm, device, self.allocator) catch |err| {
            std.log.err("failed to allocate new keyboard: {s}", .{@errorName(err)});
            return;
        },
        .pointer => self.cursor.wlr_cursor.attachInputDevice(device),
        else => {},
    }

    self.pocowm.seat.setCapabilities(.{
        .pointer = true,
        .keyboard = self.keyboards.items.len > 0,
    });
}

const Keyboard = struct {
    // TODO: remove this when factorizing keybinds
    allocator: std.mem.Allocator,
    pocowm: *PocoWM,
    device: *wlr.InputDevice,

    on_modifiers: wl.Listener(*wlr.Keyboard) = .init(onModifiers),
    on_key: wl.Listener(*wlr.Keyboard.event.Key) = .init(onKey),
    on_destroy: wl.Listener(*wlr.InputDevice) = .init(onDestroy),

    fn create(pocowm: *PocoWM, device: *wlr.InputDevice, allocator: std.mem.Allocator) !*Keyboard {
        const self = try allocator.create(Keyboard);
        self.* = .{
            .allocator = allocator,
            .pocowm = pocowm,
            .device = device,
        };

        const context = xkb.Context.new(.no_flags) orelse return error.ContextFailed;
        defer context.unref();
        const keymap = xkb.Keymap.newFromNames(context, null, .no_flags) orelse return error.KeymapFailed;
        defer keymap.unref();

        const wlr_keyboard = device.toKeyboard();
        if (!wlr_keyboard.setKeymap(keymap)) return error.SetKeymapFailed;
        wlr_keyboard.events.modifiers.add(&self.on_modifiers);
        wlr_keyboard.events.key.add(&self.on_key);
        device.events.destroy.add(&self.on_destroy);

        self.pocowm.seat.setKeyboard(wlr_keyboard);
        try pocowm.input_mgr.keyboards.append(self);
        return self;
    }

    fn destroy(self: *Keyboard) void {
        self.on_modifiers.link.remove();
        self.on_key.link.remove();
        self.on_destroy.link.remove();

        const index = utils.find_index(*Keyboard, self.pocowm.input_mgr.keyboards.items, self) orelse return;
        _ = self.pocowm.input_mgr.keyboards.swapRemove(index);
    }

    fn onModifiers(listener: *wl.Listener(*wlr.Keyboard), wlr_keyboard: *wlr.Keyboard) void {
        const self: *Keyboard = @fieldParentPtr("on_modifiers", listener);
        self.pocowm.seat.setKeyboard(wlr_keyboard);
        self.pocowm.seat.keyboardNotifyModifiers(&wlr_keyboard.modifiers);
    }

    fn onKey(listener: *wl.Listener(*wlr.Keyboard.event.Key), key: *wlr.Keyboard.event.Key) void {
        const self: *Keyboard = @fieldParentPtr("on_key", listener);
        const wlr_keyboard = self.device.toKeyboard();
        // libinput -> xkbcommon
        const is_handled = self.handleKeybind(key);

        if (!is_handled) {
            self.pocowm.seat.setKeyboard(wlr_keyboard);
            self.pocowm.seat.keyboardNotifyKey(key.time_msec, key.keycode, key.state);
        }
    }

    fn handleKeybind(self: *Keyboard, key: *wlr.Keyboard.event.Key) bool {
        const wlr_keyboard = self.device.toKeyboard();
        const keycode = key.keycode + 8;
        if (wlr_keyboard.getModifiers().alt and key.state == .pressed) {
            for (wlr_keyboard.xkb_state.?.keyGetSyms(keycode)) |sym| {
                switch (@intFromEnum(sym)) {
                    xkb.Keysym.Return => {
                        var child = std.process.Child.init(&.{"foot"}, self.allocator);
                        child.spawn() catch |err| {
                            std.log.err("failed to spawn foot: {s}", .{@errorName(err)});
                        };
                        return true;
                    },
                    xkb.Keysym.b => {
                        const output, const focused_window = self.pocowm.getOutputAndFocusedWindow();

                        _ = output.layout.addSublayout(focused_window, .vertical) catch |err| {
                            std.log.err("failed to add new sublayout: {s}", .{@errorName(err)});
                        };
                        return true;
                    },
                    xkb.Keysym.n => {
                        const output, const focused_window = self.pocowm.getOutputAndFocusedWindow();
                        _ = output.layout.addSublayout(focused_window, .horizontal) catch |err| {
                            std.log.err("failed to add new sublayout: {s}", .{@errorName(err)});
                        };
                        return true;
                    },
                    xkb.Keysym.e => {
                        const output, const focused_window = self.pocowm.getOutputAndFocusedWindow();
                        const new_kind = @as(SublayoutKind, if (focused_window) |w| switch (w.parent.kind) {
                            .horizontal => .vertical,
                            .vertical => .horizontal,
                        } else .horizontal);
                        const parent = if (focused_window) |w| w.parent else &output.layout.root;
                        parent.kind = new_kind;
                        return true;
                    },
                    xkb.Keysym.f => {
                        const output, const focused_window = self.pocowm.getOutputAndFocusedWindow();
                        if (focused_window) |w| {
                            w.toggleFloating();
                            output.layout.render();
                        }
                        return true;
                    },
                    else => {},
                }
            }
        }
        return false;
    }

    fn onDestroy(listener: *wl.Listener(*wlr.InputDevice), device: *wlr.InputDevice) void {
        _ = device;
        const self: *Keyboard = @fieldParentPtr("on_destroy", listener);
        self.destroy();
    }
};

const Cursor = struct {
    const Grab = struct {
        grab_x: f64,
        grab_y: f64,
        old_box: wlr.Box,
        resize_edges: wlr.Edges = std.mem.zeroes(wlr.Edges),
        toplevel: *Toplevel,
    };
    pocowm: *PocoWM,
    wlr_cursor: *wlr.Cursor,
    xcursor_mgr: *wlr.XcursorManager,

    mode: enum { normal, move, resize } = .normal,
    grab: Grab = undefined,

    on_pointer_motion: wl.Listener(*wlr.Pointer.event.Motion) = .init(onPointerMotion),
    on_pointer_motion_absolute: wl.Listener(*wlr.Pointer.event.MotionAbsolute) = .init(onPointerMotionAbsolute),
    on_pointer_button: wl.Listener(*wlr.Pointer.event.Button) = .init(onPointerButton),
    on_pointer_axis: wl.Listener(*wlr.Pointer.event.Axis) = .init(onPointerAxis),
    on_cursor_frame: wl.Listener(*wlr.Cursor) = .init(onCursorFrame),

    fn init(self: *Cursor, pocowm: *PocoWM) !void {
        self.* = .{
            .pocowm = pocowm,
            .wlr_cursor = try wlr.Cursor.create(),
            .xcursor_mgr = try wlr.XcursorManager.create(null, 24),
        };

        self.wlr_cursor.attachOutputLayout(pocowm.output_mgr.output_layout);
        try self.xcursor_mgr.load(1);

        self.wlr_cursor.events.motion.add(&self.on_pointer_motion);
        self.wlr_cursor.events.motion_absolute.add(&self.on_pointer_motion_absolute);
        self.wlr_cursor.events.button.add(&self.on_pointer_button);
        self.wlr_cursor.events.axis.add(&self.on_pointer_axis);
        self.wlr_cursor.events.frame.add(&self.on_cursor_frame);
    }

    fn deinit(self: *Cursor) void {
        self.on_pointer_motion.link.remove();
        self.on_pointer_motion_absolute.link.remove();
        self.on_pointer_button.link.remove();
        self.on_pointer_axis.link.remove();
        self.on_cursor_frame.link.remove();
    }

    fn handleMove(self: *Cursor, time_msec: u32) void {
        switch (self.mode) {
            .normal => {
                if (self.pocowm.viewAt(self.wlr_cursor.x, self.wlr_cursor.y)) |result| {
                    self.pocowm.seat.pointerNotifyEnter(result.inner_surface, result.sx, result.sy);
                    self.pocowm.seat.pointerNotifyMotion(time_msec, result.sx, result.sy);
                    switch (result.surface.parent) {
                        .xdg_toplevel => |toplevel| toplevel.focus(result.inner_surface),
                        else => {},
                    }
                } else {
                    self.wlr_cursor.setXcursor(self.xcursor_mgr, "default");
                    self.pocowm.seat.pointerClearFocus();
                }
            },
            .move => {
                _, const window = self.pocowm.output_mgr.getOutputAndWindow(self.grab.toplevel) orelse return;
                window.floating_box.x = self.grab.old_box.x + @as(c_int, @intFromFloat(self.wlr_cursor.x - self.grab.grab_x));
                window.floating_box.y = self.grab.old_box.y + @as(c_int, @intFromFloat(self.wlr_cursor.y - self.grab.grab_y));
                self.grab.toplevel.setGeometry(window.floating_box);
            },
            .resize => {
                _, const window = self.pocowm.output_mgr.getOutputAndWindow(self.grab.toplevel) orelse return;
                var delta_x: c_int = @intFromFloat(self.wlr_cursor.x - self.grab.grab_x);
                var delta_y: c_int = @intFromFloat(self.wlr_cursor.y - self.grab.grab_y);
                var new_box = self.grab.old_box;
                if (self.grab.resize_edges.left) {
                    new_box.x += delta_x;
                    delta_x = -delta_x;
                }
                if (self.grab.resize_edges.left or self.grab.resize_edges.right) {
                    new_box.width += delta_x;
                }
                if (self.grab.resize_edges.top) {
                    new_box.y += delta_y;
                    delta_y = -delta_y;
                }
                if (self.grab.resize_edges.top or self.grab.resize_edges.bottom) {
                    new_box.height += delta_y;
                }
                if (new_box.width <= 0) new_box.width = 1;
                if (new_box.height <= 0) new_box.height = 1;
                window.floating_box = new_box;
                self.grab.toplevel.setGeometry(window.floating_box);
            },
        }
    }

    fn onPointerMotion(listener: *wl.Listener(*wlr.Pointer.event.Motion), event: *wlr.Pointer.event.Motion) void {
        const self: *Cursor = @fieldParentPtr("on_pointer_motion", listener);
        self.wlr_cursor.move(event.device, event.delta_x, event.delta_y);
        self.handleMove(event.time_msec);
    }

    fn onPointerMotionAbsolute(listener: *wl.Listener(*wlr.Pointer.event.MotionAbsolute), event: *wlr.Pointer.event.MotionAbsolute) void {
        const self: *Cursor = @fieldParentPtr("on_pointer_motion_absolute", listener);
        self.wlr_cursor.warpAbsolute(event.device, event.x, event.y);
        self.handleMove(event.time_msec);
    }

    fn onPointerButton(listener: *wl.Listener(*wlr.Pointer.event.Button), event: *wlr.Pointer.event.Button) void {
        const self: *Cursor = @fieldParentPtr("on_pointer_button", listener);
        var passthrough = true;
        defer if (passthrough) {
            _ = self.pocowm.seat.pointerNotifyButton(event.time_msec, event.button, event.state);
        };
        if (event.state == .released) {
            self.mode = .normal;
            return;
        }
        const result = self.pocowm.viewAt(self.wlr_cursor.x, self.wlr_cursor.y) orelse return;
        const toplevel: *Toplevel = switch (result.surface.parent) {
            .xdg_toplevel => |toplevel_| toplevel_,
            else => return,
        };
        toplevel.focus(result.inner_surface);
        var is_alt_pressed = false;
        for (self.pocowm.input_mgr.keyboards.items) |keyboard| {
            const wl_keyboard = keyboard.device.toKeyboard();
            if (wl_keyboard.getModifiers().alt) {
                is_alt_pressed = true;
                break;
            }
        }
        if (is_alt_pressed) {
            switch (event.button) {
                // 0x110 = left mouse button
                0x110 => {
                    passthrough = false;
                    toplevel.startMove();
                },
                // 0x111 = right mouse button
                0x111 => {
                    passthrough = false;
                    const rx = @as(i32, @intFromFloat(self.wlr_cursor.x)) - toplevel.scene_tree.node.x;
                    const ry = @as(i32, @intFromFloat(self.wlr_cursor.y)) - toplevel.scene_tree.node.y;
                    toplevel.startResize(toplevel.getEdgeAt(rx, ry));
                },
                else => {},
            }
        }
    }

    fn onPointerAxis(listener: *wl.Listener(*wlr.Pointer.event.Axis), event: *wlr.Pointer.event.Axis) void {
        const self: *Cursor = @fieldParentPtr("on_pointer_axis", listener);
        _ = self.pocowm.seat.pointerNotifyAxis(
            event.time_msec,
            event.orientation,
            event.delta,
            event.delta_discrete,
            event.source,
            event.relative_direction,
        );
    }

    fn onCursorFrame(listener: *wl.Listener(*wlr.Cursor), event: *wlr.Cursor) void {
        _ = event;
        const self: *Cursor = @fieldParentPtr("on_cursor_frame", listener);
        _ = self.pocowm.seat.pointerNotifyFrame();
    }
};
