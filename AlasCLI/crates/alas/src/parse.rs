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
    let mut branch: Option<String> = None;
    let mut base: Option<String> = None;
    let mut i = 0;
    while i < args.len() {
        match args[i] {
            "--base" => {
                i += 1;
                if i >= args.len() || args[i].starts_with("--") {
                    return Err(USAGE.into());
                }
                base = Some(args[i].to_string());
            }
            a if a.starts_with("--") => return Err(USAGE.into()),
            a => {
                if branch.is_some() {
                    return Err(USAGE.into());
                }
                branch = Some(a.to_string());
            }
        }
        i += 1;
    }
    match branch {
        Some(branch) => Ok(Command::WtNew { branch, base }),
        None => Err(USAGE.into()),
    }
}

fn parse_wt_delete(args: &[&str]) -> Result<Command, String> {
    const USAGE: &str = "usage: alas wt delete <name-or-branch> [--force] [--keep-branch]";
    let mut target: Option<String> = None;
    let mut force = false;
    let mut keep_branch = false;
    for a in args {
        match *a {
            "--force" => force = true,
            "--keep-branch" => keep_branch = true,
            s if s.starts_with("--") => return Err(USAGE.into()),
            s => {
                if target.is_some() {
                    return Err(USAGE.into());
                }
                target = Some(s.to_string());
            }
        }
    }
    match target {
        Some(target) => Ok(Command::WtDelete { target, force, keep_branch }),
        None => Err(USAGE.into()),
    }
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
        let cmd = parse(&s(&["wt", "new", "feat", "--base", "main"]), Path::new("/b")).unwrap();
        assert_eq!(cmd, Command::WtNew { branch: "feat".into(), base: Some("main".into()) });
    }

    #[test]
    fn wt_new_rejects_leading_flag() {
        assert!(parse(&s(&["wt", "new", "--base"]), Path::new("/b")).is_err());
    }

    #[test]
    fn wt_delete_parses_flags() {
        let cmd = parse(&s(&["wt", "delete", "feat", "--force"]), Path::new("/b")).unwrap();
        assert_eq!(cmd, Command::WtDelete { target: "feat".into(), force: true, keep_branch: false });
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
