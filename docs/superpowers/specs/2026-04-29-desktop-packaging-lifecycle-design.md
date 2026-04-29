# Desktop Packaging and App Lifecycle Design

## Summary

Alas should be buildable as a normal desktop application instead of only being run with `cargo run`. The first packaging target is an unsigned, developer-local macOS `.app` bundle, with Linux AppImage and Debian package support. The app should also behave like a normal desktop app: closing the last open window quits the process, and a standard Quit action/shortcut exits cleanly.

## Goals

- Build an unsigned macOS `Alas.app` locally for development and personal use.
- Build Linux AppImage and `.deb` packages locally.
- Add release-only CI artifact builds for macOS `.app`, Linux AppImage, and Linux `.deb`.
- Add predictable app shutdown behavior:
  - closing the last open window quits the app;
  - provide a standard Quit shortcut/action where GPUI supports it;
  - stop active terminal sessions on shutdown where possible.
- Document local packaging commands, prerequisites, and manual test steps.

## Non-goals

- Apple Developer ID signing and notarization in the first implementation.
- Auto-update support.
- Flatpak, Homebrew, Snap, RPM, or Windows packaging.
- Cross-compilation. The first implementation builds macOS artifacts on macOS and Linux artifacts on Linux.
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

`dist all` means “build all package formats supported on the current host.” On macOS it builds the macOS `.app` archive; on Linux it builds AppImage and `.deb`. If a target is unsupported on the current host, `xtask` should skip it for `dist all` with a clear message, while direct commands such as `dist macos` on Linux should fail with an explicit unsupported-host error.

## Architecture

### Workspace packaging helper

Add an `xtask` crate to the workspace. It owns packaging orchestration only; application logic stays in `src/`.

Responsibilities:

- Run `cargo build --release --all-features --package alas --bin alas` for the main `alas` binary.
- Resolve package metadata from the root `Cargo.toml` where possible.
- Normalize versions and architecture names for each package format.
- Create a clean `dist/` output tree.
- Stage platform-specific bundle/package directories.
- Invoke required external tools with clear errors when missing.
- Print output artifact paths on success.

Expected output layout:

```text
dist/
├── macos/
│   ├── Alas.app/
│   └── Alas-<version>-<arch>.zip
├── linux/
│   ├── appimage/
│   │   └── Alas-<version>-<arch>.AppImage
│   └── deb/
│       └── alas_<version>_<arch>.deb
└── staging/
```

### Version and architecture normalization

The packaging helper should derive the source version from `package.version` in `Cargo.toml`, then normalize it per platform:

- macOS `CFBundleShortVersionString`: numeric dotted version only, e.g. `1.2.3`. Strip prerelease and build metadata from SemVer values such as `1.2.3-alpha.1+build.5`.
- macOS `CFBundleVersion`: use the full Cargo version after replacing characters that are invalid or awkward in bundle versions with dots or hyphens; if this is too restrictive for macOS tooling, fall back to the numeric dotted version and include the full version only in artifact names/docs.
- Debian package version: use the Cargo version converted to Debian-compatible syntax. Prerelease identifiers should become Debian revision/order syntax, e.g. `1.2.3~alpha.1`; build metadata should be omitted from the Debian version or moved to an internal release suffix only if needed.
- Artifact filenames: use a filesystem-safe version derived from Cargo SemVer, preserving prerelease text and replacing `+` with `_`.

Architecture names should be mapped explicitly:

- Rust/macOS `aarch64` → artifact arch `arm64`; `x86_64` → `x86_64`.
- Debian `x86_64` → `amd64`; `aarch64` → `arm64`.
- AppImage artifact names should use common Linux names: `x86_64` or `aarch64`.

The first implementation can build per-host architecture artifacts only. Universal macOS binaries are a future extension.

### macOS `.app`

The macOS packaging command creates an unsigned app bundle and a zip archive suitable for release upload:

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
- `CFBundleIdentifier`: `dev.alas.Alas` as a temporary stable identifier unless the project owner provides a different reverse-DNS identifier before implementation
- `CFBundleExecutable`: `alas`
- `CFBundlePackageType`: `APPL`
- `CFBundleShortVersionString`: normalized numeric dotted version
- `CFBundleVersion`: normalized bundle version
- `LSMinimumSystemVersion`: a conservative supported macOS version, chosen during implementation based on GPUI/runtime requirements
- high-resolution capability flags if needed by GPUI

The release artifact should be `Alas-<version>-<arch>.zip`, produced with tooling that preserves executable bits and bundle structure (`ditto -c -k --keepParent` on macOS is preferred). A DMG is a future extension, not part of the first implementation.

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

Dependency policy for the first implementation:

- Bundle the Alas executable and project-owned metadata/icons in the AppDir.
- Use `ldd` or equivalent inspection to report dynamic library dependencies in the packaging output.
- Do not attempt aggressive bundling of core graphics/session libraries in the first pass unless `appimagetool` or a chosen helper handles them safely. Wayland/X11, GL, fontconfig, libc, and similar platform libraries may remain host dependencies initially.
- Document known required host packages for Ubuntu/Debian-style systems and refine after clean-machine testing.
- Treat AppImage as “portable across similar modern Linux desktop distributions,” not as a guarantee of running on every Linux installation.

Linux runtime dependencies for GPUI, Wayland/X11/fontconfig, and Ghostty/Zig build-time requirements should be documented. The package should not hide missing host runtime assumptions; failures should be explicit.

### Debian package

The Debian command can use either `cargo-deb` or explicit `dpkg-deb` staging. The implementation should prefer explicit staging plus Debian tooling if dependency detection is needed; otherwise `cargo-deb` is acceptable if it supports the required metadata cleanly.

Installed files:

```text
/usr/bin/alas
/usr/share/applications/alas.desktop
/usr/share/icons/hicolor/.../apps/alas.png or alas.svg
/usr/share/doc/alas/copyright
```

Package metadata:

- package name: `alas`
- version: Debian-normalized Cargo package version
- section: `devel` or `utils`
- priority: `optional`
- maintainer: project maintainer placeholder if none exists
- architecture: host architecture mapped to Debian architecture names
- dependencies: derive with `dpkg-shlibdeps` when available; otherwise use a documented conservative manual list based on `ldd` output and CI/manual testing

The `.deb` should follow standard Debian expectations more than AppImage expectations: system libraries should be declared in `Depends`, not bundled, unless a library is project-owned and installed under an application-specific path.

## App Lifecycle and Quit Behavior

Alas should not feel like a process that only developers can start and kill from a terminal.

Required behavior:

- Closing the last open window quits the application. If GPUI only supports one window today, the implementation should still use “last window” semantics where the API allows it.
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

- Missing external tools (`appimagetool`, `dpkg-deb`, `dpkg-shlibdeps`, `cargo-deb`, icon tooling) should name the missing tool and suggest an install path.
- Failed `cargo build --release --all-features --package alas --bin alas` should return the cargo failure directly.
- Missing icons or metadata should either use a committed placeholder or print the expected path.
- Unsupported host/target combinations should be explicit. The first implementation builds macOS bundles on macOS and Linux packages on Linux only.

Runtime quit cleanup should be best effort:

- Attempt to stop terminal sessions.
- Clear active terminal state.
- Continue exiting even if an individual terminal stop reports an error.

## Release Workflow

Keep the existing PR/push CI focused on formatting, clippy, Linux build, and tests.

Add a separate release-only workflow triggered by `release: published`. It should:

- Build an unsigned macOS `.app` on a macOS runner and upload `Alas-<version>-<arch>.zip` to the GitHub release.
- Build Linux AppImage and `.deb` artifacts on a Linux runner.
- Upload artifacts to the GitHub release that triggered the workflow.

The workflow should not run for every push. Tag-push-only artifact uploads are out of scope for the first implementation because they do not guarantee a GitHub Release upload target. If tag-push support is desired later, it should either create a draft release explicitly or store CI artifacts separately.

Signing/notarization secrets are out of scope for the first version, but the workflow should be structured so signing can be added later without redesigning packaging.

## Documentation Updates

Update `README.md` with:

- Difference between running from source and building installable artifacts.
- Local packaging commands.
- macOS unsigned app caveats, including Gatekeeper expectations.
- Linux packaging prerequisites, including AppImage, Debian package tooling, and known runtime dependency policy.
- Release artifact policy: local packaging is primary during development; GitHub artifacts are produced only for actual published releases.

Update `docs/manual-test.md` with packaging and lifecycle checks:

- Build and launch `Alas.app` by double-clicking on macOS.
- Confirm closing the last window quits the process.
- Confirm standard Quit shortcut works.
- Build AppImage and run it on Linux.
- Build `.deb`, install it, launch from terminal and desktop entry if available.
- Confirm packaged app can open a repository and start a terminal session.

## Testing Strategy

Automated tests:

- Unit-test `xtask` helper functions that compute paths, package names, architecture mappings, version normalization, and metadata rendering.
- Snapshot or string-test generated `Info.plist` and `.desktop` content.
- Test command argument parsing for `dist macos`, `dist linux-appimage`, `dist linux-deb`, and `dist all`.
- Test unsupported-host behavior for direct target commands and current-host-only behavior for `dist all`.

Manual tests:

- Use `docs/manual-test.md` for actual GUI launch, window close, Quit shortcut, and packaged artifact verification.
- Test macOS packaging on macOS and Linux packaging on Linux.

CI tests:

- Existing CI should continue to pass.
- Release workflow validates packaging commands on `release: published` triggers only.

## Open Decisions for Implementation

- Whether the project owner wants a bundle identifier other than temporary `dev.alas.Alas`.
- Final icon source and whether to commit a generated placeholder.
- Whether `.deb` is best produced by `cargo-deb` or by explicit `dpkg-deb` staging after dependency inspection.
- Exact GPUI API for close-window and Quit shortcut/menu handling in the pinned dependency version.
