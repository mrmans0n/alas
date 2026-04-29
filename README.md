# Alas

Alas is a native Rust desktop app for managing Git repositories, their worktrees,
and persistent embedded terminals.

## Development

```bash
cargo test
cargo run
```

The optional `ghostty-vt` feature depends on `libghostty-vt` and may require a
compatible Zig toolchain when enabled.
