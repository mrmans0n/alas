use std::path::{Path, PathBuf};

use anyhow::{Context, Result};

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
    let app_dir = dist_dir.join("Alas.AppDir");
    let usr_bin = app_dir.join("usr/bin");
    AppImagePaths {
        executable: usr_bin.join(&meta.name),
        desktop: app_dir.join("alas.desktop"),
        app_run: app_dir.join("AppRun"),
        icon_svg: app_dir.join("alas.svg"),
        output: dist_dir.join(crate::metadata::appimage_name(meta)),
        app_dir,
        usr_bin,
    }
}

pub fn stage_appdir(dist_dir: &Path, meta: &PackageMetadata) -> Result<AppImagePaths> {
    let paths = appimage_paths(dist_dir, meta);

    crate::fs::reset_dir(&paths.app_dir)?;
    std::fs::create_dir_all(&paths.usr_bin)
        .with_context(|| format!("creating directory {}", paths.usr_bin.display()))?;

    crate::fs::copy_file(&meta.target_release_binary, &paths.executable)?;
    crate::fs::make_executable(&paths.executable)?;
    std::fs::write(&paths.desktop, crate::templates::desktop_entry())
        .with_context(|| format!("writing {}", paths.desktop.display()))?;
    std::fs::write(&paths.app_run, crate::templates::app_run())
        .with_context(|| format!("writing {}", paths.app_run.display()))?;
    crate::fs::make_executable(&paths.app_run)?;
    crate::fs::copy_file(&meta.root.join("assets/alas.svg"), &paths.icon_svg)?;

    Ok(paths)
}

#[allow(dead_code)]
pub fn build_appimage(paths: &AppImagePaths) -> Result<()> {
    #[cfg(target_os = "linux")]
    {
        let status = std::process::Command::new("appimagetool")
            .arg(&paths.app_dir)
            .arg(&paths.output)
            .status()
            .map_err(|error| anyhow::anyhow!("failed to run appimagetool: {error}. Install appimagetool and ensure it is on PATH"))?;
        if !status.success() {
            anyhow::bail!(
                "appimagetool failed while creating {}",
                paths.output.display()
            );
        }
        Ok(())
    }
    #[cfg(not(target_os = "linux"))]
    {
        let _ = paths;
        anyhow::bail!("AppImage packaging requires a Linux host")
    }
}

#[allow(dead_code)]
pub fn print_ldd_report(binary: &Path) {
    #[cfg(not(target_os = "linux"))]
    {
        let _ = binary;
    }

    #[cfg(target_os = "linux")]
    {
        if let Ok(output) = std::process::Command::new("ldd").arg(binary).output() {
            println!(
                "Dynamic dependencies for {}:\n{}",
                binary.display(),
                String::from_utf8_lossy(&output.stdout)
            );
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{fs, path::Path};

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
        assert_eq!(
            paths.app_dir,
            Path::new("/repo/dist/linux/appimage/Alas.AppDir")
        );
        assert_eq!(
            paths.executable,
            Path::new("/repo/dist/linux/appimage/Alas.AppDir/usr/bin/alas")
        );
        assert_eq!(
            paths.desktop,
            Path::new("/repo/dist/linux/appimage/Alas.AppDir/alas.desktop")
        );
        assert_eq!(
            paths.output,
            Path::new("/repo/dist/linux/appimage/Alas-1.2.3-x86_64.AppImage")
        );
    }

    #[test]
    fn stages_appdir_with_binary_desktop_apprun_and_icon() {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path();
        let binary = root.join("target/release/alas");
        fs::create_dir_all(binary.parent().unwrap()).unwrap();
        fs::write(&binary, "fake-binary").unwrap();
        fs::create_dir_all(root.join("assets")).unwrap();
        fs::write(root.join("assets/alas.svg"), "fake-icon").unwrap();

        let dist_dir = root.join("dist/linux/appimage");
        let stale_file = dist_dir.join("Alas.AppDir/stale.txt");
        fs::create_dir_all(stale_file.parent().unwrap()).unwrap();
        fs::write(&stale_file, "old").unwrap();

        let mut meta = meta();
        meta.root = root.to_path_buf();
        meta.target_release_binary = binary;

        let paths = stage_appdir(&dist_dir, &meta).unwrap();

        assert!(paths.usr_bin.is_dir());
        assert_eq!(
            fs::read_to_string(&paths.executable).unwrap(),
            "fake-binary"
        );
        assert_eq!(
            fs::read_to_string(&paths.desktop).unwrap(),
            crate::templates::desktop_entry()
        );
        assert_eq!(
            fs::read_to_string(&paths.app_run).unwrap(),
            crate::templates::app_run()
        );
        assert_eq!(fs::read_to_string(&paths.icon_svg).unwrap(), "fake-icon");
        assert!(!stale_file.exists());

        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;

            let binary_mode = fs::metadata(&paths.executable)
                .unwrap()
                .permissions()
                .mode()
                & 0o111;
            let app_run_mode = fs::metadata(&paths.app_run).unwrap().permissions().mode() & 0o111;
            assert_eq!(binary_mode, 0o111);
            assert_eq!(app_run_mode, 0o111);
        }
    }
}
