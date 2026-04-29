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
#[cfg(not(feature = "ghostty-vt"))]
compile_error!("Alas V1 requires the ghostty-vt feature for terminal rendering");
#[cfg(feature = "ghostty-vt")]
use libghostty_vt::{
    RenderState, Terminal, TerminalOptions, ffi,
    render::{CellIterator, RowIterator},
    terminal::ScrollViewport,
};
use portable_pty::{Child, CommandBuilder, MasterPty, PtySize, native_pty_system};

use super::{
    CommandSpec, TerminalCell, TerminalCellStyle, TerminalColor, TerminalCursor,
    TerminalCursorShape, TerminalGridSnapshot, TerminalRow, TerminalScreenMode, TerminalStatus,
    TerminalViewport,
};

const MAX_PENDING_PTY_BYTES: usize = 1024 * 1024;
const MAX_SCROLLBACK_ROWS: usize = 10_000;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TerminalBackendSession {
    pub backend_id: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TerminalSize {
    pub cols: u16,
    pub rows: u16,
}

pub trait TerminalBackend {
    fn start(&mut self, command: CommandSpec) -> anyhow::Result<TerminalBackendSession>;
    fn write_input(&mut self, session: TerminalBackendSession, bytes: &[u8]) -> anyhow::Result<()>;
    fn resize(&mut self, session: TerminalBackendSession, size: TerminalSize)
    -> anyhow::Result<()>;
    fn snapshot(
        &mut self,
        session: TerminalBackendSession,
        viewport: TerminalViewport,
    ) -> anyhow::Result<TerminalGridSnapshot>;
    fn has_exited(&mut self, session: TerminalBackendSession) -> anyhow::Result<bool>;
    fn restart(
        &mut self,
        session: TerminalBackendSession,
    ) -> anyhow::Result<TerminalBackendSession>;

    fn stop(&mut self, _session: TerminalBackendSession) -> anyhow::Result<()> {
        Ok(())
    }
}

#[cfg(feature = "ghostty-vt")]
struct VtState {
    terminal: Terminal<'static, 'static>,
    render_state: RenderState<'static>,
    row_iter: RowIterator<'static>,
    cell_iter: CellIterator<'static>,
}

#[cfg(feature = "ghostty-vt")]
impl VtState {
    fn new(size: TerminalSize) -> anyhow::Result<Self> {
        Ok(Self {
            terminal: Terminal::new(TerminalOptions {
                cols: size.cols,
                rows: size.rows,
                max_scrollback: MAX_SCROLLBACK_ROWS,
            })
            .context("create Ghostty VT terminal")?,
            render_state: RenderState::new().context("create Ghostty VT render state")?,
            row_iter: RowIterator::new().context("create Ghostty VT row iterator")?,
            cell_iter: CellIterator::new().context("create Ghostty VT cell iterator")?,
        })
    }

    fn feed(&mut self, bytes: &[u8]) {
        self.terminal.vt_write(bytes);
    }

    fn resize(&mut self, size: TerminalSize) -> anyhow::Result<()> {
        self.terminal
            .resize(size.cols, size.rows, 0, 0)
            .context("resize Ghostty VT terminal")
    }

    fn snapshot_rows(&mut self, viewport: TerminalViewport) -> anyhow::Result<VtSnapshotRows> {
        let screen_mode = self.screen_mode()?;
        let raw_scrollback_rows = self
            .terminal
            .scrollback_rows()
            .context("read Ghostty VT scrollback row count")?;
        let scrollback_rows = match screen_mode {
            TerminalScreenMode::Main => raw_scrollback_rows,
            TerminalScreenMode::Alternate => 0,
        };
        let terminal_rows = self
            .terminal
            .rows()
            .context("read Ghostty VT terminal row count")?;
        let bounded_viewport = viewport.clamped(scrollback_rows, terminal_rows);

        self.terminal.scroll_viewport(ScrollViewport::Bottom);
        if bounded_viewport.scroll_offset_rows > 0 {
            let delta = isize::try_from(bounded_viewport.scroll_offset_rows)
                .context("convert Ghostty VT scrollback offset to viewport delta")?;
            self.terminal.scroll_viewport(ScrollViewport::Delta(-delta));
        }

        let result = (|| -> anyhow::Result<(Vec<TerminalRow>, Option<TerminalCursor>)> {
            let snapshot = self
                .render_state
                .update(&self.terminal)
                .context("update Ghostty VT render state")?;
            let cursor = snapshot
                .cursor_viewport()
                .context("read Ghostty VT cursor viewport")?
                .map(|cursor| TerminalCursor {
                    col: cursor.x,
                    row: cursor.y,
                    visible: true,
                    shape: TerminalCursorShape::Block,
                });
            let mut rows = self
                .row_iter
                .update(&snapshot)
                .context("iterate Ghostty VT render rows")?;
            let mut terminal_rows = Vec::new();

            while let Some(row) = rows.next() {
                let mut cells = self
                    .cell_iter
                    .update(row)
                    .context("iterate Ghostty VT render cells")?;
                let mut row_cells = Vec::new();
                while let Some(cell) = cells.next() {
                    let text: String = cell
                        .graphemes()
                        .context("read Ghostty VT render cell graphemes")?
                        .into_iter()
                        .filter(|grapheme| *grapheme != '\0')
                        .collect();
                    row_cells.push(TerminalCell {
                        text,
                        style: convert_style(cell)?,
                    });
                }
                while row_cells
                    .last()
                    .is_some_and(|cell| cell.text.trim().is_empty())
                {
                    row_cells.pop();
                }
                terminal_rows.push(TerminalRow { cells: row_cells });
            }

            Ok((terminal_rows, cursor))
        })();
        self.terminal.scroll_viewport(ScrollViewport::Bottom);

        let (mut terminal_rows, mut cursor) = result?;
        let visible_rows = usize::from(bounded_viewport.visible_rows);
        if terminal_rows.len() > visible_rows {
            let crop_start = terminal_rows.len() - visible_rows;
            cursor = cursor.and_then(|cursor| {
                if usize::from(cursor.row) < crop_start {
                    None
                } else {
                    Some(TerminalCursor {
                        row: cursor.row - u16::try_from(crop_start).ok()?,
                        ..cursor
                    })
                }
            });
            terminal_rows = terminal_rows.split_off(crop_start);
        }

        Ok(VtSnapshotRows {
            rows: terminal_rows,
            cursor,
            viewport: bounded_viewport,
            scrollback_rows,
            screen_mode,
        })
    }

    fn screen_mode(&self) -> anyhow::Result<TerminalScreenMode> {
        match self
            .terminal
            .active_screen()
            .context("read Ghostty VT active screen")?
        {
            ffi::GhosttyTerminalScreen_GHOSTTY_TERMINAL_SCREEN_PRIMARY => {
                Ok(TerminalScreenMode::Main)
            }
            ffi::GhosttyTerminalScreen_GHOSTTY_TERMINAL_SCREEN_ALTERNATE => {
                Ok(TerminalScreenMode::Alternate)
            }
            screen => anyhow::bail!("unknown Ghostty VT active screen {screen}"),
        }
    }
}

#[cfg(feature = "ghostty-vt")]
fn convert_rgb(color: libghostty_vt::style::RgbColor) -> TerminalColor {
    TerminalColor::rgb(color.r, color.g, color.b)
}

#[cfg(feature = "ghostty-vt")]
fn convert_style(
    cell: &libghostty_vt::render::CellIteration<'_, '_>,
) -> anyhow::Result<TerminalCellStyle> {
    let style = cell.style().context("read Ghostty cell style")?;
    Ok(TerminalCellStyle {
        foreground: cell
            .fg_color()
            .context("read Ghostty foreground")?
            .map(convert_rgb),
        background: cell
            .bg_color()
            .context("read Ghostty background")?
            .map(convert_rgb),
        bold: style.bold,
        italic: style.italic,
        underline: !matches!(style.underline, libghostty_vt::style::Underline::None),
        inverse: style.inverse,
        strikethrough: style.strikethrough,
    })
}

#[cfg(feature = "ghostty-vt")]
struct VtSnapshotRows {
    rows: Vec<TerminalRow>,
    cursor: Option<TerminalCursor>,
    viewport: TerminalViewport,
    scrollback_rows: usize,
    screen_mode: TerminalScreenMode,
}

struct BackendSessionState {
    command: CommandSpec,
    size: TerminalSize,
    master: Box<dyn MasterPty + Send>,
    writer: Box<dyn Write + Send>,
    child: Box<dyn Child + Send + Sync>,
    read_buffer: Arc<Mutex<Vec<u8>>>,
    vt: VtState,
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
        let bytes = {
            let mut read_buffer = self
                .read_buffer
                .lock()
                .map_err(|_| anyhow::anyhow!("terminal backend reader buffer lock poisoned"))?;
            std::mem::take(&mut *read_buffer)
        };

        if !bytes.is_empty() {
            self.vt.feed(&bytes);
        }
        Ok(())
    }

    fn snapshot_rows(&mut self, viewport: TerminalViewport) -> anyhow::Result<VtSnapshotRows> {
        self.vt.snapshot_rows(viewport)
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
                vt: VtState::new(size)?,
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
        state.vt.resize(size)?;
        Ok(())
    }

    fn snapshot(
        &mut self,
        session: TerminalBackendSession,
        viewport: TerminalViewport,
    ) -> anyhow::Result<TerminalGridSnapshot> {
        let state = self.sessions.get_mut(&session.backend_id).ok_or_else(|| {
            anyhow::anyhow!("unknown terminal backend session {}", session.backend_id)
        })?;
        state.poll_exit()?;
        state.drain_output()?;
        let vt_snapshot = state.snapshot_rows(viewport)?;
        let status = if state.exited {
            TerminalStatus::Exited(state.exit_status)
        } else {
            TerminalStatus::Running
        };
        Ok(TerminalGridSnapshot {
            size: state.size,
            rows: vt_snapshot.rows,
            cursor: vt_snapshot.cursor,
            status,
            viewport: vt_snapshot.viewport,
            scrollback_rows: vt_snapshot.scrollback_rows,
            screen_mode: vt_snapshot.screen_mode,
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

    fn stop(&mut self, session: TerminalBackendSession) -> anyhow::Result<()> {
        self.sessions.remove(&session.backend_id).ok_or_else(|| {
            anyhow::anyhow!("unknown terminal backend session {}", session.backend_id)
        })?;
        Ok(())
    }
}

fn read_pty_output(mut reader: Box<dyn Read + Send>, read_buffer: Arc<Mutex<Vec<u8>>>) {
    let mut buffer = [0; 8192];
    loop {
        match reader.read(&mut buffer) {
            Ok(0) => break,
            Ok(bytes_read) => {
                if let Ok(mut output) = read_buffer.lock() {
                    append_bounded_bytes(&mut output, &buffer[..bytes_read], MAX_PENDING_PTY_BYTES);
                } else {
                    break;
                }
            }
            Err(_) => break,
        }
    }
}

fn append_bounded_bytes(buffer: &mut Vec<u8>, bytes: &[u8], max_len: usize) {
    if bytes.len() >= max_len {
        buffer.clear();
        buffer.extend_from_slice(&bytes[bytes.len() - max_len..]);
        return;
    }

    let needed = buffer
        .len()
        .saturating_add(bytes.len())
        .saturating_sub(max_len);
    if needed > 0 {
        buffer.drain(..needed);
    }
    buffer.extend_from_slice(bytes);
}
