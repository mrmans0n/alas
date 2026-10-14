//! macOS: no pidfds and no subreaper. A process is its pid and start time,
//! checked again immediately before every signal. Orphans, which launchd
//! adopts at once, are found by the run's process group and output pipes
//! (`strays`).
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
    bsdinfo(pid).map(|info| stat_of(&info))
}

fn stat_of(info: &libc::proc_bsdinfo) -> Stat {
    Stat {
        ppid: info.pbi_ppid as i32,
        pgrp: info.pbi_pgid as i32,
        start: info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec,
        dead: info.pbi_status == libc::SZOMB,
    }
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

/// `struct proc_fileinfo` from `<sys/proc_info.h>`.
#[repr(C)]
struct ProcFileInfo {
    fi_openflags: u32,
    fi_status: u32,
    fi_offset: libc::off_t,
    fi_type: i32,
    fi_guardflags: u32,
}

/// `struct pipe_fdinfo` from `<sys/proc_info.h>`.
#[repr(C)]
struct PipeFdInfo {
    pfi: ProcFileInfo,
    pipe_stat: libc::vinfo_stat,
    pipe_handle: u64,
    pipe_peerhandle: u64,
    pipe_status: i32,
    rfu_1: i32,
}

const PROC_PIDFDPIPEINFO: i32 = 6;

/// Both ends of the pipe `fd` of `pid` is, by their kernel handles.
fn pipe_ends(pid: i32, fd: i32) -> Option<[u64; 2]> {
    // SAFETY: plain data, filled below.
    let mut info: PipeFdInfo = unsafe { std::mem::zeroed() };
    let size = std::mem::size_of::<PipeFdInfo>() as i32;
    // SAFETY: proc_pidfdinfo fills at most `size` bytes of a local.
    let filled = unsafe {
        libc::proc_pidfdinfo(
            pid,
            fd,
            PROC_PIDFDPIPEINFO,
            (&mut info as *mut PipeFdInfo).cast(),
            size,
        )
    };
    (filled == size).then_some([info.pipe_handle, info.pipe_peerhandle])
}

/// The pipes `pid` holds, each as the handle of the end it holds.
fn pipes_held(pid: i32) -> Vec<u64> {
    // SAFETY: a null buffer asks for the size.
    let bytes =
        unsafe { libc::proc_pidinfo(pid, libc::PROC_PIDLISTFDS, 0, std::ptr::null_mut(), 0) };
    if bytes <= 0 {
        return Vec::new();
    }
    let mut fds: Vec<libc::proc_fdinfo> =
        Vec::with_capacity(bytes as usize / std::mem::size_of::<libc::proc_fdinfo>() + 8);
    let capacity = (fds.capacity() * std::mem::size_of::<libc::proc_fdinfo>()) as i32;
    // SAFETY: the buffer holds `capacity` bytes; only what was filled is kept.
    let filled = unsafe {
        let filled = libc::proc_pidinfo(
            pid,
            libc::PROC_PIDLISTFDS,
            0,
            fds.as_mut_ptr().cast(),
            capacity,
        );
        fds.set_len(filled.max(0) as usize / std::mem::size_of::<libc::proc_fdinfo>());
        filled
    };
    if filled <= 0 {
        return Vec::new();
    }
    fds.iter()
        .filter(|fd| fd.proc_fdtype == libc::PROX_FDTYPE_PIPE as u32)
        .filter_map(|fd| pipe_ends(pid, fd.proc_fd).map(|[held, _]| held))
        .collect()
}

/// The run's output pipes, held open by the supervisor so their handles can't
/// be reused for another pipe while cleanup looks for them.
pub(super) struct Pins {
    _fds: Vec<std::os::fd::OwnedFd>,
    /// Both ends of every pinned pipe.
    handles: Vec<u64>,
}

pub(super) fn pin(pipes: Vec<std::os::fd::OwnedFd>) -> Pins {
    use std::os::fd::AsRawFd;
    let me = std::process::id() as i32;
    let handles = pipes
        .iter()
        .filter_map(|fd| pipe_ends(me, fd.as_raw_fd()))
        .flatten()
        .collect();
    Pins {
        _fds: pipes,
        handles,
    }
}

/// The user's processes started since `since` that launchd may have adopted
/// but still belong to the run: in the anchor's group while it lives, or
/// holding either end of the run's output pipes.
/// ponytail: one that left the group and redirected its output before a
/// sample saw it below the supervisor escapes.
pub(super) fn strays(pins: &Pins, anchor: Option<i32>, since: u64) -> Vec<(i32, Stat)> {
    let me = std::process::id() as i32;
    // SAFETY: getuid only.
    let uid = unsafe { libc::getuid() };
    pids()
        .into_iter()
        .filter(|pid| *pid != me && Some(*pid) != anchor)
        .filter_map(|pid| {
            let info = bsdinfo(pid)?;
            let stat = stat_of(&info);
            (info.pbi_uid == uid && stat.start >= since && !stat.dead).then_some((pid, stat))
        })
        .filter(|(pid, stat)| {
            Some(stat.pgrp) == anchor
                || (!pins.handles.is_empty()
                    && pipes_held(*pid)
                        .iter()
                        .any(|held| pins.handles.contains(held)))
        })
        .collect()
}
