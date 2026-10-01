//! Who is where. Deterministic given the snapshot sequence and tick deltas.

use crate::layout::{aisle_y, Layout, COUCH_SPOTS, DOOR, LOUNGE, SIDE_X};
use crate::look::hash;
use alas_plugin::{Plan, Snapshot};

pub const WALK_SPEED: f32 = 32.0;
pub const SLEEP_AFTER_MS: u32 = 300_000;
const DWELL_MIN_MS: u32 = 8_000;
const DWELL_MAX_MS: u32 = 20_000;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mood {
    Working,
    Waiting,
    Permission,
    Idle,
    Unknown,
}

impl Mood {
    pub fn from_state(state: &str) -> Mood {
        match state {
            "running" => Mood::Working,
            "awaiting_input" => Mood::Waiting,
            "permission_request" => Mood::Permission,
            "idle" => Mood::Idle,
            _ => Mood::Unknown,
        }
    }

    pub fn words(self) -> &'static str {
        match self {
            Mood::Working => "working",
            Mood::Waiting => "awaiting input",
            Mood::Permission => "needs permission",
            Mood::Idle => "idle",
            Mood::Unknown => "unknown",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Activity {
    Walking,
    Seated,
    Lounging,
    Sleeping,
}

#[derive(Debug, Clone)]
pub struct Character {
    pub session_id: String,
    pub agent: String,
    pub title: String,
    pub mood: Mood,
    pub plan: Option<Plan>,
    pub x: f32,
    pub y: f32,
    pub activity: Activity,
    pub facing_left: bool,
    /// -1 walking up, 1 walking down, 0 walking sideways; picks the walk row.
    pub vertical: i8,
    /// Drives walk and typing frames.
    pub walk_ms: u32,
    pub leaving: bool,
    seat: (i32, i32),
    path: Vec<(f32, f32)>,
    /// What to become on arrival.
    arrive_as: Activity,
    idle_ms: u32,
    dwell_ms: u32,
    rng: u32,
}

impl Character {
    fn next_random(&mut self) -> u32 {
        // xorshift32; seeded from the session id so routines are reproducible.
        self.rng ^= self.rng << 13;
        self.rng ^= self.rng >> 17;
        self.rng ^= self.rng << 5;
        self.rng
    }

    fn dwell(&mut self) -> u32 {
        DWELL_MIN_MS + self.next_random() % (DWELL_MAX_MS - DWELL_MIN_MS)
    }

    /// Door -> corridor -> row aisle -> target, as straight segments.
    fn walk_to(&mut self, target: (i32, i32), arrive_as: Activity) {
        let (tx, ty) = (target.0 as f32, target.1 as f32);
        let here = aisle_y(self.y as i32) as f32;
        let there = aisle_y(target.1) as f32;
        self.path = if here == there {
            vec![(self.x, here), (tx, there), (tx, ty)]
        } else {
            vec![(self.x, here), (SIDE_X as f32, here), (SIDE_X as f32, there), (tx, there), (tx, ty)]
        };
        self.activity = Activity::Walking;
        self.arrive_as = arrive_as;
    }

    fn wants_seat(&self) -> bool {
        self.mood != Mood::Idle
    }
}

#[derive(Default)]
pub struct World {
    pub characters: Vec<Character>,
    pub clock_ms: u64,
}

impl World {
    /// Adds arrivals, sends departures to the door, and re-routes anyone whose mood or seat changed.
    pub fn sync(&mut self, snapshot: &Snapshot, layout: &Layout) {
        for pod in &layout.pods {
            let worktree = snapshot.worktrees.iter().find(|w| w.id == pod.worktree_id).unwrap();
            for (seat_index, session_id) in pod.seated.iter().enumerate() {
                let session = worktree.sessions.iter().find(|s| &s.id == session_id).unwrap();
                let seat = pod.seats[seat_index];
                let mood = Mood::from_state(&session.state);
                match self.characters.iter_mut().find(|c| &c.session_id == session_id && !c.leaving) {
                    Some(c) => {
                        c.title = session.title.clone();
                        c.plan = session.plan;
                        if c.mood != mood || c.seat != seat {
                            if mood != Mood::Idle {
                                c.idle_ms = 0;
                            }
                            c.mood = mood;
                            c.seat = seat;
                            reroute(c);
                        }
                    }
                    None => {
                        let mut c = Character {
                            session_id: session_id.clone(),
                            agent: session.agent.clone(),
                            title: session.title.clone(),
                            mood,
                            plan: session.plan,
                            x: DOOR.0 as f32,
                            y: DOOR.1 as f32,
                            activity: Activity::Walking,
                            facing_left: false,
                            vertical: 0,
                            walk_ms: 0,
                            leaving: false,
                            seat,
                            path: Vec::new(),
                            arrive_as: Activity::Seated,
                            idle_ms: 0,
                            dwell_ms: 0,
                            rng: hash(session_id) | 1,
                        };
                        c.walk_to(seat, Activity::Seated);
                        self.characters.push(c);
                    }
                }
            }
        }
        let present: Vec<&String> = layout.pods.iter().flat_map(|p| &p.seated).collect();
        for c in self.characters.iter_mut().filter(|c| !c.leaving && !present.contains(&&c.session_id)) {
            c.leaving = true;
            // Any non-walking arrival state works: `step` drops leavers once they stop walking.
            c.walk_to(DOOR, Activity::Seated);
        }
    }

    /// `_layout` is unused today; it is part of the signature so seats can move without an API change.
    pub fn step(&mut self, dt_ms: u32, _layout: &Layout) {
        self.clock_ms += dt_ms as u64;
        for i in 0..self.characters.len() {
            let taken = taken_spots(&self.characters);
            let c = &mut self.characters[i];
            c.walk_ms = c.walk_ms.wrapping_add(dt_ms);
            if c.mood == Mood::Idle && !c.leaving {
                c.idle_ms = c.idle_ms.saturating_add(dt_ms);
            }
            advance(c, dt_ms);
            if c.activity == Activity::Walking {
                continue;
            }
            if c.mood == Mood::Idle && !c.leaving {
                if c.idle_ms >= SLEEP_AFTER_MS && c.activity != Activity::Sleeping {
                    let spot = pick_spot(c, &COUCH_SPOTS, &taken);
                    c.walk_to(spot, Activity::Sleeping);
                    continue;
                }
                if c.activity == Activity::Sleeping {
                    continue;
                }
                c.dwell_ms = c.dwell_ms.saturating_sub(dt_ms);
                if c.dwell_ms == 0 {
                    if c.activity == Activity::Lounging && c.next_random().is_multiple_of(2) {
                        let seat = c.seat;
                        c.walk_to(seat, Activity::Seated);
                    } else {
                        let spot = pick_spot(c, &LOUNGE, &taken);
                        c.walk_to(spot, Activity::Lounging);
                    }
                }
            }
        }
        self.characters.retain(|c| !(c.leaving && c.activity != Activity::Walking));
    }
}

/// Where every non-leaving character is, or is heading to.
fn taken_spots(characters: &[Character]) -> Vec<(i32, i32)> {
    characters
        .iter()
        .filter(|c| !c.leaving)
        .map(|c| match (c.activity, c.path.last()) {
            (Activity::Walking, Some(&(x, y))) => (x as i32, y as i32),
            _ => (c.x as i32, c.y as i32),
        })
        .collect()
}

/// A random spot nobody occupies or is heading to; any spot if all are taken.
fn pick_spot(c: &mut Character, spots: &[(i32, i32)], taken: &[(i32, i32)]) -> (i32, i32) {
    let free: Vec<_> = spots.iter().copied().filter(|s| !taken.contains(s)).collect();
    let pool = if free.is_empty() { spots } else { &free };
    pool[c.next_random() as usize % pool.len()]
}

fn reroute(c: &mut Character) {
    if c.wants_seat() {
        if c.activity == Activity::Seated && (c.x, c.y) == (c.seat.0 as f32, c.seat.1 as f32) {
            return; // already at the desk: busy moods just change the pose
        }
        let seat = c.seat;
        c.walk_to(seat, Activity::Seated);
    } else {
        // Newly idle: stay put for one dwell, then start wandering.
        c.dwell_ms = c.dwell();
        if c.activity == Activity::Walking {
            let seat = c.seat;
            c.walk_to(seat, Activity::Seated);
        }
    }
}

fn advance(c: &mut Character, dt_ms: u32) {
    let mut budget = WALK_SPEED * dt_ms as f32 / 1000.0;
    while budget > 0.0 {
        let Some(&(tx, ty)) = c.path.first() else { break };
        let (dx, dy) = (tx - c.x, ty - c.y);
        let distance = (dx * dx + dy * dy).sqrt();
        if dx != 0.0 {
            c.facing_left = dx < 0.0;
        }
        c.vertical = if dx.abs() >= dy.abs() { 0 } else if dy < 0.0 { -1 } else { 1 };
        if distance <= budget {
            (c.x, c.y) = (tx, ty);
            budget -= distance;
            c.path.remove(0);
        } else {
            c.x += dx / distance * budget;
            c.y += dy / distance * budget;
            budget = 0.0;
        }
    }
    if c.path.is_empty() && c.activity == Activity::Walking {
        c.activity = c.arrive_as;
        if c.activity == Activity::Lounging || (c.activity == Activity::Seated && c.mood == Mood::Idle) {
            c.dwell_ms = c.dwell();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::layout::{layout, tests::snapshot};

    fn settle(world: &mut World, l: &Layout, ms: u32) {
        for _ in 0..ms / 100 {
            world.step(100, l);
        }
    }

    fn with_state(mut s: Snapshot, state: &str) -> Snapshot {
        s.worktrees[0].sessions[0].state = state.into();
        s
    }

    #[test]
    fn a_new_session_walks_in_from_the_door_and_sits_down() {
        let s = snapshot(&[1]);
        let l = layout(&s);
        let mut world = World::default();
        world.sync(&s, &l);
        let c = &world.characters[0];
        assert_eq!((c.x, c.y, c.activity), (DOOR.0 as f32, DOOR.1 as f32, Activity::Walking));
        settle(&mut world, &l, 20_000);
        let c = &world.characters[0];
        assert_eq!(c.activity, Activity::Seated);
        assert_eq!((c.x as i32, c.y as i32), l.pods[0].seats[0]);
    }

    #[test]
    fn busy_moods_stay_seated_and_idle_wanders_to_the_lounge() {
        for (state, busy) in [("running", true), ("awaiting_input", true), ("permission_request", true), ("unknown", true), ("idle", false)] {
            let s = with_state(snapshot(&[1]), state);
            let l = layout(&s);
            let mut world = World::default();
            world.sync(&s, &l);
            settle(&mut world, &l, 20_000); // walk in from the door
            let mut seen = Vec::new();
            for _ in 0..600 {
                world.step(100, &l); // one more minute
                seen.push(world.characters[0].activity);
            }
            if busy {
                assert!(seen.iter().all(|a| *a == Activity::Seated), "{state} left its seat");
            } else {
                assert!(seen.contains(&Activity::Lounging), "idle never reached the lounge");
                assert!(!seen.contains(&Activity::Sleeping), "idle for a minute should not sleep yet");
            }
        }
    }

    #[test]
    fn five_idle_minutes_end_asleep_on_the_couch() {
        let s = with_state(snapshot(&[1]), "idle");
        let l = layout(&s);
        let mut world = World::default();
        world.sync(&s, &l);
        settle(&mut world, &l, SLEEP_AFTER_MS + 30_000);
        let c = &world.characters[0];
        assert_eq!(c.activity, Activity::Sleeping);
        assert!(COUCH_SPOTS.contains(&(c.x as i32, c.y as i32)));
        // Waking: any busy state sends it back to the desk.
        let busy = snapshot(&[1]);
        world.sync(&busy, &l);
        settle(&mut world, &l, 30_000);
        assert_eq!(world.characters[0].activity, Activity::Seated);
    }

    #[test]
    fn an_ended_session_walks_out_and_disappears() {
        let s = snapshot(&[1]);
        let l = layout(&s);
        let mut world = World::default();
        world.sync(&s, &l);
        settle(&mut world, &l, 20_000);
        let empty = snapshot(&[0]);
        let l2 = layout(&empty);
        world.sync(&empty, &l2);
        assert!(world.characters[0].leaving);
        settle(&mut world, &l2, 30_000);
        assert!(world.characters.is_empty());
    }

    #[test]
    fn a_seated_agent_stays_put_when_its_busy_mood_changes() {
        let l = layout(&snapshot(&[1]));
        let mut world = World::default();
        world.sync(&snapshot(&[1]), &l);
        settle(&mut world, &l, 20_000);
        for state in ["awaiting_input", "permission_request", "running", "unknown"] {
            world.sync(&with_state(snapshot(&[1]), state), &l);
            for _ in 0..50 {
                world.step(100, &l);
                assert_eq!(world.characters[0].activity, Activity::Seated, "{state}");
            }
        }
    }

    #[test]
    fn idlers_never_share_a_lounge_spot() {
        let mut s = snapshot(&[2]); // the couch has two spots
        for session in &mut s.worktrees[0].sessions {
            session.state = "idle".into();
        }
        let l = layout(&s);
        let mut world = World::default();
        world.sync(&s, &l);
        for _ in 0..4_000 {
            world.step(100, &l);
            let mut spots: Vec<_> = world
                .characters
                .iter()
                .filter(|c| c.activity == Activity::Lounging || c.activity == Activity::Sleeping)
                .map(|c| (c.x as i32, c.y as i32))
                .collect();
            let n = spots.len();
            spots.sort();
            spots.dedup();
            assert_eq!(spots.len(), n, "two characters share a spot");
        }
    }
}
