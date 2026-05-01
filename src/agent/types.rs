use std::{
    path::PathBuf,
    sync::atomic::{AtomicU64, Ordering},
    time::{SystemTime, UNIX_EPOCH},
};

use serde::{Deserialize, Serialize};

use super::AgentAuthStatus;

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum AgentTrustMode {
    #[default]
    AllowEverything,
    Ask,
    WorktreeOnly,
    Deny,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct AgentThreadState {
    #[serde(default = "new_agent_thread_id")]
    pub thread_id: String,
    pub provider_id: String,
    pub acp_session_id: Option<String>,
    pub worktree_path: PathBuf,
    pub title: String,
    pub status: AgentThreadStatus,
    #[serde(default)]
    pub auth_status: AgentAuthStatus,
    pub transcript: Vec<AgentTranscriptEntry>,
    pub tool_calls: Vec<AgentToolCallState>,
    pub plans: Vec<AgentPlanState>,
    pub pending_permissions: Vec<AgentPermissionRequest>,
    pub available_commands: Vec<AgentSlashCommand>,
    pub available_modes: Vec<AgentModeOption>,
    pub current_mode: Option<String>,
    pub config_options: Vec<AgentConfigOption>,
    pub draft: String,
    pub resume: AgentResumeState,
    pub debug_log: Vec<AgentDebugEvent>,
}

fn new_agent_thread_id() -> String {
    static NEXT_THREAD_ID: AtomicU64 = AtomicU64::new(1);
    let sequence = NEXT_THREAD_ID.fetch_add(1, Ordering::Relaxed);
    let millis = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis())
        .unwrap_or_default();
    format!("agent-thread-{millis}-{sequence}")
}

const MAX_DEBUG_LOG_ENTRIES: usize = 500;

pub fn redact_debug_value(key: &str, value: &str) -> String {
    if is_sensitive_debug_key(key) {
        "[redacted]".to_string()
    } else {
        value.to_string()
    }
}

pub fn redact_debug_message(message: &str) -> String {
    let mut redacted = String::with_capacity(message.len());
    let mut index = 0;

    while index < message.len() {
        let Some((key_start, key)) = next_debug_key(message, index) else {
            redacted.push_str(&message[index..]);
            break;
        };

        let key_end = key_start + key.len();
        let separator_start = next_debug_separator_start(message, key_end);

        let Some(separator) = message[separator_start..].chars().next() else {
            redacted.push_str(&message[index..]);
            break;
        };

        if is_sensitive_debug_key(key) && matches!(separator, '=' | ':') {
            let value_start = separator_start
                + separator.len_utf8()
                + message[separator_start + separator.len_utf8()..]
                    .char_indices()
                    .find(|(_, ch)| !ch.is_ascii_whitespace())
                    .map(|(offset, _)| offset)
                    .unwrap_or(message.len() - separator_start - separator.len_utf8());
            let (redacted_start, value_end) = debug_value_bounds(message, value_start);

            redacted.push_str(&message[index..redacted_start]);
            redacted.push_str("[redacted]");
            index = value_end;
        } else {
            redacted.push_str(&message[index..key_end]);
            index = key_end;
        }
    }

    redacted
}

fn is_sensitive_debug_key(key: &str) -> bool {
    let key = key.to_ascii_uppercase();
    key.contains("KEY")
        || key.contains("TOKEN")
        || key.contains("SECRET")
        || key.contains("PASSWORD")
}

fn next_debug_separator_start(message: &str, key_end: usize) -> usize {
    let mut cursor = key_end;

    if let Some((offset, quote)) = message[cursor..]
        .char_indices()
        .find(|(_, ch)| !ch.is_ascii_whitespace())
        .filter(|(_, ch)| matches!(ch, '"' | '\''))
    {
        cursor += offset + quote.len_utf8();
    }

    message[cursor..]
        .char_indices()
        .find(|(_, ch)| !ch.is_ascii_whitespace())
        .map(|(offset, _)| cursor + offset)
        .unwrap_or(message.len())
}

fn debug_value_bounds(message: &str, value_start: usize) -> (usize, usize) {
    let Some(quote) = message[value_start..]
        .chars()
        .next()
        .filter(|ch| matches!(ch, '"' | '\''))
    else {
        let value_end = message[value_start..]
            .char_indices()
            .find(|(_, ch)| ch.is_ascii_whitespace() || matches!(ch, ',' | ';'))
            .map(|(offset, _)| value_start + offset)
            .unwrap_or(message.len());
        return (value_start, value_end);
    };

    let redacted_start = value_start + quote.len_utf8();
    let value_end = quoted_debug_value_end(message, redacted_start, quote);

    (redacted_start, value_end)
}

fn quoted_debug_value_end(message: &str, start: usize, quote: char) -> usize {
    let mut escaped = false;

    for (offset, ch) in message[start..].char_indices() {
        if escaped {
            escaped = false;
            continue;
        }

        if ch == '\\' {
            escaped = true;
            continue;
        }

        if ch == quote {
            return start + offset;
        }
    }

    message.len()
}

fn next_debug_key(message: &str, start: usize) -> Option<(usize, &str)> {
    let mut key_start = None;

    for (offset, ch) in message[start..].char_indices() {
        let index = start + offset;
        if is_debug_key_char(ch) {
            key_start.get_or_insert(index);
        } else if let Some(found_start) = key_start {
            return Some((found_start, &message[found_start..index]));
        }
    }

    key_start.map(|found_start| (found_start, &message[found_start..]))
}

fn is_debug_key_char(ch: char) -> bool {
    ch.is_ascii_alphanumeric() || matches!(ch, '_' | '-')
}

impl AgentThreadState {
    pub fn new(provider_id: impl Into<String>, worktree_path: PathBuf) -> Self {
        Self {
            thread_id: new_agent_thread_id(),
            provider_id: provider_id.into(),
            acp_session_id: None,
            worktree_path,
            title: "Agent Chat".to_string(),
            status: AgentThreadStatus::Disconnected,
            auth_status: AgentAuthStatus::Unknown,
            transcript: Vec::new(),
            tool_calls: Vec::new(),
            plans: Vec::new(),
            pending_permissions: Vec::new(),
            available_commands: Vec::new(),
            available_modes: Vec::new(),
            current_mode: None,
            config_options: Vec::new(),
            draft: String::new(),
            resume: AgentResumeState::NotRestored,
            debug_log: Vec::new(),
        }
    }

    pub fn push_debug_event(&mut self, event: AgentDebugEvent) {
        if self.debug_log.len() >= MAX_DEBUG_LOG_ENTRIES {
            let excess = self.debug_log.len() + 1 - MAX_DEBUG_LOG_ENTRIES;
            self.debug_log.drain(0..excess);
        }
        self.debug_log.push(AgentDebugEvent {
            message: redact_debug_message(&event.message),
        });
    }
}

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum AgentThreadStatus {
    #[default]
    Disconnected,
    Starting,
    AuthRequired,
    Ready,
    Running,
    Failed {
        message: String,
    },
    ReadOnly {
        reason: String,
    },
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct AgentTranscriptEntry {
    pub role: AgentTranscriptRole,
    pub text: String,
}

impl AgentTranscriptEntry {
    pub fn user(text: impl Into<String>) -> Self {
        Self {
            role: AgentTranscriptRole::User,
            text: text.into(),
        }
    }

    pub fn agent(text: impl Into<String>) -> Self {
        Self {
            role: AgentTranscriptRole::Agent,
            text: text.into(),
        }
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum AgentTranscriptRole {
    User,
    Agent,
    Thought,
    System,
    Tool,
}

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
pub struct AgentToolCallState {
    pub id: String,
    pub title: String,
    pub status: String,
}

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
pub struct AgentPlanState {
    pub entries: Vec<String>,
}

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
pub struct AgentPermissionRequest {
    pub id: String,
    pub description: String,
}

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
pub struct AgentSlashCommand {
    pub name: String,
    pub description: Option<String>,
}

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
pub struct AgentModeOption {
    pub id: String,
    pub name: String,
}

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
pub struct AgentConfigValueOption {
    pub id: String,
    pub label: String,
}

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
pub struct AgentConfigOption {
    pub id: String,
    pub label: String,
    pub value: Option<String>,
    #[serde(default)]
    pub options: Vec<AgentConfigValueOption>,
}

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum AgentResumeState {
    #[default]
    NotRestored,
    Pending,
    Resumed,
    Unsupported,
    Failed {
        message: String,
    },
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct AgentDebugEvent {
    pub message: String,
}
