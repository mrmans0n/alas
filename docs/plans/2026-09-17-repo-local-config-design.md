# Repo-local `.alas/` configuration — design

Date: 2026-09-17

## Motivation

Teams sharing a repo should be able to commit Alas configuration alongside the
code: the project logo, MCP integrations, and the default worktree agent.
Today every per-project setting lives in the app-level, per-user
`projects.json` (`ProjectConfig`) and cannot be shared. There is already an
in-repo precedent: `.alas/scripts/` for run scripts. This design extends that
convention into a committed, team-shared config layer.

## Decisions (from brainstorming)

- **Per-key precedence semantics.** Repo config acts as team-provided
  *defaults*; app-level project settings win where explicitly set. MCP servers
  merge by name rather than override wholesale.
- **Trust-once approval for repo MCP servers.** A repo-defined server must be
  approved once (keyed by config hash) before it can attach to a session;
  editing it in the repo re-triggers the prompt.
- **Scope for v1:** icon, MCP servers, default agent only. The format is built
  to grow (tolerant decoding, each key independently defaulted) so adding keys
  later is a small diff.

## Layering

```
global defaults → repo config (.alas/) → per-user ProjectConfig
```

Each layer only contributes keys it explicitly sets. Nothing repo-derived is
ever written back into `projects.json`.

## On-disk format

In the repo, beside the existing `.alas/scripts/`:

- `.alas/config.json` — optional; `mcpServers`, `defaultAgent`, optional `icon`
- `.alas/icon.png` (or `.svg`/`.jpg`/`.jpeg`) — convention path, no config needed

```json
{
  "version": 1,
  "icon": { "image": "logo.png" },
  "defaultAgent": "pi",
  "mcpServers": [
    { "name": "linear", "transport": { "type": "http", "url": "https://mcp.linear.app/mcp" } }
  ]
}
```

- Versioned, tolerant per-key decoding: unknown keys are ignored so future
  keys ship without breaking older Alas versions.
- `mcpServers` reuses the existing `ProjectMCPTransport` Codable shapes, so
  the current MCP editor UI can read/write repo-defined servers without a
  parallel model. IDs derive deterministically from the server name (not
  random UUIDs) so a repo-edited server keeps its identity across loads — the
  trust-hash flow depends on this.
- `defaultAgent` stores the agent's existing id string; unknown/missing ids
  resolve to "no repo default" and fall through.
- `icon.image` resolves relative to `.alas/`. Absent key → discovery order
  `icon.png`, `icon.svg`, `icon.jpg`, `icon.jpeg`.

## Read location and reload

- **Session-scoped keys** (`mcpServers`, `defaultAgent`) resolve from the
  session's **worktree root**, so the config matches the checked-out branch
  (same convention as `.alas/scripts/`).
- **Project-scoped keys** (`icon`) resolve from the repo's **primary
  checkout** — stable and always present, since the icon renders at project
  level in the sidebar.
- No file watchers in v1. `RepoConfigStore` caches per worktree path with the
  config file's mtime; every lookup stats the file and reparses on change.
  Icons resolve to absolute path + mtime, `NSImage` cached by that pair.
  Changes from `git pull`/branch switches appear on the next natural lookup.

## Icon resolution

Effective icon chain:

1. **App-level, if explicit.** An app icon counts as explicit when it is
   anything other than the untouched default: mode ≠ `.letter`, or any of
   label/emoji/symbol/image set. Explicit always wins.
2. Repo `config.json` `icon` key (path relative to `.alas/`).
3. Discovered `.alas/icon.{png,svg,jpg,jpeg}`.
4. Current letter fallback, unchanged.

Color carries over: repo config only supplies an *image*. A user's custom
squircle color (and `transparentBackground`) merges onto the repo icon rather
than blocking it — a color pick should not veto the team logo. Repo icons
render in image mode, which draws no background.

Renders via the existing `ProjectIcon.image` mode and `ProjectIconView`; the
resolution layer maps the repo-relative path to absolute before rendering.
Nothing repo-derived is persisted. Implementation detail to verify: whether
the existing image pipeline accepts SVG via `NSImage`; if not, SVG drops out
of the discovery list and we document PNG.

## MCP servers and trust

**Merge.** Effective servers = repo servers + app-level `mcpServers`, keyed by
name. An app-level server with the same name fully replaces the repo one (and
needs no trust — it is the user's own config). `ProjectConfig` gains one
sparse field, `disabledRepoMCPServers: [String]` (names), settable from the
existing MCP status control, for "the repo wants it, I don't."

**Trust storage.** On `ProjectConfig` (per-user, per-project — trust is a user
decision about this repo): `repoMCPTrust: [String: RepoMCPTrustState]`, keyed
by SHA-256 over the server's canonical config (name + transport, stable
encoding), state `approved` or `declined`. Recording declines prevents nagging:
unknown prompts, declined stays silent, approved attaches.

**Prompt.** Non-blocking banner on the project/workspace (same pattern as
`ACPSetupNudgeBanner`), not a modal at session start: "This repo defines N MCP
servers" with Review / Approve All / Decline. Review opens a read-only detail
sheet (command, URL, env names — not values) with per-server Approve/Decline.

**Attachment.** `MCPAttachmentPlanner` gains a filter step: repo servers pass
only when approved, not disabled, and not shadowed by an app-level name.
Declined/unknown servers surface in the MCP status control as "not enabled
(repo)".

**Repo edits.** Changing a server changes its hash → unknown → re-prompt by
name. Stale hashes are inert; no GC in v1. Trust keyed by hash means the same
config approved on `main` stays approved on a PR branch.

## Default agent resolution

`defaultAgent` slots into the existing `ProjectStartupScripts` model:

1. `worktreeAgentMode` is `.overrideGlobal`/`.appendToGlobal`/`.disabled`, or
   `worktreeAgentId` is set → app-level wins, repo ignored.
2. Mode is `.useGlobal` and repo config has `defaultAgent` → repo agent.
3. Otherwise → global default, as today.

`useGlobal` effectively becomes "use inherited" (repo first, then global).
Unknown/uninstalled agent ids fall through to global with a debug log.

Scope unchanged: this controls the agent launched on worktree creation, same
as the current per-project agent setting.

**Excluded:** bypass-permissions stays user-only. A repo file must never opt a
teammate into auto-accepting agent permissions;
`worktreeAgentUseBypassPermissions` remains app-level regardless.

**UI:** the agent picker keeps its three states (Global / None / specific
agent). When the effective pick comes from the repo, it shows a caption —
"Repo default: pi (from `.alas/config.json`)".

## Error handling and non-goals

- Malformed `config.json` / bad `version` → treated as absent, logged to
  diagnostics. Bad individual entries (e.g. a server missing a name) are
  skipped, not file-fatal. Unloadable icon files fall through to the letter
  default. Repo config must never break project display.
- **Remote repos:** v1 reads repo config for local projects only; for
  `host != nil` projects the layer is silently absent (no SSH round-trip on
  hot paths). Deferred, not designed-forbidden.
- **Not in v1:** startup scripts, gg mode, launch preference, per-user
  `.local` override files, file watchers, bypass-permissions from repo,
  "set as project override" convenience action.

## Testing

Swift Testing suites in `AlasTests`, all against a pure resolution layer
(`RepoConfigResolver`) operating on plain inputs — no UI tests for v1:

- `RepoConfig` decoding: unknown keys tolerated, bad version, partial server
  entries, deterministic id derivation from names.
- Icon resolution: explicit-heuristic table, color carry-over, discovery
  order, missing-file fallthrough.
- MCP merge: name shadowing, disable list, trust-hash stability (same config →
  same hash), approve/decline/unknown filtering into the attachment plan.
- Agent resolution: the three-layer chain plus unknown-id fallthrough.
