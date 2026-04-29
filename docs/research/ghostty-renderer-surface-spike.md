# Ghostty Renderer Surface Feasibility Spike

## Questions

- What renderer components are accessible outside Ghostty's app?
- Does the renderer assume Ghostty-owned windows, surfaces, event loops, or GPU pipelines?
- Can a Ghostty-rendered surface live inside a GPUI element with clipping/focus/resize/input?
- What API changes or upstream work would be needed?

## Findings

- Local `libghostty-vt` inspection found terminal/VT render state APIs, not the full Ghostty GPU renderer. The Rust crate exposes `Terminal`, `RenderState`, render row/cell iterators, color/cursor data, focus/paste helpers, and key/mouse encoders. Its README also marks handles `!Send + !Sync`, so the safe API expects single-threaded ownership with any cross-thread coordination above it.
- The required registry search only matched render-state and input-encoding symbols in `libghostty-vt`/`libghostty-vt-sys`: `ghostty_render_state_*`, row/cell iterators, dirty-state docs, focus events, and mouse event positions in surface-space pixels. It did not expose `ghostty_surface_*`, renderer backends, Metal/OpenGL targets, GPU pipelines, or window/view handles through the installed Rust bindings.
- The vendored Ghostty checkout created by `libghostty-vt-sys` exists under `target/debug/build/.../ghostty-src`. Its `src/lib_vt.zig` public API explicitly exports terminal state plus input encoding; it does not export the app `Surface` or renderer backend through `libghostty-vt`.
- Full Ghostty sources do contain renderer and surface internals. `src/renderer.zig` says renderers are closely tied to the windowing system and assume the runtime has already prepared a context/surface, e.g. OpenGL context, Vulkan surface, or equivalent. The selected renderer is compile-time chosen (`Metal`, `OpenGL`, or `WebGL`) and wraps a generic renderer.
- Ghostty's core `src/Surface.zig` owns more than a drawable layer: it binds app/runtime surface pointers, renderer, renderer state, renderer thread, PTY/termio thread, font grid, mouse/keyboard state, resize, selection, focus, and config. `Surface.init` requires an `apprt.runtime.Surface`, initializes the renderer against it, starts Ghostty's renderer thread, starts termio, and later drives resize/draw through Ghostty mailboxes.
- The available embedded runtime in `src/apprt/embedded.zig` is a Ghostty host-embedding API, not the `libghostty-vt` Rust API. On Darwin it asks for an `NSView`/`UIView`, manages content scale and surface size, exposes `ghostty_surface_new`, `ghostty_surface_set_size`, `ghostty_surface_draw`, and related callbacks, and still routes through Ghostty's core app/surface lifecycle. No equivalent GPUI element/surface adapter is present locally.
- On macOS the Metal renderer initializes from the runtime surface's platform view and installs an `IOSurfaceLayer`; on OpenGL it renders to framebuffer/renderbuffer targets. Both paths presume Ghostty-controlled renderer lifecycle and a prepared native runtime surface. GPUI canvas painting, clipping, focus, resize, and input routing would need to cooperate with those native layer/context assumptions rather than simply borrow `RenderState`.
- A Ghostty-rendered surface inside a GPUI element is therefore not directly feasible with the currently installed Rust crates. It may be possible as a separate native embedding effort, but it would require a GPUI-to-Ghostty runtime bridge, native view/layer ownership decisions, lifecycle/thread integration, clipping/compositing behavior, focus and input translation, resize/content-scale synchronization, and likely upstream-stabilized APIs outside `libghostty-vt`.

## Recommendation

Continue the current GPUI canvas renderer path for V1. `libghostty-vt` gives Alas the right terminal state, render cells, colors, cursor metadata, and Ghostty-aware key/mouse encoders without taking over windows or GPU surfaces. Revisit true Ghostty renderer embedding only after the canvas path is working and only in a separate branch with explicit native runtime/API work.

Recommendation: continue GPUI canvas renderer; revisit embedding later
