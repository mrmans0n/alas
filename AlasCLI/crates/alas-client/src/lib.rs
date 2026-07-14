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
}
