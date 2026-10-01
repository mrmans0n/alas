# Plugins run JavaScript in JavaScriptCore, not WebAssembly

Tracks [#1560](https://github.com/mrmans0n/alas/issues/1560). Replaces the
WasmKit runtime from #1619. The contract (manifest, JSON-RPC messages,
capabilities, approval, storage, view trees, tabs) does not change, and neither
do the API expansion and catalog specs of the same date, except where they name
`.wasm`.

## Why

The plugin ecosystem needs a language people already write. Rust compiled to Wasm
is the biggest barrier to contributions, and the alternatives inside WasmKit don't
work:

- **Kotlin** emits WasmGC, which WasmKit doesn't implement. Loading fails at the
  first GC type (`Malformed function type: 94`). The same applies to TeaVM, Dart and
  OCaml.
- **JavaScript in WasmKit** (QuickJS via Javy) is about 10x slower than Rust in
  real time, which would be fine. Fuel metering makes it unusable, though. WasmKit
  charges a whole function or loop body up front, and QuickJS's interpreter is one
  giant switch in one loop. A typical Kanban render costs 235M fuel against a 25M
  budget, and the ratio of fuel to time swings 80x between workloads, so no budget
  is both safe and fair.

JavaScriptCore is part of macOS, needs no dependency, and runs the same JS faster
than WasmKit runs Rust.

## Measurements

Same Kanban board render (50 cards) and workloads in every column. Release
builds on Apple silicon. The JSC binaries are signed with the hardened runtime and
no JIT entitlement, exactly as Alas ships. Scratch code is in `/tmp/js-plugin-spike`
and `/tmp/jsc-spike`.

| Median per call | Rust in WasmKit | JS in WasmKit (QuickJS) | JS in JSC, no JIT |
|---|---|---|---|
| Activate | 0.02 ms | 0.46 ms | 0.01 ms |
| Render, typical board (25 KB out) | 0.62 ms | 7.6 ms | 0.12 ms |
| Render, board at the caps (75–85 KB out) | 1.37 ms | 66 ms | 2.3 ms |
| Parse a 20 KB snapshot | 0.66 ms | 6.7 ms | 0.06 ms |
| Startup | 1 ms | 7 ms | 2–30 ms |

- **Runaway code.** `JSContextGroupSetExecutionTimeLimit` stopped `for (;;) {}`
  after 250 ms. The context kept its state and handled the next message normally.
- **JIT.** Under the hardened runtime with `com.apple.security.cs.allow-jit`, the
  heavy render drops to 0.72 ms, but **the time limit never fires**: `for (;;) {}`
  ran until killed. Without the entitlement JSC stays on its interpreter tiers and
  the limit works. An unsigned build with the JIT on also stops the loop, so only
  the hardened-plus-JIT combination is broken. We ship without the JIT entitlement.
- **Memory.** A plugin allocating as fast as it can reached 73 MB before the
  250 ms limit stopped it. JSC has no public per-context heap cap, so a plugin can
  still grow across many calls.

## Decisions

- **One runtime.** JavaScriptCore replaces WasmKit. Keeping both would double the
  SDK, docs and tests for little gain, and WasmKit is pinned to an unreleased
  revision and a `@_spi` limiter. The WasmKit and WAT packages leave `project.yml`.
- **One `JSContextGroup` per instance.** The time limit is set per group, and
  separate groups (separate VMs) keep plugins from sharing a heap or reaching
  each other's objects.
- **The global object is empty except for `alas`.** No `fetch`, timers, `require`,
  `console` bridged to stdout, or Objective-C bridging. The only host functions are:
  - `alas.send(json: string)`: one JSON-RPC message, same caps as today
    (1 MiB, 64 per call).
  - `alas.present(tab: number, pixels: Uint8Array, width: number)`: canvas
    frames, read with `JSObjectGetTypedArrayBytesPtr`.
  - the plugin defines `globalThis.handle(json: string)`. One delivery is one call.

  The JS ABI keeps strings, not objects, so the host validates exactly the bytes
  it validates today and the message code in `PluginHost` doesn't change.
- **Limits.**
  - A wall-clock limit replaces fuel: 250 ms per call, 1 s for `alas/activate`
    (the first call also evaluates the script).
  - Hitting the limit fails the plugin (`stopped: took longer than 250 ms`), the
    same rule as running out of fuel today.
  - Memory: no cap for now. JSC's per-VM heap statistics leave out typed-array
    storage (100 MB of typed arrays reported as 3.8 MB of heap), and the process
    footprint is shared with Alas, so neither can attribute memory to one plugin.
    The time limit bounds growth per call. A helper process is the upgrade if a
    plugin ever needs a real cap.
- **Entry point.** `"entry": "plugin.js"`, one file, evaluated once at
  activation. An ES module, a bundle produced by esbuild, or a plain script all
  work, because the plugin only has to assign `globalThis.handle`.
- **API version.** API 4 is the first JS API. A manifest with `api` 1–3 (the Wasm
  plugins) is refused with "this plugin was built for the WebAssembly runtime,
  which Alas no longer supports". No user has non-experimental plugins, so no
  migration path is needed.
- **Trust hash.** The same SHA-256 over manifest and entry bytes. Only the name of
  the second input changes.

## TypeScript SDK

`alas-plugins/sdk/alas-plugin` (Rust) is replaced by `sdk/alas` (TypeScript), an npm
package published from that repo:

- Typed messages for API 4 (generated by hand from `docs/plugins/api-v4.md`).
- `definePlugin({ activate, onMessage, onViewEvent, … })`, request ids and reply
  matching, the activation handshake. The same responsibilities as the Rust SDK.
- `testHost`: a fake that records sends and frames, so plugins test with
  `node --test` without Alas. It runs the plugin in Node, which has more globals
  than Alas does. A lint rule (no `fetch`, `setTimeout`, `process`) catches the
  common mistakes.
- Each plugin builds with `esbuild --bundle --format=iife` to one `plugin.js`.

## Rollout

Each step lands as its own PR.

1. **Runtime swap (alas).** Replace `PluginRuntime` with a JavaScriptCore version
   behind the same `load`/`handle`/`PluginDelivery` interface; drop WasmKit,
   `PluginWAT` and `alas.present`'s pointer checks. Rewrite the
   `PluginHostTests` and `PluginRuntimeTests` fixtures from WAT to small JS
   sources, which are shorter. The other plugin suites don't touch the runtime.
   Move `hello-workspace` to JS. Update `docs/plugins` to API 4 and JS.
2. **SDK and ports (alas-plugins).** TypeScript SDK, then Kanban, then Pixel
   Office. Pixel Office renders pixel buffers each frame, so it is the one to
   measure against the 250 ms limit before the port is done. Remove the Rust SDK.
   Change the release workflow to publish `plugin.js` and run `npm test` in CI.
3. **Catalog.** As in the repository spec, with `plugin.js` in place of
   `plugin.wasm`.
4. **API expansion.** As in the expansion spec, starting with API 5 for commands,
   settings and network, since API 4 is now the runtime switch.

## Risks

- **`JSContextGroupSetExecutionTimeLimit` is private.** It has been exported and
  used unchanged since 2014. If it goes away, the fallback is the helper process
  the phase 1 decision deferred, which also brings real memory caps and crash
  containment.
- **The JIT trap.** Anyone adding `allow-jit` to `Alas.entitlements` for another
  reason silently disables the plugin time limit, and tests won't notice because
  they don't run hardened. The ci-workflow contract test fails if the entitlements
  file contains `allow-jit`, with a message pointing here.
- **In-process.** A JSC crash takes Alas down, as a WasmKit crash would have.
  JSC is far more widely used than WasmKit.

## Testing

- `PluginRuntimeTests`: the limit stops `for (;;) {}` and the next delivery works;
  `send` size and count caps; `present` validation; a script that never defines
  `handle` fails activation; globals other than `alas` are absent (`fetch`,
  `setTimeout`, `require`).
- `PluginHostTests`: unchanged in intent, rewritten from WAT to JS fixtures.
- Delete the WAT fixture helper and any test that only pinned WasmKit behaviour
  (pointer ranges, exports' signatures, memory growth).
