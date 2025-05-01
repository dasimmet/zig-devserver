const std = @import("std");
const mime = @import("mime");

pub const std_options: std.Options = .{
    .log_level = .info,
};
const log = std.log;

var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{}){};

pub fn main() !void {
    const gpa = general_purpose_allocator.allocator();
    const args = try std.process.argsAlloc(gpa);
    log.info("server args: {s}", .{args});

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
        .{ "serve", startServer },
        .{ "notify", notifyServer },
    }) |cmd| {
        if (std.mem.eql(u8, args[1], cmd[0])) {
            return cmd[1](gpa, args[2..]);
        }
    }
    std.log.err("unknown subcommand: {s}", .{args[1]});
    try usage(gpa, args[2..]);
    std.process.exit(1);
}

pub fn usage(gpa: std.mem.Allocator, args: []const [:0]const u8) !void {
    _ = gpa;
    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll("args: ");
    for (args) |arg| {
        try stdout.print("{s} ", .{arg});
    }
    try stdout.writeAll(
        \\usage: devserver {-h|--help|-?|help|serve|notify} [subcommand args]
        \\
        \\subcommand usage:
        \\  serve {port} {directory}
        \\  notify
        \\  help
        \\
    );
}

pub fn notifyServer(gpa: std.mem.Allocator, args: []const [:0]const u8) !void {
    _ = gpa;
    _ = args;
    @panic("TODO: notify is not implemented yet");
}

pub fn startServer(gpa: std.mem.Allocator, args: []const [:0]const u8) !void {
    if (args.len != 2) {
        return error.IncorrectNumberOfArguments;
    }

    const port = std.fmt.parseInt(u16, args[0], 10) catch |err| failWithError("Parse port", err);
    const root_dir_path = args[1];

    var root_dir: std.fs.Dir = std.fs.cwd().openDir(root_dir_path, .{}) catch |err| failWithError("Open serving directory", err);
    defer root_dir.close();

    var request_pool: std.Thread.Pool = undefined;
    request_pool.init(.{
        .allocator = gpa,
    }) catch |err| failWithError("Start webserver threads", err);

    const address = std.net.Address.parseIp("127.0.0.1", port) catch |err| failWithError("obtain ip", err);
    var tcp_server = address.listen(.{
        .reuse_port = true,
        .reuse_address = true,
    }) catch |err| failWithError("listen", err);
    defer tcp_server.deinit();

    log.warn("\x1b[2K\rServing website at http://{any}/\n", .{tcp_server.listen_address.in});

    accept: while (true) {
        const request = gpa.create(Request) catch |err| {
            failWithError("allocating request", err);
        };
        request.gpa = gpa;
        request.public_dir = root_dir;
        request.conn = tcp_server.accept() catch |err| {
            switch (err) {
                error.ConnectionAborted, error.ConnectionResetByPeer => {
                    log.warn("{s} on lister accept", .{@errorName(err)});
                    gpa.destroy(request);
                    continue :accept;
                },
                else => {},
            }
            failWithError("accept connection", err);
        };

        request_pool.spawn(Request.handle, .{request}) catch |err| {
            log.err("Error spawning request response thread: {s}", .{@errorName(err)});
            request.conn.stream.close();
            gpa.destroy(request);
        };
    }
}

fn failWithError(operation: []const u8, err: anyerror) noreturn {
    std.log.err("Unrecoverable Failure: {s} encountered error {s}.", .{ operation, @errorName(err) });
    std.process.exit(1);
}

const Request = struct {
    // Fields are in initialization order.
    // Initialized by main.
    gpa: std.mem.Allocator,
    public_dir: std.fs.Dir,
    conn: std.net.Server.Connection,
    // Initialized by handle.
    allocator_arena: std.heap.ArenaAllocator,
    allocator: std.mem.Allocator,
    http: std.http.Server.Request,

    // Not initialized in this code but utilized by http server.
    buffer: [1024]u8,
    response_buffer: [4000]u8,

    fn handle(req: *Request) void {
        defer req.gpa.destroy(req);
        defer req.conn.stream.close();

        req.allocator_arena = std.heap.ArenaAllocator.init(req.gpa);
        defer req.allocator_arena.deinit();
        req.allocator = req.allocator_arena.allocator();

        var http_server = std.http.Server.init(req.conn, &req.buffer);
        req.http = http_server.receiveHead() catch |err| {
            if (err != error.HttpConnectionClosing) {
                log.err("Error with getting request headers:{s}", .{@errorName(err)});
                // TODO: We're supposed to server an error to the request on some of these
                // error types, but the http server doesn't give us the response to write to,
                // so we're not going to bother doing it manually.
            }
            return;
        };
        req.handleFile() catch |err| {
            log.warn("Error {s} responding to request from {any} for {s}", .{ @errorName(err), req.conn.address, req.http.head.target });
        };
    }

    const common_headers = [_]std.http.Header{
        .{ .name = "connection", .value = "close" },
        .{ .name = "Cache-Control", .value = "no-cache, no-store, must-revalidate" },
    };

    fn handleFile(req: *Request) !void {
        var path = req.http.head.target;

        if (std.mem.indexOf(u8, path, "..")) |_| {
            req.serveError("'..' not allowed in URLs", .bad_request);

            // TODO: Allow relative paths while ensuring that directories
            // outside of the served directory can never be accessed.
            return error.BadPath;
        }

        if (std.mem.endsWith(u8, path, "/")) {
            path = try std.fmt.allocPrint(req.allocator, "{s}{s}", .{
                path,
                "index.html",
            });
        }

        if (path.len < 1 or path[0] != '/') {
            req.serveError("bad request path.", .bad_request);
            return error.BadPath;
        }

        path = path[1 .. std.mem.indexOfScalar(u8, path, '?') orelse path.len];

        const mime_type = mime.extension_map.get(std.fs.path.extension(path)) orelse
            .@"application/octet-stream";

        const file = req.public_dir.openFile(path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                req.serveError(null, .not_found);
                if (std.mem.eql(u8, path, "favicon.ico")) {
                    return; // Surpress error logging.
                }
                return err;
            },
            else => {
                req.serveError("accessing resource", .internal_server_error);
                return err;
            },
        };
        defer file.close();

        const metadata = file.metadata() catch |err| {
            req.serveError("accessing resource", .internal_server_error);
            return err;
        };
        if (metadata.kind() == .directory) {
            const location = try std.fmt.allocPrint(
                req.allocator,
                "{s}/",
                .{req.http.head.target},
            );
            try req.http.respond("redirecting...", .{
                .status = .see_other,
                .extra_headers = &([_]std.http.Header{
                    .{ .name = "location", .value = location },
                    .{ .name = "content-type", .value = "text/html" },
                } ++ common_headers),
            });
            return;
        }

        const content_type = switch (mime_type) {
            inline else => |mt| blk: {
                if (std.mem.startsWith(u8, @tagName(mt), "text")) {
                    break :blk @tagName(mt) ++ "; charset=utf-8";
                }
                break :blk @tagName(mt);
            },
        };

        var response = req.http.respondStreaming(.{
            .send_buffer = try req.allocator.alloc(u8, 4000),
            // .content_length = metadata.size(),
            .respond_options = .{
                .extra_headers = &([_]std.http.Header{
                    .{ .name = "content-type", .value = content_type },
                } ++ common_headers),
            },
        });
        try response.writer().writeFile(file);
        return response.end();
    }

    fn serveError(req: *Request, comptime reason: ?[]const u8, comptime status: std.http.Status) void {
        const sep = if (reason) |_| ": " else ".";
        const text = std.fmt.comptimePrint("{d} {s}{s}{s}", .{ @intFromEnum(status), comptime status.phrase().?, sep, reason orelse "" });
        req.http.respond(text, .{
            .status = status,
            .extra_headers = &([_]std.http.Header{
                .{ .name = "content-type", .value = "text/text" },
            } ++ common_headers),
        }) catch |err| {
            log.warn("Error {s} serving error text {s}", .{ @errorName(err), text });
        };
    }
};
