// a server request

const std = @import("std");
const mime = @import("mime");
const log = std.log;

pub const Api = @import("Api.zig");

const Request = @This();
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
// timestamp of the server's start
start_time: isize,

pub fn handle(req: *Request) void {
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
    const api = req.handleApi() catch |err| {
        log.warn("Error {s} responding to request from {any} for {s}", .{ @errorName(err), req.conn.address, req.http.head.target });
        return;
    };
    if (api) return;

    req.handleFile() catch |err| {
        log.warn("Error {s} responding to request from {any} for {s}", .{ @errorName(err), req.conn.address, req.http.head.target });
    };
}

const common_headers = [_]std.http.Header{
    .{ .name = "connection", .value = "close" },
    .{ .name = "Cache-Control", .value = "no-cache, no-store, must-revalidate" },
};

fn handleApi(req: *Request) !bool {
    const path = req.http.head.target;
    if (std.mem.eql(u8, path, Api.endpoint)) {
        if (req.http.head.method == .POST) {
            var buf: [4096]u8 = undefined;
            const reader = try req.http.reader();
            const message_size = try reader.readAll(&buf);
            const message_str = buf[0..message_size];
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
                .client_reload_check => {
                    if (msg.value.start_time) |start_time| {
                        if (start_time == req.start_time) {
                            std.Thread.sleep(Api.sleep_time);
                        }
                    } else {
                        std.Thread.sleep(Api.sleep_time);
                    }
                    var res_buf: [64]u8 = undefined;
                    const res = try std.fmt.bufPrint(&res_buf, "{}", .{std.json.fmt(.{
                        .start_time = req.start_time,
                    }, .{})});
                    try req.http.respond(res, .{});
                    return true;
                },
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
    log.info("req: {s}", .{path});

    if (std.mem.eql(u8, path, Api.js_endpoint)) {
        const reload_js = @embedFile("__zig_devserver_api.js");
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
                return req.http.respond(@embedFile("favicon.ico"), .{
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
    if (mime_type == .@"text/html") {
        const content = try file.readToEndAlloc(req.allocator, std.math.maxInt(u32));
        defer req.allocator.free(content);

        var response = req.http.respondStreaming(.{
            .send_buffer = try req.allocator.alloc(u8, content.len + Api.injected_js.len),
            // .content_length = metadata.size(),
            .respond_options = .{
                .extra_headers = &([_]std.http.Header{
                    .{ .name = "content-type", .value = content_type },
                } ++ common_headers),
            },
        });
        if (std.mem.indexOf(u8, content, "<head>")) |head_idx| {
            const post_head_pos = head_idx + "<head>".len;
            _ = try response.writer().write(content[0..post_head_pos]);
            _ = try response.writer().write(Api.injected_js);
            _ = try response.writer().write(content[post_head_pos..]);
        } else {
            log.warn("<head> not found in html: {s}\ncannot inject reload js", .{path});
            _ = try response.writer().write(content);
        }
        return response.end();
    }

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

fn handleDir(req: *Request, path: []const u8) !void {
    log.info("dir: {s}", .{path});
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

    var response = req.http.respondStreaming(.{
        .send_buffer = try req.allocator.alloc(u8, 4000),
        // .content_length = metadata.size(),
        .respond_options = .{
            .extra_headers = &([_]std.http.Header{
                .{ .name = "content-type", .value = "text/html" },
            } ++ common_headers),
        },
    });
    const style =
        \\:root {
        \\  color-scheme: light dark;
        \\}
    ;
    try response.writeAll("<html><head><style>\n");
    try response.writeAll(style);
    try response.writeAll("\n</style></head><body><ul>\n");
    try response.writeAll("<a href=\".\"><li>.</li></a>");
    try response.writeAll("<a href=\"..\"><li>..</li></a>");
    while (try iter.next()) |entry| {
        try response.writeAll("<a href=\"");
        try response.writeAll(entry.name);
        try response.writeAll("\"><li>");
        try response.writeAll(@tagName(entry.kind));
        try response.writeAll(" - ");
        try response.writeAll(entry.name);
        try response.writeAll("</li></a>\n");
    }
    try response.writeAll("</ul></body></html>\n");
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
