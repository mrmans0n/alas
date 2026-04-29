#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VersionInfo {
    pub cargo: String,
    pub macos_short: String,
    pub macos_bundle: String,
    pub debian: String,
    pub filename: String,
}

pub fn normalize_version(cargo_version: &str) -> VersionInfo {
    let (without_build, _build) = cargo_version
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
