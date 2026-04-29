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
    let manifest_path = root.join("Cargo.toml");
    let manifest_text = std::fs::read_to_string(&manifest_path)?;
    let manifest: CargoManifest = toml::from_str(&manifest_text)?;
    let arch = crate::arch::arch_names(std::env::consts::ARCH)?;

    Ok(PackageMetadata {
        display_name: "Alas".to_string(),
        target_release_binary: root
            .join("target")
            .join("release")
            .join(&manifest.package.name),
        version: crate::version::normalize_version(&manifest.package.version),
        name: manifest.package.name,
        arch,
        root: root.to_path_buf(),
    })
}

pub fn macos_zip_name(meta: &PackageMetadata) -> String {
    format!(
        "Alas-{}-{}.zip",
        meta.version.filename, meta.arch.macos_artifact
    )
}

pub fn appimage_name(meta: &PackageMetadata) -> String {
    format!(
        "Alas-{}-{}.AppImage",
        meta.version.filename, meta.arch.appimage_artifact
    )
}

pub fn deb_name(meta: &PackageMetadata) -> String {
    format!(
        "{}_{}_{}.deb",
        meta.name, meta.version.debian, meta.arch.debian
    )
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
        assert_eq!(
            meta.target_release_binary,
            temp.path().join("target/release/alas")
        );
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

        assert_eq!(
            macos_zip_name(&meta),
            "Alas-1.2.3-alpha.1_build.5-x86_64.zip"
        );
        assert_eq!(
            appimage_name(&meta),
            "Alas-1.2.3-alpha.1_build.5-x86_64.AppImage"
        );
        assert_eq!(deb_name(&meta), "alas_1.2.3~alpha.1_amd64.deb");
    }
}
