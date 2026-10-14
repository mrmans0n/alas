//! macOS: no pidfds and no subreaper. A process is its pid and start time,
//! checked again immediately before every signal.
//! ponytail: a pid reused between the check and `kill` is still hit; that
//! needs the pid space to wrap within microseconds.

use super::*;

#[derive(Debug, Clone, Copy, PartialEq)]
pub(super) struct Handle {
    pid: i32,
    start: u64,
}

pub(super) fn supported() -> Result<(), String> {
    Ok(())
}

fn bsdinfo(pid: i32) -> Option<libc::proc_bsdinfo> {
    // SAFETY: plain data, filled below.
    let mut info: libc::proc_bsdinfo = unsafe { std::mem::zeroed() };
    let size = std::mem::size_of::<libc::proc_bsdinfo>() as i32;
    // SAFETY: proc_pidinfo fills at most `size` bytes of a local.
    let filled = unsafe {
        libc::proc_pidinfo(
            pid,
            libc::PROC_PIDTBSDINFO,
            0,
            (&mut info as *mut libc::proc_bsdinfo).cast(),
            size,
        )
    };
    (filled == size).then_some(info)
}

pub(super) fn stat(pid: i32) -> Option<Stat> {
    let info = bsdinfo(pid)?;
    Some(Stat {
        ppid: info.pbi_ppid as i32,
        pgrp: info.pbi_pgid as i32,
        start: info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec,
        dead: info.pbi_status == libc::SZOMB,
    })
}

pub(super) fn pids() -> Vec<i32> {
    // SAFETY: a null buffer asks for the count.
    let count = unsafe { libc::proc_listallpids(std::ptr::null_mut(), 0) };
    if count <= 0 {
        return Vec::new();
    }
    // Room for processes started since the count.
    let mut pids = vec![0_i32; count as usize + 64];
    let bytes = (pids.len() * std::mem::size_of::<i32>()) as i32;
    // SAFETY: the buffer holds `bytes` bytes.
    let filled = unsafe { libc::proc_listallpids(pids.as_mut_ptr().cast(), bytes) };
    pids.truncate(filled.max(0) as usize);
    pids.retain(|pid| *pid > 0);
    pids
}

fn matches(handle: &Handle) -> bool {
    stat(handle.pid).is_some_and(|stat| stat.start == handle.start && !stat.dead)
}

/// A handle for `pid` only while it is still the process sampled with `start`.
pub(super) fn open_validated(pid: i32, start: u64) -> Option<Handle> {
    let handle = Handle { pid, start };
    matches(&handle).then_some(handle)
}

pub(super) fn signal(handle: &Handle, signal: i32) -> bool {
    // SAFETY: plain kill, right after the identity check.
    matches(handle) && unsafe { libc::kill(handle.pid, signal) } == 0
}

/// macOS has no subreaper: orphans go to launchd at once.
pub(super) fn become_reaper() {}

/// Ignores every signal it can. Async-signal-safe, so the anchor runs it
/// between fork and exec: ignored dispositions survive exec, so the anchor is
/// never without them, however soon the command signals its group.
pub(super) fn guard_anchor(parent: i32) -> std::io::Result<()> {
    // SAFETY: signal, getppid and _exit only, all async-signal-safe.
    unsafe {
        for signal in 1..32 {
            if signal != libc::SIGKILL && signal != libc::SIGSTOP {
                libc::signal(signal, libc::SIG_IGN);
            }
        }
        // The supervisor may already be gone.
        if libc::getppid() != parent {
            libc::_exit(0);
        }
    }
    Ok(())
}

/// Without a parent-death signal, the anchor watches for its supervisor to go:
/// once it is reparented, the group it leads no longer needs keeping.
pub(super) fn anchor(parent: i32) -> ! {
    // SAFETY: getppid only.
    while unsafe { libc::getppid() } == parent {
        thread::sleep(Duration::from_millis(250));
    }
    std::process::exit(0);
}
