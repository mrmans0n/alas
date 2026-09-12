//! MCP stdio server mode: newline-delimited JSON-RPC on stdin/stdout,
//! translating tool calls into the same socket requests the CLI sends.
//! Hand-rolled on purpose — the surface is five methods; an MCP SDK would
//! be the largest dependency in the workspace.

use alas_client::{Command, Response, TransportError};
use serde_json::{Value, json};
use std::path::PathBuf;
use std::sync::{
    Arc, Mutex,
    atomic::{AtomicUsize, Ordering},
};

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

impl Clone for McpEnv {
    fn clone(&self) -> Self {
        Self {
            socket: self.socket.clone(),
            worktree_dir: self.worktree_dir.clone(),
            session_id: self.session_id.clone(),
            parent_session_id: self.parent_session_id.clone(),
            workspace_only: self.workspace_only,
        }
    }
}

const MAX_MCP_WORKERS: usize = 8;
const MAX_MCP_PREVIEW_CALLS: usize = MAX_MCP_WORKERS - 1;
const MAX_HTTP_CONNECTION_WORKERS: usize = 8;
const HTTP_IO_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(2);

#[derive(Clone)]
struct McpRuntime {
    pending: Arc<Mutex<std::collections::HashMap<String, Command>>>,
    active_workers: Arc<AtomicUsize>,
}

impl McpRuntime {
    fn new() -> Self {
        Self {
            pending: Arc::new(Mutex::new(std::collections::HashMap::new())),
            active_workers: Arc::new(AtomicUsize::new(0)),
        }
    }
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
        Some(_) => {
            "Tools that drive the user's Alas workspace UI. This session was delegated by a parent session: it cannot create descendants; return results or questions through session_send."
        }
        None => {
            "Tools that drive the user's Alas workspace UI: open files for the user to look at, manage linked worktrees, and open reviews. Root ACP sessions may delegate direct child sessions."
        }
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
                    .is_some_and(|name| {
                        name.starts_with("workspace_") || name.starts_with("preview_")
                    })
            })
            .collect();
    }
    all_tool_definitions()
}

fn all_tool_definitions() -> Vec<Value> {
    let mut tools = vec![
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
    ];
    tools.extend(preview_tool_definitions());
    tools.extend(workspace_tool_definitions());
    tools
}

fn workspace_tool_definitions() -> Vec<Value> {
    vec![
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

fn preview_tool_definitions() -> Vec<Value> {
    vec![
        json!({
            "name": "preview_list",
            "description": "List open web previews in Alas as versioned JSON. Read-only.",
            "annotations": { "readOnlyHint": true },
            "inputSchema": { "type": "object", "properties": {} }
        }),
        json!({
            "name": "preview_open",
            "description": "Open or focus a web preview in Alas. May navigate to an external URL or configured script endpoint.",
            "annotations": { "destructiveHint": true },
            "inputSchema": {
                "type": "object",
                "properties": {
                    "url": { "type": "string", "description": "Optional URL to open. Mutually exclusive with script_key." },
                    "script_key": { "type": "string", "description": "Optional configured preview endpoint key. Mutually exclusive with url." }
                }
            }
        }),
        json!({
            "name": "preview_navigate",
            "description": "Navigate an existing Alas web preview. This can trigger external side effects from page loading.",
            "annotations": { "destructiveHint": true },
            "inputSchema": {
                "type": "object",
                "properties": {
                    "preview_id": { "type": "string" },
                    "url": { "type": "string" }
                },
                "required": ["preview_id", "url"]
            }
        }),
        simple_preview_tool(
            "preview_reload",
            "Reload an Alas web preview. Page loading can trigger external side effects.",
        ),
        simple_preview_tool(
            "preview_back",
            "Move an Alas web preview backward in history. Navigation can trigger external side effects.",
        ),
        simple_preview_tool(
            "preview_forward",
            "Move an Alas web preview forward in history. Navigation can trigger external side effects.",
        ),
        json!({
            "name": "preview_inspect",
            "description": "Inspect bounded main-frame DOM metadata from an Alas web preview. Password and file inputs are not read.",
            "annotations": { "readOnlyHint": true },
            "inputSchema": {
                "type": "object",
                "properties": {
                    "preview_id": { "type": "string" },
                    "selector": { "type": "string", "description": "Optional CSS selector. Defaults to interactive elements." },
                    "limit": { "type": "integer", "minimum": 1, "maximum": 100, "description": "Default: 50." }
                },
                "required": ["preview_id"]
            }
        }),
        json!({
            "name": "preview_capture",
            "description": "Capture a PNG screenshot from an Alas web preview. Returns native MCP image content plus JSON metadata.",
            "annotations": { "readOnlyHint": true },
            "inputSchema": {
                "type": "object",
                "properties": {
                    "preview_id": { "type": "string" },
                    "element_id": { "type": "string", "description": "Optional inspected element reference. Mutually exclusive with region." },
                    "region": {
                        "type": "object",
                        "properties": {
                            "x": { "type": "number" },
                            "y": { "type": "number" },
                            "width": { "type": "number", "exclusiveMinimum": 0 },
                            "height": { "type": "number", "exclusiveMinimum": 0 }
                        },
                        "required": ["x", "y", "width", "height"]
                    }
                },
                "required": ["preview_id"]
            }
        }),
        json!({
            "name": "preview_console",
            "description": "Read console metadata from an Alas web preview; optionally clear stored entries after returning them. By default this is read-only, but clear resets stored history.",
            "annotations": { "readOnlyHint": false, "destructiveHint": true },
            "inputSchema": {
                "type": "object",
                "properties": {
                    "preview_id": { "type": "string" },
                    "clear": { "type": "boolean", "description": "Return current console metadata, then clear stored entries. This is destructive." }
                },
                "required": ["preview_id"]
            }
        }),
        json!({
            "name": "preview_click",
            "description": "Click an inspected element in an Alas web preview using DOM interaction. Trusted user gestures are unsupported and page code may have external side effects.",
            "annotations": { "destructiveHint": true },
            "inputSchema": {
                "type": "object",
                "properties": {
                    "preview_id": { "type": "string" },
                    "element_id": { "type": "string" }
                },
                "required": ["preview_id", "element_id"]
            }
        }),
        json!({
            "name": "preview_type",
            "description": "Type text into an inspected element in an Alas web preview using DOM interaction. Trusted user gestures are unsupported; file inputs cannot be populated.",
            "annotations": { "destructiveHint": true },
            "inputSchema": {
                "type": "object",
                "properties": {
                    "preview_id": { "type": "string" },
                    "element_id": { "type": "string" },
                    "text": { "type": "string", "maxLength": 10000 },
                    "append": { "type": "boolean", "description": "Default: false." }
                },
                "required": ["preview_id", "element_id", "text"]
            }
        }),
        json!({
            "name": "preview_scroll",
            "description": "Scroll an Alas web preview by CSS pixel deltas. Scrolling can trigger page side effects such as lazy loading.",
            "annotations": { "destructiveHint": true },
            "inputSchema": {
                "type": "object",
                "properties": {
                    "preview_id": { "type": "string" },
                    "x": { "type": "number", "minimum": -100000, "maximum": 100000 },
                    "y": { "type": "number", "minimum": -100000, "maximum": 100000 }
                },
                "required": ["preview_id", "x", "y"]
            }
        }),
        json!({
            "name": "preview_wait",
            "description": "Wait for loaded state or selector visibility in an Alas web preview. Deadlines are bounded.",
            "annotations": { "readOnlyHint": true },
            "inputSchema": {
                "type": "object",
                "properties": {
                    "preview_id": { "type": "string" },
                    "condition": { "type": "string", "enum": ["loaded", "visible", "hidden"] },
                    "selector": { "type": "string", "description": "Required for visible/hidden; forbidden for loaded." },
                    "timeout_ms": { "type": "integer", "minimum": 1, "maximum": 20000, "description": "Default: 5000." }
                },
                "required": ["preview_id", "condition"]
            }
        }),
        json!({
            "name": "preview_cancel",
            "description": "Cancel the active operation for this preview owner without closing the tab.",
            "annotations": { "destructiveHint": true },
            "inputSchema": {
                "type": "object",
                "properties": { "preview_id": { "type": "string" } },
                "required": ["preview_id"]
            }
        }),
    ]
}

fn simple_preview_tool(name: &str, description: &str) -> Value {
    json!({
        "name": name,
        "description": description,
        "annotations": { "destructiveHint": true },
        "inputSchema": {
            "type": "object",
            "properties": { "preview_id": { "type": "string" } },
            "required": ["preview_id"]
        }
    })
}

fn is_workspace_tool(name: &str) -> bool {
    name.starts_with("workspace_") || name.starts_with("preview_")
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
        "preview_list" => Ok(Command::Preview(alas_client::PreviewCommand::List)),
        "preview_open" => {
            let url = optional_limited_string(args, "url", 8192)?;
            let script_key = optional_limited_string(args, "script_key", 4096)?;
            if url.is_some() && script_key.is_some() {
                return Err("preview_open accepts either 'url' or 'script_key', not both".into());
            }
            Ok(Command::Preview(alas_client::PreviewCommand::Open {
                url,
                script_key,
            }))
        }
        "preview_navigate" => Ok(Command::Preview(alas_client::PreviewCommand::Navigate {
            preview_id: required_limited_string(args, "preview_id", 4096)?,
            url: required_limited_string(args, "url", 8192)?,
        })),
        "preview_reload" => preview_id_command(args, |preview_id| {
            alas_client::PreviewCommand::Reload { preview_id }
        }),
        "preview_back" => preview_id_command(args, |preview_id| {
            alas_client::PreviewCommand::Back { preview_id }
        }),
        "preview_forward" => preview_id_command(args, |preview_id| {
            alas_client::PreviewCommand::Forward { preview_id }
        }),
        "preview_inspect" => Ok(Command::Preview(alas_client::PreviewCommand::Inspect {
            preview_id: required_limited_string(args, "preview_id", 4096)?,
            selector: optional_limited_string(args, "selector", 4096)?,
            limit: optional_bounded_u64(args, "limit", 1, 100)?.unwrap_or(50),
        })),
        "preview_capture" => {
            let preview_id = required_limited_string(args, "preview_id", 4096)?;
            let element_id = optional_limited_string(args, "element_id", 4096)?;
            let region = optional_region(args)?;
            if element_id.is_some() && region.is_some() {
                return Err(
                    "preview_capture accepts either 'element_id' or 'region', not both".into(),
                );
            }
            let target = match (element_id, region) {
                (Some(element_id), None) => {
                    alas_client::PreviewCaptureTarget::Element { element_id }
                }
                (None, Some(region)) => region,
                (None, None) => alas_client::PreviewCaptureTarget::Viewport,
                (Some(_), Some(_)) => unreachable!("mutual exclusion checked above"),
            };
            Ok(Command::Preview(alas_client::PreviewCommand::Capture {
                preview_id,
                target,
            }))
        }
        "preview_console" => Ok(Command::Preview(alas_client::PreviewCommand::Console {
            preview_id: required_limited_string(args, "preview_id", 4096)?,
            clear: optional_bool(args, "clear")?.unwrap_or(false),
        })),
        "preview_click" => Ok(Command::Preview(alas_client::PreviewCommand::Click {
            preview_id: required_limited_string(args, "preview_id", 4096)?,
            element_id: required_limited_string(args, "element_id", 4096)?,
        })),
        "preview_type" => {
            let text = required_exact_string(args, "text")?;
            if text.chars().count() > 10_000 || text.len() > 40_000 {
                return Err(
                    "preview_type 'text' must be at most 10000 characters and 40000 bytes".into(),
                );
            }
            Ok(Command::Preview(alas_client::PreviewCommand::Type {
                preview_id: required_limited_string(args, "preview_id", 4096)?,
                element_id: required_limited_string(args, "element_id", 4096)?,
                text,
                append: optional_bool(args, "append")?.unwrap_or(false),
            }))
        }
        "preview_scroll" => Ok(Command::Preview(alas_client::PreviewCommand::Scroll {
            preview_id: required_limited_string(args, "preview_id", 4096)?,
            x: required_bounded_f64(args, "x", -100_000.0, 100_000.0)?,
            y: required_bounded_f64(args, "y", -100_000.0, 100_000.0)?,
        })),
        "preview_wait" => {
            let condition = match required_non_blank_string(args, "condition")?.as_str() {
                "loaded" => alas_client::PreviewWaitCondition::Loaded,
                "visible" => alas_client::PreviewWaitCondition::Visible,
                "hidden" => alas_client::PreviewWaitCondition::Hidden,
                _ => {
                    return Err(
                        "preview_wait 'condition' must be loaded, visible, or hidden".into(),
                    );
                }
            };
            let selector = optional_limited_string(args, "selector", 4096)?;
            match condition {
                alas_client::PreviewWaitCondition::Loaded if selector.is_some() => {
                    return Err("preview_wait 'loaded' does not accept 'selector'".into());
                }
                alas_client::PreviewWaitCondition::Visible
                | alas_client::PreviewWaitCondition::Hidden
                    if selector.is_none() =>
                {
                    return Err("preview_wait 'selector' is required for visible and hidden".into());
                }
                _ => {}
            }
            Ok(Command::Preview(alas_client::PreviewCommand::Wait {
                preview_id: required_limited_string(args, "preview_id", 4096)?,
                condition,
                selector,
                timeout_ms: optional_bounded_u64(args, "timeout_ms", 1, 20_000)?.unwrap_or(5_000),
            }))
        }
        "preview_cancel" => preview_id_command(args, |preview_id| {
            alas_client::PreviewCommand::Cancel { preview_id }
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

fn required_non_blank_string(args: &Value, key: &str) -> Result<String, String> {
    optional_non_blank_string(args, key)?
        .ok_or_else(|| format!("missing required argument '{key}'"))
}

fn required_limited_string(args: &Value, key: &str, max_bytes: usize) -> Result<String, String> {
    optional_limited_string(args, key, max_bytes)?
        .ok_or_else(|| format!("missing required argument '{key}'"))
}

fn required_exact_string(args: &Value, key: &str) -> Result<String, String> {
    match args.get(key) {
        Some(Value::String(value)) => Ok(value.clone()),
        Some(_) => Err(format!("{key} must be a string")),
        None => Err(format!("missing required argument '{key}'")),
    }
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

fn optional_bool(args: &Value, key: &str) -> Result<Option<bool>, String> {
    match args.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Bool(value)) => Ok(Some(*value)),
        Some(_) => Err(format!("{key} must be a boolean")),
    }
}

fn optional_bounded_u64(
    args: &Value,
    key: &str,
    min: u64,
    max: u64,
) -> Result<Option<u64>, String> {
    match args.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(value) => value
            .as_u64()
            .filter(|value| *value >= min && *value <= max)
            .map(Some)
            .ok_or_else(|| format!("{key} must be an integer from {min} to {max}")),
    }
}

fn required_bounded_f64(args: &Value, key: &str, min: f64, max: f64) -> Result<f64, String> {
    args.get(key)
        .and_then(Value::as_f64)
        .filter(|value| value.is_finite() && *value >= min && *value <= max)
        .ok_or_else(|| format!("{key} must be a number from {min} to {max}"))
}

fn optional_region(args: &Value) -> Result<Option<alas_client::PreviewCaptureTarget>, String> {
    let Some(value) = args.get("region") else {
        return Ok(None);
    };
    let Value::Object(region) = value else {
        return Err("preview_capture 'region' must be an object".into());
    };
    let x = required_region_number(region, "x", false)?;
    let y = required_region_number(region, "y", false)?;
    let width = required_region_number(region, "width", true)?;
    let height = required_region_number(region, "height", true)?;
    Ok(Some(alas_client::PreviewCaptureTarget::Region {
        x,
        y,
        width,
        height,
    }))
}

fn required_region_number(
    region: &serde_json::Map<String, Value>,
    key: &str,
    positive: bool,
) -> Result<f64, String> {
    let value = region
        .get(key)
        .and_then(Value::as_f64)
        .filter(|value| value.is_finite() && value.abs() <= 100_000.0)
        .ok_or_else(|| format!("preview_capture 'region.{key}' must be a number"))?;
    if positive && value <= 0.0 {
        Err(format!(
            "preview_capture 'region.{key}' must be greater than 0"
        ))
    } else {
        Ok(value)
    }
}

fn preview_id_command(
    args: &Value,
    build: impl FnOnce(String) -> alas_client::PreviewCommand,
) -> Result<Command, String> {
    Ok(Command::Preview(build(required_limited_string(
        args,
        "preview_id",
        4096,
    )?)))
}

fn optional_limited_string(
    args: &Value,
    key: &str,
    max_bytes: usize,
) -> Result<Option<String>, String> {
    match optional_non_blank_string(args, key)? {
        Some(value) if value.len() > max_bytes => {
            Err(format!("{key} must be at most {max_bytes} bytes"))
        }
        value => Ok(value),
    }
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
    if matches!(
        command,
        Command::Preview(alas_client::PreviewCommand::Capture { .. })
    ) {
        if let Some(result) = capture_tool_result(resp.lines.as_ref()) {
            return result;
        }
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
        Command::Preview(_) => "Preview command completed.".into(),
        Command::WtList | Command::Resolve => "OK".into(),
    }
}

fn transport_error_result(err: &TransportError) -> Value {
    // Mirrors describe() in main.rs so agents and humans read the same words.
    let message = match err {
        TransportError::Malformed => "malformed response from Alas",
        TransportError::ResponseTooLarge => "response from Alas exceeded 12 MiB",
        TransportError::Connect | TransportError::Io => "could not reach Alas",
    };
    text_result(message.into(), true)
}

fn text_result(text: String, is_error: bool) -> Value {
    json!({ "content": [{ "type": "text", "text": text }], "isError": is_error })
}

fn capture_tool_result(lines: Option<&Vec<String>>) -> Option<Value> {
    let first = lines?.first()?;
    let mut metadata: Value = serde_json::from_str(first).ok()?;
    let image = metadata.get("image")?;
    let mime_type = image.get("mime_type").and_then(Value::as_str)?.to_string();
    let data = image.get("data").and_then(Value::as_str)?.to_string();
    metadata.as_object_mut()?.remove("image");
    let metadata_text =
        serde_json::to_string_pretty(&metadata).unwrap_or_else(|_| metadata.to_string());
    let mut content = vec![
        json!({ "type": "image", "mimeType": mime_type, "data": data }),
        json!({ "type": "text", "text": metadata_text }),
    ];
    if let Some(extra_lines) = lines {
        if extra_lines.len() > 1 {
            content.push(json!({ "type": "text", "text": extra_lines[1..].join("\n") }));
        }
    }
    Some(json!({ "content": content, "isError": false }))
}

fn tools_call_command(
    msg: &Value,
    worktree_dir: &str,
    workspace_only: bool,
) -> Result<Option<(Value, Command)>, Value> {
    if msg.get("method").and_then(Value::as_str) != Some("tools/call") {
        return Ok(None);
    }
    let id = msg.get("id").cloned().unwrap_or(Value::Null);
    let params = msg.get("params").cloned().unwrap_or(Value::Null);
    let name = match params.get("name").and_then(Value::as_str) {
        Some(name) => name,
        None => {
            return Err(error_reply(id, -32602, "tools/call requires a tool name"));
        }
    };
    if workspace_only && !is_workspace_tool(name) {
        return Err(error_reply(
            id,
            -32602,
            &format!("tool unavailable in Workspace Checkout context: {name}"),
        ));
    }
    let args = params
        .get("arguments")
        .cloned()
        .unwrap_or_else(|| json!({}));
    match command_for_tool(name, &args, worktree_dir) {
        Ok(command) => Ok(Some((id, command))),
        Err(message) => Err(error_reply(id, -32602, &message)),
    }
}

fn request_key(id: &Value) -> String {
    id.to_string()
}

fn preview_id_for_cancel(command: &Command) -> Option<String> {
    match command {
        Command::Preview(alas_client::PreviewCommand::Navigate { preview_id, .. })
        | Command::Preview(alas_client::PreviewCommand::Reload { preview_id })
        | Command::Preview(alas_client::PreviewCommand::Back { preview_id })
        | Command::Preview(alas_client::PreviewCommand::Forward { preview_id })
        | Command::Preview(alas_client::PreviewCommand::Inspect { preview_id, .. })
        | Command::Preview(alas_client::PreviewCommand::Capture { preview_id, .. })
        | Command::Preview(alas_client::PreviewCommand::Console { preview_id, .. })
        | Command::Preview(alas_client::PreviewCommand::Click { preview_id, .. })
        | Command::Preview(alas_client::PreviewCommand::Type { preview_id, .. })
        | Command::Preview(alas_client::PreviewCommand::Scroll { preview_id, .. })
        | Command::Preview(alas_client::PreviewCommand::Wait { preview_id, .. })
        | Command::Preview(alas_client::PreviewCommand::Cancel { preview_id }) => {
            Some(preview_id.clone())
        }
        Command::Preview(alas_client::PreviewCommand::List)
        | Command::Preview(alas_client::PreviewCommand::Open { .. }) => None,
        _ => None,
    }
}

fn is_preview_command(command: &Command) -> bool {
    matches!(command, Command::Preview(_))
}

fn is_preview_cancel_command(command: &Command) -> bool {
    matches!(
        command,
        Command::Preview(alas_client::PreviewCommand::Cancel { .. })
    )
}

fn register_pending_preview(
    pending: &Mutex<std::collections::HashMap<String, Command>>,
    id: &Value,
    command: &Command,
) -> Option<String> {
    if preview_id_for_cancel(command).is_none() {
        return None;
    }
    let key = request_key(id);
    if let Ok(mut pending) = pending.lock() {
        pending.insert(key.clone(), command.clone());
        Some(key)
    } else {
        None
    }
}

fn remove_pending_preview(
    pending: &Mutex<std::collections::HashMap<String, Command>>,
    key: Option<&str>,
) {
    if let Some(key) = key {
        if let Ok(mut pending) = pending.lock() {
            pending.remove(key);
        }
    }
}

fn try_reserve_worker(active_workers: &AtomicUsize, limit: usize) -> bool {
    active_workers
        .fetch_update(Ordering::SeqCst, Ordering::SeqCst, |count| {
            (count < limit).then_some(count + 1)
        })
        .is_ok()
}

fn release_worker(active_workers: &AtomicUsize) {
    active_workers.fetch_sub(1, Ordering::SeqCst);
}

fn cancellation_request_key(msg: &Value) -> Option<String> {
    if msg.get("id").is_some() {
        return None;
    }
    let method = msg.get("method").and_then(Value::as_str)?;
    if method != "notifications/cancelled" && method != "$/cancelRequest" {
        return None;
    }
    let request_id = msg.get("params")?.get("requestId")?;
    Some(request_key(request_id))
}

fn cancellation_command_for_message(
    msg: &Value,
    pending: &Mutex<std::collections::HashMap<String, Command>>,
) -> Option<Command> {
    let key = cancellation_request_key(msg)?;
    let command = pending.lock().ok()?.get(&key).cloned()?;
    let preview_id = preview_id_for_cancel(&command)?;
    Some(Command::Preview(alas_client::PreviewCommand::Cancel {
        preview_id,
    }))
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
    let (reply_tx, reply_rx) = std::sync::mpsc::channel::<Value>();
    let writer = std::thread::spawn(move || -> std::io::Result<()> {
        let mut out = stdout.lock();
        for reply in reply_rx {
            out.write_all(reply.to_string().as_bytes())?;
            out.write_all(b"\n")?;
            out.flush()?;
        }
        Ok(())
    });
    let runtime = McpRuntime::new();

    for line in stdin.lock().lines() {
        let line = line?;
        if line.trim().is_empty() {
            continue;
        }
        let msg = match serde_json::from_str::<Value>(&line) {
            Ok(Value::Object(_)) => serde_json::from_str::<Value>(&line).unwrap(),
            Ok(_) => {
                let _ = reply_tx.send(error_reply(Value::Null, -32600, "invalid request"));
                continue;
            }
            Err(_) => {
                let _ = reply_tx.send(error_reply(Value::Null, -32700, "parse error"));
                continue;
            }
        };
        if let Some(cancel) = cancellation_command_for_message(&msg, &runtime.pending) {
            if !try_reserve_worker(&runtime.active_workers, MAX_MCP_WORKERS) {
                continue;
            }
            let env = env.clone();
            let active_workers = Arc::clone(&runtime.active_workers);
            let spawn = std::thread::Builder::new()
                .name("alas-mcp-cancel".into())
                .spawn(move || {
                    let _ = dispatch(&env, &cancel);
                    release_worker(&active_workers);
                });
            if spawn.is_err() {
                release_worker(&runtime.active_workers);
            }
            continue;
        }
        match tools_call_command(&msg, &env.worktree_dir, env.workspace_only) {
            Ok(Some((id, command))) => {
                if !is_preview_command(&command) {
                    let result = match dispatch(env, &command) {
                        Ok(resp) => tool_result(&command, resp),
                        Err(err) => transport_error_result(&err),
                    };
                    let _ = reply_tx.send(json!({
                        "jsonrpc": "2.0",
                        "id": id,
                        "result": result
                    }));
                    continue;
                }
                let limit = if is_preview_cancel_command(&command) {
                    MAX_MCP_WORKERS
                } else {
                    MAX_MCP_PREVIEW_CALLS
                };
                if !try_reserve_worker(&runtime.active_workers, limit) {
                    let _ = reply_tx.send(error_reply(
                        id,
                        -32000,
                        "too many concurrent Alas MCP preview calls",
                    ));
                    continue;
                }
                let key = register_pending_preview(&runtime.pending, &id, &command);
                let env = env.clone();
                let reply_tx = reply_tx.clone();
                let pending = Arc::clone(&runtime.pending);
                let active_workers = Arc::clone(&runtime.active_workers);
                let fallback_id = id.clone();
                let fallback_key = key.clone();
                let worker_reply_tx = reply_tx.clone();
                let spawn = std::thread::Builder::new()
                    .name("alas-mcp-preview-tool".into())
                    .spawn(move || {
                        let result = match dispatch(&env, &command) {
                            Ok(resp) => tool_result(&command, resp),
                            Err(err) => transport_error_result(&err),
                        };
                        remove_pending_preview(&pending, key.as_deref());
                        release_worker(&active_workers);
                        let _ = worker_reply_tx.send(json!({
                            "jsonrpc": "2.0",
                            "id": id,
                            "result": result
                        }));
                    });
                if spawn.is_err() {
                    remove_pending_preview(&runtime.pending, fallback_key.as_deref());
                    release_worker(&runtime.active_workers);
                    let _ = reply_tx.send(error_reply(
                        fallback_id,
                        -32000,
                        "could not start preview tool worker",
                    ));
                }
            }
            Ok(None) => {
                if let Some(reply) = handle_line_with_parent(
                    &line,
                    &env.worktree_dir,
                    env.parent_session_id.as_deref(),
                    env.workspace_only,
                    |cmd| dispatch(env, cmd),
                ) {
                    let _ = reply_tx.send(reply);
                }
            }
            Err(reply) => {
                let _ = reply_tx.send(reply);
            }
        }
    }
    drop(reply_tx);
    writer
        .join()
        .unwrap_or_else(|_| Err(std::io::Error::other("mcp writer thread panicked")))
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
        503 => "Service Unavailable",
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
/// `ALAS_MCP_HTTP_TOKEN` on every request.
pub fn serve_http(env: &McpEnv) -> std::io::Result<()> {
    use std::io::Write;
    use std::net::TcpListener;

    let token = std::env::var("ALAS_MCP_HTTP_TOKEN").unwrap_or_default();
    let runtime = McpRuntime::new();
    let active_connections = Arc::new(AtomicUsize::new(0));

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

    fn serve_one(
        env: McpEnv,
        listener: TcpListener,
        token: String,
        runtime: McpRuntime,
        active_connections: Arc<AtomicUsize>,
    ) {
        for stream in listener.incoming() {
            match stream {
                Ok(stream) => {
                    if !try_reserve_worker(&active_connections, MAX_HTTP_CONNECTION_WORKERS) {
                        reject_http_connection(stream);
                        continue;
                    }
                    let env = env.clone();
                    let token = token.clone();
                    let runtime = runtime.clone();
                    let active_connections = Arc::clone(&active_connections);
                    let worker_active_connections = Arc::clone(&active_connections);
                    let spawn = std::thread::Builder::new()
                        .name("alas-mcp-http-connection".into())
                        .spawn(move || {
                            let mut stream = stream;
                            if let Err(err) =
                                handle_http_connection(&env, &mut stream, &token, &runtime)
                            {
                                // A single bad connection must not take down the server.
                                eprintln!("alas: mcp http connection error: {err}");
                            }
                            release_worker(&worker_active_connections);
                        });
                    if spawn.is_err() {
                        release_worker(&active_connections);
                    }
                }
                Err(err) => eprintln!("alas: mcp http accept error: {err}"),
            }
        }
    }

    if let Some(v6) = v6_listener {
        let env = env.clone();
        let token = token.clone();
        let runtime = runtime.clone();
        let active_connections = Arc::clone(&active_connections);
        let _ = std::thread::Builder::new()
            .name("alas-mcp-http-v6".into())
            .spawn(move || serve_one(env, v6, token, runtime, active_connections));
    }
    serve_one(env.clone(), v4_listener, token, runtime, active_connections);
    Ok(())
}

fn reject_http_connection(mut stream: std::net::TcpStream) {
    use std::io::Write;

    let response = http_response(
        503,
        "text/plain",
        "too many concurrent MCP HTTP connections",
    );
    let _ = stream.write_all(response.as_bytes());
    let _ = stream.flush();
}

fn handle_http_connection(
    env: &McpEnv,
    stream: &mut std::net::TcpStream,
    token: &str,
    runtime: &McpRuntime,
) -> std::io::Result<()> {
    use std::io::{ErrorKind, Read, Write};
    // The accept loop is single-threaded, so a client that connects and never
    // sends a complete request must not wedge every other session. Bound the
    // (pre-auth) read with a timeout; on timeout we answer 400 and move on.
    let _ = stream.set_read_timeout(Some(HTTP_IO_TIMEOUT));

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
        Ok(Some(req)) => build_http_response(env, &req, token, runtime),
        Ok(None) => http_response(400, "text/plain", "bad request"),
        Err(message) => http_response(400, "text/plain", message),
    };
    let _ = stream.set_write_timeout(Some(HTTP_IO_TIMEOUT));
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

fn build_http_response(
    env: &McpEnv,
    req: &HttpRequest,
    token: &str,
    runtime: &McpRuntime,
) -> String {
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

    let msg = match serde_json::from_str::<Value>(&req.body) {
        Ok(Value::Object(_)) => serde_json::from_str::<Value>(&req.body).ok(),
        Ok(_) => {
            return http_response(
                200,
                "application/json",
                &error_reply(Value::Null, -32600, "invalid request").to_string(),
            );
        }
        Err(_) => {
            return http_response(
                200,
                "application/json",
                &error_reply(Value::Null, -32700, "parse error").to_string(),
            );
        }
    };
    if let Some(msg) = msg {
        if let Some(cancel) = cancellation_command_for_message(&msg, &runtime.pending) {
            let _ = dispatch(env, &cancel);
            return http_response(202, "application/json", "");
        }
        match tools_call_command(&msg, &env.worktree_dir, env.workspace_only) {
            Ok(Some((id, command))) if is_preview_command(&command) => {
                let limit = if is_preview_cancel_command(&command) {
                    MAX_MCP_WORKERS
                } else {
                    MAX_MCP_PREVIEW_CALLS
                };
                if !try_reserve_worker(&runtime.active_workers, limit) {
                    return http_response(
                        200,
                        "application/json",
                        &error_reply(id, -32000, "too many concurrent Alas MCP preview calls")
                            .to_string(),
                    );
                }
                let key = register_pending_preview(&runtime.pending, &id, &command);
                let result = match dispatch(env, &command) {
                    Ok(resp) => tool_result(&command, resp),
                    Err(err) => transport_error_result(&err),
                };
                remove_pending_preview(&runtime.pending, key.as_deref());
                release_worker(&runtime.active_workers);
                let reply = json!({ "jsonrpc": "2.0", "id": id, "result": result });
                return http_response(200, "application/json", &reply.to_string());
            }
            Ok(Some(_)) => {}
            Ok(None) => {}
            Err(reply) => {
                return http_response(200, "application/json", &reply.to_string());
            }
        }
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
        HttpRequest, McpEnv, McpRuntime, PROTOCOL_VERSION, build_http_response,
        cancellation_command_for_message, command_for_tool, dispatch, env_from, handle_line,
        handle_line_with_parent, http_response, is_initialize_message, parse_http_request,
        tools_call_command,
    };
    use alas_client::{Command, Response};
    use serde_json::{Value, json};

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
        assert!(
            env_from(env(&[
                ("ALAS_WORKTREE_DIR", "/wt"),
                ("ALAS_SESSION_ID", "s1")
            ]))
            .is_err()
        );
        assert!(
            env_from(env(&[
                ("ALAS_SOCKET_PATH", "/tmp/s"),
                ("ALAS_SESSION_ID", "s1")
            ]))
            .is_err()
        );
        assert!(
            env_from(env(&[
                ("ALAS_SOCKET_PATH", "/tmp/s"),
                ("ALAS_WORKTREE_DIR", "/wt")
            ]))
            .is_err()
        );
        assert!(
            env_from(env(&[
                ("ALAS_SOCKET_PATH", ""),
                ("ALAS_WORKTREE_DIR", "/wt"),
                ("ALAS_SESSION_ID", "s1")
            ]))
            .is_err()
        );
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
        assert!(
            env_from(env(&[
                ("ALAS_SOCKET_PATH", "/tmp/s"),
                ("ALAS_WORKTREE_DIR", "wt"),
                ("ALAS_SESSION_ID", "s1")
            ]))
            .is_err()
        );
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

        assert!(
            command_for_tool(
                "notify",
                &json!({ "body": "Done", "level": "urgent" }),
                "/wt"
            )
            .is_err()
        );
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
                "preview_list",
                "preview_open",
                "preview_navigate",
                "preview_reload",
                "preview_back",
                "preview_forward",
                "preview_inspect",
                "preview_capture",
                "preview_console",
                "preview_click",
                "preview_type",
                "preview_scroll",
                "preview_wait",
                "preview_cancel",
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
        assert!(
            command_for_tool(
                "workspace_focus",
                &json!({ "checkout_id": checkout }),
                "/wt"
            )
            .is_err()
        );
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
                "preview_list",
                "preview_open",
                "preview_navigate",
                "preview_reload",
                "preview_back",
                "preview_forward",
                "preview_inspect",
                "preview_capture",
                "preview_console",
                "preview_click",
                "preview_type",
                "preview_scroll",
                "preview_wait",
                "preview_cancel",
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

        let preview = handle_line_with_parent(
            r#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"preview_list","arguments":{}}}"#,
            "/checkout",
            None,
            true,
            |command| {
                assert_eq!(*command, Command::Preview(alas_client::PreviewCommand::List));
                Ok(Response {
                    ok: true,
                    lines: Some(vec![r#"{"version":1,"previews":[]}"#.into()]),
                    error: None,
                    exit_code: None,
                })
            },
        )
        .unwrap();
        assert!(preview.get("error").is_none());

        let preview_open = handle_line_with_parent(
            r#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"preview_open","arguments":{"url":"http://127.0.0.1:5173"}}}"#,
            "/checkout",
            None,
            true,
            |command| {
                assert_eq!(
                    *command,
                    Command::Preview(alas_client::PreviewCommand::Open {
                        url: Some("http://127.0.0.1:5173".into()),
                        script_key: None,
                    })
                );
                Ok(Response {
                    ok: true,
                    lines: Some(vec![r#"{"version":1,"preview_id":"p1"}"#.into()]),
                    error: None,
                    exit_code: None,
                })
            },
        )
        .unwrap();
        assert!(preview_open.get("error").is_none());
    }

    #[test]
    fn workspace_only_preparsed_tool_call_accepts_preview_tools() {
        let msg: Value = serde_json::from_str(
            r#"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"preview_open","arguments":{"url":"http://127.0.0.1:5173"}}}"#,
        )
        .unwrap();
        let (id, command) = tools_call_command(&msg, "/checkout", true)
            .unwrap()
            .expect("preview tool call");
        assert_eq!(id, json!(9));
        assert_eq!(
            command,
            Command::Preview(alas_client::PreviewCommand::Open {
                url: Some("http://127.0.0.1:5173".into()),
                script_key: None,
            })
        );
    }

    #[test]
    fn workspace_only_mode_exposes_preview_tools_too() {
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
        assert!(names.contains(&"workspace_list"));
        assert!(names.contains(&"preview_capture"));
        assert!(!names.contains(&"open"));
    }

    #[test]
    fn preview_tools_validate_arguments_and_map_to_commands() {
        assert_eq!(
            command_for_tool(
                "preview_open",
                &json!({ "url": "http://127.0.0.1:5173" }),
                "/wt"
            )
            .unwrap(),
            alas_client::Command::Preview(alas_client::PreviewCommand::Open {
                url: Some("http://127.0.0.1:5173".into()),
                script_key: None
            })
        );
        assert_eq!(
            command_for_tool(
                "preview_capture",
                &json!({ "preview_id": "p1", "element_id": "e1" }),
                "/wt"
            )
            .unwrap(),
            alas_client::Command::Preview(alas_client::PreviewCommand::Capture {
                preview_id: "p1".into(),
                target: alas_client::PreviewCaptureTarget::Element {
                    element_id: "e1".into()
                }
            })
        );
        assert!(
            command_for_tool(
                "preview_open",
                &json!({ "url": "http://localhost", "script_key": "web" }),
                "/wt"
            )
            .is_err()
        );
        assert!(
            command_for_tool(
                "preview_inspect",
                &json!({ "preview_id": "p1", "limit": 101 }),
                "/wt"
            )
            .is_err()
        );
        assert!(
            command_for_tool(
                "preview_scroll",
                &json!({ "preview_id": "p1", "x": 0, "y": -100001 }),
                "/wt"
            )
            .is_err()
        );
        assert!(
            command_for_tool(
                "preview_wait",
                &json!({ "preview_id": "p1", "condition": "hidden" }),
                "/wt"
            )
            .is_err()
        );
    }

    #[test]
    fn preview_tools_validate_swift_schema_bounds() {
        assert!(
            command_for_tool("preview_open", &json!({ "url": "h".repeat(8193) }), "/wt").is_err()
        );
        assert!(
            command_for_tool(
                "preview_inspect",
                &json!({ "preview_id": "p".repeat(4097) }),
                "/wt"
            )
            .is_err()
        );
        assert!(
            command_for_tool(
                "preview_type",
                &json!({ "preview_id": "p1", "element_id": "e1", "text": "é".repeat(20_001) }),
                "/wt"
            )
            .is_err()
        );
        assert!(
            command_for_tool(
                "preview_capture",
                &json!({ "preview_id": "p1", "region": { "x": 100001.0, "y": 0, "width": 1, "height": 1 } }),
                "/wt"
            )
            .is_err()
        );
        assert_eq!(
            command_for_tool(
                "preview_scroll",
                &json!({ "preview_id": "p1", "x": 0.5, "y": -1.25 }),
                "/wt"
            )
            .unwrap(),
            Command::Preview(alas_client::PreviewCommand::Scroll {
                preview_id: "p1".into(),
                x: 0.5,
                y: -1.25
            })
        );
    }

    #[test]
    fn cancellation_notification_maps_pending_preview_request_to_cancel_command() {
        let pending = std::sync::Mutex::new(std::collections::HashMap::from([(
            json!(7).to_string(),
            Command::Preview(alas_client::PreviewCommand::Wait {
                preview_id: "runtime-preview-id".into(),
                condition: alas_client::PreviewWaitCondition::Loaded,
                selector: None,
                timeout_ms: 20_000,
            }),
        )]));
        let msg: Value = serde_json::from_str(
            r#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":7,"reason":"user requested cancellation"}}"#,
        )
        .unwrap();
        assert_eq!(
            cancellation_command_for_message(&msg, &pending),
            Some(Command::Preview(alas_client::PreviewCommand::Cancel {
                preview_id: "runtime-preview-id".into()
            }))
        );
    }

    #[test]
    fn http_cancellation_notification_uses_pending_preview_map() {
        let runtime = McpRuntime::new();
        runtime.pending.lock().unwrap().insert(
            json!("wait-1").to_string(),
            Command::Preview(alas_client::PreviewCommand::Wait {
                preview_id: "runtime-preview-id".into(),
                condition: alas_client::PreviewWaitCondition::Loaded,
                selector: None,
                timeout_ms: 20_000,
            }),
        );
        let env = McpEnv {
            socket: "/tmp/alas-no-such-socket-for-cancel-test".into(),
            worktree_dir: "/wt".into(),
            session_id: "s1".into(),
            parent_session_id: None,
            workspace_only: false,
        };
        let req = HttpRequest {
            method: "POST".into(),
            path: "/mcp".into(),
            bearer: Some("tok".into()),
            body: r#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"wait-1"}}"#.into(),
        };

        let response = build_http_response(&env, &req, "tok", &runtime);

        assert!(response.starts_with("HTTP/1.1 202 Accepted"));
    }

    #[test]
    fn preview_capture_result_extracts_mcp_image_and_keeps_metadata_text() {
        let line = json!({
            "version": 1,
            "url": "http://127.0.0.1:5173/",
            "captured_at": "2026-09-12T10:00:00Z",
            "viewport": { "width": 800, "height": 600 },
            "image": { "mime_type": "image/png", "data": "iVBORw0KGgo=" }
        })
        .to_string();
        let reply = handle_line(
            r#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"preview_capture","arguments":{"preview_id":"p1"}}}"#,
            "/wt",
            |command| {
                assert!(matches!(
                    command,
                    Command::Preview(alas_client::PreviewCommand::Capture { .. })
                ));
                Ok(Response {
                    ok: true,
                    lines: Some(vec![line.clone()]),
                    error: None,
                    exit_code: None,
                })
            },
        )
        .unwrap();

        let content = reply["result"]["content"].as_array().unwrap();
        assert_eq!(content[0]["type"], json!("image"));
        assert_eq!(content[0]["mimeType"], json!("image/png"));
        assert_eq!(content[0]["data"], json!("iVBORw0KGgo="));
        assert_eq!(content[1]["type"], json!("text"));
        assert!(content[1]["text"].as_str().unwrap().contains("\"url\""));
        assert!(!content[1]["text"].as_str().unwrap().contains("\"image\""));
    }

    #[test]
    fn preview_tool_schemas_include_security_hints() {
        let reply = handle_line(
            r#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#,
            "/wt",
            |_| unreachable!(),
        )
        .unwrap();
        let tools = reply["result"]["tools"].as_array().unwrap();
        let by_name = |name: &str| {
            tools
                .iter()
                .find(|tool| tool["name"] == json!(name))
                .expect("tool exists")
        };
        assert_eq!(
            by_name("preview_list")["annotations"]["readOnlyHint"],
            json!(true)
        );
        assert_eq!(
            by_name("preview_click")["annotations"]["destructiveHint"],
            json!(true)
        );
        assert_eq!(
            by_name("preview_type")["annotations"]["destructiveHint"],
            json!(true)
        );
        assert_eq!(
            by_name("preview_console")["annotations"]["readOnlyHint"],
            json!(false)
        );
        assert_eq!(
            by_name("preview_console")["annotations"]["destructiveHint"],
            json!(true)
        );
        assert_eq!(
            by_name("preview_console")["inputSchema"]["properties"]["clear"]["description"],
            json!(
                "Return current console metadata, then clear stored entries. This is destructive."
            )
        );
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
        assert!(
            command_for_tool(
                "session_send",
                &json!({ "session_id": "child", "prompt": "  " }),
                "/wt"
            )
            .is_err()
        );
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
        assert!(
            command_for_tool(
                "open",
                &json!({"path": "a", "line": 3, "end_line": 2}),
                "/wt"
            )
            .is_err()
        );
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
        assert!(
            command_for_tool(
                "review_resolve",
                &json!({"comment_id": "c1", "state": "bogus"}),
                "/wt"
            )
            .is_err()
        );
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
        assert!(
            command_for_tool(
                "review_comment_add",
                &json!({"path": "a.swift", "body": "hm"}),
                "/wt"
            )
            .is_err()
        );
        assert!(
            command_for_tool(
                "review_comment_add",
                &json!({"path": "a.swift", "start_line": 0, "body": "hm"}),
                "/wt"
            )
            .is_err()
        );
        assert!(
            command_for_tool(
                "review_comment_add",
                &json!({"path": "a.swift", "start_line": 3, "body": "hm", "side": "sideways"}),
                "/wt"
            )
            .is_err()
        );
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
