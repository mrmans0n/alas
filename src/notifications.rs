use std::{
    collections::{HashMap, HashSet, VecDeque},
    path::PathBuf,
    sync::{
        Mutex, OnceLock,
        atomic::{AtomicU64, Ordering},
    },
};

use serde_json::Value;

#[cfg(target_os = "macos")]
mod macos;

#[cfg(target_os = "macos")]
pub use macos::{MacOsAppFocusState, MacOsNotificationSink};

#[cfg(target_os = "macos")]
pub type DefaultAppFocusState = MacOsAppFocusState;
#[cfg(target_os = "macos")]
pub type DefaultNotificationSink = MacOsNotificationSink;

#[cfg(not(target_os = "macos"))]
pub type DefaultAppFocusState = NeverFocusedAppFocusState;
#[cfg(not(target_os = "macos"))]
pub type DefaultNotificationSink = NotificationService;

use crate::app::{TerminalTabId, WorkspaceTabContext};
use crate::config::NotificationPrefs;
use crate::terminal::HarnessKind;

const ACTIVATION_KIND_KEY: &str = "alas_activation_kind";
const ACTIVATION_TOKEN_KEY: &str = "alas_activation_token";
const ACTIVATION_REPO_ID_KEY: &str = "alas_repo_id";
const ACTIVATION_WORKTREE_PATH_KEY: &str = "alas_worktree_path";
const ACTIVATION_TERMINAL_TAB_ID_KEY: &str = "alas_terminal_tab_id";
const HARNESS_COMPLETION_ACTIVATION_KIND: &str = "harness_completion";
const ACTIVATION_REGISTRY_CAPACITY: usize = 256;

static NEXT_ACTIVATION_TOKEN: AtomicU64 = AtomicU64::new(1);
static GLOBAL_ACTIVATION_REGISTRY: OnceLock<Mutex<NotificationActivationRegistry>> =
    OnceLock::new();
static PENDING_ACTIVATIONS: OnceLock<Mutex<Vec<NotificationActivation>>> = OnceLock::new();

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
    pub outcome: HarnessCompletionOutcome,
    pub terminal_tab_id: Option<TerminalTabId>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HarnessCompletionEvent {
    pub harness: HarnessKind,
    pub source: HarnessCompletionSource,
    pub outcome: HarnessCompletionOutcome,
    pub terminal_tab_id: Option<TerminalTabId>,
    pub context: HarnessCompletionContext,
    pub title: String,
    pub body: String,
    pub sound: NotificationSound,
}

impl HarnessCompletionEvent {
    pub fn activation_target(&self) -> Option<NotificationTabTarget> {
        Some(NotificationTabTarget {
            repo_id: self.context.repo_id.clone()?,
            worktree_path: self.context.worktree_path.clone()?,
            terminal_tab_id: self.context.terminal_tab_id?,
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct HarnessCompletionContext {
    pub terminal_tab_id: Option<TerminalTabId>,
    pub tab_name: Option<String>,
    pub repo_id: Option<String>,
    pub worktree_path: Option<PathBuf>,
}

impl HarnessCompletionContext {
    pub fn unresolved(terminal_tab_id: Option<TerminalTabId>) -> Self {
        Self {
            terminal_tab_id,
            ..Self::default()
        }
    }
}

impl From<WorkspaceTabContext> for HarnessCompletionContext {
    fn from(context: WorkspaceTabContext) -> Self {
        Self {
            terminal_tab_id: Some(context.tab_id),
            tab_name: Some(context.tab_name),
            repo_id: Some(context.repo_id),
            worktree_path: Some(context.worktree_path),
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum NotificationSound {
    Success,
    Failure,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NotificationTabTarget {
    pub repo_id: String,
    pub worktree_path: PathBuf,
    pub terminal_tab_id: TerminalTabId,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct NotificationActivationToken(String);

impl NotificationActivationToken {
    fn generate() -> Self {
        let token_id = NEXT_ACTIVATION_TOKEN.fetch_add(1, Ordering::Relaxed);
        Self(format!("{}-{token_id}", std::process::id()))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl From<String> for NotificationActivationToken {
    fn from(value: String) -> Self {
        Self(value)
    }
}

impl From<&str> for NotificationActivationToken {
    fn from(value: &str) -> Self {
        Self(value.to_string())
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NotificationActivationPayload {
    pub kind: String,
    pub token: Option<NotificationActivationToken>,
    pub target: Option<NotificationTabTarget>,
}

impl NotificationActivationPayload {
    pub fn harness_completion(
        token: NotificationActivationToken,
        target: NotificationTabTarget,
    ) -> Self {
        Self {
            kind: HARNESS_COMPLETION_ACTIVATION_KIND.to_string(),
            token: Some(token),
            target: Some(target),
        }
    }

    pub fn from_values(kind: Option<&str>, token: Option<&str>) -> Option<Self> {
        Some(Self {
            kind: kind?.to_string(),
            token: token.map(NotificationActivationToken::from),
            target: None,
        })
    }

    pub fn from_user_info_values(
        kind: Option<&str>,
        token: Option<&str>,
        repo_id: Option<&str>,
        worktree_path: Option<&str>,
        terminal_tab_id: Option<&str>,
    ) -> Option<Self> {
        let target = match (repo_id, worktree_path, terminal_tab_id) {
            (Some(repo_id), Some(worktree_path), Some(terminal_tab_id)) => {
                Some(NotificationTabTarget {
                    repo_id: repo_id.to_string(),
                    worktree_path: PathBuf::from(worktree_path),
                    terminal_tab_id: TerminalTabId(terminal_tab_id.parse().ok()?),
                })
            }
            _ => None,
        };

        Some(Self {
            kind: kind?.to_string(),
            token: token.map(NotificationActivationToken::from),
            target,
        })
    }

    pub fn user_info_entries(&self) -> Vec<(&'static str, String)> {
        let mut entries = vec![(ACTIVATION_KIND_KEY, self.kind.clone())];
        if let Some(token) = self.token.as_ref() {
            entries.push((ACTIVATION_TOKEN_KEY, token.as_str().to_string()));
        }
        if let Some(target) = self.target.as_ref() {
            entries.push((ACTIVATION_REPO_ID_KEY, target.repo_id.clone()));
            entries.push((
                ACTIVATION_WORKTREE_PATH_KEY,
                target.worktree_path.to_string_lossy().into_owned(),
            ));
            entries.push((
                ACTIVATION_TERMINAL_TAB_ID_KEY,
                target.terminal_tab_id.0.to_string(),
            ));
        }
        entries
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum NotificationActivation {
    HarnessCompletion(NotificationTabTarget),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum NotificationActivationResolution {
    Resolved(NotificationTabTarget),
    MissingToken,
    UnknownToken,
    UnsupportedKind,
}

#[derive(Debug, Default)]
pub struct NotificationActivationRegistry {
    entries: HashMap<NotificationActivationToken, NotificationTabTarget>,
    insertion_order: VecDeque<NotificationActivationToken>,
}

impl NotificationActivationRegistry {
    pub fn register_harness_completion(
        &mut self,
        target: NotificationTabTarget,
    ) -> NotificationActivationPayload {
        let token = NotificationActivationToken::generate();
        self.register_harness_completion_with_token(token, target)
    }

    pub fn register_harness_completion_with_token(
        &mut self,
        token: NotificationActivationToken,
        target: NotificationTabTarget,
    ) -> NotificationActivationPayload {
        self.entries.remove(&token);
        self.insertion_order
            .retain(|existing_token| existing_token != &token);
        self.entries.insert(token.clone(), target.clone());
        self.insertion_order.push_back(token.clone());
        while self.insertion_order.len() > ACTIVATION_REGISTRY_CAPACITY {
            if let Some(expired_token) = self.insertion_order.pop_front() {
                self.entries.remove(&expired_token);
            }
        }
        NotificationActivationPayload::harness_completion(token, target)
    }

    pub fn resolve(
        &mut self,
        payload: Option<NotificationActivationPayload>,
    ) -> NotificationActivationResolution {
        let Some(payload) = payload else {
            return NotificationActivationResolution::MissingToken;
        };
        if payload.kind != HARNESS_COMPLETION_ACTIVATION_KIND {
            return NotificationActivationResolution::UnsupportedKind;
        }

        if let Some(token) = payload.token
            && let Some(target) = self.entries.remove(&token)
        {
            self.insertion_order
                .retain(|existing_token| existing_token != &token);
            return NotificationActivationResolution::Resolved(target);
        }

        payload
            .target
            .map(NotificationActivationResolution::Resolved)
            .unwrap_or(NotificationActivationResolution::UnknownToken)
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum HookBackedHarness {
    ClaudeCode,
    Codex,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Hash)]
pub enum HarnessCompletionOutcome {
    Success,
    Failure,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum HarnessNotificationSource {
    HookBacked(HookBackedHarness),
    Unsupported(String),
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct HarnessCompletionNotificationEvent {
    pub source: HarnessNotificationSource,
    pub outcome: HarnessCompletionOutcome,
    pub title: String,
    pub body: String,
    pub repo_id: Option<String>,
    pub worktree_path: Option<std::path::PathBuf>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum NotificationDecision {
    Allowed,
    Disabled,
    SuccessDisabled,
    FailureDisabled,
    UnsupportedHarness,
    Focused,
}

#[derive(Clone, Debug, Default)]
pub struct NotificationService;

impl NotificationService {
    pub fn harness_completion_decision(
        &self,
        prefs: &NotificationPrefs,
        event: &HarnessCompletionNotificationEvent,
        app_is_active: bool,
    ) -> NotificationDecision {
        let completion_prefs = &prefs.harness_completion;
        if !completion_prefs.enabled {
            return NotificationDecision::Disabled;
        }
        if app_is_active {
            return NotificationDecision::Focused;
        }
        if matches!(event.source, HarnessNotificationSource::Unsupported(_)) {
            return NotificationDecision::UnsupportedHarness;
        }

        match event.outcome {
            HarnessCompletionOutcome::Success if !completion_prefs.success => {
                NotificationDecision::SuccessDisabled
            }
            HarnessCompletionOutcome::Failure if !completion_prefs.failure => {
                NotificationDecision::FailureDisabled
            }
            HarnessCompletionOutcome::Success | HarnessCompletionOutcome::Failure => {
                NotificationDecision::Allowed
            }
        }
    }

    pub fn build_harness_completion_event(
        &self,
        signal: HookSignal,
        context: HarnessCompletionContext,
    ) -> HarnessCompletionEvent {
        let title = completion_title(signal.harness, signal.outcome);
        let body = completion_body(signal.source, signal.outcome, &context);
        let sound = match signal.outcome {
            HarnessCompletionOutcome::Success => NotificationSound::Success,
            HarnessCompletionOutcome::Failure => NotificationSound::Failure,
        };

        HarnessCompletionEvent {
            harness: signal.harness,
            source: signal.source,
            outcome: signal.outcome,
            terminal_tab_id: signal.terminal_tab_id,
            context,
            title,
            body,
            sound,
        }
    }
}

pub trait NotificationSink {
    fn notify_harness_completed(&mut self, event: HarnessCompletionEvent) -> anyhow::Result<()>;
}

pub trait AppFocusState {
    fn is_app_active(&self) -> bool;
}

#[derive(Clone, Copy, Debug, Default)]
pub struct NeverFocusedAppFocusState;

impl AppFocusState for NeverFocusedAppFocusState {
    fn is_app_active(&self) -> bool {
        false
    }
}

impl NotificationSink for NotificationService {
    fn notify_harness_completed(&mut self, _event: HarnessCompletionEvent) -> anyhow::Result<()> {
        Ok(())
    }
}

#[derive(Debug)]
pub struct NotificationController<N, F = NeverFocusedAppFocusState> {
    notifier: N,
    focus_state: F,
    preferences: NotificationPrefs,
    notification_service: NotificationService,
    recent_hook_signals: VecDeque<HookSignalKey>,
    seen_hook_signals: HashSet<HookSignalKey>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
struct HookSignalKey {
    harness: HarnessKind,
    source: HarnessCompletionSource,
    outcome: HarnessCompletionOutcome,
    terminal_tab_id: Option<TerminalTabId>,
}

impl From<&HookSignal> for HookSignalKey {
    fn from(signal: &HookSignal) -> Self {
        Self {
            harness: signal.harness,
            source: signal.source,
            outcome: signal.outcome,
            terminal_tab_id: signal.terminal_tab_id,
        }
    }
}

const RECENT_HOOK_SIGNAL_CAPACITY: usize = 256;

impl<N> NotificationController<N> {
    pub fn new(notifier: N) -> Self {
        Self::new_with_preferences(notifier, NotificationPrefs::default())
    }

    pub fn new_with_preferences(notifier: N, preferences: NotificationPrefs) -> Self {
        Self::new_with_preferences_and_focus(notifier, preferences, NeverFocusedAppFocusState)
    }
}

impl<N, F> NotificationController<N, F> {
    pub fn new_with_preferences_and_focus(
        notifier: N,
        preferences: NotificationPrefs,
        focus_state: F,
    ) -> Self {
        Self {
            notifier,
            focus_state,
            preferences,
            notification_service: NotificationService,
            recent_hook_signals: VecDeque::new(),
            seen_hook_signals: HashSet::new(),
        }
    }

    pub fn notifier(&self) -> &N {
        &self.notifier
    }

    pub fn focus_state(&self) -> &F {
        &self.focus_state
    }

    pub fn preferences(&self) -> &NotificationPrefs {
        &self.preferences
    }

    pub fn update_preferences(&mut self, preferences: NotificationPrefs) {
        self.preferences = preferences;
    }

    pub fn into_notifier(self) -> N {
        self.notifier
    }
}

impl<N: NotificationSink, F: AppFocusState> NotificationController<N, F> {
    pub fn handle_hook_signal(&mut self, signal: HookSignal) -> anyhow::Result<bool> {
        let context = HarnessCompletionContext::unresolved(signal.terminal_tab_id);
        self.handle_hook_signal_with_context(signal, context)
    }

    pub fn handle_hook_signal_with_context(
        &mut self,
        signal: HookSignal,
        context: HarnessCompletionContext,
    ) -> anyhow::Result<bool> {
        let notification_event = notification_event(&signal);
        if self.notification_service.harness_completion_decision(
            &self.preferences,
            &notification_event,
            self.focus_state.is_app_active(),
        ) != NotificationDecision::Allowed
        {
            return Ok(true);
        }

        if !self.remember_hook_signal(&signal) {
            return Ok(false);
        }

        self.notifier.notify_harness_completed(
            self.notification_service
                .build_harness_completion_event(signal, context),
        )?;

        Ok(true)
    }

    pub fn handle_raw_hook_payload(
        &mut self,
        provider: HookProvider,
        payload: &Value,
    ) -> anyhow::Result<bool> {
        if let Some(signal) = parse_hook_signal(provider, payload) {
            return self.handle_hook_signal(signal);
        }

        Ok(false)
    }

    pub fn handle_raw_hook_payload_with_context(
        &mut self,
        provider: HookProvider,
        payload: &Value,
        context: HarnessCompletionContext,
    ) -> anyhow::Result<bool> {
        if let Some(signal) = parse_hook_signal(provider, payload) {
            return self.handle_hook_signal_with_context(signal, context);
        }

        Ok(false)
    }

    fn remember_hook_signal(&mut self, signal: &HookSignal) -> bool {
        let key = HookSignalKey::from(signal);
        if self.seen_hook_signals.contains(&key) {
            return false;
        }

        self.seen_hook_signals.insert(key);
        self.recent_hook_signals.push_back(key);
        while self.recent_hook_signals.len() > RECENT_HOOK_SIGNAL_CAPACITY {
            if let Some(old_key) = self.recent_hook_signals.pop_front() {
                self.seen_hook_signals.remove(&old_key);
            }
        }

        true
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
        outcome: hook_outcome(payload)?,
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
        outcome: hook_outcome(payload)?,
        terminal_tab_id: terminal_tab_id(payload),
    })
}

fn hook_outcome(payload: &Value) -> Option<HarnessCompletionOutcome> {
    payload
        .get("success")
        .and_then(Value::as_bool)
        .map(|success| {
            if success {
                HarnessCompletionOutcome::Success
            } else {
                HarnessCompletionOutcome::Failure
            }
        })
        .or_else(|| string_outcome(payload.get("outcome").and_then(Value::as_str)))
        .or_else(|| string_outcome(payload.get("status").and_then(Value::as_str)))
        .or_else(|| exit_code_outcome(payload.get("exit_code").and_then(Value::as_i64)))
        .or_else(|| exit_code_outcome(payload.get("code").and_then(Value::as_i64)))
}

fn string_outcome(value: Option<&str>) -> Option<HarnessCompletionOutcome> {
    match value?.to_ascii_lowercase().as_str() {
        "success" | "succeeded" | "ok" | "complete" | "completed" | "passed" => {
            Some(HarnessCompletionOutcome::Success)
        }
        "failure" | "failed" | "error" | "errored" | "cancelled" | "canceled" => {
            Some(HarnessCompletionOutcome::Failure)
        }
        _ => None,
    }
}

fn exit_code_outcome(value: Option<i64>) -> Option<HarnessCompletionOutcome> {
    value.map(|code| {
        if code == 0 {
            HarnessCompletionOutcome::Success
        } else {
            HarnessCompletionOutcome::Failure
        }
    })
}

fn terminal_tab_id(payload: &Value) -> Option<TerminalTabId> {
    payload
        .get("terminal_tab_id")
        .and_then(Value::as_u64)
        .or_else(|| payload.get("alas_terminal_tab_id").and_then(Value::as_u64))
        .map(TerminalTabId)
}

pub fn register_harness_completion_activation(
    target: NotificationTabTarget,
) -> NotificationActivationPayload {
    global_registry()
        .lock()
        .expect("notification activation registry poisoned")
        .register_harness_completion(target)
}

pub fn resolve_notification_activation(
    payload: Option<NotificationActivationPayload>,
) -> NotificationActivationResolution {
    global_registry()
        .lock()
        .expect("notification activation registry poisoned")
        .resolve(payload)
}

pub fn enqueue_notification_activation(activation: NotificationActivation) {
    pending_activations()
        .lock()
        .expect("notification activation queue poisoned")
        .push(activation);
}

pub fn drain_notification_activations() -> Vec<NotificationActivation> {
    pending_activations()
        .lock()
        .expect("notification activation queue poisoned")
        .drain(..)
        .collect()
}

pub fn activation_payload_from_values(
    kind: Option<&str>,
    token: Option<&str>,
) -> Option<NotificationActivationPayload> {
    NotificationActivationPayload::from_values(kind, token)
}

pub fn activation_kind_key() -> &'static str {
    ACTIVATION_KIND_KEY
}

pub fn activation_token_key() -> &'static str {
    ACTIVATION_TOKEN_KEY
}

pub fn activation_repo_id_key() -> &'static str {
    ACTIVATION_REPO_ID_KEY
}

pub fn activation_worktree_path_key() -> &'static str {
    ACTIVATION_WORKTREE_PATH_KEY
}

pub fn activation_terminal_tab_id_key() -> &'static str {
    ACTIVATION_TERMINAL_TAB_ID_KEY
}

#[cfg(target_os = "macos")]
pub fn install_notification_activation_handler() {
    macos::install_delegate();
}

#[cfg(not(target_os = "macos"))]
pub fn install_notification_activation_handler() {}

fn global_registry() -> &'static Mutex<NotificationActivationRegistry> {
    GLOBAL_ACTIVATION_REGISTRY.get_or_init(|| Mutex::new(NotificationActivationRegistry::default()))
}

fn pending_activations() -> &'static Mutex<Vec<NotificationActivation>> {
    PENDING_ACTIVATIONS.get_or_init(|| Mutex::new(Vec::new()))
}

fn notification_event(signal: &HookSignal) -> HarnessCompletionNotificationEvent {
    HarnessCompletionNotificationEvent {
        source: HarnessNotificationSource::HookBacked(match signal.harness {
            HarnessKind::ClaudeCode => HookBackedHarness::ClaudeCode,
            HarnessKind::Codex => HookBackedHarness::Codex,
        }),
        outcome: signal.outcome,
        title: completion_title(signal.harness, signal.outcome),
        body: String::new(),
        repo_id: None,
        worktree_path: None,
    }
}

fn completion_title(harness: HarnessKind, outcome: HarnessCompletionOutcome) -> String {
    match outcome {
        HarnessCompletionOutcome::Success => format!("{} completed", harness.display_name()),
        HarnessCompletionOutcome::Failure => format!("{} failed", harness.display_name()),
    }
}

fn completion_body(
    source: HarnessCompletionSource,
    outcome: HarnessCompletionOutcome,
    context: &HarnessCompletionContext,
) -> String {
    let context = context_display(context);
    match source {
        HarnessCompletionSource::ClaudeCodeStop => outcome_body("Claude Code", outcome, context),
        HarnessCompletionSource::ClaudeCodeSubagentStop => {
            outcome_body("Claude Code subagent", outcome, context)
        }
        HarnessCompletionSource::CodexAgentTurnComplete => {
            outcome_body("Codex agent turn", outcome, context)
        }
    }
}

fn outcome_body(
    source_label: &str,
    outcome: HarnessCompletionOutcome,
    context: Option<String>,
) -> String {
    let verb = match outcome {
        HarnessCompletionOutcome::Success => "finished successfully",
        HarnessCompletionOutcome::Failure => "failed",
    };

    match context {
        Some(context) => format!("{source_label} {verb} in {context}."),
        None => format!("{source_label} {verb}."),
    }
}

fn context_display(context: &HarnessCompletionContext) -> Option<String> {
    let tab_name = context.tab_name.as_deref()?.trim();
    if tab_name.is_empty() {
        return None;
    }

    let workspace = context
        .repo_id
        .as_deref()
        .map(str::trim)
        .filter(|repo_id| !repo_id.is_empty())
        .map(ToOwned::to_owned)
        .or_else(|| {
            context
                .worktree_path
                .as_ref()
                .and_then(|path| path.file_name())
                .and_then(|name| name.to_str())
                .filter(|name| !name.is_empty())
                .map(ToOwned::to_owned)
        })
        .or_else(|| {
            context
                .worktree_path
                .as_ref()
                .map(|path| path.display().to_string())
                .filter(|path| !path.is_empty())
        });

    match workspace {
        Some(workspace) => Some(format!("{tab_name} - {workspace}")),
        None => Some(tab_name.to_string()),
    }
}
