# Repo-shared startup hooks implementation plan

Date: 2026-09-23
Design: `docs/superpowers/specs/2026-09-23-repo-shared-startup-hooks-design.md`

## Goal

Load `.alas/hooks/session-open.sh` and `.alas/hooks/worktree-create.sh` from local and SSH worktrees, require approval for the exact event and bytes, layer them between global and explicit per-user project scripts, and apply the worktree hook to ordinary and Workspace Checkout creation.

## Implementation rules

- Use Swift Testing. Add behavior tests before production changes in each task.
- Run only the named suites while implementing. Do not run the full test plan.
- Every task that creates Swift files must run `xcodegen` and include `Alas.xcodeproj/project.pbxproj` in that task's commit.
- Keep hook file I/O out of `StartupScriptResolver`; the resolver remains pure.
- Pass loaded bytes through approval and execution. Do not approve one read and execute another.
- Preserve current shell exit and output behavior.
- Keep `.alas/config.json` and `.alas/scripts/` unchanged.

## Task 1: Add the hook domain model and three-layer resolver

**Files**

- Create `Alas/Sources/RepoHooks/RepoHook.swift`.
- Create `Alas/Sources/RepoHooks/RepoHookTrust.swift`.
- Modify `Alas/Sources/Terminal/StartupScriptResolver.swift`.
- Create `AlasTests/RepoHooks/RepoHookTests.swift`.
- Modify `AlasTests/StartupScriptResolverTests.swift`.
- Regenerate `Alas.xcodeproj/project.pbxproj`.

**Steps**

1. Add failing tests for `RepoHookEvent`:
   - `sessionOpen` maps to `.alas/hooks/session-open.sh`;
   - `worktreeCreate` maps to `.alas/hooks/worktree-create.sh`;
   - each event has a stable trust identifier and user-facing title.
2. Add failing digest tests. The digest input must be `alas-repo-hook-trust-v1`, a separator, the event identifier, a separator, and the exact bytes. Assert:
   - identical event and bytes produce the same lowercase SHA-256;
   - identical bytes for different events produce different hashes;
   - a one-byte change produces a different hash.
3. Extend resolver tests with an optional repo script. Cover all four project modes:
   - Use inherited returns `global\nrepo`;
   - Append returns `global\nrepo\nproject`;
   - Override returns project only;
   - Disabled returns empty;
   - empty parts are omitted and trimmed as they are today.
4. Run the new tests and confirm they fail because the types and resolver inputs do not exist.
5. Implement `RepoHookEvent`, `RepoHookSource`, and `RepoHookTrust.digest(event:data:)` with CryptoKit.
6. Change `StartupScriptResolver.sessionOpenScript` and `worktreeCreateScript` to require `repoScript: String?`. Replace the private two-layer helper with one that builds the inherited global-plus-repo prefix before applying `ProjectStartupScriptMode`.
7. Update existing resolver test calls to pass `repoScript: nil`; do not add a default argument that lets production call sites silently omit repo context.
8. Run `xcodegen`.
9. Run:

   ```bash
   xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
     -only-testing AlasTests/RepoHookTests \
     -only-testing AlasTests/StartupScriptResolverTests test
   ```

10. Commit as `feat(hooks): add repo hook model and resolution`.

## Task 2: Implement confined local and SSH hook loading

**Files**

- Create `Alas/Sources/RepoHooks/RepoHookLoader.swift`.
- Modify `Alas/Sources/SSH/ACPRemoteFileServer.swift` only if the current contained read cannot follow a final symlink that resolves inside the worktree.
- Create `AlasTests/RepoHooks/RepoHookLoaderTests.swift`.
- Modify `AlasTests/SSH/ACPRemoteFileServerTests.swift` when remote containment gains a hook-specific read path.
- Regenerate `Alas.xcodeproj/project.pbxproj`.

**Steps**

1. Add failing loader tests for local files:
   - missing file;
   - exact bytes and decoded text;
   - empty and whitespace-only content reported as no-op;
   - strict UTF-8 rejection;
   - exactly 262,144 bytes accepted;
   - 262,145 bytes rejected before an unbounded read;
   - directory, FIFO, device, and escaping symlink rejected;
   - a final symlink whose resolved regular-file target remains inside the worktree accepted.
2. Add failing remote tests through injected operations. Cover the same result mapping plus connection failure. Do not require a live SSH host.
3. Reuse `RemotePathContainment` rather than composing a separate lexical-only check. If final in-worktree symlinks need support, add one contained read operation that resolves the symlink and reads the resolved regular file in the same remote invocation. Bound symlink depth and reject cycles, `.git`, outside-worktree targets, and non-regular targets.
4. Implement `RepoHookLoader` as a small `Sendable` value with live local and remote readers plus injectable readers for tests. Its public operation is:

   ```swift
   func load(event: RepoHookEvent, worktreeRoot: URL, host: String?) async -> RepoHookLoadResult
   ```

5. Return distinct `missing`, `loaded`, and `failed` outcomes. Include event, repo-relative path, host, bytes, decoded text, and digest in the loaded value. Keep user-facing error text at this boundary so UI and execution paths cannot disagree.
6. Run `xcodegen`.
7. Run:

   ```bash
   xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
     -only-testing AlasTests/RepoHookLoaderTests \
     -only-testing AlasTests/ACPRemoteFileServerTests test
   ```

8. Commit as `feat(hooks): load confined local and remote hooks`.

## Task 3: Persist per-project content approvals

**Files**

- Modify `Alas/Sources/Persistence/ProjectConfig.swift`.
- Modify `Alas/Sources/App/ProjectsManager.swift`.
- Modify `AlasTests/ProjectConfigTests.swift`.
- Create `AlasTests/RepoHooks/RepoHookTrustPersistenceTests.swift`.
- Regenerate `Alas.xcodeproj/project.pbxproj`.

**Steps**

1. Add failing persistence tests:
   - old JSON decodes with no approved hashes;
   - approved hashes round-trip;
   - encoding is deterministic and omits an empty collection;
   - approving an existing hash does not duplicate it;
   - approvals remain isolated by project.
2. Add `approvedRepoHookHashes: [String] = []` to `ProjectConfig`. Decode missing data as empty. Encode a sorted, deduplicated array only when non-empty.
3. Add `ProjectsManager.isRepoHookApproved(projectId:hash:)` and `approveRepoHook(projectId:hash:)`. The mutation returns whether it changed state so callers only save when needed.
4. Extend project creation APIs to accept initial approved hashes. This supports approving a readable hook in the Add Project dialog before `ProjectConfig` exists.
5. Run `xcodegen`.
6. Run:

   ```bash
   xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
     -only-testing AlasTests/ProjectConfigTests \
     -only-testing AlasTests/RepoHookTrustPersistenceTests \
     -only-testing AlasTests/ProjectsManagerTests test
   ```

7. Commit as `feat(hooks): persist per-project hook approvals`.

## Task 4: Add a serialized approval queue and review sheet

**Files**

- Create `Alas/Sources/RepoHooks/RepoHookApprovalQueue.swift`.
- Create `Alas/Sources/RepoHooks/RepoHookApprovalSheet.swift`.
- Modify `Alas/Sources/App/AppState.swift`.
- Modify `Alas/Sources/App/RootView.swift`.
- Create `AlasTests/RepoHooks/RepoHookApprovalQueueTests.swift`.
- Regenerate `Alas.xcodeproj/project.pbxproj`.

**Steps**

1. Add failing queue tests for:
   - FIFO presentation of concurrent requests;
   - approve, skip, retry, and cancel decisions;
   - contexts that disallow cancel after checkout creation;
   - canceling an awaiting task removes or resolves its queued request exactly once;
   - one Workspace member waiting does not prevent another request from entering the queue.
2. Implement a `@MainActor`, observable `RepoHookApprovalQueue`. `requestDecision` suspends through a checked continuation and exposes only the head request to SwiftUI. Keep continuation ownership inside the queue and resume every continuation exactly once.
3. Model the execution context explicitly: session open, ordinary worktree setup, or Workspace member setup. Derive permitted buttons and copy from the context instead of branching on strings in the view.
4. Build `RepoHookApprovalSheet` with event name, relative path, SSH host, exact read-only source, approval-change warning, and context-appropriate actions.
5. Add the queue to `AppState`. Attach one `.sheet(item:)` in a dedicated root presentation modifier so all runtime requests serialize through the same presenter.
6. Keep persistence outside the queue. An Approve decision returns to the caller, which must save the project approval before execution.
7. Run `xcodegen`.
8. Run:

   ```bash
   xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
     -only-testing AlasTests/RepoHookApprovalQueueTests test
   ```

9. Commit as `feat(hooks): add serialized hook approval UI`.

## Task 5: Integrate session-open hooks into every user-startup terminal path

**Files**

- Create `Alas/Sources/App/AppState+RepoHooks.swift`.
- Modify `Alas/Sources/App/AppState.swift`.
- Modify `Alas/Sources/Terminal/TerminalService.swift`.
- Modify `AlasTests/AgentTerminalLaunchTests.swift`.
- Modify `AlasTests/ClosedTabAppStateTests.swift`.
- Modify `AlasTests/RunScriptLaunchTests.swift`.
- Create `AlasTests/RepoHooks/RepoHookSessionLaunchTests.swift`.
- Regenerate `Alas.xcodeproj/project.pbxproj`.

**Steps**

1. Add failing orchestration tests for:
   - approved local hook passed to terminal startup between global and project content;
   - SSH hook loaded from the target worktree and host;
   - unapproved hook waits, then Approve persists before opening;
   - Skip Once opens without only the repo layer;
   - Cancel opens no terminal;
   - changed content requests approval again;
   - Override and Disabled do not request approval;
   - `includeUserStartupScript == false` does not load or request approval.
   - approval-save failure reports the persistence error and opens no terminal.
2. Add an `AppState` preflight method that loads the session hook, checks project policy and trust, obtains a queue decision when required, persists approval through `saveProjects()`, and returns the approved or skipped repo script. If persistence fails, report the existing projects-save error and do not execute the approved hook.
3. Pass the resolved repo script into `TerminalService.effectiveStartupScript`. `TerminalService` remains synchronous and performs no file I/O or trust checks.
4. Make the async `openTerminalTabPreparingRemoteZmxIfNeeded` path perform preflight before the existing synchronous terminal creation seam.
5. Remove the production use of synchronous `openAgentTerminalTab`; migrate its tests and callers to the async preparing variant. Keep synchronous ACP-auth launch internal because it passes `includeUserStartupScript: false` and therefore has no hook work.
6. Make closed-terminal reopening preflight once, then reuse the same approved bytes for every pane reopened in that tab.
7. Verify manual run scripts and scheduled run scripts continue through the async preparing path. A scheduled run with an unapproved hook waits in the approval queue; it must not bypass trust or report itself started before a terminal exists.
8. Run `xcodegen`.
9. Run:

   ```bash
   xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
     -only-testing AlasTests/RepoHookSessionLaunchTests \
     -only-testing AlasTests/AgentTerminalLaunchTests \
     -only-testing AlasTests/ClosedTabAppStateTests \
     -only-testing AlasTests/RunScriptLaunchTests test
   ```

10. Commit as `feat(hooks): run approved session-open hooks`.

## Task 6: Integrate hooks into ordinary worktree creation

**Files**

- Modify `Alas/Sources/App/AppState.swift`.
- Create `AlasTests/RepoHooks/RepoHookWorktreeCreationTests.swift`.
- Regenerate `Alas.xcodeproj/project.pbxproj`.

**Steps**

1. Add failing tests using a real temporary Git repository and an injected setup runner. Assert:
   - the destination checkout exists before the loader reads its hook;
   - the selected base revision supplies the hook bytes;
   - Approve saves before setup runs;
   - approval persistence failure runs no hook and does not finish setup as approved;
   - Finish Without Hook runs global and applicable per-user content without repo content;
   - `runStartup == false`, Override, and Disabled do not load or prompt;
   - local and SSH targets select the correct runner context;
   - read failures can retry or finish without the repo layer.
2. Add an injectable worktree setup runner to `AppState` with the current `Process.run` and `RemoteExec.run` behavior as its live default. Do not change exit or output handling.
3. Move worktree startup resolution from before `performCreateWorktree` to immediately after the new worktree exists.
4. Load and approve `.alas/hooks/worktree-create.sh` from `newWorktree.path`, resolve the final script, then invoke the existing setup behavior.
5. Preserve operation-state behavior while approval is pending. The optimistic worktree remains in `.creating`; Finish Without Hook continues normal refresh and launch.
6. Run `xcodegen`.
7. Run:

   ```bash
   xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
     -only-testing AlasTests/RepoHookWorktreeCreationTests \
     -only-testing AlasTests/AppStateCreateWorktreeLaunchSurfaceTests test
   ```

8. Commit as `feat(hooks): run hooks after worktree creation`.

## Task 7: Show inherited hook status in create/edit project dialogs

**Files**

- Create `Alas/Sources/RepoHooks/RepoHookPresentation.swift`.
- Modify `Alas/Sources/Dialogs/NewProjectDialog.swift`.
- Create `AlasTests/RepoHooks/RepoHookPresentationTests.swift`.
- Modify `AlasTests/ProjectsManagerTests.swift`.
- Regenerate `Alas.xcodeproj/project.pbxproj`.

**Steps**

1. Add failing presentation-policy tests for `Approved`, `Approval required`, `Unreadable`, `Not found`, and `Check after repository is available`.
2. Add failing policy tests that show Review only for readable content and show the per-user editor only for Append/Override.
3. Rename picker labels to Use inherited, Append to inherited, Override inherited, and Disabled. Keep persisted enum values unchanged.
4. Load both hook statuses asynchronously when an existing local path or SSH project location becomes inspectable. Cancel stale tasks when path, host, or dialog mode changes.
5. Show a compact source/status row below each picker. Review opens the shared read-only hook sheet without adding a second editor implementation.
6. In Edit mode, approval saves immediately through `ProjectsManager` and `saveProjects()`. In Add mode, collect approved hashes in dialog state and pass them into project creation. Clone flows that do not yet have a checkout show the deferred-check state.
7. Run `xcodegen`.
8. Run:

   ```bash
   xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
     -only-testing AlasTests/RepoHookPresentationTests \
     -only-testing AlasTests/ProjectsManagerTests test
   ```

9. Commit as `feat(hooks): show inherited hooks in project settings`.

## Task 8: Preserve unresolved script policy in Workspace snapshots

**Files**

- Modify `Alas/Sources/Workspace/WorkspaceConfiguration.swift`.
- Modify `Alas/Sources/Persistence/ProjectConfig.swift`.
- Modify `Alas/Sources/Workspace/WorkspaceModels.swift` if snapshot coding lives there after implementation starts.
- Modify `AlasTests/Workspace/WorkspaceConfigurationResolverTests.swift`.
- Modify the Workspace snapshot coding tests that currently cover legacy defaults.

**Steps**

1. Add failing tests that a new `WorkspaceMemberConfigurationSnapshot` freezes:
   - the project worktree-create mode and project snippet;
   - the Workspace member setup mode and snippet;
   - the already-resolved legacy setup script for backward compatibility.
2. Add decoding coverage for old snapshots without the new fields. Those snapshots must keep their existing resolved script and must not acquire repo hooks during resume.
3. Add a pure member-resolution test with a repo hook:
   - project Inherit/Append retains the hook;
   - project Override/Disabled removes it;
   - Workspace member Inherit/Append retains the resolved project layer;
   - Workspace member Override/Disabled removes the project and repo layers;
   - the existing shared/global-prefix de-duplication behavior stays unchanged.
4. Extend `WorkspaceMemberConfigurationSnapshot` with optional frozen policy fields. Populate them in `WorkspaceConfigurationResolver.resolve` while continuing to write the legacy resolved `setupScript`. Add `Sendable` conformance to `ProjectStartupScriptMode` and `ProjectStartupScripts` because the snapshot is `Sendable`.
5. Add one pure helper that resolves a member script from frozen inputs plus optional repo content. Use the legacy `setupScript` only when frozen inputs are absent.
6. Run:

   ```bash
   xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
     -only-testing AlasTests/WorkspaceConfigurationResolverTests test
   ```

7. Commit as `feat(workspace): freeze repo-hook script policy`.

## Task 9: Integrate hook approval into Workspace member setup

**Files**

- Modify `Alas/Sources/Workspace/WorkspaceCheckoutCoordinator.swift`.
- Modify `Alas/Sources/App/AppState.swift`.
- Modify `AlasTests/Workspace/WorkspaceCheckoutCoordinatorCreationTests.swift`.
- Modify `AlasTests/Workspace/WorkspaceCheckoutRepairTests.swift`.
- Modify `AlasTests/RepoHooks/RepoHookApprovalQueueTests.swift`.

**Steps**

1. Add a narrow async dependency to `WorkspaceCheckoutCoordinator` that resolves the effective repo hook for one member after checkout creation. The input includes project ID, destination path, execution location, and frozen member policy. The output is approved hook text or a one-time skipped nil.
2. Give tests a no-op default so unrelated coordinator suites keep their current setup. Inject the live resolver from `AppState.workspaceCoordinator()`.
3. Add failing coordinator tests:
   - hook resolution starts only after `.worktreeCreated`;
   - a waiting member stays at `.worktreeCreated`, not `.setupRunning`;
   - another project member can continue while the first waits;
   - approval sheets serialize through the queue;
   - Approve inserts repo content at the frozen project layer;
   - Finish Member Without Hook omits only repo content;
   - resume after interruption reloads and asks again;
   - a legacy snapshot bypasses repo loading and runs its frozen resolved script.
4. Update `runSetupThrowing` to resolve the member hook before setting `.setupRunning`. Keep the loaded text in the task through decision and script execution. Do not persist source bytes in Workspace state.
5. On resume, start from the durable `.worktreeCreated` checkpoint and perform a fresh load and trust check.
6. Keep Workspace-root terminal behavior unchanged. Member worktree terminals already use the ordinary session-open path from Task 5.
7. Run:

   ```bash
   xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
     -only-testing AlasTests/WorkspaceCheckoutCoordinatorCreationTests \
     -only-testing AlasTests/WorkspaceCheckoutRepairTests \
     -only-testing AlasTests/RepoHookApprovalQueueTests test
   ```

8. Commit as `feat(workspace): approve member startup hooks`.

## Task 10: Document and verify the complete behavior

**Files**

- Modify `README.md`.
- Modify `CHANGELOG.md`.
- Remove any throwaway smoke fixtures created during verification.

**Steps**

1. Update the README's repo-local configuration section with:
   - both fixed `.alas/hooks/` paths;
   - distinction from `.alas/scripts/`;
   - global, repo, project, and Workspace member precedence;
   - content-hash approval and re-approval after byte changes;
   - local and SSH support;
   - the 256 KiB and UTF-8 requirements.
2. Add an unreleased changelog entry.
3. Run one focused test command that covers every changed contract:

   ```bash
   xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
     -only-testing AlasTests/RepoHookTests \
     -only-testing AlasTests/RepoHookLoaderTests \
     -only-testing AlasTests/RepoHookTrustPersistenceTests \
     -only-testing AlasTests/RepoHookApprovalQueueTests \
     -only-testing AlasTests/RepoHookSessionLaunchTests \
     -only-testing AlasTests/RepoHookWorktreeCreationTests \
     -only-testing AlasTests/RepoHookPresentationTests \
     -only-testing AlasTests/StartupScriptResolverTests \
     -only-testing AlasTests/WorkspaceConfigurationResolverTests \
     -only-testing AlasTests/WorkspaceCheckoutCoordinatorCreationTests \
     -only-testing AlasTests/WorkspaceCheckoutRepairTests test
   ```

4. Launch Alas and verify the actual UI with a temporary local repository:
   - status rows in Add/Edit Project;
   - source review;
   - approval before session open;
   - changed bytes re-prompt;
   - Skip Once;
   - Override and Disabled;
   - worktree-create approval after checkout exists;
   - a two-member Workspace Checkout with one approval and one skip.
5. Repeat session-open and worktree-create verification against a configured SSH project. If no SSH host is available, run the injected remote loader and remote execution smoke harness and report that live SSH UI verification was unavailable.
6. Remove temporary repositories and scripts created for smoke verification.
7. Commit documentation and cleanup as `docs: document repo-shared startup hooks`.

## Completion evidence

The final report must include:

- the exact focused test command and result;
- local UI scenarios exercised;
- live SSH scenarios exercised, or the explicit missing-host limitation plus remote harness result;
- the Workspace Checkout approval scenario;
- confirmation that no `.alas/hooks/` writer was added;
- confirmation that `project.yml` was unchanged and each new-file commit included regenerated project references.
