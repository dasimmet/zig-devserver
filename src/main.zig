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
    \\Usage: devserver [options] <command> [args]
    \\
    \\Commands:
    \\  watch <host> <port> <directory>   Serve files and watch for in-process changes
    \\  help, -h, --help                  Show this help message
    \\
    \\Options:
    \\  --devtools                        Enable Chrome DevTools workspace on served directory
    \\  --devtools-dir <directory>        Enable Chrome DevTools workspace on custom directory
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

fn listenServerSocket(io: Io, address: *const Io.net.IpAddress) !Io.net.Server {
    // On Windows, `reuse_address = false` already allows rebinding past `TIME_WAIT`
    // without enabling WinSock `SO_REUSEADDR` port hijacking. On POSIX (Linux/macOS),
    // `Io.net.IpAddress.listen` bundles `SO_REUSEPORT` with `SO_REUSEADDR`, so we
    // configure `SO_REUSEADDR` alone: restarts past `TIME_WAIT` succeed while
    // concurrent live binds still fail with `AddressInUse`.
    if (builtin.os.tag == .windows) {
        return address.listen(io, .{ .reuse_address = false });
    }

    const posix = std.posix;
    const is_darwin = builtin.os.tag.isDarwin();
    const family: posix.sa_family_t = switch (address.*) {
        .ip4 => posix.AF.INET,
        .ip6 => posix.AF.INET6,
    };
    const sock_type: u32 = posix.SOCK.STREAM | if (is_darwin or builtin.os.tag == .haiku) 0 else posix.SOCK.CLOEXEC;
    const rc = posix.system.socket(family, sock_type, posix.IPPROTO.TCP);
    const fd: posix.fd_t = switch (posix.errno(rc)) {
        .SUCCESS => @intCast(rc),
        .AFNOSUPPORT => return error.AddressFamilyUnsupported,
        .MFILE => return error.ProcessFdQuotaExceeded,
        .NFILE => return error.SystemFdQuotaExceeded,
        .NOBUFS, .NOMEM => return error.SystemResources,
        else => |e| return posix.unexpectedErrno(e),
    };
    errdefer {
        const s: Io.net.Socket = .{ .handle = fd, .address = address.* };
        s.close(io);
    }

    if (is_darwin or builtin.os.tag == .haiku) {
        switch (posix.errno(posix.system.fcntl(fd, posix.F.SETFD, @as(usize, posix.FD_CLOEXEC)))) {
            .SUCCESS => {},
            else => |e| return posix.unexpectedErrno(e),
        }
    }

    const enable: c_int = 1;
    try posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, std.mem.asBytes(&enable));

    const SockAddr = extern union {
        any: posix.sockaddr,
        in: posix.sockaddr.in,
        in6: posix.sockaddr.in6,
    };
    var storage: SockAddr = undefined;
    var addr_len: posix.socklen_t = switch (address.*) {
        .ip4 => |ip4| blk: {
            const addr_raw: *align(1) const u32 = @ptrCast(&ip4.bytes);
            storage.in = .{
                .port = std.mem.nativeToBig(u16, ip4.port),
                .addr = addr_raw.*,
            };
            break :blk @sizeOf(posix.sockaddr.in);
        },
        .ip6 => |ip6| blk: {
            storage.in6 = .{
                .port = std.mem.nativeToBig(u16, ip6.port),
                .flowinfo = ip6.flow,
                .addr = ip6.bytes,
                .scope_id = ip6.interface.index,
            };
            break :blk @sizeOf(posix.sockaddr.in6);
        },
    };

    while (true) {
        switch (posix.errno(posix.system.bind(fd, &storage.any, addr_len))) {
            .SUCCESS => break,
            .INTR => continue,
            .ADDRINUSE => return error.AddressInUse,
            .ACCES => return error.AccessDenied,
            .ADDRNOTAVAIL => return error.AddressUnavailable,
            else => |e| return posix.unexpectedErrno(e),
        }
    }

    while (true) {
        switch (posix.errno(posix.system.listen(fd, 128))) {
            .SUCCESS => break,
            .INTR => continue,
            .ADDRINUSE => return error.AddressInUse,
            else => |e| return posix.unexpectedErrno(e),
        }
    }

    addr_len = @sizeOf(SockAddr);
    while (true) {
        switch (posix.errno(posix.system.getsockname(fd, &storage.any, &addr_len))) {
            .SUCCESS => break,
            .INTR => continue,
            else => |e| return posix.unexpectedErrno(e),
        }
    }

    const bound: Io.net.IpAddress = switch (storage.any.family) {
        posix.AF.INET => .{ .ip4 = .{
            .port = std.mem.bigToNative(u16, storage.in.port),
            .bytes = @as(*const [4]u8, @ptrCast(&storage.in.addr)).*,
        } },
        posix.AF.INET6 => .{ .ip6 = .{
            .port = std.mem.bigToNative(u16, storage.in6.port),
            .bytes = storage.in6.addr,
            .flow = storage.in6.flowinfo,
            .interface = .{ .index = storage.in6.scope_id },
        } },
        else => address.*,
    };

    return .{
        .socket = .{
            .handle = fd,
            .address = bound,
        },
        .options = {},
    };
}

fn runWatchServer(
    gpa: std.mem.Allocator,
    io: Io,
    open_browser_path: ?[]const u8,
    host: []const u8,
    port: u16,
    public_dir: Io.Dir,
    public_path: []const u8,
    devtools_workspace: ?Request.Api.DevToolsWorkspace,
    protocol_state: ?ProtocolSessionState,
    ready_state: ?*ReadyState,
) !void {
    errdefer if (ready_state) |r| r.notifyFailed(io);

    const resolved = try Io.net.IpAddress.resolve(io, host, port);
    var tcp_server = try listenServerSocket(io, &resolved);
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
        public_path,
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
    if (devtools_workspace) |ws| {
        log.info("Chrome DevTools workspace: {s} (uuid={s})", .{ ws.root, &ws.uuid });
    }
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
            .devtools_workspace = devtools_workspace,
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

const DevToolsOption = union(enum) {
    disabled,
    served_dir,
    custom_dir: CmdArg,
};

const ParsedCommand = union(enum) {
    help,
    watch: struct {
        host: CmdArg,
        port: CmdArg,
        dir: CmdArg,
        devtools: DevToolsOption = .disabled,
    },
    invalid: enum {
        empty,
        non_string_command,
        serve_removed,
        missing_devtools_dir,
        unknown_option,
        expected_protocol_args,
        unknown_command,
        expected_watch_args,
    },
};

fn parseCommand(in_protocol: bool, cmd_args: []const CmdArg) ParsedCommand {
    if (cmd_args.len == 0) return .{ .invalid = .empty };

    var devtools: DevToolsOption = .disabled;
    var pos: [4]CmdArg = undefined;
    var pos_len: usize = 0;
    var total_pos: usize = 0;

    var i: usize = 0;
    while (i < cmd_args.len) : (i += 1) {
        const arg = cmd_args[i];
        if (arg.asString()) |s| {
            if (isHelpCommand(s)) return .help;
            if (std.mem.eql(u8, s, "--devtools")) {
                devtools = .served_dir;
                continue;
            }
            if (std.mem.eql(u8, s, "--devtools-dir")) {
                if (i + 1 >= cmd_args.len) return .{ .invalid = .missing_devtools_dir };
                i += 1;
                devtools = .{ .custom_dir = cmd_args[i] };
                continue;
            }
            if (std.mem.startsWith(u8, s, "--devtools-dir=")) {
                const val = s["--devtools-dir=".len..];
                if (val.len == 0) return .{ .invalid = .missing_devtools_dir };
                devtools = .{ .custom_dir = .{ .string = val } };
                continue;
            }
            if (std.mem.startsWith(u8, s, "-")) {
                return .{ .invalid = .unknown_option };
            }
        }
        if (pos_len < pos.len) {
            pos[pos_len] = arg;
            pos_len += 1;
        }
        total_pos += 1;
    }

    if (total_pos == 0) return .{ .invalid = .empty };

    const first = pos[0].asString() orelse return .{ .invalid = .non_string_command };
    if (std.mem.eql(u8, first, "serve")) return .{ .invalid = .serve_removed };

    // When `--listen=-` is provided, always run the watch command: accept either explicit
    // `watch <host> <port> <directory>` (4 args) or `<host> <port> <directory>` (3 args).
    if (in_protocol and !std.mem.eql(u8, first, "watch")) {
        if (total_pos != 3) return .{ .invalid = .expected_protocol_args };
        return .{ .watch = .{
            .host = pos[0],
            .port = pos[1],
            .dir = pos[2],
            .devtools = devtools,
        } };
    }

    if (!std.mem.eql(u8, first, "watch")) return .{ .invalid = .unknown_command };
    if (total_pos != 4) return .{ .invalid = .expected_watch_args };

    return .{ .watch = .{
        .host = pos[1],
        .port = pos[2],
        .dir = pos[3],
        .devtools = devtools,
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
                .missing_devtools_dir => log.err("--devtools-dir requires a directory argument", .{}),
                .unknown_option => log.err("unknown option in arguments", .{}),
                .expected_protocol_args => log.err("expected 3 or 4 positional arguments in --listen=- mode: [watch] <host> <port> <directory>", .{}),
                .unknown_command => log.err("unknown command", .{}),
                .expected_watch_args => log.err("expected 4 positional arguments: watch <host> <port> <directory>", .{}),
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

    const devtools_workspace: ?Request.Api.DevToolsWorkspace = switch (watch_args.devtools) {
        .disabled => null,
        .served_dir => try Request.Api.DevToolsWorkspace.init(gpa, resolved.path),
        .custom_dir => |dt_arg| blk: {
            var dt_resolved = resolveDirArg(io, gpa, dt_arg) catch |err| {
                log.err("failed to open devtools workspace directory: {s}", .{@errorName(err)});
                return .failed;
            };
            dt_resolved.dir.close(io);
            defer gpa.free(dt_resolved.path);
            break :blk try Request.Api.DevToolsWorkspace.init(gpa, dt_resolved.path);
        },
    };
    defer if (devtools_workspace) |ws| ws.deinit(gpa);

    try runWatchServer(
        gpa,
        io,
        open_browser_path,
        host,
        port,
        resolved.dir,
        resolved.path,
        devtools_workspace,
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
    devtools_workspace: ?Request.Api.DevToolsWorkspace,
    ready_state: *ReadyState,
) void {
    runWatchServer(gpa, io, null, host, port, public_dir, public_path, devtools_workspace, null, ready_state) catch |err| {
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

    const devtools_served = [_]CmdArg{
        .{ .string = "--devtools" },
        .{ .string = "watch" },
        .{ .string = "127.0.0.1" },
        .{ .string = "0" },
        .{ .string = "." },
    };
    switch (parseCommand(false, &devtools_served)) {
        .watch => |w| try std.testing.expect(w.devtools == .served_dir),
        else => return error.UnexpectedParsedCommand,
    }

    const devtools_custom = [_]CmdArg{
        .{ .string = "--devtools-dir" },
        .{ .string = "src" },
        .{ .string = "127.0.0.1" },
        .{ .string = "0" },
        .{ .string = "." },
    };
    switch (parseCommand(true, &devtools_custom)) {
        .watch => |w| switch (w.devtools) {
            .custom_dir => |arg| try std.testing.expectEqualStrings("src", arg.asString().?),
            else => return error.UnexpectedParsedCommand,
        },
        else => return error.UnexpectedParsedCommand,
    }

    const missing_dt = [_]CmdArg{.{ .string = "--devtools-dir" }};
    try std.testing.expectEqual(ParsedCommand{ .invalid = .missing_devtools_dir }, parseCommand(false, &missing_dt));
}

test "runWatchServer handles GET HTML injection, directory listing, DevTools JSON, and POST shutdown cleanly" {
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

    const devtools_ws = try Request.Api.DevToolsWorkspace.init(gpa, "/custom/workspace/root");
    defer devtools_ws.deinit(gpa);

    const server_thread = try std.Thread.spawn(.{}, runWatchForTest, .{
        gpa,
        io,
        "127.0.0.1",
        0,
        tmp.dir,
        path,
        devtools_ws,
        &ready,
    });
    var joined = false;
    defer if (!joined) server_thread.join();

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

    // 3. Chrome DevTools workspace JSON (`GET` -> 200, `POST` -> 405, static file override).
    {
        const stream = try addr.connect(io, .{ .mode = .stream });
        defer stream.close(io);

        var send_buf: [512]u8 = undefined;
        var recv_buf: [4096]u8 = undefined;
        var writer = stream.writer(io, &send_buf);
        var reader = stream.reader(io, &recv_buf);

        try writer.interface.writeAll(
            "GET /.well-known/appspecific/com.chrome.devtools.json?check=1 HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
        );
        try writer.interface.flush();

        const resp = try reader.interface.allocRemaining(gpa, .limited(64 * 1024));
        defer gpa.free(resp);

        try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 200 OK"));
        try std.testing.expect(std.mem.indexOf(u8, resp, "\"/custom/workspace/root\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, resp, &devtools_ws.uuid) != null);
    }
    {
        const stream = try addr.connect(io, .{ .mode = .stream });
        defer stream.close(io);

        var send_buf: [512]u8 = undefined;
        var recv_buf: [4096]u8 = undefined;
        var writer = stream.writer(io, &send_buf);
        var reader = stream.reader(io, &recv_buf);

        try writer.interface.writeAll(
            "POST /.well-known/appspecific/com.chrome.devtools.json HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        );
        try writer.interface.flush();

        const resp = try reader.interface.allocRemaining(gpa, .limited(64 * 1024));
        defer gpa.free(resp);

        try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 405"));
    }

    // 4. Concurrent port reuse is disallowed (`AddressInUse`), while immediate rebind
    // after shutdown succeeds even with prior TCP connections in `TIME_WAIT`.
    try std.testing.expectError(error.AddressInUse, listenServerSocket(io, &addr));

    // 5. Shutdown via API stops both HTTP server and watcher thread.
    try std.testing.expect(try sendShutdownForTest(gpa, io, addr));
    server_thread.join();
    joined = true;

    var rebound = try listenServerSocket(io, &addr);
    rebound.deinit(io);
}

fn sendShutdownForTest(gpa: std.mem.Allocator, io: Io, target: Io.net.IpAddress) !bool {
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
