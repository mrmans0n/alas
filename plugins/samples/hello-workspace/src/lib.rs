//! Minimal Alas plugin (API 1). Logs a summary of the project's worktrees and
//! agent sessions, and deliberately calls `worktree/switch` without the
//! capability to show the denial path.

use alas_plugin::{export_plugin, log, request, request_snapshot, Event, Plugin, Snapshot};
use serde_json::json;

#[derive(Default)]
struct Hello {
    switch_request: i64,
}

fn summary(snapshot: &Snapshot) -> String {
    let sessions: Vec<_> = snapshot.worktrees.iter().flat_map(|w| &w.sessions).collect();
    let running = sessions.iter().filter(|s| s.state == "running").count();
    format!("{} worktrees, {} sessions ({} running)", snapshot.worktrees.len(), sessions.len(), running)
}

impl Plugin for Hello {
    fn handle(&mut self, event: Event) {
        match event {
            Event::Activate { project_name, .. } => {
                log("info", &format!("activated for {project_name}"));
                request_snapshot();
                self.switch_request = request("worktree/switch", json!({"id": "any"}));
            }
            Event::WorkspaceChanged(snapshot) => log("info", &format!("changed: {}", summary(&snapshot))),
            Event::Snapshot(snapshot) => log("info", &format!("snapshot: {}", summary(&snapshot))),
            Event::Reply { id, result: Err(error), .. } if id == self.switch_request => {
                log("warn", &format!("worktree/switch replied {} {}", error.code, error.message));
            }
            _ => {}
        }
    }
}

export_plugin!(Hello);
