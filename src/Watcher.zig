//! In-process directory tree watcher and reload notification broker.
//!
//! When `devserver` runs under `Run.stdio = .protocol`, `Maker` blocks until
//! the `Run` step finishes, so `Maker`'s `--watch` cannot detect edits while the
//! server is running. This module monitors the served `Io.Dir` tree directly and
//! wakes connected WebSocket clients whenever files change.

const std = @import("std");
const Io = std.Io;
const log = std.log;

const Watcher = @This();

/// Safety bound preventing excessive directory scans on very large trees.
pub const max_watched_entries: usize = 50_000;
pub const default_poll_interval_ns: i96 = 250 * std.time.ns_per_ms;
pub const default_debounce_ns: i96 = 50 * std.time.ns_per_ms;

pub const Snapshot = struct {
    hash: u64 = 0,
    entry_count: usize = 0,

    pub fn eql(a: Snapshot, b: Snapshot) bool {
        return a.hash == b.hash and a.entry_count == b.entry_count;
    }
};

/// Coordinates live-reload versions and graceful shutdown across connections.
pub const Broker = struct {
    reload_time_ms: std.atomic.Value(i64),
    seq: std.atomic.Value(u32) align(@alignOf(u32)),
    stop: std.atomic.Value(bool),

    pub fn init(io: Io) Broker {
        // Keep > 0 because `__zig_devserver_api.js` ignores non-positive timestamps.
        const now_ms: i64 = @max(1, Io.Clock.real.now(io).toMilliseconds());
        return .{
            .reload_time_ms = .init(now_ms),
            .seq = .init(0),
            .stop = .init(false),
        };
    }

    pub fn currentReloadTime(self: *const Broker) i64 {
        return self.reload_time_ms.load(.acquire);
    }

    /// Strictly advances `reload_time_ms` and wakes all waiting listeners.
    pub fn bumpReload(self: *Broker, io: Io) i64 {
        const now_ms: i64 = @max(1, Io.Clock.real.now(io).toMilliseconds());
        var prev = self.reload_time_ms.load(.monotonic);
        while (true) {
            const next = @max(prev + 1, now_ms);
            if (self.reload_time_ms.cmpxchgWeak(prev, next, .acq_rel, .monotonic)) |actual| {
                prev = actual;
            } else {
                _ = self.seq.fetchAdd(1, .release);
                io.futexWake(u32, &self.seq.raw, std.math.maxInt(u32));
                return next;
            }
        }
    }

    /// Marks shutdown requested and immediately wakes all blocked waiters.
    pub fn requestStop(self: *Broker, io: Io) void {
        self.stop.store(true, .release);
        _ = self.seq.fetchAdd(1, .release);
        io.futexWake(u32, &self.seq.raw, std.math.maxInt(u32));
    }

    /// Waits up to `timeout_ns` unless `seq` changes or shutdown is requested.
    pub fn waitForChange(
        self: *const Broker,
        io: Io,
        expected_seq: u32,
        timeout_ns: i96,
    ) Io.Cancelable!void {
        if (self.stop.load(.acquire)) return;
        if (self.seq.load(.acquire) != expected_seq) return;
        try io.futexWaitTimeout(
            u32,
            &self.seq.raw,
            expected_seq,
            .{ .duration = .{ .raw = .fromNanoseconds(timeout_ns), .clock = .awake } },
        );
    }
};

fn shouldSkipDirectory(basename: []const u8) bool {
    return std.mem.eql(u8, basename, ".git") or std.mem.eql(u8, basename, ".zig-cache");
}

fn hashEntry(entry: Io.Dir.Walker.Entry, size: u64, mtime_ns: i96) u64 {
    var hasher: std.hash.Wyhash = .init(0);
    hasher.update(entry.path);
    hasher.update(&[_]u8{@intFromEnum(entry.kind)});
    hasher.update(std.mem.asBytes(&size));
    hasher.update(std.mem.asBytes(&mtime_ns));
    return hasher.final();
}

/// Computes an order-independent tree fingerprint over `dir`.
pub fn computeSnapshot(
    arena_allocator: std.mem.Allocator,
    io: Io,
    dir: Io.Dir,
) !Snapshot {
    // Reopen `"."` with `.iterate = true` so inherited handles without iterate flags work.
    var iter_dir = try dir.openDir(io, ".", .{ .iterate = true });
    defer iter_dir.close(io);

    var walker = try iter_dir.walk(arena_allocator);
    defer walker.deinit();

    var snapshot: Snapshot = .{};
    while (try walker.next(io)) |entry| {
        if (entry.kind == .directory and shouldSkipDirectory(entry.basename)) {
            walker.leave(io);
            continue;
        }
        if (snapshot.entry_count >= max_watched_entries) {
            log.warn("watcher entry cap ({d}) reached; halting scan", .{max_watched_entries});
            break;
        }

        var size: u64 = 0;
        var mtime_ns: i96 = 0;
        switch (entry.kind) {
            .file, .sym_link => {
                const follow = entry.kind == .file;
                if (entry.dir.statFile(io, entry.basename, .{ .follow_symlinks = follow })) |stat| {
                    size = stat.size;
                    mtime_ns = stat.mtime.nanoseconds;
                } else |err| switch (err) {
                    error.FileNotFound, error.AccessDenied => continue,
                    else => return err,
                }
            },
            else => {},
        }

        snapshot.hash ^= hashEntry(entry, size, mtime_ns);
        snapshot.entry_count += 1;
    }
    return snapshot;
}

/// Polls `dir` until `broker.stop` becomes true, bumping `broker` when edits settle.
pub fn runLoop(
    dir: Io.Dir,
    broker: *Broker,
    gpa: std.mem.Allocator,
    io: Io,
    poll_interval_ns: i96,
) void {
    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();

    var prev = scanWithReset(&arena_impl, io, dir) orelse Snapshot{};

    while (!broker.stop.load(.acquire)) {
        const expected_seq = broker.seq.load(.acquire);
        broker.waitForChange(io, expected_seq, poll_interval_ns) catch return;
        if (broker.stop.load(.acquire)) return;

        var curr = scanWithReset(&arena_impl, io, dir) orelse continue;
        if (curr.eql(prev)) continue;

        // Wait briefly so multi-file saves settle into a single browser reload.
        var settles: u8 = 0;
        while (settles < 4 and !broker.stop.load(.acquire)) : (settles += 1) {
            const settle_seq = broker.seq.load(.acquire);
            broker.waitForChange(io, settle_seq, default_debounce_ns) catch return;
            if (broker.stop.load(.acquire)) return;
            const next = scanWithReset(&arena_impl, io, dir) orelse continue;
            if (next.eql(curr)) break;
            curr = next;
        }

        prev = curr;
        const version = broker.bumpReload(io);
        log.info("detected file change; reloading clients (version={d})", .{version});
    }
}

fn scanWithReset(
    arena_impl: *std.heap.ArenaAllocator,
    io: Io,
    dir: Io.Dir,
) ?Snapshot {
    defer _ = arena_impl.reset(.retain_capacity);
    return computeSnapshot(arena_impl.allocator(), io, dir) catch |err| switch (err) {
        error.Canceled => null,
        else => {
            log.warn("watcher scan failed: {s}", .{@errorName(err)});
            return null;
        },
    };
}

test "computeSnapshot detects additions, edits, removals, and skips .git/.zig-cache" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const s0 = try computeSnapshot(gpa, io, tmp.dir);
    try std.testing.expectEqual(@as(usize, 0), s0.entry_count);

    try tmp.dir.writeFile(io, .{ .sub_path = "index.html", .data = "<h1>v1</h1>" });
    const s1 = try computeSnapshot(gpa, io, tmp.dir);
    try std.testing.expectEqual(@as(usize, 1), s1.entry_count);
    try std.testing.expect(!s1.eql(s0));

    // Ignored metadata dirs should not alter snapshot.
    try tmp.dir.createDirPath(io, ".git");
    try tmp.dir.writeFile(io, .{ .sub_path = ".git/HEAD", .data = "ref: refs/heads/main\n" });
    try tmp.dir.createDirPath(io, ".zig-cache");
    try tmp.dir.writeFile(io, .{ .sub_path = ".zig-cache/tmp.bin", .data = "abc" });
    const s1_with_ignored = try computeSnapshot(gpa, io, tmp.dir);
    try std.testing.expect(s1.eql(s1_with_ignored));

    // Modify file length -> changes snapshot even within same timestamp tick.
    try tmp.dir.writeFile(io, .{ .sub_path = "index.html", .data = "<h1>version 2</h1>" });
    const s2 = try computeSnapshot(gpa, io, tmp.dir);
    try std.testing.expect(!s2.eql(s1));

    // Deleting file reverts to initial count & hash.
    try tmp.dir.deleteFile(io, "index.html");
    const s3 = try computeSnapshot(gpa, io, tmp.dir);
    try std.testing.expect(s3.eql(s0));
}

test "Broker reload_time_ms is positive and strictly increasing" {
    const io = std.testing.io;
    var broker = Broker.init(io);
    const t0 = broker.currentReloadTime();
    try std.testing.expect(t0 > 0);
    const t1 = broker.bumpReload(io);
    const t2 = broker.bumpReload(io);
    try std.testing.expect(t1 > t0);
    try std.testing.expect(t2 > t1);
    try std.testing.expectEqual(@as(u32, 2), broker.seq.load(.acquire));

    broker.requestStop(io);
    try std.testing.expect(broker.stop.load(.acquire));
}
