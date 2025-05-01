port: u16,
action: union(enum) {
    start: serve,
    shutdown,
    reload: serve,
},

pub const serve = struct {
    directory: []const u8,
};
