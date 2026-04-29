# Alas

Alas is a native Rust desktop app for working across Git repositories, linked
worktrees, project files, Git changes, and long-lived terminal sessions from one
workspace.

It is currently an early-stage desktop app built with [GPUI](https://www.gpui.rs/)
and a Ghostty-backed terminal renderer.

## What it does

- Register local Git repositories and show their main and linked worktrees.
- Create, archive, unarchive, remove, and prune worktrees from the sidebar.
- Keep persistent terminal tabs per worktree, including failed/exited command
  state and restart/retry controls.
- Configure reusable commands and launch them in new terminal tabs.
- Inspect worktree files and Git changes without leaving the app.
- Render terminal output through Ghostty VT, including scrollback, alternate
  screen TUIs, colors, wide text, and resize handling.

## Prerequisites

- Rust 1.95+ with Cargo.
- Git 2.x+.
- Zig compatible with the pinned Ghostty source used by `libghostty-vt`
  (currently Zig 0.15.2).
- Network access for the first `libghostty-vt` build, unless you provide a local
  Ghostty checkout with `GHOSTTY_SOURCE_DIR=/path/to/ghostty`.

On macOS with Homebrew, Zig 0.15 can be installed and selected with:

```bash
brew install zig@0.15
export PATH="/opt/homebrew/opt/zig@0.15/bin:$PATH"
```

## Development

Build and test the default app configuration:

```bash
cargo build --all-features
cargo test --all-features
```

Run the app:

```bash
cargo run
```

Before pushing changes, run the same checks as CI:

```bash
cargo fmt --all -- --check
cargo clippy --all-targets --all-features -- -D warnings
cargo build --all-features
cargo test --all-features
```

If the Ghostty source download fails, clone Ghostty separately and point the
build at it:

```bash
GHOSTTY_SOURCE_DIR=/path/to/ghostty cargo test --all-features
```

## Building installable artifacts

During development, `cargo run` still works, but Alas can also be packaged as a desktop app.

Local packaging commands:

```bash
cargo xtask dist macos          # macOS host only; creates dist/macos/Alas.app and a zip
cargo xtask dist linux-appimage # Linux host only; creates an AppImage
cargo xtask dist linux-deb      # Linux host only; creates a .deb
cargo xtask dist all            # all package formats supported by the current host
```

The equivalent command without the Cargo alias is:

```bash
cargo run -p xtask -- dist <target>
```

### macOS

The first macOS artifact is an unsigned local `Alas.app`. You can launch it from
`dist/macos/Alas.app` after building. Because it is unsigned and not notarized,
Gatekeeper may require right-click → Open or a local security exception.

Signing, notarization, and DMG creation are planned future release improvements.

### Linux

Linux packaging currently targets AppImage and Debian packages.

Build prerequisites are the same as development plus packaging tools:

```bash
sudo apt-get install -y \
  libfontconfig1-dev \
  libwayland-dev \
  libxkbcommon-dev \
  pkg-config \
  dpkg-dev
```

AppImage builds also require `appimagetool` on `PATH`.

The AppImage bundles the Alas executable and app metadata, but some desktop
runtime libraries such as Wayland/X11, GL, fontconfig, and libc may still be
provided by the host distribution. The `.deb` declares runtime dependencies
instead of bundling system libraries.

### Release artifacts

Pull request and push CI only format, lint, build, and test. GitHub release
artifacts are built only when a release is published.

## Manual testing

Automated tests cover the app model, configuration, Git/worktree services,
terminal sessions, terminal rendering, file tree loading, and inspector state.
For desktop behavior that requires a real window or interactive terminal, use
[`docs/manual-test.md`](docs/manual-test.md).

## Repository layout

```text
src/
├── app/       # App state, action registry, workspace/session model
├── config/    # App and per-repository configuration
├── git/       # Git repository, inspector, and worktree services
├── project/   # File tree loading
├── terminal/  # Terminal sessions, Ghostty adapter, rendering, input
└── ui/        # GPUI shell, sidebar, dialogs, inspector, terminal views

tests/         # Unit and integration-style tests
docs/          # Manual testing and research notes
examples/      # Development probes and experiments
```
