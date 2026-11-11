//! Build runner IPC protocol support for `Run.stdio = .protocol`.
//!
//! When a build step sets `run.stdio = .protocol`, Zig's `Maker` spawns the
//! child with `--listen=-`, sends the step's arguments via `Client.Message.Tag.args`,
//! and drives the test-runner IPC state machine over `stdin`/`stdout`.

const std = @import("std");
const builtin = @import("builtin");

const Io = std.Io;
const Client = std.zig.Client;
const Server = std.zig.Server;

const Protocol = @This();

/// A single decoded item from `std.zig.Client.Message.Tag.args`.
pub const Arg = union(enum) {
    string: []const u8,
    input_dir: Handle(Io.Dir),
    input_file: Handle(Io.File),
    output_dir: Handle(Io.Dir),
    output_file: Handle(Io.File),

    pub fn Handle(comptime T: type) type {
        return struct {
            handle: T,
            prefix: []const u8 = "",
            suffix: []const u8 = "",
        };
    }

    pub fn setSuffix(self: *Arg, suffix: []const u8) bool {
        switch (self.*) {
            .string => return false,
            inline .input_dir, .input_file, .output_dir, .output_file => |*h| {
                if (h.suffix.len != 0) return false;
                h.suffix = suffix;
                return true;
            },
        }
    }
};

pub const DecodeError = error{
    OutOfMemory,
    InvalidProtocolArgs,
};

fn freeArgStrings(gpa: std.mem.Allocator, arg: Arg) void {
    switch (arg) {
        .string => |s| gpa.free(s),
        inline .input_dir, .input_file, .output_dir, .output_file => |h| {
            if (h.prefix.len != 0) gpa.free(h.prefix);
            if (h.suffix.len != 0) gpa.free(h.suffix);
        },
    }
}

pub fn deinitArgs(gpa: std.mem.Allocator, args: []const Arg) void {
    for (args) |arg| freeArgStrings(gpa, arg);
    gpa.free(args);
}

fn readHandleBytes(comptime HandleType: type, reader: *Io.Reader) !HandleType {
    const bytes = reader.takeArray(@sizeOf(HandleType)) catch |err| switch (err) {
        error.EndOfStream, error.ReadFailed => return error.InvalidProtocolArgs,
    };
    return std.mem.bytesToValue(HandleType, bytes);
}

fn readSentinelDup(gpa: std.mem.Allocator, reader: *Io.Reader) DecodeError![]const u8 {
    const raw = reader.takeSentinel(0) catch return error.InvalidProtocolArgs;
    return try gpa.dupe(u8, raw);
}

/// Decodes a `Client.Message.Tag.args` payload into a slice of `Arg`.
/// Caller owns the returned memory via `deinitArgs`.
pub fn decodeArgs(gpa: std.mem.Allocator, bytes: []const u8) DecodeError![]Arg {
    var list: std.ArrayList(Arg) = .empty;
    errdefer {
        for (list.items) |arg| freeArgStrings(gpa, arg);
        list.deinit(gpa);
    }

    var reader: Io.Reader = .fixed(bytes);
    var pending_prefix: ?[]const u8 = null;
    errdefer if (pending_prefix) |p| gpa.free(p);

    while (true) {
        const tag_byte = reader.takeByte() catch |err| switch (err) {
            error.EndOfStream => break,
            error.ReadFailed => return error.InvalidProtocolArgs,
        };
        const arg_tag = std.enums.fromInt(Client.Message.Arg, tag_byte) orelse
            return error.InvalidProtocolArgs;

        switch (arg_tag) {
            .string => {
                if (pending_prefix != null) return error.InvalidProtocolArgs;
                const s = try readSentinelDup(gpa, &reader);
                errdefer gpa.free(s);
                try list.append(gpa, .{ .string = s });
            },
            .prefix => {
                if (pending_prefix != null) return error.InvalidProtocolArgs;
                pending_prefix = try readSentinelDup(gpa, &reader);
            },
            .input_dir => try appendDirHandle(gpa, &list, &reader, &pending_prefix, false),
            .output_dir => try appendDirHandle(gpa, &list, &reader, &pending_prefix, true),
            .input_file, .input_file_content => {
                try appendFileHandle(gpa, &list, &reader, &pending_prefix, false);
            },
            .output_file => try appendFileHandle(gpa, &list, &reader, &pending_prefix, true),
            .suffix => {
                if (pending_prefix != null or list.items.len == 0) {
                    return error.InvalidProtocolArgs;
                }
                const suffix = try readSentinelDup(gpa, &reader);
                if (!list.items[list.items.len - 1].setSuffix(suffix)) {
                    gpa.free(suffix);
                    return error.InvalidProtocolArgs;
                }
            },
        }
    }

    if (pending_prefix != null) return error.InvalidProtocolArgs;
    return try list.toOwnedSlice(gpa);
}

fn appendDirHandle(
    gpa: std.mem.Allocator,
    list: *std.ArrayList(Arg),
    reader: *Io.Reader,
    pending_prefix: *?[]const u8,
    is_output: bool,
) DecodeError!void {
    const raw = readHandleBytes(Io.Dir.Handle, reader) catch return error.InvalidProtocolArgs;
    const prefix = pending_prefix.* orelse "";
    pending_prefix.* = null;
    const handle_arg: Arg.Handle(Io.Dir) = .{
        .handle = .{ .handle = raw },
        .prefix = prefix,
    };
    errdefer if (prefix.len != 0) gpa.free(prefix);
    try list.append(gpa, if (is_output)
        .{ .output_dir = handle_arg }
    else
        .{ .input_dir = handle_arg });
}

fn appendFileHandle(
    gpa: std.mem.Allocator,
    list: *std.ArrayList(Arg),
    reader: *Io.Reader,
    pending_prefix: *?[]const u8,
    is_output: bool,
) DecodeError!void {
    const raw = readHandleBytes(Io.File.Handle, reader) catch return error.InvalidProtocolArgs;
    const prefix = pending_prefix.* orelse "";
    pending_prefix.* = null;
    const handle_arg: Arg.Handle(Io.File) = .{
        .handle = .{ .handle = raw, .flags = .{ .nonblocking = false } },
        .prefix = prefix,
    };
    errdefer if (prefix.len != 0) gpa.free(prefix);
    try list.append(gpa, if (is_output)
        .{ .output_file = handle_arg }
    else
        .{ .input_file = handle_arg });
}

/// Manages the child side of `Run.stdio = .protocol` (`std.zig.Server`) and logs
/// all incoming and outgoing protocol messages to `stderr` (or `log_writer` in tests).
pub const Session = struct {
    server: Server,
    log_writer: ?*Io.Writer = null,

    pub const HandshakeResult = union(enum) {
        run: struct {
            args: []Arg,
            test_index: u32,
        },
        exit,
    };

    pub fn init(in: *Io.Reader, out: *Io.Writer) Session {
        return .{
            .server = .{ .in = in, .out = out },
        };
    }

    pub fn initWithLogWriter(in: *Io.Reader, out: *Io.Writer, log_writer: *Io.Writer) Session {
        return .{
            .server = .{ .in = in, .out = out },
            .log_writer = log_writer,
        };
    }

    fn logMsg(self: *const Session, comptime fmt: []const u8, args: anytype) void {
        if (self.log_writer) |w| {
            w.print("protocol: " ++ fmt ++ "\n", args) catch return;
            w.flush() catch return;
            return;
        }

        const io = std.Options.debug_io;
        const prev = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(prev);

        var buf: [256]u8 = undefined;
        const stderr = std.debug.lockStderr(&buf);
        defer std.debug.unlockStderr();
        stderr.file_writer.interface.print("protocol: " ++ fmt ++ "\n", args) catch return;
    }

    fn receiveMessageLogged(self: *Session) !Client.Message.Header {
        return self.server.receiveMessage() catch |err| {
            switch (err) {
                error.EndOfStream => self.logMsg("<- EOF", .{}),
                else => self.logMsg("<- receive error ({s})", .{@errorName(err)}),
            }
            return err;
        };
    }

    /// Completes the initial `zig_version`, `args`, and unit-test handshake until
    /// `Maker` sends `run_test` (with `test_started` acknowledged) or `exit`.
    pub fn handshake(self: *Session, gpa: std.mem.Allocator) !HandshakeResult {
        try self.server.serveStringMessage(.zig_version, builtin.zig_version_string);
        self.logMsg("-> zig_version \"{f}\"", .{std.zig.fmtString(builtin.zig_version_string)});

        var decoded_args: ?[]Arg = null;
        errdefer if (decoded_args) |args| deinitArgs(gpa, args);

        while (true) {
            const hdr = try self.receiveMessageLogged();
            switch (hdr.tag) {
                .args => {
                    const body = try gpa.alloc(u8, hdr.bytes_len);
                    defer gpa.free(body);
                    self.server.in.readSliceAll(body) catch |err| {
                        self.logMsg("<- args (bytes={d}) read_error={s}", .{ hdr.bytes_len, @errorName(err) });
                        return err;
                    };

                    if (decoded_args) |prev| deinitArgs(gpa, prev);
                    decoded_args = null;
                    const decoded = decodeArgs(gpa, body) catch |err| {
                        self.logMsg("<- args (bytes={d}) decode_error={s}", .{ hdr.bytes_len, @errorName(err) });
                        return err;
                    };
                    decoded_args = decoded;
                    self.logMsg("<- args (bytes={d}, count={d}) {f}", .{
                        hdr.bytes_len,
                        decoded.len,
                        fmtArgsList(decoded),
                    });
                },
                .query_test_metadata => {
                    self.logMsg("<- query_test_metadata (bytes={d})", .{hdr.bytes_len});
                    try self.server.in.discardAll(hdr.bytes_len);
                    const string_bytes = "\x00devserver\x00";
                    const names = [_]u32{1};
                    const expected_panic_msgs = [_]u32{0};
                    try self.server.serveTestMetadata(.{
                        .names = &names,
                        .expected_panic_msgs = &expected_panic_msgs,
                        .string_bytes = string_bytes,
                    });
                    self.logMsg("-> test_metadata (tests=1, names=[\"devserver\"])", .{});
                },
                .run_test => {
                    if (hdr.bytes_len < @sizeOf(u32)) {
                        self.logMsg("<- run_test (bytes={d}) invalid_len", .{hdr.bytes_len});
                        return error.InvalidProtocolMessage;
                    }
                    const test_index = self.server.receiveBody_u32() catch |err| {
                        self.logMsg("<- run_test (bytes={d}) read_error={s}", .{ hdr.bytes_len, @errorName(err) });
                        return err;
                    };
                    if (hdr.bytes_len > @sizeOf(u32)) {
                        try self.server.in.discardAll(hdr.bytes_len - @sizeOf(u32));
                    }
                    self.logMsg("<- run_test (bytes={d}, test_index={d})", .{ hdr.bytes_len, test_index });
                    // Transition Maker out of `response_timeout` (60s) into running state.
                    try self.server.serveStringMessage(.test_started, &.{});
                    self.logMsg("-> test_started", .{});
                    const args = decoded_args orelse try gpa.alloc(Arg, 0);
                    decoded_args = null;
                    return .{ .run = .{
                        .args = args,
                        .test_index = test_index,
                    } };
                },
                .exit => {
                    self.logMsg("<- exit (bytes={d})", .{hdr.bytes_len});
                    if (hdr.bytes_len > 0) try self.server.in.discardAll(hdr.bytes_len);
                    if (decoded_args) |prev| deinitArgs(gpa, prev);
                    return .exit;
                },
                else => {
                    self.logMsg("<- {f} (tag=0x{x:0>8}, bytes={d}) unsupported", .{
                        fmtClientTag(hdr.tag),
                        @intFromEnum(hdr.tag),
                        hdr.bytes_len,
                    });
                    try self.server.in.discardAll(hdr.bytes_len);
                    return error.UnsupportedProtocolMessage;
                },
            }
        }
    }

    pub fn sendTestResults(
        self: *Session,
        test_index: u32,
        status: Server.Message.TestResults.Status,
    ) !void {
        try self.server.serveTestResults(.{
            .index = test_index,
            .flags = .{
                .status = status,
                .fuzz = false,
                .log_err_count = 0,
                .leak_count = 0,
            },
        });
        self.logMsg("-> test_results (index={d}, status={s})", .{ test_index, @tagName(status) });
    }

    fn waitForExitMessage(self: *Session) !void {
        while (true) {
            const hdr = self.receiveMessageLogged() catch |err| switch (err) {
                error.EndOfStream => return,
                else => |e| return e,
            };
            self.logMsg("<- {f} (bytes={d})", .{ fmtClientTag(hdr.tag), hdr.bytes_len });
            self.server.in.discardAll(hdr.bytes_len) catch |err| switch (err) {
                error.EndOfStream => {
                    self.logMsg("<- EOF", .{});
                    return;
                },
                else => |e| {
                    self.logMsg("<- discard error ({s})", .{@errorName(e)});
                    return e;
                },
            };
            if (hdr.tag == .exit) return;
        }
    }

    /// Reports the dummy test result and waits for `Maker`'s `.exit` acknowledgement.
    pub fn finish(
        self: *Session,
        test_index: u32,
        status: Server.Message.TestResults.Status,
    ) !void {
        try self.sendTestResults(test_index, status);
        try self.waitForExitMessage();
    }

    /// Blocks reading control messages until `Maker` closes stdin or sends `.exit`.
    pub fn waitForCloseOrExit(self: *Session) void {
        self.waitForExitMessage() catch {};
    }
};

fn formatClientTag(tag: Client.Message.Tag, w: *Io.Writer) Io.Writer.Error!void {
    if (std.enums.tagName(Client.Message.Tag, tag)) |name| {
        try w.writeAll(name);
    } else {
        try w.print("unknown(0x{x:0>8})", .{@intFromEnum(tag)});
    }
}

fn fmtClientTag(tag: Client.Message.Tag) std.fmt.Alt(Client.Message.Tag, formatClientTag) {
    return .{ .data = tag };
}

fn writeHandleArg(w: *Io.Writer, label: []const u8, h: anytype) Io.Writer.Error!void {
    const raw = h.handle.handle;
    switch (@typeInfo(@TypeOf(raw))) {
        .pointer => try w.print("{s}(handle=0x{x}", .{ label, @intFromPtr(raw) }),
        else => try w.print("{s}(handle={d}", .{ label, raw }),
    }
    if (h.prefix.len != 0) try w.print(", prefix=\"{f}\"", .{std.zig.fmtString(h.prefix)});
    if (h.suffix.len != 0) try w.print(", suffix=\"{f}\"", .{std.zig.fmtString(h.suffix)});
    try w.writeByte(')');
}

fn formatArgsList(args: []const Arg, w: *Io.Writer) Io.Writer.Error!void {
    try w.writeByte('[');
    for (args, 0..) |arg, idx| {
        if (idx > 0) try w.writeAll(", ");
        switch (arg) {
            .string => |s| try w.print("string(\"{f}\")", .{std.zig.fmtString(s)}),
            .input_dir => |h| try writeHandleArg(w, "input_dir", h),
            .output_dir => |h| try writeHandleArg(w, "output_dir", h),
            .input_file => |h| try writeHandleArg(w, "input_file", h),
            .output_file => |h| try writeHandleArg(w, "output_file", h),
        }
    }
    try w.writeByte(']');
}

fn fmtArgsList(args: []const Arg) std.fmt.Alt([]const Arg, formatArgsList) {
    return .{ .data = args };
}

fn dummyHandle(comptime T: type, value: usize) T {
    return switch (@typeInfo(T)) {
        .pointer => @ptrFromInt(value),
        else => @intCast(value),
    };
}

test "decodeArgs parses strings, prefixed handles, and suffixes" {
    const gpa = std.testing.allocator;
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(gpa);

    try payload.append(gpa, @intFromEnum(Client.Message.Arg.string));
    try payload.appendSlice(gpa, "watch\x00");

    try payload.append(gpa, @intFromEnum(Client.Message.Arg.prefix));
    try payload.appendSlice(gpa, "--root=\x00");
    try payload.append(gpa, @intFromEnum(Client.Message.Arg.input_dir));
    const dir_handle = dummyHandle(Io.Dir.Handle, 42);
    try payload.appendSlice(gpa, std.mem.asBytes(&dir_handle));
    try payload.append(gpa, @intFromEnum(Client.Message.Arg.suffix));
    try payload.appendSlice(gpa, "/sub\x00");

    try payload.append(gpa, @intFromEnum(Client.Message.Arg.input_file));
    const file_handle = dummyHandle(Io.File.Handle, 77);
    try payload.appendSlice(gpa, std.mem.asBytes(&file_handle));

    const args = try decodeArgs(gpa, payload.items);
    defer deinitArgs(gpa, args);

    try std.testing.expectEqual(@as(usize, 3), args.len);
    try std.testing.expectEqualStrings("watch", args[0].string);
    try std.testing.expectEqual(dir_handle, args[1].input_dir.handle.handle);
    try std.testing.expectEqualStrings("--root=", args[1].input_dir.prefix);
    try std.testing.expectEqualStrings("/sub", args[1].input_dir.suffix);
    try std.testing.expectEqual(file_handle, args[2].input_file.handle.handle);
}

test "decodeArgs rejects invalid tag ordering" {
    const gpa = std.testing.allocator;
    // Orphan suffix without prior handle arg.
    const orphan_suffix = [_]u8{@intFromEnum(Client.Message.Arg.suffix)} ++ "abc\x00";
    try std.testing.expectError(error.InvalidProtocolArgs, decodeArgs(gpa, orphan_suffix));

    // Dangling prefix before end of payload.
    const dangling_prefix = [_]u8{@intFromEnum(Client.Message.Arg.prefix)} ++ "pre\x00";
    try std.testing.expectError(error.InvalidProtocolArgs, decodeArgs(gpa, dangling_prefix));
}

test "Session completes Maker handshake and finish round-trip" {
    const gpa = std.testing.allocator;

    // Build client->server byte stream containing args, query_test_metadata, run_test(0).
    var client_aw: Io.Writer.Allocating = .init(gpa);
    defer client_aw.deinit();
    var dummy_in: Io.Reader = .fixed(&.{});
    var client: Client = .{ .in = &dummy_in, .out = &client_aw.writer };

    const arg_bytes = [_]u8{@intFromEnum(Client.Message.Arg.string)} ++ "watch\x00";
    try client.serveMessageHeader(.{ .tag = .args, .bytes_len = arg_bytes.len });
    try client.out.writeAll(arg_bytes);
    try client.serveBodylessMessage(.query_test_metadata);
    try client.serveRunTest(0);
    try client.out.flush();

    var server_in: Io.Reader = .fixed(client_aw.written());
    var server_aw: Io.Writer.Allocating = .init(gpa);
    defer server_aw.deinit();
    var log_aw: Io.Writer.Allocating = .init(gpa);
    defer log_aw.deinit();

    var session = Session.initWithLogWriter(&server_in, &server_aw.writer, &log_aw.writer);
    const result = try session.handshake(gpa);
    switch (result) {
        .run => |run| {
            defer deinitArgs(gpa, run.args);
            try std.testing.expectEqual(@as(u32, 0), run.test_index);
            try std.testing.expectEqual(@as(usize, 1), run.args.len);
            try std.testing.expectEqualStrings("watch", run.args[0].string);
        },
        .exit => return error.UnexpectedExit,
    }

    const expected_handshake_log = try std.fmt.allocPrint(gpa,
        \\protocol: -> zig_version "{f}"
        \\protocol: <- args (bytes=7, count=1) [string("watch")]
        \\protocol: <- query_test_metadata (bytes=0)
        \\protocol: -> test_metadata (tests=1, names=["devserver"])
        \\protocol: <- run_test (bytes=4, test_index=0)
        \\protocol: -> test_started
        \\
    , .{std.zig.fmtString(builtin.zig_version_string)});
    defer gpa.free(expected_handshake_log);
    try std.testing.expectEqualStrings(expected_handshake_log, log_aw.written());

    // Verify server responses: zig_version, test_metadata, test_started.
    var verify_in: Io.Reader = .fixed(server_aw.written());
    var verify_out_discard: Io.Writer.Allocating = .init(gpa);
    defer verify_out_discard.deinit();
    var checker: Client = .{ .in = &verify_in, .out = &verify_out_discard.writer };

    const h1 = try checker.receiveMessage();
    try std.testing.expectEqual(Server.Message.Tag.zig_version, h1.tag);
    const ver = try checker.in.take(h1.bytes_len);
    try std.testing.expectEqualStrings(builtin.zig_version_string, ver);

    const h2 = try checker.receiveMessage();
    try std.testing.expectEqual(Server.Message.Tag.test_metadata, h2.tag);
    try checker.in.discardAll(h2.bytes_len);

    const h3 = try checker.receiveMessage();
    try std.testing.expectEqual(Server.Message.Tag.test_started, h3.tag);
    try std.testing.expectEqual(@as(u32, 0), h3.bytes_len);

    // Drive finish() with an .exit message.
    var exit_aw: Io.Writer.Allocating = .init(gpa);
    defer exit_aw.deinit();
    var exit_client: Client = .{ .in = &dummy_in, .out = &exit_aw.writer };
    try exit_client.serveBodylessMessage(.exit);
    try exit_client.out.flush();

    var finish_in: Io.Reader = .fixed(exit_aw.written());
    var finish_aw: Io.Writer.Allocating = .init(gpa);
    defer finish_aw.deinit();
    var finish_log_aw: Io.Writer.Allocating = .init(gpa);
    defer finish_log_aw.deinit();
    var finish_session = Session.initWithLogWriter(&finish_in, &finish_aw.writer, &finish_log_aw.writer);
    try finish_session.finish(0, .pass);

    try std.testing.expectEqualStrings(
        \\protocol: -> test_results (index=0, status=pass)
        \\protocol: <- exit (bytes=0)
        \\
    ,
        finish_log_aw.written(),
    );

    var verify_finish_in: Io.Reader = .fixed(finish_aw.written());
    var finish_checker: Client = .{ .in = &verify_finish_in, .out = &verify_out_discard.writer };
    const h4 = try finish_checker.receiveMessage();
    try std.testing.expectEqual(Server.Message.Tag.test_results, h4.tag);
    const tr = try finish_checker.in.takeStruct(Server.Message.TestResults, .little);
    try std.testing.expectEqual(@as(u32, 0), tr.index);
    try std.testing.expectEqual(Server.Message.TestResults.Status.pass, tr.flags.status);
}

test "Session logs unsupported BSP messages and EOF events" {
    const gpa = std.testing.allocator;
    var dummy_in: Io.Reader = .fixed(&.{});

    var bsp_aw: Io.Writer.Allocating = .init(gpa);
    defer bsp_aw.deinit();
    var client: Client = .{ .in = &dummy_in, .out = &bsp_aw.writer };
    try client.serveBodylessMessage(.bsp_build_steps);
    try client.out.flush();

    var in_r: Io.Reader = .fixed(bsp_aw.written());
    var out_aw: Io.Writer.Allocating = .init(gpa);
    defer out_aw.deinit();
    var log_aw: Io.Writer.Allocating = .init(gpa);
    defer log_aw.deinit();

    var session = Session.initWithLogWriter(&in_r, &out_aw.writer, &log_aw.writer);
    try std.testing.expectError(error.UnsupportedProtocolMessage, session.handshake(gpa));
    try std.testing.expect(
        std.mem.indexOf(u8, log_aw.written(), "protocol: <- bsp_build_steps (tag=0x80000000, bytes=0) unsupported\n") != null,
    );

    var eof_in: Io.Reader = .fixed(&.{});
    var eof_log: Io.Writer.Allocating = .init(gpa);
    defer eof_log.deinit();
    var eof_session = Session.initWithLogWriter(&eof_in, &out_aw.writer, &eof_log.writer);
    eof_session.waitForCloseOrExit();
    try std.testing.expectEqualStrings("protocol: <- EOF\n", eof_log.written());
}
