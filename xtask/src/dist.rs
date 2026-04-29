use anyhow::{Result, bail};

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
