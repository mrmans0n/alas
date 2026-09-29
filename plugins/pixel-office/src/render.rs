//! Background layer (room, desks, labels) cached and rebuilt only when the layout's
//! look changes; each frame restores the background under last frame's sprites and
//! draws them again. Must be pixel-identical to a full redraw.

use crate::atlas::{self, *};
use crate::canvas::{text_width, Canvas, Rect, Rgba, GLYPH_W};
use crate::layout::{Layout, COUCH_SPOTS, DOOR, LOUNGE, ROOM_W};
use crate::look;
use crate::sim::{Activity, Mood, World};
use crate::sprites::{Sheet, CHARACTERS, FURNITURE, OVERLAYS, PALETTE};
use alas_plugin::Region;

const LABEL: Rgba = [232, 232, 240, 255];
const BAR_FILL: usize = 20;
/// Monitors sit above the seated character so the screen shows over its head.
const MONITOR_RISE: i32 = 8;

pub struct Renderer {
    background: Canvas,
    frame: Canvas,
    background_key: Option<String>,
    previous: Vec<Rect>,
}

impl Default for Renderer {
    fn default() -> Self {
        Renderer { background: Canvas::new(0, 0), frame: Canvas::new(0, 0), background_key: None, previous: Vec::new() }
    }
}

fn draw(canvas: &mut Canvas, sheet: &Sheet, src: Rect, x: i32, y: i32) -> Rect {
    canvas.blit(sheet, src, x, y, &PALETTE, false, false);
    Rect::new(x, y, src.w, src.h)
}

/// Everything the background depends on, so any change rebuilds it.
fn background_key(layout: &Layout) -> String {
    let pods: Vec<String> = layout
        .pods
        .iter()
        .map(|p| format!("{}|{}|{}|{}|{}", p.branch, p.lamp_on, p.papers, p.warning, p.overflow))
        .collect();
    format!("{}#{}#{}", layout.height, layout.hidden_worktrees, pods.join(";"))
}

fn draw_background(layout: &Layout) -> Canvas {
    let mut c = Canvas::new(ROOM_W as usize, layout.height as usize);
    for y in (0..layout.height).step_by(16) {
        for x in (0..ROOM_W).step_by(16) {
            draw(&mut c, &FURNITURE, if y < 24 { WALL } else { FLOOR }, x, y);
        }
    }
    draw(&mut c, &FURNITURE, atlas::DOOR, DOOR.0 - 8, 8);
    draw(&mut c, &FURNITURE, COFFEE, LOUNGE[0].0 - 16, 16);
    draw(&mut c, &FURNITURE, COOLER, LOUNGE[2].0 - 16, 16);
    draw(&mut c, &FURNITURE, COUCH, COUCH_SPOTS[0].0, 36);
    draw(&mut c, &FURNITURE, PLANT, ROOM_W - 20, 8);
    for pod in &layout.pods {
        for &(sx, sy) in &pod.seats {
            draw(&mut c, &FURNITURE, CHAIR, sx, sy + 10);
        }
        draw(&mut c, &FURNITURE, DESK, pod.desk.x, pod.desk.y);
        draw(&mut c, &FURNITURE, if pod.lamp_on { LAMP_ON } else { LAMP_OFF }, pod.desk.x + pod.desk.w, pod.desk.y - 4);
        if pod.papers > 0 {
            draw(&mut c, &OVERLAYS, PAPERS[pod.papers as usize - 1], pod.desk.x + pod.desk.w - 16, pod.desk.y);
        }
        if pod.warning {
            draw(&mut c, &OVERLAYS, WARNING, pod.desk.x - 6, pod.desk.y);
        }
        c.text(pod.desk.x - 4, pod.desk.y + 17, &fit(&pod.branch, pod.desk.w + 8), LABEL);
        if pod.overflow > 0 {
            c.text(pod.desk.x + 2, pod.desk.y + 9, &format!("+{}", pod.overflow), LABEL);
        }
    }
    if layout.hidden_worktrees > 0 {
        draw(&mut c, &FURNITURE, SIGN, DOOR.0 + 12, 4);
        c.text(DOOR.0 + 14, 9, &format!("+{} more", layout.hidden_worktrees), LABEL);
    }
    c
}

/// Cuts `text` to `max` pixels; the 4x6 font has no ellipsis, so '~' marks truncation.
fn fit(text: &str, max: i32) -> String {
    if text_width(text) <= max {
        return text.to_string();
    }
    let keep = (max / GLYPH_W - 1).max(0) as usize;
    text.chars().take(keep).chain(Some('~')).collect()
}

impl Renderer {
    pub fn render(&mut self, world: &World, layout: &Layout) -> &Canvas {
        let key = background_key(layout);
        if self.background_key.as_ref() != Some(&key) {
            self.background = draw_background(layout);
            self.frame = Canvas::new(self.background.width, self.background.height);
            self.frame.pixels.copy_from_slice(&self.background.pixels);
            self.background_key = Some(key);
        } else {
            for r in std::mem::take(&mut self.previous) {
                self.frame.copy_from(&self.background, r);
            }
        }
        self.previous = draw_sprites(&mut self.frame, world, layout);
        &self.frame
    }
}

/// Draws the dynamic layer and returns every rect it touched.
fn draw_sprites(c: &mut Canvas, world: &World, layout: &Layout) -> Vec<Rect> {
    let mut touched = Vec::new();
    let flicker = (world.clock_ms / 250 % 2) as usize;
    for pod in &layout.pods {
        for (i, id) in pod.seated.iter().enumerate() {
            let working = world.characters.iter().any(|ch| &ch.session_id == id && ch.mood == Mood::Working && ch.activity == Activity::Seated);
            let (sx, sy) = pod.seats[i];
            let src = if working { MONITOR_ON[flicker] } else { MONITOR_OFF };
            touched.push(draw(c, &FURNITURE, src, sx, sy - MONITOR_RISE));
        }
    }
    let mut order: Vec<_> = world.characters.iter().collect();
    order.sort_by_key(|ch| (ch.y as i32, ch.session_id.clone()));
    for ch in order {
        let (x, y) = (ch.x.round() as i32, ch.y.round() as i32);
        let frame = (ch.walk_ms / 150 % 4) as i32;
        let src = match (ch.activity, ch.mood) {
            (Activity::Walking, _) => walk([WALK_UP, WALK_RIGHT, WALK_DOWN][(ch.vertical + 1) as usize], frame),
            (Activity::Sleeping, _) => SLEEP,
            (Activity::Seated, Mood::Working) => TYPE[(ch.walk_ms / 200 % 2) as usize],
            (Activity::Seated, Mood::Waiting | Mood::Permission) => HAND,
            _ => SIT,
        };
        let palette = look::for_session(&ch.session_id, &ch.agent).palette;
        c.blit(&CHARACTERS, src, x, y, &palette, ch.facing_left, ch.mood == Mood::Unknown);
        touched.push(Rect::new(x, y, CHAR_W, CHAR_H));
        let bob = (world.clock_ms / 400 % 2) as i32;
        let overlay = match (ch.activity, ch.mood) {
            (Activity::Seated, Mood::Waiting) => Some(BUBBLE_Q),
            (Activity::Seated, Mood::Permission) => Some(BUBBLE_BANG[(world.clock_ms / 300 % 2) as usize]),
            (Activity::Sleeping, _) => Some(ZZ),
            _ => None,
        };
        // Sleepers lie low in their 16x24 cell, so their Zs start just above the body.
        let lift = if ch.activity == Activity::Sleeping { 2 } else { 14 };
        if let Some(src) = overlay {
            touched.push(draw(c, &OVERLAYS, src, x + 8, y - lift - bob));
        }
        if let (Activity::Seated, Mood::Working, Some(plan)) = (ch.activity, ch.mood, ch.plan) {
            if plan.total > 0 {
                let r = draw(c, &OVERLAYS, BAR_FRAME, x, y - 12);
                let filled = (14 * plan.completed.min(plan.total) / plan.total) as i32;
                c.fill(Rect::new(x + 1, y - 11, filled, 2), PALETTE[BAR_FILL]);
                touched.push(r);
            }
        }
    }
    touched
}

pub enum Target {
    Session(String),
    Worktree(String),
}

/// Region ids are short indexes ("r0", "r1", …) because Alas bounds ids to 64 bytes and
/// worktree ids can be long; `Target` at the same index says what a click means.
pub fn regions(world: &World, layout: &Layout) -> (Vec<Region>, Vec<Target>) {
    let mut regions = Vec::new();
    let mut targets = Vec::new();
    for ch in world.characters.iter().filter(|c| !c.leaving) {
        regions.push(Region {
            id: format!("r{}", regions.len()),
            label: format!("{}: {}, {}", ch.agent, ch.title, ch.mood.words()),
            rect: [ch.x.round() as i32, ch.y.round() as i32, CHAR_W, CHAR_H],
        });
        targets.push(Target::Session(ch.session_id.clone()));
    }
    for pod in &layout.pods {
        let mut label = format!("Worktree {}", pod.branch);
        if let Some(files) = pod.files {
            label += &format!(", {files} changed files");
        }
        if pod.warning {
            label += ", conflicts";
        }
        regions.push(Region {
            id: format!("r{}", regions.len()),
            label,
            rect: [pod.desk.x, pod.desk.y, pod.desk.w, pod.desk.h],
        });
        targets.push(Target::Worktree(pod.worktree_id.clone()));
    }
    (regions, targets)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::layout::{layout, tests::snapshot};

    #[test]
    fn incremental_frames_match_a_full_redraw() {
        let mut s = snapshot(&[2, 1, 0, 3, 1]);
        s.worktrees[0].sessions[1].state = "idle".into();
        s.worktrees[1].sessions[0].state = "awaiting_input".into();
        s.worktrees[3].sessions[2].state = "permission_request".into();
        let l = layout(&s);
        let mut world = World::default();
        world.sync(&s, &l);
        let mut incremental = Renderer::default();
        for step in 0..400 {
            world.step(66, &l);
            if step == 200 {
                s.worktrees[0].sessions.pop();
                world.sync(&s, &layout(&s));
            }
            let l = layout(&s);
            let got = incremental.render(&world, &l).pixels.clone();
            let expected = Renderer::default().render(&world, &l).pixels.clone();
            assert!(got == expected, "frame {step} differs from a full redraw");
        }
    }

    #[test]
    fn long_branch_labels_are_cut_with_a_tilde() {
        assert_eq!(fit("main", 72), "main");
        assert_eq!(fit("feature/a-really-long", 72), "feature/a-really-~");
        assert_eq!(text_width(&fit("feature/a-really-long", 72)), 72);
    }

    #[test]
    fn regions_label_characters_and_desks() {
        let s = snapshot(&[1]);
        let l = layout(&s);
        let mut world = World::default();
        world.sync(&s, &l);
        let (regions, targets) = regions(&world, &l);
        assert_eq!(regions[0].label, "claude: T0, working");
        assert!(matches!(&targets[0], Target::Session(id) if id == "w0s0"));
        assert_eq!(regions[1].label, "Worktree b0");
        assert!(matches!(&targets[1], Target::Worktree(id) if id == "w0"));
    }
}
