const std = @import("std");
const ResolvedTarget = std.Build.ResolvedTarget;
const OptimizeMode = std.builtin.OptimizeMode;
const Step = std.Build.Step;
const Compile = Step.Compile;
const Run = Step.Run;
const LazyPath = std.Build.LazyPath;

pub const ServerOptions = struct {
    port: u16 = 0,
    directory: union(enum) {
        install: []const u8,
        lazypath: LazyPath,
    },
};

pub fn serveDir(b: *std.Build, opt: ServerOptions) *Run {
    const this_dep = b.dependencyFromBuildZig(@This(), .{
        .target = b.graph.host,
        .optimize = .Debug,
    });
    return serveDirInternal(b, this_dep.artifact("devserver"), opt);
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = compileServer(b, target, optimize);
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

    const install_html = b.addInstallFile(b.path("src/index.html"), "www/index.html");
    const watch = serveDirInternal(b, exe, .{
        .port = b.option(u16, "port", "port to listen on") orelse 8080,
        .directory = .{ .install = "www" },
    });
    watch.step.dependOn(&install_html.step);

    b.step("watch", "run the server").dependOn(&watch.step);
}

pub fn serveDirInternal(b: *std.Build, server: *Compile, opt: ServerOptions) *Run {
    const run = b.addRunArtifact(server);
    run.has_side_effects = true;
    const maybe_ppid: ?[]const u8 = switch (@import("builtin").os.tag) {
        .linux, .macos => b.fmt("{d}", .{std.os.linux.getpid()}),
        else => null,
    };
    if (maybe_ppid) |ppid| {
        run.setEnvironmentVariable("PPID", ppid);
    }
    var watch = false;
    {
        // TODO: find a better way to determine we are watching
        const args = std.process.argsAlloc(b.allocator) catch unreachable;
        defer std.process.argsFree(b.allocator, args);
        for (args) |arg| {
            if (std.mem.eql(u8, arg, "--watch")) watch = true;
        }
    }

    run.addArg(if (watch) "watch" else "serve");
    run.addArg(b.fmt("{d}", .{opt.port}));
    switch (opt.directory) {
        .install => |subdir| run.addArg(b.pathJoin(&.{ b.install_path, subdir })),
        .lazypath => |lp| run.addFileArg(lp),
    }
    return run;
}

fn compileServer(b: *std.Build, target: ResolvedTarget, optimize: OptimizeMode) *Compile {
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

    const mime = b.dependency("mime", .{
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("mime", mime.module("mime"));
    return exe;
}
