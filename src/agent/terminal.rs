use std::{
    collections::HashMap,
    io::Read,
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    sync::{Arc, Mutex},
    thread::{self, JoinHandle},
    time::{Duration, Instant},
};

#[cfg(unix)]
use std::os::unix::process::CommandExt;

use anyhow::{Context, bail};

use crate::agent::{AgentTrustMode, PermissionDecision, PermissionPolicy, PermissionRequestKind};

#[derive(Clone, Copy, Debug, Eq, PartialEq, Hash)]
pub struct AgentTerminalHandle(pub u64);

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum AgentTerminalStatus {
    Running,
    Exited(Option<i32>),
    Failed,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AgentTerminalResult {
    pub status: AgentTerminalStatus,
}

#[derive(Debug)]
struct AgentTerminalProcess {
    child: Option<Child>,
    output: Arc<Mutex<String>>,
    readers: Vec<JoinHandle<()>>,
    status: AgentTerminalStatus,
}

#[derive(Debug)]
pub struct AgentTerminalService {
    pub policy: PermissionPolicy,
    next_handle: u64,
    processes: HashMap<AgentTerminalHandle, AgentTerminalProcess>,
}

impl AgentTerminalService {
    pub fn new(trust_mode: AgentTrustMode, worktree_path: PathBuf) -> Self {
        Self {
            policy: PermissionPolicy::new(trust_mode, worktree_path),
            next_handle: 1,
            processes: HashMap::new(),
        }
    }

    pub fn create(&mut self, command: &str, cwd: &Path) -> anyhow::Result<AgentTerminalHandle> {
        match self.policy.decide(&PermissionRequestKind::RunTerminal {
            command: command.to_string(),
        }) {
            PermissionDecision::Allow => {}
            PermissionDecision::Ask => {
                bail!("permission required to run terminal command {command}")
            }
            PermissionDecision::Deny => {
                bail!("permission denied to run terminal command {command}")
            }
        }

        let handle = AgentTerminalHandle(self.next_handle);
        self.next_handle = self
            .next_handle
            .checked_add(1)
            .context("terminal handle counter overflow")?;

        let output = Arc::new(Mutex::new(String::new()));
        let mut shell = Command::new(shell_program());
        shell
            .args(shell_args(command))
            .current_dir(cwd)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        configure_process_group(&mut shell);

        let mut child = shell
            .spawn()
            .with_context(|| format!("spawn terminal command {command}"))?;

        let mut readers = Vec::new();
        if let Some(stdout) = child.stdout.take() {
            readers.push(stream_output(stdout, Arc::clone(&output)));
        }
        if let Some(stderr) = child.stderr.take() {
            readers.push(stream_output(stderr, Arc::clone(&output)));
        }

        self.processes.insert(
            handle,
            AgentTerminalProcess {
                child: Some(child),
                output,
                readers,
                status: AgentTerminalStatus::Running,
            },
        );

        Ok(handle)
    }

    pub fn wait_for_exit(
        &mut self,
        handle: AgentTerminalHandle,
    ) -> anyhow::Result<AgentTerminalResult> {
        let process = self
            .processes
            .get_mut(&handle)
            .with_context(|| format!("terminal handle {} not found", handle.0))?;

        if process.status != AgentTerminalStatus::Running {
            return Ok(AgentTerminalResult {
                status: process.status.clone(),
            });
        }

        let Some(mut child) = process.child.take() else {
            process.status = AgentTerminalStatus::Failed;
            join_readers(process);
            return Ok(AgentTerminalResult {
                status: AgentTerminalStatus::Failed,
            });
        };

        let exit_status = child
            .wait()
            .with_context(|| format!("wait for terminal handle {}", handle.0))?;
        process.status = AgentTerminalStatus::Exited(exit_status.code());
        join_readers(process);

        Ok(AgentTerminalResult {
            status: process.status.clone(),
        })
    }

    pub fn output(&self, handle: AgentTerminalHandle) -> anyhow::Result<String> {
        let process = self
            .processes
            .get(&handle)
            .with_context(|| format!("terminal handle {} not found", handle.0))?;
        let output = process
            .output
            .lock()
            .map_err(|_| anyhow::anyhow!("terminal output buffer poisoned"))?;
        Ok(output.clone())
    }

    pub fn kill(&mut self, handle: AgentTerminalHandle) -> anyhow::Result<AgentTerminalResult> {
        let process = self
            .processes
            .get_mut(&handle)
            .with_context(|| format!("terminal handle {} not found", handle.0))?;

        if let Some(mut child) = process.child.take() {
            terminate_child(&mut child);
        }
        process.status = AgentTerminalStatus::Failed;
        join_readers(process);

        Ok(AgentTerminalResult {
            status: AgentTerminalStatus::Failed,
        })
    }

    pub fn release(&mut self, handle: AgentTerminalHandle) -> anyhow::Result<()> {
        let Some(mut process) = self.processes.remove(&handle) else {
            bail!("terminal handle {} not found", handle.0);
        };

        if process.status == AgentTerminalStatus::Running
            && let Some(mut child) = process.child.take()
        {
            terminate_child(&mut child);
        }
        join_readers(&mut process);

        Ok(())
    }
}

fn stream_output<R>(mut reader: R, output: Arc<Mutex<String>>) -> JoinHandle<()>
where
    R: Read + Send + 'static,
{
    thread::spawn(move || {
        let mut buffer = [0_u8; 4096];
        loop {
            match reader.read(&mut buffer) {
                Ok(0) => break,
                Ok(bytes_read) => {
                    let chunk = String::from_utf8_lossy(&buffer[..bytes_read]);
                    if let Ok(mut output) = output.lock() {
                        output.push_str(&chunk);
                    } else {
                        break;
                    }
                }
                Err(_) => break,
            }
        }
    })
}

fn join_readers(process: &mut AgentTerminalProcess) {
    for reader in process.readers.drain(..) {
        let _ = reader.join();
    }
}

fn terminate_child(child: &mut Child) {
    #[cfg(unix)]
    {
        terminate_child_unix(child);
    }

    #[cfg(not(unix))]
    {
        let _ = child.kill();
        let _ = child.wait();
    }
}

#[cfg(unix)]
fn terminate_child_unix(child: &mut Child) {
    const TERM_TIMEOUT: Duration = Duration::from_millis(750);
    const POLL_INTERVAL: Duration = Duration::from_millis(25);

    let pgid = child.id() as libc::pid_t;
    unsafe {
        let _ = libc::kill(-pgid, libc::SIGTERM);
    }

    let deadline = Instant::now() + TERM_TIMEOUT;
    while Instant::now() < deadline {
        match child.try_wait() {
            Ok(Some(_)) => {
                let _ = child.wait();
                return;
            }
            Ok(None) => thread::sleep(POLL_INTERVAL),
            Err(_) => return,
        }
    }

    unsafe {
        let _ = libc::kill(-pgid, libc::SIGKILL);
    }
    let _ = child.kill();
    let _ = child.wait();
}

#[cfg(unix)]
fn configure_process_group(command: &mut Command) {
    unsafe {
        command.pre_exec(|| {
            if libc::setpgid(0, 0) == 0 {
                Ok(())
            } else {
                Err(std::io::Error::last_os_error())
            }
        });
    }
}

#[cfg(not(unix))]
fn configure_process_group(_command: &mut Command) {}

fn shell_program() -> &'static str {
    #[cfg(windows)]
    {
        "cmd"
    }
    #[cfg(not(windows))]
    {
        "/bin/sh"
    }
}

fn shell_args(command: &str) -> [&str; 2] {
    #[cfg(windows)]
    {
        ["/C", command]
    }
    #[cfg(not(windows))]
    {
        ["-lc", command]
    }
}
