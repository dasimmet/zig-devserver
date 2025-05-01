# Zig Dev Webserver

a webserver that reloads the page when `zig build --watch` rebuilds your content

test it with:

```
zig build --watch watch
```

and then edit `src/index.html`.

Only POSIX is supported, since reloading requires `fork()` ing the server
to the background at the moment.

## `build.zig` usage

```zig
// zig fetch --save git+https://github.com/dasimmet/zig-devserver.git
const devserver = @import("devserver");
// in the build() function:

const run_devserver = devserver.serveDir(b, .{
    .port = b.option(u16, "port", "dev server port") orelse 8080,
    .directory = .{ .install = "www" }, // this can also accept a `LazyPath`
});
b.step("dev", "run dev webserver").dependOn(&run_devserver.step);

// ...  create a step `www_install` that will populate `zig-out/www`
run_devserver.step.dependOn(&www_install.step);
```

## References

- <https://cookbook.ziglang.cc/05-02-http-post.html>
- <https://github.com/andrewrk/mime.git>
- <https://github.com/scottredig/zig-demo-webserver>
