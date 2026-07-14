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
        "tools/list" => Ok(json!({ "tools": tool_definitions() })),
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

/// The six agent-facing tools, mirroring the CLI 1:1. Descriptions make
/// explicit that these act on the user's Alas UI — that is what makes the
/// agent-side permission prompt legible. `resolve` is internal and not
/// exposed.
pub fn tool_definitions() -> Vec<Value> {
    vec![
        json!({
            "name": "open",
            "description": "Open one or more files in the Alas UI for the user to look at. Paths may be relative to the worktree root or absolute.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "paths": {
                        "type": "array",
                        "items": { "type": "string" },
                        "minItems": 1,
                        "description": "Files to open in Alas."
                    }
                },
                "required": ["paths"]
            }
        }),
        json!({
            "name": "worktree_list",
            "description": "List this project's worktrees in Alas. The current worktree is marked with an asterisk.",
            "inputSchema": { "type": "object", "properties": {} }
        }),
        json!({
            "name": "worktree_switch",
            "description": "Switch the user's Alas window focus to another worktree of this project.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "target": { "type": "string", "description": "Worktree name or branch name." }
                },
                "required": ["target"]
            }
        }),
        json!({
            "name": "worktree_new",
            "description": "Create a new linked worktree in Alas for the given branch and focus it.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "branch": { "type": "string", "description": "Branch name for the new worktree." },
                    "base": { "type": "string", "description": "Base ref to branch from. Defaults to the repository's default base." }
                },
                "required": ["branch"]
            }
        }),
        json!({
            "name": "worktree_delete",
            "description": "Delete a linked worktree in Alas. Refuses when the worktree has uncommitted changes unless force is set.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "target": { "type": "string", "description": "Worktree name or branch name." },
                    "force": { "type": "boolean", "description": "Delete even with uncommitted changes. Default false." },
                    "keep_branch": { "type": "boolean", "description": "Keep the git branch, delete only the worktree. Default false." }
                },
                "required": ["target"]
            }
        }),
        json!({
            "name": "review",
            "description": "Open Alas's review pane for the user: on the current local changes when target is omitted, or on a provider pull/merge request when target (a PR/MR number or URL) is given.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "target": { "type": "string", "description": "PR/MR number or URL. Omit to review local changes." }
                }
            }
        }),
    ]
}

/// Translate a tool call into the CLI command it mirrors. Relative `open`
/// paths absolutize against the injected worktree dir — never the process
/// cwd, which the agent controls.
pub fn command_for_tool(name: &str, args: &Value, worktree_dir: &str) -> Result<Command, String> {
    match name {
        "open" => {
            let paths = args
                .get("paths")
                .and_then(Value::as_array)
                .ok_or("open requires a 'paths' array")?;
            if paths.is_empty() {
                return Err("open requires at least one path".into());
            }
            let base = std::path::Path::new(worktree_dir);
            let mut resolved = Vec::new();
            for path in paths {
                let path = path.as_str().ok_or("open paths must be strings")?;
                if path.trim().is_empty() {
                    return Err("open paths must be non-empty".into());
                }
                resolved.push(alas_client::absolutize(base, path));
            }
            Ok(Command::Open { paths: resolved })
        }
        "worktree_list" => Ok(Command::WtList),
        "worktree_switch" => Ok(Command::WtSwitch { target: required_string(args, "target")? }),
        "worktree_new" => Ok(Command::WtNew {
            branch: required_string(args, "branch")?,
            base: optional_string(args, "base"),
        }),
        "worktree_delete" => Ok(Command::WtDelete {
            target: required_string(args, "target")?,
            force: args.get("force").and_then(Value::as_bool).unwrap_or(false),
            keep_branch: args.get("keep_branch").and_then(Value::as_bool).unwrap_or(false),
        }),
        "review" => Ok(Command::Review { target: optional_string(args, "target") }),
        other => Err(format!("unknown tool: {other}")),
    }
}

fn required_string(args: &Value, key: &str) -> Result<String, String> {
    optional_string(args, key).ok_or_else(|| format!("missing required argument '{key}'"))
}

fn optional_string(args: &Value, key: &str) -> Option<String> {
    args.get(key)
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(String::from)
}

#[cfg(test)]
mod tests {
    use super::{command_for_tool, env_from, handle_line, tool_definitions, PROTOCOL_VERSION};
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

    #[test]
    fn tools_list_returns_the_six_tools() {
        let line = r#"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#;
        let reply = handle_line(line, "/wt", ok_dispatch).unwrap();
        let tools = reply["result"]["tools"].as_array().unwrap();
        let names: Vec<&str> = tools.iter().map(|t| t["name"].as_str().unwrap()).collect();
        assert_eq!(
            names,
            ["open", "worktree_list", "worktree_switch", "worktree_new", "worktree_delete", "review"]
        );
        for tool in tools {
            assert!(tool["description"].as_str().unwrap().len() > 20);
            assert_eq!(tool["inputSchema"]["type"], json!("object"));
        }
    }

    #[test]
    fn open_maps_paths_and_absolutizes_relative_ones() {
        let cmd = command_for_tool("open", &json!({"paths": ["a.txt", "/abs/b.txt"]}), "/wt").unwrap();
        assert_eq!(
            cmd,
            alas_client::Command::Open { paths: vec!["/wt/a.txt".into(), "/abs/b.txt".into()] }
        );
    }

    #[test]
    fn open_rejects_missing_empty_or_non_string_paths() {
        assert!(command_for_tool("open", &json!({}), "/wt").is_err());
        assert!(command_for_tool("open", &json!({"paths": []}), "/wt").is_err());
        assert!(command_for_tool("open", &json!({"paths": [1]}), "/wt").is_err());
        assert!(command_for_tool("open", &json!({"paths": ["  "]}), "/wt").is_err());
    }

    #[test]
    fn worktree_tools_map_to_wt_commands() {
        assert_eq!(
            command_for_tool("worktree_list", &json!({}), "/wt").unwrap(),
            alas_client::Command::WtList
        );
        assert_eq!(
            command_for_tool("worktree_switch", &json!({"target": "feat"}), "/wt").unwrap(),
            alas_client::Command::WtSwitch { target: "feat".into() }
        );
        assert_eq!(
            command_for_tool("worktree_new", &json!({"branch": "feat", "base": "main"}), "/wt").unwrap(),
            alas_client::Command::WtNew { branch: "feat".into(), base: Some("main".into()) }
        );
        assert_eq!(
            command_for_tool("worktree_new", &json!({"branch": "feat"}), "/wt").unwrap(),
            alas_client::Command::WtNew { branch: "feat".into(), base: None }
        );
        assert_eq!(
            command_for_tool(
                "worktree_delete",
                &json!({"target": "feat", "force": true, "keep_branch": true}),
                "/wt"
            )
            .unwrap(),
            alas_client::Command::WtDelete { target: "feat".into(), force: true, keep_branch: true }
        );
        assert_eq!(
            command_for_tool("worktree_delete", &json!({"target": "feat"}), "/wt").unwrap(),
            alas_client::Command::WtDelete { target: "feat".into(), force: false, keep_branch: false }
        );
    }

    #[test]
    fn worktree_tools_reject_missing_required_args() {
        assert!(command_for_tool("worktree_switch", &json!({}), "/wt").is_err());
        assert!(command_for_tool("worktree_new", &json!({}), "/wt").is_err());
        assert!(command_for_tool("worktree_delete", &json!({}), "/wt").is_err());
    }

    #[test]
    fn review_target_is_optional() {
        assert_eq!(
            command_for_tool("review", &json!({}), "/wt").unwrap(),
            alas_client::Command::Review { target: None }
        );
        assert_eq!(
            command_for_tool("review", &json!({"target": "123"}), "/wt").unwrap(),
            alas_client::Command::Review { target: Some("123".into()) }
        );
    }

    #[test]
    fn unknown_tool_is_an_error() {
        assert!(command_for_tool("resolve", &json!({}), "/wt").is_err());
        assert!(command_for_tool("nope", &json!({}), "/wt").is_err());
    }
}
