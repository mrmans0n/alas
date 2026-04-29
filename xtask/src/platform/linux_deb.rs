use std::path::{Path, PathBuf};

use anyhow::{Context, Result};

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
    let package_root = dist_dir.join(format!(
        "{}_{}_{}",
        meta.name, meta.version.debian, meta.arch.debian
    ));
    let debian_dir = package_root.join("DEBIAN");

    DebPaths {
        control: debian_dir.join("control"),
        executable: package_root.join("usr/bin").join(&meta.name),
        desktop: package_root
            .join("usr/share/applications")
            .join(format!("{}.desktop", meta.name)),
        icon_svg: package_root
            .join("usr/share/icons/hicolor/scalable/apps")
            .join(format!("{}.svg", meta.name)),
        copyright: package_root
            .join("usr/share/doc")
            .join(&meta.name)
            .join("copyright"),
        output: dist_dir.join(crate::metadata::deb_name(meta)),
        package_root,
        debian_dir,
    }
}

pub fn stage_deb(dist_dir: &Path, meta: &PackageMetadata, depends: &[String]) -> Result<DebPaths> {
    let paths = deb_paths(dist_dir, meta);
    let usr_bin = paths
        .executable
        .parent()
        .context("Debian executable path has no parent directory")?;
    let applications_dir = paths
        .desktop
        .parent()
        .context("Debian desktop entry path has no parent directory")?;
    let icons_dir = paths
        .icon_svg
        .parent()
        .context("Debian icon path has no parent directory")?;
    let doc_dir = paths
        .copyright
        .parent()
        .context("Debian copyright path has no parent directory")?;

    crate::fs::reset_dir(&paths.package_root)?;
    for dir in [
        paths.debian_dir.as_path(),
        usr_bin,
        applications_dir,
        icons_dir,
        doc_dir,
    ] {
        std::fs::create_dir_all(dir)
            .with_context(|| format!("creating directory {}", dir.display()))?;
    }

    crate::fs::copy_file(&meta.target_release_binary, &paths.executable)?;
    crate::fs::make_executable(&paths.executable)?;
    std::fs::write(&paths.desktop, crate::templates::desktop_entry())
        .with_context(|| format!("writing {}", paths.desktop.display()))?;
    std::fs::write(&paths.icon_svg, include_str!("../../../assets/alas.svg"))
        .with_context(|| format!("writing {}", paths.icon_svg.display()))?;
    std::fs::write(
        &paths.control,
        crate::templates::debian_control(meta, depends),
    )
    .with_context(|| format!("writing {}", paths.control.display()))?;
    std::fs::write(&paths.copyright, crate::templates::debian_copyright())
        .with_context(|| format!("writing {}", paths.copyright.display()))?;

    Ok(paths)
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

#[cfg(any(target_os = "linux", test))]
pub fn parse_shlibdeps_substvars(text: &str) -> Vec<String> {
    text.lines()
        .find_map(|line| line.strip_prefix("shlibs:Depends="))
        .map(|depends| {
            depends
                .split(',')
                .map(str::trim)
                .filter(|dependency| !dependency.is_empty())
                .map(ToOwned::to_owned)
                .collect()
        })
        .unwrap_or_default()
}

#[allow(dead_code)]
pub fn derive_depends(binary: &Path) -> Vec<String> {
    #[cfg(target_os = "linux")]
    {
        match std::process::Command::new("dpkg-shlibdeps")
            .arg("-O")
            .arg(binary)
            .output()
        {
            Ok(output) if output.status.success() => {
                let stdout = String::from_utf8_lossy(&output.stdout);
                let depends = parse_shlibdeps_substvars(&stdout);
                if !depends.is_empty() {
                    return depends;
                }
                eprintln!(
                    "warning: dpkg-shlibdeps returned no shlibs:Depends for {}; using default Debian dependencies",
                    binary.display()
                );
            }
            Ok(output) => {
                let stderr = String::from_utf8_lossy(&output.stderr);
                eprintln!(
                    "warning: dpkg-shlibdeps failed for {}: {}; using default Debian dependencies",
                    binary.display(),
                    stderr.trim()
                );
            }
            Err(error) => {
                eprintln!(
                    "warning: failed to run dpkg-shlibdeps for {}: {}; using default Debian dependencies",
                    binary.display(),
                    error
                );
            }
        }
    }

    #[cfg(not(target_os = "linux"))]
    {
        let _ = binary;
        eprintln!(
            "warning: dpkg-shlibdeps is only run on Linux; using default Debian dependencies"
        );
    }

    default_depends()
}

#[allow(dead_code)]
pub fn build_deb(paths: &DebPaths) -> Result<()> {
    #[cfg(target_os = "linux")]
    {
        let status = std::process::Command::new("dpkg-deb")
            .arg("--build")
            .arg(&paths.package_root)
            .arg(&paths.output)
            .status()
            .map_err(|error| {
                anyhow::anyhow!(
                    "failed to run dpkg-deb: {error}. Install dpkg-deb and ensure it is on PATH"
                )
            })?;
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
        assert_eq!(
            paths.package_root,
            Path::new("/repo/dist/linux/deb/alas_1.2.3_amd64")
        );
        assert_eq!(
            paths.executable,
            Path::new("/repo/dist/linux/deb/alas_1.2.3_amd64/usr/bin/alas")
        );
        assert_eq!(
            paths.control,
            Path::new("/repo/dist/linux/deb/alas_1.2.3_amd64/DEBIAN/control")
        );
        assert_eq!(
            paths.output,
            Path::new("/repo/dist/linux/deb/alas_1.2.3_amd64.deb")
        );
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
        assert!(
            std::fs::read_to_string(paths.control)
                .unwrap()
                .contains("Depends: libc6")
        );
    }
}
