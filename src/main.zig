//! HTTP/WebSocket development server with Zig build `--listen=-` (`Run.stdio = .protocol`) support
//! and in-process directory watching for live browser reloads.

const std = @import("std");
const builtin = @import("builtin");

pub const Request = @import("Request.zig");
pub const Protocol = @import("Protocol.zig");
pub const Watcher = @import("Watcher.zig");

const Io = std.Io;
const log = std.log;

pub const std_options: std.Options = .{
    .logFn = customLogFn,
};

const LogState = struct {
    protocol_mode: std.atomic.Value(bool) = .init(false),
    mutex: Io.Mutex = .init,
    tty_io: Io = undefined,
    tty_file: ?Io.File = null,
    tty_color: bool = false,
};

var log_state: LogState = .{};

fn initTtyLog(io: Io, no_color: bool) void {
    const file: ?Io.File = if (builtin.os.tag == .windows)
        null
    else
        Io.Dir.openFileAbsolute(io, "/dev/tty", .{ .mode = .write_only }) catch null;

    const use_color = if (file) |f|
        (!no_color and (f.supportsAnsiEscapeCodes(io) catch false))
    else
        false;

    log_state.tty_io = io;
    log_state.tty_file = file;
    log_state.tty_color = use_color;
    log_state.protocol_mode.store(true, .release);
}

fn deinitTtyLog() void {
    log_state.protocol_mode.store(false, .release);
    if (log_state.tty_file == null) return;

    const io = log_state.tty_io;
    log_state.mutex.lockUncancelable(io);
    const maybe_file = log_state.tty_file;
    log_state.tty_file = null;
    log_state.mutex.unlock(io);

    if (maybe_file) |f| f.close(io);
}

fn writeFormattedLog(
    writer: *Io.Writer,
    use_color: bool,
    comptime message_level: log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) !void {
    if (use_color) {
        const color = switch (message_level) {
            .err => "\x1b[31;1m",
            .warn => "\x1b[33;1m",
            .info => "\x1b[32;1m",
            .debug => "\x1b[34;1m",
        };
        try writer.writeAll(color);
    }
    try writer.writeAll(message_level.asText());
    if (scope != .default) {
        try writer.print("({s})", .{@tagName(scope)});
    }
    if (use_color) try writer.writeAll("\x1b[0m");
    try writer.writeAll(": ");
    try writer.print(format ++ "\n", args);
}

pub fn customLogFn(
    comptime message_level: log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    if (!log_state.protocol_mode.load(.acquire)) {
        std.log.defaultLog(message_level, scope, format, args);
        return;
    }

    // In `.protocol` mode, keep stdout strictly reserved for binary IPC and avoid
    // writing non-error application logs to buffered stderr (protocol trace logs go
    // directly to stderr in `Protocol.zig`).
    if (log_state.tty_file != null) {
        const io = log_state.tty_io;
        log_state.mutex.lockUncancelable(io);
        defer log_state.mutex.unlock(io);
        if (log_state.tty_file) |f| {
            var buf: [256]u8 = undefined;
            var w = f.writerStreaming(io, &buf);
            writeFormattedLog(&w.interface, log_state.tty_color, message_level, scope, format, args) catch {};
            w.interface.flush() catch {};
        }
    }

    if (message_level == .err) {
        std.log.defaultLog(message_level, scope, format, args);
    }
}

const CmdArg = union(enum) {
    string: []const u8,
    dir: Io.Dir,

    fn asString(self: CmdArg) ?[]const u8 {
        return switch (self) {
            .string => |s| s,
            .dir => null,
        };
    }
};

const CommandStatus = enum {
    ok,
    failed,
};

const ReadyState = struct {
    // Encoding: 0 = pending, 1 = failed, 0x10000 | port = bound.
    state: std.atomic.Value(u32) align(@alignOf(u32)) = .init(0),

    fn notifyBound(self: *ReadyState, io: Io, port: u16) void {
        self.state.store(@as(u32, 0x10000) | @as(u32, port), .release);
        io.futexWake(u32, &self.state.raw, std.math.maxInt(u32));
    }

    fn notifyFailed(self: *ReadyState, io: Io) void {
        self.state.store(1, .release);
        io.futexWake(u32, &self.state.raw, std.math.maxInt(u32));
    }
};

const WorkerTracker = struct {
    active: std.atomic.Value(u32) align(@alignOf(u32)) = .init(0),
    io: Io,

    fn spawn(self: *WorkerTracker, req: *Request) !void {
        _ = self.active.fetchAdd(1, .acq_rel);
        errdefer self.done();
        const thread = try std.Thread.spawn(.{}, workerMain, .{ self, req });
        thread.detach();
    }

    fn workerMain(self: *WorkerTracker, req: *Request) void {
        defer self.done();
        req.handle();
    }

    fn done(self: *WorkerTracker) void {
        if (self.active.fetchSub(1, .acq_rel) == 1) {
            self.io.futexWake(u32, &self.active.raw, 1);
        }
    }

    fn waitAll(self: *WorkerTracker) void {
        while (true) {
            const count = self.active.load(.acquire);
            if (count == 0) return;
            self.io.futexWaitUncancelable(u32, &self.active.raw, count);
        }
    }
};

const ShutdownCoord = struct {
    io: Io,
    broker: *Watcher.Broker,
    listen_address: Io.net.IpAddress,
    accept_mutex: Io.Mutex = .init,
    accept_closed: bool = false,

    fn markAcceptClosed(self: *ShutdownCoord) void {
        self.accept_mutex.lockUncancelable(self.io);
        self.accept_closed = true;
        self.accept_mutex.unlock(self.io);
    }

    fn trigger(self: *ShutdownCoord) void {
        const was_stopped = self.broker.stop.swap(true, .acq_rel);
        self.broker.requestStop(self.io);
        if (!was_stopped) {
            self.wakeAcceptLoop();
        }
    }

    fn wakeAcceptLoop(self: *ShutdownCoord) void {
        self.accept_mutex.lockUncancelable(self.io);
        defer self.accept_mutex.unlock(self.io);
        if (self.accept_closed) return;

        const target = connectTargetForAddress(self.listen_address);
        if (target.connect(self.io, .{ .mode = .stream })) |wake_stream| {
            wake_stream.close(self.io);
        } else |_| {}
    }

    fn onShutdownCallback(ctx: ?*anyopaque) void {
        const self: *ShutdownCoord = @ptrCast(@alignCast(ctx orelse return));
        self.trigger();
    }
};

const ControlContext = struct {
    session: *Protocol.Session,
    coord: *ShutdownCoord,
    maker_requested_exit: std.atomic.Value(bool) = .init(false),

    fn run(self: *@This()) void {
        self.session.waitForCloseOrExit();
        self.maker_requested_exit.store(true, .release);
        self.coord.trigger();
    }
};

const ProtocolSessionState = struct {
    session: *Protocol.Session,
    test_index: u32,
    finished: *bool,
};

const usage_text =
    \\Usage: devserver <command> [args]
    \\
    \\Commands:
    \\  watch <host> <port> <directory>   Serve files and watch for in-process changes
    \\  help, -h, --help                  Show this help message
    \\
;

fn writeUsage(io: Io, in_protocol: bool) void {
    var buf: [512]u8 = undefined;
    if (!in_protocol) {
        var w = Io.File.stdout().writerStreaming(io, &buf);
        w.interface.writeAll(usage_text) catch return;
        w.interface.flush() catch return;
        return;
    }

    if (log_state.tty_file != null) {
        const tty_io = log_state.tty_io;
        log_state.mutex.lockUncancelable(tty_io);
        defer log_state.mutex.unlock(tty_io);
        if (log_state.tty_file) |f| {
            var w = f.writerStreaming(tty_io, &buf);
            w.interface.writeAll(usage_text) catch {};
            w.interface.flush() catch {};
            return;
        }
    }

    var w = Io.File.stderr().writerStreaming(io, &buf);
    w.interface.writeAll(usage_text) catch {};
    w.interface.flush() catch {};
}

fn connectTargetForAddress(addr: Io.net.IpAddress) Io.net.IpAddress {
    const unspec_ip6: [16]u8 = @splat(0);
    return switch (addr) {
        .ip4 => |ip4| if (std.mem.eql(u8, &ip4.bytes, &.{ 0, 0, 0, 0 }))
            .{ .ip4 = .loopback(ip4.port) }
        else
            addr,
        .ip6 => |ip6| if (std.mem.eql(u8, &ip6.bytes, &unspec_ip6))
            .{ .ip6 = .loopback(ip6.port) }
        else
            addr,
    };
}

fn notifyExistingServer(gpa: std.mem.Allocator, io: Io, target: Io.net.IpAddress) !bool {
    const stream = target.connect(io, .{ .mode = .stream }) catch return false;
    defer stream.close(io);

    var send_buf: [512]u8 = undefined;
    var recv_buf: [1024]u8 = undefined;
    var writer = stream.writer(io, &send_buf);
    var reader = stream.reader(io, &recv_buf);

    const payload = "{\"action\":\"shutdown\"}";
    try writer.interface.print(
        "POST {s} HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
        .{ Request.Api.endpoint, payload.len, payload },
    );
    try writer.interface.flush();

    const resp = reader.interface.allocRemaining(gpa, .limited(4096)) catch return false;
    defer gpa.free(resp);

    return std.mem.startsWith(u8, resp, "HTTP/1.1 200") or
        std.mem.startsWith(u8, resp, "HTTP/1.0 200");
}

fn listenWithWatchTakeover(
    io: Io,
    gpa: std.mem.Allocator,
    address: *const Io.net.IpAddress,
) !Io.net.Server {
    return address.listen(io, .{ .reuse_address = true }) catch |err| {
        if (err != error.AddressInUse or address.getPort() == 0) return err;

        const target = connectTargetForAddress(address.*);
        const ack = notifyExistingServer(gpa, io, target) catch return err;
        if (!ack) return err;

        var attempt: usize = 0;
        while (attempt < 20) : (attempt += 1) {
            io.sleep(.fromMilliseconds(25), .awake) catch {};
            if (address.listen(io, .{ .reuse_address = true })) |srv| {
                return srv;
            } else |retry_err| {
                if (retry_err != error.AddressInUse) return retry_err;
            }
        }
        return address.listen(io, .{ .reuse_address = true });
    };
}

fn openBrowser(
    gpa: std.mem.Allocator,
    io: Io,
    bound_address: Io.net.IpAddress,
    open_path: []const u8,
) void {
    var rel = open_path;
    while (rel.len > 0 and rel[0] == '/') rel = rel[1..];

    const target = connectTargetForAddress(bound_address);
    const url = std.fmt.allocPrint(gpa, "http://{f}/{s}", .{ target, rel }) catch return;
    defer gpa.free(url);

    const argv: []const []const u8 = switch (builtin.os.tag) {
        .macos => &.{ "open", url },
        .windows => &.{ "cmd", "/c", "start", "", url },
        else => &.{ "xdg-open", url },
    };

    const child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch |err| {
        log.warn("failed to launch browser for {s}: {s}", .{ url, @errorName(err) });
        return;
    };

    const reaper = std.Thread.spawn(.{}, reapChildProcess, .{ child, io }) catch null;
    if (reaper) |t| t.detach();
}

fn reapChildProcess(child: std.process.Child, io: Io) void {
    var mutable_child = child;
    _ = mutable_child.wait(io) catch {};
}

fn resolveDirArg(
    io: Io,
    gpa: std.mem.Allocator,
    dir_arg: CmdArg,
) !struct { dir: Io.Dir, path: [:0]u8 } {
    switch (dir_arg) {
        .string => |path| {
            var dir = try Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
            errdefer dir.close(io);
            const resolved = try dir.realPathFileAlloc(io, ".", gpa);
            return .{ .dir = dir, .path = resolved };
        },
        .dir => |inherited| {
            var dir = try inherited.openDir(io, ".", .{ .iterate = true });
            errdefer dir.close(io);
            const resolved = try dir.realPathFileAlloc(io, ".", gpa);
            return .{ .dir = dir, .path = resolved };
        },
    }
}

fn runWatchServer(
    gpa: std.mem.Allocator,
    io: Io,
    open_browser_path: ?[]const u8,
    host: []const u8,
    port: u16,
    public_dir: Io.Dir,
    public_path: []const u8,
    protocol_state: ?ProtocolSessionState,
    ready_state: ?*ReadyState,
) !void {
    errdefer if (ready_state) |r| r.notifyFailed(io);

    const resolved = try Io.net.IpAddress.resolve(io, host, port);
    var tcp_server = try listenWithWatchTakeover(io, gpa, &resolved);
    defer tcp_server.deinit(io);

    const bound_address = tcp_server.socket.address;
    if (ready_state) |r| r.notifyBound(io, bound_address.getPort());

    var broker = Watcher.Broker.init(io);
    var coord: ShutdownCoord = .{
        .io = io,
        .broker = &broker,
        .listen_address = bound_address,
    };

    var workers: WorkerTracker = .{ .io = io };

    var watch_thread: ?std.Thread = try std.Thread.spawn(.{}, Watcher.runLoop, .{
        public_dir,
        &broker,
        gpa,
        io,
        Watcher.default_poll_interval_ns,
    });
    errdefer {
        coord.trigger();
        if (watch_thread) |t| t.join();
    }

    var ctrl_ctx: ControlContext = undefined;
    var control_thread: ?std.Thread = if (protocol_state) |ps| blk: {
        ctrl_ctx = .{
            .session = ps.session,
            .coord = &coord,
        };
        break :blk try std.Thread.spawn(.{}, ControlContext.run, .{&ctrl_ctx});
    } else null;

    log.info("Serving {s} at http://{f}", .{ public_path, bound_address });
    if (open_browser_path) |path| openBrowser(gpa, io, bound_address, path);

    var accept_err: ?anyerror = null;
    while (!broker.stop.load(.acquire)) {
        const stream = tcp_server.accept(io) catch |err| switch (err) {
            error.Canceled => break,
            else => {
                if (broker.stop.load(.acquire)) break;
                accept_err = err;
                break;
            },
        };

        if (broker.stop.load(.acquire)) {
            stream.close(io);
            break;
        }

        const req = gpa.create(Request) catch |err| {
            stream.close(io);
            accept_err = err;
            break;
        };
        req.* = .{
            .io = io,
            .gpa = gpa,
            .public_dir = public_dir,
            .public_path = public_path,
            .stream = stream,
            .broker = &broker,
            .on_shutdown = ShutdownCoord.onShutdownCallback,
            .shutdown_ctx = &coord,
        };

        workers.spawn(req) catch |err| {
            gpa.destroy(req);
            stream.close(io);
            accept_err = err;
            break;
        };
    }

    coord.markAcceptClosed();
    broker.requestStop(io);
    workers.waitAll();

    if (watch_thread) |t| {
        t.join();
        watch_thread = null;
    }

    if (protocol_state) |ps| {
        if (!ctrl_ctx.maker_requested_exit.load(.acquire)) {
            ps.session.sendTestResults(
                ps.test_index,
                if (accept_err == null) .pass else .fail,
            ) catch |err| {
                log.warn("failed to send protocol test_results: {s}", .{@errorName(err)});
            };
        }
        ps.finished.* = true;
    }

    if (control_thread) |t| {
        t.join();
        control_thread = null;
    }

    if (accept_err) |err| return err;
}

fn deinitCmdArgs(io: Io, gpa: std.mem.Allocator, cmd_args: []const CmdArg) void {
    for (cmd_args) |arg| {
        switch (arg) {
            .string => {},
            .dir => |dir| dir.close(io),
        }
    }
    gpa.free(cmd_args);
}

fn fromProtocolArgs(
    io: Io,
    gpa: std.mem.Allocator,
    protocol_args: []const Protocol.Arg,
) ![]CmdArg {
    var list: std.ArrayList(CmdArg) = .empty;
    errdefer {
        for (list.items) |arg| {
            switch (arg) {
                .string => {},
                .dir => |dir| dir.close(io),
            }
        }
        list.deinit(gpa);
    }

    for (protocol_args) |arg| {
        switch (arg) {
            .string => |s| try list.append(gpa, .{ .string = s }),
            .input_dir => |h| {
                if (h.prefix.len != 0) {
                    log.err("prefixed directory argument '{s}' is not supported", .{h.prefix});
                    return error.InvalidArguments;
                }
                const sub_path = if (h.suffix.len != 0) h.suffix else ".";
                const opened = try h.handle.openDir(io, sub_path, .{ .iterate = true });
                if (h.handle.handle != Io.Dir.cwd().handle) {
                    h.handle.close(io);
                }
                try list.append(gpa, .{ .dir = opened });
            },
            .input_file, .output_dir, .output_file => {
                log.err("expected a directory path or addDirectoryArg() handle", .{});
                return error.InvalidArguments;
            },
        }
    }

    return try list.toOwnedSlice(gpa);
}

fn isHelpCommand(cmd: []const u8) bool {
    return std.mem.eql(u8, cmd, "help") or
        std.mem.eql(u8, cmd, "-h") or
        std.mem.eql(u8, cmd, "--help");
}

const ParsedCommand = union(enum) {
    help,
    watch: struct {
        host: CmdArg,
        port: CmdArg,
        dir: CmdArg,
    },
    invalid: enum {
        empty,
        non_string_command,
        serve_removed,
        expected_protocol_args,
        unknown_command,
        expected_watch_args,
    },
};

fn parseCommand(in_protocol: bool, cmd_args: []const CmdArg) ParsedCommand {
    if (cmd_args.len == 0) return .{ .invalid = .empty };

    const first = cmd_args[0].asString() orelse return .{ .invalid = .non_string_command };
    if (isHelpCommand(first)) return .help;
    if (std.mem.eql(u8, first, "serve")) return .{ .invalid = .serve_removed };

    // When `--listen=-` is provided, always run the watch command: accept either explicit
    // `watch <host> <port> <directory>` (4 args) or `<host> <port> <directory>` (3 args).
    if (in_protocol and !std.mem.eql(u8, first, "watch")) {
        if (cmd_args.len != 3) return .{ .invalid = .expected_protocol_args };
        return .{ .watch = .{
            .host = cmd_args[0],
            .port = cmd_args[1],
            .dir = cmd_args[2],
        } };
    }

    if (!std.mem.eql(u8, first, "watch")) return .{ .invalid = .unknown_command };
    if (cmd_args.len != 4) return .{ .invalid = .expected_watch_args };

    return .{ .watch = .{
        .host = cmd_args[1],
        .port = cmd_args[2],
        .dir = cmd_args[3],
    } };
}

fn dispatchCommand(
    gpa: std.mem.Allocator,
    io: Io,
    open_browser_path: ?[]const u8,
    cmd_args: []const CmdArg,
    protocol_state: ?ProtocolSessionState,
) !CommandStatus {
    const in_protocol = protocol_state != null;

    const watch_args = switch (parseCommand(in_protocol, cmd_args)) {
        .help => {
            writeUsage(io, in_protocol);
            return .ok;
        },
        .invalid => |reason| {
            switch (reason) {
                .empty => {},
                .non_string_command => log.err("first argument must be a string", .{}),
                .serve_removed => log.err("unknown command 'serve' (use 'watch' instead)", .{}),
                .expected_protocol_args => log.err("expected 3 or 4 arguments in --listen=- mode: [watch] <host> <port> <directory>", .{}),
                .unknown_command => log.err("unknown command '{s}'", .{cmd_args[0].asString().?}),
                .expected_watch_args => log.err("expected 4 arguments: watch <host> <port> <directory>", .{}),
            }
            writeUsage(io, in_protocol);
            return .failed;
        },
        .watch => |args| args,
    };

    const host = watch_args.host.asString() orelse {
        log.err("host argument must be a string", .{});
        return .failed;
    };
    const port_str = watch_args.port.asString() orelse {
        log.err("port argument must be a string", .{});
        return .failed;
    };
    const port = std.fmt.parseInt(u16, port_str, 10) catch {
        log.err("invalid port number '{s}'", .{port_str});
        return .failed;
    };

    var resolved = resolveDirArg(io, gpa, watch_args.dir) catch |err| {
        log.err("failed to open served directory: {s}", .{@errorName(err)});
        return .failed;
    };
    defer {
        resolved.dir.close(io);
        gpa.free(resolved.path);
    }

    try runWatchServer(
        gpa,
        io,
        open_browser_path,
        host,
        port,
        resolved.dir,
        resolved.path,
        protocol_state,
        null,
    );
    return .ok;
}

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;

    var args_it = try init.minimal.args.iterateAllocator(gpa);
    defer args_it.deinit();

    // Skip argv[0] (executable path).
    _ = args_it.next();

    var os_args: std.ArrayList([]const u8) = .empty;
    defer {
        for (os_args.items) |s| gpa.free(s);
        os_args.deinit(gpa);
    }

    var is_protocol = false;
    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--listen=-")) {
            is_protocol = true;
            continue;
        }
        try os_args.append(gpa, try gpa.dupe(u8, arg));
    }

    const open_browser_path = init.environ_map.get("ZIG_DEVSERVER_OPEN_BROWSER");

    if (!is_protocol) {
        const cmd_args = try gpa.alloc(CmdArg, os_args.items.len);
        defer gpa.free(cmd_args);
        for (os_args.items, 0..) |s, idx| {
            cmd_args[idx] = .{ .string = s };
        }
        const status = dispatchCommand(gpa, io, open_browser_path, cmd_args, null) catch |err| {
            log.err("server error: {s}", .{@errorName(err)});
            return 1;
        };
        return switch (status) {
            .ok => 0,
            .failed => 1,
        };
    }

    const no_color = if (init.environ_map.get("NO_COLOR")) |v| v.len != 0 else false;
    initTtyLog(io, no_color);
    defer deinitTtyLog();

    var stdin_buf: [4096]u8 = undefined;
    var stdout_buf: [4096]u8 = undefined;
    var stdin_reader = Io.File.stdin().readerStreaming(io, &stdin_buf);
    var stdout_writer = Io.File.stdout().writerStreaming(io, &stdout_buf);

    var session = Protocol.Session.init(&stdin_reader.interface, &stdout_writer.interface);
    const handshake = session.handshake(gpa) catch |err| {
        log.err("protocol handshake failed: {s}", .{@errorName(err)});
        return 1;
    };

    switch (handshake) {
        .exit => return 0,
        .run => |run| {
            defer Protocol.deinitArgs(gpa, run.args);

            const cmd_args = fromProtocolArgs(io, gpa, run.args) catch {
                session.finish(run.test_index, .fail) catch {};
                return 0;
            };
            defer deinitCmdArgs(io, gpa, cmd_args);

            var protocol_finished = false;
            const status = dispatchCommand(gpa, io, open_browser_path, cmd_args, .{
                .session = &session,
                .test_index = run.test_index,
                .finished = &protocol_finished,
            }) catch |err| {
                log.err("server error: {s}", .{@errorName(err)});
                if (!protocol_finished) {
                    session.finish(run.test_index, .fail) catch {};
                }
                return 0;
            };

            // For non-serving commands like `help` or invalid args, `runWatchServer` never
            // ran, so report the test result and complete `.exit` handshake cleanly.
            if (!protocol_finished) {
                session.finish(run.test_index, switch (status) {
                    .ok => .pass,
                    .failed => .fail,
                }) catch {};
            }
            return 0;
        },
    }
}

fn runWatchForTest(
    gpa: std.mem.Allocator,
    io: Io,
    host: []const u8,
    port: u16,
    public_dir: Io.Dir,
    public_path: []const u8,
    ready_state: *ReadyState,
) void {
    runWatchServer(gpa, io, null, host, port, public_dir, public_path, null, ready_state) catch |err| {
        log.err("test server failed: {s}", .{@errorName(err)});
    };
}

test {
    _ = Request;
    _ = Protocol;
    _ = Watcher;
}

test "parseCommand removes serve and defaults --listen=- to watch" {
    const cli_serve = [_]CmdArg{
        .{ .string = "serve" },
        .{ .string = "127.0.0.1" },
        .{ .string = "8080" },
        .{ .string = "." },
    };
    try std.testing.expectEqual(ParsedCommand{ .invalid = .serve_removed }, parseCommand(false, &cli_serve));
    try std.testing.expectEqual(ParsedCommand{ .invalid = .serve_removed }, parseCommand(true, &cli_serve));

    const proto_implicit = [_]CmdArg{
        .{ .string = "127.0.0.1" },
        .{ .string = "8080" },
        .{ .string = "." },
    };
    try std.testing.expectEqual(ParsedCommand{ .invalid = .unknown_command }, parseCommand(false, &proto_implicit));
    switch (parseCommand(true, &proto_implicit)) {
        .watch => |w| {
            try std.testing.expectEqualStrings("127.0.0.1", w.host.asString().?);
            try std.testing.expectEqualStrings("8080", w.port.asString().?);
            try std.testing.expectEqualStrings(".", w.dir.asString().?);
        },
        else => return error.UnexpectedParsedCommand,
    }

    const explicit_watch = [_]CmdArg{
        .{ .string = "watch" },
        .{ .string = "127.0.0.1" },
        .{ .string = "8080" },
        .{ .string = "." },
    };
    try std.testing.expect(parseCommand(false, &explicit_watch) == .watch);
    try std.testing.expect(parseCommand(true, &explicit_watch) == .watch);

    const help_arg = [_]CmdArg{.{ .string = "help" }};
    try std.testing.expect(parseCommand(false, &help_arg) == .help);
    try std.testing.expect(parseCommand(true, &help_arg) == .help);
}

test "runWatchServer handles GET HTML injection, directory listing, and POST shutdown cleanly" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "sub");
    try tmp.dir.writeFile(io, .{
        .sub_path = "sub/page.html",
        .data = "<html><head></head><body><h1>hello</h1></body></html>",
    });

    var ready: ReadyState = .{};
    const path = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(path);

    const server_thread = try std.Thread.spawn(.{}, runWatchForTest, .{
        gpa,
        io,
        "127.0.0.1",
        0,
        tmp.dir,
        path,
        &ready,
    });
    defer server_thread.join();

    while (ready.state.load(.acquire) == 0) {
        io.futexWaitUncancelable(u32, &ready.state.raw, 0);
    }
    const ready_val = ready.state.load(.acquire);
    if (ready_val == 1) return error.TestServerStartupFailed;

    const port: u16 = @intCast(ready_val & 0xffff);
    const addr: Io.net.IpAddress = .{ .ip4 = .loopback(port) };

    // 1. Directory listing on `/`.
    {
        const stream = try addr.connect(io, .{ .mode = .stream });
        defer stream.close(io);

        var send_buf: [512]u8 = undefined;
        var recv_buf: [4096]u8 = undefined;
        var writer = stream.writer(io, &send_buf);
        var reader = stream.reader(io, &recv_buf);

        try writer.interface.writeAll("GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n");
        try writer.interface.flush();

        const resp = try reader.interface.allocRemaining(gpa, .limited(64 * 1024));
        defer gpa.free(resp);

        try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 200 OK"));
        try std.testing.expect(std.mem.indexOf(u8, resp, "sub") != null);
    }

    // 2. HTML file with injected devserver API script.
    {
        const stream = try addr.connect(io, .{ .mode = .stream });
        defer stream.close(io);

        var send_buf: [512]u8 = undefined;
        var recv_buf: [4096]u8 = undefined;
        var writer = stream.writer(io, &send_buf);
        var reader = stream.reader(io, &recv_buf);

        try writer.interface.writeAll("GET /sub/page.html HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n");
        try writer.interface.flush();

        const resp = try reader.interface.allocRemaining(gpa, .limited(64 * 1024));
        defer gpa.free(resp);

        try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 200 OK"));
        try std.testing.expect(std.mem.indexOf(u8, resp, "<h1>hello</h1>") != null);
        try std.testing.expect(std.mem.indexOf(u8, resp, Request.Api.injected_js) != null);
    }

    // 3. Shutdown via API stops both HTTP server and watcher thread.
    try std.testing.expect(try notifyExistingServer(gpa, io, addr));
}

test "fromProtocolArgs reopens input_dir handles and writes formatted logs" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const sub_handle = try tmp.dir.openDir(io, ".", .{ .iterate = false });
    const proto_args = [_]Protocol.Arg{
        .{ .string = "watch" },
        .{ .input_dir = .{ .handle = sub_handle } },
    };

    const cmd_args = try fromProtocolArgs(io, gpa, &proto_args);
    defer deinitCmdArgs(io, gpa, cmd_args);

    try std.testing.expectEqual(@as(usize, 2), cmd_args.len);
    try std.testing.expectEqualStrings("watch", cmd_args[0].asString().?);

    var resolved = try resolveDirArg(io, gpa, cmd_args[1]);
    defer {
        resolved.dir.close(io);
        gpa.free(resolved.path);
    }
    try std.testing.expect(resolved.path.len > 0);

    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try writeFormattedLog(&aw.writer, false, .info, .default, "ready {d}", .{8080});
    try std.testing.expectEqualStrings("info: ready 8080\n", aw.written());
}
