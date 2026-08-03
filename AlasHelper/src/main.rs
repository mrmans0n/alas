mod watch;

use alas_helper::acp_broker_process;
use base64::Engine;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};
use std::io::{self, BufRead, BufReader, Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, RecvTimeoutError, Sender, TryRecvError};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use watch::{SubscriptionWatcher, WatchKind, WatchNotification};

const PROTOCOL_VERSION: u32 = 1;

#[derive(Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
struct Handshake<'a> {
    name: &'a str,
    protocol_version: u32,
    binary_version: &'a str,
}

#[derive(Debug, Deserialize)]
struct JsonRpcRequest {
    id: Option<Value>,
    method: Option<String>,
    params: Option<Value>,
}

#[derive(Debug)]
struct HelperError {
    code: i64,
    message: String,
}

#[derive(Default)]
struct HelperState {
    next_subscription_id: u64,
    next_search_id: u64,
    subscriptions: HashMap<String, PathBuf>,
    watchers: HashMap<String, SubscriptionWatcher>,
    searches: HashMap<String, Arc<AtomicBool>>,
    event_sender: Option<Sender<ServerMessage>>,
    proc_tailers: HashSet<String>,
}

#[derive(Debug, Deserialize)]
struct WatchSubscribeParams {
    root: String,
    #[allow(dead_code)]
    kinds: Vec<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct WatchUnsubscribeParams {
    subscription_id: String,
}

#[derive(Debug, Deserialize)]
struct FsReadParams {
    path: String,
    offset: Option<u64>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct FsWriteParams {
    path: String,
    content: String,
    expected_mtime: Option<f64>,
    expected_content: Option<String>,
}

#[derive(Debug, Deserialize)]
struct FsStatParams {
    paths: Vec<String>,
}

#[derive(Debug, Deserialize)]
struct FsLineCountsParams {
    root: String,
    paths: Vec<String>,
}

#[derive(Debug, Deserialize)]
struct FsListParams {
    path: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct SearchStartParams {
    root: String,
    query: String,
    case_sensitive: bool,
    whole_word: bool,
    regex: bool,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct SearchCancelParams {
    search_id: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ProcSpawnParams {
    proc_id: String,
    command: String,
    args: Vec<String>,
    cwd: String,
    env: HashMap<String, String>,
    path_prefix_directories: Option<Vec<String>>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ProcAttachParams {
    proc_id: String,
    stdout_offset: Option<u64>,
    stderr_offset: Option<u64>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ProcWriteParams {
    proc_id: String,
    data_base64: String,
    expected_stdin_offset: Option<u64>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ProcKillParams {
    proc_id: String,
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ProcMetadata {
    proc_id: String,
    command: String,
    args: Vec<String>,
    cwd: String,
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ProcPidMetadata {
    pid: u32,
    process_group_id: Option<u32>,
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ProcSupervisorLaunch {
    command: String,
    args: Vec<String>,
    cwd: String,
    env: HashMap<String, String>,
    path_prefix_directories: Vec<String>,
}

#[derive(Debug)]
struct ProcReplayFrame {
    offset: u64,
    data: Vec<u8>,
}

#[derive(Debug)]
pub(crate) enum SearchNotification {
    Line {
        search_id: String,
        line: String,
    },
    Complete {
        search_id: String,
        exit_code: i32,
        stderr: String,
        cancelled: bool,
    },
}

#[derive(Debug)]
pub(crate) enum ProcNotification {
    Stdout {
        proc_id: String,
        offset: u64,
        data: Vec<u8>,
    },
    Stderr {
        proc_id: String,
        offset: u64,
        data: Vec<u8>,
    },
    Exit {
        proc_id: String,
        exit_code: Option<i32>,
    },
}

#[derive(Debug)]
pub(crate) enum ServerMessage {
    Request(String),
    /// A fully-formed JSON-RPC response produced off the serve loop, waiting
    /// to be written. See `AcpJob`.
    Response(String),
    Watch(WatchNotification),
    Search(SearchNotification),
    Proc(ProcNotification),
    InputClosed,
}

fn handshake() -> Handshake<'static> {
    Handshake {
        name: env!("CARGO_PKG_NAME"),
        protocol_version: PROTOCOL_VERSION,
        binary_version: env!("CARGO_PKG_VERSION"),
    }
}

fn capabilities() -> Value {
    json!({
        "watchKinds": ["files", "git"],
        "fs": {
            "read": true,
            "write": true,
            "stat": true,
            "lineCounts": true,
            "list": true
        },
        "search": true,
        "ping": true,
        "proc": true
        ,
        "acp": true
    })
}

fn main() {
    let mut args = std::env::args();
    let _program = args.next();
    let command = args.next();
    match command.as_deref() {
        None | Some("version") => {
            println!(
                "{}",
                serde_json::to_string(&handshake()).expect("handshake serialization must succeed")
            );
        }
        Some("serve") => {
            if let Err(error) = serve() {
                eprintln!("alas-helper: {error}");
                std::process::exit(1);
            }
        }
        Some("proc-supervise") => {
            let Some(dir) = args.next() else {
                eprintln!("usage: alas-helper proc-supervise <proc-dir>");
                std::process::exit(2);
            };
            if let Err(error) = proc_supervise(PathBuf::from(dir)) {
                eprintln!("alas-helper proc-supervise: {}", error.message);
                std::process::exit(1);
            }
        }
        Some("acp-broker-supervise") => {
            let Some(dir) = args.next() else {
                eprintln!("usage: alas-helper acp-broker-supervise <broker-dir>");
                std::process::exit(2);
            };
            if let Err(error) = acp_broker_process::run_broker_supervisor(PathBuf::from(dir)) {
                eprintln!("alas-helper acp-broker-supervise: {}", error.message);
                std::process::exit(1);
            }
        }
        Some(_) => {
            eprintln!("usage: alas-helper [version|serve]");
            std::process::exit(2);
        }
    }
}

fn serve() -> io::Result<()> {
    const DEBOUNCE: Duration = Duration::from_millis(250);
    let (sender, receiver) = mpsc::channel();
    let input_sender = sender.clone();
    std::thread::spawn(move || {
        let stdin = io::stdin();
        for line in stdin.lock().lines() {
            match line {
                Ok(line) => {
                    if input_sender.send(ServerMessage::Request(line)).is_err() {
                        break;
                    }
                }
                Err(_) => break,
            }
        }
        let _ = input_sender.send(ServerMessage::InputClosed);
    });

    let mut stdout = io::stdout().lock();
    let mut state = HelperState {
        event_sender: Some(sender),
        ..HelperState::default()
    };
    let mut pending_events: HashMap<(String, WatchKind), HashSet<String>> = HashMap::new();
    let mut flush_at: Option<Instant> = None;

    loop {
        let message = match flush_at {
            Some(deadline) => {
                let timeout = deadline.saturating_duration_since(Instant::now());
                match receiver.recv_timeout(timeout) {
                    Ok(message) => Some(message),
                    Err(RecvTimeoutError::Timeout) => None,
                    Err(RecvTimeoutError::Disconnected) => break,
                }
            }
            None => match receiver.recv() {
                Ok(message) => Some(message),
                Err(_) => break,
            },
        };

        match message {
            Some(ServerMessage::Request(line)) => {
                flush_due_watch_events(&mut stdout, &state, &mut pending_events, &mut flush_at)?;
                if line.trim().is_empty() {
                    continue;
                }
                // ACP requests talk to broker processes and wait as long as a
                // broker takes to answer. Handling one here would put that
                // wait in front of everything else this helper serves — every
                // other ACP session, and every fs, watch, search and proc
                // request — so a single slow or wedged broker would stall the
                // whole app. Run them off this thread and let the response
                // come back through the same channel the watchers use.
                match AcpJob::from_line(&line) {
                    Some(job) => match state.event_sender.clone() {
                        Some(sender) => {
                            std::thread::spawn(move || {
                                let _ = sender.send(ServerMessage::Response(job.run()));
                            });
                        }
                        // No channel to answer on (only reachable outside the
                        // serve loop); fall back to answering inline.
                        None => write_json_line(&mut stdout, &job.run())?,
                    },
                    None => {
                        if let Some(response) = handle_line(&mut state, &line) {
                            write_json_line(&mut stdout, &response)?;
                        }
                    }
                }
            }
            Some(ServerMessage::Response(line)) => {
                flush_due_watch_events(&mut stdout, &state, &mut pending_events, &mut flush_at)?;
                write_json_line(&mut stdout, &line)?;
            }
            Some(ServerMessage::Watch(notification)) => {
                pending_events
                    .entry((notification.subscription_id, notification.kind))
                    .or_default()
                    .extend(notification.paths);
                flush_at.get_or_insert_with(|| Instant::now() + DEBOUNCE);
            }
            Some(ServerMessage::Search(notification)) => {
                flush_due_watch_events(&mut stdout, &state, &mut pending_events, &mut flush_at)?;
                write_search_notification(&mut stdout, &mut state, notification)?;
            }
            Some(ServerMessage::Proc(notification)) => {
                flush_due_watch_events(&mut stdout, &state, &mut pending_events, &mut flush_at)?;
                write_proc_notification(&mut stdout, notification)?;
            }
            Some(ServerMessage::InputClosed) => {
                flush_watch_events(&mut stdout, &state, &mut pending_events)?;
                break;
            }
            None => {
                flush_watch_events(&mut stdout, &state, &mut pending_events)?;
                flush_at = None;
            }
        }
    }
    Ok(())
}

fn write_proc_notification(
    stdout: &mut impl Write,
    notification: ProcNotification,
) -> io::Result<()> {
    let value = match notification {
        ProcNotification::Stdout {
            proc_id,
            offset,
            data,
        } => json!({
            "jsonrpc": "2.0",
            "method": "proc/output",
            "params": {
                "procId": proc_id,
                "stream": "stdout",
                "offset": offset,
                "dataBase64": base64::engine::general_purpose::STANDARD.encode(data)
            }
        }),
        ProcNotification::Stderr {
            proc_id,
            offset,
            data,
        } => json!({
            "jsonrpc": "2.0",
            "method": "proc/output",
            "params": {
                "procId": proc_id,
                "stream": "stderr",
                "offset": offset,
                "dataBase64": base64::engine::general_purpose::STANDARD.encode(data)
            }
        }),
        ProcNotification::Exit { proc_id, exit_code } => json!({
            "jsonrpc": "2.0",
            "method": "proc/exit",
            "params": { "procId": proc_id, "exitCode": exit_code }
        }),
    };
    write_json_line(stdout, &value.to_string())
}

fn write_search_notification(
    stdout: &mut impl Write,
    state: &mut HelperState,
    notification: SearchNotification,
) -> io::Result<()> {
    let value = match notification {
        SearchNotification::Line { search_id, line } => json!({
            "jsonrpc": "2.0",
            "method": "search/event",
            "params": { "searchId": search_id, "line": line }
        }),
        SearchNotification::Complete {
            search_id,
            exit_code,
            stderr,
            cancelled,
        } => {
            state.searches.remove(&search_id);
            json!({
                "jsonrpc": "2.0",
                "method": "search/complete",
                "params": {
                    "searchId": search_id,
                    "exitCode": exit_code,
                    "stderr": stderr,
                    "cancelled": cancelled
                }
            })
        }
    };
    write_json_line(stdout, &value.to_string())
}

fn flush_due_watch_events(
    stdout: &mut impl Write,
    state: &HelperState,
    pending: &mut HashMap<(String, WatchKind), HashSet<String>>,
    flush_at: &mut Option<Instant>,
) -> io::Result<bool> {
    let Some(deadline) = *flush_at else {
        return Ok(false);
    };
    if deadline > Instant::now() {
        return Ok(false);
    }
    flush_watch_events(stdout, state, pending)?;
    *flush_at = None;
    Ok(true)
}

fn write_json_line(stdout: &mut impl Write, line: &str) -> io::Result<()> {
    writeln!(stdout, "{line}")?;
    stdout.flush()
}

fn flush_watch_events(
    stdout: &mut impl Write,
    state: &HelperState,
    pending: &mut HashMap<(String, WatchKind), HashSet<String>>,
) -> io::Result<()> {
    let events = std::mem::take(pending);
    for ((subscription_id, kind), paths) in events {
        let Some(root) = state.subscriptions.get(&subscription_id) else {
            continue;
        };
        let notification = json!({
            "jsonrpc": "2.0",
            "method": "watch/event",
            "params": {
                "subscriptionId": subscription_id,
                "root": root.display().to_string(),
                "kind": kind.as_str(),
                "paths": paths.into_iter().collect::<Vec<_>>()
            }
        });
        write_json_line(stdout, &notification.to_string())?;
    }
    Ok(())
}

/// An `acp/*` request lifted out of the serve loop so it can block on a
/// broker without blocking anything else.
///
/// Only requests with an id qualify: a notification has nothing to send back,
/// so there is no response to route through the channel.
///
/// A thread per request, with no pool, is deliberate. It reads alarming next
/// to `ACPBrokerClient`'s 50ms active poll — 20 requests a second per live
/// session — but that loop awaits each `attachAndReplay` before sleeping
/// again, so a session has at most one attach outstanding. Concurrency
/// therefore tracks the number of sessions, not the poll rate, and a wedged
/// broker parks one thread per session rather than accumulating them. What is
/// left is churn: ~20 spawns a second per active session, tens of microseconds
/// each. A pool would buy that back and cost a queue that could itself stall.
struct AcpJob {
    id: Value,
    method: String,
    params: Option<Value>,
}

impl AcpJob {
    fn from_line(line: &str) -> Option<Self> {
        let request: JsonRpcRequest = serde_json::from_str(line).ok()?;
        let method = request.method?;
        if !method.starts_with("acp/") {
            return None;
        }
        Some(Self {
            id: request.id?,
            method,
            params: request.params,
        })
    }

    fn run(self) -> String {
        match acp_broker_process::handle_control_request(&self.method, self.params) {
            Ok(result) => success_response(self.id, result),
            Err(error) => error_response(self.id, error.code, error.message),
        }
    }
}

fn handle_line(state: &mut HelperState, line: &str) -> Option<String> {
    let request: Result<JsonRpcRequest, _> = serde_json::from_str(line);
    let request = match request {
        Ok(request) => request,
        Err(error) => {
            return Some(error_response(
                Value::Null,
                -32700,
                format!("parse error: {error}"),
            ));
        }
    };

    let id = request.id.clone();
    let Some(id) = id else {
        return None;
    };
    let Some(method) = request.method.as_deref() else {
        return Some(error_response(id, -32600, "missing method"));
    };

    match handle_request(state, method, request.params) {
        Ok(result) => Some(success_response(id, result)),
        Err(error) => Some(error_response(id, error.code, error.message)),
    }
}

fn handle_request(
    state: &mut HelperState,
    method: &str,
    params: Option<Value>,
) -> Result<Value, HelperError> {
    match method {
        "hello" => Ok(json!({
            "name": handshake().name,
            "protocolVersion": handshake().protocol_version,
            "binaryVersion": handshake().binary_version,
            "capabilities": capabilities()
        })),
        "ping" => Ok(json!({ "ok": true })),
        "watch/subscribe" => watch_subscribe(state, params),
        "watch/unsubscribe" => watch_unsubscribe(state, params),
        "fs/read" => fs_read(state, params),
        "fs/write" => fs_write(state, params),
        "fs/stat" => fs_stat(state, params),
        "fs/line-counts" => fs_line_counts(state, params),
        "fs/list" => fs_list(state, params),
        "search/start" => search_start(state, params),
        "search/cancel" => search_cancel(state, params),
        "proc/spawn" => proc_spawn(state, params),
        "proc/attach" => proc_attach(state, params),
        "proc/write" => proc_write(params),
        "proc/kill" => proc_kill(params),
        "proc/list" => proc_list(),
        method if method.starts_with("acp/") => {
            acp_broker_process::handle_control_request(method, params).map_err(|error| {
                HelperError {
                    code: error.code,
                    message: error.message,
                }
            })
        }
        _ => Err(jsonrpc_error(-32601, format!("method not found: {method}"))),
    }
}

fn watch_subscribe(state: &mut HelperState, params: Option<Value>) -> Result<Value, HelperError> {
    let params: WatchSubscribeParams = decode_params(params)?;
    let root = std::fs::canonicalize(&params.root)
        .map_err(|error| jsonrpc_error(-32010, format!("invalid root: {error}")))?;
    let kinds: HashSet<_> = params
        .kinds
        .iter()
        .map(|kind| {
            WatchKind::parse(kind)
                .ok_or_else(|| jsonrpc_error(-32602, format!("unsupported watch kind: {kind}")))
        })
        .collect::<Result<_, _>>()?;
    if kinds.is_empty() {
        return Err(jsonrpc_error(-32602, "at least one watch kind is required"));
    }
    state.next_subscription_id += 1;
    let id = state.next_subscription_id.to_string();
    if let Some(sender) = state.event_sender.clone() {
        let watcher = SubscriptionWatcher::new(id.clone(), root.clone(), kinds, sender)
            .map_err(|error| jsonrpc_error(-32011, error))?;
        state.watchers.insert(id.clone(), watcher);
    }
    state.subscriptions.insert(id.clone(), root);
    Ok(json!({ "subscriptionId": id }))
}

fn watch_unsubscribe(state: &mut HelperState, params: Option<Value>) -> Result<Value, HelperError> {
    let params: WatchUnsubscribeParams = decode_params(params)?;
    state.subscriptions.remove(&params.subscription_id);
    state.watchers.remove(&params.subscription_id);
    Ok(json!({ "ok": true }))
}

fn fs_read(state: &HelperState, params: Option<Value>) -> Result<Value, HelperError> {
    let params: FsReadParams = decode_params(params)?;
    let path = match contained_existing_path(state, &params.path) {
        Ok(path) => path,
        Err(error) if error.code == -32021 => return Ok(json!({ "kind": "missing" })),
        Err(error) => return Err(error),
    };
    let source_metadata = std::fs::symlink_metadata(&params.path)
        .map_err(|error| jsonrpc_error(-32020, format!("metadata failed: {error}")))?;
    if source_metadata.file_type().is_symlink() {
        return Ok(json!({ "kind": "symlink" }));
    }
    let metadata = std::fs::metadata(&path)
        .map_err(|error| jsonrpc_error(-32020, format!("metadata failed: {error}")))?;
    if metadata.is_dir() {
        return Ok(json!({ "kind": "directory" }));
    }
    if !metadata.is_file() {
        return Ok(json!({ "kind": "unreadable", "detail": "path is not a regular file" }));
    }
    let bytes = std::fs::read(&path)
        .map_err(|error| jsonrpc_error(-32020, format!("read failed: {error}")))?;
    let offset = params.offset.unwrap_or(0) as usize;
    let body = bytes.get(offset..).unwrap_or_default();
    let content = base64::engine::general_purpose::STANDARD.encode(body);
    let legacy_content = std::str::from_utf8(body).ok();
    let mtime = modified_seconds(&metadata);
    Ok(json!({
        "kind": "file",
        "content": legacy_content,
        "contentBase64": content,
        "mtime": mtime
    }))
}

fn fs_write(state: &HelperState, params: Option<Value>) -> Result<Value, HelperError> {
    let params: FsWriteParams = decode_params(params)?;
    let path = contained_write_path(state, &params.path).map_err(|error| {
        if params.expected_content.is_some() && error.code == -32025 {
            jsonrpc_error(-32030, "content target unreadable")
        } else {
            error
        }
    })?;
    if let Some(expected) = params.expected_content.as_deref() {
        let actual = std::fs::read(&path).map_err(|error| {
            if error.kind() == io::ErrorKind::NotFound {
                jsonrpc_error(-32030, "content target missing")
            } else {
                jsonrpc_error(-32030, format!("content target unreadable: {error}"))
            }
        })?;
        if actual != expected.as_bytes() {
            return Err(jsonrpc_error(-32030, "content mismatch"));
        }
    } else if let Some(expected) = params.expected_mtime {
        let metadata = std::fs::metadata(&path).map_err(|error| {
            if error.kind() == io::ErrorKind::NotFound {
                jsonrpc_error(-32030, "mtime target missing")
            } else {
                jsonrpc_error(-32020, format!("mtime failed: {error}"))
            }
        })?;
        if let Some(actual) = modified_seconds(&metadata)
            && (actual - expected).abs() > 0.000_001
        {
            return Err(jsonrpc_error(-32030, "mtime mismatch"));
        }
    }
    write_replacing_path(&path, &params.content)?;
    let mtime = std::fs::metadata(path)
        .ok()
        .and_then(|metadata| modified_seconds(&metadata));
    Ok(json!({ "mtime": mtime }))
}

fn fs_stat(state: &HelperState, params: Option<Value>) -> Result<Value, HelperError> {
    let params: FsStatParams = decode_params(params)?;
    let mut entries = Vec::with_capacity(params.paths.len());
    for path in params.paths {
        match contained_existing_path(state, &path) {
            Ok(contained) => {
                let metadata = std::fs::metadata(&contained)
                    .map_err(|error| jsonrpc_error(-32020, format!("stat failed: {error}")))?;
                entries.push(json!({
                    "path": path,
                    "exists": true,
                    "isDirectory": metadata.is_dir(),
                    "isFile": metadata.is_file(),
                    "size": metadata.len(),
                    "mtime": modified_seconds(&metadata)
                }));
            }
            Err(error) if error.code == -32021 => {
                entries.push(json!({
                    "path": path,
                    "exists": false,
                    "isDirectory": false,
                    "isFile": false,
                    "size": null,
                    "mtime": null
                }));
            }
            Err(error) => return Err(error),
        }
    }
    Ok(json!({ "entries": entries }))
}

fn fs_line_counts(state: &HelperState, params: Option<Value>) -> Result<Value, HelperError> {
    let params: FsLineCountsParams = decode_params(params)?;
    let root = contained_directory(state, &params.root)?;
    let mut entries = Vec::with_capacity(params.paths.len());
    for relative in params.paths {
        let requested = root.join(&relative);
        let requested = requested.to_string_lossy().into_owned();
        let path = match contained_existing_path(state, &requested) {
            Ok(path) => path,
            Err(error) if error.code == -32021 => continue,
            Err(error) => return Err(error),
        };
        let metadata = std::fs::metadata(&path)
            .map_err(|error| jsonrpc_error(-32020, format!("metadata failed: {error}")))?;
        if !metadata.is_file() {
            continue;
        }
        let mut file = std::fs::File::open(&path)
            .map_err(|error| jsonrpc_error(-32020, format!("open failed: {error}")))?;
        let mut buffer = [0_u8; 64 * 1024];
        let mut count = 0_u64;
        loop {
            let read = file
                .read(&mut buffer)
                .map_err(|error| jsonrpc_error(-32020, format!("read failed: {error}")))?;
            if read == 0 {
                break;
            }
            count += buffer[..read].iter().filter(|byte| **byte == b'\n').count() as u64;
        }
        entries.push(json!({ "path": relative, "lineCount": count }));
    }
    Ok(json!({ "entries": entries }))
}

fn fs_list(state: &HelperState, params: Option<Value>) -> Result<Value, HelperError> {
    let params: FsListParams = decode_params(params)?;
    let path = contained_directory(state, &params.path)?;
    let mut entries = Vec::new();
    let directory = std::fs::read_dir(path)
        .map_err(|error| jsonrpc_error(-32020, format!("list failed: {error}")))?;
    for entry in directory {
        let entry =
            entry.map_err(|error| jsonrpc_error(-32020, format!("list failed: {error}")))?;
        let file_type = entry
            .file_type()
            .map_err(|error| jsonrpc_error(-32020, format!("file type failed: {error}")))?;
        entries.push(json!({
            "name": entry.file_name().to_string_lossy(),
            "isDirectory": file_type.is_dir()
        }));
    }
    entries.sort_by(|left, right| left["name"].as_str().cmp(&right["name"].as_str()));
    Ok(json!({ "entries": entries }))
}

fn contained_directory(state: &HelperState, path: &str) -> Result<PathBuf, HelperError> {
    let path = contained_existing_path(state, path)?;
    let metadata = std::fs::metadata(&path)
        .map_err(|error| jsonrpc_error(-32020, format!("metadata failed: {error}")))?;
    if !metadata.is_dir() {
        return Err(jsonrpc_error(-32025, "path is not a directory"));
    }
    Ok(path)
}

fn search_start(state: &mut HelperState, params: Option<Value>) -> Result<Value, HelperError> {
    let params: SearchStartParams = decode_params(params)?;
    let root = contained_directory(state, &params.root)?;
    let sender = state
        .event_sender
        .clone()
        .ok_or_else(|| jsonrpc_error(-32040, "search channel unavailable"))?;
    state.next_search_id += 1;
    let search_id = state.next_search_id.to_string();
    let cancelled = Arc::new(AtomicBool::new(false));
    state.searches.insert(search_id.clone(), cancelled.clone());
    spawn_search(search_id.clone(), root, params, cancelled, sender);
    Ok(json!({ "searchId": search_id }))
}

fn search_cancel(state: &mut HelperState, params: Option<Value>) -> Result<Value, HelperError> {
    let params: SearchCancelParams = decode_params(params)?;
    if let Some(cancelled) = state.searches.get(&params.search_id) {
        cancelled.store(true, Ordering::Release);
    }
    Ok(json!({ "ok": true }))
}

fn spawn_search(
    search_id: String,
    root: PathBuf,
    params: SearchStartParams,
    cancelled: Arc<AtomicBool>,
    sender: Sender<ServerMessage>,
) {
    std::thread::spawn(move || {
        let mut command = Command::new("rg");
        command.current_dir(root).args([
            "--json",
            "--hidden",
            "--glob",
            "!.git",
            "--max-count=200",
            "--max-columns=400",
        ]);
        command.arg(if params.case_sensitive {
            "--case-sensitive"
        } else {
            "--smart-case"
        });
        if params.whole_word {
            command.arg("--word-regexp");
        }
        if !params.regex {
            command.arg("--fixed-strings");
        }
        command
            .arg("--")
            .arg(params.query)
            .arg(".")
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());

        let mut child = match command.spawn() {
            Ok(child) => child,
            Err(error) => {
                let _ = sender.send(ServerMessage::Search(SearchNotification::Complete {
                    search_id,
                    exit_code: 127,
                    stderr: error.to_string(),
                    cancelled: false,
                }));
                return;
            }
        };
        let stdout = child.stdout.take().expect("piped stdout");
        let stderr = child.stderr.take().expect("piped stderr");
        let (line_sender, line_receiver) = mpsc::channel();
        std::thread::spawn(move || {
            for line in BufReader::new(stdout).lines().map_while(Result::ok) {
                if line_sender.send(line).is_err() {
                    break;
                }
            }
        });
        let stderr_reader = std::thread::spawn(move || {
            let mut reader = BufReader::new(stderr);
            let mut bytes = Vec::new();
            let mut chunk = [0_u8; 4096];
            while let Ok(read) = reader.read(&mut chunk) {
                if read == 0 {
                    break;
                }
                let remaining = 8192_usize.saturating_sub(bytes.len());
                bytes.extend_from_slice(&chunk[..read.min(remaining)]);
            }
            String::from_utf8_lossy(&bytes).into_owned()
        });

        let mut exit_code = None;
        loop {
            loop {
                match line_receiver.try_recv() {
                    Ok(line) => {
                        let _ = sender.send(ServerMessage::Search(SearchNotification::Line {
                            search_id: search_id.clone(),
                            line,
                        }));
                    }
                    Err(TryRecvError::Empty) => break,
                    Err(TryRecvError::Disconnected) => break,
                }
            }
            if cancelled.load(Ordering::Acquire) {
                let _ = child.kill();
            }
            match child.try_wait() {
                Ok(Some(status)) => {
                    exit_code = Some(status.code().unwrap_or(2));
                    break;
                }
                Ok(None) => std::thread::sleep(Duration::from_millis(20)),
                Err(_) => {
                    let _ = child.kill();
                    break;
                }
            }
        }
        for line in line_receiver {
            let _ = sender.send(ServerMessage::Search(SearchNotification::Line {
                search_id: search_id.clone(),
                line,
            }));
        }
        let stderr = stderr_reader.join().unwrap_or_default();
        let was_cancelled = cancelled.load(Ordering::Acquire);
        let _ = sender.send(ServerMessage::Search(SearchNotification::Complete {
            search_id,
            exit_code: exit_code.unwrap_or(2),
            stderr,
            cancelled: was_cancelled,
        }));
    });
}

fn proc_spawn(state: &mut HelperState, params: Option<Value>) -> Result<Value, HelperError> {
    let params: ProcSpawnParams = decode_params(params)?;
    validate_proc_id(&params.proc_id)?;
    let cwd = validated_proc_cwd(&params.cwd)?;
    let dir = proc_dir(&params.proc_id)?;
    std::fs::create_dir_all(&dir)
        .map_err(|error| jsonrpc_error(-32050, format!("proc dir failed: {error}")))?;
    let status = proc_status_in_dir(&dir);
    if status.running {
        register_proc_cwd(state, &params.proc_id, cwd);
        return Ok(json!({
            "procId": params.proc_id,
            "running": true,
            "exitCode": null,
            "spawned": false
        }));
    }
    state
        .proc_tailers
        .remove(&proc_tailer_key(&params.proc_id, "io"));
    state
        .proc_tailers
        .remove(&proc_tailer_key(&params.proc_id, "stdout"));
    state
        .proc_tailers
        .remove(&proc_tailer_key(&params.proc_id, "stderr"));

    let stdin_path = dir.join("stdin.log");
    let stdout_path = dir.join("stdout.log");
    let stderr_path = dir.join("stderr.log");
    let exit_path = dir.join("exit");
    let pid_path = dir.join("pid");
    let _ = std::fs::remove_file(&exit_path);
    let _ = std::fs::remove_file(&pid_path);
    create_restrictive_empty_file(&stdin_path, "stdin")?;
    create_restrictive_empty_file(&stdout_path, "stdout")?;
    create_restrictive_empty_file(&stderr_path, "stderr")?;
    let metadata = ProcMetadata {
        proc_id: params.proc_id.clone(),
        command: params.command.clone(),
        args: params.args.clone(),
        cwd: cwd.display().to_string(),
    };
    write_restrictive_bytes(
        &dir.join("meta.json"),
        &serde_json::to_vec(&metadata).expect("metadata serialization must succeed"),
        "metadata",
    )?;

    for key in params.env.keys() {
        if !is_safe_env_key(key) {
            return Err(jsonrpc_error(-32602, format!("invalid env key: {key}")));
        }
    }
    let launch = ProcSupervisorLaunch {
        command: params.command,
        args: params.args,
        cwd: cwd.display().to_string(),
        env: params.env,
        path_prefix_directories: params.path_prefix_directories.unwrap_or_default(),
    };
    write_restrictive_bytes(
        &dir.join("launch.json"),
        &serde_json::to_vec(&launch).expect("launch serialization must succeed"),
        "launch",
    )?;
    spawn_proc_supervisor(&dir)?;
    register_proc_cwd(state, &params.proc_id, cwd);
    let status = proc_status_in_dir(&dir);
    Ok(json!({
        "procId": params.proc_id,
        "running": status.running,
        "exitCode": status.exit_code,
        "spawned": true
    }))
}

fn validated_proc_cwd(requested_cwd: &str) -> Result<PathBuf, HelperError> {
    let cwd = PathBuf::from(requested_cwd);
    let metadata = std::fs::metadata(&cwd)
        .map_err(|error| jsonrpc_error(-32050, format!("invalid cwd: {error}")))?;
    if !metadata.is_dir() {
        return Err(jsonrpc_error(-32050, "cwd is not a directory"));
    }
    Ok(cwd)
}

fn register_proc_cwd(state: &mut HelperState, proc_id: &str, cwd: PathBuf) {
    state.subscriptions.insert(format!("proc:{proc_id}"), cwd);
}

fn register_persisted_proc_cwd(state: &mut HelperState, proc_id: &str, dir: &Path) {
    let Ok(bytes) = std::fs::read(dir.join("meta.json")) else {
        return;
    };
    let Ok(metadata) = serde_json::from_slice::<ProcMetadata>(&bytes) else {
        return;
    };
    if metadata.proc_id != proc_id {
        return;
    }
    let Ok(cwd) = validated_proc_cwd(&metadata.cwd) else {
        return;
    };
    register_proc_cwd(state, proc_id, cwd);
}

fn spawn_proc_supervisor(dir: &Path) -> Result<(), HelperError> {
    let exe = std::env::current_exe()
        .map_err(|error| jsonrpc_error(-32050, format!("helper path failed: {error}")))?;
    let mut command = Command::new(exe);
    command
        .arg("proc-supervise")
        .arg(dir)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        command.process_group(0);
    }
    let mut supervisor = command
        .spawn()
        .map_err(|error| jsonrpc_error(-32050, format!("supervisor spawn failed: {error}")))?;
    thread::spawn(move || {
        let _ = supervisor.wait();
    });

    let deadline = Instant::now() + Duration::from_secs(2);
    while Instant::now() < deadline {
        if dir.join("pid").is_file() || dir.join("exit").is_file() {
            return Ok(());
        }
        thread::sleep(Duration::from_millis(20));
    }
    Err(jsonrpc_error(-32050, "supervisor did not start process"))
}

fn proc_supervise(dir: PathBuf) -> Result<(), HelperError> {
    let launch_path = dir.join("launch.json");
    let launch: ProcSupervisorLaunch = serde_json::from_slice(
        &std::fs::read(&launch_path)
            .map_err(|error| jsonrpc_error(-32050, format!("launch read failed: {error}")))?,
    )
    .map_err(|error| jsonrpc_error(-32050, format!("launch decode failed: {error}")))?;
    let _ = std::fs::remove_file(&launch_path);

    let script = proc_launch_script(
        &launch.cwd,
        &launch.command,
        &launch.args,
        &launch.env,
        &launch.path_prefix_directories,
    )?;
    let stdout_file = std::fs::OpenOptions::new()
        .append(true)
        .open(dir.join("stdout.log"))
        .map_err(|error| jsonrpc_error(-32050, format!("stdout open failed: {error}")))?;
    let stderr_file = std::fs::OpenOptions::new()
        .append(true)
        .open(dir.join("stderr.log"))
        .map_err(|error| jsonrpc_error(-32050, format!("stderr open failed: {error}")))?;
    let mut command = Command::new("/bin/sh");
    command.arg("-c").arg(script);
    configure_proc_child_stdio(&mut command, stdout_file, stderr_file);
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        command.process_group(0);
    }
    let child = command
        .spawn()
        .map_err(|error| jsonrpc_error(-32050, format!("spawn failed: {error}")))?;
    write_proc_pid(&dir, child.id())?;
    run_supervised_proc_child(child, dir.join("stdin.log"), dir.join("exit"));
    Ok(())
}

fn configure_proc_child_stdio(
    command: &mut Command,
    stdout_file: std::fs::File,
    stderr_file: std::fs::File,
) {
    command
        .stdin(Stdio::piped())
        .stdout(Stdio::from(stdout_file))
        .stderr(Stdio::from(stderr_file));
}

fn run_supervised_proc_child(
    mut child: std::process::Child,
    stdin_path: PathBuf,
    exit_path: PathBuf,
) {
    let child_stdin = Option::take(&mut child.stdin);
    pump_proc_stdin_and_record_exit(child, child_stdin, stdin_path, exit_path);
}

fn proc_launch_script(
    cwd: &str,
    command: &str,
    args: &[String],
    env: &HashMap<String, String>,
    path_prefix_directories: &[String],
) -> Result<String, HelperError> {
    let mut env_parts: Vec<String> = vec!["env".to_string()];
    env_parts.extend(
        ACP_REMOTE_MARKER_SCRUB
            .iter()
            .flat_map(|key| ["-u".to_string(), (*key).to_string()]),
    );
    let mut env_keys: Vec<_> = env.keys().collect();
    env_keys.sort();
    for key in env_keys {
        if !is_safe_env_key(key) {
            return Err(jsonrpc_error(-32602, format!("invalid env key: {key}")));
        }
        let value = env.get(key).expect("key from map");
        env_parts.push(format!("{}={}", key, shell_quote(value)));
    }
    let argv = std::iter::once(command)
        .chain(args.iter().map(String::as_str))
        .map(shell_quote)
        .collect::<Vec<_>>()
        .join(" ");
    let path_prefix = if path_prefix_directories.is_empty() {
        String::new()
    } else {
        let joined = path_prefix_directories
            .iter()
            .map(|directory| shell_quote(directory))
            .collect::<Vec<_>>()
            .join(":");
        format!("PATH={joined}:\"$PATH\" && export PATH && ")
    };
    Ok(format!(
        "cd {cwd} && {path_prefix}exec {env_command} {argv}",
        cwd = shell_quote(cwd),
        path_prefix = path_prefix,
        env_command = env_parts.join(" "),
        argv = argv,
    ))
}

fn create_restrictive_empty_file(path: &Path, label: &str) -> Result<(), HelperError> {
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create(true).truncate(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let file = options
        .open(path)
        .map_err(|error| jsonrpc_error(-32050, format!("{label} create failed: {error}")))?;
    drop(file);
    set_restrictive_file_permissions(path, label)
}

fn write_restrictive_bytes(path: &Path, bytes: &[u8], label: &str) -> Result<(), HelperError> {
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create(true).truncate(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options
        .open(path)
        .map_err(|error| jsonrpc_error(-32050, format!("{label} create failed: {error}")))?;
    file.write_all(bytes)
        .map_err(|error| jsonrpc_error(-32050, format!("{label} write failed: {error}")))?;
    file.flush()
        .map_err(|error| jsonrpc_error(-32050, format!("{label} flush failed: {error}")))?;
    drop(file);
    set_restrictive_file_permissions(path, label)
}

#[cfg(unix)]
fn set_restrictive_file_permissions(path: &Path, label: &str) -> Result<(), HelperError> {
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))
        .map_err(|error| jsonrpc_error(-32050, format!("{label} chmod failed: {error}")))
}

#[cfg(not(unix))]
fn set_restrictive_file_permissions(_path: &Path, _label: &str) -> Result<(), HelperError> {
    Ok(())
}

fn proc_attach(state: &mut HelperState, params: Option<Value>) -> Result<Value, HelperError> {
    let params: ProcAttachParams = decode_params(params)?;
    validate_proc_id(&params.proc_id)?;
    let dir = proc_dir(&params.proc_id)?;
    if !dir.is_dir() {
        return Err(jsonrpc_error(-32051, "process not found"));
    }
    register_persisted_proc_cwd(state, &params.proc_id, &dir);
    let stdout_offset = requested_log_offset(&dir.join("stdout.log"), params.stdout_offset);
    let stderr_offset = requested_log_offset(&dir.join("stderr.log"), params.stderr_offset);
    let mut stdout_frames = Vec::new();
    let mut stderr_chunk = None;
    let mut stdout_next_offset = stdout_offset;
    let mut stderr_next_offset = stderr_offset;
    collect_proc_replay(
        &dir,
        &mut stdout_next_offset,
        &mut stderr_next_offset,
        &mut stdout_frames,
        &mut stderr_chunk,
    )?;
    let stdin_offset = std::fs::metadata(dir.join("stdin.log"))
        .map(|metadata| metadata.len())
        .unwrap_or(0);
    let status = proc_status_in_dir(&dir);
    if status.running {
        if let Some(sender) = state.event_sender.clone() {
            ensure_proc_tailers(
                state,
                &params.proc_id,
                &dir,
                stdout_next_offset,
                stderr_next_offset,
                sender,
            );
        }
    } else {
        collect_proc_replay(
            &dir,
            &mut stdout_next_offset,
            &mut stderr_next_offset,
            &mut stdout_frames,
            &mut stderr_chunk,
        )?;
    }
    Ok(json!({
        "procId": params.proc_id,
        "running": status.running,
        "exitCode": status.exit_code,
        "stdinOffset": stdin_offset,
        "stdoutOffset": stdout_next_offset,
        "stderrOffset": stderr_next_offset,
        "stdoutFrames": stdout_frames.into_iter().map(|frame| {
            json!({
                "offset": frame.offset,
                "dataBase64": base64::engine::general_purpose::STANDARD.encode(frame.data)
            })
        }).collect::<Vec<_>>(),
        "stderrChunks": stderr_chunk.into_iter().map(|(offset, data)| {
            json!({
                "offset": offset,
                "dataBase64": base64::engine::general_purpose::STANDARD.encode(data)
            })
        }).collect::<Vec<_>>()
    }))
}

fn collect_proc_replay(
    dir: &Path,
    stdout_offset: &mut u64,
    stderr_offset: &mut u64,
    stdout_frames: &mut Vec<ProcReplayFrame>,
    stderr_chunk: &mut Option<(u64, Vec<u8>)>,
) -> Result<(), HelperError> {
    let frames = read_stdout_frames(&dir.join("stdout.log"), *stdout_offset)?;
    if let Some(frame) = frames.last() {
        *stdout_offset = frame.offset;
    }
    stdout_frames.extend(frames);

    if let Some((next_offset, data)) = read_file_tail(&dir.join("stderr.log"), *stderr_offset)? {
        *stderr_offset = next_offset;
        if let Some((offset, existing)) = stderr_chunk.as_mut() {
            *offset = next_offset;
            existing.extend(data);
        } else {
            *stderr_chunk = Some((next_offset, data));
        }
    }
    Ok(())
}

fn ensure_proc_tailers(
    state: &mut HelperState,
    proc_id: &str,
    dir: &Path,
    stdout_offset: u64,
    stderr_offset: u64,
    sender: Sender<ServerMessage>,
) {
    if state.proc_tailers.insert(proc_tailer_key(proc_id, "io")) {
        spawn_proc_tail(
            proc_id.to_string(),
            dir.to_path_buf(),
            stdout_offset,
            stderr_offset,
            sender,
        );
    }
}

fn proc_write(params: Option<Value>) -> Result<Value, HelperError> {
    let params: ProcWriteParams = decode_params(params)?;
    validate_proc_id(&params.proc_id)?;
    let dir = proc_dir(&params.proc_id)?;
    if !dir.is_dir() {
        return Err(jsonrpc_error(-32051, "process not found"));
    }
    proc_write_in_dir(&dir, &params)
}

fn proc_write_in_dir(dir: &Path, params: &ProcWriteParams) -> Result<Value, HelperError> {
    if !proc_status_in_dir(dir).running {
        return Err(jsonrpc_error(-32051, "process not running"));
    }
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(params.data_base64.as_bytes())
        .map_err(|error| jsonrpc_error(-32602, format!("invalid base64: {error}")))?;
    let stdin_path = dir.join("stdin.log");
    let mut file = std::fs::OpenOptions::new()
        .read(true)
        .append(true)
        .open(&stdin_path)
        .map_err(|error| jsonrpc_error(-32052, format!("stdin open failed: {error}")))?;
    let current_offset = file
        .metadata()
        .map_err(|error| jsonrpc_error(-32052, format!("stdin metadata failed: {error}")))?
        .len();
    if let Some(expected_offset) = params.expected_stdin_offset {
        if current_offset != expected_offset {
            if input_log_already_contains(&mut file, expected_offset, &bytes)? {
                return Ok(
                    json!({ "ok": true, "stdinOffset": expected_offset + bytes.len() as u64 }),
                );
            }
            return Err(jsonrpc_error(
                -32053,
                format!(
                    "stdin offset mismatch: expected {expected_offset}, found {current_offset}"
                ),
            ));
        }
    }
    file.write_all(&bytes)
        .map_err(|error| jsonrpc_error(-32052, format!("stdin write failed: {error}")))?;
    file.flush()
        .map_err(|error| jsonrpc_error(-32052, format!("stdin flush failed: {error}")))?;
    Ok(json!({ "ok": true, "stdinOffset": current_offset + bytes.len() as u64 }))
}

fn pump_proc_stdin_and_record_exit(
    mut child: std::process::Child,
    mut child_stdin: Option<std::process::ChildStdin>,
    stdin_path: PathBuf,
    exit_path: PathBuf,
) {
    let mut stdin_offset = 0_u64;
    let mut buffer = [0_u8; 8192];
    loop {
        if let Some(stdin) = child_stdin.as_mut() {
            if pump_proc_stdin_once(&stdin_path, &mut stdin_offset, stdin, &mut buffer).is_err() {
                child_stdin = None;
            }
        }
        match child.try_wait() {
            Ok(Some(status)) => {
                drop(child_stdin.take());
                let code = status.code().unwrap_or(2);
                let _ = std::fs::write(&exit_path, format!("{code}\n"));
                break;
            }
            Ok(None) => thread::sleep(Duration::from_millis(20)),
            Err(_) => {
                drop(child_stdin.take());
                let _ = child.kill();
                let _ = std::fs::write(&exit_path, "2\n");
                break;
            }
        }
    }
}

fn pump_proc_stdin_once(
    path: &Path,
    offset: &mut u64,
    stdin: &mut std::process::ChildStdin,
    buffer: &mut [u8],
) -> io::Result<()> {
    let mut file = std::fs::File::open(path)?;
    file.seek(SeekFrom::Start(*offset))?;
    loop {
        let read = file.read(buffer)?;
        if read == 0 {
            break;
        }
        stdin.write_all(&buffer[..read])?;
        *offset += read as u64;
    }
    stdin.flush()
}

fn input_log_already_contains(
    file: &mut std::fs::File,
    offset: u64,
    bytes: &[u8],
) -> Result<bool, HelperError> {
    let end = offset + bytes.len() as u64;
    let len = file
        .metadata()
        .map_err(|error| jsonrpc_error(-32052, format!("stdin metadata failed: {error}")))?
        .len();
    if len < end {
        return Ok(false);
    }
    file.seek(SeekFrom::Start(offset))
        .map_err(|error| jsonrpc_error(-32052, format!("stdin seek failed: {error}")))?;
    let mut existing = vec![0_u8; bytes.len()];
    file.read_exact(&mut existing)
        .map_err(|error| jsonrpc_error(-32052, format!("stdin read failed: {error}")))?;
    Ok(existing == bytes)
}

fn proc_kill(params: Option<Value>) -> Result<Value, HelperError> {
    let params: ProcKillParams = decode_params(params)?;
    validate_proc_id(&params.proc_id)?;
    let dir = proc_dir(&params.proc_id)?;
    if let Some(pid) = verified_proc_pid(&dir) {
        terminate_process_group_and_wait(&dir, pid)?;
    }
    remove_proc_directory(&dir)?;
    Ok(json!({ "ok": true }))
}

fn remove_proc_directory(dir: &Path) -> Result<(), HelperError> {
    match std::fs::remove_dir_all(dir) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(jsonrpc_error(
            -32050,
            format!("proc cleanup failed: {error}"),
        )),
    }
}

fn proc_list() -> Result<Value, HelperError> {
    let root = proc_root()?;
    let mut entries = Vec::new();
    let Ok(read_dir) = std::fs::read_dir(root) else {
        return Ok(json!({ "entries": entries }));
    };
    for entry in read_dir.flatten() {
        let dir = entry.path();
        if !dir.is_dir() {
            continue;
        }
        let Some(proc_id) = entry.file_name().to_str().map(str::to_string) else {
            continue;
        };
        let status = proc_status_in_dir(&dir);
        entries.push(json!({
            "procId": proc_id,
            "running": status.running,
            "exitCode": status.exit_code
        }));
    }
    Ok(json!({ "entries": entries }))
}

struct ProcStatus {
    running: bool,
    exit_code: Option<i32>,
}

fn proc_status_in_dir(dir: &Path) -> ProcStatus {
    let exit_code = std::fs::read_to_string(dir.join("exit"))
        .ok()
        .and_then(|value| value.trim().parse::<i32>().ok());
    let running = exit_code.is_none() && verified_proc_pid(dir).is_some();
    ProcStatus { running, exit_code }
}

fn read_stdout_frames(path: &Path, offset: u64) -> Result<Vec<ProcReplayFrame>, HelperError> {
    use std::io::{Read, Seek};
    let mut file = match std::fs::File::open(path) {
        Ok(file) => file,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(error) => {
            return Err(jsonrpc_error(
                -32053,
                format!("stdout open failed: {error}"),
            ));
        }
    };
    file.seek(io::SeekFrom::Start(offset))
        .map_err(|error| jsonrpc_error(-32053, format!("stdout seek failed: {error}")))?;
    let mut data = Vec::new();
    file.read_to_end(&mut data)
        .map_err(|error| jsonrpc_error(-32053, format!("stdout read failed: {error}")))?;
    let mut frames = Vec::new();
    let mut start = 0;
    for (index, byte) in data.iter().enumerate() {
        if *byte != b'\n' {
            continue;
        }
        let end = index + 1;
        let frame = data[start..index].to_vec();
        frames.push(ProcReplayFrame {
            offset: offset + end as u64,
            data: frame,
        });
        start = end;
    }
    Ok(frames)
}

fn read_file_tail(path: &Path, offset: u64) -> Result<Option<(u64, Vec<u8>)>, HelperError> {
    use std::io::{Read, Seek};
    let mut file = match std::fs::File::open(path) {
        Ok(file) => file,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(error) => {
            return Err(jsonrpc_error(
                -32053,
                format!("stderr open failed: {error}"),
            ));
        }
    };
    file.seek(io::SeekFrom::Start(offset))
        .map_err(|error| jsonrpc_error(-32053, format!("stderr seek failed: {error}")))?;
    let mut data = Vec::new();
    file.read_to_end(&mut data)
        .map_err(|error| jsonrpc_error(-32053, format!("stderr read failed: {error}")))?;
    if data.is_empty() {
        Ok(None)
    } else {
        Ok(Some((offset + data.len() as u64, data)))
    }
}

fn spawn_proc_tail(
    proc_id: String,
    dir: PathBuf,
    mut stdout_offset: u64,
    mut stderr_offset: u64,
    sender: Sender<ServerMessage>,
) {
    thread::spawn(move || {
        loop {
            if drain_proc_output_once(
                &proc_id,
                &dir,
                &sender,
                &mut stdout_offset,
                &mut stderr_offset,
            )
            .is_err()
            {
                return;
            }
            let status = proc_status_in_dir(&dir);
            if !status.running {
                finish_proc_tail(
                    &proc_id,
                    &dir,
                    &sender,
                    &mut stdout_offset,
                    &mut stderr_offset,
                    status.exit_code,
                );
                return;
            }
            thread::sleep(Duration::from_millis(50));
        }
    });
}

fn finish_proc_tail(
    proc_id: &str,
    dir: &Path,
    sender: &Sender<ServerMessage>,
    stdout_offset: &mut u64,
    stderr_offset: &mut u64,
    exit_code: Option<i32>,
) {
    let _ = drain_proc_output_once(proc_id, dir, sender, stdout_offset, stderr_offset);
    let _ = sender.send(ServerMessage::Proc(ProcNotification::Exit {
        proc_id: proc_id.to_string(),
        exit_code,
    }));
}

fn drain_proc_output_once(
    proc_id: &str,
    dir: &Path,
    sender: &Sender<ServerMessage>,
    stdout_offset: &mut u64,
    stderr_offset: &mut u64,
) -> Result<(), ()> {
    match read_stdout_frames(&dir.join("stdout.log"), *stdout_offset) {
        Ok(frames) => {
            for frame in frames {
                *stdout_offset = frame.offset;
                sender
                    .send(ServerMessage::Proc(ProcNotification::Stdout {
                        proc_id: proc_id.to_string(),
                        offset: *stdout_offset,
                        data: frame.data,
                    }))
                    .map_err(|_| ())?;
            }
        }
        Err(_) => return Err(()),
    }
    match read_file_tail(&dir.join("stderr.log"), *stderr_offset) {
        Ok(Some((next_offset, data))) => {
            *stderr_offset = next_offset;
            sender
                .send(ServerMessage::Proc(ProcNotification::Stderr {
                    proc_id: proc_id.to_string(),
                    offset: *stderr_offset,
                    data,
                }))
                .map_err(|_| ())?;
        }
        Ok(None) => {}
        Err(_) => return Err(()),
    }
    Ok(())
}

fn proc_tailer_key(proc_id: &str, stream: &str) -> String {
    format!("{proc_id}:{stream}")
}

const ACP_REMOTE_MARKER_SCRUB: &[&str] = &[
    "CLAUDECODE",
    "CLAUDE_CODE",
    "CLAUDE_PROJECT_DIR",
    "CLAUDE_CODE_ENTRYPOINT",
    "CLAUDE_SESSION_ID",
];

fn validate_proc_id(proc_id: &str) -> Result<(), HelperError> {
    if proc_id.is_empty()
        || proc_id.len() > 128
        || !proc_id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
    {
        return Err(jsonrpc_error(-32602, "invalid procId"));
    }
    Ok(())
}

fn proc_root() -> Result<PathBuf, HelperError> {
    let home = std::env::var("HOME").map_err(|_| jsonrpc_error(-32050, "HOME is not set"))?;
    Ok(PathBuf::from(home).join(".alas").join("procs"))
}

fn proc_dir(proc_id: &str) -> Result<PathBuf, HelperError> {
    validate_proc_id(proc_id)?;
    Ok(proc_root()?.join(proc_id))
}

fn read_pid(dir: &Path) -> Option<u32> {
    std::fs::read_to_string(dir.join("pid"))
        .ok()
        .and_then(|value| value.split_whitespace().next()?.parse::<u32>().ok())
}

fn write_proc_pid(dir: &Path, pid: u32) -> Result<(), HelperError> {
    write_restrictive_bytes(
        dir.join("pid").as_path(),
        format!("{pid}\n").as_bytes(),
        "pid",
    )?;
    let metadata = ProcPidMetadata {
        pid,
        process_group_id: current_process_group_id(pid),
    };
    write_restrictive_bytes(
        dir.join("pid.json").as_path(),
        &serde_json::to_vec(&metadata).expect("pid metadata serialization must succeed"),
        "pid metadata",
    )
}

fn read_proc_pid_metadata(dir: &Path) -> Option<ProcPidMetadata> {
    serde_json::from_slice(&std::fs::read(dir.join("pid.json")).ok()?).ok()
}

fn verified_proc_pid(dir: &Path) -> Option<u32> {
    let pid = read_pid(dir)?;
    if !pid_is_alive(pid) {
        mark_stale_proc_pid(dir);
        return None;
    }
    let Some(metadata) = read_proc_pid_metadata(dir) else {
        return Some(pid);
    };
    if metadata.pid != pid {
        mark_stale_proc_pid(dir);
        return None;
    }
    if let Some(expected_pgid) = metadata.process_group_id {
        if current_process_group_id(pid) != Some(expected_pgid) {
            mark_stale_proc_pid(dir);
            return None;
        }
    }
    Some(pid)
}

fn mark_stale_proc_pid(dir: &Path) {
    let _ = std::fs::remove_file(dir.join("pid"));
    let _ = std::fs::remove_file(dir.join("pid.json"));
}

fn file_len(path: &Path) -> io::Result<u64> {
    Ok(std::fs::metadata(path)?.len())
}

fn requested_log_offset(path: &Path, requested_offset: Option<u64>) -> u64 {
    let len = file_len(path).unwrap_or(0);
    match requested_offset {
        Some(u64::MAX) => len,
        Some(offset) => offset.min(len),
        None => 0,
    }
}

#[cfg(unix)]
fn pid_is_alive(pid: u32) -> bool {
    unsafe { libc_kill(pid as i32, 0) == 0 }
}

#[cfg(not(unix))]
fn pid_is_alive(_pid: u32) -> bool {
    false
}

#[cfg(unix)]
fn current_process_group_id(pid: u32) -> Option<u32> {
    let pgid = unsafe { libc_getpgid(pid as i32) };
    if pgid >= 0 { Some(pgid as u32) } else { None }
}

#[cfg(not(unix))]
fn current_process_group_id(_pid: u32) -> Option<u32> {
    None
}

#[cfg(unix)]
fn terminate_process_group_and_wait(dir: &Path, pid: u32) -> Result<(), HelperError> {
    signal_process_group(pid, 15);
    if wait_for_proc_to_stop(dir, Duration::from_millis(500)) {
        return Ok(());
    }
    signal_process_group(pid, 9);
    if wait_for_proc_to_stop(dir, Duration::from_secs(2)) {
        return Ok(());
    }
    Err(jsonrpc_error(
        -32050,
        "process did not exit after kill signal",
    ))
}

#[cfg(not(unix))]
fn terminate_process_group_and_wait(_dir: &Path, _pid: u32) -> Result<(), HelperError> {
    Ok(())
}

#[cfg(unix)]
fn signal_process_group(pid: u32, signal: i32) {
    unsafe {
        let _ = libc_kill(-(pid as i32), signal);
    }
}

#[cfg(unix)]
fn wait_for_proc_to_stop(dir: &Path, timeout: Duration) -> bool {
    let deadline = Instant::now() + timeout;
    while Instant::now() < deadline {
        if proc_status_in_dir(dir).exit_code.is_some() || verified_proc_pid(dir).is_none() {
            return true;
        }
        thread::sleep(Duration::from_millis(20));
    }
    proc_status_in_dir(dir).exit_code.is_some() || verified_proc_pid(dir).is_none()
}

#[cfg(unix)]
unsafe extern "C" {
    fn kill(pid: i32, sig: i32) -> i32;
    fn getpgid(pid: i32) -> i32;
}

#[cfg(unix)]
unsafe fn libc_kill(pid: i32, sig: i32) -> i32 {
    unsafe { kill(pid, sig) }
}

#[cfg(unix)]
unsafe fn libc_getpgid(pid: i32) -> i32 {
    unsafe { getpgid(pid) }
}

fn shell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}

fn is_safe_env_key(key: &str) -> bool {
    !key.is_empty()
        && key
            .bytes()
            .all(|b| b.is_ascii_uppercase() || b.is_ascii_digit() || b == b'_')
        && !key.as_bytes()[0].is_ascii_digit()
}

fn contained_existing_path(state: &HelperState, path: &str) -> Result<PathBuf, HelperError> {
    if state.subscriptions.is_empty() {
        return Err(jsonrpc_error(-32022, "no registered roots"));
    }
    let canonical = match std::fs::canonicalize(path) {
        Ok(path) => path,
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            ensure_missing_path_parent_is_contained(state, path)?;
            return Err(jsonrpc_error(-32021, "path not found"));
        }
        Err(error) => return Err(jsonrpc_error(-32020, format!("path failed: {error}"))),
    };
    if state
        .subscriptions
        .values()
        .any(|root| canonical.starts_with(root))
    {
        Ok(canonical)
    } else {
        Err(jsonrpc_error(-32023, "path outside registered roots"))
    }
}

fn contained_write_path(state: &HelperState, path: &str) -> Result<PathBuf, HelperError> {
    if state.subscriptions.is_empty() {
        return Err(jsonrpc_error(-32022, "no registered roots"));
    }
    let path = Path::new(path);
    let parent = path
        .parent()
        .ok_or_else(|| jsonrpc_error(-32020, "path has no parent"))?;
    let parent = std::fs::canonicalize(parent)
        .map_err(|error| jsonrpc_error(-32020, format!("parent failed: {error}")))?;
    if !state
        .subscriptions
        .values()
        .any(|root| parent.starts_with(root))
    {
        return Err(jsonrpc_error(-32023, "path outside registered roots"));
    }
    let file_name = path
        .file_name()
        .ok_or_else(|| jsonrpc_error(-32020, "path has no filename"))?;
    let target = parent.join(file_name);
    match std::fs::symlink_metadata(&target) {
        Ok(metadata) if metadata.file_type().is_symlink() => {
            Err(jsonrpc_error(-32025, "path is a symbolic link"))
        }
        Ok(_) => Ok(target),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(target),
        Err(error) => Err(jsonrpc_error(-32020, format!("path failed: {error}"))),
    }
}

fn write_replacing_path(path: &Path, content: &str) -> Result<(), HelperError> {
    let parent = path
        .parent()
        .ok_or_else(|| jsonrpc_error(-32020, "path has no parent"))?;
    let file_name = path
        .file_name()
        .ok_or_else(|| jsonrpc_error(-32020, "path has no filename"))?
        .to_string_lossy();
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_nanos())
        .unwrap_or_default();
    let temp = parent.join(format!(
        ".{file_name}.alas-helper-write-{}-{nonce}",
        std::process::id()
    ));

    write_restrictive_temp_file(&temp, content)?;
    if let Err(error) = apply_final_write_permissions(path, &temp, parent, &file_name) {
        let _ = std::fs::remove_file(&temp);
        return Err(error);
    }
    if let Err(error) = std::fs::rename(&temp, path) {
        let _ = std::fs::remove_file(&temp);
        return Err(jsonrpc_error(-32020, format!("rename failed: {error}")));
    }
    Ok(())
}

fn write_restrictive_temp_file(path: &Path, content: &str) -> Result<(), HelperError> {
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options
        .open(path)
        .map_err(|error| jsonrpc_error(-32020, format!("temp create failed: {error}")))?;
    file.write_all(content.as_bytes())
        .map_err(|error| jsonrpc_error(-32020, format!("write failed: {error}")))
}

fn apply_final_write_permissions(
    path: &Path,
    temp: &Path,
    parent: &Path,
    file_name: &str,
) -> Result<(), HelperError> {
    let permissions = match std::fs::metadata(path) {
        Ok(metadata) => metadata.permissions(),
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            return apply_new_file_permissions(temp, parent, file_name);
        }
        Err(error) => return Err(jsonrpc_error(-32020, format!("metadata failed: {error}"))),
    };
    std::fs::set_permissions(temp, permissions)
        .map_err(|error| jsonrpc_error(-32020, format!("chmod failed: {error}")))
}

#[cfg(unix)]
fn apply_new_file_permissions(
    temp: &Path,
    parent: &Path,
    file_name: &str,
) -> Result<(), HelperError> {
    let probe = parent.join(format!(
        ".{file_name}.alas-helper-mode-probe-{}-{}",
        std::process::id(),
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|duration| duration.as_nanos())
            .unwrap_or_default()
    ));
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create_new(true);
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o666);
    }
    let probe_file = options
        .open(&probe)
        .map_err(|error| jsonrpc_error(-32020, format!("mode probe failed: {error}")))?;
    drop(probe_file);
    let permissions = match std::fs::metadata(&probe) {
        Ok(metadata) => metadata.permissions(),
        Err(error) => {
            let _ = std::fs::remove_file(&probe);
            return Err(jsonrpc_error(
                -32020,
                format!("mode probe metadata failed: {error}"),
            ));
        }
    };
    let _ = std::fs::remove_file(&probe);
    std::fs::set_permissions(temp, permissions)
        .map_err(|error| jsonrpc_error(-32020, format!("chmod failed: {error}")))
}

#[cfg(not(unix))]
fn apply_new_file_permissions(
    _temp: &Path,
    _parent: &Path,
    _file_name: &str,
) -> Result<(), HelperError> {
    Ok(())
}

fn ensure_missing_path_parent_is_contained(
    state: &HelperState,
    path: &str,
) -> Result<(), HelperError> {
    let path = Path::new(path);
    let mut ancestor = path
        .parent()
        .ok_or_else(|| jsonrpc_error(-32020, "path has no parent"))?;
    let parent = loop {
        match std::fs::canonicalize(ancestor) {
            Ok(parent) => break parent,
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                ancestor = ancestor
                    .parent()
                    .ok_or_else(|| jsonrpc_error(-32021, "path not found"))?;
            }
            Err(error) => {
                return Err(jsonrpc_error(-32020, format!("parent failed: {error}")));
            }
        }
    };
    if state
        .subscriptions
        .values()
        .any(|root| parent.starts_with(root))
    {
        Ok(())
    } else {
        Err(jsonrpc_error(-32023, "path outside registered roots"))
    }
}

fn modified_seconds(metadata: &std::fs::Metadata) -> Option<f64> {
    let modified = metadata.modified().ok()?;
    let duration = modified.duration_since(UNIX_EPOCH).ok()?;
    Some(duration.as_secs() as f64 + f64::from(duration.subsec_nanos()) / 1_000_000_000.0)
}

fn decode_params<T: for<'de> Deserialize<'de>>(params: Option<Value>) -> Result<T, HelperError> {
    let params = params.ok_or_else(|| jsonrpc_error(-32602, "missing params"))?;
    serde_json::from_value(params)
        .map_err(|error| jsonrpc_error(-32602, format!("invalid params: {error}")))
}

fn success_response(id: Value, result: Value) -> String {
    json!({
        "jsonrpc": "2.0",
        "id": id,
        "result": result
    })
    .to_string()
}

fn error_response(id: Value, code: i64, message: impl Into<String>) -> String {
    json!({
        "jsonrpc": "2.0",
        "id": id,
        "error": {
            "code": code,
            "message": message.into()
        }
    })
    .to_string()
}

fn jsonrpc_error(code: i64, message: impl Into<String>) -> HelperError {
    HelperError {
        code,
        message: message.into(),
    }
}

#[allow(dead_code)]
fn system_time_seconds(time: SystemTime) -> Option<f64> {
    let duration = time.duration_since(UNIX_EPOCH).ok()?;
    Some(duration.as_secs() as f64 + f64::from(duration.subsec_nanos()) / 1_000_000_000.0)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn append_to_file(path: &Path, bytes: &[u8]) -> io::Result<()> {
        let mut file = std::fs::OpenOptions::new().append(true).open(path)?;
        file.write_all(bytes)
    }

    #[test]
    fn bundled_manifest_matches_handshake() {
        let manifest: Handshake<'_> =
            serde_json::from_str(include_str!("../manifest.json")).expect("valid manifest");
        assert_eq!(manifest, handshake());
    }

    #[test]
    fn hello_returns_protocol_capabilities() {
        let mut state = HelperState::default();
        let response = handle_line(
            &mut state,
            r#"{"jsonrpc":"2.0","id":1,"method":"hello","params":{"clientName":"Alas","protocolVersion":1}}"#,
        )
        .expect("response");
        let value: Value = serde_json::from_str(&response).expect("json");
        assert_eq!(value["result"]["protocolVersion"], 1);
        assert_eq!(
            value["result"]["capabilities"]["watchKinds"],
            json!(["files", "git"])
        );
        assert_eq!(value["result"]["capabilities"]["fs"]["read"], true);
    }

    #[test]
    fn notification_without_id_has_no_response() {
        let mut state = HelperState::default();
        assert!(
            handle_line(
                &mut state,
                r#"{"jsonrpc":"2.0","method":"watch/event","params":{}}"#
            )
            .is_none()
        );
    }

    #[test]
    fn input_log_already_contains_detects_idempotent_retry() {
        let root = std::env::temp_dir().join(format!(
            "alas-helper-proc-input-{}-{}",
            std::process::id(),
            system_time_seconds(SystemTime::now()).unwrap()
        ));
        std::fs::create_dir_all(&root).expect("root");
        let path = root.join("stdin.log");
        std::fs::write(&path, b"first\nsecond\n").expect("input log");
        let mut file = std::fs::OpenOptions::new()
            .read(true)
            .append(true)
            .open(&path)
            .expect("open input log");

        assert!(input_log_already_contains(&mut file, 6, b"second\n").expect("contains check"));
        assert!(!input_log_already_contains(&mut file, 6, b"other\n").expect("contains mismatch"));
        assert!(
            !input_log_already_contains(&mut file, 20, b"later\n").expect("contains beyond eof")
        );

        let _ = std::fs::remove_dir_all(root);
    }

    #[cfg(unix)]
    #[test]
    fn proc_cwd_validation_preserves_symlink_path() {
        use std::os::unix::fs::symlink;

        let root = std::env::temp_dir().join(format!(
            "alas-helper-proc-cwd-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(SystemTime::UNIX_EPOCH)
                .expect("time after epoch")
                .as_nanos()
        ));
        let target = root.join("target");
        let link = root.join("link");
        std::fs::create_dir_all(&target).expect("target cwd");
        symlink(&target, &link).expect("cwd symlink");

        let validated = validated_proc_cwd(link.to_str().expect("utf8 path"))
            .expect("symlink cwd should be valid");

        assert_eq!(validated, link);
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn proc_cwd_registration_uses_proc_subscription_key() {
        let mut state = HelperState::default();
        let cwd = PathBuf::from("/repo/link");

        register_proc_cwd(&mut state, "session-1", cwd.clone());

        assert_eq!(state.subscriptions.get("proc:session-1"), Some(&cwd));
    }

    #[test]
    fn proc_attach_restores_cwd_registration_from_metadata() {
        let root = std::env::temp_dir().join(format!(
            "alas-helper-proc-attach-cwd-{}-{}",
            std::process::id(),
            system_time_seconds(SystemTime::now()).unwrap()
        ));
        let cwd = root.join("repo");
        let proc_dir = root.join("proc");
        std::fs::create_dir_all(&cwd).expect("cwd");
        std::fs::create_dir_all(&proc_dir).expect("proc dir");
        let metadata = ProcMetadata {
            proc_id: "session-1".to_string(),
            command: "codex-acp".to_string(),
            args: Vec::new(),
            cwd: cwd.display().to_string(),
        };
        std::fs::write(
            proc_dir.join("meta.json"),
            serde_json::to_vec(&metadata).expect("metadata"),
        )
        .expect("metadata file");
        let mut state = HelperState::default();

        register_persisted_proc_cwd(&mut state, "session-1", &proc_dir);

        assert_eq!(state.subscriptions.get("proc:session-1"), Some(&cwd));
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn proc_write_rejects_exited_process_without_appending() {
        let root = std::env::temp_dir().join(format!(
            "alas-helper-proc-write-exited-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(SystemTime::UNIX_EPOCH)
                .expect("time after epoch")
                .as_nanos()
        ));
        std::fs::create_dir_all(&root).expect("proc dir");
        std::fs::write(root.join("stdin.log"), b"existing\n").expect("stdin log");
        std::fs::write(root.join("exit"), b"0\n").expect("exit status");
        let params = ProcWriteParams {
            proc_id: "session-1".to_string(),
            data_base64: base64::engine::general_purpose::STANDARD.encode(b"prompt\n"),
            expected_stdin_offset: Some(9),
        };

        let error = proc_write_in_dir(&root, &params).expect_err("exited proc must reject writes");

        assert_eq!(error.code, -32051);
        assert_eq!(
            std::fs::read(root.join("stdin.log")).expect("stdin contents"),
            b"existing\n"
        );
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn due_watch_events_flush_before_processing_more_requests() {
        let mut state = HelperState::default();
        state
            .subscriptions
            .insert("1".to_string(), PathBuf::from("/repo"));
        let mut pending = HashMap::from([(
            ("1".to_string(), WatchKind::Files),
            HashSet::from(["/repo/file.txt".to_string()]),
        )]);
        let mut flush_at = Some(Instant::now() - Duration::from_millis(1));
        let mut output = Vec::new();

        let did_flush = flush_due_watch_events(&mut output, &state, &mut pending, &mut flush_at)
            .expect("flush due watch events");

        assert!(did_flush);
        assert!(flush_at.is_none());
        assert!(pending.is_empty());
        let output = String::from_utf8(output).expect("utf8 output");
        assert!(output.contains(r#""method":"watch/event""#));
        assert!(output.contains("/repo/file.txt"));
    }

    #[test]
    fn stat_missing_path_requires_registered_parent() {
        let root = std::env::temp_dir().join(format!(
            "alas-helper-test-{}-{}",
            std::process::id(),
            system_time_seconds(SystemTime::now()).unwrap()
        ));
        std::fs::create_dir_all(&root).expect("root");
        let outside = std::env::temp_dir().join(format!(
            "alas-helper-outside-{}-{}",
            std::process::id(),
            system_time_seconds(SystemTime::now()).unwrap()
        ));
        std::fs::create_dir_all(&outside).expect("outside");
        let mut state = HelperState::default();
        handle_line(
            &mut state,
            &format!(
                r#"{{"jsonrpc":"2.0","id":1,"method":"watch/subscribe","params":{{"root":"{}","kinds":["files"]}}}}"#,
                root.display()
            ),
        )
        .expect("subscribe response");

        let inside_response = handle_line(
            &mut state,
            &format!(
                r#"{{"jsonrpc":"2.0","id":2,"method":"fs/stat","params":{{"paths":["{}"]}}}}"#,
                root.join("missing.txt").display()
            ),
        )
        .expect("inside response");
        let inside: Value = serde_json::from_str(&inside_response).expect("inside json");
        assert_eq!(inside["result"]["entries"][0]["exists"], false);

        let outside_response = handle_line(
            &mut state,
            &format!(
                r#"{{"jsonrpc":"2.0","id":3,"method":"fs/stat","params":{{"paths":["{}"]}}}}"#,
                outside.join("missing.txt").display()
            ),
        )
        .expect("outside response");
        let outside_json: Value = serde_json::from_str(&outside_response).expect("outside json");
        assert_eq!(outside_json["error"]["code"], -32023);

        let _ = std::fs::remove_dir_all(root);
        let _ = std::fs::remove_dir_all(outside);
    }

    #[test]
    fn stat_nested_missing_path_under_registered_root_is_absent() {
        let root = std::env::temp_dir().join(format!(
            "alas-helper-nested-missing-{}-{}",
            std::process::id(),
            system_time_seconds(SystemTime::now()).unwrap()
        ));
        std::fs::create_dir_all(&root).expect("root");
        let nested = root.join("removed").join("file.txt");

        let mut state = HelperState::default();
        state.subscriptions.insert(
            "1".to_string(),
            std::fs::canonicalize(&root).expect("canonical root"),
        );
        let result = fs_stat(
            &state,
            Some(json!({
                "paths": [nested.display().to_string()]
            })),
        )
        .expect("nested missing path should be reported absent");

        assert_eq!(result["entries"][0]["exists"], false);
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn read_returns_binary_content_as_base64() {
        let root = std::env::temp_dir().join(format!(
            "alas-helper-invalid-utf8-{}-{}",
            std::process::id(),
            system_time_seconds(SystemTime::now()).unwrap()
        ));
        std::fs::create_dir_all(&root).expect("root");
        let file = root.join("binary.dat");
        std::fs::write(&file, [0xff, 0xfe]).expect("binary file");

        let mut state = HelperState::default();
        state.subscriptions.insert(
            "1".to_string(),
            std::fs::canonicalize(&root).expect("canonical root"),
        );
        let result = fs_read(
            &state,
            Some(json!({
                "path": file.display().to_string()
            })),
        )
        .expect("binary read");

        assert_eq!(result["kind"], "file");
        assert_eq!(result["contentBase64"], "//4=");
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn read_identifies_directory() {
        let root = std::env::temp_dir().join(format!(
            "alas-helper-non-regular-{}-{}",
            std::process::id(),
            system_time_seconds(SystemTime::now()).unwrap()
        ));
        let directory = root.join("directory");
        std::fs::create_dir_all(&directory).expect("directory");

        let mut state = HelperState::default();
        state.subscriptions.insert(
            "1".to_string(),
            std::fs::canonicalize(&root).expect("canonical root"),
        );
        let result = fs_read(
            &state,
            Some(json!({
                "path": directory.display().to_string()
            })),
        )
        .expect("directory result");

        assert_eq!(result["kind"], "directory");
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn line_counts_are_unbounded_and_list_preserves_names() {
        let root = std::env::temp_dir().join(format!(
            "alas-helper-stats-{}-{}",
            std::process::id(),
            system_time_seconds(SystemTime::now()).unwrap()
        ));
        std::fs::create_dir_all(root.join("folder")).expect("root");
        std::fs::write(root.join("a file.txt"), "one\ntwo\n").expect("file");

        let mut state = HelperState::default();
        state.subscriptions.insert(
            "1".to_string(),
            std::fs::canonicalize(&root).expect("canonical root"),
        );
        let counts = fs_line_counts(
            &state,
            Some(json!({
                "root": root.display().to_string(),
                "paths": ["a file.txt", "missing.txt"]
            })),
        )
        .expect("line counts");
        assert_eq!(
            counts["entries"],
            json!([{"path": "a file.txt", "lineCount": 2}])
        );

        let listing = fs_list(&state, Some(json!({ "path": root.display().to_string() })))
            .expect("directory listing");
        assert_eq!(listing["entries"][0]["name"], "a file.txt");
        assert_eq!(listing["entries"][1]["name"], "folder");
        assert_eq!(listing["entries"][1]["isDirectory"], true);
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn write_mtime_gate_rejects_changed_target_before_replace() {
        let root = std::env::temp_dir().join(format!(
            "alas-helper-mtime-conflict-{}-{}",
            std::process::id(),
            system_time_seconds(SystemTime::now()).unwrap()
        ));
        std::fs::create_dir_all(&root).expect("root");
        let file = root.join("file.txt");
        std::fs::write(&file, "external").expect("file");
        let actual = modified_seconds(&std::fs::metadata(&file).expect("metadata")).unwrap();
        let mut state = HelperState::default();
        state.subscriptions.insert(
            "1".to_string(),
            std::fs::canonicalize(&root).expect("canonical root"),
        );

        let error = fs_write(
            &state,
            Some(json!({
                "path": file.display().to_string(),
                "content": "editor",
                "expectedMtime": actual - 1.0
            })),
        )
        .expect_err("stale mtime must conflict");

        assert_eq!(error.code, -32030);
        assert_eq!(std::fs::read_to_string(&file).expect("content"), "external");
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn write_content_gate_rejects_changed_target_with_matching_mtime() {
        let root = std::env::temp_dir().join(format!(
            "alas-helper-content-conflict-{}-{}",
            std::process::id(),
            system_time_seconds(SystemTime::now()).unwrap()
        ));
        std::fs::create_dir_all(&root).expect("root");
        let file = root.join("file.txt");
        std::fs::write(&file, "external").expect("file");
        let actual = modified_seconds(&std::fs::metadata(&file).expect("metadata")).unwrap();
        let mut state = HelperState::default();
        state.subscriptions.insert(
            "1".to_string(),
            std::fs::canonicalize(&root).expect("canonical root"),
        );

        let error = fs_write(
            &state,
            Some(json!({
                "path": file.display().to_string(),
                "content": "editor",
                "expectedMtime": actual,
                "expectedContent": "baseline"
            })),
        )
        .expect_err("changed content must conflict even when mtime matches");

        assert_eq!(error.code, -32030);
        assert_eq!(std::fs::read_to_string(&file).expect("content"), "external");
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn write_content_gate_accepts_matching_content_with_coarse_mtime() {
        let root = std::env::temp_dir().join(format!(
            "alas-helper-coarse-mtime-{}-{}",
            std::process::id(),
            system_time_seconds(SystemTime::now()).unwrap()
        ));
        std::fs::create_dir_all(&root).expect("root");
        let file = root.join("file.txt");
        std::fs::write(&file, "baseline").expect("file");
        let actual = modified_seconds(&std::fs::metadata(&file).expect("metadata")).unwrap();
        let coarse = if actual.fract() == 0.0 {
            actual - 0.5
        } else {
            actual.floor()
        };
        let mut state = HelperState::default();
        state.subscriptions.insert(
            "1".to_string(),
            std::fs::canonicalize(&root).expect("canonical root"),
        );

        fs_write(
            &state,
            Some(json!({
                "path": file.display().to_string(),
                "content": "editor",
                "expectedMtime": coarse,
                "expectedContent": "baseline"
            })),
        )
        .expect("matching content should tolerate mtime precision");

        assert_eq!(std::fs::read_to_string(&file).expect("content"), "editor");
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn write_content_gate_treats_directory_as_conflict() {
        let root = std::env::temp_dir().join(format!(
            "alas-helper-directory-conflict-{}-{}",
            std::process::id(),
            system_time_seconds(SystemTime::now()).unwrap()
        ));
        let directory = root.join("file.txt");
        std::fs::create_dir_all(&directory).expect("directory");
        let mut state = HelperState::default();
        state.subscriptions.insert(
            "1".to_string(),
            std::fs::canonicalize(&root).expect("canonical root"),
        );

        let error = fs_write(
            &state,
            Some(json!({
                "path": directory.display().to_string(),
                "content": "editor",
                "expectedContent": "baseline"
            })),
        )
        .expect_err("unreadable baseline must conflict");

        assert_eq!(error.code, -32030);
        assert!(directory.is_dir());
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn write_rejects_symlink_without_modifying_target() {
        let root = std::env::temp_dir().join(format!(
            "alas-helper-symlink-write-{}-{}",
            std::process::id(),
            system_time_seconds(SystemTime::now()).unwrap()
        ));
        std::fs::create_dir_all(&root).expect("root");
        let target = root.join("target.txt");
        let link = root.join("link.txt");
        std::fs::write(&target, "target").expect("target");
        std::os::unix::fs::symlink(&target, &link).expect("symlink");
        let mut state = HelperState::default();
        state.subscriptions.insert(
            "1".to_string(),
            std::fs::canonicalize(&root).expect("canonical root"),
        );

        let error = fs_write(
            &state,
            Some(json!({
                "path": link.display().to_string(),
                "content": "editor"
            })),
        )
        .expect_err("symlink writes must be rejected");

        assert_eq!(error.code, -32025);
        let guarded_error = fs_write(
            &state,
            Some(json!({
                "path": link.display().to_string(),
                "content": "editor",
                "expectedContent": "target"
            })),
        )
        .expect_err("guarded symlink writes must conflict");
        assert_eq!(guarded_error.code, -32030);
        assert_eq!(std::fs::read_to_string(&target).expect("content"), "target");
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn search_cancel_marks_the_server_side_operation() {
        let cancelled = Arc::new(AtomicBool::new(false));
        let mut state = HelperState::default();
        state
            .searches
            .insert("search-1".to_string(), cancelled.clone());

        let result = search_cancel(&mut state, Some(json!({ "searchId": "search-1" })))
            .expect("cancel response");

        assert_eq!(result["ok"], true);
        assert!(cancelled.load(Ordering::Acquire));
    }

    #[test]
    fn write_with_expected_mtime_rejects_missing_target() {
        let root = std::env::temp_dir().join(format!(
            "alas-helper-missing-mtime-{}-{}",
            std::process::id(),
            system_time_seconds(SystemTime::now()).unwrap()
        ));
        std::fs::create_dir_all(&root).expect("root");
        let missing = root.join("deleted.txt");

        let mut state = HelperState::default();
        state.subscriptions.insert(
            "1".to_string(),
            std::fs::canonicalize(&root).expect("canonical root"),
        );
        let error = fs_write(
            &state,
            Some(json!({
                "path": missing.display().to_string(),
                "content": "changed",
                "expectedMtime": 12.0
            })),
        )
        .expect_err("missing mtime target should conflict");

        assert_eq!(error.code, -32030);
        assert!(!missing.exists());
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn write_replaces_hardlink_without_mutating_outside_inode() {
        let root = std::env::temp_dir().join(format!(
            "alas-helper-hardlink-root-{}-{}",
            std::process::id(),
            system_time_seconds(SystemTime::now()).unwrap()
        ));
        let outside = std::env::temp_dir().join(format!(
            "alas-helper-hardlink-outside-{}-{}",
            std::process::id(),
            system_time_seconds(SystemTime::now()).unwrap()
        ));
        std::fs::create_dir_all(&root).expect("root");
        std::fs::create_dir_all(&outside).expect("outside");
        let outside_file = outside.join("secret.txt");
        std::fs::write(&outside_file, "original").expect("outside file");
        let link = root.join("link.txt");
        std::fs::hard_link(&outside_file, &link).expect("hardlink");

        let mut state = HelperState::default();
        state.subscriptions.insert(
            "1".to_string(),
            std::fs::canonicalize(&root).expect("canonical root"),
        );
        let result = fs_write(
            &state,
            Some(json!({
                "path": link.display().to_string(),
                "content": "changed"
            })),
        )
        .expect("write should replace the hardlink entry");

        assert!(result["mtime"].is_number());
        assert_eq!(
            std::fs::read_to_string(&outside_file).expect("outside content"),
            "original"
        );
        assert_eq!(
            std::fs::read_to_string(&link).expect("inside content"),
            "changed"
        );

        let _ = std::fs::remove_dir_all(root);
        let _ = std::fs::remove_dir_all(outside);
    }

    #[cfg(unix)]
    #[test]
    fn write_preserves_existing_file_mode() {
        use std::os::unix::fs::PermissionsExt;

        let root = std::env::temp_dir().join(format!(
            "alas-helper-mode-root-{}-{}",
            std::process::id(),
            system_time_seconds(SystemTime::now()).unwrap()
        ));
        std::fs::create_dir_all(&root).expect("root");
        let script = root.join("script.sh");
        std::fs::write(&script, "#!/bin/sh\n").expect("script");
        std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755))
            .expect("script mode");

        let mut state = HelperState::default();
        state.subscriptions.insert(
            "1".to_string(),
            std::fs::canonicalize(&root).expect("canonical root"),
        );
        fs_write(
            &state,
            Some(json!({
                "path": script.display().to_string(),
                "content": "#!/bin/sh\necho changed\n"
            })),
        )
        .expect("write should preserve mode");

        let mode = std::fs::metadata(&script)
            .expect("script metadata")
            .permissions()
            .mode();
        assert_eq!(mode & 0o777, 0o755);
        let _ = std::fs::remove_dir_all(root);
    }

    #[cfg(unix)]
    #[test]
    fn temp_write_uses_restrictive_permissions_before_replace() {
        use std::os::unix::fs::PermissionsExt;

        let root = std::env::temp_dir().join(format!(
            "alas-helper-temp-mode-{}-{}",
            std::process::id(),
            system_time_seconds(SystemTime::now()).unwrap()
        ));
        std::fs::create_dir_all(&root).expect("root");
        let temp = root.join("payload.tmp");

        write_restrictive_temp_file(&temp, "secret").expect("write temp");

        let mode = std::fs::metadata(&temp)
            .expect("temp metadata")
            .permissions()
            .mode();
        assert_eq!(mode & 0o777, 0o600);
        let _ = std::fs::remove_dir_all(root);
    }

    #[cfg(unix)]
    #[test]
    fn proc_log_creation_forces_restrictive_permissions() {
        use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};

        let root = std::env::temp_dir().join(format!(
            "alas-helper-proc-log-mode-{}-{}",
            std::process::id(),
            system_time_seconds(SystemTime::now()).unwrap()
        ));
        std::fs::create_dir_all(&root).expect("root");
        let path = root.join("stdin.log");
        let file = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o666)
            .open(&path)
            .expect("permissive input log");
        drop(file);

        create_restrictive_empty_file(&path, "stdin").expect("restrictive log");

        let metadata = std::fs::metadata(&path).expect("log metadata");
        assert_eq!(metadata.permissions().mode() & 0o777, 0o600);
        assert_eq!(metadata.len(), 0);
        let _ = std::fs::remove_dir_all(root);
    }

    #[cfg(unix)]
    #[test]
    fn proc_launch_file_uses_restrictive_permissions() {
        use std::os::unix::fs::PermissionsExt;

        let root = std::env::temp_dir().join(format!(
            "alas-helper-proc-launch-mode-{}-{}",
            std::process::id(),
            system_time_seconds(SystemTime::now()).unwrap()
        ));
        std::fs::create_dir_all(&root).expect("root");
        let path = root.join("launch.json");

        write_restrictive_bytes(&path, br#"{"env":{"TOKEN":"secret"}}"#, "launch")
            .expect("launch write");

        let mode = std::fs::metadata(&path)
            .expect("launch metadata")
            .permissions()
            .mode();
        assert_eq!(mode & 0o777, 0o600);
        let _ = std::fs::remove_dir_all(root);
    }

    #[cfg(unix)]
    #[test]
    fn proc_metadata_file_uses_restrictive_permissions() {
        use std::os::unix::fs::PermissionsExt;

        let root = std::env::temp_dir().join(format!(
            "alas-helper-proc-meta-mode-{}-{}",
            std::process::id(),
            system_time_seconds(SystemTime::now()).unwrap()
        ));
        std::fs::create_dir_all(&root).expect("root");
        let path = root.join("meta.json");

        let metadata = ProcMetadata {
            proc_id: "acp-session-1".to_string(),
            command: "codex-acp".to_string(),
            args: vec!["--stdio".to_string()],
            cwd: "/private/repo".to_string(),
        };
        write_restrictive_bytes(
            &path,
            &serde_json::to_vec(&metadata).expect("metadata"),
            "metadata",
        )
        .expect("metadata write");

        let mode = std::fs::metadata(&path)
            .expect("metadata file")
            .permissions()
            .mode();
        assert_eq!(mode & 0o777, 0o600);
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn proc_launch_script_prepends_path_prefix_before_scrubbed_env() {
        let script = proc_launch_script(
            "/srv/repo",
            "codex-acp",
            &[],
            &HashMap::new(),
            &["/managed/node/bin".to_string()],
        )
        .expect("script");

        assert!(script.starts_with(
            "cd '/srv/repo' && PATH='/managed/node/bin':\"$PATH\" && export PATH && exec env "
        ));
        assert!(script.contains("-u CLAUDECODE"));
        assert!(script.ends_with("'codex-acp'"));
    }

    #[test]
    fn proc_tail_finishes_after_draining_stdout_and_stderr() {
        let root = std::env::temp_dir().join(format!(
            "alas-helper-proc-tail-finish-{}-{}",
            std::process::id(),
            system_time_seconds(SystemTime::now()).unwrap()
        ));
        std::fs::create_dir_all(&root).expect("root");
        std::fs::write(root.join("stdout.log"), b"out\n").expect("stdout");
        std::fs::write(root.join("stderr.log"), b"err").expect("stderr");
        let (sender, receiver) = mpsc::channel();
        let mut stdout_offset = 0;
        let mut stderr_offset = 0;

        finish_proc_tail(
            "acp-session-1",
            &root,
            &sender,
            &mut stdout_offset,
            &mut stderr_offset,
            Some(7),
        );

        match receiver.try_recv().expect("stdout message") {
            ServerMessage::Proc(ProcNotification::Stdout {
                proc_id,
                offset,
                data,
            }) => {
                assert_eq!(proc_id, "acp-session-1");
                assert_eq!(offset, 4);
                assert_eq!(data, b"out");
            }
            other => panic!("unexpected first message: {other:?}"),
        }
        match receiver.try_recv().expect("stderr message") {
            ServerMessage::Proc(ProcNotification::Stderr {
                proc_id,
                offset,
                data,
            }) => {
                assert_eq!(proc_id, "acp-session-1");
                assert_eq!(offset, 3);
                assert_eq!(data, b"err");
            }
            other => panic!("unexpected second message: {other:?}"),
        }
        match receiver.try_recv().expect("exit message") {
            ServerMessage::Proc(ProcNotification::Exit { proc_id, exit_code }) => {
                assert_eq!(proc_id, "acp-session-1");
                assert_eq!(exit_code, Some(7));
            }
            other => panic!("unexpected third message: {other:?}"),
        }
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn proc_replay_can_be_collected_again_before_terminal_attach_returns() {
        let root = std::env::temp_dir().join(format!(
            "alas-helper-proc-terminal-replay-{}-{}",
            std::process::id(),
            system_time_seconds(SystemTime::now()).unwrap()
        ));
        std::fs::create_dir_all(&root).expect("root");
        std::fs::write(root.join("stdout.log"), b"early\n").expect("stdout");
        std::fs::write(root.join("stderr.log"), b"early err").expect("stderr");
        let mut stdout_offset = 0;
        let mut stderr_offset = 0;
        let mut stdout_frames = Vec::new();
        let mut stderr_chunk = None;

        collect_proc_replay(
            &root,
            &mut stdout_offset,
            &mut stderr_offset,
            &mut stdout_frames,
            &mut stderr_chunk,
        )
        .expect("initial replay");
        append_to_file(&root.join("stdout.log"), b"final\n").expect("stdout append");
        append_to_file(&root.join("stderr.log"), b" final err").expect("stderr append");
        collect_proc_replay(
            &root,
            &mut stdout_offset,
            &mut stderr_offset,
            &mut stdout_frames,
            &mut stderr_chunk,
        )
        .expect("terminal replay");

        assert_eq!(stdout_frames.len(), 2);
        assert_eq!(stdout_frames[0].offset, 6);
        assert_eq!(stdout_frames[0].data, b"early");
        assert_eq!(stdout_frames[1].offset, 12);
        assert_eq!(stdout_frames[1].data, b"final");
        assert_eq!(stderr_chunk, Some((19, b"early err final err".to_vec())));
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn remove_proc_directory_deletes_logs_and_metadata() {
        let root = std::env::temp_dir().join(format!(
            "alas-helper-proc-cleanup-{}-{}",
            std::process::id(),
            system_time_seconds(SystemTime::now()).unwrap()
        ));
        std::fs::create_dir_all(&root).expect("root");
        std::fs::write(root.join("stdin.log"), b"request").expect("stdin");
        std::fs::write(root.join("stdout.log"), b"response").expect("stdout");
        std::fs::write(root.join("stderr.log"), b"error").expect("stderr");
        std::fs::write(root.join("meta.json"), b"{}").expect("metadata");

        remove_proc_directory(&root).expect("cleanup");

        assert!(!root.exists());
    }

    #[cfg(unix)]
    #[test]
    fn terminate_process_group_escalates_before_cleanup() {
        use std::os::unix::process::CommandExt;

        let root = std::env::temp_dir().join(format!(
            "alas-helper-proc-kill-{}-{}",
            std::process::id(),
            system_time_seconds(SystemTime::now()).unwrap()
        ));
        std::fs::create_dir_all(&root).expect("root");
        let mut child = Command::new("/bin/sh");
        child
            .arg("-c")
            .arg("trap '' TERM; sleep 30")
            .process_group(0);
        let mut child = child.spawn().expect("child");
        write_proc_pid(&root, child.id()).expect("pid metadata");

        terminate_process_group_and_wait(&root, child.id()).expect("terminated");
        remove_proc_directory(&root).expect("cleanup");

        let status = child.wait().expect("wait");
        assert!(!status.success());
        assert!(!root.exists());
    }

    #[test]
    fn max_requested_log_offset_attaches_at_current_end() {
        let root = std::env::temp_dir().join(format!(
            "alas-helper-proc-offset-end-{}-{}",
            std::process::id(),
            system_time_seconds(SystemTime::now()).unwrap()
        ));
        std::fs::create_dir_all(&root).expect("root");
        let path = root.join("stdout.log");
        std::fs::write(&path, b"old response\n").expect("stdout");

        assert_eq!(requested_log_offset(&path, Some(u64::MAX)), 13);
        assert_eq!(requested_log_offset(&path, Some(4)), 4);
        assert_eq!(requested_log_offset(&path, Some(99)), 13);
        assert_eq!(requested_log_offset(&path, None), 0);
        let _ = std::fs::remove_dir_all(root);
    }

    #[cfg(unix)]
    #[test]
    fn proc_pid_metadata_uses_restrictive_permissions() {
        use std::os::unix::fs::PermissionsExt;

        let root = std::env::temp_dir().join(format!(
            "alas-helper-proc-pid-mode-{}-{}",
            std::process::id(),
            system_time_seconds(SystemTime::now()).unwrap()
        ));
        std::fs::create_dir_all(&root).expect("root");

        write_proc_pid(&root, std::process::id()).expect("pid write");

        let pid_mode = std::fs::metadata(root.join("pid"))
            .expect("pid metadata")
            .permissions()
            .mode();
        let pid_json_mode = std::fs::metadata(root.join("pid.json"))
            .expect("pid json metadata")
            .permissions()
            .mode();
        assert_eq!(pid_mode & 0o777, 0o600);
        assert_eq!(pid_json_mode & 0o777, 0o600);
        assert_eq!(verified_proc_pid(&root), Some(std::process::id()));
        let _ = std::fs::remove_dir_all(root);
    }

    #[cfg(unix)]
    #[test]
    fn proc_status_rejects_pid_with_mismatched_process_group() {
        let root = std::env::temp_dir().join(format!(
            "alas-helper-proc-stale-pid-{}-{}",
            std::process::id(),
            system_time_seconds(SystemTime::now()).unwrap()
        ));
        std::fs::create_dir_all(&root).expect("root");
        let pid = std::process::id();
        write_restrictive_bytes(
            root.join("pid").as_path(),
            format!("{pid}\n").as_bytes(),
            "pid",
        )
        .expect("pid write");
        let wrong_group = current_process_group_id(pid).unwrap_or(pid).wrapping_add(1);
        let metadata = ProcPidMetadata {
            pid,
            process_group_id: Some(wrong_group),
        };
        write_restrictive_bytes(
            root.join("pid.json").as_path(),
            &serde_json::to_vec(&metadata).expect("pid metadata"),
            "pid metadata",
        )
        .expect("pid metadata write");

        let status = proc_status_in_dir(&root);
        assert!(!status.running);
        assert!(!root.join("pid").exists());
        assert!(!root.join("pid.json").exists());
        let _ = std::fs::remove_dir_all(root);
    }

    #[cfg(unix)]
    #[test]
    fn write_new_file_uses_default_file_mode() {
        use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};

        let root = std::env::temp_dir().join(format!(
            "alas-helper-new-file-mode-{}-{}",
            std::process::id(),
            system_time_seconds(SystemTime::now()).unwrap()
        ));
        std::fs::create_dir_all(&root).expect("root");
        let expected_mode = {
            let probe = root.join("probe");
            let mut options = std::fs::OpenOptions::new();
            options.write(true).create_new(true).mode(0o666);
            let file = options.open(&probe).expect("probe");
            drop(file);
            let mode = std::fs::metadata(&probe)
                .expect("probe metadata")
                .permissions()
                .mode()
                & 0o777;
            std::fs::remove_file(&probe).expect("remove probe");
            mode
        };
        let file = root.join("created.txt");
        let mut state = HelperState::default();
        state.subscriptions.insert(
            "1".to_string(),
            std::fs::canonicalize(&root).expect("canonical root"),
        );

        fs_write(
            &state,
            Some(json!({
                "path": file.display().to_string(),
                "content": "new\n"
            })),
        )
        .expect("write should create file");

        let mode = std::fs::metadata(&file)
            .expect("file metadata")
            .permissions()
            .mode()
            & 0o777;
        assert_eq!(mode, expected_mode);
        let _ = std::fs::remove_dir_all(root);
    }

    #[cfg(unix)]
    #[test]
    fn write_rejects_symlink_target_outside_registered_root() {
        use std::os::unix::fs::symlink;

        let root = std::env::temp_dir().join(format!(
            "alas-helper-symlink-root-{}-{}",
            std::process::id(),
            system_time_seconds(SystemTime::now()).unwrap()
        ));
        let outside = std::env::temp_dir().join(format!(
            "alas-helper-symlink-outside-{}-{}",
            std::process::id(),
            system_time_seconds(SystemTime::now()).unwrap()
        ));
        std::fs::create_dir_all(&root).expect("root");
        std::fs::create_dir_all(&outside).expect("outside");
        let outside_file = outside.join("secret.txt");
        std::fs::write(&outside_file, "original").expect("outside file");
        let link = root.join("link.txt");
        symlink(&outside_file, &link).expect("symlink");

        let mut state = HelperState::default();
        state.subscriptions.insert(
            "1".to_string(),
            std::fs::canonicalize(&root).expect("canonical root"),
        );
        let error = fs_write(
            &state,
            Some(json!({
                "path": link.display().to_string(),
                "content": "changed"
            })),
        )
        .expect_err("write should reject symlink");

        assert_eq!(error.code, -32025);
        assert_eq!(
            std::fs::read_to_string(&outside_file).expect("outside content"),
            "original"
        );

        let _ = std::fs::remove_dir_all(root);
        let _ = std::fs::remove_dir_all(outside);
    }
}
