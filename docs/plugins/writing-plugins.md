# Writing plugins

Practical guidance for building a plugin: how to structure one, how to test it
without Alas, how to stay inside the limits, and how to write one in a language
other than Rust. The examples here are Rust because that is the toolchain the
sample uses and the one that has been checked against Alas.

## The shape of a plugin

Every plugin has the same three parts:

1. **ABI glue.** The two exports Alas calls (`alas_alloc`, `alas_handle`) and the
   one import it provides (`alas.send`). This is boilerplate you write once.
2. **A message handler.** Takes one incoming JSON message and decides which
   messages to send back.
3. **State.** Whatever the plugin remembers between messages.

Keep part 2 free of anything Wasm-specific. Then you can run it with plain
`cargo test`, without Alas.

## A structure that tests well

This skeleton keeps all the logic in a `Plugin` type that turns one message into
zero or more messages. Only the `abi` module knows about WebAssembly, and it
compiles only for `wasm32`, so `cargo test` on your own machine never tries to
link the `alas.send` import.

`Cargo.toml`:

```toml
[package]
name = "my-plugin"
version = "0.1.0"
edition = "2021"

[lib]
crate-type = ["cdylib", "rlib"]   # cdylib: the .wasm; rlib: lets cargo test link

[dependencies]
serde_json = "1"

[profile.release]
opt-level = "s"
lto = true
strip = true
panic = "abort"
```

`src/lib.rs`:

```rust
use std::collections::HashMap;

use serde_json::{json, Value};

/// What a pending request was for, so its response can be matched by id.
enum Pending {
    Snapshot,
}

#[derive(Default)]
pub struct Plugin {
    next_id: i64,
    pending: HashMap<i64, Pending>,
}

impl Plugin {
    fn request(&mut self, method: &str, params: Value, purpose: Pending) -> Value {
        self.next_id += 1;
        self.pending.insert(self.next_id, purpose);
        json!({"jsonrpc": "2.0", "id": self.next_id, "method": method, "params": params})
    }

    /// One message in, zero or more messages out. No I/O, so it runs in `cargo test`.
    pub fn handle(&mut self, input: &str) -> Vec<Value> {
        let Ok(message) = serde_json::from_str::<Value>(input) else { return vec![] };
        match message["method"].as_str() {
            Some("alas/activate") => vec![
                // Answer the activation first, then start work.
                json!({"jsonrpc": "2.0", "id": message["id"], "result": {}}),
                self.request("workspace/snapshot", json!({}), Pending::Snapshot),
            ],
            Some("workspace/changed") => vec![log("info", summary(&message["params"]["snapshot"]))],
            Some(_) => vec![],
            // No method: this is a response to one of our requests.
            None => match message["id"].as_i64().and_then(|id| self.pending.remove(&id)) {
                Some(Pending::Snapshot) => vec![log("info", summary(&message["result"]["snapshot"]))],
                None => vec![],
            },
        }
    }
}

fn log(level: &str, message: String) -> Value {
    json!({"jsonrpc": "2.0", "method": "log", "params": {"level": level, "message": message}})
}

fn summary(snapshot: &Value) -> String {
    let count = snapshot["worktrees"].as_array().map_or(0, |worktrees| worktrees.len());
    format!("{count} worktrees")
}

/// The Wasm ABI. Everything above is plain Rust; only this module talks to Alas.
#[cfg(target_arch = "wasm32")]
mod abi {
    use super::Plugin;
    use std::cell::RefCell;

    #[link(wasm_import_module = "alas")]
    extern "C" {
        #[link_name = "send"]
        fn alas_send(ptr: *const u8, len: usize);
    }

    thread_local! {
        static PLUGIN: RefCell<Plugin> = RefCell::new(Plugin::default());
    }

    #[no_mangle]
    pub extern "C" fn alas_alloc(len: usize) -> *mut u8 {
        Box::into_raw(vec![0u8; len].into_boxed_slice()) as *mut u8
    }

    /// # Safety
    /// `ptr`/`len` must come from `alas_alloc`; Alas guarantees this.
    #[no_mangle]
    pub unsafe extern "C" fn alas_handle(ptr: *mut u8, len: usize) {
        // Taking ownership of the buffer frees it when `bytes` goes out of scope.
        let bytes = Box::from_raw(std::ptr::slice_from_raw_parts_mut(ptr, len));
        let input = String::from_utf8_lossy(&bytes);
        let output = PLUGIN.with(|plugin| plugin.borrow_mut().handle(&input));
        for message in output {
            let text = message.to_string();
            alas_send(text.as_ptr(), text.len());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn activation_is_answered_before_the_snapshot_is_requested() {
        let mut plugin = Plugin::default();
        let out = plugin.handle(r#"{"jsonrpc":"2.0","id":0,"method":"alas/activate","params":{}}"#);
        assert_eq!(out[0]["result"], json!({}));
        assert_eq!(out[1]["method"], "workspace/snapshot");
    }

    #[test]
    fn a_snapshot_response_is_matched_by_id() {
        let mut plugin = Plugin::default();
        plugin.handle(r#"{"jsonrpc":"2.0","id":0,"method":"alas/activate","params":{}}"#);
        let out = plugin.handle(r#"{"jsonrpc":"2.0","id":1,"result":{"snapshot":{"worktrees":[{}, {}]}}}"#);
        assert_eq!(out[0]["params"]["message"], "2 worktrees");
        assert!(plugin.handle(r#"{"jsonrpc":"2.0","id":1,"result":{}}"#).is_empty());
    }
}
```

Run the tests on your machine, then build the plugin:

```bash
cargo test
cargo build --release --target wasm32-unknown-unknown
```

The sample in [`plugins/samples/hello-workspace`](../../plugins/samples/hello-workspace)
is the same idea in a single file with no state. Its `build.sh` builds it and
installs it. It uses a small ABI section you can copy as is.

### About the ABI glue

- **`alas_alloc`** hands Alas a buffer to write the next message into. Here it
  allocates a zeroed buffer and deliberately leaks it (`Box::into_raw`), so that
  Rust does not free it while Alas is filling it.
- **`alas_handle`** takes that buffer back with `Box::from_raw`, which makes Rust
  free it when the function returns. You must free it. A plugin that never does
  runs out of its [64 MiB](api-v1.md#7-limits) after enough messages.
- **`alas.send`** copies the bytes right away, so the `String` you pass can be
  dropped straight after the call.
- **`thread_local!`** is the simplest safe way to keep state in a single-threaded
  module. A `static mut` works too, but needs `unsafe`.

## Working with requests and replies

- **Answer `alas/activate` first**, in the same call, before any request of your
  own. Reply with the `id` you were given.
- **Choose your own request ids** and remember what each was for, as the skeleton
  does with `pending`. Replies come back later, in the order you asked, and carry
  the same `id`.
- **Do not answer every reply with a new request.** Alas stops a plugin that needs
  more than 64 calls to settle a single delivery. Ask again on the next
  `workspace/changed` instead.
- **You get the snapshot without asking.** `workspace/changed` arrives shortly
  after activation, so most plugins never need to send `workspace/snapshot`. The
  skeleton does it only to show the request and reply pattern.
- **State does not survive a restart.** A restarted plugin is a fresh instance with
  empty memory and receives `alas/activate` again. Rebuild anything you need from
  the next snapshot.

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

- Send `log` messages, and read them under **Debug → Plugins…**. Open **Messages**
  on a row for the raw JSON in both directions.
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
  snapshot you ever received.

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
