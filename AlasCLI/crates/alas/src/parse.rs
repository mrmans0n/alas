use alas_client::Command;

/// Program invocation name → whether we're the `ao` alias.
pub fn is_ao(argv0: &str) -> bool {
    std::path::Path::new(argv0)
        .file_name()
        .map(|n| n == "ao")
        .unwrap_or(false)
}

/// Usage text for the whole tool (stderr on top-level misuse).
pub const USAGE_ALL: &str = "\
usage: alas open <path> [path...]
usage: alas wt list
usage: alas wt switch <name-or-branch>
usage: alas wt new <branch> [--base <ref>]
usage: alas wt delete <name-or-branch> [--force] [--keep-branch]
usage: alas review [pr-number-or-url]";

/// Parse arguments (excluding argv0) into a Command. `base` is the directory
/// `open` paths resolve against. On misuse, returns the usage string to print.
pub fn parse(args: &[String], base: &std::path::Path) -> Result<Command, String> {
    let mut it = args.iter();
    match it.next().map(String::as_str) {
        Some("open") => {
            let rest: Vec<&String> = it.collect();
            if rest.is_empty() {
                return Err("usage: alas open <path> [path...]".into());
            }
            let paths = rest
                .iter()
                .map(|p| alas_client::absolutize(base, p))
                .collect();
            Ok(Command::Open { paths })
        }
        Some("wt") => parse_wt(&it.map(|s| s.as_str()).collect::<Vec<_>>()),
        Some("review") => {
            let rest: Vec<&String> = it.collect();
            match rest.len() {
                0 => Ok(Command::Review { target: None }),
                1 => Ok(Command::Review { target: Some(rest[0].clone()) }),
                _ => Err("usage: alas review [pr-number-or-url]".into()),
            }
        }
        _ => Err(USAGE_ALL.into()),
    }
}

fn parse_wt(args: &[&str]) -> Result<Command, String> {
    match args.first().copied() {
        Some("list") => {
            if args.len() != 1 {
                return Err("usage: alas wt list".into());
            }
            Ok(Command::WtList)
        }
        Some("switch") => {
            if args.len() != 2 {
                return Err("usage: alas wt switch <name-or-branch>".into());
            }
            Ok(Command::WtSwitch { target: args[1].to_string() })
        }
        Some("new") => parse_wt_new(&args[1..]),
        Some("delete") => parse_wt_delete(&args[1..]),
        _ => Err(USAGE_ALL.into()),
    }
}

fn parse_wt_new(args: &[&str]) -> Result<Command, String> {
    const USAGE: &str = "usage: alas wt new <branch> [--base <ref>]";
    let (branch, rest) = match args.split_first() {
        Some((first, rest)) if !first.starts_with("--") => (first.to_string(), rest),
        _ => return Err(USAGE.into()),
    };
    let mut base: Option<String> = None;
    let mut i = 0;
    while i < rest.len() {
        match rest[i] {
            "--base" => {
                i += 1;
                if i >= rest.len() || rest[i].starts_with("--") {
                    return Err(USAGE.into());
                }
                base = Some(rest[i].to_string());
            }
            _ => return Err(USAGE.into()),
        }
        i += 1;
    }
    Ok(Command::WtNew { branch, base })
}

fn parse_wt_delete(args: &[&str]) -> Result<Command, String> {
    const USAGE: &str = "usage: alas wt delete <name-or-branch> [--force] [--keep-branch]";
    let (target, rest) = match args.split_first() {
        Some((first, rest)) if !first.starts_with("--") => (first.to_string(), rest),
        _ => return Err(USAGE.into()),
    };
    let mut force = false;
    let mut keep_branch = false;
    for a in rest {
        match *a {
            "--force" => force = true,
            "--keep-branch" => keep_branch = true,
            _ => return Err(USAGE.into()),
        }
    }
    Ok(Command::WtDelete { target, force, keep_branch })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::Path;

    fn s(v: &[&str]) -> Vec<String> {
        v.iter().map(|x| x.to_string()).collect()
    }

    #[test]
    fn open_requires_a_path() {
        assert!(parse(&s(&["open"]), Path::new("/b")).is_err());
    }

    #[test]
    fn open_absolutizes_relative_paths() {
        let cmd = parse(&s(&["open", "a.txt"]), Path::new("/b")).unwrap();
        assert_eq!(cmd, Command::Open { paths: vec!["/b/a.txt".into()] });
    }

    #[test]
    fn wt_new_parses_base_flag() {
        let cmd = parse(&s(&["wt", "new", "feature", "--base", "main"]), Path::new("/b")).unwrap();
        assert_eq!(cmd, Command::WtNew { branch: "feature".into(), base: Some("main".into()) });
    }

    #[test]
    fn wt_new_no_base_is_ok() {
        let cmd = parse(&s(&["wt", "new", "feat"]), Path::new("/b")).unwrap();
        assert_eq!(cmd, Command::WtNew { branch: "feat".into(), base: None });
    }

    #[test]
    fn wt_new_rejects_leading_flag() {
        assert!(parse(&s(&["wt", "new", "--base"]), Path::new("/b")).is_err());
        assert!(parse(&s(&["wt", "new", "--base", "main", "feature-x"]), Path::new("/b")).is_err());
    }

    #[test]
    fn wt_new_rejects_second_positional() {
        assert!(parse(&s(&["wt", "new", "feature", "extra"]), Path::new("/b")).is_err());
    }

    #[test]
    fn wt_new_rejects_base_with_missing_value() {
        assert!(parse(&s(&["wt", "new", "feature", "--base"]), Path::new("/b")).is_err());
    }

    #[test]
    fn wt_new_rejects_base_value_that_is_a_flag() {
        assert!(parse(&s(&["wt", "new", "feature", "--base", "--x"]), Path::new("/b")).is_err());
    }

    #[test]
    fn wt_new_rejects_unknown_flag() {
        assert!(parse(&s(&["wt", "new", "feature", "--unknown"]), Path::new("/b")).is_err());
    }

    #[test]
    fn wt_delete_parses_flags() {
        let cmd = parse(
            &s(&["wt", "delete", "target", "--force", "--keep-branch"]),
            Path::new("/b"),
        )
        .unwrap();
        assert_eq!(cmd, Command::WtDelete { target: "target".into(), force: true, keep_branch: true });
    }

    #[test]
    fn wt_delete_no_flags_is_ok() {
        let cmd = parse(&s(&["wt", "delete", "target"]), Path::new("/b")).unwrap();
        assert_eq!(cmd, Command::WtDelete { target: "target".into(), force: false, keep_branch: false });
    }

    #[test]
    fn wt_delete_rejects_leading_flag() {
        assert!(parse(&s(&["wt", "delete", "--force", "some-target"]), Path::new("/b")).is_err());
    }

    #[test]
    fn wt_delete_rejects_second_positional() {
        assert!(parse(&s(&["wt", "delete", "target", "extra"]), Path::new("/b")).is_err());
    }

    #[test]
    fn review_takes_at_most_one_target() {
        assert!(parse(&s(&["review", "1", "2"]), Path::new("/b")).is_err());
        assert_eq!(
            parse(&s(&["review"]), Path::new("/b")).unwrap(),
            Command::Review { target: None }
        );
    }

    #[test]
    fn ao_detected_from_argv0() {
        assert!(is_ao("/usr/local/bin/ao"));
        assert!(!is_ao("/usr/local/bin/alas"));
    }
}
