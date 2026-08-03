use crate::acp_broker::{
    ACPBrokerMetadata, ACPBrokerSnapshot, ACPBrokerState, AdapterRPCOutcome, BrokerGeneration,
    BrokerId, BrokerTurnState, JSONRPCErrorObject, OperationKey, PendingClientRequestKind,
};
use crate::acp_broker_protocol::{
    AcpAckParams, AcpAttachParams, AcpCloseParams, AcpDetachParams, AcpNotifyParams, AcpOpenParams,
    AcpOpenResult, AcpRespondParams, AcpSendParams,
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::io::{self, BufRead, BufReader, BufWriter, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

#[cfg(unix)]
use std::os::unix::net::{UnixListener, UnixStream};

/// How long the supervisor waits for an accepted client to deliver a complete
/// request line. The read happens on the accept thread, so a client that
/// connects and then goes quiet — a stalled writer, or one killed between
/// `connect()` and `write()` — would otherwise stop the broker from ever
/// accepting another connection.
const IPC_REQUEST_TIMEOUT: Duration = Duration::from_secs(5);

/// How long a caller gives a broker to send *something* before treating it as
/// wedged. Idle rather than total, because a legitimate response has no size
/// we can predict and therefore no duration we can predict either: the reply
/// to a maximal image prompt carries its params
/// twice and measures ~15s just to serialize, silently, before a byte is
/// written. A total budget would have to out-guess that; an idle budget only
/// has to notice a broker that has stopped.
///
/// It is still worth keeping tight-ish, because `send_ipc` runs inline on the
/// helper's single-threaded serve loop, so this is also how long one wedged
/// broker freezes every other session. Moving `acp/*` dispatch off that thread
/// would decouple the two and let this be far more generous.
const BROKER_IPC_IDLE_TIMEOUT: Duration = Duration::from_secs(20);

/// How long a single write to a broker may block. Writing even a maximal
/// request measures ~0.2s, so this only ever fires on a broker that has
/// stopped reading.
const BROKER_IPC_WRITE_TIMEOUT: Duration = Duration::from_secs(20);

#[derive(Debug)]
pub struct AcpBrokerProcessError {
    pub code: i64,
    pub message: String,
}

impl AcpBrokerProcessError {
    fn new(code: i64, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct BrokerLaunch {
    broker_id: BrokerId,
    session_id: String,
    command: String,
    args: Vec<String>,
    cwd: String,
    env: HashMap<String, String>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct BrokerPidMetadata {
    pid: u32,
    process_group_id: Option<u32>,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct BrokerIpcRequest {
    method: String,
    params: Option<Value>,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct BrokerIpcResponse {
    ok: bool,
    result: Option<Value>,
    error: Option<String>,
}

#[derive(Clone)]
struct Runtime {
    state: Arc<(Mutex<RuntimeState>, Condvar)>,
    adapter_stdin: Arc<Mutex<std::process::ChildStdin>>,
}

struct RuntimeState {
    broker: ACPBrokerState,
    pending_methods: HashMap<u64, PendingOperation>,
    adapter_process_group_id: Option<u32>,
    adapter_exited: bool,
    closing: bool,
}

#[derive(Clone, Debug)]
struct PendingOperation {
    operation_key: OperationKey,
    method: String,
}

pub fn handle_control_request(
    method: &str,
    params: Option<Value>,
) -> Result<Value, AcpBrokerProcessError> {
    match method {
        "acp/open" => acp_open(params),
        "acp/attach" => acp_attach(params),
        "acp/send" => acp_send(params),
        "acp/notify" => acp_notify(params),
        "acp/respond" => acp_respond(params),
        "acp/ack" => acp_ack(params),
        "acp/detach" => acp_detach(params),
        "acp/close" => acp_close(params),
        "acp/list" => acp_list(),
        _ => Err(AcpBrokerProcessError::new(
            -32601,
            format!("method not found: {method}"),
        )),
    }
}

pub fn run_broker_supervisor(dir: PathBuf) -> Result<(), AcpBrokerProcessError> {
    let result = run_broker_supervisor_inner(dir.clone());
    if let Err(error) = &result {
        let _ = write_restrictive_bytes(&dir.join("startup-error"), error.message.as_bytes());
    }
    result
}

fn run_broker_supervisor_inner(dir: PathBuf) -> Result<(), AcpBrokerProcessError> {
    let launch_path = dir.join("launch.json");
    let launch: BrokerLaunch = serde_json::from_slice(
        &std::fs::read(&launch_path)
            .map_err(|error| broker_error(-32070, format!("launch read failed: {error}")))?,
    )
    .map_err(|error| broker_error(-32070, format!("launch decode failed: {error}")))?;
    let _ = std::fs::remove_file(&launch_path);

    let metadata = ACPBrokerMetadata {
        broker_id: launch.broker_id.clone(),
        generation: BrokerGeneration::new(current_nanos()),
        alas_session_id: launch.session_id.clone(),
        adapter_program: launch.command.clone(),
        adapter_args: launch.args.clone(),
        cwd: launch.cwd.clone(),
        env_keys: sorted_env_keys(&launch.env),
        created_at_millis: current_millis(),
    };
    write_restrictive_json(&dir.join("metadata.json"), &metadata)?;
    write_broker_pid(&dir)?;

    let mut command = Command::new(&launch.command);
    command
        .args(&launch.args)
        .current_dir(&launch.cwd)
        .env_clear()
        .envs(&launch.env)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        command.process_group(0);
    }
    let mut child = command
        .spawn()
        .map_err(|error| broker_error(-32071, format!("adapter spawn failed: {error}")))?;
    let adapter_stdin = child
        .stdin
        .take()
        .ok_or_else(|| broker_error(-32071, "adapter stdin unavailable"))?;
    let adapter_stdout = child
        .stdout
        .take()
        .ok_or_else(|| broker_error(-32071, "adapter stdout unavailable"))?;
    let adapter_stderr = child
        .stderr
        .take()
        .ok_or_else(|| broker_error(-32071, "adapter stderr unavailable"))?;
    let adapter_process_group_id = adapter_process_group_id(&child);

    let runtime = Runtime {
        state: Arc::new((
            Mutex::new(RuntimeState {
                broker: ACPBrokerState::new(metadata),
                pending_methods: HashMap::new(),
                adapter_process_group_id,
                adapter_exited: false,
                closing: false,
            }),
            Condvar::new(),
        )),
        adapter_stdin: Arc::new(Mutex::new(adapter_stdin)),
    };

    spawn_stdout_reader(runtime.clone(), adapter_stdout);
    spawn_stderr_reader(runtime.clone(), adapter_stderr);
    spawn_waiter(runtime.clone(), child);
    serve_broker_ipc(runtime, dir)
}

fn acp_open(params: Option<Value>) -> Result<Value, AcpBrokerProcessError> {
    let params: AcpOpenParams = decode(params)?;
    validate_broker_id(params.broker_id.as_str())?;
    let dir = broker_dir(params.broker_id.as_str())?;
    std::fs::create_dir_all(&dir)
        .map_err(|error| broker_error(-32070, format!("broker dir failed: {error}")))?;
    set_restrictive_dir_permissions(&dir)?;

    if broker_is_running(&dir) {
        match send_ipc_with_retry(&dir, "snapshot", json!({}), Duration::from_secs(2)) {
            Ok(result) => {
                let snapshot: ACPBrokerSnapshot =
                    serde_json::from_value(result.clone()).map_err(|error| {
                        broker_error(-32072, format!("snapshot decode failed: {error}"))
                    })?;
                if result
                    .get("adapterExited")
                    .and_then(Value::as_bool)
                    .unwrap_or(false)
                {
                    let _ = send_ipc(
                        &dir,
                        "close",
                        json!({
                            "brokerId": params.broker_id.clone(),
                            "generation": snapshot.metadata.generation
                        }),
                    );
                    // The supervisor is alive but its adapter is gone. Close
                    // that generation and fall through to spawn a replacement.
                } else {
                    return Ok(json!(AcpOpenResult {
                        snapshot,
                        adopted: true,
                    }));
                }
            }
            Err(error) if broker_is_running(&dir) => {
                return Err(error);
            }
            Err(_) => {
                // The pid disappeared while we were waiting for its socket.
                // It is now safe to remove stale startup files and spawn a replacement.
            }
        }
    }

    let env = decode_env(params.env)?;
    let launch = BrokerLaunch {
        broker_id: params.broker_id,
        session_id: params.session_id,
        command: params.command,
        args: params.args,
        cwd: params.cwd,
        env,
    };
    remove_transient_startup_files(&dir);
    write_restrictive_json(&dir.join("launch.json"), &launch)?;
    spawn_broker_supervisor(&dir)?;
    let snapshot = send_ipc_with_retry(&dir, "snapshot", json!({}), Duration::from_secs(2))?;
    Ok(json!(AcpOpenResult {
        snapshot: serde_json::from_value(snapshot)
            .map_err(|error| broker_error(-32072, format!("snapshot decode failed: {error}")))?,
        adopted: false,
    }))
}

fn acp_attach(params: Option<Value>) -> Result<Value, AcpBrokerProcessError> {
    let params: AcpAttachParams = decode(params)?;
    let result = send_ipc(
        &broker_dir(params.broker_id.as_str())?,
        "attach",
        serde_json::to_value(params).expect("attach params serialize"),
    )?;
    Ok(result)
}

fn acp_send(params: Option<Value>) -> Result<Value, AcpBrokerProcessError> {
    let params: AcpSendParams = decode(params)?;
    let result = send_ipc(
        &broker_dir(params.broker_id.as_str())?,
        "send",
        serde_json::to_value(params).expect("send params serialize"),
    )?;
    Ok(result)
}

fn acp_notify(params: Option<Value>) -> Result<Value, AcpBrokerProcessError> {
    let params: AcpNotifyParams = decode(params)?;
    let result = send_ipc(
        &broker_dir(params.broker_id.as_str())?,
        "notify",
        serde_json::to_value(params).expect("notify params serialize"),
    )?;
    Ok(result)
}

fn acp_respond(params: Option<Value>) -> Result<Value, AcpBrokerProcessError> {
    let params: AcpRespondParams = decode(params)?;
    let result = send_ipc(
        &broker_dir(params.broker_id.as_str())?,
        "respond",
        serde_json::to_value(params).expect("respond params serialize"),
    )?;
    Ok(result)
}

fn acp_ack(params: Option<Value>) -> Result<Value, AcpBrokerProcessError> {
    let params: AcpAckParams = decode(params)?;
    let result = send_ipc(
        &broker_dir(params.broker_id.as_str())?,
        "ack",
        serde_json::to_value(params).expect("ack params serialize"),
    )?;
    Ok(result)
}

fn acp_detach(params: Option<Value>) -> Result<Value, AcpBrokerProcessError> {
    let params: AcpDetachParams = decode(params)?;
    let _ = broker_dir(params.broker_id.as_str())?;
    Ok(json!({ "ok": true }))
}

fn acp_close(params: Option<Value>) -> Result<Value, AcpBrokerProcessError> {
    let params: AcpCloseParams = decode(params)?;
    let dir = broker_dir(params.broker_id.as_str())?;
    if broker_is_running(&dir) {
        send_ipc(
            &dir,
            "close",
            serde_json::to_value(&params).expect("close params serialize"),
        )?;
    }
    remove_broker_dir(&dir)?;
    Ok(json!({ "ok": true }))
}

fn acp_list() -> Result<Value, AcpBrokerProcessError> {
    let root = broker_root()?;
    let mut brokers = Vec::new();
    let Ok(entries) = std::fs::read_dir(root) else {
        return Ok(json!({ "brokers": brokers }));
    };
    for entry in entries.flatten() {
        let dir = entry.path();
        if !dir.is_dir() || !broker_is_running(&dir) {
            continue;
        }
        // The ordinary budget, deliberately. A shorter one was tempting here
        // — this sweeps every broker dir on disk, including leftovers from
        // earlier runs — but it silently drops healthy brokers: a snapshot
        // carrying a retained large-image prompt takes ~7.4s to serialize,
        // all of it silent, so any budget below that omits a live broker from
        // the list rather than reporting it. The cheap exclusions are already
        // handled above by `broker_is_running`, and a dead socket fails the
        // connect immediately; what is left is a broker that is live but
        // wedged, which is exactly what an idle budget is for.
        if let Ok(snapshot) = send_ipc_within(&dir, "snapshot", json!({}), BROKER_IPC_IDLE_TIMEOUT)
        {
            if snapshot
                .get("adapterExited")
                .and_then(Value::as_bool)
                .unwrap_or(false)
            {
                continue;
            }
            brokers.push(snapshot);
        }
    }
    Ok(json!({ "brokers": brokers }))
}

/// How a line read is bounded in time.
///
/// Which variant is right depends on whether the peer is one we trust to
/// finish what it starts.
#[derive(Clone, Copy)]
enum LineBudget {
    /// Wall-clock for the whole line. Correct where the peer is arbitrary,
    /// since only a total bound stops a slow trickle that keeps looking like
    /// progress.
    Total(Duration),
    /// Longest run with no bytes arriving. Correct where a legitimate payload
    /// can be arbitrarily large, which makes any total a guess that eventually
    /// fails a valid transfer: the real failure being guarded against is a peer
    /// that has stopped making progress, not one that is merely big.
    Idle(Duration),
}

/// Reads one newline-terminated line, bounded in time by `budget`.
///
/// `set_read_timeout` on its own bounds neither: it applies to each underlying
/// read for inactivity, while `read_line` keeps issuing fresh reads until it
/// finds a newline. A peer that trickles bytes faster than the timeout renews
/// its budget indefinitely, holding the caller — and growing the buffer —
/// without limit.
///
/// The socket timeout is therefore set once, to a short slice that just wakes
/// a blocked read periodically; the budget checked on each pass is what
/// actually bounds the line. (Re-arming the socket per read would express a
/// deadline more directly, but `setsockopt` starts failing with `EINVAL` once
/// the peer goes away mid-stream, which would turn an otherwise complete read
/// into an error.)
///
/// There is deliberately no length ceiling in either direction. Neither side
/// sends a payload whose size we can predict: a request can be an `acp/respond`
/// carrying a whole file `fs/read_text_file` was asked for, and a reply can be
/// an attach replay carrying a prompt's params more than once. Every ceiling
/// picked for those was eventually below something legitimate, and being wrong
/// is expensive — the Swift side drops the resulting error (`catch {}` in
/// `ACPBrokerClient.respondToRawResult`), so a rejected response leaves the
/// adapter waiting forever, which is the very hang this bounding exists to
/// prevent. `budget` still limits how long a peer can feed us, and so how much
/// it can feed us.
#[cfg(unix)]
fn read_line_within(stream: &UnixStream, budget: LineBudget) -> io::Result<String> {
    /// How long a blocked read waits before the budget is re-checked. Also
    /// the amount by which a read may overshoot it.
    const POLL_SLICE: Duration = Duration::from_millis(500);

    enum Step {
        Complete(usize),
        Partial(usize),
        Retry,
    }

    stream.set_read_timeout(Some(POLL_SLICE))?;
    let mut reader = BufReader::new(stream);
    let mut line: Vec<u8> = Vec::new();
    // For `Idle`, this is pushed back every time bytes actually arrive.
    let mut deadline = match budget {
        LineBudget::Total(limit) | LineBudget::Idle(limit) => std::time::Instant::now() + limit,
    };
    loop {
        if std::time::Instant::now() >= deadline {
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "timed out reading IPC line",
            ));
        }
        let step = match reader.fill_buf() {
            Ok([]) => {
                return Err(io::Error::new(
                    io::ErrorKind::UnexpectedEof,
                    "peer closed before completing the IPC line",
                ));
            }
            Ok(available) => match available.iter().position(|byte| *byte == b'\n') {
                Some(index) => {
                    line.extend_from_slice(&available[..=index]);
                    Step::Complete(index + 1)
                }
                None => {
                    line.extend_from_slice(available);
                    Step::Partial(available.len())
                }
            },
            // A quiet peer, not a failed one — the deadline above decides
            // when quiet has gone on too long.
            Err(error)
                if matches!(
                    error.kind(),
                    io::ErrorKind::WouldBlock
                        | io::ErrorKind::TimedOut
                        | io::ErrorKind::Interrupted
                ) =>
            {
                Step::Retry
            }
            Err(error) => return Err(error),
        };
        let finished = match step {
            Step::Complete(consumed) => {
                reader.consume(consumed);
                true
            }
            Step::Partial(consumed) => {
                reader.consume(consumed);
                false
            }
            Step::Retry => continue,
        };
        // Bytes arrived, so an idle budget starts over: the peer is making
        // progress, which is the only thing this bound is asking about. A
        // total budget is left alone — for an arbitrary peer, progress is
        // exactly what a slow trickle fakes.
        if let LineBudget::Idle(limit) = budget {
            deadline = std::time::Instant::now() + limit;
        }
        if finished {
            return String::from_utf8(line)
                .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error));
        }
    }
}

fn serve_broker_ipc(runtime: Runtime, dir: PathBuf) -> Result<(), AcpBrokerProcessError> {
    #[cfg(unix)]
    {
        let socket_path = dir.join("broker.sock");
        let _ = std::fs::remove_file(&socket_path);
        let listener = UnixListener::bind(&socket_path)
            .map_err(|error| broker_error(-32072, format!("socket bind failed: {error}")))?;
        write_restrictive_bytes(&dir.join("ready"), b"1\n")?;
        for stream in listener.incoming() {
            let stream = match stream {
                Ok(stream) => stream,
                Err(_) => continue,
            };
            // The request line is read on this thread, so a client that never
            // completes one would stop `accept()` for every other caller.
            // `read_line_within` bounds the whole line, not just each read, so
            // neither silence nor a slow trickle can hold this loop; dropping
            // the stream afterwards gives that client a clean EOF to fail on
            // instead of a hang. The write gets the larger budget on purpose:
            // it guards against a client that stops reading, but an `attach`
            // replay can be a large response, and cutting one short would
            // corrupt a legitimate reply rather than rescue a stuck one.
            if stream
                .set_write_timeout(Some(BROKER_IPC_WRITE_TIMEOUT))
                .is_err()
            {
                continue;
            }
            let Ok(line) = read_line_within(&stream, LineBudget::Total(IPC_REQUEST_TIMEOUT)) else {
                continue;
            };
            if ipc_line_is_close(&line) {
                let _ = handle_ipc_line(runtime.clone(), stream, line);
            } else {
                let request_runtime = runtime.clone();
                std::thread::spawn(move || {
                    let _ = handle_ipc_line(request_runtime, stream, line);
                });
            }
            if runtime_is_closing(&runtime) {
                break;
            }
        }
        Ok(())
    }
    #[cfg(not(unix))]
    {
        let _ = runtime;
        let _ = dir;
        Err(broker_error(-32072, "ACP broker IPC requires Unix sockets"))
    }
}

#[cfg(unix)]
fn handle_ipc_line(runtime: Runtime, stream: UnixStream, line: String) -> io::Result<()> {
    let response = match serde_json::from_str::<BrokerIpcRequest>(&line) {
        Ok(request) => match handle_ipc_request(&runtime, request) {
            Ok(result) => BrokerIpcResponse {
                ok: true,
                result: Some(result),
                error: None,
            },
            Err(error) => BrokerIpcResponse {
                ok: false,
                result: None,
                error: Some(error.message),
            },
        },
        Err(error) => BrokerIpcResponse {
            ok: false,
            result: None,
            error: Some(format!("invalid IPC request: {error}")),
        },
    };
    // Serialize straight into the socket rather than building the whole
    // response first. Two reasons, both about large replies: a maximal attach
    // reply is ~533 MiB, so `to_string` would materialize that entire String
    // in this process before a byte moved — on exactly the memory-pressured
    // machine where it is most likely to happen. And the caller bounds this
    // read by inactivity, which only works if the expensive phase produces
    // bytes: encoding to a String first means ~15s of complete silence, long
    // enough to trip the caller's budget before the reply even starts.
    // Streaming turns that silence into steady progress.
    let mut writer = BufWriter::new(stream);
    serde_json::to_writer(&mut writer, &response).map_err(io::Error::other)?;
    writer.write_all(b"\n")?;
    writer.flush()
}

fn ipc_line_is_close(line: &str) -> bool {
    serde_json::from_str::<BrokerIpcRequest>(line)
        .map(|request| request.method == "close")
        .unwrap_or(false)
}

fn handle_ipc_request(
    runtime: &Runtime,
    request: BrokerIpcRequest,
) -> Result<Value, AcpBrokerProcessError> {
    match request.method.as_str() {
        "snapshot" => Ok(broker_snapshot(runtime)),
        "attach" => broker_attach(runtime, request.params),
        "send" => broker_send(runtime, request.params),
        "notify" => broker_notify(runtime, request.params),
        "respond" => broker_respond(runtime, request.params),
        "ack" => broker_ack(runtime, request.params),
        "close" => broker_close(runtime, request.params),
        _ => Err(broker_error(
            -32601,
            format!("broker method not found: {}", request.method),
        )),
    }
}

fn broker_snapshot(runtime: &Runtime) -> Value {
    let state = lock_runtime(runtime);
    let mut snapshot = json!(state.broker.snapshot());
    if let Some(object) = snapshot.as_object_mut() {
        object.insert("adapterExited".to_string(), json!(state.adapter_exited));
    }
    snapshot
}

fn broker_attach(runtime: &Runtime, params: Option<Value>) -> Result<Value, AcpBrokerProcessError> {
    let params: AcpAttachParams = decode(params)?;
    let state = lock_runtime(runtime);
    ensure_generation(&state, params.generation)?;
    let events = state
        .broker
        .replay_after(params.acknowledged_cursor)
        .map_err(domain_error)?;
    Ok(json!({
        "snapshot": state.broker.snapshot(),
        "events": events
    }))
}

fn broker_send(runtime: &Runtime, params: Option<Value>) -> Result<Value, AcpBrokerProcessError> {
    let params: AcpSendParams = decode(params)?;
    let operation = {
        let mut state = lock_runtime(runtime);
        ensure_generation(&state, params.generation)?;
        let operation = state
            .broker
            .begin_operation(
                params.operation_key.clone(),
                params.method.clone(),
                params.params.clone(),
            )
            .map_err(domain_error)?;
        if operation.replayed {
            if let Some(outcome) = operation.terminal_outcome {
                let mut response = json!({
                    "requestId": operation.adapter_request_id,
                    "replayed": true,
                });
                apply_outcome_fields(&mut response, outcome);
                return Ok(response);
            }
        } else {
            state.pending_methods.insert(
                operation.adapter_request_id.value(),
                PendingOperation {
                    operation_key: params.operation_key.clone(),
                    method: params.method.clone(),
                },
            );
            if params.method == "session/prompt" {
                let _ = state.broker.set_turn_state(BrokerTurnState::Sending);
            }
        }
        operation
    };

    if !operation.replayed {
        write_adapter_request(
            runtime,
            operation.adapter_request_id.value(),
            &params.method,
            params.params,
        )?;
    }
    Ok(json!({
        "requestId": operation.adapter_request_id,
        "replayed": operation.replayed,
        "pending": true
    }))
}

fn broker_notify(runtime: &Runtime, params: Option<Value>) -> Result<Value, AcpBrokerProcessError> {
    let params: AcpNotifyParams = decode(params)?;
    {
        let mut state = lock_runtime(runtime);
        ensure_generation(&state, params.generation)?;
        if params.method == "session/cancel" {
            let _ = state.broker.set_turn_state(BrokerTurnState::Cancelling);
        }
    }
    write_adapter_notification(runtime, &params.method, params.params)?;
    Ok(json!({ "ok": true }))
}

fn broker_respond(
    runtime: &Runtime,
    params: Option<Value>,
) -> Result<Value, AcpBrokerProcessError> {
    let params: AcpRespondParams = decode(params)?;
    let request_key = request_id_key(&params.request_id);
    let outcome = params
        .outcome()
        .ok_or_else(|| broker_error(-32602, "respond requires exactly one of result or error"))?;
    {
        let mut state = lock_runtime(runtime);
        ensure_generation(&state, params.generation)?;
        state
            .broker
            .respond_to_pending_request(&request_key, outcome.clone())
            .map_err(domain_error)?;
    }
    write_adapter_response(runtime, params.request_id, outcome)?;
    Ok(json!({ "ok": true }))
}

fn broker_ack(runtime: &Runtime, params: Option<Value>) -> Result<Value, AcpBrokerProcessError> {
    let params: AcpAckParams = decode(params)?;
    let mut state = lock_runtime(runtime);
    ensure_generation(&state, params.generation)?;
    state.broker.ack(params.cursor).map_err(domain_error)?;
    Ok(json!({ "ok": true }))
}

fn broker_close(runtime: &Runtime, params: Option<Value>) -> Result<Value, AcpBrokerProcessError> {
    let params: AcpCloseParams = decode(params)?;
    let adapter_process_group_id = {
        let mut state = lock_runtime(runtime);
        ensure_generation(&state, params.generation)?;
        state.closing = true;
        if state.adapter_exited {
            None
        } else {
            state.adapter_process_group_id
        }
    };
    terminate_adapter_process_group(runtime, adapter_process_group_id);
    Ok(json!({ "ok": true }))
}

fn spawn_stdout_reader(runtime: Runtime, stdout: std::process::ChildStdout) {
    std::thread::spawn(move || {
        for line in BufReader::new(stdout).lines().map_while(Result::ok) {
            handle_adapter_stdout_line(&runtime, &line);
        }
    });
}

fn spawn_stderr_reader(runtime: Runtime, stderr: std::process::ChildStderr) {
    std::thread::spawn(move || {
        for line in BufReader::new(stderr).lines().map_while(Result::ok) {
            let mut state = lock_runtime(&runtime);
            state
                .broker
                .add_adapter_notification("adapter/stderr", json!({ "text": line }));
        }
    });
}

fn spawn_waiter(runtime: Runtime, mut child: std::process::Child) {
    std::thread::spawn(move || {
        let _ = child.wait();
        let (lock, condvar) = &*runtime.state;
        let mut state = lock.lock().expect("broker state poisoned");
        state.adapter_exited = true;
        if !state.closing {
            let _ = state.broker.set_turn_state(BrokerTurnState::Ambiguous);
            complete_pending_operations_after_adapter_exit(&mut state);
            state
                .broker
                .add_adapter_notification("adapter/exit", json!({ "unexpected": true }));
        }
        condvar.notify_all();
    });
}

fn complete_pending_operations_after_adapter_exit(state: &mut RuntimeState) {
    let outcome = AdapterRPCOutcome::error(JSONRPCErrorObject {
        code: -32074,
        message: "adapter exited before completing request".to_string(),
        data: None,
    });
    let pending: Vec<_> = state
        .pending_methods
        .drain()
        .map(|(_, pending)| pending)
        .collect();
    for pending in pending {
        let _ = state
            .broker
            .complete_operation(&pending.operation_key, outcome.clone());
    }
}

fn handle_adapter_stdout_line(runtime: &Runtime, line: &str) {
    let Ok(value) = serde_json::from_str::<Value>(line) else {
        let mut state = lock_runtime(runtime);
        state
            .broker
            .add_adapter_notification("adapter/stdout", json!({ "line": line }));
        return;
    };
    if value.get("id").is_some() && (value.get("result").is_some() || value.get("error").is_some())
    {
        handle_adapter_response(runtime, value);
    } else if value.get("id").is_some() && value.get("method").is_some() {
        handle_adapter_client_request(runtime, value);
    } else if let Some(method) = value.get("method").and_then(Value::as_str) {
        let params = value.get("params").cloned().unwrap_or(Value::Null);
        let (lock, condvar) = &*runtime.state;
        let mut state = lock.lock().expect("broker state poisoned");
        if method == "session/update"
            && state
                .pending_methods
                .values()
                .any(|pending| pending.method == "session/prompt")
        {
            let _ = state.broker.set_turn_state(BrokerTurnState::Streaming);
        }
        state.broker.add_adapter_notification(method, params);
        condvar.notify_all();
    }
}

fn handle_adapter_response(runtime: &Runtime, value: Value) {
    let Some(id) = value.get("id").and_then(Value::as_u64) else {
        return;
    };
    let Some(outcome) = adapter_response_outcome(&value) else {
        return;
    };
    let (lock, condvar) = &*runtime.state;
    let mut state = lock.lock().expect("broker state poisoned");
    let Some(pending) = state.pending_methods.remove(&id) else {
        state
            .broker
            .add_adapter_notification("adapter/orphanResponse", value);
        return;
    };
    if let Some(result) = &outcome.result {
        if pending.method == "initialize" {
            let _ = state.broker.record_initialize_result(result.clone());
        } else if matches!(
            pending.method.as_str(),
            "session/new" | "session/load" | "session/resume"
        ) {
            let _ = state.broker.record_remote_session_result(result.clone());
        }
    }
    if pending.method == "session/prompt" {
        let _ = state.broker.set_turn_state(BrokerTurnState::Completed);
    }
    let _ = state
        .broker
        .complete_operation(&pending.operation_key, outcome);
    condvar.notify_all();
}

fn handle_adapter_client_request(runtime: &Runtime, value: Value) {
    let Some(id) = value.get("id").cloned() else {
        return;
    };
    let request_id = id
        .as_u64()
        .map(|number| number.to_string())
        .or_else(|| id.as_str().map(ToString::to_string))
        .unwrap_or_else(|| id.to_string());
    let method = value
        .get("method")
        .and_then(Value::as_str)
        .unwrap_or("adapter/request")
        .to_string();
    let params = value.get("params").cloned().unwrap_or(Value::Null);
    let kind = pending_kind(&method);
    let (lock, condvar) = &*runtime.state;
    let mut state = lock.lock().expect("broker state poisoned");
    let _ = state.broker.add_pending_request(
        request_id,
        id,
        kind,
        json!({ "method": method, "params": params }),
    );
    if pending_kind_awaits_user(kind) {
        let _ = state.broker.set_turn_state(BrokerTurnState::AwaitingInput);
    }
    condvar.notify_all();
}

fn pending_kind_awaits_user(kind: PendingClientRequestKind) -> bool {
    matches!(
        kind,
        PendingClientRequestKind::Permission
            | PendingClientRequestKind::Question
            | PendingClientRequestKind::Elicitation
    )
}

fn pending_kind(method: &str) -> PendingClientRequestKind {
    if method.contains("permission") {
        PendingClientRequestKind::Permission
    } else if method.contains("question") {
        PendingClientRequestKind::Question
    } else if method.contains("elicitation") {
        PendingClientRequestKind::Elicitation
    } else if method.contains("file") {
        PendingClientRequestKind::File
    } else {
        PendingClientRequestKind::Terminal
    }
}

fn adapter_response_outcome(value: &Value) -> Option<AdapterRPCOutcome> {
    if let Some(result) = value.get("result") {
        return Some(AdapterRPCOutcome::result(result.clone()));
    }
    if let Some(error) = value.get("error") {
        return Some(AdapterRPCOutcome::error(jsonrpc_error_object(error)));
    }
    None
}

fn jsonrpc_error_object(value: &Value) -> JSONRPCErrorObject {
    JSONRPCErrorObject {
        code: value.get("code").and_then(Value::as_i64).unwrap_or(-32000),
        message: value
            .get("message")
            .and_then(Value::as_str)
            .unwrap_or("adapter JSON-RPC error")
            .to_string(),
        data: value.get("data").cloned(),
    }
}

fn request_id_key(id: &Value) -> String {
    id.as_u64()
        .map(|number| number.to_string())
        .or_else(|| id.as_str().map(ToString::to_string))
        .unwrap_or_else(|| id.to_string())
}

fn apply_outcome_fields(response: &mut Value, outcome: AdapterRPCOutcome) {
    if let Some(object) = response.as_object_mut() {
        match (outcome.result, outcome.error) {
            (Some(result), None) => {
                object.insert("result".to_string(), result);
            }
            (None, Some(error)) => {
                object.insert("error".to_string(), json!(error));
            }
            _ => {
                object.insert(
                    "error".to_string(),
                    json!({ "code": -32603, "message": "invalid broker outcome" }),
                );
            }
        }
    }
}

fn write_adapter_request(
    runtime: &Runtime,
    id: u64,
    method: &str,
    params: Value,
) -> Result<(), AcpBrokerProcessError> {
    let request = json!({
        "jsonrpc": "2.0",
        "id": id,
        "method": method,
        "params": params
    });
    write_adapter_line(runtime, &request)
}

fn write_adapter_notification(
    runtime: &Runtime,
    method: &str,
    params: Value,
) -> Result<(), AcpBrokerProcessError> {
    let notification = json!({
        "jsonrpc": "2.0",
        "method": method,
        "params": params
    });
    write_adapter_line(runtime, &notification)
}

fn write_adapter_response(
    runtime: &Runtime,
    id: Value,
    outcome: AdapterRPCOutcome,
) -> Result<(), AcpBrokerProcessError> {
    let mut response = json!({
        "jsonrpc": "2.0",
        "id": id,
    });
    apply_outcome_fields(&mut response, outcome);
    write_adapter_line(runtime, &response)
}

fn write_adapter_line(runtime: &Runtime, value: &Value) -> Result<(), AcpBrokerProcessError> {
    let mut stdin = runtime
        .adapter_stdin
        .lock()
        .map_err(|_| broker_error(-32074, "adapter stdin lock poisoned"))?;
    writeln!(stdin, "{value}")
        .map_err(|error| broker_error(-32074, format!("adapter write failed: {error}")))?;
    stdin
        .flush()
        .map_err(|error| broker_error(-32074, format!("adapter flush failed: {error}")))
}

fn ensure_generation(
    state: &RuntimeState,
    generation: BrokerGeneration,
) -> Result<(), AcpBrokerProcessError> {
    if state.broker.metadata().generation != generation {
        return Err(broker_error(-32075, "broker generation mismatch"));
    }
    Ok(())
}

fn lock_runtime(runtime: &Runtime) -> std::sync::MutexGuard<'_, RuntimeState> {
    runtime.state.0.lock().expect("broker state poisoned")
}

fn runtime_is_closing(runtime: &Runtime) -> bool {
    lock_runtime(runtime).closing
}

fn decode<T: for<'de> Deserialize<'de>>(params: Option<Value>) -> Result<T, AcpBrokerProcessError> {
    let params = params.ok_or_else(|| broker_error(-32602, "missing params"))?;
    serde_json::from_value(params)
        .map_err(|error| broker_error(-32602, format!("invalid params: {error}")))
}

fn decode_env(value: Value) -> Result<HashMap<String, String>, AcpBrokerProcessError> {
    let object = value
        .as_object()
        .ok_or_else(|| broker_error(-32602, "env must be an object"))?;
    let mut env = HashMap::new();
    for (key, value) in object {
        validate_env_key(key)?;
        let string = value
            .as_str()
            .ok_or_else(|| broker_error(-32602, format!("env value for {key} must be a string")))?;
        env.insert(key.clone(), string.to_string());
    }
    Ok(env)
}

fn validate_env_key(key: &str) -> Result<(), AcpBrokerProcessError> {
    if !key.is_empty() && !key.bytes().any(|byte| byte == b'=' || byte == b'\0') {
        return Ok(());
    }
    Err(broker_error(-32602, format!("invalid env key: {key}")))
}

fn sorted_env_keys(env: &HashMap<String, String>) -> Vec<String> {
    let mut keys: Vec<_> = env.keys().cloned().collect();
    keys.sort();
    keys
}

fn send_ipc(dir: &Path, method: &str, params: Value) -> Result<Value, AcpBrokerProcessError> {
    send_ipc_within(dir, method, params, BROKER_IPC_IDLE_TIMEOUT)
}

fn send_ipc_within(
    dir: &Path,
    method: &str,
    params: Value,
    idle_timeout: Duration,
) -> Result<Value, AcpBrokerProcessError> {
    #[cfg(unix)]
    {
        // Serialize BEFORE connecting. The broker starts its request deadline
        // the moment `accept()` returns, so any work done between connecting
        // and writing is spent out of the broker's budget rather than ours.
        // That is not a small effect at the sizes the UI permits: encoding a
        // maximal image prompt (~267 MiB) measures
        // ~7.4s on an idle machine, against an `IPC_REQUEST_TIMEOUT` of 5s —
        // so connecting first would drop a perfectly valid prompt every time,
        // not merely under load. Writing the bytes, by contrast, takes ~0.2s,
        // which is what the broker's deadline should actually be covering.
        let body = serde_json::to_string(&BrokerIpcRequest {
            method: method.to_string(),
            params: Some(params),
        })
        .expect("IPC request serialization");
        // This connect is blocking and deliberately left that way. On Darwin
        // — the only platform that reaches this code, since the ACP broker is
        // spawned for local sessions only — a full listen backlog fails the
        // connect with ECONNREFUSED immediately rather than waiting for room,
        // so a wedged supervisor cannot stall the caller here; the retry
        // deadline in `send_ipc_with_retry` handles the refusal. Linux instead
        // *blocks* until backlog space frees up, so if brokers ever run on a
        // remote helper — this binary is built for Linux too — this needs a
        // non-blocking, deadline-aware connect before it can be trusted.
        // `connect_does_not_block_on_a_full_backlog` pins the Darwin
        // behaviour this relies on.
        let mut stream = UnixStream::connect(dir.join("broker.sock"))
            .map_err(|error| broker_error(-32072, format!("broker connect failed: {error}")))?;
        // Without a bound, a broker that accepted the connection but never
        // answered would block this call forever. That matters more than it
        // looks: every `acp/*` request is handled inline on the helper's
        // single-threaded serve loop, so one unresponsive broker would take
        // down file, watch, search and *every other ACP session* with it.
        // The response read is bounded below by `read_line_within`.
        stream
            .set_write_timeout(Some(BROKER_IPC_WRITE_TIMEOUT))
            .map_err(|error| {
                broker_error(-32072, format!("broker write timeout failed: {error}"))
            })?;
        writeln!(stream, "{body}")
            .map_err(|error| broker_error(-32072, format!("broker write failed: {error}")))?;
        stream
            .flush()
            .map_err(|error| broker_error(-32072, format!("broker flush failed: {error}")))?;
        // Bounded by inactivity, not total time: a reply's size — and so how
        // long it legitimately takes — is not a bounded multiple of the
        // request. What can be asked of a broker is that it keep making
        // progress.
        let line = read_line_within(&stream, LineBudget::Idle(idle_timeout))
            .map_err(|error| broker_error(-32072, format!("broker read failed: {error}")))?;
        let response: BrokerIpcResponse = serde_json::from_str(&line)
            .map_err(|error| broker_error(-32072, format!("broker response failed: {error}")))?;
        if response.ok {
            Ok(response.result.unwrap_or(Value::Null))
        } else {
            Err(broker_error(
                -32072,
                response
                    .error
                    .unwrap_or_else(|| "broker request failed".to_string()),
            ))
        }
    }
    #[cfg(not(unix))]
    {
        let _ = dir;
        let _ = method;
        let _ = params;
        Err(broker_error(-32072, "ACP broker IPC requires Unix sockets"))
    }
}

fn send_ipc_with_retry(
    dir: &Path,
    method: &str,
    params: Value,
    retry_budget: Duration,
) -> Result<Value, AcpBrokerProcessError> {
    let deadline = std::time::Instant::now() + retry_budget;
    loop {
        if let Some(message) = read_startup_error(dir) {
            return Err(broker_error(-32072, message));
        }
        // Each attempt gets the ordinary response budget, NOT what is left of
        // `retry_budget`. The two measure different things: `retry_budget` is
        // how long to keep re-trying a broker that is not answering *yet* —
        // typically one still starting up, whose socket does not exist — while
        // `BROKER_IPC_IDLE_TIMEOUT` is how long a single legitimate response may
        // take once the broker does answer. Those are far apart: `acp_open`
        // adopts a live broker on a 2s retry budget, and a snapshot carrying a
        // retained large-image prompt takes ~7.4s just to serialize on the
        // broker side. Deriving the response deadline from the retry budget
        // makes adopting such a broker fail permanently, since every retry
        // hits the same wall.
        match send_ipc_within(dir, method, params.clone(), BROKER_IPC_IDLE_TIMEOUT) {
            Ok(value) => return Ok(value),
            Err(error) if std::time::Instant::now() < deadline => {
                let _ = error;
                std::thread::sleep(Duration::from_millis(20));
            }
            Err(error) => return Err(error),
        }
    }
}

fn read_startup_error(dir: &Path) -> Option<String> {
    let message = std::fs::read_to_string(dir.join("startup-error")).ok()?;
    let trimmed = message.trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.to_string())
    }
}

fn remove_transient_startup_files(dir: &Path) {
    for name in ["broker.sock", "ready", "startup-error", "pid.json"] {
        let _ = std::fs::remove_file(dir.join(name));
    }
}

fn spawn_broker_supervisor(dir: &Path) -> Result<(), AcpBrokerProcessError> {
    let exe = std::env::current_exe()
        .map_err(|error| broker_error(-32070, format!("helper path failed: {error}")))?;
    let mut command = Command::new(exe);
    command
        .arg("acp-broker-supervise")
        .arg(dir)
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
        .map_err(|error| broker_error(-32070, format!("broker spawn failed: {error}")))?;
    std::thread::spawn(move || {
        let _ = child.wait();
    });
    Ok(())
}

fn broker_is_running(dir: &Path) -> bool {
    let Some(metadata) = read_broker_pid_metadata(dir) else {
        return false;
    };
    if !pid_is_alive(metadata.pid) {
        mark_stale_broker_pid(dir);
        return false;
    }
    if let Some(expected_pgid) = metadata.process_group_id {
        if current_process_group_id(metadata.pid) != Some(expected_pgid) {
            mark_stale_broker_pid(dir);
            return false;
        }
    }
    true
}

fn read_broker_pid_metadata(dir: &Path) -> Option<BrokerPidMetadata> {
    serde_json::from_slice::<BrokerPidMetadata>(&std::fs::read(dir.join("pid.json")).ok()?).ok()
}

fn mark_stale_broker_pid(dir: &Path) {
    let _ = std::fs::remove_file(dir.join("pid.json"));
}

fn write_broker_pid(dir: &Path) -> Result<(), AcpBrokerProcessError> {
    let metadata = BrokerPidMetadata {
        pid: std::process::id(),
        process_group_id: current_process_group_id(std::process::id()),
    };
    write_restrictive_json(&dir.join("pid.json"), &metadata)
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
fn adapter_process_group_id(child: &std::process::Child) -> Option<u32> {
    Some(child.id())
}

#[cfg(not(unix))]
fn adapter_process_group_id(_child: &std::process::Child) -> Option<u32> {
    None
}

fn terminate_adapter_process_group(runtime: &Runtime, process_group_id: Option<u32>) {
    let Some(process_group_id) = process_group_id else {
        return;
    };
    signal_process_group(process_group_id, 15);
    if wait_for_adapter_exit(runtime, Duration::from_millis(500)) {
        return;
    }
    signal_process_group(process_group_id, 9);
    let _ = wait_for_adapter_exit(runtime, Duration::from_secs(2));
}

fn wait_for_adapter_exit(runtime: &Runtime, timeout: Duration) -> bool {
    let (lock, condvar) = &*runtime.state;
    let mut state = lock.lock().expect("broker state poisoned");
    let deadline = std::time::Instant::now() + timeout;
    while !state.adapter_exited {
        let now = std::time::Instant::now();
        if now >= deadline {
            break;
        }
        let (next_state, _) = condvar
            .wait_timeout(state, deadline.saturating_duration_since(now))
            .expect("broker state poisoned");
        state = next_state;
    }
    state.adapter_exited
}

#[cfg(unix)]
fn signal_process_group(process_group_id: u32, signal: i32) {
    unsafe {
        let _ = libc_kill(-(process_group_id as i32), signal);
        let _ = libc_kill(process_group_id as i32, signal);
    }
}

#[cfg(not(unix))]
fn signal_process_group(_process_group_id: u32, _signal: i32) {}

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

fn validate_broker_id(broker_id: &str) -> Result<(), AcpBrokerProcessError> {
    if broker_id.is_empty()
        || broker_id.len() > 160
        || !broker_id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-' || byte == b'_')
    {
        return Err(broker_error(-32602, "invalid brokerId"));
    }
    Ok(())
}

fn broker_root() -> Result<PathBuf, AcpBrokerProcessError> {
    let home = std::env::var("HOME").map_err(|_| broker_error(-32070, "HOME is not set"))?;
    Ok(PathBuf::from(home).join(".alas").join("acp-brokers"))
}

fn broker_dir(broker_id: &str) -> Result<PathBuf, AcpBrokerProcessError> {
    validate_broker_id(broker_id)?;
    Ok(broker_root()?.join(broker_id))
}

fn remove_broker_dir(dir: &Path) -> Result<(), AcpBrokerProcessError> {
    match std::fs::remove_dir_all(dir) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(broker_error(
            -32070,
            format!("broker cleanup failed: {error}"),
        )),
    }
}

fn write_restrictive_json<T: Serialize>(
    path: &Path,
    value: &T,
) -> Result<(), AcpBrokerProcessError> {
    write_restrictive_bytes(
        path,
        &serde_json::to_vec(value).expect("broker JSON serialization"),
    )
}

fn write_restrictive_bytes(path: &Path, bytes: &[u8]) -> Result<(), AcpBrokerProcessError> {
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create(true).truncate(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options
        .open(path)
        .map_err(|error| broker_error(-32070, format!("file create failed: {error}")))?;
    file.write_all(bytes)
        .map_err(|error| broker_error(-32070, format!("file write failed: {error}")))?;
    file.flush()
        .map_err(|error| broker_error(-32070, format!("file flush failed: {error}")))?;
    Ok(())
}

#[cfg(unix)]
fn set_restrictive_dir_permissions(dir: &Path) -> Result<(), AcpBrokerProcessError> {
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700))
        .map_err(|error| broker_error(-32070, format!("broker chmod failed: {error}")))
}

#[cfg(not(unix))]
fn set_restrictive_dir_permissions(_dir: &Path) -> Result<(), AcpBrokerProcessError> {
    Ok(())
}

fn current_millis() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis() as u64)
        .unwrap_or_default()
}

fn current_nanos() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_nanos() as u64)
        .unwrap_or_default()
}

fn domain_error(error: crate::acp_broker::BrokerError) -> AcpBrokerProcessError {
    broker_error(-32076, format!("broker state error: {:?}", error.kind()))
}

fn broker_error(code: i64, message: impl Into<String>) -> AcpBrokerProcessError {
    AcpBrokerProcessError::new(code, message)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_user_facing_pending_requests_move_turn_to_awaiting_input() {
        assert!(pending_kind_awaits_user(
            PendingClientRequestKind::Permission
        ));
        assert!(pending_kind_awaits_user(PendingClientRequestKind::Question));
        assert!(pending_kind_awaits_user(
            PendingClientRequestKind::Elicitation
        ));
        assert!(!pending_kind_awaits_user(PendingClientRequestKind::File));
        assert!(!pending_kind_awaits_user(
            PendingClientRequestKind::Terminal
        ));
    }

    /// The retry budget governs how long to keep retrying a broker that is not
    /// answering *yet* — its socket may not exist while it starts up. It must
    /// not double as the deadline for a single legitimate response, which can
    /// take far longer: `acp_open` adopts with a 2s retry budget, while a
    /// snapshot carrying a retained large-image prompt takes ~7.4s just to
    /// serialize broker-side. Conflating the two makes adoption of a live
    /// broker fail permanently, every retry hitting the same wall.
    #[cfg(unix)]
    #[test]
    fn a_retry_budget_does_not_cap_how_long_one_response_may_take() {
        let dir = PathBuf::from(format!("/tmp/alas-slow-broker-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("broker dir");
        let listener = UnixListener::bind(dir.join("broker.sock")).expect("listener binds");

        let responder = std::thread::spawn(move || {
            let (stream, _) = listener.accept().expect("accept");
            let mut line = String::new();
            BufReader::new(&stream)
                .read_line(&mut line)
                .expect("request");
            // Stands in for a broker serializing a large snapshot: answers
            // correctly, just well past the caller's retry budget.
            std::thread::sleep(Duration::from_secs(4));
            let mut stream = stream;
            writeln!(stream, r#"{{"ok":true,"result":{{"slow":true}}}}"#).expect("response");
            stream.flush().expect("flush");
        });

        let outcome = send_ipc_with_retry(&dir, "snapshot", json!({}), Duration::from_secs(2));
        let _ = responder.join();
        let _ = std::fs::remove_dir_all(&dir);

        let value = outcome.expect("a slow but healthy broker must not be given up on");
        assert_eq!(value["slow"], json!(true));
    }

    /// `send_ipc_within` connects with a blocking socket, which is only safe
    /// because Darwin refuses a connect to a full listen backlog instead of
    /// waiting for room — otherwise a wedged supervisor could stall the
    /// helper's single-threaded loop before any timeout is installed. Pin that
    /// behaviour so a future Darwin that starts blocking is caught here.
    ///
    /// Darwin-only on purpose. This helper is also built for Linux (see
    /// `scripts/build-alas-helper.sh`), where a full backlog *does* block —
    /// but Linux never reaches the code this guards, because brokers are
    /// spawned for local sessions only. Running it there would fail for an
    /// assumption that platform does not need to hold. What Linux would need
    /// if brokers ever ran on a remote helper is documented at the connect
    /// itself, which is the thing that would have to change.
    #[cfg(target_os = "macos")]
    #[test]
    fn connect_does_not_block_on_a_full_backlog() {
        use std::sync::mpsc;

        let path = std::env::temp_dir().join(format!("alas-backlog-{}.sock", std::process::id()));
        let _ = std::fs::remove_file(&path);
        // Bound to a listener that never accepts, so the backlog fills and
        // stays full.
        let listener = UnixListener::bind(&path).expect("listener binds");

        let (sender, receiver) = mpsc::channel();
        let connect_path = path.clone();
        std::thread::spawn(move || {
            let mut held = Vec::new();
            // Comfortably past the default backlog on any platform we target.
            for _ in 0..1024 {
                match UnixStream::connect(&connect_path) {
                    Ok(stream) => held.push(stream),
                    Err(error) => {
                        let _ = sender.send(Some(error.kind()));
                        return;
                    }
                }
            }
            let _ = sender.send(None);
        });

        let outcome = receiver.recv_timeout(Duration::from_secs(20));
        drop(listener);
        let _ = std::fs::remove_file(&path);

        let kind = outcome
            .expect("connect blocked on a full backlog — send_ipc_within needs a bounded connect")
            .expect("expected the backlog to fill within 1024 connects");
        assert_eq!(kind, io::ErrorKind::ConnectionRefused);
    }

    /// An idle budget must survive a transfer that runs well past it in total,
    /// which is the whole reason responses use one: a maximal attach reply
    /// carries its prompt params twice and takes ~15s to serialize before a
    /// byte is written, and there is no total we could pick that a larger
    /// legitimate reply would not eventually exceed. A total budget of the
    /// same size would fail this.
    #[cfg(unix)]
    #[test]
    fn an_idle_budget_survives_a_transfer_longer_than_the_budget_itself() {
        let (mut writer, reader) = UnixStream::pair().expect("socket pair");
        std::thread::spawn(move || {
            // Six chunks over ~3s, none more than 0.5s apart: never idle for
            // long, but comfortably past a 1s total.
            for _ in 0..6 {
                if writer.write_all(&[b'z'; 512]).is_err() {
                    return;
                }
                let _ = writer.flush();
                std::thread::sleep(Duration::from_millis(500));
            }
            let _ = writer.write_all(b"\n");
            let _ = writer.flush();
        });

        let started = std::time::Instant::now();
        let line = read_line_within(&reader, LineBudget::Idle(Duration::from_secs(1)))
            .expect("a peer that keeps making progress must not be given up on");
        assert_eq!(line.len(), 6 * 512 + 1);
        assert!(
            started.elapsed() > Duration::from_secs(1),
            "transfer finished too fast to prove the budget was exceeded in total"
        );
    }

    /// The whole fix rests on this: a peer that keeps the connection alive and
    /// keeps sending, but never ends the line, must still hit the deadline.
    /// A per-read inactivity timeout never would — and with no length ceiling
    /// left, this total budget is the only thing standing between a trickling
    /// peer and an unbounded read.
    #[cfg(unix)]
    #[test]
    fn read_line_within_stops_a_peer_that_drips_without_ever_ending_the_line() {
        let (mut writer, reader) = UnixStream::pair().expect("socket pair");
        let done = Arc::new(Mutex::new(false));
        let writer_done = done.clone();
        std::thread::spawn(move || {
            while !*writer_done.lock().expect("drip flag") {
                if writer.write_all(b" ").is_err() {
                    return;
                }
                std::thread::sleep(Duration::from_millis(50));
            }
        });

        let started = std::time::Instant::now();
        let outcome = read_line_within(&reader, LineBudget::Total(Duration::from_secs(2)));
        let elapsed = started.elapsed();
        *done.lock().expect("drip flag") = true;

        let error = outcome.expect_err("a line that never ends must not read forever");
        assert_eq!(error.kind(), io::ErrorKind::TimedOut);
        assert!(
            elapsed < Duration::from_secs(10),
            "deadline overshot badly: {elapsed:?}"
        );
    }

    /// A large line must arrive intact rather than being cut short mid-way:
    /// an `acp/respond` can carry a whole file the adapter asked to read.
    #[cfg(unix)]
    #[test]
    fn read_line_within_accepts_a_line_larger_than_a_typical_request() {
        let (mut writer, reader) = UnixStream::pair().expect("socket pair");
        let payload = vec![b'x'; 40 * 1024 * 1024];
        let expected = payload.len();
        std::thread::spawn(move || {
            let _ = writer.write_all(&payload);
            let _ = writer.write_all(b"\n");
            let _ = writer.flush();
        });

        let line = read_line_within(&reader, LineBudget::Total(Duration::from_secs(30)))
            .expect("large line");
        assert_eq!(line.len(), expected + 1);
    }
}
