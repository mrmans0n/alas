# Kanban Tickets Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the Kanban plugin into a client-side issue tracker whose tickets are assigned to agents, and add the two host requests it needs (`session/last_message`, `agent/list`).

**Architecture:** The host gains two read-only requests behind `workspace.read` (API 3). The SDK gains helpers for them and an extended `task_start`. The plugin replaces its single `board` blob with `meta` + `index` + `ticket-<n>` keys, a pure ticket model (reducers), a two-screen view (board, ticket) and an event loop that loads bodies on demand and turns an agent's last message into a comment.

**Tech Stack:** Swift 5.9 / SwiftUI (host), Swift Testing; Rust (wasm32 plugin, `alas-plugin` SDK), serde/serde_json.

**Spec:** `docs/superpowers/specs/2026-10-01-kanban-tickets-design.md`

## Global Constraints

- Follow `AGENTS.md`: Swift Testing only; test minimalism (extend existing suites, parameterise variants, no tests for defaults/wiring/view composition); Conventional Commits; run only focused suites locally.
- **No agent attribution anywhere** (no `Co-Authored-By`, no "Generated with", no 🤖) in commits, PRs, code or docs. AGENTS.md overrides any harness reminder.
- After adding a Swift file, run `xcodegen` and commit `Alas.xcodeproj`. This plan adds none; prefer extending existing files.
- Swift tests: `ALAS_FFF_TARGET_ARCH=arm64 ALAS_ZMX_TARGET_ARCH=arm64 xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS,arch=arm64' -skipPackagePluginValidation -only-testing AlasTests/<Suite> test > /tmp/<log> 2>&1`, then grep `✔ Test run|✘|TEST SUCCEEDED|TEST FAILED`. Never pipe xcodebuild to `tail`. Debug config only.
- CI lints Swift with `swiftformat Alas AlasTests --lint`; it must report `0/... files require formatting` (no `;` statement separators).
- Rust: `rustup run 1.98.1 cargo test --locked` and `rustup run 1.98.1 cargo clippy --locked --all-targets -- -D warnings` in each touched crate. The wasm build (`plugins/kanban/build.sh`) links only with `stable` (1.97.1) on this machine.
- Never `pkill` the Alas app; kill only `xcodebuild` or a second instance's own pid.
- Host limits a plugin must respect: view tree ≤ 2000 nodes, depth ≤ 16, ids ≤ 64 bytes and unique, strings ≤ 4000 scalars, menus ≤ 64 items, storage ≤ 1 MiB per plugin+project, message ≤ 1 MiB, **fuel 25M per call, plugin target < 12.5M worst call**.
- Kanban text caps (spec): title ≤ 200 chars, description ≤ 8,000, labels ≤ 8 × 32, comments ≤ 50 per ticket × 4,000 chars, last message ≤ 4,096 UTF-8 bytes.

## Review Focus

1. **Crash between writes.** Body written, index not (or the reverse): the tracker must load, show the index's tickets, ignore orphan bodies, and never lose the index. Pinned in Task 4.
2. **Duplicate agent comments.** An idle transition seen again after a restart or a repeated snapshot must not add the agent's message twice. The "fetched" marker is persisted per ticket and session. Pinned in Task 3 and Task 5.
3. **Migration runs once.** With `meta` present the old `board` key is ignored; with neither, an empty tracker; a garbage `board` leaves it untouched with a notice. Pinned in Task 3 and Task 4.
4. **Edits before the body loads.** Editing the description or commenting on a ticket whose body is still loading must not write a body made of defaults over the real one. Pinned in Task 5.
5. **Ticket deleted or cancelled while its start is pending.** The later `task/start` reply must not resurrect it or attach a session to a missing ticket. Pinned in Task 5.

---

### Task 1: Host requests `session/last_message` and `agent/list`

**Files:**
- Modify: `Alas/Sources/Plugins/PluginHost.swift` (method table ~66-74, `PluginHostActions` ~42-58, `handleRequest` switch ~326)
- Modify: `Alas/Sources/Plugins/PluginMessages.swift` (param/result payload types, next to `PluginSessionFocusParams`)
- Modify: `Alas/Sources/Plugins/AppState+Plugins.swift` (`pluginHostActions(for:)`)
- Modify: `Alas/Sources/Plugins/PluginManifest.swift` (the `workspace.read` approval summary)
- Modify: `AlasTests/PluginHostTests.swift` (`makeHost` fake actions + new cases)
- Modify: `docs/plugins/api-v3.md`

**Interfaces:**
- Produces (wire): `session/last_message {id}` → `{"message": String|null}`; `agent/list` → `{"agents":[{"id","name"}]}`. Both require `workspace.read` and `manifest.api >= 3` (same gate as `storage/*`), else `-32601` below API 3 and `-32001` without the grant. Unknown session → `-32003 "unknown session <id>"`.
- Produces (Swift):
  ```swift
  enum PluginLastMessage: Equatable { case unknownSession, none, text(String) }
  // PluginHostActions gains:
  var lastMessage: (String) -> PluginLastMessage
  var agents: () -> [PluginAgent]          // struct PluginAgent: Encodable, Equatable { let id: String; let name: String }
  // .inert: lastMessage { _ in .unknownSession }, agents { [] }
  enum PluginLastMessageText { static func bounded(_ text: String, maxBytes: Int = 4096) -> String } // cut on a Character boundary
  ```

- [ ] **Step 1: Tests first.** In `PluginHostTests.swift`, give `makeHost`'s fake actions `lastMessage` (`"s1"` → `.text(String(repeating: "é", count: 3000))`, `"quiet"` → `.none`, else `.unknownSession`) and `agents` (`[PluginAgent(id: "claude", name: "Claude Code")]`). Add one parameterised test in the style of `sessionFocusIsCheckedAgainstGrants`:

  ```swift
  struct ReadCase: Sendable { let method: String; let params: String; let grants: Set<PluginCapability>; let reply: String }
  @Test(arguments: [
      ReadCase(method: "session/last_message", params: #"{"id":"s1"}"#, grants: [], reply: #""code":-32001"#),
      ReadCase(method: "session/last_message", params: #"{"id":"quiet"}"#, grants: [.workspaceRead], reply: #""result":{"message":null}"#),
      ReadCase(method: "session/last_message", params: #"{"id":"gone"}"#, grants: [.workspaceRead], reply: #""code":-32003"#),
      ReadCase(method: "agent/list", params: "{}", grants: [.workspaceRead], reply: #""agents":[{"id":"claude","name":"Claude Code"}]"#),
  ])
  func workspaceReadRequestsAreGatedAndShaped(_ c: ReadCase) async throws { /* v3Manifest with workspace.read, activate, send, check lastReply */ }
  ```
  plus one plain test that `"s1"`'s reply `message` is at most 4096 UTF-8 bytes and is a prefix of the original (no split `é`). Add `bounded` cases to the same test file only if not already covered by that assertion (they are; do not add more).
- [ ] **Step 2:** Run `-only-testing AlasTests/PluginHostTests`; expect the new tests to fail (unknown method `-32601`).
- [ ] **Step 3: Implement.** Method table: `"session/last_message": .workspaceRead, "agent/list": .workspaceRead`, and extend the existing `storage/*` API-3 gate to these two. `handleRequest` cases: decode `{id}` with the existing session params type (`-32602` on bad params); map `.unknownSession` → `-32003 "unknown session \(id)"`, `.none` → `{"message":null}`, `.text(t)` → `{"message": PluginLastMessageText.bounded(t)}`. `agent/list` → `{"agents": actions.agents()}`.
- [ ] **Step 4: AppState.** In `pluginHostActions(for:)`:
  - `lastMessage`: find the session the same way `focusSession` does (active sidebar rows of the project's worktrees, matched by `PluginWorkspaceSnapshot.SessionInput(row:).id`); not found → `.unknownSession`. Then `acpManager(forWorktreeId:)?.liveSession(for: id)?.transcript.messages` → last `.agent(_, _, text)` → `text.value`; trim; empty or none → `.none`. Terminal sessions → `.none`.
  - `agents`: `agentRegistry.enabled().filter { ACPLaunchCatalog.spec(for: $0.id) != nil }.map { PluginAgent(id: $0.id, name: $0.displayName) }`, in registry order. Check the real property names before using them.
- [ ] **Step 5: Approval text.** Extend the `workspace.read` summary in `PluginManifest.swift` to say plugins can read an agent's final reply in this project (e.g. "Read worktrees, sessions and agents' final replies in this project"). If a test pins the old text, update it.
- [ ] **Step 6: Docs.** `docs/plugins/api-v3.md`: a new section after Storage, "Reading sessions and agents", documenting both requests, the 4,096-byte bound, `null`, errors, and that they need `workspace.read` and API 3.
- [ ] **Step 7:** Run `PluginHostTests` (all pass) and `swiftformat Alas AlasTests --lint` (0 files).
- [ ] **Step 8: Commit** `feat(plugins): let plugins read an agent's last reply and the installed agents`.

---

### Task 2: SDK helpers

**Files:**
- Modify: `plugins/alas-plugin/src/lib.rs`

**Interfaces:**
- Consumes: Task 1 wire shapes.
- Produces:
  ```rust
  pub fn last_message(session_id: &str) -> i64;          // reply: Event::Reply, parse with parse_last_message
  pub fn agent_list() -> i64;                            // reply: Event::Reply, parse with parse_agents
  pub fn task_start_with(title: &str, prompt: &str, branch: Option<&str>, agent: Option<&str>) -> i64;
  #[derive(Debug, Clone, PartialEq, Deserialize)] pub struct Agent { pub id: String, pub name: String }
  pub fn parse_last_message(result: &Value) -> Option<String>;   // {"message": "..."} → Some, null/missing → None
  pub fn parse_agents(result: &Value) -> Vec<Agent>;             // malformed → empty
  ```
  `task_start` stays and calls `task_start_with(title, prompt, None, None)`; omitted options are not serialised.

- [ ] **Step 1: Test.** Extend the existing `task_and_storage_helpers_send_the_documented_requests` test (do not add a sibling) to assert the wire shape of `last_message("s1")` (`{"method":"session/last_message","params":{"id":"s1"}}`), `agent_list()` (`params` `{}`), and `task_start_with("t","p",Some("task/kan-3"),Some("claude"))`; and one assertion each that `parse_last_message`/`parse_agents` decode the documented results and return `None`/empty on `null`/garbage.
- [ ] **Step 2:** `rustup run 1.98.1 cargo test --locked` in `plugins/alas-plugin` → the new assertions fail to compile.
- [ ] **Step 3:** Implement with the existing typed `Params` serialisation (no `json!` on the hot path).
- [ ] **Step 4:** Tests and clippy pass in `plugins/alas-plugin`, `plugins/kanban`, `plugins/pixel-office` (pixel-office has 3 pre-existing clippy lints; do not fix them, do not add new ones).
- [ ] **Step 5: Commit** `feat(plugins): SDK helpers for last messages, agents and task options`.

---

### Task 3: Ticket model, following and migration

**Files:**
- Create: `plugins/kanban/src/tickets.rs`
- Modify: `plugins/kanban/src/board.rs` (keep only what migration needs to parse the old `board` value: `Board`, `Card`, `Column`; delete reducers no longer used once Task 5 lands — in this task, leave them and add `#[allow(dead_code)]` only if clippy requires)
- Modify: `plugins/kanban/src/lib.rs` (`mod tickets;` only)

**Interfaces:**
- Produces:
  ```rust
  #[derive(Serialize, Deserialize, Clone, Copy, PartialEq, Eq, Debug)] #[serde(rename_all = "snake_case")]
  pub enum Status { Backlog, Todo, InProgress, InReview, Done, Cancelled }   // ALL, title(), key(), from_key()
  #[derive(... same, Default)] pub enum Priority { #[default] None, Low, Medium, High, Urgent }
  #[derive(Serialize, Deserialize, Clone, PartialEq, Debug)]
  pub struct Entry {            // one index record
      pub number: u64, pub title: String, pub status: Status, #[serde(default)] pub priority: Priority,
      #[serde(default)] pub assignee: Option<String>, #[serde(default)] pub session_id: Option<String>,
      #[serde(default)] pub branch: Option<String>, #[serde(default)] pub agent_state: Option<String>,
      #[serde(default)] pub following: bool, #[serde(default)] pub seen: bool,
      #[serde(default)] pub fetched: bool,   // last message already fetched for this session's current idle
      #[serde(default)] pub error: Option<String>,
  }
  #[derive(Serialize, Deserialize, Clone, PartialEq, Debug, Default)]
  pub struct Body { #[serde(default)] pub description: String, #[serde(default)] pub labels: Vec<String>, #[serde(default)] pub comments: Vec<Comment> }
  #[derive(Serialize, Deserialize, Clone, PartialEq, Debug)]
  pub struct Comment { pub author: Author, pub text: String }   // Author { You, Agent }, snake_case
  #[derive(Serialize, Deserialize, Clone, PartialEq, Debug, Default)]
  pub struct Meta { pub version: u32, pub next_number: u64 }
  #[derive(Default)] pub struct Tracker { pub meta: Meta, pub index: Vec<Entry> }
  pub enum Follow { Unchanged, Changed, FetchLastMessage(u64 /*number*/, String /*session*/) }
  impl Tracker {
      pub fn create(&mut self, title: &str, priority: Priority, assignee: Option<String>) -> Option<u64>; // None: empty title or index full
      pub fn entry(&self, number: u64) -> Option<&Entry>; pub fn entry_mut(&mut self, number: u64) -> Option<&mut Entry>;
      pub fn set_status(&mut self, number: u64, status: Status);   // Done/Cancelled stop following; others follow iff session
      pub fn delete(&mut self, number: u64);
      pub fn started(&mut self, number: u64, session_id: String, branch: String); // InProgress, following, clears seen/fetched/agent_state/error
      pub fn start_failed(&mut self, number: u64, reason: &str);   // error only (non-destructive)
      pub fn task_failed(&mut self, session_id: &str, reason: &str); // clears the session, back to Todo, error set
      pub fn sync(&mut self, sessions: &[(String, String, String)]) -> (bool, Vec<(u64, String)>); // (changed, last messages to fetch)
      pub fn archive(&mut self) -> Vec<u64>;                       // drops oldest Done/Cancelled past ARCHIVE_KEEP; returns their numbers
      pub fn in_status(&self, status: Status) -> impl Iterator<Item = &Entry>;
      pub fn migrate(board: &crate::board::Board) -> (Tracker, Vec<(u64, Body)>);
  }
  impl Body { pub fn comment(&mut self, author: Author, text: &str); } // trims, clips to MAX_COMMENT_CHARS, drops oldest past MAX_COMMENTS; empty → no-op
  pub const MAX_TITLE_CHARS: usize = 200; pub const MAX_DESCRIPTION_CHARS: usize = 8_000;
  pub const MAX_LABELS: usize = 8; pub const MAX_LABEL_CHARS: usize = 32;
  pub const MAX_COMMENTS: usize = 50; pub const MAX_COMMENT_CHARS: usize = 4_000;
  pub const MAX_INDEX: usize = 200;      // provisional; Task 6 sets it from the fuel probe
  pub const ARCHIVE_KEEP: usize = 50;    // provisional; closed tickets kept in the index
  pub const FORMAT_VERSION: u32 = 1;
  ```
- `sync` rules (spec §3): only entries with `following && session_id` are moved; act only on a *change* of the session's state (compare to `agent_state`) or on absent-after-seen; `running` → `InProgress`; `awaiting_input`/`permission_request` → `InProgress`; `idle` → `InReview`; absent after seen → `InReview`; never seen and absent → unchanged; `unknown` → unchanged (still record `seen`). Branch from the snapshot replaces `branch` when it differs (counts as changed, also for non-following entries). When a session transitions to `idle` and `!fetched`, push `(number, session_id)` to the fetch list and set `fetched = true`; any later transition to `running` resets `fetched = false`.
- Migration column map: Backlog → `Backlog`, Running/NeedsYou → `InProgress`, Review → `InReview`, Done → `Done`. Numbers follow the old card order starting at 1; `meta.next_number` = count + 1. Card `prompt` → body description (first line was the title). Session, branch, agent state, following, seen carried over; `fetched = true` for migrated idle sessions so nothing is fetched retroactively.

- [ ] **Step 1: Tests** in `tickets.rs` (`#[cfg(test)] mod tests`), one behaviour each, table-driven where variants exist:
  - `numbers_are_never_reused` (create 1,2, delete 2, create → 3; `create("")` → None; index full → None).
  - `session_states_move_following_tickets` (table over the sync rules above, including manual hold: `set_status(InReview)` then an unchanged snapshot keeps it, a changed state moves it; Done/Cancelled never move).
  - `idle_fetches_the_last_message_once` (running→idle yields one fetch; the same idle snapshot again yields none; running→idle again yields one more).
  - `a_rejected_start_keeps_the_session_and_a_failed_task_clears_it`.
  - `comments_are_capped_and_clipped` (51st drops the oldest; 4,001 chars clipped; empty ignored).
  - `migration_maps_columns_and_keeps_sessions` (all five columns; numbers in card order; description from prompt; fetched true for idle).
  - `archive_keeps_the_newest_closed_tickets`.
- [ ] **Step 2:** `cargo test --locked` in `plugins/kanban` → fails (module missing).
- [ ] **Step 3:** Implement `tickets.rs`.
- [ ] **Step 4:** Tests and clippy pass.
- [ ] **Step 5: Commit** `feat(kanban): ticket model, session following and migration from cards`.

---

### Task 4: Storage layout and loading

**Files:**
- Create: `plugins/kanban/src/store.rs`
- Modify: `plugins/kanban/src/lib.rs` (`mod store;` only)

**Interfaces:**
- Consumes: Task 3 types; SDK `storage_get`, `storage_set`, `Event::Stored`.
- Produces a pure, testable loader/writer (no SDK calls inside, so it is unit-testable):
  ```rust
  pub const META: &str = "meta"; pub const INDEX: &str = "index"; pub const LEGACY: &str = "board";
  pub fn body_key(number: u64) -> String;                       // "ticket-<n>"
  pub enum Loaded { Fresh, Tracker(Tracker), Migrated(Tracker, Vec<(u64, Body)>), Unreadable(String) }
  /// Decide what was stored, given the raw replies for meta, index and (only when meta is absent) the legacy board.
  pub fn load(meta: Option<&str>, index: Option<&str>, legacy: Option<&str>) -> Loaded;
  pub fn parse_body(raw: Option<&str>) -> Body;                 // missing or unreadable → Body::default()
  /// The writes for one change, in order: bodies first, then index, then meta. Each item is (key, raw JSON or None to delete).
  pub fn writes(tracker: &Tracker, bodies: &[(u64, &Body)], deleted: &[u64], index_changed: bool) -> Vec<(String, Option<String>)>;
  ```
- Rules: `meta` present → parse `meta` + `index` (index missing → empty), never look at `board`; a `meta`/`index` that does not parse → `Unreadable` (the caller shows a notice and never saves). `meta` absent and `board` present and parseable → `Migrated`; `board` unparseable → `Unreadable` with a notice text that the old board was left untouched. Neither → `Fresh`. Index entries keep their numbers; `meta.next_number` is raised to `max(number) + 1` if lower. Deletes come after the index write.

- [ ] **Step 1: Tests** in `store.rs`: `loading_picks_the_stored_format` (table: fresh; meta+index; meta without index; legacy only → migrated; legacy garbage → unreadable; meta garbage → unreadable; meta + legacy → legacy ignored); `writes_put_bodies_before_the_index_and_deletes_last`; `a_stale_next_number_is_raised`.
- [ ] **Step 2–4:** fail, implement, pass (+ clippy).
- [ ] **Step 5: Commit** `feat(kanban): store tickets as an index plus one key per ticket`.

---

### Task 5: Screens and the plugin loop

**Files:**
- Modify: `plugins/kanban/src/view.rs` (rewrite)
- Modify: `plugins/kanban/src/lib.rs` (rewrite the plugin state and event handling)
- Modify: `plugins/kanban/src/board.rs` (trim to the migration types)
- Modify: `plugins/kanban/plugin.json` only if a capability changes (it should not: `workspace.read`, `session.focus`, `tasks.start`)

**Interfaces:**
- Consumes: Tasks 2–4.
- View:
  ```rust
  pub enum Screen { Board { show_cancelled: bool }, Ticket(u64) }
  pub struct ViewState<'a> {
      pub tracker: &'a Tracker, pub screen: &'a Screen, pub body: Option<&'a Body>, // body of the open ticket, None while loading
      pub agents: &'a [Agent], pub form: u64, pub notice: Option<&'a str>, pub starting: &'a [u64],
  }
  pub fn render(state: &ViewState) -> Node;
  ```
  Ids are built only from fixed words and ticket numbers (`ticket-<n>`, `ticket-<n>-title`, `status-<n>`, `priority-<n>`, `assign-<n>`, `start-<n>`, `open-<n>`, `cancel-<n>`, `delete-<n>`, `comment-<n>-<form>`, `description-<n>-<form>`, `back`, `new-title-<form>`, `new-description-<form>`, `new-priority-<form>`, `new-assignee-<form>`, `create`, `show-cancelled`, `col-<key>…` as now). Keep the per-column vertical scroll from the current view. The ticket screen shows "Loading…" while `body` is `None` and renders no editable description/comment fields until it loads.
- Plugin state (replaces the `Kanban` fields): `tracker`, `screen`, `open_body: Option<(u64, Body)>`, `agents: Vec<Agent>`, `form`, `notice`, `loaded`, `load_failed`, request-id bookkeeping (`load: [i64; 3]` for meta/index/legacy, `body_request: Option<(i64, u64)>`, `pending_starts: Vec<(i64, u64)>`, `fetches: Vec<(i64, u64)>`, `agent_request: Option<i64>`, `saves: Vec<i64>`), `sessions: Option<Vec<(String,String,String)>>`, and `draft: Draft { title: String, priority: Priority, assignee: Option<String> }` for the New ticket form (title is stored on `submit`, like the old title field was; ⌘Return in the description creates the ticket, using the draft title or the description's first line).
- Behaviour:
  - Activate → request `meta`, `index`, `board` (legacy) in one go plus a snapshot and `agent_list()`. When all three storage replies are in, call `store::load`. `Migrated` → write all bodies, index and meta (bodies first), leave `board`. `Unreadable` → notice, `load_failed = true`, render, never save.
  - Every change goes through one `commit(index_changed, bodies, deleted)` that issues `store::writes` in order (skip all writes while `load_failed`) and re-renders. A snapshot that changes nothing neither writes nor renders (as now).
  - Opening a ticket requests its body (`body_request`); its description and comment fields are not rendered until the body arrives, and any event for them that still arrives is ignored (no write of a default body). Leaving the ticket screen drops `open_body`.
  - `sync` fetch list → `last_message(session)` per item, tracked in `fetches`; the reply appends an `Agent` comment to that ticket's body: if the body is not open, request it first, then append and write it. A failed or empty fetch shows a notice.
  - Start (`start-<n>`): `task_start_with(title, prompt, Some(&format!("task/kan-{n}")), assignee.as_deref())` where `prompt` is `"KAN-<n>: <title>\n\n<description>"` (needs the body: if not loaded, load it first, then start). Ignore a second Start while one is pending for that ticket. The reply attaches the session only if the ticket still exists and is not Done/Cancelled; otherwise ignore it (the agent keeps running; nothing is resurrected).
  - `TaskFailed` → `tracker.task_failed`. Rejected start → `start_failed` (non-destructive).
  - The Assign menu lists `agents`; refresh with `agent_list()` each time a ticket screen opens. Empty list → a single disabled "No agents available" label instead of the menu.
  - `open-<n>` → `request("session/focus", {"id": session})`.

- [ ] **Step 1: Tests.** Replace the current `lib.rs` and `view.rs` tests (delete those that no longer apply; keep the count lean):
  - view: `the_board_has_five_columns_and_cards_carry_index_data` (+ Cancelled column only with `show_cancelled`); `a_full_tracker_stays_within_the_host_limits` (MAX_INDEX tickets in one status, max-length titles: unique ids, ≤ 2000 nodes, depth ≤ 16); `the_ticket_screen_waits_for_its_body`.
  - lib (through `test_host`): `a_legacy_board_is_migrated_once_and_left_in_place`; `an_unreadable_store_is_never_overwritten`; `an_idle_session_adds_its_last_message_as_one_comment` (snapshot running→idle → one `session/last_message` sent; reply → body write with an agent comment; same snapshot again → nothing sent); `edits_before_the_body_loads_write_nothing`; `a_start_reply_for_a_deleted_ticket_is_ignored`; `start_sends_the_ticket_and_assignee`.
- [ ] **Step 2:** fail. **Step 3:** implement; trim `board.rs` to the migration types (delete `Board`'s reducers and their tests). **Step 4:** `cargo test --locked` + clippy pass; `plugins/kanban/build.sh` (with `stable`) builds.
- [ ] **Step 5: Commit** `feat(kanban): tickets with a board and a ticket screen`.

---

### Task 6: Fuel caps, docs and live check

**Files:**
- Modify: `plugins/kanban/src/tickets.rs` (`MAX_INDEX`, `ARCHIVE_KEEP` from the measurement)
- Modify: `plugins/kanban/README.md`, `CHANGELOG.md` (`[Unreleased]`, ✨ Features), `docs/plugins/api-v3.md` (Reference plugin section)

- [ ] **Step 1: Fuel probe (throwaway, never committed).** As in #1653: a temporary `AlasTests/ZZFuelProbeTests.swift` (run `xcodegen` to include it) that loads the built kanban wasm into a real `PluginHost` (Debug), with storage pre-seeded with `meta`, an index at the candidate cap (max-length titles, every ticket with a session, spread over statuses and all in one status) and max-size bodies, plus a snapshot with every session. Measure activation+load+first render, a moving snapshot, opening a max-size ticket, adding a comment, and an idle→last_message comment. Bisect the largest `MAX_INDEX` (and `ARCHIVE_KEEP`) whose worst call is < 12.5M; also confirm a real host with `fuelPerCall: 12_500_000` stays active. Delete the probe, `git checkout -- Alas.xcodeproj`. Record numbers in the commit message body.
- [ ] **Step 2:** Set the constants; if the index cap must be below 50, report it rather than shrinking text caps.
- [ ] **Step 3: Docs.** README: tickets, statuses, priorities, assignment, Start, agent comments, migration, caps. CHANGELOG entry. `api-v3.md` Reference plugin paragraph.
- [ ] **Step 4: Live check** in an isolated profile on a scratch repo (recipe: project memory `alas-drive-second-instance-via-osascript`; never touch prod, quit the instance by its own pid/menu, guard every keystroke with a frontmost check). Seed an old-format `board` key in the profile's `PluginData` and confirm migration; create, assign and start a ticket with the prompt "Reply with only the word hello"; watch In progress → In review; confirm the agent's reply appears as one comment; open the session; edit the description, comment, change status; quit and relaunch; confirm everything restored. Screenshot each step. Clean up worktrees, branches, scratch repo, profile, preferences suite. Report anything not verified.
- [ ] **Step 5: Commit** `feat(kanban): size the tracker from a fuel measurement and document tickets`.
