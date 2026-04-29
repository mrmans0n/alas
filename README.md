# Alas

Alas is a native Rust desktop app for managing Git repositories, their worktrees,
and persistent embedded terminals.

## Development

```bash
cargo test
cargo run
```

## Ghostty VT build

Alas V1 requires `libghostty-vt`. The crate builds Ghostty's VT library with Zig.

Requirements:
- Zig available on `PATH`
- network access for the crate's pinned Ghostty source, or `GHOSTTY_SOURCE_DIR=/path/to/ghostty` pointing at a checkout containing `build.zig`

If GitHub fetch fails, clone Ghostty separately and run:

```bash
GHOSTTY_SOURCE_DIR=/path/to/ghostty cargo test
```
