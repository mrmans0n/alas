# ACP Provider Auto-Discovery Design

Date: 2026-05-01

## Goal

Add lightweight ACP provider auto-discovery so Alas can silently configure known installed ACP providers when possible, while preserving all user-edited provider configuration and avoiding broken guesses.

The first target is OpenCode via `opencode acp`. Claude Code and Codex should be detected as suggestions until their ACP command shapes are verified.

## Context

Alas currently supports manual global ACP provider configuration. Provider install/update/registry management was intentionally out of scope for the initial center-pane ACP implementation. This feature adds a small, safe discovery layer on top of the existing manual provider model.

Relevant existing areas:

- `src/agent/provider.rs`: provider config and settings state.
- `src/config/types.rs`: persisted app config.
- `src/config/app_config.rs`: app config load/save.
- `src/ui/shell.rs`: startup config loading and provider settings state.
- `src/ui/provider_settings.rs`: provider settings UI.

## Product Decisions

- Discovery runs on every startup.
- Verified providers are silently added when missing.
- Existing providers are never overwritten by discovery.
- Disabled providers are not re-enabled.
- Deleted auto-discovered providers should stay deleted by recording an ignored provider id.
- Suggestions are non-invasive and are not active providers.
- V1 should avoid launching ACP servers for probing.
- OpenCode is the first verified silent provider: `opencode acp`.
- Claude Code and Codex are suggestions only until their ACP command shapes are confirmed.

## Scope

### In scope

- Scan `PATH` for known provider binaries.
- Add verified missing providers to global app config.
- Preserve existing user provider config unchanged.
- Persist ignored discovery ids for deleted providers.
- Surface unverified detections as Provider Settings suggestions.
- Add unit tests for discovery and merge behavior.

### Out of scope

- Installing providers.
- Updating providers.
- Downloading remote provider registries.
- Running long-lived ACP server processes as startup probes.
- Automatically adding unverified Claude/Codex command guesses.
- Credential discovery or migration.

## Architecture

Add a provider discovery layer separate from provider configuration.

### Known provider registry

The registry is a small built-in table of known candidates. Each entry should describe:

- stable provider id,
- display name,
- executable name,
- verified ACP args when known,
- suggestion message when unverified.

Initial registry:

| Provider | Binary | Verified command | Discovery result |
| --- | --- | --- | --- |
| OpenCode | `opencode` | `opencode acp` | verified provider |
| Claude Code | `claude` | unknown in V1 | suggestion |
| Codex | `codex` | unknown in V1 | suggestion |

Provider ids are stable and predictable: `opencode`, `claude`, and `codex`.

### Discovery result

Discovery should produce:

- `verified_providers`: providers safe to auto-add,
- `suggestions`: detected tools that may support ACP but are not auto-configured.

Suggested types:

- `KnownAgentProvider`
- `AgentProviderDiscovery`
- `DiscoveredAgentProvider`
- `AgentProviderSuggestion`
- `ProviderDiscoveryResult`

These names are suggestions; implementation may adjust them to match existing module style.

### PATH scanning

Discovery scans the process `PATH` for known executable names. It should tolerate:

- missing `PATH`,
- empty path segments,
- non-existent directories,
- unreadable directories,
- duplicate matches.

Discovery should not fail app startup. Unexpected filesystem errors should produce no provider for that candidate or a non-fatal diagnostic, not a hard error.

Discovery must be conservative about PATH safety because verified providers are added silently and use the existing default trust mode. It must ignore:

- empty PATH segments,
- relative PATH segments, including current-directory entries,
- non-directory PATH entries,
- matching files that are not executable.

For V1, do not execute `opencode acp`, `claude`, or `codex` during startup. Running an ACP command may start a server and hang. Safe version probes may be added later only when bounded and known to exit quickly.

## Config Model

Extend app config with an agent provider discovery section, for example:

```toml
[agent_provider_discovery]
ignored_provider_ids = ["opencode"]
```

Equivalent Rust model:

```rust
pub struct AgentProviderDiscoveryConfig {
    pub ignored_provider_ids: Vec<String>,
}
```

Defaults must preserve existing config compatibility.

## Merge Behavior

Add a pure merge function, for example:

```rust
merge_discovered_agent_providers(config, discovery_result) -> bool
```

The function appends verified providers and returns whether config changed.

Rules:

1. If a provider id already exists in `config.agent_providers`, do nothing.
2. If a provider id is in `agent_provider_discovery.ignored_provider_ids`, do nothing.
3. If a verified provider is missing and not ignored, append it.
4. Appended provider defaults:
   - `id`: stable id,
   - `display_name`: registry display name,
   - `command`: executable name, not absolute path,
   - `args`: verified ACP args,
   - `enabled`: true,
   - `trust_mode`: the existing provider default, Allow Everything,
   - `cwd_policy`: existing default,
   - `env` and `auth_methods`: empty unless a future verified provider requires metadata.

Allow Everything remains the default for consistency with the approved ACP trust-mode design. The PATH safety rules above are required so silent auto-enablement does not come from current-directory or non-executable spoofing. Users can still change trust mode or disable the provider in Provider Settings.
5. Never mutate existing command, args, env, trust mode, enabled state, auth methods, or display name.

Storing the command name instead of the absolute path lets normal PATH changes continue to work.

## Startup Flow

On startup:

1. Load app config.
2. Run provider discovery.
3. Merge verified providers into config.
4. Save config only if merge changed it.
5. Continue app startup even if discovery or save has a non-fatal error.
6. Store filtered suggestions in Shell/provider settings state so Provider Settings can display them.

If config save fails after adding providers, Alas should still start. The in-memory config may contain the discovered provider for the current session, but the provider settings state should record a deterministic non-fatal error explaining that auto-discovered providers could not be persisted.

## Provider Settings UX

Provider Settings continues to show configured providers as editable entries. Auto-configured providers appear as normal configured providers.

Add a small suggestions area when unverified tools are detected, for example:

- “Claude Code found, but ACP command is not verified yet.”
- “Codex found, but ACP command is not verified yet.”

For V1, suggestions may be informational only. A later enhancement can add an “Add manually” action that pre-fills provider name and command while leaving args editable.

Suggestions must be filtered before display:

- Do not show a suggestion when the same provider id already exists in configured providers.
- Do not show a suggestion when the provider id is in `ignored_provider_ids`.

Deleting a provider whose id matches a known discovery registry entry should append that id to `ignored_provider_ids` before saving provider settings. This applies whether the provider was originally auto-discovered or manually added with the same known id; the user action means “do not recreate this known provider automatically.” Disabling a provider should simply keep the existing disabled provider entry; discovery will not re-enable it because existing providers are never overwritten.

## Error Handling

- Missing binaries are normal and not errors.
- Missing or malformed PATH is not fatal.
- Discovery must avoid blocking startup.
- Config save failures after discovery are non-fatal and should be surfaced as deterministic settings/debug state.
- Suggestions should not imply Claude or Codex are ready to use as ACP providers.
- Unsafe PATH entries, relative directories, and non-executable matches are ignored rather than warned about during normal startup.

## Testing

Add tests for:

- `opencode` on a fake PATH produces a verified provider with command `opencode` and args `["acp"]`.
- `claude` on a fake PATH produces a suggestion only.
- `codex` on a fake PATH produces a suggestion only.
- Existing provider config is not overwritten.
- Disabled existing provider is not re-enabled.
- Ignored provider id is not re-added.
- Merge reports `changed == true` only when providers are appended.
- Missing or empty PATH does not error.
- Empty PATH segments and relative/current-directory entries are ignored.
- Matching non-executable files are ignored.
- Duplicate PATH matches do not create duplicate providers or suggestions.
- Suggestions are not shown for already configured provider ids.
- Suggestions are not shown for ignored provider ids.
- Removing a known provider id records it in `ignored_provider_ids` before saving.
- Startup continues with deterministic error state when discovery merge changes config but save fails.

Shell-level behavior should be covered where practical, but pure discovery and merge tests are the priority.
