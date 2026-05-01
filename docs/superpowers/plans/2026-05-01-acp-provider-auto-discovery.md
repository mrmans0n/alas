# ACP Provider Auto-Discovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Silently auto-configure verified installed ACP providers on startup, while preserving user config and showing unverified provider suggestions.

**Architecture:** Add a focused provider discovery module under `src/agent` that scans safe PATH directories and returns verified providers plus suggestions. Extend app config with ignored provider ids, merge verified discoveries into config during startup, and pass filtered suggestions into Provider Settings.

**Tech Stack:** Rust, serde/TOML app config, GPUI view-model/UI tests, existing `AgentProviderConfig` and `ProviderSettingsState`.

---

## File Structure

- `src/agent/discovery.rs` — new focused module for known provider registry, PATH scanning, discovery result types, merge/filter helpers, and ignore helper.
- `src/agent/mod.rs` — export discovery types/functions.
- `src/agent/provider.rs` — extend `ProviderSettingsState` with discovery suggestions and error/suggestion helper methods if needed.
- `src/config/types.rs` — add defaulted `AgentProviderDiscoveryConfig` to `AppConfig`.
- `src/ui/provider_settings.rs` — render suggestions below configured providers.
- `src/ui/shell.rs` — run discovery at startup, save config on merge, pass suggestions to settings, record ignored ids on known provider removal.
- `tests/agent_provider_discovery_tests.rs` — pure discovery/merge tests with fake PATH directories.
- `tests/agent_ui_view_model_tests.rs` — provider settings suggestion state/render helper coverage.
- `tests/config_tests.rs` — app config round-trip/default compatibility for discovery config.

---

### Task 1: Add Discovery Config Model

**Files:**
- Modify: `src/config/types.rs`
- Test: `tests/config_tests.rs`

- [ ] **Step 1: Add config tests**

Add tests to `tests/config_tests.rs`:

```rust
#[test]
fn app_config_defaults_provider_discovery_config() {
    let config: AppConfig = toml::from_str("").expect("empty config");

    assert!(config.agent_provider_discovery.ignored_provider_ids.is_empty());
}

#[test]
fn app_config_round_trips_provider_discovery_ignored_ids() {
    let mut config = AppConfig::default();
    config
        .agent_provider_discovery
        .ignored_provider_ids
        .push("opencode".to_string());

    let toml = toml::to_string(&config).expect("serialize config");
    assert!(toml.contains("agent_provider_discovery"));
    assert!(toml.contains("opencode"));

    let loaded: AppConfig = toml::from_str(&toml).expect("deserialize config");
    assert_eq!(loaded, config);
}
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
cargo test --test config_tests app_config_defaults_provider_discovery_config --all-features
```

Expected: FAIL because `agent_provider_discovery` does not exist.

- [ ] **Step 3: Implement config model**

In `src/config/types.rs`, add:

```rust
#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
pub struct AgentProviderDiscoveryConfig {
    #[serde(default)]
    pub ignored_provider_ids: Vec<String>,
}
```

Extend `AppConfig`:

```rust
#[serde(default)]
pub agent_provider_discovery: AgentProviderDiscoveryConfig,
```

- [ ] **Step 4: Run tests**

Run:

```bash
cargo test --test config_tests --all-features
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/config/types.rs tests/config_tests.rs
git commit -m "feat: add ACP provider discovery config"
```

---

### Task 2: Implement Provider Discovery Core

**Files:**
- Create: `src/agent/discovery.rs`
- Modify: `src/agent/mod.rs`
- Test: `tests/agent_provider_discovery_tests.rs`

- [ ] **Step 1: Add failing discovery tests**

Create `tests/agent_provider_discovery_tests.rs` with helpers that create executable fake binaries in temp directories. On Unix, mark files executable via `std::os::unix::fs::PermissionsExt`; on other platforms, file existence is enough or guard with `#[cfg]` helpers.

Test cases:

```rust
#[test]
fn opencode_on_path_is_verified_provider() {
    // fake PATH contains executable `opencode`
    // discover_agent_providers_from_path(path)
    // assert one verified provider: id opencode, command opencode, args ["acp"], enabled true
}

#[test]
fn claude_and_codex_on_path_are_suggestions_only() {
    // fake PATH contains executable `claude` and `codex`
    // assert verified is empty
    // assert suggestions ids are claude and codex with clear non-ready messages
}

#[test]
fn missing_or_empty_path_does_not_error() {
    // discover from None or ""
    // assert no providers and no suggestions
}

#[test]
fn ignores_empty_relative_and_non_executable_path_entries() {
    // PATH includes empty segment, relative segment, and a directory containing non-executable opencode
    // assert opencode is not verified
}

#[test]
fn duplicate_path_matches_are_deduped() {
    // two PATH dirs contain opencode
    // assert only one verified provider
}

#[test]
fn duplicate_suggestion_matches_are_deduped() {
    // two PATH dirs contain claude
    // assert only one claude suggestion
}
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
cargo test --test agent_provider_discovery_tests --all-features
```

Expected: FAIL because module/functions do not exist.

- [ ] **Step 3: Implement discovery types and registry**

In `src/agent/discovery.rs`, define:

```rust
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AgentProviderSuggestion {
    pub id: String,
    pub display_name: String,
    pub command: String,
    pub message: String,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct ProviderDiscoveryResult {
    pub verified_providers: Vec<AgentProviderConfig>,
    pub suggestions: Vec<AgentProviderSuggestion>,
}
```

Add known provider registry entries:

- `opencode`: display `OpenCode`, command `opencode`, verified args `vec!["acp"]`.
- `claude`: display `Claude Code`, command `claude`, suggestion only.
- `codex`: display `Codex`, command `codex`, suggestion only.

- [ ] **Step 4: Implement safe PATH scanning**

Expose testable functions:

```rust
pub fn discover_agent_providers() -> ProviderDiscoveryResult;
pub fn discover_agent_providers_from_path(path_env: Option<&str>) -> ProviderDiscoveryResult;
pub fn is_known_discoverable_provider_id(provider_id: &str) -> bool;
```

Rules:

- Use `std::env::split_paths` for PATH parsing.
- Ignore empty and relative path entries.
- Ignore path entries that are not directories.
- For each known command, check `dir.join(command)`.
- Require executable files on Unix (`mode & 0o111 != 0`).
- On non-Unix, require `is_file()`.
- Deduplicate by provider id.
- Do not execute any provider command.

- [ ] **Step 5: Export module**

Update `src/agent/mod.rs` with only the exports implemented in this task:

```rust
mod discovery;
pub use discovery::{
    AgentProviderSuggestion, ProviderDiscoveryResult, discover_agent_providers,
    discover_agent_providers_from_path, is_known_discoverable_provider_id,
};
```

- [ ] **Step 6: Run tests**

Run:

```bash
cargo test --test agent_provider_discovery_tests --all-features
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add src/agent/discovery.rs src/agent/mod.rs tests/agent_provider_discovery_tests.rs
git commit -m "feat: discover installed ACP providers"
```

---

### Task 3: Add Discovery Merge and Suggestion Filtering

**Files:**
- Modify: `src/agent/discovery.rs`
- Test: `tests/agent_provider_discovery_tests.rs`

- [ ] **Step 1: Add failing merge tests**

Add tests:

```rust
#[test]
fn merge_appends_missing_verified_provider_and_reports_changed() {
    // config default + opencode discovery
    // assert changed true and config.agent_providers[0].id == "opencode"
}

#[test]
fn merge_preserves_existing_provider_without_overwrite_or_reenable() {
    // config has disabled opencode with custom command/args
    // discovery has default opencode
    // assert changed false and custom disabled provider unchanged
}

#[test]
fn merge_skips_ignored_provider_id() {
    // config ignored_provider_ids contains opencode
    // discovery has opencode
    // assert changed false and providers empty
}

#[test]
fn suggestions_are_filtered_for_configured_and_ignored_ids() {
    // discovery suggestions include claude/codex
    // config has claude configured and codex ignored
    // assert filtered suggestions empty
}

#[test]
fn record_ignored_known_provider_id_dedupes() {
    // call helper twice with opencode
    // assert ignored ids contains one opencode
}
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
cargo test --test agent_provider_discovery_tests --all-features
```

Expected: FAIL because merge/filter helpers do not exist.

- [ ] **Step 3: Implement merge/filter helpers**

In `src/agent/discovery.rs`, add:

```rust
pub fn merge_discovered_agent_providers(
    config: &mut AppConfig,
    discovery: &ProviderDiscoveryResult,
) -> bool;

pub fn filtered_provider_suggestions(
    config: &AppConfig,
    discovery: &ProviderDiscoveryResult,
) -> Vec<AgentProviderSuggestion>;

pub fn ignore_discovered_provider_id(config: &mut AppConfig, provider_id: &str) -> bool;
```

Update `src/agent/mod.rs` to re-export these Task 3 helpers after they exist:

```rust
pub use discovery::{
    filtered_provider_suggestions, ignore_discovered_provider_id,
    merge_discovered_agent_providers,
};
```

Rules:

- Merge appends only verified providers whose id is neither configured nor ignored.
- Merge never mutates existing provider fields.
- Filtering removes suggestions whose id is configured or ignored.
- Ignore helper only records ids known to the registry.
- Ignore helper deduplicates and returns whether config changed.

- [ ] **Step 4: Run tests**

Run:

```bash
cargo test --test agent_provider_discovery_tests --all-features
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/agent/discovery.rs tests/agent_provider_discovery_tests.rs
git commit -m "feat: merge discovered ACP providers"
```

---

### Task 4: Wire Startup Auto-Configuration

**Files:**
- Modify: `src/ui/shell.rs`
- Test: `tests/agent_provider_discovery_tests.rs` or focused Shell helper tests if accessible

- [ ] **Step 1: Extract testable startup helper**

Add a required testable helper near discovery or shell integration that accepts a save closure. This makes startup save-failure behavior deterministic without needing to instantiate GPUI shell state.

Suggested API:

```rust
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ProviderDiscoveryStartupResult {
    pub changed: bool,
    pub suggestions: Vec<AgentProviderSuggestion>,
    pub error: Option<String>,
}

pub fn apply_provider_discovery_to_config(
    config: &mut AppConfig,
    discovery: &ProviderDiscoveryResult,
    save: impl FnOnce(&AppConfig) -> anyhow::Result<()>,
) -> ProviderDiscoveryStartupResult
```

Rules:

- Call `merge_discovered_agent_providers`.
- Call `save` only when merge changed config.
- Always return filtered suggestions from the post-merge config.
- If save fails, keep startup alive and return `error: Some("failed to persist auto-discovered providers: ...")`.

- [ ] **Step 2: Add startup behavior tests**

Add tests for the helper:

```rust
#[test]
fn startup_discovery_returns_filtered_suggestions_after_merge() {
    // opencode verified + claude suggestion
    // save closure records it was called and returns Ok(())
    // after apply, config has opencode and suggestions contain claude only
}

#[test]
fn startup_discovery_save_failure_returns_deterministic_error_without_aborting() {
    // opencode verified + empty config
    // save closure returns anyhow!("disk full")
    // assert config still has opencode for current session
    // assert result.changed == true
    // assert result.error contains "failed to persist auto-discovered providers"
    // assert result.error contains "disk full"
}

#[test]
fn startup_discovery_does_not_save_when_config_unchanged() {
    // config already has opencode
    // save closure panics if called
    // assert changed false and no error
}
```

- [ ] **Step 3: Run tests to verify failure**

Run:

```bash
cargo test --test agent_provider_discovery_tests --all-features
```

Expected: FAIL until helper/wiring exists.

- [ ] **Step 4: Export startup helper**

Update `src/agent/mod.rs` to re-export the new helper and result so integration tests and Shell code can use them:

```rust
pub use discovery::{
    ProviderDiscoveryStartupResult, apply_provider_discovery_to_config,
    filtered_provider_suggestions, ignore_discovered_provider_id,
    merge_discovered_agent_providers,
    // keep the existing discovery exports too
};
```

- [ ] **Step 5: Wire Shell startup**

In `src/ui/shell.rs`, during `AlasShell::new` after config load and before provider settings use:

1. Run `discover_agent_providers()`.
2. Call `merge_discovered_agent_providers(&mut config, &discovery)`.
3. If changed, call `app_config_store.save(&config)`.
4. Compute filtered suggestions and store them in Shell state or pass into `ProviderSettingsState` when opened.
5. If save fails, keep startup alive and retain deterministic error text for provider settings.

Add fields to `AlasShell` if needed:

```rust
provider_discovery_suggestions: Vec<AgentProviderSuggestion>,
provider_discovery_error: Option<String>,
```

- [ ] **Step 6: Run targeted tests**

Run:

```bash
cargo test --test agent_provider_discovery_tests --all-features
cargo test --test config_tests --all-features
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add src/ui/shell.rs src/agent/discovery.rs src/agent/mod.rs tests/agent_provider_discovery_tests.rs
git commit -m "feat: auto-configure discovered ACP providers"
```

---

### Task 5: Show Provider Discovery Suggestions

**Files:**
- Modify: `src/agent/provider.rs`
- Modify: `src/ui/provider_settings.rs`
- Modify: `src/ui/shell.rs`
- Test: `tests/agent_ui_view_model_tests.rs`

- [ ] **Step 1: Add failing view-model tests**

In `tests/agent_ui_view_model_tests.rs`, add tests:

```rust
#[test]
fn provider_settings_tracks_discovery_suggestions() {
    let mut state = ProviderSettingsState::default();
    state.discovery_suggestions.push(AgentProviderSuggestion {
        id: "claude".to_string(),
        display_name: "Claude Code".to_string(),
        command: "claude".to_string(),
        message: "Claude Code found, but ACP command is not verified yet.".to_string(),
    });

    assert_eq!(state.discovery_suggestions[0].id, "claude");
}

#[test]
fn provider_settings_error_can_report_discovery_save_failure() {
    let mut state = ProviderSettingsState::default();
    state.error = Some("failed to persist auto-discovered providers".to_string());

    assert!(state.error.as_deref().unwrap().contains("auto-discovered"));
}
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
cargo test --test agent_ui_view_model_tests provider_settings_tracks_discovery_suggestions --all-features
```

Expected: FAIL because `discovery_suggestions` does not exist/export is missing.

- [ ] **Step 3: Extend provider settings state**

In `src/agent/provider.rs`, add this field to `ProviderSettingsState`:

```rust
pub discovery_suggestions: Vec<AgentProviderSuggestion>,
```

Keep the existing `ProviderSettingsState` derive unchanged. Do not add serde derives to `ProviderSettingsState`; it is view-model state, not persisted config. Import `AgentProviderSuggestion` from the agent discovery exports.

- [ ] **Step 4: Render suggestions**

In `src/ui/provider_settings.rs`, render a suggestions section after provider rows and before buttons when suggestions are non-empty:

- heading: `Discovered tools`
- each card text: `{display_name} found`
- message: suggestion message
- command hint: `Command: claude`

Use existing theme colors (`TEXT`, `TEXT_MUTED`, `PANEL_BORDER`) and readable text colors.

- [ ] **Step 5: Populate settings from Shell**

When `open_provider_settings` creates `ProviderSettingsState`, include the discovery fields in the current struct literal or construct a mutable settings value before assigning it:

```rust
let mut settings = ProviderSettingsState {
    providers: self.config.agent_providers.clone(),
    selected_provider_id: self.config.agent_providers.first().map(|provider| provider.id.clone()),
    discovery_suggestions: self.provider_discovery_suggestions.clone(),
    ..ProviderSettingsState::default()
};
if let Some(error) = self.provider_discovery_error.clone() {
    settings.error = Some(error);
}
self.provider_settings = Some(settings);
```

Adapt field initialization to the exact current `open_provider_settings` code.

- [ ] **Step 6: Run tests**

Run:

```bash
cargo test --test agent_ui_view_model_tests --all-features
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add src/agent/provider.rs src/ui/provider_settings.rs src/ui/shell.rs tests/agent_ui_view_model_tests.rs
git commit -m "feat: show ACP provider discovery suggestions"
```

---

### Task 6: Record Ignored Provider IDs on Removal

**Files:**
- Modify: `src/ui/shell.rs`
- Test: `tests/agent_provider_discovery_tests.rs` or shell helper tests

- [ ] **Step 1: Add failing removal/ignore test**

If `remove_provider_settings_entry` cannot be tested directly, extract a publicly reachable helper in `src/agent/discovery.rs` and re-export it from `src/agent/mod.rs`:

```rust
pub fn remove_provider_and_record_discovery_ignore(
    config: &mut AppConfig,
    settings: &mut ProviderSettingsState,
    provider_id: &str,
) -> bool
```

If the helper is added, update `src/agent/mod.rs`:

```rust
pub use discovery::remove_provider_and_record_discovery_ignore;
```

Test:

```rust
#[test]
fn removing_known_discovered_provider_records_ignored_id() {
    let mut config = AppConfig::default();
    let mut settings = ProviderSettingsState::default();
    settings.add_provider(AgentProviderConfig::new("opencode", "OpenCode", "opencode"));

    let changed = remove_provider_and_record_discovery_ignore(&mut config, &mut settings, "opencode");

    assert!(changed);
    assert!(settings.providers.is_empty());
    assert_eq!(config.agent_provider_discovery.ignored_provider_ids, vec!["opencode"]);
}

#[test]
fn saving_after_removal_persists_ignored_provider_ids() {
    // Use AppConfigStore with a temp config path or a smaller save helper.
    // Remove opencode through the helper, assign settings.providers into config.agent_providers,
    // save config, reload it, and assert ignored_provider_ids contains opencode.
}
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
cargo test --test agent_provider_discovery_tests removing_known_discovered_provider_records_ignored_id --all-features
```

Expected: FAIL until helper/wiring exists.

- [ ] **Step 3: Implement removal ignore wiring**

Update `remove_provider_settings_entry` in `src/ui/shell.rs`:

- Before or after removing from settings, call `ignore_discovered_provider_id(&mut self.config, provider_id)`.
- Recompute `self.provider_discovery_suggestions` using current config and the latest discovery result if stored, or remove matching suggestion locally.
- Ensure `save_provider_settings` persists both updated providers and updated ignored ids.

Do not ignore unknown custom provider ids.

- [ ] **Step 4: Run tests**

Run:

```bash
cargo test --test agent_provider_discovery_tests --all-features
cargo test --test agent_ui_view_model_tests --all-features
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/ui/shell.rs src/agent/discovery.rs tests/agent_provider_discovery_tests.rs
git commit -m "feat: remember ignored discovered ACP providers"
```

---

### Task 7: Full Verification and Manual Docs

**Files:**
- Modify: `docs/manual-test.md`

- [ ] **Step 1: Add manual test section**

Append a short section:

```markdown
## ACP Provider Auto-Discovery

1. Ensure `opencode` is installed and available on `PATH`.
2. Start Alas with no configured `opencode` provider.
3. Open Provider Settings and confirm OpenCode appears with command `opencode` and args `["acp"]`.
4. Disable OpenCode, restart Alas, and confirm it stays disabled.
5. Remove OpenCode, save settings, restart Alas, and confirm it is not re-added.
6. If `claude` or `codex` are installed, confirm they appear only as suggestions unless manually configured.
```

- [ ] **Step 2: Run formatting**

Run:

```bash
cargo fmt --all -- --check
```

Expected: PASS.

- [ ] **Step 3: Run clippy**

Run:

```bash
cargo clippy --all-targets --all-features -- -D warnings
```

Expected: PASS.

- [ ] **Step 4: Run build**

Run:

```bash
cargo build --all-features
```

Expected: PASS.

- [ ] **Step 5: Run tests**

Run:

```bash
cargo test --all-features
```

Expected: PASS.

- [ ] **Step 6: Commit docs if verification passes**

```bash
git add docs/manual-test.md
git commit -m "docs: add ACP provider discovery manual test"
```

- [ ] **Step 7: Final status**

Run:

```bash
git status --short
```

Expected: clean working tree.
