# Writing plugins

Practical guidance for building a plugin: how to structure one, how to test it
without Alas, how to stay inside the limits, and how to write one in a language
other than Rust. The examples here are Rust because that is the toolchain the
sample uses and the one that has been checked against Alas.

## The shape of a plugin

With the [`alas-plugin`](https://github.com/mrmans0n/alas-plugins/tree/main/sdk/alas-plugin) Rust SDK a plugin is one
type and one macro call. The SDK owns the ABI glue (`alas_alloc`, `alas_handle`
and the `alas.send` import), the JSON-RPC framing, request ids, and the
activation handshake: `alas/activate` is answered before your code sees it.

`Cargo.toml`:

```toml
[package]
name = "my-plugin"
version = "0.1.0"
edition = "2021"

# Standalone: not part of any parent workspace.
[workspace]

[lib]
crate-type = ["cdylib"]

[dependencies]
alas-plugin = { git = "https://github.com/mrmans0n/alas-plugins", tag = "sdk-v0.1.0" }
serde_json = "1"

[profile.release]
opt-level = "s"
lto = true
strip = true
panic = "abort"
```

`src/lib.rs`:

```rust
use alas_plugin::{export_plugin, log, request, Event, Plugin};
use serde_json::json;

#[derive(Default)]
struct MyPlugin {
    snapshot_request: i64,
}

impl Plugin for MyPlugin {
    fn handle(&mut self, event: Event) {
        match event {
            Event::Activate { project_name, .. } => {
                log("info", &format!("activated for {project_name}"));
                self.snapshot_request = request("workspace/snapshot", json!({}));
            }
            Event::WorkspaceChanged(snapshot) => {
                log("info", &format!("{} worktrees", snapshot.worktrees.len()));
            }
            Event::Reply { id, result } if id == self.snapshot_request => {
                log("info", &format!("snapshot reply ok: {}", result.is_ok()));
            }
            _ => {}
        }
    }
}

export_plugin!(MyPlugin);
```

The sample in [`plugins/samples/hello-workspace`](../../plugins/samples/hello-workspace)
is the same idea with a bit more logic. Its `build.sh` builds and installs it.

### Testing without Alas

On non-wasm targets the SDK replaces the host imports with an in-memory
recorder, so plain `cargo test` works. Feed messages to `alas_plugin::dispatch`
and read what the plugin sent with `alas_plugin::test_host::take_sent()`, or the
frames it presented with `test_host::take_frames()`. The SDK's own tests in
`sdk/alas-plugin/src/lib.rs` in
[alas-plugins](https://github.com/mrmans0n/alas-plugins) show the pattern.

For that, add `"rlib"` to `crate-type` (`["cdylib", "rlib"]`) so tests can link.

Then build the plugin:

```bash
cargo test
cargo build --release --target wasm32-unknown-unknown
```

## Working with requests and replies

- **You do not answer `alas/activate`.** The SDK does it in the same call, before
  your `Event::Activate` handler runs, so any requests you send there follow it.
- **`request(method, params)` returns the request id.** Remember what each id was
  for and match it against `Event::Reply { id, result }` later. `result` is
  `Ok(value)` or `Err(RpcError { code, message })`. Replies come back in the order
  you asked.
- **Do not answer every reply with a new request.** Alas stops a plugin that needs
  more than 64 calls to settle a single delivery. Ask again on the next
  `workspace/changed` instead.
- **You get the snapshot without asking.** `workspace/changed` arrives shortly
  after activation, so most plugins never need to send `workspace/snapshot`.
- **State does not survive a restart.** A restarted plugin is a fresh instance with
  empty memory and receives `alas/activate` again. Rebuild anything you need from
  the next snapshot.

## Canvas tabs (API 2)

API 2 plugins can draw. `present(tab, pixels, width)` hands Alas one RGBA8 frame
for a canvas tab, `set_regions(tab, &[Region { id, label, rect }])` publishes the
clickable, accessible regions, and `Event::Tick { dt }` and
`Event::Click { tab, region }` drive animation and input. Frame and region limits,
the manifest fields, and the exact wire format are in [api-v2.md](api-v2.md).
`present` is only available to API 2 plugins: a module that imports it under API 1
fails to load. The SDK links the import only when `present` is actually called,
so an API 1 plugin such as `hello-workspace` does not import it.

## Reading the snapshot

The [snapshot](api-v1.md#snapshot) always contains the whole project, so the
simplest plugin is a pure function of the latest one. If you need to react to a
*transition*, such as a session finishing, keep the previous snapshot in your
state and compare. Alas does not send differences.

- Treat `id` values as opaque strings and compare them for equality only.
- Do not rely on worktree order.
- `dirty` and `plan` may be absent. Handle both.
- Treat a session `state` you do not recognize as `unknown`.

## Logging and debugging

- Send `log` messages, and read them in **Settings → Plugins** under each
  project's instance. In Debug builds of Alas, **Debug → Plugins…** also has
  **Messages** on each row, with the raw JSON in both directions.
- **A call that fails loses its own output**, `log` included. If a plugin traps,
  the lines it logged during that same message are gone. Log what you are about to
  do in an earlier message, or look at the last **Messages** entry to see which
  message was being handled.
- `println!` and `eprintln!` go nowhere in `wasm32-unknown-unknown`.

## Staying within the limits

Read the full [limits table](api-v1.md#7-limits). What matters day to day:

- **Work per message.** Each message gets a fixed budget, about 50 ms of
  computation on an optimized build of Alas. Parsing one snapshot is far below
  that. Building large structures, sorting big lists on every message, or looping
  over history is not.
- **Debug builds of Alas are much slower.** The plugin runs in an interpreter,
  and Debug builds of Alas do not optimize it. Compile your plugin with
  `opt-level = "s"` (or `3`) and keep messages cheap so it behaves the same in both.
- **Memory.** 64 MiB in total. Free what you allocate, and do not keep every
  snapshot you ever received. The SDK installs a small global allocator whose
  calls cost little fuel, so do not declare another `#[global_allocator]`.

## Rust checklist

- Build with `--target wasm32-unknown-unknown`, not `wasm32-wasip1`. WASI targets
  import functions Alas does not provide, so the module will not load.
- Set `panic = "abort"`. A panic then becomes a trap, and Alas stops the plugin
  with a clear reason.
- Do not use `wasm-bindgen` or `wasm-pack`. They add JavaScript imports.
- Avoid what this platform does not have. `std::time::Instant::now()` and
  `SystemTime::now()` panic, `std::fs` and `std::thread` are unsupported, and
  there is no source of randomness. A plugin has no clock.
- Crates that need those things will fail at run time, not compile time. Check
  what a dependency uses before adding it.

## Other languages

The raw ABI is described in [api-v1.md](api-v1.md); the SDK above is just Rust glue over it.

The contract is the module's exports and imports, so any language that can produce
a core WebAssembly module with the right shape can write a plugin. Rust is the only
toolchain that has been checked against Alas so far. For anything else, check
these, in this order:

1. The module exports `memory`, `alas_alloc` and `alas_handle`, with the exact
   [signatures](api-v1.md#exports). `alas_handle` must not return a value.
2. The only import is `alas.send`. If your toolchain adds imports of its own,
   configure it to produce a standalone module without a runtime.
3. Your allocator frees what `alas_alloc` gave out, and stays within 64 MiB.
4. Nothing needs a clock, files, or randomness.

The smallest possible plugin is this WebAssembly text module. It never reads a
message. It answers every one with the activation response, which Alas ignores
except the first time. It is useful as a starting point for testing a toolchain:

```wat
(module
  (import "alas" "send" (func $send (param i32 i32)))

  ;; 17 pages (about 1 MiB), so messages up to Alas's 1 MiB limit fit.
  (memory (export "memory") 17)

  ;; The activation response, stored at offset 0 (36 bytes).
  (data (i32.const 0) "{\"jsonrpc\":\"2.0\",\"id\":0,\"result\":{}}")

  (global $heap (mut i32) (i32.const 1024))

  ;; Hands out the same buffer for every message. Fine here, because nothing
  ;; reads a message. A real plugin needs an allocator that can free.
  (func (export "alas_alloc") (param $len i32) (result i32)
    (global.get $heap))

  (func (export "alas_handle") (param $ptr i32) (param $len i32)
    (call $send (i32.const 0) (i32.const 36))))
```
