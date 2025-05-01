const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mime = b.dependency("mime", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "devserver",
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/main.zig"),
    });
    switch (target.result.os.tag) {
        .windows => exe.linkLibC(),
        else => {},
    }

    exe.root_module.addImport("mime", mime.module("mime"));
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.has_side_effects = true;
    const maybe_ppid: ?[]const u8 = switch (@import("builtin").os.tag) {
        .linux, .macos => b.fmt("{d}", .{std.os.linux.getpid()}),
        // TODO: figure out processes on windows
        // .windows => b.fmt("{d}", .{std.os.windows.GetCurrentProcessId()}),
        else => null,
    };
    if (maybe_ppid) |ppid| {
        run.setEnvironmentVariable("PPID", ppid);
    }
    if (b.args) |args| {
        run.addArgs(args);
    }
    b.step("run", "run the server").dependOn(&run.step);
}
