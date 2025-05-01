action: union(enum) {
    start: serve,
    shutdown,
    reload: serve,
},

pub const serve = struct {
    directory: []const u8,
};

pub const endpoint = "/__zig_devserver_api";
