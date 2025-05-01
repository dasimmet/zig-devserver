# Zig Dev Webserver

a webserver that reloads the page when `zig build --watch` rebuilds your content

try it with:

```
zig build --watch watch
```

and then edit `src/index.html`.

Only POSIX is supported, since reloading requires `fork()` ing the server
to the background at the moment.

The next launch of the server will send a request to the old instance to kill it.

On html pages a small javascript is injected to check when the server was started.
When the page receives a newer timestamp, a reload is triggered.

To stop the forked server when `zig build --watch` is stopped,
it sends `kill(ppid, 0)` signals back to it's parent process on request and end itself if needed.

## `build.zig` usage

```zig
// zig fetch --save git+https://github.com/dasimmet/zig-devserver.git
const devserver = @import("devserver");
// in the build() function:

const run_devserver = devserver.serveDir(b, .{
    .port = b.option(u16, "port", "dev server port") orelse 8080,

    // this can accept a `LazyPath`
    // or a path in `zig-out`
    .directory = .{ .install = "www" }, 
});
b.step("dev", "run dev webserver").dependOn(&run_devserver.step);
```

## References

- <https://cookbook.ziglang.cc/05-02-http-post.html>
- <https://github.com/andrewrk/mime.git>
- <https://github.com/scottredig/zig-demo-webserver>
- <https://stackoverflow.com/questions/3043978/how-to-check-if-a-process-id-pid-exists>
- <https://ziggit.dev/t/build-zig-webserver/7078/4>
