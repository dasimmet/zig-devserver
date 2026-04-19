const std = @import("std");
const builtin = @import("builtin");

const Request = @import("Request.zig");

pub const std_options: std.Options = .{
    .log_level = .info,
};
const log = std.log;

var previous_shutdown_servers: u8 = 0;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    log.info("server args: {f}", .{
        std.json.fmt(args, .{}),
    });

    if (args.len < 2) {
        try usage(init, args);
        std.process.exit(1);
    }

    inline for (&.{
        .{ "-h", usage },
        .{ "-?", usage },
        .{ "/h", usage },
        .{ "/?", usage },
        .{ "--help", usage },
        .{ "help", usage },
        .{ "usage", usage },
        .{ "serve", startServer },
        .{ "watch", watchServer },
    }) |cmd| {
        if (std.mem.eql(u8, args[1], cmd[0])) {
            return cmd[1](init, args[2..]);
        }
    }
    log.err("unknown subcommand: {s}", .{args[1]});
    try usage(init, args[2..]);
    std.process.exit(1);
}

pub fn usage(init: std.process.Init, args: []const [:0]const u8) !void {
    var outbuf: [64]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &outbuf).interface;
    try stdout.print("args: {f}\n", .{
        std.json.fmt(args, .{}),
    });
    try stdout.writeAll(
        \\usage: devserver {-h|--help|-?|help|serve|notify} [subcommand args]
        \\
        \\subcommand usage:
        \\  serve {host} {port} {directory} # server a directory on a given host and port
        \\  watch {host} {port} {directory} # used from `zig build --watch` to auto-restart server
        \\  help # print usage
        \\
        \\environment variables:
        \\  ZIG_DEVSERVER_OPEN_BROWSER=/ # open browser at path
        \\  PPID # id of parent process. stop forked progam if this id ends
    );
}

pub fn watchServer(init: std.process.Init, args: []const [:0]const u8) !void {
    if (args.len != 3) {
        return error.IncorrectNumberOfArguments;
    }
    const port = try std.fmt.parseInt(u16, args[1], 10);
    if (port == 0) {
        log.err("port 0 is not supported with 'watch'.", .{});
        log.err("we cannot terminate a forked server on an unknown port.", .{});
        return error.Port0NotSupported;
    }
    if (!init.environ_map.contains("PPID")) {
        std.log.err("env var PPID not found. watch will fork and never stop otherwise.", .{});
        return error.MissingEnvVar;
    }

    previous_shutdown_servers = 0;
    for (0..2) |_| {
        notifyServer(init.io, init.gpa, args[0], port) catch |err| switch (err) {
            error.ConnectionRefused => {
                try init.io.sleep(.fromSeconds(1), .awake);
            }, // no server found.
            error.ConnectionResetByPeer,
            error.ReadFailed,
            error.HttpConnectionClosing,
            => {
                try init.io.sleep(.fromSeconds(1), .awake);
            },
            else => return err,
        };
        previous_shutdown_servers += 1;
    }

    const forkpid = std.os.linux.fork();

    if (forkpid > 0) {
        // we stop the parent process
        std.process.exit(0);
    }

    // const smp = std.heap.smp_allocator;
    return startServer(init, args);
}

pub fn notifyServer(
    io: std.Io,
    gpa: std.mem.Allocator,
    host: []const u8,
    port: u16,
) !void {
    var client = std.http.Client{
        .io = io,
        .allocator = gpa,
    };
    defer client.deinit();
    const msg: Request.Api = .{ .action = .shutdown };
    var buf: [4096]u8 = undefined;
    const payload = std.fmt.bufPrint(&buf, "{f}\n", .{
        std.json.fmt(msg, .{
            .emit_null_optional_fields = false,
        }),
    }) catch @panic("Buffer Overflow");

    var api_url_buf: [256]u8 = undefined;
    const api_url = std.fmt.bufPrint(
        &api_url_buf,
        "http://{s}" ++ Request.Api.endpoint,
        .{host},
    ) catch @panic("Buffer Overflow");
    var uri = std.Uri.parse(api_url) catch @panic("Host malformed!");
    uri.port = port;

    _ = try client.fetch(.{
        .location = .{ .uri = uri },
        .payload = payload,
        .method = .POST,
    });
    try io.sleep(.fromSeconds(1), .awake);
}

pub fn startServer(init: std.process.Init, args: []const [:0]const u8) !void {
    if (args.len != 3) {
        return error.IncorrectNumberOfArguments;
    }

    const host = args[0];
    const port = try std.fmt.parseInt(u16, args[1], 10);

    const root_dir_path = args[2];
    var root_dir: std.Io.Dir = try std.Io.Dir.cwd().openDir(init.io, root_dir_path, .{});
    defer root_dir.close(init.io);

    const start_time = std.Io.Clock.real.now(init.io);

    var request_group = std.Io.Group.init;

    const address = try std.Io.net.IpAddress.parse(host, port);
    var tcp_server = try address.listen(init.io, .{
        .reuse_address = true,
    });
    defer tcp_server.deinit(init.io);

    if (previous_shutdown_servers == 0) {
        if (init.environ_map.get("ZIG_DEVSERVER_OPEN_BROWSER")) |open_browser| {
            const url_str = try std.fmt.allocPrint(
                init.gpa,
                "http://{f}/{s}",
                .{
                    tcp_server.socket.address,
                    if (open_browser.len > 0 and open_browser[0] == '/') open_browser[1..] else open_browser,
                },
            );
            defer init.gpa.free(url_str);
            std.log.info("opening in browser: {s}", .{url_str});
            const res = try std.process.run(init.gpa, init.io, .{
                .argv = &.{ open_command, url_str },
            });
            init.gpa.free(res.stderr);
            init.gpa.free(res.stdout);
        }
    }

    const maybe_ppid: ?std.posix.pid_t = blk: {
        const ppid = init.environ_map.get("PPID") orelse break :blk null;
        break :blk std.fmt.parseInt(std.posix.pid_t, ppid, 10) catch null;
    };

    log.warn("\x1b[2K\rServing website at http://{f}/\n", .{tcp_server.socket.address});
    accept: while (true) {
        const request = try init.gpa.create(Request);

        request.io = init.io;
        request.gpa = init.gpa;
        request.public_dir = root_dir;
        request.public_path = root_dir_path;
        request.start_time = start_time;
        request.stream = tcp_server.accept(init.io) catch |err| {
            switch (err) {
                error.ConnectionAborted => {
                    log.warn("{s} on lister accept", .{@errorName(err)});
                    init.gpa.destroy(request);
                    continue :accept;
                },
                else => {},
            }
            return err;
        };
        // log.warn("req: {any}", .{request});

        if (maybe_ppid) |ppid| {
            std.posix.kill(ppid, @enumFromInt(0)) catch |err| {
                log.info("parent process {d} not found: {}. exiting devserver", .{ ppid, err });
                return;
            };
        }

        request_group.async(init.io, Request.handle, .{request});
    }
}

const open_command = switch (builtin.os.tag) {
    .linux => "xdg-open",
    .macos => "open",
    .windows => "explorer.exe",
    else => "",
};
