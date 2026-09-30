//! Kanban: a board of task cards that start agents in new worktrees and follow them.

pub mod board;
pub mod view;

use alas_plugin::{export_plugin, log, render, request, request_snapshot, storage_get, storage_set, task_start, Event, Plugin, Snapshot};
use board::{Board, Column};
use serde_json::json;

#[derive(Default)]
pub struct Kanban {
    board: Board,
    form: u64,
    draft_title: String,
    /// task/start request id → card id.
    pending: Vec<(i64, u64)>,
    loaded: bool,
    load_request: i64,
    /// The latest (session id, state) list, kept so a snapshot that beats the stored board still applies.
    sessions: Vec<(String, String)>,
}

impl Kanban {
    fn changed(&mut self) {
        if !self.loaded {
            return;
        }
        storage_set("board", &serde_json::to_value(&self.board).unwrap_or_default());
        render(0, &view::render(&self.board, self.form));
    }

    fn apply(&mut self, snapshot: Snapshot) {
        self.sessions = snapshot
            .worktrees
            .into_iter()
            .flat_map(|w| w.sessions)
            .map(|s| (s.id, s.state))
            .collect();
        self.board.sync(&self.sessions);
        self.changed();
    }

    fn view_event(&mut self, id: &str, kind: &str, value: Option<String>) {
        let card_id = |prefix: &str| id.strip_prefix(prefix).and_then(|n| n.parse::<u64>().ok());
        if id.starts_with("new-title-") && kind == "submit" {
            // Not a board change: nothing to save or render.
            self.draft_title = value.unwrap_or_default();
            return;
        }
        if id.starts_with("new-prompt-") && kind == "submit" {
            if self.board.add(&self.draft_title, &value.unwrap_or_default()) == 0 {
                return;
            }
            self.draft_title.clear();
            self.form += 1;
        } else if let Some(card) = card_id("start-") {
            let Some(c) = self.board.cards.iter().find(|c| c.id == card) else { return };
            if self.pending.iter().any(|&(_, p)| p == card) {
                return;
            }
            let request = task_start(&c.title, &c.prompt);
            self.pending.push((request, card));
            return;
        } else if let Some(card) = card_id("delete-") {
            self.board.delete(card);
        } else if let Some(card) = card_id("move-") {
            let Some(column) = value.as_deref().and_then(Column::from_key) else { return };
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
            Event::Reply { id, result } if id == self.load_request && !self.loaded => {
                // A missing, unreadable or invalid board starts empty.
                self.board = result
                    .ok()
                    .and_then(|r| serde_json::from_value(r["value"].clone()).ok())
                    .unwrap_or_default();
                self.loaded = true;
                self.board.sync(&self.sessions);
                self.changed();
            }
            Event::Snapshot(snapshot) | Event::WorkspaceChanged(snapshot) => self.apply(snapshot),
            Event::ViewEvent { id, kind, value, .. } => self.view_event(&id, &kind, value),
            Event::Reply { id, result } if self.pending.iter().any(|&(r, _)| r == id) => {
                let index = self.pending.iter().position(|&(r, _)| r == id).unwrap();
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
        let root = sent.iter().rev().find(|m| m["method"] == "view/render").expect("a render")["params"]["root"].clone();
        for col in root["children"][0]["child"]["children"].as_array().unwrap() {
            if let Some(node) = col["children"].as_array().unwrap().iter().find(|n| n["id"] == card) {
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
}
