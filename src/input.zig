const std = @import("std");

const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const xkb = @import("xkbcommon");

const PocoWM = @import("main.zig").PocoWM;
const Toplevel = @import("xdg_shell.zig").Toplevel;
const SublayoutKind = @import("layout.zig").SublayoutKind;
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
                        var child = std.process.Child.init(&.{"kitty"}, self.allocator);
                        child.spawn() catch |err| {
                            std.log.err("failed to spawn kitty: {s}", .{@errorName(err)});
                        };
                        return true;
                    },
                    xkb.Keysym.b => {
                        const focused = self.pocowm.xdg_shell_mgr.getFocus();
                        const focused_window = if (focused) |f| self.pocowm.layout.getWindow(f) else null;
                        _ = self.pocowm.layout.addSublayout(focused_window, .vertical) catch |err| {
                            std.log.err("failed to add new sublayout: {s}", .{@errorName(err)});
                        };
                        return true;
                    },
                    xkb.Keysym.n => {
                        const focused = self.pocowm.xdg_shell_mgr.getFocus();
                        const focused_window = if (focused) |f| self.pocowm.layout.getWindow(f) else null;
                        _ = self.pocowm.layout.addSublayout(focused_window, .horizontal) catch |err| {
                            std.log.err("failed to add new sublayout: {s}", .{@errorName(err)});
                        };
                        return true;
                    },
                    xkb.Keysym.e => {
                        const focused = self.pocowm.xdg_shell_mgr.getFocus();
                        const focused_window = if (focused) |f| self.pocowm.layout.getWindow(f) else null;
                        const new_kind = @as(SublayoutKind, if (focused_window) |w| switch (w.parent.kind) {
                            .horizontal => .vertical,
                            .vertical => .horizontal,
                        } else .horizontal);
                        const parent = if (focused_window) |w| w.parent else &self.pocowm.layout.root;
                        parent.kind = new_kind;
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
    pocowm: *PocoWM,
    wlr_cursor: *wlr.Cursor,
    xcursor_mgr: *wlr.XcursorManager,

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

    fn handleMove(self: *Cursor, time_msec: u32) void {
        if (self.pocowm.viewAt(self.wlr_cursor.x, self.wlr_cursor.y)) |result| {
            self.pocowm.seat.pointerNotifyEnter(result.surface.wlr_surface(), result.sx, result.sy);
            self.pocowm.seat.pointerNotifyMotion(time_msec, result.sx, result.sy);
            switch (result.surface.parent) {
                .xdg => |xdg| xdg.focus(result.inner_surface),
                else => {},
            }
        } else {
            self.wlr_cursor.setXcursor(self.xcursor_mgr, "default");
            self.pocowm.seat.pointerClearFocus();
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
        _ = self.pocowm.seat.pointerNotifyButton(event.time_msec, event.button, event.state);
        if (self.pocowm.viewAt(self.wlr_cursor.x, self.wlr_cursor.y)) |result| {
            switch (result.surface.parent) {
                .xdg => |xdg| xdg.focus(result.inner_surface),
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
