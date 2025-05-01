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
    exe.root_module.addImport("mime", mime.module("mime"));
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.has_side_effects = true;
    if (b.args) |args| {
        run.addArgs(args);
    }
    b.step("run", "run the server").dependOn(&run.step);
}
