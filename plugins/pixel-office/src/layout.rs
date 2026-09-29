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

pub fn max_pods() -> usize {
    ((MAX_H - TOP - BOTTOM_MARGIN) / ROW_H) as usize * PODS_PER_ROW
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
    let shown = snapshot.worktrees.len().min(max_pods());
    let rows = shown.div_ceil(PODS_PER_ROW) as i32;
    let pods = snapshot.worktrees[..shown]
        .iter()
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

    #[test]
    fn paper_piles_step_with_dirty_files() {
        let bucket = |files| papers_bucket(Some(Dirty { files, conflicts: 0 }));
        assert_eq!([papers_bucket(None), bucket(0), bucket(5), bucket(6), bucket(20), bucket(21)], [0, 0, 1, 2, 2, 3]);
    }
}
