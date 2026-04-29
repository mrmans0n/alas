use std::path::{Path, PathBuf};

use anyhow::{Context, Result};

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

pub fn stage_app(dist_dir: &Path, meta: &PackageMetadata) -> Result<MacosBundlePaths> {
    let paths = bundle_paths(dist_dir, meta);

    crate::fs::reset_dir(&paths.app_dir)?;
    std::fs::create_dir_all(&paths.macos_dir)
        .with_context(|| format!("creating directory {}", paths.macos_dir.display()))?;
    std::fs::create_dir_all(&paths.resources_dir)
        .with_context(|| format!("creating directory {}", paths.resources_dir.display()))?;

    crate::fs::copy_file(&meta.target_release_binary, &paths.executable)?;
    crate::fs::make_executable(&paths.executable)?;
    std::fs::write(&paths.info_plist, crate::templates::info_plist(meta))
        .with_context(|| format!("writing {}", paths.info_plist.display()))?;
    prepare_icon(meta, &paths.icon)?;

    Ok(paths)
}

fn prepare_icon(meta: &PackageMetadata, destination: &Path) -> Result<()> {
    let committed_icns = meta.root.join("assets/Alas.icns");
    if committed_icns.exists() {
        return crate::fs::copy_file(&committed_icns, destination);
    }

    #[cfg(target_os = "macos")]
    {
        generate_icns_from_svg(meta, destination).map_err(|error| {
            anyhow::anyhow!(
                "failed to generate Alas.icns from assets/alas.svg: {error}. Install/use macOS sips+iconutil or place a committed assets/Alas.icns file"
            )
        })
    }

    #[cfg(not(target_os = "macos"))]
    {
        let _ = meta;
        let _ = destination;
        anyhow::bail!(
            "missing assets/Alas.icns; macOS icon generation requires a macOS host with sips and iconutil"
        )
    }
}

#[cfg(target_os = "macos")]
fn generate_icns_from_svg(meta: &PackageMetadata, destination: &Path) -> Result<()> {
    let svg = meta.root.join("assets/alas.svg");
    if !svg.exists() {
        anyhow::bail!("missing {}", svg.display());
    }

    let parent = destination
        .parent()
        .with_context(|| format!("finding parent directory for {}", destination.display()))?;
    std::fs::create_dir_all(parent)
        .with_context(|| format!("creating directory {}", parent.display()))?;

    let iconset = parent.join("Alas.iconset");
    if iconset.exists() {
        std::fs::remove_dir_all(&iconset)
            .with_context(|| format!("removing directory {}", iconset.display()))?;
    }
    std::fs::create_dir_all(&iconset)
        .with_context(|| format!("creating directory {}", iconset.display()))?;

    let sizes = [
        (16, "icon_16x16.png"),
        (32, "icon_16x16@2x.png"),
        (32, "icon_32x32.png"),
        (64, "icon_32x32@2x.png"),
        (128, "icon_128x128.png"),
        (256, "icon_128x128@2x.png"),
        (256, "icon_256x256.png"),
        (512, "icon_256x256@2x.png"),
        (512, "icon_512x512.png"),
        (1024, "icon_512x512@2x.png"),
    ];

    for (size, file_name) in sizes {
        let output = iconset.join(file_name);
        let status = std::process::Command::new("sips")
            .arg("-s")
            .arg("format")
            .arg("png")
            .arg(&svg)
            .arg("--resampleHeightWidth")
            .arg(size.to_string())
            .arg(size.to_string())
            .arg("--out")
            .arg(&output)
            .status()
            .with_context(|| format!("running sips for {}", output.display()))?;
        if !status.success() {
            anyhow::bail!("sips failed while creating {}", output.display());
        }
    }

    let status = std::process::Command::new("iconutil")
        .arg("-c")
        .arg("icns")
        .arg(&iconset)
        .arg("-o")
        .arg(destination)
        .status()
        .with_context(|| format!("running iconutil for {}", destination.display()))?;
    if !status.success() {
        anyhow::bail!("iconutil failed while creating {}", destination.display());
    }

    std::fs::remove_dir_all(&iconset)
        .with_context(|| format!("removing directory {}", iconset.display()))?;
    Ok(())
}

#[allow(dead_code)]
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
        assert_eq!(
            paths.executable,
            Path::new("/repo/dist/macos/Alas.app/Contents/MacOS/alas")
        );
        assert_eq!(
            paths.info_plist,
            Path::new("/repo/dist/macos/Alas.app/Contents/Info.plist")
        );
        assert_eq!(
            paths.zip,
            Path::new("/repo/dist/macos/Alas-1.2.3-arm64.zip")
        );
    }

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
}
