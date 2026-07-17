use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

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
        let response: Value = serde_json::from_str(&line).expect("helper response JSON");
        if response.get("error").is_some() {
            panic!("helper error for {method}: {response}");
        }
        response["result"].clone()
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
    helper.kill();

    let mut recovered = Helper::start(&fixture.home);
    let attached = recovered.request(
        "acp/attach",
        json!({
            "brokerId": "broker-permission",
            "generation": open["snapshot"]["metadata"]["generation"],
            "acknowledgedCursor": 0
        }),
    );
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

    send(
        &mut helper,
        "broker-adapter-error",
        generation.clone(),
        "initialize",
        "init",
        json!({}),
    );

    let failed = send(
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

fn drive_until_pending_request(
    helper: &mut Helper,
    broker_id: &str,
    generation: Value,
    operation_key: &str,
    params: Value,
) -> Value {
    let mut acknowledged_cursor = 0;
    let mut last_attached = Value::Null;
    for _ in 0..20 {
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

fn drive_until_prompt_completed(
    helper: &mut Helper,
    broker_id: &str,
    generation: Value,
    operation_key: &str,
    params: Value,
) -> Value {
    for _ in 0..20 {
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

struct Fixture {
    root: PathBuf,
    home: PathBuf,
    adapter: PathBuf,
    log: PathBuf,
}

impl Fixture {
    fn new(_name: &str) -> Self {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = PathBuf::from(format!("/tmp/aab-{}-{nonce}", std::process::id()));
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
        let deadline = std::time::Instant::now() + Duration::from_secs(2);
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
