use crate::canvas::Rgba;
use crate::sprites::PALETTE;

pub fn hash(text: &str) -> u32 {
    text.bytes().fold(0x811c9dc5u32, |h, b| (h ^ b as u32).wrapping_mul(0x01000193))
}

type Ramp = [Rgba; 3];

const SKIN: [Ramp; 4] = [
    [[138, 90, 60, 255], [198, 138, 94, 255], [234, 178, 140, 255]],
    [[92, 58, 38, 255], [140, 92, 60, 255], [182, 128, 90, 255]],
    [[168, 120, 88, 255], [222, 170, 132, 255], [246, 208, 176, 255]],
    [[60, 38, 26, 255], [100, 66, 44, 255], [140, 98, 68, 255]],
];

const HAIR: [Ramp; 6] = [
    [[58, 42, 34, 255], [94, 67, 50, 255], [134, 100, 74, 255]],
    [[20, 20, 28, 255], [44, 44, 58, 255], [70, 70, 90, 255]],
    [[150, 90, 30, 255], [200, 130, 50, 255], [236, 180, 90, 255]],
    [[170, 60, 40, 255], [210, 90, 60, 255], [240, 140, 100, 255]],
    [[150, 150, 160, 255], [196, 196, 206, 255], [232, 232, 240, 255]],
    [[70, 40, 90, 255], [110, 70, 140, 255], [150, 110, 190, 255]],
];

const SHIRTS: [Ramp; 7] = [
    [[168, 76, 36, 255], [218, 112, 60, 255], [244, 156, 104, 255]],  // orange
    [[36, 100, 60, 255], [60, 150, 90, 255], [110, 200, 130, 255]],   // green
    [[42, 58, 110, 255], [62, 86, 160, 255], [106, 134, 204, 255]],   // blue
    [[90, 50, 130, 255], [130, 80, 180, 255], [176, 130, 220, 255]],  // purple
    [[70, 70, 80, 255], [110, 110, 124, 255], [160, 160, 176, 255]],  // grey
    [[30, 110, 120, 255], [50, 160, 170, 255], [110, 210, 214, 255]], // teal
    [[150, 50, 90, 255], [210, 80, 130, 255], [240, 140, 180, 255]],  // pink
];

fn shirt_for(agent: &str) -> usize {
    match agent {
        "claude" => 0,
        "codex" => 1,
        "gemini" => 2,
        "copilot" => 3,
        "cursor" => 4,
        "opencode" => 5,
        "pi" => 6,
        other => hash(other) as usize % SHIRTS.len(),
    }
}

pub struct Look {
    pub palette: [Rgba; 25],
}

/// Same session, same look: skin and hair from the session id, shirt from the agent.
pub fn for_session(session_id: &str, agent: &str) -> Look {
    let h = hash(session_id);
    let mut palette = PALETTE;
    let ramps = [SKIN[h as usize % SKIN.len()], HAIR[(h >> 8) as usize % HAIR.len()], SHIRTS[shirt_for(agent)]];
    for (r, ramp) in ramps.iter().enumerate() {
        palette[1 + r * 3..4 + r * 3].copy_from_slice(ramp);
    }
    Look { palette }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn looks_are_stable_per_session_and_shirts_follow_the_agent() {
        assert_eq!(for_session("s1", "codex").palette, for_session("s1", "codex").palette);
        assert_eq!(for_session("a", "claude").palette[7..10], SHIRTS[0]);
        assert_eq!(for_session("b", "claude").palette[7..10], SHIRTS[0]);
        assert_eq!(for_session("a", "claude").palette[10..], PALETTE[10..], "fixed colours never change");
    }
}
