# AGENTS.md - alas

## Project
- Repo: `mrmans0n/alas`
- Stack: Rust desktop app built with GPUI
- Purpose: native workspace for Git repos, linked worktrees, files, Git changes, and persistent terminals

## Development rules
- Keep code, comments, logs, and UI strings in English.
- Prefer small, reviewable changes with tests when practical.
- Do not introduce large architectural changes without an explicit plan.
- Preserve the existing Rust/GPUI structure unless there is a clear reason to refactor.

## Before finishing a change
Run the same checks documented in `README.md` when relevant:

```bash
cargo fmt --all -- --check
cargo clippy --all-targets --all-features -- -D warnings
cargo build --all-features
cargo test --all-features
```

If Ghostty source resolution is needed locally, use `GHOSTTY_SOURCE_DIR=/path/to/ghostty` as documented in the README.
