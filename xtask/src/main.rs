mod arch;
mod dist;
mod fs;
mod metadata;
mod templates;
mod version;

use anyhow::{Result, bail};

#[derive(Debug, Clone, PartialEq, Eq)]
enum Command {
    Dist(dist::DistTarget),
}

fn parse_command(args: &[&str]) -> Result<Command> {
    match args {
        ["dist", target] => Ok(Command::Dist(dist::DistTarget::parse(target)?)),
        ["dist", _, extra @ ..] => bail!("unexpected extra arguments: {}", extra.join(" ")),
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
        assert_eq!(
            parse_command(&["dist", "macos"]).unwrap(),
            Command::Dist(dist::DistTarget::Macos)
        );
        assert_eq!(
            parse_command(&["dist", "linux-appimage"]).unwrap(),
            Command::Dist(dist::DistTarget::LinuxAppImage)
        );
        assert_eq!(
            parse_command(&["dist", "linux-deb"]).unwrap(),
            Command::Dist(dist::DistTarget::LinuxDeb)
        );
        assert_eq!(
            parse_command(&["dist", "all"]).unwrap(),
            Command::Dist(dist::DistTarget::All)
        );
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

    #[test]
    fn rejects_unknown_dist_target() {
        let error = parse_command(&["dist", "windows"]).unwrap_err().to_string();
        assert!(error.contains("unknown dist target"));
    }

    #[test]
    fn rejects_extra_dist_arguments() {
        let error = parse_command(&["dist", "macos", "extra"])
            .unwrap_err()
            .to_string();
        assert!(error.contains("unexpected extra arguments"));
    }
}
