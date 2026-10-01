//! Storage layout: `meta`, `index`, and one `ticket-<n>` key per body. Pure, no SDK calls.

use crate::board::Board;
use crate::tickets::{Body, Entry, Meta, Tracker};
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

/// A finished tracker always has an index, so `legacy` (the old `board`) must be supplied
/// whenever `meta` or `index` is absent: a parseable board then means an interrupted migration
/// and is migrated again (numbering is deterministic, so this is idempotent).
pub fn load(meta: Option<&str>, index: Option<&str>, legacy: Option<&str>) -> Loaded {
    let unreadable = |what: &str, e: serde_json::Error, tail: &str| Loaded::Unreadable(format!("The {what} could not be read ({e}); {tail}"));
    let board = legacy.map(serde_json::from_str::<Board>);
    if let (Some(meta), Some(index)) = (meta, index.map(Some).unwrap_or(match &board {
        Some(Ok(_)) => None,
        _ => Some("[]"),
    })) {
        let mut meta = match serde_json::from_str::<Meta>(meta) {
            Ok(m) => m,
            Err(e) => return unreadable("stored tickets", e, "nothing will be saved."),
        };
        let index = match serde_json::from_str::<Vec<Entry>>(index) {
            Ok(i) => i,
            Err(e) => return unreadable("stored tickets", e, "nothing will be saved."),
        };
        let floor = index.iter().map(|e| e.number.saturating_add(1)).max().unwrap_or(1);
        meta.next_number = meta.next_number.max(floor);
        return Loaded::Tracker(Tracker { meta, index });
    }
    match board {
        None => Loaded::Fresh,
        Some(Ok(board)) => {
            let (tracker, bodies) = Tracker::migrate(&board);
            Loaded::Migrated(tracker, bodies)
        }
        Some(Err(e)) => unreadable("old board", e, "it was left untouched and nothing will be saved."),
    }
}

pub fn parse_body(raw: Option<&str>) -> Body {
    raw.and_then(|r| serde_json::from_str(r).ok()).unwrap_or_default()
}

/// The writes for one change, in order: meta, bodies, the index (only if `index_changed`), then
/// deletes. Each item is (key, raw JSON, or `None` to delete). Raw, so sending it copies the text
/// instead of parsing it again. `deleted` is only for tickets
/// removed by `Tracker::delete`; archived bodies stay.
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
        ] {
            assert_eq!(kind(&load(m, i, l)), want, "{m:?} {i:?} {l:?}");
        }
        let Loaded::Tracker(t) = load(Some(meta), None, Some("garbage")) else { panic!() };
        assert!(t.index.is_empty());
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
