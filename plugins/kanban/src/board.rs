//! Kanban board model: pure reducers, no SDK calls.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum Column {
    Backlog,
    Running,
    NeedsYou,
    Review,
    Done,
}

impl Column {
    pub const ALL: [Column; 5] = [
        Column::Backlog,
        Column::Running,
        Column::NeedsYou,
        Column::Review,
        Column::Done,
    ];

    pub fn title(self) -> &'static str {
        match self {
            Column::Backlog => "Backlog",
            Column::Running => "Running",
            Column::NeedsYou => "Needs you",
            Column::Review => "Review",
            Column::Done => "Done",
        }
    }

    pub fn key(self) -> &'static str {
        match self {
            Column::Backlog => "backlog",
            Column::Running => "running",
            Column::NeedsYou => "needs_you",
            Column::Review => "review",
            Column::Done => "done",
        }
    }

    pub fn from_key(key: &str) -> Option<Column> {
        Column::ALL.into_iter().find(|c| c.key() == key)
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Card {
    pub id: u64,
    pub title: String,
    pub prompt: String,
    pub column: Column,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub branch: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub following: bool,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub seen: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent_state: Option<String>,
}

/// Alas gives each plugin call a fixed fuel budget, and a board costs fuel per card and
/// per byte of text on every load, save and render. Measured with a real plugin host, the
/// costliest call on a full board (a snapshot that moves a card: parse it, save, render)
/// stays near 11M fuel, under half the 25M default. Adding past a cap removes the oldest
/// Done cards; with none to remove, the card is not added.
pub const MAX_CARDS: usize = 50;
/// Title and prompt bytes across all cards.
pub const MAX_TEXT_BYTES: usize = 96_000;
/// The most text one card can add: a 200-char title and an 8,000-char prompt, 4 UTF-8 bytes each.
pub const MAX_CARD_TEXT_BYTES: usize = (200 + 8_000) * 4;

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Board {
    pub cards: Vec<Card>,
    pub next_id: u64,
}

impl Board {
    /// Returns the new card id, or 0 when both title and prompt are empty or the board is
    /// full of cards that are not Done.
    pub fn add(&mut self, title: &str, prompt: &str) -> u64 {
        let (title, prompt) = (title.trim(), prompt.trim());
        let title = if title.is_empty() {
            prompt.lines().next().unwrap_or("").trim()
        } else {
            title
        };
        // A title is one line; a long first line of the prompt is cut.
        let title: String = title.chars().take(200).collect();
        if title.is_empty() {
            return 0;
        }
        let bytes = title.len() + prompt.len();
        if !self.has_room(bytes) {
            return 0;
        }
        while !self.fits(bytes, |_| true) {
            let Some(oldest_done) = self.cards.iter().position(|c| c.column == Column::Done) else { return 0 };
            self.cards.remove(oldest_done);
        }
        // A stale stored next_id must not reuse an existing id.
        self.next_id = self.next_id.max(self.cards.iter().map(|c| c.id).max().unwrap_or(0)) + 1;
        self.cards.push(Card {
            id: self.next_id,
            title,
            prompt: prompt.into(),
            column: Column::Backlog,
            session_id: None,
            branch: None,
            error: None,
            following: false,
            seen: false,
            agent_state: None,
        });
        self.next_id
    }

    /// Whether a card with `text_bytes` of text fits beside the cards that `keep`.
    fn fits(&self, text_bytes: usize, keep: impl Fn(&Card) -> bool) -> bool {
        let kept = self.cards.iter().filter(|c| keep(c));
        let (count, used) = kept.fold((0, 0), |(n, b), c| (n + 1, b + c.title.len() + c.prompt.len()));
        count < MAX_CARDS && used + text_bytes <= MAX_TEXT_BYTES
    }

    /// Whether `add` would take a card with `text_bytes` of text, removing Done cards if needed.
    pub fn has_room(&self, text_bytes: usize) -> bool {
        self.fits(text_bytes, |c| c.column != Column::Done)
    }

    /// Whether the next card, at its largest, might not fit without removing Done cards.
    pub fn nearly_full(&self) -> bool {
        !self.fits(MAX_CARD_TEXT_BYTES, |_| true)
    }

    pub fn delete(&mut self, id: u64) {
        self.cards.retain(|c| c.id != id);
    }

    fn card_mut(&mut self, id: u64) -> Option<&mut Card> {
        self.cards.iter_mut().find(|c| c.id == id)
    }

    pub fn started(&mut self, id: u64, session_id: String, branch: String) {
        if let Some(c) = self.card_mut(id) {
            c.column = Column::Running;
            c.session_id = Some(session_id);
            c.branch = Some(branch);
            c.following = true;
            c.seen = false;
            c.error = None;
            c.agent_state = None;
        }
    }

    pub fn start_failed(&mut self, id: u64, reason: &str) {
        if let Some(c) = self.card_mut(id) {
            c.column = Column::Backlog;
            c.error = Some(reason.into());
            c.session_id = None;
            c.following = false;
            c.seen = false;
            c.agent_state = None;
        }
    }

    pub fn task_failed(&mut self, session_id: &str, reason: &str) {
        if let Some(id) = self
            .cards
            .iter()
            .find(|c| c.session_id.as_deref() == Some(session_id))
            .map(|c| c.id)
        {
            self.start_failed(id, reason);
        }
    }

    pub fn move_to(&mut self, id: u64, column: Column) {
        if let Some(c) = self.card_mut(id) {
            c.column = column;
            c.following = !matches!(column, Column::Done | Column::Backlog) && c.session_id.is_some();
        }
    }

    /// `sessions` is (session id, state) from the snapshot. Returns whether any card changed.
    /// A following card moves only when its session's state changes, so a manual move holds
    /// until the agent does something new. A session not seen yet leaves the card alone.
    pub fn sync(&mut self, sessions: &[(String, String)]) -> bool {
        let mut changed = false;
        for c in self.cards.iter_mut().filter(|c| c.following) {
            let Some(sid) = c.session_id.as_deref() else { continue };
            let state = sessions.iter().find(|(id, _)| id == sid).map(|(_, s)| s.as_str());
            if (state.is_none() && !c.seen) || (c.seen && c.agent_state.as_deref() == state) {
                continue;
            }
            c.column = match state {
                Some("running") => Column::Running,
                Some("awaiting_input" | "permission_request") => Column::NeedsYou,
                Some("idle") | None => Column::Review,
                Some(_) => c.column,
            };
            c.seen = true;
            c.agent_state = state.map(str::to_owned);
            changed = true;
        }
        changed
    }

    pub fn in_column(&self, column: Column) -> Vec<&Card> {
        self.cards.iter().filter(|c| c.column == column).collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn started_board() -> (Board, u64) {
        let mut b = Board::default();
        let id = b.add("t", "p");
        b.started(id, "s1".into(), "br".into());
        (b, id)
    }

    fn sess(state: &str) -> Vec<(String, String)> {
        vec![("s1".into(), state.into())]
    }

    #[test]
    fn session_states_move_following_cards() {
        for (state, want) in [
            ("running", Column::Running),
            ("awaiting_input", Column::NeedsYou),
            ("permission_request", Column::NeedsYou),
            ("idle", Column::Review),
        ] {
            let (mut b, id) = started_board();
            b.move_to(id, Column::Review);
            b.sync(&sess(state));
            assert_eq!(b.cards[0].column, want, "{state}");
            assert_eq!(b.cards[0].agent_state.as_deref(), Some(state));
        }
        let (mut b, _) = started_board();
        b.sync(&sess("unknown"));
        assert_eq!(b.cards[0].column, Column::Running);
        assert!(b.cards[0].seen);
    }

    #[test]
    fn a_started_card_waits_for_its_session_before_review() {
        let (mut b, _) = started_board();
        b.sync(&[]);
        assert_eq!(b.cards[0].column, Column::Running);
        b.sync(&sess("running"));
        b.sync(&[]);
        assert_eq!(b.cards[0].column, Column::Review);
    }

    #[test]
    fn a_manual_move_holds_until_the_session_state_changes() {
        let (mut b, id) = started_board();
        b.sync(&sess("idle"));
        b.move_to(id, Column::NeedsYou);
        assert!(!b.sync(&sess("idle")));
        assert_eq!(b.cards[0].column, Column::NeedsYou);
        assert!(b.sync(&sess("running")));
        assert_eq!(b.cards[0].column, Column::Running);
    }

    #[test]
    fn done_and_backlog_stop_following() {
        let (mut b, id) = started_board();
        b.move_to(id, Column::Done);
        b.sync(&sess("running"));
        assert_eq!(b.cards[0].column, Column::Done);
        b.move_to(id, Column::Review);
        assert!(b.cards[0].following);
        b.move_to(id, Column::Backlog);
        assert!(!b.cards[0].following);
    }

    #[test]
    fn a_failed_start_returns_to_backlog_with_the_reason() {
        let (mut b, id) = started_board();
        b.start_failed(id, "boom");
        assert_eq!(b.cards[0].column, Column::Backlog);
        assert_eq!(b.cards[0].error.as_deref(), Some("boom"));
        assert_eq!(b.cards[0].session_id, None);

        b.started(id, "s1".into(), "br".into());
        assert_eq!(b.cards[0].error, None);
        b.task_failed("s1", "later");
        assert_eq!(b.cards[0].column, Column::Backlog);
        assert_eq!(b.cards[0].error.as_deref(), Some("later"));
    }

    #[test]
    fn adding_uses_the_first_prompt_line_without_a_title_and_ignores_empty_cards() {
        let mut b = Board::default();
        let id = b.add("  ", "  fix it\nmore detail ");
        assert_eq!(b.cards[0].title, "fix it");
        assert_eq!(b.cards[0].prompt, "fix it\nmore detail");
        assert_eq!(b.add(" ", "\n "), 0);
        assert_eq!(b.cards.len(), 1);
        assert_eq!(b.in_column(Column::Backlog)[0].id, id);
        b.delete(id);
        assert_ne!(b.add("again", ""), id);
    }

    #[test]
    fn a_full_board_makes_room_by_removing_the_oldest_done_cards() {
        let mut b = Board::default();
        for i in 0..MAX_CARDS {
            b.add(&format!("c{i}"), "p");
        }
        let (first, second) = (b.cards[0].id, b.cards[1].id);
        b.move_to(second, Column::Done);
        b.move_to(first, Column::Done);
        assert!(b.nearly_full());
        let added = b.add("new", "p");
        assert_ne!(added, 0);
        assert_eq!(b.cards.len(), MAX_CARDS);
        assert!(b.cards.iter().all(|c| c.id != first), "the oldest Done card goes first");

        b.move_to(second, Column::Backlog);
        assert_eq!(b.add("more", "p"), 0, "only Done cards make room");
        assert_eq!(b.cards.len(), MAX_CARDS);
    }

    #[test]
    fn text_over_the_byte_cap_also_removes_done_cards() {
        let mut b = Board::default();
        let long = "x".repeat(MAX_CARD_TEXT_BYTES - 10);
        let done = b.add("done", &long);
        b.move_to(done, Column::Done);
        while !b.nearly_full() {
            b.add("big", &long);
        }
        let count = b.cards.len();
        assert_ne!(b.add("big", &long), 0);
        assert!(b.cards.iter().all(|c| c.id != done) && b.cards.len() == count);
        let small = b.add("small", "p");
        b.move_to(small, Column::Done);
        assert_eq!(b.add("big", &long), 0);
        assert!(b.cards.iter().any(|c| c.id == small), "a card that cannot fit removes nothing");
    }

    #[test]
    fn the_board_round_trips_through_json() {
        let (b, _) = started_board();
        let back: Board = serde_json::from_str(&serde_json::to_string(&b).unwrap()).unwrap();
        assert_eq!(b, back);
        assert_eq!(Column::from_key("needs_you"), Some(Column::NeedsYou));
    }

    #[test]
    fn stored_boards_load_tolerantly() {
        let b: Board = serde_json::from_str(
            r#"{"cards":[{"id":3,"title":"t","prompt":"p","column":"Review","extra":1}]}"#,
        )
        .unwrap();
        assert!(!b.cards[0].following && !b.cards[0].seen);
        assert!(serde_json::from_str::<Board>("not json{").is_err());
    }
}
