const std = @import("std");
const ResolvedTarget = std.Build.ResolvedTarget;
const OptimizeMode = std.builtin.OptimizeMode;
const Step = std.Build.Step;
const Compile = Step.Compile;
const Run = Step.Run;
const LazyPath = std.Build.LazyPath;

pub const ServerOptions = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 0,
    // open the os default webbrowser on first launch,
    open_browser: ?[]const u8 = null,
    // should the server fork and reload itself.
    // true by default if `--watch` is in zig build's `argv`
    watch: ?bool = null,
    directory: ServePath,
};

pub const ServePath = union(enum) {
    // a subpath in `zig-out`
    install: []const u8,
    // a generated directory in the cache or the sources
    lazypath: LazyPath,
    pub fn serveInstall(dir: []const u8) @This() {
        return .{ .install = dir };
    }

    pub fn serveLazyPath(dir: LazyPath) @This() {
        return .{ .lazypath = dir };
    }
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
    b.step("run-with-args", "run the server binary with arguments").dependOn(&run.step);

    const install_html = b.addInstallFile(b.path("src/index.html"), "www/index.html");
    b.getInstallStep().dependOn(&install_html.step);

    const port = b.option(u16, "port", "port to listen on") orelse 8080;
    const open_browser = b.option([]const u8, "open-browser", "open the browser when server starts");
    {
        const watch = serveDirInternal(b, exe, .{
            .port = port,
            .open_browser = open_browser,
            .directory = .serveInstall("www"),
        });

        b.step("run", "run the server").dependOn(&watch.step);
    }
    {
        const watch = serveDirInternal(b, exe, .{
            .port = port,
            .open_browser = open_browser,
            .directory = .serveLazyPath(b.path("src")),
        });

        b.step("run-lazypath-src", "run the server on a lazypath in src").dependOn(&watch.step);
    }
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
    var watch = opt.watch orelse false;
    if (opt.watch == null) {
        // TODO: find a better way to determine we are watching
        const args = std.process.argsAlloc(b.allocator) catch unreachable;
        defer std.process.argsFree(b.allocator, args);
        for (args) |arg| {
            if (std.mem.eql(u8, arg, "--watch")) {
                watch = true;
                break;
            }
        }
    }

    run.addArg(if (watch) "watch" else "serve");
    run.addArg(opt.host);
    run.addArg(b.fmt("{d}", .{opt.port}));
    switch (opt.directory) {
        .install => |subdir| {
            run.addArg(b.pathJoin(&.{ b.install_path, subdir }));
            run.step.dependOn(b.getInstallStep());
        },
        .lazypath => |lp| run.addFileArg(lp),
    }
    if (opt.open_browser) |path| run.setEnvironmentVariable("ZIG_DEVSERVER_OPEN_BROWSER", path);
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
