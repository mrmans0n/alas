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
usage: alas open <path> --line <n> [--end-line <n>]
usage: alas notify <body> [--title <title>] [--level <info|attention>]
usage: alas wt list
usage: alas wt switch <name-or-branch>
usage: alas wt new <branch> [--base <ref>]
usage: alas wt delete <name-or-branch> [--force] [--keep-branch]
usage: alas workspace list
usage: alas workspace show <checkout-uuid>
usage: alas workspace switch <checkout-uuid>
usage: alas workspace focus <checkout-uuid> --member <member-uuid>
usage: alas session list
usage: alas session new --prompt <text> [--agent <id>] [--worktree <name-or-branch> | --new-worktree <branch> [--base <ref>]]
usage: alas session send <session-id> <prompt>
usage: alas review [target] [--worktree <name-or-path>]
usage: alas review -- <target> [--worktree <name-or-path>]  (escapes a target named like a review subcommand)
usage: alas review comments [--state <active|resolved|dismissed|all>] [--session <id>]
usage: alas review reply <comment-id> <body>
usage: alas review resolve <comment-id> [--reply <body>] [--reopen]
usage: alas review comment <path> <line> <body> [--end-line <n>] [--side <old|new>] [--session <id>]
usage: alas review finish [--session <id>] [--verdict <approve|request-changes|comment>] [--summary <body>]";

/// Parse arguments (excluding argv0) into a Command. `base` is the directory
/// `open` paths resolve against. On misuse, returns the usage string to print.
pub fn parse(args: &[String], base: &std::path::Path) -> Result<Command, String> {
    let mut it = args.iter();
    match it.next().map(String::as_str) {
        Some("open") => {
            let rest: Vec<&str> = it.map(String::as_str).collect();
            parse_open(&rest, base)
        }
        Some("notify") => parse_notify(&it.map(|s| s.as_str()).collect::<Vec<_>>()),
        Some("wt") => parse_wt(&it.map(|s| s.as_str()).collect::<Vec<_>>()),
        Some("workspace") => parse_workspace(&it.map(|s| s.as_str()).collect::<Vec<_>>()),
        Some("session") => parse_session(&it.map(|s| s.as_str()).collect::<Vec<_>>()),
        Some("review") => {
            let rest: Vec<&str> = it.map(String::as_str).collect();
            parse_review(&rest, base)
        }
        _ => Err(USAGE_ALL.into()),
    }
}

fn parse_workspace(args: &[&str]) -> Result<Command, String> {
    match args.first().copied() {
        Some("list") if args.len() == 1 => Ok(Command::WorkspaceList),
        Some("show") if args.len() == 2 => Ok(Command::WorkspaceShow {
            checkout_id: validated_uuid(args[1])?,
        }),
        Some("switch") if args.len() == 2 => Ok(Command::WorkspaceSwitch {
            checkout_id: validated_uuid(args[1])?,
        }),
        Some("focus") if args.len() == 4 && args[2] == "--member" => Ok(Command::WorkspaceFocus {
            checkout_id: validated_uuid(args[1])?,
            member_id: validated_uuid(args[3])?,
        }),
        _ => Err(USAGE_ALL.into()),
    }
}

fn validated_uuid(value: &str) -> Result<String, String> {
    let bytes = value.as_bytes();
    let hyphens = [8, 13, 18, 23];
    let valid = bytes.len() == 36
        && bytes.iter().enumerate().all(|(index, byte)| {
            if hyphens.contains(&index) {
                *byte == b'-'
            } else {
                byte.is_ascii_hexdigit()
            }
        });
    if valid {
        Ok(value.to_string())
    } else {
        Err("workspace commands require UUID targets".into())
    }
}

fn parse_session(args: &[&str]) -> Result<Command, String> {
    match args.first().copied() {
        Some("list") if args.len() == 1 => Ok(Command::SessionList),
        Some("new") => parse_session_new(&args[1..]),
        Some("send") => {
            const USAGE: &str = "usage: alas session send <session-id> <prompt>";
            if args.len() != 3 || args[1].trim().is_empty() || args[2].trim().is_empty() {
                return Err(USAGE.into());
            }
            Ok(Command::SessionSend {
                session_id: args[1].to_string(),
                prompt: args[2].to_string(),
            })
        }
        _ => Err(USAGE_ALL.into()),
    }
}

fn parse_session_new(args: &[&str]) -> Result<Command, String> {
    const USAGE: &str = "usage: alas session new --prompt <text> [--agent <id>] [--worktree <name-or-branch> | --new-worktree <branch> [--base <ref>]]";
    let mut prompt = None;
    let mut agent = None;
    let mut existing_worktree = None;
    let mut new_worktree = None;
    let mut base = None;
    let mut i = 0;
    while i < args.len() {
        let value = match args[i] {
            "--prompt" => &mut prompt,
            "--agent" => &mut agent,
            "--worktree" => &mut existing_worktree,
            "--new-worktree" => &mut new_worktree,
            "--base" => &mut base,
            _ => return Err(USAGE.into()),
        };
        if value.is_some() {
            return Err(USAGE.into());
        }
        i += 1;
        let Some(argument) = flag_value(args, i).filter(|argument| !argument.trim().is_empty())
        else {
            return Err(USAGE.into());
        };
        *value = Some(argument.to_string());
        i += 1;
    }
    let prompt = prompt.ok_or(USAGE)?;
    if existing_worktree.is_some() && new_worktree.is_some() {
        return Err(USAGE.into());
    }
    if base.is_some() && new_worktree.is_none() {
        return Err(USAGE.into());
    }
    let worktree = match (existing_worktree, new_worktree) {
        (Some(worktree), None) => alas_client::SessionWorktreeTarget::Existing { worktree },
        (None, Some(branch)) => alas_client::SessionWorktreeTarget::New { branch, base },
        (None, None) => alas_client::SessionWorktreeTarget::Current,
        (Some(_), Some(_)) => unreachable!("mutual exclusion checked above"),
    };
    Ok(Command::SessionNew {
        prompt,
        agent,
        worktree,
    })
}

fn parse_notify(args: &[&str]) -> Result<Command, String> {
    const USAGE: &str = "usage: alas notify <body> [--title <title>] [--level <info|attention>]";
    let (body, rest) = match args.split_first() {
        Some((first, rest)) if !first.starts_with("--") => (first.to_string(), rest),
        _ => return Err(USAGE.into()),
    };
    let mut title: Option<String> = None;
    let mut level: Option<String> = None;
    let mut i = 0;
    while i < rest.len() {
        match rest[i] {
            "--title" => {
                i += 1;
                title = Some(flag_value(rest, i).ok_or(USAGE)?.to_string());
            }
            "--level" => {
                i += 1;
                let value = flag_value(rest, i).ok_or(USAGE)?;
                if value != "info" && value != "attention" {
                    return Err(USAGE.into());
                }
                level = Some(value.to_string());
            }
            _ => return Err(USAGE.into()),
        }
        i += 1;
    }
    Ok(Command::Notify { body, title, level })
}

fn parse_open(args: &[&str], base: &std::path::Path) -> Result<Command, String> {
    const USAGE: &str = "usage: alas open <path> [path...]\n\
usage: alas open <path> --line <n> [--end-line <n>]";
    if args.len() > 1
        && let Some(separator) = args.iter().position(|arg| *arg == "--")
    {
        let paths: Vec<String> = args[..separator]
            .iter()
            .chain(&args[separator + 1..])
            .map(|path| alas_client::absolutize(base, path))
            .collect();
        if paths.is_empty() {
            return Err(USAGE.into());
        }
        return Ok(Command::Open { paths });
    }
    let (first, rest) = args.split_first().ok_or(USAGE)?;
    if rest
        .iter()
        .all(|arg| !matches!(*arg, "--line" | "--end-line"))
    {
        let paths = args
            .iter()
            .map(|path| alas_client::absolutize(base, path))
            .collect();
        return Ok(Command::Open { paths });
    }

    let mut line = None;
    let mut end_line = None;
    let mut i = 0;
    while i < rest.len() {
        match rest[i] {
            "--line" => {
                if line.is_some() {
                    return Err(USAGE.into());
                }
                i += 1;
                line = Some(
                    flag_value(rest, i)
                        .ok_or(USAGE)?
                        .parse::<u64>()
                        .map_err(|_| USAGE)?,
                );
            }
            "--end-line" => {
                if end_line.is_some() {
                    return Err(USAGE.into());
                }
                i += 1;
                end_line = Some(
                    flag_value(rest, i)
                        .ok_or(USAGE)?
                        .parse::<u64>()
                        .map_err(|_| USAGE)?,
                );
            }
            _ => return Err(USAGE.into()),
        }
        i += 1;
    }
    let line = line.filter(|line| *line >= 1).ok_or(USAGE)?;
    if end_line.is_some_and(|end| end < line) {
        return Err(USAGE.into());
    }
    Ok(Command::OpenAt {
        path: alas_client::absolutize(base, first),
        line,
        end_line,
    })
}

pub const REVIEW_STATES: [&str; 4] = ["active", "resolved", "dismissed", "all"];

fn parse_review(args: &[&str], base: &std::path::Path) -> Result<Command, String> {
    if let Some(separator) = args.iter().position(|arg| *arg == "--") {
        // Force review-open interpretation regardless of what the target
        // looks like — lets a branch/tag literally named `finish`,
        // `comments`, etc. be reviewed instead of misfiring into the
        // matching subcommand below (e.g. `alas review finish` would
        // otherwise silently finish the current review).
        let mut without_separator: Vec<&str> = args[..separator].to_vec();
        without_separator.extend_from_slice(&args[separator + 1..]);
        return parse_review_open(&without_separator, base);
    }
    match args.first().copied() {
        None => Ok(Command::Review {
            target: None,
            worktree: None,
        }),
        Some("comments") => parse_review_comments(&args[1..]),
        Some("comment") => parse_review_comment(&args[1..], base),
        Some("reply") => {
            const USAGE: &str = "usage: alas review reply <comment-id> <body>";
            if args.len() != 3 || args[1].starts_with("--") {
                return Err(USAGE.into());
            }
            Ok(Command::ReviewReply {
                comment_id: args[1].to_string(),
                body: args[2].to_string(),
            })
        }
        Some("resolve") => parse_review_resolve(&args[1..]),
        Some("finish") => parse_review_finish(&args[1..]),
        Some(_) => parse_review_open(args, base),
    }
}

/// `alas review [target] [--worktree <name-or-path>]`. The target is a PR/MR
/// number or URL, a commit range (`base..head` / `base...head`), a branch, or
/// a revision — classified by the app, not here.
fn parse_review_open(args: &[&str], base: &std::path::Path) -> Result<Command, String> {
    const USAGE: &str = "usage: alas review [target] [--worktree <name-or-path>]";
    let mut target: Option<String> = None;
    let mut worktree: Option<String> = None;
    let mut i = 0;
    while i < args.len() {
        match args[i] {
            "--worktree" => {
                if worktree.is_some() {
                    return Err(USAGE.into());
                }
                i += 1;
                let value = flag_value(args, i).ok_or(USAGE)?;
                worktree = Some(
                    if value == "."
                        || value == ".."
                        || value.starts_with('/')
                        || value.starts_with("./")
                        || value.starts_with("../")
                    {
                        alas_client::absolutize(base, value)
                    } else {
                        value.to_string()
                    },
                );
            }
            value if !value.starts_with("--") && target.is_none() => {
                target = Some(value.to_string());
            }
            _ => return Err(USAGE.into()),
        }
        i += 1;
    }
    Ok(Command::Review { target, worktree })
}

fn parse_review_finish(args: &[&str]) -> Result<Command, String> {
    const USAGE: &str = "usage: alas review finish [--session <id>] [--verdict <approve|request-changes|comment>] [--summary <body>]";
    let mut session_id: Option<String> = None;
    let mut verdict: Option<String> = None;
    let mut summary: Option<String> = None;
    let mut i = 0;
    while i < args.len() {
        match args[i] {
            "--session" => {
                i += 1;
                session_id = Some(flag_value(args, i).ok_or(USAGE)?.to_string());
            }
            "--verdict" => {
                i += 1;
                let value = flag_value(args, i).ok_or(USAGE)?;
                let wire_value = match value {
                    "approve" | "comment" => value,
                    "request-changes" => "request_changes",
                    _ => return Err(USAGE.into()),
                };
                verdict = Some(wire_value.to_string());
            }
            "--summary" => {
                i += 1;
                summary = Some(flag_value(args, i).ok_or(USAGE)?.to_string());
            }
            _ => return Err(USAGE.into()),
        }
        i += 1;
    }
    Ok(Command::ReviewFinish {
        session_id,
        verdict,
        summary,
    })
}

fn parse_review_resolve(args: &[&str]) -> Result<Command, String> {
    const USAGE: &str = "usage: alas review resolve <comment-id> [--reply <body>] [--reopen]";
    let (comment_id, rest) = match args.split_first() {
        Some((first, rest)) if !first.starts_with("--") => (first.to_string(), rest),
        _ => return Err(USAGE.into()),
    };
    let mut reply: Option<String> = None;
    let mut reopen = false;
    let mut i = 0;
    while i < rest.len() {
        match rest[i] {
            "--reply" => {
                i += 1;
                reply = Some(flag_value(rest, i).ok_or(USAGE)?.to_string());
            }
            "--reopen" => reopen = true,
            _ => return Err(USAGE.into()),
        }
        i += 1;
    }
    Ok(Command::ReviewResolve {
        comment_id,
        reply,
        reopen,
    })
}

fn parse_review_comments(args: &[&str]) -> Result<Command, String> {
    const USAGE: &str =
        "usage: alas review comments [--state <active|resolved|dismissed|all>] [--session <id>]";
    let mut state: Option<String> = None;
    let mut session_id: Option<String> = None;
    let mut i = 0;
    while i < args.len() {
        match args[i] {
            "--state" => {
                i += 1;
                let value = flag_value(args, i).ok_or(USAGE)?;
                if !REVIEW_STATES.contains(&value) {
                    return Err(USAGE.into());
                }
                state = Some(value.to_string());
            }
            "--session" => {
                i += 1;
                session_id = Some(flag_value(args, i).ok_or(USAGE)?.to_string());
            }
            _ => return Err(USAGE.into()),
        }
        i += 1;
    }
    Ok(Command::ReviewComments { session_id, state })
}

fn parse_review_comment(args: &[&str], base: &std::path::Path) -> Result<Command, String> {
    const USAGE: &str = "usage: alas review comment <path> <line> <body> [--end-line <n>] [--side <old|new>] [--session <id>]";
    if args.len() < 3 || args[..3].iter().any(|a| a.starts_with("--")) {
        return Err(USAGE.into());
    }
    // Resolved against the caller's cwd, same as `open`: the app treats an
    // already-relative path as worktree-root-relative, which is wrong when
    // the command is run from a subdirectory.
    let path = alas_client::absolutize(base, args[0]);
    let start_line: u64 = args[1].parse().map_err(|_| USAGE.to_string())?;
    if start_line == 0 {
        return Err(USAGE.into());
    }
    let body = args[2].to_string();

    let mut end_line: Option<u64> = None;
    let mut side: Option<String> = None;
    let mut session_id: Option<String> = None;
    let rest = &args[3..];
    let mut i = 0;
    while i < rest.len() {
        match rest[i] {
            "--end-line" => {
                i += 1;
                let value = flag_value(rest, i).ok_or(USAGE)?;
                let parsed: u64 = value.parse().map_err(|_| USAGE.to_string())?;
                if parsed < start_line {
                    return Err(USAGE.into());
                }
                end_line = Some(parsed);
            }
            "--side" => {
                i += 1;
                let value = flag_value(rest, i).ok_or(USAGE)?;
                if value != "old" && value != "new" {
                    return Err(USAGE.into());
                }
                side = Some(value.to_string());
            }
            "--session" => {
                i += 1;
                session_id = Some(flag_value(rest, i).ok_or(USAGE)?.to_string());
            }
            _ => return Err(USAGE.into()),
        }
        i += 1;
    }
    Ok(Command::ReviewCommentAdd {
        path,
        start_line,
        end_line,
        side,
        body,
        session_id,
    })
}

/// Value at `i` unless it is missing or looks like another flag.
fn flag_value<'a>(args: &[&'a str], i: usize) -> Option<&'a str> {
    args.get(i).copied().filter(|v| !v.starts_with("--"))
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
            Ok(Command::WtSwitch {
                target: args[1].to_string(),
            })
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
    Ok(Command::WtDelete {
        target,
        force,
        keep_branch,
    })
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
        assert_eq!(
            cmd,
            Command::Open {
                paths: vec!["/b/a.txt".into()]
            }
        );
    }

    #[test]
    fn notify_parses_body_title_and_level() {
        let cmd = parse(
            &s(&[
                "notify",
                "Blocked on input",
                "--title",
                "Need input",
                "--level",
                "attention",
            ]),
            Path::new("/b"),
        )
        .unwrap();
        assert_eq!(
            cmd,
            Command::Notify {
                body: "Blocked on input".into(),
                title: Some("Need input".into()),
                level: Some("attention".into()),
            }
        );
    }

    #[test]
    fn notify_rejects_missing_body_and_bad_level() {
        assert!(parse(&s(&["notify"]), Path::new("/b")).is_err());
        assert!(
            parse(
                &s(&["notify", "Done", "--level", "urgent"]),
                Path::new("/b")
            )
            .is_err()
        );
    }

    #[test]
    fn open_preserves_flag_shaped_legacy_paths() {
        let cmd = parse(&s(&["open", "--notes"]), Path::new("/b")).unwrap();
        assert_eq!(
            cmd,
            Command::Open {
                paths: vec!["/b/--notes".into()]
            }
        );

        let cmd = parse(&s(&["open", "--"]), Path::new("/b")).unwrap();
        assert_eq!(
            cmd,
            Command::Open {
                paths: vec!["/b/--".into()]
            }
        );

        let cmd = parse(&s(&["open", "a.txt", "--", "--line"]), Path::new("/b")).unwrap();
        assert_eq!(
            cmd,
            Command::Open {
                paths: vec!["/b/a.txt".into(), "/b/--line".into()]
            }
        );
    }

    #[test]
    fn open_parses_line_range_for_one_path() {
        let cmd = parse(
            &s(&["open", "a.txt", "--line", "12", "--end-line", "15"]),
            Path::new("/b"),
        )
        .unwrap();
        assert_eq!(
            cmd,
            Command::OpenAt {
                path: "/b/a.txt".into(),
                line: 12,
                end_line: Some(15),
            }
        );
    }

    #[test]
    fn open_rejects_invalid_line_targets() {
        assert!(parse(&s(&["open", "a.txt", "--line", "0"]), Path::new("/b")).is_err());
        assert!(parse(&s(&["open", "a.txt", "--end-line", "12"]), Path::new("/b")).is_err());
        assert!(
            parse(
                &s(&["open", "a.txt", "--line", "15", "--end-line", "12"]),
                Path::new("/b")
            )
            .is_err()
        );
        assert!(
            parse(
                &s(&["open", "a.txt", "b.txt", "--line", "12"]),
                Path::new("/b")
            )
            .is_err()
        );
        assert!(
            parse(
                &s(&["open", "a.txt", "--line", "12", "--line", "13"]),
                Path::new("/b")
            )
            .is_err()
        );
    }

    #[test]
    fn wt_new_parses_base_flag() {
        let cmd = parse(
            &s(&["wt", "new", "feature", "--base", "main"]),
            Path::new("/b"),
        )
        .unwrap();
        assert_eq!(
            cmd,
            Command::WtNew {
                branch: "feature".into(),
                base: Some("main".into())
            }
        );
    }

    #[test]
    fn wt_new_no_base_is_ok() {
        let cmd = parse(&s(&["wt", "new", "feat"]), Path::new("/b")).unwrap();
        assert_eq!(
            cmd,
            Command::WtNew {
                branch: "feat".into(),
                base: None
            }
        );
    }

    #[test]
    fn wt_new_rejects_leading_flag() {
        assert!(parse(&s(&["wt", "new", "--base"]), Path::new("/b")).is_err());
        assert!(
            parse(
                &s(&["wt", "new", "--base", "main", "feature-x"]),
                Path::new("/b")
            )
            .is_err()
        );
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
        assert!(
            parse(
                &s(&["wt", "new", "feature", "--base", "--x"]),
                Path::new("/b")
            )
            .is_err()
        );
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
        assert_eq!(
            cmd,
            Command::WtDelete {
                target: "target".into(),
                force: true,
                keep_branch: true
            }
        );
    }

    #[test]
    fn wt_delete_no_flags_is_ok() {
        let cmd = parse(&s(&["wt", "delete", "target"]), Path::new("/b")).unwrap();
        assert_eq!(
            cmd,
            Command::WtDelete {
                target: "target".into(),
                force: false,
                keep_branch: false
            }
        );
    }

    #[test]
    fn wt_delete_rejects_leading_flag() {
        assert!(
            parse(
                &s(&["wt", "delete", "--force", "some-target"]),
                Path::new("/b")
            )
            .is_err()
        );
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
            Command::Review {
                target: None,
                worktree: None
            }
        );
    }

    #[test]
    fn review_comments_parses_flags_and_rejects_bad_state() {
        assert_eq!(
            parse(&s(&["review", "comments"]), Path::new("/b")).unwrap(),
            Command::ReviewComments {
                session_id: None,
                state: None
            }
        );
        assert_eq!(
            parse(
                &s(&["review", "comments", "--state", "all", "--session", "sid"]),
                Path::new("/b")
            )
            .unwrap(),
            Command::ReviewComments {
                session_id: Some("sid".into()),
                state: Some("all".into())
            }
        );
        assert!(
            parse(
                &s(&["review", "comments", "--state", "bogus"]),
                Path::new("/b")
            )
            .is_err()
        );
        assert!(parse(&s(&["review", "comments", "--session"]), Path::new("/b")).is_err());
        assert!(parse(&s(&["review", "comments", "extra"]), Path::new("/b")).is_err());
    }

    #[test]
    fn review_reply_takes_exactly_id_and_body() {
        assert_eq!(
            parse(
                &s(&["review", "reply", "c1", "looks good"]),
                Path::new("/b")
            )
            .unwrap(),
            Command::ReviewReply {
                comment_id: "c1".into(),
                body: "looks good".into()
            }
        );
        assert!(parse(&s(&["review", "reply", "c1"]), Path::new("/b")).is_err());
        assert!(parse(&s(&["review", "reply", "c1", "a", "b"]), Path::new("/b")).is_err());
    }

    #[test]
    fn review_resolve_parses_flags() {
        assert_eq!(
            parse(&s(&["review", "resolve", "c1"]), Path::new("/b")).unwrap(),
            Command::ReviewResolve {
                comment_id: "c1".into(),
                reply: None,
                reopen: false
            }
        );
        assert_eq!(
            parse(
                &s(&["review", "resolve", "c1", "--reply", "fixed", "--reopen"]),
                Path::new("/b")
            )
            .unwrap(),
            Command::ReviewResolve {
                comment_id: "c1".into(),
                reply: Some("fixed".into()),
                reopen: true
            }
        );
        assert!(parse(&s(&["review", "resolve"]), Path::new("/b")).is_err());
        assert!(parse(&s(&["review", "resolve", "--reopen"]), Path::new("/b")).is_err());
        assert!(parse(&s(&["review", "resolve", "c1", "--reply"]), Path::new("/b")).is_err());
    }

    #[test]
    fn review_finish_parses_flags_and_normalizes_request_changes() {
        assert_eq!(
            parse(&s(&["review", "finish"]), Path::new("/b")).unwrap(),
            Command::ReviewFinish {
                session_id: None,
                verdict: None,
                summary: None
            }
        );
        assert_eq!(
            parse(
                &s(&[
                    "review",
                    "finish",
                    "--session",
                    "sid",
                    "--verdict",
                    "request-changes",
                    "--summary",
                    "Fix it"
                ]),
                Path::new("/b")
            )
            .unwrap(),
            Command::ReviewFinish {
                session_id: Some("sid".into()),
                verdict: Some("request_changes".into()),
                summary: Some("Fix it".into()),
            }
        );
        assert!(
            parse(
                &s(&["review", "finish", "--verdict", "reject"]),
                Path::new("/b")
            )
            .is_err()
        );
        assert!(parse(&s(&["review", "finish", "summary"]), Path::new("/b")).is_err());
    }

    #[test]
    fn review_comment_parses_positionals_and_flags() {
        assert_eq!(
            parse(
                &s(&["review", "comment", "src/a.swift", "10", "fix this"]),
                Path::new("/b")
            )
            .unwrap(),
            Command::ReviewCommentAdd {
                path: "/b/src/a.swift".into(),
                start_line: 10,
                end_line: None,
                side: None,
                body: "fix this".into(),
                session_id: None,
            }
        );
        assert_eq!(
            parse(
                &s(&[
                    "review",
                    "comment",
                    "a.swift",
                    "3",
                    "b",
                    "--end-line",
                    "5",
                    "--side",
                    "old",
                    "--session",
                    "sid"
                ]),
                Path::new("/b")
            )
            .unwrap(),
            Command::ReviewCommentAdd {
                path: "/b/a.swift".into(),
                start_line: 3,
                end_line: Some(5),
                side: Some("old".into()),
                body: "b".into(),
                session_id: Some("sid".into()),
            }
        );
        assert!(
            parse(
                &s(&["review", "comment", "a.swift", "0", "b"]),
                Path::new("/b")
            )
            .is_err()
        );
        assert!(
            parse(
                &s(&["review", "comment", "a.swift", "x", "b"]),
                Path::new("/b")
            )
            .is_err()
        );
        assert!(
            parse(
                &s(&[
                    "review", "comment", "a.swift", "3", "b", "--side", "sideways"
                ]),
                Path::new("/b")
            )
            .is_err()
        );
        assert!(parse(&s(&["review", "comment", "a.swift"]), Path::new("/b")).is_err());
    }

    #[test]
    fn review_comment_resolves_relative_path_against_the_callers_subdirectory() {
        // `cd Sources && alas review comment App.swift 10 "..."` must resolve
        // to the actual changed file `/repo/Sources/App.swift`, not
        // `/repo/App.swift` (base is the worktree root; the caller's cwd is
        // a subdirectory of it, same as `open`).
        let cmd = parse(
            &s(&["review", "comment", "App.swift", "10", "fix this"]),
            Path::new("/repo/Sources"),
        )
        .unwrap();
        assert_eq!(
            cmd,
            Command::ReviewCommentAdd {
                path: "/repo/Sources/App.swift".into(),
                start_line: 10,
                end_line: None,
                side: None,
                body: "fix this".into(),
                session_id: None,
            }
        );
    }

    #[test]
    fn review_comment_keeps_an_already_absolute_path_unchanged() {
        let cmd = parse(
            &s(&[
                "review",
                "comment",
                "/repo/Sources/App.swift",
                "10",
                "fix this",
            ]),
            Path::new("/repo/Sources"),
        )
        .unwrap();
        assert_eq!(
            cmd,
            Command::ReviewCommentAdd {
                path: "/repo/Sources/App.swift".into(),
                start_line: 10,
                end_line: None,
                side: None,
                body: "fix this".into(),
                session_id: None,
            }
        );
    }

    #[test]
    fn plain_review_targets_still_parse() {
        assert_eq!(
            parse(&s(&["review", "123"]), Path::new("/b")).unwrap(),
            Command::Review {
                target: Some("123".into()),
                worktree: None
            }
        );
    }

    #[test]
    fn review_parses_worktree_flag_with_and_without_target() {
        assert_eq!(
            parse(
                &s(&["review", "abc123", "--worktree", "feature-x"]),
                Path::new("/b")
            )
            .unwrap(),
            Command::Review {
                target: Some("abc123".into()),
                worktree: Some("feature-x".into())
            }
        );
        assert_eq!(
            parse(&s(&["review", "--worktree", "feature-x"]), Path::new("/b")).unwrap(),
            Command::Review {
                target: None,
                worktree: Some("feature-x".into())
            }
        );
        assert_eq!(
            parse(
                &s(&["review", "main..HEAD", "--worktree", "feature-x"]),
                Path::new("/b")
            )
            .unwrap(),
            Command::Review {
                target: Some("main..HEAD".into()),
                worktree: Some("feature-x".into())
            }
        );
    }

    #[test]
    fn review_rejects_bad_worktree_flag_usage() {
        assert!(parse(&s(&["review", "--worktree"]), Path::new("/b")).is_err());
        assert!(
            parse(
                &s(&["review", "x", "--worktree", "--flag"]),
                Path::new("/b")
            )
            .is_err()
        );
        assert!(
            parse(
                &s(&["review", "x", "--worktree", "a", "--worktree", "b"]),
                Path::new("/b")
            )
            .is_err()
        );
        assert!(parse(&s(&["review", "x", "--unknown", "v"]), Path::new("/b")).is_err());
    }

    #[test]
    fn review_double_dash_escapes_subcommand_like_targets() {
        for name in ["finish", "comments", "comment", "reply", "resolve"] {
            assert_eq!(
                parse(&s(&["review", "--", name]), Path::new("/b")).unwrap(),
                Command::Review {
                    target: Some(name.into()),
                    worktree: None
                },
                "target {name:?} should escape to a plain review target"
            );
        }
    }

    #[test]
    fn review_absolutizes_path_shaped_worktree_values() {
        assert_eq!(
            parse(
                &s(&["review", "--worktree", "../sibling"]),
                Path::new("/repo/current")
            )
            .unwrap(),
            Command::Review {
                target: None,
                worktree: Some("/repo/sibling".into())
            }
        );
        assert_eq!(
            parse(
                &s(&["review", "--worktree", "./nested"]),
                Path::new("/repo/current")
            )
            .unwrap(),
            Command::Review {
                target: None,
                worktree: Some("/repo/current/nested".into())
            }
        );
    }

    #[test]
    fn review_leaves_bare_worktree_names_untouched() {
        assert_eq!(
            parse(
                &s(&["review", "--worktree", "feature-x"]),
                Path::new("/repo/current")
            )
            .unwrap(),
            Command::Review {
                target: None,
                worktree: Some("feature-x".into())
            }
        );
    }

    #[test]
    fn review_worktree_already_absolute_path_passes_through() {
        assert_eq!(
            parse(
                &s(&["review", "--worktree", "/already/absolute/path"]),
                Path::new("/repo/current")
            )
            .unwrap(),
            Command::Review {
                target: None,
                worktree: Some("/already/absolute/path".into())
            }
        );
    }

    #[test]
    fn review_leaves_slash_named_worktree_branches_untouched() {
        // Branch names containing `/` are an extremely common convention
        // (`feature/foo`, `release/1.0`, `bugfix/login-crash`). They must
        // not be mistaken for paths just because they contain a slash —
        // only an `/`, `./`, or `../` prefix makes a value path-shaped.
        for name in ["feature/foo", "release/1.0", "bugfix/login-crash"] {
            assert_eq!(
                parse(
                    &s(&["review", "--worktree", name]),
                    Path::new("/repo/current")
                )
                .unwrap(),
                Command::Review {
                    target: None,
                    worktree: Some(name.into())
                },
                "worktree {name:?} should pass through unmodified"
            );
        }

        // A bare value like `sub/dir` could theoretically be a genuine
        // relative subdirectory, but without an explicit `./` prefix it is
        // treated as a name, not a path. This is an intentional tradeoff:
        // a user who means a relative subdirectory can type `./sub/dir`.
        assert_eq!(
            parse(
                &s(&["review", "--worktree", "sub/dir"]),
                Path::new("/repo/current")
            )
            .unwrap(),
            Command::Review {
                target: None,
                worktree: Some("sub/dir".into())
            }
        );
    }

    #[test]
    fn review_absolutizes_bare_dot_and_dotdot_worktree_values() {
        assert_eq!(
            parse(
                &s(&["review", "--worktree", "."]),
                Path::new("/repo/current")
            )
            .unwrap(),
            Command::Review {
                target: None,
                worktree: Some("/repo/current".into())
            }
        );
        assert_eq!(
            parse(
                &s(&["review", "--worktree", ".."]),
                Path::new("/repo/current")
            )
            .unwrap(),
            Command::Review {
                target: None,
                worktree: Some("/repo".into())
            }
        );

        // Regression guard: `.`/`..` handling must not broaden the check
        // back toward matching other bare, slash-containing branch names.
        assert_eq!(
            parse(
                &s(&["review", "--worktree", "feature/foo"]),
                Path::new("/repo/current")
            )
            .unwrap(),
            Command::Review {
                target: None,
                worktree: Some("feature/foo".into())
            }
        );
    }

    #[test]
    fn review_double_dash_composes_with_absolutized_worktree() {
        assert_eq!(
            parse(
                &s(&["review", "--worktree", "../sibling", "--", "finish"]),
                Path::new("/repo/current")
            )
            .unwrap(),
            Command::Review {
                target: Some("finish".into()),
                worktree: Some("/repo/sibling".into())
            }
        );
    }

    #[test]
    fn review_double_dash_composes_with_worktree_flag_on_either_side() {
        assert_eq!(
            parse(
                &s(&["review", "--worktree", "feature", "--", "finish"]),
                Path::new("/b")
            )
            .unwrap(),
            Command::Review {
                target: Some("finish".into()),
                worktree: Some("feature".into())
            }
        );
        assert_eq!(
            parse(
                &s(&["review", "--", "finish", "--worktree", "feature"]),
                Path::new("/b")
            )
            .unwrap(),
            Command::Review {
                target: Some("finish".into()),
                worktree: Some("feature".into())
            }
        );
    }

    #[test]
    fn workspace_commands_parse_uuid_targets_and_require_member_for_focus() {
        let checkout = "7D064822-8491-4E33-BD74-355FD2AB3330";
        let member = "C2476427-94B2-423F-A490-568775E8B309";

        assert_eq!(
            parse(&s(&["workspace", "list"]), Path::new("/b")).unwrap(),
            Command::WorkspaceList
        );
        assert_eq!(
            parse(&s(&["workspace", "show", checkout]), Path::new("/b")).unwrap(),
            Command::WorkspaceShow { checkout_id: checkout.into() }
        );
        assert_eq!(
            parse(&s(&["workspace", "switch", checkout]), Path::new("/b")).unwrap(),
            Command::WorkspaceSwitch { checkout_id: checkout.into() }
        );
        assert_eq!(
            parse(&s(&["workspace", "focus", checkout, "--member", member]), Path::new("/b")).unwrap(),
            Command::WorkspaceFocus { checkout_id: checkout.into(), member_id: member.into() }
        );
        assert!(parse(&s(&["workspace", "focus", checkout]), Path::new("/b")).is_err());
        assert!(parse(&s(&["workspace", "delete", checkout]), Path::new("/b")).is_err());
    }

    #[test]
    fn session_commands_parse_and_validate() {
        assert_eq!(
            parse(&s(&["session", "list"]), Path::new("/b")).unwrap(),
            Command::SessionList
        );
        assert_eq!(
            parse(
                &s(&[
                    "session",
                    "new",
                    "--prompt",
                    "Task",
                    "--agent",
                    "codex",
                    "--worktree",
                    "feature",
                ]),
                Path::new("/b"),
            )
            .unwrap(),
            Command::SessionNew {
                prompt: "Task".into(),
                agent: Some("codex".into()),
                worktree: alas_client::SessionWorktreeTarget::Existing {
                    worktree: "feature".into()
                }
            }
        );
        assert_eq!(
            parse(
                &s(&[
                    "session",
                    "new",
                    "--prompt",
                    "Task",
                    "--new-worktree",
                    "child",
                    "--base",
                    "origin/main",
                ]),
                Path::new("/b"),
            )
            .unwrap(),
            Command::SessionNew {
                prompt: "Task".into(),
                agent: None,
                worktree: alas_client::SessionWorktreeTarget::New {
                    branch: "child".into(),
                    base: Some("origin/main".into())
                }
            }
        );
        assert_eq!(
            parse(
                &s(&["session", "send", "child", "Follow-up"]),
                Path::new("/b"),
            )
            .unwrap(),
            Command::SessionSend {
                session_id: "child".into(),
                prompt: "Follow-up".into()
            }
        );
        for invalid in [
            ["session", "new", "--prompt", "Task", "--prompt", "Again"].as_slice(),
            [
                "session",
                "new",
                "--prompt",
                "Task",
                "--worktree",
                "main",
                "--new-worktree",
                "child",
            ]
            .as_slice(),
            [
                "session",
                "new",
                "--prompt",
                "Task",
                "--base",
                "origin/main",
            ]
            .as_slice(),
            ["session", "send", "child"].as_slice(),
        ] {
            assert!(parse(&s(invalid), Path::new("/b")).is_err());
        }
    }

    #[test]
    fn ao_detected_from_argv0() {
        assert!(is_ao("/usr/local/bin/ao"));
        assert!(!is_ao("/usr/local/bin/alas"));
    }
}
