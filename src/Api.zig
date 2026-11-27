const std = @import("std");
const builtin = @import("builtin");

action: enum {
    none,
    shutdown,
} = .none,
start_time: ?isize = null,

pub const embedded = struct {
    pub const favicon = @embedFile("static/favicon.ico");
    pub const js = @embedFile("static/__zig_devserver_api.js");
};

pub const endpoint = "/__zig_devserver_api";
pub const js_endpoint = endpoint ++ ".js?version=1";
pub const injected_js = "<script src=\"" ++ js_endpoint ++ "\"></script>";
pub const devtools_endpoint = "/.well-known/appspecific/com.chrome.devtools.json";
pub const sleep_time = 3 * std.time.ns_per_s;

pub const DevToolsWorkspace = struct {
    root: []u8,
    uuid: [36]u8,

    pub fn init(gpa: std.mem.Allocator, raw_root: []const u8) !DevToolsWorkspace {
        const root = try normalizeWorkspaceRootAlloc(gpa, raw_root, builtin.os.tag == .windows);
        return .{
            .root = root,
            .uuid = deriveUuid(root),
        };
    }

    pub fn deinit(self: DevToolsWorkspace, gpa: std.mem.Allocator) void {
        gpa.free(self.root);
    }

    pub fn normalizeWorkspaceRootAlloc(
        gpa: std.mem.Allocator,
        raw_root: []const u8,
        is_windows: bool,
    ) ![]u8 {
        if (!is_windows) {
            return try gpa.dupe(u8, raw_root);
        }

        var trimmed = raw_root;
        if (std.mem.startsWith(u8, trimmed, "\\\\?\\UNC\\") or
            std.mem.startsWith(u8, trimmed, "//?/UNC/"))
        {
            const rest = trimmed["\\\\?\\UNC\\".len..];
            const out = try gpa.alloc(u8, 2 + rest.len);
            out[0] = '/';
            out[1] = '/';
            @memcpy(out[2..], rest);
            std.mem.replaceScalar(u8, out, '\\', '/');
            return out;
        }
        if (std.mem.startsWith(u8, trimmed, "\\\\?\\") or
            std.mem.startsWith(u8, trimmed, "//?/"))
        {
            trimmed = trimmed[4..];
        }

        const out = try gpa.dupe(u8, trimmed);
        std.mem.replaceScalar(u8, out, '\\', '/');
        return out;
    }

    /// Derives a deterministic RFC 9562 v4-formatted UUID from the normalized root path
    /// so workspace permissions persist across restarts without colliding across projects.
    pub fn deriveUuid(normalized_root: []const u8) [36]u8 {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update("zig-devserver:chrome-devtools:v1:");
        hasher.update(normalized_root);
        var digest: [32]u8 = undefined;
        hasher.final(&digest);

        digest[6] = (digest[6] & 0x0f) | 0x40;
        digest[8] = (digest[8] & 0x3f) | 0x80;

        const hex = std.fmt.bytesToHex(digest[0..16], .lower);
        var uuid: [36]u8 = undefined;
        @memcpy(uuid[0..8], hex[0..8]);
        uuid[8] = '-';
        @memcpy(uuid[9..13], hex[8..12]);
        uuid[13] = '-';
        @memcpy(uuid[14..18], hex[12..16]);
        uuid[18] = '-';
        @memcpy(uuid[19..23], hex[16..20]);
        uuid[23] = '-';
        @memcpy(uuid[24..36], hex[20..32]);
        return uuid;
    }
};

test "DevToolsWorkspace normalizes Windows paths and derives stable unique UUIDs" {
    const gpa = std.testing.allocator;

    const win1 = try DevToolsWorkspace.normalizeWorkspaceRootAlloc(gpa, "\\\\?\\C:\\Users\\dev\\proj", true);
    defer gpa.free(win1);
    try std.testing.expectEqualStrings("C:/Users/dev/proj", win1);

    const win_unc = try DevToolsWorkspace.normalizeWorkspaceRootAlloc(gpa, "\\\\?\\UNC\\srv\\share\\proj", true);
    defer gpa.free(win_unc);
    try std.testing.expectEqualStrings("//srv/share/proj", win_unc);

    const posix = try DevToolsWorkspace.normalizeWorkspaceRootAlloc(gpa, "/home/dev/proj", false);
    defer gpa.free(posix);
    try std.testing.expectEqualStrings("/home/dev/proj", posix);

    const uuid_a1 = DevToolsWorkspace.deriveUuid("/home/dev/proj-a");
    const uuid_a2 = DevToolsWorkspace.deriveUuid("/home/dev/proj-a");
    const uuid_b = DevToolsWorkspace.deriveUuid("/home/dev/proj-b");

    try std.testing.expectEqualStrings(&uuid_a1, &uuid_a2);
    try std.testing.expect(!std.mem.eql(u8, &uuid_a1, &uuid_b));
    try std.testing.expectEqual(@as(u8, '-'), uuid_a1[8]);
    try std.testing.expectEqual(@as(u8, '-'), uuid_a1[13]);
    try std.testing.expectEqual(@as(u8, '4'), uuid_a1[14]);
    try std.testing.expectEqual(@as(u8, '-'), uuid_a1[18]);
    try std.testing.expect(uuid_a1[19] == '8' or uuid_a1[19] == '9' or uuid_a1[19] == 'a' or uuid_a1[19] == 'b');
    try std.testing.expectEqual(@as(u8, '-'), uuid_a1[23]);
}
