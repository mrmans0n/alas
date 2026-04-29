# Desktop Packaging and App Lifecycle Design

## Summary

Alas should be buildable as a normal desktop application instead of only being run with `cargo run`. The first packaging target is an unsigned, developer-local macOS `.app` bundle, with Linux AppImage and Debian package support. The app should also behave like a normal desktop app: closing the only window quits the process, and a standard Quit action/shortcut exits cleanly.

## Goals

- Build an unsigned macOS `Alas.app` locally for development and personal use.
- Build Linux AppImage and `.deb` packages locally.
- Add release-only CI artifact builds for macOS `.app`, Linux AppImage, and Linux `.deb`.
- Add predictable app shutdown behavior:
  - closing the only window quits the app;
  - provide a standard Quit shortcut/action where GPUI supports it;
  - stop active terminal sessions on shutdown where possible.
- Document local packaging commands, prerequisites, and manual test steps.

## Non-goals

- Apple Developer ID signing and notarization in the first implementation.
- Auto-update support.
- Flatpak, Homebrew, Snap, RPM, or Windows packaging.
- A polished final product icon. A placeholder/generated icon is acceptable until a real icon exists.

## Recommended Approach

Use a small Rust `xtask` workspace crate as the packaging entrypoint, backed by standard platform packaging tools where useful. This keeps local packaging commands consistent and gives release CI a single stable command to run later.

Primary commands:

```bash
cargo xtask dist macos
cargo xtask dist linux-appimage
cargo xtask dist linux-deb
cargo xtask dist all
```

If `cargo xtask` aliasing is not configured, the equivalent command can be:

```bash
cargo run -p xtask -- dist <target>
```

## Architecture

### Workspace packaging helper

Add an `xtask` crate to the workspace. It owns packaging orchestration only; application logic stays in `src/`.

Responsibilities:

- Run `cargo build --release --all-features` for the main `alas` binary.
- Resolve package metadata from `Cargo.toml` where possible.
- Create a clean `dist/` output tree.
- Stage platform-specific bundle/package directories.
- Invoke required external tools with clear errors when missing.
- Print output artifact paths on success.

Expected output layout:

```text
dist/
├── macos/
│   └── Alas.app/
├── linux/
│   ├── appimage/
│   │   └── Alas-<version>-<arch>.AppImage
│   └── deb/
│       └── alas_<version>_<arch>.deb
└── staging/
```

### macOS `.app`

The macOS packaging command creates an unsigned app bundle:

```text
Alas.app/
└── Contents/
    ├── Info.plist
    ├── MacOS/
    │   └── alas
    └── Resources/
        └── Alas.icns
```

`Info.plist` should include:

- `CFBundleName`: `Alas`
- `CFBundleDisplayName`: `Alas`
- `CFBundleIdentifier`: a stable reverse-DNS identifier, e.g. `dev.alas.Alas` or project-specific equivalent
- `CFBundleExecutable`: `alas`
- `CFBundlePackageType`: `APPL`
- `CFBundleShortVersionString`: Cargo package version
- `CFBundleVersion`: Cargo package version or release build number
- `LSMinimumSystemVersion`: a conservative supported macOS version, chosen during implementation based on GPUI/runtime requirements
- high-resolution capability flags if needed by GPUI

The first implementation may use a placeholder icon. If no `.icns` exists, the packaging task should either generate one from committed source artwork or fail with a clear message telling the developer where to place it.

Signing/notarization should be left as a documented future extension, not mixed into the first local `.app` work.

### Linux AppImage

The AppImage command stages an AppDir:

```text
Alas.AppDir/
├── AppRun
├── alas.desktop
├── alas.png/svg
└── usr/
    └── bin/
        └── alas
```

The `.desktop` file should include:

```ini
[Desktop Entry]
Type=Application
Name=Alas
Comment=Native Git worktree and terminal workspace
Exec=alas
Icon=alas
Categories=Development;Utility;
Terminal=false
```

The `AppRun` script executes the packaged binary. The task invokes `appimagetool` if present. If it is missing, the task exits with a clear installation hint and preserves or identifies the staged AppDir for debugging.

Linux runtime dependencies for GPUI, Wayland/X11/fontconfig, and Ghostty/Zig build-time requirements should be documented. The package should not hide missing host runtime assumptions; failures should be explicit.

### Debian package

The Debian command can use either a standard helper such as `cargo-deb` or explicit `dpkg-deb` staging. The implementation should prefer the simpler reliable option after checking what fits GPUI native dependencies.

Installed files:

```text
/usr/bin/alas
/usr/share/applications/alas.desktop
/usr/share/icons/hicolor/.../apps/alas.png or alas.svg
/usr/share/doc/alas/copyright
```

Package metadata:

- package name: `alas`
- version: Cargo package version
- section: `devel` or `utils`
- priority: `optional`
- maintainer: project maintainer placeholder if none exists
- architecture: host architecture mapped to Debian architecture names
- dependencies: start conservative and document any known required system packages; refine after testing on a clean Debian/Ubuntu environment

## App Lifecycle and Quit Behavior

Alas should not feel like a process that only developers can start and kill from a terminal.

Required behavior:

- Closing the only window quits the application.
- Add a standard Quit action/shortcut where GPUI supports it:
  - macOS: `Cmd+Q`
  - Linux: `Ctrl+Q` if shortcut handling is available cleanly
- If GPUI exposes native menu APIs in the current dependency version, add a simple app menu with `Alas → Quit` on macOS.
- If native menu support is missing or unstable, implement keyboard quit first and document the menu limitation.
- Shutdown should attempt to stop active terminal sessions using the existing terminal cleanup path (`terminal_backend.stop(...)` through registry/session cleanup).
- Cleanup is best effort: failures should not hang quit forever.

Implementation should avoid adding unrelated session persistence or confirmation prompts. Users can already restart/retry terminal tabs; this task is only about normal desktop lifecycle behavior and packaging.

## Error Handling

Packaging commands should fail fast with actionable messages:

- Missing external tools (`appimagetool`, `dpkg-deb`, `cargo-deb`, icon tooling) should name the missing tool and suggest an install path.
- Failed `cargo build --release --all-features` should return the cargo failure directly.
- Missing icons or metadata should either use a committed placeholder or print the expected path.
- Unsupported host/target combinations should be explicit. The first implementation may build macOS bundles on macOS and Linux packages on Linux only.

Runtime quit cleanup should be best effort:

- Attempt to stop terminal sessions.
- Clear active terminal state.
- Continue exiting even if an individual terminal stop reports an error.

## Release Workflow

Keep the existing PR/push CI focused on formatting, clippy, Linux build, and tests.

Add a separate release-only workflow triggered by tags/releases. It should:

- Build macOS unsigned `.app` artifacts on a macOS runner.
- Build Linux AppImage and `.deb` artifacts on a Linux runner.
- Upload artifacts to the GitHub release.

This workflow should not run for every push. Signing/notarization secrets are out of scope for the first version, but the workflow should be structured so signing can be added later without redesigning packaging.

## Documentation Updates

Update `README.md` with:

- Difference between running from source and building installable artifacts.
- Local packaging commands.
- macOS unsigned app caveats, including Gatekeeper expectations.
- Linux packaging prerequisites, including AppImage and Debian package tooling.
- Release artifact policy: local packaging is primary during development; GitHub artifacts are produced only for actual releases.

Update `docs/manual-test.md` with packaging and lifecycle checks:

- Build and launch `Alas.app` by double-clicking on macOS.
- Confirm closing the only window quits the process.
- Confirm standard Quit shortcut works.
- Build AppImage and run it on Linux.
- Build `.deb`, install it, launch from terminal and desktop entry if available.
- Confirm packaged app can open a repository and start a terminal session.

## Testing Strategy

Automated tests:

- Unit-test `xtask` helper functions that compute paths, package names, architecture mappings, and metadata rendering.
- Snapshot or string-test generated `Info.plist` and `.desktop` content.
- Test command argument parsing for `dist macos`, `dist linux-appimage`, `dist linux-deb`, and `dist all`.

Manual tests:

- Use `docs/manual-test.md` for actual GUI launch, window close, Quit shortcut, and packaged artifact verification.
- Test macOS packaging on macOS and Linux packaging on Linux.

CI tests:

- Existing CI should continue to pass.
- Release workflow validates packaging commands on release triggers only.

## Open Decisions for Implementation

- Exact reverse-DNS bundle identifier.
- Final icon source and whether to commit a generated placeholder.
- Whether `.deb` is best produced by `cargo-deb` or by explicit `dpkg-deb` staging.
- Exact GPUI API for close-window and Quit shortcut/menu handling in the pinned dependency version.
