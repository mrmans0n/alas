# Alas reviews and pull requests

## Review pane

- `alas review [target] [--worktree <name-or-path>]` opens the review pane on
  local changes, or on a PR/MR number or URL, a commit, a range
  (`base..head`, or `base...head` for a merge-base diff), or a branch. It
  prints the review session id.
- `alas review comment <path> <line> <body> [--end-line <n>] [--side old|new] [--session <id>]`
  files a finding inline in the diff, attributed to you.
- `alas review comments [--state active|resolved|dismissed|all] [--session <id>]`
  lists the user's and agents' comments as JSON.
- `alas review reply <comment-id> <body>` replies to a thread;
  `alas review resolve <comment-id> [--reply <body>] [--reopen]` settles it
  after you address it.
- `alas review finish [--session <id>] [--verdict approve|request-changes|comment] [--summary <body>]`
  closes a review you ran. Requesting changes needs a summary.

To address the user's review: list active comments, fix each, then resolve
it with a one-line reply saying what changed.

## Pull requests

- `alas pr create --title <title> --body <body> [--draft] [--base <ref>]`
  pushes this worktree's exact HEAD (never force), opens its PR/MR or adopts
  the open one, and has Alas watch it: Alas sends this session a new turn
  when CI fails, a trusted reviewer leaves a thread, or the branch conflicts
  with its base. Offer it when you finish a change the user will want
  reviewed, and run it only after the user agrees or asks. Write the title
  and body from the actual diff.
- `alas pr status` prints the watched PR/MR as JSON: state, checks, failing
  checks, actionable threads, missing reviewers and the watcher's phase.
- `alas stack ship` is `alas pr create` for a gg stacked-diffs worktree: one
  PR/MR per entry, all watched. Run it from the top of the stack with the
  work committed into entries, with the same consent rule. It may answer
  `in_progress` and keep going; then `alas pr status` reports progress, and
  you must not run `gg sync` or ship again meanwhile.

If a publish times out, the push may still complete: run `alas pr status`
before retrying.
