# Effortless Remote Worktrees Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users pick the machine a new worktree runs on, from a managed
machine list, and show remote worktrees inside the same project group as local
ones.

**Architecture:** Machines are a list in `AppConfig`. An SSH `ProjectConfig`
gets linked to the local project with the same git origin, and the sidebar
lists its worktrees under that project. Creating a worktree on a machine
creates it in the linked record, using the existing SSH creation path. The
plan covers five PRs. PR 1 is detailed here. PRs 2–5 are outlined, and each
gets detailed in this file once the previous PR lands, so its plan reads the
code as it actually is.

**Tech Stack:** Swift 5.9+, SwiftUI (app), `Packages/AlasCore` (UI-free core),
Swift Testing.

**Spec:** `docs/superpowers/specs/2026-11-14-effortless-remote-worktrees-design.md`

## Global Constraints

- English for code, comments, logs, and UI strings.
- Commit titles follow Conventional Commits. No agent attribution of any kind:
  no `Co-Authored-By` trailers and no generated-by footers.
- Core code in `Packages/AlasCore` must not import SwiftUI, AppKit, or
  GhosttyKit. Anything the app uses from the package must be `public`.
- Tests use Swift Testing (`import Testing`). Test pure decisions only, no
  view tests, and parameterize with `@Test(arguments:)`.
- A new file under `Alas/Sources` needs `xcodegen` run, and both
  `project.yml` and `Alas.xcodeproj` committed. Without that, the file and any
  new suite are silently left out of the build.
- Run `swiftformat --lint` on the changed files before pushing, because CI
  fails on lint first.
- Never `pkill` the Alas app binary: the release app may be running. Kill only
  `xcodebuild`.

## Review Focus

1. **Projects folder written as `~/…`.** It must expand on the machine, not
   on the Mac, and must never be single-quoted into a literal `~`. Covered by
   the Task 2 test `tildeFolderExpandsOnTheMachine`.
2. **Folder with spaces or quotes** (`~/My Code`, `/srv/o'brien`). It must be
   shell-quoted. Covered by the Task 2 test arguments.
3. **Seeding with a host already in the list but a different label.** The
   user's label must survive the next launch. Covered by the Task 1 test
   `seedingKeepsExistingMachines`.
4. **SSH project whose host is `RemotePath.unavailableHost` or invalid.** It
   must never become a machine. Covered by the Task 1 test
   `seedingSkipsUnroutableHosts`.
5. **First contact needs a host key or password.** Test must open the
   connection assistant instead of reporting a bare failure. This is UI
   wiring, so it is checked by hand in Task 4, step 6.

---

## PR 1: `feat(remote): manage SSH machines in Settings`

### Task 1: `Machine` model, `AppConfig.machines`, and seeding

**Files:**
- Create: `Packages/AlasCore/Sources/AlasModel/Persistence/Machine.swift`
- Modify: `Packages/AlasCore/Sources/AlasModel/Persistence/AppConfig.swift`
  (property near `repositoryCloneRootPath` at line 113, `CodingKeys` at line
  926, tolerant decode next to line 1238, `encode` if it is hand-written)
- Test: `Packages/AlasCore/Tests/AlasCoreTests/MachineTests.swift`

**Interfaces:**
- Produces:
  - `public struct Machine: Codable, Equatable, Identifiable, Sendable`
    - `public let destination: String`
    - `public var label: String`
    - `public var projectsFolder: String`
    - `public var id: String { destination }`
    - `public init(destination: String, label: String? = nil, projectsFolder: String)`.
      The label defaults to `destination`.
  - `public static func defaultProjectsFolder(cloneRoot: String, localHome: String = NSHomeDirectory()) -> String`
  - `public static func seeded(_ machines: [Machine], projectHosts: [String], defaultProjectsFolder: String) -> [Machine]`
  - `AppConfig.machines: [Machine] = []`, decoded tolerantly (a missing or
    bad value gives `[]`).

- [ ] **Step 1: Write the failing tests** in `MachineTests.swift`
  (`@Suite struct MachineTests`):
  - **`defaultProjectsFolder`, parameterized** over (cloneRoot, home,
    expected):
    - `("/Users/n/code", "/Users/n", "~/code")`
    - `("/Users/n/src/repos", "/Users/n", "~/src/repos")`
    - `("", "/Users/n", "~/code")`
    - `("/Volumes/W/alas", "/Users/n", "~/code")`
    - `("/Users/n", "/Users/n", "~/code")`
  - **`seedingAddsProjectHostsInOrder`:** `seeded([], projectHosts: ["mini", "devbox", "mini"], defaultProjectsFolder: "~/code")`
    returns two machines, `mini` then `devbox`. Both have label equal to
    destination and folder `~/code`.
  - **`seedingKeepsExistingMachines`:** an existing
    `Machine(destination: "mini", label: "Mac mini", projectsFolder: "~/src")`
    plus hosts `["mini", "devbox"]` returns the unchanged `mini` entry first,
    then `devbox`.
  - **`seedingSkipsUnroutableHosts`:** hosts
    `[RemotePath.unavailableHost, "-oProxy", ""]` return `[]`. The rule is
    `RemotePath.isValidHost` and `!= RemotePath.unavailableHost`.
  - **`machinesSurviveConfigRoundTrip`:** encode an `AppConfig.defaults`
    with one machine, decode it, and compare. Decoding `{}` gives
    `machines == []`. Put this in the existing `AppConfigDecodingTests`, not
    in `MachineTests`.

- [ ] **Step 2: Run the tests and see them fail**
  Run: `swift test --package-path Packages/AlasCore --filter "MachineTests|AppConfigDecodingTests"`
  Expected: a compile failure, because `Machine` is undefined.

- [ ] **Step 3: Implement `Machine` and `AppConfig.machines`**
  - The home check in `defaultProjectsFolder` compares path components:
    `cloneRoot` must be strictly inside `localHome`. Anything else gives
    `"~/code"`.
  - Add `machines` to the memberwise `init` as a trailing defaulted
    parameter, so existing call sites compile unchanged.

- [ ] **Step 4: Run the tests and see them pass**
  Run: the same command as step 2.
  Expected: PASS.

- [ ] **Step 5: Commit** with the message
  `feat(remote): add the SSH machine list to the app config`.

### Task 2: Machine connection check

**Files:**
- Create: `Packages/AlasCore/Sources/AlasPlatform/SSH/MachineCheck.swift`
- Test: `Packages/AlasCore/Tests/AlasCoreTests/MachineCheckTests.swift`

**Interfaces:**
- Consumes: `SSHCommand(host:mode: .batch)`, `SSHCommand.shellQuote`,
  `SSHCommand.remoteScript(command:)`, `SSHCommand.executable`, and the
  `RemoteRepoValidator.Runner` typealias. The check follows the pattern of
  `RemoteRepoValidator.validate`.
- Produces:
  - `public enum MachineCheckResult: Equatable, Sendable { case ok, connectionFailed(String), folderUnusable(String) }`
  - `public enum MachineCheck`, containing:
    - `public static func folderCommand(_ projectsFolder: String) -> String`
    - `public static func run(host: String, projectsFolder: String, runner: @escaping RemoteRepoValidator.Runner = <Process.run default>) async -> MachineCheckResult`

- [ ] **Step 1: Write the failing tests**
  - **`tildeFolderExpandsOnTheMachine`, parameterized:**
    - `"~"` gives `mkdir -p "$HOME" && test -w "$HOME" && echo true`.
    - `"~/code"` gives `mkdir -p "$HOME"/'code' && test -w "$HOME"/'code' && echo true`.
    - `"~/My Code"` gives the same command with `'My Code'`.
    - `"/srv/o'brien"` gives the absolute path quoted by
      `SSHCommand.shellQuote`.
    - Assert the exact strings. The `~/` prefix becomes `"$HOME"/` followed
      by `shellQuote(rest)`.
  - **`runClassifiesExitCodes`, parameterized** over a fake runner returning
    (exitCode, stdout, stderr):
    - `(0, "true\n", "")` gives `.ok`.
    - `(255, "", "Host key verification failed.")` gives
      `.connectionFailed("Host key verification failed.")`.
    - `(1, "", "mkdir: Permission denied")` gives
      `.folderUnusable("mkdir: Permission denied")`.
    - A runner that throws gives `.connectionFailed(error.localizedDescription)`.

- [ ] **Step 2: Run the tests and see them fail**
  Run: `swift test --package-path Packages/AlasCore --filter MachineCheckTests`
  Expected: a compile failure.

- [ ] **Step 3: Implement `MachineCheck`**
  - Use a 30 s timeout, as `validate` does.
  - When stderr is empty, the folder message is
    `"Can't create or write to \(projectsFolder) on \(host)."`.

- [ ] **Step 4: Run the tests and see them pass.** Use the same command as
  step 2.

- [ ] **Step 5: Commit** with the message
  `feat(remote): check a machine's SSH connection and projects folder`.

### Task 3: Extract the SSH connection assistant from `NewProjectDialog`

This is a pure move with no behavior change. The assistant and the flow that
drives it (`startSSHSetup`, `handleSSHSetupExit`, `dismissSSHSetup`) leave
the dialog so the Machines pane can reuse them.

**Files:**
- Create: `Alas/Sources/Dialogs/SSHConnectionAssistant.swift`
- Modify: `Alas/Sources/Dialogs/NewProjectDialog.swift`
  - Remove `SSHConnectionIssue` (lines 37–63), `SSHSetupStatus` (71–76), the
    `SSHConnectionAssistant` view (1905–1993), and the setup state/functions
    (162–166, 1817–1870).
  - Use the new type instead.
- Modify: `project.yml` is unchanged, because `Alas/Sources` is globbed. Run
  `xcodegen` and commit `Alas.xcodeproj`.

**Interfaces:**
- Produces, all in `SSHConnectionAssistant.swift` with internal access:
  - `struct SSHConnectionIssue` and `enum SSHSetupStatus`, moved unchanged.
  - `struct SSHConnectionAssistant: View`, moved unchanged.
  - `@MainActor @Observable final class SSHConnectionSetup`, with:
    - `var isPresented: Bool`
    - `private(set) var status: SSHSetupStatus`
    - `private(set) var surface: AlasGhostty.SurfaceView?`
    - `func start(host: String, state: AppState, theme: Theme, onConnected: @escaping @MainActor () async -> Void) -> String?`.
      It returns an error message when the terminal cannot open, matching
      today's "Could not open the SSH connection terminal: …".
    - `func markIncompatible(_ message: String)`
    - `func fail(_ message: String)`
    - `func dismiss()`
  - The attempt-id guard and the `waitForActiveControlMaster` wait move into
    `start` unchanged. `onConnected` runs where `addProject(afterInteractiveSetup: true)`
    runs today.

- [ ] **Step 1: Move the code** and point `NewProjectDialog` at
  `@State private var sshSetup = SSHConnectionSetup()`. The sheet binds
  `$sshSetup.isPresented`, and `onRetry` calls `start` again with the same
  closure.
- [ ] **Step 2: Run `xcodegen`, then build**
  ```bash
  xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
    -skipPackagePluginValidation -skipMacroValidation -quiet build > /tmp/alas-build.log 2>&1; echo $?
  ```
  Expected: `0`, with no `error:` lines in the log.
- [ ] **Step 3: Run the existing dialog suite**
  Use `-only-testing AlasTests/RemoteRepoValidatorTests`. Expected: the ✔
  lines pass. Swift Testing's ◇/✔ lines are the real result; the "Executed
  0 tests" summary is not.
- [ ] **Step 4: Commit** with the message
  `refactor(remote): share the SSH connection assistant`, including
  `Alas.xcodeproj`.

### Task 4: Machines pane and seeding

**Files:**
- Create: `Alas/Sources/Settings/MachinesPane.swift`
- Modify: `Alas/Sources/Settings/SettingsNavView.swift`
  - Add `case machines` to `SettingsSection`.
  - Label `"Machines"`, icon `"server.rack"`.
- Modify: `Alas/Sources/Settings/SettingsWindow.swift:36`, adding
  `case .machines: MachinesPane(state: state)`.
- Modify: `Alas/Sources/App/AppState.swift`
  - Seed at load, right after `RemotePathMigration.complete` (around line
    1813) and before `self.config = config`.
  - Seed again at the end of `addProject(path:…host:…)` (line 5542) when
    `host != nil`, then call `saveConfig()`.
- Run `xcodegen` and commit `Alas.xcodeproj`.

**Interfaces:**
- Consumes:
  - `Machine`, `Machine.seeded`, and `Machine.defaultProjectsFolder` from
    Task 1. Seed with `projectHosts: projects.compactMap(\.host)` and
    `defaultProjectsFolder: Machine.defaultProjectsFolder(cloneRoot: config.repositoryCloneRootPath)`.
  - `MachineCheck.run` from Task 2.
  - `SSHConnectionSetup` from Task 3.
  - `SSHHostPicker`, `SSHConfigParser.parse(home:)`, and
    `RemoteHostStatusStore.shared.reachability(for:)`.
- Produces: `MachinesPane(state: AppState)`, plus the `.machines` settings
  section, which PR 3's "Add machine…" opens.

- [ ] **Step 1: Seeding in `AppState`.** Only write the config when
  `seeded(...) != config.machines`, so launches with nothing to seed write
  nothing.
- [ ] **Step 2: The list.** Use one `SettingsGroup`, with one row per machine
  showing:
  - The label (primary text).
  - `destination · projectsFolder` (detail text).
  - A reachability dot: green for `.online`, `fg-faint` for `.unknown`, and
    red for `.offline`.
  - `"\(n) projects"`, where n is the number of `projects` with
    `host == destination`.
  Each row has **Edit…** and **Remove** buttons.
  - Remove deletes the machine from `config.machines` only, with no
    confirmation, because nothing on disk or on the machine changes.
- [ ] **Step 3: The empty state.** The text is "No machines yet." It is
  followed by one row per `SSHConfigParser.parse(home:)` alias not already in
  the list, each with an **Add** button that pre-fills the add sheet.
- [ ] **Step 4: The Add/Edit sheet.** It uses `DialogContainer` and has
  these fields:
  - **Destination:** an `SSHHostPicker`, which is read-only text when
    editing.
  - **Label:** placeholder = destination.
  - **Projects folder:** default `Machine.defaultProjectsFolder(…)`.
  Then:
  - Buttons: **Test**, **Cancel**, **Save**.
  - Save is enabled when `RemotePath.isValidHost(destination)` holds, the
    destination is not already in the list (when adding), and the folder is
    non-empty. Save does not require a passing Test.
  - Test calls `MachineCheck.run` and shows the result inline:
    - `.ok` shows "Connected. Projects folder is ready."
    - `.folderUnusable(m)` shows `m`.
    - `.connectionFailed` calls `sshSetup.start(host:…)`. Its `onConnected`
      re-runs `MachineCheck.run`, and if that still fails, it calls
      `sshSetup.markIncompatible(SSHConnectionIssue(kind: .nonInteractiveUnavailable, detail: m).message)`.
- [ ] **Step 5: The footer.** Add an "Open ~/.ssh/config" link that calls
  `NSWorkspace.shared.open` on `~/.ssh/config`, plus this caption: "User,
  port, identity, and jump host come from your SSH config."
- [ ] **Step 6: Build and check by hand.**
  - Build as in Task 3, step 2.
  - Launch Alas Dev with its own `ALAS_APP_SUPPORT_DIR` while the release
    app runs.
  - Open Settings → Machines and add an alias.
  - Run Test against a reachable host, then against a host with an unknown
    key. The second must open the assistant.
  - Edit the label and confirm it survives a relaunch.
- [ ] **Step 7: Lint and run the package tests**
  ```bash
  swiftformat --lint Alas/Sources/Settings/MachinesPane.swift Alas/Sources/Dialogs/SSHConnectionAssistant.swift Packages/AlasCore/Sources/AlasModel/Persistence/Machine.swift Packages/AlasCore/Sources/AlasPlatform/SSH/MachineCheck.swift
  swift test --package-path Packages/AlasCore --filter "MachineTests|MachineCheckTests|AppConfigDecodingTests"
  ```
  Expected: no lint findings, and all tests pass.
- [ ] **Step 8: Commit** with the message
  `feat(remote): manage SSH machines in Settings`, including
  `Alas.xcodeproj`. Then open PR 1.

---

## PR 2a: `feat(remote): link SSH projects to their local project` (core only)

PR 2 from the spec is split in two. 2a adds the core model and APIs, with
tests and no app wiring, so nothing visible changes. 2b wires them into the
app. Start 2a from `main` after #2503 merges.

### Task 5: `linkedProjectId` and `ProjectLink.match`

**Files:**
- Modify: `Packages/AlasCore/Sources/AlasModel/Persistence/ProjectConfig.swift`.
  Add the property next to `host`, a `CodingKeys` case, and a tolerant decode.
  Encoding omits the key when it is nil; check whether `encode` is
  synthesized and, if so, rely on `encodeIfPresent` semantics.
- Create: `Packages/AlasCore/Sources/AlasModel/Model/ProjectLink.swift`
- Test: `Packages/AlasCore/Tests/AlasCoreTests/ProjectLinkTests.swift`

**Interfaces:**
- Produces:
  - `ProjectConfig.linkedProjectId: String?`
  - `public enum ProjectLink`, containing:
    - `public static func match(remoteOrigin: String, locals: [(id: String, origin: String?)]) -> String?`.
      It normalizes both sides with `GitRemoteIdentity.normalized` and
      returns the single matching id, or nil when nothing matches, more than
      one matches, or the remote origin doesn't normalize.

- [ ] **Step 1: Write the failing tests.**
  - `matchFindsTheOneLocalClone`, parameterized. Each row is (remote, locals,
    expected):
    - `"git@github.com:o/r.git"` against
      `[("a","https://github.com/o/r"), ("b","https://github.com/o/x")]`
      gives `"a"`.
    - The same remote against two locals that both match gives `nil`.
    - `"/srv/r.git"` (no host) gives `nil`.
    - A local with a `nil` origin is skipped.
  - `linkedProjectIdRoundTripsAndIsOmittedWhenNil`: encode a project
    without a link and check the JSON has no `linkedProjectId` key. Encode
    one with a link and check it decodes back equal.
- [ ] **Step 2: Run them and see them fail.**
  Run: `swift test --package-path Packages/AlasCore --filter ProjectLinkTests`.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run them and see them pass.**
- [ ] **Step 5: Commit** with the message
  `feat(remote): record which local project an SSH project belongs to`.

### Task 6: `ProjectsManager` linking APIs

**Files:**
- Modify: `Packages/AlasCore/Sources/AlasIntegrations/Projects/ProjectsManager.swift`
- Test: extend the existing `ProjectsManager` suite (find it with
  `grep -l "ProjectsManager(" Packages/AlasCore/Tests`). Create a new file
  only if there is none.

**Interfaces:**
- Consumes: `ProjectConfig.linkedProjectId` (Task 5).
- Produces:
  - `public var primaryProjects: [ProjectConfig]`, the projects whose
    `linkedProjectId` is nil.
  - `public func linkedProjects(of primaryId: String) -> [ProjectConfig]`
  - `public func settingsProject(for projectId: String) -> ProjectConfig?`,
    which returns the primary for a linked record and the project itself
    otherwise.
  - `public func link(_ projectId: String, to primaryId: String)`. It
    refuses, as a no-op, when:
    - the record has no host, or is a folder project;
    - the primary has a host, or is itself linked;
    - another record with the same host is already linked to that primary.
  - `public func unlinkAll(from primaryId: String)`. `removeProject(id:)`
    calls it for the removed id before removing.
  - `public func visibleWorktrees(includingLinkedTo primaryId: String) -> [Worktree]`.
    It sorts the primary's and its linked records' visible rows with
    `sortedWorktrees(_:project: primary)`. Only the primary's own main
    worktree is pinned: change `isMainWorktree` so a row whose `projectId`
    differs from `project.id` is never treated as main.
  - `reorderWorktree(projectId: primaryId, movingId:destinationId:)` works
    on the merged rows when the primary has linked records, writing the
    primary's `worktreeOrder`.

- [ ] **Step 1: Write the failing tests:**
  - `settingsComeFromThePrimary`: a linked record's `settingsProject` is the
    primary.
  - `linkRefusesInvalidPairs`, parameterized over the refusal rows above.
  - `removingThePrimaryUnlinksItsRecords`
  - `mergedWorktreesFollowThePrimarysManualOrder`: a manual order
    interleaving a local and a remote id is honored. The remote record's own
    main row is not pinned.
- [ ] **Step 2: Run them and see them fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run them and see them pass.**
- [ ] **Step 5: Run the full package suite.**
  Run: `swift test --package-path Packages/AlasCore`
  Expected: every test passes.
- [ ] **Step 6: Commit and open PR 2a.**

## PR 2b: `feat(remote): fold SSH projects under their local project` (app wiring)

This section gets detailed after 2a merges. Its tasks:

1. **Auto-link.**
   - `RemoteHostStatusStore.onStatusTransition` (`AppState.swift:1975`):
     on each online edge, for each unlinked SSH git project on that host,
     read `git remote get-url origin` with one `RemoteExec` call. Pass it to
     `ProjectLink.match` against local projects' origins, which are read
     locally.
   - On a match: `link`, remove the record from all spaces, save the
     projects and spaces.
   - Skip linked records in the load-time space auto-add
     (`AppState.swift:1880`).
2. **Settings reads.** Switch the read sites listed in the spec's "Settings
   inheritance" section to `settingsProject(for:)`.
3. **Sidebar.**
   - `SidebarView.projectRow` and `filteredWorktreeIds` use
     `visibleWorktrees(includingLinkedTo:)`.
   - Add a badge decision function on `WorktreeRowPresentation`, with one
     parameterized test.
   - Add "Reconnect to <label>" and "Remove <host> checkout from Alas" menu
     items.
4. **Lists.**
   - Switch to `primaryProjects` at the sites listed in the spec's "Hidden
     linked records" section.
   - The CLI router (`AlasCLICommandRouter.swift:280`) filters by the same
     primary.
   - `ProjectSnapshot.linkedProjectId`: check whether new fields need a
     `host.projects.*.v1` capability, as `ggMode` does.
5. **`CONTEXT.md` terms.**

## PR 3: `feat(remote): choose where a new worktree runs` (outline)

- **Picker logic.** Add a pure `RunOnOptions.make(primary:linked:machines:reachability:)`
  in core, with tests on order, the no-origin case, and preselection by
  `lastRunOnHost` including a removed machine. Add
  `ProjectConfig.lastRunOnHost`.
- **Dialog.** Add a Run on picker in `NewWorktreeDialog`, in a new file. It
  holds a separate `targetProjectId`, and `create()` passes it to
  `state.createWorktree`. In this PR, rows that need setup are listed but
  disabled.
- **Pushed-base check.** Add a pure `BasePushState` decision. Add one
  real-git integration test that uses a template repository with a bare
  origin, covering pushed, ahead, and never pushed. Add the "Push <b> and
  continue" button, reusing the push in `CommitPublishOperations`.
- **`WorktreeCreateRequest.createsFromFetchedOrigin`.** `finishCreate`
  always fetches, then creates from `origin/<b>`.

## PR 4: `feat(remote): set up a machine on first use` (outline)

- **`RemoteCheckoutSetup.ensure(primary:machine:)`** in core, with pure parts
  that are tested:
  - `matchingClone(listing: String, identity: String, repoName: String) -> String?`
  - `freeCloneName(repoName: String, taken: Set<String>) -> String`
- **Remote clone** with `--progress` streaming and cancel.
- **Record creation:** link the new record and hide the main path.
- **Dialog:** enable the rows that need setup, show the progress line, and
  add Choose folder… with an origin-identity check.

## PR 5: iOS and Mac remote-client folding (outline)

Fold by `ProjectSnapshot.linkedProjectId` in the iOS app and in the Mac's
peer views of a host's projects. Merge this into PR 2b if it is small.
