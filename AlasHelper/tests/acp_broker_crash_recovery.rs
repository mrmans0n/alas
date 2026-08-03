use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

static NEXT_FIXTURE_ID: AtomicU64 = AtomicU64::new(0);

/// Budget for the polling helpers below. These waits used to be bounded by
/// iteration count, which measures round trips rather than time: the suite
/// runs its integration tests in parallel, each driving its own helper,
/// broker and adapter processes, so on a loaded machine a healthy-but-slow
/// broker could exhaust the count and fail the test. A wall-clock budget
/// still catches a genuinely stuck broker, without failing a slow one.
const POLL_BUDGET: Duration = Duration::from_secs(20);

fn poll_deadline() -> std::time::Instant {
    std::time::Instant::now() + POLL_BUDGET
}

struct Helper {
    child: Child,
    stdin: ChildStdin,
    stdout: BufReader<std::process::ChildStdout>,
    next_id: u64,
}

impl Helper {
    fn start(home: &Path) -> Self {
        let mut child = Command::new(env!("CARGO_BIN_EXE_alas-helper"))
            .arg("serve")
            .env("HOME", home)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .expect("helper serve starts");
        let stdin = child.stdin.take().expect("helper stdin");
        let stdout = BufReader::new(child.stdout.take().expect("helper stdout"));
        Self {
            child,
            stdin,
            stdout,
            next_id: 1,
        }
    }

    fn request(&mut self, method: &str, params: Value) -> Value {
        let response = self.raw_request(method, params);
        if response.get("error").is_some() {
            panic!("helper error for {method}: {response}");
        }
        response["result"].clone()
    }

    fn raw_request(&mut self, method: &str, params: Value) -> Value {
        let id = self.next_id;
        self.next_id += 1;
        writeln!(
            self.stdin,
            "{}",
            json!({
                "jsonrpc": "2.0",
                "id": id,
                "method": method,
                "params": params
            })
        )
        .expect("write helper request");
        self.stdin.flush().expect("flush helper request");
        let mut line = String::new();
        self.stdout
            .read_line(&mut line)
            .expect("read helper response");
        serde_json::from_str(&line).expect("helper response JSON")
    }

    fn write_request_without_reading(&mut self, method: &str, params: Value) {
        let id = self.next_id;
        self.next_id += 1;
        writeln!(
            self.stdin,
            "{}",
            json!({
                "jsonrpc": "2.0",
                "id": id,
                "method": method,
                "params": params
            })
        )
        .expect("write helper request");
        self.stdin.flush().expect("flush helper request");
    }

    fn kill(mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

impl Drop for Helper {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

#[test]
fn open_list_and_close_broker_without_persisting_env_values() {
    let fixture = Fixture::new("open-list-close");
    let mut helper = Helper::start(&fixture.home);
    let open = helper.request("acp/open", fixture.open_params("broker-open", 0));

    assert_eq!(open["adopted"], false);
    assert_eq!(open["snapshot"]["metadata"]["brokerId"], "broker-open");
    assert_eq!(
        open["snapshot"]["metadata"]["envKeys"],
        json!([
            "FAKE_ACP_LOG",
            "FAKE_ACP_PROMPT_DELAY",
            "__CFBundleIdentifier"
        ])
    );

    let metadata = std::fs::read_to_string(
        fixture
            .home
            .join(".alas/acp-brokers/broker-open/metadata.json"),
    )
    .expect("metadata exists");
    assert!(metadata.contains("FAKE_ACP_LOG"));
    assert!(!metadata.contains(fixture.log.to_string_lossy().as_ref()));

    let adopted = helper.request("acp/open", fixture.open_params("broker-open", 0));
    assert_eq!(adopted["adopted"], true);

    let mut helper2 = Helper::start(&fixture.home);
    let list = helper2.request("acp/list", json!({}));
    assert_eq!(list["brokers"].as_array().unwrap().len(), 1);

    let generation = open["snapshot"]["metadata"]["generation"].clone();
    let close = helper2.request(
        "acp/close",
        json!({ "brokerId": "broker-open", "generation": generation }),
    );
    assert_eq!(close["ok"], true);
}

#[cfg(unix)]
#[test]
fn open_reclaims_stale_broker_pid_when_process_group_mismatches() {
    let fixture = Fixture::new("stale-broker-pid");
    let broker_dir = fixture
        .home
        .join(".alas/acp-brokers/broker-stale-reused-pid");
    std::fs::create_dir_all(&broker_dir).expect("broker dir");
    std::fs::write(
        broker_dir.join("pid.json"),
        serde_json::to_vec(&json!({
            "pid": std::process::id(),
            "processGroupId": 0
        }))
        .expect("pid metadata"),
    )
    .expect("stale pid metadata");

    let mut helper = Helper::start(&fixture.home);
    let open = helper.request(
        "acp/open",
        fixture.open_params("broker-stale-reused-pid", 0),
    );

    assert_eq!(open["adopted"], false);
    assert_eq!(
        open["snapshot"]["metadata"]["brokerId"],
        "broker-stale-reused-pid"
    );
}

#[test]
fn close_rejects_stale_generation_without_removing_broker() {
    let fixture = Fixture::new("close-stale-generation");
    let mut helper = Helper::start(&fixture.home);
    let open = helper.request("acp/open", fixture.open_params("broker-close-stale", 0));
    let generation = open["snapshot"]["metadata"]["generation"]
        .as_u64()
        .expect("generation");

    let stale = helper.raw_request(
        "acp/close",
        json!({ "brokerId": "broker-close-stale", "generation": generation + 1 }),
    );
    assert!(
        stale["error"]["message"]
            .as_str()
            .is_some_and(|message| message.contains("broker generation mismatch")),
        "stale close response: {stale}"
    );

    let list = helper.request("acp/list", json!({}));
    assert_eq!(list["brokers"].as_array().unwrap().len(), 1);

    let close = helper.request(
        "acp/close",
        json!({ "brokerId": "broker-close-stale", "generation": generation }),
    );
    assert_eq!(close["ok"], true);
}

#[test]
fn helper_crash_during_prompt_preserves_completion_and_replays_events() {
    let fixture = Fixture::new("prompt-crash");
    let mut helper = Helper::start(&fixture.home);
    let open = helper.request("acp/open", fixture.open_params("broker-prompt", 1));
    let generation = open["snapshot"]["metadata"]["generation"].clone();

    send(
        &mut helper,
        "broker-prompt",
        generation.clone(),
        "initialize",
        "init",
        json!({}),
    );
    send(
        &mut helper,
        "broker-prompt",
        generation.clone(),
        "session/new",
        "session-new",
        json!({}),
    );

    helper.write_request_without_reading(
        "acp/send",
        json!({
            "brokerId": "broker-prompt",
            "generation": generation,
            "operationKey": "prompt-1",
            "method": "session/prompt",
            "params": { "prompt": "finish after crash" }
        }),
    );
    fixture.wait_for_log("session/prompt\n");
    helper.kill();
    std::thread::sleep(Duration::from_millis(1200));

    let mut recovered = Helper::start(&fixture.home);
    let attached = recovered.request(
        "acp/attach",
        json!({
            "brokerId": "broker-prompt",
            "generation": open["snapshot"]["metadata"]["generation"],
            "acknowledgedCursor": 0
        }),
    );
    let events = attached["events"].as_array().expect("events");
    assert!(
        events.iter().any(|event| {
            event["kind"]["type"] == "operationCompleted"
                && event["kind"]["operationKey"] == "prompt-1"
        }),
        "attached payload: {attached}"
    );

    let retried = recovered.request(
        "acp/send",
        json!({
            "brokerId": "broker-prompt",
            "generation": open["snapshot"]["metadata"]["generation"],
            "operationKey": "prompt-1",
            "method": "session/prompt",
            "params": { "prompt": "finish after crash" }
        }),
    );
    assert_eq!(retried["replayed"], true);
    assert_eq!(retried["result"]["stopReason"], "end_turn");

    let log = std::fs::read_to_string(&fixture.log).expect("adapter log");
    assert_eq!(log.matches("initialize\n").count(), 1);
    assert_eq!(log.matches("session/prompt\n").count(), 1);
}

#[test]
fn prompt_streaming_update_returns_progress_before_turn_completion() {
    let fixture = Fixture::new("prompt-progress");
    let mut helper = Helper::start(&fixture.home);
    let open = helper.request("acp/open", fixture.open_params("broker-progress", 1));
    let generation = open["snapshot"]["metadata"]["generation"].clone();

    send(
        &mut helper,
        "broker-progress",
        generation.clone(),
        "initialize",
        "init",
        json!({}),
    );
    send(
        &mut helper,
        "broker-progress",
        generation.clone(),
        "session/new",
        "session-new",
        json!({}),
    );

    let progress = send(
        &mut helper,
        "broker-progress",
        generation,
        "session/prompt",
        "prompt-progress",
        json!({ "prompt": "stream before completion" }),
    );

    assert_eq!(progress["pending"], true);
    assert!(progress.get("result").is_none(), "{progress}");
}

#[test]
fn attach_with_stale_persisted_cursor_does_not_move_ack_back() {
    let fixture = Fixture::new("stale-attach-cursor");
    let mut helper = Helper::start(&fixture.home);
    let open = helper.request("acp/open", fixture.open_params("broker-stale-attach", 0));
    let generation = open["snapshot"]["metadata"]["generation"].clone();

    send(
        &mut helper,
        "broker-stale-attach",
        generation.clone(),
        "initialize",
        "init",
        json!({}),
    );

    let attached = helper.request(
        "acp/attach",
        json!({
            "brokerId": "broker-stale-attach",
            "generation": generation.clone(),
            "acknowledgedCursor": 0
        }),
    );
    let journal_tail = attached["snapshot"]["journalTail"]
        .as_u64()
        .expect("journal tail");
    assert!(journal_tail > 0, "{attached}");

    helper.request(
        "acp/ack",
        json!({
            "brokerId": "broker-stale-attach",
            "generation": generation.clone(),
            "cursor": journal_tail
        }),
    );

    let stale_attach = helper.request(
        "acp/attach",
        json!({
            "brokerId": "broker-stale-attach",
            "generation": generation,
            "acknowledgedCursor": 0
        }),
    );
    assert_eq!(
        stale_attach["snapshot"]["acknowledgedCursor"],
        json!(journal_tail)
    );
    assert_eq!(stale_attach["events"], json!([]), "{stale_attach}");
}

#[test]
fn load_updates_do_not_mark_turn_as_streaming() {
    let fixture = Fixture::new("load-update-state");
    let mut helper = Helper::start(&fixture.home);
    let open = helper.request("acp/open", fixture.open_params("broker-load-update", 0));
    let generation = open["snapshot"]["metadata"]["generation"].clone();

    let mut loaded = Value::Null;
    let deadline = poll_deadline();
    while std::time::Instant::now() < deadline {
        let result = send(
            &mut helper,
            "broker-load-update",
            generation.clone(),
            "session/load",
            "load-with-update",
            json!({ "mode": "stream-load" }),
        );
        if result["result"]["sessionId"] == "remote-loaded" {
            loaded = result;
            break;
        }
        assert_eq!(result["pending"], true, "{result}");
        std::thread::sleep(Duration::from_millis(50));
    }
    assert_eq!(loaded["result"]["sessionId"], "remote-loaded");

    let attached = helper.request(
        "acp/attach",
        json!({
            "brokerId": "broker-load-update",
            "generation": generation,
            "acknowledgedCursor": 0
        }),
    );
    assert_ne!(attached["snapshot"]["turnState"], "streaming", "{attached}");
}

#[test]
fn adapter_exit_completes_inflight_prompt_with_error() {
    let fixture = Fixture::new("prompt-exit");
    let mut helper = Helper::start(&fixture.home);
    let mut open_params = fixture.open_params("broker-prompt-exit", 0);
    open_params["env"]["FAKE_ACP_EXIT_DURING_PROMPT"] = json!("1");
    let open = helper.request("acp/open", open_params);
    let generation = open["snapshot"]["metadata"]["generation"].clone();

    send(
        &mut helper,
        "broker-prompt-exit",
        generation.clone(),
        "initialize",
        "init",
        json!({}),
    );
    send(
        &mut helper,
        "broker-prompt-exit",
        generation.clone(),
        "session/new",
        "session-new",
        json!({}),
    );

    let completed = drive_until_prompt_completed(
        &mut helper,
        "broker-prompt-exit",
        generation.clone(),
        "prompt-exit",
        json!({ "prompt": "adapter exits" }),
    );

    assert_eq!(completed["replayed"], true, "{completed}");
    assert_eq!(completed["error"]["code"], -32074, "{completed}");
    assert_eq!(
        completed["error"]["message"],
        "adapter exited before completing request"
    );

    let attached = helper.request(
        "acp/attach",
        json!({
            "brokerId": "broker-prompt-exit",
            "generation": generation,
            "acknowledgedCursor": 0
        }),
    );
    let events = attached["events"].as_array().expect("events");
    assert!(
        events.iter().any(|event| {
            event["kind"]["type"] == "operationCompleted"
                && event["kind"]["operationKey"] == "prompt-exit"
                && event["kind"]["outcome"]["error"]["code"] == -32074
        }),
        "attached payload: {attached}"
    );
    assert!(
        events.iter().any(|event| {
            event["kind"]["type"] == "adapterNotification"
                && event["kind"]["method"] == "adapter/exit"
        }),
        "attached payload: {attached}"
    );
}

#[test]
fn pending_permission_survives_helper_crash_and_can_be_answered_after_attach() {
    let fixture = Fixture::new("permission-crash");
    let mut helper = Helper::start(&fixture.home);
    let open = helper.request("acp/open", fixture.open_params("broker-permission", 0));
    let generation = open["snapshot"]["metadata"]["generation"].clone();

    send(
        &mut helper,
        "broker-permission",
        generation.clone(),
        "initialize",
        "init",
        json!({}),
    );
    send(
        &mut helper,
        "broker-permission",
        generation.clone(),
        "session/new",
        "session-new",
        json!({}),
    );

    helper.write_request_without_reading(
        "acp/send",
        json!({
            "brokerId": "broker-permission",
            "generation": generation,
            "operationKey": "prompt-permission",
            "method": "session/prompt",
            "params": { "prompt": "needs permission" }
        }),
    );
    fixture.wait_for_log("session/prompt\n");

    let mut recovered = Helper::start(&fixture.home);
    let attached = wait_for_pending_request_visible(
        &mut recovered,
        "broker-permission",
        open["snapshot"]["metadata"]["generation"].clone(),
        json!("900"),
    );
    helper.kill();

    assert!(
        attached["snapshot"]["pendingRequests"]
            .as_array()
            .unwrap()
            .iter()
            .any(|request| request["requestId"] == "900")
    );

    let response = recovered.request(
        "acp/respond",
        json!({
            "brokerId": "broker-permission",
            "generation": open["snapshot"]["metadata"]["generation"],
            "requestId": 900,
            "operationKey": "permission-answer",
            "result": { "outcome": "approved" }
        }),
    );
    assert_eq!(response["ok"], true);
    std::thread::sleep(Duration::from_millis(250));

    let retried = recovered.request(
        "acp/send",
        json!({
            "brokerId": "broker-permission",
            "generation": open["snapshot"]["metadata"]["generation"],
            "operationKey": "prompt-permission",
            "method": "session/prompt",
            "params": { "prompt": "needs permission" }
        }),
    );
    assert_eq!(retried["replayed"], true);
    assert_eq!(retried["result"]["stopReason"], "end_turn");
}

#[test]
fn pending_permission_returns_before_prompt_completion_and_can_resume() {
    let fixture = Fixture::new("permission-pending");
    let mut helper = Helper::start(&fixture.home);
    let open = helper.request("acp/open", fixture.open_params("broker-pending", 0));
    let generation = open["snapshot"]["metadata"]["generation"].clone();

    send(
        &mut helper,
        "broker-pending",
        generation.clone(),
        "initialize",
        "init",
        json!({}),
    );
    send(
        &mut helper,
        "broker-pending",
        generation.clone(),
        "session/new",
        "session-new",
        json!({}),
    );

    let attached = drive_until_pending_request(
        &mut helper,
        "broker-pending",
        generation.clone(),
        "prompt-permission",
        json!({ "prompt": "needs permission" }),
    );
    assert!(attached_has_pending_request(&attached), "{attached}");

    let response = helper.request(
        "acp/respond",
        json!({
            "brokerId": "broker-pending",
            "generation": open["snapshot"]["metadata"]["generation"],
            "requestId": 900,
            "operationKey": "permission-answer",
            "result": { "outcome": "approved" }
        }),
    );
    assert_eq!(response["ok"], true);

    let completed = drive_until_prompt_completed(
        &mut helper,
        "broker-pending",
        open["snapshot"]["metadata"]["generation"].clone(),
        "prompt-permission",
        json!({ "prompt": "needs permission" }),
    );
    assert_eq!(completed["replayed"], true);
    assert_eq!(completed["result"]["stopReason"], "end_turn");
}

#[test]
fn string_permission_request_id_is_preserved_when_responding() {
    let fixture = Fixture::new("permission-string-id");
    let mut helper = Helper::start(&fixture.home);
    let open = helper.request("acp/open", fixture.open_params("broker-string-id", 0));
    let generation = open["snapshot"]["metadata"]["generation"].clone();

    send(
        &mut helper,
        "broker-string-id",
        generation.clone(),
        "initialize",
        "init",
        json!({}),
    );
    send(
        &mut helper,
        "broker-string-id",
        generation.clone(),
        "session/new",
        "session-new",
        json!({}),
    );

    drive_until_pending_request(
        &mut helper,
        "broker-string-id",
        generation.clone(),
        "prompt-string-permission",
        json!({ "prompt": "needs string-permission" }),
    );

    helper.request(
        "acp/respond",
        json!({
            "brokerId": "broker-string-id",
            "generation": generation,
            "requestId": "req-alpha",
            "operationKey": "permission-answer",
            "result": { "outcome": "approved" }
        }),
    );
    fixture.wait_for_log("\"id\":\"req-alpha\"");
    let log = std::fs::read_to_string(&fixture.log).expect("adapter log");
    assert!(
        log.contains("\"result\":{\"outcome\":\"approved\"}"),
        "{log}"
    );
}

#[test]
fn failed_permission_response_is_sent_to_adapter_as_jsonrpc_error() {
    let fixture = Fixture::new("permission-error");
    let mut helper = Helper::start(&fixture.home);
    let open = helper.request(
        "acp/open",
        fixture.open_params("broker-permission-error", 0),
    );
    let generation = open["snapshot"]["metadata"]["generation"].clone();

    send(
        &mut helper,
        "broker-permission-error",
        generation.clone(),
        "initialize",
        "init",
        json!({}),
    );
    send(
        &mut helper,
        "broker-permission-error",
        generation.clone(),
        "session/new",
        "session-new",
        json!({}),
    );

    drive_until_pending_request(
        &mut helper,
        "broker-permission-error",
        generation.clone(),
        "prompt-string-permission",
        json!({ "prompt": "needs string-permission" }),
    );

    helper.request(
        "acp/respond",
        json!({
            "brokerId": "broker-permission-error",
            "generation": generation,
            "requestId": "req-alpha",
            "operationKey": "permission-answer",
            "error": { "code": -32001, "message": "denied" }
        }),
    );
    fixture.wait_for_log("\"error\":{\"code\":-32001");
}

#[test]
fn adapter_jsonrpc_errors_are_returned_as_send_errors() {
    let fixture = Fixture::new("adapter-error");
    let mut helper = Helper::start(&fixture.home);
    let open = helper.request("acp/open", fixture.open_params("broker-adapter-error", 0));
    let generation = open["snapshot"]["metadata"]["generation"].clone();

    drive_until_operation_completed(
        &mut helper,
        "broker-adapter-error",
        generation.clone(),
        "initialize",
        "init",
        json!({}),
    );

    let failed = drive_until_operation_completed(
        &mut helper,
        "broker-adapter-error",
        generation.clone(),
        "session/load",
        "session-load-error",
        json!({ "sessionId": "fail-load" }),
    );
    assert_eq!(failed["error"]["code"], -32042);
    assert_eq!(failed["error"]["message"], "load failed");
    assert!(failed.get("result").is_none());
}

#[test]
fn adapter_exit_completes_pending_operation_and_replays_error() {
    let fixture = Fixture::new("adapter-exit");
    let mut helper = Helper::start(&fixture.home);
    let open = helper.request("acp/open", fixture.open_params("broker-adapter-exit", 0));
    let generation = open["snapshot"]["metadata"]["generation"].clone();

    send(
        &mut helper,
        "broker-adapter-exit",
        generation.clone(),
        "initialize",
        "init",
        json!({}),
    );

    helper.write_request_without_reading(
        "acp/send",
        json!({
            "brokerId": "broker-adapter-exit",
            "generation": generation,
            "operationKey": "session-load-exit",
            "method": "session/load",
            "params": { "sessionId": "exit-load" }
        }),
    );
    fixture.wait_for_log("session/load\n");
    std::thread::sleep(Duration::from_millis(250));

    let mut inspector = Helper::start(&fixture.home);
    let attached = inspector.request(
        "acp/attach",
        json!({
            "brokerId": "broker-adapter-exit",
            "generation": open["snapshot"]["metadata"]["generation"],
            "acknowledgedCursor": 0
        }),
    );
    assert!(
        attached["events"].as_array().unwrap().iter().any(|event| {
            event["kind"]["type"] == "operationCompleted"
                && event["kind"]["operationKey"] == "session-load-exit"
                && event["kind"]["outcome"]["error"]["code"] == -32074
        }),
        "attached payload: {attached}"
    );

    let retried = inspector.request(
        "acp/send",
        json!({
            "brokerId": "broker-adapter-exit",
            "generation": open["snapshot"]["metadata"]["generation"],
            "operationKey": "session-load-exit",
            "method": "session/load",
            "params": { "sessionId": "exit-load" }
        }),
    );
    assert_eq!(retried["replayed"], true);
    assert_eq!(retried["error"]["code"], -32074);
    assert_eq!(
        retried["error"]["message"],
        "adapter exited before completing request"
    );
}

#[test]
fn open_replaces_broker_after_adapter_exit() {
    let fixture = Fixture::new("adapter-exit-reopen");
    let mut helper = Helper::start(&fixture.home);
    let open = helper.request("acp/open", fixture.open_params("broker-exit-reopen", 0));
    let generation = open["snapshot"]["metadata"]["generation"].clone();

    send(
        &mut helper,
        "broker-exit-reopen",
        generation.clone(),
        "initialize",
        "init",
        json!({}),
    );

    let failed = drive_until_operation_completed(
        &mut helper,
        "broker-exit-reopen",
        generation,
        "session/load",
        "session-load-exit",
        json!({ "sessionId": "exit-load" }),
    );
    assert_eq!(failed["error"]["code"], -32074);

    let reopened = helper.request("acp/open", fixture.open_params("broker-exit-reopen", 0));
    assert_eq!(reopened["adopted"], false);
    assert_ne!(
        reopened["snapshot"]["metadata"]["generation"],
        open["snapshot"]["metadata"]["generation"]
    );

    let initialized = send(
        &mut helper,
        "broker-exit-reopen",
        reopened["snapshot"]["metadata"]["generation"].clone(),
        "initialize",
        "init-reopened",
        json!({}),
    );
    assert!(initialized.get("error").is_none(), "{initialized}");
}

fn send(
    helper: &mut Helper,
    broker_id: &str,
    generation: Value,
    method: &str,
    operation_key: &str,
    params: Value,
) -> Value {
    helper.request(
        "acp/send",
        json!({
            "brokerId": broker_id,
            "generation": generation,
            "operationKey": operation_key,
            "method": method,
            "params": params
        }),
    )
}

fn drive_until_operation_completed(
    helper: &mut Helper,
    broker_id: &str,
    generation: Value,
    method: &str,
    operation_key: &str,
    params: Value,
) -> Value {
    let deadline = poll_deadline();
    while std::time::Instant::now() < deadline {
        let result = send(
            helper,
            broker_id,
            generation.clone(),
            method,
            operation_key,
            params.clone(),
        );
        if result.get("result").is_some() || result.get("error").is_some() {
            return result;
        }
        assert_eq!(result["pending"], true, "{result}");
        std::thread::sleep(Duration::from_millis(50));
    }
    panic!("timed out waiting for operation completion");
}

fn drive_until_pending_request(
    helper: &mut Helper,
    broker_id: &str,
    generation: Value,
    operation_key: &str,
    params: Value,
) -> Value {
    let mut acknowledged_cursor = 0;
    let mut last_attached = Value::Null;
    let deadline = poll_deadline();
    while std::time::Instant::now() < deadline {
        let progress = send(
            helper,
            broker_id,
            generation.clone(),
            "session/prompt",
            operation_key,
            params.clone(),
        );
        assert_eq!(progress["pending"], true, "{progress}");

        last_attached = helper.request(
            "acp/attach",
            json!({
                "brokerId": broker_id,
                "generation": generation.clone(),
                "acknowledgedCursor": acknowledged_cursor
            }),
        );
        if attached_has_pending_request(&last_attached) {
            return last_attached;
        }

        let journal_tail = last_attached["snapshot"]["journalTail"]
            .as_u64()
            .unwrap_or(acknowledged_cursor);
        if journal_tail > acknowledged_cursor {
            helper.request(
                "acp/ack",
                json!({
                    "brokerId": broker_id,
                    "generation": generation.clone(),
                    "cursor": journal_tail
                }),
            );
            acknowledged_cursor = journal_tail;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    panic!("timed out waiting for pending request: {last_attached}");
}

fn wait_for_pending_request_visible(
    helper: &mut Helper,
    broker_id: &str,
    generation: Value,
    request_id: Value,
) -> Value {
    let mut last_attached = Value::Null;
    let deadline = poll_deadline();
    while std::time::Instant::now() < deadline {
        last_attached = helper.request(
            "acp/attach",
            json!({
                "brokerId": broker_id,
                "generation": generation.clone(),
                "acknowledgedCursor": 0
            }),
        );
        if last_attached["snapshot"]["pendingRequests"]
            .as_array()
            .is_some_and(|requests| {
                requests
                    .iter()
                    .any(|request| request["requestId"] == request_id)
            })
        {
            return last_attached;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    panic!("timed out waiting for pending request visibility: {last_attached}");
}

fn drive_until_prompt_completed(
    helper: &mut Helper,
    broker_id: &str,
    generation: Value,
    operation_key: &str,
    params: Value,
) -> Value {
    let deadline = poll_deadline();
    while std::time::Instant::now() < deadline {
        let result = send(
            helper,
            broker_id,
            generation.clone(),
            "session/prompt",
            operation_key,
            params.clone(),
        );
        if result.get("result").is_some() || result.get("error").is_some() {
            return result;
        }
        assert_eq!(result["pending"], true, "{result}");
        std::thread::sleep(Duration::from_millis(50));
    }
    panic!("timed out waiting for prompt completion");
}

fn attached_has_pending_request(attached: &Value) -> bool {
    attached["events"].as_array().is_some_and(|events| {
        events
            .iter()
            .any(|event| event["kind"]["type"] == "pendingRequest")
    }) || attached["snapshot"]["pendingRequests"]
        .as_array()
        .is_some_and(|requests| !requests.is_empty())
}

/// A client that connects to a broker's socket and then goes quiet — killed
/// A socket read timeout is an *inactivity* timeout on each underlying read,
/// and `read_line` keeps issuing reads until it sees a newline. So a client
/// that dribbles a byte at a time, faster than the timeout but never ending
/// the line, renews its budget forever and holds the accept thread just as
/// effectively as one that sends nothing — while growing the line buffer
/// without limit. Only a deadline across the whole line catches this.
#[cfg(unix)]
#[test]
fn a_client_dripping_bytes_cannot_renew_the_request_read_forever() {
    use std::io::Write as _;
    use std::os::unix::net::UnixStream;
    use std::sync::mpsc;

    let fixture = Fixture::new("dripping-ipc-client");
    let mut helper = Helper::start(&fixture.home);
    let opened = helper.request("acp/open", fixture.open_params("broker-drip", 0));
    assert_eq!(opened["adopted"], false);

    let socket = fixture
        .home
        .join(".alas/acp-brokers/broker-drip/broker.sock");
    let mut drip = UnixStream::connect(&socket).expect("dripping client connects");
    let stop = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let dripper_stop = stop.clone();
    let dripper = std::thread::spawn(move || {
        // Never a newline: valid JSON padding, one byte at a time, well
        // inside any per-read inactivity window.
        while !dripper_stop.load(Ordering::Relaxed) {
            if drip.write_all(b" ").is_err() || drip.flush().is_err() {
                return;
            }
            std::thread::sleep(Duration::from_millis(200));
        }
    });

    // The helper survives either way — its own socket reads are bounded, so
    // it answers with an error rather than hanging. What is at stake here is
    // the broker: its accept loop is stuck mid-line, so until that read is
    // bounded in total it never serves anyone again and this session is
    // permanently dead. Recovery must happen while the client is STILL
    // dripping, which is what a per-read timeout can never deliver.
    let (sender, receiver) = mpsc::channel();
    let params = fixture.open_params("broker-drip", 0);
    std::thread::spawn(move || {
        let deadline = poll_deadline();
        loop {
            let attempt = helper.raw_request("acp/open", params.clone());
            if attempt["result"]["adopted"] == true || std::time::Instant::now() >= deadline {
                let ping = helper.request("ping", json!({}));
                let _ = sender.send((attempt, ping));
                return;
            }
            std::thread::sleep(Duration::from_millis(250));
        }
    });

    let result = receiver.recv_timeout(Duration::from_secs(60));
    stop.store(true, Ordering::Relaxed);
    let _ = dripper.join();

    let (recovered, ping) = result.expect("probe finished");
    assert_eq!(
        recovered["result"]["adopted"], true,
        "broker never accepted again while a client dripped bytes without a newline: {recovered}"
    );
    assert_eq!(ping["ok"], true);
}

/// between `connect()` and `write()`, or just slow — used to stall the
/// supervisor's accept loop forever, because the request line is read on that
/// thread with no timeout. The helper then blocked forever too: it talks to
/// brokers over the same unbounded socket, inline on its single-threaded serve
/// loop, so every other ACP session (and every file, watch and search request)
/// died with it. Both reads are bounded now, so one silent client costs a
/// bounded stall and the broker recovers on its own.
#[cfg(unix)]
#[test]
fn a_silent_client_on_the_broker_socket_does_not_wedge_the_helper() {
    use std::os::unix::net::UnixStream;
    use std::sync::mpsc;

    let fixture = Fixture::new("silent-ipc-client");
    let mut helper = Helper::start(&fixture.home);
    let opened = helper.request("acp/open", fixture.open_params("broker-silent", 0));
    assert_eq!(opened["adopted"], false);

    let socket = fixture
        .home
        .join(".alas/acp-brokers/broker-silent/broker.sock");
    let silent = UnixStream::connect(&socket).expect("silent client connects");

    let (sender, receiver) = mpsc::channel();
    let params = fixture.open_params("broker-silent", 0);
    let probe = std::thread::spawn(move || {
        // Whatever this answers, it must answer: an error is a recoverable
        // outcome the UI can surface and retry, a hang is not.
        let contested = helper.raw_request("acp/open", params.clone());
        // The decisive check. `ping` never touches a broker, so if it stops
        // being served, one bad broker has taken the whole helper down.
        let ping = helper.request("ping", json!({}));
        let _ = sender.send((contested, ping));
        // Once the broker times out the silent reader it accepts again, with
        // no restart and no intervention. Poll for that rather than sleeping
        // out the timeout, so this test costs only as long as recovery
        // actually takes.
        let deadline = poll_deadline();
        loop {
            let attempt = helper.raw_request("acp/open", params.clone());
            if attempt["result"]["adopted"] == true || std::time::Instant::now() >= deadline {
                return attempt;
            }
            std::thread::sleep(Duration::from_millis(100));
        }
    });

    let (contested, ping) = receiver
        .recv_timeout(Duration::from_secs(30))
        .expect("helper keeps answering while a silent client holds the broker socket");
    assert!(
        contested.get("result").is_some() || contested.get("error").is_some(),
        "contested acp/open produced neither result nor error: {contested}"
    );
    assert_eq!(ping["ok"], true);

    let recovered = probe.join().expect("probe thread");
    assert_eq!(
        recovered["result"]["adopted"], true,
        "broker did not recover after the silent client timed out: {recovered}"
    );
    drop(silent);
}

struct Fixture {
    root: PathBuf,
    home: PathBuf,
    adapter: PathBuf,
    log: PathBuf,
}

impl Fixture {
    fn new(_name: &str) -> Self {
        let id = NEXT_FIXTURE_ID.fetch_add(1, Ordering::Relaxed);
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = PathBuf::from(format!("/tmp/aab-{}-{id}-{nonce}", std::process::id()));
        std::fs::create_dir_all(&root).expect("fixture root");
        let home = root.join("home");
        std::fs::create_dir_all(&home).expect("fixture home");
        let adapter = root.join("fake-acp.sh");
        let log = root.join("adapter.log");
        write_fake_adapter(&adapter);
        Self {
            root,
            home,
            adapter,
            log,
        }
    }

    fn open_params(&self, broker_id: &str, delay_seconds: u64) -> Value {
        json!({
            "brokerId": broker_id,
            "sessionId": format!("{broker_id}-session"),
            "command": self.adapter,
            "args": [],
            "cwd": self.root,
            "env": {
                "FAKE_ACP_LOG": self.log,
                "FAKE_ACP_PROMPT_DELAY": delay_seconds.to_string(),
                "__CFBundleIdentifier": "io.nlopez.alas"
            }
        })
    }

    fn wait_for_log(&self, needle: &str) {
        let deadline = poll_deadline();
        while std::time::Instant::now() < deadline {
            if std::fs::read_to_string(&self.log)
                .map(|log| log.contains(needle))
                .unwrap_or(false)
            {
                return;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        panic!("timed out waiting for adapter log entry {needle:?}");
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

fn write_fake_adapter(path: &Path) {
    std::fs::write(
        path,
        r#"#!/bin/sh
while IFS= read -r line; do
  id=$(printf '%s\n' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
  case "$line" in
    *'"method":"initialize"'*)
      printf 'initialize\n' >> "$FAKE_ACP_LOG"
      printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":1,"capabilities":{}}}\n' "$id"
      ;;
    *'"method":"session/new"'*)
      printf 'session/new\n' >> "$FAKE_ACP_LOG"
      printf '{"jsonrpc":"2.0","id":%s,"result":{"sessionId":"remote-1"}}\n' "$id"
      ;;
    *'"method":"session/load"'*)
      printf 'session/load\n' >> "$FAKE_ACP_LOG"
      if printf '%s\n' "$line" | grep -q exit-load; then
        exit 42
      fi
      if printf '%s\n' "$line" | grep -q stream-load; then
        printf '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"remote-loaded","update":{"kind":"text","text":"restored"}}}\n'
        printf '{"jsonrpc":"2.0","id":%s,"result":{"sessionId":"remote-loaded"}}\n' "$id"
        continue
      fi
      printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32042,"message":"load failed"}}\n' "$id"
      ;;
    *'"method":"session/prompt"'*)
      printf 'session/prompt\n' >> "$FAKE_ACP_LOG"
      printf '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"remote-1","update":{"kind":"text","text":"started"}}}\n'
      if [ "${FAKE_ACP_EXIT_DURING_PROMPT:-0}" = "1" ]; then
        exit 42
      fi
      if printf '%s\n' "$line" | grep -q permission; then
        if printf '%s\n' "$line" | grep -q string-permission; then
          request_id='"req-alpha"'
        else
          request_id='900'
        fi
        printf '{"jsonrpc":"2.0","id":%s,"method":"session/request_permission","params":{"toolCallId":"tool-1"}}\n' "$request_id"
        IFS= read -r answer
        printf 'permission-answer:%s\n' "$answer" >> "$FAKE_ACP_LOG"
      fi
      sleep "${FAKE_ACP_PROMPT_DELAY:-0}"
      printf '{"jsonrpc":"2.0","id":%s,"result":{"stopReason":"end_turn"}}\n' "$id"
      ;;
    *)
      printf '{"jsonrpc":"2.0","id":%s,"result":{}}\n' "$id"
      ;;
  esac
done
"#,
    )
    .expect("write fake adapter");
    let status = Command::new("chmod")
        .arg("+x")
        .arg(path)
        .status()
        .expect("chmod fake adapter");
    assert!(status.success());
}
