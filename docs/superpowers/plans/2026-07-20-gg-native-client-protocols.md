# GG Native Client Protocols Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the structured Split, keep-current Unstack, and explicit staged-only Amend contracts that native clients need while GG retains ownership of validation, history rewriting, metadata, conflicts, worktree placement, and Undo.

**Architecture:** Extract Split protocol DTOs and stable hunk identities into a focused core module. `gg split --describe` and `gg split --plan-json` form a target-bound two-step rewrite, `gg unstack --keep-current` makes worktree placement explicit and atomic for native clients that do not create a second worktree, and `gg sc --staged-only` provides deterministic index-only amend semantics independent of repository defaults.

**Tech Stack:** Rust, clap, serde/serde_json, git2, Cargo workspace integration tests, mdBook.

## Global Constraints

- Implement in an isolated worktree created from current `origin/main` of `/Volumes/Workspace/git-gud`; the inspected baseline was `59c84fd`.
- Protocol schema version is exactly `1`.
- Keep all existing interactive, TUI, `FILES...`, `--message`, and `--no-edit` behavior compatible.
- Never bypass `ImmutabilityPolicy`; structured Apply has no force field.
- Describe is read-only and must not create an operation-log record or move refs.
- Apply must validate the target SHA/tree, plan token, hunk IDs, non-empty messages, and a non-empty selection that leaves either unselected textual hunks or non-textual changes for the remainder before the first ref mutation.
- Structured Split leaves every `non_textual_files` path in the remainder commit; native clients cannot assign those files to the first commit in protocol v1.
- GG remains responsible for GG-ID assignment, descendant rebasing, conflict pause state, and operation-log recording.
- `gg unstack --keep-current` conflicts with `--worktree`, leaves the invoking worktree on the lower stack, and leaves the new upper stack without a worktree.
- New flags and JSON schemas must update `docs/src/commands/split.md`, `docs/src/commands/unstack.md`, `skills/gg/SKILL.md`, and `skills/gg/reference.md`.
- Every code commit must pass focused tests and `cargo fmt --all`.
- Final verification is `cargo clippy --all-targets --all-features -- -D warnings` and `cargo test --all-features`.

---

## File Map

- Create `crates/gg-core/src/commands/split_protocol.rs`: protocol v1 DTOs, canonical patch rendering, stable hunk IDs, plan-token generation, and plan-file decoding.
- Modify `crates/gg-core/src/commands/mod.rs`: export `split_protocol`.
- Modify `crates/gg-core/src/commands/split.rs`: move `DiffLine`/`DiffHunk` to the protocol module, add read-only Describe, add structured Apply, and extract a common rewrite function.
- Modify `crates/gg-cli/src/main.rs`: add mutually exclusive `--describe`, `--plan-json`, and `--json` split arguments and route JSON errors correctly.
- Modify `crates/gg-cli/tests/integration_tests/split.rs`: describe/apply success, stale plan, invalid selection, immutable target, and Undo integration coverage.
- Modify `docs/src/commands/split.md`: native-client protocol guide and examples.
- Modify `skills/gg/SKILL.md`: structured split workflow and agent guidance.
- Modify `skills/gg/reference.md`: exact request/response schemas and refusal behavior.
- Modify `crates/gg-core/src/commands/unstack.rs`: explicit keep-current placement mode without a checkout workaround in Alas.
- Modify `crates/gg-cli/tests/integration_tests/unstack.rs`: branch, config, JSON, conflict, and compatibility coverage for the new mode.
- Modify `docs/src/commands/unstack.md`: `--keep-current` behavior and mutual exclusion with `--worktree`.
- Modify `crates/gg-cli/src/main.rs` and `crates/gg-core/src/commands/squash.rs`: add explicit staged-only Amend mode.
- Modify `crates/gg-cli/tests/integration_tests/squash.rs`: cover staged-only index isolation, repository defaults, and refusal behavior.
- Modify `docs/src/commands/sc.md`, `skills/gg/SKILL.md`, and `skills/gg/reference.md`: document native-client staged-only Amend.

### Task 1: Define Protocol V1 And Stable Hunk Identity

**Files:**
- Create: `crates/gg-core/src/commands/split_protocol.rs`
- Modify: `crates/gg-core/src/commands/mod.rs`
- Test: `crates/gg-core/src/commands/split_protocol.rs` (`#[cfg(test)]` module)

**Interfaces:**
- Produces: `SPLIT_PROTOCOL_VERSION`, `SplitTargetIdentity`, `SplitHunkDescription`, `SplitDescribeResponse`, `SplitPlanV1`, `SplitCommitIdentity`, `SplitApplyResponse`.
- Produces: `describe_hunk(index:file_path:header:lines:)`, `plan_token(target:hunks:)`, and `read_plan(at:)`.
- Consumes later: `split.rs` uses these types without defining another JSON shape.

- [ ] **Step 1: Write failing protocol unit tests**

Add tests that construct two `DiffHunk` values with identical content and one with changed content, then assert deterministic IDs, token sensitivity, and JSON round trips:

```rust
#[test]
fn hunk_ids_are_stable_and_content_sensitive() {
    let a = test_hunk("src/lib.rs", "@@ -1,1 +1,1 @@", "-old\n+new\n");
    let b = test_hunk("src/lib.rs", "@@ -1,1 +1,1 @@", "-old\n+new\n");
    let changed = test_hunk("src/lib.rs", "@@ -1,1 +1,1 @@", "-old\n+other\n");
    assert_eq!(describe_hunk(0, &a).id, describe_hunk(0, &b).id);
    assert_ne!(describe_hunk(0, &a).id, describe_hunk(0, &changed).id);
}

#[test]
fn plan_token_changes_with_target_or_hunks() {
    let target = test_target("aaaaaaaa");
    let hunk = describe_hunk(0, &test_hunk("a", "@@ -1 +1 @@", "-a\n+b\n"));
    assert_eq!(plan_token(&target, std::slice::from_ref(&hunk)), plan_token(&target, &[hunk.clone()]));
    assert_ne!(plan_token(&target, &[hunk.clone()]), plan_token(&test_target("bbbbbbbb"), &[hunk]));
}

#[test]
fn plan_v1_round_trips() {
    let plan = SplitPlanV1 {
        version: 1,
        plan_token: "token".into(),
        target: test_target("aaaaaaaa"),
        selected_hunk_ids: vec!["h-abc".into()],
        first_message: "first".into(),
        remainder_message: "remainder".into(),
    };
    let json = serde_json::to_string(&plan).unwrap();
    assert_eq!(serde_json::from_str::<SplitPlanV1>(&json).unwrap(), plan);
}
```

Define `test_target(sha:)` in the test module as a literal `SplitTargetIdentity` with a fixed tree SHA and GG ID; define `test_hunk` beside it so every helper used above is local and explicit.

- [ ] **Step 2: Run the focused test and verify it fails**

Run: `rtk cargo test -p gg-core split_protocol::tests --all-features`

Expected: FAIL because `split_protocol` and its DTOs do not exist.

- [ ] **Step 3: Implement the protocol module**

Move `DiffLine` and `DiffHunk` from `split.rs` into the new module and derive `Clone`, `Debug`, and `PartialEq`. Add these public DTOs with `serde` snake-case field names:

```rust
pub const SPLIT_PROTOCOL_VERSION: u32 = 1;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct SplitTargetIdentity {
    pub gg_id: Option<String>,
    pub sha: String,
    pub tree: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct SplitHunkDescription {
    pub id: String,
    pub path: String,
    pub header: String,
    pub patch: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct SplitDescribeResponse {
    pub version: u32,
    pub plan_token: String,
    pub target: SplitTargetIdentity,
    pub hunks: Vec<SplitHunkDescription>,
    pub non_textual_files: Vec<String>,
    pub first_message: String,
    pub remainder_message: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct SplitPlanV1 {
    pub version: u32,
    pub plan_token: String,
    pub target: SplitTargetIdentity,
    pub selected_hunk_ids: Vec<String>,
    pub first_message: String,
    pub remainder_message: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct SplitCommitIdentity {
    pub sha: String,
    pub gg_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct SplitApplyResult {
    pub operation_id: String,
    pub original_sha: String,
    pub first: SplitCommitIdentity,
    pub remainder: SplitCommitIdentity,
    pub rewritten_descendants: Vec<SplitCommitIdentity>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct SplitApplyResponse {
    pub version: u32,
    #[serde(flatten)]
    pub result: SplitApplyResult,
}
```

Render canonical patch bytes as `header + "\n" + each origin character + content`, preserving the newline already present in `DiffLine.content`. Generate IDs with `git2::Oid::hash_object(ObjectType::Blob, canonical.as_bytes())`, formatted as `h-` plus the first 12 hex characters. Include the hunk's index and path in the canonical bytes so duplicate hunks remain distinguishable.

Generate `plan_token` the same way from protocol version, target GG ID/SHA/tree, and ordered hunk IDs, formatted as `split-v1-<12 hex>`. `read_plan(at:)` must reject unreadable JSON, versions other than `1`, empty messages after trimming, and duplicate hunk IDs using actionable `GgError::Other` messages.

Export the module from `commands/mod.rs`:

```rust
pub mod split_protocol;
```

- [ ] **Step 4: Run protocol tests and format**

Run: `rtk cargo test -p gg-core split_protocol::tests --all-features`

Expected: PASS.

Run: `rtk cargo fmt --all --check`

Expected: PASS. If it fails, run `rtk cargo fmt --all`, then rerun the check.

- [ ] **Step 5: Commit the protocol types**

```bash
rtk git status --short
rtk git add crates/gg-core/src/commands/mod.rs crates/gg-core/src/commands/split_protocol.rs
rtk git commit -m "feat(split): define structured split protocol"
```

### Task 2: Add Read-only Describe JSON

**Files:**
- Modify: `crates/gg-core/src/commands/split.rs:18-260,660-743`
- Modify: `crates/gg-cli/src/main.rs:191-217,615-633`
- Test: `crates/gg-cli/tests/integration_tests/split.rs`

**Interfaces:**
- Consumes: protocol DTOs and helpers from Task 1.
- Produces: `SplitOptions.describe: bool`, `SplitOptions.json: bool`, and `describe(options: &SplitOptions) -> Result<SplitDescribeResponse>`.
- Produces CLI: `gg split --describe --commit <target> --json`.

- [ ] **Step 1: Add failing describe integration tests**

Create a test repo with a stack commit containing two separated textual hunks. Execute:

```rust
let (success, stdout, stderr) = run_gg(
    &repo_path,
    &["split", "--describe", "--commit", "1", "--json"],
);
assert!(success, "describe failed: {stderr}");
let value: serde_json::Value = serde_json::from_str(&stdout).unwrap();
assert_eq!(value["version"], 1);
assert_eq!(value["hunks"].as_array().unwrap().len(), 2);
assert!(value["plan_token"].as_str().unwrap().starts_with("split-v1-"));
assert_eq!(run_git_full(&repo_path, &["status", "--porcelain"]).1, "");
```

Add a second assertion that two Describe calls return identical target, token, and hunk IDs. Add help coverage asserting `--describe` and `--json` appear.

- [ ] **Step 2: Run the describe test and verify it fails**

Run: `rtk cargo test -p gg-cli --test integration_tests split::test_split_describe_json --all-features`

Expected: FAIL because clap rejects `--describe`.

- [ ] **Step 3: Add CLI arguments and read-only resolution**

Extend the `Commands::Split` fields:

```rust
#[arg(long, requires = "json", conflicts_with_all = ["message", "no_edit", "no_tui", "files"])]
describe: bool,

#[arg(long)]
json: bool,
```

Add `describe` and `json` to `SplitOptions`. In command dispatch, mark the command as JSON-output whenever `describe` is true, so `main` calls `print_json_error` for failures.

Extract target resolution from `run` into:

```rust
struct ResolvedSplitTarget<'repo> {
    stack: Stack,
    target_pos: usize,
    target_commit: git2::Commit<'repo>,
    parent_commit: git2::Commit<'repo>,
    original_gg_id: Option<String>,
}

fn resolve_target<'repo>(
    repo: &'repo git2::Repository,
    config: &Config,
    target: Option<&str>,
    check_immutability: bool,
) -> Result<ResolvedSplitTarget<'repo>>;
```

Describe must open the repo, load effective config, resolve and immutability-check the target, call the existing `get_hunks`, convert each hunk with `describe_hunk`, compute `non_textual_files`, strip the original GG-ID from the remainder message, and return `SplitDescribeResponse`. It must not acquire the operation lock, require a clean worktree, call `begin_recorded_op`, or print human output.

At the top of `run`, route `options.describe` to Describe and `print_json`. Do not add `--plan-json` until Task 3, so every exposed flag works in each intermediate commit.

- [ ] **Step 4: Run focused tests and regression tests**

Run: `rtk cargo test -p gg-cli --test integration_tests split::test_split_describe_json --all-features`

Expected: PASS.

Run: `rtk cargo test -p gg-cli --test integration_tests split --all-features`

Expected: all split integration tests PASS.

Run: `rtk cargo fmt --all --check`

Expected: PASS.

- [ ] **Step 5: Commit Describe**

```bash
rtk git status --short
rtk git add crates/gg-cli/src/main.rs crates/gg-cli/tests/integration_tests/split.rs crates/gg-core/src/commands/split.rs
rtk git commit -m "feat(split): describe split hunks as JSON"
```

### Task 3: Apply A Validated Split Plan

**Files:**
- Modify: `crates/gg-core/src/commands/split.rs:87-368,560-654`
- Modify: `crates/gg-cli/src/main.rs:191-217,615-633`
- Modify: `crates/gg-cli/tests/integration_tests/split.rs`
- Test: `crates/gg-core/src/commands/split_protocol.rs`

**Interfaces:**
- Consumes: `SplitPlanV1` and Task 2 target resolution.
- Produces: `apply_plan(options: &SplitOptions, path: &Path) -> Result<SplitApplyResponse>`.
- Produces: common `execute_split(...) -> Result<SplitApplyResult>` used by interactive and structured paths.
- Produces CLI: `gg split --plan-json <path> --json`, mutually exclusive with Describe and all interactive selection/message flags.

- [ ] **Step 1: Add failing structured Apply tests**

Add integration tests for these exact cases:

- Describe a two-hunk commit, select one returned hunk ID, write the v1 plan to a temp file, Apply it, and assert three commits plus JSON `operation_id`, `first`, and `remainder`.
- Change the target commit after Describe and assert Apply returns JSON error containing `stale split plan`, with refs unchanged by Apply.
- Submit zero selected hunks, all returned hunks, an unknown hunk ID, duplicate IDs, empty messages, and `version: 2`; each must fail before refs move.
- Split a commit with a descendant and assert `rewritten_descendants` contains the rewritten descendant identity.
- Split, read the returned `operation_id`, run `gg undo <id> --json`, and assert the original stack is restored.
- Mark the target immutable and assert structured Apply returns `ImmutableTargets` without a force path.

The success call is:

```rust
let (success, stdout, stderr) = run_gg(
    &repo_path,
    &["split", "--plan-json", plan_path.to_str().unwrap(), "--json"],
);
assert!(success, "apply failed: {stderr}");
let result: serde_json::Value = serde_json::from_str(&stdout).unwrap();
assert_eq!(result["version"], 1);
assert!(result["operation_id"].as_str().unwrap().starts_with("op_"));
```

- [ ] **Step 2: Run Apply tests and verify they fail**

Run: `rtk cargo test -p gg-cli --test integration_tests split::test_split_plan --all-features`

Expected: FAIL because clap rejects `--plan-json`.

- [ ] **Step 3: Extract the common rewrite engine**

Introduce:

```rust
struct SplitSelection {
    selected_indices: Vec<usize>,
    non_hunk_files: Vec<String>,
    first_message: String,
    remainder_message: String,
}

fn execute_split(
    repo: &git2::Repository,
    config: &Config,
    resolved: ResolvedSplitTarget<'_>,
    hunks: &[DiffHunk],
    selection: SplitSelection,
    command_args: Vec<String>,
) -> Result<SplitApplyResult>;
```

Move tree building, operation recording, commit creation, descendant rebase, metadata normalization, and guard finalization from `run` into `execute_split`. Capture `guard.id().to_owned()` before finalization. After the rebase, reload the stack and map the first, remainder, and descendant positions to `SplitCommitIdentity` values.

The existing interactive path must continue to gather its selection/messages exactly as today, call `execute_split`, and print the current human summary. Do not change its prompts or file-argument behavior.

- [ ] **Step 4: Implement structured validation and JSON output**

Add `plan_json: Option<PathBuf>` to the CLI and `SplitOptions` in this task:

```rust
#[arg(long, value_name = "PATH", requires = "json", conflicts_with_all = ["describe", "message", "no_edit", "no_tui", "files"])]
plan_json: Option<PathBuf>,
```

Update Describe's conflict list to include `plan_json`, and mark command dispatch as JSON-output when `describe || plan_json.is_some()`.

`apply_plan` must perform operations in this order:

1. Decode with `read_plan`.
2. Acquire the operation lock and require a clean worktree.
3. Resolve the target and run the immutability guard with `force = false`.
4. Require exact target GG ID/SHA/tree equality.
5. Recompute hunks and descriptions and require exact token equality.
6. Map every selected ID to one unique current hunk.
7. Reject zero selected hunks. Reject selection of all selectable hunks only when no non-textual changes remain, using `No changes would remain in the remainder commit`.
8. Trim and validate both messages.
9. Keep every recomputed non-textual file in the remainder selection.
10. Call `execute_split` and print `SplitApplyResponse` with `output::print_json`.

Any failure before step 9 must leave no new operation-log record. A conflict after mutation keeps the existing interrupted operation marker and returns the normal structured JSON error envelope from `main`.

- [ ] **Step 5: Run focused, core, and Undo tests**

Run: `rtk cargo test -p gg-cli --test integration_tests split --all-features`

Expected: all split integration tests PASS.

Run: `rtk cargo test -p gg-cli --test integration_tests undo --all-features`

Expected: all Undo integration tests PASS.

Run: `rtk cargo test -p gg-core split --all-features`

Expected: all core split/protocol tests PASS.

Run: `rtk cargo fmt --all --check`

Expected: PASS.

- [ ] **Step 6: Commit structured Apply**

```bash
rtk git status --short
rtk git add crates/gg-cli/src/main.rs crates/gg-cli/tests/integration_tests/split.rs crates/gg-core/src/commands/split.rs crates/gg-core/src/commands/split_protocol.rs
rtk git commit -m "feat(split): apply structured hunk plans"
```

### Task 4: Add Explicit Keep-current Unstack Placement

**Files:**
- Modify: `crates/gg-core/src/commands/unstack.rs`
- Modify: `crates/gg-cli/src/main.rs`
- Modify: `crates/gg-core/src/output.rs`
- Modify: `crates/gg-cli/tests/integration_tests/unstack.rs`

**Interfaces:**
- Produces CLI: `gg unstack --target <target> --name <name> --no-tui --keep-current --json`.
- Produces: `UnstackOptions.keep_current: bool` and `UnstackResultJson.current_stack: String`.
- Preserves: default no-worktree behavior still switches to the upper stack; `--worktree` still creates/selects the managed upper worktree while the invoking worktree stays lower.

- [ ] **Step 1: Add failing placement tests**

Add an integration test that records the original branch, runs:

```rust
let (success, stdout, stderr) = run_gg(
    &repo_path,
    &["unstack", "--target", "3", "--name", "upper", "--no-tui", "--keep-current", "--json"],
);
assert!(success, "keep-current unstack failed: {stderr}");
let value: serde_json::Value = serde_json::from_str(&stdout).unwrap();
let (_, current_branch) = run_git(&repo_path, &["branch", "--show-current"]);
assert_eq!(current_branch.trim(), "testuser/original");
assert_eq!(value["unstack"]["current_stack"], "original");
assert!(value["unstack"]["worktree_path"].is_null());
let config: serde_json::Value = serde_json::from_str(
    &fs::read_to_string(repo_path.join(".git/gg/config.json")).unwrap(),
).unwrap();
assert!(config["stacks"]["original"]["worktree_path"].is_string());
assert!(config["stacks"]["upper"]["worktree_path"].is_null());
```

Add regression assertions that the existing default mode still finishes on `testuser/upper`, the existing `--worktree` mode still finishes on the lower branch, and clap rejects `--keep-current --worktree` before mutation.

- [ ] **Step 2: Run the focused tests and verify they fail**

Run: `rtk cargo test -p gg-cli --test integration_tests unstack --all-features`

Expected: FAIL because clap rejects `--keep-current`.

- [ ] **Step 3: Implement the explicit placement mode**

Add the mutually exclusive CLI field:

```rust
/// Leave this worktree on the lower stack without creating an upper worktree.
#[arg(long, conflicts_with = "worktree")]
keep_current: bool,
```

Pass it into `UnstackOptions`. Replace the config-migration boolean with `preserve_original_worktree = options.worktree || options.keep_current`, so the current worktree mapping remains attached to the lower stack in both modes.

Normalize the upper stack inside a closure, then restore the original branch before propagating any normalization error:

```rust
let upper_result = (|| -> Result<()> {
    git::checkout_branch(&repo, &new_branch)?;
    let upper_stack = Stack::load(&repo, &config)?;
    git::normalize_stack_metadata(&repo, &upper_stack)
})();
git::checkout_branch(&repo, &original_branch)?;
upper_result?;
```

Use that path only for `keep_current`; keep the existing default and managed-worktree paths unchanged. Set `current_stack` from the actual final placement (`original_stack` for worktree/keep-current, `new_stack_name` for default) and include it in JSON.

- [ ] **Step 4: Run focused and regression tests**

Run: `rtk cargo test -p gg-cli --test integration_tests unstack --all-features`

Expected: all Unstack integration tests PASS.

Run: `rtk cargo fmt --all --check`

Expected: PASS.

- [ ] **Step 5: Commit keep-current placement**

```bash
rtk git add crates/gg-core/src/commands/unstack.rs crates/gg-cli/src/main.rs crates/gg-core/src/output.rs crates/gg-cli/tests/integration_tests/unstack.rs
rtk git commit -m "feat(unstack): keep invoking worktree on lower stack"
```

### Task 5: Add Explicit Staged-only Amend

**Files:**
- Modify: `crates/gg-cli/src/main.rs`
- Modify: `crates/gg-core/src/commands/completions.rs`
- Modify: `crates/gg-core/src/commands/squash.rs`
- Modify: `crates/gg-cli/tests/integration_tests/squash.rs`
- Modify: `docs/src/commands/sc.md`
- Modify: `skills/gg/SKILL.md`
- Modify: `skills/gg/reference.md`

**Interfaces:**
- Produces: `gg sc --staged-only`, mutually exclusive with `--all`.
- Guarantees: native clients amend from the prepared index only and do not inherit `unstaged_action` behavior.

- [ ] **Step 1: Add failing staged-only integration coverage**

Cover `unstaged_action = add` and `stash`, stack-head and mid-stack amend behavior, untracked descendant collisions, the `--all` conflict, help output, and the no-staged-changes no-op. Assert that unstaged and untracked worktree content is never silently included or stashed by staged-only mode.

- [ ] **Step 2: Implement explicit staged-only routing**

Add the clap flag and pass it into the squash core. Preserve the existing default `gg sc` behavior for interactive users, but bypass `unstaged_action` handling when staged-only is selected. Refuse unsafe mid-stack rewrites before amending when unstaged or untracked content would collide with the descendant rebase.

- [ ] **Step 3: Document and verify staged-only Amend**

Document the native-client contract and run the focused squash integration suite, `cargo fmt --all --check`, and strict workspace Clippy.

- [ ] **Step 4: Commit staged-only Amend**

```bash
rtk git add crates/gg-cli/src/main.rs crates/gg-core/src/commands/completions.rs crates/gg-core/src/commands/squash.rs crates/gg-cli/tests/integration_tests/squash.rs docs/src/commands/sc.md skills/gg/SKILL.md skills/gg/reference.md
rtk git commit -m "feat(squash): add staged-only client mode"
```

### Task 6: Document And Verify The Protocols

**Files:**
- Modify: `docs/src/commands/split.md`
- Modify: `docs/src/commands/unstack.md`
- Modify: `skills/gg/SKILL.md`
- Modify: `skills/gg/reference.md`

**Interfaces:**
- Consumes: final v1 CLI and JSON types from Tasks 1-3.
- Produces: one authoritative schema reference for Alas and other native clients.

- [ ] **Step 1: Document the two-step client workflow**

Add a `Structured clients` section to `docs/src/commands/split.md` with runnable Describe and Apply examples, the non-empty selection and remainder rules, stale-plan semantics, immutable refusal, conflict continuation, and Undo using the returned operation ID.

- [ ] **Step 2: Update the agent skill and schema reference**

In `skills/gg/SKILL.md`, state that agents should prefer the structured protocol only when a native client is collecting hunk choices; ordinary terminal use should keep the TUI.

In `docs/src/commands/unstack.md`, document `--keep-current`, its conflict with `--worktree`, and the `current_stack` JSON field. In `skills/gg/SKILL.md`, use `--keep-current` when a native client must leave the current worktree on the lower stack without creating another worktree.

In `skills/gg/reference.md`, document every v1 field from `SplitDescribeResponse`, `SplitPlanV1`, and `SplitApplyResponse`, including `non_textual_files`, the opaque treatment of IDs/tokens, JSON errors, and the absence of a force field. Also document the Unstack placement matrix and `current_stack` result field.

- [ ] **Step 3: Build documentation and run full verification**

Run: `rtk mdbook build docs`

Expected: exit 0 with no broken-link or preprocessing error.

Run: `rtk cargo fmt --all --check`

Expected: PASS.

Run: `rtk cargo clippy --all-targets --all-features -- -D warnings`

Expected: PASS with zero warnings.

Run: `rtk cargo test --all-features`

Expected: all workspace tests PASS.

- [ ] **Step 4: Commit documentation**

```bash
rtk git status --short
rtk git add docs/src/commands/split.md docs/src/commands/unstack.md skills/gg/SKILL.md skills/gg/reference.md
rtk git commit -m "docs: document native client protocols"
```

## GG Plan Completion Gate

- [ ] Confirm `gg split --help` lists `--describe`, `--plan-json`, and `--json`.
- [ ] Confirm two Describe calls over unchanged state return identical target, token, and hunk IDs.
- [ ] Confirm every rejected plan leaves refs and the operation log unchanged.
- [ ] Confirm a successful plan can be undone by its returned operation ID.
- [ ] Confirm interactive/TUI and file-based Split tests remain green.
- [ ] Confirm docs and agent skill match the shipped schema exactly.
- [ ] Confirm `gg unstack --keep-current --json` leaves the invoking worktree on the lower stack and reports that stack in JSON.
- [ ] Confirm default and `--worktree` Unstack placement remain backward compatible.
