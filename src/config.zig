const std = @import("std");
const xkb = @import("xkbcommon");
const wlr = @import("wlroots");

const utils = @import("utils.zig");
const Args = @import("args.zig");
const Layout = @import("layout.zig");

const c = @cImport({
    @cInclude("kdl/kdl.h");
});

const Config = @This();

pub var instance: Config = undefined;

const MAX_MOD_LEN = 5;

const Bind = struct {
    keys: std.ArrayList(u32),
    modifiers: wlr.Keyboard.ModifierMask,
    action: Lambda,
};

const Decoration = struct {
    outline_size: i32,
    outline_color: [4]f32,
    border_size: i32,
    border_color: [4]f32,
    titlebar_height: i32,
    titlebar_color: [4]f32,
    button_size: i32,
    close_button_color: [4]f32,
    maximize_button_color: [4]f32,

    pub fn buttonGap(self: Decoration) i32 {
        return @divTrunc(self.titlebar_height - self.button_size, 2);
    }
};

const CLayout = struct {
    gap: i32,
};

binds: std.ArrayList(Bind),
decoration: Decoration,
layout: CLayout,

pub fn try_load(path: []const u8, allocator: std.mem.Allocator) !Config {
    var self = Config{
        .binds = std.ArrayList(Bind).init(allocator),
        .decoration = std.mem.zeroes(Decoration),
        .layout = std.mem.zeroes(CLayout),
    };
    var file = try std.fs.cwd().openFile(path, .{});
    const parser = c.kdl_create_stream_parser(read_chunk, @as(?*anyopaque, &file), c.KDL_DEFAULTS) orelse return error.CreateParserError;
    defer c.kdl_destroy_parser(parser);
    while (true) {
        const event_data = c.kdl_parser_next_event(parser);
        switch (event_data.*.event) {
            c.KDL_EVENT_EOF => break,
            c.KDL_EVENT_START_NODE => {
                const name = kdl_str_to_slice(event_data.*.name);
                if (std.mem.eql(u8, name, "binds")) {
                    while (true) {
                        const bind_ed = c.kdl_parser_next_event(parser);
                        if (bind_ed.*.event == c.KDL_EVENT_END_NODE) break;
                        const bind = try parse_bind(parser, bind_ed, allocator);
                        self.binds.append(bind) catch unreachable;
                    }
                } else if (std.mem.eql(u8, name, "decoration")) {
                    while (true) {
                        const decor_ed = c.kdl_parser_next_event(parser);
                        switch (decor_ed.*.event) {
                            c.KDL_EVENT_END_NODE => break,
                            c.KDL_EVENT_START_NODE => {
                                const decor_name = kdl_str_to_slice(decor_ed.*.name);
                                const value_ed = c.kdl_parser_next_event(parser);
                                if (value_ed.*.event != c.KDL_EVENT_ARGUMENT) return error.ParseError;
                                if (std.mem.eql(u8, decor_name, "outline-size")) {
                                    if (!kdl_expect_type(value_ed.*.value.type, c.KDL_TYPE_NUMBER, "outline-size")) return error.ParseError;
                                    const value = Value.fromKdl(value_ed.*.value, .integer, allocator) orelse return error.ParseError;
                                    self.decoration.outline_size = value.integer;
                                    const end_evt = c.kdl_parser_next_event(parser);
                                    if (!kdl_expect_end_node(end_evt.*.event, 1, "outline-size")) return error.ParseError;
                                } else if (std.mem.eql(u8, decor_name, "outline-color")) {
                                    if (!kdl_expect_type(value_ed.*.value.type, c.KDL_TYPE_STRING, "outline-color")) return error.ParseError;
                                    const value = Value.fromKdl(value_ed.*.value, .color, allocator) orelse return error.ParseError;
                                    self.decoration.outline_color = value.color;
                                    const end_evt = c.kdl_parser_next_event(parser);
                                    if (!kdl_expect_end_node(end_evt.*.event, 1, "outline-color")) return error.ParseError;
                                } else if (std.mem.eql(u8, decor_name, "border-size")) {
                                    if (!kdl_expect_type(value_ed.*.value.type, c.KDL_TYPE_NUMBER, "border-size")) return error.ParseError;
                                    const value = Value.fromKdl(value_ed.*.value, .integer, allocator) orelse return error.ParseError;
                                    self.decoration.border_size = value.integer;
                                    const end_evt = c.kdl_parser_next_event(parser);
                                    if (!kdl_expect_end_node(end_evt.*.event, 1, "border-size")) return error.ParseError;
                                } else if (std.mem.eql(u8, decor_name, "border-color")) {
                                    if (!kdl_expect_type(value_ed.*.value.type, c.KDL_TYPE_STRING, "border-color")) return error.ParseError;
                                    const value = Value.fromKdl(value_ed.*.value, .color, allocator) orelse return error.ParseError;
                                    self.decoration.border_color = value.color;
                                    const end_evt = c.kdl_parser_next_event(parser);
                                    if (!kdl_expect_end_node(end_evt.*.event, 1, "border-color")) return error.ParseError;
                                } else if (std.mem.eql(u8, decor_name, "titlebar-height")) {
                                    if (!kdl_expect_type(value_ed.*.value.type, c.KDL_TYPE_NUMBER, "titlebar-height")) return error.ParseError;
                                    const value = Value.fromKdl(value_ed.*.value, .integer, allocator) orelse return error.ParseError;
                                    self.decoration.titlebar_height = value.integer;
                                    const end_evt = c.kdl_parser_next_event(parser);
                                    if (!kdl_expect_end_node(end_evt.*.event, 1, "titlebar-height")) return error.ParseError;
                                } else if (std.mem.eql(u8, decor_name, "titlebar-color")) {
                                    if (!kdl_expect_type(value_ed.*.value.type, c.KDL_TYPE_STRING, "titlebar-color")) return error.ParseError;
                                    const value = Value.fromKdl(value_ed.*.value, .color, allocator) orelse return error.ParseError;
                                    self.decoration.titlebar_color = value.color;
                                    const end_evt = c.kdl_parser_next_event(parser);
                                    if (!kdl_expect_end_node(end_evt.*.event, 1, "titlebar-color")) return error.ParseError;
                                } else if (std.mem.eql(u8, decor_name, "button-size")) {
                                    if (!kdl_expect_type(value_ed.*.value.type, c.KDL_TYPE_NUMBER, "button-size")) return error.ParseError;
                                    const value = Value.fromKdl(value_ed.*.value, .integer, allocator) orelse return error.ParseError;
                                    self.decoration.button_size = value.integer;
                                    const end_evt = c.kdl_parser_next_event(parser);
                                    if (!kdl_expect_end_node(end_evt.*.event, 1, "button-size")) return error.ParseError;
                                } else if (std.mem.eql(u8, decor_name, "close-button-color")) {
                                    if (!kdl_expect_type(value_ed.*.value.type, c.KDL_TYPE_STRING, "close-button-color")) return error.ParseError;
                                    const value = Value.fromKdl(value_ed.*.value, .color, allocator) orelse return error.ParseError;
                                    self.decoration.close_button_color = value.color;
                                    const end_evt = c.kdl_parser_next_event(parser);
                                    if (!kdl_expect_end_node(end_evt.*.event, 1, "close-button-color")) return error.ParseError;
                                } else if (std.mem.eql(u8, decor_name, "maximize-button-color")) {
                                    if (!kdl_expect_type(value_ed.*.value.type, c.KDL_TYPE_STRING, "maximize-button-color")) return error.ParseError;
                                    const value = Value.fromKdl(value_ed.*.value, .color, allocator) orelse return error.ParseError;
                                    self.decoration.maximize_button_color = value.color;
                                    const end_evt = c.kdl_parser_next_event(parser);
                                    if (!kdl_expect_end_node(end_evt.*.event, 1, "maximize-button-color")) return error.ParseError;
                                } else {
                                    std.log.err("unknown option: {s}", .{decor_name});
                                    return error.ParseError;
                                }
                            },
                            else => {},
                        }
                    }
                } else if (std.mem.eql(u8, name, "layout")) {
                    while (true) {
                        const decor_ed = c.kdl_parser_next_event(parser);
                        switch (decor_ed.*.event) {
                            c.KDL_EVENT_END_NODE => break,
                            c.KDL_EVENT_START_NODE => {
                                const decor_name = kdl_str_to_slice(decor_ed.*.name);
                                const value_ed = c.kdl_parser_next_event(parser);
                                if (value_ed.*.event != c.KDL_EVENT_ARGUMENT) return error.ParseError;
                                if (std.mem.eql(u8, decor_name, "gap")) {
                                    if (!kdl_expect_type(value_ed.*.value.type, c.KDL_TYPE_NUMBER, "gap")) return error.ParseError;
                                    const value = Value.fromKdl(value_ed.*.value, .integer, allocator) orelse return error.ParseError;
                                    self.layout.gap = value.integer;
                                    const end_evt = c.kdl_parser_next_event(parser);
                                    if (!kdl_expect_end_node(end_evt.*.event, 1, "gap")) return error.ParseError;
                                } else {
                                    std.log.err("unknown option: {s}", .{decor_name});
                                    return error.ParseError;
                                }
                            },
                            else => {},
                        }
                    }
                } else {
                    std.log.err("unknown option: {s}", .{name});
                    return error.ParseError;
                }
            },
            else => {
                std.log.err("Unexpected event: {s}", .{kdl_event_to_str(event_data.*.event)});
                return error.ParseEvent;
            },
        }
    }
    return self;
}

pub fn load(path: []const u8, allocator: std.mem.Allocator) Config {
    return try_load(path, allocator) catch |err| {
        if (err == error.ParseError) {
            std.log.err("Failed to parse config", .{});
        } else {
            std.log.err("Failed to load config: {s}", .{@errorName(err)});
        }
        std.process.exit(1);
    };
}

pub fn init(allocator: std.mem.Allocator) void {
    instance = load(Args.instance.config, allocator);
}

// -----------------------------------------------------------------------------

fn parse_bind(parser: *c.struct__kdl_parser, evt: *c.kdl_event_data, allocator: std.mem.Allocator) !Bind {
    if (!kdl_expect_start_node(evt.event)) return error.ParseError;
    var bind = Bind{
        .keys = .init(allocator),
        .modifiers = std.mem.zeroes(wlr.Keyboard.ModifierMask),
        .action = Lambda{
            .body = .init(allocator),
        },
    };
    const seq = kdl_str_to_slice(evt.name);
    var seq_it = std.mem.tokenizeScalar(u8, seq, '+');
    while (seq_it.next()) |key| {
        const keyz = allocator.dupeZ(u8, key) catch unreachable;
        const keysym = xkb.Keysym.fromName(keyz.ptr, .case_insensitive);

        if (keysym != .NoSymbol) {
            bind.keys.append(keysym.toUTF32()) catch unreachable;
            continue;
        }

        var lowkey = allocator.alloc(u8, key.len) catch unreachable;
        for (key, 0..) |l, i| {
            lowkey[i] = std.ascii.toLower(l);
        }

        if (std.mem.eql(u8, lowkey, "mod1") or std.mem.eql(u8, lowkey, "alt")) {
            bind.modifiers.alt = true;
        } else if (std.mem.eql(u8, lowkey, "mod2")) {
            bind.modifiers.mod2 = true;
        } else if (std.mem.eql(u8, lowkey, "mod3")) {
            bind.modifiers.mod3 = true;
        } else if (std.mem.eql(u8, lowkey, "mod4") or std.mem.eql(u8, lowkey, "super")) {
            bind.modifiers.logo = true;
        } else if (std.mem.eql(u8, lowkey, "mod5")) {
            bind.modifiers.mod5 = true;
        } else if (std.mem.eql(u8, lowkey, "shift")) {
            bind.modifiers.shift = true;
        } else if (std.mem.eql(u8, lowkey, "caps")) {
            bind.modifiers.caps = true;
        } else if (std.mem.eql(u8, lowkey, "ctrl") or std.mem.eql(u8, lowkey, "control")) {
            bind.modifiers.ctrl = true;
        } else if (std.mem.eql(u8, lowkey, "enter")) {
            bind.keys.append(xkb.Keysym.Return) catch unreachable;
        } else {
            std.log.err("Unknown key or modifier: {s}", .{key});
        }
    }

    while (true) {
        const func_call_evt = c.kdl_parser_next_event(parser);
        if (func_call_evt.*.event == c.KDL_EVENT_END_NODE) break;
        const func_call: FuncCall = kdl_parse_func_call(parser, allocator, func_call_evt) orelse return error.ParseError;
        bind.action.body.append(func_call) catch unreachable;
    }
    return bind;
}

// -----------------------------------------------------------------------------

fn read_chunk(ctx: ?*anyopaque, buf: [*c]u8, bufsize: usize) callconv(.c) usize {
    const file: *std.fs.File = @ptrCast(@alignCast(ctx));
    return file.read(buf[0..bufsize]) catch |err| {
        std.log.err("Failed to read config file: {s}", .{@errorName(err)});
        return 0;
    };
}

fn kdl_str_to_slice(str: c.struct_kdl_str) []const u8 {
    return str.data[0..str.len];
}

fn kdl_type_to_str(ty: c.enum_kdl_type) []const u8 {
    return switch (ty) {
        c.KDL_TYPE_NULL => "null",
        c.KDL_TYPE_BOOLEAN => "boolean",
        c.KDL_TYPE_NUMBER => "number",
        c.KDL_TYPE_STRING => "string",
        else => unreachable,
    };
}

fn kdl_event_to_str(ty: c.enum_kdl_event) []const u8 {
    return switch (ty) {
        c.KDL_EVENT_EOF => "EOF",
        c.KDL_EVENT_PARSE_ERROR => "PARSE_ERROR",
        c.KDL_EVENT_START_NODE => "START_NODE",
        c.KDL_EVENT_END_NODE => "END_NODE",
        c.KDL_EVENT_ARGUMENT => "ARGUMENT",
        c.KDL_EVENT_PROPERTY => "PROPERTY",
        else => unreachable,
    };
}

fn kdl_expect_argument(ty: c.enum_kdl_event, i: usize, n: usize, name: []const u8) bool {
    switch (ty) {
        c.KDL_EVENT_ARGUMENT => return true,
        c.KDL_EVENT_PARSE_ERROR => {
            std.log.err("Failed to parse config file", .{});
        },
        c.KDL_EVENT_END_NODE | c.KDL_EVENT_EOF => {
            std.log.err("Not enough arguments for {s}. Expected {d}, got {d}", .{
                name,
                n,
                i,
            });
        },
        else => {
            std.log.err("Unexpected event: {s}", .{kdl_event_to_str(ty)});
        },
    }
    return false;
}

fn kdl_expect_start_node(ty: c.enum_kdl_event) bool {
    switch (ty) {
        c.KDL_EVENT_START_NODE => return true,
        c.KDL_EVENT_PARSE_ERROR => {
            std.log.err("Failed to parse config file", .{});
        },
        else => {
            std.log.err("Unexpected event: {s}", .{kdl_event_to_str(ty)});
        },
    }
    return false;
}

fn kdl_expect_end_node(ty: c.enum_kdl_event, n: usize, name: []const u8) bool {
    switch (ty) {
        c.KDL_EVENT_END_NODE => return true,
        c.KDL_EVENT_PARSE_ERROR => {
            std.log.err("Failed to parse config file: {s}", .{name});
        },
        c.KDL_EVENT_ARGUMENT => {
            std.log.err("Too many arguments for {s}. Expected {d}, got {d}", .{
                name,
                n,
                // TODO: Calculate this properly
                n + 1,
            });
        },
        else => {
            std.log.err("Unexpected event: {s}", .{kdl_event_to_str(ty)});
        },
    }
    return false;
}

fn kdl_expect_type(ty: c.enum_kdl_type, expected: c.enum_kdl_type, name: []const u8) bool {
    if (ty == expected) return true;
    std.log.err("Invalid argument for {s}. Expected {s}, got {s}", .{
        name,
        kdl_type_to_str(expected),
        kdl_type_to_str(ty),
    });
    return false;
}

const Func = struct {
    name: FnName,
    args: []const ValueKind,
};

const FnName = enum {
    spawn,
    toggle_float,
    toggle_maximized,
    toggle_fullscreen,
    switch_direction,
    make_group,
};

const builtin_funcs = [_]Func{
    Func{ .name = .spawn, .args = &.{.string} },
    Func{ .name = .toggle_float, .args = &.{} },
    Func{ .name = .toggle_maximized, .args = &.{} },
    Func{ .name = .toggle_fullscreen, .args = &.{} },
    Func{ .name = .switch_direction, .args = &.{} },
    Func{ .name = .make_group, .args = &.{.layout} },
};

const MAX_ARGS = 1;

const ValueKind = enum {
    null,
    boolean,
    integer,
    float,
    string,
    layout,
    color,

    fn toKdl(self: ValueKind) c.kdl_type {
        switch (self) {
            .null => return c.KDL_TYPE_NULL,
            .boolean => return c.KDL_TYPE_BOOLEAN,
            .integer => return c.KDL_TYPE_NUMBER,
            .float => return c.KDL_TYPE_NUMBER,
            .string => return c.KDL_TYPE_STRING,
            .layout => return c.KDL_TYPE_STRING,
            .color => return c.KDL_TYPE_STRING,
        }
    }
};

const Value = union(ValueKind) {
    null: void,
    boolean: bool,
    integer: i32,
    float: f64,
    string: []const u8,
    layout: Layout.SublayoutKind,
    color: [4]f32,

    fn fromKdl(value: c.struct_kdl_value, kind: ValueKind, allocator: std.mem.Allocator) ?Value {
        return switch (value.type) {
            c.KDL_TYPE_NULL => if (kind == .null) .{ .null = {} } else {
                std.log.err("Expected null, got {s}", .{kdl_type_to_str(value.type)});
                return null;
            },
            c.KDL_TYPE_BOOLEAN => if (kind == .boolean) .{ .boolean = value.unnamed_0.boolean } else {
                std.log.err("Expected boolean, got {s}", .{kdl_type_to_str(value.type)});
                return null;
            },
            c.KDL_TYPE_STRING => switch (kind) {
                .layout => .{ .layout = Layout.SublayoutKind.fromString(kdl_str_to_slice(value.unnamed_0.string)) orelse {
                    std.log.err("Unknown layout: {s}", .{kdl_str_to_slice(value.unnamed_0.string)});
                    return null;
                } },
                .color => .{ .color = utils.parseColor(kdl_str_to_slice(value.unnamed_0.string)) catch {
                    std.log.err("Invalid color: {s}", .{kdl_str_to_slice(value.unnamed_0.string)});
                    return null;
                } },
                else => .{ .string = allocator.dupe(u8, kdl_str_to_slice(value.unnamed_0.string)) catch unreachable },
            },
            c.KDL_TYPE_NUMBER => switch (kind) {
                .integer => .{ .integer = switch (value.unnamed_0.number.type) {
                    c.KDL_NUMBER_TYPE_INTEGER => @intCast(value.unnamed_0.number.unnamed_0.integer),
                    c.KDL_NUMBER_TYPE_FLOATING_POINT => {
                        std.log.err("Expected integer, got float", .{});
                        return null;
                    },
                    else => unreachable,
                } },
                .float => .{ .float = switch (value.unnamed_0.number.type) {
                    c.KDL_NUMBER_TYPE_INTEGER => @floatFromInt(value.unnamed_0.number.unnamed_0.integer),
                    c.KDL_NUMBER_TYPE_FLOATING_POINT => value.unnamed_0.number.unnamed_0.floating_point,
                    else => unreachable,
                } },
                else => {
                    std.log.err("Expected number, got {s}", .{kdl_type_to_str(value.type)});
                    return null;
                },
            },
            else => unreachable,
        };
    }
};

pub const FuncCall = struct {
    func: *const Func,
    args: std.BoundedArray(Value, MAX_ARGS),
};

fn kdl_parse_func_call(parser: *c.struct__kdl_parser, allocator: std.mem.Allocator, evt: ?*c.kdl_event_data) ?FuncCall {
    const func_evt = evt orelse c.kdl_parser_next_event(parser);
    if (!kdl_expect_start_node(func_evt.*.event)) return null;
    const func_name = kdl_str_to_slice(func_evt.*.name);

    const builtin_func: *const Func = for (&builtin_funcs) |*func| {
        if (std.mem.eql(u8, @tagName(func.name), func_name)) {
            break func;
        }
    } else {
        std.log.err("Unknown function: {s}", .{func_name});
        return null;
    };

    var func_call = FuncCall{
        .func = builtin_func,
        .args = .{},
    };

    for (builtin_func.args, 0..) |ty, i| {
        const arg = c.kdl_parser_next_event(parser);
        if (!kdl_expect_argument(arg.*.event, i, builtin_func.args.len, @tagName(builtin_func.name))) return null;
        if (!kdl_expect_type(arg.*.value.type, ty.toKdl(), @tagName(builtin_func.name))) return null;
        const value = Value.fromKdl(arg.*.value, ty, allocator) orelse return null;
        func_call.args.append(value) catch unreachable;
    }

    const end_evt = c.kdl_parser_next_event(parser);
    if (!kdl_expect_end_node(end_evt.*.event, builtin_func.args.len, @tagName(builtin_func.name))) return null;

    return func_call;
}

const Lambda = struct {
    body: std.ArrayList(FuncCall),
};
