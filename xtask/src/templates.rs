use crate::metadata::PackageMetadata;

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

pub fn app_run() -> String {
    r#"#!/bin/sh
APPDIR="$(dirname "$(readlink -f "$0")")"
exec "$APPDIR/usr/bin/alas" "$@"
"#
    .to_string()
}

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

pub fn debian_copyright() -> String {
    r#"Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Files: *
Copyright: Alas contributors
License: Proprietary
 This package is distributed under the project's upstream license.
"#
    .to_string()
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

    #[test]
    fn renders_debian_copyright_placeholder() {
        let copyright = debian_copyright();
        assert!(copyright.contains("Format:"));
        assert!(copyright.contains("Files: *"));
        assert!(copyright.contains("Copyright:"));
        assert!(copyright.contains("License:"));
    }
}
