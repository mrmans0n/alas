//! Kanban: a small ticket tracker whose tickets start agents in new worktrees and follow them.

pub mod board;
pub mod store;
pub mod tickets;
pub mod view;

use alas_plugin::{
    agent_list, export_plugin, last_message, log, parse_agents, parse_last_message, render, request, request_snapshot, storage_get,
    storage_set, task_start_with, Agent, Event, Plugin, RpcError, Snapshot,
};
use serde_json::{json, value::RawValue, Value};
use store::{body_key, Loaded};
use tickets::{Author, Body, Entry, Priority, Status, Tracker, FORMAT_VERSION, MAX_DESCRIPTION_CHARS, MAX_TITLE_CHARS};
use view::{Draft, Screen, ViewState};

const TRACKER_FULL: &str = "The tracker is full: delete some tickets first.";
const SAVE_FAILED: &str = "Could not save: ";
const DESCRIPTION_CUT: &str = "The description was cut to 4,000 characters.";

/// What to do with a ticket body once it is read.
enum Then {
    /// Show it on the ticket screen.
    Open,
    /// Append the agent's message and save it.
    Comment(String),
    /// Start the ticket with its description.
    Start,
}

#[derive(Default)]
pub struct Kanban {
    tracker: Tracker,
    screen: Screen,
    /// The open ticket's body, once read. Its description and comments are editable only then,
    /// so a body is never saved before it is known.
    open_body: Option<(u64, Body)>,
    agents: Vec<Agent>,
    draft: Draft,
    /// Generation of the New ticket and description field ids; bumping it resets those fields.
    form: u64,
    /// Generation of the comment field id, separate so posting keeps unsaved description text.
    comment_form: u64,
    notice: Option<String>,
    loaded: bool,
    /// The store could not be read, so it is never overwritten.
    load_failed: bool,
    /// storage/get ids for meta, index and the legacy board, and their replies as they arrive.
    load: [i64; 3],
    load_replies: [Option<Result<Option<String>, RpcError>>; 3],
    /// storage/get id, ticket, and what to do with the body.
    body_loads: Vec<(i64, u64, Then)>,
    /// task/start id → ticket.
    pending_starts: Vec<(i64, u64)>,
    /// session/last_message id → ticket.
    fetches: Vec<(i64, u64)>,
    agent_request: Option<i64>,
    /// The session/focus request of the last Open session click.
    focus_request: Option<i64>,
    /// storage/set ids awaiting a reply.
    saves: Vec<(i64, u64)>,
    /// The last save batch issued, and the latest one with a failed write. A failure notice
    /// clears only when a later batch completes with every write accepted.
    save_batch: u64,
    last_failed_batch: Option<u64>,
    /// Tickets whose stored body could not be decoded this session: read-only, never written.
    unreadable: Vec<u64>,
    /// The latest (session id, state, branch) list, kept so a snapshot that beats the load still applies.
    /// `None` until the first snapshot, so a tracker loaded first is not synced against no sessions.
    sessions: Option<Vec<(String, String, String)>>,
}

fn send_start(e: &Entry, description: &str) -> i64 {
    let n = e.number;
    let prompt = format!("KAN-{n}: {}\n\n{description}", e.title);
    task_start_with(&e.title, prompt.trim_end(), Some(&format!("task/kan-{n}")), e.assignee.as_deref())
}

impl Kanban {
    fn render(&self) {
        if !self.loaded {
            return;
        }
        let body = match (self.screen, &self.open_body) {
            (Screen::Ticket(n), Some((open, body))) if n == *open => Some(body),
            _ => None,
        };
        let loading_starts = self.body_loads.iter().filter(|(_, _, then)| matches!(then, Then::Start)).map(|&(_, n, _)| n);
        let starting: Vec<u64> = self.pending_starts.iter().map(|&(_, n)| n).chain(loading_starts).collect();
        render(
            0,
            &view::render(&ViewState {
                tracker: &self.tracker,
                screen: &self.screen,
                body,
                agents: &self.agents,
                draft: &self.draft,
                form: self.form,
                comment_form: self.comment_form,
                notice: self.notice.as_deref(),
                starting: &starting,
                body_unreadable: matches!(self.screen, Screen::Ticket(n) if self.unreadable.contains(&n)),
            }),
        );
    }

    /// A load failure's notice stays: it says nothing will be saved.
    fn set_notice(&mut self, notice: String) {
        if self.note(notice) {
            self.render();
        }
    }

    /// Sets the notice without rendering; returns whether it was set.
    fn note(&mut self, notice: String) -> bool {
        if !self.load_failed {
            self.notice = Some(notice);
        }
        !self.load_failed
    }

    /// Sends writes in order, unless the store could not be read.
    fn save(&mut self, writes: Vec<(String, Option<Box<RawValue>>)>) {
        if self.load_failed {
            return;
        }
        self.save_batch += 1;
        for (key, value) in writes {
            // ponytail: a linear scan; at most MAX_INDEX tickets ever fail to decode.
            if key.strip_prefix("ticket-").and_then(|n| n.parse().ok()).is_some_and(|n| self.unreadable.contains(&n)) {
                continue;
            }
            self.saves.push((storage_set(&key, &value), self.save_batch));
        }
    }

    /// Saves one change (the index, the open body, deleted bodies) and re-renders.
    fn commit(&mut self, index_changed: bool, open_body: bool, deleted: &[u64]) {
        if !self.loaded {
            return;
        }
        // Nobody can open an archived ticket, so its body goes with it.
        let archived = if index_changed { self.tracker.archive() } else { Vec::new() };
        if let Screen::Ticket(n) = self.screen {
            if self.tracker.entry(n).is_none() {
                self.screen = Screen::default();
                self.open_body = None;
            }
        }
        let deleted: Vec<u64> = deleted.iter().copied().chain(archived).collect();
        let body = self.open_body.as_ref().filter(|_| open_body).map(|(n, b)| (*n, b));
        let writes = store::writes(&self.tracker, body.as_slice(), &deleted, index_changed);
        self.save(writes);
        self.render();
    }

    /// Follows the latest sessions; saves and renders only when a ticket changed.
    fn sync(&mut self) -> bool {
        let Some(sessions) = &self.sessions else { return false };
        let (changed, fetch) = self.tracker.sync(sessions);
        for (n, session) in fetch {
            self.fetches.push((last_message(&session), n));
        }
        if changed {
            self.commit(true, false, &[]);
        }
        changed
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
        if self.loaded {
            self.sync();
        }
    }

    fn finish_load(&mut self) {
        let [meta, index, legacy] = std::mem::take(&mut self.load_replies).map(|r| r.expect("every reply is in"));
        let loaded = match (meta, index, legacy) {
            (Ok(meta), Ok(index), Ok(legacy)) => store::load(meta.as_deref(), index.as_deref(), legacy.as_deref()),
            (Err(e), _, _) | (_, Err(e), _) | (_, _, Err(e)) => Loaded::Unreadable(format!("The stored tickets could not be read ({}); nothing will be saved.", e.message)),
        };
        self.loaded = true;
        match loaded {
            Loaded::Fresh => self.tracker.meta.version = FORMAT_VERSION,
            Loaded::Tracker(tracker) => self.tracker = tracker,
            Loaded::Migrated(tracker, bodies) => {
                // The old board stays stored, so a downgrade loses nothing.
                self.tracker = tracker;
                let bodies: Vec<(u64, &Body)> = bodies.iter().map(|(n, b)| (*n, b)).collect();
                let writes = store::writes(&self.tracker, &bodies, &[], true);
                self.save(writes);
            }
            Loaded::Unreadable(reason) => {
                self.load_failed = true;
                self.notice = Some(reason);
            }
        }
        if !self.sync() {
            self.render();
        }
    }

    fn navigate(&mut self, screen: Screen) {
        self.screen = screen;
        self.open_body = None;
        // A failed load or save stays until it no longer holds; other notices go with the screen.
        if !self.load_failed && !self.notice.as_deref().is_some_and(|n| n.starts_with(SAVE_FAILED)) {
            self.notice = None;
        }
        self.render();
    }

    fn open(&mut self, n: u64) {
        if self.tracker.entry(n).is_none() {
            return;
        }
        self.body_loads.retain(|(_, _, then)| !matches!(then, Then::Open));
        // Agents may have been installed since the last screen.
        self.agent_request = Some(agent_list());
        if self.unreadable.contains(&n) {
            self.screen = Screen::Ticket(n);
            self.open_body = None;
            return self.unreadable_notice(n, "read earlier");
        }
        self.body_loads.push((storage_get(&body_key(n)), n, Then::Open));
        self.navigate(Screen::Ticket(n));
    }

    fn create(&mut self, description: &str) {
        let cut = description.trim().chars().nth(MAX_DESCRIPTION_CHARS).is_some();
        let description: String = description.trim().chars().take(MAX_DESCRIPTION_CHARS).collect();
        let title = if self.draft.title.is_empty() { description.lines().next().unwrap_or("") } else { self.draft.title.as_str() };
        if title.trim().is_empty() {
            return;
        }
        let Some(n) = self.tracker.create(title, self.draft.priority, self.draft.assignee.clone()) else {
            if !self.load_failed {
                self.set_notice(TRACKER_FULL.into());
            }
            return;
        };
        if self.notice.as_deref() == Some(TRACKER_FULL) {
            self.notice = None;
        }
        if cut {
            self.note(DESCRIPTION_CUT.into());
        }
        self.draft = Draft::default();
        self.form += 1;
        let body = Body { description, ..Body::default() };
        let bodies: &[(u64, &Body)] = if body.description.is_empty() { &[] } else { &[(n, &body)] };
        let writes = store::writes(&self.tracker, bodies, &[], true);
        self.save(writes);
        self.render();
    }

    fn unreadable_notice(&mut self, n: u64, problem: &str) {
        let problem: String = problem.chars().take(200).collect();
        self.set_notice(format!("KAN-{n}: this ticket's saved details could not be read; they are left untouched ({problem})."));
    }

    fn open_body_mut(&mut self, n: u64) -> Option<&mut Body> {
        self.open_body.as_mut().filter(|(open, _)| *open == n).map(|(_, b)| b)
    }

    fn starting(&self, n: u64) -> bool {
        self.pending_starts.iter().any(|&(_, p)| p == n) || self.body_loads.iter().any(|(_, p, then)| *p == n && matches!(then, Then::Start))
    }

    /// The prompt needs the description, so a body that is not open is read first.
    fn start(&mut self, n: u64) {
        if self.starting(n) {
            return;
        }
        if self.unreadable.contains(&n) {
            return self.set_notice(format!("Could not start KAN-{n}: its saved details could not be read."));
        }
        let Some(e) = self.tracker.entry(n).filter(|e| !e.status.closed()) else { return };
        match self.open_body.as_ref().filter(|(open, _)| *open == n) {
            Some((_, body)) => self.pending_starts.push((send_start(e, &body.description), n)),
            None => self.body_loads.push((storage_get(&body_key(n)), n, Then::Start)),
        }
        self.render();
    }

    /// Appends an agent's message to ticket `n`'s body: the open one, `loaded`, or one read first.
    fn agent_comment(&mut self, n: u64, text: String, loaded: Option<Body>) {
        if self.tracker.entry(n).is_none() {
            return;
        }
        if self.unreadable.contains(&n) {
            return self.set_notice(format!("KAN-{n}: the agent's reply was not saved because the ticket's saved details could not be read."));
        }
        if let Some(body) = self.open_body_mut(n) {
            body.comment(Author::Agent, &text);
            self.commit(false, true, &[]);
        } else if let Some(mut body) = loaded {
            body.comment(Author::Agent, &text);
            let writes = store::writes(&self.tracker, &[(n, &body)], &[], false);
            self.save(writes);
            // Reads sent before this write would miss the comment: read again.
            for load in self.body_loads.iter_mut().filter(|(_, p, then)| *p == n && matches!(then, Then::Open | Then::Comment(_))) {
                load.0 = storage_get(&body_key(n));
            }
        } else {
            self.body_loads.push((storage_get(&body_key(n)), n, Then::Comment(text)));
        }
    }

    fn body_loaded(&mut self, id: i64, value: Result<Option<String>, RpcError>) {
        let Some(i) = self.body_loads.iter().position(|(r, _, _)| *r == id) else { return };
        let (_, n, then) = self.body_loads.remove(i);
        let body = match value.map(|raw| store::parse_body(raw.as_deref())) {
            Ok(Ok(body)) => body,
            Ok(Err(problem)) => {
                if !self.unreadable.contains(&n) {
                    self.unreadable.push(n);
                }
                return match then {
                    Then::Open => self.unreadable_notice(n, &problem),
                    Then::Comment(text) => self.agent_comment(n, text, None),
                    Then::Start => self.start(n),
                };
            }
            // Nothing is written without the body, so a failed read loses nothing.
            Err(e) => return self.set_notice(format!("Could not read KAN-{n}: {}", e.message)),
        };
        match then {
            Then::Open => {
                if self.screen == Screen::Ticket(n) && self.open_body.is_none() {
                    self.open_body = Some((n, body));
                    self.render();
                }
            }
            Then::Comment(text) => self.agent_comment(n, text, Some(body)),
            Then::Start => {
                if let Some(e) = self.tracker.entry(n).filter(|e| !e.status.closed()) {
                    // The open body may hold a newer description than the one just read.
                    let open = self.open_body.as_ref().filter(|(open, _)| *open == n).map(|(_, b)| b);
                    let request = send_start(e, &open.unwrap_or(&body).description);
                    self.pending_starts.push((request, n));
                }
                self.render();
            }
        }
    }

    fn start_replied(&mut self, n: u64, result: Result<Value, RpcError>) {
        // A deleted or closed ticket is not resurrected; its agent keeps running.
        if !self.tracker.entry(n).is_some_and(|e| !e.status.closed()) {
            return self.render();
        }
        match result {
            Ok(r) => self.tracker.started(n, r["sessionId"].as_str().unwrap_or_default().into(), r["branch"].as_str().unwrap_or_default().into()),
            Err(e) => self.tracker.start_failed(n, &e.message),
        }
        self.commit(true, false, &[]);
    }

    fn fetched(&mut self, n: u64, result: Result<Value, RpcError>) {
        match result.map(|r| parse_last_message(&r)) {
            Ok(Some(text)) if !text.trim().is_empty() => self.agent_comment(n, text, None),
            Ok(_) => self.set_notice(format!("KAN-{n}: the agent finished without a message.")),
            Err(e) => self.set_notice(format!("Could not read the agent's last message for KAN-{n}: {}", e.message)),
        }
    }

    fn view_event(&mut self, id: &str, value: Option<String>) {
        if !self.loaded {
            return;
        }
        let value = value.unwrap_or_default();
        let number = |prefix: &str| id.strip_prefix(prefix).and_then(|n| n.parse::<u64>().ok());
        // Field ids end in the form generation: `<prefix><n>-<form>`.
        let field = |prefix: &str| id.strip_prefix(prefix).and_then(|r| r.split_once('-')).and_then(|(n, _)| n.parse::<u64>().ok());

        if id == "back" {
            self.navigate(Screen::default());
        } else if id == "show-cancelled" {
            if let Screen::Board { show_cancelled } = &mut self.screen {
                *show_cancelled = !*show_cancelled;
            }
            self.render();
        } else if id.starts_with("new-title-") {
            // Kept for Create; the field keeps showing what was typed.
            self.draft.title = value.trim().chars().take(MAX_TITLE_CHARS).collect();
        } else if id.starts_with("new-description-") {
            self.create(&value);
        } else if id.starts_with("new-priority-") {
            if let Some(p) = Priority::from_key(&value) {
                self.draft.priority = p;
                self.render();
            }
        } else if id.starts_with("new-assignee-") {
            self.draft.assignee = (value != view::UNASSIGNED).then_some(value);
            self.render();
        } else if let Some(n) = number("ticket-") {
            self.open(n);
        } else if let Some(n) = number("status-") {
            let Some(status) = Status::from_key(&value) else { return };
            self.tracker.set_status(n, status);
            self.commit(true, false, &[]);
        } else if let Some(n) = number("cancel-") {
            self.tracker.set_status(n, Status::Cancelled);
            self.commit(true, false, &[]);
        } else if let Some(n) = number("priority-") {
            let (Some(priority), Some(e)) = (Priority::from_key(&value), self.tracker.entry_mut(n)) else { return };
            e.priority = priority;
            self.commit(true, false, &[]);
        } else if let Some(n) = number("assign-") {
            let Some(e) = self.tracker.entry_mut(n) else { return };
            e.assignee = (value != view::UNASSIGNED).then_some(value);
            self.commit(true, false, &[]);
        } else if let Some(n) = number("start-") {
            self.start(n);
        } else if let Some(n) = number("open-") {
            if let Some(session) = self.tracker.entry(n).and_then(|e| e.session_id.as_deref()) {
                self.focus_request = Some(request("session/focus", json!({"id": session})));
            }
        } else if let Some(n) = number("delete-") {
            if self.tracker.entry(n).is_some() {
                self.tracker.delete(n);
                self.commit(true, false, &[n]);
            }
        } else if let Some(n) = field("description-") {
            // Before the body arrives there is nothing to edit, and saving would overwrite it.
            let Some(body) = self.open_body_mut(n) else { return };
            let description: String = value.trim().chars().take(MAX_DESCRIPTION_CHARS).collect();
            if body.description != description {
                body.description = description;
                if value.trim().chars().nth(MAX_DESCRIPTION_CHARS).is_some() {
                    self.note(DESCRIPTION_CUT.into());
                }
                self.commit(false, true, &[]);
            }
        } else if let Some(n) = field("comment-") {
            let Some(body) = self.open_body_mut(n) else { return };
            if value.trim().is_empty() {
                return;
            }
            body.comment(Author::You, &value);
            self.comment_form += 1;
            self.commit(false, true, &[]);
        }
    }
}

impl Plugin for Kanban {
    fn handle(&mut self, event: Event) {
        match event {
            Event::Activate { .. } => {
                // The legacy board is read every time: loading needs it whenever meta or index is absent.
                self.load = [storage_get(store::META), storage_get(store::INDEX), storage_get(store::LEGACY)];
                request_snapshot();
                self.agent_request = Some(agent_list());
            }
            Event::Stored { id, value } if !self.loaded && self.load.contains(&id) => {
                let i = self.load.iter().position(|&l| l == id).expect("contained");
                self.load_replies[i] = Some(value);
                if self.load_replies.iter().all(Option::is_some) {
                    self.finish_load();
                }
            }
            Event::Stored { id, value } => self.body_loaded(id, value),
            Event::Snapshot(snapshot) | Event::WorkspaceChanged(snapshot) => self.apply(snapshot),
            Event::ViewEvent { id, value, .. } => self.view_event(&id, value),
            Event::TaskFailed { session_id, reason } => {
                if self.tracker.task_failed(&session_id, &reason) {
                    self.commit(true, false, &[]);
                }
            }
            Event::Reply { id, result } if self.saves.iter().any(|&(r, _)| r == id) => {
                let i = self.saves.iter().position(|&(r, _)| r == id).expect("contained");
                let (_, batch) = self.saves.remove(i);
                if let Err(e) = result {
                    self.last_failed_batch = Some(batch);
                    return self.set_notice(format!("{SAVE_FAILED}{}", e.message));
                }
                // A batch's own later writes never clear its failure; a newer batch that fully
                // succeeded does.
                let batch_done = !self.saves.iter().any(|&(_, b)| b == batch);
                let after_failure = self.last_failed_batch.is_none_or(|f| batch > f);
                if batch_done && after_failure && self.notice.as_deref().is_some_and(|n| n.starts_with(SAVE_FAILED)) {
                    self.notice = None;
                    self.render();
                }
            }
            Event::Reply { id, result } if self.pending_starts.iter().any(|&(r, _)| r == id) => {
                let i = self.pending_starts.iter().position(|&(r, _)| r == id).expect("contained");
                let (_, n) = self.pending_starts.remove(i);
                self.start_replied(n, result);
            }
            Event::Reply { id, result } if self.fetches.iter().any(|&(r, _)| r == id) => {
                let i = self.fetches.iter().position(|&(r, _)| r == id).expect("contained");
                let (_, n) = self.fetches.remove(i);
                self.fetched(n, result);
            }
            Event::Reply { id, result } if self.focus_request == Some(id) => {
                self.focus_request = None;
                if result.is_err() {
                    self.set_notice("That session is not open any more.".into());
                }
            }
            Event::Reply { id, result } if self.agent_request == Some(id) => {
                self.agent_request = None;
                match result {
                    Ok(r) => {
                        let mut agents = parse_agents(&r);
                        // Duplicate menu item ids would stop the plugin.
                        let mut seen = std::collections::HashSet::new();
                        agents.retain(|a| seen.insert(a.id.clone()));
                        self.agents = agents;
                        self.render();
                    }
                    Err(e) => self.set_notice(format!("Could not list the agents: {}", e.message)),
                }
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

    fn feed(k: &mut Kanban, message: Value) {
        dispatch(k, message.to_string().as_bytes());
    }

    fn reply(k: &mut Kanban, id: i64, result: Value) {
        feed(k, json!({"jsonrpc":"2.0","id":id,"result":result}));
    }

    fn event(k: &mut Kanban, id: &str, value: Option<&str>) {
        feed(k, json!({"jsonrpc":"2.0","method":"view/event","params":{"tab":0,"id":id,"kind":"click","value":value}}));
    }

    fn snapshot(k: &mut Kanban, state: &str) {
        feed(k, json!({"jsonrpc":"2.0","method":"workspace/changed","params":{"snapshot":{"worktrees":[
            {"id":"w","branch":"task/kan-1","current":false,"sessions":[{"id":"s","agent":"a","title":"T","state":state}]}]}}}));
    }

    /// An activated plugin whose store held `meta`, `index` and the legacy `board` (`null` = unset).
    fn activate(meta: Value, index: Value, board: Value) -> Kanban {
        test_host::take_sent();
        let mut k = Kanban::default();
        feed(&mut k, json!({"jsonrpc":"2.0","id":0,"method":"alas/activate","params":{"project":{"id":"p","name":"P"}}}));
        let reads: Vec<_> = test_host::take_sent().into_iter().filter(|m| m["method"] == "storage/get").map(|m| m["params"]["key"].clone()).collect();
        assert_eq!(reads, ["meta", "index", "board"], "the legacy board is always read");
        for (id, value) in k.load.into_iter().zip([meta, index, board]) {
            reply(&mut k, id, json!({ "value": value }));
        }
        k
    }

    /// A loaded tracker holding ticket 1 ("Fix it", Todo, plus `fields`), with the sent log cleared.
    fn with_ticket(fields: Value) -> Kanban {
        let mut entry = json!({"number":1,"title":"Fix it","status":"todo"});
        entry.as_object_mut().unwrap().extend(fields.as_object().unwrap().clone());
        let k = activate(json!({"version":1,"next_number":2}), json!([entry]), Value::Null);
        test_host::take_sent();
        k
    }

    /// (key, value) of every storage/set in `sent`, in order.
    fn writes(sent: &[Value]) -> Vec<(String, Value)> {
        let sets = sent.iter().filter(|m| m["method"] == "storage/set");
        sets.map(|m| (m["params"]["key"].as_str().unwrap().to_owned(), m["params"]["value"].clone())).collect()
    }

    fn sent_one(sent: &[Value], method: &str) -> Value {
        let found: Vec<_> = sent.iter().filter(|m| m["method"] == method).collect();
        assert_eq!(found.len(), 1, "one {method} in {sent:?}");
        found[0].clone()
    }

    #[test]
    fn a_legacy_board_is_migrated_once_and_left_in_place() {
        let board = json!({"cards":[{"id":7,"title":"Fix it","prompt":"do","column":"Review","session_id":"s","following":true,"seen":true,"agent_state":"idle"}],"next_id":7});
        let mut k = activate(Value::Null, Value::Null, board.clone());
        let saved = writes(&test_host::take_sent());
        let keys: Vec<_> = saved.iter().map(|(key, _)| key.as_str()).collect();
        assert_eq!(keys, ["meta", "ticket-1", "index"], "the old board is not touched");
        assert_eq!(k.tracker.entry(1).unwrap().status, Status::InReview);

        let mut stored = saved.into_iter().map(|(_, v)| v);
        let (meta, _, index) = (stored.next().unwrap(), stored.next(), stored.next().unwrap());
        k = activate(meta, index, board);
        assert!(writes(&test_host::take_sent()).is_empty(), "a migrated tracker is not migrated again");
        assert_eq!(k.tracker.index.len(), 1);
    }

    #[test]
    fn an_unreadable_store_is_never_overwritten() {
        let mut k = activate(json!({"version":1,"next_number":2}), json!("garbage"), Value::Null);
        let sent = test_host::take_sent();
        assert!(sent_one(&sent, "view/render")["params"]["root"].to_string().contains("could not be read"));
        event(&mut k, "new-description-0", Some("New ticket"));
        snapshot(&mut k, "idle");
        assert_eq!(k.tracker.index.len(), 1, "the tracker still works in memory");
        assert!(writes(&test_host::take_sent()).is_empty());
    }

    #[test]
    fn an_idle_session_adds_its_last_message_as_one_comment() {
        let mut k = with_ticket(json!({"status":"in_progress","session_id":"s","branch":"task/kan-1","agent_state":"running","following":true,"seen":true}));
        snapshot(&mut k, "idle");
        let fetch = sent_one(&test_host::take_sent(), "session/last_message");
        assert_eq!(fetch["params"], json!({"id":"s"}));

        reply(&mut k, fetch["id"].as_i64().unwrap(), json!({"message":"Fixed it."}));
        let read = sent_one(&test_host::take_sent(), "storage/get");
        assert_eq!(read["params"]["key"], "ticket-1");
        reply(&mut k, read["id"].as_i64().unwrap(), json!({"value":{"description":"d"}}));
        let saved = writes(&test_host::take_sent());
        let body = &saved.iter().find(|(key, _)| key == "ticket-1").expect("the body is saved").1;
        assert_eq!(body["description"], "d");
        assert_eq!(body["comments"], json!([{"author":"agent","text":"Fixed it."}]));

        snapshot(&mut k, "idle");
        assert!(test_host::take_sent().is_empty());
    }

    #[test]
    fn edits_before_the_body_loads_write_nothing() {
        let mut k = with_ticket(json!({}));
        event(&mut k, "ticket-1", None);
        sent_one(&test_host::take_sent(), "storage/get");
        let (description, comment) = (format!("description-1-{}", k.form), format!("comment-1-{}", k.comment_form));
        event(&mut k, &description, Some("new description"));
        event(&mut k, &comment, Some("a comment"));
        assert!(test_host::take_sent().is_empty());
    }

    #[test]
    fn a_start_reply_for_a_deleted_ticket_is_ignored() {
        let mut k = with_ticket(json!({}));
        event(&mut k, "start-1", None);
        let read = sent_one(&test_host::take_sent(), "storage/get");
        reply(&mut k, read["id"].as_i64().unwrap(), json!({"value":null}));
        let start = sent_one(&test_host::take_sent(), "task/start");
        event(&mut k, "delete-1", None);
        assert!(writes(&test_host::take_sent()).contains(&("ticket-1".into(), Value::Null)));

        reply(&mut k, start["id"].as_i64().unwrap(), json!({"sessionId":"s","branch":"task/kan-1"}));
        assert!(writes(&test_host::take_sent()).is_empty());
        assert!(k.tracker.index.is_empty());
    }

    #[test]
    fn start_sends_the_ticket_and_assignee() {
        let mut k = with_ticket(json!({"assignee":"claude"}));
        event(&mut k, "start-1", None);
        let read = sent_one(&test_host::take_sent(), "storage/get");
        event(&mut k, "start-1", None);
        assert!(!test_host::take_sent().iter().any(|m| m["method"] == "storage/get"), "a second Start waits for the first");

        reply(&mut k, read["id"].as_i64().unwrap(), json!({"value":{"description":"Make it work."}}));
        let start = sent_one(&test_host::take_sent(), "task/start");
        assert_eq!(
            start["params"],
            json!({"title":"Fix it","prompt":"KAN-1: Fix it\n\nMake it work.","branch":"task/kan-1","agent":"claude"})
        );
    }

    #[test]
    fn a_failed_write_stays_visible_until_a_later_save_fully_succeeds() {
        let mut k = with_ticket(json!({}));
        event(&mut k, "new-description-0", Some("New ticket\nwith a body"));
        let sets: Vec<i64> = test_host::take_sent().iter().filter(|m| m["method"] == "storage/set").map(|m| m["id"].as_i64().unwrap()).collect();
        assert_eq!(sets.len(), 3, "meta, body, index");
        reply(&mut k, sets[0], json!({}));
        feed(&mut k, json!({"jsonrpc":"2.0","id":sets[1],"error":{"code":-32003,"message":"storage is full"}}));
        reply(&mut k, sets[2], json!({}));
        assert!(k.notice.as_deref().is_some_and(|n| n.starts_with(SAVE_FAILED)), "its own later writes do not hide it");
        event(&mut k, "ticket-1", None);
        event(&mut k, "back", None);
        let render = test_host::take_sent().into_iter().rev().find(|m| m["method"] == "view/render").unwrap();
        assert!(render["params"]["root"].to_string().contains(SAVE_FAILED), "navigating keeps it");

        event(&mut k, "status-1", Some("done"));
        for set in test_host::take_sent().iter().filter(|m| m["method"] == "storage/set") {
            reply(&mut k, set["id"].as_i64().unwrap(), json!({}));
        }
        assert_eq!(k.notice, None);
    }

    #[test]
    fn an_undecodable_body_is_shown_read_only_and_never_written() {
        let mut k = with_ticket(json!({}));
        event(&mut k, "ticket-1", None);
        let read = sent_one(&test_host::take_sent(), "storage/get");
        reply(&mut k, read["id"].as_i64().unwrap(), json!({"value":"not a body"}));
        let root = sent_one(&test_host::take_sent(), "view/render")["params"]["root"].to_string();
        assert!(root.contains("could not be read") && !root.contains("description-1-") && !root.contains("comment-1-"));

        event(&mut k, "comment-1-0", Some("hi"));
        event(&mut k, "delete-1", None);
        assert!(writes(&test_host::take_sent()).iter().all(|(key, _)| key != "ticket-1"));
    }
}
