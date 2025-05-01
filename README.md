# Zig Dev Http Webserver

a webserver that reloads the page when `zig build --watch` rebuilds your content

try it with:

```
zig build run --watch -Dopen-browser=index.html
```

and then edit `src/index.html` and have the browser tab reload.

Only POSIX is supported, since reloading requires `fork()` ing the server
to the background at the moment.

The next launch of the server will send a request to the old instance to kill it.

On html pages a small javascript is injected to check when the server was started.
When the page receives a newer timestamp, a reload is triggered.

To stop the forked server when `zig build --watch` is stopped,
it sends `kill(ppid, 0)` signals back to it's parent process on request and end itself if needed.

Naturally, DO NOT USE THIS IN PRODUCTION. This is a development tool only.

## `build.zig` usage

```zig
// zig fetch --save git+https://github.com/dasimmet/zig-devserver.git

pub fn build(b: *std.Build) void {
const devserver = @import("devserver");
    const run_devserver = devserver.serveDir(b, .{
        // optionally provide a host ip. this is the default:
        .host = "127.0.0.1",

        // provide a port to listen on
        .port = b.option(u16, "port", "dev server port") orelse 8080,

        // optionally provide a path to open
        .open_browser = b.option(
            []const u8,
            "open-browser",
            "open the os default webbbrowser on first server launch",
        ) orelse "/",

        // this union can accept a `install` path in `zig-out`
        // or a `LazyPath`
        .directory = .{ .install = "www" },
    });
    b.step("dev", "run dev webserver").dependOn(&run_devserver.step);
}
```

## References

- <https://cookbook.ziglang.cc/05-02-http-post.html>
- <https://github.com/andrewrk/mime.git>
- <https://github.com/scottredig/zig-demo-webserver>
- <https://stackoverflow.com/questions/3043978/how-to-check-if-a-process-id-pid-exists>
- <https://ziggit.dev/t/build-zig-webserver/7078/4>
