# SSH Agent Environments

## Context

Alas currently folds agent configuration and local installation detection into
one `AgentRegistry`. Repository-facing selectors then read
`agentRegistry.enabled()` without considering where the repository runs. This
leaks the Mac's agent list into SSH repositories.

The same mismatch affects execution. Draft commit and review request generation
collect Git context through host-aware Git helpers, then call `AgentRunner`,
which always starts the selected CLI on the Mac. An SSH worktree path is not a
valid local working directory, and the remote host may have a different set of
agent CLIs. ACP sessions already launch through SSH, but transcript fork targets
still come from the local registry.

## Goals

- Make agent selectors reflect the execution host of their repository.
- Show enabled built-in agents installed on an SSH host without requiring the
  same binary to exist on the Mac.
- Show enabled custom agents from Alas settings when their configured
  executable is available on the SSH host.
- Use one host-scoped availability result for draft commit generation, draft
  review request generation, and ACP transcript forks.
- Run direct, non-interactive generation on the SSH host in the remote
  worktree.
- Preserve local repository behavior.

## Non-goals

- Do not discover arbitrary custom agent definitions from a remote host. Alas
  remains the source of command arguments, prompt behavior, names, and icons.
- Do not synchronize agent settings between machines.
- Do not install direct agent CLIs on a remote host.
- Do not change ACP adapter installation or ACP setup checks.
- Do not persist remote availability across app launches.
- Do not introduce per-repository agent preferences. The selected changes tool
  remains a global preference, validated against each repository's host.

## Agent catalog and preferences

Agent definitions and user preferences must be separable from local install
state. The configured catalog contains:

- built-ins in `AgentBuiltins` order, with `BuiltinAgentState` applied;
- custom definitions in their configured order;
- only definitions the user has enabled.

For a local target, the current local installation scan filters this catalog.
For an SSH target, a remote probe filters the configured catalog instead. A
built-in missing locally can therefore appear for an SSH repository. A custom
agent appears only when its effective executable, including any
`binaryOverride`, passes the remote probe.

An explicit disabled preference wins on every host. Local absence does not.
Default built-in enablement continues to come from `AgentBuiltins` when no
stored preference exists.

## Execution targets

A small value type identifies where agent work runs:

- local;
- SSH with a host string.

The target is resolved from the repository worktree path through
`RemoteHostRegistry`, matching host-aware Git behavior. Callers that already
have a pinned remote host may supply it directly. Target resolution belongs
outside SwiftUI views so selectors and runners cannot choose different hosts.

## Remote availability

A main-actor store owns remote availability by SSH host. Each entry has a
loading, available, or failed state. Available state contains the ordered agent
definitions that passed probing.

The store batches all candidate checks into one `RemoteExec` call per refresh.
The generated POSIX script assigns an opaque index to each candidate and emits
only successful indices. It never interpolates display names or ids into shell
syntax. Executables and path-shaped overrides use `SSHCommand.shellQuote`.

Probe rules match the actual remote launch rules:

- a bare executable uses `command -v` under the standard augmented remote
  `PATH`;
- a path-shaped executable expands a leading `~/` against remote `$HOME` and
  must be an executable non-directory file;
- relative paths containing `/` are checked relative to the remote worktree,
  because direct execution also starts there.

Availability is cached by host. Concurrent requests for the same host share
one task. The store invalidates affected entries when agent configuration
changes. A failed probe remains a visible failed state and offers retry; it
never substitutes the Mac's agents. Reconnecting or retrying starts a fresh
probe.

The cache intentionally keys by host rather than worktree. Relative custom
executables are the exception because their result depends on the worktree. If
the configured catalog contains one, the key includes the worktree path. This
keeps the common built-in case to one probe per host without returning a stale
answer for repository-local tools.

## Selection behavior

Repository agent surfaces receive a resolved availability state instead of
reading `agentRegistry.enabled()` directly.

The draft commit and review request selectors show only agents available for
the repository target. The global `changes.aiToolId` value is not rewritten
when the current repository cannot use it. Generation remains disabled until
the user selects an available agent. This avoids one SSH repository silently
changing the user's choice for local and other remote repositories.

While an SSH probe is loading, selectors show a loading state and generation is
disabled. A failed probe shows a concise connection error with Retry. A valid
empty result explains that no configured agents were found on the host.

ACP transcript fork targets use the source session's execution target. The
source agent remains eligible only if it is in the host-scoped available list;
the current policy's unconditional re-insertion of the source agent is removed
for resolved SSH availability. This prevents a persisted transcript from
offering a fork into an agent that has since been removed from the host.

Other agent surfaces are outside this change unless they operate on an
existing SSH repository and currently use the same local-only list. During
implementation, such consumers should move to the shared source when the
execution target is already known. New-worktree creation stays local until a
remote worktree and host exist.

## Remote direct execution

`AgentRunner` keeps prompt construction, output parsing, timeout handling,
cancellation, and exit-code mapping. It gains an execution target and builds
one of two process invocations:

- local: the existing `/usr/bin/env <binary> ...` process in the local working
  directory;
- SSH: `/usr/bin/ssh ... <host> <remote-script>`, where the script changes to
  the remote worktree and executes the quoted binary and arguments under the
  augmented remote `PATH`.

The local process still writes the existing invocation stdin to its child. For
SSH, that same stream becomes the remote CLI's stdin. stdout and stderr return
through SSH and use the existing concurrent drains. Cancelling or timing out
terminates the local SSH process, whose connection teardown terminates the
foreground remote command. Exit 255 maps to an SSH connection error. Exit 127
continues to map to `binaryNotFound`, now naming the remote host in its user
message. Other remote exit codes retain the CLI's stderr.

The runner accepts an already resolved target. It does not re-probe
availability before every launch. A binary removed between the probe and launch
fails normally and the availability store invalidates that host so the next UI
read refreshes it.

Draft commit generation already obtains Git data through host-aware helpers
except for direct `Process.git` calls, which use `RemoteHostRegistry` and remain
unchanged. Draft review request context is likewise already host-aware. Both
views pass the resolved execution target and remote worktree path to the
runner.

## Errors and recovery

Availability failures and generation failures remain distinct:

- probe connection failure: selector-level error with Retry;
- no matching CLI: empty selector state naming the host;
- selected global agent absent from this host: prompt to select an available
  agent, without modifying the saved preference;
- SSH disconnect during generation: inline generation error;
- CLI removed after probing: binary-not-found error followed by cache
  invalidation.

No failure falls back to local execution. Running an agent against the wrong
filesystem is worse than requiring a retry.

## Testing

- Catalog tests prove that remote candidates respect user enablement but do
  not depend on local installation, and that configured custom agents retain
  their overrides and ordering.
- Probe-script tests cover bare commands, absolute paths, `~/` paths, relative
  paths, shell metacharacters, and opaque result parsing.
- Availability-store tests cover host separation, relative-path worktree keys,
  concurrent request coalescing, configuration invalidation, failures, and
  retry.
- Selector policy tests cover local and SSH lists, a globally selected agent
  missing from one host, loading, empty, and failed states.
- Fork policy tests prove that SSH targets come only from remote availability
  and that an unavailable source agent is not reinserted.
- `AgentRunnerInvocationTests` cover the SSH executable, arguments, quoted
  remote working directory, prompt arguments, stdin behavior, and connection
  failure mapping while retaining the local cases.
- Focused view/model tests cover draft commit and review request routing into
  the resolved execution target.

Focused suites run during implementation. If the changed behavior lacks a
reliable focused suite at the final integration point, run the macOS app build
as required by `AGENTS.md`.

## Open questions

None. Remote-host discovery of unknown custom agents, remote installation, and
per-repository preferences are deferred deliberately.
