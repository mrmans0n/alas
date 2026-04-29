use anyhow::Context;
use libghostty_vt::{
    Terminal,
    key::{Action, Encoder, Event, Key, Mods},
    terminal::Mode,
};

use super::terminal_input_bytes;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PasteMode {
    Plain,
    Bracketed,
}

impl PasteMode {
    pub fn from_bracketed_enabled(enabled: bool) -> Self {
        if enabled {
            Self::Bracketed
        } else {
            Self::Plain
        }
    }
}

pub fn normalize_paste_text(text: &str) -> String {
    text.replace("\r\n", "\n").replace('\r', "\n")
}

pub fn paste_bytes(text: &str, mode: PasteMode) -> Vec<u8> {
    let normalized = normalize_paste_text(text);
    match mode {
        PasteMode::Plain => normalized.into_bytes(),
        PasteMode::Bracketed => {
            let mut bytes =
                Vec::with_capacity("\x1b[200~".len() + normalized.len() + "\x1b[201~".len());
            bytes.extend_from_slice(b"\x1b[200~");
            bytes.extend_from_slice(normalized.as_bytes());
            bytes.extend_from_slice(b"\x1b[201~");
            bytes
        }
    }
}

pub fn paste_mode_from_terminal(terminal: &Terminal<'_, '_>) -> anyhow::Result<PasteMode> {
    let bracketed = terminal
        .mode(Mode::BRACKETED_PASTE)
        .context("read Ghostty bracketed paste mode")?;
    Ok(PasteMode::from_bracketed_enabled(bracketed))
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct TerminalKeyModifiers {
    pub control: bool,
    pub alt: bool,
    pub shift: bool,
    pub platform: bool,
    pub function: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TerminalKeyInput {
    pub key: String,
    pub key_char: Option<String>,
    pub modifiers: TerminalKeyModifiers,
    pub is_held: bool,
    fallback_bytes: Option<Vec<u8>>,
}

impl TerminalKeyInput {
    pub fn new(
        key: impl Into<String>,
        key_char: Option<String>,
        modifiers: TerminalKeyModifiers,
        is_held: bool,
    ) -> Self {
        Self {
            key: key.into(),
            key_char,
            modifiers,
            is_held,
            fallback_bytes: None,
        }
    }

    pub fn with_fallback_bytes(mut self, fallback_bytes: Option<Vec<u8>>) -> Self {
        self.fallback_bytes = fallback_bytes;
        self
    }

    pub fn fallback_bytes(&self) -> Option<Vec<u8>> {
        self.fallback_bytes.clone()
    }
}

impl From<&gpui::KeyDownEvent> for TerminalKeyInput {
    fn from(event: &gpui::KeyDownEvent) -> Self {
        Self {
            key: event.keystroke.key.clone(),
            key_char: event.keystroke.key_char.clone(),
            modifiers: TerminalKeyModifiers {
                control: event.keystroke.modifiers.control,
                alt: event.keystroke.modifiers.alt,
                shift: event.keystroke.modifiers.shift,
                platform: event.keystroke.modifiers.platform,
                function: event.keystroke.modifiers.function,
            },
            is_held: event.is_held,
            fallback_bytes: terminal_input_bytes(event),
        }
    }
}

pub fn encode_key_input(
    terminal: &Terminal<'_, '_>,
    input: &TerminalKeyInput,
) -> anyhow::Result<Option<Vec<u8>>> {
    let event = match ghostty_key_event(input) {
        Ok(Some(event)) => event,
        Ok(None) => return Ok(input.fallback_bytes()),
        Err(error) => {
            if let Some(bytes) = input.fallback_bytes() {
                return Ok(Some(bytes));
            }
            return Err(error);
        }
    };

    let mut encoder = Encoder::new().context("create Ghostty key encoder")?;
    encoder.set_options_from_terminal(terminal);

    let mut bytes = Vec::new();
    if let Err(error) = encoder.encode_to_vec(&event, &mut bytes) {
        if let Some(bytes) = input.fallback_bytes() {
            return Ok(Some(bytes));
        }
        return Err(error).context("encode key input with Ghostty");
    }

    if bytes.is_empty() {
        Ok(input.fallback_bytes())
    } else {
        Ok(Some(bytes))
    }
}

pub fn ghostty_key_event(input: &TerminalKeyInput) -> anyhow::Result<Option<Event<'static>>> {
    let Some(key) = ghostty_key_for_input(&input.key) else {
        return Ok(None);
    };

    let mut event = Event::new().context("create Ghostty key event")?;
    event
        .set_action(if input.is_held {
            Action::Repeat
        } else {
            Action::Press
        })
        .set_key(key)
        .set_mods(ghostty_mods(&input.modifiers));

    if let Some(text) = ghostty_event_text(input) {
        event.set_utf8(Some(text));
    }
    if let Some(codepoint) = ghostty_unshifted_codepoint(&input.key) {
        event.set_unshifted_codepoint(codepoint);
    }

    Ok(Some(event))
}

fn ghostty_mods(modifiers: &TerminalKeyModifiers) -> Mods {
    let mut mods = Mods::empty();
    if modifiers.control {
        mods |= Mods::CTRL;
    }
    if modifiers.alt {
        mods |= Mods::ALT;
    }
    if modifiers.shift {
        mods |= Mods::SHIFT;
    }
    if modifiers.platform {
        mods |= Mods::SUPER;
    }
    mods
}

fn ghostty_event_text(input: &TerminalKeyInput) -> Option<String> {
    if input.modifiers.platform || input.modifiers.control || input.modifiers.function {
        return None;
    }

    if input.modifiers.alt && input.key.chars().count() == 1 {
        return Some(input.key.clone());
    }

    input.key_char.clone()
}

fn ghostty_unshifted_codepoint(key: &str) -> Option<char> {
    if key.chars().count() == 1 {
        key.chars().next()
    } else if key == "space" {
        Some(' ')
    } else {
        None
    }
}

fn ghostty_key_for_input(key: &str) -> Option<Key> {
    let normalized = key.to_ascii_lowercase();
    Some(match normalized.as_str() {
        "`" => Key::Backquote,
        "\\" => Key::Backslash,
        "[" => Key::BracketLeft,
        "]" => Key::BracketRight,
        "," => Key::Comma,
        "0" => Key::Digit0,
        "1" => Key::Digit1,
        "2" => Key::Digit2,
        "3" => Key::Digit3,
        "4" => Key::Digit4,
        "5" => Key::Digit5,
        "6" => Key::Digit6,
        "7" => Key::Digit7,
        "8" => Key::Digit8,
        "9" => Key::Digit9,
        "=" => Key::Equal,
        "a" => Key::A,
        "b" => Key::B,
        "c" => Key::C,
        "d" => Key::D,
        "e" => Key::E,
        "f" => Key::F,
        "g" => Key::G,
        "h" => Key::H,
        "i" => Key::I,
        "j" => Key::J,
        "k" => Key::K,
        "l" => Key::L,
        "m" => Key::M,
        "n" => Key::N,
        "o" => Key::O,
        "p" => Key::P,
        "q" => Key::Q,
        "r" => Key::R,
        "s" => Key::S,
        "t" => Key::T,
        "u" => Key::U,
        "v" => Key::V,
        "w" => Key::W,
        "x" => Key::X,
        "y" => Key::Y,
        "z" => Key::Z,
        "-" => Key::Minus,
        "." => Key::Period,
        "'" => Key::Quote,
        ";" => Key::Semicolon,
        "/" => Key::Slash,
        "backspace" => Key::Backspace,
        "enter" => Key::Enter,
        "space" => Key::Space,
        "tab" => Key::Tab,
        "delete" => Key::Delete,
        "escape" => Key::Escape,
        "end" => Key::End,
        "home" => Key::Home,
        "insert" => Key::Insert,
        "pageup" => Key::PageUp,
        "pagedown" => Key::PageDown,
        "down" => Key::ArrowDown,
        "left" => Key::ArrowLeft,
        "right" => Key::ArrowRight,
        "up" => Key::ArrowUp,
        "f1" => Key::F1,
        "f2" => Key::F2,
        "f3" => Key::F3,
        "f4" => Key::F4,
        "f5" => Key::F5,
        "f6" => Key::F6,
        "f7" => Key::F7,
        "f8" => Key::F8,
        "f9" => Key::F9,
        "f10" => Key::F10,
        "f11" => Key::F11,
        "f12" => Key::F12,
        "f13" => Key::F13,
        "f14" => Key::F14,
        "f15" => Key::F15,
        "f16" => Key::F16,
        "f17" => Key::F17,
        "f18" => Key::F18,
        "f19" => Key::F19,
        "f20" => Key::F20,
        "f21" => Key::F21,
        "f22" => Key::F22,
        "f23" => Key::F23,
        "f24" => Key::F24,
        "f25" => Key::F25,
        "menu" | "contextmenu" => Key::ContextMenu,
        "back" | "browserback" => Key::BrowserBack,
        "forward" | "browserforward" => Key::BrowserForward,
        "copy" => Key::Copy,
        "cut" => Key::Cut,
        "paste" => Key::Paste,
        _ => return None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bracketed_paste_wraps_normalized_text() {
        assert_eq!(
            paste_bytes("hello\r\nworld", PasteMode::Bracketed),
            b"\x1b[200~hello\nworld\x1b[201~"
        );
    }

    #[test]
    fn plain_paste_writes_normalized_text_directly() {
        assert_eq!(
            paste_bytes("hello\r\nworld", PasteMode::Plain),
            b"hello\nworld"
        );
    }

    #[test]
    fn paste_mode_uses_terminal_bracketed_paste_mode() {
        let mut terminal = libghostty_vt::Terminal::new(libghostty_vt::TerminalOptions {
            cols: 80,
            rows: 24,
            max_scrollback: 100,
        })
        .unwrap();

        assert_eq!(
            paste_mode_from_terminal(&terminal).unwrap(),
            PasteMode::Plain
        );

        terminal
            .set_mode(libghostty_vt::terminal::Mode::BRACKETED_PASTE, true)
            .unwrap();
        assert_eq!(
            paste_mode_from_terminal(&terminal).unwrap(),
            PasteMode::Bracketed
        );
    }

    #[test]
    fn ghostty_encoder_handles_navigation_and_function_keys_without_fallback() {
        let terminal = libghostty_vt::Terminal::new(libghostty_vt::TerminalOptions {
            cols: 80,
            rows: 24,
            max_scrollback: 100,
        })
        .unwrap();

        for key in ["home", "end", "insert", "pageup", "pagedown", "f1", "f12"] {
            let bytes = encode_key_input(
                &terminal,
                &TerminalKeyInput::new(key, None, TerminalKeyModifiers::default(), false),
            )
            .unwrap();
            assert!(
                bytes.is_some_and(|bytes| !bytes.is_empty()),
                "expected Ghostty to encode {key}"
            );
        }
    }
}
