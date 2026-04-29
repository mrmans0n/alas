use anyhow::{Result, bail};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ArchNames {
    pub rust: String,
    pub macos_artifact: String,
    pub appimage_artifact: String,
    pub debian: String,
}

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
