# Remote Web Worktree Creation Design

## Goal

Let a paired Alas Remote browser create a worktree and immediately start an ACP session in it. The flow must work well on a phone, reuse the Mac app's worktree settings, and leave filesystem and Git policy on the Mac.

## Scope

The first version exposes only the fields needed to start work: repository, base branch, new branch name, and agent. Alas uses the configured worktree path template, worktree root, fetch-before-create setting, startup script, and ACP auto-run default. Stacked-diffs mode, issue attachment, destination editing, and standalone remote worktree management are out of scope.

Creation mirrors the existing remote-session behavior. After success, Alas switches to the new worktree, opens its ACP tab on the Mac, and opens the session in the browser.

## Interaction

The existing **New session** sheet remains the entry point. Its worktree step adds **Create new worktree** above the searchable list of existing worktrees.

Choosing that action opens a compact worktree form:

- Repository picker
- Lazily loaded base-branch picker
- New branch name field
- Back and Next actions

Next opens the existing agent picker. Its primary action reads **Create worktree and session** for this path. Back navigation preserves the repository, base, branch, and agent selections. Closing the sheet clears them.

While creation runs, the sheet stays open, disables navigation, and shows progress. Success closes the sheet and subscribes the browser to the returned session. Failure keeps the sheet open and shows the server's message near the form.

## Protocol

Add these client messages:

- `listProjects`
- `listBranches(projectId)`
- `createWorktreeSession(projectId, base, branch, agentId)`

Add matching server messages:

- `projectList(projects)` with stable project IDs and display names
- `branchList(projectId, branches, preferredBase)`
- `branchListFailed(projectId, message)`
- `worktreeSessionCreated(session)`
- `worktreeSessionCreationFailed(stage, message, worktreeId?)`

The combined-creation failure stage is `worktree` or `session`. A non-nil `worktreeId` means worktree creation completed but session creation did not. Branch-loading failures use the repository-scoped `branchListFailed` response so a late failure cannot overwrite the current repository's state. Existing worktree and agent list messages remain unchanged.

The gateway suppresses superseded asynchronous project or branch-list results with generation checks, matching the existing worktree-list refresh behavior. A branch response includes its project ID so the browser can reject a late response after the user changes repositories.

## App architecture

`RemoteSessionGateway` decodes requests, calls `RemoteSessionsProvider`, and maps provider results to wire messages. It does not construct paths or run Git commands.

`RemoteSessionsProvider` gains methods for remote project options, branches for one project, and combined worktree-session creation. `AppState` implements them with existing services and settings.

For branch listing, `AppState` confirms the project still exists, asks `GitService` for branches at the project's local or SSH-backed path, and chooses a preferred base with `NewWorktreeDialog.preferredBaseBranch`. The browser can select only a branch returned for the current project.

For creation, `AppState` performs all checks again because browser state may be stale:

1. Confirm the project exists and the agent is enabled and ACP-capable.
2. Validate the new branch with `GitNameValidator`.
3. Reload or otherwise validate the requested base against the project's branches.
4. Render the destination with `WorktreePathTemplateRenderer` and reject an existing path.
5. Call `createWorktreeAndWait` with `runStartup: true` and inherited GG mode. Existing configuration controls fetch-before-create and the startup script.
6. After reconciliation returns the worktree, call the existing remote-session creation path. That path switches spaces if needed, selects the worktree, appends and activates the ACP tab, schedules attachment, and returns a session summary.

The worktree operation cannot be transactionally rolled back after Git succeeds. If session creation fails, Alas returns the created worktree ID, refreshes the browser's worktree list, and tells the user that the worktree exists but the session could not be created.

## Browser state and concurrency

The browser creation state distinguishes existing-worktree selection, new-worktree entry, agent selection, and active creation. Repository changes clear the old base, request new branches, and tag the request with the selected project ID. Late results for another project do not change the form.

Submission is enabled only when the current project has a loaded branch list, the chosen base occurs in that list, the branch name is non-empty, and an agent is selected. The server remains authoritative for every validation rule.

If the WebSocket disconnects during creation, the browser marks the outcome unknown. After reconnecting, it refreshes sessions and worktrees before enabling retry. A completed session then appears normally. If only the worktree completed, it appears in the existing-worktree list. A retry cannot create a duplicate because the server rechecks the branch and destination.

## Errors

Branch-loading errors stay within the base-branch field and provide Retry. Worktree validation and creation errors appear on the worktree step even if the user submitted from the agent step. Session-stage failures state that the worktree was created and return the user to the existing-worktree list with that worktree selected when it is available.

Error strings remain user-facing English produced by `AppState`. Logs may retain the underlying error for diagnosis, but the protocol must not expose command output, local credentials, or more filesystem detail than existing remote worktree options already reveal.

## Testing

Protocol tests cover round trips for every new message, optional partial-success data, and malformed or missing fields. Gateway tests cover list forwarding, success, each failure stage, stale asynchronous response suppression, and worktree-list refresh after partial success.

`AppState` tests use temporary Git repositories to cover preferred-base selection, branch validation, destination rendering, duplicate rejection, startup configuration, successful reconciliation followed by ACP session creation, partial success when session creation fails, space switching, and SSH-backed projects through the existing remote Git abstractions.

Extract the browser wizard's pure state transitions into a small JavaScript module, following `session-ordering.js`. Node tests cover forward and backward navigation, preserved values, late branch responses, submit enablement, disconnect recovery, and partial success. Swift asset tests verify the controls, protocol message names, script loading order, and coordinated service-worker cache revisions.

Finish with the focused Node test, `xcodegen`, a macOS build, the full test suite, and a manual narrow-phone check of the sheet.
