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
    pub session_id: Option<String>,
    pub branch: Option<String>,
    pub error: Option<String>,
    pub following: bool,
    pub seen: bool,
    pub agent_state: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct Board {
    pub cards: Vec<Card>,
    pub next_id: u64,
}

impl Board {
    /// Returns the new card id, or 0 when both title and prompt are empty.
    pub fn add(&mut self, title: &str, prompt: &str) -> u64 {
        let (title, prompt) = (title.trim(), prompt.trim());
        let title = if title.is_empty() {
            prompt.lines().next().unwrap_or("").trim()
        } else {
            title
        };
        if title.is_empty() {
            return 0;
        }
        self.next_id += 1;
        self.cards.push(Card {
            id: self.next_id,
            title: title.into(),
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

    /// `sessions` is (session id, state) from the snapshot.
    pub fn sync(&mut self, sessions: &[(String, String)]) {
        for c in self.cards.iter_mut().filter(|c| c.following) {
            let Some(sid) = c.session_id.as_deref() else { continue };
            match sessions.iter().find(|(id, _)| id == sid) {
                Some((_, state)) => {
                    c.seen = true;
                    c.agent_state = Some(state.clone());
                    match state.as_str() {
                        "running" => c.column = Column::Running,
                        "awaiting_input" | "permission_request" => c.column = Column::NeedsYou,
                        "idle" => c.column = Column::Review,
                        _ => {}
                    }
                }
                None if c.seen => c.column = Column::Review,
                None => {}
            }
        }
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
    }

    #[test]
    fn the_board_round_trips_through_json() {
        let (b, _) = started_board();
        let back: Board = serde_json::from_str(&serde_json::to_string(&b).unwrap()).unwrap();
        assert_eq!(b, back);
        assert_eq!(Column::from_key("needs_you"), Some(Column::NeedsYou));
    }
}
