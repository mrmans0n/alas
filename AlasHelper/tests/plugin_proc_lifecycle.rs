//! Lifecycle of plugin processes (`pproc/*`), driven through a real helper.
//! Linux only: other hosts refuse plugin processes.
#![cfg(target_os = "linux")]

use base64::Engine;
use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{self, Receiver};
use std::time::{Duration, Instant};

static NEXT_FIXTURE: AtomicU64 = AtomicU64::new(0);
const BUDGET: Duration = Duration::from_secs(30);
const LEASE: &str = "lease-a";

struct Helper {
    child: Child,
    stdin: ChildStdin,
    lines: Receiver<Value>,
    next_id: u64,
    home: PathBuf,
    worktree: PathBuf,
}

impl Helper {
    fn start() -> Self {
        // Not the pid alone: a container reuses it from one run to the next, and
        // a spawn of an id the earlier run left behind would only report it.
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = std::env::temp_dir().join(format!(
            "alas-pproc-{}-{nanos}-{}",
            std::process::id(),
            NEXT_FIXTURE.fetch_add(1, Ordering::SeqCst)
        ));
        let home = root.join("home");
        let worktree = root.join("worktree");
        std::fs::create_dir_all(&home).unwrap();
        std::fs::create_dir_all(&worktree).unwrap();
        let mut child = Command::new(env!("CARGO_BIN_EXE_alas-helper"))
            .arg("serve")
            .env("HOME", &home)
            .env("SHELL", "/bin/sh")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .expect("helper serve starts");
        let stdin = child.stdin.take().unwrap();
        let stdout = BufReader::new(child.stdout.take().unwrap());
        let (sender, lines) = mpsc::channel();
        std::thread::spawn(move || {
            for line in stdout.lines().map_while(Result::ok) {
                if sender.send(serde_json::from_str(&line).unwrap()).is_err() {
                    break;
                }
            }
        });
        Self {
            child,
            stdin,
            lines,
            next_id: 1,
            home,
            worktree,
        }
    }

    /// The response to this request; notifications in between are skipped.
    fn raw(&mut self, method: &str, params: Value) -> Value {
        let id = self.next_id;
        self.next_id += 1;
        writeln!(
            self.stdin,
            "{}",
            json!({ "jsonrpc": "2.0", "id": id, "method": method, "params": params })
        )
        .unwrap();
        self.stdin.flush().unwrap();
        let deadline = Instant::now() + BUDGET;
        loop {
            let line = self
                .lines
                .recv_timeout(deadline.saturating_duration_since(Instant::now()))
                .expect("helper answers");
            if line["id"] == json!(id) {
                return line;
            }
        }
    }

    fn request(&mut self, method: &str, params: Value) -> Value {
        let response = self.raw(method, params);
        assert!(response.get("error").is_none(), "{method}: {response}");
        response["result"].clone()
    }

    fn spawn(&mut self, proc_id: &str, argv: &[&str], extra: Value) -> Value {
        let mut params = json!({
            "procId": proc_id, "lease": LEASE, "argv": argv,
            "cwd": self.worktree, "outputLimit": 65536, "leaseMs": 20000,
        });
        for (key, value) in extra.as_object().unwrap() {
            params[key] = value.clone();
        }
        self.request("pproc/spawn", params)
    }

    /// Runs `script` with `/bin/sh` in the worktree.
    fn spawn_script(&mut self, proc_id: &str, script: &str, extra: Value) -> Value {
        std::fs::write(self.worktree.join(format!("{proc_id}.sh")), script).unwrap();
        self.spawn(proc_id, &["/bin/sh", &format!("{proc_id}.sh")], extra)
    }

    /// Polls `pproc/attach` until the process has ended and nothing it owned
    /// is left. Returns the attach result.
    fn wait_exit(&mut self, proc_id: &str) -> Value {
        let deadline = Instant::now() + BUDGET;
        loop {
            let result = self.request("pproc/attach", json!({ "procId": proc_id, "lease": LEASE }));
            if result.get("exit").is_some() {
                return result;
            }
            assert!(Instant::now() < deadline, "{proc_id} did not exit");
            std::thread::sleep(Duration::from_millis(50));
        }
    }

    fn kill(&mut self, proc_id: &str) {
        self.request("pproc/kill", json!({ "procId": proc_id, "lease": LEASE }));
    }

    fn dir(&self, proc_id: &str) -> PathBuf {
        self.home.join(".alas/plugin-procs").join(proc_id)
    }

    fn log(&self, proc_id: &str) -> Vec<String> {
        std::fs::read_to_string(self.dir(proc_id).join("cleanup.log"))
            .unwrap_or_default()
            .lines()
            .map(str::to_string)
            .collect()
    }

    fn anchor(&self, proc_id: &str) -> i32 {
        std::fs::read_to_string(self.dir(proc_id).join("anchor"))
            .unwrap()
            .parse()
            .unwrap()
    }

    /// A pid a script wrote to `name` in the worktree.
    fn pid_file(&self, name: &str) -> i32 {
        let path = self.worktree.join(name);
        wait_until(|| std::fs::read_to_string(&path).is_ok_and(|text| text.ends_with('\n')));
        std::fs::read_to_string(&path)
            .unwrap()
            .trim()
            .parse()
            .unwrap()
    }
}

impl Drop for Helper {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn wait_until(mut condition: impl FnMut() -> bool) {
    let deadline = Instant::now() + BUDGET;
    while !condition() {
        assert!(Instant::now() < deadline, "condition not met in time");
        std::thread::sleep(Duration::from_millis(20));
    }
}

/// Running, not a zombie.
fn alive(pid: i32) -> bool {
    std::fs::read_to_string(format!("/proc/{pid}/stat")).is_ok_and(|stat| {
        !matches!(
            stat[stat.rfind(')').unwrap() + 2..].chars().next(),
            Some('Z' | 'X')
        )
    })
}

fn output(result: &Value) -> String {
    result["chunks"]
        .as_array()
        .unwrap()
        .iter()
        .map(|chunk| {
            let bytes = base64::engine::general_purpose::STANDARD
                .decode(chunk["dataBase64"].as_str().unwrap())
                .unwrap();
            String::from_utf8(bytes).unwrap()
        })
        .collect()
}

fn b64(text: &str) -> String {
    base64::engine::general_purpose::STANDARD.encode(text)
}

#[test]
fn argv_arrives_unchanged_and_stdin_ends_after_the_payload() {
    let mut helper = Helper::start();
    let argv = [
        "/bin/sh",
        "-c",
        "printf '%s|' \"$@\"; cat",
        "sh",
        "a b",
        "\"q\"",
        "$HOME",
        "it's",
        "",
    ];
    helper.spawn("args", &argv, json!({ "stdinBase64": b64("in-put") }));
    let result = helper.wait_exit("args");
    // Raw bytes: no newline framing, no final fragment dropped.
    assert_eq!(output(&result), "a b|\"q\"|$HOME|it's||in-put");
    assert_eq!(result["exit"], 0);
}

#[test]
fn a_long_running_start_sees_eof_on_stdin() {
    let mut helper = Helper::start();
    helper.spawn("cat", &["cat"], json!({ "longRunning": true }));
    let result = helper.wait_exit("cat");
    assert_eq!(
        (result["exit"].clone(), result["timedOut"].clone()),
        (json!(0), json!(false))
    );
}

#[test]
fn a_signal_exit_reports_128_plus_the_signal() {
    let mut helper = Helper::start();
    for (signal, code) in [("TERM", 143), ("KILL", 137)] {
        let id = format!("sig-{signal}");
        helper.spawn(
            &id,
            &["/bin/sh", "-c", &format!("kill -{signal} $$")],
            json!({}),
        );
        assert_eq!(helper.wait_exit(&id)["exit"], code);
    }
}

#[test]
fn what_the_root_leaves_running_is_stopped_when_it_exits() {
    let mut helper = Helper::start();
    // A plain background child, and a daemon that double-forks into its own
    // session and is orphaned before anything could sample it.
    helper.spawn_script(
        "leftovers",
        "sleep 300 &\necho $! > bg.pid\n(setsid sh -c 'echo $$ > daemon.pid; exec sleep 300' &)\nwhile [ ! -s daemon.pid ]; do sleep 0.01; done\necho done\n",
        json!({}),
    );
    let background = helper.pid_file("bg.pid");
    let daemon = helper.pid_file("daemon.pid");
    let result = helper.wait_exit("leftovers");
    assert_eq!(
        (result["exit"].clone(), output(&result)),
        (json!(0), "done\n".to_string())
    );
    assert!(!alive(background) && !alive(daemon));
}

#[test]
fn a_root_that_calls_setsid_and_its_setsid_child_are_stopped() {
    let mut helper = Helper::start();
    std::fs::write(
        helper.worktree.join("detach.sh"),
        "echo $$ > root.pid\nsetsid sh -c 'echo $$ > child.pid; exec sleep 300' &\nexec sleep 300\n",
    )
    .unwrap();
    helper.spawn(
        "detach",
        &["setsid", "/bin/sh", "detach.sh"],
        json!({ "killGraceMs": 1000 }),
    );
    let root = helper.pid_file("root.pid");
    let child = helper.pid_file("child.pid");
    let anchor = helper.anchor("detach");
    // Both left the anchored group.
    let pgrp = |pid: i32| {
        std::fs::read_to_string(format!("/proc/{pid}/stat"))
            .unwrap()
            .split(") ")
            .nth(1)
            .unwrap()
            .split(' ')
            .nth(2)
            .unwrap()
            .parse::<i32>()
            .unwrap()
    };
    assert!(pgrp(root) != anchor && pgrp(child) != anchor);
    helper.kill("detach");
    let result = helper.wait_exit("detach");
    assert_eq!(result["exit"], 143);
    assert!(!alive(root) && !alive(child));
}

#[test]
fn a_child_forked_during_the_term_grace_is_stopped_too() {
    let mut helper = Helper::start();
    helper.spawn_script(
        "late",
        // The root records the child's pid: the child itself is signalled as
        // soon as cleanup sees it, likely before it could write anything.
        "trap 'setsid sleep 300 & echo $! > late.pid' TERM\necho $$ > root.pid\nwhile :; do sleep 0.05; done\n",
        json!({ "killGraceMs": 1000 }),
    );
    let root = helper.pid_file("root.pid");
    helper.kill("late");
    let late = helper.pid_file("late.pid");
    let result = helper.wait_exit("late");
    assert_eq!(result["exit"], 137);
    assert!(!alive(root) && !alive(late));
}

#[test]
fn the_anchor_ignores_the_groups_signals_and_is_removed_last() {
    let mut helper = Helper::start();
    // The command signals its own group, the anchor's, then ignores SIGTERM.
    helper.spawn_script(
        "stubborn",
        "trap '' HUP INT TERM USR1\nkill -HUP 0; kill -INT 0; kill -USR1 0\necho $$ > root.pid\nwhile :; do sleep 0.05; done\n",
        json!({ "killGraceMs": 1000 }),
    );
    let root = helper.pid_file("root.pid");
    let anchor = helper.anchor("stubborn");
    assert!(alive(anchor));
    helper.kill("stubborn");
    wait_until(|| helper.log("stubborn").iter().any(|line| line == "group 15"));
    assert!(alive(anchor), "the anchor outlives the group's SIGTERM");
    let result = helper.wait_exit("stubborn");
    assert_eq!(result["exit"], 137);
    let log = helper.log("stubborn");
    let last_kill = log
        .iter()
        .rposition(|line| line.starts_with("pid ") && line.ends_with(" 9"))
        .expect("a SIGKILL pass");
    assert_eq!(log.last().map(String::as_str), Some("anchor-removed"));
    assert!(last_kill < log.len() - 1);
    assert!(!alive(anchor) && !alive(root));
}

#[test]
fn once_the_anchor_dies_cleanup_goes_on_through_pidfds_alone() {
    let mut helper = Helper::start();
    helper.spawn_script(
        "orphaned",
        "sleep 300 &\necho $! > bg.pid\necho $$ > root.pid\nwait\n",
        json!({ "killGraceMs": 1000 }),
    );
    let root = helper.pid_file("root.pid");
    let background = helper.pid_file("bg.pid");
    let anchor = helper.anchor("orphaned");
    unsafe { libc::kill(anchor, libc::SIGKILL) };
    wait_until(|| {
        helper
            .log("orphaned")
            .iter()
            .any(|line| line == "anchor-dead")
    });
    helper.kill("orphaned");
    let result = helper.wait_exit("orphaned");
    assert_eq!(result["exit"], 143);
    let log = helper.log("orphaned");
    assert!(!log.iter().any(|line| line.starts_with("group")), "{log:?}");
    assert!(!alive(root) && !alive(background));
}

#[test]
fn a_lapsed_lease_and_the_deadline_stop_the_run() {
    let mut helper = Helper::start();
    helper.spawn(
        "lapsed",
        &["sleep", "300"],
        json!({ "longRunning": true, "leaseMs": 300 }),
    );
    helper.spawn("late", &["sleep", "300"], json!({ "timeoutMs": 300 }));
    let lapsed = helper.wait_exit("lapsed");
    let late = helper.wait_exit("late");
    assert_eq!(
        (lapsed["exit"].clone(), lapsed["timedOut"].clone()),
        (json!(143), json!(false))
    );
    assert_eq!(
        (late["exit"].clone(), late["timedOut"].clone()),
        (json!(143), json!(true))
    );
}

#[test]
fn another_lease_can_neither_attach_nor_stop_a_process() {
    let mut helper = Helper::start();
    helper.spawn("mine", &["sleep", "300"], json!({ "longRunning": true }));
    for method in ["pproc/attach", "pproc/kill", "pproc/renew", "pproc/release"] {
        let response = helper.raw(method, json!({ "procId": "mine", "lease": "lease-b" }));
        assert_eq!(response["error"]["code"], -32054, "{method}: {response}");
    }
    let spawn = helper.raw(
        "pproc/spawn",
        json!({ "procId": "mine", "lease": "lease-b", "argv": ["true"], "cwd": helper.worktree, "outputLimit": 10 }),
    );
    assert_eq!(spawn["error"]["code"], -32054);
    assert!(
        helper.request("pproc/attach", json!({ "procId": "mine", "lease": LEASE }))["running"]
            == true
    );
    helper.request("pproc/release", json!({ "procId": "mine", "lease": LEASE }));
    assert!(!helper.dir("mine").exists());
}

#[test]
fn output_streams_as_notifications_until_the_exit() {
    let mut helper = Helper::start();
    helper.spawn_script(
        "stream",
        "printf one\nsleep 0.3\nprintf two >&2\n",
        json!({}),
    );
    let attached = helper.request(
        "pproc/attach",
        json!({ "procId": "stream", "lease": LEASE }),
    );
    let mut text = output(&attached);
    let deadline = Instant::now() + BUDGET;
    let exit = loop {
        let line = helper
            .lines
            .recv_timeout(deadline.saturating_duration_since(Instant::now()))
            .expect("notification");
        match line["method"].as_str() {
            Some("pproc/output") => {
                text += &String::from_utf8(
                    base64::engine::general_purpose::STANDARD
                        .decode(line["params"]["dataBase64"].as_str().unwrap())
                        .unwrap(),
                )
                .unwrap()
            }
            Some("pproc/exit") => break line["params"]["exit"].clone(),
            _ => {}
        }
    };
    assert_eq!((text.as_str(), exit), ("onetwo", json!(0)));
}
