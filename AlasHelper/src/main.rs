mod watch;

use base64::Engine;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};
use std::io::{self, BufRead, BufReader, Read, Write};
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

#[derive(Debug)]
struct ProcReplayFrame {
    offset: u64,
    data: Vec<u8>,
}

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

pub(crate) enum ServerMessage {
    Request(String),
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
        "proc": true,
        "ping": true
    })
}

fn main() {
    let command = std::env::args().nth(1);
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
                if let Some(response) = handle_line(&mut state, &line) {
                    write_json_line(&mut stdout, &response)?;
                }
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
    let cwd = std::fs::canonicalize(&params.cwd)
        .map_err(|error| jsonrpc_error(-32050, format!("invalid cwd: {error}")))?;
    if !cwd.is_dir() {
        return Err(jsonrpc_error(-32050, "cwd is not a directory"));
    }
    let dir = proc_dir(&params.proc_id)?;
    std::fs::create_dir_all(&dir)
        .map_err(|error| jsonrpc_error(-32050, format!("proc dir failed: {error}")))?;
    let status = proc_status_in_dir(&dir);
    if status.running {
        return Ok(json!({
            "procId": params.proc_id,
            "running": true,
            "exitCode": null
        }));
    }

    let stdin_path = dir.join("stdin.log");
    let stdout_path = dir.join("stdout.log");
    let stderr_path = dir.join("stderr.log");
    let exit_path = dir.join("exit");
    let pid_path = dir.join("pid");
    let _ = std::fs::remove_file(&exit_path);
    std::fs::File::create(&stdin_path)
        .map_err(|error| jsonrpc_error(-32050, format!("stdin create failed: {error}")))?;
    std::fs::File::create(&stdout_path)
        .map_err(|error| jsonrpc_error(-32050, format!("stdout create failed: {error}")))?;
    std::fs::File::create(&stderr_path)
        .map_err(|error| jsonrpc_error(-32050, format!("stderr create failed: {error}")))?;
    let metadata = ProcMetadata {
        proc_id: params.proc_id.clone(),
        command: params.command.clone(),
        args: params.args.clone(),
        cwd: cwd.display().to_string(),
    };
    std::fs::write(
        dir.join("meta.json"),
        serde_json::to_vec(&metadata).expect("metadata serialization must succeed"),
    )
    .map_err(|error| jsonrpc_error(-32050, format!("metadata write failed: {error}")))?;

    let mut env_parts: Vec<String> = vec!["env".to_string()];
    env_parts.extend(
        ACP_REMOTE_MARKER_SCRUB
            .iter()
            .flat_map(|key| ["-u".to_string(), (*key).to_string()]),
    );
    let mut env_keys: Vec<_> = params.env.keys().collect();
    env_keys.sort();
    for key in env_keys {
        if !is_safe_env_key(key) {
            return Err(jsonrpc_error(-32602, format!("invalid env key: {key}")));
        }
        let value = params.env.get(key).expect("key from map");
        env_parts.push(format!("{}={}", key, shell_quote(value)));
    }
    let argv = std::iter::once(params.command.as_str())
        .chain(params.args.iter().map(String::as_str))
        .map(shell_quote)
        .collect::<Vec<_>>()
        .join(" ");
    let env_command = env_parts.join(" ");
    let script = format!(
        "cd {cwd} && tail -n +1 -f {stdin} | {env_command} {argv} > {stdout} 2> {stderr}; status=$?; printf '%s\\n' \"$status\" > {exit}",
        cwd = shell_quote(cwd.to_string_lossy().as_ref()),
        stdin = shell_quote(stdin_path.to_string_lossy().as_ref()),
        stdout = shell_quote(stdout_path.to_string_lossy().as_ref()),
        stderr = shell_quote(stderr_path.to_string_lossy().as_ref()),
        exit = shell_quote(exit_path.to_string_lossy().as_ref()),
        env_command = env_command,
        argv = argv,
    );
    let mut command = Command::new("/bin/sh");
    command
        .arg("-c")
        .arg(script)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        command.process_group(0);
    }
    let mut child = command
        .spawn()
        .map_err(|error| jsonrpc_error(-32050, format!("spawn failed: {error}")))?;
    std::fs::write(&pid_path, format!("{}\n", child.id()))
        .map_err(|error| jsonrpc_error(-32050, format!("pid write failed: {error}")))?;
    thread::spawn(move || {
        let _ = child.wait();
    });
    state
        .subscriptions
        .insert(format!("proc:{}", params.proc_id), cwd);
    Ok(json!({
        "procId": params.proc_id,
        "running": true,
        "exitCode": null
    }))
}

fn proc_attach(state: &mut HelperState, params: Option<Value>) -> Result<Value, HelperError> {
    let params: ProcAttachParams = decode_params(params)?;
    validate_proc_id(&params.proc_id)?;
    let dir = proc_dir(&params.proc_id)?;
    if !dir.is_dir() {
        return Err(jsonrpc_error(-32051, "process not found"));
    }
    let stdout_offset = params.stdout_offset.unwrap_or(0);
    let stderr_offset = params.stderr_offset.unwrap_or(0);
    let stdout_frames = read_stdout_frames(&dir.join("stdout.log"), stdout_offset)?;
    let stderr_chunk = read_file_tail(&dir.join("stderr.log"), stderr_offset)?;
    let stdout_next_offset = stdout_frames
        .last()
        .map(|frame| frame.offset)
        .unwrap_or(stdout_offset);
    let stderr_next_offset = stderr_chunk
        .as_ref()
        .map(|(offset, _)| *offset)
        .unwrap_or(stderr_offset);
    let status = proc_status_in_dir(&dir);
    if status.running {
        if let Some(sender) = state.event_sender.clone() {
            spawn_proc_stdout_tail(
                params.proc_id.clone(),
                dir.clone(),
                stdout_next_offset,
                sender.clone(),
            );
            spawn_proc_stderr_tail(
                params.proc_id.clone(),
                dir.clone(),
                stderr_next_offset,
                sender,
            );
        }
    }
    Ok(json!({
        "procId": params.proc_id,
        "running": status.running,
        "exitCode": status.exit_code,
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

fn proc_write(params: Option<Value>) -> Result<Value, HelperError> {
    let params: ProcWriteParams = decode_params(params)?;
    validate_proc_id(&params.proc_id)?;
    let dir = proc_dir(&params.proc_id)?;
    if !dir.is_dir() {
        return Err(jsonrpc_error(-32051, "process not found"));
    }
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(params.data_base64.as_bytes())
        .map_err(|error| jsonrpc_error(-32602, format!("invalid base64: {error}")))?;
    let mut file = std::fs::OpenOptions::new()
        .append(true)
        .open(dir.join("stdin.log"))
        .map_err(|error| jsonrpc_error(-32052, format!("stdin open failed: {error}")))?;
    file.write_all(&bytes)
        .map_err(|error| jsonrpc_error(-32052, format!("stdin write failed: {error}")))?;
    file.flush()
        .map_err(|error| jsonrpc_error(-32052, format!("stdin flush failed: {error}")))?;
    Ok(json!({ "ok": true }))
}

fn proc_kill(params: Option<Value>) -> Result<Value, HelperError> {
    let params: ProcKillParams = decode_params(params)?;
    validate_proc_id(&params.proc_id)?;
    let dir = proc_dir(&params.proc_id)?;
    if let Some(pid) = read_pid(&dir) {
        kill_process_group(pid);
    }
    Ok(json!({ "ok": true }))
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
    let running = exit_code.is_none() && read_pid(dir).map(pid_is_alive).unwrap_or(false);
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

fn spawn_proc_stdout_tail(
    proc_id: String,
    dir: PathBuf,
    mut offset: u64,
    sender: Sender<ServerMessage>,
) {
    thread::spawn(move || {
        loop {
            match read_stdout_frames(&dir.join("stdout.log"), offset) {
                Ok(frames) if frames.is_empty() => {}
                Ok(frames) => {
                    for frame in frames {
                        offset = frame.offset;
                        if sender
                            .send(ServerMessage::Proc(ProcNotification::Stdout {
                                proc_id: proc_id.clone(),
                                offset,
                                data: frame.data,
                            }))
                            .is_err()
                        {
                            return;
                        }
                    }
                }
                Err(_) => return,
            }
            if proc_status_in_dir(&dir).exit_code.is_some() {
                let _ = sender.send(ServerMessage::Proc(ProcNotification::Exit {
                    proc_id,
                    exit_code: proc_status_in_dir(&dir).exit_code,
                }));
                return;
            }
            thread::sleep(Duration::from_millis(50));
        }
    });
}

fn spawn_proc_stderr_tail(
    proc_id: String,
    dir: PathBuf,
    mut offset: u64,
    sender: Sender<ServerMessage>,
) {
    thread::spawn(move || {
        loop {
            match read_file_tail(&dir.join("stderr.log"), offset) {
                Ok(Some((next_offset, data))) => {
                    offset = next_offset;
                    if sender
                        .send(ServerMessage::Proc(ProcNotification::Stderr {
                            proc_id: proc_id.clone(),
                            offset,
                            data,
                        }))
                        .is_err()
                    {
                        return;
                    }
                }
                Ok(None) => {}
                Err(_) => return,
            }
            if proc_status_in_dir(&dir).exit_code.is_some() {
                return;
            }
            thread::sleep(Duration::from_millis(100));
        }
    });
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
        .and_then(|value| value.trim().parse::<u32>().ok())
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
fn kill_process_group(pid: u32) {
    unsafe {
        let _ = libc_kill(-(pid as i32), 15);
    }
}

#[cfg(not(unix))]
fn kill_process_group(_pid: u32) {}

#[cfg(unix)]
unsafe extern "C" {
    fn kill(pid: i32, sig: i32) -> i32;
}

#[cfg(unix)]
unsafe fn libc_kill(pid: i32, sig: i32) -> i32 {
    unsafe { kill(pid, sig) }
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
