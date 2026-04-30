#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum HarnessKind {
    ClaudeCode,
    Codex,
}

impl HarnessKind {
    pub fn display_name(self) -> &'static str {
        match self {
            Self::ClaudeCode => "Claude Code",
            Self::Codex => "Codex",
        }
    }
}
