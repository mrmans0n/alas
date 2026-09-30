//! Renders the board as a view tree. Pure: no SDK calls besides the node types.

use crate::board::{Board, Card, Column};
use alas_plugin::{Axis, ButtonStyle, MenuItem, Node, TextStyle, Tone};

// ponytail: fixed per-column cap keeps the tree under the host's 2,000-node limit;
// paginate or collapse Done if boards grow past it.
const MAX_CARDS_PER_COLUMN: usize = 30;
const MAX_TEXT: usize = 500;

fn clip(s: &str, max: usize) -> String {
    match s.char_indices().nth(max) {
        Some((i, _)) => format!("{}…", &s[..i]),
        None => s.to_string(),
    }
}

fn text(id: String, text: &str, style: Option<TextStyle>, tone: Option<Tone>) -> Node {
    Node::Text { id, text: clip(text, MAX_TEXT), style, tone }
}

fn hstack(id: String, children: Vec<Node>) -> Node {
    Node::Hstack { id, children, spacing: None }
}

pub fn render(board: &Board, form: u64) -> Node {
    let columns = Column::ALL.into_iter().map(|col| column(board, col, form)).collect();
    Node::Vstack {
        id: "root".into(),
        spacing: None,
        width: None,
        children: vec![Node::Scroll {
            id: "scroll".into(),
            axis: Axis::Horizontal,
            child: Box::new(Node::Hstack { id: "columns".into(), children: columns, spacing: Some(12) }),
        }],
    }
}

fn column(board: &Board, col: Column, form: u64) -> Node {
    let key = col.key();
    let cards = board.in_column(col);
    let mut children = vec![hstack(
        format!("col-{key}-header"),
        vec![
            text(format!("col-{key}-title"), col.title(), Some(TextStyle::Title), None),
            Node::Badge { id: format!("col-{key}-count"), text: cards.len().to_string(), tone: None },
        ],
    )];
    if col == Column::Backlog {
        children.push(Node::TextField {
            id: format!("new-title-{form}"),
            value: String::new(),
            placeholder: Some("Title".into()),
            multiline: false,
        });
        children.push(Node::TextField {
            id: format!("new-prompt-{form}"),
            value: String::new(),
            placeholder: Some("Prompt — ⌘Return to add".into()),
            multiline: true,
        });
    }
    children.extend(cards.iter().take(MAX_CARDS_PER_COLUMN).map(|c| card(c)));
    if cards.len() > MAX_CARDS_PER_COLUMN {
        let more = format!("+{} more", cards.len() - MAX_CARDS_PER_COLUMN);
        children.push(text(format!("col-{key}-more"), &more, Some(TextStyle::Caption), Some(Tone::Dim)));
    }
    Node::Vstack { id: format!("col-{key}"), children, spacing: Some(8), width: Some(280) }
}

fn card(c: &Card) -> Node {
    let id = c.id;
    let mut children = vec![
        text(format!("card-{id}-title"), &c.title, None, None),
        text(format!("card-{id}-prompt"), &clip(&c.prompt, 120), Some(TextStyle::Caption), Some(Tone::Dim)),
    ];
    if let Some(branch) = &c.branch {
        children.push(text(format!("card-{id}-branch"), branch, Some(TextStyle::Monospaced), None));
    }
    if let Some(state) = &c.agent_state {
        let tone = match state.as_str() {
            "awaiting_input" | "permission_request" => Some(Tone::Warn),
            "running" => Some(Tone::Accent),
            _ => None,
        };
        children.push(Node::Badge { id: format!("card-{id}-state"), text: state.clone(), tone });
    }
    if let Some(error) = &c.error {
        children.push(text(format!("card-{id}-error"), &format!("Start failed: {error}"), None, Some(Tone::Danger)));
    }
    let mut buttons = Vec::new();
    if c.column == Column::Backlog {
        buttons.push(Node::Button {
            id: format!("start-{id}"),
            label: "Start".into(),
            icon: Some("play.fill".into()),
            style: Some(ButtonStyle::Primary),
            disabled: false,
        });
        buttons.push(Node::Button {
            id: format!("delete-{id}"),
            label: "Delete".into(),
            icon: None,
            style: Some(ButtonStyle::Plain),
            disabled: false,
        });
    }
    // A card without a session has nothing to follow, so only Backlog and Done make sense.
    let items = Column::ALL
        .into_iter()
        .filter(|&col| col != c.column)
        .filter(|col| c.session_id.is_some() || matches!(col, Column::Backlog | Column::Done))
        .map(|col| MenuItem { id: col.key().into(), label: col.title().into() })
        .collect();
    buttons.push(Node::Menu { id: format!("move-{id}"), label: "Move to".into(), items });
    children.push(hstack(format!("card-{id}-buttons"), buttons));
    Node::Card { id: format!("card-{id}"), children, tone: None, clickable: c.session_id.is_some(), width: None }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Every node in the tree, depth first.
    fn flatten<'a>(node: &'a Node, out: &mut Vec<(&'a str, &'a Node)>) {
        let (id, kids): (&String, Vec<&Node>) = match node {
            Node::Vstack { id, children, .. } | Node::Hstack { id, children, .. } | Node::Card { id, children, .. } => {
                (id, children.iter().collect())
            }
            Node::Scroll { id, child, .. } => (id, vec![child.as_ref()]),
            Node::Text { id, .. }
            | Node::Badge { id, .. }
            | Node::Button { id, .. }
            | Node::TextField { id, .. }
            | Node::Menu { id, .. }
            | Node::Divider { id }
            | Node::Spacer { id } => (id, vec![]),
        };
        out.push((id, node));
        kids.into_iter().for_each(|k| flatten(k, out));
    }

    fn find<'a>(tree: &'a Node, want: &str) -> Option<&'a Node> {
        let mut all = Vec::new();
        flatten(tree, &mut all);
        all.into_iter().find(|(id, _)| *id == want).map(|(_, n)| n)
    }

    #[test]
    fn the_board_renders_five_columns_with_counts() {
        let mut b = Board::default();
        b.add("a", "p");
        let id = b.add("b", "p");
        b.started(id, "s".into(), "br".into());
        let tree = render(&b, 0);
        let Node::Vstack { children, .. } = &tree else { panic!() };
        let Node::Scroll { child, axis: Axis::Horizontal, .. } = &children[0] else { panic!() };
        let Node::Hstack { children: cols, .. } = child.as_ref() else { panic!() };
        let keys: Vec<_> = cols
            .iter()
            .map(|c| match c {
                Node::Vstack { id, width: Some(280), .. } => id.as_str(),
                other => panic!("{other:?}"),
            })
            .collect();
        assert_eq!(keys, ["col-backlog", "col-running", "col-needs_you", "col-review", "col-done"]);
        for (col, count) in [("backlog", "1"), ("running", "1"), ("done", "0")] {
            let Some(Node::Badge { text, .. }) = find(&tree, &format!("col-{col}-count")) else { panic!() };
            assert_eq!(text, count);
        }
        let mut ids = Vec::new();
        flatten(&tree, &mut ids);
        let unique: std::collections::HashSet<_> = ids.iter().map(|(id, _)| id).collect();
        assert_eq!(unique.len(), ids.len(), "ids must be unique");
    }

    #[test]
    fn backlog_cards_have_start_and_delete_and_started_cards_are_clickable() {
        let mut b = Board::default();
        let fresh = b.add("a", "p");
        let started = b.add("b", "p");
        b.started(started, "s".into(), "task/b".into());
        b.start_failed(fresh, "boom");
        let tree = render(&b, 0);

        let Some(Node::Card { clickable: false, .. }) = find(&tree, &format!("card-{fresh}")) else { panic!() };
        assert!(find(&tree, &format!("start-{fresh}")).is_some());
        assert!(find(&tree, &format!("delete-{fresh}")).is_some());
        let Some(Node::Text { text, tone: Some(Tone::Danger), .. }) = find(&tree, &format!("card-{fresh}-error")) else { panic!() };
        assert_eq!(text, "Start failed: boom");
        let Some(Node::Menu { items, .. }) = find(&tree, &format!("move-{fresh}")) else { panic!() };
        assert_eq!(items.iter().map(|i| i.id.as_str()).collect::<Vec<_>>(), ["done"]);

        let Some(Node::Card { clickable: true, .. }) = find(&tree, &format!("card-{started}")) else { panic!() };
        assert!(find(&tree, &format!("start-{started}")).is_none());
        assert!(find(&tree, &format!("card-{started}-branch")).is_some());
        let Some(Node::Menu { items, .. }) = find(&tree, &format!("move-{started}")) else { panic!() };
        assert_eq!(items.len(), 4);
    }

    #[test]
    fn form_field_ids_change_with_the_form_generation() {
        let b = Board::default();
        assert!(find(&render(&b, 0), "new-prompt-0").is_some());
        let tree = render(&b, 1);
        assert!(find(&tree, "new-title-1").is_some() && find(&tree, "new-prompt-1").is_some());
        assert!(find(&tree, "new-title-0").is_none());
    }
}
