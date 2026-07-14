use serde::{Deserialize, Serialize};
use std::path::{Component, Path, PathBuf};

pub const PROTOCOL_VERSION: u32 = 1;

/// The base directory `open`/`cwd` paths resolve against. Prefers the logical
/// `$PWD` (which preserves the symlinked path the user `cd`'d through) and
/// falls back to the process working directory, matching the old sh script.
pub fn logical_base() -> PathBuf {
    if let Some(pwd) = std::env::var_os("PWD") {
        let p = PathBuf::from(pwd);
        if p.is_absolute() {
            return p;
        }
    }
    std::env::current_dir().unwrap_or_else(|_| PathBuf::from("/"))
}

/// Absolute, lexically-normalized path for `input` resolved against `base`.
/// Collapses `.`/`..`/repeated separators and strips a trailing slash. Does not
/// touch the filesystem, so symlinks in `base` are preserved.
pub fn absolutize(base: &Path, input: &str) -> String {
    let joined = if Path::new(input).is_absolute() {
        PathBuf::from(input)
    } else {
        base.join(input)
    };

    let mut out: Vec<std::ffi::OsString> = Vec::new();
    for component in joined.components() {
        match component {
            Component::RootDir | Component::Prefix(_) => {}
            Component::CurDir => {}
            Component::ParentDir => {
                out.pop();
            }
            Component::Normal(part) => out.push(part.to_os_string()),
        }
    }

    let mut result = String::from("/");
    for (i, part) in out.iter().enumerate() {
        if i > 0 {
            result.push('/');
        }
        result.push_str(&part.to_string_lossy());
    }
    result
}

/// One CLI request over the Alas Unix socket. `session_id` and `cwd` are both
/// optional on the wire, but a valid request always carries at least one; the
/// app prefers `session_id`. Fields serialize only when present so an older app
/// that ignores unknown keys stays compatible.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Request {
    pub v: u32,
    pub kind: &'static str,
    pub command: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cwd: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub subcommand: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub target: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub branch: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub base: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub force: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub keep_branch: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub paths: Option<Vec<String>>,
}

impl Request {
    /// A request with all optional fields cleared and `v`/`kind` fixed.
    pub fn new(command: impl Into<String>) -> Self {
        Request {
            v: PROTOCOL_VERSION,
            kind: "cli",
            command: command.into(),
            session_id: None,
            cwd: None,
            subcommand: None,
            target: None,
            branch: None,
            base: None,
            force: None,
            keep_branch: None,
            paths: None,
        }
    }
}

/// The app's reply. `ok` is authoritative; `lines` is present for list-style
/// output, `error` for failures.
#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct Response {
    pub ok: bool,
    #[serde(default)]
    pub lines: Option<Vec<String>>,
    #[serde(default)]
    pub error: Option<String>,
}

/// The parsed CLI intent, independent of transport. `Open` paths are already
/// absolutized by the caller.
#[derive(Debug, Clone, PartialEq)]
pub enum Command {
    Open { paths: Vec<String> },
    WtList,
    WtSwitch { target: String },
    WtNew { branch: String, base: Option<String> },
    WtDelete { target: String, force: bool, keep_branch: bool },
    Review { target: Option<String> },
    Resolve,
}

/// Build the wire request for a command, attaching whichever addressing the
/// caller resolved (`session_id` inside Alas, else `cwd`).
pub fn build_request(command: &Command, session_id: Option<String>, cwd: Option<String>) -> Request {
    let mut req = match command {
        Command::Open { paths } => {
            let mut r = Request::new("open");
            r.paths = Some(paths.clone());
            r
        }
        Command::WtList => {
            let mut r = Request::new("wt");
            r.subcommand = Some("list".into());
            r
        }
        Command::WtSwitch { target } => {
            let mut r = Request::new("wt");
            r.subcommand = Some("switch".into());
            r.target = Some(target.clone());
            r
        }
        Command::WtNew { branch, base } => {
            let mut r = Request::new("wt");
            r.subcommand = Some("new".into());
            r.branch = Some(branch.clone());
            r.base = base.clone();
            r
        }
        Command::WtDelete { target, force, keep_branch } => {
            let mut r = Request::new("wt");
            r.subcommand = Some("delete".into());
            r.target = Some(target.clone());
            r.force = Some(*force);
            r.keep_branch = Some(*keep_branch);
            r
        }
        Command::Review { target } => {
            let mut r = Request::new("review");
            r.target = target.clone();
            r
        }
        Command::Resolve => Request::new("resolve"),
    };
    req.session_id = session_id;
    req.cwd = cwd;
    req
}

/// The per-user socket directory Alas binds its `pid-<pid>` sockets under.
pub fn socket_dir() -> PathBuf {
    let uid = unsafe { libc::getuid() };
    PathBuf::from(format!("/tmp/alas-{}", uid))
}

/// True if a process with `pid` exists and we may signal it. Same-uid callers
/// get `0` for a live process; a missing process yields `ESRCH`.
fn process_alive(pid: i32) -> bool {
    unsafe { libc::kill(pid, 0) == 0 }
}

/// Live `pid-<pid>` sockets in `dir`, filtering out entries whose process has
/// exited. Non-`pid-` entries (e.g. per-leaf `sock-` symlinks) are ignored.
pub fn discover_live_sockets_in(dir: &Path) -> Vec<PathBuf> {
    let mut result = Vec::new();
    let Ok(entries) = std::fs::read_dir(dir) else {
        return result;
    };
    for entry in entries.flatten() {
        let name = entry.file_name();
        let name = name.to_string_lossy();
        let Some(pid_str) = name.strip_prefix("pid-") else {
            continue;
        };
        let Ok(pid) = pid_str.parse::<i32>() else {
            continue;
        };
        if process_alive(pid) {
            result.push(entry.path());
        }
    }
    result.sort();
    result
}

/// Live Alas sockets under the standard per-user directory.
pub fn discover_live_sockets() -> Vec<PathBuf> {
    discover_live_sockets_in(&socket_dir())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::Path;

    #[test]
    fn absolutize_joins_relative_against_base_without_resolving_symlinks() {
        let base = Path::new("/logical/dir with spaces");
        assert_eq!(
            absolutize(base, "sub/file.txt"),
            "/logical/dir with spaces/sub/file.txt"
        );
    }

    #[test]
    fn absolutize_normalizes_dot_and_dotdot_lexically() {
        let base = Path::new("/a/b");
        assert_eq!(absolutize(base, "../c/./d"), "/a/c/d");
        assert_eq!(absolutize(base, "/x//y/"), "/x/y");
    }

    #[test]
    fn absolutize_keeps_absolute_input() {
        let base = Path::new("/a/b");
        assert_eq!(absolutize(base, "/etc/hosts"), "/etc/hosts");
    }

    #[test]
    fn open_request_omits_absent_fields() {
        let mut req = Request::new("open");
        req.session_id = Some("s1".into());
        req.paths = Some(vec!["/tmp/a.txt".into()]);
        let json = serde_json::to_string(&req).unwrap();
        assert_eq!(
            json,
            r#"{"v":1,"kind":"cli","command":"open","session_id":"s1","paths":["/tmp/a.txt"]}"#
        );
    }

    #[test]
    fn response_parses_lines_and_error_defaults() {
        let ok: Response = serde_json::from_str(r#"{"ok":true}"#).unwrap();
        assert!(ok.ok && ok.lines.is_none() && ok.error.is_none());
        let err: Response = serde_json::from_str(r#"{"ok":false,"error":"nope"}"#).unwrap();
        assert_eq!(err.error.as_deref(), Some("nope"));
    }

    #[test]
    fn builds_wt_new_with_base() {
        let cmd = Command::WtNew { branch: "feature".into(), base: Some("main".into()) };
        let req = build_request(&cmd, Some("s1".into()), None);
        let json = serde_json::to_string(&req).unwrap();
        assert_eq!(
            json,
            r#"{"v":1,"kind":"cli","command":"wt","session_id":"s1","subcommand":"new","branch":"feature","base":"main"}"#
        );
    }

    #[test]
    fn builds_wt_delete_flags_and_cwd() {
        let cmd = Command::WtDelete { target: "feature".into(), force: true, keep_branch: false };
        let req = build_request(&cmd, None, Some("/repo".into()));
        assert_eq!(req.command, "wt");
        assert_eq!(req.subcommand.as_deref(), Some("delete"));
        assert_eq!(req.cwd.as_deref(), Some("/repo"));
        assert_eq!(req.force, Some(true));
        assert_eq!(req.keep_branch, Some(false));
    }

    #[test]
    fn builds_review_local_and_provider() {
        let local = build_request(&Command::Review { target: None }, Some("s1".into()), None);
        assert_eq!(local.command, "review");
        assert!(local.target.is_none());
        let provider = build_request(&Command::Review { target: Some("123".into()) }, Some("s1".into()), None);
        assert_eq!(provider.target.as_deref(), Some("123"));
    }

    #[test]
    fn builds_resolve_with_cwd_only() {
        let req = build_request(&Command::Resolve, None, Some("/repo".into()));
        assert_eq!(req.command, "resolve");
        assert_eq!(req.cwd.as_deref(), Some("/repo"));
        assert!(req.session_id.is_none());
    }

    #[test]
    fn discovers_only_live_pid_sockets() {
        let root = std::env::temp_dir().join(format!("alas-cli-disc-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        // Live: our own pid. Dead: pid 999999999 (out of range, guaranteed absent).
        let live = root.join(format!("pid-{}", std::process::id()));
        let dead = root.join("pid-999999999");
        let junk = root.join("sock-abc"); // symlink-style entry, ignored by prefix
        std::fs::write(&live, b"").unwrap();
        std::fs::write(&dead, b"").unwrap();
        std::fs::write(&junk, b"").unwrap();

        let found = discover_live_sockets_in(&root);
        assert_eq!(found, vec![live]);
        let _ = std::fs::remove_dir_all(&root);
    }
}
