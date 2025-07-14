const std = @import("std");
const Args = @This();

const help_message: []const u8 =
    \\Usage: pocowm [OPTIONS]
    \\
    \\Options:
    \\  -h, --help           Show this help message and exit
    \\  -c, --config <PATH>  Path to config file (default to $XDG_CONFIG_HOME/pocowm/config.json)
    \\
;

pub var instance: Args = undefined;

config: []const u8,

pub fn try_parse(allocator: std.mem.Allocator) !Args {
    var config: ?[]const u8 = null;
    var args_it = std.process.args();
    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            std.io.getStdOut().writeAll(help_message) catch unreachable;
            std.process.exit(0);
        }
        if (std.mem.eql(u8, arg, "--config") or std.mem.eql(u8, arg, "-c")) {
            config = args_it.next() orelse return error.MissingConfigFile;
        }
    }
    return .{
        .config = config orelse defaultConfigPath(allocator) catch |err| {
            std.log.err("Failed to get default config path: {s}", .{@errorName(err)});
            std.process.exit(1);
        },
    };
}

pub fn defaultConfigPath(allocator: std.mem.Allocator) ![]const u8 {
    const base_config_folder =
        std.posix.getenv("XDG_CONFIG_HOME") orelse
        try std.fs.path.join(allocator, &.{
            std.posix.getenv("HOME") orelse ".",
            "/.config",
        });
    return try std.fs.path.join(allocator, &.{
        base_config_folder,
        "pocowm",
        "config.json",
    });
}

pub fn parse(allocator: std.mem.Allocator) Args {
    const self = try_parse(allocator) catch |err| {
        switch (err) {
            error.MissingConfigFile => std.log.err("Missing config file", .{}),
        }
        std.io.getStdErr().writeAll(help_message) catch unreachable;
        std.process.exit(0);
        std.process.exit(1);
    };

    return self;
}

pub fn init(allocator: std.mem.Allocator) void {
    instance = parse(allocator);
}
