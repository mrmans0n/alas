//! The supervisor of one plugin process: starts it under an anchor that leads
//! its group, journals its output, and stops it and everything it started.
//! What differs per OS is in `platform`.

use super::platform::{self, Handle};
use super::*;
use std::collections::HashMap;
use std::io::Read;
use std::sync::Arc;
use std::sync::mpsc;

/// Every live process below `ancestor`, with its identity.
pub(super) fn descendants(ancestor: i32) -> Vec<(i32, Stat)> {
    let all: Vec<(i32, Stat)> = platform::pids()
        .into_iter()
        .filter_map(|pid| Some((pid, platform::stat(pid)?)))
        .collect();
    let mut below = HashSet::from([ancestor]);
    let mut found = Vec::new();
    // Parents may be listed after their children; repeat until stable.
    loop {
        let before = found.len();
        for (pid, stat) in &all {
            if !below.contains(pid) && below.contains(&stat.ppid) {
                below.insert(*pid);
                found.push((*pid, *stat));
            }
        }
        if found.len() == before {
            break;
        }
    }
    found.retain(|(_, stat)| !stat.dead);
    found
}

fn exit_code(status: i32) -> i32 {
    if libc::WIFEXITED(status) {
        libc::WEXITSTATUS(status)
    } else if libc::WIFSIGNALED(status) {
        128 + libc::WTERMSIG(status)
    } else {
        -1
    }
}

struct Supervisor {
    dir: PathBuf,
    me: i32,
    anchor: i32,
    anchor_fd: Option<Handle>,
    root: i32,
    root_status: Option<i32>,
    owned: HashMap<(i32, u64), Handle>,
    /// What `platform::strays` recognizes the run's leftovers by: its output
    /// pipes, pinned so their identity can't be reused, and the supervisor's
    /// start, before which none of them began.
    pins: platform::Pins,
    since: u64,
    log: Option<std::fs::File>,
}

impl Supervisor {
    fn log(&mut self, line: &str) {
        if let Some(log) = self.log.as_mut() {
            let _ = writeln!(log, "{line}");
        }
    }

    /// Reaps everything that ended, the root and adopted orphans alike.
    fn reap(&mut self) {
        loop {
            let mut status = 0;
            // SAFETY: waitpid with a valid out pointer.
            let pid = unsafe { libc::waitpid(-1, &mut status, libc::WNOHANG) };
            if pid <= 0 {
                break;
            }
            if pid == self.root {
                self.root_status = Some(exit_code(status));
            } else if pid == self.anchor && self.anchor_fd.take().is_some() {
                self.log("anchor-dead");
            }
        }
    }

    /// The processes this run still owns, each with a validated handle,
    /// the anchor aside.
    fn sample(&mut self) -> Vec<(i32, u64)> {
        let mut found = descendants(self.me);
        // Orphans the platform can't keep below us (macOS): in the anchor's
        // group while it holds the id, or holding the run's output.
        let group = self.anchor_fd.is_some().then_some(self.anchor);
        for (pid, stat) in platform::strays(&self.pins, group, self.since) {
            if !found.iter().any(|(known, _)| *known == pid) {
                found.push((pid, stat));
            }
        }
        let live: HashSet<(i32, u64)> = found
            .iter()
            .filter(|(pid, _)| *pid != self.anchor)
            .map(|(pid, stat)| (*pid, stat.start))
            .collect();
        self.owned.retain(|key, _| live.contains(key));
        for &(pid, start) in &live {
            if self.owned.contains_key(&(pid, start)) {
                continue;
            }
            match platform::open_validated(pid, start) {
                Some(fd) => {
                    self.owned.insert((pid, start), fd);
                }
                None => self.log(&format!("mismatch {pid}")),
            }
        }
        self.owned.keys().copied().collect()
    }

    fn signal_owned(&mut self, key: (i32, u64), signal: i32) {
        if let Some(fd) = self.owned.get(&key) {
            platform::signal(fd, signal);
            self.log(&format!("pid {} {signal}", key.0));
        }
    }

    /// `SIGTERM` to the group while its anchor lives, and to every owned
    /// process by its handle, newcomers included, until none is left or
    /// the grace ends; then `SIGKILL` passes until none is left; then the
    /// anchor, last.
    fn stop(&mut self, grace: Duration) {
        let term_until = Instant::now() + grace;
        let mut termed = HashSet::new();
        let mut group_termed = false;
        loop {
            self.reap();
            let owned = self.sample();
            if owned.is_empty() || Instant::now() >= term_until {
                break;
            }
            if !group_termed && self.anchor_fd.is_some() {
                group_termed = true;
                // SAFETY: plain kill; the live anchor keeps the group id ours.
                unsafe { libc::kill(-self.anchor, libc::SIGTERM) };
                self.log(&format!("group {}", libc::SIGTERM));
            }
            for key in owned {
                if termed.insert(key) {
                    self.signal_owned(key, libc::SIGTERM);
                }
            }
            thread::sleep(Duration::from_millis(10));
        }
        // ponytail: a process stuck in uninterruptible sleep outlasting
        // 30 s of SIGKILL passes is given up on; the anchor still goes.
        let kill_until = Instant::now() + Duration::from_secs(30);
        loop {
            self.reap();
            let owned = self.sample();
            if owned.is_empty() || Instant::now() >= kill_until {
                break;
            }
            for key in owned {
                self.signal_owned(key, libc::SIGKILL);
            }
            thread::sleep(Duration::from_millis(5));
        }
        if let Some(fd) = self.anchor_fd.take() {
            platform::signal(&fd, libc::SIGKILL);
            self.log("anchor-removed");
            let mut status = 0;
            // SAFETY: waitpid on our own child.
            unsafe { libc::waitpid(self.anchor, &mut status, 0) };
        }
        self.reap();
    }
}

fn fail(dir: &Path, message: String) {
    let _ = write_atomic(&dir.join("error"), message.as_bytes());
}

pub(super) fn supervise(dir: PathBuf) {
    platform::become_reaper();
    // With its start time, so a retry can tell it from a reused pid.
    let me = std::process::id() as i32;
    let since = platform::stat(me).map_or(0, |stat| stat.start);
    if let Some(stat) = platform::stat(me) {
        let _ = write_atomic(
            &dir.join("supervisor"),
            format!("{me} {}", stat.start).as_bytes(),
        );
    }
    let launch: Launch = match std::fs::read(dir.join("launch.json"))
        .ok()
        .and_then(|bytes| serde_json::from_slice(&bytes).ok())
    {
        Some(launch) => launch,
        None => return fail(&dir, "launch file unreadable".into()),
    };
    let _ = std::fs::remove_file(dir.join("launch.json"));
    let stdin = launch
        .stdin_base64
        .as_deref()
        .and_then(|data| base64::engine::general_purpose::STANDARD.decode(data).ok());

    let (anchor, anchor_fd) = match spawn_anchor() {
        Ok(anchor) => anchor,
        Err(message) => return fail(&dir, message),
    };
    let _ = write_atomic(&dir.join("anchor"), anchor.to_string().as_bytes());

    use std::os::unix::process::CommandExt;
    let mut command = Command::new(&launch.executable);
    command
        .arg0(&launch.argv[0])
        .args(&launch.argv[1..])
        .current_dir(&launch.cwd)
        .env_clear()
        .envs(launch.env.iter().map(|(key, value)| (key, value)))
        .stdin(if stdin.is_some() {
            Stdio::piped()
        } else {
            Stdio::null()
        })
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .process_group(anchor);
    let mut child = match command.spawn() {
        Ok(child) => child,
        Err(error) => {
            platform::signal(&anchor_fd, libc::SIGKILL);
            // SAFETY: waitpid on our own child.
            unsafe { libc::waitpid(anchor, &mut 0, 0) };
            return fail(&dir, format!("could not start {}: {error}", launch.argv[0]));
        }
    };
    let root = child.id() as i32;
    // Read ends of our own, apart from the readers', which drop theirs at EOF.
    use std::os::fd::AsFd;
    let pins = [
        child
            .stdout
            .as_ref()
            .map(|pipe| pipe.as_fd().try_clone_to_owned()),
        child
            .stderr
            .as_ref()
            .map(|pipe| pipe.as_fd().try_clone_to_owned()),
    ]
    .into_iter()
    .flatten()
    .flatten()
    .collect();
    let mut supervisor = Supervisor {
        dir: dir.clone(),
        me: std::process::id() as i32,
        anchor,
        anchor_fd: Some(anchor_fd),
        root,
        root_status: None,
        owned: HashMap::new(),
        pins: platform::pin(pins),
        since,
        log: std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(dir.join("cleanup.log"))
            .ok(),
    };
    // The root is our unreaped child, so its pid is still its own here.
    if let Some(stat) = platform::stat(root) {
        if let Some(handle) = platform::open_validated(root, stat.start) {
            supervisor.owned.insert((root, stat.start), handle);
        }
    }

    let journal = Arc::new(Mutex::new(Journal::new(
        launch.long_running,
        launch.output_limit,
    )));
    let (done_tx, done_rx) = mpsc::channel();
    let mut readers = 0;
    for (stream, pipe) in [
        (
            0_u8,
            child
                .stdout
                .take()
                .map(|pipe| Box::new(pipe) as Box<dyn Read + Send>),
        ),
        (
            1_u8,
            child
                .stderr
                .take()
                .map(|pipe| Box::new(pipe) as Box<dyn Read + Send>),
        ),
    ] {
        let Some(mut pipe) = pipe else { continue };
        let journal = journal.clone();
        let done = done_tx.clone();
        readers += 1;
        thread::spawn(move || {
            let mut buffer = [0_u8; 16 * 1024];
            while let Ok(read) = pipe.read(&mut buffer) {
                if read == 0 {
                    break;
                }
                journal
                    .lock()
                    .expect("journal lock")
                    .append(stream, &buffer[..read]);
            }
            let _ = done.send(());
        });
    }
    if let (Some(mut input), Some(stdin)) = (child.stdin.take(), stdin) {
        // Written, then closed, so the process sees EOF.
        thread::spawn(move || {
            let _ = input.write_all(&stdin);
        });
    }
    // Never waited through `Child`: `reap` collects every status.
    drop(child);
    let _ = write_atomic(&dir.join("root"), root.to_string().as_bytes());
    let _ = write_atomic(&dir.join("started"), b"");

    let started = Instant::now();
    let deadline = launch
        .timeout_ms
        .map(|ms| started + Duration::from_millis(ms));
    let grace = Duration::from_millis(launch.kill_grace_ms);
    let mut timed_out = false;
    let mut flushed = 0;
    let mut last_flush = Instant::now();
    loop {
        supervisor.reap();
        if supervisor.root_status.is_some() {
            supervisor.stop(grace.min(Duration::from_millis(LEFTOVER_GRACE_MS)));
            break;
        }
        if deadline.is_some_and(|deadline| Instant::now() >= deadline) {
            timed_out = true;
            supervisor.stop(grace);
            break;
        }
        if dir.join("stop").exists() || !dir.is_dir() || lease_lapsed(&dir) {
            supervisor.stop(grace);
            break;
        }
        if last_flush.elapsed() >= Duration::from_millis(100) {
            flushed = flush(&dir, &journal, flushed);
            last_flush = Instant::now();
        }
        thread::sleep(Duration::from_millis(20));
    }
    // Everything that held the pipes is gone; a straggler that escaped
    // the passes doesn't hold the exit back for long.
    drop(done_tx);
    let wait_until = Instant::now() + Duration::from_secs(1);
    for _ in 0..readers {
        if done_rx
            .recv_timeout(wait_until.saturating_duration_since(Instant::now()))
            .is_err()
        {
            break;
        }
    }
    flush(&dir, &journal, u64::MAX);
    let record = ExitRecord {
        exit: supervisor.root_status.unwrap_or(-1),
        timed_out,
    };
    let _ = write_atomic(
        &dir.join("exit.json"),
        &serde_json::to_vec(&record).expect("exit serializes"),
    );
    // Kept for a replay until released, or until nobody renews it for a
    // lease's time after the exit, so a stopped run can still report.
    let _ = write_lease(&dir, None);
    while supervisor.dir.is_dir() {
        if lease_lapsed(&supervisor.dir) {
            let _ = std::fs::remove_dir_all(&supervisor.dir);
            break;
        }
        thread::sleep(Duration::from_millis(250));
    }
}

/// Writes the journal when it changed since version `written`, and
/// returns the version written.
fn flush(dir: &Path, journal: &Mutex<Journal>, written: u64) -> u64 {
    let (bytes, version) = {
        let journal = journal.lock().expect("journal lock");
        if journal.version == written {
            return written;
        }
        (journal.encode(), journal.version)
    };
    if dir.is_dir() {
        let _ = write_atomic(&dir.join("journal"), &bytes);
    }
    version
}

fn spawn_anchor() -> Result<(i32, Handle), String> {
    use std::os::unix::process::CommandExt;
    let exe = std::env::current_exe().map_err(|error| format!("helper path failed: {error}"))?;
    let parent = std::process::id() as i32;
    let mut command = Command::new(exe);
    // SAFETY: `guard_anchor` is async-signal-safe.
    unsafe { command.pre_exec(move || platform::guard_anchor(parent)) };
    let child = command
        .arg("plugin-proc-anchor")
        .arg(parent.to_string())
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .process_group(0)
        .spawn()
        .map_err(|error| format!("anchor spawn failed: {error}"))?;
    let pid = child.id() as i32;
    // Our unreaped child, so its pid is still its own here.
    let handle = platform::stat(pid)
        .and_then(|stat| platform::open_validated(pid, stat.start))
        .ok_or("anchor handle failed")?;
    Ok((pid, handle))
}
