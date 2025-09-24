const std = @import("std");
const builtin = @import("builtin");

const Request = @import("Request.zig");

pub const std_options: std.Options = .{
    .log_level = .info,
};
const log = std.log;

var previous_shutdown_servers: u8 = 0;

pub fn main() !void {
    var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = general_purpose_allocator.deinit();
    const gpa = general_purpose_allocator.allocator();
    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    log.info("server args: {f}", .{
        std.json.fmt(args, .{}),
    });

    if (args.len < 2) {
        try usage(gpa, args);
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
            return cmd[1](gpa, args[2..]);
        }
    }
    log.err("unknown subcommand: {s}", .{args[1]});
    try usage(gpa, args[2..]);
    std.process.exit(1);
}

pub fn usage(gpa: std.mem.Allocator, args: []const [:0]const u8) !void {
    _ = gpa;
    var outbuf: [64]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&outbuf).interface;
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

pub fn watchServer(gpa: std.mem.Allocator, args: []const [:0]const u8) !void {
    if (args.len != 3) {
        return error.IncorrectNumberOfArguments;
    }
    const port = try std.fmt.parseInt(u16, args[1], 10);
    if (port == 0) {
        log.err("port 0 is not supported with 'watch'.", .{});
        log.err("we cannot terminate a forked server on an unknown port.", .{});
        return error.Port0NotSupported;
    }
    if (!try std.process.hasEnvVar(gpa, "PPID")) {
        std.log.err("env var PPID not found. watch will fork and never stop otherwise.", .{});
        return error.MissingEnvVar;
    }

    previous_shutdown_servers = 0;
    for (0..2) |_| {
        notifyServer(gpa, args[0], port) catch |err| switch (err) {
            error.ConnectionRefused => break, // no server found.
            error.ConnectionResetByPeer,
            error.ReadFailed,
            error.HttpConnectionClosing,
            => {},
            else => return err,
        };
        previous_shutdown_servers += 1;
    }

    const forkpid = try std.posix.fork();

    if (forkpid < 0) {
        return error.ForkFailed;
    } else if (forkpid > 0) {
        // we stop the parent process
        std.process.exit(0);
    }

    const smp = std.heap.smp_allocator;
    return startServer(smp, args);
}

pub fn notifyServer(gpa: std.mem.Allocator, host: []const u8, port: u16) !void {
    var client = std.http.Client{
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
    std.Thread.sleep(std.time.ns_per_s);
}

pub fn startServer(gpa: std.mem.Allocator, args: []const [:0]const u8) !void {
    if (args.len != 3) {
        return error.IncorrectNumberOfArguments;
    }

    const host = args[0];
    const port = try std.fmt.parseInt(u16, args[1], 10);

    const root_dir_path = args[2];
    var root_dir: std.fs.Dir = try std.fs.cwd().openDir(root_dir_path, .{});
    defer root_dir.close();

    const start_time = std.time.timestamp();
    var request_pool: std.Thread.Pool = undefined;
    try request_pool.init(.{
        .allocator = gpa,
    });
    defer request_pool.deinit();

    const address = try std.net.Address.parseIp(host, port);
    var tcp_server = try address.listen(.{
        .reuse_address = true,
    });
    defer tcp_server.deinit();

    log.warn("\x1b[2K\rServing website at http://{f}/\n", .{tcp_server.listen_address.in});

    if (previous_shutdown_servers == 0) {
        if (std.process.getEnvVarOwned(gpa, "ZIG_DEVSERVER_OPEN_BROWSER") catch null) |open_browser| {
            defer gpa.free(open_browser);
            const url_str = try std.fmt.allocPrint(
                gpa,
                "http://{f}/{s}",
                .{
                    tcp_server.listen_address.in,
                    if (open_browser.len > 0 and open_browser[0] == '/') open_browser[1..] else open_browser,
                },
            );
            defer gpa.free(url_str);
            std.log.info("opening in browser: {s}", .{url_str});
            const res = try std.process.Child.run(.{
                .allocator = gpa,
                .argv = &.{ open_command, url_str },
            });
            gpa.free(res.stderr);
            gpa.free(res.stdout);
        }
    }

    const maybe_ppid: ?std.posix.pid_t = blk: {
        const ppid = std.process.getEnvVarOwned(gpa, "PPID") catch break :blk null;
        break :blk std.fmt.parseInt(std.posix.pid_t, ppid, 10) catch null;
    };

    accept: while (true) {
        const request = try gpa.create(Request);

        request.gpa = gpa;
        request.public_dir = root_dir;
        request.public_path = root_dir_path;
        request.start_time = start_time;
        request.conn = tcp_server.accept() catch |err| {
            switch (err) {
                error.ConnectionAborted, error.ConnectionResetByPeer => {
                    log.warn("{s} on lister accept", .{@errorName(err)});
                    gpa.destroy(request);
                    continue :accept;
                },
                else => {},
            }
            return err;
        };

        if (maybe_ppid) |ppid| {
            std.posix.kill(ppid, 0) catch |err| {
                log.info("parent process {d} not found: {}. exiting devserver", .{ ppid, err });
                return;
            };
        }

        request_pool.spawn(Request.handle, .{request}) catch |err| {
            log.err("Error spawning request response thread: {s}", .{@errorName(err)});
            request.conn.stream.close();
            gpa.destroy(request);
        };
    }
}

const open_command = switch (builtin.os.tag) {
    .linux => "xdg-open",
    .macos => "open",
    .windows => "explorer.exe",
    else => "",
};
