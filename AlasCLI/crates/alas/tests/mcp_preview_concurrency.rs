use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpStream;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::sync::{Arc, Mutex, mpsc};
use std::thread;
use std::time::Duration;

enum ServerEvent {
    Wait { release: mpsc::Sender<()> },
    Cancel,
}

struct FakeAlas {
    socket: PathBuf,
    events: mpsc::Receiver<ServerEvent>,
    /// Every request the fake app received, in arrival order.
    requests: Arc<Mutex<Vec<Value>>>,
    stop: mpsc::Sender<()>,
    handle: Option<thread::JoinHandle<()>>,
}

impl Drop for FakeAlas {
    fn drop(&mut self) {
        let _ = self.stop.send(());
        if let Some(handle) = self.handle.take() {
            let _ = handle.join();
        }
        let _ = std::fs::remove_file(&self.socket);
    }
}

fn start_fake_alas(test_name: &str) -> FakeAlas {
    let socket = PathBuf::from(format!(
        "/tmp/alas-mcp-{test_name}-{}-{}.sock",
        std::process::id(),
        line!()
    ));
    let _ = std::fs::remove_file(&socket);
    let listener = UnixListener::bind(&socket).unwrap();
    listener.set_nonblocking(true).unwrap();
    let (events_tx, events_rx) = mpsc::channel();
    let (stop_tx, stop_rx) = mpsc::channel();
    let requests = Arc::new(Mutex::new(Vec::new()));
    let server_requests = Arc::clone(&requests);
    let handle = thread::spawn(move || {
        loop {
            if stop_rx.try_recv().is_ok() {
                return;
            }
            match listener.accept() {
                Ok((stream, _)) => {
                    let events_tx = events_tx.clone();
                    let requests = Arc::clone(&server_requests);
                    thread::spawn(move || handle_fake_connection(stream, events_tx, requests));
                }
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                    thread::sleep(Duration::from_millis(5));
                }
                Err(_) => return,
            }
        }
    });
    FakeAlas {
        socket,
        events: events_rx,
        requests,
        stop: stop_tx,
        handle: Some(handle),
    }
}

fn handle_fake_connection(
    mut stream: UnixStream,
    events_tx: mpsc::Sender<ServerEvent>,
    requests: Arc<Mutex<Vec<Value>>>,
) {
    let mut buf = Vec::new();
    let mut chunk = [0u8; 1024];
    loop {
        let read = stream.read(&mut chunk).unwrap();
        if read == 0 {
            return;
        }
        buf.extend_from_slice(&chunk[..read]);
        if serde_json::from_slice::<Value>(&buf).is_ok() {
            break;
        }
    }
    let request: Value = serde_json::from_slice(&buf).unwrap();
    requests.lock().unwrap().push(request.clone());
    match request.get("command").and_then(Value::as_str) {
        Some("preview_wait") | Some("computer_screenshot") => {
            let (release_tx, release_rx) = mpsc::channel();
            events_tx
                .send(ServerEvent::Wait {
                    release: release_tx,
                })
                .unwrap();
            release_rx.recv().unwrap();
            stream
                .write_all(
                    br#"{"ok":true,"lines":["{\"version\":1,\"event\":\"wait-complete\"}"]}"#,
                )
                .unwrap();
        }
        Some("vm_run") => {
            // Reports the run as a wait, then never answers: once the client
            // closes its end, reports that as a cancel, the way the app stops
            // a run whose client left.
            let (release_tx, _release_rx) = mpsc::channel();
            events_tx
                .send(ServerEvent::Wait {
                    release: release_tx,
                })
                .unwrap();
            // Accepted from a nonblocking listener; block until the client leaves.
            stream.set_nonblocking(false).unwrap();
            while matches!(stream.read(&mut chunk), Ok(read) if read > 0) {}
            events_tx.send(ServerEvent::Cancel).unwrap();
        }
        Some("preview_cancel") | Some("computer_cancel") => {
            events_tx.send(ServerEvent::Cancel).unwrap();
            stream
                .write_all(br#"{"ok":true,"lines":["{\"version\":1,\"event\":\"cancelled\"}"]}"#)
                .unwrap();
        }
        Some("visual_show") => {
            stream
                .write_all(br#"{"ok":true,"lines":["{\"visual_id\":\"visual-42\"}"]}"#)
                .unwrap();
        }
        Some("preview_capture") => {
            let data = "a".repeat(8 * 1024 * 1024);
            let payload = json!({
                "version": 1,
                "url": "http://127.0.0.1:5173/",
                "image": { "mime_type": "image/png", "data": data }
            })
            .to_string();
            let response = json!({ "ok": true, "lines": [payload] }).to_string();
            stream.write_all(response.as_bytes()).unwrap();
        }
        _ => {
            stream.write_all(br#"{"ok":true}"#).unwrap();
        }
    }
}

struct McpProcess {
    child: Child,
    stdin: ChildStdin,
    stdout: BufReader<ChildStdout>,
}

struct HttpMcpProcess {
    child: Child,
    port: u16,
}

impl Drop for HttpMcpProcess {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

impl Drop for McpProcess {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn start_mcp(socket: &PathBuf) -> McpProcess {
    start_mcp_with_args(socket, &["mcp"])
}

fn start_mcp_with_args(socket: &PathBuf, args: &[&str]) -> McpProcess {
    let mut child = Command::new(env!("CARGO_BIN_EXE_alas"))
        .args(args)
        .env("ALAS_SOCKET_PATH", socket)
        .env("ALAS_WORKTREE_DIR", "/tmp")
        .env("ALAS_SESSION_ID", "session-1")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let stdin = child.stdin.take().unwrap();
    let stdout = BufReader::new(child.stdout.take().unwrap());
    McpProcess {
        child,
        stdin,
        stdout,
    }
}

fn start_mcp_http(socket: &PathBuf, token: &str) -> HttpMcpProcess {
    let mut child = Command::new(env!("CARGO_BIN_EXE_alas"))
        .arg("mcp")
        .arg("--http")
        .env("ALAS_SOCKET_PATH", socket)
        .env("ALAS_WORKTREE_DIR", "/tmp")
        .env("ALAS_SESSION_ID", "session-1")
        .env("ALAS_MCP_HTTP_TOKEN", token)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let stdout = child.stdout.take().unwrap();
    let mut stdout = BufReader::new(stdout);
    let mut line = String::new();
    stdout.read_line(&mut line).unwrap();
    let port = line
        .trim()
        .strip_prefix("PORT ")
        .unwrap()
        .parse::<u16>()
        .unwrap();
    HttpMcpProcess { child, port }
}

fn send_line(stdin: &mut ChildStdin, value: Value) {
    writeln!(stdin, "{value}").unwrap();
    stdin.flush().unwrap();
}

fn http_post(port: u16, token: &str, body: Value) -> String {
    let body = body.to_string();
    let mut stream = TcpStream::connect(("127.0.0.1", port)).unwrap();
    write!(
        stream,
        "POST /mcp HTTP/1.1\r\nHost: localhost:{port}\r\nAuthorization: Bearer {token}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
        body.len(),
        body
    )
    .unwrap();
    stream.flush().unwrap();
    let mut response = String::new();
    stream.read_to_string(&mut response).unwrap();
    response
}

fn poll_http_until_result(
    port: u16,
    token: &str,
    body: Value,
    expected_id: &str,
    timeout: Duration,
) -> String {
    let deadline = std::time::Instant::now() + timeout;
    let mut last_response = String::new();
    while std::time::Instant::now() < deadline {
        last_response = http_post(port, token, body.clone());
        if last_response.starts_with("HTTP/1.1 200 OK")
            && last_response.contains(&format!(r#""id":"{expected_id}""#))
            && last_response.contains(r#""result""#)
        {
            return last_response;
        }
        thread::sleep(Duration::from_millis(100));
    }
    panic!("timed out waiting for HTTP result; last response: {last_response}");
}

fn http_post_without_reading(port: u16, token: &str, body: Value) -> thread::JoinHandle<()> {
    let token = token.to_string();
    thread::spawn(move || {
        let body = body.to_string();
        let mut stream = TcpStream::connect(("127.0.0.1", port)).unwrap();
        write!(
            stream,
            "POST /mcp HTTP/1.1\r\nHost: localhost:{port}\r\nAuthorization: Bearer {token}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
            body.len(),
            body
        )
        .unwrap();
        stream.flush().unwrap();
        thread::sleep(Duration::from_secs(5));
    })
}

fn read_reply(stdout: &mut BufReader<ChildStdout>) -> Value {
    let mut line = String::new();
    stdout.read_line(&mut line).unwrap();
    serde_json::from_str(&line).unwrap()
}

#[test]
fn stdio_preview_cancel_tool_runs_while_preview_wait_socket_response_is_pending() {
    let fake = start_fake_alas("cancel-tool");
    let mut mcp = start_mcp(&fake.socket);

    send_line(
        &mut mcp.stdin,
        json!({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": {
                "name": "preview_wait",
                "arguments": {
                    "preview_id": "preview-runtime-id",
                    "condition": "loaded",
                    "timeout_ms": 20000
                }
            }
        }),
    );
    let wait_release = match fake.events.recv_timeout(Duration::from_secs(5)).unwrap() {
        ServerEvent::Wait { release } => release,
        ServerEvent::Cancel => panic!("cancel arrived before wait started"),
    };

    send_line(
        &mut mcp.stdin,
        json!({
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/call",
            "params": {
                "name": "preview_cancel",
                "arguments": { "preview_id": "preview-runtime-id" }
            }
        }),
    );

    match fake.events.recv_timeout(Duration::from_secs(5)).unwrap() {
        ServerEvent::Cancel => {}
        ServerEvent::Wait { .. } => panic!("unexpected second wait"),
    }
    wait_release.send(()).unwrap();

    let first = read_reply(&mut mcp.stdout);
    let second = read_reply(&mut mcp.stdout);
    let mut ids = vec![first["id"].clone(), second["id"].clone()];
    ids.sort_by_key(|value| value.to_string());
    assert_eq!(ids, vec![json!(1), json!(2)]);
    assert!(first.get("result").is_some());
    assert!(second.get("result").is_some());
}

#[test]
fn stdio_cancelled_notification_sends_preview_cancel_before_wait_completes() {
    let fake = start_fake_alas("cancel-notification");
    let mut mcp = start_mcp(&fake.socket);

    send_line(
        &mut mcp.stdin,
        json!({
            "jsonrpc": "2.0",
            "id": "wait-1",
            "method": "tools/call",
            "params": {
                "name": "preview_wait",
                "arguments": {
                    "preview_id": "preview-runtime-id",
                    "condition": "loaded",
                    "timeout_ms": 20000
                }
            }
        }),
    );
    let wait_release = match fake.events.recv_timeout(Duration::from_secs(5)).unwrap() {
        ServerEvent::Wait { release } => release,
        ServerEvent::Cancel => panic!("cancel arrived before wait started"),
    };

    send_line(
        &mut mcp.stdin,
        json!({
            "jsonrpc": "2.0",
            "method": "notifications/cancelled",
            "params": { "requestId": "wait-1", "reason": "test cancellation" }
        }),
    );

    match fake.events.recv_timeout(Duration::from_secs(5)).unwrap() {
        ServerEvent::Cancel => {}
        ServerEvent::Wait { .. } => panic!("unexpected second wait"),
    }
    wait_release.send(()).unwrap();

    let reply = read_reply(&mut mcp.stdout);
    assert_eq!(reply["id"], json!("wait-1"));
    assert!(reply.get("result").is_some());
}

#[test]
fn http_cancelled_notification_sends_preview_cancel_before_wait_completes() {
    let fake = start_fake_alas("http-cancel-notification");
    let mcp = start_mcp_http(&fake.socket, "test-token");

    let port = mcp.port;
    let wait = thread::spawn(move || {
        http_post(
            port,
            "test-token",
            json!({
                "jsonrpc": "2.0",
                "id": "wait-1",
                "method": "tools/call",
                "params": {
                    "name": "preview_wait",
                    "arguments": {
                        "preview_id": "preview-runtime-id",
                        "condition": "loaded",
                        "timeout_ms": 20000
                    }
                }
            }),
        )
    });

    let wait_release = match fake.events.recv_timeout(Duration::from_secs(5)).unwrap() {
        ServerEvent::Wait { release } => release,
        ServerEvent::Cancel => panic!("cancel arrived before wait started"),
    };

    let cancel_response = http_post(
        mcp.port,
        "test-token",
        json!({
            "jsonrpc": "2.0",
            "method": "notifications/cancelled",
            "params": { "requestId": "wait-1", "reason": "test cancellation" }
        }),
    );
    assert!(cancel_response.starts_with("HTTP/1.1 202 Accepted"));

    match fake.events.recv_timeout(Duration::from_secs(5)).unwrap() {
        ServerEvent::Cancel => {}
        ServerEvent::Wait { .. } => panic!("unexpected second wait"),
    }
    wait_release.send(()).unwrap();

    let wait_response = wait.join().unwrap();
    assert!(wait_response.starts_with("HTTP/1.1 200 OK"));
    assert!(wait_response.contains(r#""id":"wait-1""#));
    assert!(wait_response.contains(r#""result""#));
}

fn computer_screenshot_call(id: &str) -> Value {
    json!({
        "jsonrpc": "2.0",
        "id": id,
        "method": "tools/call",
        "params": { "name": "computer_screenshot", "arguments": { "window_id": 7 } }
    })
}

fn cancelled_notification(id: &str) -> Value {
    json!({
        "jsonrpc": "2.0",
        "method": "notifications/cancelled",
        "params": { "requestId": id, "reason": "test cancellation" }
    })
}

fn expect_cancel_then_release(fake: &FakeAlas, wait_release: mpsc::Sender<()>) {
    match fake.events.recv_timeout(Duration::from_secs(5)).unwrap() {
        ServerEvent::Cancel => {}
        ServerEvent::Wait { .. } => panic!("unexpected second call"),
    }
    let cancel = fake.requests.lock().unwrap().last().cloned().unwrap();
    assert_eq!(cancel["command"], json!("computer_cancel"));
    assert!(
        cancel["params"]["call_id"]
            .as_str()
            .is_some_and(|id| !id.is_empty())
    );
    wait_release.send(()).unwrap();
}

fn wait_started(fake: &FakeAlas) -> mpsc::Sender<()> {
    match fake.events.recv_timeout(Duration::from_secs(5)).unwrap() {
        ServerEvent::Wait { release } => release,
        ServerEvent::Cancel => panic!("cancel arrived before the call started"),
    }
}

#[test]
fn stdio_cancelled_computer_call_gets_no_late_response() {
    let fake = start_fake_alas("computer-cancel-stdio");
    // Spawned directly: closing stdin lets the server finish its workers and
    // exit, so stdout then holds every reply it will ever send.
    let mut child = Command::new(env!("CARGO_BIN_EXE_alas"))
        .arg("mcp")
        .env("ALAS_SOCKET_PATH", &fake.socket)
        .env("ALAS_WORKTREE_DIR", "/tmp")
        .env("ALAS_SESSION_ID", "session-1")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let mut stdin = child.stdin.take().unwrap();

    send_line(&mut stdin, computer_screenshot_call("shot-1"));
    let wait_release = wait_started(&fake);
    send_line(&mut stdin, cancelled_notification("shot-1"));
    expect_cancel_then_release(&fake, wait_release);

    drop(stdin);
    let mut rest = String::new();
    child
        .stdout
        .take()
        .unwrap()
        .read_to_string(&mut rest)
        .unwrap();
    let _ = child.wait();
    assert!(!rest.contains("shot-1"), "cancelled call answered: {rest}");
}

#[test]
fn http_cancelled_computer_call_returns_the_cancellation_error() {
    let fake = start_fake_alas("computer-cancel-http");
    let mcp = start_mcp_http(&fake.socket, "test-token");

    let port = mcp.port;
    let call =
        thread::spawn(move || http_post(port, "test-token", computer_screenshot_call("shot-1")));
    let wait_release = wait_started(&fake);
    let cancel = http_post(mcp.port, "test-token", cancelled_notification("shot-1"));
    assert!(cancel.starts_with("HTTP/1.1 202 Accepted"));
    expect_cancel_then_release(&fake, wait_release);

    let response = call.join().unwrap();
    assert!(response.contains(r#""id":"shot-1""#));
    assert!(response.contains("-32800"), "{response}");
    assert!(!response.contains(r#""result""#));
}

#[test]
fn http_cancelled_vm_run_closes_its_app_connection() {
    let fake = start_fake_alas("vm-run-cancel-http");
    let mcp = start_mcp_http(&fake.socket, "test-token");

    let port = mcp.port;
    let call = thread::spawn(move || {
        http_post(
            port,
            "test-token",
            json!({
                "jsonrpc": "2.0",
                "id": "run-1",
                "method": "tools/call",
                "params": {
                    "name": "vm_run",
                    "arguments": { "command": "sleep 600", "timeout_seconds": 600 }
                }
            }),
        )
    });
    let _release = wait_started(&fake);
    let cancel = http_post(mcp.port, "test-token", cancelled_notification("run-1"));
    assert!(cancel.starts_with("HTTP/1.1 202 Accepted"));
    // The connection closes, so the app stops the guest command; no
    // separate cancel request goes out.
    match fake.events.recv_timeout(Duration::from_secs(5)).unwrap() {
        ServerEvent::Cancel => {}
        ServerEvent::Wait { .. } => panic!("unexpected second call"),
    }
    let commands: Vec<Value> = fake
        .requests
        .lock()
        .unwrap()
        .iter()
        .filter_map(|request| request.get("command").cloned())
        .collect();
    assert_eq!(commands, vec![json!("vm_run")]);

    let response = call.join().unwrap();
    assert!(response.contains(r#""id":"run-1""#));
    assert!(response.contains("-32800"), "{response}");
}

#[test]
fn http_stalled_response_reader_does_not_pin_connection_worker_forever() {
    let fake = start_fake_alas("http-stalled-reader");
    let mcp = start_mcp_http(&fake.socket, "test-token");

    let mut stalled = Vec::new();
    for id in 0..8 {
        stalled.push(http_post_without_reading(
            mcp.port,
            "test-token",
            json!({
                "jsonrpc": "2.0",
                "id": format!("capture-{id}"),
                "method": "tools/call",
                "params": {
                    "name": "preview_capture",
                    "arguments": { "preview_id": format!("preview-{id}") }
                }
            }),
        ));
    }

    let response = poll_http_until_result(
        mcp.port,
        "test-token",
        json!({
            "jsonrpc": "2.0",
            "id": "list-after-stalled-readers",
            "method": "tools/call",
            "params": {
                "name": "preview_list",
                "arguments": {}
            }
        }),
        "list-after-stalled-readers",
        Duration::from_secs(10),
    );

    assert!(response.starts_with("HTTP/1.1 200 OK"), "{response}");
    assert!(response.contains(r#""id":"list-after-stalled-readers""#));
    assert!(response.contains(r#""result""#));

    for handle in stalled {
        let _ = handle.join();
    }
}

#[test]
fn stdio_visual_only_forwards_html_bytes_and_returns_the_visual_id_without_hello() {
    let fake = start_fake_alas("visual-only");
    let mut mcp = start_mcp_with_args(&fake.socket, &["mcp", "--visual-only"]);
    let html = "<h2 class=\"pick\">Choose \u{2014} \u{1F600}</h2>\n<p>'/.alas-remote/example/srv/repo'</p>\n";

    send_line(
        &mut mcp.stdin,
        json!({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": {
                "name": "visual_show",
                "arguments": {
                    "title": "Layouts",
                    "html": html,
                    "question": {
                        "prompt": "Which one?",
                        "options": [{ "id": "a", "label": "One" }, { "id": "b", "label": "Two" }]
                    }
                }
            }
        }),
    );
    let reply = read_reply(&mut mcp.stdout);

    assert_eq!(reply["id"], json!(1));
    assert_eq!(reply["result"]["isError"], json!(false), "{reply}");
    assert!(
        reply["result"]["content"][0]["text"]
            .as_str()
            .unwrap()
            .contains("visual-42")
    );
    let requests = fake.requests.lock().unwrap().clone();
    assert!(
        requests.iter().all(|request| request["kind"] != json!("mcp_hello")),
        "{requests:?}"
    );
    let [request] = requests.as_slice() else {
        panic!("expected exactly the visual_show request: {requests:?}");
    };
    assert_eq!(request["command"], json!("visual_show"));
    assert_eq!(request["session_id"], json!("session-1"));
    assert_eq!(request["params"]["html"].as_str(), Some(html));
    assert_eq!(request["params"]["question"]["prompt"], json!("Which one?"));
}

fn hello_count(fake: &FakeAlas) -> usize {
    fake.requests
        .lock()
        .unwrap()
        .iter()
        .filter(|request| request["kind"] == json!("mcp_hello"))
        .count()
}

#[test]
fn http_requested_port_bind_failure_exits_without_port_line() {
    let occupied = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port = occupied.local_addr().unwrap().port();
    let output = Command::new(env!("CARGO_BIN_EXE_alas"))
        .args(["mcp", "--http", "--port", &port.to_string()])
        .env("ALAS_SOCKET_PATH", "/tmp/alas-mcp-unused.sock")
        .env("ALAS_WORKTREE_DIR", "/tmp")
        .env("ALAS_SESSION_ID", "session-1")
        .env("ALAS_MCP_HTTP_TOKEN", "tok")
        .stdin(Stdio::null())
        .output()
        .unwrap();

    assert!(!output.status.success(), "{output:?}");
    assert!(!String::from_utf8_lossy(&output.stdout).contains("PORT"), "{output:?}");
    assert!(!output.stderr.is_empty(), "{output:?}");
}

fn wait_for_hellos(fake: &FakeAlas, expected: usize) -> usize {
    let deadline = std::time::Instant::now() + Duration::from_secs(5);
    while hello_count(fake) < expected && std::time::Instant::now() < deadline {
        thread::sleep(Duration::from_millis(10));
    }
    hello_count(fake)
}

#[test]
fn http_hello_fires_on_first_authenticated_request_and_every_initialize() {
    let fake = start_fake_alas("http-hello");
    let token = "hello-token";
    let mcp = start_mcp_http(&fake.socket, token);
    let list = |id: &str| json!({ "jsonrpc": "2.0", "id": id, "method": "tools/list" });

    let rejected = http_post(mcp.port, "wrong-token", list("unauthenticated"));
    assert!(rejected.starts_with("HTTP/1.1 401"), "{rejected}");

    // A server respawned on its old port serves an already-initialized
    // client: its first request of any method announces the process.
    for id in ["first", "second"] {
        let response = http_post(mcp.port, token, list(id));
        assert!(response.starts_with("HTTP/1.1 200 OK"), "{response}");
    }
    assert_eq!(wait_for_hellos(&fake, 1), 1);

    // A reconnecting harness re-initializes against the reused process and
    // must announce again: the app clears its registration per attach.
    let initialize = json!({ "jsonrpc": "2.0", "id": "init", "method": "initialize", "params": {} });
    let response = http_post(mcp.port, token, initialize);
    assert!(response.starts_with("HTTP/1.1 200 OK"), "{response}");
    assert_eq!(wait_for_hellos(&fake, 2), 2);
}
