const std = @import("std");

action: enum {
    shutdown,
    client_reload_check,
},
start_time: ?isize = null,

pub const embedded = struct {
    pub const favicon = @embedFile("static/favicon.ico");
    pub const js = @embedFile("static/__zig_devserver_api.js");
};

pub const endpoint = "/__zig_devserver_api";
pub const js_endpoint = endpoint ++ ".js?version=1";
pub const injected_js = "<script src=\"" ++ js_endpoint ++ "\"></script>";
pub const sleep_time = 3 * std.time.ns_per_s;
