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
    pub session_id: String,
    pub parent_session_id: Option<String>,
    pub workspace_only: bool,
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
    let session_id = get("ALAS_SESSION_ID")
        .filter(|s| !s.is_empty())
        .ok_or("alas mcp requires ALAS_SESSION_ID (it is launched by Alas, not by hand)")?;
    Ok(McpEnv {
        socket: PathBuf::from(socket),
        worktree_dir,
        session_id,
        parent_session_id: get("ALAS_PARENT_SESSION_ID").filter(|s| !s.is_empty()),
        workspace_only: get("ALAS_MCP_WORKSPACE_ONLY")
            .map(|value| value == "1" || value.eq_ignore_ascii_case("true"))
            .unwrap_or(false),
    })
}

/// Handle one raw input line. Returns the JSON-RPC reply to write, or None
/// when no reply must be produced (notifications — replying to one is a
/// protocol violation).
pub fn handle_line(
    line: &str,
    worktree_dir: &str,
    dispatch: impl FnMut(&Command) -> Result<Response, TransportError>,
) -> Option<Value> {
    handle_line_with_parent(line, worktree_dir, None, false, dispatch)
}

fn handle_line_with_parent(
    line: &str,
    worktree_dir: &str,
    parent_session_id: Option<&str>,
    workspace_only: bool,
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
    let method = msg
        .get("method")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let reply = match method {
        "initialize" => Ok(initialize_result(parent_session_id)),
        "ping" => Ok(json!({})),
        "tools/list" => Ok(json!({ "tools": tool_definitions_for_mode(workspace_only) })),
        "tools/call" => {
            let params = msg.get("params").cloned().unwrap_or(Value::Null);
            call_tool(&params, worktree_dir, workspace_only, &mut dispatch)
        }
        other => Err((-32601, format!("method not found: {other}"))),
    };
    Some(match reply {
        Ok(result) => json!({ "jsonrpc": "2.0", "id": id, "result": result }),
        Err((code, message)) => error_reply(id, code, &message),
    })
}

fn initialize_result(parent_session_id: Option<&str>) -> Value {
    let instructions = match parent_session_id {
        Some(_) => "Tools that drive the user's Alas workspace UI. This session was delegated by a parent session: it cannot create descendants; return results or questions through session_send.",
        None => "Tools that drive the user's Alas workspace UI: open files for the user to look at, manage linked worktrees, and open reviews. Root ACP sessions may delegate direct child sessions.",
    };
    json!({
        "protocolVersion": PROTOCOL_VERSION,
        "capabilities": { "tools": {} },
        "serverInfo": { "name": "alas", "version": env!("CARGO_PKG_VERSION") },
        "instructions": instructions
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
    tool_definitions_for_mode(false)
}

fn tool_definitions_for_mode(workspace_only: bool) -> Vec<Value> {
    if workspace_only {
        return all_tool_definitions()
            .into_iter()
            .filter(|tool| {
                tool.get("name")
                    .and_then(Value::as_str)
                    .is_some_and(|name| name.starts_with("workspace_"))
            })
            .collect();
    }
    all_tool_definitions()
}

fn all_tool_definitions() -> Vec<Value> {
    vec![
        json!({
            "name": "open",
            "description": "Open one or more files in Alas. Use path with line/end_line to reveal source; use paths for multiple files.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "path": { "type": "string", "description": "One file to open, relative to the worktree root or absolute." },
                    "paths": {
                        "type": "array",
                        "items": { "type": "string" },
                        "minItems": 1,
                        "description": "Files to open in Alas."
                    },
                    "line": { "type": "integer", "minimum": 1, "description": "First line to reveal (1-based)." },
                    "end_line": { "type": "integer", "minimum": 1, "description": "Last line to reveal (1-based). Requires line." }
                }
            }
        }),
        json!({
            "name": "notify",
            "description": "Post a macOS notification through Alas and optionally flag this session's sidebar row for attention.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "body": { "type": "string", "description": "Notification body." },
                    "title": { "type": "string", "description": "Optional notification title." },
                    "level": {
                        "type": "string",
                        "enum": ["info", "attention"],
                        "description": "Default: attention. Attention also marks the session row as needing input."
                    }
                },
                "required": ["body"]
            }
        }),
        json!({
            "name": "session_list",
            "description": "List this ACP session and its direct parent or children only. Returns structured state summaries without transcript content.",
            "inputSchema": { "type": "object", "properties": {} }
        }),
        json!({
            "name": "session_new",
            "description": "Asynchronously ask Alas to create a direct child ACP session. The child may use the current worktree, an existing project worktree, or a new linked worktree. The prompt is text-only and Alas does not automatically focus the child.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "prompt": { "type": "string", "description": "Initial text-only task for the child session." },
                    "agent": { "type": "string", "description": "Optional enabled ACP-capable agent id. Defaults to this session's agent." },
                    "worktree": { "type": "string", "description": "Existing project worktree name or branch. Mutually exclusive with new_worktree." },
                    "new_worktree": {
                        "type": "object",
                        "description": "New linked worktree selector. Mutually exclusive with worktree.",
                        "properties": {
                            "branch": { "type": "string", "description": "Branch for the new linked worktree." },
                            "base": { "type": "string", "description": "Optional base ref." }
                        },
                        "required": ["branch"]
                    }
                },
                "required": ["prompt"]
            }
        }),
        json!({
            "name": "session_send",
            "description": "Queue a text-only prompt for this session's direct parent or child. Delivery is asynchronous and does not automatically focus either session.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "session_id": { "type": "string", "description": "Direct parent or child session id." },
                    "prompt": { "type": "string", "description": "Text-only prompt to queue." }
                },
                "required": ["session_id", "prompt"]
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
            "description": "Open Alas's review pane for the user: on the current local changes when target is omitted, or on the given target — a provider pull/merge request (number or URL), a commit SHA or revision, a commit range (base..head, or base...head for a merge-base diff), or a local branch (reviewed against the repository's base branch). Returns the review session id for use with review_comment_add.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "target": { "type": "string", "description": "PR/MR number or URL, commit SHA/revision, commit range (base..head or base...head), or branch name. Omit to review local changes." },
                    "worktree": { "type": "string", "description": "Worktree to review in: name, branch, or absolute path. Defaults to the current worktree." }
                }
            }
        }),
        json!({
            "name": "review_comments",
            "description": "List review comments from the user's Alas review pane for this worktree, as a JSON array. Each comment has an id, path, anchor_kind (line/file/image), side, state (active/resolved/dismissed), author, body, and replies. Line anchors include start_line and optional end_line. Image anchors include x_percent and y_percent. Defaults to active comments only.",
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
        json!({
            "name": "review_comment_add",
            "description": "File a review comment into the user's Alas review pane, attributed to the agent. The user sees it inline in the diff. Use after the review tool to leave findings on specific lines.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "path": { "type": "string", "description": "File path relative to the worktree root." },
                    "start_line": { "type": "integer", "minimum": 1, "description": "First line the comment refers to." },
                    "end_line": { "type": "integer", "minimum": 1, "description": "Last line of the range, when commenting on a range." },
                    "side": { "type": "string", "enum": ["old", "new"], "description": "Which side of the diff the lines refer to. Default: new." },
                    "body": { "type": "string", "description": "Comment body, Markdown." },
                    "session_id": { "type": "string", "description": "Review session to file into (returned by the review tool). Omit for the worktree's local-changes review." }
                },
                "required": ["path", "start_line", "body"]
            }
        }),
        json!({
            "name": "review_finish",
            "description": "Finish an Alas review session with its capstone verdict and optional summary after filing findings. Requesting changes requires a summary.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "session_id": { "type": "string", "description": "Review session to finish, returned by the review tool. Defaults to the current worktree's local-changes review." },
                    "verdict": { "type": "string", "enum": ["approve", "request_changes", "comment"], "description": "Review verdict. Default: comment." },
                    "summary": { "type": "string", "description": "Optional review summary. Required when verdict is request_changes." }
                }
            }
        }),
        json!({
            "name": "workspace_list",
            "description": "List Workspace Checkouts visible in Alas as versioned JSON. This observes Workspace state only and never mutates checkout lifecycle.",
            "inputSchema": { "type": "object", "properties": {} }
        }),
        json!({
            "name": "workspace_show",
            "description": "Show one Workspace Checkout by UUID as versioned JSON, including independent operation, health, member availability, and diagnostics.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "checkout_id": { "type": "string", "description": "Workspace Checkout UUID." }
                },
                "required": ["checkout_id"]
            }
        }),
        json!({
            "name": "workspace_switch",
            "description": "Select one Workspace Checkout in Alas by UUID. This changes UI focus only; it does not create, repair, archive, or delete checkouts.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "checkout_id": { "type": "string", "description": "Workspace Checkout UUID." }
                },
                "required": ["checkout_id"]
            }
        }),
        json!({
            "name": "workspace_focus",
            "description": "Focus a specific member inside a Workspace Checkout. The member UUID is required so repository-specific operations never use Repository Focus implicitly.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "checkout_id": { "type": "string", "description": "Workspace Checkout UUID." },
                    "member_id": { "type": "string", "description": "Workspace Checkout member UUID." }
                },
                "required": ["checkout_id", "member_id"]
            }
        }),
    ]
}

fn is_workspace_tool(name: &str) -> bool {
    name.starts_with("workspace_")
}

/// Translate a tool call into the CLI command it mirrors. Relative `open`
/// paths absolutize against the injected worktree dir — never the process
/// cwd, which the agent controls.
pub fn command_for_tool(name: &str, args: &Value, worktree_dir: &str) -> Result<Command, String> {
    match name {
        "open" => {
            let singular = match args.get("path") {
                None => None,
                Some(Value::String(path)) if !path.trim().is_empty() => Some(path.as_str()),
                Some(Value::String(_)) => return Err("open path must be non-empty".into()),
                Some(_) => return Err("open path must be a string".into()),
            };
            if singular.is_some() && args.get("paths").is_some() {
                return Err("open accepts either 'path' or 'paths', not both".into());
            }
            let base = std::path::Path::new(worktree_dir);
            let resolved = if let Some(path) = singular {
                vec![alas_client::absolutize(base, path)]
            } else {
                let paths = args
                    .get("paths")
                    .and_then(Value::as_array)
                    .ok_or("open requires 'path' or a 'paths' array")?;
                if paths.is_empty() {
                    return Err("open requires at least one path".into());
                }
                paths
                    .iter()
                    .map(|path| {
                        let path = path.as_str().ok_or("open paths must be strings")?;
                        if path.trim().is_empty() {
                            return Err("open paths must be non-empty".into());
                        }
                        Ok(alas_client::absolutize(base, path))
                    })
                    .collect::<Result<Vec<_>, String>>()?
            };
            let line = args.get("line").and_then(Value::as_u64);
            let end_line = args.get("end_line").and_then(Value::as_u64);
            if args.get("line").is_some_and(|_| line.is_none())
                || args.get("end_line").is_some_and(|_| end_line.is_none())
                || line == Some(0)
                || end_line == Some(0)
            {
                return Err("open line targets must be positive integers".into());
            }
            if let Some(line) = line {
                if resolved.len() != 1 {
                    return Err("open line targets require exactly one path".into());
                }
                if end_line.is_some_and(|end| end < line) {
                    return Err("open 'end_line' must be greater than or equal to 'line'".into());
                }
                return Ok(Command::OpenAt {
                    path: resolved.into_iter().next().ok_or("open requires a path")?,
                    line,
                    end_line,
                });
            }
            if end_line.is_some() {
                return Err("open 'end_line' requires 'line'".into());
            }
            Ok(Command::Open { paths: resolved })
        }
        "notify" => {
            let level = optional_string(args, "level");
            if let Some(level) = &level {
                if level != "info" && level != "attention" {
                    return Err("notify 'level' must be 'info' or 'attention'".into());
                }
            }
            Ok(Command::Notify {
                body: required_string(args, "body")?,
                title: optional_string(args, "title"),
                level,
            })
        }
        "session_list" => Ok(Command::SessionList),
        "session_new" => {
            let worktree = optional_non_blank_string(args, "worktree")?;
            let agent = optional_non_blank_string(args, "agent")?;
            let new_worktree = match args.get("new_worktree") {
                None => None,
                Some(Value::Object(new_worktree)) => {
                    let branch = required_object_string(new_worktree, "branch", "new_worktree")?;
                    let base = optional_object_string(new_worktree, "base", "new_worktree")?;
                    Some((branch, base))
                }
                Some(_) => return Err("session_new 'new_worktree' must be an object".into()),
            };
            if worktree.is_some() && new_worktree.is_some() {
                return Err(
                    "session_new accepts either 'worktree' or 'new_worktree', not both".into(),
                );
            }
            let worktree = match (worktree, new_worktree) {
                (Some(worktree), None) => alas_client::SessionWorktreeTarget::Existing { worktree },
                (None, Some((branch, base))) => {
                    alas_client::SessionWorktreeTarget::New { branch, base }
                }
                (None, None) => alas_client::SessionWorktreeTarget::Current,
                (Some(_), Some(_)) => unreachable!("mutual exclusion checked above"),
            };
            Ok(Command::SessionNew {
                prompt: required_string(args, "prompt")?,
                agent,
                worktree,
            })
        }
        "session_send" => Ok(Command::SessionSend {
            session_id: required_string(args, "session_id")?,
            prompt: required_string(args, "prompt")?,
        }),
        "worktree_list" => Ok(Command::WtList),
        "worktree_switch" => Ok(Command::WtSwitch {
            target: required_string(args, "target")?,
        }),
        "worktree_new" => Ok(Command::WtNew {
            branch: required_string(args, "branch")?,
            base: optional_string(args, "base"),
        }),
        "worktree_delete" => Ok(Command::WtDelete {
            target: required_string(args, "target")?,
            force: args.get("force").and_then(Value::as_bool).unwrap_or(false),
            keep_branch: args
                .get("keep_branch")
                .and_then(Value::as_bool)
                .unwrap_or(false),
        }),
        "review" => Ok(Command::Review {
            target: review_target(args)?,
            worktree: optional_non_blank_string(args, "worktree")?,
        }),
        "review_comments" => {
            let state = optional_string(args, "state");
            if let Some(state) = &state {
                if !["active", "resolved", "dismissed", "all"].contains(&state.as_str()) {
                    return Err(
                        "review_comments 'state' must be one of active|resolved|dismissed|all"
                            .into(),
                    );
                }
            }
            Ok(Command::ReviewComments {
                session_id: optional_string(args, "session_id"),
                state,
            })
        }
        "review_reply" => Ok(Command::ReviewReply {
            comment_id: required_string(args, "comment_id")?,
            body: required_string(args, "body")?,
        }),
        "review_resolve" => {
            let reopen = match optional_string(args, "state").as_deref() {
                None | Some("resolved") => false,
                Some("active") => true,
                Some(_) => {
                    return Err("review_resolve 'state' must be 'resolved' or 'active'".into());
                }
            };
            Ok(Command::ReviewResolve {
                comment_id: required_string(args, "comment_id")?,
                reply: optional_string(args, "reply"),
                reopen,
            })
        }
        "review_comment_add" => {
            let start_line = args
                .get("start_line")
                .and_then(Value::as_u64)
                .filter(|line| *line >= 1)
                .ok_or("review_comment_add requires an integer 'start_line' >= 1")?;
            let end_line = match args.get("end_line") {
                None | Some(Value::Null) => None,
                Some(value) => Some(
                    value
                        .as_u64()
                        .filter(|line| *line >= start_line)
                        .ok_or("review_comment_add 'end_line' must be an integer >= start_line")?,
                ),
            };
            let side = optional_string(args, "side");
            if let Some(side) = &side {
                if side != "old" && side != "new" {
                    return Err("review_comment_add 'side' must be 'old' or 'new'".into());
                }
            }
            Ok(Command::ReviewCommentAdd {
                path: required_string(args, "path")?,
                start_line,
                end_line,
                side,
                body: required_string(args, "body")?,
                session_id: optional_string(args, "session_id"),
            })
        }
        "review_finish" => {
            let verdict = optional_string(args, "verdict");
            if let Some(verdict) = &verdict {
                if !["approve", "request_changes", "comment"].contains(&verdict.as_str()) {
                    return Err(
                        "review_finish 'verdict' must be approve, request_changes, or comment"
                            .into(),
                    );
                }
            }
            Ok(Command::ReviewFinish {
                session_id: optional_string(args, "session_id"),
                verdict,
                summary: optional_string(args, "summary"),
            })
        }
        "workspace_list" => Ok(Command::WorkspaceList),
        "workspace_show" => Ok(Command::WorkspaceShow {
            checkout_id: required_uuid(args, "checkout_id")?,
        }),
        "workspace_switch" => Ok(Command::WorkspaceSwitch {
            checkout_id: required_uuid(args, "checkout_id")?,
        }),
        "workspace_focus" => Ok(Command::WorkspaceFocus {
            checkout_id: required_uuid(args, "checkout_id")?,
            member_id: required_uuid(args, "member_id")?,
        }),
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
            Ok(if s.is_empty() {
                None
            } else {
                Some(s.to_string())
            })
        }
        Some(Value::Number(n)) => Ok(Some(n.to_string())),
        Some(_) => Err("review 'target' must be a string (PR/MR number or URL)".into()),
    }
}

fn required_string(args: &Value, key: &str) -> Result<String, String> {
    optional_string(args, key).ok_or_else(|| format!("missing required argument '{key}'"))
}

fn required_uuid(args: &Value, key: &str) -> Result<String, String> {
    let value = required_string(args, key)?;
    if is_uuid(&value) {
        Ok(value)
    } else {
        Err(format!("{key} must be a UUID"))
    }
}

fn is_uuid(value: &str) -> bool {
    let bytes = value.as_bytes();
    let hyphens = [8, 13, 18, 23];
    bytes.len() == 36
        && bytes.iter().enumerate().all(|(index, byte)| {
            if hyphens.contains(&index) {
                *byte == b'-'
            } else {
                byte.is_ascii_hexdigit()
            }
        })
}

fn optional_string(args: &Value, key: &str) -> Option<String> {
    args.get(key)
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(String::from)
}

fn optional_non_blank_string(args: &Value, key: &str) -> Result<Option<String>, String> {
    match args.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(value)) if !value.trim().is_empty() => {
            Ok(Some(value.trim().to_string()))
        }
        Some(Value::String(_)) => Err(format!("{key} must be non-empty")),
        Some(_) => Err(format!("{key} must be a string")),
    }
}

fn required_object_string(
    object: &serde_json::Map<String, Value>,
    key: &str,
    object_name: &str,
) -> Result<String, String> {
    match object.get(key) {
        Some(Value::String(value)) if !value.trim().is_empty() => Ok(value.trim().to_string()),
        Some(Value::String(_)) => Err(format!(
            "session_new '{object_name}.{key}' must be non-empty"
        )),
        Some(_) => Err(format!(
            "session_new '{object_name}.{key}' must be a string"
        )),
        None => Err(format!("session_new requires '{object_name}.{key}'")),
    }
}

fn optional_object_string(
    object: &serde_json::Map<String, Value>,
    key: &str,
    object_name: &str,
) -> Result<Option<String>, String> {
    match object.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(value)) if !value.trim().is_empty() => {
            Ok(Some(value.trim().to_string()))
        }
        Some(Value::String(_)) => Err(format!(
            "session_new '{object_name}.{key}' must be non-empty"
        )),
        Some(_) => Err(format!(
            "session_new '{object_name}.{key}' must be a string"
        )),
    }
}

/// Send one command to the owning app instance, addressed by worktree
/// directory (never session id — the MCP server has no terminal session).
pub fn dispatch(env: &McpEnv, command: &Command) -> Result<Response, TransportError> {
    let req = alas_client::build_request(
        command,
        Some(env.session_id.clone()),
        Some(env.worktree_dir.clone()),
    );
    alas_client::send(&env.socket, &req)
}

/// Unknown tools and invalid arguments are JSON-RPC protocol errors
/// (-32602); failures while executing a valid call are tool results with
/// isError:true, per the MCP spec's split between the two.
fn call_tool(
    params: &Value,
    worktree_dir: &str,
    workspace_only: bool,
    mut dispatch: impl FnMut(&Command) -> Result<Response, TransportError>,
) -> Result<Value, (i64, String)> {
    let name = params
        .get("name")
        .and_then(Value::as_str)
        .ok_or((-32602, "tools/call requires a tool name".to_string()))?;
    let args = params
        .get("arguments")
        .cloned()
        .unwrap_or_else(|| json!({}));
    if workspace_only && !is_workspace_tool(name) {
        return Err((
            -32602,
            format!("tool unavailable in Workspace Checkout context: {name}"),
        ));
    }
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
        Command::OpenAt { .. } => "Opened file at the requested lines in Alas.".into(),
        Command::Notify { .. } => "Notification sent.".into(),
        Command::WtSwitch { target } => format!("Switched Alas to worktree '{target}'."),
        Command::WtNew { branch, .. } => format!("Created worktree for branch '{branch}' in Alas."),
        Command::WtDelete { target, .. } => format!("Deleted worktree '{target}'."),
        Command::Review {
            target: Some(target),
            ..
        } => format!("Opened review for '{target}' in Alas."),
        Command::Review { target: None, .. } => "Opened review of local changes in Alas.".into(),
        Command::ReviewComments { .. } => "No review comments found.".into(),
        Command::ReviewReply { .. } => "Reply posted.".into(),
        Command::ReviewResolve { reopen: false, .. } => "Comment resolved.".into(),
        Command::ReviewResolve { reopen: true, .. } => "Comment reopened.".into(),
        Command::ReviewCommentAdd { path, .. } => format!("Filed review comment on {path}."),
        Command::ReviewFinish { .. } => "Review finished.".into(),
        Command::SessionList => "No delegated sessions found.".into(),
        Command::SessionNew { .. } => "Delegated session creation accepted.".into(),
        Command::SessionSend { .. } => "Delegated prompt queued.".into(),
        Command::WorkspaceList => "No Workspace Checkouts found.".into(),
        Command::WorkspaceShow { .. } => "Workspace Checkout shown.".into(),
        Command::WorkspaceSwitch { .. } => "Switched Alas to Workspace Checkout.".into(),
        Command::WorkspaceFocus { .. } => "Focused Workspace Checkout member.".into(),
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

    // Announce startup so the app can tell an injected-but-spawned server from
    // one the harness silently dropped. Best-effort; never blocks serving.
    alas_client::send_hello(&env.socket, &env.session_id, "stdio");

    let stdin = std::io::stdin();
    let stdout = std::io::stdout();
    for line in stdin.lock().lines() {
        let line = line?;
        if line.trim().is_empty() {
            continue;
        }
        if let Some(reply) = handle_line_with_parent(
            &line,
            &env.worktree_dir,
            env.parent_session_id.as_deref(),
            env.workspace_only,
            |cmd| dispatch(env, cmd),
        ) {
            let mut out = stdout.lock();
            out.write_all(reply.to_string().as_bytes())?;
            out.write_all(b"\n")?;
            out.flush()?;
        }
    }
    Ok(())
}

/// A parsed HTTP/1.1 request. Only the fields the MCP transport needs are
/// kept; everything else in the request is ignored.
struct HttpRequest {
    method: String,
    path: String,
    bearer: Option<String>,
    body: String,
}

/// Parse an HTTP/1.1 request from raw bytes. Returns None when the request is
/// incomplete (headers not yet terminated, or fewer body bytes than
/// Content-Length) or malformed. Headers are matched case-insensitively; the
/// bearer token is taken from `Authorization: Bearer <token>`.
fn parse_http_request(bytes: &[u8]) -> Option<HttpRequest> {
    let split = bytes.windows(4).position(|w| w == b"\r\n\r\n")?;
    let head = std::str::from_utf8(&bytes[..split]).ok()?;
    let body_bytes = &bytes[split + 4..];

    let mut lines = head.split("\r\n");
    let mut request_line = lines.next()?.split_whitespace();
    let method = request_line.next()?.to_string();
    let path = request_line.next()?.to_string();
    // The HTTP version token must be present for a well-formed request line.
    request_line.next()?;

    let mut bearer = None;
    let mut content_length: usize = 0;
    for line in lines {
        let Some((name, value)) = line.split_once(':') else {
            continue;
        };
        let name = name.trim();
        let value = value.trim();
        if name.eq_ignore_ascii_case("authorization") {
            let scheme = "bearer ";
            // `value.get(..len)` returns None on a non-char boundary instead of
            // panicking, so a multibyte char in the first bytes of a malicious
            // pre-auth header can't crash the accept thread. When it's Some, the
            // offset is a valid boundary and the tail slice is safe.
            if let Some(prefix) = value.get(..scheme.len()) {
                if prefix.eq_ignore_ascii_case(scheme) {
                    bearer = Some(value[scheme.len()..].trim().to_string());
                }
            }
        } else if name.eq_ignore_ascii_case("content-length") {
            content_length = value.parse().ok()?;
        }
    }

    if body_bytes.len() < content_length {
        return None;
    }
    let body = String::from_utf8_lossy(&body_bytes[..content_length]).into_owned();
    Some(HttpRequest {
        method,
        path,
        bearer,
        body,
    })
}

/// Build a minimal HTTP/1.1 response. Content-Length is the body's byte
/// length; the connection is always closed after one response.
fn http_response(status: u16, content_type: &str, body: &str) -> String {
    let reason = match status {
        200 => "OK",
        202 => "Accepted",
        400 => "Bad Request",
        401 => "Unauthorized",
        404 => "Not Found",
        _ => "OK",
    };
    format!(
        "HTTP/1.1 {status} {reason}\r\nContent-Type: {content_type}\r\nContent-Length: {len}\r\nConnection: close\r\n\r\n{body}",
        len = body.len(),
    )
}

/// HTTP transport for the same MCP server as `serve`. Binds an ephemeral
/// localhost port, prints `PORT <n>` on stdout so the app can wire up
/// `http://localhost:<n>/mcp`, and requires a bearer token matching
/// `ALAS_MCP_HTTP_TOKEN` on every request. Single-threaded: alas tool calls
/// are quick and connections are served one at a time with `Connection: close`.
pub fn serve_http(env: &McpEnv) -> std::io::Result<()> {
    use std::io::Write;
    use std::net::TcpListener;

    let token = std::env::var("ALAS_MCP_HTTP_TOKEN").unwrap_or_default();

    // Bind IPv4 loopback first so the OS picks the port, then reuse that same
    // port for IPv6 loopback. We advertise `http://localhost:<port>` (the
    // enterprise allowlist matches the literal `http://localhost:*`, not
    // `127.0.0.1`), and `localhost` resolves to `::1` before `127.0.0.1` on
    // many modern clients (Node/undici, which the claude ACP adapter uses).
    // Serving both loopback families on the same port keeps the server
    // reachable regardless of resolution order — while staying loopback-only.
    let v4_listener = TcpListener::bind("127.0.0.1:0")?;
    let port = v4_listener.local_addr()?.port();

    // Best-effort: a missing or busy IPv6 loopback must not sink the server.
    let v6_listener = match TcpListener::bind(("::1", port)) {
        Ok(listener) => Some(listener),
        Err(err) => {
            eprintln!("alas: mcp http ipv6 bind failed on port {port}: {err}");
            None
        }
    };

    println!("PORT {port}");
    std::io::stdout().flush()?;

    fn serve_one(env: &McpEnv, listener: TcpListener, token: &str) {
        for stream in listener.incoming() {
            match stream {
                Ok(mut stream) => {
                    if let Err(err) = handle_http_connection(env, &mut stream, token) {
                        // A single bad connection must not take down the server.
                        eprintln!("alas: mcp http connection error: {err}");
                    }
                }
                Err(err) => eprintln!("alas: mcp http accept error: {err}"),
            }
        }
    }

    std::thread::scope(|scope| {
        scope.spawn(|| serve_one(env, v4_listener, &token));
        if let Some(v6) = v6_listener {
            scope.spawn(|| serve_one(env, v6, &token));
        }
    });
    Ok(())
}

fn handle_http_connection(
    env: &McpEnv,
    stream: &mut std::net::TcpStream,
    token: &str,
) -> std::io::Result<()> {
    use std::io::{ErrorKind, Read, Write};
    use std::time::Duration;

    // The accept loop is single-threaded, so a client that connects and never
    // sends a complete request must not wedge every other session. Bound the
    // (pre-auth) read with a timeout; on timeout we answer 400 and move on.
    let _ = stream.set_read_timeout(Some(Duration::from_secs(15)));

    const MAX_REQUEST_BYTES: usize = 1024 * 1024;
    let mut buf: Vec<u8> = Vec::new();
    let mut chunk = [0u8; 8192];
    let request = loop {
        if buf.len() > MAX_REQUEST_BYTES {
            break Err("bad request");
        }
        if let Some(req) = parse_http_request(&buf) {
            break Ok(Some(req));
        }
        let read = match stream.read(&mut chunk) {
            Ok(read) => read,
            Err(err)
                if err.kind() == ErrorKind::WouldBlock || err.kind() == ErrorKind::TimedOut =>
            {
                // Client stalled mid-request; drop it so the loop stays free.
                break Err("request timeout");
            }
            Err(err) => return Err(err),
        };
        if read == 0 {
            // Peer hung up: accept whatever completed, else treat as malformed.
            break Ok(parse_http_request(&buf));
        }
        buf.extend_from_slice(&chunk[..read]);
    };

    let response = match request {
        Ok(Some(req)) => build_http_response(env, &req, token),
        Ok(None) => http_response(400, "text/plain", "bad request"),
        Err(message) => http_response(400, "text/plain", message),
    };
    stream.write_all(response.as_bytes())?;
    stream.flush()?;
    Ok(())
}

/// True iff `body` parses as JSON whose `method` is `initialize`.
fn is_initialize_message(body: &str) -> bool {
    serde_json::from_str::<Value>(body)
        .ok()
        .and_then(|value| {
            value
                .get("method")
                .and_then(Value::as_str)
                .map(|method| method == "initialize")
        })
        .unwrap_or(false)
}

fn build_http_response(env: &McpEnv, req: &HttpRequest, token: &str) -> String {
    // No token configured, or a mismatch, is a flat 401 with no detail so the
    // response never distinguishes "no token here" from "wrong token".
    if token.is_empty() || req.bearer.as_deref() != Some(token) {
        return http_response(401, "text/plain", "");
    }
    if req.method != "POST" || !req.path.starts_with("/mcp") {
        return http_response(404, "text/plain", "not found");
    }

    // Re-announce on every authenticated `initialize`. The supervisor reuses the
    // process across ACP reattaches while the app clears its registration
    // registry per attach, so the hello must fire each time the harness
    // reconnects and re-sends `initialize`. `recordHello` is idempotent.
    if is_initialize_message(&req.body) {
        alas_client::send_hello(&env.socket, &env.session_id, "http");
    }

    match handle_line_with_parent(
        &req.body,
        &env.worktree_dir,
        env.parent_session_id.as_deref(),
        env.workspace_only,
        |cmd| dispatch(env, cmd),
    ) {
        Some(reply) => http_response(200, "application/json", &reply.to_string()),
        // Notifications (e.g. notifications/initialized) get no JSON-RPC reply.
        None => http_response(202, "application/json", ""),
    }
}

#[cfg(test)]
mod tests {
    use super::{
        command_for_tool, dispatch, env_from, handle_line, handle_line_with_parent, http_response,
        is_initialize_message, parse_http_request, McpEnv, PROTOCOL_VERSION,
    };
    use alas_client::{Command, Response};
    use serde_json::{json, Value};

    #[test]
    fn detects_initialize_messages() {
        assert!(is_initialize_message(
            r#"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#
        ));
        assert!(!is_initialize_message(
            r#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#
        ));
        assert!(!is_initialize_message("not json"));
    }

    #[test]
    fn parses_post_body_and_token() {
        let raw = "POST /mcp HTTP/1.1\r\nAuthorization: Bearer TOK\r\nContent-Length: 2\r\n\r\n{}";
        let req = parse_http_request(raw.as_bytes()).unwrap();
        assert_eq!(req.bearer.as_deref(), Some("TOK"));
        assert_eq!(req.body, "{}");
    }

    #[test]
    fn multibyte_authorization_does_not_panic() {
        // A multibyte char within the first bytes of the header value must not
        // cause a non-char-boundary slice panic; it simply isn't a bearer.
        let raw = "POST /mcp HTTP/1.1\r\nAuthorization: Béarer x\r\nContent-Length: 0\r\n\r\n";
        let req = parse_http_request(raw.as_bytes()).unwrap();
        assert_eq!(req.bearer, None);
    }

    #[test]
    fn builds_json_http_response() {
        let resp = http_response(200, "application/json", "{\"ok\":true}");
        assert!(resp.starts_with("HTTP/1.1 200"));
        assert!(resp.contains("Content-Length: 11"));
        assert!(resp.ends_with("{\"ok\":true}"));
    }

    fn ok_dispatch(_: &alas_client::Command) -> Result<Response, alas_client::TransportError> {
        Ok(Response {
            ok: true,
            lines: None,
            error: None,
            exit_code: None,
        })
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
        assert!(env_from(env(&[
            ("ALAS_WORKTREE_DIR", "/wt"),
            ("ALAS_SESSION_ID", "s1")
        ]))
        .is_err());
        assert!(env_from(env(&[
            ("ALAS_SOCKET_PATH", "/tmp/s"),
            ("ALAS_SESSION_ID", "s1")
        ]))
        .is_err());
        assert!(env_from(env(&[
            ("ALAS_SOCKET_PATH", "/tmp/s"),
            ("ALAS_WORKTREE_DIR", "/wt")
        ]))
        .is_err());
        assert!(env_from(env(&[
            ("ALAS_SOCKET_PATH", ""),
            ("ALAS_WORKTREE_DIR", "/wt"),
            ("ALAS_SESSION_ID", "s1")
        ]))
        .is_err());
        let ok = env_from(env(&[
            ("ALAS_SOCKET_PATH", "/tmp/s"),
            ("ALAS_WORKTREE_DIR", "/wt"),
            ("ALAS_SESSION_ID", "s1"),
        ]))
        .unwrap();
        assert_eq!(ok.socket, std::path::PathBuf::from("/tmp/s"));
        assert_eq!(ok.worktree_dir, "/wt");
        assert_eq!(ok.session_id, "s1");
        assert!(!ok.workspace_only);
        let workspace = env_from(env(&[
            ("ALAS_SOCKET_PATH", "/tmp/s"),
            ("ALAS_WORKTREE_DIR", "/wt"),
            ("ALAS_SESSION_ID", "s1"),
            ("ALAS_MCP_WORKSPACE_ONLY", "true"),
        ]))
        .unwrap();
        assert!(workspace.workspace_only);
    }

    #[test]
    fn env_from_rejects_relative_worktree_dir() {
        assert!(env_from(env(&[
            ("ALAS_SOCKET_PATH", "/tmp/s"),
            ("ALAS_WORKTREE_DIR", "wt"),
            ("ALAS_SESSION_ID", "s1")
        ]))
        .is_err());
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
    fn command_for_notify_tool_validates_and_maps_arguments() {
        let cmd = command_for_tool(
            "notify",
            &json!({ "body": "Blocked on input", "title": "Need input", "level": "attention" }),
            "/wt",
        )
        .unwrap();
        assert_eq!(
            cmd,
            alas_client::Command::Notify {
                body: "Blocked on input".into(),
                title: Some("Need input".into()),
                level: Some("attention".into()),
            }
        );

        assert!(command_for_tool(
            "notify",
            &json!({ "body": "Done", "level": "urgent" }),
            "/wt"
        )
        .is_err());
        assert!(command_for_tool("notify", &json!({ "title": "Missing body" }), "/wt").is_err());
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
                "notify",
                "session_list",
                "session_new",
                "session_send",
                "worktree_list",
                "worktree_switch",
                "worktree_new",
                "worktree_delete",
                "review",
                "review_comments",
                "review_reply",
                "review_resolve",
                "review_comment_add",
                "review_finish",
                "workspace_list",
                "workspace_show",
                "workspace_switch",
                "workspace_focus"
            ]
        );
        assert!(!names.contains(&"workspace_create"));
        assert!(!names.contains(&"workspace_delete"));
        for tool in tools {
            assert!(tool["description"].as_str().unwrap().len() > 20);
            assert_eq!(tool["inputSchema"]["type"], json!("object"));
        }
        let open_schema = &reply["result"]["tools"][0]["inputSchema"];
        assert!(open_schema.get("oneOf").is_none());
        assert!(open_schema.get("anyOf").is_none());
    }

    #[test]
    fn workspace_tools_map_to_read_only_workspace_commands() {
        let checkout = "7D064822-8491-4E33-BD74-355FD2AB3330";
        let member = "C2476427-94B2-423F-A490-568775E8B309";

        assert_eq!(
            command_for_tool("workspace_list", &json!({}), "/wt").unwrap(),
            Command::WorkspaceList
        );
        assert_eq!(
            command_for_tool("workspace_show", &json!({ "checkout_id": checkout }), "/wt").unwrap(),
            Command::WorkspaceShow {
                checkout_id: checkout.into()
            }
        );
        assert_eq!(
            command_for_tool(
                "workspace_switch",
                &json!({ "checkout_id": checkout }),
                "/wt"
            )
            .unwrap(),
            Command::WorkspaceSwitch {
                checkout_id: checkout.into()
            }
        );
        assert_eq!(
            command_for_tool(
                "workspace_focus",
                &json!({ "checkout_id": checkout, "member_id": member }),
                "/wt"
            )
            .unwrap(),
            Command::WorkspaceFocus {
                checkout_id: checkout.into(),
                member_id: member.into()
            }
        );
        assert!(command_for_tool(
            "workspace_focus",
            &json!({ "checkout_id": checkout }),
            "/wt"
        )
        .is_err());
    }

    #[test]
    fn workspace_only_mode_exposes_and_accepts_only_workspace_tools() {
        let list = handle_line_with_parent(
            r#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#,
            "/checkout",
            None,
            true,
            |_| unreachable!(),
        )
        .unwrap();
        let names: Vec<_> = list["result"]["tools"]
            .as_array()
            .unwrap()
            .iter()
            .map(|tool| tool["name"].as_str().unwrap())
            .collect();
        assert_eq!(
            names,
            vec![
                "workspace_list",
                "workspace_show",
                "workspace_switch",
                "workspace_focus"
            ]
        );

        let open = handle_line_with_parent(
            r#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"open","arguments":{"path":"README.md"}}}"#,
            "/checkout",
            None,
            true,
            |_| unreachable!(),
        )
        .unwrap();
        assert_eq!(open["error"]["code"], json!(-32602));

        let workspace = handle_line_with_parent(
            r#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"workspace_list","arguments":{}}}"#,
            "/checkout",
            None,
            true,
            |command| {
                assert_eq!(*command, Command::WorkspaceList);
                Ok(Response { ok: true, lines: Some(vec!["[]".into()]), error: None, exit_code: None })
            },
        )
        .unwrap();
        assert!(workspace.get("error").is_none());
    }

    #[test]
    fn open_maps_paths_and_absolutizes_relative_ones() {
        let cmd =
            command_for_tool("open", &json!({"paths": ["a.txt", "/abs/b.txt"]}), "/wt").unwrap();
        assert_eq!(
            cmd,
            alas_client::Command::Open {
                paths: vec!["/wt/a.txt".into(), "/abs/b.txt".into()]
            }
        );
    }

    #[test]
    fn session_tools_validate_and_map_arguments() {
        assert_eq!(
            command_for_tool("session_list", &json!({}), "/wt").unwrap(),
            alas_client::Command::SessionList
        );
        assert_eq!(
            command_for_tool(
                "session_new",
                &json!({
                    "prompt": "Task",
                    "agent": "codex",
                    "new_worktree": { "branch": "child", "base": "origin/main" }
                }),
                "/wt"
            )
            .unwrap(),
            alas_client::Command::SessionNew {
                prompt: "Task".into(),
                agent: Some("codex".into()),
                worktree: alas_client::SessionWorktreeTarget::New {
                    branch: "child".into(),
                    base: Some("origin/main".into())
                }
            }
        );
        assert_eq!(
            command_for_tool(
                "session_send",
                &json!({ "session_id": "child", "prompt": "Follow up" }),
                "/wt"
            )
            .unwrap(),
            alas_client::Command::SessionSend {
                session_id: "child".into(),
                prompt: "Follow up".into()
            }
        );
        assert!(command_for_tool(
            "session_new",
            &json!({ "prompt": "Task", "worktree": "main", "new_worktree": { "branch": "child" } }),
            "/wt"
        )
        .is_err());
        assert!(command_for_tool(
            "session_send",
            &json!({ "session_id": "child", "prompt": "  " }),
            "/wt"
        )
        .is_err());
    }

    #[test]
    fn open_maps_a_line_range_target() {
        let cmd = command_for_tool(
            "open",
            &json!({"path": "a.txt", "line": 12, "end_line": 15}),
            "/wt",
        )
        .unwrap();
        assert_eq!(
            cmd,
            alas_client::Command::OpenAt {
                path: "/wt/a.txt".into(),
                line: 12,
                end_line: Some(15),
            }
        );
    }

    #[test]
    fn open_rejects_missing_empty_or_non_string_paths() {
        assert!(command_for_tool("open", &json!({}), "/wt").is_err());
        assert!(command_for_tool("open", &json!({"path": null}), "/wt").is_err());
        assert!(command_for_tool("open", &json!({"path": 1}), "/wt").is_err());
        assert!(command_for_tool("open", &json!({"path": "  "}), "/wt").is_err());
        assert!(command_for_tool("open", &json!({"paths": []}), "/wt").is_err());
        assert!(command_for_tool("open", &json!({"paths": [1]}), "/wt").is_err());
        assert!(command_for_tool("open", &json!({"paths": ["  "]}), "/wt").is_err());
    }

    #[test]
    fn open_rejects_invalid_line_targets() {
        assert!(command_for_tool("open", &json!({"path": "a", "line": 0}), "/wt").is_err());
        assert!(command_for_tool("open", &json!({"path": "a", "end_line": 2}), "/wt").is_err());
        assert!(command_for_tool(
            "open",
            &json!({"path": "a", "line": 3, "end_line": 2}),
            "/wt"
        )
        .is_err());
        assert!(command_for_tool("open", &json!({"paths": ["a", "b"], "line": 2}), "/wt").is_err());
        assert!(command_for_tool("open", &json!({"path": "a", "paths": ["a"]}), "/wt").is_err());
    }

    #[test]
    fn worktree_tools_map_to_wt_commands() {
        assert_eq!(
            command_for_tool("worktree_list", &json!({}), "/wt").unwrap(),
            alas_client::Command::WtList
        );
        assert_eq!(
            command_for_tool("worktree_switch", &json!({"target": "feat"}), "/wt").unwrap(),
            alas_client::Command::WtSwitch {
                target: "feat".into()
            }
        );
        assert_eq!(
            command_for_tool(
                "worktree_new",
                &json!({"branch": "feat", "base": "main"}),
                "/wt"
            )
            .unwrap(),
            alas_client::Command::WtNew {
                branch: "feat".into(),
                base: Some("main".into())
            }
        );
        assert_eq!(
            command_for_tool("worktree_new", &json!({"branch": "feat"}), "/wt").unwrap(),
            alas_client::Command::WtNew {
                branch: "feat".into(),
                base: None
            }
        );
        assert_eq!(
            command_for_tool(
                "worktree_delete",
                &json!({"target": "feat", "force": true, "keep_branch": true}),
                "/wt"
            )
            .unwrap(),
            alas_client::Command::WtDelete {
                target: "feat".into(),
                force: true,
                keep_branch: true
            }
        );
        assert_eq!(
            command_for_tool("worktree_delete", &json!({"target": "feat"}), "/wt").unwrap(),
            alas_client::Command::WtDelete {
                target: "feat".into(),
                force: false,
                keep_branch: false
            }
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
            alas_client::Command::Review {
                target: None,
                worktree: None
            }
        );
        assert_eq!(
            command_for_tool("review", &json!({"target": "123"}), "/wt").unwrap(),
            alas_client::Command::Review {
                target: Some("123".into()),
                worktree: None
            }
        );
    }

    #[test]
    fn review_tool_maps_worktree_argument() {
        let cmd = command_for_tool(
            "review",
            &serde_json::json!({ "target": "main..HEAD", "worktree": "feature-x" }),
            "/wt",
        )
        .unwrap();
        assert_eq!(
            cmd,
            alas_client::Command::Review {
                target: Some("main..HEAD".into()),
                worktree: Some("feature-x".into()),
            }
        );

        let bare = command_for_tool("review", &serde_json::json!({}), "/wt").unwrap();
        assert_eq!(
            bare,
            alas_client::Command::Review {
                target: None,
                worktree: None,
            }
        );
    }

    #[test]
    fn review_rejects_non_string_worktree_argument() {
        assert!(command_for_tool("review", &json!({"worktree": 123}), "/wt").is_err());
        assert!(command_for_tool("review", &json!({"worktree": true}), "/wt").is_err());
    }

    #[test]
    fn review_accepts_valid_or_omitted_worktree_argument() {
        assert_eq!(
            command_for_tool("review", &json!({"worktree": "feature-x"}), "/wt").unwrap(),
            alas_client::Command::Review {
                target: None,
                worktree: Some("feature-x".into())
            }
        );
        assert_eq!(
            command_for_tool("review", &json!({}), "/wt").unwrap(),
            alas_client::Command::Review {
                target: None,
                worktree: None
            }
        );
    }

    #[test]
    fn review_coerces_numeric_target_and_rejects_other_types() {
        assert_eq!(
            command_for_tool("review", &json!({"target": 123}), "/wt").unwrap(),
            alas_client::Command::Review {
                target: Some("123".into()),
                worktree: None
            }
        );
        assert_eq!(
            command_for_tool("review", &json!({"target": null}), "/wt").unwrap(),
            alas_client::Command::Review {
                target: None,
                worktree: None
            }
        );
        assert!(command_for_tool("review", &json!({"target": true}), "/wt").is_err());
        assert!(command_for_tool("review", &json!({"target": ["1"]}), "/wt").is_err());
    }

    #[test]
    fn review_comments_tool_maps_and_validates_state() {
        assert_eq!(
            command_for_tool("review_comments", &json!({}), "/wt").unwrap(),
            alas_client::Command::ReviewComments {
                session_id: None,
                state: None
            }
        );
        assert_eq!(
            command_for_tool(
                "review_comments",
                &json!({"session_id": "sid", "state": "resolved"}),
                "/wt"
            )
            .unwrap(),
            alas_client::Command::ReviewComments {
                session_id: Some("sid".into()),
                state: Some("resolved".into())
            }
        );
        assert!(command_for_tool("review_comments", &json!({"state": "bogus"}), "/wt").is_err());
    }

    #[test]
    fn review_reply_and_resolve_tools_map_to_commands() {
        assert_eq!(
            command_for_tool(
                "review_reply",
                &json!({"comment_id": "c1", "body": "hi"}),
                "/wt"
            )
            .unwrap(),
            alas_client::Command::ReviewReply {
                comment_id: "c1".into(),
                body: "hi".into()
            }
        );
        assert!(command_for_tool("review_reply", &json!({"comment_id": "c1"}), "/wt").is_err());

        assert_eq!(
            command_for_tool("review_resolve", &json!({"comment_id": "c1"}), "/wt").unwrap(),
            alas_client::Command::ReviewResolve {
                comment_id: "c1".into(),
                reply: None,
                reopen: false
            }
        );
        assert_eq!(
            command_for_tool(
                "review_resolve",
                &json!({"comment_id": "c1", "reply": "done", "state": "active"}),
                "/wt"
            )
            .unwrap(),
            alas_client::Command::ReviewResolve {
                comment_id: "c1".into(),
                reply: Some("done".into()),
                reopen: true
            }
        );
        assert!(command_for_tool(
            "review_resolve",
            &json!({"comment_id": "c1", "state": "bogus"}),
            "/wt"
        )
        .is_err());
    }

    #[test]
    fn review_comment_add_tool_maps_and_validates() {
        assert_eq!(
            command_for_tool(
                "review_comment_add",
                &json!({"path": "a.swift", "start_line": 3, "body": "hm"}),
                "/wt"
            )
            .unwrap(),
            alas_client::Command::ReviewCommentAdd {
                path: "a.swift".into(),
                start_line: 3,
                end_line: None,
                side: None,
                body: "hm".into(),
                session_id: None,
            }
        );
        assert!(command_for_tool(
            "review_comment_add",
            &json!({"path": "a.swift", "body": "hm"}),
            "/wt"
        )
        .is_err());
        assert!(command_for_tool(
            "review_comment_add",
            &json!({"path": "a.swift", "start_line": 0, "body": "hm"}),
            "/wt"
        )
        .is_err());
        assert!(command_for_tool(
            "review_comment_add",
            &json!({"path": "a.swift", "start_line": 3, "body": "hm", "side": "sideways"}),
            "/wt"
        )
        .is_err());
    }

    #[test]
    fn review_finish_tool_maps_and_validates_verdict() {
        assert_eq!(
            command_for_tool("review_finish", &json!({}), "/wt").unwrap(),
            alas_client::Command::ReviewFinish {
                session_id: None,
                verdict: None,
                summary: None
            }
        );
        assert_eq!(
            command_for_tool(
                "review_finish",
                &json!({"session_id": "sid", "verdict": "approve", "summary": "Looks good."}),
                "/wt"
            )
            .unwrap(),
            alas_client::Command::ReviewFinish {
                session_id: Some("sid".into()),
                verdict: Some("approve".into()),
                summary: Some("Looks good.".into()),
            }
        );
        assert!(command_for_tool("review_finish", &json!({"verdict": "reject"}), "/wt").is_err());
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
            Ok(Response {
                ok: true,
                lines: Some(vec!["main *".into(), "feat".into()]),
                error: None,
                exit_code: None,
            })
        })
        .unwrap();
        let result = &reply["result"];
        assert_eq!(result["isError"], json!(false));
        assert_eq!(result["content"][0]["type"], json!("text"));
        assert_eq!(result["content"][0]["text"], json!("main *\nfeat"));
    }

    #[test]
    fn tools_call_synthesizes_confirmation_when_no_lines() {
        let reply = handle_line(
            &call("open", json!({"paths": ["a.txt", "b.txt"]})),
            "/wt",
            |cmd| {
                assert_eq!(
                    cmd,
                    &alas_client::Command::Open {
                        paths: vec!["/wt/a.txt".into(), "/wt/b.txt".into()]
                    }
                );
                Ok(Response {
                    ok: true,
                    lines: None,
                    error: None,
                    exit_code: None,
                })
            },
        )
        .unwrap();
        assert_eq!(reply["result"]["isError"], json!(false));
        assert_eq!(
            reply["result"]["content"][0]["text"],
            json!("Opened 2 file(s) in Alas.")
        );
    }

    #[test]
    fn tools_call_maps_app_failure_to_error_result() {
        let reply = handle_line(&call("review", json!({})), "/wt", |_| {
            Ok(Response {
                ok: false,
                lines: None,
                error: Some("no changes to review".into()),
                exit_code: None,
            })
        })
        .unwrap();
        assert_eq!(reply["result"]["isError"], json!(true));
        assert_eq!(
            reply["result"]["content"][0]["text"],
            json!("no changes to review")
        );
    }

    #[test]
    fn tools_call_maps_transport_failure_to_error_result() {
        let reply = handle_line(&call("worktree_list", json!({})), "/wt", |_| {
            Err(alas_client::TransportError::Connect)
        })
        .unwrap();
        assert_eq!(reply["result"]["isError"], json!(true));
        assert_eq!(
            reply["result"]["content"][0]["text"],
            json!("could not reach Alas")
        );

        let reply = handle_line(&call("worktree_list", json!({})), "/wt", |_| {
            Err(alas_client::TransportError::Malformed)
        })
        .unwrap();
        assert_eq!(
            reply["result"]["content"][0]["text"],
            json!("malformed response from Alas")
        );
        assert_eq!(reply["result"]["isError"], json!(true));
    }

    #[test]
    fn empty_lines_vec_falls_back_to_confirmation_text() {
        let reply = handle_line(&call("worktree_list", json!({})), "/wt", |_| {
            Ok(Response {
                ok: true,
                lines: Some(vec![]),
                error: None,
                exit_code: None,
            })
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
    fn dispatch_sends_session_and_cwd_addressed_request_over_the_socket() {
        use std::io::{Read, Write};

        let unique = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let dir = std::path::PathBuf::from("/private/tmp")
            .join(format!("alas-mcp-it-{}-{unique}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("stub.sock");
        let listener = std::os::unix::net::UnixListener::bind(&path).unwrap();
        let (tx, rx) = std::sync::mpsc::channel::<String>();
        let handle = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut buf = [0u8; 65536];
            let n = stream.read(&mut buf).unwrap();
            tx.send(String::from_utf8_lossy(&buf[..n]).into_owned())
                .unwrap();
            stream
                .write_all(br#"{"ok":true,"lines":["main *"]}"#)
                .unwrap();
        });

        let env = McpEnv {
            socket: path.clone(),
            worktree_dir: "/wt".into(),
            session_id: "acp-1".into(),
            parent_session_id: None,
            workspace_only: false,
        };
        let resp = dispatch(&env, &alas_client::Command::WtList).unwrap();
        assert!(resp.ok);
        assert_eq!(resp.lines, Some(vec!["main *".into()]));

        let seen: Value = serde_json::from_str(&rx.recv().unwrap()).unwrap();
        assert_eq!(seen["kind"], json!("cli"));
        assert_eq!(seen["v"], json!(1));
        assert_eq!(seen["command"], json!("wt"));
        assert_eq!(seen["subcommand"], json!("list"));
        assert_eq!(seen["cwd"], json!("/wt"));
        assert_eq!(seen["session_id"], json!("acp-1"));

        let _ = handle.join();
        let _ = std::fs::remove_dir_all(&dir);
    }
}
