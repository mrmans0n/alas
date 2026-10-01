//! Ticket model: the index, ticket bodies, session following and migration from cards.
//! Pure reducers, no SDK calls.

use crate::board::{Board, Column};
use serde::{Deserialize, Serialize};

pub const MAX_TITLE_CHARS: usize = 200;
pub const MAX_DESCRIPTION_CHARS: usize = 8_000;
pub const MAX_LABELS: usize = 8;
pub const MAX_LABEL_CHARS: usize = 32;
pub const MAX_COMMENTS: usize = 50;
pub const MAX_COMMENT_CHARS: usize = 4_000;
/// Provisional; Task 6 sets it from the fuel probe.
pub const MAX_INDEX: usize = 200;
/// Provisional; closed tickets kept in the index.
pub const ARCHIVE_KEEP: usize = 50;
pub const FORMAT_VERSION: u32 = 1;

#[derive(Serialize, Deserialize, Clone, Copy, PartialEq, Eq, Debug)]
#[serde(rename_all = "snake_case")]
pub enum Status {
    Backlog,
    Todo,
    InProgress,
    InReview,
    Done,
    Cancelled,
}

impl Status {
    pub const ALL: [Status; 6] = [
        Status::Backlog,
        Status::Todo,
        Status::InProgress,
        Status::InReview,
        Status::Done,
        Status::Cancelled,
    ];

    pub fn title(self) -> &'static str {
        match self {
            Status::Backlog => "Backlog",
            Status::Todo => "Todo",
            Status::InProgress => "In progress",
            Status::InReview => "In review",
            Status::Done => "Done",
            Status::Cancelled => "Cancelled",
        }
    }

    pub fn key(self) -> &'static str {
        match self {
            Status::Backlog => "backlog",
            Status::Todo => "todo",
            Status::InProgress => "in_progress",
            Status::InReview => "in_review",
            Status::Done => "done",
            Status::Cancelled => "cancelled",
        }
    }

    pub fn from_key(key: &str) -> Option<Status> {
        Status::ALL.into_iter().find(|s| s.key() == key)
    }

    fn closed(self) -> bool {
        matches!(self, Status::Done | Status::Cancelled)
    }
}

#[derive(Serialize, Deserialize, Clone, Copy, PartialEq, Eq, Debug, Default)]
#[serde(rename_all = "snake_case")]
pub enum Priority {
    #[default]
    None,
    Low,
    Medium,
    High,
    Urgent,
}

/// One index record. Empty fields are not written: the index is saved after every change.
#[derive(Serialize, Deserialize, Clone, PartialEq, Debug)]
pub struct Entry {
    pub number: u64,
    pub title: String,
    pub status: Status,
    #[serde(default)]
    pub priority: Priority,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub assignee: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub branch: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent_state: Option<String>,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub following: bool,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub seen: bool,
    /// The last message was already fetched for this session's current idle.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub fetched: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

#[derive(Serialize, Deserialize, Clone, Copy, PartialEq, Eq, Debug)]
#[serde(rename_all = "snake_case")]
pub enum Author {
    You,
    Agent,
}

#[derive(Serialize, Deserialize, Clone, PartialEq, Debug)]
pub struct Comment {
    pub author: Author,
    pub text: String,
}

#[derive(Serialize, Deserialize, Clone, PartialEq, Debug, Default)]
pub struct Body {
    #[serde(default)]
    pub description: String,
    #[serde(default)]
    pub labels: Vec<String>,
    #[serde(default)]
    pub comments: Vec<Comment>,
}

impl Body {
    /// Trims and clips the text; past the cap the oldest comments go. Empty text is ignored.
    pub fn comment(&mut self, author: Author, text: &str) {
        let text = text.trim();
        if text.is_empty() {
            return;
        }
        let text = match text.char_indices().nth(MAX_COMMENT_CHARS) {
            Some((cut, _)) => &text[..cut],
            None => text,
        };
        self.comments.push(Comment { author, text: text.into() });
        if self.comments.len() > MAX_COMMENTS {
            let excess = self.comments.len() - MAX_COMMENTS;
            self.comments.drain(..excess);
        }
    }
}

#[derive(Serialize, Deserialize, Clone, PartialEq, Debug, Default)]
#[serde(default)]
pub struct Meta {
    pub version: u32,
    pub next_number: u64,
}

#[derive(Default)]
pub struct Tracker {
    pub meta: Meta,
    /// Open tickets in creation order; a ticket moves to the end when it is closed, so closed
    /// tickets are in closing order and `archive` drops the oldest-closed. Not number order:
    /// callers that display by number must sort by number.
    pub index: Vec<Entry>,
}

impl Tracker {
    /// Returns the new ticket number, or `None` for an empty title or a full index.
    pub fn create(&mut self, title: &str, priority: Priority, assignee: Option<String>) -> Option<u64> {
        let title = title.trim();
        if title.is_empty() || self.index.len() >= MAX_INDEX {
            return None;
        }
        // A stale stored next_number must not reuse a number still in the index.
        let number = self.meta.next_number.max(self.index.iter().map(|e| e.number + 1).max().unwrap_or(1)).max(1);
        self.meta.next_number = number + 1;
        self.index.push(Entry {
            number,
            title: title.chars().take(MAX_TITLE_CHARS).collect(),
            status: Status::Backlog,
            priority,
            assignee,
            session_id: None,
            branch: None,
            agent_state: None,
            following: false,
            seen: false,
            fetched: false,
            error: None,
        });
        Some(number)
    }

    pub fn entry(&self, number: u64) -> Option<&Entry> {
        self.index.iter().find(|e| e.number == number)
    }

    pub fn entry_mut(&mut self, number: u64) -> Option<&mut Entry> {
        self.index.iter_mut().find(|e| e.number == number)
    }

    /// Done and Cancelled stop following; any other status follows while there is a session.
    /// Closing an open ticket moves it to the end of the index (see `index`).
    pub fn set_status(&mut self, number: u64, status: Status) {
        let Some(i) = self.index.iter().position(|e| e.number == number) else { return };
        let e = &mut self.index[i];
        let closing = status.closed() && !e.status.closed();
        e.status = status;
        e.following = !status.closed() && e.session_id.is_some();
        if closing {
            let e = self.index.remove(i);
            self.index.push(e);
        }
    }

    pub fn delete(&mut self, number: u64) {
        self.index.retain(|e| e.number != number);
    }

    pub fn started(&mut self, number: u64, session_id: String, branch: String) {
        if let Some(e) = self.entry_mut(number) {
            e.status = Status::InProgress;
            e.session_id = Some(session_id);
            e.branch = Some(branch);
            e.following = true;
            e.seen = false;
            e.fetched = false;
            e.agent_state = None;
            e.error = None;
        }
    }

    /// The host refused a Start, so no new session exists: the ticket keeps any session it had
    /// and only shows the reason.
    pub fn start_failed(&mut self, number: u64, reason: &str) {
        if let Some(e) = self.entry_mut(number) {
            e.error = Some(reason.into());
        }
    }

    /// An accepted start failed in the background: its session never came up.
    pub fn task_failed(&mut self, session_id: &str, reason: &str) {
        if let Some(e) = self.index.iter_mut().find(|e| e.session_id.as_deref() == Some(session_id)) {
            e.status = Status::Todo;
            e.error = Some(reason.into());
            e.session_id = None;
            e.following = false;
            e.seen = false;
            e.fetched = false;
            e.agent_state = None;
        }
    }

    /// `sessions` is (session id, state, worktree branch) from the snapshot. Returns whether any
    /// entry changed and the (number, session id) pairs whose last message should be fetched.
    /// A following ticket moves only when its session's state changes, so a manual status change
    /// holds until the agent does something new. A session not seen yet leaves the ticket alone.
    pub fn sync(&mut self, sessions: &[(String, String, String)]) -> (bool, Vec<(u64, String)>) {
        let mut changed = false;
        let mut fetch = Vec::new();
        for e in self.index.iter_mut() {
            let Some(sid) = e.session_id.as_deref() else { continue };
            let session = sessions.iter().find(|(id, _, _)| id == sid);
            // task/start answers with the requested branch; the worktree may have a suffixed one.
            if let Some((_, _, branch)) = session {
                if e.branch.as_deref() != Some(branch.as_str()) {
                    e.branch = Some(branch.clone());
                    changed = true;
                }
            }
            if !e.following {
                continue;
            }
            let state = session.map(|(_, s, _)| s.as_str());
            if (state.is_none() && !e.seen) || (e.seen && e.agent_state.as_deref() == state) {
                continue;
            }
            e.status = match state {
                Some("running" | "awaiting_input" | "permission_request") => Status::InProgress,
                Some("idle") | None => Status::InReview,
                Some(_) => e.status,
            };
            match state {
                Some("running") => e.fetched = false,
                Some("idle") if !e.fetched => {
                    e.fetched = true;
                    fetch.push((e.number, sid.to_owned()));
                }
                _ => {}
            }
            e.seen = true;
            e.agent_state = state.map(str::to_owned);
            changed = true;
        }
        (changed, fetch)
    }

    /// Drops the oldest Done and Cancelled tickets past `ARCHIVE_KEEP` from the index and
    /// returns their numbers. Their bodies stay stored.
    pub fn archive(&mut self) -> Vec<u64> {
        let closed = self.index.iter().filter(|e| e.status.closed()).count();
        let mut excess = closed.saturating_sub(ARCHIVE_KEEP);
        let mut dropped = Vec::with_capacity(excess);
        if excess > 0 {
            self.index.retain(|e| {
                if excess > 0 && e.status.closed() {
                    excess -= 1;
                    dropped.push(e.number);
                    return false;
                }
                true
            });
        }
        dropped
    }

    pub fn in_status(&self, status: Status) -> impl Iterator<Item = &Entry> {
        self.index.iter().filter(move |e| e.status == status)
    }

    /// Each card becomes a ticket numbered in card order, its prompt the description. Idle
    /// sessions count as fetched, so nothing is fetched retroactively. Empty bodies are omitted.
    pub fn migrate(board: &Board) -> (Tracker, Vec<(u64, Body)>) {
        let mut index = Vec::with_capacity(board.cards.len());
        let mut bodies = Vec::new();
        for (number, c) in (1..).zip(&board.cards) {
            index.push(Entry {
                number,
                title: c.title.clone(),
                status: match c.column {
                    Column::Backlog => Status::Backlog,
                    Column::Running | Column::NeedsYou => Status::InProgress,
                    Column::Review => Status::InReview,
                    Column::Done => Status::Done,
                },
                priority: Priority::None,
                assignee: None,
                session_id: c.session_id.clone(),
                branch: c.branch.clone(),
                agent_state: c.agent_state.clone(),
                following: c.following,
                seen: c.seen,
                fetched: c.agent_state.as_deref() == Some("idle"),
                error: c.error.clone(),
            });
            if !c.prompt.is_empty() {
                bodies.push((number, Body { description: c.prompt.clone(), ..Body::default() }));
            }
        }
        let meta = Meta { version: FORMAT_VERSION, next_number: index.len() as u64 + 1 };
        (Tracker { meta, index }, bodies)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::board::Card;

    fn started() -> Tracker {
        let mut t = Tracker::default();
        let n = t.create("t", Priority::None, None).unwrap();
        t.started(n, "s1".into(), "br".into());
        t
    }

    fn sess(state: &str) -> Vec<(String, String, String)> {
        vec![("s1".into(), state.into(), "br".into())]
    }

    #[test]
    fn numbers_are_never_reused() {
        let mut t = Tracker::default();
        assert_eq!(t.create("a", Priority::None, None), Some(1));
        assert_eq!(t.create("b", Priority::High, Some("claude".into())), Some(2));
        t.delete(2);
        assert_eq!(t.create("c", Priority::None, None), Some(3));
        assert_eq!(t.create("  ", Priority::None, None), None);
        while t.index.len() < MAX_INDEX {
            t.create("x", Priority::None, None).unwrap();
        }
        assert_eq!(t.create("full", Priority::None, None), None);
    }

    #[test]
    fn session_states_move_following_tickets() {
        for (state, want) in [
            ("running", Status::InProgress),
            ("awaiting_input", Status::InProgress),
            ("permission_request", Status::InProgress),
            ("idle", Status::InReview),
        ] {
            let mut t = started();
            t.set_status(1, Status::Todo);
            assert!(t.sync(&sess(state)).0, "{state}");
            assert_eq!(t.index[0].status, want, "{state}");
            assert_eq!(t.index[0].agent_state.as_deref(), Some(state));
        }

        let mut t = started();
        t.set_status(1, Status::Todo);
        t.sync(&sess("unknown"));
        assert_eq!(t.index[0].status, Status::Todo);
        assert!(t.index[0].seen);

        // Absent: unchanged until seen, then In review.
        let mut t = started();
        assert!(!t.sync(&[]).0);
        assert_eq!(t.index[0].status, Status::InProgress);
        t.sync(&sess("running"));
        t.sync(&[]);
        assert_eq!(t.index[0].status, Status::InReview);

        // A manual status holds until the state changes.
        let mut t = started();
        t.sync(&sess("running"));
        t.set_status(1, Status::InReview);
        assert!(!t.sync(&sess("running")).0);
        assert_eq!(t.index[0].status, Status::InReview);
        assert!(t.sync(&sess("awaiting_input")).0);
        assert_eq!(t.index[0].status, Status::InProgress);

        // Closed tickets never move, but still take the real branch.
        for closed in [Status::Done, Status::Cancelled] {
            let mut t = started();
            t.set_status(1, closed);
            assert!(!t.sync(&sess("idle")).0, "{closed:?}");
            assert_eq!(t.index[0].status, closed, "{closed:?}");
            assert!(t.sync(&[("s1".into(), "idle".into(), "br-2".into())]).0, "{closed:?}");
            assert_eq!(t.index[0].branch.as_deref(), Some("br-2"), "{closed:?}");
        }
    }

    #[test]
    fn idle_fetches_the_last_message_once() {
        let mut t = started();
        t.sync(&sess("running"));
        assert_eq!(t.sync(&sess("idle")).1, vec![(1, "s1".to_owned())]);
        assert!(t.sync(&sess("idle")).1.is_empty());
        t.sync(&sess("running"));
        assert_eq!(t.sync(&sess("idle")).1.len(), 1);
    }

    #[test]
    fn a_rejected_start_keeps_the_session_and_a_failed_task_clears_it() {
        let mut t = started();
        t.sync(&sess("idle"));
        t.set_status(1, Status::Todo);
        t.start_failed(1, "a task is already starting");
        let e = &t.index[0];
        assert_eq!((e.status, e.error.as_deref()), (Status::Todo, Some("a task is already starting")));
        assert_eq!((e.session_id.as_deref(), e.branch.as_deref()), (Some("s1"), Some("br")));

        t.started(1, "s2".into(), "br-2".into());
        assert_eq!(t.index[0].error, None);
        t.task_failed("s2", "later");
        let e = &t.index[0];
        assert_eq!((e.status, e.error.as_deref(), e.session_id.as_deref()), (Status::Todo, Some("later"), None));
        assert!(!e.following);
    }

    #[test]
    fn comments_are_capped_and_clipped() {
        let mut b = Body::default();
        b.comment(Author::You, "  \n ");
        assert!(b.comments.is_empty());
        for i in 0..=MAX_COMMENTS {
            b.comment(Author::You, &format!("c{i}"));
        }
        assert_eq!(b.comments.len(), MAX_COMMENTS);
        assert_eq!(b.comments[0].text, "c1");
        b.comment(Author::Agent, &"é".repeat(MAX_COMMENT_CHARS + 1));
        assert_eq!(b.comments.last().unwrap().text.chars().count(), MAX_COMMENT_CHARS);
    }

    #[test]
    fn migration_maps_columns_and_keeps_sessions() {
        let card = |id, column, prompt: &str, state: Option<&str>| Card {
            id,
            title: format!("t{id}"),
            prompt: prompt.into(),
            column,
            session_id: state.map(|_| format!("s{id}")),
            branch: state.map(|_| "br".into()),
            error: None,
            following: state.is_some(),
            seen: state.is_some(),
            agent_state: state.map(str::to_owned),
        };
        let board = Board {
            cards: vec![
                card(7, Column::Backlog, "do it\nmore", None),
                card(3, Column::Running, "", Some("running")),
                card(9, Column::NeedsYou, "p", Some("awaiting_input")),
                card(4, Column::Review, "p", Some("idle")),
                card(5, Column::Done, "p", None),
            ],
            next_id: 9,
        };
        let (t, bodies) = Tracker::migrate(&board);
        let got: Vec<_> = t.index.iter().map(|e| (e.number, e.title.as_str(), e.status)).collect();
        assert_eq!(
            got,
            [
                (1, "t7", Status::Backlog),
                (2, "t3", Status::InProgress),
                (3, "t9", Status::InProgress),
                (4, "t4", Status::InReview),
                (5, "t5", Status::Done),
            ]
        );
        assert_eq!((t.meta.version, t.meta.next_number), (FORMAT_VERSION, 6));
        assert_eq!(bodies[0], (1, Body { description: "do it\nmore".into(), ..Body::default() }));
        assert!(bodies.iter().all(|(n, _)| *n != 2), "an empty prompt has no body");
        let review = &t.index[3];
        assert_eq!((review.session_id.as_deref(), review.branch.as_deref()), (Some("s4"), Some("br")));
        assert!(review.following && review.seen && review.fetched);
        assert!(!t.index[1].fetched);
    }

    #[test]
    fn archive_keeps_the_newest_closed_tickets() {
        let mut t = Tracker::default();
        t.create("open", Priority::None, None);
        for i in 0..ARCHIVE_KEEP + 2 {
            let n = t.create("closed", Priority::None, None).unwrap();
            t.set_status(n, if i % 2 == 0 { Status::Done } else { Status::Cancelled });
        }
        assert_eq!(t.archive(), vec![2, 3]);
        assert_eq!(t.index.len(), ARCHIVE_KEEP + 1);
        assert!(t.archive().is_empty());
        // Closing the old open ticket keeps it; the oldest-closed goes instead.
        t.set_status(1, Status::Done);
        assert_eq!(t.archive(), vec![4]);
        assert!(t.entry(1).is_some());
    }
}
