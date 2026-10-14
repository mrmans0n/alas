//! Linux: pidfds make every signal hit the process that was checked, and the
//! supervisor is a child subreaper, so orphans stay findable.

use super::*;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};

pub(super) type Handle = OwnedFd;

pub(super) fn supported() -> Result<(), String> {
    if pidfd_supported() {
        Ok(())
    } else {
        Err("this host's Linux kernel lacks pidfd_open and pidfd_send_signal (Linux 5.3 or later is required to stop everything a command starts)".into())
    }
}

fn pidfd_open(pid: i32) -> Option<OwnedFd> {
    // SAFETY: a plain syscall; a non-negative result is a new fd we own.
    let fd = unsafe { libc::syscall(libc::SYS_pidfd_open, pid, 0) };
    (fd >= 0).then(|| unsafe { OwnedFd::from_raw_fd(fd as i32) })
}

fn pidfd_signal(fd: &OwnedFd, signal: i32) -> bool {
    // SAFETY: a plain syscall on an fd we hold, without siginfo.
    unsafe {
        libc::syscall(
            libc::SYS_pidfd_send_signal,
            fd.as_raw_fd(),
            signal,
            std::ptr::null::<libc::siginfo_t>(),
            0,
        ) == 0
    }
}

fn pidfd_supported() -> bool {
    pidfd_open(std::process::id() as i32).is_some_and(|fd| pidfd_signal(&fd, 0))
}

/// Fields of `/proc/<pid>/stat` after the command name, which may itself
/// hold spaces and parentheses.
pub(super) fn parse_stat(text: &str) -> Option<Stat> {
    let fields: Vec<&str> = text[text.rfind(')')? + 1..].split_whitespace().collect();
    Some(Stat {
        dead: matches!(*fields.first()?, "Z" | "X"),
        ppid: fields.get(1)?.parse().ok()?,
        pgrp: fields.get(2)?.parse().ok()?,
        start: fields.get(19)?.parse().ok()?,
    })
}

pub(super) fn stat(pid: i32) -> Option<Stat> {
    parse_stat(&std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?)
}

pub(super) fn pids() -> Vec<i32> {
    std::fs::read_dir("/proc")
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|entry| entry.file_name().to_str()?.parse::<i32>().ok())
        .collect()
}

/// A pidfd for `pid` only while it is still the process sampled with
/// `start`: the fd is opened first and the identity checked while it is
/// held, so a pid reused in between is closed, never signalled.
pub(super) fn open_validated(pid: i32, start: u64) -> Option<Handle> {
    let fd = pidfd_open(pid)?;
    stat(pid)
        .filter(|stat| stat.start == start && !stat.dead)
        .map(|_| fd)
}

pub(super) fn signal(handle: &Handle, signal: i32) -> bool {
    pidfd_signal(handle, signal)
}

pub(super) fn become_reaper() {
    // SAFETY: plain prctl. Orphans of the run reparent here, so they stay
    // findable however they detach.
    unsafe { libc::prctl(libc::PR_SET_CHILD_SUBREAPER, 1) };
}

/// Ignores every signal it can and dies with `parent`. Async-signal-safe,
/// so the anchor runs it between fork and exec: ignored dispositions and
/// the parent-death signal survive exec, so the anchor is never without
/// them, however soon the command signals its group.
pub(super) fn guard_anchor(parent: i32) -> std::io::Result<()> {
    // SAFETY: sigaction and prctl only, both async-signal-safe.
    unsafe {
        for signal in 1..=64 {
            if signal != libc::SIGKILL && signal != libc::SIGSTOP {
                libc::signal(signal, libc::SIG_IGN);
            }
        }
        libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGKILL);
        // The supervisor may have died before the line above took effect.
        if libc::getppid() != parent {
            libc::_exit(0);
        }
    }
    Ok(())
}

/// The parent-death signal set in `guard_anchor` ends it.
pub(super) fn anchor(_parent: i32) -> ! {
    loop {
        // SAFETY: waiting for a signal; every catchable one is ignored.
        unsafe { libc::pause() };
    }
}

/// Nothing to pin: the subreaper keeps every orphan below the supervisor.
pub(super) struct Pins;

pub(super) fn pin(_pipes: Vec<OwnedFd>) -> Pins {
    Pins
}

pub(super) fn strays(_pins: &Pins, _anchor: Option<i32>, _since: u64) -> Vec<(i32, Stat)> {
    Vec::new()
}
