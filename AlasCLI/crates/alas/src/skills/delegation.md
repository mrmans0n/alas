# Alas delegation

Alas can start child agent sessions that work in parallel and report back to
this session.

- `alas agent list [--worktree <name-or-branch>] [--peer <mac>]` lists the
  agents you can delegate to, with their models. Only agents with
  `available: true` can start.
- `alas session new --prompt <text> [--agent <id>] [--model <id>] [--reasoning <level>] [--role <name>] [--worktree <name-or-branch> | --new-worktree <branch> [--base <ref>]] [--peer <mac> [--project <id-or-name>]]`
  starts a child. The prompt must stand on its own: the child sees nothing of
  this conversation. Give each child its own worktree when children edit
  files in parallel.
- `alas session list` shows this session with its parent or children.
- `alas session send <session-id> <prompt>` queues a message for a direct
  parent or child.
- `alas session read <session-id> [--offset <n>] [--limit <n>] [--max-chars <n>]`
  pages through a parent's, child's or fork's transcript;
  `alas session search <query>` searches them.
- `alas session wait <session-id>... [--timeout-ms <n>]` blocks until the
  children settle or the timeout passes (at most 20 seconds per call; call
  again while `timed_out` is true).
- `alas session interrupt <session-id>` stops a child's running turn.
- `alas session report [--failed] <result>` (delegated sessions only) sends
  the parent your final result.

Delegate with `alas session new`, not your native subagent tool, when the
user names another agent or model ("have Codex review this"), or wants the
work in another worktree, on another Mac, or in a session they can watch and
talk to. If `alas agent list` does not offer that agent or model, say so
instead of substituting another.

A child's final result arrives here as a message from its
`alas session report`; a message it sends with `alas session send` is a
question or progress update. When a child finishes without
reporting, fails, or is blocked on a permission or question, this session is
told; there is no need to poll. After starting children, end your turn unless
you have other work; use `alas session wait` only when your very next step
needs a child's result. Only the user can answer a blocked child: reach them
with `alas notify`.

A delegated session cannot start children of its own. When it finishes, it
reports its result once with `alas session report <result>` (`--failed` if it
could not do the task): what it changed, the evidence that it works, and open
problems. It sends questions or progress with
`alas session send "$ALAS_PARENT_SESSION_ID" <prompt>`. A
child started from another Mac cannot message its parent at all: its final
message is its report.
