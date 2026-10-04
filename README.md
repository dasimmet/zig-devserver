# Zig Dev Http Webserver

A lightweight HTTP/WebSocket development server for Zig 0.17.1+ that watches a served directory in-process and reloads connected browser tabs when files change.

> [!IMPORTANT]
> **Serving compiled / installed build outputs (`zig-out`):**
> When `zig build dev` runs `devserver` (`Run.stdio = .protocol`), Zig's build runner blocks waiting on the server step and does **not** re-run upstream build or install steps while the server is alive.
>
> If you want **output prefix watching** (rebuilding your project into `zig-out` on source changes and having `devserver` reload the browser), start `zig build --watch` **in parallel** with the devserver:
>
> ```sh
> # Terminal 1: continuously rebuild & install outputs into zig-out
> zig build --watch
>
> # Terminal 2: serve the output directory and live-reload browsers on changes
> zig build dev -Dopen-browser=index.html
> ```
>
> Or in a single shell session:
>
> ```sh
> zig build --watch &
> zig build dev -Dopen-browser=index.html
> ```
>
> If you are only serving a static source directory directly (without needing rebuilds), running `zig build run-lazypath-src`, `zig build run-lazypath-option -Dserve-dir=<path>`, or `./zig-out/bin/devserver watch <host> <port> <directory>` by itself is sufficient.

## How It Works

* **In-Process Directory Watching**: `devserver` monitors the served directory tree directly (skipping `.git` and `.zig-cache`, with debouncing) and logs all watched directories/files on setup as well as added/modified/removed entries on change events to `stderr`.
* **Live Browser Reload**: HTML pages are injected with a small script that connects over WebSocket to `/__zig_devserver_api`. Whenever watched files change, the server pushes a newer `start_time` timestamp and the browser tab reloads.
* **Port Takeover & Clean Shutdown**: Starting a new `watch` instance on an already-bound fixed port sends a `POST /__zig_devserver_api` shutdown request (`{"action":"shutdown"}`) to the previous instance to take over the port cleanly.
* **`Run.stdio = .protocol` Integration**: `build.zig` `Run` steps use `run.stdio = .protocol;` (no `fork()` or `PPID` polling). All build server protocol messages are logged to `stderr`, while interactive server status logs are written to `/dev/tty` when available.

Naturally, **DO NOT USE THIS IN PRODUCTION**. This is a development tool only.

## CLI Usage

```sh
devserver watch <host> <port> <directory>   # Serve files and watch for changes
devserver help                              # Show usage (-h, --help)
```

When invoked with `--listen=-` (by Zig's `Run.stdio = .protocol`), `devserver` always runs the watcher for both `watch <host> <port> <directory>` and `<host> <port> <directory>`. The legacy `serve` command has been removed.

You can also run the server binary through `build.zig`:

```sh
zig build dev -Dport=8080 -Dopen-browser=index.html
zig build run-lazypath-option -Dserve-dir=path/to/dir -Dport=8080
zig build run-with-args -- 127.0.0.1 8080 path/to/dir
zig build test
```

## `build.zig` Usage

```zig
// zig fetch --save git+https://github.com/dasimmet/zig-devserver.git

pub fn build(b: *std.Build) void {
    const devserver = @import("devserver");
    const run_devserver = devserver.serveDir(b, .{
        // optionally provide a host ip (default: "127.0.0.1"):
        .host = "127.0.0.1",

        // provide a port to listen on (0 picks an ephemeral port):
        .port = b.option(u16, "port", "dev server port") orelse 8080,

        // optionally provide a path to open in the default browser on startup:
        .open_browser = b.option(
            []const u8,
            "open-browser",
            "open the os default webbrowser on first server launch",
        ),

        // either `.serveInstall("www")` => path in `zig-out` (depends on install step),
        // or `.serveLazyPath(...)` on source or generated directories:
        .directory = .serveInstall("www"),
    });

    // Set up a `dev` top-level step to run the server.
    // To rebuild `zig-out` on source edits while serving, run `zig build --watch`
    // in parallel with `zig build dev`.
    b.step("dev", "run dev webserver").dependOn(&run_devserver.step);
}
```

## References

- <https://cookbook.ziglang.cc/05-02-http-post.html>
- <https://github.com/andrewrk/mime.git>
- <https://github.com/scottredig/zig-demo-webserver>
- <https://stackoverflow.com/questions/3043978/how-to-check-if-a-process-id-pid-exists>
- <https://ziggit.dev/t/build-zig-webserver/7078/4>
