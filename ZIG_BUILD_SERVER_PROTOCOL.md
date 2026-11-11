# Zig Build Server Protocol (BSP) Reference & Implementation Plan

This document summarizes the **Build Server Protocol (BSP)** introduced in **Zig 0.17.0**, its architectural motivations, wire specification, and a detailed implementation plan for integrating it into `zig-devserver` to support live rebuilding without broken `b.args` hacks or process forking.

---

## 1. Background & Motivation

### Why the Old Model Broke
In earlier Zig releases (such as 0.15/0.16), `zig-devserver` attempted to:
1. Inspect CLI arguments (`b.args` or `std.process.argsAlloc`) inside `build.zig` to detect flags like `--watch`.
2. Spawn child processes or call `std.os.linux.fork()` during step execution so the server could detach into the background.
3. Track parent processes via `PPID` environment variables and poll network sockets to shut down old instances.

In **Zig 0.17.0**, this approach stopped working due to a core architectural overhaul:
* **Separation of Maker and Configurer Processes**:
  `zig build` runs `build.zig` inside a separate **configurer process** whose sole responsibility is to evaluate configuration logic and serialize the resulting dependency graph into an immutable binary cache file. The **maker process** later reads this graph and executes build steps.
* **Removal of `b.args`**:
  Passthrough arguments for `Run` steps are now decoupled using `run.addPassthruArgs()`. Runtime CLI arguments are only resolved by the maker process and are intentionally hidden from `build.zig` to keep configuration evaluation pure and cacheable.
* **Configure Cache Poisoning**:
  Any configure-time side effects (e.g., process detection, environment inspection outside declared inputs) mark the configuration as poisoned (`std.Build.Graph.poisonCache`), preventing cache reuse or aborting execution under `--cache-poison=disallowed`.
* **Removal of Custom Build Runners**:
  Forking or overriding the build runner is no longer supported.

To support external tools such as IDEs (ZLS), file watchers, and dev servers, Zig 0.17.0 introduced the **Build Server Protocol (BSP)**.

---

## 2. Protocol Overview & Invocation

Passing `--listen=-` activates the protocol over standard I/O:

```bash
zig build --listen=-
```

### Transport & Framing
* **Transport**: Binary communication over `stdin` (client to server) and `stdout` (server to client).
* **Endianness**: Little-endian for all multi-byte integers.
* **Protocol Version**: Version 1 (`std.zig.Server.build_system_version = 1`).
* **Packet Header**: Every message in either direction begins with an 8-byte header:
  ```zig
  pub const Header = extern struct {
      tag: Tag,        // u32 enum
      bytes_len: u32,  // payload size in bytes (excluding this header)
  };
  ```
* **Multiplexed Namespace**: BSP-specific message tags use values `0x80000000` and above. Values below `0x80000000` are reserved for the internal compiler server and test runner protocols.

---

## 3. Protocol Message Specification

### A. Server-to-Client Messages (`std.zig.Server.Message`)

Defined in [`lib/std/zig/Server.zig`](file:///home/tobi/.cache/zig/p/N-V-__8AALBXTRYsilzupvrmv0afm7ohtj5Mj0paqVfKLmfP/lib/std/zig/Server.zig).

| Tag Name | Tag Value | Payload Description |
| :--- | :--- | :--- |
| `bsp_handshake` | `0x80000000` | Sent immediately after connection starts. Body is `Handshake` followed by `BasePaths`. |
| `bsp_configuration` | `0x80000001` | Sent when a new build configuration file has been written. Body is the CWD-relative path (UTF-8 string) to the binary configuration file in `.zig-cache/c/...`. |
| `bsp_configuration_failed`| `0x80000002` | Sent if `build.zig` failed to compile or configure. Body is an `ErrorBundle`. |
| `bsp_build_started` | `0x80000003` | Empty body (`bytes_len = 0`). Indicates that execution of build steps has begun. |
| `bsp_build_completed` | `0x80000004` | Empty body (`bytes_len = 0`). Indicates that the build run has finished. |
| `bsp_step_started` | `0x80000005` | Body is a `u32` containing the `Configuration.Step.Index` of the step being executed. |
| `bsp_step_completed` | `0x80000006` | Body is `BuildStepCompleted` describing the step index, execution status, errors, and generated files. |

#### Key Server Structs

```zig
pub const Handshake = extern struct {
    version: u32,       // Matches build_system_version (1)
    flags: Flags,

    pub const Flags = packed struct(u32) {
        file_system_watch_supported: bool,
        unused: u31 = 0,
    };
};

pub const BuildStepCompleted = extern struct {
    step_index: Configuration.Step.Index,
    status: Status,
    error_bundle: ErrorBundle,
    generated_files_len: u32,

    pub const Status = enum(u32) {
        success,
        failure,
        skipped,
        skipped_oom,
    };
    // Trailing payload:
    // * error_bundle data
    // * [generated_files_len]GeneratedFile
    // * path bytes for each generated file
};
```

---

### B. Client-to-Server Messages (`std.zig.Client.Message`)

Defined in [`lib/std/zig/Client.zig`](file:///home/tobi/.cache/zig/p/N-V-__8AALBXTRYsilzupvrmv0afm7ohtj5Mj0paqVfKLmfP/lib/std/zig/Client.zig).

| Tag Name | Tag Value | Payload Description |
| :--- | :--- | :--- |
| `bsp_build_steps` | `0x80000000` | Body is `BuildSteps` header followed by an array of `step_count` elements of `Configuration.Step.Index` (`u32`). |
| `update` | `0x00000001` | Empty body (`bytes_len = 0`). Tells the build server to detect file modifications and re-run. |
| `exit` | `0x00000000` | Empty body (`bytes_len = 0`). Requests clean termination of the build server process. |

#### Requesting Steps & Watch Mode

```zig
pub const BuildSteps = extern struct {
    step_count: u32,
    flags: Flags,

    pub const Flags = packed struct(u32) {
        watch: bool,       // Enable continuous file watching and rebuilds
        reserved: u31 = 0,
    };
    // Trailing:
    // * step_indices: [step_count]Configuration.Step.Index
};
```

---

## 4. Reading the Build Configuration Graph

When the server sends `bsp_configuration`, the payload contains a relative path to the serialized graph. The client can load this configuration using `std.Build.Configuration`:

```zig
const std = @import("std");

pub fn inspectConfig(arena: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    const file = try io.cwd().openFile(io, path, .{ .mode = .read_only });
    defer file.close(io);

    const config = try std.Build.Configuration.loadFile(arena, io, file);

    // Inspect available steps:
    for (config.steps, 0..) |step, idx| {
        const name = config.string(step.name);
        std.debug.print("Step #{d}: {s}\n", .{ idx, name });
    }

    // Inspect options, dependencies, and default step:
    std.debug.print("Default step index: {d}\n", .{config.default_step});
}
```

Relevant source files:
* [`lib/std/Build/Configuration.zig`](file:///home/tobi/.cache/zig/p/N-V-__8AALBXTRYsilzupvrmv0afm7ohtj5Mj0paqVfKLmfP/lib/std/Build/Configuration.zig)
* [`lib/std/Build/Serialize.zig`](file:///home/tobi/.cache/zig/p/N-V-__8AALBXTRYsilzupvrmv0afm7ohtj5Mj0paqVfKLmfP/lib/std/Build/Serialize.zig)

---

## 5. `Run.stdio = .protocol` vs. `--listen=-` BSP in `zig-devserver`

Zig 0.17.0 introduced `Run.stdio = .protocol` (`std.Build.Step.Run.StdIo.protocol`), which lets a build-graph `Run` step speak Zig's `stdin`/`stdout` binary test-runner protocol (`std.zig.Client` in `Maker` <-> `std.zig.Server` in the child) instead of inheriting stdio or receiving plain filesystem paths on `argv`. Because `b.args` and `fork()`-based daemonization no longer work for `zig build dev` under Zig 0.17+, `zig-devserver` adopts **`Run.stdio = .protocol` with in-process directory watching**.

### How `Run.stdio = .protocol` Works in Zig 0.17.0 / 0.17.1

When a `Run` step sets `run.stdio = .protocol`:

```
[ Developer Terminal ]
       │
       ▼ runs: `zig build dev` / `zig build run-with-args -- ...`
[ Zig Maker (`lib/compiler/Maker.zig` + `Maker/Step/Run.zig`) ]
       │  Spawns `devserver --listen=-` with piped stdin/stdout/stderr
       │  Inherits `LazyPath` directories as open OS handles (`inherit_dirs`)
       │
       ├──► stdin  (`Client.Message`): `.args` (string/prefix/handle/suffix), `.query_test_metadata`, `.run_test(0)`
       ◄──  stdout (`Server.Message`): `.zig_version`, `.test_metadata`, `.test_started`, ... `.test_results`
       └──► stdin  (`.exit` after `.test_results`)
       │
[ Foreground `devserver` Process ]
       ├── Decodes `Client.Message.Arg` (`.string`, `.input_dir` handles, etc.)
       ├── Serves HTTP + `/__zig_devserver_api` + WebSocket live-reload notifications
       ├── Runs in-process directory polling (`Watcher.zig`) with debounce + futex `Broker`
       └── Logs all protocol messages to `stderr` and interactive app info/warnings to `/dev/tty` (errors to both)
```

1. **Test-Runner Handshake & Timeout Behavior**:
   * `Maker` spawns the step with `--listen=-` and piped `stdin`/`stdout`/`stderr`.
   * If `run` has arguments past `argv[0]`, `Maker` encodes them into a single `Client.Message.Tag.args` packet (`string`, `prefix`, `input_dir`, `input_file`, `input_file_content`, `output_dir`, `output_file`, `suffix`), passing open `Io.Dir.Handle` / `Io.File.Handle` values natively for `LazyPath` arguments such as `addDirectoryArg(lp)`.
   * `Maker` then sends `.query_test_metadata` followed by `.run_test`. Once the server responds with `.test_started`, `Maker` clears its 60-second `response_timeout` and waits indefinitely while the server runs (unless `--unit-test-timeout` is specified on `zig build`).
   * On clean shutdown (e.g. `POST /__zig_devserver_api` with `{"action":"shutdown"}`), the server stops accepting connections, joins worker/watcher threads, sends `.test_results` (`.pass`), waits for `Maker`'s `.exit` frame on `stdin`, and exits with code `0`.

2. **Observed Constraints of `Run.stdio = .protocol` (`0.17.0` & `0.17.1`)**:
   * **Foreground blocking, no upstream graph rebuilds while serving**: While `devserver` is running inside `evalZigTest`/`waitZigTest`, `Maker` blocks waiting on the child step and does not re-evaluate upstream `Compile`, `InstallFile`, or `WriteFiles` steps in the build graph.
   * **`discovered_inputs` direction**: The `.discovered_inputs` message goes *child -> `Maker`* for manifest/cache tracking of future builds, not *`Maker` -> child*. Because `Maker` only updates its watch list after the `Run` step completes, exiting inside `devserver` on file edits does not trigger an automatic respawn under `zig build --watch`.
   * **Single `stdin` reader & reserved stdio**: Writing plain text to `stdout` corrupts binary IPC framing; writing non-error logs to `stderr` triggers `Maker`'s buffered `"stderr"` summary in Zig 0.17.1. Furthermore, only one thread may read `session.server.in` (`stdin`) at a time while serving.

### When `--listen=-` BSP Supervisor Would Be Required Instead

Use an outer/inner `--listen=-` BSP client (`bsp_configuration` / `bsp_build_steps` with `watch = true` / `bsp_step_completed`, documented in Sections 2–4) instead of pure `Run.stdio = .protocol` + in-process directory watching if `zig-devserver` later needs to serve **compiled or generated assets** (such as a Zig WASM binary or bundled frontend assets) and automatically re-run upstream `std.Build` steps on source edits without restarting `devserver`. For serving static/pre-built directories (`serveDir` and `serveLazyPath`), `Run.stdio = .protocol` plus in-process directory watching avoids nested `zig build` recursion and option-reflection complexity cleanly.

---

## 6. Implemented `Run.stdio = .protocol` Architecture

### Phase 1: `build.zig` Updates
1. **Enable `.protocol` Stdio on Server `Run` Steps**:
   * Keep `run.stdio = .protocol;` on the `"run-with-args"` step and set `run.stdio = .protocol;` inside `serveDirInternal`, always invoking the `"watch"` command without branching to `"serve"`.
   * Use `run.addDirectoryArg(lp)` (instead of `addFileArg(lp)`) for `.lazypath` directories so `Maker` opens the directory handle with `.iterate = true` and passes `Client.Message.Arg.input_dir`.
   * Remove legacy `PPID` environment variable propagation across Linux/macOS/Windows.
2. **Add `test` Top-Level Step**:
   * Expose `zig build test` running unit and HTTP integration tests on `exe.root_module`.

### Phase 2: Protocol Session & Argument Decoder (`src/Protocol.zig`)
* **`Arg` & `decodeArgs`**: Decodes `Client.Message.Tag.args` payloads into typed `Arg` variants (`.string`, `.input_dir`, `.input_file`, `.output_dir`, `.output_file`) supporting `.prefix` and `.suffix` modifiers and validated tag ordering.
* **`Session`**: Implements `std.zig.Server` messaging over `stdin`/`stdout` and logs all incoming and outgoing build server protocol messages (`protocol: -> ...` / `protocol: <- ...`, including decoded `args`, `test_index`, status, EOF, and unsupported tags) thread-safely to `stderr` via `std.debug.lockStderr` (with `initWithLogWriter` for unit tests):
  * `handshake()`: Sends `.zig_version`, decodes `.args`, replies to `.query_test_metadata` with a single synthetic `"devserver"` entry, and responds `.test_started` upon `.run_test`.
  * `sendTestResults()`: Sends `.test_results` (`.pass`/`.fail`) and logs the outgoing result frame to `stderr`.
  * `waitForCloseOrExit()`: Runs on a dedicated single-reader `ControlContext` thread while the server runs so if `Maker` closes `stdin` or sends `.exit`, the server logs the control message/EOF and initiates graceful shutdown without concurrent `stdin` reads.
  * `finish()`: Used for early non-serving exits (`help`, argument errors, startup failures) before the control thread starts, emitting `.test_results` via `sendTestResults()` and draining until `.exit`/EOF.

### Phase 3: In-Process Directory Watcher & Broker (`src/Watcher.zig`)
* **`Broker`**: Thread-safe reload coordinator storing strictly monotonically increasing positive `reload_time_ms: std.atomic.Value(i64)` (fixing JS `res.start_time > 0` checks and avoiding nanosecond `MAX_SAFE_INTEGER` precision overflow), `seq: std.atomic.Value(u32)`, and `stop: std.atomic.Value(bool)`. Uses `io.futexWaitTimeout` / `io.futexWake` for zero-spin instant WebSocket wakeups and immediate shutdown notification.
* **`computeSnapshot` & `runLoop`**: Walks the served `Io.Dir` (reopened via `.openDir(io, ".", .{ .iterate = true })`), skipping `.git` and `.zig-cache` and capping scans at `50_000` entries, XOR-hashing path, entry kind, size, and `mtime_ns` into an order-independent `Wyhash` digest. Polls every 250ms with 50ms settle debouncing before bumping `Broker`.

### Phase 4: HTTP / WebSocket Server & Teardown (`src/Request.zig`, `src/main.zig`)
* **`Request.zig`**:
  * Replaces `start_time: Io.Timestamp` with `broker: *Watcher.Broker` and optional `on_shutdown` callback (`ShutdownCoord.trigger`).
  * Pushes `broker.currentReloadTime()` (epoch milliseconds) over WebSocket whenever `broker.waitForChange` wakes on edit or shutdown, and shuts down the socket + joins `recv_thread` cleanly on teardown.
  * Ensures opened directories in `handleDir` are closed via `defer dir.close(req.io);`.
* **`main.zig`**:
  * Removes the legacy `serve` command; `watch` (plus `help`/`-h`/`--help`) is the sole server command, and when `--listen=-` is provided, both explicit `watch <host> <port> <directory>` and implicit `<host> <port> <directory>` run the in-process watcher automatically.
  * Dispatches unified `CmdArg` slices identically from CLI `argv` or `--listen=-` `Protocol.Session` (opening `.string` paths or `.input_dir` handles with `.iterate = true` and resolving canonical `public_path` via `realPathFileAlloc`).
  * Installs `customLogFn`: in `.protocol` mode, routes interactive application logs (`info`/`warn`/`debug`) to `/dev/tty` when available without touching `stdout`/`stderr`, while forwarding `.err` messages (alongside `Protocol.zig`'s direct `stderr` protocol message logs) to `stderr`.
  * Supports ephemeral port `0` (`tcp_server.socket.address`), safe watch-mode fixed-port takeover on `AddressInUse` via `POST /__zig_devserver_api`, tracked HTTP worker teardown (`WorkerTracker`), watcher + control thread joins, and clean `.test_results` (`Session.sendTestResults`) / `.exit` completion before returning exit code `0`.

---

## 7. Verification & Testing Checklist

- [x] **Unit & Integration Tests (`zig build test`)**: Verified `Protocol.zig` arg decoding, handshake/finish round-trip, protocol message logging (including unsupported BSP tags and EOF), `Watcher.zig` snapshot/broker tests, `main.zig` command parsing (`serve` removed, `--listen=-` implicit/explicit `watch`), HTTP directory listing, HTML JS injection, `fromProtocolArgs`, and API shutdown integration tests (`Build Summary: 3/3 steps succeeded; 10/10 tests passed`).
- [x] **Executable Build (`zig build`)**: Verified `zig build` builds the `devserver` artifact cleanly on Zig 0.17.1 (`Build Summary: 4/4 steps succeeded`).
- [x] **Protocol Help, Implicit Watch, Removed `serve` & `stderr` Logging (`zig build run-with-args`)**: Verified `.protocol` handles `help` (exit `0`), `<host> <port> <dir>` without explicit `"watch"`, rejects `serve` cleanly (`error: unknown command 'serve' (use 'watch' instead)`), and logs all build server protocol messages (`protocol: -> zig_version`, `<- args`, `<- query_test_metadata`, `-> test_metadata`, `<- run_test`, `-> test_started`, `-> test_results`, `<- exit`) to `stderr`.
- [x] **Live Serving & In-Process Reload (`zig build dev`, `run-lazypath-wf`, `run-lazypath-option`)**: Started servers under `Run.stdio = .protocol`, verified HTTP responses, injected reload script, `WriteFiles` directory handle serving, `stderr` protocol message logging (including `input_dir` handles), live WebSocket `start_time` reload bump on file edit (`1794422544702 -> 1794422545003`), and clean `/__zig_devserver_api` shutdown & exit.
- [x] **Direct CLI Mode**: Verified `./zig-out/bin/devserver` supports `help` (exit `0`) and `watch` (without emitting `--listen=-` `protocol:` trace lines), and rejects `serve` (exit `1`).

---

## 8. Resources & References

### Official Documentation
* [Zig 0.17.0 Release Notes: Build Server Protocol](https://ziglang.org/download/0.17.0/release-notes.html#Build-Server-Protocol)
* [Zig 0.17.0 Release Notes: Separate Maker from Configurer Process](https://ziglang.org/download/0.17.0/release-notes.html#Separate-the-Maker-Process-from-the-Configurer-Process)
* [Zig 0.17.0 Release Notes: Run Step Passthru Args](https://ziglang.org/download/0.17.0/release-notes.html#Run-Step-Passthru-Args)
* [Zig 0.17.0 Release Notes: Configure Cache Poisoning](https://ziglang.org/download/0.17.0/release-notes.html#Introduce-the-Concept-of-Configure-Cache-Poisoning)

### Standard Library Sources
* [`std.zig.Server`](file:///home/tobi/.cache/zig/p/N-V-__8AALBXTRYsilzupvrmv0afm7ohtj5Mj0paqVfKLmfP/lib/std/zig/Server.zig): Full definition of server message tags, `Handshake`, `BuildStepCompleted`, and serialization helpers.
* [`std.zig.Client`](file:///home/tobi/.cache/zig/p/N-V-__8AALBXTRYsilzupvrmv0afm7ohtj5Mj0paqVfKLmfP/lib/std/zig/Client.zig): Client message tags, `BuildSteps`, `serveBuildSteps`, and request framing.
* [`std.Build.Configuration`](file:///home/tobi/.cache/zig/p/N-V-__8AALBXTRYsilzupvrmv0afm7ohtj5Mj0paqVfKLmfP/lib/std/Build/Configuration.zig): Deserialization functions (`loadFile`, `load`) and graph data structures.

### Commits & Issue Tracking
* **Codeberg PR [#35428](https://codeberg.org/ziglang/zig/pulls/35428)**: *Separate the maker process from the configurer process* (introduces BSP and binary configuration).
* **Codeberg Issue [#36497](https://codeberg.org/ziglang/zig/issues/36497)**: *Dogfooding build server protocol in Zig's first-party tooling*.
* **GitHub Issue [#615](https://github.com/ziglang/zig/issues/615)**: *Multiplex compiler server protocol into build server*.
* **Zig Language Server (ZLS)**: ZLS development discussions and PRs for tracking the 0.17.0 BSP migration.

### CLI Inspection Commands
* `zig build --listen=-`: Start build runner with BSP on standard I/O.
* `zig build --print-configuration`: Dump the entire configuration graph to stdout in human-readable ZON format.
* `zig build --print-configuration-path`: Print the path to the serialized binary configuration file.
* `zig cache-cat <file>`: Inspect binary cache and configuration files directly.
