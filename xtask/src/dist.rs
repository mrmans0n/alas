use std::path::Path;

use anyhow::{Result, bail};

use crate::{
    metadata,
    platform::{linux_appimage, linux_deb, macos},
};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DistTarget {
    Macos,
    LinuxAppImage,
    LinuxDeb,
    All,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HostOs {
    Macos,
    Linux,
    Other,
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

pub fn targets_for_host(target: DistTarget, host: HostOs) -> Result<Vec<DistTarget>> {
    match (target, host) {
        (DistTarget::All, HostOs::Macos) => Ok(vec![DistTarget::Macos]),
        (DistTarget::All, HostOs::Linux) => {
            Ok(vec![DistTarget::LinuxAppImage, DistTarget::LinuxDeb])
        }
        (DistTarget::All, HostOs::Other) => {
            bail!("no packaging targets are supported on this host")
        }
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

fn build_release(root: &Path) -> Result<()> {
    let status = std::process::Command::new("cargo")
        .args([
            "build",
            "--release",
            "--all-features",
            "--package",
            "alas",
            "--bin",
            "alas",
        ])
        .current_dir(root)
        .status()?;
    if !status.success() {
        bail!("cargo release build failed");
    }
    Ok(())
}

pub fn run(target: DistTarget) -> Result<()> {
    let root = std::env::current_dir()?;
    let targets = targets_for_host(target, current_host())?;
    let meta = metadata::load(&root)?;

    build_release(&root)?;

    for target in targets {
        match target {
            DistTarget::Macos => {
                let paths = macos::stage_app(&root.join("dist/macos"), &meta)?;
                macos::zip_app(&paths)?;
                println!("Created {}", paths.zip.display());
            }
            DistTarget::LinuxAppImage => {
                let paths = linux_appimage::stage_appdir(&root.join("dist/linux/appimage"), &meta)?;
                linux_appimage::print_ldd_report(&meta.target_release_binary);
                linux_appimage::build_appimage(&paths)?;
                println!("Created {}", paths.output.display());
            }
            DistTarget::LinuxDeb => {
                let depends = linux_deb::derive_depends(&meta.target_release_binary);
                let paths = linux_deb::stage_deb(&root.join("dist/linux/deb"), &meta, &depends)?;
                linux_deb::build_deb(&paths)?;
                println!("Created {}", paths.output.display());
            }
            DistTarget::All => unreachable!("all target is resolved before packaging"),
        }
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn all_on_macos_builds_macos_only() {
        assert_eq!(
            targets_for_host(DistTarget::All, HostOs::Macos).unwrap(),
            vec![DistTarget::Macos]
        );
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
        let error = targets_for_host(DistTarget::Macos, HostOs::Linux)
            .unwrap_err()
            .to_string();
        assert!(error.contains("requires a macOS host"));
    }
}
