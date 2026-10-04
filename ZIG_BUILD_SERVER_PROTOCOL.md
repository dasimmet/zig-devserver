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

## 5. Architectural Pattern: The Outer/Inner Supervisor Model

Rather than running `devserver` as an external standalone CLI tool, we preserve the standard `zig build dev` entry point using an **Outer/Inner Supervisor Pattern**:

```
[ Developer Terminal ]
       │
       ▼ runs: `zig build dev`
[ Outer zig build ]
       │
       └── Executes Run step: `devserver` (has_side_effects = true, foreground)
             │
             ├── 1. Starts HTTP server (serves static files, SSE/WebSocket reload broker)
             │
             └── 2. Spawns Child: `<zig_exe> build --listen=-` (Inner Build)
                      │
                      ├── BSP Handshake & Configuration exchange
                      ├── `devserver` requests build steps with `flags.watch = true`
                      ├── Inner zig build performs native incremental compilation & file watching
                      └── On step completion -> `devserver` triggers browser reload
```

### Why This Works & Avoids Recursion
1. **No Infinite Recursion**: Under `--listen=-`, the inner `zig build` **never executes any steps on startup**. It waits for the client to send `bsp_build_steps`. `devserver` explicitly requests the `install` step (or static asset step) and **omits the `dev` step**.
2. **No Cache Conflicts**: Zig 0.17.0 locks `.zig-cache` on a fine-grained, per-manifest basis. The outer and inner builds share the cache safely, and artifacts built by the outer build are instant cache hits for the inner build.
3. **No Process Detachment**: `devserver` stays in the foreground of the outer build step. Pressing `Ctrl+C` terminates both the outer runner and the inner build cleanly.

---

## 6. Detailed Implementation Plan for `zig-devserver`

Below is the step-by-step engineering plan to migrate `zig-devserver` to this architecture.

### Phase 1: `build.zig` Updates
1. **Pass `zig_exe` to the Devserver Step**:
   Pass the path of the compiler executing the current build to the devserver executable:
   ```zig
   const devserver_run = b.addRunArtifact(devserver_exe);
   devserver_run.has_side_effects = true;
   // Pass the zig executable path:
   devserver_run.addFileArg(.{ .relative = .{ .base = .zig_exe } });
   ```
2. **Pass Configuration Arguments**:
   Add host, port, and directory arguments:
   ```zig
   devserver_run.addArg(opt.host);
   devserver_run.addArg(b.fmt("{d}", .{opt.port}));
   // directory arg...
   ```
3. **Keep `dev` Step Independent**:
   Ensure `b.step("dev", "run the dev server")` depends on `devserver_run.step`, while the standard `install` step builds the actual web application assets.

### Phase 2: Create BSP Client (`src/BspClient.zig`)
Create a dedicated module in `src/BspClient.zig` responsible for managing the inner `zig build` subprocess:

1. **Process Spawning**:
   ```zig
   pub const BspClient = struct {
       child: std.process.Child,
       in_reader: std.Io.Reader,
       out_writer: std.Io.Writer,
       config_path: ?[]const u8 = null,

       pub fn spawn(io: std.Io, gpa: std.mem.Allocator, zig_exe: []const u8) !BspClient {
           var child = std.process.spawn(io, .{
               .argv = &.{ zig_exe, "build", "--listen=-" },
               .stdin = .pipe,
               .stdout = .pipe,
               .stderr = .inherit,
           }) catch |err| return err;
           // setup readers/writers...
       }
   };
   ```
2. **Message Reading & Writing**:
   Implement wire-framing helpers using little-endian headers:
   * `receiveHeader() !std.zig.Server.Message.Header`
   * `readHandshake() !std.zig.Server.Message.Handshake`
   * `sendBuildSteps(step_indices: []const u32, watch: bool) !void`
   * `sendExit() !void`
3. **Configuration Parsing**:
   Upon receiving `bsp_configuration`, read the payload path and parse the graph with `std.Build.Configuration.loadFile(arena, io, file)`.
   * Find the step index named `"install"` (or default step `config.default_step`).
   * Send `bsp_build_steps` containing this index with `flags.watch = true`.
4. **Event Dispatch Loop**:
   Run an event loop (or async task) reading incoming server messages:
   * When `bsp_step_completed` has `status == .success` for target assets, notify the reload broker.
   * If `status == .failure`, log a compilation error to stderr.

### Phase 3: Signal Handling & Graceful Teardown
1. **Capture Termination Signals**:
   Ensure `SIGINT` (Ctrl+C) and `SIGTERM` are caught in `main.zig`.
2. **Clean Child Termination**:
   When stopping:
   * Send the BSP `exit` message (`tag = 0x00000000`, `bytes_len = 0`) over stdin.
   * Close `child.stdin`.
   * Wait for child process termination with `child.wait(io)` to avoid leaving orphaned background compiler processes.

### Phase 4: HTTP Server & Browser Live-Reload
1. **Live-Reload Endpoint**:
   Expose an SSE (`/devserver-events`) or WebSocket endpoint in `src/main.zig`.
2. **Browser Client Script**:
   Inject (or serve from `src/static/devserver-index.html`) a lightweight client script:
   ```javascript
   const evtSource = new EventSource("/devserver-events");
   evtSource.onmessage = (event) => {
       if (event.data === "reload") location.reload();
   };
   ```
3. **Triggering the Reload**:
   When `BspClient` signals that a rebuild completed successfully, broadcast `"reload"` to all connected SSE clients.

### Phase 5: Codebase Cleanup
1. **Remove Broken Legacy Code**:
   * Delete `watchServer` and all calls to `std.os.linux.fork()`.
   * Delete `notifyServer` and socket polling loops.
   * Remove `PPID` environment variable passing and checks.
   * Remove the syntax typo at `src/main.zig:14` (`std.Build.Watch.`).
2. **Fix `std.Io` Streaming Buffers**:
   Update `usage()` and `stdout` printing in `src/main.zig` to use proper `writerStreaming` / `std.debug.print` patterns compatible with Zig 0.17.0.

---

## 7. Verification & Testing Checklist

- [ ] **Initial Launch**: Run `zig build dev`. Verify the server starts, serves the index page, and displays the banner.
- [ ] **Incremental File Watch**: Modify an HTML or Zig source file. Verify the inner build triggers recompilation, prints progress, and emits `bsp_step_completed`.
- [ ] **Live Reload**: Verify open browser tabs refresh automatically without manual user action.
- [ ] **Error Resilience**: Introduce a syntax error in source files. Verify the inner build reports the error without crashing `devserver`. Fix the error and verify it recovers and reloads.
- [ ] **Clean Exit**: Press `Ctrl+C`. Verify that both the devserver and the inner `zig build` exit cleanly without leaving dangling processes or locked `.zig-cache` files.

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
