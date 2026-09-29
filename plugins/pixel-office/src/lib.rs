//! Pixel Office: one character per agent session, one desk per worktree.

pub mod atlas;
pub mod canvas;
pub mod layout;
pub mod look;
pub mod render;
pub mod sim;
pub mod sprites;

use alas_plugin::{export_plugin, log, present, request, set_regions, Event, Plugin, Region, Snapshot};
use layout::Layout;
use render::{Renderer, Target};
use serde_json::json;
use sim::World;

#[derive(Default)]
pub struct Office {
    layout: Option<Layout>,
    world: World,
    renderer: Renderer,
    snapshot_request: i64,
    regions: Vec<Region>,
    targets: Vec<Target>,
}

impl Office {
    fn apply(&mut self, snapshot: Snapshot) {
        let layout = layout::layout(&snapshot);
        self.world.sync(&snapshot, &layout);
        self.layout = Some(layout);
    }
}

impl Plugin for Office {
    fn handle(&mut self, event: Event) {
        match event {
            Event::Activate { .. } => self.snapshot_request = request("workspace/snapshot", json!({})),
            Event::WorkspaceChanged(snapshot) => self.apply(snapshot),
            Event::Reply { id, result: Ok(value) } if id == self.snapshot_request => {
                if let Ok(snapshot) = serde_json::from_value(value["snapshot"].clone()) {
                    self.apply(snapshot);
                }
            }
            // Review focus 4: e.g. a session that ended between the snapshot and the click.
            Event::Reply { result: Err(error), .. } => log("warn", &format!("request failed: {} {}", error.code, error.message)),
            Event::Tick { dt } => {
                let Some(layout) = &self.layout else { return };
                self.world.step(dt, layout);
                let frame = self.renderer.render(&self.world, layout);
                present(0, &frame.pixels, frame.width as u32);
                let (regions, targets) = render::regions(&self.world, layout);
                if regions != self.regions {
                    set_regions(0, &regions);
                    self.regions = regions;
                }
                self.targets = targets;
            }
            Event::Click { region, .. } => {
                let Some(index) = region.strip_prefix('r').and_then(|n| n.parse::<usize>().ok()) else { return };
                match self.targets.get(index) {
                    Some(Target::Session(id)) => {
                        request("session/focus", json!({"id": id}));
                    }
                    Some(Target::Worktree(id)) => {
                        request("worktree/switch", json!({"id": id}));
                    }
                    None => {}
                }
            }
            _ => {}
        }
    }
}

export_plugin!(Office);

#[cfg(test)]
mod tests {
    use super::*;
    use alas_plugin::{dispatch, test_host};

    fn feed(office: &mut Office, message: serde_json::Value) {
        dispatch(office, message.to_string().as_bytes());
    }

    #[test]
    fn ticks_present_a_frame_and_clicks_focus_the_session() {
        test_host::take_sent();
        test_host::take_frames();
        let mut office = Office::default();
        feed(&mut office, json!({"jsonrpc":"2.0","method":"workspace/changed","params":{"snapshot":{"worktrees":[
            {"id":"w","branch":"main","current":true,"sessions":[{"id":"s","agent":"claude","title":"T","state":"running"}]}]}}}));
        feed(&mut office, json!({"jsonrpc":"2.0","method":"tick","params":{"dt":66}}));
        let frames = test_host::take_frames();
        assert_eq!(frames.len(), 1);
        assert_eq!(frames[0].1, layout::ROOM_W as u32);
        feed(&mut office, json!({"jsonrpc":"2.0","method":"canvas/click","params":{"tab":0,"region":"r0"}}));
        let sent = test_host::take_sent();
        assert!(sent.iter().any(|m| m["method"] == "canvas/regions"));
        assert!(sent.iter().any(|m| m["method"] == "session/focus" && m["params"]["id"] == "s"));
    }

    /// Review focus 4 (plugin side).
    #[test]
    fn an_error_reply_is_logged_and_ignored() {
        test_host::take_sent();
        let mut office = Office::default();
        feed(&mut office, json!({"jsonrpc":"2.0","id":7,"error":{"code":-32003,"message":"unknown session s"}}));
        let sent = test_host::take_sent();
        assert_eq!(sent[0]["params"]["level"], "warn");
    }
}
