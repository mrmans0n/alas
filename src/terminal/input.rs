use gpui::{KeyDownEvent, Keystroke};

/// Translate a GPUI key-down event into bytes to send to a terminal PTY.
///
/// This intentionally handles only key-down data GPUI exposes directly. Text
/// composition/IME and full function-key coverage should be routed through a
/// richer terminal input layer if Alas adopts one later.
pub fn terminal_input_bytes(event: &KeyDownEvent) -> Option<Vec<u8>> {
    terminal_input_bytes_for_keystroke(&event.keystroke)
}

fn terminal_input_bytes_for_keystroke(keystroke: &Keystroke) -> Option<Vec<u8>> {
    if keystroke.modifiers.platform {
        return None;
    }

    if keystroke.modifiers.alt {
        return alt_input_bytes(keystroke);
    }

    unmodified_or_control_input_bytes(keystroke)
}

fn alt_input_bytes(keystroke: &Keystroke) -> Option<Vec<u8>> {
    let mut without_alt = keystroke.clone();
    without_alt.modifiers.alt = false;

    // For Option/Alt character keys, GPUI exposes `key` as the ASCII-equivalent
    // key and `key_char` as the composed text (for example option-s -> `ß` on
    // macOS). Terminals usually expect Meta/Alt as ESC plus the underlying key,
    // so prefer `key` for single-character Alt input.
    if !without_alt.modifiers.control && without_alt.key.chars().count() == 1 {
        without_alt.key_char = Some(without_alt.key.clone());
    }

    let mut bytes = unmodified_or_control_input_bytes(&without_alt)?;
    bytes.insert(0, 0x1b);
    Some(bytes)
}

fn unmodified_or_control_input_bytes(keystroke: &Keystroke) -> Option<Vec<u8>> {
    if keystroke.modifiers.control {
        let key = keystroke.key.to_ascii_lowercase();
        if key.len() == 1 {
            let byte = key.as_bytes()[0];
            if byte.is_ascii_lowercase() {
                return Some(vec![byte - b'a' + 1]);
            }
        }
        return None;
    }

    match keystroke.key.as_str() {
        "enter" => Some(b"\r".to_vec()),
        "backspace" => Some(vec![0x7f]),
        "delete" => Some(b"\x1b[3~".to_vec()),
        "tab" => Some(b"\t".to_vec()),
        "escape" => Some(vec![0x1b]),
        "up" => Some(b"\x1b[A".to_vec()),
        "down" => Some(b"\x1b[B".to_vec()),
        "right" => Some(b"\x1b[C".to_vec()),
        "left" => Some(b"\x1b[D".to_vec()),
        _ => keystroke
            .key_char
            .as_ref()
            .map(|text| text.as_bytes().to_vec()),
    }
}
