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
    mut dispatch: impl FnMut(&Command) -> Result<Response, TransportError>,
) -> Option<Value> {
    let msg: Value = match serde_json::from_str(line) {
        Ok(v) => v,
        Err(_) => return Some(error_reply(Value::Null, -32700, "parse error")),
    };
    if !msg.is_object() {
        return Some(error_reply(Value::Null, -32600, "invalid request"));
    }
    // Messages without an id are notifications (e.g. notifications/initialized).
    let id = msg.get("id").cloned()?;
    let method = msg.get("method").and_then(Value::as_str).unwrap_or_default();
    let reply = match method {
        "initialize" => Ok(initialize_result()),
        "ping" => Ok(json!({})),
        "tools/list" => Ok(json!({ "tools": tool_definitions() })),
        "tools/call" => {
            let params = msg.get("params").cloned().unwrap_or(Value::Null);
            call_tool(&params, worktree_dir, &mut dispatch)
        }
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

/// The agent-facing tools, mirroring the CLI 1:1. Descriptions make
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
        json!({
            "name": "review_comments",
            "description": "List review comments from the user's Alas review pane for this worktree, as a JSON array. Each comment has an id, path, line range, side, state (active/resolved/dismissed), author, body, and replies. Defaults to active comments only.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "session_id": { "type": "string", "description": "Limit to one review session (from the review tool). Omit to list across the worktree's review sessions." },
                    "state": { "type": "string", "enum": ["active", "resolved", "dismissed", "all"], "description": "Filter by comment state. Default: active." }
                }
            }
        }),
        json!({
            "name": "review_reply",
            "description": "Reply to a review comment thread in the user's Alas review pane. Use review_resolve instead when the reply also settles the comment.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "comment_id": { "type": "string", "description": "Comment id, from review_comments." },
                    "body": { "type": "string", "description": "Reply body, Markdown." }
                },
                "required": ["comment_id", "body"]
            }
        }),
        json!({
            "name": "review_resolve",
            "description": "Resolve a review comment in the user's Alas review pane after addressing it, optionally posting a reply first. Pass state 'active' to reopen a comment instead.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "comment_id": { "type": "string", "description": "Comment id, from review_comments." },
                    "reply": { "type": "string", "description": "Optional reply to post before changing state, e.g. a one-line summary of the fix." },
                    "state": { "type": "string", "enum": ["resolved", "active"], "description": "Target state. Default: resolved." }
                },
                "required": ["comment_id"]
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
        "review" => Ok(Command::Review { target: review_target(args)? }),
        "review_comments" => {
            let state = optional_string(args, "state");
            if let Some(state) = &state {
                if !["active", "resolved", "dismissed", "all"].contains(&state.as_str()) {
                    return Err("review_comments 'state' must be one of active|resolved|dismissed|all".into());
                }
            }
            Ok(Command::ReviewComments { session_id: optional_string(args, "session_id"), state })
        }
        "review_reply" => Ok(Command::ReviewReply {
            comment_id: required_string(args, "comment_id")?,
            body: required_string(args, "body")?,
        }),
        "review_resolve" => {
            let reopen = match optional_string(args, "state").as_deref() {
                None | Some("resolved") => false,
                Some("active") => true,
                Some(_) => return Err("review_resolve 'state' must be 'resolved' or 'active'".into()),
            };
            Ok(Command::ReviewResolve {
                comment_id: required_string(args, "comment_id")?,
                reply: optional_string(args, "reply"),
                reopen,
            })
        }
        other => Err(format!("unknown tool: {other}")),
    }
}

/// `review` targets are commonly numeric PR/MR ids, so JSON numbers are
/// coerced to strings; other non-string shapes are rejected instead of being
/// silently treated as "review local changes".
fn review_target(args: &Value) -> Result<Option<String>, String> {
    match args.get("target") {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(s)) => {
            let s = s.trim();
            Ok(if s.is_empty() { None } else { Some(s.to_string()) })
        }
        Some(Value::Number(n)) => Ok(Some(n.to_string())),
        Some(_) => Err("review 'target' must be a string (PR/MR number or URL)".into()),
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

/// Send one command to the owning app instance, addressed by worktree
/// directory (never session id — the MCP server has no terminal session).
pub fn dispatch(env: &McpEnv, command: &Command) -> Result<Response, TransportError> {
    let req = alas_client::build_request(command, None, Some(env.worktree_dir.clone()));
    alas_client::send(&env.socket, &req)
}

/// Unknown tools and invalid arguments are JSON-RPC protocol errors
/// (-32602); failures while executing a valid call are tool results with
/// isError:true, per the MCP spec's split between the two.
fn call_tool(
    params: &Value,
    worktree_dir: &str,
    mut dispatch: impl FnMut(&Command) -> Result<Response, TransportError>,
) -> Result<Value, (i64, String)> {
    let name = params
        .get("name")
        .and_then(Value::as_str)
        .ok_or((-32602, "tools/call requires a tool name".to_string()))?;
    let args = params.get("arguments").cloned().unwrap_or_else(|| json!({}));
    let command = command_for_tool(name, &args, worktree_dir).map_err(|msg| (-32602, msg))?;
    Ok(match dispatch(&command) {
        Ok(resp) => tool_result(&command, resp),
        Err(err) => transport_error_result(&err),
    })
}

fn tool_result(command: &Command, resp: Response) -> Value {
    if !resp.ok {
        return text_result(resp.error.unwrap_or_else(|| "request failed".into()), true);
    }
    match resp.lines.filter(|lines| !lines.is_empty()) {
        Some(lines) => text_result(lines.join("\n"), false),
        None => text_result(success_message(command), false),
    }
}

/// The app replies to UI-action commands with a bare ok; agents read better
/// with an explicit confirmation than with empty content.
fn success_message(command: &Command) -> String {
    match command {
        Command::Open { paths } => format!("Opened {} file(s) in Alas.", paths.len()),
        Command::WtSwitch { target } => format!("Switched Alas to worktree '{target}'."),
        Command::WtNew { branch, .. } => format!("Created worktree for branch '{branch}' in Alas."),
        Command::WtDelete { target, .. } => format!("Deleted worktree '{target}'."),
        Command::Review { target: Some(target) } => format!("Opened review for '{target}' in Alas."),
        Command::Review { target: None } => "Opened review of local changes in Alas.".into(),
        Command::ReviewComments { .. } => "No review comments found.".into(),
        Command::ReviewReply { .. } => "Reply posted.".into(),
        Command::ReviewResolve { reopen: false, .. } => "Comment resolved.".into(),
        Command::ReviewResolve { reopen: true, .. } => "Comment reopened.".into(),
        Command::WtList | Command::Resolve => "OK".into(),
    }
}

fn transport_error_result(err: &TransportError) -> Value {
    // Mirrors describe() in main.rs so agents and humans read the same words.
    let message = match err {
        TransportError::Malformed => "malformed response from Alas",
        TransportError::Connect | TransportError::Io => "could not reach Alas",
    };
    text_result(message.into(), true)
}

fn text_result(text: String, is_error: bool) -> Value {
    json!({ "content": [{ "type": "text", "text": text }], "isError": is_error })
}

/// Blocking stdio server loop: one JSON-RPC message per line in, one per
/// line out. EOF on stdin means the agent hung up — exit cleanly.
pub fn serve(env: &McpEnv) -> std::io::Result<()> {
    use std::io::{BufRead, Write};

    let stdin = std::io::stdin();
    let stdout = std::io::stdout();
    for line in stdin.lock().lines() {
        let line = line?;
        if line.trim().is_empty() {
            continue;
        }
        if let Some(reply) = handle_line(&line, &env.worktree_dir, |cmd| dispatch(env, cmd)) {
            let mut out = stdout.lock();
            out.write_all(reply.to_string().as_bytes())?;
            out.write_all(b"\n")?;
            out.flush()?;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{command_for_tool, dispatch, env_from, handle_line, McpEnv, PROTOCOL_VERSION};
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
    fn non_object_json_line_is_invalid_request() {
        for line in [r#""hello""#, "42", "[1,2]", "true", "null"] {
            let reply = handle_line(line, "/wt", ok_dispatch).unwrap();
            assert_eq!(reply["error"]["code"], json!(-32600), "line: {line}");
            assert_eq!(reply["id"], Value::Null);
        }
    }

    #[test]
    fn tools_list_returns_all_tools() {
        let line = r#"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#;
        let reply = handle_line(line, "/wt", ok_dispatch).unwrap();
        let tools = reply["result"]["tools"].as_array().unwrap();
        let names: Vec<&str> = tools.iter().map(|t| t["name"].as_str().unwrap()).collect();
        assert_eq!(
            names,
            [
                "open",
                "worktree_list",
                "worktree_switch",
                "worktree_new",
                "worktree_delete",
                "review",
                "review_comments",
                "review_reply",
                "review_resolve"
            ]
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
    fn review_coerces_numeric_target_and_rejects_other_types() {
        assert_eq!(
            command_for_tool("review", &json!({"target": 123}), "/wt").unwrap(),
            alas_client::Command::Review { target: Some("123".into()) }
        );
        assert_eq!(
            command_for_tool("review", &json!({"target": null}), "/wt").unwrap(),
            alas_client::Command::Review { target: None }
        );
        assert!(command_for_tool("review", &json!({"target": true}), "/wt").is_err());
        assert!(command_for_tool("review", &json!({"target": ["1"]}), "/wt").is_err());
    }

    #[test]
    fn review_comments_tool_maps_and_validates_state() {
        assert_eq!(
            command_for_tool("review_comments", &json!({}), "/wt").unwrap(),
            alas_client::Command::ReviewComments { session_id: None, state: None }
        );
        assert_eq!(
            command_for_tool("review_comments", &json!({"session_id": "sid", "state": "resolved"}), "/wt").unwrap(),
            alas_client::Command::ReviewComments { session_id: Some("sid".into()), state: Some("resolved".into()) }
        );
        assert!(command_for_tool("review_comments", &json!({"state": "bogus"}), "/wt").is_err());
    }

    #[test]
    fn review_reply_and_resolve_tools_map_to_commands() {
        assert_eq!(
            command_for_tool("review_reply", &json!({"comment_id": "c1", "body": "hi"}), "/wt").unwrap(),
            alas_client::Command::ReviewReply { comment_id: "c1".into(), body: "hi".into() }
        );
        assert!(command_for_tool("review_reply", &json!({"comment_id": "c1"}), "/wt").is_err());

        assert_eq!(
            command_for_tool("review_resolve", &json!({"comment_id": "c1"}), "/wt").unwrap(),
            alas_client::Command::ReviewResolve { comment_id: "c1".into(), reply: None, reopen: false }
        );
        assert_eq!(
            command_for_tool("review_resolve", &json!({"comment_id": "c1", "reply": "done", "state": "active"}), "/wt").unwrap(),
            alas_client::Command::ReviewResolve { comment_id: "c1".into(), reply: Some("done".into()), reopen: true }
        );
        assert!(command_for_tool("review_resolve", &json!({"comment_id": "c1", "state": "bogus"}), "/wt").is_err());
    }

    #[test]
    fn unknown_tool_is_an_error() {
        assert!(command_for_tool("resolve", &json!({}), "/wt").is_err());
        assert!(command_for_tool("nope", &json!({}), "/wt").is_err());
    }

    fn call(name: &str, arguments: Value) -> String {
        json!({
            "jsonrpc": "2.0", "id": 7, "method": "tools/call",
            "params": { "name": name, "arguments": arguments }
        })
        .to_string()
    }

    #[test]
    fn tools_call_returns_joined_lines_on_success() {
        let reply = handle_line(&call("worktree_list", json!({})), "/wt", |_| {
            Ok(Response { ok: true, lines: Some(vec!["main *".into(), "feat".into()]), error: None })
        })
        .unwrap();
        let result = &reply["result"];
        assert_eq!(result["isError"], json!(false));
        assert_eq!(result["content"][0]["type"], json!("text"));
        assert_eq!(result["content"][0]["text"], json!("main *\nfeat"));
    }

    #[test]
    fn tools_call_synthesizes_confirmation_when_no_lines() {
        let reply = handle_line(&call("open", json!({"paths": ["a.txt", "b.txt"]})), "/wt", |cmd| {
            assert_eq!(
                cmd,
                &alas_client::Command::Open { paths: vec!["/wt/a.txt".into(), "/wt/b.txt".into()] }
            );
            Ok(Response { ok: true, lines: None, error: None })
        })
        .unwrap();
        assert_eq!(reply["result"]["isError"], json!(false));
        assert_eq!(reply["result"]["content"][0]["text"], json!("Opened 2 file(s) in Alas."));
    }

    #[test]
    fn tools_call_maps_app_failure_to_error_result() {
        let reply = handle_line(&call("review", json!({})), "/wt", |_| {
            Ok(Response { ok: false, lines: None, error: Some("no changes to review".into()) })
        })
        .unwrap();
        assert_eq!(reply["result"]["isError"], json!(true));
        assert_eq!(reply["result"]["content"][0]["text"], json!("no changes to review"));
    }

    #[test]
    fn tools_call_maps_transport_failure_to_error_result() {
        let reply = handle_line(&call("worktree_list", json!({})), "/wt", |_| {
            Err(alas_client::TransportError::Connect)
        })
        .unwrap();
        assert_eq!(reply["result"]["isError"], json!(true));
        assert_eq!(reply["result"]["content"][0]["text"], json!("could not reach Alas"));

        let reply = handle_line(&call("worktree_list", json!({})), "/wt", |_| {
            Err(alas_client::TransportError::Malformed)
        })
        .unwrap();
        assert_eq!(reply["result"]["content"][0]["text"], json!("malformed response from Alas"));
        assert_eq!(reply["result"]["isError"], json!(true));
    }

    #[test]
    fn empty_lines_vec_falls_back_to_confirmation_text() {
        let reply = handle_line(&call("worktree_list", json!({})), "/wt", |_| {
            Ok(Response { ok: true, lines: Some(vec![]), error: None })
        })
        .unwrap();
        assert_eq!(reply["result"]["isError"], json!(false));
        assert_eq!(reply["result"]["content"][0]["text"], json!("OK"));
    }

    #[test]
    fn tools_call_with_unknown_tool_or_bad_args_is_invalid_params() {
        let reply = handle_line(&call("nope", json!({})), "/wt", ok_dispatch).unwrap();
        assert_eq!(reply["error"]["code"], json!(-32602));

        let reply = handle_line(&call("open", json!({})), "/wt", ok_dispatch).unwrap();
        assert_eq!(reply["error"]["code"], json!(-32602));
    }

    #[test]
    fn dispatch_sends_cwd_addressed_request_over_the_socket() {
        use std::io::{Read, Write};

        let dir = std::env::temp_dir().join(format!("alas-mcp-it-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("stub.sock");
        let listener = std::os::unix::net::UnixListener::bind(&path).unwrap();
        let (tx, rx) = std::sync::mpsc::channel::<String>();
        let handle = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut buf = [0u8; 65536];
            let n = stream.read(&mut buf).unwrap();
            tx.send(String::from_utf8_lossy(&buf[..n]).into_owned()).unwrap();
            stream
                .write_all(br#"{"ok":true,"lines":["main *"]}"#)
                .unwrap();
        });

        let env = McpEnv { socket: path.clone(), worktree_dir: "/wt".into() };
        let resp = dispatch(&env, &alas_client::Command::WtList).unwrap();
        assert!(resp.ok);
        assert_eq!(resp.lines, Some(vec!["main *".into()]));

        let seen: Value = serde_json::from_str(&rx.recv().unwrap()).unwrap();
        assert_eq!(seen["kind"], json!("cli"));
        assert_eq!(seen["v"], json!(1));
        assert_eq!(seen["command"], json!("wt"));
        assert_eq!(seen["subcommand"], json!("list"));
        assert_eq!(seen["cwd"], json!("/wt"));
        assert!(seen.get("session_id").is_none());

        let _ = handle.join();
        let _ = std::fs::remove_dir_all(&dir);
    }
}
