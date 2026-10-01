//! Storage layout: `meta`, `index`, and one `ticket-<n>` key per body. Pure, no SDK calls.

use crate::board::Board;
use crate::tickets::{Body, Entry, Meta, Tracker, MAX_INDEX};
use serde_json::value::{to_raw_value, RawValue};

pub const META: &str = "meta";
pub const INDEX: &str = "index";
pub const LEGACY: &str = "board";

pub fn body_key(number: u64) -> String {
    format!("ticket-{number}")
}

pub enum Loaded {
    Fresh,
    Tracker(Tracker),
    Migrated(Tracker, Vec<(u64, Body)>),
    /// Nothing may be saved; the text is for the notice.
    Unreadable(String),
}

/// The index is the source of truth: when it is present it is loaded, with default meta if
/// that is missing. Without one, a parseable old `board` means a first or interrupted migration
/// (numbering is deterministic, so migrating again is idempotent), so `legacy` must be supplied
/// whenever the index is absent.
pub fn load(meta: Option<&str>, index: Option<&str>, legacy: Option<&str>) -> Loaded {
    let unreadable = |what: &str, e: serde_json::Error, tail: &str| Loaded::Unreadable(format!("The {what} could not be read ({e}); {tail}"));
    let index = match index {
        Some(index) => index,
        None => match legacy.map(serde_json::from_str::<Board>) {
            Some(Ok(board)) => {
                let (mut tracker, bodies) = Tracker::migrate(&board);
                relaunched(&mut tracker);
                return Loaded::Migrated(tracker, bodies);
            }
            // Meta without an index or a usable board: an empty tracker that keeps its numbering.
            _ if meta.is_some() => "[]",
            None => return Loaded::Fresh,
            Some(Err(e)) => return unreadable("old board", e, "it was left untouched and nothing will be saved."),
        },
    };
    let mut meta = match serde_json::from_str::<Meta>(meta.unwrap_or("{}")) {
        Ok(m) => m,
        Err(e) => return unreadable("stored tickets", e, "nothing will be saved."),
    };
    let mut index = match serde_json::from_str::<Vec<Entry>>(index) {
        Ok(i) => i,
        Err(e) => return unreadable("stored tickets", e, "nothing will be saved."),
    };
    // The floor counts every stored number, so one dropped below is never reused.
    let floor = index.iter().map(|e| e.number.saturating_add(1)).max().unwrap_or(1);
    meta.next_number = meta.next_number.max(floor);
    // Tampered storage must not break the view's unique ids or size limits on every start.
    let mut seen = std::collections::HashSet::new();
    index.retain(|e| seen.insert(e.number));
    index.truncate(MAX_INDEX);
    let mut tracker = Tracker { meta, index };
    relaunched(&mut tracker);
    Loaded::Tracker(tracker)
}

/// A relaunch ends any start in flight, so every linked session counts as seen: one missing
/// from the next snapshot then moves its ticket to In review, and Start is offered again.
/// A followed session never seen gets the state `starting`, so that move counts as a change.
fn relaunched(tracker: &mut Tracker) {
    for e in tracker.index.iter_mut().filter(|e| e.session_id.is_some() && !e.seen) {
        e.seen = true;
        if e.following && e.agent_state.is_none() {
            e.agent_state = Some("starting".into());
        }
    }
}

pub fn parse_body(raw: Option<&str>) -> Body {
    raw.and_then(|r| serde_json::from_str(r).ok()).unwrap_or_default()
}

/// The writes for one change, in order: meta, bodies, the index (only if `index_changed`), then
/// deletes. Each item is (key, raw JSON, or `None` to delete). Raw, so sending it copies the text
/// instead of parsing it again. `deleted` is only for tickets
/// removed by `Tracker::delete` or `Tracker::archive`.
pub fn writes(tracker: &Tracker, bodies: &[(u64, &Body)], deleted: &[u64], index_changed: bool) -> Vec<(String, Option<Box<RawValue>>)> {
    let json = |v: serde_json::Result<Box<RawValue>>| v.expect("plain data serializes");
    let mut out = Vec::with_capacity(bodies.len() + deleted.len() + 2);
    out.push((META.to_owned(), Some(json(to_raw_value(&tracker.meta)))));
    for (n, b) in bodies {
        out.push((body_key(*n), Some(json(to_raw_value(b)))));
    }
    if index_changed {
        out.push((INDEX.to_owned(), Some(json(to_raw_value(&tracker.index)))));
    }
    out.extend(deleted.iter().map(|n| (body_key(*n), None)));
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tickets::{Priority, FORMAT_VERSION};

    fn kind(l: &Loaded) -> &'static str {
        match l {
            Loaded::Fresh => "fresh",
            Loaded::Tracker(_) => "tracker",
            Loaded::Migrated(..) => "migrated",
            Loaded::Unreadable(_) => "unreadable",
        }
    }

    #[test]
    fn loading_picks_the_stored_format() {
        let meta = r#"{"version":1,"next_number":3}"#;
        let index = r#"[{"number":2,"title":"t","status":"todo"}]"#;
        let legacy = r#"{"cards":[{"id":1,"title":"c","prompt":"p","column":"Backlog"}],"next_id":2}"#;
        for (m, i, l, want) in [
            (None, None, None, "fresh"),
            (Some(meta), Some(index), None, "tracker"),
            (Some(meta), None, None, "tracker"),
            (None, None, Some(legacy), "migrated"),
            (None, None, Some("garbage"), "unreadable"),
            (Some("garbage"), Some(index), None, "unreadable"),
            (Some(meta), Some("garbage"), None, "unreadable"),
            (Some(meta), Some(index), Some(legacy), "tracker"),
            (Some(meta), None, Some(legacy), "migrated"),
            (None, Some(index), None, "tracker"),
            (None, Some(index), Some(legacy), "tracker"),
        ] {
            assert_eq!(kind(&load(m, i, l)), want, "{m:?} {i:?} {l:?}");
        }
        let Loaded::Tracker(t) = load(Some(meta), None, Some("garbage")) else { panic!() };
        assert!(t.index.is_empty());

        // A relaunch ended any start in flight: a session missing from the snapshot is not
        // waited for, so the ticket moves to In review.
        let starting = r#"[{"number":2,"title":"t","status":"in_progress","session_id":"s","following":true}]"#;
        let Loaded::Tracker(mut t) = load(Some(meta), Some(starting), None) else { panic!() };
        assert!(t.sync(&[]).0);
        assert_eq!(t.index[0].status, crate::tickets::Status::InReview);
        assert_eq!(t.index[0].agent_state, None);
    }

    #[test]
    fn a_stale_next_number_is_raised() {
        let index = r#"[{"number":5,"title":"a","status":"done"},{"number":2,"title":"b","status":"todo"}]"#;
        let Loaded::Tracker(t) = load(Some(r#"{"version":1,"next_number":2}"#), Some(index), None) else { panic!() };
        assert_eq!(t.meta.next_number, 6);
    }

    #[test]
    fn writes_put_meta_first_then_bodies_then_the_index_and_deletes_last() {
        let mut t = Tracker::default();
        t.meta.version = FORMAT_VERSION;
        t.create("a", Priority::None, None);
        let body = Body { description: "d".into(), ..Body::default() };
        let keys = |w: Vec<(String, Option<Box<RawValue>>)>| w.into_iter().map(|(k, v)| (k, v.is_some())).collect::<Vec<_>>();
        let k = |s: &str, put| (s.to_owned(), put);
        assert_eq!(
            keys(writes(&t, &[(1, &body)], &[7], true)),
            [k("meta", true), k("ticket-1", true), k("index", true), k("ticket-7", false)]
        );
        assert_eq!(keys(writes(&t, &[], &[], false)), [k("meta", true)]);
        assert_eq!(parse_body(Some(r#"{"description":"d"}"#)), body);
        assert_eq!(parse_body(Some("x")), Body::default());
        assert_eq!(parse_body(None), Body::default());
    }
}
