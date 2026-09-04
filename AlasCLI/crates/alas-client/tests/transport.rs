use alas_client::{send, Request};
use std::io::{Read, Write};
use std::os::unix::net::UnixListener;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU32, Ordering};
use std::thread;

static STUB_COUNTER: AtomicU32 = AtomicU32::new(0);

fn stub_server(reply: &'static str) -> (PathBuf, thread::JoinHandle<Vec<u8>>) {
    // Tests in this file run concurrently (default cargo test behavior) and
    // share a process id, so mix in a counter to keep each stub's socket path
    // unique and avoid racing on the same file.
    let unique = STUB_COUNTER.fetch_add(1, Ordering::Relaxed);
    let path = std::env::temp_dir().join(format!(
        "alas-cli-stub-{}-{}.sock",
        std::process::id(),
        unique
    ));
    let _ = std::fs::remove_file(&path);
    let listener = UnixListener::bind(&path).unwrap();
    let handle = thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let mut buf = Vec::new();
        // Read one JSON object: read until we can parse (mirrors the app).
        let mut chunk = [0u8; 1024];
        loop {
            let n = stream.read(&mut chunk).unwrap();
            if n == 0 {
                break;
            }
            buf.extend_from_slice(&chunk[..n]);
            if serde_json::from_slice::<serde_json::Value>(&buf).is_ok() {
                break;
            }
        }
        stream.write_all(reply.as_bytes()).unwrap();
        buf
    });
    (path, handle)
}

#[test]
fn send_writes_request_and_parses_reply() {
    let (path, handle) = stub_server(r#"{"ok":true,"lines":["a","b"]}"#);
    let mut req = Request::new("wt");
    req.session_id = Some("s1".into());
    req.subcommand = Some("list".into());

    let resp = send(&path, &req).unwrap();
    assert!(resp.ok);
    assert_eq!(resp.lines.unwrap(), vec!["a", "b"]);

    let received = handle.join().unwrap();
    let parsed: serde_json::Value = serde_json::from_slice(&received).unwrap();
    assert_eq!(parsed["command"], "wt");
    assert_eq!(parsed["subcommand"], "list");
    let _ = std::fs::remove_file(&path);
}

use alas_client::{Command, DispatchError, Target};

#[test]
fn dispatch_directory_single_owner_sends_command() {
    // Even with a single live socket, directory dispatch probes first (a
    // `resolve`) before sending the real command, so the single-instance and
    // multi-instance paths agree on exit codes for "not in a worktree".
    let (path, handle) = stub_multi_server(vec![r#"{"ok":true}"#, r#"{"ok":true}"#]);
    let target = Target::Directory {
        cwd: "/repo".into(),
    };
    // One explicit socket via the test-only entry point.
    let resp =
        alas_client::dispatch_to_sockets(&Command::WtList, &target, std::slice::from_ref(&path));
    assert!(matches!(resp, Ok(r) if r.ok));

    let received = handle.join().unwrap();
    assert_eq!(received.len(), 2, "owner should see probe + real command");
    assert_eq!(parsed(&received[0])["command"], "resolve");
    assert_eq!(parsed(&received[1])["command"], "wt");
    assert_eq!(parsed(&received[1])["subcommand"], "list");

    let _ = std::fs::remove_file(&path);
}

#[test]
fn dispatch_directory_no_sockets_is_no_alas() {
    let target = Target::Directory {
        cwd: "/repo".into(),
    };
    let resp = alas_client::dispatch_to_sockets(&Command::WtList, &target, &[]);
    assert!(matches!(resp, Err(DispatchError::NoAlas)));
}

#[test]
fn dispatch_directory_workspace_command_bypasses_worktree_probe_for_single_instance() {
    let (path, handle) = stub_multi_server(vec![r#"{"ok":true}"#]);
    let target = Target::Directory {
        cwd: "/outside".into(),
    };

    let resp = alas_client::dispatch_to_sockets(
        &Command::WorkspaceList,
        &target,
        std::slice::from_ref(&path),
    );

    assert!(matches!(resp, Ok(r) if r.ok));
    let received = handle.join().unwrap();
    assert_eq!(
        received.len(),
        1,
        "workspace command should not probe worktree ownership"
    );
    assert_eq!(parsed(&received[0])["command"], "workspace");
    assert_eq!(parsed(&received[0])["subcommand"], "list");

    let _ = std::fs::remove_file(&path);
}

#[test]
fn dispatch_directory_workspace_command_is_ambiguous_with_multiple_instances() {
    let (path_a, handle_a) = stub_multi_server(vec![]);
    let (path_b, handle_b) = stub_multi_server(vec![]);
    let target = Target::Directory {
        cwd: "/outside".into(),
    };

    let resp = alas_client::dispatch_to_sockets(
        &Command::WorkspaceList,
        &target,
        &[path_a.clone(), path_b.clone()],
    );

    assert!(matches!(resp, Err(DispatchError::Ambiguous)));
    assert!(handle_a.join().unwrap().is_empty());
    assert!(handle_b.join().unwrap().is_empty());

    let _ = std::fs::remove_file(&path_a);
    let _ = std::fs::remove_file(&path_b);
}

/// A stub server that accepts `replies.len()` sequential connections on one
/// listener. Each connection is read until the buffered bytes parse as JSON
/// (mirroring the app's framing), replied to with the scripted response for
/// that connection index, then closed. Returns the raw bytes received on
/// each connection, in acceptance order.
fn stub_multi_server(replies: Vec<&'static str>) -> (PathBuf, thread::JoinHandle<Vec<Vec<u8>>>) {
    let unique = STUB_COUNTER.fetch_add(1, Ordering::Relaxed);
    let path = std::env::temp_dir().join(format!(
        "alas-cli-stub-multi-{}-{}.sock",
        std::process::id(),
        unique
    ));
    let _ = std::fs::remove_file(&path);
    let listener = UnixListener::bind(&path).unwrap();
    let handle = thread::spawn(move || {
        let mut received = Vec::new();
        for reply in replies {
            let (mut stream, _) = listener.accept().unwrap();
            let mut buf = Vec::new();
            let mut chunk = [0u8; 1024];
            loop {
                let n = stream.read(&mut chunk).unwrap();
                if n == 0 {
                    break;
                }
                buf.extend_from_slice(&chunk[..n]);
                if serde_json::from_slice::<serde_json::Value>(&buf).is_ok() {
                    break;
                }
            }
            stream.write_all(reply.as_bytes()).unwrap();
            received.push(buf);
        }
        received
    });
    (path, handle)
}

fn parsed(bytes: &[u8]) -> serde_json::Value {
    serde_json::from_slice(bytes).unwrap()
}

#[test]
fn dispatch_directory_multi_socket_unique_owner_sends_command_once() {
    // Owner: replies "ok" to the resolve probe, then to the real command.
    let (owner_path, owner_handle) = stub_multi_server(vec![r#"{"ok":true}"#, r#"{"ok":true}"#]);
    // Non-owner: replies "not mine" to the probe and is never contacted again.
    let (other_path, other_handle) = stub_multi_server(vec![r#"{"ok":false,"error":"not mine"}"#]);

    let target = Target::Directory {
        cwd: "/repo".into(),
    };
    let resp = alas_client::dispatch_to_sockets(
        &Command::WtList,
        &target,
        &[owner_path.clone(), other_path.clone()],
    );
    assert!(matches!(resp, Ok(r) if r.ok));

    let owner_received = owner_handle.join().unwrap();
    assert_eq!(
        owner_received.len(),
        2,
        "owner should see probe + real command"
    );
    assert_eq!(parsed(&owner_received[0])["command"], "resolve");
    assert_eq!(parsed(&owner_received[1])["command"], "wt");
    assert_eq!(parsed(&owner_received[1])["subcommand"], "list");

    let other_received = other_handle.join().unwrap();
    assert_eq!(
        other_received.len(),
        1,
        "non-owner should see only the probe"
    );
    assert_eq!(parsed(&other_received[0])["command"], "resolve");

    let _ = std::fs::remove_file(&owner_path);
    let _ = std::fs::remove_file(&other_path);
}

#[test]
fn dispatch_directory_multi_socket_zero_owners_is_not_in_worktree() {
    let (path_a, handle_a) = stub_multi_server(vec![r#"{"ok":false}"#]);
    let (path_b, handle_b) = stub_multi_server(vec![r#"{"ok":false}"#]);

    let target = Target::Directory {
        cwd: "/repo".into(),
    };
    let resp = alas_client::dispatch_to_sockets(
        &Command::WtList,
        &target,
        &[path_a.clone(), path_b.clone()],
    );
    assert!(matches!(resp, Err(DispatchError::NotInWorktree)));

    for received in [handle_a.join().unwrap(), handle_b.join().unwrap()] {
        assert_eq!(received.len(), 1);
        assert_eq!(parsed(&received[0])["command"], "resolve");
    }

    let _ = std::fs::remove_file(&path_a);
    let _ = std::fs::remove_file(&path_b);
}

#[test]
fn dispatch_directory_slow_non_owner_does_not_stall_dispatch() {
    // Owner: replies promptly to both the probe and the real command.
    let (owner_path, owner_handle) = stub_multi_server(vec![r#"{"ok":true}"#, r#"{"ok":true}"#]);

    // Non-owner: accepts the connection but never replies, modeling a wedged
    // unrelated Alas instance. Probing must not wait anywhere near the normal
    // 30s read timeout for this socket.
    let unique = STUB_COUNTER.fetch_add(1, Ordering::Relaxed);
    let wedged_path = std::env::temp_dir().join(format!(
        "alas-cli-stub-wedged-{}-{}.sock",
        std::process::id(),
        unique
    ));
    let _ = std::fs::remove_file(&wedged_path);
    let listener = UnixListener::bind(&wedged_path).unwrap();
    let wedged_handle = thread::spawn(move || {
        let (_stream, _) = listener.accept().unwrap();
        // Hold the connection open without ever writing a reply.
        thread::sleep(std::time::Duration::from_secs(5));
    });

    let target = Target::Directory {
        cwd: "/repo".into(),
    };
    let started = std::time::Instant::now();
    let resp = alas_client::dispatch_to_sockets(
        &Command::WtList,
        &target,
        &[owner_path.clone(), wedged_path.clone()],
    );
    let elapsed = started.elapsed();
    assert!(matches!(resp, Ok(r) if r.ok));
    assert!(
        elapsed < std::time::Duration::from_secs(10),
        "dispatch took {:?}; a wedged non-owner must not stall it past the probe timeout",
        elapsed
    );

    let owner_received = owner_handle.join().unwrap();
    assert_eq!(
        owner_received.len(),
        2,
        "owner should see probe + real command"
    );

    let _ = std::fs::remove_file(&owner_path);
    let _ = std::fs::remove_file(&wedged_path);
    // Detach; the wedged listener thread will exit once its sleep elapses.
    drop(wedged_handle);
}

#[test]
fn dispatch_directory_multi_socket_multiple_owners_is_ambiguous() {
    let (path_a, handle_a) = stub_multi_server(vec![r#"{"ok":true}"#]);
    let (path_b, handle_b) = stub_multi_server(vec![r#"{"ok":true}"#]);

    let target = Target::Directory {
        cwd: "/repo".into(),
    };
    let resp = alas_client::dispatch_to_sockets(
        &Command::WtList,
        &target,
        &[path_a.clone(), path_b.clone()],
    );
    assert!(matches!(resp, Err(DispatchError::Ambiguous)));

    for received in [handle_a.join().unwrap(), handle_b.join().unwrap()] {
        assert_eq!(received.len(), 1);
        assert_eq!(parsed(&received[0])["command"], "resolve");
    }

    let _ = std::fs::remove_file(&path_a);
    let _ = std::fs::remove_file(&path_b);
}
