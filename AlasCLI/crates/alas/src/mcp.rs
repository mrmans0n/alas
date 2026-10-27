//! MCP stdio server mode: newline-delimited JSON-RPC on stdin/stdout,
//! translating tool calls into the same socket requests the CLI sends.
//! Hand-rolled on purpose — the surface is five methods; an MCP SDK would
//! be the largest dependency in the workspace.

use alas_client::{Command, Response, TransportError, VisualOption, VisualQuestion};
use serde_json::{Value, json};
use std::path::PathBuf;
use std::sync::{
    Arc, Mutex,
    atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering},
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
    /// Set by `ALAS_MCP_HEADLESS`: the agent runs under a headless `alas-host`,
    /// which has no UI, so screen-bound tools are hidden.
    pub headless: bool,
    /// Set by `alas mcp --visual-only` or `--remote`: the backend of the
    /// remote-session relay, which lists and accepts only that relay's tools,
    /// whatever the other restrictions say.
    pub relay: Option<RelayScope>,
    /// "stdio" or "http"; tags every request this server dispatches.
    pub transport: &'static str,
}

/// The tools an SSH session's relay backend exposes. Alas picks `Remote` only
/// when the remote helper waits long enough for `pr_create` to finish.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum RelayScope {
    /// `visual_show` only.
    Visual,
    /// `visual_show`, `pr_create`, and `pr_status`.
    Remote,
}

impl McpEnv {
    fn tool_scope(&self) -> ToolScope {
        if let Some(relay) = self.relay {
            match relay {
                RelayScope::Visual => ToolScope::Visual,
                RelayScope::Remote => ToolScope::Remote,
            }
        } else if self.headless {
            ToolScope::Headless
        } else if self.workspace_only {
            ToolScope::Workspace
        } else {
            ToolScope::All
        }
    }
}

/// Which tools a server lists and accepts.
#[derive(Clone, Copy, Debug, PartialEq)]
enum ToolScope {
    All,
    /// Workspace Checkout sessions: read-only workspace, preview, and visual tools.
    Workspace,
    /// The remote-session bridge behind an older helper: `visual_show` only.
    Visual,
    /// The remote-session bridge: `visual_show` and the PR shepherd tools.
    Remote,
    /// A headless `alas-host`: everything except screen-bound tools.
    Headless,
}

impl ToolScope {
    fn allows(self, name: &str) -> bool {
        match self {
            ToolScope::All => true,
            ToolScope::Workspace => is_workspace_tool(name),
            ToolScope::Visual => name == "visual_show",
            ToolScope::Remote => matches!(name, "visual_show" | "pr_create" | "pr_status"),
            ToolScope::Headless => !is_headless_hidden(name),
        }
    }

    /// The error for a call outside the scope, before anything is dispatched.
    fn rejection(self, name: &str) -> (i64, String) {
        match self {
            ToolScope::Workspace => (
                -32602,
                format!("tool unavailable in Workspace Checkout context: {name}"),
            ),
            ToolScope::Headless => (
                -32602,
                format!("Not available on a headless host: {name}"),
            ),
            ToolScope::All | ToolScope::Visual | ToolScope::Remote => (-32602, format!("unknown tool: {name}")),
        }
    }
}

impl Clone for McpEnv {
    fn clone(&self) -> Self {
        Self {
            socket: self.socket.clone(),
            worktree_dir: self.worktree_dir.clone(),
            session_id: self.session_id.clone(),
            parent_session_id: self.parent_session_id.clone(),
            workspace_only: self.workspace_only,
            headless: self.headless,
            relay: self.relay,
            transport: self.transport,
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
        headless: get("ALAS_MCP_HEADLESS")
            .map(|value| value == "1" || value.eq_ignore_ascii_case("true"))
            .unwrap_or(false),
        relay: None,
        transport: "stdio",
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
    handle_line_with_parent(line, worktree_dir, None, ToolScope::All, dispatch)
}

fn handle_line_with_parent(
    line: &str,
    worktree_dir: &str,
    parent_session_id: Option<&str>,
    scope: ToolScope,
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
        "initialize" => Ok(initialize_result(parent_session_id, scope)),
        "ping" => Ok(json!({})),
        "tools/list" => Ok(json!({
            "tools": tool_definitions_for_session(scope, parent_session_id.is_some())
        })),
        "tools/call" => {
            let params = msg.get("params").cloned().unwrap_or(Value::Null);
            call_tool(&params, worktree_dir, scope, &mut dispatch)
        }
        other => Err((-32601, format!("method not found: {other}"))),
    };
    Some(match reply {
        Ok(result) => json!({ "jsonrpc": "2.0", "id": id, "result": result }),
        Err((code, message)) => error_reply(id, code, &message),
    })
}

fn initialize_result(parent_session_id: Option<&str>, scope: ToolScope) -> Value {
    let instructions = match parent_session_id {
        _ if scope == ToolScope::Remote => {
            "Shows visuals to the user in Alas with visual_show, and opens pull requests with pr_create/pr_status. Reach for visual_show when an explanation has shape: how parts connect (architecture, data or control flow, state machines, sequences), options compared on several dimensions, before/after layouts or UI sketches, or numbers that read better as a chart. Keep it to one visual per reply, usually none: skip it for short answers, single facts, code edits, status updates, and anything a list or code block already shows clearly. A visual may ask one optional question; the user's answer arrives as their next prompt, so end your turn after showing it. pr_create pushes this worktree's branch, opens its PR/MR, and has Alas watch it until it merges; offer it when you've finished a change the user will want reviewed, and call it only after the user agrees or asks. pr_status reports that PR/MR."
        }
        _ if scope == ToolScope::Visual => {
            "Shows visuals to the user in Alas with visual_show. Reach for it when an explanation has shape: how parts connect (architecture, data or control flow, state machines, sequences), options compared on several dimensions, before/after layouts or UI sketches, or numbers that read better as a chart. Keep it to one visual per reply, usually none: skip it for short answers, single facts, code edits, status updates, and anything a list or code block already shows clearly. A visual may ask one optional question; the user's answer arrives as their next prompt, so end your turn after showing it."
        }
        Some(_) if scope == ToolScope::Headless => {
            "Tools that drive the user's Alas host. This session was delegated by a parent session: it cannot create descendants. Report results and questions to the parent only with this server's session_send tool; do not use SendMessage, ListAgents, or any other messaging or agent tool for that."
        }
        Some(_) => {
            "Tools that drive the user's Alas workspace UI. This session was delegated by a parent session: it cannot create descendants. Report results and questions to the parent only with this server's session_send tool; do not use SendMessage, ListAgents, or any other messaging or agent tool for that."
        }
        None if scope == ToolScope::Headless => {
            "Tools that drive the user's Alas host: manage linked worktrees and reviews. Root ACP sessions may delegate direct child sessions: call agent_list first to pick an available agent id (and see its remembered models), then session_new. Use visual_show when an explanation has shape (architecture, flows, multi-dimension comparisons, layouts, charts); keep it to one visual per reply, usually none."
        }
        None => {
            "Tools that drive the user's Alas workspace UI: open files for the user to look at, manage linked worktrees, and open reviews. Root ACP sessions may delegate direct child sessions: call agent_list first to pick an available agent id (and see its remembered models), then session_new. Use visual_show when an explanation has shape (architecture, flows, multi-dimension comparisons, layouts, charts); keep it to one visual per reply, usually none."
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

/// The agent-facing tools. Most mirror a CLI command; `visual_show` is
/// MCP-only because a terminal caller has no transcript to show it in.
/// Descriptions make explicit that these act on the user's Alas UI — that is
/// what makes the agent-side permission prompt legible. `resolve` is internal
/// and not exposed.
pub fn tool_definitions() -> Vec<Value> {
    tool_definitions_for_mode(ToolScope::All)
}

fn tool_definitions_for_mode(scope: ToolScope) -> Vec<Value> {
    all_tool_definitions()
        .into_iter()
        .filter(|tool| {
            tool.get("name")
                .and_then(Value::as_str)
                .is_some_and(|name| scope.allows(name))
        })
        .collect()
}

/// Tools that only act on a session's own children.
const CHILD_ONLY_TOOLS: [&str; 3] = ["session_new", "session_wait", "session_interrupt"];

/// Delegated children are leaves: tools that act on children are left out
/// of their discovery. Direct or forged calls still reach Alas, whose
/// orchestration policy rejects them.
fn tool_definitions_for_session(scope: ToolScope, is_delegated: bool) -> Vec<Value> {
    let tools = tool_definitions_for_mode(scope);
    if !is_delegated {
        return tools;
    }
    tools
        .into_iter()
        .filter(|tool| {
            tool.get("name")
                .and_then(Value::as_str)
                .is_none_or(|name| !CHILD_ONLY_TOOLS.contains(&name))
        })
        .collect()
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
            "name": "visual_show",
            "description": "Show the user an HTML visual inline in their Alas transcript. Reach for it when an explanation has shape: how parts connect (architecture, data or control flow, state machines, sequences), options compared on several dimensions, before/after layouts or UI sketches, or numbers that read better as a chart. Keep it to one visual per reply, usually none: answer in text for short answers, single facts, code edits, status updates, and anything a list or code block already shows clearly. `presentation`: \"embedded\" (default) draws the page with no frame as part of your reply, on the transcript background at the width of your reply text; \"card\" puts it in a titled frame, better for UI prototypes and mockups to inspect. A visual with `question` is always a card. For embedded pages leave html, body and the outermost element without background, border, padding or a banner title; boxes that need a fill use var(--alas-card) with at least 12px padding and var(--alas-radius) corners, borders use var(--alas-border), highlights var(--alas-accent). Use these variables for every colour and font so the page follows the user's theme: --alas-text, --alas-dim, --alas-muted, --alas-accent, --alas-accent-soft, --alas-card, --alas-border, --alas-line, --alas-background, --alas-tone-info/success/warning/danger, --alas-chart-1 to 6, --alas-radius, --alas-font-sans, --alas-font-mono, --alas-font-size. Give charts fixed pixel heights, never 100vh. `html` may be a fragment, which Alas wraps in a themed frame providing these classes: options/option (with letter and content children) for A/B/C choices, cards/card/card-image/card-body, mockup/mockup-header/mockup-body, split (side by side), pros-cons/pros/cons, mock-nav, mock-sidebar, mock-content, mock-button, mock-input, placeholder, subtitle, section, label. A document starting with <!DOCTYPE or <html is used as is. Scripts, styles, fonts and images may load from https CDNs; fetch, XHR and WebSockets are blocked. To ask the user to pick, pass `question` and put data-choice=\"<option id>\" on the matching elements: clicking one selects that option on a native card under the visual. The tool returns at once; the user's answer, if any, arrives as their next message, so end your turn after asking.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "title": { "type": "string", "minLength": 1, "maxLength": 120, "description": "Short title shown above the visual." },
                    "html": { "type": "string", "minLength": 1, "description": "HTML fragment or full document. Must contain non-whitespace; at most 512 KiB (524288 bytes) of UTF-8." },
                    "question": {
                        "type": "object",
                        "description": "Optional single question answered from a native card.",
                        "properties": {
                            "prompt": { "type": "string", "minLength": 1, "maxLength": 500 },
                            "options": {
                                "type": "array",
                                "description": "Option ids must be unique.",
                                "minItems": 2,
                                "maxItems": 8,
                                "items": {
                                    "type": "object",
                                    "properties": {
                                        "id": { "type": "string", "pattern": "^[A-Za-z0-9_-]{1,64}$" },
                                        "label": { "type": "string", "minLength": 1, "maxLength": 200 }
                                    },
                                    "required": ["id", "label"]
                                }
                            },
                            "allow_multiple": { "type": "boolean" }
                        },
                        "required": ["prompt", "options"]
                    },
                    "presentation": { "type": "string", "enum": ["embedded", "card"], "description": "Default: embedded. Ignored when question is set (always a card)." }
                },
                "required": ["title", "html"]
            }
        }),
        json!({
            "name": "agent_list",
            "description": "Read-only: list the ACP agents this session could delegate to with session_new. Returns versioned JSON with each agent's id, display name, availability, model-selection support, and remembered model catalog state. Only agents with available=true are valid session_new targets. Never starts a session or model request.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "worktree": { "type": "string", "description": "Optional existing project worktree name or branch you plan to pass to session_new. Defaults to this session's worktree." }
                }
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
                    "agent": { "type": "string", "description": "Optional agent id from agent_list with available=true. Defaults to this session's agent." },
                    "model": { "type": "string", "description": "Optional model id for the child, taken from that agent's agent_list model_catalog. Alas sets it and waits for the agent to acknowledge it before sending the prompt. An id the agent does not offer fails the child instead of falling back to its default model. Omit to keep the agent's default." },
                    "role": { "type": "string", "description": "Optional child role, such as planner, implementer, or reviewer. Shown in Alas and included in the child context." },
                    "reasoning": { "type": "string", "description": "Optional reasoning level (for example low, medium, high) for agents that expose a reasoning config option. Applied before the prompt. Agents without one reject it instead of ignoring it." },
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
            "name": "session_read",
            "description": "Read-only: one page of a direct parent's, child's, or this session's fork transcript, or of a session the user attached to your prompt, as JSON entries (user and agent messages, one-line tool-call summaries; thoughts omitted). Archived forks remain readable. Without offset, returns the latest entries. Pass the returned end as offset to read on.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "session_id": { "type": "string", "description": "Direct parent, child, fork, or attached session id." },
                    "offset": { "type": "integer", "minimum": 0, "description": "First entry index to return. Omit for the latest entries." },
                    "limit": { "type": "integer", "minimum": 1, "maximum": 100, "description": "Maximum entries. Default: 20." },
                    "max_chars": { "type": "integer", "minimum": 1, "maximum": 100000, "description": "Text budget across entries; an entry over it is cut and marked truncated. Default: 8000." }
                },
                "required": ["session_id"]
            }
        }),
        json!({
            "name": "session_search",
            "description": "Read-only: case-insensitive text search across the transcripts of this session's direct parent and children. Returns session id, entry index (usable as session_read offset), role, and a snippet per match.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "query": { "type": "string", "description": "Text to find." },
                    "limit": { "type": "integer", "minimum": 1, "maximum": 100, "description": "Maximum matches. Default: 20." }
                },
                "required": ["query"]
            }
        }),
        json!({
            "name": "session_wait",
            "description": "Wait until every listed direct child has no turn running or queued, or the timeout passes, then return each child's state and latest agent text together. A child blocked on a permission or question counts as settled (state awaiting_input): only the user can answer it. Call again if timed_out is true.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "session_ids": {
                        "type": "array",
                        "items": { "type": "string" },
                        "minItems": 1,
                        "maxItems": 20,
                        "description": "Direct child session ids."
                    },
                    "timeout_ms": { "type": "integer", "minimum": 1, "maximum": 20000, "description": "Default: 20000." }
                },
                "required": ["session_ids"]
            }
        }),
        json!({
            "name": "session_interrupt",
            "description": "Cancel a direct child's running turn, like the user pressing Stop. A pending permission request is cancelled, never approved. Queued prompts stay queued.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "session_id": { "type": "string", "description": "Direct child session id." }
                },
                "required": ["session_id"]
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
            "name": "pr_create",
            "description": "Open a pull/merge request for this worktree's branch and have Alas watch it. Offer this when you've finished a change the user will want reviewed, and call it only after the user agrees or asks. Alas pushes the exact HEAD (never force), creates the PR/MR (or adopts the open one for this branch), and later sends this session a new turn when CI fails, a trusted reviewer leaves a thread, or the branch conflicts with base. Returns JSON with number, url, provider, head_sha, created, uncommitted_changes, and the shepherd's auto_fix/auto_merge settings.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "title": { "type": "string", "description": "PR/MR title, written from the actual diff." },
                    "body": { "type": "string", "description": "PR/MR description, Markdown." },
                    "draft": { "type": "boolean", "description": "Create as a draft. Default: false." },
                    "base": { "type": "string", "description": "Target branch. Default: the worktree's base branch." }
                },
                "required": ["title", "body"]
            }
        }),
        json!({
            "name": "pr_status",
            "description": "Show the pull/merge request Alas watches for this session, else the one for this worktree's branch, as JSON from a fresh provider fetch: state, head_sha, merge_state, check counts with failing checks, actionable threads from trusted reviewers, required reviewers still missing on the current head, and the shepherd's phase and settings. pull_request is null when there is none; shepherd is null when Alas is not watching it. For a gg stack (one this session ships, or the worktree's stack in gg mode) it returns {stack, shepherd} instead: stack has name, base and its entries bottom-up, each with position, entry_id, title, its pull_request in the shape above (null until published) and the shepherd's phase for it; shepherd adds ready_to_land, and restack_needed when an entry landed while the stack still holds it (call stack_ship to rebase it away and publish the rest).",
            "inputSchema": { "type": "object", "properties": {} }
        }),
        json!({
            "name": "stack_ship",
            "description": "The pr_create of a gg stacked-diffs worktree: publish its stack with gg sync, one pull/merge request per entry, and have Alas watch every one of them. Offer this when the stack is ready for review, and call it only after the user agrees or asks; call it again after fixing entries to publish the fixes, and after entries at the bottom land. Run it from the top of the stack (gg last) with the work committed into stack entries. When entries already landed on the base, it first runs gg rebase to drop them, then syncs the rest; if that rebase stops on a conflict, resolve it, run gg continue, and call it again. Alas later sends this session one turn listing every entry with failing CI, threads from trusted reviewers, or conflicts, bottom-up, and one when an entry lands while the stack still holds it. It never lands: the user lands the stack with gg land. Returns JSON with stack, base, provider, entries (position, entry_id, title, number, url, state, draft), uncommitted_changes, restacked (whether it rebased landed entries away first), and the shepherd's auto_fix setting.",
            "inputSchema": { "type": "object", "properties": {} }
        }),
    ];
    tools.extend(preview_tool_definitions());
    tools.extend(computer_tool_definitions());
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

fn computer_tool_definitions() -> Vec<Value> {
    vec![
        json!({
            "name": "computer_apps",
            "description": "List running apps on the user's Mac and their on-screen windows (window_id, title, frame) with each app's approval state. A window with `off_screen: true` is on another Space or workspace: screenshots and refs still work, x/y clicks and scrolls go through accessibility or are refused, and a drag brings it back by activating the app. An app showing a system password prompt has `credential_prompt: true` and no windows: it can't be seen or driven until the user answers the prompt. `credential_prompt: \"unchecked\"` means a prompt may be showing and the app wasn't checked in time; its windows are left out too. computer_open_app on that app checks it alone and lists its windows when no prompt shows. Does not need approval.",
            "annotations": { "readOnlyHint": true },
            "inputSchema": { "type": "object", "properties": {} }
        }),
        json!({
            "name": "computer_screenshot",
            "description": "Capture a PNG screenshot of one on-screen window by window_id (long edge at most 1280 px). Returns native MCP image content plus JSON metadata, including `scale` (image pixels per screen point). Its pixel coordinates hold for the current turn only: after a stop, a resume or a new turn, take a fresh screenshot before using x/y. The first use of each app asks the user for approval.",
            "annotations": { "readOnlyHint": true },
            "inputSchema": {
                "type": "object",
                "properties": {
                    "window_id": { "type": "integer", "minimum": 0, "maximum": 4294967295u64, "description": "A window_id from computer_apps." }
                },
                "required": ["window_id"]
            }
        }),
        json!({
            "name": "computer_inspect",
            "description": "Read a window's Accessibility tree as numbered elements (ref, role, title, value, frame). Use `query` to filter (a query searches 32 levels unless max_depth is given) and `limit`/`max_depth` to bound the result. Prefer this over screenshots. Refs hold for the current turn only: after a stop, a resume or a new turn, inspect again before using them. The first use of each app asks the user for approval.",
            "annotations": { "readOnlyHint": true },
            "inputSchema": {
                "type": "object",
                "properties": {
                    "window_id": { "type": "integer", "minimum": 0, "maximum": 4294967295u64, "description": "A window_id from computer_apps." },
                    "query": { "type": "string", "maxLength": 256, "description": "Optional text filter on element role, title and value." },
                    "limit": { "type": "integer", "minimum": 1, "maximum": 3000, "description": "Maximum elements returned. Default: 300." },
                    "max_depth": { "type": "integer", "minimum": 1, "maximum": 32, "description": "Maximum tree depth, at most 32. Default: 12, or 32 when query is given." }
                },
                "required": ["window_id"]
            }
        }),
        json!({
            "name": "computer_click",
            "description": "Click an element or a point in a window. Target it with `ref` (an element ref from the latest computer_inspect or computer_wait of this window) or with `x` and `y` (pixels in the latest computer_screenshot of this window). Returns the window's new elements (refs are replaced). Works in the background without moving the user's cursor or changing the user's focus, though it may change which of the target app's windows is key; `delivery: \"direct\"` briefly activates the app instead. The first use of each app asks the user for approval.",
            "annotations": { "readOnlyHint": false, "destructiveHint": true },
            "inputSchema": computer_action_schema(
                json!({
                    "ref": computer_ref_property("The element to click."),
                    "x": computer_pixel_property("Pixels from the left edge of the latest screenshot. Use with y, instead of ref."),
                    "y": computer_pixel_property("Pixels from the top edge of the latest screenshot. Use with x, instead of ref."),
                    "button": { "type": "string", "enum": ["left", "right"], "description": "Default: left." },
                    "count": { "type": "integer", "minimum": 1, "maximum": 2, "description": "2 double-clicks. Default: 1." },
                    "delivery": computer_delivery_property()
                }),
                &[]
            )
        }),
        json!({
            "name": "computer_type",
            "description": "Type text into a window. With `ref` (from the latest computer_inspect or computer_wait of this window) the element is focused first; `mode: \"replace\"` (needs ref) sets the element's whole value. Without ref the text goes to the focused element. Returns the window's new elements (refs are replaced). Works in the background; `delivery: \"direct\"` briefly activates the app and pastes the text in one step when the user's clipboard is empty or holds only plain text (the check that the user isn't using the app then runs once, before it); otherwise it types the text, checking for the user between chunks, and may stop part-way, reporting how much was typed (\"stopped after typing N of M characters\"). The first use of each app asks the user for approval.",
            "annotations": { "readOnlyHint": false, "destructiveHint": true },
            "inputSchema": computer_action_schema(
                json!({
                    "text": { "type": "string", "minLength": 1, "maxLength": 10000, "description": "The text to type (at most 40000 UTF-8 bytes)." },
                    "ref": computer_ref_property("The element to focus and type into."),
                    "mode": { "type": "string", "enum": ["insert", "replace"], "description": "replace sets the element's whole value and needs ref. Default: insert." },
                    "delivery": computer_delivery_property()
                }),
                &["text"]
            )
        }),
        json!({
            "name": "computer_key",
            "description": "Press a key or chord in a window, such as `return`, `cmd+s` or `shift+tab`. Keys go to the window's app, not to the user's focused app. A bare `escape` or `return` on a window with a sheet or dialog presses its cancel or default button (the result's `button` names it). Returns the window's new elements (refs are replaced). The first use of each app asks the user for approval.",
            "annotations": { "readOnlyHint": false, "destructiveHint": true },
            "inputSchema": computer_action_schema(
                json!({
                    "keys": { "type": "string", "minLength": 1, "maxLength": 64, "description": "A key or chord, for example `cmd+shift+p`." },
                    "delivery": computer_delivery_property()
                }),
                &["keys"]
            )
        }),
        json!({
            "name": "computer_scroll",
            "description": "Scroll at an element or a point in a window. Target it with `ref` (from the latest computer_inspect or computer_wait of this window) or with `x` and `y` (pixels in the latest computer_screenshot of this window). `dx` and `dy` are scroll-wheel lines, at most 100 each: positive dy scrolls down, positive dx scrolls right. Returns the window's new elements (refs are replaced). The first use of each app asks the user for approval.",
            "annotations": { "readOnlyHint": false, "destructiveHint": true },
            "inputSchema": computer_action_schema(
                json!({
                    "ref": computer_ref_property("The element to scroll over."),
                    "x": computer_pixel_property("Pixels from the left edge of the latest screenshot. Use with y, instead of ref."),
                    "y": computer_pixel_property("Pixels from the top edge of the latest screenshot. Use with x, instead of ref."),
                    "dx": { "type": "integer", "minimum": -100, "maximum": 100, "description": "Horizontal lines. Default: 0." },
                    "dy": { "type": "integer", "minimum": -100, "maximum": 100, "description": "Vertical lines. Default: 0. dx and dy are not both 0." },
                    "delivery": computer_delivery_property()
                }),
                &[]
            )
        }),
        json!({
            "name": "computer_drag",
            "description": "Drag from one element or point to another in a window, or into another window with `to_window_id`. Each end is a `ref` (from the latest computer_inspect or computer_wait of its window) or an `x`+`y` pair (pixels in the latest computer_screenshot of its window); the start uses ref/x/y in window_id, the end uses to_ref/to_x/to_y in to_window_id (default: window_id). to_window_id must be another window of the same app; dragging between apps is refused. Drags inside one window stay in the app in the background when they can (sliders, canvases, splitters). Drags that go to the front briefly bring the app forward and move the real cursor, and are refused while the user is typing or using the mouse: drags into another window, drags that start on a list or table item (a file or a row), drags in Chrome and other Chromium or Electron apps, drags in a window that's off screen or on another space, drags with delivery \"direct\", and a background drag that starts a file-style drag and drop. A drag that goes to the front needs its drop point visible: when another window covers it, the drag is cancelled in place with an error. Returns the start window's new elements (refs are replaced) and the drop window's under `to_window`. The first use of each app asks the user for approval.",
            "annotations": { "readOnlyHint": false, "destructiveHint": true },
            "inputSchema": computer_action_schema(
                json!({
                    "ref": computer_ref_property("The element to start the drag on."),
                    "x": computer_pixel_property("Start pixels from the left edge of the latest screenshot. Use with y, instead of ref."),
                    "y": computer_pixel_property("Start pixels from the top edge of the latest screenshot. Use with x, instead of ref."),
                    "to_window_id": { "type": "integer", "minimum": 0, "maximum": 4294967295u64, "description": "Another window of the same app to drop into, a window_id from computer_apps. Default: window_id." },
                    "to_ref": computer_ref_property("The element to drop on."),
                    "to_x": computer_pixel_property("End pixels from the left edge of the latest screenshot. Use with to_y, instead of to_ref."),
                    "to_y": computer_pixel_property("End pixels from the top edge of the latest screenshot. Use with to_x, instead of to_ref."),
                    "delivery": computer_delivery_property()
                }),
                &[]
            )
        }),
        json!({
            "name": "computer_open_app",
            "description": "Launch or unhide an app without bringing it to the front, then wait for its window. Give exactly one of `name` or `bundle_id`. Returns the app and its windows like computer_apps, so you can pick a window_id for computer_screenshot and computer_inspect. Asks the user for approval for that app before launching.",
            "annotations": { "readOnlyHint": false, "destructiveHint": true },
            "inputSchema": {
                "type": "object",
                "properties": {
                    "name": { "type": "string", "maxLength": 256, "description": "The app's name, such as `TextEdit`. Use instead of bundle_id." },
                    "bundle_id": { "type": "string", "maxLength": 256, "description": "The app's bundle identifier, such as `com.apple.TextEdit`. Use instead of name." }
                }
            }
        }),
        json!({
            "name": "computer_wait",
            "description": "Wait until an element matching `query` (on role, title and value) appears in or disappears from a window, then return the window's elements as computer_inspect does (refs are replaced). Times out with an error. The first use of each app asks the user for approval.",
            "annotations": { "readOnlyHint": false, "destructiveHint": true },
            "inputSchema": {
                "type": "object",
                "properties": {
                    "window_id": { "type": "integer", "minimum": 0, "maximum": 4294967295u64, "description": "A window_id from computer_apps." },
                    "query": { "type": "string", "minLength": 1, "maxLength": 256, "description": "Text to look for in element role, title and value." },
                    "condition": { "type": "string", "enum": ["appear", "disappear"], "description": "Default: appear." },
                    "timeout_ms": { "type": "integer", "minimum": 100, "maximum": 20000, "description": "Default: 5000." },
                    "limit": { "type": "integer", "minimum": 1, "maximum": 3000, "description": "Maximum elements returned. Default: 100." }
                },
                "required": ["window_id", "query"]
            }
        }),
    ]
}

/// The input schema shared by the actions that operate a window and return a
/// fresh read of it.
fn computer_action_schema(extra: Value, required: &[&str]) -> Value {
    let mut properties = serde_json::Map::new();
    properties.insert(
        "window_id".into(),
        json!({ "type": "integer", "minimum": 0, "maximum": 4294967295u64, "description": "A window_id from computer_apps." }),
    );
    if let Value::Object(extra) = extra {
        properties.extend(extra);
    }
    properties.insert(
        "query".into(),
        json!({ "type": "string", "maxLength": 256, "description": "Optional text filter on the returned elements' role, title and value." }),
    );
    properties.insert(
        "limit".into(),
        json!({ "type": "integer", "minimum": 1, "maximum": 3000, "description": "Maximum elements returned. Default: 100." }),
    );
    properties.insert(
        "max_depth".into(),
        json!({ "type": "integer", "minimum": 1, "maximum": 32, "description": "Maximum depth of the returned elements' tree, at most 32. Default: 12, or 32 when query is given." }),
    );
    properties.insert(
        "include_screenshot".into(),
        json!({ "type": "boolean", "description": "Also return a screenshot of the window afterwards. Default: false." }),
    );
    let mut required = required.to_vec();
    required.insert(0, "window_id");
    json!({ "type": "object", "properties": properties, "required": required })
}

fn computer_ref_property(description: &str) -> Value {
    json!({ "type": "string", "pattern": "^e[1-9][0-9]{0,4}$", "description": format!("{description} An element ref such as `e12`.") })
}

fn computer_pixel_property(description: &str) -> Value {
    json!({ "type": "number", "minimum": 0, "maximum": 100000, "description": description })
}

fn computer_delivery_property() -> Value {
    json!({ "type": "string", "enum": ["background", "direct"], "description": "background posts to the app without touching the user's focus; it may change the target app's key window, and activates the app briefly when that window can't be made key. direct briefly activates the app and is refused while the user is active. Default: background. The result's `delivery` reports how the input went: ax, background or activation." })
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

fn is_headless_hidden(name: &str) -> bool {
    name.starts_with("workspace_")
        || name.starts_with("preview_")
        || name.starts_with("computer_")
        || matches!(name, "open" | "worktree_switch")
}

fn is_workspace_tool(name: &str) -> bool {
    name.starts_with("workspace_")
        || name.starts_with("preview_")
        || matches!(name, "session_read" | "visual_show")
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
        "agent_list" => Ok(Command::AgentList {
            worktree: optional_non_blank_string(args, "worktree")?,
        }),
        "session_list" => Ok(Command::SessionList),
        "session_new" => {
            let worktree = optional_non_blank_string(args, "worktree")?;
            let agent = optional_non_blank_string(args, "agent")?;
            let model = optional_non_blank_string(args, "model")?;
            let reasoning = optional_non_blank_string(args, "reasoning")?;
            let role = optional_non_blank_string(args, "role")?;
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
                model,
                reasoning,
                role,
            })
        }
        "visual_show" => visual_show_command(args),
        "session_send" => Ok(Command::SessionSend {
            session_id: required_string(args, "session_id")?,
            prompt: required_string(args, "prompt")?,
        }),
        "session_read" => Ok(Command::SessionRead {
            session_id: required_non_blank_string(args, "session_id")?,
            offset: optional_bounded_u64(args, "offset", 0, u64::MAX)?,
            limit: optional_bounded_u64(args, "limit", 1, 100)?,
            max_chars: optional_bounded_u64(args, "max_chars", 1, 100_000)?,
        }),
        "session_search" => Ok(Command::SessionSearch {
            query: required_non_blank_string(args, "query")?,
            limit: optional_bounded_u64(args, "limit", 1, 100)?,
        }),
        "session_wait" => {
            let ids = args
                .get("session_ids")
                .and_then(Value::as_array)
                .filter(|ids| (1..=20).contains(&ids.len()))
                .ok_or("session_wait requires a 'session_ids' array of 1 to 20 ids")?;
            let session_ids = ids
                .iter()
                .map(|id| {
                    id.as_str()
                        .map(str::trim)
                        .filter(|id| !id.is_empty())
                        .map(str::to_string)
                        .ok_or_else(|| {
                            "session_wait 'session_ids' must be non-empty strings".to_string()
                        })
                })
                .collect::<Result<Vec<_>, String>>()?;
            Ok(Command::SessionWait {
                session_ids,
                timeout_ms: optional_bounded_u64(args, "timeout_ms", 1, 20_000)?,
            })
        }
        "session_interrupt" => Ok(Command::SessionInterrupt {
            session_id: required_non_blank_string(args, "session_id")?,
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
        "pr_create" => Ok(Command::PrCreate {
            title: required_string(args, "title")?,
            body: required_string(args, "body")?,
            draft: optional_bool(args, "draft")?.unwrap_or(false),
            base: match args.get("base") {
                None | Some(Value::Null) | Some(Value::String(_)) => optional_string(args, "base"),
                Some(_) => return Err("base must be a string".into()),
            },
        }),
        "pr_status" => Ok(Command::PrStatus),
        "stack_ship" => Ok(Command::StackShip),
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
        "computer_apps" => {
            reject_arguments(args, name, &[])?;
            Ok(Command::Computer(alas_client::ComputerCommand::Apps {
                call_id: None,
            }))
        }
        "computer_screenshot" => {
            reject_arguments(args, name, &["window_id"])?;
            Ok(Command::Computer(
                alas_client::ComputerCommand::Screenshot {
                    window_id: required_window_id(args)?,
                    call_id: None,
                },
            ))
        }
        "computer_inspect" => {
            reject_arguments(args, name, &["window_id", "query", "limit", "max_depth"])?;
            let query = optional_limited_string(args, "query", 256)?;
            // A query searches as deep as a read may go, as on input actions.
            let default_depth = if query.is_some() { 32 } else { 12 };
            Ok(Command::Computer(alas_client::ComputerCommand::Inspect {
                window_id: required_window_id(args)?,
                limit: optional_bounded_u64(args, "limit", 1, 3000)?.unwrap_or(300),
                max_depth: optional_bounded_u64(args, "max_depth", 1, 32)?.unwrap_or(default_depth),
                query,
                call_id: None,
            }))
        }
        "computer_click" => {
            reject_arguments(
                args,
                name,
                &[
                    "window_id",
                    "ref",
                    "x",
                    "y",
                    "button",
                    "count",
                    "delivery",
                    "query",
                    "limit",
                    "max_depth",
                    "include_screenshot",
                ],
            )?;
            let button = optional_enum(args, "button", &["left", "right"])?.unwrap_or("left");
            Ok(Command::Computer(alas_client::ComputerCommand::Click {
                window_id: required_window_id(args)?,
                target: computer_target(args, "ref", "x", "y")?,
                button: button.into(),
                count: optional_bounded_u64(args, "count", 1, 2)?.unwrap_or(1),
                direct: computer_direct(args)?,
                post: computer_post(args)?,
                call_id: None,
            }))
        }
        "computer_type" => {
            reject_arguments(
                args,
                name,
                &[
                    "window_id",
                    "text",
                    "ref",
                    "mode",
                    "delivery",
                    "query",
                    "limit",
                    "max_depth",
                    "include_screenshot",
                ],
            )?;
            let element = optional_computer_ref(args, "ref")?;
            let replace = optional_enum(args, "mode", &["insert", "replace"])? == Some("replace");
            if replace && element.is_none() {
                return Err("mode replace needs a ref".into());
            }
            Ok(Command::Computer(alas_client::ComputerCommand::Type {
                window_id: required_window_id(args)?,
                text: required_computer_text(args)?,
                element,
                replace,
                direct: computer_direct(args)?,
                post: computer_post(args)?,
                call_id: None,
            }))
        }
        "computer_key" => {
            reject_arguments(
                args,
                name,
                &[
                    "window_id",
                    "keys",
                    "delivery",
                    "query",
                    "limit",
                    "max_depth",
                    "include_screenshot",
                ],
            )?;
            let keys = match args.get("keys") {
                Some(Value::String(keys)) if !keys.trim().is_empty() && keys.len() <= 64 => {
                    keys.clone()
                }
                _ => return Err("keys must be a non-blank string of at most 64 bytes".into()),
            };
            Ok(Command::Computer(alas_client::ComputerCommand::Key {
                window_id: required_window_id(args)?,
                keys,
                direct: computer_direct(args)?,
                post: computer_post(args)?,
                call_id: None,
            }))
        }
        "computer_scroll" => {
            reject_arguments(
                args,
                name,
                &[
                    "window_id",
                    "ref",
                    "x",
                    "y",
                    "dx",
                    "dy",
                    "delivery",
                    "query",
                    "limit",
                    "max_depth",
                    "include_screenshot",
                ],
            )?;
            let dx = optional_bounded_i64(args, "dx", -100, 100)?.unwrap_or(0);
            let dy = optional_bounded_i64(args, "dy", -100, 100)?.unwrap_or(0);
            if dx == 0 && dy == 0 {
                return Err("dx and dy must not both be 0".into());
            }
            Ok(Command::Computer(alas_client::ComputerCommand::Scroll {
                window_id: required_window_id(args)?,
                target: computer_target(args, "ref", "x", "y")?,
                dx,
                dy,
                direct: computer_direct(args)?,
                post: computer_post(args)?,
                call_id: None,
            }))
        }
        "computer_drag" => {
            reject_arguments(
                args,
                name,
                &[
                    "window_id",
                    "ref",
                    "x",
                    "y",
                    "to_window_id",
                    "to_ref",
                    "to_x",
                    "to_y",
                    "delivery",
                    "query",
                    "limit",
                    "max_depth",
                    "include_screenshot",
                ],
            )?;
            Ok(Command::Computer(alas_client::ComputerCommand::Drag {
                window_id: required_window_id(args)?,
                from: computer_target(args, "ref", "x", "y")?,
                to_window_id: optional_bounded_u64(args, "to_window_id", 0, u32::MAX.into())?
                    .map(|value| value as u32),
                to: computer_target(args, "to_ref", "to_x", "to_y")?,
                direct: computer_direct(args)?,
                post: computer_post(args)?,
                call_id: None,
            }))
        }
        "computer_open_app" => {
            reject_arguments(args, name, &["name", "bundle_id"])?;
            let app_name = optional_limited_string_raw(args, "name", 256)?;
            let bundle_id = optional_limited_string_raw(args, "bundle_id", 256)?;
            if app_name.is_some() == bundle_id.is_some() {
                return Err("computer_open_app needs exactly one of name or bundle_id".into());
            }
            Ok(Command::Computer(alas_client::ComputerCommand::OpenApp {
                name: app_name,
                bundle_id,
                call_id: None,
            }))
        }
        "computer_wait" => {
            reject_arguments(
                args,
                name,
                &["window_id", "query", "condition", "timeout_ms", "limit"],
            )?;
            let query = optional_limited_string_raw(args, "query", 256)?
                .ok_or_else(|| "query is required".to_string())?;
            Ok(Command::Computer(alas_client::ComputerCommand::Wait {
                window_id: required_window_id(args)?,
                query,
                disappear: optional_enum(args, "condition", &["appear", "disappear"])?
                    == Some("disappear"),
                timeout_ms: optional_bounded_u64(args, "timeout_ms", 100, 20000)?.unwrap_or(5000),
                limit: optional_bounded_u64(args, "limit", 1, 3000)?.unwrap_or(100),
                call_id: None,
            }))
        }
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

const VISUAL_TITLE_MAX_CHARS: usize = 120;
const VISUAL_HTML_MAX_BYTES: usize = 512 * 1024;
const VISUAL_PROMPT_MAX_CHARS: usize = 500;
const VISUAL_OPTION_ID_MAX_CHARS: usize = 64;
const VISUAL_OPTION_LABEL_MAX_CHARS: usize = 200;

fn visual_show_command(args: &Value) -> Result<Command, String> {
    let title = required_string(args, "title")?;
    if title.chars().count() > VISUAL_TITLE_MAX_CHARS {
        return Err(format!("title must be at most {VISUAL_TITLE_MAX_CHARS} characters"));
    }
    // Exact: the HTML reaches the page byte for byte.
    let html = required_exact_string(args, "html")?;
    if html.trim().is_empty() {
        return Err("html must be non-empty".into());
    }
    if html.len() > VISUAL_HTML_MAX_BYTES {
        return Err(format!("html must be at most {VISUAL_HTML_MAX_BYTES} bytes"));
    }
    let question = match args.get("question") {
        None | Some(Value::Null) => None,
        Some(value @ Value::Object(_)) => Some(visual_question(value)?),
        Some(_) => return Err("question must be an object".into()),
    };
    let presentation = match args.get("presentation") {
        None | Some(Value::Null) => None,
        Some(Value::String(value)) if value == "embedded" || value == "card" => Some(value.clone()),
        Some(_) => return Err("presentation must be \"embedded\" or \"card\"".into()),
    };
    Ok(Command::VisualShow { title, html, question, presentation })
}

fn visual_question(value: &Value) -> Result<VisualQuestion, String> {
    let prompt = required_string(value, "prompt")
        .map_err(|_| "question.prompt is required".to_string())?;
    if prompt.chars().count() > VISUAL_PROMPT_MAX_CHARS {
        return Err(format!("question.prompt must be at most {VISUAL_PROMPT_MAX_CHARS} characters"));
    }
    let raw_options = value
        .get("options")
        .and_then(Value::as_array)
        .ok_or("question.options must be an array")?;
    if !(2..=8).contains(&raw_options.len()) {
        return Err("question.options must have 2 to 8 items".into());
    }
    let mut seen = std::collections::HashSet::new();
    let mut options = Vec::with_capacity(raw_options.len());
    for option in raw_options {
        let id = option.get("id").and_then(Value::as_str).unwrap_or_default();
        let valid_id = (1..=VISUAL_OPTION_ID_MAX_CHARS).contains(&id.chars().count())
            && id.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_');
        if !valid_id {
            return Err(format!(
                "question option id '{id}' must be 1 to {VISUAL_OPTION_ID_MAX_CHARS} characters of A-Z, a-z, 0-9, '-' or '_'"
            ));
        }
        if !seen.insert(id.to_string()) {
            return Err(format!("question option id '{id}' is duplicated"));
        }
        let label = option.get("label").and_then(Value::as_str).map(str::trim).unwrap_or_default();
        if !(1..=VISUAL_OPTION_LABEL_MAX_CHARS).contains(&label.chars().count()) {
            return Err(format!(
                "question option '{id}' label must be 1 to {VISUAL_OPTION_LABEL_MAX_CHARS} characters"
            ));
        }
        options.push(VisualOption { id: id.into(), label: label.into() });
    }
    let allow_multiple = match value.get("allow_multiple") {
        None | Some(Value::Null) => false,
        Some(Value::Bool(flag)) => *flag,
        Some(_) => return Err("question.allow_multiple must be a boolean".into()),
    };
    Ok(VisualQuestion { prompt, options, allow_multiple })
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

/// The computer_* tools accept exactly their documented arguments.
fn reject_arguments(args: &Value, tool: &str, allowed: &[&str]) -> Result<(), String> {
    if let Some(object) = args.as_object() {
        if let Some(key) = object.keys().find(|key| !allowed.contains(&key.as_str())) {
            return Err(format!("{tool} does not accept '{key}'"));
        }
    }
    Ok(())
}

fn required_window_id(args: &Value) -> Result<u32, String> {
    args.get("window_id")
        .and_then(Value::as_u64)
        .and_then(|value| u32::try_from(value).ok())
        .ok_or_else(|| "window_id must be an integer from a computer_apps window".to_string())
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

fn optional_bounded_i64(
    args: &Value,
    key: &str,
    min: i64,
    max: i64,
) -> Result<Option<i64>, String> {
    match args.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(value) => value
            .as_i64()
            .filter(|value| *value >= min && *value <= max)
            .map(Some)
            .ok_or_else(|| format!("{key} must be an integer from {min} to {max}")),
    }
}

fn optional_enum<'a>(
    args: &Value,
    key: &str,
    allowed: &[&'a str],
) -> Result<Option<&'a str>, String> {
    match args.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(value)) => allowed
            .iter()
            .copied()
            .find(|candidate| candidate == value)
            .map(Some)
            .ok_or_else(|| format!("{key} must be one of {}", allowed.join(", "))),
        Some(_) => Err(format!("{key} must be one of {}", allowed.join(", "))),
    }
}

/// A non-blank string of at most `max_bytes`, passed on untrimmed like the app reads it.
fn optional_limited_string_raw(
    args: &Value,
    key: &str,
    max_bytes: usize,
) -> Result<Option<String>, String> {
    match args.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(value)) if !value.trim().is_empty() && value.len() <= max_bytes => {
            Ok(Some(value.clone()))
        }
        Some(_) => Err(format!(
            "{key} must be a non-blank string of at most {max_bytes} bytes"
        )),
    }
}

/// An `eN` ref: `^e[1-9][0-9]{0,4}$`.
fn optional_computer_ref(args: &Value, key: &str) -> Result<Option<String>, String> {
    match args.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(value)) => {
            let digits = value.strip_prefix('e').unwrap_or("");
            if (1..=5).contains(&digits.len())
                && digits.bytes().all(|byte| byte.is_ascii_digit())
                && !digits.starts_with('0')
            {
                Ok(Some(value.clone()))
            } else {
                Err(format!("{key} must be an element ref such as e12"))
            }
        }
        Some(_) => Err(format!("{key} must be an element ref such as e12")),
    }
}

/// Exactly one of a ref or an x+y pair, under the given keys.
fn computer_target(
    args: &Value,
    ref_key: &str,
    x_key: &str,
    y_key: &str,
) -> Result<alas_client::ComputerTarget, String> {
    let coordinate = |key: &str| match args.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(_) => required_bounded_f64(args, key, 0.0, 100_000.0).map(Some),
    };
    match (
        optional_computer_ref(args, ref_key)?,
        coordinate(x_key)?,
        coordinate(y_key)?,
    ) {
        (Some(element), None, None) => Ok(alas_client::ComputerTarget::Ref(element)),
        (None, Some(x), Some(y)) => Ok(alas_client::ComputerTarget::Point { x, y }),
        _ => Err(format!(
            "give exactly one target: {ref_key}, or {x_key} and {y_key}"
        )),
    }
}

fn required_computer_text(args: &Value) -> Result<String, String> {
    match args.get("text") {
        Some(Value::String(text))
            if (1..=10000).contains(&text.chars().count()) && text.len() <= 40000 =>
        {
            Ok(text.clone())
        }
        _ => Err("text must be 1 to 10000 characters and at most 40000 bytes".into()),
    }
}

fn computer_direct(args: &Value) -> Result<bool, String> {
    Ok(optional_enum(args, "delivery", &["background", "direct"])? == Some("direct"))
}

fn computer_post(args: &Value) -> Result<alas_client::ComputerPost, String> {
    Ok(alas_client::ComputerPost {
        limit: optional_bounded_u64(args, "limit", 1, 3000)?.unwrap_or(100),
        query: optional_limited_string_raw(args, "query", 256)?,
        max_depth: optional_bounded_u64(args, "max_depth", 1, 32)?,
        include_screenshot: optional_bool(args, "include_screenshot")?.unwrap_or(false),
    })
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
    let mut req = alas_client::build_request(
        command,
        Some(env.session_id.clone()),
        Some(env.worktree_dir.clone()),
    );
    req.mcp_transport = Some(env.transport);
    if publishes(command) {
        alas_client::send_with_timeout(&env.socket, &req, PR_CREATE_READ_TIMEOUT)
    } else if is_computer_call(command) {
        alas_client::send_with_timeout(&env.socket, &req, COMPUTER_READ_TIMEOUT)
    } else {
        alas_client::send(&env.socket, &req)
    }
}

/// `pr_create` checks the branch, pushes it, and opens the PR/MR with
/// `gh`/`glab` before replying; on an SSH worktree each of those runs over
/// ssh, so it gets far longer than the default 30-second reply bound. The
/// remote helper's relay waits slightly longer than this.
const PR_CREATE_READ_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(120);

/// `computer_*` calls may wait on the user's approval prompt the first time
/// an app is used, so they get longer than the default reply bound.
const COMPUTER_READ_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(120);

/// Unknown tools and invalid arguments are JSON-RPC protocol errors
/// (-32602); failures while executing a valid call are tool results with
/// isError:true, per the MCP spec's split between the two.
fn call_tool(
    params: &Value,
    worktree_dir: &str,
    scope: ToolScope,
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
    if !scope.allows(name) {
        return Err(scope.rejection(name));
    }
    let command = command_for_tool(name, &args, worktree_dir).map_err(|msg| (-32602, msg))?;
    Ok(match dispatch(&command) {
        Ok(resp) => tool_result(&command, resp),
        Err(err) => transport_error_result(&command, &err),
    })
}

fn visual_show_result(lines: Option<&[String]>) -> Value {
    let reply = lines
        .and_then(|lines| lines.first())
        .and_then(|line| serde_json::from_str::<Value>(line).ok());
    let visual_id = reply
        .as_ref()
        .and_then(|reply| reply.get("visual_id").and_then(Value::as_str).map(String::from));
    let embedded = reply
        .as_ref()
        .and_then(|reply| reply.get("presentation").and_then(Value::as_str))
        == Some("embedded");
    match visual_id {
        Some(id) if embedded => text_result(
            format!(
                "Shown to the user as visual {id}, above your reply. Don't restate or describe it; reply with only what it doesn't already say."
            ),
            false,
        ),
        Some(id) => text_result(
            format!(
                "Shown to the user as visual {id}. Their selection, if any, arrives as their next message. End your turn unless you have more to show."
            ),
            false,
        ),
        None => text_result("Alas did not confirm the visual.".into(), true),
    }
}

fn tool_result(command: &Command, resp: Response) -> Value {
    if !resp.ok {
        return text_result(resp.error.unwrap_or_else(|| "request failed".into()), true);
    }
    if matches!(command, Command::VisualShow { .. }) {
        return visual_show_result(resp.lines.as_deref());
    }
    if matches!(
        command,
        Command::Preview(alas_client::PreviewCommand::Capture { .. })
    ) || matches!(command, Command::Computer(computer) if computer.includes_screenshot())
    {
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
        Command::PrCreate { .. } | Command::PrStatus | Command::StackShip => "OK".into(),
        Command::AgentList { .. } => "No delegation agents found.".into(),
        Command::SessionList => "No delegated sessions found.".into(),
        Command::SessionNew { .. } => "Delegated session creation accepted.".into(),
        Command::SessionSend { .. } => "Delegated prompt queued.".into(),
        Command::VisualShow { .. } => "Visual shown.".into(),
        Command::SessionRead { .. }
        | Command::SessionSearch { .. }
        | Command::SessionWait { .. }
        | Command::SessionInterrupt { .. } => "OK".into(),
        Command::WorkspaceList => "No Workspace Checkouts found.".into(),
        Command::WorkspaceShow { .. } => "Workspace Checkout shown.".into(),
        Command::WorkspaceSwitch { .. } => "Switched Alas to Workspace Checkout.".into(),
        Command::WorkspaceFocus { .. } => "Focused Workspace Checkout member.".into(),
        Command::Preview(_) => "Preview command completed.".into(),
        Command::Computer(_) => "Computer command completed.".into(),
        Command::WtList | Command::Resolve => "OK".into(),
    }
}

fn transport_error_result(command: &Command, err: &TransportError) -> Value {
    // A publish that was sent but got no reply keeps running in the app, so
    // its push and PR/MRs may still land; never report that as a failure.
    if let Some(tool) = publish_tool(command).filter(|_| matches!(err, TransportError::Io)) {
        return text_result(
            format!("Alas did not reply before the {tool} deadline; the push and PR/MR(s) may still complete. Call pr_status before retrying."),
            true,
        );
    }
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
    scope: ToolScope,
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
    if !scope.allows(name) {
        let (code, message) = scope.rejection(name);
        return Err(error_reply(id, code, &message));
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

/// Calls that can block for seconds in the app. The stdio loop runs them on
/// a worker so it keeps reading other calls and cancellations meanwhile.
fn runs_on_worker(command: &Command) -> bool {
    is_preview_command(command)
        || matches!(command, Command::Computer(_))
        || publishes(command)
        || matches!(command, Command::SessionWait { .. })
}

/// The calls that push and open pull/merge requests, which outlast the
/// default read timeout: the tool name, or None for any other command.
fn publish_tool(command: &Command) -> Option<&'static str> {
    match command {
        Command::PrCreate { .. } => Some("pr_create"),
        Command::StackShip => Some("stack_ship"),
        _ => None,
    }
}

fn publishes(command: &Command) -> bool {
    publish_tool(command).is_some()
}

/// Longest single `session_wait` request sent to the app by a worker.
const SESSION_WAIT_SLICE_MS: u64 = 1_000;

/// Dispatches `command`, running a `session_wait` as a series of short
/// waits so a cancelled request stops within one slice instead of holding a
/// worker until its timeout. Returns None once `still_pending` turns false,
/// for any command: a cancelled computer call still runs to its end in the
/// app's reply, but its result is dropped.
fn dispatch_session_wait(
    env: &McpEnv,
    command: &Command,
    still_pending: impl Fn() -> bool,
) -> Option<Result<Response, TransportError>> {
    let Command::SessionWait {
        session_ids,
        timeout_ms,
    } = command
    else {
        let result = dispatch(env, command);
        return still_pending().then_some(result);
    };
    let deadline =
        std::time::Instant::now() + std::time::Duration::from_millis(timeout_ms.unwrap_or(20_000));
    loop {
        let remaining = deadline
            .saturating_duration_since(std::time::Instant::now())
            .as_millis() as u64;
        let slice = Command::SessionWait {
            session_ids: session_ids.clone(),
            timeout_ms: Some(remaining.clamp(1, SESSION_WAIT_SLICE_MS)),
        };
        let result = dispatch(env, &slice);
        if !still_pending() {
            return None;
        }
        let timed_out = result.as_ref().is_ok_and(session_wait_timed_out);
        if !timed_out || remaining <= SESSION_WAIT_SLICE_MS {
            return Some(result);
        }
    }
}

fn session_wait_timed_out(resp: &Response) -> bool {
    resp.ok
        && resp
            .lines
            .as_ref()
            .and_then(|lines| lines.first())
            .and_then(|line| serde_json::from_str::<Value>(line).ok())
            .and_then(|reply| reply.get("timed_out")?.as_bool())
            .unwrap_or(false)
}

fn is_preview_cancel_command(command: &Command) -> bool {
    matches!(
        command,
        Command::Preview(alas_client::PreviewCommand::Cancel { .. })
    )
}

/// A computer call that may block in the app; its cancel is quick.
fn is_computer_call(command: &Command) -> bool {
    matches!(command, Command::Computer(computer) if !matches!(computer, alas_client::ComputerCommand::Cancel { .. }))
}

/// Process-unique ids for computer calls, so a cancellation can name one.
fn next_computer_call_id() -> String {
    static NEXT: AtomicU64 = AtomicU64::new(1);
    format!(
        "{}-{}",
        std::process::id(),
        NEXT.fetch_add(1, Ordering::Relaxed)
    )
}

/// Records a call a cancellation can reach, first tagging a computer call
/// with a fresh call id. Returns the key to remove once the call finishes.
fn register_pending_call(
    pending: &Mutex<std::collections::HashMap<String, Command>>,
    id: &Value,
    command: &mut Command,
) -> Option<String> {
    if is_computer_call(command) {
        if let Command::Computer(computer) = command {
            computer.set_call_id(next_computer_call_id());
        }
    } else if preview_id_for_cancel(command).is_none()
        && !matches!(command, Command::SessionWait { .. })
    {
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

fn remove_pending_call(
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
    let mut pending = pending.lock().ok()?;
    let command = pending.get(&key).cloned()?;
    // A wait has nothing to cancel in the app: dropping it from `pending`
    // stops its worker at the next slice (see `dispatch_session_wait`).
    if matches!(command, Command::SessionWait { .. }) {
        pending.remove(&key);
        return None;
    }
    // Retired like a wait, so its worker answers nothing (stdio) or the
    // cancellation error (HTTP) instead of a late result.
    if let Command::Computer(computer) = &command {
        let call_id = computer.call_id()?.to_string();
        pending.remove(&key);
        return Some(Command::Computer(alas_client::ComputerCommand::Cancel {
            call_id,
        }));
    }
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
    // The relay backend starts before any agent talks to it, so its startup
    // proves nothing and it stays quiet.
    if env.relay.is_none() {
        alas_client::send_hello(&env.socket, &env.session_id, "stdio");
    }

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
        match tools_call_command(&msg, &env.worktree_dir, env.tool_scope()) {
            Ok(Some((id, mut command))) => {
                if !runs_on_worker(&command) {
                    let result = match dispatch(env, &command) {
                        Ok(resp) => tool_result(&command, resp),
                        Err(err) => transport_error_result(&command, &err),
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
                        "too many concurrent Alas MCP worker calls",
                    ));
                    continue;
                }
                let key = register_pending_call(&runtime.pending, &id, &mut command);
                let env = env.clone();
                let reply_tx = reply_tx.clone();
                let pending = Arc::clone(&runtime.pending);
                let active_workers = Arc::clone(&runtime.active_workers);
                let fallback_id = id.clone();
                let fallback_key = key.clone();
                let worker_reply_tx = reply_tx.clone();
                let spawn = std::thread::Builder::new()
                    .name("alas-mcp-tool-worker".into())
                    .spawn(move || {
                        let still_pending = || {
                            key.as_ref().is_none_or(|key| {
                                pending
                                    .lock()
                                    .map_or(true, |pending| pending.contains_key(key))
                            })
                        };
                        let dispatched = dispatch_session_wait(&env, &command, still_pending);
                        remove_pending_call(&pending, key.as_deref());
                        release_worker(&active_workers);
                        // A cancelled request gets no response.
                        let Some(dispatched) = dispatched else { return };
                        let result = match dispatched {
                            Ok(resp) => tool_result(&command, resp),
                            Err(err) => transport_error_result(&command, &err),
                        };
                        let _ = worker_reply_tx.send(json!({
                            "jsonrpc": "2.0",
                            "id": id,
                            "result": result
                        }));
                    });
                if spawn.is_err() {
                    remove_pending_call(&runtime.pending, fallback_key.as_deref());
                    release_worker(&runtime.active_workers);
                    let _ = reply_tx.send(error_reply(
                        fallback_id,
                        -32000,
                        "could not start tool worker",
                    ));
                }
            }
            Ok(None) => {
                if let Some(reply) = handle_line_with_parent(
                    &line,
                    &env.worktree_dir,
                    env.parent_session_id.as_deref(),
                    env.tool_scope(),
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

/// Options for `alas mcp --http`.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct HttpOptions {
    /// Bind this exact port instead of an ephemeral one. Used when the app
    /// respawns a session's server so an adopted agent's URL keeps working.
    pub port: Option<u16>,
    /// Exit once stdin reaches EOF, i.e. when the parent holding the pipe dies.
    pub exit_with_parent: bool,
}

/// Set once the first authenticated HTTP request has announced this process.
static HTTP_HELLO_SENT: AtomicBool = AtomicBool::new(false);

/// HTTP transport for the same MCP server as `serve`. Binds a localhost port
/// (ephemeral unless `options.port` is set), prints `PORT <n>` on stdout so
/// the app can wire up `http://localhost:<n>/mcp`, and requires a bearer
/// token matching `ALAS_MCP_HTTP_TOKEN` on every request.
pub fn serve_http(env: &McpEnv, options: &HttpOptions) -> std::io::Result<()> {
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
    // A failed bind returns before `PORT` is printed, so the caller sees EOF.
    let v4_listener = TcpListener::bind(("127.0.0.1", options.port.unwrap_or(0)))?;
    let port = v4_listener.local_addr()?.port();

    // Best-effort: a missing or busy IPv6 loopback must not sink the server.
    let v6_listener = match TcpListener::bind(("::1", port)) {
        Ok(listener) => Some(listener),
        Err(err) => {
            eprintln!("alas: mcp http ipv6 bind failed on port {port}: {err}");
            None
        }
    };

    if options.exit_with_parent {
        // The parent holds the write end of our stdin pipe; EOF (or a read
        // error) means it is gone, so take the server down with it.
        std::thread::Builder::new()
            .name("alas-mcp-http-parent-watch".into())
            .spawn(|| {
                use std::io::Read;
                let mut stdin = std::io::stdin();
                let mut buf = [0u8; 1024];
                while matches!(stdin.read(&mut buf), Ok(n) if n > 0) {}
                std::process::exit(0);
            })?;
    }

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

    // A 512 KiB `visual_show` html argument can grow several-fold under JSON
    // escaping; 4 MiB keeps every schema-valid call transportable.
    const MAX_REQUEST_BYTES: usize = 4 * 1024 * 1024;
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

/// Claims the once-per-process HTTP hello; true only for the first caller.
fn claim_http_hello() -> bool {
    !HTTP_HELLO_SENT.swap(true, Ordering::SeqCst)
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

    // Announce on the first authenticated request of any method — a server
    // respawned on its old port serves an already-initialized client that may
    // only ever send `tools/call` — and again on every `initialize`: the
    // supervisor reuses the process across ACP reattaches while the app clears
    // its registration per attach, so a reconnecting harness must re-announce.
    let first_request = claim_http_hello();
    if env.relay.is_none() && (first_request || is_initialize_message(&req.body)) {
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
        match tools_call_command(&msg, &env.worktree_dir, env.tool_scope()) {
            Ok(Some((id, mut command))) if runs_on_worker(&command) => {
                let limit = if is_preview_cancel_command(&command) {
                    MAX_MCP_WORKERS
                } else {
                    MAX_MCP_PREVIEW_CALLS
                };
                if !try_reserve_worker(&runtime.active_workers, limit) {
                    return http_response(
                        200,
                        "application/json",
                        &error_reply(id, -32000, "too many concurrent Alas MCP worker calls")
                            .to_string(),
                    );
                }
                let key = register_pending_call(&runtime.pending, &id, &mut command);
                let still_pending = || {
                    key.as_ref().is_none_or(|key| {
                        runtime
                            .pending
                            .lock()
                            .map_or(true, |pending| pending.contains_key(key))
                    })
                };
                let dispatched = dispatch_session_wait(env, &command, still_pending);
                remove_pending_call(&runtime.pending, key.as_deref());
                release_worker(&runtime.active_workers);
                // An HTTP request still needs a reply once its wait is cancelled.
                let Some(dispatched) = dispatched else {
                    let reply = error_reply(id, -32800, "request cancelled");
                    return http_response(200, "application/json", &reply.to_string());
                };
                let result = match dispatched {
                    Ok(resp) => tool_result(&command, resp),
                    Err(err) => transport_error_result(&command, &err),
                };
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
        env.tool_scope(),
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
        CHILD_ONLY_TOOLS, HttpRequest, McpEnv, McpRuntime, PROTOCOL_VERSION, RelayScope, ToolScope,
        build_http_response, cancellation_command_for_message, command_for_tool, dispatch,
        env_from, handle_line, handle_line_with_parent, http_response, initialize_result,
        parse_http_request, register_pending_call, runs_on_worker, session_wait_timed_out,
        tool_definitions, tool_definitions_for_session, tool_result, tools_call_command, transport_error_result,
    };
    use alas_client::{Command, Response, TransportError, VisualOption, VisualQuestion};
    use serde_json::{Value, json};

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
    fn headless_scope_hides_screen_bound_tools() {
        let env = env_from(env(&[
            ("ALAS_SOCKET_PATH", "/s"),
            ("ALAS_WORKTREE_DIR", "/wt"),
            ("ALAS_SESSION_ID", "s1"),
            ("ALAS_MCP_HEADLESS", "1"),
        ]))
        .unwrap();
        let scope = env.tool_scope();
        assert_eq!(scope, ToolScope::Headless);
        let listed = tool_definitions_for_session(scope, false);
        let names: Vec<&str> = listed.iter().map(|t| t["name"].as_str().unwrap()).collect();
        for hidden in [
            "open",
            "preview_list",
            "computer_apps",
            "worktree_switch",
            "workspace_list",
            "workspace_focus",
        ] {
            assert!(!names.contains(&hidden), "{hidden}");
            let reply = handle_line_with_parent(&call(hidden, json!({})), "/wt", None, scope, |_| {
                unreachable!()
            })
            .unwrap();
            assert_eq!(
                reply["error"]["message"],
                json!(format!("Not available on a headless host: {hidden}"))
            );
        }
        for kept in [
            "session_new",
            "review",
            "review_comments",
            "visual_show",
            "worktree_new",
            "worktree_delete",
            "notify",
            "pr_create",
        ] {
            assert!(names.contains(&kept), "{kept}");
        }
        // A paired Mac shows the local-changes review, so review tools keep
        // the app's schemas: no target or session is required.
        let review_tools = |tools: Vec<Value>| -> Vec<Value> {
            tools
                .into_iter()
                .filter(|t| t["name"].as_str().is_some_and(|n| n.starts_with("review")))
                .collect()
        };
        assert_eq!(
            review_tools(listed.clone()),
            review_tools(tool_definitions_for_session(ToolScope::All, false))
        );
        for parent in [None, Some("p")] {
            let text = initialize_result(parent, scope)["instructions"].as_str().unwrap().to_string();
            for banned in ["open files", "preview", "workspace_", "workspace UI"] {
                assert!(!text.contains(banned), "{parent:?}: {banned}");
            }
        }
        // A delegated child keeps both filters.
        let child: Vec<String> = tool_definitions_for_session(scope, true)
            .iter()
            .map(|t| t["name"].as_str().unwrap().into())
            .collect();
        assert!(!child.contains(&"session_new".into()) && !child.contains(&"open".into()));
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
    fn delegated_initialize_instructions_route_reports_through_session_send_only() {
        let instructions = initialize_result(Some("parent"), ToolScope::All)["instructions"]
            .as_str()
            .unwrap()
            .to_string();
        assert!(instructions.contains("only with this server's session_send tool"));
        assert!(instructions.contains("do not use SendMessage, ListAgents"));
        let root = initialize_result(None, ToolScope::All)["instructions"]
            .as_str()
            .unwrap()
            .to_string();
        assert!(!root.contains("SendMessage"));
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
    fn visual_show_maps_arguments_and_keeps_html_bytes() {
        let cmd = command_for_tool(
            "visual_show",
            &json!({
                "title": " Layouts ",
                "html": "  <h2>Pick</h2>\n",
                "presentation": "card",
                "question": {
                    "prompt": "Which?",
                    "options": [{ "id": "a", "label": "One" }, { "id": "b", "label": "Two" }],
                    "allow_multiple": true
                }
            }),
            "/wt",
        )
        .unwrap();
        assert_eq!(
            cmd,
            Command::VisualShow {
                title: "Layouts".into(),
                html: "  <h2>Pick</h2>\n".into(),
                question: Some(VisualQuestion {
                    prompt: "Which?".into(),
                    options: vec![
                        VisualOption { id: "a".into(), label: "One".into() },
                        VisualOption { id: "b".into(), label: "Two".into() },
                    ],
                    allow_multiple: true,
                }),
                presentation: Some("card".into()),
            }
        );
        let omitted = command_for_tool("visual_show", &json!({ "title": "T", "html": "<p>" }), "/wt").unwrap();
        assert!(matches!(omitted, Command::VisualShow { presentation: None, .. }));
    }

    #[test]
    fn visual_show_rejects_out_of_contract_arguments() {
        let one = json!([{ "id": "a", "label": "One" }]);
        let duplicate = json!([{ "id": "a", "label": "One" }, { "id": "a", "label": "Two" }]);
        let bad_id = json!([{ "id": "a b", "label": "One" }, { "id": "b", "label": "Two" }]);
        let cases = [
            json!({ "title": "T" }),
            json!({ "title": "T", "html": "   " }),
            json!({ "title": "T", "html": "x".repeat(512 * 1024 + 1) }),
            json!({ "title": "x".repeat(121), "html": "<p>" }),
            json!({ "title": "T", "html": "<p>", "question": { "prompt": "Q", "options": one } }),
            json!({ "title": "T", "html": "<p>", "question": { "prompt": "Q", "options": duplicate } }),
            json!({ "title": "T", "html": "<p>", "question": { "prompt": "Q", "options": bad_id } }),
            json!({ "title": "T", "html": "<p>", "question": "Which?" }),
            json!({ "title": "T", "html": "<p>", "presentation": "banner" }),
            json!({ "title": "T", "html": "<p>", "presentation": 3 }),
        ];
        for args in cases {
            let err = command_for_tool("visual_show", &args, "/wt").expect_err(&format!("accepted {args}"));
            if args.get("presentation").is_some() {
                assert!(err.contains("presentation must be \"embedded\" or \"card\""), "{err}");
            }
        }
    }

    #[test]
    fn visual_show_result_reports_the_visual_id() {
        let old = "Shown to the user as visual ABC. Their selection, if any, arrives as their next message. End your turn unless you have more to show.";
        let embedded = "Shown to the user as visual ABC, above your reply. Don't restate or describe it; reply with only what it doesn't already say.";
        let cases = [
            (r#"{"visual_id":"ABC"}"#, old),
            (r#"{"visual_id":"ABC","presentation":"card"}"#, old),
            (r#"{"visual_id":"ABC","presentation":"embedded"}"#, embedded),
        ];
        for (line, expected) in cases {
            let cmd = Command::VisualShow {
                title: "T".into(),
                html: "<p>".into(),
                question: None,
                presentation: None,
            };
            let result = tool_result(
                &cmd,
                Response { ok: true, lines: Some(vec![line.into()]), error: None, exit_code: None },
            );
            assert_eq!(result["isError"], json!(false));
            assert_eq!(result["content"][0]["text"], json!(expected), "{line}");
        }
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
                "visual_show",
                "agent_list",
                "session_list",
                "session_new",
                "session_send",
                "session_read",
                "session_search",
                "session_wait",
                "session_interrupt",
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
                "pr_create",
                "pr_status",
                "stack_ship",
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
                "computer_apps",
                "computer_screenshot",
                "computer_inspect",
                "computer_click",
                "computer_type",
                "computer_key",
                "computer_scroll",
                "computer_drag",
                "computer_open_app",
                "computer_wait",
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
    fn workspace_mode_allows_fork_reads_and_keeps_project_tools_blocked() {
        let list = handle_line_with_parent(
            r#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#,
            "/checkout",
            None,
            ToolScope::Workspace,
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
                "visual_show",
                "session_read",
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
            ToolScope::Workspace,
            |_| unreachable!(),
        )
        .unwrap();
        assert_eq!(open["error"]["code"], json!(-32602));

        let read = handle_line_with_parent(
            r#"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"session_read","arguments":{"session_id":"fork"}}}"#,
            "/checkout",
            None,
            ToolScope::Workspace,
            |command| {
                assert!(matches!(command, Command::SessionRead { session_id, .. } if session_id == "fork"));
                Ok(Response { ok: true, lines: Some(vec!["{}".into()]), error: None, exit_code: None })
            },
        )
        .unwrap();
        assert!(read.get("error").is_none());
        let send = handle_line_with_parent(
            r#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"session_send","arguments":{"session_id":"fork","prompt":"Run this"}}}"#,
            "/checkout",
            None,
            ToolScope::Workspace,
            |_| unreachable!(),
        )
        .unwrap();
        assert_eq!(send["error"]["code"], json!(-32602));

        let workspace = handle_line_with_parent(
            r#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"workspace_list","arguments":{}}}"#,
            "/checkout",
            None,
            ToolScope::Workspace,
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
            ToolScope::Workspace,
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
            ToolScope::Workspace,
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

        let visual = handle_line_with_parent(
            r#"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"visual_show","arguments":{"title":"Pick","html":"<p>hi</p>"}}}"#,
            "/checkout",
            None,
            ToolScope::Workspace,
            |command| {
                assert!(matches!(command, Command::VisualShow { title, .. } if title == "Pick"));
                Ok(Response {
                    ok: true,
                    lines: Some(vec![r#"{"visual_id":"v1"}"#.into()]),
                    error: None,
                    exit_code: None,
                })
            },
        )
        .unwrap();
        assert!(visual.get("error").is_none());
    }

    #[test]
    fn a_publish_without_a_reply_reports_an_unknown_outcome() {
        let create = Command::PrCreate {
            title: "t".into(),
            body: "b".into(),
            draft: false,
            base: None,
        };
        let text = |command: &Command, err: TransportError| {
            transport_error_result(command, &err)["content"][0]["text"]
                .as_str()
                .unwrap()
                .to_string()
        };
        assert!(text(&create, TransportError::Io).contains("Call pr_status before retrying"));
        assert!(text(&Command::StackShip, TransportError::Io).contains("stack_ship deadline"));
        // Nothing was sent, or the call is read-only: a plain failure.
        assert_eq!(text(&create, TransportError::Connect), "could not reach Alas");
        assert_eq!(text(&Command::StackShip, TransportError::Connect), "could not reach Alas");
        assert_eq!(text(&Command::PrStatus, TransportError::Io), "could not reach Alas");
    }

    #[test]
    fn relay_modes_list_and_accept_only_their_tools() {
        for (relay, allowed) in [
            (RelayScope::Visual, &["visual_show"][..]),
            (RelayScope::Remote, &["pr_create", "pr_status", "visual_show"][..]),
        ] {
            // Workspace and delegated restrictions must not widen a relay mode.
            let env = McpEnv {
                socket: "/tmp/alas-no-such-socket-for-relay-test".into(),
                worktree_dir: "/wt".into(),
                session_id: "s1".into(),
                parent_session_id: Some("parent".into()),
                workspace_only: true,
                headless: false,
                relay: Some(relay),
                transport: "stdio",
            };
            let scope = env.tool_scope();
            let instructions = initialize_result(Some("parent"), scope)["instructions"]
                .as_str()
                .unwrap()
                .to_string();
            for name in allowed {
                assert!(instructions.contains(name), "{relay:?} {name}");
            }
            assert!(!instructions.contains("session_send"), "{relay:?}");

            let list = handle_line_with_parent(
                r#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#,
                "/wt",
                Some("parent"),
                scope,
                |_| unreachable!(),
            )
            .unwrap();
            let expected: Vec<Value> = tool_definitions()
                .into_iter()
                .filter(|tool| allowed.contains(&tool["name"].as_str().unwrap()))
                .collect();
            assert_eq!(list["result"]["tools"], json!(expected), "{relay:?}");

            // Every other name, listed or hidden, is refused before dispatch on
            // both the shared path and the stdio/HTTP pre-parse path.
            let mut names: Vec<String> = tool_definitions()
                .iter()
                .map(|tool| tool["name"].as_str().unwrap().to_string())
                .filter(|name| !allowed.contains(&name.as_str()))
                .collect();
            names.extend(["resolve".to_string(), "workspace_create".to_string()]);
            for name in names {
                let line = call(&name, json!({}));
                let reply =
                    handle_line_with_parent(&line, "/wt", Some("parent"), scope, |_| unreachable!())
                        .unwrap();
                assert_eq!(reply["error"]["code"], json!(-32602), "{relay:?} {name}");
                assert_eq!(reply["error"]["message"], json!(format!("unknown tool: {name}")));
                let msg: Value = serde_json::from_str(&line).unwrap();
                assert!(tools_call_command(&msg, "/wt", scope).is_err(), "{relay:?} {name}");
            }
        }
    }

    #[test]
    fn workspace_only_preparsed_tool_call_accepts_preview_tools() {
        let msg: Value = serde_json::from_str(
            r#"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"preview_open","arguments":{"url":"http://127.0.0.1:5173"}}}"#,
        )
        .unwrap();
        let (id, command) = tools_call_command(&msg, "/checkout", ToolScope::Workspace)
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
    fn child_role_reaches_the_session_request() {
        let command = command_for_tool(
            "session_new",
            &json!({"prompt": "Review", "role": "reviewer"}),
            "/wt",
        )
        .unwrap();
        let request = alas_client::build_session_request(&command, "parent".into(), "/wt".into());
        assert_eq!(request.params.unwrap()["role"], "reviewer");
    }

    #[test]
    fn delegated_child_discovery_omits_session_new_but_calls_still_reach_alas() {
        let tool_names = |parent: Option<&str>| -> Vec<String> {
            let list = handle_line_with_parent(
                r#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#,
                "/wt",
                parent,
                ToolScope::All,
                |_| unreachable!(),
            )
            .unwrap();
            list["result"]["tools"]
                .as_array()
                .unwrap()
                .iter()
                .map(|tool| tool["name"].as_str().unwrap().to_string())
                .collect()
        };
        let root = tool_names(None);
        let child = tool_names(Some("parent-session"));
        assert!(root.iter().any(|name| name == "session_new"));
        assert!(!child.iter().any(|name| name == "session_new"));
        assert_eq!(
            child,
            root.iter()
                .filter(|name| !CHILD_ONLY_TOOLS.contains(&name.as_str()))
                .cloned()
                .collect::<Vec<_>>()
        );
        assert!(child.iter().any(|name| name == "session_read"));

        // Authorization stays server-side: a forged call is forwarded to
        // Alas, which rejects it.
        let mut forwarded = false;
        let reply = handle_line_with_parent(
            r#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"session_new","arguments":{"prompt":"x"}}}"#,
            "/wt",
            Some("parent-session"),
            ToolScope::All,
            |command| {
                assert!(matches!(command, Command::SessionNew { .. }));
                forwarded = true;
                Ok(Response {
                    ok: false,
                    lines: None,
                    error: Some("delegated sessions cannot create descendants".into()),
                    exit_code: None,
                })
            },
        )
        .unwrap();
        assert!(forwarded);
        assert_eq!(reply["result"]["isError"], json!(true));
    }

    #[test]
    fn pr_tools_stay_with_delegated_children_and_leave_workspace_checkouts() {
        let tool_names = |parent: Option<&str>, scope: ToolScope| -> Vec<String> {
            let list = handle_line_with_parent(
                r#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#,
                "/wt",
                parent,
                scope,
                |_| unreachable!(),
            )
            .unwrap();
            list["result"]["tools"]
                .as_array()
                .unwrap()
                .iter()
                .map(|tool| tool["name"].as_str().unwrap().to_string())
                .collect()
        };
        let child = tool_names(Some("parent-session"), ToolScope::All);
        let checkout = tool_names(None, ToolScope::Workspace);
        for tool in ["pr_create", "pr_status", "stack_ship"] {
            assert!(child.iter().any(|name| name == tool), "child lacks {tool}");
            assert!(!checkout.iter().any(|name| name == tool), "checkout exposes {tool}");
        }

        let reply = handle_line_with_parent(
            r#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"pr_status","arguments":{}}}"#,
            "/checkout",
            None,
            ToolScope::Workspace,
            |_| unreachable!(),
        )
        .unwrap();
        assert_eq!(reply["error"]["code"], json!(-32602));
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
    fn cancellation_notification_maps_pending_computer_call_to_cancel_by_call_id() {
        use alas_client::ComputerCommand;
        let pending = std::sync::Mutex::new(std::collections::HashMap::new());
        let mut first = Command::Computer(ComputerCommand::Screenshot {
            window_id: 7,
            call_id: None,
        });
        let mut second = Command::Computer(ComputerCommand::Wait {
            window_id: 7,
            query: "Done".into(),
            disappear: false,
            timeout_ms: 5000,
            limit: 100,
            call_id: None,
        });
        assert!(register_pending_call(&pending, &json!(7), &mut first).is_some());
        assert!(register_pending_call(&pending, &json!(8), &mut second).is_some());
        let call_id = |command: &Command| match command {
            Command::Computer(computer) => computer.call_id().unwrap().to_string(),
            _ => unreachable!(),
        };
        assert_ne!(call_id(&first), call_id(&second));
        let msg: Value = serde_json::from_str(
            r#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":7}}"#,
        )
        .unwrap();
        assert_eq!(
            cancellation_command_for_message(&msg, &pending),
            Some(Command::Computer(ComputerCommand::Cancel {
                call_id: call_id(&first)
            }))
        );
        assert!(!pending.lock().unwrap().contains_key(&json!(7).to_string()));
    }

    #[test]
    fn cancelling_a_pending_session_wait_drops_it_without_an_app_command() {
        let pending = std::sync::Mutex::new(std::collections::HashMap::new());
        let mut wait = Command::SessionWait {
            session_ids: vec!["child".into()],
            timeout_ms: None,
        };
        assert!(register_pending_call(&pending, &json!(9), &mut wait).is_some());
        let msg: Value = serde_json::from_str(
            r#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":9}}"#,
        )
        .unwrap();
        assert_eq!(cancellation_command_for_message(&msg, &pending), None);
        assert!(pending.lock().unwrap().is_empty());
    }

    #[test]
    fn session_wait_slices_continue_only_on_timed_out_replies() {
        let reply = |line: &str| Response {
            ok: true,
            lines: Some(vec![line.into()]),
            error: None,
            exit_code: None,
        };
        assert!(session_wait_timed_out(&reply(
            r#"{"sessions":[],"timed_out":true}"#
        )));
        assert!(!session_wait_timed_out(&reply(
            r#"{"sessions":[],"timed_out":false}"#
        )));
        assert!(!session_wait_timed_out(&Response {
            ok: false,
            lines: None,
            error: Some("denied".into()),
            exit_code: None,
        }));
    }

    #[test]
    fn http_cancellation_notification_uses_pending_preview_map() {
        for pending in [
            Command::Preview(alas_client::PreviewCommand::Wait {
                preview_id: "runtime-preview-id".into(),
                condition: alas_client::PreviewWaitCondition::Loaded,
                selector: None,
                timeout_ms: 20_000,
            }),
            Command::Computer(alas_client::ComputerCommand::Screenshot {
                window_id: 7,
                call_id: Some("42-1".into()),
            }),
        ] {
            assert_http_cancellation_is_accepted(pending);
        }
    }

    fn assert_http_cancellation_is_accepted(pending: Command) {
        let runtime = McpRuntime::new();
        runtime
            .pending
            .lock()
            .unwrap()
            .insert(json!("wait-1").to_string(), pending);
        let env = McpEnv {
            socket: "/tmp/alas-no-such-socket-for-cancel-test".into(),
            worktree_dir: "/wt".into(),
            session_id: "s1".into(),
            parent_session_id: None,
            workspace_only: false,
            headless: false,
            relay: None,
            transport: "stdio",
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
    fn computer_tools_validate_arguments_and_map_to_commands() {
        use alas_client::ComputerCommand;
        assert_eq!(
            command_for_tool("computer_apps", &json!({}), "/wt").unwrap(),
            Command::Computer(ComputerCommand::Apps { call_id: None })
        );
        assert_eq!(
            command_for_tool("computer_screenshot", &json!({ "window_id": 7 }), "/wt").unwrap(),
            Command::Computer(ComputerCommand::Screenshot {
                window_id: 7,
                call_id: None
            })
        );
        assert_eq!(
            command_for_tool(
                "computer_inspect",
                &json!({ "window_id": 7, "query": "Save" }),
                "/wt"
            )
            .unwrap(),
            Command::Computer(ComputerCommand::Inspect {
                window_id: 7,
                query: Some("Save".into()),
                limit: 300,
                max_depth: 32,
                call_id: None
            })
        );
        assert_eq!(
            command_for_tool(
                "computer_inspect",
                &json!({ "window_id": 7, "max_depth": 32 }),
                "/wt"
            )
            .unwrap(),
            Command::Computer(ComputerCommand::Inspect {
                window_id: 7,
                query: None,
                limit: 300,
                max_depth: 32,
                call_id: None
            })
        );
        let post = alas_client::ComputerPost::default();
        let at = |x, y| alas_client::ComputerTarget::Point { x, y };
        let element = |value: &str| alas_client::ComputerTarget::Ref(value.into());
        for (tool, args, expected) in [
            (
                "computer_click",
                json!({ "window_id": 7, "ref": "e12", "button": "right", "count": 2, "delivery": "direct" }),
                ComputerCommand::Click {
                    window_id: 7,
                    target: element("e12"),
                    button: "right".into(),
                    count: 2,
                    direct: true,
                    post: post.clone(),
                    call_id: None,
                },
            ),
            (
                "computer_type",
                json!({ "window_id": 7, "text": " hi ", "ref": "e1", "mode": "replace", "include_screenshot": true, "limit": 5, "query": "ok", "max_depth": 20 }),
                ComputerCommand::Type {
                    window_id: 7,
                    text: " hi ".into(),
                    element: Some("e1".into()),
                    replace: true,
                    direct: false,
                    post: alas_client::ComputerPost {
                        limit: 5,
                        query: Some("ok".into()),
                        max_depth: Some(20),
                        include_screenshot: true,
                    },
                    call_id: None,
                },
            ),
            (
                "computer_key",
                json!({ "window_id": 7, "keys": "cmd+s" }),
                ComputerCommand::Key {
                    window_id: 7,
                    keys: "cmd+s".into(),
                    direct: false,
                    post: post.clone(),
                    call_id: None,
                },
            ),
            (
                "computer_scroll",
                json!({ "window_id": 7, "x": 10.5, "y": 0, "dy": -3 }),
                ComputerCommand::Scroll {
                    window_id: 7,
                    target: at(10.5, 0.0),
                    dx: 0,
                    dy: -3,
                    direct: false,
                    post: post.clone(),
                    call_id: None,
                },
            ),
            (
                "computer_drag",
                json!({ "window_id": 7, "ref": "e1", "to_window_id": 9, "to_ref": "e4" }),
                ComputerCommand::Drag {
                    window_id: 7,
                    from: element("e1"),
                    to_window_id: Some(9),
                    to: element("e4"),
                    direct: false,
                    post: post.clone(),
                    call_id: None,
                },
            ),
            (
                "computer_drag",
                json!({ "window_id": 7, "ref": "e1", "to_ref": "e2", "delivery": "direct" }),
                ComputerCommand::Drag {
                    window_id: 7,
                    from: element("e1"),
                    to_window_id: None,
                    to: element("e2"),
                    direct: true,
                    post,
                    call_id: None,
                },
            ),
            (
                "computer_open_app",
                json!({ "bundle_id": "com.apple.TextEdit" }),
                ComputerCommand::OpenApp {
                    name: None,
                    bundle_id: Some("com.apple.TextEdit".into()),
                    call_id: None,
                },
            ),
            (
                "computer_wait",
                json!({ "window_id": 7, "query": "Done", "condition": "disappear", "timeout_ms": 100 }),
                ComputerCommand::Wait {
                    window_id: 7,
                    query: "Done".into(),
                    disappear: true,
                    timeout_ms: 100,
                    limit: 100,
                    call_id: None,
                },
            ),
        ] {
            assert_eq!(
                command_for_tool(tool, &args, "/wt").unwrap(),
                Command::Computer(expected),
                "{tool} {args}"
            );
        }
        let long_query = "q".repeat(257);
        let long_text = "a".repeat(10001);
        // 10000 characters of 4 bytes each is the largest accepted text: 40000 bytes.
        let wide_text = "\u{1F600}".repeat(10000);
        assert!(
            command_for_tool(
                "computer_type",
                &json!({ "window_id": 7, "text": wide_text }),
                "/wt"
            )
            .is_ok()
        );
        for (tool, args) in [
            ("computer_click", json!({ "window_id": 7 })),
            (
                "computer_click",
                json!({ "window_id": 7, "ref": "e1", "x": 1, "y": 2 }),
            ),
            ("computer_click", json!({ "window_id": 7, "x": 1 })),
            (
                "computer_click",
                json!({ "window_id": 7, "x": 1, "y": 100001 }),
            ),
            ("computer_click", json!({ "window_id": 7, "x": -1, "y": 1 })),
            ("computer_click", json!({ "window_id": 7, "ref": "e0" })),
            (
                "computer_click",
                json!({ "window_id": 7, "ref": "e123456" }),
            ),
            ("computer_click", json!({ "window_id": 7, "ref": "12" })),
            (
                "computer_click",
                json!({ "window_id": 7, "ref": "e1", "count": 3 }),
            ),
            (
                "computer_click",
                json!({ "window_id": 7, "ref": "e1", "button": "middle" }),
            ),
            (
                "computer_click",
                json!({ "window_id": 7, "ref": "e1", "delivery": "teleport" }),
            ),
            (
                "computer_click",
                json!({ "window_id": 7, "ref": "e1", "text": "x" }),
            ),
            (
                "computer_click",
                json!({ "window_id": 7, "ref": "e1", "limit": 0 }),
            ),
            (
                "computer_click",
                json!({ "window_id": 7, "ref": "e1", "include_screenshot": "yes" }),
            ),
            (
                "computer_click",
                json!({ "window_id": 7, "ref": "e1", "call_id": "forged" }),
            ),
            ("computer_type", json!({ "window_id": 7, "text": "" })),
            (
                "computer_type",
                json!({ "window_id": 7, "text": long_text }),
            ),
            (
                "computer_type",
                json!({ "window_id": 7, "text": "x", "mode": "replace" }),
            ),
            (
                "computer_type",
                json!({ "window_id": 7, "text": "x", "x": 1, "y": 1 }),
            ),
            ("computer_type", json!({ "window_id": 7 })),
            ("computer_key", json!({ "window_id": 7, "keys": "  " })),
            (
                "computer_key",
                json!({ "window_id": 7, "keys": "k".repeat(65) }),
            ),
            (
                "computer_key",
                json!({ "window_id": 7, "keys": "a", "ref": "e1" }),
            ),
            ("computer_scroll", json!({ "window_id": 7, "ref": "e1" })),
            (
                "computer_scroll",
                json!({ "window_id": 7, "ref": "e1", "dx": 0, "dy": 0 }),
            ),
            (
                "computer_scroll",
                json!({ "window_id": 7, "ref": "e1", "dy": 101 }),
            ),
            (
                "computer_scroll",
                json!({ "window_id": 7, "ref": "e1", "dx": -101 }),
            ),
            ("computer_drag", json!({ "window_id": 7, "ref": "e1" })),
            (
                "computer_drag",
                json!({ "window_id": 7, "ref": "e1", "to_window_id": -1, "to_ref": "e2" }),
            ),
            (
                "computer_drag",
                json!({ "window_id": 7, "ref": "e1", "to_window_id": 4294967296u64, "to_ref": "e2" }),
            ),
            (
                "computer_click",
                json!({ "window_id": 7, "ref": "e1", "to_window_id": 2 }),
            ),
            (
                "computer_drag",
                json!({ "window_id": 7, "ref": "e1", "to_x": 1 }),
            ),
            (
                "computer_drag",
                json!({ "window_id": 7, "ref": "e1", "to_ref": "e2", "to_x": 1, "to_y": 1 }),
            ),
            ("computer_open_app", json!({})),
            (
                "computer_open_app",
                json!({ "name": "A", "bundle_id": "b" }),
            ),
            ("computer_open_app", json!({ "name": "  " })),
            ("computer_open_app", json!({ "name": "n".repeat(257) })),
            ("computer_open_app", json!({ "name": "A", "window_id": 7 })),
            ("computer_wait", json!({ "window_id": 7 })),
            ("computer_wait", json!({ "window_id": 7, "query": "  " })),
            (
                "computer_wait",
                json!({ "window_id": 7, "query": "x", "timeout_ms": 99 }),
            ),
            (
                "computer_wait",
                json!({ "window_id": 7, "query": "x", "timeout_ms": 20001 }),
            ),
            (
                "computer_wait",
                json!({ "window_id": 7, "query": "x", "condition": "later" }),
            ),
            (
                "computer_wait",
                json!({ "window_id": 7, "query": "x", "include_screenshot": true }),
            ),
            ("computer_apps", json!({ "window_id": 7 })),
            ("computer_apps", json!({ "query": "x" })),
            ("computer_screenshot", json!({})),
            ("computer_screenshot", json!({ "window_id": -1 })),
            ("computer_screenshot", json!({ "window_id": 4294967296u64 })),
            (
                "computer_screenshot",
                json!({ "window_id": 7, "query": "x" }),
            ),
            (
                "computer_screenshot",
                json!({ "window_id": 7, "call_id": "forged" }),
            ),
            ("computer_inspect", json!({})),
            ("computer_inspect", json!({ "window_id": 7, "query": "  " })),
            (
                "computer_inspect",
                json!({ "window_id": 7, "query": long_query }),
            ),
            ("computer_inspect", json!({ "window_id": 7, "limit": 0 })),
            ("computer_inspect", json!({ "window_id": 7, "limit": 3001 })),
            (
                "computer_inspect",
                json!({ "window_id": 7, "max_depth": 0 }),
            ),
            (
                "computer_inspect",
                json!({ "window_id": 7, "max_depth": 33 }),
            ),
            (
                "computer_click",
                json!({ "window_id": 7, "ref": "e1", "max_depth": 33 }),
            ),
            (
                "computer_open_app",
                json!({ "name": "Notes", "max_depth": 12 }),
            ),
        ] {
            assert!(
                command_for_tool(tool, &args, "/wt").is_err(),
                "{tool} {args}"
            );
        }
    }

    #[test]
    fn computer_screenshot_result_extracts_mcp_image_and_keeps_metadata_text() {
        let line = json!({
            "version": 1,
            "scale": 2.0,
            "image": { "mime_type": "image/png", "data": "iVBORw0KGgo=" }
        })
        .to_string();
        let reply = handle_line(
            r#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"computer_screenshot","arguments":{"window_id":7}}}"#,
            "/wt",
            |command| {
                assert!(matches!(
                    command,
                    Command::Computer(alas_client::ComputerCommand::Screenshot { .. })
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
        assert!(content[1]["text"].as_str().unwrap().contains("\"scale\""));
        assert!(!content[1]["text"].as_str().unwrap().contains("\"image\""));
    }

    #[test]
    fn computer_action_with_include_screenshot_returns_mcp_image() {
        let line = json!({
            "version": 1,
            "action": "click",
            "elements": [],
            "image": { "mime_type": "image/png", "data": "iVBORw0KGgo=" }
        })
        .to_string();
        let reply = handle_line(
            r#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"computer_key","arguments":{"window_id":7,"keys":"return","include_screenshot":true}}}"#,
            "/wt",
            |_| {
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
        assert_eq!(content[1]["type"], json!("text"));
        assert!(content[1]["text"].as_str().unwrap().contains("\"action\""));
    }

    #[test]
    fn computer_tools_are_read_only_and_absent_from_relays_and_workspace_mode() {
        let reply = handle_line(
            r#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#,
            "/wt",
            |_| unreachable!(),
        )
        .unwrap();
        let tools = reply["result"]["tools"].as_array().unwrap();
        let annotation = |name: &str, hint: &str| {
            let tool = tools
                .iter()
                .find(|tool| tool["name"] == json!(name))
                .unwrap();
            tool["annotations"][hint].clone()
        };
        for name in ["computer_apps", "computer_screenshot", "computer_inspect"] {
            assert_eq!(annotation(name, "readOnlyHint"), json!(true), "{name}");
        }
        for name in [
            "computer_click",
            "computer_type",
            "computer_key",
            "computer_scroll",
            "computer_drag",
            "computer_open_app",
            "computer_wait",
        ] {
            assert_eq!(annotation(name, "readOnlyHint"), json!(false), "{name}");
            assert_eq!(annotation(name, "destructiveHint"), json!(true), "{name}");
        }
        for scope in [ToolScope::Visual, ToolScope::Remote, ToolScope::Workspace] {
            let names: Vec<String> = super::tool_definitions_for_mode(scope)
                .iter()
                .map(|tool| tool["name"].as_str().unwrap().to_string())
                .collect();
            assert!(
                names.iter().all(|name| !name.starts_with("computer_")),
                "{scope:?}"
            );
        }
        let msg: Value = serde_json::from_str(&call("computer_apps", json!({}))).unwrap();
        let err = tools_call_command(&msg, "/wt", ToolScope::Workspace).unwrap_err();
        assert_eq!(err["error"]["code"], json!(-32602));
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
            command_for_tool("agent_list", &json!({}), "/wt").unwrap(),
            alas_client::Command::AgentList { worktree: None }
        );
        assert_eq!(
            command_for_tool("agent_list", &json!({ "worktree": "feature" }), "/wt").unwrap(),
            alas_client::Command::AgentList {
                worktree: Some("feature".into())
            }
        );
        assert!(command_for_tool("agent_list", &json!({ "worktree": 3 }), "/wt").is_err());
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
                    "model": "gpt-5.2",
                    "reasoning": "high",
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
                },
                model: Some("gpt-5.2".into()),
                reasoning: Some("high".into()),
                role: None,
            }
        );
        for invalid in [
            json!({ "prompt": "Task", "model": " " }),
            json!({ "prompt": "Task", "model": 5 }),
            json!({ "prompt": "Task", "reasoning": ["high"] }),
            json!({ "prompt": "Task", "role": " " }),
            json!({ "prompt": "Task", "role": 5 }),
        ] {
            assert!(command_for_tool("session_new", &invalid, "/wt").is_err());
        }
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
        assert_eq!(
            command_for_tool(
                "session_wait",
                &json!({ "session_ids": ["a", "b"], "timeout_ms": 500 }),
                "/wt"
            )
            .unwrap(),
            alas_client::Command::SessionWait {
                session_ids: vec!["a".into(), "b".into()],
                timeout_ms: Some(500),
            }
        );
        assert_eq!(
            command_for_tool("session_read", &json!({ "session_id": "child" }), "/wt").unwrap(),
            alas_client::Command::SessionRead {
                session_id: "child".into(),
                offset: None,
                limit: None,
                max_chars: None,
            }
        );
        // A wait blocks for seconds; the stdio loop must keep reading meanwhile.
        assert!(runs_on_worker(&alas_client::Command::SessionWait {
            session_ids: vec!["a".into()],
            timeout_ms: None,
        }));
        assert!(!runs_on_worker(&alas_client::Command::SessionInterrupt {
            session_id: "a".into(),
        }));
        for (tool, invalid) in [
            ("session_wait", json!({ "session_ids": [] })),
            ("session_wait", json!({ "session_ids": "a" })),
            ("session_wait", json!({ "session_ids": [" "] })),
            (
                "session_wait",
                json!({ "session_ids": ["a"], "timeout_ms": 20_001 }),
            ),
            ("session_read", json!({ "session_id": "child", "limit": 0 })),
            (
                "session_read",
                json!({ "session_id": "child", "offset": -1 }),
            ),
            ("session_search", json!({ "query": "  " })),
            ("session_interrupt", json!({})),
        ] {
            assert!(
                command_for_tool(tool, &invalid, "/wt").is_err(),
                "{tool} {invalid}"
            );
        }
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
    fn pr_tools_map_to_commands_and_validate_arguments() {
        assert_eq!(
            command_for_tool(
                "pr_create",
                &json!({"title": "fix: retry", "body": "Why.", "draft": true, "base": "release"}),
                "/wt"
            )
            .unwrap(),
            Command::PrCreate {
                title: "fix: retry".into(),
                body: "Why.".into(),
                draft: true,
                base: Some("release".into())
            }
        );
        assert_eq!(
            command_for_tool(
                "pr_create",
                &json!({"title": " fix: retry ", "body": "Why.", "base": "  "}),
                "/wt"
            )
            .unwrap(),
            Command::PrCreate {
                title: "fix: retry".into(),
                body: "Why.".into(),
                draft: false,
                base: None
            }
        );
        for bad in [
            json!({"body": "Why."}),
            json!({"title": "   ", "body": "Why."}),
            json!({"title": "fix: retry"}),
            json!({"title": "fix: retry", "body": "Why.", "draft": "yes"}),
            json!({"title": "fix: retry", "body": "Why.", "base": 123}),
        ] {
            assert!(
                command_for_tool("pr_create", &bad, "/wt").is_err(),
                "accepted {bad}"
            );
        }
        assert_eq!(
            command_for_tool("pr_status", &json!({}), "/wt").unwrap(),
            Command::PrStatus
        );
        assert_eq!(
            command_for_tool("stack_ship", &json!({}), "/wt").unwrap(),
            Command::StackShip
        );
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
        let base_dir = if cfg!(target_os = "macos") {
            std::path::PathBuf::from("/private/tmp")
        } else {
            std::env::temp_dir()
        };
        let dir = base_dir.join(format!("alas-mcp-it-{}-{unique}", std::process::id()));
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
            headless: false,
            relay: None,
            transport: "stdio",
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
        assert_eq!(seen["mcp_transport"], json!("stdio"));

        let _ = handle.join();
        let _ = std::fs::remove_dir_all(&dir);
    }
}
