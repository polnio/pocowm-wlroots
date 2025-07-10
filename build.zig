const std = @import("std");

const Scanner = @import("wayland").Scanner;

fn get_path(b: *std.Build, pkg: []const u8, path: []const u8) std.Build.LazyPath {
    const pc_output = b.run(&.{ "pkg-config", "--variable=pkgdatadir", pkg });
    return .{ .cwd_relative = b.pathJoin(&.{ std.mem.trim(u8, pc_output, &std.ascii.whitespace), path }) };
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const scanner = Scanner.create(b, .{});
    scanner.addSystemProtocol("stable/xdg-shell/xdg-shell.xml");
    scanner.addSystemProtocol("stable/tablet/tablet-v2.xml");
    scanner.addSystemProtocol("unstable/xdg-decoration/xdg-decoration-unstable-v1.xml");
    scanner.addCustomProtocol(get_path(b, "wlr-protocols", "unstable/wlr-layer-shell-unstable-v1.xml"));

    // Some of these versions may be out of date with what wlroots implements.
    // This is not a problem in practice though as long as tinywl successfully compiles.
    // These versions control Zig code generation and have no effect on anything internal
    // to wlroots. Therefore, the only thing that can happen due to a version being too
    // old is that tinywl fails to compile.
    scanner.generate("wl_compositor", 6);
    scanner.generate("wl_subcompositor", 1);
    scanner.generate("wl_shm", 2);
    scanner.generate("wl_output", 4);
    scanner.generate("wl_seat", 9);
    scanner.generate("wl_data_device_manager", 3);
    scanner.generate("xdg_wm_base", 6);
    scanner.generate("zxdg_decoration_manager_v1", 1);
    scanner.generate("zwlr_layer_shell_v1", 4);
    scanner.generate("zwp_tablet_manager_v2", 2);

    const wayland = b.createModule(.{ .root_source_file = scanner.result });
    const xkbcommon = b.dependency("xkbcommon", .{}).module("xkbcommon");
    const pixman = b.dependency("pixman", .{}).module("pixman");
    const wlroots = b.dependency("wlroots", .{}).module("wlroots");

    wlroots.addImport("wayland", wayland);
    wlroots.addImport("xkbcommon", xkbcommon);
    wlroots.addImport("pixman", pixman);

    // We need to ensure the wlroots include path obtained from pkg-config is
    // exposed to the wlroots module for @cImport() to work. This seems to be
    // the best way to do so with the current std.Build API.
    wlroots.resolved_target = target;
    wlroots.linkSystemLibrary("wlroots-0.18", .{});

    const pocowm = b.addExecutable(.{
        .name = "pocowm",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    pocowm.linkLibC();

    pocowm.root_module.addImport("wayland", wayland);
    pocowm.root_module.addImport("xkbcommon", xkbcommon);
    pocowm.root_module.addImport("wlroots", wlroots);

    pocowm.linkSystemLibrary("wayland-server");
    pocowm.linkSystemLibrary("xkbcommon");
    pocowm.linkSystemLibrary("pixman-1");

    b.installArtifact(pocowm);

    const run_cmd = b.addRunArtifact(pocowm);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
