use serde::{Deserialize, Serialize};

pub const PROTOCOL_VERSION: u32 = 1;

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
