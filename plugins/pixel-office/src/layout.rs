//! Where everything sits. Pure function of the snapshot.

use crate::canvas::Rect;
use alas_plugin::{Dirty, Snapshot};

pub const ROOM_W: i32 = 320;
pub const BASE_H: i32 = 180;
/// Desk rows start below the wall (0..24) and the lounge strip (24..64).
pub const TOP: i32 = 64;
pub const ROW_H: i32 = 48;
pub const PODS_PER_ROW: usize = 4;
pub const SEATS: usize = 4;
pub const MAX_H: i32 = 1024;
pub const BOTTOM_MARGIN: i32 = 12;
/// Where characters enter and leave (in front of the door, top-left).
pub const DOOR: (i32, i32) = (24, 56);
/// The corridor along the left wall joining the lounge and every desk row.
pub const SIDE_X: i32 = 4;
/// Standing/sitting spots in the lounge strip: coffee machine, water cooler, window.
pub const LOUNGE: [(i32, i32); 6] = [(96, 56), (112, 56), (176, 56), (192, 56), (256, 56), (272, 56)];
/// Couch seats, where sleepers go (top-left of a 16x24 sleeping sprite; the couch is drawn at y=36).
pub const COUCH_SPOTS: [(i32, i32); 2] = [(216, 29), (232, 29)];

#[derive(Debug, Clone, PartialEq)]
pub struct Pod {
    pub worktree_id: String,
    pub branch: String,
    pub desk: Rect,
    /// Top-left of each seated character (16x24).
    pub seats: [(i32, i32); SEATS],
    pub seated: Vec<String>,
    pub overflow: usize,
    pub lamp_on: bool,
    pub papers: u8,
    pub warning: bool,
    pub files: Option<u32>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Layout {
    pub height: i32,
    pub pods: Vec<Pod>,
    pub hidden_worktrees: usize,
}

/// Desk pods drawn at most; the rest go on the "+N more" sign. Measured worst case (every
/// pod seating four sessions) is about 1.4M fuel per pod plus 1.3M, so 12 pods cost about
/// 18M of a call's 25M budget. The rest of the headroom is for slower-than-measured phases.
pub const MAX_PODS: usize = 12;

pub fn max_pods() -> usize {
    MAX_PODS.min(((MAX_H - TOP - BOTTOM_MARGIN) / ROW_H) as usize * PODS_PER_ROW)
}

/// Which worktrees get a desk, as indexes into the snapshot in snapshot order. Past the cap,
/// the current worktree comes first, then those with sessions, then the quiet ones, so a cap
/// never hides what the user is looking at or an active agent. Membership changes only when
/// the set crosses the cap, so desks do not shuffle as sessions start and stop.
fn shown_worktrees(snapshot: &Snapshot) -> Vec<usize> {
    let worktrees = &snapshot.worktrees;
    let rank = |i: usize| match (worktrees[i].current, worktrees[i].sessions.is_empty()) {
        (true, _) => 0,
        (false, false) => 1,
        (false, true) => 2,
    };
    let mut order: Vec<usize> = (0..worktrees.len()).collect();
    order.sort_by_key(|&i| rank(i)); // stable: snapshot order breaks ties
    order.truncate(max_pods());
    order.sort_unstable();
    order
}

pub fn papers_bucket(dirty: Option<Dirty>) -> u8 {
    match dirty.map(|d| d.files) {
        None | Some(0) => 0,
        Some(1..=5) => 1,
        Some(6..=20) => 2,
        Some(_) => 3,
    }
}

/// The walking lane of the row containing `y`: just below its desks, or the lounge strip.
pub fn aisle_y(y: i32) -> i32 {
    if y < TOP { DOOR.1 } else { TOP + (y - TOP) / ROW_H * ROW_H + 40 }
}

pub fn layout(snapshot: &Snapshot) -> Layout {
    let indexes = shown_worktrees(snapshot);
    let shown = indexes.len();
    let rows = shown.div_ceil(PODS_PER_ROW) as i32;
    let pods = indexes
        .iter()
        .map(|&index| &snapshot.worktrees[index])
        .enumerate()
        .map(|(i, worktree)| {
            let x = (i % PODS_PER_ROW) as i32 * (ROOM_W / PODS_PER_ROW as i32);
            let y = TOP + (i / PODS_PER_ROW) as i32 * ROW_H;
            let desk = Rect::new(x + 8, y + 16, 64, 16);
            let seats = [0, 1, 2, 3].map(|s| (desk.x + s * 16, y));
            Pod {
                worktree_id: worktree.id.clone(),
                branch: worktree.branch.clone(),
                desk,
                seats,
                seated: worktree.sessions.iter().take(SEATS).map(|s| s.id.clone()).collect(),
                overflow: worktree.sessions.len().saturating_sub(SEATS),
                lamp_on: worktree.current,
                papers: papers_bucket(worktree.dirty),
                warning: worktree.dirty.is_some_and(|d| d.conflicts > 0),
                files: worktree.dirty.map(|d| d.files),
            }
        })
        .collect();
    Layout {
        height: BASE_H.max(TOP + rows * ROW_H + BOTTOM_MARGIN).min(MAX_H),
        pods,
        hidden_worktrees: snapshot.worktrees.len() - shown,
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use alas_plugin::{Session, Worktree};

    pub(crate) fn snapshot(sessions_per_worktree: &[usize]) -> Snapshot {
        Snapshot {
            worktrees: sessions_per_worktree
                .iter()
                .enumerate()
                .map(|(w, &n)| Worktree {
                    id: format!("w{w}"),
                    branch: format!("b{w}"),
                    current: w == 0,
                    dirty: None,
                    sessions: (0..n)
                        .map(|s| Session {
                            id: format!("w{w}s{s}"),
                            agent: "claude".into(),
                            title: format!("T{s}"),
                            state: "running".into(),
                            plan: None,
                        })
                        .collect(),
                })
                .collect(),
        }
    }

    #[test]
    fn pods_fill_rows_of_four_and_the_room_grows_downward() {
        assert_eq!(layout(&snapshot(&[0; 5])).height, BASE_H);
        let nine = layout(&snapshot(&[0; 9]));
        assert_eq!(nine.height, TOP + 3 * ROW_H + BOTTOM_MARGIN);
        assert_eq!(nine.pods[4].desk.y, TOP + ROW_H + 16);
        assert!(nine.pods[0].lamp_on && !nine.pods[1].lamp_on);
    }

    #[test]
    fn a_pod_seats_four_and_counts_the_rest() {
        let pod = &layout(&snapshot(&[6])).pods[0];
        assert_eq!(pod.seated.len(), 4);
        assert_eq!(pod.overflow, 2);
    }

    /// Review focus 5.
    #[test]
    fn overflowing_worktrees_are_summarised_and_height_is_capped() {
        let big = layout(&snapshot(&vec![0; max_pods() + 4]));
        assert_eq!(big.pods.len(), max_pods());
        assert_eq!(big.hidden_worktrees, 4);
        assert!(big.height <= MAX_H);
    }

    /// A cap must never hide the worktrees that matter: active sessions and the current one
    /// stay, the quiet ones make way, and the order on screen is still the snapshot's.
    #[test]
    fn the_cap_keeps_worktrees_with_sessions_and_the_current_one_in_snapshot_order() {
        let mut counts = vec![0; max_pods() + 6];
        for busy in [max_pods() + 2, max_pods() + 4] {
            counts[busy] = 1;
        }
        let mut snap = snapshot(&counts);
        snap.worktrees[0].current = false;
        snap.worktrees[3].current = true;

        let laid_out = layout(&snap);
        let shown: Vec<&str> = laid_out.pods.iter().map(|p| p.worktree_id.as_str()).collect();

        assert_eq!(shown.len(), max_pods());
        let position = |id: &str| shown.iter().position(|shown| *shown == id);
        let (current, first_busy, second_busy) = (position("w3"), position(&format!("w{}", max_pods() + 2)), position(&format!("w{}", max_pods() + 4)));
        assert!(current.is_some() && first_busy.is_some() && second_busy.is_some());
        assert!(current < first_busy && first_busy < second_busy, "snapshot order is kept: {shown:?}");
        assert!(shown.windows(2).all(|pair| index(pair[0]) < index(pair[1])));
    }

    /// The current worktree is the one the user is looking at: even when more than a cap's worth
    /// of earlier worktrees are busy, it keeps its desk.
    #[test]
    fn the_current_worktree_keeps_its_desk_when_earlier_worktrees_fill_the_cap() {
        let mut counts = vec![1; max_pods() + 3];
        counts.push(0);
        let mut snap = snapshot(&counts);
        snap.worktrees[0].current = false;
        let last = snap.worktrees.len() - 1;
        snap.worktrees[last].current = true;

        let laid_out = layout(&snap);
        let shown: Vec<&str> = laid_out.pods.iter().map(|p| p.worktree_id.as_str()).collect();

        assert_eq!(shown.len(), max_pods());
        assert!(shown.contains(&format!("w{last}").as_str()), "current worktree dropped: {shown:?}");
        assert!(shown.windows(2).all(|pair| index(pair[0]) < index(pair[1])), "snapshot order is kept: {shown:?}");
    }

    fn index(id: &str) -> usize {
        id.trim_start_matches('w').parse().unwrap()
    }

    #[test]
    fn paper_piles_step_with_dirty_files() {
        let bucket = |files| papers_bucket(Some(Dirty { files, conflicts: 0 }));
        assert_eq!([papers_bucket(None), bucket(0), bucket(5), bucket(6), bucket(20), bucket(21)], [0, 0, 1, 2, 2, 3]);
    }
}
