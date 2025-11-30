// a server request

const std = @import("std");
const mime = @import("mime");
const log = std.log;

pub const Api = @import("Api.zig");

const Request = @This();
// Fields are in initialization order.
// Initialized by main.
io: std.Io,
gpa: std.mem.Allocator,
public_dir: std.fs.Dir,
public_path: []const u8 = "",
stream: std.Io.net.Stream,
// Initialized by handle.
allocator_arena: std.heap.ArenaAllocator,
allocator: std.mem.Allocator,
http: std.http.Server.Request,

// Not initialized in this code but utilized by http server.
buffer: [1024]u8,
response_buffer: [4000]u8,
// timestamp of the server's start
start_time: std.Io.Timestamp,
ws_running: bool,

pub fn handle(req: *Request) void {
    defer req.gpa.destroy(req);
    defer req.stream.close(req.io);

    req.allocator_arena = std.heap.ArenaAllocator.init(req.gpa);
    defer req.allocator_arena.deinit();
    req.allocator = req.allocator_arena.allocator();

    var send_buffer: [4096]u8 = undefined;
    var recv_buffer: [4096]u8 = undefined;
    var connection_reader = req.stream.reader(req.io, &recv_buffer);
    var connection_writer = req.stream.writer(req.io, &send_buffer);

    var http_server: std.http.Server = .init(&connection_reader.interface, &connection_writer.interface);

    req.http = http_server.receiveHead() catch |err| {
        if (err != error.HttpConnectionClosing) {
            log.err("Error with getting request headers:{s}", .{@errorName(err)});
            // TODO: We're supposed to server an error to the request on some of these
            // error types, but the http server doesn't give us the response to write to,
            // so we're not going to bother doing it manually.
        }
        return;
    };

    switch (req.http.upgradeRequested()) {
        .none => {},
        .other => |upgrade| {
            std.log.err("Unknown Upgrade request: {s}", .{upgrade});
        },
        .websocket => |upgrade| {
            if (upgrade) |key| {
                var web_socket = req.http.respondWebSocket(.{ .key = key }) catch {
                    return log.err("failed to respond web socket: {t}", .{connection_writer.err.?});
                };
                return req.handleWebsocket(&web_socket) catch |err| {
                    return log.err("failed to handle web socket: {}", .{err});
                };
            } else {
                std.log.warn("Websocket connection without id!", .{});
            }
            return;
        },
    }

    const api = req.handleApi() catch |err| {
        log.warn("Error {s} responding to request from {f} for {s}", .{ @errorName(err), req.stream.socket.address, req.http.head.target });
        return;
    };
    if (api) return;

    if (req.handleChromeDevTools() catch |err| {
        log.warn("Error {s} responding to request from {f} for {s}", .{ @errorName(err), req.stream.socket.address, req.http.head.target });
        return;
    }) return;

    req.handleFile() catch |err| {
        log.warn("Error {s} responding to request from {f} for {s}", .{ @errorName(err), req.stream.socket.address, req.http.head.target });
    };
}

const common_headers = [_]std.http.Header{
    .{ .name = "connection", .value = "close" },
    .{ .name = "Cache-Control", .value = "no-cache, no-store, must-revalidate" },
};

fn handleWebsocket(req: *Request, sock: *std.http.Server.WebSocket) !void {
    req.ws_running = true;
    const recv_thread = try std.Thread.spawn(.{}, recvWebSocketMessages, .{ req, sock });
    defer recv_thread.join();
    while (req.ws_running) {
        var res_buf: [64]u8 = undefined;
        var bufs: [1][]const u8 = .{
            try std.fmt.bufPrint(&res_buf, "{f}", .{
                std.json.fmt(.{
                    .start_time = req.start_time,
                    .bypass_cache = true,
                }, .{}),
            }),
        };
        try sock.writeMessageVec(&bufs, .text);
        try req.io.sleep(.fromSeconds(5), .awake);
    }
}

fn recvWebSocketMessages(req: *Request, sock: *std.http.Server.WebSocket) void {
    while (true) {
        const msg = sock.readSmallMessage() catch |err| {
            std.log.err("client disconnect: {s} {}", .{ sock.key, err });
            return;
        };
        if (msg.data.len == 0) continue;
        if (msg.opcode == .connection_close) {
            req.ws_running = false;
            return;
        }
        std.log.info("WebSocket msg: {} {s}", .{ msg.opcode, msg.data });
    }
}

fn handleApi(req: *Request) !bool {
    const path = req.http.head.target;
    if (std.mem.eql(u8, path, Api.endpoint)) {
        if (req.http.head.method == .POST) {
            var buf: [4096]u8 = undefined;
            const reader = try req.http.readerExpectContinue(&buf);
            try reader.fillMore();
            const message_str = reader.buffered();
            const msg = try std.json.parseFromSlice(
                Api,
                req.allocator,
                message_str,
                .{},
            );
            switch (msg.value.action) {
                .shutdown => {
                    log.info("api: {s}", .{message_str});
                    try req.http.respond("ok", .{});
                    std.process.exit(0);
                },
                .none => {},
                // else => return error.MessageNotImplemented,
            }
        }
    }
    return false;
}

fn handleFile(req: *Request) !void {
    var path = req.http.head.target;

    if (std.mem.indexOf(u8, path, "..")) |_| {
        req.serveError("'..' not allowed in URLs", .bad_request);

        // TODO: Allow relative paths while ensuring that directories
        // outside of the served directory can never be accessed.
        return error.BadPath;
    }

    var is_dir_index = false;
    if (std.mem.endsWith(u8, path, "/")) {
        path = try std.fmt.allocPrint(req.allocator, "{s}{s}", .{
            path,
            "index.html",
        });
        is_dir_index = true;
    }

    if (path.len < 1 or path[0] != '/') {
        req.serveError("bad request path.", .bad_request);
        return error.BadPath;
    }

    if (std.mem.eql(u8, path, Api.js_endpoint)) {
        const reload_js = Api.embedded.js;
        const ts = try std.Io.Clock.real.now(req.io);
        log.debug("{d}: {s} - {s}", .{ ts.toSeconds(), path, "application/javascript" });
        return req.http.respond(reload_js, .{
            .extra_headers = &([_]std.http.Header{
                .{ .name = "content-type", .value = "application/javascript" },
            } ++ common_headers),
        });
    }
    path = path[1 .. std.mem.indexOfScalar(u8, path, '?') orelse path.len];

    const mime_type = mime.extension_map.get(std.fs.path.extension(path)) orelse
        .@"application/octet-stream";

    const file = req.public_dir.openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            if (is_dir_index) {
                return req.handleDir(std.fs.path.dirname(path) orelse ".");
            }
            if (std.mem.eql(u8, path, "favicon.ico")) {
                const ts = try std.Io.Clock.real.now(req.io);
                log.info("{d}: {s} - {s}", .{ ts.toSeconds(), path, "image/x-icon" });
                return req.http.respond(Api.embedded.favicon, .{
                    .extra_headers = &([_]std.http.Header{
                        .{ .name = "content-type", .value = "image/x-icon" },
                    } ++ common_headers),
                });
            }
            req.serveError(null, .not_found);
            return err;
        },
        error.IsDir => {
            return req.handleDir(path);
        },
        else => {
            req.serveError("accessing resource", .internal_server_error);
            return err;
        },
    };
    defer file.close();

    const stat: std.fs.File.Stat = file.stat() catch |err| {
        req.serveError("accessing resource", .internal_server_error);
        return err;
    };

    if (stat.kind == .directory) {
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
    const ts = try std.Io.Clock.real.now(req.io);
    log.info("{d}: {s} - {s}", .{ ts.toSeconds(), path, content_type });

    if (mime_type == .@"text/html") {
        var content_reader = file.reader(req.io, &.{});
        const content = try content_reader.interface.allocRemaining(req.allocator, .limited(std.math.maxInt(u32)));
        defer req.allocator.free(content);

        var response = try req.http.respondStreaming(
            try req.allocator.alloc(u8, content.len + Api.injected_js.len),
            .{
                .respond_options = .{
                    .extra_headers = &([_]std.http.Header{
                        .{ .name = "content-type", .value = content_type },
                    } ++ common_headers),
                },
            },
        );
        if (std.mem.indexOf(u8, content, "<head>")) |head_idx| {
            const post_head_pos = head_idx + "<head>".len;
            try response.writer.writeAll(content[0..post_head_pos]);
            try response.writer.writeAll(Api.injected_js);
            try response.writer.writeAll(content[post_head_pos..]);
        } else {
            log.warn("<head> not found in html: {s}\ncannot inject reload js", .{path});
            try response.writer.writeAll(content);
        }
        return response.end();
    }

    var response = try req.http.respondStreaming(
        try req.allocator.alloc(u8, 4000),
        .{
            .respond_options = .{
                .extra_headers = &([_]std.http.Header{
                    .{ .name = "content-type", .value = content_type },
                } ++ common_headers),
            },
        },
    );
    var file_reader = file.reader(req.io, &.{});
    _ = try response.writer.sendFileAll(&file_reader, .unlimited);

    return response.end();
}

fn handleChromeDevTools(req: *Request) !bool {
    const path = req.http.head.target;
    if (std.mem.eql(u8, path, "/.well-known/appspecific/com.chrome.devtools.json")) {
        const ts = try std.Io.Clock.real.now(req.io);
        log.info("{d}: chrome devtools: {s} - {s}", .{ ts.toSeconds(), path, "application/json" });
        var buf: [8196]u8 = undefined;
        const res = try std.fmt.bufPrint(&buf, "{f}\n", .{std.json.fmt(.{
            .workspace = .{
                .root = req.public_path,
                .uuid = "6ec0bd7f-11c0-43da-975e-2a8ad9ebae0b",
            },
        }, .{
            .whitespace = .indent_4,
        })});
        try req.http.respond(res, .{ .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
        } });
        return true;
    }
    return false;
}

fn handleDir(req: *Request, path: []const u8) !void {
    const ts = try std.Io.Clock.real.now(req.io);
    log.info("{d}: {s}", .{ ts.toSeconds(), path });

    const dir = req.public_dir.openDir(path, .{
        .iterate = true,
    }) catch |err| switch (err) {
        error.FileNotFound => {
            req.serveError(null, .not_found);
            return err;
        },
        else => return err,
    };

    var iter = dir.iterate();

    var res = try req.http.respondStreaming(
        try req.allocator.alloc(u8, 4000),
        .{
            .respond_options = .{
                .extra_headers = &([_]std.http.Header{
                    .{ .name = "content-type", .value = "text/html; charset=utf-8" },
                } ++ common_headers),
            },
        },
    );
    const response = &res.writer;
    const style =
        \\:root {
        \\  color-scheme: light dark;
        \\}
    ;
    try response.writeAll("<html><head><script src=\"");
    try response.writeAll(Api.js_endpoint);
    try response.writeAll("\"></script><style>\n");
    try response.writeAll(style);
    try response.writeAll("\n</style></head><body>\n");
    try response.writeAll("<h2>Directory Listing - ");
    if (std.mem.eql(u8, ".", path)) {
        try response.writeAll("/");
    } else {
        try response.writeAll(path);
    }
    try response.writeAll("</h2>\n<ul style=\"width: max-content;\">\n");
    try response.writeAll("<a href=\".\"><li>.</li></a>");
    if (!std.mem.eql(u8, path, ".")) {
        try response.writeAll("<a href=\"..\"><li>..</li></a>");
    }
    while (try iter.next()) |entry| {
        switch (entry.kind) {
            .directory, .file, .sym_link => {},
            else => continue,
        }
        try response.writeAll("<a href=\"");
        try response.writeAll(entry.name);
        try response.writeAll("\"><li>");
        try response.writeAll(switch (entry.kind) {
            .directory => "📁",
            .file => "🗎",
            .sym_link => "🔗",
            else => unreachable,
        });
        try response.writeAll(" ");
        try response.writeAll(entry.name);
        try response.writeAll("</li></a>\n");
    }
    try response.writeAll("</ul></body></html>\n");
    return res.end();
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
