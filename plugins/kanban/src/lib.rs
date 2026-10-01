//! Kanban: a board of task cards that start agents in new worktrees and follow them.

pub mod board;
pub mod tickets;
pub mod view;

use alas_plugin::{export_plugin, log, render, request, request_snapshot, storage_get, storage_set, task_start, Event, Plugin, Snapshot};
use board::{Board, Column};
use serde_json::json;

const BOARD_FULL: &str = "The board is full: delete or finish some cards first.";

#[derive(Default)]
pub struct Kanban {
    board: Board,
    form: u64,
    /// task/start request id → card id.
    pending: Vec<(i64, u64)>,
    loaded: bool,
    load_request: i64,
    /// The latest (session id, state) list, kept so a snapshot that beats the stored board still applies.
    /// `None` until the first snapshot, so a board loaded first is not synced against no sessions.
    sessions: Option<Vec<(String, String, String)>>,
    /// The stored board could not be read, so it is never overwritten.
    load_failed: bool,
    /// storage/set request ids awaiting a reply.
    saves: Vec<i64>,
    /// A danger line at the top of the board, e.g. a failed save.
    notice: Option<String>,
}

impl Kanban {
    fn changed(&mut self) {
        if !self.loaded {
            return;
        }
        if !self.load_failed {
            self.saves.push(storage_set("board", &self.board));
        }
        self.render();
    }

    fn render(&self) {
        render(0, &view::render(&self.board, self.form, self.notice.as_deref()));
    }

    fn starting(&self, card: u64) -> bool {
        self.pending.iter().any(|&(_, p)| p == card)
    }

    /// Syncs the board with the latest sessions; returns whether any card changed.
    fn sync(&mut self) -> bool {
        self.sessions.as_deref().is_some_and(|sessions| self.board.sync(sessions))
    }

    fn apply(&mut self, snapshot: Snapshot) {
        self.sessions = Some(
            snapshot
                .worktrees
                .into_iter()
                .flat_map(|w| {
                    let branch = w.branch;
                    w.sessions.into_iter().map(move |s| (s.id, s.state, branch.clone()))
                })
                .collect(),
        );
        // Most snapshots move nothing; saving and re-rendering the whole board for them is wasted fuel.
        if self.sync() {
            self.changed();
        }
    }

    fn view_event(&mut self, id: &str, kind: &str, value: Option<String>) {
        let card_id = |prefix: &str| id.strip_prefix(prefix).and_then(|n| n.parse::<u64>().ok());
        if id.starts_with("new-prompt-") && kind == "submit" {
            // The cap keeps one pasted card from filling the plugin's 1 MiB of storage.
            let prompt: String = value.unwrap_or_default().chars().take(8000).collect();
            // The card's title is the prompt's first line.
            if self.board.add("", &prompt) == 0 {
                // Empty input adds nothing; otherwise the board is full. The form keeps its text.
                if !prompt.trim().is_empty() && !self.load_failed {
                    self.notice = Some(BOARD_FULL.into());
                    self.render();
                }
                return;
            }
            if self.notice.as_deref() == Some(BOARD_FULL) {
                self.notice = None;
            }
            self.form += 1;
        } else if let Some(card) = card_id("start-") {
            let Some(c) = self.board.cards.iter().find(|c| c.id == card) else { return };
            if self.starting(card) {
                return;
            }
            let request = task_start(&c.title, &c.prompt);
            self.pending.push((request, card));
            return;
        } else if let Some(card) = card_id("delete-") {
            if self.starting(card) {
                return;
            }
            self.board.delete(card);
        } else if let Some(card) = card_id("move-") {
            let Some(column) = value.as_deref().and_then(Column::from_key) else { return };
            if self.starting(card) {
                return;
            }
            self.board.move_to(card, column);
        } else if let Some(card) = card_id("card-") {
            if let Some(session) = self.board.cards.iter().find(|c| c.id == card).and_then(|c| c.session_id.clone()) {
                request("session/focus", json!({"id": session}));
            }
            return;
        } else {
            return;
        }
        self.changed();
    }
}

impl Plugin for Kanban {
    fn handle(&mut self, event: Event) {
        match event {
            Event::Activate { .. } => {
                self.load_request = storage_get("board");
                request_snapshot();
            }
            Event::Stored { id, value } if id == self.load_request && !self.loaded => {
                // A missing board starts empty. One that cannot be read also starts empty,
                // but is never overwritten, so the stored copy survives.
                let loaded = match value {
                    Ok(None) => Ok(Board::default()),
                    Ok(Some(text)) => serde_json::from_str(&text).map_err(|e| e.to_string()),
                    Err(e) => Err(e.message),
                };
                match loaded {
                    Ok(board) => self.board = board,
                    Err(reason) => {
                        self.load_failed = true;
                        self.notice = Some(format!("Could not load the board, so changes are not saved: {reason}"));
                    }
                }
                self.loaded = true;
                // The stored board needs saving only when the sync changed it.
                if self.sync() {
                    self.changed();
                } else {
                    self.render();
                }
            }
            Event::Snapshot(snapshot) | Event::WorkspaceChanged(snapshot) => self.apply(snapshot),
            Event::ViewEvent { id, kind, value, .. } => self.view_event(&id, &kind, value),
            Event::Reply { id, result } if self.saves.contains(&id) => {
                self.saves.retain(|&s| s != id);
                let notice = result.err().map(|e| format!("Could not save the board: {}", e.message));
                if notice != self.notice {
                    self.notice = notice;
                    self.render();
                }
            }
            Event::Reply { id, result } if self.pending.iter().any(|&(r, _)| r == id) => {
                let Some(index) = self.pending.iter().position(|&(r, _)| r == id) else { return };
                let (_, card) = self.pending.remove(index);
                match result {
                    Ok(r) => self.board.started(
                        card,
                        r["sessionId"].as_str().unwrap_or_default().into(),
                        r["branch"].as_str().unwrap_or_default().into(),
                    ),
                    Err(e) => self.board.start_failed(card, &e.message),
                }
                self.changed();
            }
            Event::TaskFailed { session_id, reason } => {
                self.board.task_failed(&session_id, &reason);
                self.changed();
            }
            Event::Reply { result: Err(e), .. } => log("warn", &format!("request failed: {} {}", e.code, e.message)),
            _ => {}
        }
    }
}

export_plugin!(Kanban);

#[cfg(test)]
mod tests {
    use super::*;
    use alas_plugin::{dispatch, test_host};
    use serde_json::Value;

    fn feed(k: &mut Kanban, message: Value) {
        dispatch(k, message.to_string().as_bytes());
    }

    /// An activated plugin whose stored board holds Backlog card 1, with the sent log cleared.
    fn loaded_with_a_card() -> Kanban {
        test_host::take_sent();
        let mut k = Kanban::default();
        feed(&mut k, json!({"jsonrpc":"2.0","id":0,"method":"alas/activate","params":{"project":{"id":"p","name":"P"}}}));
        let load = k.load_request;
        feed(&mut k, json!({"jsonrpc":"2.0","id":load,"result":{"value":{"cards":[
            {"id":1,"title":"Fix it","prompt":"do","column":"Backlog"}],"next_id":1}}}));
        test_host::take_sent();
        k
    }

    /// Clicks Start on card 1 and returns the task/start request id.
    fn start(k: &mut Kanban) -> i64 {
        feed(k, json!({"jsonrpc":"2.0","method":"view/event","params":{"tab":0,"id":"start-1","kind":"click"}}));
        let sent = test_host::take_sent();
        let req = sent.iter().find(|m| m["method"] == "task/start").expect("a task/start request");
        assert_eq!(req["params"], json!({"title":"Fix it","prompt":"do"}));
        req["id"].as_i64().unwrap()
    }

    /// The column holding `card` in the last rendered tree, and that tree.
    fn rendered_column(card: &str) -> (String, Value) {
        let sent = test_host::take_sent();
        assert!(sent.iter().any(|m| m["method"] == "storage/set"), "every change is saved");
        column_in(&sent, card)
    }

    fn column_in(sent: &[Value], card: &str) -> (String, Value) {
        let root = sent.iter().rev().find(|m| m["method"] == "view/render").expect("a render")["params"]["root"].clone();
        let scroll = root["children"].as_array().unwrap().last().unwrap();
        for col in scroll["child"]["children"].as_array().unwrap() {
            let cards = col["children"].as_array().unwrap().last().unwrap()["child"]["children"].as_array().unwrap();
            if let Some(node) = cards.iter().find(|n| n["id"] == card) {
                return (col["id"].as_str().unwrap().to_string(), node.clone());
            }
        }
        panic!("{card} is not rendered")
    }

    #[test]
    fn starting_a_card_requests_a_task_and_a_reply_moves_it_to_running() {
        let mut k = loaded_with_a_card();
        let req = start(&mut k);
        feed(&mut k, json!({"jsonrpc":"2.0","id":req,"result":{"sessionId":"s","branch":"task/x"}}));
        let (col, card) = rendered_column("card-1");
        assert_eq!(col, "col-running");
        assert_eq!(card["clickable"], true);

        feed(&mut k, json!({"jsonrpc":"2.0","method":"view/event","params":{"tab":0,"id":"card-1","kind":"click"}}));
        let sent = test_host::take_sent();
        assert_eq!((sent[0]["method"].clone(), sent[0]["params"].clone()), (json!("session/focus"), json!({"id":"s"})));
    }

    #[test]
    fn a_failed_start_shows_the_reason_in_backlog() {
        let mut k = loaded_with_a_card();
        let req = start(&mut k);
        feed(&mut k, json!({"jsonrpc":"2.0","id":req,"error":{"code":-32003,"message":"a task is already starting"}}));
        let (col, card) = rendered_column("card-1");
        assert_eq!(col, "col-backlog");
        assert!(card.to_string().contains("Start failed: a task is already starting"));

        let req = start(&mut k);
        feed(&mut k, json!({"jsonrpc":"2.0","id":req,"result":{"sessionId":"s","branch":"task/x"}}));
        feed(&mut k, json!({"jsonrpc":"2.0","method":"task/failed","params":{"sessionId":"s","reason":"no worktree"}}));
        let (col, card) = rendered_column("card-1");
        assert_eq!(col, "col-backlog");
        assert!(card.to_string().contains("Start failed: no worktree"));
    }

    #[test]
    fn a_refused_card_shows_a_notice_keeps_the_typed_text_and_the_next_add_clears_it() {
        let mut k = loaded_with_a_card();
        while k.board.add("filler", "p") != 0 {}
        let submit = |k: &mut Kanban, field: &str, value: &str| {
            let id = format!("{field}-{}", k.form);
            feed(k, json!({"jsonrpc":"2.0","method":"view/event","params":{"tab":0,"id":id,"kind":"submit","value":value}}));
        };
        submit(&mut k, "new-prompt", "P");
        let sent = test_host::take_sent();
        assert!(!sent.iter().any(|m| m["method"] == "storage/set"));
        assert!(sent.last().unwrap()["params"]["root"].to_string().contains(BOARD_FULL));
        assert_eq!(k.form, 0, "the form keeps its text");

        k.board.delete(1);
        submit(&mut k, "new-prompt", "P");
        assert_eq!(k.notice, None);
        assert!(!test_host::take_sent().last().unwrap()["params"]["root"].to_string().contains(BOARD_FULL));
    }

    #[test]
    fn a_snapshot_takes_the_real_branch_and_one_that_changes_nothing_is_neither_saved_nor_rendered() {
        let mut k = loaded_with_a_card();
        let req = start(&mut k);
        feed(&mut k, json!({"jsonrpc":"2.0","id":req,"result":{"sessionId":"s","branch":"task/x"}}));
        let snapshot = |branch: &str| json!({"jsonrpc":"2.0","method":"workspace/changed","params":{"snapshot":{"worktrees":[
            {"id":"w","branch":branch,"current":false,"sessions":[{"id":"s","agent":"a","title":"T","state":"running"}]}]}}});
        feed(&mut k, snapshot("task/x"));
        assert_eq!(rendered_column("card-1").0, "col-running");
        // Only the branch differs: the host created a suffixed one because task/x was taken.
        feed(&mut k, snapshot("task/x-2"));
        assert_eq!(k.board.cards[0].branch.as_deref(), Some("task/x-2"));
        assert!(test_host::take_sent().iter().any(|m| m["method"] == "storage/set"));
        feed(&mut k, snapshot("task/x-2"));
        assert!(test_host::take_sent().is_empty());
    }

    #[test]
    fn a_board_loaded_before_the_first_snapshot_keeps_its_columns_and_is_not_resaved() {
        test_host::take_sent();
        let mut k = Kanban::default();
        feed(&mut k, json!({"jsonrpc":"2.0","id":0,"method":"alas/activate","params":{"project":{"id":"p","name":"P"}}}));
        let load = k.load_request;
        feed(&mut k, json!({"jsonrpc":"2.0","id":load,"result":{"value":{"cards":[
            {"id":1,"title":"Fix it","prompt":"do","column":"Running","session_id":"s","following":true,"seen":true}],"next_id":1}}}));
        let sent = test_host::take_sent();
        assert!(!sent.iter().any(|m| m["method"] == "storage/set"));
        assert_eq!(column_in(&sent, "card-1").0, "col-running");
    }

    #[test]
    fn a_snapshot_before_the_board_loads_is_applied_after_load_without_saving_an_empty_board() {
        test_host::take_sent();
        let mut k = Kanban::default();
        feed(&mut k, json!({"jsonrpc":"2.0","id":0,"method":"alas/activate","params":{"project":{"id":"p","name":"P"}}}));
        let snapshot = test_host::take_sent().iter().find(|m| m["method"] == "workspace/snapshot").unwrap()["id"].clone();
        feed(&mut k, json!({"jsonrpc":"2.0","id":snapshot,"result":{"snapshot":{"worktrees":[
            {"id":"w","branch":"task/x","current":false,"sessions":[{"id":"s","agent":"a","title":"T","state":"idle"}]}]}}}));
        assert!(test_host::take_sent().is_empty(), "nothing is saved or rendered before the board loads");

        let load = k.load_request;
        feed(&mut k, json!({"jsonrpc":"2.0","id":load,"result":{"value":{"cards":[
            {"id":1,"title":"Fix it","prompt":"do","column":"Running","session_id":"s","following":true}],"next_id":1}}}));
        let sent = test_host::take_sent();
        let saved = &sent.iter().find(|m| m["method"] == "storage/set").expect("the loaded board is saved")["params"]["value"];
        assert_eq!(saved["cards"][0]["column"], "Review");
    }
}
