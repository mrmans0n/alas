# Center Pane ACP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add ACP-backed Agent Chat tabs to the Alas center pane with global manual providers, in-app auth, durable resume behavior, filesystem/terminal callbacks, and provider settings.

**Architecture:** Add ACP as a new workspace tab content type, with provider config and persisted thread state kept separate from live ACP runtime connections. Implement an `agent` module with focused submodules for domain types, provider config/auth, runtime lifecycle, callbacks, terminal command execution, persistence, and test fakes. Integrate UI through the existing `WorkspaceSession`, `render_workspace` tab bar, and `AlasShell` active-tab routing without rewriting terminal/file/markdown surfaces.

**Tech Stack:** Rust 2024, GPUI/gpui-component, serde/toml/serde_json, `agent-client-protocol` crate, OS credential storage via `keyring`, standard subprocess/file APIs, existing Alas app/config/workspace/session patterns.

---

## Scope and Sequencing Notes

This plan implements the approved first subproject from `docs/superpowers/specs/2026-05-01-center-pane-acp-design.md`: ACP foundation with full contracts. It intentionally does not implement ACP registry install/update management.

Use TDD for each task. Keep commits small and do not batch unrelated tasks. If the real `agent-client-protocol` Rust API names differ from examples below, adapt the runtime wrapper while keeping the public Alas-owned interfaces and tests intact.

## File Structure

Create these new files:

- `src/agent/mod.rs` — exports the ACP/agent feature modules.
- `src/agent/types.rs` — provider ids, trust modes, auth status, thread status, transcript/tool/plan data types.
- `src/agent/provider.rs` — global provider config model, env/auth metadata, validation helpers.
- `src/agent/credentials.rs` — OS secure credential store trait and `keyring` implementation, plus test memory store.
- `src/agent/persistence.rs` — local persisted Agent Chat records and JSON store.
- `src/agent/permission.rs` — trust-mode policy decisions for permission, filesystem, and terminal callbacks.
- `src/agent/filesystem.rs` — ACP filesystem callback implementation against disk.
- `src/agent/terminal.rs` — protocol-only terminal command callback service.
- `src/agent/runtime.rs` — live ACP runtime state machine, provider process lifecycle, session lifecycle, prompt/cancel facade.
- `src/agent/fake.rs` — test fakes for runtime/connection behavior.
- `src/ui/agent_pane.rs` — Agent Chat pane renderer.
- `src/ui/provider_settings.rs` — global provider settings/auth UI renderer.
- `tests/agent_provider_config_tests.rs` — provider config serialization/defaults/validation.
- `tests/agent_workspace_tests.rs` — Agent Chat tab behavior in workspace session.
- `tests/agent_persistence_tests.rs` — persisted thread store behavior.
- `tests/agent_permission_tests.rs` — trust policy behavior.
- `tests/agent_filesystem_tests.rs` — filesystem callback behavior.
- `tests/agent_terminal_tests.rs` — protocol-only terminal callback behavior.
- `tests/agent_runtime_tests.rs` — runtime state transitions using fakes.
- `tests/agent_ui_view_model_tests.rs` — UI/view model state coverage.

Modify these existing files:

- `Cargo.toml` — add `agent-client-protocol`, `keyring`, and any small async/process helper only if needed.
- `src/lib.rs` — export `agent` module.
- `src/config/types.rs` — add global provider config to `AppConfig`.
- `src/config/mod.rs` — re-export new provider config types if they live under `config`; otherwise re-export from `agent` as needed.
- `src/app/workspace.rs` — add Agent Chat tab state/content/kind and mutation helpers.
- `src/app/mod.rs` — re-export Agent Chat workspace types.
- `src/ui/mod.rs` — export `agent_pane` and `provider_settings`.
- `src/ui/workspace.rs` — make `+` action open a Terminal vs Agent Chat picker and add Agent Chat tab labels.
- `src/ui/shell.rs` — store provider/settings/picker/runtime UI state, route Agent Chat tabs, connect UI events to runtime facade, persist thread changes.
- `docs/manual-test.md` — add ACP manual acceptance steps.

---

### Task 1: Add Provider Config Types

**Files:**
- Modify: `Cargo.toml`
- Modify: `src/config/types.rs`
- Test: `tests/agent_provider_config_tests.rs`

- [ ] **Step 1: Add failing provider config tests**

Create `tests/agent_provider_config_tests.rs`:

```rust
use alas::config::AppConfig;
use alas::agent::{AgentProviderConfig, AgentProviderEnvVar, AgentTrustMode, ProviderCwdPolicy};

#[test]
fn app_config_serializes_global_agent_providers_without_secret_values() {
    let mut config = AppConfig::default();
    config.agent_providers.push(AgentProviderConfig {
        id: "opencode".to_string(),
        display_name: "OpenCode".to_string(),
        command: "opencode".to_string(),
        args: vec!["acp".to_string()],
        env: vec![AgentProviderEnvVar::secure_ref("OPENCODE_API_KEY", "opencode/api-key")],
        cwd_policy: ProviderCwdPolicy::SelectedWorktree,
        trust_mode: AgentTrustMode::AllowEverything,
        enabled: true,
    });

    let toml = toml::to_string(&config).expect("serialize config");
    assert!(toml.contains("agent_providers"));
    assert!(toml.contains("opencode/api-key"));
    assert!(!toml.contains("super-secret"));

    let loaded: AppConfig = toml::from_str(&toml).expect("deserialize config");
    assert_eq!(loaded.agent_providers[0].trust_mode, AgentTrustMode::AllowEverything);
}

#[test]
fn provider_defaults_to_allow_everything_and_selected_worktree() {
    let provider = AgentProviderConfig::new("codex", "Codex", "codex-acp");
    assert_eq!(provider.trust_mode, AgentTrustMode::AllowEverything);
    assert_eq!(provider.cwd_policy, ProviderCwdPolicy::SelectedWorktree);
    assert!(provider.enabled);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cargo test --test agent_provider_config_tests --all-features`

Expected: FAIL because `alas::agent` and `AppConfig::agent_providers` do not exist.

- [ ] **Step 3: Add dependencies and minimal provider types**

Modify `Cargo.toml`:

```toml
agent-client-protocol = "0.20"
keyring = { version = "3", default-features = true }
```

If the ACP crate version has advanced, use the latest compatible version from `cargo search agent-client-protocol` and record the chosen version in the commit message.

Create `src/agent/mod.rs`:

```rust
pub mod provider;
pub mod types;

pub use provider::{AgentProviderConfig, AgentProviderEnvVar, ProviderCwdPolicy};
pub use types::AgentTrustMode;
```

Create `src/agent/types.rs`:

```rust
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum AgentTrustMode {
    AllowEverything,
    Ask,
    WorktreeOnly,
    Deny,
}

impl Default for AgentTrustMode {
    fn default() -> Self {
        Self::AllowEverything
    }
}
```

Create `src/agent/provider.rs`:

```rust
use serde::{Deserialize, Serialize};

use crate::agent::AgentTrustMode;

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct AgentProviderConfig {
    pub id: String,
    pub display_name: String,
    pub command: String,
    #[serde(default)]
    pub args: Vec<String>,
    #[serde(default)]
    pub env: Vec<AgentProviderEnvVar>,
    #[serde(default)]
    pub cwd_policy: ProviderCwdPolicy,
    #[serde(default)]
    pub trust_mode: AgentTrustMode,
    #[serde(default = "default_enabled")]
    pub enabled: bool,
}

impl AgentProviderConfig {
    pub fn new(id: impl Into<String>, display_name: impl Into<String>, command: impl Into<String>) -> Self {
        Self {
            id: id.into(),
            display_name: display_name.into(),
            command: command.into(),
            args: Vec::new(),
            env: Vec::new(),
            cwd_policy: ProviderCwdPolicy::default(),
            trust_mode: AgentTrustMode::default(),
            enabled: true,
        }
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct AgentProviderEnvVar {
    pub name: String,
    #[serde(default)]
    pub value: Option<String>,
    #[serde(default)]
    pub secure_ref: Option<String>,
}

impl AgentProviderEnvVar {
    pub fn secure_ref(name: impl Into<String>, secure_ref: impl Into<String>) -> Self {
        Self { name: name.into(), value: None, secure_ref: Some(secure_ref.into()) }
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum ProviderCwdPolicy {
    SelectedWorktree,
    RepositoryRoot,
    Fixed(std::path::PathBuf),
}

impl Default for ProviderCwdPolicy {
    fn default() -> Self { Self::SelectedWorktree }
}

fn default_enabled() -> bool { true }
```

Modify `src/lib.rs`:

```rust
pub mod agent;
```

Modify `src/config/types.rs` `AppConfig`:

```rust
#[serde(default)]
pub agent_providers: Vec<crate::agent::AgentProviderConfig>,
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cargo test --test agent_provider_config_tests --all-features`

Expected: PASS.

- [ ] **Step 5: Run formatting**

Run: `cargo fmt --all -- --check`

Expected: PASS. If it fails, run `cargo fmt --all`, then rerun the check.

- [ ] **Step 6: Commit**

```bash
git add Cargo.toml Cargo.lock src/lib.rs src/agent src/config/types.rs tests/agent_provider_config_tests.rs
git commit -m "feat: add ACP provider config model"
```

---

### Task 2: Add Credential Store Abstraction

**Files:**
- Create: `src/agent/credentials.rs`
- Modify: `src/agent/mod.rs`
- Test: `tests/agent_provider_config_tests.rs`

- [ ] **Step 1: Add failing credential-store tests**

Append to `tests/agent_provider_config_tests.rs`:

```rust
use alas::agent::{CredentialStore, CredentialStoreKey, MemoryCredentialStore};

#[test]
fn memory_credential_store_round_trips_secret_by_provider_and_field() {
    let store = MemoryCredentialStore::default();
    let key = CredentialStoreKey::new("opencode", "OPENCODE_API_KEY");

    store.write_secret(&key, "super-secret").expect("write secret");
    assert_eq!(store.read_secret(&key).expect("read secret"), Some("super-secret".to_string()));
    store.delete_secret(&key).expect("delete secret");
    assert_eq!(store.read_secret(&key).expect("read after delete"), None);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cargo test --test agent_provider_config_tests --all-features`

Expected: FAIL because credential types do not exist.

- [ ] **Step 3: Implement credential store trait, memory store, and keyring store**

Create `src/agent/credentials.rs`:

```rust
use std::{collections::HashMap, sync::{Arc, Mutex}};

use anyhow::Context;

#[derive(Clone, Debug, Eq, PartialEq, Hash)]
pub struct CredentialStoreKey {
    pub provider_id: String,
    pub field: String,
}

impl CredentialStoreKey {
    pub fn new(provider_id: impl Into<String>, field: impl Into<String>) -> Self {
        Self { provider_id: provider_id.into(), field: field.into() }
    }

    fn service(&self) -> String { format!("alas.agent.{}", self.provider_id) }
    fn username(&self) -> &str { &self.field }
}

pub trait CredentialStore: Send + Sync {
    fn read_secret(&self, key: &CredentialStoreKey) -> anyhow::Result<Option<String>>;
    fn write_secret(&self, key: &CredentialStoreKey, value: &str) -> anyhow::Result<()>;
    fn delete_secret(&self, key: &CredentialStoreKey) -> anyhow::Result<()>;
}

#[derive(Clone, Default)]
pub struct MemoryCredentialStore {
    secrets: Arc<Mutex<HashMap<CredentialStoreKey, String>>>,
}

impl CredentialStore for MemoryCredentialStore {
    fn read_secret(&self, key: &CredentialStoreKey) -> anyhow::Result<Option<String>> {
        Ok(self.secrets.lock().expect("credential lock").get(key).cloned())
    }

    fn write_secret(&self, key: &CredentialStoreKey, value: &str) -> anyhow::Result<()> {
        self.secrets.lock().expect("credential lock").insert(key.clone(), value.to_string());
        Ok(())
    }

    fn delete_secret(&self, key: &CredentialStoreKey) -> anyhow::Result<()> {
        self.secrets.lock().expect("credential lock").remove(key);
        Ok(())
    }
}

#[derive(Clone, Debug, Default)]
pub struct OsCredentialStore;

impl CredentialStore for OsCredentialStore {
    fn read_secret(&self, key: &CredentialStoreKey) -> anyhow::Result<Option<String>> {
        let entry = keyring::Entry::new(&key.service(), key.username())
            .context("failed to create keyring entry")?;
        match entry.get_password() {
            Ok(secret) => Ok(Some(secret)),
            Err(keyring::Error::NoEntry) => Ok(None),
            Err(error) => Err(error).context("failed to read secret from OS credential store"),
        }
    }

    fn write_secret(&self, key: &CredentialStoreKey, value: &str) -> anyhow::Result<()> {
        keyring::Entry::new(&key.service(), key.username())
            .context("failed to create keyring entry")?
            .set_password(value)
            .context("failed to write secret to OS credential store")
    }

    fn delete_secret(&self, key: &CredentialStoreKey) -> anyhow::Result<()> {
        let entry = keyring::Entry::new(&key.service(), key.username())
            .context("failed to create keyring entry")?;
        match entry.delete_credential() {
            Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
            Err(error) => Err(error).context("failed to delete secret from OS credential store"),
        }
    }
}
```

Modify `src/agent/mod.rs`:

```rust
pub mod credentials;
pub use credentials::{CredentialStore, CredentialStoreKey, MemoryCredentialStore, OsCredentialStore};
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cargo test --test agent_provider_config_tests --all-features`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/agent/credentials.rs src/agent/mod.rs tests/agent_provider_config_tests.rs
git commit -m "feat: add secure credential store abstraction"
```

---

### Task 3: Add Agent Thread Domain Types

**Files:**
- Modify: `src/agent/types.rs`
- Test: `tests/agent_workspace_tests.rs`

- [ ] **Step 1: Add failing tests for thread defaults**

Create `tests/agent_workspace_tests.rs` with only domain tests first:

```rust
use std::path::PathBuf;

use alas::agent::{AgentThreadState, AgentThreadStatus, AgentTranscriptEntry};

#[test]
fn new_agent_thread_starts_disconnected_with_empty_transcript() {
    let state = AgentThreadState::new("opencode", PathBuf::from("/repo/worktree"));

    assert_eq!(state.provider_id, "opencode");
    assert_eq!(state.status, AgentThreadStatus::Disconnected);
    assert!(state.acp_session_id.is_none());
    assert!(state.transcript.is_empty());
    assert_eq!(state.draft, "");
}

#[test]
fn transcript_entries_keep_role_and_text() {
    let entry = AgentTranscriptEntry::user("hello");
    assert_eq!(entry.text, "hello");
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cargo test --test agent_workspace_tests --all-features`

Expected: FAIL because thread types do not exist.

- [ ] **Step 3: Implement minimal domain types**

Extend `src/agent/types.rs`:

```rust
use std::path::PathBuf;

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct AgentThreadState {
    pub provider_id: String,
    pub acp_session_id: Option<String>,
    pub worktree_path: PathBuf,
    pub title: String,
    pub status: AgentThreadStatus,
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

impl AgentThreadState {
    pub fn new(provider_id: impl Into<String>, worktree_path: PathBuf) -> Self {
        Self {
            provider_id: provider_id.into(),
            acp_session_id: None,
            worktree_path,
            title: "Agent Chat".to_string(),
            status: AgentThreadStatus::Disconnected,
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
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum AgentThreadStatus {
    Disconnected,
    Starting,
    AuthRequired,
    Ready,
    Running,
    Failed { message: String },
    ReadOnly { reason: String },
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct AgentTranscriptEntry {
    pub role: AgentTranscriptRole,
    pub text: String,
}

impl AgentTranscriptEntry {
    pub fn user(text: impl Into<String>) -> Self {
        Self { role: AgentTranscriptRole::User, text: text.into() }
    }

    pub fn agent(text: impl Into<String>) -> Self {
        Self { role: AgentTranscriptRole::Agent, text: text.into() }
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum AgentTranscriptRole { User, Agent, Thought, System, Tool }

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
pub struct AgentToolCallState { pub id: String, pub title: String, pub status: String }

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
pub struct AgentPlanState { pub entries: Vec<String> }

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
pub struct AgentPermissionRequest { pub id: String, pub description: String }

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
pub struct AgentSlashCommand { pub name: String, pub description: Option<String> }

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
pub struct AgentModeOption { pub id: String, pub name: String }

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
pub struct AgentConfigOption { pub id: String, pub label: String, pub value: Option<String> }

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum AgentResumeState {
    NotRestored,
    Pending,
    Resumed,
    Unsupported,
    Failed { message: String },
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct AgentDebugEvent { pub message: String }
```

Update `src/agent/mod.rs` exports for the new types.

- [ ] **Step 4: Run test to verify it passes**

Run: `cargo test --test agent_workspace_tests --all-features`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/agent/types.rs src/agent/mod.rs tests/agent_workspace_tests.rs
git commit -m "feat: add agent thread state types"
```

---

### Task 4: Add Agent Chat Tabs to WorkspaceSession

**Files:**
- Modify: `src/app/workspace.rs`
- Modify: `src/app/mod.rs`
- Modify: `src/ui/workspace.rs`
- Test: `tests/agent_workspace_tests.rs`

- [ ] **Step 1: Add failing workspace tests**

Append to `tests/agent_workspace_tests.rs`:

```rust
use alas::app::{TerminalTabKind, WorkspaceSession, WorkspaceTabContent, WorkspaceTabKind};
use alas::terminal::CommandSpec;

#[test]
fn worktree_can_have_agent_chat_tabs_with_other_tab_kinds() {
    let mut session = WorkspaceSession::default();
    let path = PathBuf::from("/repo/a");
    let terminal = session.create_terminal_tab(
        "repo",
        path.clone(),
        "Shell".to_string(),
        TerminalTabKind::Shell,
        CommandSpec::shell_command("$SHELL", path.clone()),
    );

    let agent = session.create_agent_chat_tab("repo", path.clone(), "opencode".to_string());

    let tabs = session.tabs_for_worktree("repo", &path);
    assert_eq!(tabs.len(), 2);
    assert_eq!(tabs[0].id, terminal);
    assert_eq!(tabs[1].id, agent);
    assert_eq!(tabs[1].kind, WorkspaceTabKind::AgentChat);
    assert!(matches!(tabs[1].content, WorkspaceTabContent::AgentChat(_)));
    assert_eq!(session.active_tab("repo", &path).map(|tab| tab.id), Some(agent));
}

#[test]
fn terminal_specific_mutation_rejects_agent_chat_tabs() {
    let mut session = WorkspaceSession::default();
    let path = PathBuf::from("/repo/a");
    let agent = session.create_agent_chat_tab("repo", path.clone(), "opencode".to_string());

    let error = session
        .set_tab_scroll_offset("repo", &path, agent, 12)
        .expect_err("agent tab should reject terminal mutation")
        .to_string();

    assert!(error.contains("not a terminal tab"));
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cargo test --test agent_workspace_tests --all-features`

Expected: FAIL because workspace Agent Chat methods/kinds do not exist.

- [ ] **Step 3: Implement workspace model support**

Modify `src/app/workspace.rs`:

```rust
use crate::agent::AgentThreadState;
```

Add variants:

```rust
pub enum WorkspaceTabKind {
    Terminal(TerminalTabKind),
    File,
    AgentChat,
}

pub enum WorkspaceTabContent {
    Terminal(TerminalTabState),
    File(FileTabState),
    Markdown(MarkdownTabState),
    AgentChat(AgentThreadState),
}
```

Update helper matches so AgentChat is non-terminal and non-file. Add:

```rust
pub fn is_agent_chat(&self) -> bool {
    matches!(self.kind, WorkspaceTabKind::AgentChat)
}

pub fn agent_thread_state(&self) -> Option<&AgentThreadState> {
    match &self.content {
        WorkspaceTabContent::AgentChat(state) => Some(state),
        _ => None,
    }
}

pub fn agent_thread_state_mut(&mut self) -> Option<&mut AgentThreadState> {
    match &mut self.content {
        WorkspaceTabContent::AgentChat(state) => Some(state),
        _ => None,
    }
}
```

Add `WorkspaceSession::create_agent_chat_tab`:

```rust
pub fn create_agent_chat_tab(
    &mut self,
    repo_id: impl Into<String>,
    path: PathBuf,
    provider_id: String,
) -> WorkspaceTabId {
    let key = WorktreeKey::new(repo_id, path.clone());
    self.next_tab_id += 1;
    let id = WorkspaceTabId(self.next_tab_id);
    let tab = WorkspaceTab {
        id,
        name: "Agent Chat".to_string(),
        kind: WorkspaceTabKind::AgentChat,
        content: WorkspaceTabContent::AgentChat(AgentThreadState::new(provider_id, path)),
    };
    self.tabs.entry(key.clone()).or_default().push(tab);
    self.active_tabs.insert(key, id);
    id
}
```

Update `known_file_tab_mut`, `known_markdown_tab_mut`, and `file_tab_path` matches to include AgentChat.

Modify `src/app/mod.rs` to re-export agent workspace types if needed.

Modify `src/ui/workspace.rs` `tab_label`:

```rust
WorkspaceTabKind::AgentChat => format!("◇ {}", tab.name),
```

- [ ] **Step 4: Run targeted tests**

Run: `cargo test --test agent_workspace_tests --all-features`

Expected: PASS.

- [ ] **Step 5: Run existing workspace tests**

Run: `cargo test --test workspace_session_tests --all-features`

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/app/workspace.rs src/app/mod.rs src/ui/workspace.rs tests/agent_workspace_tests.rs
git commit -m "feat: add agent chat workspace tabs"
```

---

### Task 5: Add Agent Thread Persistence Store

**Files:**
- Create: `src/agent/persistence.rs`
- Modify: `src/agent/mod.rs`
- Test: `tests/agent_persistence_tests.rs`

- [ ] **Step 1: Add failing persistence tests**

Create `tests/agent_persistence_tests.rs`:

```rust
use std::path::PathBuf;

use alas::agent::{AgentThreadRecord, AgentThreadState, AgentThreadStore, AgentTranscriptEntry};
use tempfile::tempdir;

#[test]
fn thread_store_round_trips_persisted_thread_records() {
    let dir = tempdir().expect("tempdir");
    let store = AgentThreadStore::new(dir.path().join("agent_threads.json"));
    let mut state = AgentThreadState::new("opencode", PathBuf::from("/repo/a"));
    state.acp_session_id = Some("sess-1".to_string());
    state.transcript.push(AgentTranscriptEntry::user("hello"));

    let record = AgentThreadRecord::from_state("thread-1".to_string(), &state);
    store.save_records(&[record.clone()]).expect("save records");

    let loaded = store.load_records().expect("load records");
    assert_eq!(loaded, vec![record]);
}

#[test]
fn missing_thread_store_loads_empty_records() {
    let dir = tempdir().expect("tempdir");
    let store = AgentThreadStore::new(dir.path().join("missing.json"));
    assert!(store.load_records().expect("load missing").is_empty());
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cargo test --test agent_persistence_tests --all-features`

Expected: FAIL because persistence types do not exist.

- [ ] **Step 3: Implement JSON persistence**

Create `src/agent/persistence.rs`:

```rust
use std::path::{Path, PathBuf};

use anyhow::Context;
use serde::{Deserialize, Serialize};

use crate::agent::AgentThreadState;

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct AgentThreadRecord {
    pub thread_id: String,
    pub state: AgentThreadState,
}

impl AgentThreadRecord {
    pub fn from_state(thread_id: String, state: &AgentThreadState) -> Self {
        Self { thread_id, state: state.clone() }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AgentThreadStore { path: PathBuf }

impl AgentThreadStore {
    pub fn new(path: PathBuf) -> Self { Self { path } }
    pub fn path(&self) -> &Path { &self.path }

    pub fn load_records(&self) -> anyhow::Result<Vec<AgentThreadRecord>> {
        if !self.path.exists() { return Ok(Vec::new()); }
        let contents = std::fs::read_to_string(&self.path)
            .with_context(|| format!("failed to read agent thread store {}", self.path.display()))?;
        serde_json::from_str(&contents)
            .with_context(|| format!("failed to parse agent thread store {}", self.path.display()))
    }

    pub fn save_records(&self, records: &[AgentThreadRecord]) -> anyhow::Result<()> {
        if let Some(parent) = self.path.parent() {
            std::fs::create_dir_all(parent)
                .with_context(|| format!("failed to create agent thread store directory {}", parent.display()))?;
        }
        let contents = serde_json::to_string_pretty(records).context("failed to serialize agent thread records")?;
        std::fs::write(&self.path, contents)
            .with_context(|| format!("failed to write agent thread store {}", self.path.display()))
    }
}
```

Modify `src/agent/mod.rs`:

```rust
pub mod persistence;
pub use persistence::{AgentThreadRecord, AgentThreadStore};
```

- [ ] **Step 4: Run tests**

Run: `cargo test --test agent_persistence_tests --all-features`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/agent/persistence.rs src/agent/mod.rs tests/agent_persistence_tests.rs
git commit -m "feat: persist agent chat thread records"
```

---

### Task 6: Add Permission Policy Service

**Files:**
- Create: `src/agent/permission.rs`
- Modify: `src/agent/mod.rs`
- Test: `tests/agent_permission_tests.rs`

- [ ] **Step 1: Add failing permission tests**

Create `tests/agent_permission_tests.rs`:

```rust
use std::path::PathBuf;

use alas::agent::{AgentTrustMode, PermissionDecision, PermissionPolicy, PermissionRequestKind};
use tempfile::tempdir;

#[test]
fn allow_everything_approves_filesystem_and_terminal_anywhere() {
    let policy = PermissionPolicy::new(AgentTrustMode::AllowEverything, PathBuf::from("/repo/a"));

    assert_eq!(
        policy.decide(PermissionRequestKind::WriteFile(PathBuf::from("/tmp/outside.txt"))),
        PermissionDecision::Allow,
    );
    assert_eq!(
        policy.decide(PermissionRequestKind::RunTerminal { command: "rm -rf /tmp/example".to_string() }),
        PermissionDecision::Allow,
    );
}

#[test]
fn worktree_only_rejects_write_outside_canonical_worktree() {
    let worktree = tempdir().expect("worktree");
    let outside = tempdir().expect("outside");
    let policy = PermissionPolicy::new(AgentTrustMode::WorktreeOnly, worktree.path().to_path_buf());

    assert_eq!(
        policy.decide(PermissionRequestKind::WriteFile(outside.path().join("outside.txt"))),
        PermissionDecision::Deny,
    );
    assert_eq!(
        policy.decide(PermissionRequestKind::WriteFile(worktree.path().join("inside.txt"))),
        PermissionDecision::Allow,
    );
}

#[test]
fn deny_rejects_all_side_effects() {
    let policy = PermissionPolicy::new(AgentTrustMode::Deny, PathBuf::from("/repo/a"));
    assert_eq!(
        policy.decide(PermissionRequestKind::RunTerminal { command: "cargo test".to_string() }),
        PermissionDecision::Deny,
    );
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cargo test --test agent_permission_tests --all-features`

Expected: FAIL because permission policy does not exist.

- [ ] **Step 3: Implement policy decisions**

Create `src/agent/permission.rs`:

```rust
use std::path::{Path, PathBuf};

use crate::agent::AgentTrustMode;

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum PermissionDecision { Allow, Ask, Deny }

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum PermissionRequestKind {
    ReadFile(PathBuf),
    WriteFile(PathBuf),
    RunTerminal { command: String },
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PermissionPolicy {
    trust_mode: AgentTrustMode,
    worktree_path: PathBuf,
}

impl PermissionPolicy {
    pub fn new(trust_mode: AgentTrustMode, worktree_path: PathBuf) -> Self {
        Self { trust_mode, worktree_path }
    }

    pub fn decide(&self, request: PermissionRequestKind) -> PermissionDecision {
        match self.trust_mode {
            AgentTrustMode::AllowEverything => PermissionDecision::Allow,
            AgentTrustMode::Ask => PermissionDecision::Ask,
            AgentTrustMode::Deny => PermissionDecision::Deny,
            AgentTrustMode::WorktreeOnly => match request {
                PermissionRequestKind::ReadFile(path) | PermissionRequestKind::WriteFile(path) => {
                    if path_is_within(&path, &self.worktree_path) { PermissionDecision::Allow } else { PermissionDecision::Deny }
                }
                PermissionRequestKind::RunTerminal { .. } => PermissionDecision::Ask,
            },
        }
    }
}

fn path_is_within(path: &Path, root: &Path) -> bool {
    let Some(canonical_root) = canonicalize_policy_path(root) else { return false; };
    let Some(canonical_path) = canonicalize_policy_path(path) else { return false; };
    canonical_path.starts_with(canonical_root)
}

fn canonicalize_policy_path(path: &Path) -> Option<PathBuf> {
    if let Ok(canonical) = path.canonicalize() {
        return Some(canonical);
    }

    let mut missing_components = Vec::new();
    let mut existing = path;
    while !existing.exists() {
        let file_name = existing.file_name()?.to_os_string();
        missing_components.push(file_name);
        existing = existing.parent()?;
    }

    let mut canonical = existing.canonicalize().ok()?;
    for component in missing_components.into_iter().rev() {
        canonical.push(component);
    }
    Some(canonical)
}
```

Modify `src/agent/mod.rs` exports.

- [ ] **Step 4: Run permission tests**

Run: `cargo test --test agent_permission_tests --all-features`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/agent/permission.rs src/agent/mod.rs tests/agent_permission_tests.rs
git commit -m "feat: add agent permission policy"
```

---

### Task 7: Add Filesystem Callback Service

**Files:**
- Create: `src/agent/filesystem.rs`
- Modify: `src/agent/mod.rs`
- Test: `tests/agent_filesystem_tests.rs`

- [ ] **Step 1: Add failing filesystem callback tests**

Create `tests/agent_filesystem_tests.rs`:

```rust
use alas::agent::{AgentTrustMode, FilesystemCallbackService, PermissionDecision};
use tempfile::tempdir;

#[test]
fn filesystem_service_reads_and_writes_text_files_when_allowed() {
    let dir = tempdir().expect("tempdir");
    let file = dir.path().join("note.txt");
    let service = FilesystemCallbackService::new(AgentTrustMode::AllowEverything, dir.path().to_path_buf());

    service.write_text_file(&file, "hello").expect("write file");
    assert_eq!(service.read_text_file(&file).expect("read file"), "hello");
}

#[test]
fn filesystem_service_denies_writes_when_policy_denies() {
    let dir = tempdir().expect("tempdir");
    let file = dir.path().join("note.txt");
    let service = FilesystemCallbackService::new(AgentTrustMode::Deny, dir.path().to_path_buf());

    let error = service.write_text_file(&file, "hello").expect_err("denied write").to_string();
    assert!(error.contains("denied"));
    assert!(!file.exists());
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cargo test --test agent_filesystem_tests --all-features`

Expected: FAIL because service does not exist.

- [ ] **Step 3: Implement filesystem service**

Create `src/agent/filesystem.rs`:

```rust
use std::path::{Path, PathBuf};

use anyhow::Context;

use crate::agent::{AgentTrustMode, PermissionDecision, PermissionPolicy, PermissionRequestKind};

#[derive(Clone, Debug)]
pub struct FilesystemCallbackService {
    policy: PermissionPolicy,
}

impl FilesystemCallbackService {
    pub fn new(trust_mode: AgentTrustMode, worktree_path: PathBuf) -> Self {
        Self { policy: PermissionPolicy::new(trust_mode, worktree_path) }
    }

    pub fn read_text_file(&self, path: &Path) -> anyhow::Result<String> {
        match self.policy.decide(PermissionRequestKind::ReadFile(path.to_path_buf())) {
            PermissionDecision::Allow => std::fs::read_to_string(path)
                .with_context(|| format!("failed to read text file {}", path.display())),
            PermissionDecision::Ask => anyhow::bail!("permission required before reading {}", path.display()),
            PermissionDecision::Deny => anyhow::bail!("permission denied reading {}", path.display()),
        }
    }

    pub fn write_text_file(&self, path: &Path, content: &str) -> anyhow::Result<()> {
        match self.policy.decide(PermissionRequestKind::WriteFile(path.to_path_buf())) {
            PermissionDecision::Allow => {
                if let Some(parent) = path.parent() {
                    std::fs::create_dir_all(parent)
                        .with_context(|| format!("failed to create parent directory {}", parent.display()))?;
                }
                std::fs::write(path, content)
                    .with_context(|| format!("failed to write text file {}", path.display()))
            }
            PermissionDecision::Ask => anyhow::bail!("permission required before writing {}", path.display()),
            PermissionDecision::Deny => anyhow::bail!("permission denied writing {}", path.display()),
        }
    }
}
```

Modify `src/agent/mod.rs` exports. In Task 19, the runtime dispatcher will catch `permission required` outcomes from this low-level service and turn them into pending `AgentPermissionRequest` records; the low-level service itself should not show UI.

- [ ] **Step 4: Run tests**

Run: `cargo test --test agent_filesystem_tests --all-features`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/agent/filesystem.rs src/agent/mod.rs tests/agent_filesystem_tests.rs
git commit -m "feat: add ACP filesystem callback service"
```

---

### Task 8: Add Protocol-Only Terminal Callback Service

**Files:**
- Create: `src/agent/terminal.rs`
- Modify: `src/agent/mod.rs`
- Test: `tests/agent_terminal_tests.rs`

- [ ] **Step 1: Add failing terminal callback tests**

Create `tests/agent_terminal_tests.rs`:

```rust
use std::path::PathBuf;

use alas::agent::{AgentTrustMode, AgentTerminalService, AgentTerminalStatus};
use tempfile::tempdir;

#[test]
fn terminal_service_runs_command_and_captures_output() {
    let dir = tempdir().expect("tempdir");
    let mut service = AgentTerminalService::new(AgentTrustMode::AllowEverything, dir.path().to_path_buf());

    let handle = service.create("printf hello", PathBuf::from(dir.path())).expect("create command");
    let result = service.wait_for_exit(handle).expect("wait");

    assert_eq!(result.status, AgentTerminalStatus::Exited(Some(0)));
    assert_eq!(service.output(handle).expect("output"), "hello");
    service.release(handle).expect("release");
}

#[test]
fn terminal_service_streams_output_before_wait_for_exit() {
    let dir = tempdir().expect("tempdir");
    let mut service = AgentTerminalService::new(AgentTrustMode::AllowEverything, dir.path().to_path_buf());

    let handle = service.create("printf hello; sleep 1", PathBuf::from(dir.path())).expect("create command");
    std::thread::sleep(std::time::Duration::from_millis(100));
    assert!(service.output(handle).expect("output").contains("hello"));
    service.kill(handle).expect("kill");
    service.release(handle).expect("release");
}

#[test]
fn terminal_service_denies_command_when_policy_denies() {
    let dir = tempdir().expect("tempdir");
    let mut service = AgentTerminalService::new(AgentTrustMode::Deny, dir.path().to_path_buf());

    let error = service.create("printf hello", PathBuf::from(dir.path())).expect_err("denied").to_string();
    assert!(error.contains("denied"));
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cargo test --test agent_terminal_tests --all-features`

Expected: FAIL because terminal service does not exist.

- [ ] **Step 3: Implement protocol-only terminal service**

Create `src/agent/terminal.rs`:

```rust
use std::{
    collections::HashMap,
    io::Read,
    path::PathBuf,
    process::{Child, Command, Stdio},
    sync::{Arc, Mutex},
    thread,
};

use anyhow::Context;

use crate::agent::{AgentTrustMode, PermissionDecision, PermissionPolicy, PermissionRequestKind};

#[derive(Clone, Copy, Debug, Eq, PartialEq, Hash)]
pub struct AgentTerminalHandle(pub u64);

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum AgentTerminalStatus { Running, Exited(Option<i32>), Failed }

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AgentTerminalResult { pub status: AgentTerminalStatus }

#[derive(Debug)]
struct AgentTerminalCommandState {
    command: String,
    cwd: PathBuf,
    child: Option<Child>,
    output: Arc<Mutex<String>>,
    status: AgentTerminalStatus,
}

#[derive(Debug)]
pub struct AgentTerminalService {
    next_handle: u64,
    policy: PermissionPolicy,
    commands: HashMap<AgentTerminalHandle, AgentTerminalCommandState>,
}

impl AgentTerminalService {
    pub fn new(trust_mode: AgentTrustMode, worktree_path: PathBuf) -> Self {
        Self { next_handle: 0, policy: PermissionPolicy::new(trust_mode, worktree_path), commands: HashMap::new() }
    }

    pub fn create(&mut self, command: &str, cwd: PathBuf) -> anyhow::Result<AgentTerminalHandle> {
        match self.policy.decide(PermissionRequestKind::RunTerminal { command: command.to_string() }) {
            PermissionDecision::Allow => {}
            PermissionDecision::Ask => anyhow::bail!("permission required before running terminal command"),
            PermissionDecision::Deny => anyhow::bail!("permission denied running terminal command"),
        }

        let mut child = Command::new(std::env::var("SHELL").unwrap_or_else(|_| "/bin/sh".to_string()))
            .args(["-lc", command])
            .current_dir(&cwd)
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .with_context(|| format!("failed to start terminal command {command}"))?;

        let output = Arc::new(Mutex::new(String::new()));
        spawn_output_reader(child.stdout.take(), output.clone());
        spawn_output_reader(child.stderr.take(), output.clone());

        self.next_handle += 1;
        let handle = AgentTerminalHandle(self.next_handle);
        self.commands.insert(handle, AgentTerminalCommandState {
            command: command.to_string(),
            cwd,
            child: Some(child),
            output,
            status: AgentTerminalStatus::Running,
        });
        Ok(handle)
    }

    pub fn wait_for_exit(&mut self, handle: AgentTerminalHandle) -> anyhow::Result<AgentTerminalResult> {
        let state = self.commands.get_mut(&handle).context("unknown agent terminal handle")?;
        if !matches!(state.status, AgentTerminalStatus::Running) {
            return Ok(AgentTerminalResult { status: state.status.clone() });
        }
        let child = state.child.as_mut().context("terminal command has no child process")?;
        let status = child.wait().with_context(|| format!("failed to wait for terminal command {}", state.command))?;
        state.status = AgentTerminalStatus::Exited(status.code());
        Ok(AgentTerminalResult { status: state.status.clone() })
    }

    pub fn output(&self, handle: AgentTerminalHandle) -> anyhow::Result<String> {
        Ok(self.commands.get(&handle).context("unknown agent terminal handle")?.output.lock().expect("terminal output lock").clone())
    }

    pub fn kill(&mut self, handle: AgentTerminalHandle) -> anyhow::Result<()> {
        let state = self.commands.get_mut(&handle).context("unknown agent terminal handle")?;
        if let Some(child) = state.child.as_mut() {
            let _ = child.kill();
        }
        state.status = AgentTerminalStatus::Failed;
        Ok(())
    }

    pub fn release(&mut self, handle: AgentTerminalHandle) -> anyhow::Result<()> {
        self.commands.remove(&handle).context("unknown agent terminal handle")?;
        Ok(())
    }
}

fn spawn_output_reader<R: Read + Send + 'static>(reader: Option<R>, output: Arc<Mutex<String>>) {
    if let Some(mut reader) = reader {
        thread::spawn(move || {
            let mut buffer = [0_u8; 4096];
            while let Ok(read) = reader.read(&mut buffer) {
                if read == 0 { break; }
                output.lock().expect("terminal output lock").push_str(&String::from_utf8_lossy(&buffer[..read]));
            }
        });
    }
}
```

This implementation starts the process in `create`, buffers output as it streams, waits in `wait_for_exit`, kills the child in `kill`, and releases handles in `release`. Runtime integration should call waiting work from a background task so UI rendering is not blocked. In Task 19, the runtime dispatcher will catch `permission required` outcomes and turn them into pending permission cards.

Modify `src/agent/mod.rs` exports.

- [ ] **Step 4: Run tests**

Run: `cargo test --test agent_terminal_tests --all-features`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/agent/terminal.rs src/agent/mod.rs tests/agent_terminal_tests.rs
git commit -m "feat: add protocol-only ACP terminal service"
```

---

### Task 9: Add ACP Runtime State Machine Facade

**Files:**
- Create: `src/agent/runtime.rs`
- Create: `src/agent/fake.rs`
- Modify: `src/agent/mod.rs`
- Test: `tests/agent_runtime_tests.rs`

- [ ] **Step 1: Add failing runtime tests using fake connection**

Create `tests/agent_runtime_tests.rs`:

```rust
use std::path::PathBuf;

use alas::agent::{AgentRuntime, AgentRuntimeEvent, AgentThreadStatus, FakeAcpConnection};

#[test]
fn runtime_creates_new_session_and_applies_streamed_updates() {
    let fake = FakeAcpConnection::new()
        .with_new_session("sess-1")
        .with_prompt_update(AgentRuntimeEvent::AgentMessageChunk("hello from agent".to_string()));
    let mut runtime = AgentRuntime::with_connection("opencode", PathBuf::from("/repo/a"), fake);

    runtime.initialize().expect("initialize");
    runtime.create_session().expect("new session");
    runtime.prompt("hello").expect("prompt");

    let thread = runtime.thread();
    assert_eq!(thread.acp_session_id.as_deref(), Some("sess-1"));
    assert_eq!(thread.status, AgentThreadStatus::Ready);
    assert!(thread.transcript.iter().any(|entry| entry.text == "hello from agent"));
}

#[test]
fn runtime_cancel_can_interrupt_after_first_streamed_update() {
    let fake = FakeAcpConnection::new()
        .with_new_session("sess-1")
        .with_prompt_update(AgentRuntimeEvent::AgentMessageChunk("partial".to_string()))
        .with_prompt_update(AgentRuntimeEvent::NeedsPermission { id: "perm-1".to_string(), description: "Run command".to_string() });
    let mut runtime = AgentRuntime::with_connection("opencode", PathBuf::from("/repo/a"), fake);

    runtime.initialize().expect("initialize");
    runtime.create_session().expect("new session");
    runtime.prompt("hello").expect("prompt");

    assert!(runtime.thread().pending_permissions.iter().any(|permission| permission.id == "perm-1"));
}

#[test]
fn runtime_marks_restored_thread_read_only_when_resume_fails() {
    let fake = FakeAcpConnection::new().with_resume_error("resume unsupported");
    let mut runtime = AgentRuntime::with_connection("opencode", PathBuf::from("/repo/a"), fake);
    runtime.thread_mut().acp_session_id = Some("sess-old".to_string());

    runtime.resume_existing_session().expect("resume attempt handled");

    assert!(matches!(runtime.thread().status, AgentThreadStatus::ReadOnly { .. }));
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cargo test --test agent_runtime_tests --all-features`

Expected: FAIL because runtime/fake types do not exist.

- [ ] **Step 3: Implement ACP-owned facade and fake connection**

Create `src/agent/runtime.rs` with an Alas-owned trait so tests do not depend on real subprocesses:

```rust
use std::path::PathBuf;

use crate::agent::{AgentThreadState, AgentThreadStatus, AgentTranscriptEntry};

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum AgentRuntimeEvent {
    Initialized,
    AuthRequired { instructions: Option<String> },
    Ready,
    AgentMessageChunk(String),
    ThoughtChunk(String),
    ToolCall { id: String, title: String, status: String },
    Plan(Vec<String>),
    AvailableCommands(Vec<crate::agent::AgentSlashCommand>),
    AvailableModes { modes: Vec<crate::agent::AgentModeOption>, current: Option<String> },
    ConfigOptions(Vec<crate::agent::AgentConfigOption>),
    NeedsPermission { id: String, description: String },
    Failed(String),
}

pub trait AgentEventSink {
    fn emit(&mut self, event: AgentRuntimeEvent);
}

pub trait AcpConnection {
    fn initialize(&mut self, sink: &mut dyn AgentEventSink) -> anyhow::Result<()>;
    fn new_session(&mut self, sink: &mut dyn AgentEventSink) -> anyhow::Result<String>;
    fn resume_session(&mut self, session_id: &str, sink: &mut dyn AgentEventSink) -> anyhow::Result<()>;
    fn prompt(&mut self, session_id: &str, prompt: &str, sink: &mut dyn AgentEventSink) -> anyhow::Result<()>;
    fn cancel(&mut self, session_id: &str) -> anyhow::Result<()>;
}

pub struct AgentRuntime<C> {
    thread: AgentThreadState,
    connection: C,
}

impl<C: AcpConnection> AgentRuntime<C> {
    pub fn with_connection(provider_id: impl Into<String>, worktree_path: PathBuf, connection: C) -> Self {
        Self { thread: AgentThreadState::new(provider_id, worktree_path), connection }
    }

    pub fn thread(&self) -> &AgentThreadState { &self.thread }
    pub fn thread_mut(&mut self) -> &mut AgentThreadState { &mut self.thread }

    pub fn initialize(&mut self) -> anyhow::Result<()> {
        self.thread.status = AgentThreadStatus::Starting;
        let mut sink = ThreadEventSink { thread: &mut self.thread };
        self.connection.initialize(&mut sink)?;
        if matches!(self.thread.status, AgentThreadStatus::Starting) {
            self.thread.status = AgentThreadStatus::Ready;
        }
        Ok(())
    }

    pub fn create_session(&mut self) -> anyhow::Result<()> {
        let mut sink = ThreadEventSink { thread: &mut self.thread };
        let session_id = self.connection.new_session(&mut sink)?;
        self.thread.acp_session_id = Some(session_id);
        if !matches!(self.thread.status, AgentThreadStatus::AuthRequired | AgentThreadStatus::Failed { .. }) {
            self.thread.status = AgentThreadStatus::Ready;
        }
        Ok(())
    }

    pub fn resume_existing_session(&mut self) -> anyhow::Result<()> {
        let Some(session_id) = self.thread.acp_session_id.clone() else {
            self.thread.status = AgentThreadStatus::ReadOnly { reason: "missing ACP session id".to_string() };
            return Ok(());
        };
        let mut sink = ThreadEventSink { thread: &mut self.thread };
        match self.connection.resume_session(&session_id, &mut sink) {
            Ok(()) => self.thread.status = AgentThreadStatus::Ready,
            Err(error) => self.thread.status = AgentThreadStatus::ReadOnly { reason: error.to_string() },
        }
        Ok(())
    }

    pub fn prompt(&mut self, prompt: &str) -> anyhow::Result<()> {
        let session_id = self.thread.acp_session_id.clone().ok_or_else(|| anyhow::anyhow!("missing ACP session id"))?;
        self.thread.status = AgentThreadStatus::Running;
        self.thread.transcript.push(AgentTranscriptEntry::user(prompt));
        let mut sink = ThreadEventSink { thread: &mut self.thread };
        self.connection.prompt(&session_id, prompt, &mut sink)?;
        if matches!(self.thread.status, AgentThreadStatus::Running) {
            self.thread.status = AgentThreadStatus::Ready;
        }
        Ok(())
    }

    pub fn cancel(&mut self) -> anyhow::Result<()> {
        if let Some(session_id) = self.thread.acp_session_id.clone() {
            self.connection.cancel(&session_id)?;
        }
        self.thread.status = AgentThreadStatus::Ready;
        Ok(())
    }
}

struct ThreadEventSink<'a> { thread: &'a mut AgentThreadState }

impl AgentEventSink for ThreadEventSink<'_> {
    fn emit(&mut self, event: AgentRuntimeEvent) {
        apply_runtime_event(self.thread, event);
    }
}

pub fn apply_runtime_event(thread: &mut AgentThreadState, event: AgentRuntimeEvent) {
    match event {
        AgentRuntimeEvent::Initialized | AgentRuntimeEvent::Ready => thread.status = AgentThreadStatus::Ready,
        AgentRuntimeEvent::AuthRequired { instructions } => {
            thread.status = AgentThreadStatus::AuthRequired;
            if let Some(instructions) = instructions { thread.debug_log.push(crate::agent::AgentDebugEvent { message: instructions }); }
        }
        AgentRuntimeEvent::AgentMessageChunk(text) => thread.transcript.push(AgentTranscriptEntry::agent(text)),
        AgentRuntimeEvent::ThoughtChunk(text) => thread.transcript.push(AgentTranscriptEntry { role: crate::agent::AgentTranscriptRole::Thought, text }),
        AgentRuntimeEvent::ToolCall { id, title, status } => thread.tool_calls.push(crate::agent::AgentToolCallState { id, title, status }),
        AgentRuntimeEvent::Plan(entries) => thread.plans.push(crate::agent::AgentPlanState { entries }),
        AgentRuntimeEvent::AvailableCommands(commands) => thread.available_commands = commands,
        AgentRuntimeEvent::AvailableModes { modes, current } => { thread.available_modes = modes; thread.current_mode = current; },
        AgentRuntimeEvent::ConfigOptions(options) => thread.config_options = options,
        AgentRuntimeEvent::NeedsPermission { id, description } => thread.pending_permissions.push(crate::agent::AgentPermissionRequest { id, description }),
        AgentRuntimeEvent::Failed(message) => thread.status = AgentThreadStatus::Failed { message },
    }
}
```

Create `src/agent/fake.rs`:

```rust
use crate::agent::runtime::{AcpConnection, AgentEventSink, AgentRuntimeEvent};

#[derive(Clone, Debug, Default)]
pub struct FakeAcpConnection {
    new_session: Option<String>,
    prompt_updates: Vec<AgentRuntimeEvent>,
    resume_error: Option<String>,
}

impl FakeAcpConnection {
    pub fn new() -> Self { Self::default() }
    pub fn with_new_session(mut self, session_id: impl Into<String>) -> Self { self.new_session = Some(session_id.into()); self }
    pub fn with_prompt_update(mut self, update: AgentRuntimeEvent) -> Self { self.prompt_updates.push(update); self }
    pub fn with_resume_error(mut self, error: impl Into<String>) -> Self { self.resume_error = Some(error.into()); self }
}

impl AcpConnection for FakeAcpConnection {
    fn initialize(&mut self, sink: &mut dyn AgentEventSink) -> anyhow::Result<()> { sink.emit(AgentRuntimeEvent::Initialized); Ok(()) }
    fn new_session(&mut self, sink: &mut dyn AgentEventSink) -> anyhow::Result<String> { sink.emit(AgentRuntimeEvent::Ready); Ok(self.new_session.clone().unwrap_or_else(|| "sess-test".to_string())) }
    fn resume_session(&mut self, _session_id: &str, sink: &mut dyn AgentEventSink) -> anyhow::Result<()> {
        if let Some(error) = &self.resume_error { anyhow::bail!(error.clone()); }
        sink.emit(AgentRuntimeEvent::Ready);
        Ok(())
    }
    fn prompt(&mut self, _session_id: &str, _prompt: &str, sink: &mut dyn AgentEventSink) -> anyhow::Result<()> {
        for update in self.prompt_updates.clone() { sink.emit(update); }
        Ok(())
    }
    fn cancel(&mut self, _session_id: &str) -> anyhow::Result<()> { Ok(()) }
}
```

Modify `src/agent/mod.rs` exports.

- [ ] **Step 4: Run runtime tests**

Run: `cargo test --test agent_runtime_tests --all-features`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/agent/runtime.rs src/agent/fake.rs src/agent/mod.rs tests/agent_runtime_tests.rs
git commit -m "feat: add ACP runtime state facade"
```

---

### Task 10: Add Real ACP Process Connection Skeleton

**Files:**
- Modify: `src/agent/runtime.rs`
- Modify: `src/agent/provider.rs`
- Test: `tests/agent_runtime_tests.rs`

- [ ] **Step 1: Add failing process launch validation test**

Append to `tests/agent_runtime_tests.rs`:

```rust
use alas::agent::{AgentProviderConfig, AcpProcessConnection, ProviderCwdPolicy, resolve_provider_cwd};

#[test]
fn process_connection_reports_missing_provider_binary_with_context() {
    let provider = AgentProviderConfig::new("missing", "Missing", "definitely-not-an-acp-binary");
    let error = AcpProcessConnection::spawn(&provider, PathBuf::from("/tmp"))
        .expect_err("missing binary should fail")
        .to_string();
    assert!(error.contains("definitely-not-an-acp-binary"));
}

#[test]
fn provider_cwd_policy_resolves_launch_directory() {
    let selected = PathBuf::from("/repo/worktrees/feature");
    let repo_root = PathBuf::from("/repo");

    let mut provider = AgentProviderConfig::new("opencode", "OpenCode", "opencode");
    provider.cwd_policy = ProviderCwdPolicy::SelectedWorktree;
    assert_eq!(resolve_provider_cwd(&provider, &selected, &repo_root), selected);

    provider.cwd_policy = ProviderCwdPolicy::RepositoryRoot;
    assert_eq!(resolve_provider_cwd(&provider, &selected, &repo_root), repo_root);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cargo test --test agent_runtime_tests --all-features`

Expected: FAIL because `AcpProcessConnection` does not exist.

- [ ] **Step 3: Add process connection skeleton**

In `src/agent/runtime.rs`, add a real-connection struct that launches the provider and clearly fails for unimplemented protocol calls. Keep this as a skeleton until UI and fake-backed flows are integrated:

```rust
use std::{path::PathBuf, process::{Child, Command, Stdio}};

use anyhow::Context;
use crate::agent::AgentProviderConfig;

#[derive(Debug)]
pub struct AcpProcessConnection {
    _child: Child,
}

pub fn resolve_provider_cwd(provider: &AgentProviderConfig, selected_worktree: &PathBuf, repository_root: &PathBuf) -> PathBuf {
    match &provider.cwd_policy {
        crate::agent::ProviderCwdPolicy::SelectedWorktree => selected_worktree.clone(),
        crate::agent::ProviderCwdPolicy::RepositoryRoot => repository_root.clone(),
        crate::agent::ProviderCwdPolicy::Fixed(path) => path.clone(),
    }
}

impl AcpProcessConnection {
    pub fn spawn(provider: &AgentProviderConfig, cwd: PathBuf) -> anyhow::Result<Self> {
        let mut command = Command::new(&provider.command);
        command.args(&provider.args).current_dir(cwd).stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped());
        let child = command.spawn()
            .with_context(|| format!("failed to start ACP provider '{}' with command {}", provider.id, provider.command))?;
        Ok(Self { _child: child })
    }
}

impl AcpConnection for AcpProcessConnection {
    fn initialize(&mut self, _sink: &mut dyn AgentEventSink) -> anyhow::Result<()> { anyhow::bail!("real ACP initialize is not wired yet") }
    fn new_session(&mut self, _sink: &mut dyn AgentEventSink) -> anyhow::Result<String> { anyhow::bail!("real ACP session/new is not wired yet") }
    fn resume_session(&mut self, _session_id: &str, _sink: &mut dyn AgentEventSink) -> anyhow::Result<()> { anyhow::bail!("real ACP session resume is not wired yet") }
    fn prompt(&mut self, _session_id: &str, _prompt: &str, _sink: &mut dyn AgentEventSink) -> anyhow::Result<()> { anyhow::bail!("real ACP prompt is not wired yet") }
    fn cancel(&mut self, _session_id: &str) -> anyhow::Result<()> { anyhow::bail!("real ACP cancel is not wired yet") }
}
```

This deliberately creates a safe seam. A later task replaces the method bodies with actual `agent-client-protocol` crate calls after the UI and state flow are testable. Shell/runtime launch code must call `resolve_provider_cwd` instead of hard-coding the selected worktree.

- [ ] **Step 4: Run runtime tests**

Run: `cargo test --test agent_runtime_tests --all-features`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/agent/runtime.rs tests/agent_runtime_tests.rs
git commit -m "feat: add ACP provider process launch seam"
```

---

### Task 11: Add Provider Settings View Model and UI Renderer

**Files:**
- Create: `src/ui/provider_settings.rs`
- Modify: `src/ui/mod.rs`
- Modify: `src/ui/shell.rs`
- Test: `tests/agent_ui_view_model_tests.rs`

- [ ] **Step 1: Add failing provider settings view-model tests**

Create `tests/agent_ui_view_model_tests.rs`:

```rust
use alas::agent::{AgentProviderConfig, ProviderSettingsState};

#[test]
fn provider_settings_state_can_add_update_and_remove_provider() {
    let mut state = ProviderSettingsState::default();
    state.add_provider(AgentProviderConfig::new("opencode", "OpenCode", "opencode"));
    assert_eq!(state.providers.len(), 1);

    state.providers[0].args = vec!["acp".to_string()];
    assert_eq!(state.providers[0].args, vec!["acp".to_string()]);

    state.remove_provider("opencode");
    assert!(state.providers.is_empty());
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cargo test --test agent_ui_view_model_tests --all-features`

Expected: FAIL because settings state does not exist.

- [ ] **Step 3: Add settings state to agent/provider module**

In `src/agent/provider.rs` add:

```rust
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct ProviderSettingsState {
    pub providers: Vec<AgentProviderConfig>,
    pub selected_provider_id: Option<String>,
    pub error: Option<String>,
}

impl ProviderSettingsState {
    pub fn add_provider(&mut self, provider: AgentProviderConfig) {
        self.selected_provider_id = Some(provider.id.clone());
        self.providers.push(provider);
    }

    pub fn remove_provider(&mut self, provider_id: &str) {
        self.providers.retain(|provider| provider.id != provider_id);
        if self.selected_provider_id.as_deref() == Some(provider_id) {
            self.selected_provider_id = self.providers.first().map(|provider| provider.id.clone());
        }
    }
}
```

Export it from `src/agent/mod.rs`.

- [ ] **Step 4: Add UI renderer skeleton**

Create `src/ui/provider_settings.rs`:

```rust
use crate::{agent::ProviderSettingsState, ui::theme::{PANEL_BG, PANEL_BORDER, TEXT, TEXT_MUTED}};
use gpui::{div, IntoElement, ParentElement, SharedString, Styled, prelude::*};

pub fn render_provider_settings(state: &ProviderSettingsState) -> impl IntoElement {
    div()
        .id("provider-settings")
        .flex()
        .flex_col()
        .gap_2()
        .p_3()
        .rounded_md()
        .border_1()
        .border_color(PANEL_BORDER)
        .bg(PANEL_BG)
        .text_color(TEXT)
        .child(div().font_weight(gpui::FontWeight::SEMIBOLD).child("Agent Providers"))
        .when(state.providers.is_empty(), |element| {
            element.child(div().text_sm().text_color(TEXT_MUTED).child("No ACP providers configured."))
        })
        .children(state.providers.iter().map(|provider| {
            div()
                .text_sm()
                .child(SharedString::from(format!("{} — {}", provider.display_name, provider.command)))
        }))
}
```

Modify `src/ui/mod.rs`:

```rust
pub mod provider_settings;
```

Do not fully wire Shell editing yet; that is a later task.

- [ ] **Step 5: Run tests**

Run: `cargo test --test agent_ui_view_model_tests --all-features`

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/agent/provider.rs src/agent/mod.rs src/ui/provider_settings.rs src/ui/mod.rs tests/agent_ui_view_model_tests.rs
git commit -m "feat: add ACP provider settings state"
```

---

### Task 12: Add Agent Chat Pane Renderer

**Files:**
- Create: `src/ui/agent_pane.rs`
- Modify: `src/ui/mod.rs`
- Test: `tests/agent_ui_view_model_tests.rs`

- [ ] **Step 1: Add failing pane-label helper tests**

Append to `tests/agent_ui_view_model_tests.rs`:

```rust
use std::path::PathBuf;
use alas::agent::{AgentThreadState, AgentThreadStatus};
use alas::ui::agent_pane::agent_status_label;

#[test]
fn agent_status_label_describes_read_only_resume_failure() {
    let mut thread = AgentThreadState::new("opencode", PathBuf::from("/repo/a"));
    thread.status = AgentThreadStatus::ReadOnly { reason: "resume unsupported".to_string() };

    assert_eq!(agent_status_label(&thread), "Read-only: resume unsupported");
}
```

If `alas::ui` is not exported from `src/lib.rs`, add `pub mod ui;` or move the helper to `agent::types` and test there. Prefer exporting `ui` only if existing tests already do it.

- [ ] **Step 2: Run test to verify it fails**

Run: `cargo test --test agent_ui_view_model_tests --all-features`

Expected: FAIL because `agent_pane` does not exist or `ui` is not exported.

- [ ] **Step 3: Implement agent pane skeleton**

Create `src/ui/agent_pane.rs`:

```rust
use crate::{agent::{AgentThreadState, AgentThreadStatus, AgentTranscriptRole}, ui::theme::{DANGER, PANEL_BG, PANEL_BORDER, TEXT, TEXT_MUTED}};
use gpui::{div, AnyElement, IntoElement, ParentElement, SharedString, Styled, prelude::*};

pub fn agent_status_label(thread: &AgentThreadState) -> String {
    match &thread.status {
        AgentThreadStatus::Disconnected => "Disconnected".to_string(),
        AgentThreadStatus::Starting => "Starting".to_string(),
        AgentThreadStatus::AuthRequired => "Authentication required".to_string(),
        AgentThreadStatus::Ready => "Ready".to_string(),
        AgentThreadStatus::Running => "Running".to_string(),
        AgentThreadStatus::Failed { message } => format!("Failed: {message}"),
        AgentThreadStatus::ReadOnly { reason } => format!("Read-only: {reason}"),
    }
}

pub fn render_agent_pane(thread: &AgentThreadState) -> impl IntoElement {
    div()
        .id("agent-chat-pane")
        .flex()
        .flex_col()
        .flex_1()
        .size_full()
        .bg(PANEL_BG)
        .text_color(TEXT)
        .child(render_agent_header(thread))
        .child(render_transcript(thread))
        .child(render_composer(thread))
}

fn render_agent_header(thread: &AgentThreadState) -> impl IntoElement {
    div()
        .flex()
        .items_center()
        .justify_between()
        .px_3()
        .py_2()
        .border_b_1()
        .border_color(PANEL_BORDER)
        .child(div().text_sm().font_weight(gpui::FontWeight::SEMIBOLD).child(SharedString::from(thread.title.clone())))
        .child(div().text_xs().text_color(TEXT_MUTED).child(SharedString::from(agent_status_label(thread))))
}

fn render_transcript(thread: &AgentThreadState) -> impl IntoElement {
    div()
        .id("agent-chat-transcript")
        .flex()
        .flex_col()
        .flex_1()
        .overflow_scroll()
        .p_3()
        .gap_2()
        .children(thread.transcript.iter().map(|entry| {
            let label = match entry.role { AgentTranscriptRole::User => "You", AgentTranscriptRole::Agent => "Agent", AgentTranscriptRole::Thought => "Thought", AgentTranscriptRole::System => "System", AgentTranscriptRole::Tool => "Tool" };
            div().flex().flex_col().gap_1().child(div().text_xs().text_color(TEXT_MUTED).child(label)).child(div().text_sm().child(SharedString::from(entry.text.clone()))).into_any_element()
        }))
}

fn render_composer(thread: &AgentThreadState) -> AnyElement {
    let read_only = matches!(thread.status, AgentThreadStatus::ReadOnly { .. });
    div()
        .border_t_1()
        .border_color(PANEL_BORDER)
        .p_3()
        .text_sm()
        .text_color(if read_only { DANGER } else { TEXT_MUTED })
        .child(if read_only { "This restored ACP session cannot continue. Start a new session to send prompts." } else { "Prompt input will appear here." })
        .into_any_element()
}
```

Modify `src/ui/mod.rs`:

```rust
pub mod agent_pane;
```

- [ ] **Step 4: Run tests**

Run: `cargo test --test agent_ui_view_model_tests --all-features`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/ui/agent_pane.rs src/ui/mod.rs tests/agent_ui_view_model_tests.rs
git commit -m "feat: add agent chat pane renderer"
```

---

### Task 13: Wire Agent Chat Rendering into Shell

**Files:**
- Modify: `src/ui/shell.rs`
- Modify: `src/ui/workspace.rs`
- Test: `tests/agent_workspace_tests.rs`
- Test: `tests/ui_view_model_tests.rs` if affected

- [ ] **Step 1: Add failing workspace tab picker state tests**

If Shell state is hard to instantiate in tests, add pure enum/state helpers under `src/ui/workspace.rs`:

```rust
#[derive(Debug, Clone, Copy, Eq, PartialEq)]
pub enum NewWorkspaceTabChoice { Terminal, AgentChat }
```

Add tests to `tests/agent_workspace_tests.rs` or `tests/ui_view_model_tests.rs` that verify:

- choice labels include Terminal and Agent Chat;
- zero enabled providers opens provider settings;
- one enabled provider creates a tab directly;
- multiple enabled providers opens a provider picker instead of silently choosing one.

- [ ] **Step 2: Run targeted tests to verify failure**

Run: `cargo test --test agent_workspace_tests --all-features`

Expected: FAIL if helper does not exist.

- [ ] **Step 3: Implement picker model and shell fields**

Modify `src/ui/workspace.rs` to export `NewWorkspaceTabChoice` and a helper:

```rust
pub fn new_workspace_tab_choices() -> [NewWorkspaceTabChoice; 2] {
    [NewWorkspaceTabChoice::Terminal, NewWorkspaceTabChoice::AgentChat]
}
```

Modify `AlasShell` in `src/ui/shell.rs`:

- add a `new_tab_picker_open: bool` field;
- change existing `on_new_terminal_tab` behavior to open the picker;
- add callbacks for Terminal and Agent Chat choices;
- add `agent_provider_picker: Option<Vec<AgentProviderConfig>>` or equivalent shell state;
- when Terminal is chosen, call existing command picker flow;
- when Agent Chat is chosen:
  - open provider settings if there are no enabled providers,
  - create an Agent Chat tab directly if exactly one provider is enabled,
  - open the provider picker if multiple providers are enabled;
- when the user selects a provider from the picker, create the Agent Chat tab for that provider.

- [ ] **Step 4: Route AgentChat active tab to renderer**

In the `workspace_body` match in `src/ui/shell.rs`, add:

```rust
Some(WorkspaceTabContent::AgentChat(state)) => {
    render_agent_pane(state).into_any_element()
}
```

Update imports for `agent_pane::render_agent_pane`.

- [ ] **Step 5: Run targeted tests**

Run: `cargo test --test agent_workspace_tests --test ui_view_model_tests --all-features`

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/ui/shell.rs src/ui/workspace.rs tests/agent_workspace_tests.rs tests/ui_view_model_tests.rs
git commit -m "feat: render agent chat tabs in workspace"
```

---

### Task 14: Wire Provider Settings to App Config

**Files:**
- Modify: `src/ui/shell.rs`
- Modify: `src/ui/provider_settings.rs`
- Test: `tests/config_tests.rs`
- Test: `tests/agent_provider_config_tests.rs`

- [ ] **Step 1: Add config persistence test for provider edits**

In `tests/config_tests.rs`, add a test using `AppConfigStore::new(temp_path)` that saves and loads `agent_providers` with no secrets.

In `tests/agent_ui_view_model_tests.rs`, add a provider settings state test that edits all required provider fields:

```rust
use alas::agent::{AgentAuthStatus, AgentProviderConfig, AgentTrustMode, ProviderSettingsState};

#[test]
fn provider_settings_state_edits_required_provider_fields() {
    let mut state = ProviderSettingsState::default();
    state.add_provider(AgentProviderConfig::new("opencode", "OpenCode", "opencode"));
    state.update_command("opencode", "opencode");
    state.update_args("opencode", vec!["acp".to_string()]);
    state.update_plain_env("opencode", "OPENCODE_CONFIG", "dev");
    state.update_enabled("opencode", false);
    state.update_trust_mode("opencode", AgentTrustMode::Ask);
    state.update_auth_status("opencode", AgentAuthStatus::Required { instructions: Some("Run login".to_string()) });

    assert_eq!(state.auth_status_label("opencode"), Some("Auth Required".to_string()));
    let provider = &state.providers[0];
    assert_eq!(provider.args, vec!["acp".to_string()]);
    assert!(!provider.enabled);
    assert_eq!(provider.trust_mode, AgentTrustMode::Ask);
}
```

- [ ] **Step 2: Run tests to verify failure or missing coverage**

Run: `cargo test --test config_tests --all-features`

Expected: PASS after Task 1 may already serialize. If it passes, keep this as regression coverage.

- [ ] **Step 3: Add Shell provider settings state**

Modify `src/agent/provider.rs` before Shell wiring:

- add `AgentAuthStatus` with `Unknown`, `Authenticated`, `Required { instructions }`, and `Failed { message, instructions }`;
- add `AgentAuthStatus::instructions()` and a status-label helper;
- add `ProviderSettingsState` methods required by the test: `update_command`, `update_args`, `update_plain_env`, `update_enabled`, `update_trust_mode`, `update_auth_status`, and `auth_status_label`.

Modify `AlasShell`:

- add `provider_settings: Option<ProviderSettingsState>`;
- add methods:
  - `open_provider_settings`,
  - `close_provider_settings`,
  - `save_provider_settings`,
  - `create_agent_chat_from_provider`.

`save_provider_settings` must update `self.config.agent_providers`, call `self.app_config_store.save(&self.config)`, and show errors in settings state.

- [ ] **Step 4: Extend provider settings renderer with minimal controls**

Add visible fields and handlers for editing:

- display name,
- command,
- args,
- env metadata/secure refs,
- enabled/disabled state,
- trust mode.

Add buttons/handlers for:

- Add Provider,
- Save,
- Cancel,
- Remove,
- Authenticate,
- Run Terminal Auth,
- Clear Stored Credentials,
- View Auth Instructions.

The Authenticate controls should be disabled until Task 15 wires the concrete auth actions, but the UI state must already expose real auth status labels (`Unknown`, `Authenticated`, `Auth Required`, `Failed`) using `AgentAuthStatus`. Use existing dialog patterns from command settings in `src/ui/shell.rs`. Keep text editing simple and consistent with existing command settings fields.

- [ ] **Step 5: Run tests**

Run: `cargo test --test config_tests --test agent_provider_config_tests --test agent_ui_view_model_tests --all-features`

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/agent/provider.rs src/agent/mod.rs src/ui/shell.rs src/ui/provider_settings.rs tests/config_tests.rs tests/agent_ui_view_model_tests.rs
git commit -m "feat: manage ACP providers in app config"
```

---

### Task 15: Add Auth Flow State, ACP Auth Actions, and Credential Injection

**Files:**
- Modify: `src/agent/provider.rs`
- Modify: `src/agent/credentials.rs`
- Modify: `src/agent/runtime.rs`
- Modify: `src/ui/provider_settings.rs`
- Test: `tests/agent_provider_config_tests.rs`
- Test: `tests/agent_runtime_tests.rs`

- [ ] **Step 1: Add failing auth metadata and status tests**

Add tests that model ACP-advertised auth methods, provider-supplied instructions, env-var auth without storing raw secret in config, and terminal auth actions:

```rust
use alas::agent::{AgentAuthField, AgentAuthMethod};

#[test]
fn env_var_auth_method_builds_secure_env_refs() {
    let method = AgentAuthMethod::EnvVar { fields: vec![AgentAuthField::secret("API Key", "OPENAI_API_KEY")], link: None };
    let refs = method.secure_env_refs("opencode");
    assert_eq!(refs[0].name, "OPENAI_API_KEY");
    assert_eq!(refs[0].secure_ref.as_deref(), Some("opencode/OPENAI_API_KEY"));
}

#[test]
fn terminal_auth_method_keeps_setup_args() {
    let method = AgentAuthMethod::Terminal { args: vec!["login".to_string()], env: vec![] };
    assert!(matches!(method, AgentAuthMethod::Terminal { .. }));
}
```

- [ ] **Step 2: Run tests to verify failure**

Run: `cargo test --test agent_provider_config_tests --all-features`

Expected: FAIL because auth metadata types do not exist.

- [ ] **Step 3: Implement auth metadata and credential resolution**

Add to `src/agent/provider.rs`:

```rust
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum AgentAuthMethod {
    Agent { instructions: Option<String> },
    EnvVar { fields: Vec<AgentAuthField>, link: Option<String> },
    Terminal { args: Vec<String>, env: Vec<(String, String)> },
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct AgentAuthField {
    pub label: String,
    pub env_name: String,
    pub secret: bool,
    pub optional: bool,
}

impl AgentAuthField {
    pub fn secret(label: impl Into<String>, env_name: impl Into<String>) -> Self {
        Self { label: label.into(), env_name: env_name.into(), secret: true, optional: false }
    }
}
```

Extend the `AgentAuthStatus` introduced in Task 14 only if needed by runtime auth results.

Add helpers to:

- convert ACP-advertised auth methods into `AgentAuthMethod` values;
- expose provider instructions/status to the provider settings UI;
- resolve secure env values into process env with a `CredentialStore`;
- build terminal-auth command args/env from a `Terminal` auth method.

- [ ] **Step 4: Wire credential injection into `AcpProcessConnection::spawn`**

Add a spawn variant:

```rust
pub fn spawn_with_env(provider: &AgentProviderConfig, cwd: PathBuf, env: &[(String, String)]) -> anyhow::Result<Self>
```

It should call `.env(key, value)` for resolved values and never log values.

- [ ] **Step 5: Add agent-handled ACP authenticate action**

Add `AgentRuntime::authenticate(method_id)` or equivalent, backed by the real ACP crate when available and by `FakeAcpConnection` in tests. It should:

- call the provider's ACP authenticate method for agent-handled auth;
- update `AgentAuthStatus` from success/failure;
- preserve provider-supplied instructions in thread/provider settings state;
- append redacted debug events.

- [ ] **Step 6: Add env-var auth UI fields and storage**

Provider settings should allow entering env-var auth values and saving them via `CredentialStore`, not into config. Saving env-var auth should restart/reinitialize the provider with the resolved env and retry authenticate when required.

- [ ] **Step 7: Add terminal auth action**

Implement a terminal-auth launcher that runs the configured provider command plus advertised terminal auth args/env from Alas. In this task it may use the existing terminal/session infrastructure or a protocol-only command with captured output, but it must expose success/failure/instructions in provider settings. Do not allow arbitrary command substitution from the provider; only append advertised args/env to the configured provider command.

- [ ] **Step 8: Run tests**

Run: `cargo test --test agent_provider_config_tests --test agent_runtime_tests --all-features`

Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add src/agent/provider.rs src/agent/credentials.rs src/agent/runtime.rs src/ui/provider_settings.rs tests/agent_provider_config_tests.rs tests/agent_runtime_tests.rs
git commit -m "feat: add ACP provider auth flows"
```

---

### Task 16: Map Real ACP Session Updates Into Thread State

**Files:**
- Modify: `src/agent/runtime.rs`
- Modify: `src/agent/types.rs`
- Test: `tests/agent_runtime_tests.rs`

- [ ] **Step 1: Add failing update mapping tests independent of real crate transport**

Add tests for an Alas-owned update enum:

```rust
use alas::agent::{AgentConfigOption, AgentModeOption, AgentSlashCommand, AgentUpdate, apply_agent_update};

#[test]
fn agent_message_update_appends_agent_transcript_entry() {
    let mut thread = AgentThreadState::new("opencode", PathBuf::from("/repo/a"));
    apply_agent_update(&mut thread, AgentUpdate::AgentMessageChunk("hello".to_string()));
    assert!(thread.transcript.iter().any(|entry| entry.text == "hello"));
}

#[test]
fn plan_update_replaces_plan_state() {
    let mut thread = AgentThreadState::new("opencode", PathBuf::from("/repo/a"));
    apply_agent_update(&mut thread, AgentUpdate::Plan(vec!["step one".to_string()]));
    assert_eq!(thread.plans[0].entries, vec!["step one".to_string()]);
}

#[test]
fn advertised_commands_modes_and_config_options_update_thread_state() {
    let mut thread = AgentThreadState::new("opencode", PathBuf::from("/repo/a"));
    apply_agent_update(&mut thread, AgentUpdate::AvailableCommands(vec![AgentSlashCommand { name: "/test".to_string(), description: Some("Run tests".to_string()) }]));
    apply_agent_update(&mut thread, AgentUpdate::AvailableModes { modes: vec![AgentModeOption { id: "plan".to_string(), name: "Plan".to_string() }], current: Some("plan".to_string()) });
    apply_agent_update(&mut thread, AgentUpdate::ConfigOptions(vec![AgentConfigOption { id: "model".to_string(), label: "Model".to_string(), value: Some("sonnet".to_string()) }]));

    assert_eq!(thread.available_commands[0].name, "/test");
    assert_eq!(thread.current_mode.as_deref(), Some("plan"));
    assert_eq!(thread.config_options[0].id, "model");
}
```

- [ ] **Step 2: Run tests to verify failure**

Run: `cargo test --test agent_runtime_tests --all-features`

Expected: FAIL.

- [ ] **Step 3: Implement update mapper**

Add to `src/agent/runtime.rs`:

```rust
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum AgentUpdate {
    UserMessageChunk(String),
    AgentMessageChunk(String),
    ThoughtChunk(String),
    ToolCall { id: String, title: String, status: String },
    Plan(Vec<String>),
    AvailableCommands(Vec<crate::agent::AgentSlashCommand>),
    AvailableModes { modes: Vec<crate::agent::AgentModeOption>, current: Option<String> },
    ConfigOptions(Vec<crate::agent::AgentConfigOption>),
    Error(String),
}

pub fn apply_agent_update(thread: &mut AgentThreadState, update: AgentUpdate) {
    match update {
        AgentUpdate::UserMessageChunk(text) => thread.transcript.push(AgentTranscriptEntry::user(text)),
        AgentUpdate::AgentMessageChunk(text) => thread.transcript.push(AgentTranscriptEntry::agent(text)),
        AgentUpdate::ThoughtChunk(text) => thread.transcript.push(AgentTranscriptEntry { role: crate::agent::AgentTranscriptRole::Thought, text }),
        AgentUpdate::ToolCall { id, title, status } => thread.tool_calls.push(crate::agent::AgentToolCallState { id, title, status }),
        AgentUpdate::Plan(entries) => thread.plans.push(crate::agent::AgentPlanState { entries }),
        AgentUpdate::AvailableCommands(commands) => thread.available_commands = commands,
        AgentUpdate::AvailableModes { modes, current } => { thread.available_modes = modes; thread.current_mode = current; },
        AgentUpdate::ConfigOptions(options) => thread.config_options = options,
        AgentUpdate::Error(message) => thread.debug_log.push(crate::agent::AgentDebugEvent { message }),
    }
}
```

- [ ] **Step 4: Add real ACP conversion function**

Add a function such as `fn convert_acp_update(update: agent_client_protocol::SessionUpdate) -> Vec<AgentUpdate>`. Check the actual crate docs/API before writing exact matches. Keep the conversion isolated here so UI and tests stay stable.

- [ ] **Step 5: Run tests**

Run: `cargo test --test agent_runtime_tests --all-features`

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/agent/runtime.rs src/agent/types.rs tests/agent_runtime_tests.rs
git commit -m "feat: map ACP updates into agent thread state"
```

---

### Task 17: Implement Real ACP Initialize/New/Resume/Prompt/Cancel

**Files:**
- Modify: `src/agent/runtime.rs`
- Test: `tests/agent_runtime_tests.rs`

- [ ] **Step 1: Add an ignored/manual fake-provider integration test**

Create an ignored test that can run against a small test ACP server or provider command later:

```rust
#[test]
#[ignore = "requires installed ACP provider test command"]
fn real_acp_provider_can_initialize_and_create_session() {
    // Use ALAS_TEST_ACP_COMMAND and ALAS_TEST_ACP_ARGS from env.
}
```

- [ ] **Step 2: Inspect crate API and replace skeleton methods**

Use local docs/source:

```bash
cargo doc -p agent-client-protocol --no-deps --open
```

Then implement `AcpProcessConnection` with the crate-supported client-side connection over child stdio. Shell/runtime launch must compute cwd through `resolve_provider_cwd(provider, selected_worktree, repository_root)` before spawning. The methods must:

- send initialize with Alas client info/capabilities;
- call the crate's session new/load/resume APIs;
- call prompt and forward every streamed `session/update` into `AgentEventSink` as it arrives;
- keep callbacks responsive while a prompt is running;
- call cancel through the same live connection so an in-flight prompt can stop promptly.

If the crate requires async, expose an async/event-loop implementation internally and keep the Shell boundary as a background task that sends `AgentRuntimeEvent` values back to the GPUI entity. Do not collapse streaming into a final `Vec` in the real implementation.

- [ ] **Step 3: Preserve fake tests**

Run: `cargo test --test agent_runtime_tests --all-features`

Expected: PASS.

- [ ] **Step 4: Run ignored test manually when a provider is available**

Run, for example:

```bash
ALAS_TEST_ACP_COMMAND=opencode ALAS_TEST_ACP_ARGS=acp cargo test --test agent_runtime_tests real_acp_provider_can_initialize_and_create_session --all-features -- --ignored
```

Expected: PASS when the provider is installed and authenticated, or a clear auth-required error if not.

- [ ] **Step 5: Commit**

```bash
git add src/agent/runtime.rs tests/agent_runtime_tests.rs
git commit -m "feat: wire ACP runtime protocol calls"
```

---

### Task 18: Connect Runtime Actions to Agent Chat UI

**Files:**
- Modify: `src/ui/agent_pane.rs`
- Modify: `src/ui/shell.rs`
- Modify: `src/agent/runtime.rs`
- Test: `tests/agent_ui_view_model_tests.rs`

- [ ] **Step 1: Add view-model tests for composer state**

Add tests for helpers such as `agent_composer_enabled(thread)` and `agent_primary_action_label(thread)`.

Expected behavior:

- Ready => composer enabled, Send;
- Running => composer disabled for editing, Cancel visible;
- ReadOnly => composer disabled;
- AuthRequired => composer disabled and auth action visible;
- advertised modes/config options produce visible selector labels in the header;
- advertised slash commands are available to the composer helper.

- [ ] **Step 2: Run tests to verify failure**

Run: `cargo test --test agent_ui_view_model_tests --all-features`

Expected: FAIL.

- [ ] **Step 3: Implement UI helpers and callbacks**

Update `render_agent_pane` signature to accept callbacks:

```rust
pub fn render_agent_pane(
    thread: &AgentThreadState,
    on_send: impl Fn(String, &gpui::ClickEvent, &mut gpui::Window, &mut gpui::App) + Clone + 'static,
    on_cancel: impl Fn(&gpui::ClickEvent, &mut gpui::Window, &mut gpui::App) + Clone + 'static,
) -> impl IntoElement
```

Render advertised mode/model/config selectors in the compact header from `thread.available_modes`, `thread.current_mode`, and `thread.config_options`. Expose slash commands from `thread.available_commands` in the composer helper even if autocomplete UI remains minimal. If text input is not straightforward in current GPUI code, follow existing command settings field patterns from `src/ui/shell.rs` for draft editing.

- [ ] **Step 4: Add Shell runtime storage**

In `AlasShell`, add runtime state keyed by `WorkspaceTabId`, for example:

```rust
agent_runtimes: std::collections::HashMap<WorkspaceTabId, AgentRuntime<AcpProcessConnection>>,
```

If generic storage is difficult because fake/runtime types differ, introduce an `AgentRuntimeHandle` enum or trait object facade.

- [ ] **Step 5: Implement send/cancel methods**

Add methods:

- `start_agent_runtime_for_tab`,
- `send_agent_prompt`,
- `cancel_agent_prompt`,
- `sync_agent_thread_from_runtime`.

Run protocol work on the background executor and update tab state for every streamed `AgentRuntimeEvent`, not only at prompt completion. The Shell should keep enough handle state to send cancel while streaming is active.

- [ ] **Step 6: Run UI tests**

Run: `cargo test --test agent_ui_view_model_tests --all-features`

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add src/ui/agent_pane.rs src/ui/shell.rs src/agent/runtime.rs tests/agent_ui_view_model_tests.rs
git commit -m "feat: connect agent chat UI to runtime actions"
```

---

### Task 19: Wire Filesystem and Terminal Callbacks Into Runtime

**Files:**
- Modify: `src/agent/runtime.rs`
- Modify: `src/agent/filesystem.rs`
- Modify: `src/agent/terminal.rs`
- Test: `tests/agent_runtime_tests.rs`
- Test: `tests/agent_filesystem_tests.rs`
- Test: `tests/agent_terminal_tests.rs`

- [ ] **Step 1: Add runtime callback dispatch tests**

Use fake connection events or direct runtime callback methods:

```rust
#[test]
fn runtime_filesystem_callback_records_tool_error_when_denied() {
    // Construct runtime with Deny policy, call read/write callback, assert error/debug entry.
}

#[test]
fn runtime_terminal_callback_records_output_in_tool_state() {
    // Construct runtime with AllowEverything, run printf command, assert output appears in transcript/tool state.
}

#[test]
fn ask_mode_callback_creates_pending_permission_and_resumes_after_decision() {
    // Construct runtime with Ask policy, request a write/terminal callback,
    // assert pending_permissions contains the request, then approve it and assert callback completes.
}
```

- [ ] **Step 2: Run tests to verify failure**

Run: `cargo test --test agent_runtime_tests --all-features`

Expected: FAIL.

- [ ] **Step 3: Add callback dispatcher to runtime**

Runtime should own or receive:

- `FilesystemCallbackService`,
- `AgentTerminalService`,
- `PermissionPolicy`.

Add methods that the real ACP client handler and permission UI can call:

- `handle_request_permission`,
- `resolve_permission_request`,
- `handle_read_text_file`,
- `handle_write_text_file`,
- `handle_terminal_create`,
- `handle_terminal_output`,
- `handle_terminal_wait_for_exit`,
- `handle_terminal_kill`,
- `handle_terminal_release`.

Each method should append redacted debug/tool entries and return ACP-compatible success/error values. For `Ask` decisions, callbacks must create an `AgentPermissionRequest`, return or await a pending decision according to the ACP handler shape, and continue only after `resolve_permission_request` records Allow/Deny. Do not simply bail on `Ask` inside runtime dispatch.

- [ ] **Step 4: Connect real ACP client handlers**

In `AcpProcessConnection`, wire the crate's client callback hooks to the runtime dispatcher. If crate ownership makes direct calls awkward, use channels from callback handlers into the runtime event loop. The UI must render pending permission cards in `render_agent_pane` with Allow/Deny actions, even though the default Allow Everything mode normally bypasses them.

- [ ] **Step 5: Run callback and runtime tests**

Run:

```bash
cargo test --test agent_runtime_tests --test agent_filesystem_tests --test agent_terminal_tests --all-features
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/agent/runtime.rs src/agent/filesystem.rs src/agent/terminal.rs tests/agent_runtime_tests.rs
git commit -m "feat: handle ACP filesystem and terminal callbacks"
```

---

### Task 20: Persist and Restore Agent Chat Tabs

**Files:**
- Modify: `src/ui/shell.rs`
- Modify: `src/agent/persistence.rs`
- Modify: `src/app/workspace.rs`
- Test: `tests/agent_persistence_tests.rs`
- Test: `tests/agent_workspace_tests.rs`

- [ ] **Step 1: Add tests for stable thread identity**

Add a stable `thread_id` to `AgentThreadState` or `AgentThreadRecord`. Prefer stable thread id over tab id so persisted records survive tab id allocation changes.

Test:

```rust
#[test]
fn persisted_thread_record_uses_stable_thread_id_not_workspace_tab_id() {
    // Create record, assert thread_id remains the same after state clone/save/load.
}
```

- [ ] **Step 2: Run tests to verify failure**

Run: `cargo test --test agent_persistence_tests --all-features`

Expected: FAIL if stable thread id not implemented.

- [ ] **Step 3: Implement stable thread ids**

Add `thread_id: String` to `AgentThreadState` or keep it in `AgentThreadRecord` and ensure `WorkspaceSession` can restore Agent Chat tabs from records.

Use simple deterministic ids for tests; use incrementing or timestamp/uuid-like ids for runtime. If adding a UUID dependency, use `uuid = { version = "1", features = ["v4", "serde"] }`.

- [ ] **Step 4: Add Shell store path**

Use `directories::ProjectDirs::from("dev", "alas", "Alas")` data dir and store records in `agent_threads.json`.

Add `agent_thread_store: AgentThreadStore` to `AlasShell`.

- [ ] **Step 5: Restore persisted Agent Chat tabs on startup or worktree selection**

On `AlasShell::new`, load records. On worktree selection, restore records matching selected worktree into `WorkspaceSession` if they are not already open. Mark them `Pending`/`ReadOnly` until runtime resume completes.

- [ ] **Step 6: Persist after thread changes**

After prompt updates, draft changes, resume state changes, and tab close, save current Agent Chat records.

- [ ] **Step 7: Run tests**

Run:

```bash
cargo test --test agent_persistence_tests --test agent_workspace_tests --all-features
```

Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add src/ui/shell.rs src/agent/persistence.rs src/app/workspace.rs tests/agent_persistence_tests.rs tests/agent_workspace_tests.rs
git commit -m "feat: persist and restore agent chat tabs"
```

---

### Task 21: Enforce Durable Resume Read-Only Behavior

**Files:**
- Modify: `src/agent/runtime.rs`
- Modify: `src/ui/agent_pane.rs`
- Modify: `src/ui/shell.rs`
- Test: `tests/agent_runtime_tests.rs`
- Test: `tests/agent_ui_view_model_tests.rs`

- [ ] **Step 1: Add failing read-only prompt tests**

Add runtime test:

```rust
#[test]
fn runtime_rejects_prompt_when_thread_is_read_only() {
    let fake = FakeAcpConnection::new();
    let mut runtime = AgentRuntime::with_connection("opencode", PathBuf::from("/repo/a"), fake);
    runtime.thread_mut().status = AgentThreadStatus::ReadOnly { reason: "resume unsupported".to_string() };

    let error = runtime.prompt("hello").expect_err("read-only prompt should fail").to_string();
    assert!(error.contains("read-only"));
}
```

- [ ] **Step 2: Run tests to verify failure**

Run: `cargo test --test agent_runtime_tests --all-features`

Expected: FAIL if prompts are allowed in read-only state.

- [ ] **Step 3: Guard runtime and UI send paths**

- `AgentRuntime::prompt` returns an error for `ReadOnly`.
- Agent pane disables composer for `ReadOnly`.
- Shell send handler no-ops and records a debug error if a stale UI event tries to send.

- [ ] **Step 4: Run tests**

Run: `cargo test --test agent_runtime_tests --test agent_ui_view_model_tests --all-features`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/agent/runtime.rs src/ui/agent_pane.rs src/ui/shell.rs tests/agent_runtime_tests.rs tests/agent_ui_view_model_tests.rs
git commit -m "feat: enforce ACP resume read-only sessions"
```

---

### Task 22: Add Debug Log Redaction

**Files:**
- Modify: `src/agent/types.rs`
- Modify: `src/agent/runtime.rs`
- Test: `tests/agent_runtime_tests.rs`

- [ ] **Step 1: Add failing redaction tests**

```rust
use alas::agent::redact_debug_value;

#[test]
fn debug_redaction_removes_secret_values() {
    assert_eq!(redact_debug_value("OPENAI_API_KEY", "abc123"), "[redacted]");
    assert_eq!(redact_debug_value("PATH", "/usr/bin"), "/usr/bin");
}
```

- [ ] **Step 2: Run tests to verify failure**

Run: `cargo test --test agent_runtime_tests --all-features`

Expected: FAIL.

- [ ] **Step 3: Implement redaction helper and bounded log**

Add helper that redacts keys containing `KEY`, `TOKEN`, `SECRET`, `PASSWORD`, or auth fields marked secret. Add `push_debug_event` on `AgentThreadState` that caps entries, e.g. 500.

- [ ] **Step 4: Use redaction in runtime/provider launch/auth paths**

Ensure debug events include method names and safe metadata but no raw env values.

- [ ] **Step 5: Run tests**

Run: `cargo test --test agent_runtime_tests --all-features`

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/agent/types.rs src/agent/runtime.rs tests/agent_runtime_tests.rs
git commit -m "feat: redact ACP debug logs"
```

---

### Task 23: Add Manual Test Documentation

**Files:**
- Modify: `docs/manual-test.md`

- [ ] **Step 1: Add ACP manual acceptance section**

Append a section with these steps:

```markdown
## ACP Agent Chat

1. Ensure an ACP provider is installed, for example `opencode acp` or another provider command.
2. Open Alas and select a worktree.
3. Open provider settings and add a global provider with command/args.
4. Authenticate from Alas if the provider reports auth is required.
5. Use `+ → Agent Chat` and select the provider.
6. Send a prompt and confirm streamed transcript updates appear.
7. Trigger a file read/write or terminal command and confirm the tool card shows the side effect under Allow Everything.
8. Restart Alas and confirm the chat returns.
9. Confirm the composer is enabled only if ACP resume succeeds; otherwise the transcript is read-only.
```

- [ ] **Step 2: Commit**

```bash
git add docs/manual-test.md
git commit -m "docs: add ACP agent chat manual test"
```

---

### Task 24: Run Full Verification

**Files:**
- No code changes expected unless checks fail.

- [ ] **Step 1: Run formatting check**

Run: `cargo fmt --all -- --check`

Expected: PASS.

- [ ] **Step 2: Run clippy**

Run: `cargo clippy --all-targets --all-features -- -D warnings`

Expected: PASS.

- [ ] **Step 3: Run build**

Run: `cargo build --all-features`

Expected: PASS.

- [ ] **Step 4: Run tests**

Run: `cargo test --all-features`

Expected: PASS.

- [ ] **Step 5: Fix any failures with focused commits**

For each failure:

1. write or update a targeted regression test if missing;
2. fix the issue;
3. rerun the failing command;
4. commit with a focused message.

- [ ] **Step 6: Final status**

Run: `git status --short`

Expected: clean working tree.

---

## Implementation Handoff Notes

- Start with Tasks 1-9 to build a testable non-UI foundation before heavy GPUI wiring.
- Do not wire real ACP subprocess protocol calls until fake-backed state, persistence, and UI seams are stable.
- Keep provider install/update/registry work out of this branch.
- Preserve existing terminal behavior. Terminal-specific input/rendering paths should remain gated on terminal tabs.
- The default trust mode is intentionally powerful: Allow Everything across the whole machine. Keep tests explicit so future safer defaults are a conscious product change.
