use serde_json::Value;

use crate::app::TerminalTabId;
use crate::terminal::HarnessKind;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum HookProvider {
    ClaudeCode,
    Codex,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum HarnessCompletionSource {
    ClaudeCodeStop,
    ClaudeCodeSubagentStop,
    CodexAgentTurnComplete,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HookSignal {
    pub harness: HarnessKind,
    pub source: HarnessCompletionSource,
    pub terminal_tab_id: Option<TerminalTabId>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HarnessCompletionEvent {
    pub harness: HarnessKind,
    pub source: HarnessCompletionSource,
    pub terminal_tab_id: Option<TerminalTabId>,
    pub title: String,
    pub body: String,
}

pub trait NotificationService {
    fn notify_harness_completed(&mut self, event: HarnessCompletionEvent) -> anyhow::Result<()>;
}

#[derive(Debug)]
pub struct NotificationController<N> {
    notifier: N,
}

impl<N> NotificationController<N> {
    pub fn new(notifier: N) -> Self {
        Self { notifier }
    }

    pub fn notifier(&self) -> &N {
        &self.notifier
    }

    pub fn into_notifier(self) -> N {
        self.notifier
    }
}

impl<N: NotificationService> NotificationController<N> {
    pub fn handle_hook_signal(&mut self, signal: HookSignal) -> anyhow::Result<()> {
        self.notifier
            .notify_harness_completed(completion_event(signal))
    }

    pub fn handle_raw_hook_payload(
        &mut self,
        provider: HookProvider,
        payload: &Value,
    ) -> anyhow::Result<()> {
        if let Some(signal) = parse_hook_signal(provider, payload) {
            self.handle_hook_signal(signal)?;
        }

        Ok(())
    }
}

pub fn parse_hook_signal(provider: HookProvider, payload: &Value) -> Option<HookSignal> {
    match provider {
        HookProvider::ClaudeCode => parse_claude_code_hook(payload),
        HookProvider::Codex => parse_codex_notify(payload),
    }
}

fn parse_claude_code_hook(payload: &Value) -> Option<HookSignal> {
    let source = match payload.get("hook_event_name")?.as_str()? {
        "Stop" => HarnessCompletionSource::ClaudeCodeStop,
        "SubagentStop" => HarnessCompletionSource::ClaudeCodeSubagentStop,
        _ => return None,
    };

    Some(HookSignal {
        harness: HarnessKind::ClaudeCode,
        source,
        terminal_tab_id: terminal_tab_id(payload),
    })
}

fn parse_codex_notify(payload: &Value) -> Option<HookSignal> {
    let source = match payload.get("type")?.as_str()? {
        "agent-turn-complete" => HarnessCompletionSource::CodexAgentTurnComplete,
        _ => return None,
    };

    Some(HookSignal {
        harness: HarnessKind::Codex,
        source,
        terminal_tab_id: terminal_tab_id(payload),
    })
}

fn terminal_tab_id(payload: &Value) -> Option<TerminalTabId> {
    payload
        .get("terminal_tab_id")
        .and_then(Value::as_u64)
        .or_else(|| payload.get("alas_terminal_tab_id").and_then(Value::as_u64))
        .map(TerminalTabId)
}

fn completion_event(signal: HookSignal) -> HarnessCompletionEvent {
    HarnessCompletionEvent {
        harness: signal.harness,
        source: signal.source,
        terminal_tab_id: signal.terminal_tab_id,
        title: format!("{} completed", signal.harness.display_name()),
        body: completion_body(signal.source),
    }
}

fn completion_body(source: HarnessCompletionSource) -> String {
    match source {
        HarnessCompletionSource::ClaudeCodeStop => "Claude Code stopped.".to_string(),
        HarnessCompletionSource::ClaudeCodeSubagentStop => {
            "Claude Code subagent stopped.".to_string()
        }
        HarnessCompletionSource::CodexAgentTurnComplete => {
            "Codex agent turn completed.".to_string()
        }
    }
}
