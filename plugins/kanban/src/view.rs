//! Renders the board and the ticket screen as view trees. Pure: no SDK calls besides the node types.
//!
//! Ids are built only from fixed words and ticket numbers, so they stay unique and under the
//! host's 64 bytes. Board cards carry index data only; a ticket body is read on its screen.

use crate::tickets::{Author, Body, Entry, Priority, Status, Tracker, MAX_COMMENTS, MAX_COMMENT_CHARS, MAX_DESCRIPTION_CHARS, MAX_INDEX, MAX_LABELS, MAX_LABEL_CHARS};
use alas_plugin::{Agent, Axis, ButtonStyle, MenuItem, Node, TextStyle, Tone};

const MAX_TEXT: usize = 500;
/// The host's cap on menu items.
const MAX_MENU_ITEMS: usize = 64;
/// The assignee menu item that clears the assignee.
pub const UNASSIGNED: &str = "-";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Screen {
    Board { show_cancelled: bool },
    Ticket(u64),
}

impl Default for Screen {
    fn default() -> Self {
        Screen::Board { show_cancelled: false }
    }
}

/// The New ticket form's choices. The description is not kept: submitting it creates the ticket.
#[derive(Debug, Default)]
pub struct Draft {
    pub title: String,
    pub priority: Priority,
    pub assignee: Option<String>,
}

pub struct ViewState<'a> {
    pub tracker: &'a Tracker,
    pub screen: &'a Screen,
    /// The open ticket's body; `None` while it loads.
    pub body: Option<&'a Body>,
    pub agents: &'a [Agent],
    pub draft: &'a Draft,
    pub form: u64,
    /// The comment field's own generation, so posting a comment keeps unsaved description text.
    pub comment_form: u64,
    pub notice: Option<&'a str>,
    /// Tickets with a Start in flight.
    pub starting: &'a [u64],
}

fn clip(s: &str, max: usize) -> String {
    // A string has at least as many bytes as chars, so short ones skip the char scan.
    if s.len() <= max {
        return s.to_string();
    }
    match s.char_indices().nth(max) {
        Some((i, _)) => format!("{}…", &s[..i]),
        None => s.to_string(),
    }
}

fn text(id: String, text: &str, style: Option<TextStyle>, tone: Option<Tone>) -> Node {
    Node::Text { id, text: clip(text, MAX_TEXT), style, tone }
}

fn hstack(id: String, children: Vec<Node>) -> Node {
    Node::Hstack { id, children, spacing: Some(8) }
}

fn vstack(id: String, children: Vec<Node>) -> Node {
    Node::Vstack { id, children, spacing: Some(8), width: None }
}

fn button(id: String, label: &str, icon: Option<&str>, style: ButtonStyle, disabled: bool) -> Node {
    Node::Button { id, label: label.into(), icon: icon.map(Into::into), style: Some(style), disabled }
}

pub fn render(s: &ViewState) -> Node {
    let mut children: Vec<Node> = s.notice.map(|n| text("notice".into(), n, None, Some(Tone::Danger))).into_iter().collect();
    match *s.screen {
        Screen::Ticket(n) => match s.tracker.entry(n) {
            Some(e) => children.push(ticket(s, e)),
            None => board(s, false, &mut children),
        },
        Screen::Board { show_cancelled } => board(s, show_cancelled, &mut children),
    }
    Node::Vstack { id: "root".into(), spacing: Some(12), width: None, children }
}

fn board(s: &ViewState, show_cancelled: bool, out: &mut Vec<Node>) {
    out.push(new_ticket(s));
    let toggle = if show_cancelled { "Hide cancelled" } else { "Show cancelled" };
    out.push(button("show-cancelled".into(), toggle, None, ButtonStyle::Plain, false));
    let columns = Status::ALL
        .into_iter()
        .filter(|&status| show_cancelled || status != Status::Cancelled)
        .map(|status| column(s.tracker, status))
        .collect();
    out.push(Node::Scroll {
        id: "scroll".into(),
        axis: Axis::Horizontal,
        child: Box::new(Node::Hstack { id: "columns".into(), children: columns, spacing: Some(12) }),
    });
}

fn new_ticket(s: &ViewState) -> Node {
    let f = s.form;
    let row = vec![
        Node::TextField {
            id: format!("new-title-{f}"),
            value: s.draft.title.clone(),
            placeholder: Some("Title (Return keeps it)".into()),
            multiline: false,
        },
        priority_menu(format!("new-priority-{f}"), s.draft.priority),
        assignee_menu(format!("new-assignee-{f}"), s.draft.assignee.as_deref(), s.agents),
        button("create".into(), "Create", Some("plus"), ButtonStyle::Primary, false),
    ];
    let children = vec![
        text("new-heading".into(), "New ticket", Some(TextStyle::Title), None),
        hstack("new-row".into(), row),
        Node::TextField {
            id: format!("new-description-{f}"),
            value: String::new(),
            placeholder: Some("Description — ⌘Return creates the ticket; without a title, its first line is the title".into()),
            multiline: true,
        },
    ];
    Node::Card { id: "new".into(), children, tone: None, clickable: false, width: None }
}

fn priority_menu(id: String, current: Priority) -> Node {
    let items = Priority::ALL
        .into_iter()
        .filter(|&p| p != current)
        .map(|p| MenuItem { id: p.key().into(), label: p.title().into() })
        .collect();
    Node::Menu { id, label: current.title().into(), items }
}

/// With no agents there is nothing to pick, so a label says so instead of an empty menu.
fn assignee_menu(id: String, current: Option<&str>, agents: &[Agent]) -> Node {
    let name = current.map(|a| agents.iter().find(|x| x.id == a).map_or(a, |x| x.name.as_str()));
    if agents.is_empty() {
        let label = match name {
            Some(name) => format!("Assignee: {name} (no agents available)"),
            None => "No agents available".into(),
        };
        return text(id, &label, Some(TextStyle::Caption), Some(Tone::Dim));
    }
    let mut items = vec![MenuItem { id: UNASSIGNED.into(), label: "Unassigned".into() }];
    // Item ids must be 1 to 64 bytes; an agent whose id is not cannot be offered.
    let pickable = agents.iter().filter(|a| (1..=64).contains(&a.id.len()) && a.id != UNASSIGNED);
    items.extend(pickable.take(MAX_MENU_ITEMS - 1).map(|a| MenuItem { id: a.id.clone(), label: clip(&a.name, 100) }));
    Node::Menu { id, label: clip(&format!("Assignee: {}", name.unwrap_or("none")), MAX_TEXT), items }
}

fn state_badge(id: String, state: &str) -> Node {
    let tone = match state {
        "awaiting_input" | "permission_request" => Some(Tone::Warn),
        "running" => Some(Tone::Accent),
        _ => None,
    };
    Node::Badge { id, text: clip(state, 40), tone }
}

fn priority_badge(id: String, priority: Priority) -> Node {
    let tone = match priority {
        Priority::Urgent => Some(Tone::Danger),
        Priority::High => Some(Tone::Warn),
        _ => None,
    };
    Node::Badge { id, text: priority.title().into(), tone }
}

fn column(tracker: &Tracker, status: Status) -> Node {
    let key = status.key();
    // The index is not in number order: closed tickets sit at its end in closing order.
    let mut entries: Vec<&Entry> = tracker.in_status(status).collect();
    entries.sort_unstable_by_key(|e| e.number);
    // Loading caps the index; this keeps the tree within the host's node limit regardless.
    entries.truncate(MAX_INDEX);
    let header = hstack(
        format!("col-{key}-header"),
        vec![
            text(format!("col-{key}-title"), status.title(), Some(TextStyle::Title), None),
            Node::Badge { id: format!("col-{key}-count"), text: entries.len().to_string(), tone: None },
        ],
    );
    // Cards scroll on their own, under the header, so every card stays reachable.
    let cards = Node::Scroll {
        id: format!("col-{key}-scroll"),
        axis: Axis::Vertical,
        child: Box::new(vstack(format!("col-{key}-cards"), entries.into_iter().map(card).collect())),
    };
    Node::Vstack { id: format!("col-{key}"), children: vec![header, cards], spacing: Some(8), width: Some(280) }
}

fn card(e: &Entry) -> Node {
    let n = e.number;
    let mut meta = vec![text(format!("ticket-{n}-number"), &format!("KAN-{n}"), Some(TextStyle::Caption), Some(Tone::Dim))];
    if e.priority != Priority::None {
        meta.push(priority_badge(format!("ticket-{n}-priority"), e.priority));
    }
    if let Some(assignee) = &e.assignee {
        meta.push(text(format!("ticket-{n}-assignee"), assignee, Some(TextStyle::Caption), None));
    }
    if let (Some(_), Some(state)) = (&e.session_id, &e.agent_state) {
        meta.push(state_badge(format!("ticket-{n}-state"), state));
    }
    let mut children = vec![hstack(format!("ticket-{n}-meta"), meta), text(format!("ticket-{n}-title"), &e.title, None, None)];
    if let Some(error) = &e.error {
        children.push(text(format!("ticket-{n}-error"), &format!("Start failed: {error}"), None, Some(Tone::Danger)));
    }
    Node::Card { id: format!("ticket-{n}"), children, tone: None, clickable: true, width: None }
}

fn ticket(s: &ViewState, e: &Entry) -> Node {
    let n = e.number;
    let mut out = vec![hstack(
        "header".into(),
        vec![
            button("back".into(), "Back", Some("chevron.left"), ButtonStyle::Plain, false),
            text(format!("ticket-{n}-number"), &format!("KAN-{n}"), Some(TextStyle::Title), Some(Tone::Dim)),
            text(format!("ticket-{n}-title"), &e.title, Some(TextStyle::Title), None),
        ],
    )];

    let statuses = Status::ALL
        .into_iter()
        .filter(|&st| st != e.status)
        .map(|st| MenuItem { id: st.key().into(), label: st.title().into() })
        .collect();
    let mut controls = vec![
        Node::Menu { id: format!("status-{n}"), label: e.status.title().into(), items: statuses },
        priority_menu(format!("priority-{n}"), e.priority),
        assignee_menu(format!("assign-{n}"), e.assignee.as_deref(), s.agents),
    ];
    // A session is running from the accepted start until it is seen idle (or gone).
    let running = e.session_id.is_some() && (!e.seen || e.agent_state.as_deref().is_some_and(|st| st != "idle"));
    if !running && !e.status.closed() {
        let starting = s.starting.contains(&n);
        let label = if starting { "Starting…" } else { "Start" };
        controls.push(button(format!("start-{n}"), label, Some("play.fill"), ButtonStyle::Primary, starting));
    }
    out.push(hstack(format!("ticket-{n}-controls"), controls));

    if let Some(branch) = &e.branch {
        let mut row = vec![text(format!("ticket-{n}-branch"), branch, Some(TextStyle::Monospaced), None)];
        if let Some(state) = &e.agent_state {
            row.push(state_badge(format!("ticket-{n}-state"), state));
        }
        if e.session_id.is_some() {
            row.push(button(format!("open-{n}"), "Open session", None, ButtonStyle::Normal, false));
        }
        out.push(hstack(format!("ticket-{n}-session"), row));
    }
    if let Some(error) = &e.error {
        out.push(text(format!("ticket-{n}-error"), &format!("Start failed: {error}"), None, Some(Tone::Danger)));
    }

    match s.body {
        None => out.push(text("loading".into(), "Loading…", None, Some(Tone::Dim))),
        Some(body) => body_nodes(n, s.form, s.comment_form, body, &mut out),
    }

    let mut footer = Vec::new();
    if e.status != Status::Cancelled {
        footer.push(button(format!("cancel-{n}"), "Cancel ticket", None, ButtonStyle::Normal, false));
    }
    footer.push(button(format!("delete-{n}"), "Delete", Some("trash"), ButtonStyle::Plain, false));
    out.push(hstack("footer".into(), footer));

    Node::Scroll { id: "ticket".into(), axis: Axis::Vertical, child: Box::new(vstack("ticket-content".into(), out)) }
}

fn body_nodes(n: u64, form: u64, comment_form: u64, body: &Body, out: &mut Vec<Node>) {
    out.push(text("description-heading".into(), "Description", Some(TextStyle::Caption), Some(Tone::Dim)));
    out.push(Node::TextField {
        id: format!("description-{n}-{form}"),
        // Edits are capped; the clip only guards against tampered storage over the host's limit.
        value: body.description.chars().take(MAX_DESCRIPTION_CHARS).collect(),
        placeholder: Some("Describe the ticket — ⌘Return saves".into()),
        multiline: true,
    });
    if !body.labels.is_empty() {
        let labels = body.labels.iter().take(MAX_LABELS).enumerate();
        let badges = labels.map(|(i, l)| Node::Badge { id: format!("label-{i}"), text: clip(l, MAX_LABEL_CHARS), tone: None });
        out.push(hstack("labels".into(), badges.collect()));
    }

    out.push(text("comments-heading".into(), "Comments", Some(TextStyle::Caption), Some(Tone::Dim)));
    let hidden = body.comments.len().saturating_sub(MAX_COMMENTS);
    for (i, c) in body.comments.iter().enumerate().skip(hidden) {
        let author = match c.author {
            Author::You => "You",
            Author::Agent => "Agent",
        };
        out.push(Node::Card {
            id: format!("said-{i}"),
            children: vec![
                text(format!("said-{i}-author"), author, Some(TextStyle::Caption), Some(Tone::Dim)),
                Node::Text { id: format!("said-{i}-text"), text: clip(&c.text, MAX_COMMENT_CHARS), style: None, tone: None },
            ],
            tone: None,
            clickable: false,
            width: None,
        });
    }
    out.push(Node::TextField {
        id: format!("comment-{n}-{comment_form}"),
        value: String::new(),
        placeholder: Some("Add a comment — ⌘Return posts it".into()),
        multiline: true,
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tickets::MAX_TITLE_CHARS;
    use serde_json::Value;
    use std::collections::HashSet;

    fn tree(tracker: &Tracker, screen: Screen, body: Option<&Body>, agents: &[Agent]) -> Value {
        let draft = Draft::default();
        let state = ViewState { tracker, screen: &screen, body, agents, draft: &draft, form: 0, comment_form: 0, notice: None, starting: &[] };
        serde_json::to_value(render(&state)).unwrap()
    }

    fn find<'a>(v: &'a Value, id: &str) -> Option<&'a Value> {
        if v["id"] == id && v.get("kind").is_some() {
            return Some(v);
        }
        let kids = v.get("children").and_then(Value::as_array).map(|c| c.iter().collect()).or_else(|| v.get("child").map(|c| vec![c]));
        kids.unwrap_or_default().into_iter().find_map(|k| find(k, id))
    }

    fn ids(v: &Value, out: &mut Vec<String>) {
        if let Some(id) = v.get("kind").and(v["id"].as_str()) {
            out.push(id.into());
        }
        v.get("children").and_then(Value::as_array).into_iter().flatten().chain(v.get("child")).for_each(|k| ids(k, out));
    }

    fn assert_within_host_limits(tree: &Value) {
        fn walk(v: &Value, depth: usize, max_depth: &mut usize) {
            match v {
                Value::String(s) => assert!(s.chars().count() <= 4000, "a {}-char string", s.chars().count()),
                Value::Array(a) => a.iter().for_each(|x| walk(x, depth, max_depth)),
                Value::Object(o) => {
                    let depth = depth + o.contains_key("kind") as usize;
                    *max_depth = (*max_depth).max(depth);
                    if let Some(items) = o.get("items").and_then(Value::as_array) {
                        assert!(items.len() <= 64);
                    }
                    o.values().for_each(|x| walk(x, depth, max_depth));
                }
                _ => {}
            }
        }
        let mut all = Vec::new();
        ids(tree, &mut all);
        assert!(all.iter().all(|id| (1..=64).contains(&id.len())));
        assert_eq!(all.iter().collect::<HashSet<_>>().len(), all.len(), "ids must be unique");
        assert!(all.len() <= 2000, "{} nodes", all.len());
        let mut depth = 0;
        walk(tree, 0, &mut depth);
        assert!(depth <= 16, "depth {depth}");
    }

    fn column_cards(tree: &Value, key: &str) -> Vec<String> {
        let cards = find(tree, &format!("col-{key}-cards")).unwrap();
        cards["children"].as_array().unwrap().iter().map(|c| c["id"].as_str().unwrap().to_owned()).collect()
    }

    #[test]
    fn the_board_has_five_columns_and_cards_carry_index_data() {
        let mut t = Tracker::default();
        for title in ["a", "b", "c", "d", "e"] {
            t.create(title, Priority::None, None);
        }
        let first = t.entry_mut(1).unwrap();
        first.priority = Priority::High;
        first.assignee = Some("claude".into());
        t.started(2, "s".into(), "task/kan-2".into());
        t.entry_mut(2).unwrap().agent_state = Some("running".into());
        // Closing 4 before 3 leaves them out of number order in the index.
        t.set_status(4, Status::Done);
        t.set_status(3, Status::Done);
        t.set_status(5, Status::Cancelled);

        let board = tree(&t, Screen::Board { show_cancelled: false }, None, &[]);
        let columns: Vec<_> = find(&board, "columns").unwrap()["children"].as_array().unwrap().iter().map(|c| c["id"].clone()).collect();
        assert_eq!(columns, ["col-backlog", "col-todo", "col-in_progress", "col-in_review", "col-done"]);
        assert_eq!(find(&board, "col-done-count").unwrap()["text"], "2");
        assert_eq!(column_cards(&board, "done"), ["ticket-3", "ticket-4"]);
        assert_eq!(find(&board, "ticket-1").unwrap()["clickable"], true);
        assert_eq!(find(&board, "ticket-1-number").unwrap()["text"], "KAN-1");
        assert_eq!(find(&board, "ticket-1-title").unwrap()["text"], "a");
        assert_eq!(find(&board, "ticket-1-priority").unwrap()["text"], "High");
        assert_eq!(find(&board, "ticket-1-assignee").unwrap()["text"], "claude");
        assert_eq!(find(&board, "ticket-2-state").unwrap()["text"], "running");
        assert!(find(&board, "ticket-5").is_none());

        let board = tree(&t, Screen::Board { show_cancelled: true }, None, &[]);
        assert_eq!(column_cards(&board, "cancelled"), ["ticket-5"]);
    }

    #[test]
    fn a_full_tracker_stays_within_the_host_limits() {
        let mut t = Tracker::default();
        let title = "é".repeat(MAX_TITLE_CHARS);
        for i in 0..MAX_INDEX {
            let n = t.create(&title, Priority::Urgent, Some("a".repeat(200))).unwrap();
            t.started(n, format!("s{i}"), "b".repeat(300));
            let e = t.entry_mut(n).unwrap();
            e.agent_state = Some("awaiting_input".into());
            e.error = Some("x".repeat(5000));
        }
        let agents: Vec<_> = (0..100).map(|i| Agent { id: format!("agent-{i}"), name: "n".repeat(5000) }).collect();
        let board = tree(&t, Screen::Board { show_cancelled: true }, None, &agents);
        assert_within_host_limits(&board);
        assert_eq!(column_cards(&board, "in_progress").len(), MAX_INDEX);

        let mut body = Body { description: "d".repeat(MAX_DESCRIPTION_CHARS + 1), labels: vec!["l".repeat(100); 20], comments: vec![] };
        for _ in 0..MAX_COMMENTS {
            body.comment(Author::Agent, &"c".repeat(MAX_COMMENT_CHARS));
        }
        let screen = tree(&t, Screen::Ticket(MAX_INDEX as u64), Some(&body), &agents);
        assert_within_host_limits(&screen);
        let field = find(&screen, &format!("description-{MAX_INDEX}-0")).unwrap();
        assert_eq!(field["value"].as_str().unwrap().len(), MAX_DESCRIPTION_CHARS, "an over-long stored description is clipped");
    }

    #[test]
    fn the_ticket_screen_waits_for_its_body() {
        let mut t = Tracker::default();
        t.create("a", Priority::None, None);
        let has_field = |v: &Value| {
            let mut all = Vec::new();
            ids(v, &mut all);
            all.iter().any(|id| id.starts_with("description-1-") || id.starts_with("comment-1-"))
        };
        let loading = tree(&t, Screen::Ticket(1), None, &[]);
        assert!(find(&loading, "loading").is_some());
        assert!(!has_field(&loading));
        assert!(find(&loading, "status-1").is_some(), "index fields are editable at once");

        let body = Body { description: "d".into(), ..Body::default() };
        let loaded = tree(&t, Screen::Ticket(1), Some(&body), &[]);
        assert!(find(&loaded, "loading").is_none());
        assert_eq!(find(&loaded, "description-1-0").unwrap()["value"], "d");
        assert!(find(&loaded, "comment-1-0").is_some());
    }
}
