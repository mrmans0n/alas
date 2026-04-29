//! Ghostty terminal adapter boundary.
//!
//! The GPUI application model should depend on [`TerminalBackend`] and
//! [`TerminalBackendSession`] instead of libghostty-specific types. The real
//! libghostty-rs integration belongs behind this module boundary.

use std::collections::HashMap;
use std::io::{Read, Write};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;

use anyhow::Context;
use portable_pty::{Child, CommandBuilder, MasterPty, PtySize, native_pty_system};

use super::CommandSpec;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TerminalBackendSession {
    pub backend_id: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TerminalSize {
    pub cols: u16,
    pub rows: u16,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TerminalGridSnapshot {
    pub size: TerminalSize,
    pub lines: Vec<String>,
    pub cursor: Option<(u16, u16)>,
    pub exited: bool,
    pub exit_status: Option<i32>,
}

pub trait TerminalBackend {
    fn start(&mut self, command: CommandSpec) -> anyhow::Result<TerminalBackendSession>;
    fn write_input(&mut self, session: TerminalBackendSession, bytes: &[u8]) -> anyhow::Result<()>;
    fn resize(&mut self, session: TerminalBackendSession, size: TerminalSize)
    -> anyhow::Result<()>;
    fn snapshot(&mut self, session: TerminalBackendSession)
    -> anyhow::Result<TerminalGridSnapshot>;
    fn has_exited(&mut self, session: TerminalBackendSession) -> anyhow::Result<bool>;
    fn restart(
        &mut self,
        session: TerminalBackendSession,
    ) -> anyhow::Result<TerminalBackendSession>;
}

struct BackendSessionState {
    command: CommandSpec,
    size: TerminalSize,
    master: Box<dyn MasterPty + Send>,
    writer: Box<dyn Write + Send>,
    child: Box<dyn Child + Send + Sync>,
    read_buffer: Arc<Mutex<Vec<u8>>>,
    output: String,
    _reader_thread: JoinHandle<()>,
    exited: bool,
    exit_status: Option<i32>,
}

impl BackendSessionState {
    fn poll_exit(&mut self) -> anyhow::Result<bool> {
        if self.exited {
            return Ok(true);
        }

        if let Some(status) = self.child.try_wait().with_context(|| {
            format!(
                "poll command '{}' in cwd {}",
                self.command.display,
                self.command.cwd.display()
            )
        })? {
            self.exited = true;
            self.exit_status = Some(status.exit_code() as i32);
        }

        Ok(self.exited)
    }

    fn drain_output(&mut self) -> anyhow::Result<()> {
        let mut read_buffer = self
            .read_buffer
            .lock()
            .map_err(|_| anyhow::anyhow!("terminal backend reader buffer lock poisoned"))?;
        if !read_buffer.is_empty() {
            self.output.push_str(&String::from_utf8_lossy(&read_buffer));
            read_buffer.clear();
        }
        Ok(())
    }

    fn snapshot_lines(&self) -> Vec<String> {
        self.output
            .replace('\r', "")
            .lines()
            .map(ToString::to_string)
            .collect()
    }
}

impl Drop for BackendSessionState {
    fn drop(&mut self) {
        if !self.exited {
            let _ = self.child.kill();
        }
    }
}

#[derive(Default)]
pub struct GhosttyTerminalBackend {
    next_id: u64,
    sessions: HashMap<u64, BackendSessionState>,
}

impl GhosttyTerminalBackend {
    pub fn new() -> Self {
        Self::default()
    }
}

impl TerminalBackend for GhosttyTerminalBackend {
    fn start(&mut self, command: CommandSpec) -> anyhow::Result<TerminalBackendSession> {
        let size = TerminalSize { cols: 80, rows: 24 };
        let pty_system = native_pty_system();
        let pair = pty_system
            .openpty(PtySize {
                rows: size.rows,
                cols: size.cols,
                pixel_width: 0,
                pixel_height: 0,
            })
            .with_context(|| {
                format!(
                    "open PTY for command '{}' in cwd {}",
                    command.display,
                    command.cwd.display()
                )
            })?;

        let mut builder = CommandBuilder::new(&command.program);
        builder.args(&command.args);
        builder.cwd(command.cwd.as_os_str());

        let child = pair.slave.spawn_command(builder).with_context(|| {
            format!(
                "spawn command '{}' in cwd {}",
                command.display,
                command.cwd.display()
            )
        })?;
        let reader = pair.master.try_clone_reader().with_context(|| {
            format!(
                "clone PTY reader for command '{}' in cwd {}",
                command.display,
                command.cwd.display()
            )
        })?;
        let writer = pair.master.take_writer().with_context(|| {
            format!(
                "take PTY writer for command '{}' in cwd {}",
                command.display,
                command.cwd.display()
            )
        })?;
        let read_buffer = Arc::new(Mutex::new(Vec::new()));
        let reader_buffer = Arc::clone(&read_buffer);
        let reader_thread = std::thread::spawn(move || read_pty_output(reader, reader_buffer));

        self.next_id += 1;
        let session = TerminalBackendSession {
            backend_id: self.next_id,
        };
        self.sessions.insert(
            session.backend_id,
            BackendSessionState {
                command,
                size,
                master: pair.master,
                writer,
                child,
                read_buffer,
                output: String::new(),
                _reader_thread: reader_thread,
                exited: false,
                exit_status: None,
            },
        );
        Ok(session)
    }

    fn write_input(&mut self, session: TerminalBackendSession, bytes: &[u8]) -> anyhow::Result<()> {
        let state = self.sessions.get_mut(&session.backend_id).ok_or_else(|| {
            anyhow::anyhow!("unknown terminal backend session {}", session.backend_id)
        })?;
        state.writer.write_all(bytes).with_context(|| {
            format!(
                "write input to command '{}' in cwd {}",
                state.command.display,
                state.command.cwd.display()
            )
        })?;
        state.writer.flush().with_context(|| {
            format!(
                "flush input to command '{}' in cwd {}",
                state.command.display,
                state.command.cwd.display()
            )
        })?;
        Ok(())
    }

    fn resize(
        &mut self,
        session: TerminalBackendSession,
        size: TerminalSize,
    ) -> anyhow::Result<()> {
        let state = self.sessions.get_mut(&session.backend_id).ok_or_else(|| {
            anyhow::anyhow!("unknown terminal backend session {}", session.backend_id)
        })?;
        state
            .master
            .resize(PtySize {
                rows: size.rows,
                cols: size.cols,
                pixel_width: 0,
                pixel_height: 0,
            })
            .with_context(|| {
                format!(
                    "resize PTY for command '{}' in cwd {}",
                    state.command.display,
                    state.command.cwd.display()
                )
            })?;
        state.size = size;
        Ok(())
    }

    fn snapshot(
        &mut self,
        session: TerminalBackendSession,
    ) -> anyhow::Result<TerminalGridSnapshot> {
        let state = self.sessions.get_mut(&session.backend_id).ok_or_else(|| {
            anyhow::anyhow!("unknown terminal backend session {}", session.backend_id)
        })?;
        state.poll_exit()?;
        state.drain_output()?;
        Ok(TerminalGridSnapshot {
            size: state.size,
            lines: state.snapshot_lines(),
            cursor: None,
            exited: state.exited,
            exit_status: state.exit_status,
        })
    }

    fn has_exited(&mut self, session: TerminalBackendSession) -> anyhow::Result<bool> {
        let state = self.sessions.get_mut(&session.backend_id).ok_or_else(|| {
            anyhow::anyhow!("unknown terminal backend session {}", session.backend_id)
        })?;
        state.poll_exit()
    }

    fn restart(
        &mut self,
        session: TerminalBackendSession,
    ) -> anyhow::Result<TerminalBackendSession> {
        let state = self.sessions.remove(&session.backend_id).ok_or_else(|| {
            anyhow::anyhow!("unknown terminal backend session {}", session.backend_id)
        })?;
        let command = state.command.clone();
        drop(state);
        self.start(command)
    }
}

fn read_pty_output(mut reader: Box<dyn Read + Send>, read_buffer: Arc<Mutex<Vec<u8>>>) {
    let mut buffer = [0; 8192];
    loop {
        match reader.read(&mut buffer) {
            Ok(0) => break,
            Ok(bytes_read) => {
                if let Ok(mut output) = read_buffer.lock() {
                    output.extend_from_slice(&buffer[..bytes_read]);
                } else {
                    break;
                }
            }
            Err(_) => break,
        }
    }
}
