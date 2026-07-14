//! MCP stdio server mode: newline-delimited JSON-RPC on stdin/stdout,
//! translating tool calls into the same socket requests the CLI sends.
//! Hand-rolled on purpose — the surface is five methods; an MCP SDK would
//! be the largest dependency in the workspace.

use alas_client::{Command, Response, TransportError};
use serde_json::{json, Value};
use std::path::PathBuf;

pub const PROTOCOL_VERSION: &str = "2025-06-18";

/// Injected by the app in the MCP server definition. Both values are
/// required: `alas mcp` is launched by Alas itself and deliberately has no
/// discovery fallback (a hand-run `alas mcp` is not a supported mode).
pub struct McpEnv {
    pub socket: PathBuf,
    pub worktree_dir: String,
}

/// Build the env from a lookup function (`std::env::var` in production,
/// a fixture map in tests — process-global env mutation is racy in tests).
pub fn env_from(get: impl Fn(&str) -> Option<String>) -> Result<McpEnv, String> {
    let socket = get("ALAS_SOCKET_PATH")
        .filter(|s| !s.is_empty())
        .ok_or("alas mcp requires ALAS_SOCKET_PATH (it is launched by Alas, not by hand)")?;
    let worktree_dir = get("ALAS_WORKTREE_DIR")
        .filter(|s| !s.is_empty())
        .ok_or("alas mcp requires ALAS_WORKTREE_DIR (it is launched by Alas, not by hand)")?;
    if !worktree_dir.starts_with('/') {
        return Err("ALAS_WORKTREE_DIR must be an absolute path".into());
    }
    Ok(McpEnv { socket: PathBuf::from(socket), worktree_dir })
}

/// Handle one raw input line. Returns the JSON-RPC reply to write, or None
/// when no reply must be produced (notifications — replying to one is a
/// protocol violation).
pub fn handle_line(
    line: &str,
    worktree_dir: &str,
    dispatch: impl FnMut(&Command) -> Result<Response, TransportError>,
) -> Option<Value> {
    let _ = (worktree_dir, &dispatch); // used from Task 3 on
    let msg: Value = match serde_json::from_str(line) {
        Ok(v) => v,
        Err(_) => return Some(error_reply(Value::Null, -32700, "parse error")),
    };
    // Messages without an id are notifications (e.g. notifications/initialized).
    let id = msg.get("id").cloned()?;
    let method = msg.get("method").and_then(Value::as_str).unwrap_or_default();
    let reply = match method {
        "initialize" => Ok(initialize_result()),
        "ping" => Ok(json!({})),
        other => Err((-32601, format!("method not found: {other}"))),
    };
    Some(match reply {
        Ok(result) => json!({ "jsonrpc": "2.0", "id": id, "result": result }),
        Err((code, message)) => error_reply(id, code, &message),
    })
}

fn initialize_result() -> Value {
    json!({
        "protocolVersion": PROTOCOL_VERSION,
        "capabilities": { "tools": {} },
        "serverInfo": { "name": "alas", "version": env!("CARGO_PKG_VERSION") },
        "instructions": "Tools that drive the user's Alas workspace UI: open files for the user to look at, manage linked worktrees, and open reviews."
    })
}

fn error_reply(id: Value, code: i64, message: &str) -> Value {
    json!({ "jsonrpc": "2.0", "id": id, "error": { "code": code, "message": message } })
}

#[cfg(test)]
mod tests {
    use super::{env_from, handle_line, PROTOCOL_VERSION};
    use alas_client::Response;
    use serde_json::{json, Value};

    fn ok_dispatch(_: &alas_client::Command) -> Result<Response, alas_client::TransportError> {
        Ok(Response { ok: true, lines: None, error: None })
    }

    fn env<'a>(vars: &'a [(&'a str, &'a str)]) -> impl Fn(&str) -> Option<String> + 'a {
        move |key| {
            vars.iter()
                .find(|(k, _)| *k == key)
                .map(|(_, v)| v.to_string())
        }
    }

    #[test]
    fn env_from_requires_both_vars() {
        assert!(env_from(env(&[("ALAS_WORKTREE_DIR", "/wt")])).is_err());
        assert!(env_from(env(&[("ALAS_SOCKET_PATH", "/tmp/s")])).is_err());
        assert!(env_from(env(&[("ALAS_SOCKET_PATH", ""), ("ALAS_WORKTREE_DIR", "/wt")])).is_err());
        let ok = env_from(env(&[("ALAS_SOCKET_PATH", "/tmp/s"), ("ALAS_WORKTREE_DIR", "/wt")])).unwrap();
        assert_eq!(ok.socket, std::path::PathBuf::from("/tmp/s"));
        assert_eq!(ok.worktree_dir, "/wt");
    }

    #[test]
    fn env_from_rejects_relative_worktree_dir() {
        assert!(env_from(env(&[("ALAS_SOCKET_PATH", "/tmp/s"), ("ALAS_WORKTREE_DIR", "wt")])).is_err());
    }

    #[test]
    fn initialize_returns_server_info_and_tools_capability() {
        let line = r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"c","version":"1"}}}"#;
        let reply = handle_line(line, "/wt", ok_dispatch).unwrap();
        assert_eq!(reply["id"], json!(1));
        assert_eq!(reply["result"]["protocolVersion"], json!(PROTOCOL_VERSION));
        assert_eq!(reply["result"]["serverInfo"]["name"], json!("alas"));
        assert!(reply["result"]["capabilities"]["tools"].is_object());
        assert!(reply["result"]["instructions"].is_string());
    }

    #[test]
    fn initialized_notification_gets_no_reply() {
        let line = r#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#;
        assert_eq!(handle_line(line, "/wt", ok_dispatch), None);
    }

    #[test]
    fn ping_returns_empty_result() {
        let line = r#"{"jsonrpc":"2.0","id":"p1","method":"ping"}"#;
        let reply = handle_line(line, "/wt", ok_dispatch).unwrap();
        assert_eq!(reply["id"], json!("p1"));
        assert_eq!(reply["result"], json!({}));
    }

    #[test]
    fn unknown_method_is_method_not_found() {
        let line = r#"{"jsonrpc":"2.0","id":2,"method":"resources/list"}"#;
        let reply = handle_line(line, "/wt", ok_dispatch).unwrap();
        assert_eq!(reply["error"]["code"], json!(-32601));
    }

    #[test]
    fn malformed_line_is_parse_error_with_null_id() {
        let reply = handle_line("{not json", "/wt", ok_dispatch).unwrap();
        assert_eq!(reply["error"]["code"], json!(-32700));
        assert_eq!(reply["id"], Value::Null);
    }
}
