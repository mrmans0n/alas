# Desktop Packaging and Lifecycle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build local macOS `.app`, Linux AppImage, and Linux `.deb` artifacts for Alas, and make app shutdown behave like a normal desktop app.

**Architecture:** Add a focused `xtask` workspace crate that owns packaging orchestration, metadata rendering, staging, and host/tool checks while leaving app code untouched. Add a small GPUI lifecycle module for Quit actions, menus, keybindings, last-window quit, and best-effort terminal cleanup. Keep release packaging behind a `release: published` workflow.

**Tech Stack:** Rust 2024, Cargo workspace + `.cargo` alias, GPUI 0.2.2 actions/keybindings/menus/window-close hooks, AppImage `appimagetool`, Debian `dpkg-deb`/`dpkg-shlibdeps`, GitHub Actions.

---

## Reference Documents

- Spec: `docs/superpowers/specs/2026-04-29-desktop-packaging-lifecycle-design.md`
- GPUI examples to consult during implementation:
  - `~/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/gpui-0.2.2/examples/on_window_close_quit.rs`
  - `~/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/gpui-0.2.2/examples/set_menus.rs`
  - `~/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/gpui-0.2.2/examples/input.rs`

## File Structure

Create/modify these files:

- Modify: `Cargo.toml`
  - Add `[workspace]`, `members = ["xtask"]`, `resolver = "3"`, and keep the existing root package as the app package.
- Create: `.cargo/config.toml`
  - Add alias so `cargo xtask ...` works locally.
- Create: `xtask/Cargo.toml`
  - Dependencies for CLI helpers and tests.
- Create: `xtask/src/main.rs`
  - CLI entrypoint and top-level command dispatch.
- Create: `xtask/src/dist.rs`
  - `dist` command orchestration and host-target behavior.
- Create: `xtask/src/metadata.rs`
  - Cargo package metadata loading and artifact naming.
- Create: `xtask/src/version.rs`
  - Cargo SemVer normalization for macOS, Debian, and filenames.
- Create: `xtask/src/arch.rs`
  - Rust architecture to macOS/AppImage/Debian architecture names.
- Create: `xtask/src/templates.rs`
  - Render `Info.plist`, `.desktop`, `AppRun`, and Debian control/copyright text.
- Create: `xtask/src/fs.rs`
  - File copy, directory reset, executable bit helpers, zip/tool command helpers.
- Create: `xtask/src/platform/macos.rs`
  - Stage `Alas.app` and create `Alas-<version>-<arch>.zip` on macOS.
- Create: `xtask/src/platform/linux_appimage.rs`
  - Stage AppDir and invoke `appimagetool` on Linux.
- Create: `xtask/src/platform/linux_deb.rs`
  - Stage Debian package root and invoke `dpkg-deb` on Linux.
- Create: `assets/alas.svg`
  - Placeholder vector icon source.
- Create: `assets/alas.iconset/README.md` or generate icon files during packaging.
  - Document placeholder icon generation if macOS `.icns` cannot be committed in this task.
- Modify: `src/terminal/session.rs`
  - Add a drain method so lifecycle cleanup can stop all active sessions.
- Modify: `tests/terminal_session_tests.rs`
  - Cover the new registry drain method.
- Create: `src/ui/lifecycle.rs`
  - GPUI actions, keybindings, app menu, window-closed handler, and app-level quit helper.
- Modify: `src/ui/mod.rs`
  - Export lifecycle module.
- Modify: `src/ui/shell.rs`
  - Add `AlasShell::shutdown`, call lifecycle setup in `run`, and connect Quit action to cleanup.
- Create: `tests/desktop_metadata_tests.rs` only if root app metadata tests are needed outside `xtask`; prefer `xtask` unit tests first.
- Modify: `.github/workflows/build.yml`
  - Usually unchanged; only adjust if workspace conversion requires an explicit package/default member tweak.
- Create: `.github/workflows/release.yml`
  - Release-only artifact workflow triggered by `release: published`.
- Modify: `README.md`
  - Add installable artifact build docs.
- Modify: `docs/manual-test.md`
  - Add packaging/lifecycle manual checks.

Do not move existing app modules. Keep lifecycle changes small and packaging code inside `xtask`.

---

### Task 1: Add workspace and xtask skeleton

**Files:**
- Modify: `Cargo.toml`
- Create: `.cargo/config.toml`
- Create: `xtask/Cargo.toml`
- Create: `xtask/src/main.rs`
- Create: `xtask/src/dist.rs`

- [ ] **Step 1: Write failing xtask CLI tests**

Create `xtask/src/main.rs` with module declarations and tests first. Use a small parser function that does not execute packaging so argument behavior is testable.

```rust
mod dist;

use anyhow::{bail, Result};

#[derive(Debug, Clone, PartialEq, Eq)]
enum Command {
    Dist(dist::DistTarget),
}

fn parse_command(args: &[&str]) -> Result<Command> {
    match args {
        ["dist", target] => Ok(Command::Dist(dist::DistTarget::parse(target)?)),
        ["dist"] => bail!("missing dist target: expected macos, linux-appimage, linux-deb, or all"),
        [] => bail!("missing command: expected dist"),
        [other, ..] => bail!("unknown command: {other}"),
    }
}

fn run(args: impl IntoIterator<Item = String>) -> Result<()> {
    let args: Vec<String> = args.into_iter().collect();
    let refs: Vec<&str> = args.iter().map(String::as_str).collect();
    match parse_command(&refs)? {
        Command::Dist(target) => dist::run(target),
    }
}

fn main() -> Result<()> {
    run(std::env::args().skip(1))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_dist_targets() {
        assert_eq!(parse_command(&["dist", "macos"]).unwrap(), Command::Dist(dist::DistTarget::Macos));
        assert_eq!(parse_command(&["dist", "linux-appimage"]).unwrap(), Command::Dist(dist::DistTarget::LinuxAppImage));
        assert_eq!(parse_command(&["dist", "linux-deb"]).unwrap(), Command::Dist(dist::DistTarget::LinuxDeb));
        assert_eq!(parse_command(&["dist", "all"]).unwrap(), Command::Dist(dist::DistTarget::All));
    }

    #[test]
    fn rejects_unknown_command() {
        let error = parse_command(&["ship"]).unwrap_err().to_string();
        assert!(error.contains("unknown command"));
    }

    #[test]
    fn rejects_missing_dist_target() {
        let error = parse_command(&["dist"]).unwrap_err().to_string();
        assert!(error.contains("missing dist target"));
    }
}
```

Create `xtask/src/dist.rs` with the minimal target enum and parser tests:

```rust
use anyhow::{bail, Result};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DistTarget {
    Macos,
    LinuxAppImage,
    LinuxDeb,
    All,
}

impl DistTarget {
    pub fn parse(value: &str) -> Result<Self> {
        match value {
            "macos" => Ok(Self::Macos),
            "linux-appimage" => Ok(Self::LinuxAppImage),
            "linux-deb" => Ok(Self::LinuxDeb),
            "all" => Ok(Self::All),
            other => bail!("unknown dist target: {other}"),
        }
    }
}

pub fn run(_target: DistTarget) -> Result<()> {
    bail!("dist implementation not wired yet")
}
```

- [ ] **Step 2: Add workspace files but expect tests to fail before dependencies are declared**

Modify root `Cargo.toml` to add a workspace section below existing package/dependency sections:

```toml
[workspace]
members = ["xtask"]
resolver = "3"
```

Create `.cargo/config.toml`:

```toml
[alias]
xtask = "run --package xtask --"
```

Create `xtask/Cargo.toml`:

```toml
[package]
name = "xtask"
version = "0.1.0"
edition = "2024"
publish = false

[dependencies]
anyhow = "1"
serde = { version = "1", features = ["derive"] }
toml = "0.8"

[dev-dependencies]
tempfile = "3"
pretty_assertions = "1"
```

- [ ] **Step 3: Run tests to verify skeleton behavior**

Run:

```bash
cargo test --package xtask
```

Expected: parser tests pass, but if `dist::run` is accidentally exercised by tests it fails with `dist implementation not wired yet`.

- [ ] **Step 4: Commit**

```bash
git add Cargo.toml .cargo/config.toml xtask/Cargo.toml xtask/src/main.rs xtask/src/dist.rs
git commit -m "build: add xtask packaging skeleton"
```

---

### Task 2: Add version and architecture normalization

**Files:**
- Create: `xtask/src/version.rs`
- Create: `xtask/src/arch.rs`
- Modify: `xtask/src/main.rs`

- [ ] **Step 1: Write failing tests for version normalization**

Create `xtask/src/version.rs`:

```rust
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VersionInfo {
    pub cargo: String,
    pub macos_short: String,
    pub macos_bundle: String,
    pub debian: String,
    pub filename: String,
}

pub fn normalize_version(cargo_version: &str) -> VersionInfo {
    todo!("normalize Cargo SemVer for package targets")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalizes_plain_semver() {
        let version = normalize_version("1.2.3");
        assert_eq!(version.macos_short, "1.2.3");
        assert_eq!(version.macos_bundle, "1.2.3");
        assert_eq!(version.debian, "1.2.3");
        assert_eq!(version.filename, "1.2.3");
    }

    #[test]
    fn normalizes_prerelease_and_build_metadata() {
        let version = normalize_version("1.2.3-alpha.1+build.5");
        assert_eq!(version.macos_short, "1.2.3");
        assert_eq!(version.macos_bundle, "1.2.3");
        assert_eq!(version.debian, "1.2.3~alpha.1");
        assert_eq!(version.filename, "1.2.3-alpha.1_build.5");
    }
}
```

- [ ] **Step 2: Write failing tests for architecture mapping**

Create `xtask/src/arch.rs`:

```rust
use anyhow::{bail, Result};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ArchNames {
    pub rust: String,
    pub macos_artifact: String,
    pub appimage_artifact: String,
    pub debian: String,
}

pub fn arch_names(rust_arch: &str) -> Result<ArchNames> {
    todo!("map Rust host arch to package arch names")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn maps_x86_64() {
        let names = arch_names("x86_64").unwrap();
        assert_eq!(names.macos_artifact, "x86_64");
        assert_eq!(names.appimage_artifact, "x86_64");
        assert_eq!(names.debian, "amd64");
    }

    #[test]
    fn maps_aarch64() {
        let names = arch_names("aarch64").unwrap();
        assert_eq!(names.macos_artifact, "arm64");
        assert_eq!(names.appimage_artifact, "aarch64");
        assert_eq!(names.debian, "arm64");
    }

    #[test]
    fn rejects_unknown_architecture() {
        let error = arch_names("mips").unwrap_err().to_string();
        assert!(error.contains("unsupported architecture"));
    }
}
```

- [ ] **Step 3: Run tests and confirm they fail for `todo!`**

Run:

```bash
cargo test --package xtask version::
cargo test --package xtask arch::
```

Expected: tests fail/panic because implementations are `todo!`.

- [ ] **Step 4: Implement normalization and mappings**

Replace `normalize_version` with simple SemVer string splitting. Keep this dependency-free unless `semver` becomes clearly worthwhile.

```rust
pub fn normalize_version(cargo_version: &str) -> VersionInfo {
    let (without_build, build) = cargo_version
        .split_once('+')
        .map_or((cargo_version, None), |(left, right)| (left, Some(right)));
    let (core, prerelease) = without_build
        .split_once('-')
        .map_or((without_build, None), |(left, right)| (left, Some(right)));

    let macos_bundle = core.to_string();

    let debian = prerelease
        .map(|pre| format!("{core}~{pre}"))
        .unwrap_or_else(|| core.to_string());

    VersionInfo {
        cargo: cargo_version.to_string(),
        macos_short: core.to_string(),
        macos_bundle,
        debian,
        filename: cargo_version.replace('+', "_"),
    }
}
```

Replace `arch_names`:

```rust
pub fn arch_names(rust_arch: &str) -> Result<ArchNames> {
    let (macos_artifact, appimage_artifact, debian) = match rust_arch {
        "x86_64" => ("x86_64", "x86_64", "amd64"),
        "aarch64" => ("arm64", "aarch64", "arm64"),
        other => bail!("unsupported architecture: {other}"),
    };

    Ok(ArchNames {
        rust: rust_arch.to_string(),
        macos_artifact: macos_artifact.to_string(),
        appimage_artifact: appimage_artifact.to_string(),
        debian: debian.to_string(),
    })
}
```

Update `xtask/src/main.rs` module list:

```rust
mod arch;
mod dist;
mod version;
```

- [ ] **Step 5: Run tests and verify pass**

Run:

```bash
cargo test --package xtask version::
cargo test --package xtask arch::
```

Expected: all version and arch tests pass.

- [ ] **Step 6: Commit**

```bash
git add xtask/src/main.rs xtask/src/version.rs xtask/src/arch.rs
git commit -m "build: normalize package versions and architectures"
```

---

### Task 3: Add package metadata loading and artifact naming

**Files:**
- Create: `xtask/src/metadata.rs`
- Modify: `xtask/src/main.rs`

- [ ] **Step 1: Write failing metadata tests**

Create `xtask/src/metadata.rs`:

```rust
use std::path::{Path, PathBuf};

use anyhow::Result;
use serde::Deserialize;

use crate::{arch::ArchNames, version::VersionInfo};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PackageMetadata {
    pub name: String,
    pub display_name: String,
    pub version: VersionInfo,
    pub arch: ArchNames,
    pub root: PathBuf,
    pub target_release_binary: PathBuf,
}

pub fn load(root: &Path) -> Result<PackageMetadata> {
    todo!("load root Cargo.toml package metadata")
}

pub fn macos_zip_name(meta: &PackageMetadata) -> String {
    format!("Alas-{}-{}.zip", meta.version.filename, meta.arch.macos_artifact)
}

pub fn appimage_name(meta: &PackageMetadata) -> String {
    format!("Alas-{}-{}.AppImage", meta.version.filename, meta.arch.appimage_artifact)
}

pub fn deb_name(meta: &PackageMetadata) -> String {
    format!("alas_{}_{}.deb", meta.version.debian, meta.arch.debian)
}

#[derive(Debug, Deserialize)]
struct CargoManifest {
    package: CargoPackage,
}

#[derive(Debug, Deserialize)]
struct CargoPackage {
    name: String,
    version: String,
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{fs, path::Path};

    #[test]
    fn loads_package_metadata_from_root_manifest() {
        let temp = tempfile::tempdir().unwrap();
        fs::write(
            temp.path().join("Cargo.toml"),
            r#"
[package]
name = "alas"
version = "1.2.3-alpha.1+build.5"
edition = "2024"
"#,
        )
        .unwrap();

        let meta = load(temp.path()).unwrap();
        assert_eq!(meta.name, "alas");
        assert_eq!(meta.display_name, "Alas");
        assert_eq!(meta.version.macos_short, "1.2.3");
        assert_eq!(meta.target_release_binary, temp.path().join("target/release/alas"));
    }

    #[test]
    fn builds_artifact_names() {
        let meta = PackageMetadata {
            name: "alas".to_string(),
            display_name: "Alas".to_string(),
            version: crate::version::normalize_version("1.2.3-alpha.1+build.5"),
            arch: crate::arch::arch_names("x86_64").unwrap(),
            root: Path::new("/repo").to_path_buf(),
            target_release_binary: Path::new("/repo/target/release/alas").to_path_buf(),
        };

        assert_eq!(macos_zip_name(&meta), "Alas-1.2.3-alpha.1_build.5-x86_64.zip");
        assert_eq!(appimage_name(&meta), "Alas-1.2.3-alpha.1_build.5-x86_64.AppImage");
        assert_eq!(deb_name(&meta), "alas_1.2.3~alpha.1_amd64.deb");
    }
}
```

- [ ] **Step 2: Run failing tests**

Run:

```bash
cargo test --package xtask metadata::
```

Expected: fails because `load` is `todo!`.

- [ ] **Step 3: Implement metadata loading**

Implement `load`:

```rust
pub fn load(root: &Path) -> Result<PackageMetadata> {
    let manifest_path = root.join("Cargo.toml");
    let manifest_text = std::fs::read_to_string(&manifest_path)?;
    let manifest: CargoManifest = toml::from_str(&manifest_text)?;
    let arch = crate::arch::arch_names(std::env::consts::ARCH)?;

    Ok(PackageMetadata {
        display_name: "Alas".to_string(),
        target_release_binary: root.join("target").join("release").join(&manifest.package.name),
        version: crate::version::normalize_version(&manifest.package.version),
        name: manifest.package.name,
        arch,
        root: root.to_path_buf(),
    })
}
```

Update `xtask/src/main.rs` module list:

```rust
mod arch;
mod dist;
mod metadata;
mod version;
```

- [ ] **Step 4: Run metadata tests**

Run:

```bash
cargo test --package xtask metadata::
```

Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add xtask/src/main.rs xtask/src/metadata.rs
git commit -m "build: load packaging metadata"
```

---

### Task 4: Add template renderers

**Files:**
- Create: `xtask/src/templates.rs`
- Modify: `xtask/src/main.rs`

- [ ] **Step 1: Write failing template tests**

Create `xtask/src/templates.rs`:

```rust
use crate::metadata::PackageMetadata;

pub fn info_plist(meta: &PackageMetadata) -> String {
    todo!("render macOS Info.plist")
}

pub fn desktop_entry() -> String {
    todo!("render desktop entry")
}

pub fn app_run() -> String {
    todo!("render AppRun script")
}

pub fn debian_control(meta: &PackageMetadata, depends: &[String]) -> String {
    todo!("render Debian control file")
}

pub fn debian_copyright() -> String {
    todo!("render Debian copyright placeholder")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::Path;

    fn meta() -> PackageMetadata {
        PackageMetadata {
            name: "alas".to_string(),
            display_name: "Alas".to_string(),
            version: crate::version::normalize_version("1.2.3-alpha.1+build.5"),
            arch: crate::arch::arch_names("x86_64").unwrap(),
            root: Path::new("/repo").to_path_buf(),
            target_release_binary: Path::new("/repo/target/release/alas").to_path_buf(),
        }
    }

    #[test]
    fn renders_info_plist() {
        let plist = info_plist(&meta());
        assert!(plist.contains("<key>CFBundleName</key>"));
        assert!(plist.contains("<string>Alas</string>"));
        assert!(plist.contains("<key>CFBundleExecutable</key>"));
        assert!(plist.contains("<string>alas</string>"));
        assert!(plist.contains("<key>CFBundleIconFile</key>"));
        assert!(plist.contains("<string>Alas</string>"));
        assert!(plist.contains("<key>CFBundleIdentifier</key>"));
        assert!(plist.contains("<string>dev.alas.Alas</string>"));
        assert!(plist.contains("<key>CFBundleShortVersionString</key>"));
        assert!(plist.contains("<string>1.2.3</string>"));
    }

    #[test]
    fn renders_desktop_entry() {
        let desktop = desktop_entry();
        assert!(desktop.contains("Type=Application"));
        assert!(desktop.contains("Name=Alas"));
        assert!(desktop.contains("Exec=alas"));
        assert!(desktop.contains("Icon=alas"));
        assert!(desktop.contains("Categories=Development;Utility;"));
        assert!(desktop.contains("Terminal=false"));
    }

    #[test]
    fn renders_app_run_script() {
        let script = app_run();
        assert!(script.starts_with("#!/bin/sh"));
        assert!(script.contains("exec \"$APPDIR/usr/bin/alas\" \"$@\""));
    }

    #[test]
    fn renders_debian_control_with_dependencies() {
        let control = debian_control(&meta(), &["libfontconfig1".into(), "libxkbcommon0".into()]);
        assert!(control.contains("Package: alas"));
        assert!(control.contains("Version: 1.2.3~alpha.1"));
        assert!(control.contains("Architecture: amd64"));
        assert!(control.contains("Depends: libfontconfig1, libxkbcommon0"));
    }
}
```

- [ ] **Step 2: Run failing tests**

Run:

```bash
cargo test --package xtask templates::
```

Expected: fails because template functions are `todo!`.

- [ ] **Step 3: Implement template functions**

Use straightforward string rendering. Example `info_plist` body:

```rust
pub fn info_plist(meta: &PackageMetadata) -> String {
    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>{display}</string>
  <key>CFBundleDisplayName</key>
  <string>{display}</string>
  <key>CFBundleIdentifier</key>
  <string>dev.alas.Alas</string>
  <key>CFBundleExecutable</key>
  <string>{binary}</string>
  <key>CFBundleIconFile</key>
  <string>Alas</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>{short_version}</string>
  <key>CFBundleVersion</key>
  <string>{bundle_version}</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
"#,
        display = meta.display_name,
        binary = meta.name,
        short_version = meta.version.macos_short,
        bundle_version = meta.version.macos_bundle,
    )
}
```

Use this for `desktop_entry`:

```rust
pub fn desktop_entry() -> String {
    r#"[Desktop Entry]
Type=Application
Name=Alas
Comment=Native Git worktree and terminal workspace
Exec=alas
Icon=alas
Categories=Development;Utility;
Terminal=false
"#
    .to_string()
}
```

Use this for `app_run`:

```rust
pub fn app_run() -> String {
    r#"#!/bin/sh
APPDIR="$(dirname "$(readlink -f "$0")")"
exec "$APPDIR/usr/bin/alas" "$@"
"#
    .to_string()
}
```

Use this for Debian control:

```rust
pub fn debian_control(meta: &PackageMetadata, depends: &[String]) -> String {
    let depends = if depends.is_empty() {
        "libc6".to_string()
    } else {
        depends.join(", ")
    };
    format!(
        "Package: alas\nVersion: {}\nSection: devel\nPriority: optional\nArchitecture: {}\nMaintainer: Alas Maintainers <maintainers@example.invalid>\nDepends: {}\nDescription: Native Git worktree and terminal workspace\n Alas is a native desktop app for working across Git repositories, worktrees, files, changes, and terminals.\n",
        meta.version.debian, meta.arch.debian, depends
    )
}
```

- [ ] **Step 4: Run template tests**

Run:

```bash
cargo test --package xtask templates::
```

Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add xtask/src/main.rs xtask/src/templates.rs
git commit -m "build: render desktop packaging metadata"
```

---

### Task 5: Add filesystem and command helpers

**Files:**
- Create: `xtask/src/fs.rs`
- Modify: `xtask/src/main.rs`

- [ ] **Step 1: Write failing tests for safe directory reset and executable bits**

Create `xtask/src/fs.rs`:

```rust
use std::path::Path;

use anyhow::Result;

pub fn reset_dir(path: &Path) -> Result<()> {
    todo!("remove existing dir and recreate")
}

pub fn copy_file(from: &Path, to: &Path) -> Result<()> {
    todo!("copy file creating parent dirs")
}

#[cfg(unix)]
pub fn make_executable(path: &Path) -> Result<()> {
    todo!("chmod +x")
}

#[cfg(not(unix))]
pub fn make_executable(_path: &Path) -> Result<()> {
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn reset_dir_removes_existing_contents() {
        let temp = tempfile::tempdir().unwrap();
        let dir = temp.path().join("staging");
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("old.txt"), "old").unwrap();

        reset_dir(&dir).unwrap();

        assert!(dir.is_dir());
        assert!(!dir.join("old.txt").exists());
    }

    #[test]
    fn copy_file_creates_parent_dirs() {
        let temp = tempfile::tempdir().unwrap();
        let source = temp.path().join("source.txt");
        let dest = temp.path().join("nested/target.txt");
        fs::write(&source, "hello").unwrap();

        copy_file(&source, &dest).unwrap();

        assert_eq!(fs::read_to_string(dest).unwrap(), "hello");
    }
}
```

- [ ] **Step 2: Run failing tests**

Run:

```bash
cargo test --package xtask fs::
```

Expected: fails because helpers are `todo!`.

- [ ] **Step 3: Implement helpers**

```rust
pub fn reset_dir(path: &Path) -> Result<()> {
    if path.exists() {
        std::fs::remove_dir_all(path)?;
    }
    std::fs::create_dir_all(path)?;
    Ok(())
}

pub fn copy_file(from: &Path, to: &Path) -> Result<()> {
    if let Some(parent) = to.parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::copy(from, to)?;
    Ok(())
}

#[cfg(unix)]
pub fn make_executable(path: &Path) -> Result<()> {
    use std::os::unix::fs::PermissionsExt;
    let mut permissions = std::fs::metadata(path)?.permissions();
    permissions.set_mode(permissions.mode() | 0o755);
    std::fs::set_permissions(path, permissions)?;
    Ok(())
}
```

Update `xtask/src/main.rs` module list:

```rust
mod arch;
mod dist;
mod fs;
mod metadata;
mod templates;
mod version;
```

- [ ] **Step 4: Run tests**

Run:

```bash
cargo test --package xtask fs::
```

Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add xtask/src/main.rs xtask/src/fs.rs
git commit -m "build: add packaging filesystem helpers"
```

---

### Task 6: Add placeholder assets

**Files:**
- Create: `assets/alas.svg`
- Create: `assets/README.md`

- [ ] **Step 1: Add a placeholder icon source**

Create `assets/alas.svg`:

```xml
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" role="img" aria-label="Alas icon placeholder">
  <rect width="512" height="512" rx="96" fill="#111827"/>
  <path d="M128 352 L224 128 H288 L384 352 H320 L300 304 H212 L192 352 Z" fill="#F9FAFB"/>
  <path d="M232 248 H280 L256 184 Z" fill="#60A5FA"/>
  <rect x="128" y="384" width="256" height="24" rx="12" fill="#60A5FA"/>
</svg>
```

Create `assets/README.md`:

```markdown
# Alas Assets

`alas.svg` is a placeholder application icon used by local packaging tasks.
Replace it with final artwork before signed/notarized distribution.

macOS packaging may generate an `.icns` from this source when icon tooling is available,
or fail with a clear message describing where to place `Alas.icns`.
```

- [ ] **Step 2: Verify asset files exist**

Run:

```bash
test -f assets/alas.svg && test -f assets/README.md
```

Expected: command exits 0.

- [ ] **Step 3: Commit**

```bash
git add assets/alas.svg assets/README.md
git commit -m "build: add placeholder app icon asset"
```

---

### Task 7: Implement macOS bundle staging

**Files:**
- Create: `xtask/src/platform/mod.rs`
- Create: `xtask/src/platform/macos.rs`
- Modify: `xtask/src/main.rs`

- [ ] **Step 1: Write failing tests for macOS app staging paths**

Create `xtask/src/platform/mod.rs`:

```rust
pub mod macos;
```

Create `xtask/src/platform/macos.rs` with tests:

```rust
use std::path::{Path, PathBuf};

use anyhow::Result;

use crate::metadata::PackageMetadata;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MacosBundlePaths {
    pub app_dir: PathBuf,
    pub contents_dir: PathBuf,
    pub macos_dir: PathBuf,
    pub resources_dir: PathBuf,
    pub executable: PathBuf,
    pub info_plist: PathBuf,
    pub icon: PathBuf,
    pub zip: PathBuf,
}

pub fn bundle_paths(dist_dir: &Path, meta: &PackageMetadata) -> MacosBundlePaths {
    todo!("compute macOS bundle paths")
}

pub fn stage_app(dist_dir: &Path, meta: &PackageMetadata) -> Result<MacosBundlePaths> {
    todo!("stage macOS .app")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::Path;

    fn meta() -> PackageMetadata {
        PackageMetadata {
            name: "alas".to_string(),
            display_name: "Alas".to_string(),
            version: crate::version::normalize_version("1.2.3"),
            arch: crate::arch::arch_names("aarch64").unwrap(),
            root: Path::new("/repo").to_path_buf(),
            target_release_binary: Path::new("/repo/target/release/alas").to_path_buf(),
        }
    }

    #[test]
    fn computes_bundle_paths() {
        let paths = bundle_paths(Path::new("/repo/dist/macos"), &meta());
        assert_eq!(paths.app_dir, Path::new("/repo/dist/macos/Alas.app"));
        assert_eq!(paths.executable, Path::new("/repo/dist/macos/Alas.app/Contents/MacOS/alas"));
        assert_eq!(paths.info_plist, Path::new("/repo/dist/macos/Alas.app/Contents/Info.plist"));
        assert_eq!(paths.zip, Path::new("/repo/dist/macos/Alas-1.2.3-arm64.zip"));
    }
}
```

- [ ] **Step 2: Run failing tests**

Run:

```bash
cargo test --package xtask platform::macos::
```

Expected: fails because `bundle_paths` is `todo!`.

- [ ] **Step 3: Implement bundle path computation and staging**

Implement path computation:

```rust
pub fn bundle_paths(dist_dir: &Path, meta: &PackageMetadata) -> MacosBundlePaths {
    let app_dir = dist_dir.join("Alas.app");
    let contents_dir = app_dir.join("Contents");
    let macos_dir = contents_dir.join("MacOS");
    let resources_dir = contents_dir.join("Resources");
    MacosBundlePaths {
        executable: macos_dir.join(&meta.name),
        info_plist: contents_dir.join("Info.plist"),
        icon: resources_dir.join("Alas.icns"),
        zip: dist_dir.join(crate::metadata::macos_zip_name(meta)),
        app_dir,
        contents_dir,
        macos_dir,
        resources_dir,
    }
}
```

Implement `stage_app` to:

1. `reset_dir(&paths.app_dir)`.
2. Create `Contents/MacOS` and `Contents/Resources`.
3. Copy `meta.target_release_binary` to `paths.executable`.
4. Mark executable with `fs::make_executable`.
5. Write `templates::info_plist(meta)` to `paths.info_plist`.
6. Prepare `Contents/Resources/Alas.icns` by calling a helper `prepare_icon(meta, &paths.icon)`.

Implement `prepare_icon` with this policy:

```rust
fn prepare_icon(meta: &PackageMetadata, destination: &Path) -> Result<()> {
    let committed_icns = meta.root.join("assets/Alas.icns");
    if committed_icns.exists() {
        return crate::fs::copy_file(&committed_icns, destination);
    }

    #[cfg(target_os = "macos")]
    {
        generate_icns_from_svg(meta, destination)
            .map_err(|error| anyhow::anyhow!("failed to generate Alas.icns from assets/alas.svg: {error}. Install/use macOS sips+iconutil or place a committed assets/Alas.icns file"))
    }

    #[cfg(not(target_os = "macos"))]
    {
        let _ = meta;
        let _ = destination;
        anyhow::bail!("missing assets/Alas.icns; macOS icon generation requires a macOS host with sips and iconutil")
    }
}
```

`generate_icns_from_svg` can initially use macOS `sips`/`iconutil` if those tools are available. If SVG conversion with `sips` is unreliable, fail with the clear message above and document placing `assets/Alas.icns`. Do not silently package only an SVG because `Info.plist` declares `CFBundleIconFile`.

Add a test that creates a fake binary and a fake committed `assets/Alas.icns`, then asserts staged files exist:

```rust
#[test]
fn stages_app_bundle_with_binary_plist_and_icon() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path();
    let binary = root.join("target/release/alas");
    std::fs::create_dir_all(binary.parent().unwrap()).unwrap();
    std::fs::write(&binary, "fake-binary").unwrap();
    std::fs::create_dir_all(root.join("assets")).unwrap();
    std::fs::write(root.join("assets/Alas.icns"), "fake-icon").unwrap();

    let mut meta = meta();
    meta.root = root.to_path_buf();
    meta.target_release_binary = binary;

    let paths = stage_app(&root.join("dist/macos"), &meta).unwrap();

    assert!(paths.executable.exists());
    assert!(paths.info_plist.exists());
    assert!(paths.icon.exists());
}
```

- [ ] **Step 4: Run macOS staging tests**

Run:

```bash
cargo test --package xtask platform::macos::
```

Expected: pass.

- [ ] **Step 5: Add host-only zip command function**

Add a function that runs only on macOS:

```rust
pub fn zip_app(paths: &MacosBundlePaths) -> Result<()> {
    #[cfg(target_os = "macos")]
    {
        let status = std::process::Command::new("ditto")
            .arg("-c")
            .arg("-k")
            .arg("--keepParent")
            .arg(paths.app_dir.file_name().unwrap())
            .arg(paths.zip.file_name().unwrap())
            .current_dir(paths.app_dir.parent().unwrap())
            .status()?;
        if !status.success() {
            anyhow::bail!("ditto failed while creating {}", paths.zip.display());
        }
        Ok(())
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = paths;
        anyhow::bail!("macOS packaging requires a macOS host")
    }
}
```

Do not call `zip_app` from unit tests on non-macOS.

- [ ] **Step 6: Update module list and run tests**

Update `xtask/src/main.rs`:

```rust
mod platform;
```

Run:

```bash
cargo test --package xtask
```

Expected: all xtask tests pass.

- [ ] **Step 7: Commit**

```bash
git add xtask/src/main.rs xtask/src/platform/mod.rs xtask/src/platform/macos.rs
git commit -m "build: stage macOS app bundle"
```

---

### Task 8: Implement Linux AppImage staging

**Files:**
- Modify: `xtask/src/platform/mod.rs`
- Create: `xtask/src/platform/linux_appimage.rs`

- [ ] **Step 1: Write failing AppDir path tests**

Create `xtask/src/platform/linux_appimage.rs`:

```rust
use std::path::{Path, PathBuf};

use anyhow::Result;

use crate::metadata::PackageMetadata;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AppImagePaths {
    pub app_dir: PathBuf,
    pub usr_bin: PathBuf,
    pub executable: PathBuf,
    pub desktop: PathBuf,
    pub app_run: PathBuf,
    pub icon_svg: PathBuf,
    pub output: PathBuf,
}

pub fn appimage_paths(dist_dir: &Path, meta: &PackageMetadata) -> AppImagePaths {
    todo!("compute AppImage paths")
}

pub fn stage_appdir(dist_dir: &Path, meta: &PackageMetadata) -> Result<AppImagePaths> {
    todo!("stage AppDir")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::Path;

    fn meta() -> PackageMetadata {
        PackageMetadata {
            name: "alas".to_string(),
            display_name: "Alas".to_string(),
            version: crate::version::normalize_version("1.2.3"),
            arch: crate::arch::arch_names("x86_64").unwrap(),
            root: Path::new("/repo").to_path_buf(),
            target_release_binary: Path::new("/repo/target/release/alas").to_path_buf(),
        }
    }

    #[test]
    fn computes_appimage_paths() {
        let paths = appimage_paths(Path::new("/repo/dist/linux/appimage"), &meta());
        assert_eq!(paths.app_dir, Path::new("/repo/dist/linux/appimage/Alas.AppDir"));
        assert_eq!(paths.executable, Path::new("/repo/dist/linux/appimage/Alas.AppDir/usr/bin/alas"));
        assert_eq!(paths.desktop, Path::new("/repo/dist/linux/appimage/Alas.AppDir/alas.desktop"));
        assert_eq!(paths.output, Path::new("/repo/dist/linux/appimage/Alas-1.2.3-x86_64.AppImage"));
    }
}
```

- [ ] **Step 2: Run failing tests**

Run:

```bash
cargo test --package xtask platform::linux_appimage::
```

Expected: fails because `appimage_paths` is `todo!`.

- [ ] **Step 3: Implement AppDir path computation and staging**

Update `xtask/src/platform/mod.rs`:

```rust
pub mod linux_appimage;
pub mod macos;
```

Implement `appimage_paths` similarly to macOS. Implement `stage_appdir` to:

1. Reset `Alas.AppDir`.
2. Create `usr/bin`.
3. Copy release binary to `usr/bin/alas` and make executable.
4. Write `templates::desktop_entry()` to `alas.desktop` at AppDir root.
5. Write `templates::app_run()` to `AppRun` and make it executable.
6. Copy `assets/alas.svg` to AppDir root as `alas.svg`.

Add a staging test with a fake binary, similar to macOS.

- [ ] **Step 4: Add AppImage tool invocation**

Add:

```rust
pub fn build_appimage(paths: &AppImagePaths) -> Result<()> {
    #[cfg(target_os = "linux")]
    {
        let status = std::process::Command::new("appimagetool")
            .arg(&paths.app_dir)
            .arg(&paths.output)
            .status()
            .map_err(|error| anyhow::anyhow!("failed to run appimagetool: {error}. Install appimagetool and ensure it is on PATH"))?;
        if !status.success() {
            anyhow::bail!("appimagetool failed while creating {}", paths.output.display());
        }
        Ok(())
    }
    #[cfg(not(target_os = "linux"))]
    {
        let _ = paths;
        anyhow::bail!("AppImage packaging requires a Linux host")
    }
}
```

Also add a non-fatal dependency report helper used later by `dist`:

```rust
pub fn print_ldd_report(binary: &Path) {
    #[cfg(target_os = "linux")]
    {
        if let Ok(output) = std::process::Command::new("ldd").arg(binary).output() {
            println!("Dynamic dependencies for {}:\n{}", binary.display(), String::from_utf8_lossy(&output.stdout));
        }
    }
}
```

- [ ] **Step 5: Run AppImage tests**

Run:

```bash
cargo test --package xtask platform::linux_appimage::
```

Expected: pass. Tests should not require `appimagetool`.

- [ ] **Step 6: Commit**

```bash
git add xtask/src/platform/mod.rs xtask/src/platform/linux_appimage.rs
git commit -m "build: stage Linux AppImage appdir"
```

---

### Task 9: Implement Debian package staging

**Files:**
- Modify: `xtask/src/platform/mod.rs`
- Create: `xtask/src/platform/linux_deb.rs`

- [ ] **Step 1: Write failing Debian path/control tests**

Create `xtask/src/platform/linux_deb.rs`:

```rust
use std::path::{Path, PathBuf};

use anyhow::Result;

use crate::metadata::PackageMetadata;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DebPaths {
    pub package_root: PathBuf,
    pub debian_dir: PathBuf,
    pub control: PathBuf,
    pub executable: PathBuf,
    pub desktop: PathBuf,
    pub icon_svg: PathBuf,
    pub copyright: PathBuf,
    pub output: PathBuf,
}

pub fn deb_paths(dist_dir: &Path, meta: &PackageMetadata) -> DebPaths {
    todo!("compute Debian package paths")
}

pub fn stage_deb(dist_dir: &Path, meta: &PackageMetadata, depends: &[String]) -> Result<DebPaths> {
    todo!("stage Debian package root")
}

pub fn default_depends() -> Vec<String> {
    vec![
        "libc6".into(),
        "libfontconfig1".into(),
        "libxkbcommon0".into(),
        "libwayland-client0".into(),
        "libwayland-cursor0".into(),
        "libgl1".into(),
    ]
}

pub fn parse_shlibdeps_substvars(text: &str) -> Vec<String> {
    todo!("parse shlibs:Depends from dpkg-shlibdeps substvars output")
}

pub fn derive_depends(binary: &Path) -> Vec<String> {
    todo!("run dpkg-shlibdeps when available, otherwise return default_depends")
}
```

Add tests:

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use std::path::Path;

    fn meta() -> PackageMetadata {
        PackageMetadata {
            name: "alas".to_string(),
            display_name: "Alas".to_string(),
            version: crate::version::normalize_version("1.2.3"),
            arch: crate::arch::arch_names("x86_64").unwrap(),
            root: Path::new("/repo").to_path_buf(),
            target_release_binary: Path::new("/repo/target/release/alas").to_path_buf(),
        }
    }

    #[test]
    fn computes_deb_paths() {
        let paths = deb_paths(Path::new("/repo/dist/linux/deb"), &meta());
        assert_eq!(paths.package_root, Path::new("/repo/dist/linux/deb/alas_1.2.3_amd64"));
        assert_eq!(paths.executable, Path::new("/repo/dist/linux/deb/alas_1.2.3_amd64/usr/bin/alas"));
        assert_eq!(paths.control, Path::new("/repo/dist/linux/deb/alas_1.2.3_amd64/DEBIAN/control"));
        assert_eq!(paths.output, Path::new("/repo/dist/linux/deb/alas_1.2.3_amd64.deb"));
    }

    #[test]
    fn default_dependencies_cover_known_gpui_runtime_libs() {
        let deps = default_depends();
        assert!(deps.contains(&"libfontconfig1".to_string()));
        assert!(deps.contains(&"libxkbcommon0".to_string()));
        assert!(deps.contains(&"libwayland-client0".to_string()));
        assert!(deps.contains(&"libgl1".to_string()));
    }

    #[test]
    fn parses_dpkg_shlibdeps_substvars() {
        let deps = parse_shlibdeps_substvars(
            "shlibs:Depends=libc6 (>= 2.34), libfontconfig1 (>= 2.13), libxkbcommon0 (>= 0.5.0)\n",
        );
        assert_eq!(
            deps,
            vec![
                "libc6 (>= 2.34)",
                "libfontconfig1 (>= 2.13)",
                "libxkbcommon0 (>= 0.5.0)",
            ]
        );
    }
}
```

- [ ] **Step 2: Run failing tests**

Run:

```bash
cargo test --package xtask platform::linux_deb::
```

Expected: fails because `deb_paths` is `todo!`.

- [ ] **Step 3: Implement Debian staging**

Update `xtask/src/platform/mod.rs`:

```rust
pub mod linux_appimage;
pub mod linux_deb;
pub mod macos;
```

Implement `deb_paths`. Implement dependency helpers:

- `parse_shlibdeps_substvars` scans for a line starting `shlibs:Depends=` and splits the comma-separated dependency list.
- `derive_depends(binary)` should try to run `dpkg-shlibdeps -O <binary>` on Linux when available, parse stdout with `parse_shlibdeps_substvars`, and return parsed dependencies if non-empty.
- If `dpkg-shlibdeps` is unavailable, fails, or returns no dependencies, print a warning and return `default_depends()`.
- Unit tests cover parsing and defaults only; they must not require `dpkg-shlibdeps`.

Implement `stage_deb` to:

1. Reset package root.
2. Create `DEBIAN`, `usr/bin`, `usr/share/applications`, `usr/share/icons/hicolor/scalable/apps`, and `usr/share/doc/alas`.
3. Copy binary to `usr/bin/alas` and make executable.
4. Write `.desktop`, icon SVG, control, and copyright files using the dependency list passed by the caller.

Add staging test with fake binary and custom deps:

```rust
#[test]
fn stages_deb_root() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path();
    let binary = root.join("target/release/alas");
    std::fs::create_dir_all(binary.parent().unwrap()).unwrap();
    std::fs::write(&binary, "fake-binary").unwrap();

    let mut meta = meta();
    meta.root = root.to_path_buf();
    meta.target_release_binary = binary;

    let paths = stage_deb(&root.join("dist/linux/deb"), &meta, &["libc6".into()]).unwrap();
    assert!(paths.executable.exists());
    assert!(paths.desktop.exists());
    assert!(paths.control.exists());
    assert!(std::fs::read_to_string(paths.control).unwrap().contains("Depends: libc6"));
}
```

- [ ] **Step 4: Add `dpkg-deb` invocation**

```rust
pub fn build_deb(paths: &DebPaths) -> Result<()> {
    #[cfg(target_os = "linux")]
    {
        let status = std::process::Command::new("dpkg-deb")
            .arg("--build")
            .arg(&paths.package_root)
            .arg(&paths.output)
            .status()
            .map_err(|error| anyhow::anyhow!("failed to run dpkg-deb: {error}. Install dpkg-deb and ensure it is on PATH"))?;
        if !status.success() {
            anyhow::bail!("dpkg-deb failed while creating {}", paths.output.display());
        }
        Ok(())
    }
    #[cfg(not(target_os = "linux"))]
    {
        let _ = paths;
        anyhow::bail!("Debian packaging requires a Linux host")
    }
}
```

Do not require `dpkg-deb` in unit tests.

- [ ] **Step 5: Run tests**

Run:

```bash
cargo test --package xtask platform::linux_deb::
```

Expected: pass.

- [ ] **Step 6: Commit**

```bash
git add xtask/src/platform/mod.rs xtask/src/platform/linux_deb.rs
git commit -m "build: stage Debian package root"
```

---

### Task 10: Wire xtask dist orchestration

**Files:**
- Modify: `xtask/src/dist.rs`

- [ ] **Step 1: Write failing tests for host target selection**

Extend `xtask/src/dist.rs` with pure helper functions:

```rust
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HostOs {
    Macos,
    Linux,
    Other,
}

pub fn targets_for_host(target: DistTarget, host: HostOs) -> Result<Vec<DistTarget>> {
    todo!("resolve direct target/all target by host")
}
```

Add tests:

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn all_on_macos_builds_macos_only() {
        assert_eq!(targets_for_host(DistTarget::All, HostOs::Macos).unwrap(), vec![DistTarget::Macos]);
    }

    #[test]
    fn all_on_linux_builds_linux_formats() {
        assert_eq!(
            targets_for_host(DistTarget::All, HostOs::Linux).unwrap(),
            vec![DistTarget::LinuxAppImage, DistTarget::LinuxDeb]
        );
    }

    #[test]
    fn direct_wrong_host_fails() {
        let error = targets_for_host(DistTarget::Macos, HostOs::Linux).unwrap_err().to_string();
        assert!(error.contains("requires a macOS host"));
    }
}
```

- [ ] **Step 2: Run failing tests**

Run:

```bash
cargo test --package xtask dist::
```

Expected: fails because `targets_for_host` is `todo!`, and possibly because old `run` still always bails.

- [ ] **Step 3: Implement host selection and build command**

Implement:

```rust
pub fn targets_for_host(target: DistTarget, host: HostOs) -> Result<Vec<DistTarget>> {
    match (target, host) {
        (DistTarget::All, HostOs::Macos) => Ok(vec![DistTarget::Macos]),
        (DistTarget::All, HostOs::Linux) => Ok(vec![DistTarget::LinuxAppImage, DistTarget::LinuxDeb]),
        (DistTarget::All, HostOs::Other) => bail!("no packaging targets are supported on this host"),
        (DistTarget::Macos, HostOs::Macos) => Ok(vec![DistTarget::Macos]),
        (DistTarget::Macos, _) => bail!("macOS packaging requires a macOS host"),
        (DistTarget::LinuxAppImage, HostOs::Linux) => Ok(vec![DistTarget::LinuxAppImage]),
        (DistTarget::LinuxAppImage, _) => bail!("AppImage packaging requires a Linux host"),
        (DistTarget::LinuxDeb, HostOs::Linux) => Ok(vec![DistTarget::LinuxDeb]),
        (DistTarget::LinuxDeb, _) => bail!("Debian packaging requires a Linux host"),
    }
}

fn current_host() -> HostOs {
    match std::env::consts::OS {
        "macos" => HostOs::Macos,
        "linux" => HostOs::Linux,
        _ => HostOs::Other,
    }
}
```

Add build helper:

```rust
fn build_release(root: &std::path::Path) -> Result<()> {
    let status = std::process::Command::new("cargo")
        .args(["build", "--release", "--all-features", "--package", "alas", "--bin", "alas"])
        .current_dir(root)
        .status()?;
    if !status.success() {
        bail!("cargo release build failed");
    }
    Ok(())
}
```

Implement `run` to:

1. Get `root = current_dir()`.
2. `let targets = targets_for_host(target, current_host())?`.
3. Load metadata.
4. Run `build_release` once.
5. For each resolved target:
   - macOS: `stage_app`, `zip_app`, print zip path.
   - Linux AppImage: `stage_appdir`, `print_ldd_report`, `build_appimage`, print output path.
   - Linux Deb: `let depends = derive_depends(&meta.target_release_binary);`, then `stage_deb(..., &depends)`, `build_deb`, print output path.

- [ ] **Step 4: Run xtask tests**

Run:

```bash
cargo test --package xtask
```

Expected: all xtask tests pass and do not invoke external packaging tools.

- [ ] **Step 5: Smoke-test unsupported host behavior for current machine**

On macOS, run:

```bash
cargo xtask dist linux-deb
```

Expected: fails with `Debian packaging requires a Linux host`.

On Linux, run:

```bash
cargo xtask dist macos
```

Expected: fails with `macOS packaging requires a macOS host`.

- [ ] **Step 6: Commit**

```bash
git add xtask/src/dist.rs
git commit -m "build: wire desktop distribution commands"
```

---

### Task 11: Add terminal registry drain for shutdown cleanup

**Files:**
- Modify: `src/terminal/session.rs`
- Modify: `tests/terminal_session_tests.rs`

- [ ] **Step 1: Write failing registry drain test**

Append to `tests/terminal_session_tests.rs`:

```rust
#[test]
fn remove_all_sessions_drains_registry() {
    use alas::terminal::{CommandSpec, TerminalBackendSession, TerminalSessionId, TerminalSessionRegistry};
    use alas::app::TerminalTabId;
    use std::path::PathBuf;

    let mut registry = TerminalSessionRegistry::default();
    let id_one = TerminalSessionId::new("repo", PathBuf::from("/tmp/one"), TerminalTabId(1));
    let id_two = TerminalSessionId::new("repo", PathBuf::from("/tmp/two"), TerminalTabId(2));
    let command = CommandSpec::shell_command("echo ok", PathBuf::from("/tmp"));

    registry.attach_existing(id_one.clone(), command.clone(), TerminalBackendSession { backend_id: 1 });
    registry.attach_existing(id_two.clone(), command, TerminalBackendSession { backend_id: 2 });

    let removed = registry.remove_all_sessions();

    assert_eq!(removed.len(), 2);
    assert!(registry.get(&id_one).is_none());
    assert!(registry.get(&id_two).is_none());
}
```

- [ ] **Step 2: Run failing test**

Run:

```bash
cargo test --test terminal_session_tests remove_all_sessions_drains_registry --all-features
```

Expected: fails because `remove_all_sessions` does not exist.

- [ ] **Step 3: Implement registry drain**

In `src/terminal/session.rs`, add to `impl TerminalSessionRegistry`:

```rust
pub fn remove_all_sessions(&mut self) -> Vec<TerminalSessionRef> {
    self.sessions.drain().map(|(_, session)| session).collect()
}
```

- [ ] **Step 4: Run terminal session tests**

Run:

```bash
cargo test --test terminal_session_tests --all-features
```

Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add src/terminal/session.rs tests/terminal_session_tests.rs
git commit -m "feat: drain terminal sessions for shutdown"
```

---

### Task 12: Add GPUI lifecycle setup and Quit action

**Files:**
- Create: `src/ui/lifecycle.rs`
- Modify: `src/ui/mod.rs`
- Modify: `src/ui/shell.rs`

- [ ] **Step 1: Add lifecycle module with GPUI action and setup function**

Create `src/ui/lifecycle.rs`:

```rust
use gpui::{actions, App, KeyBinding, Menu, MenuItem, SystemMenuType};

actions!(alas, [Quit]);

pub fn setup_lifecycle(cx: &mut App) {
    cx.bind_keys([
        KeyBinding::new("cmd-q", Quit, None),
        KeyBinding::new("ctrl-q", Quit, None),
    ]);
    cx.set_menus(vec![Menu {
        name: "Alas".into(),
        items: vec![
            MenuItem::os_submenu("Services", SystemMenuType::Services),
            MenuItem::separator(),
            MenuItem::action("Quit", Quit),
        ],
    }]);
    cx.on_window_closed(|cx| {
        if cx.windows().is_empty() {
            cx.quit();
        }
    })
    .detach();
}
```

If `SystemMenuType` or menu APIs differ, follow `gpui-0.2.2/examples/set_menus.rs` exactly.

- [ ] **Step 2: Run compile check before wiring shell cleanup**

Update `src/ui/mod.rs`:

```rust
pub mod lifecycle;
```

Run:

```bash
cargo check --all-features
```

Expected: lifecycle module compiles or reveals exact GPUI API adjustments needed.

- [ ] **Step 3: Add best-effort shell shutdown helper**

In `src/ui/shell.rs`, add method inside `impl AlasShell` near existing cleanup helpers:

```rust
fn shutdown(&mut self) {
    let sessions = self.terminal_registry.remove_all_sessions();
    self.stop_terminal_sessions(sessions);
    self.active_terminal = None;
    self.active_terminal_tab = None;
    self.terminal_scroll_offset_rows = 0;
}
```

Register cleanup for both graceful app quit and pre-window-close. GPUI 0.2.2 exposes `Context::on_app_quit`, whose future is polled during graceful application shutdown, and `Window::on_window_should_close`, which runs before the window-owned shell entity is dropped.

In `AlasShell::new`, after `shell.start_terminal_refresh(cx);`, add:

```rust
shell.register_app_quit_cleanup(cx);
```

Add this method inside `impl AlasShell`:

```rust
fn register_app_quit_cleanup(&self, cx: &mut Context<Self>) {
    cx.on_app_quit(|shell, _cx| {
        shell.shutdown();
        async {}
    })
    .detach();
}
```

The `on_app_quit` handler covers Quit menu and keyboard-shortcut exits. Add a window should-close hook in `run()` to cover traffic-light/window-manager close before the shell entity is dropped.

Then add a root element action handler inside `Render for AlasShell` so `Quit` actions explicitly request app shutdown:

```rust
.on_action(cx.listener(|_shell, _: &crate::ui::lifecycle::Quit, _window, cx| {
    cx.quit();
}))
```

Place this near the root `div()` chain in `render`. Do not call `shutdown()` directly from the action handler; `on_app_quit` is the single cleanup path.

Recommended final split:

- `setup_lifecycle(cx)` registers keybindings, menus, and `on_window_closed`.
- `AlasShell::register_app_quit_cleanup` registers `on_app_quit` and calls `shutdown()` for graceful menu/shortcut exits.
- `run()` registers `window.on_window_should_close(...)` and calls `shutdown()` before allowing a window close.
- `AlasShell` root `.on_action(...)` handles `Quit` by calling `cx.quit()`.
- `on_window_closed` calls `cx.quit()` when `cx.windows().is_empty()`; window-close cleanup has already run in `on_window_should_close`.

- [ ] **Step 4: Update `run` to install lifecycle hooks**

Modify `src/ui/shell.rs` `run()`:

```rust
pub fn run() -> anyhow::Result<()> {
    Application::new().run(|cx: &mut App| {
        crate::ui::lifecycle::setup_lifecycle(cx);
        cx.open_window(WindowOptions::default(), |window, cx| {
            let shell = cx.new(AlasShell::new);
            let weak_shell = shell.downgrade();
            window.on_window_should_close(cx, move |_window, cx| {
                weak_shell
                    .update(cx, |shell, _cx| shell.shutdown())
                    .ok();
                true
            });
            shell
        })
        .expect("failed to open Alas window");
    });

    Ok(())
}
```

- [ ] **Step 5: Run compile and focused tests**

Run:

```bash
cargo check --all-features
cargo test --test terminal_session_tests --all-features
```

Expected: compile passes and terminal session tests pass.

- [ ] **Step 6: Commit**

```bash
git add src/ui/lifecycle.rs src/ui/mod.rs src/ui/shell.rs
git commit -m "feat: add desktop quit lifecycle"
```

---

### Task 13: Add release-only workflow

**Files:**
- Create: `.github/workflows/release.yml`

- [ ] **Step 1: Create release workflow**

Create `.github/workflows/release.yml`:

```yaml
name: Release Artifacts

on:
  release:
    types: [published]

permissions:
  contents: write

env:
  CARGO_TERM_COLOR: always

jobs:
  macos-app:
    runs-on: macos-latest
    timeout-minutes: 45
    steps:
      - uses: actions/checkout@v6

      - name: Install Zig
        uses: mlugg/setup-zig@v2
        with:
          version: 0.15.2

      - name: Build macOS app bundle
        run: cargo xtask dist macos

      - name: Upload macOS artifact to release
        uses: softprops/action-gh-release@v2
        with:
          files: dist/macos/*.zip

  linux-packages:
    runs-on: ubuntu-latest
    timeout-minutes: 45
    steps:
      - uses: actions/checkout@v6

      - name: Install Linux build and packaging dependencies
        run: |
          sudo apt-get update
          sudo apt-get install -y \
            libfontconfig1-dev \
            libwayland-dev \
            libxkbcommon-dev \
            pkg-config \
            dpkg-dev \
            wget \
            file \
            fuse

      - name: Install pinned appimagetool
        env:
          APPIMAGETOOL_URL: https://github.com/AppImage/appimagetool/releases/download/1.9.1/appimagetool-x86_64.AppImage
          APPIMAGETOOL_SHA256: ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0
        run: |
          wget -O appimagetool "$APPIMAGETOOL_URL"
          echo "$APPIMAGETOOL_SHA256  appimagetool" | sha256sum -c -
          chmod +x appimagetool
          sudo mv appimagetool /usr/local/bin/appimagetool

      - name: Install Zig
        uses: mlugg/setup-zig@v2
        with:
          version: 0.15.2

      - name: Build AppImage
        env:
          APPIMAGE_EXTRACT_AND_RUN: 1
        run: cargo xtask dist linux-appimage

      - name: Build Debian package
        run: cargo xtask dist linux-deb

      - name: Upload Linux artifacts to release
        uses: softprops/action-gh-release@v2
        with:
          files: |
            dist/linux/appimage/*.AppImage
            dist/linux/deb/*.deb
```

- [ ] **Step 2: Validate YAML shape locally if tooling exists**

Run:

```bash
ruby -e 'require "yaml"; YAML.load_file(".github/workflows/release.yml"); puts "ok"'
```

Expected: prints `ok`. If Ruby is unavailable, run `python3 - <<'PY'` with `yaml` only if PyYAML exists; otherwise visually inspect.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/release.yml
git commit -m "ci: add release artifact workflow"
```

---

### Task 14: Update README packaging docs

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add docs section after Development or before Manual testing**

Add:

```markdown
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
```

- [ ] **Step 2: Check markdown formatting**

Run:

```bash
rg -n "Building installable artifacts|cargo xtask dist|Release artifacts" README.md
```

Expected: all headings/commands are found.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: document desktop packaging commands"
```

---

### Task 15: Update manual test checklist

**Files:**
- Modify: `docs/manual-test.md`

- [ ] **Step 1: Add packaging/lifecycle manual test section**

Append near the top, after startup instructions:

```markdown
## Desktop Packaging and Lifecycle

### macOS `.app`

1. On macOS, build the app bundle with `cargo xtask dist macos`.
2. Confirm `dist/macos/Alas.app` exists.
3. Launch `Alas.app` by double-clicking it in Finder.
4. Add/open a repository and start a terminal session.
5. Press `Cmd+Q`; confirm the app exits.
6. Relaunch, then close the window with the traffic-light close button; confirm the process exits.
7. Confirm `dist/macos/Alas-<version>-<arch>.zip` exists.

### Linux AppImage

1. On Linux, ensure `appimagetool` is on `PATH`.
2. Build with `cargo xtask dist linux-appimage`.
3. Confirm `dist/linux/appimage/*.AppImage` exists and is executable.
4. Run the AppImage.
5. Add/open a repository and start a terminal session.
6. Press `Ctrl+Q`; confirm the app exits.
7. Relaunch and close the window; confirm the process exits.

### Linux Debian package

1. On Linux, build with `cargo xtask dist linux-deb`.
2. Confirm `dist/linux/deb/*.deb` exists.
3. Install with `sudo apt install ./dist/linux/deb/<package>.deb`.
4. Launch `alas` from a terminal and, if available, from the desktop app launcher.
5. Add/open a repository and start a terminal session.
6. Confirm Quit shortcut and window close exit the app.
7. Remove the package after testing if desired.
```

- [ ] **Step 2: Check section exists**

Run:

```bash
rg -n "Desktop Packaging and Lifecycle|macOS `.app`|Linux AppImage|Linux Debian package" docs/manual-test.md
```

Expected: all new section headings are found.

- [ ] **Step 3: Commit**

```bash
git add docs/manual-test.md
git commit -m "docs: add desktop packaging manual tests"
```

---

### Task 16: Full verification

**Files:**
- No new files unless fixes are needed.

- [ ] **Step 1: Run formatting**

Run:

```bash
cargo fmt --all -- --check
```

Expected: pass. If it fails, run `cargo fmt --all`, inspect changes, and commit formatting with the relevant task if possible.

- [ ] **Step 2: Run clippy**

Run:

```bash
cargo clippy --all-targets --all-features -- -D warnings
```

Expected: pass. Fix warnings rather than allowing them.

- [ ] **Step 3: Run all tests**

Run:

```bash
cargo test --all-features
cargo test --package xtask
```

Expected: pass.

- [ ] **Step 4: Run host-appropriate packaging smoke test**

On macOS:

```bash
cargo xtask dist macos
ls -la dist/macos
```

Expected: `Alas.app` and `Alas-<version>-<arch>.zip` exist.

On Linux:

```bash
cargo xtask dist linux-deb
ls -la dist/linux/deb
```

Expected: `.deb` exists. If `appimagetool` is installed, also run:

```bash
cargo xtask dist linux-appimage
ls -la dist/linux/appimage
```

Expected: `.AppImage` exists.

- [ ] **Step 5: Inspect git status**

Run:

```bash
git status --short
```

Expected: clean working tree after final commit.

- [ ] **Step 6: Final commit if any verification fixes were needed**

```bash
git add -A
git commit -m "chore: verify desktop packaging workflow"
```

Only commit if there are actual changes.
