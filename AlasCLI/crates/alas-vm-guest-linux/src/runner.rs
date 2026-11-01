//! Runs `vm_run` commands the way the macOS guest's `VMGuestShellRunner` does: in their own
//! process group, with a timeout that sends SIGTERM and then SIGKILL, keeping the last
//! `OUTPUT_LIMIT` bytes of each stream.

use std::io::Read;
use std::os::unix::process::CommandExt;
use std::process::{Command, Stdio};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

/// Bytes kept from the end of each of stdout and stderr.
pub const OUTPUT_LIMIT: usize = 256 * 1024;
pub const DEFAULT_TIMEOUT_SECONDS: u64 = 120;
pub const MAX_TIMEOUT_SECONDS: u64 = 600;
/// Between the SIGTERM and the SIGKILL of a timed-out or cancelled command's process group.
const KILL_GRACE: Duration = Duration::from_secs(2);
/// After the SIGKILL, how long to keep waiting for the output to close. A process that left the
/// group can hold it open indefinitely; the result then carries what arrived so far.
const CLOSE_GRACE: Duration = Duration::from_millis(500);

/// The shell and its options; the command is appended as the last argument.
pub const SHELL: [&str; 2] = ["/bin/bash", "-lc"];

/// A request's timeout: the default for zero or less, capped at the maximum.
pub fn clamp_timeout(requested: i64) -> Duration {
    let seconds = if requested > 0 {
        (requested as u64).min(MAX_TIMEOUT_SECONDS)
    } else {
        DEFAULT_TIMEOUT_SECONDS
    };
    Duration::from_secs(seconds)
}

/// The last `limit` bytes appended to it.
pub struct OutputTail {
    limit: usize,
    bytes: Vec<u8>,
    dropped: bool,
}

impl OutputTail {
    pub fn new(limit: usize) -> Self {
        Self {
            limit,
            bytes: Vec::new(),
            dropped: false,
        }
    }

    pub fn append(&mut self, chunk: &[u8]) {
        self.bytes.extend_from_slice(chunk);
        // Trim in batches, not on every read.
        if self.bytes.len() > 2 * self.limit {
            self.trim();
        }
    }

    /// The kept bytes and whether any were dropped.
    pub fn snapshot(&mut self) -> (Vec<u8>, bool) {
        if self.bytes.len() > self.limit {
            self.trim();
        }
        (self.bytes.clone(), self.dropped)
    }

    fn trim(&mut self) {
        self.bytes.drain(..self.bytes.len() - self.limit);
        self.dropped = true;
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RunResult {
    /// None when a signal ended the shell.
    pub exit_code: Option<i32>,
    pub stdout: String,
    pub stderr: String,
    /// Either stream kept only its last `OUTPUT_LIMIT` bytes.
    pub truncated: bool,
    pub timed_out: bool,
}

#[derive(Clone, Copy)]
enum Event {
    StreamClosed,
    LeaderExited,
    Cancel,
}

/// Ends a run's process group the way a timeout does, without marking it timed out.
#[derive(Clone)]
pub struct Canceller(Sender<Event>);

impl Canceller {
    pub fn cancel(&self) {
        let _ = self.0.send(Event::Cancel);
    }
}

/// One command run. Hand out `canceller()` before `execute` blocks.
pub struct Run {
    sender: Sender<Event>,
    events: Receiver<Event>,
}

impl Default for Run {
    fn default() -> Self {
        let (sender, events) = mpsc::channel();
        Self { sender, events }
    }
}

impl Run {
    pub fn canceller(&self) -> Canceller {
        Canceller(self.sender.clone())
    }

    /// Returns once the shell has exited and both streams are closed, so a background child that
    /// keeps them open runs into the timeout like the shell would.
    pub fn execute(self, shell: &[&str], command: &str, timeout: Duration) -> RunResult {
        let Some((program, options)) = shell.split_first() else {
            return failure("no shell");
        };
        // Its own process group, so a timeout reaches the whole pipeline. std marks every other
        // descriptor close-on-exec, and resets SIGPIPE and the signal mask in the child, which a
        // pipeline like `yes | head` relies on.
        let spawned = Command::new(program)
            .args(options)
            .arg(command)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .process_group(0)
            .spawn();
        let mut child = match spawned {
            Ok(child) => child,
            Err(error) => return failure(&error.to_string()),
        };
        let leader = child.id() as libc::pid_t;
        let stdout = Arc::new(Mutex::new(OutputTail::new(OUTPUT_LIMIT)));
        let stderr = Arc::new(Mutex::new(OutputTail::new(OUTPUT_LIMIT)));
        drain(
            child.stdout.take(),
            Arc::clone(&stdout),
            self.sender.clone(),
        );
        drain(
            child.stderr.take(),
            Arc::clone(&stderr),
            self.sender.clone(),
        );
        let sender = self.sender.clone();
        // Waits for the leader without reaping it: the unreaped leader keeps its pid, the group
        // id, from being recycled while the group may still be signalled.
        thread::spawn(move || {
            let mut info: libc::siginfo_t = unsafe { std::mem::zeroed() };
            while unsafe {
                libc::waitid(
                    libc::P_PID,
                    leader as libc::id_t,
                    &mut info,
                    libc::WEXITED | libc::WNOWAIT,
                )
            } < 0
                && std::io::Error::last_os_error().raw_os_error() == Some(libc::EINTR)
            {}
            let _ = sender.send(Event::LeaderExited);
        });

        enum Phase {
            Running,
            Terminating,
            Killed,
        }
        let mut phase = Phase::Running;
        let mut next = Instant::now() + timeout;
        let mut timed_out = false;
        let mut open_streams = 2;
        let mut leader_exited = false;
        while !(leader_exited && open_streams == 0) {
            let event = match self
                .events
                .recv_timeout(next.saturating_duration_since(Instant::now()))
            {
                Ok(event) => Some(event),
                Err(RecvTimeoutError::Timeout) => None,
                // `self.sender` keeps the channel open.
                Err(RecvTimeoutError::Disconnected) => unreachable!(),
            };
            match (event, &phase) {
                (Some(Event::StreamClosed), _) => open_streams -= 1,
                (Some(Event::LeaderExited), _) => leader_exited = true,
                (Some(Event::Cancel), Phase::Running) | (None, Phase::Running) => {
                    timed_out = event.is_none();
                    signal_group(leader, libc::SIGTERM);
                    phase = Phase::Terminating;
                    next = Instant::now() + KILL_GRACE;
                }
                (Some(Event::Cancel), _) => {}
                (None, Phase::Terminating) => {
                    signal_group(leader, libc::SIGKILL);
                    phase = Phase::Killed;
                    next = Instant::now() + CLOSE_GRACE;
                }
                // Whatever still holds the output left the group; stop waiting for it.
                (None, Phase::Killed) => break,
            }
        }

        // A member that outlived the SIGTERM is killed before the leader is reaped, while the
        // group id can't belong to anyone else.
        if !matches!(phase, Phase::Running) {
            signal_group(leader, libc::SIGKILL);
        }
        let exit_code = child.wait().ok().and_then(|status| status.code());
        let (out, out_dropped) = stdout.lock().unwrap().snapshot();
        let (err, err_dropped) = stderr.lock().unwrap().snapshot();
        RunResult {
            exit_code,
            stdout: String::from_utf8_lossy(&out).into_owned(),
            stderr: String::from_utf8_lossy(&err).into_owned(),
            truncated: out_dropped || err_dropped,
            timed_out,
        }
    }
}

fn signal_group(leader: libc::pid_t, signal: libc::c_int) {
    unsafe { libc::killpg(leader, signal) };
}

/// Reads a stream to its end on a thread of its own, then reports it closed.
fn drain(
    stream: Option<impl Read + Send + 'static>,
    tail: Arc<Mutex<OutputTail>>,
    done: Sender<Event>,
) {
    thread::spawn(move || {
        if let Some(mut stream) = stream {
            let mut buffer = vec![0; 64 * 1024];
            loop {
                match stream.read(&mut buffer) {
                    Ok(0) => break,
                    Ok(count) => tail.lock().unwrap().append(&buffer[..count]),
                    Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
                    Err(_) => break,
                }
            }
        }
        let _ = done.send(Event::StreamClosed);
    });
}

fn failure(reason: &str) -> RunResult {
    RunResult {
        exit_code: None,
        stdout: String::new(),
        stderr: format!("vm_run: couldn't start the shell: {reason}"),
        truncated: false,
        timed_out: false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn timeout_uses_the_default_for_zero_or_less_and_caps_at_the_maximum() {
        for (requested, expected) in [
            (-5, 120),
            (0, 120),
            (1, 1),
            (600, 600),
            (601, 600),
            (i64::MAX, 600),
        ] {
            assert_eq!(
                clamp_timeout(requested),
                Duration::from_secs(expected),
                "{requested}"
            );
        }
    }

    #[test]
    fn output_tail_keeps_the_last_bytes_and_flags_dropped_ones() {
        let mut tail = OutputTail::new(4);
        tail.append(b"abc");
        assert_eq!(tail.snapshot(), (b"abc".to_vec(), false));
        tail.append(b"defghij");
        tail.append(b"k");
        assert_eq!(tail.snapshot(), (b"hijk".to_vec(), true));
    }

    #[test]
    fn runner_times_out_and_keeps_the_tail() {
        // More than the limit on stdout, then a wait the timeout cuts short.
        let command = "head -c 300000 /dev/zero | tr '\\0' x; printf END; echo err >&2; sleep 30";
        let started = Instant::now();
        let result = Run::default().execute(&["/bin/sh", "-c"], command, Duration::from_secs(1));
        assert!(started.elapsed() < Duration::from_secs(5));
        assert!(result.timed_out);
        assert!(result.truncated);
        assert_eq!(result.exit_code, None);
        assert_eq!(result.stdout.len(), OUTPUT_LIMIT);
        assert!(result.stdout.ends_with("xEND"));
        assert_eq!(result.stderr, "err\n");
    }

    #[test]
    fn cancel_ends_the_process_group() {
        let run = Run::default();
        run.canceller().cancel();
        let result = run.execute(
            &["/bin/sh", "-c"],
            "sleep 30 & wait",
            Duration::from_secs(60),
        );
        assert!(!result.timed_out);
        assert_eq!(result.exit_code, None);
    }
}
