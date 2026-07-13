mod watch;

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};
use std::io::{self, BufRead, Write};
use std::path::{Path, PathBuf};
use std::sync::mpsc::{self, RecvTimeoutError, Sender};
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
    subscriptions: HashMap<String, PathBuf>,
    watchers: HashMap<String, SubscriptionWatcher>,
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
}

#[derive(Debug, Deserialize)]
struct FsStatParams {
    paths: Vec<String>,
}

pub(crate) enum ServerMessage {
    Request(String),
    Watch(WatchNotification),
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
            "stat": true
        },
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
    let path = contained_existing_path(state, &params.path)?;
    let metadata = std::fs::metadata(&path)
        .map_err(|error| jsonrpc_error(-32020, format!("metadata failed: {error}")))?;
    if !metadata.is_file() {
        return Err(jsonrpc_error(-32025, "path is not a regular file"));
    }
    let bytes = std::fs::read(&path)
        .map_err(|error| jsonrpc_error(-32020, format!("read failed: {error}")))?;
    let offset = params.offset.unwrap_or(0) as usize;
    let content = std::str::from_utf8(bytes.get(offset..).unwrap_or_default())
        .map_err(|error| jsonrpc_error(-32024, format!("invalid utf-8: {error}")))?
        .to_string();
    let mtime = modified_seconds(&metadata);
    Ok(json!({ "content": content, "mtime": mtime }))
}

fn fs_write(state: &HelperState, params: Option<Value>) -> Result<Value, HelperError> {
    let params: FsWriteParams = decode_params(params)?;
    let path = contained_write_path(state, &params.path)?;
    if let Some(expected) = params.expected_mtime {
        let metadata = std::fs::metadata(&path).map_err(|error| {
            if error.kind() == io::ErrorKind::NotFound {
                jsonrpc_error(-32030, "mtime target missing")
            } else {
                jsonrpc_error(-32020, format!("mtime failed: {error}"))
            }
        })?;
        if let Some(actual) = modified_seconds(&metadata) {
            if (actual - expected).abs() > 0.000_001 {
                return Err(jsonrpc_error(-32030, "mtime mismatch"));
            }
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
            let canonical = std::fs::canonicalize(&target).map_err(|error| {
                jsonrpc_error(-32020, format!("symlink target failed: {error}"))
            })?;
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
    fn read_rejects_invalid_utf8() {
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
        let error = fs_read(
            &state,
            Some(json!({
                "path": file.display().to_string()
            })),
        )
        .expect_err("invalid utf-8 should be rejected");

        assert_eq!(error.code, -32024);
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn read_rejects_non_regular_file() {
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
        let error = fs_read(
            &state,
            Some(json!({
                "path": directory.display().to_string()
            })),
        )
        .expect_err("non-regular files should be rejected");

        assert_eq!(error.code, -32025);
        let _ = std::fs::remove_dir_all(root);
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
        .expect_err("write should reject escaping symlink");

        assert_eq!(error.code, -32023);
        assert_eq!(
            std::fs::read_to_string(&outside_file).expect("outside content"),
            "original"
        );

        let _ = std::fs::remove_dir_all(root);
        let _ = std::fs::remove_dir_all(outside);
    }
}
