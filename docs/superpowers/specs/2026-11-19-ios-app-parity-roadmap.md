# iOS app parity roadmap (beyond the transcript)

Status: audit, 2026-11-19. Follows the transcript parity roadmap
(`2026-11-16-ios-transcript-activity-and-images-design.md`), now complete.

The phone is compared with the Mac's own native client for a remote host
(`Alas/Sources/Remote/Native`, `Alas/Sources/Right/NativePeer*`), which is the
closest analogue, and with the local Mac app where the protocol already allows it.
Non-goals stay as in `2026-11-11-native-ios-app-design.md`: iPad layout, Bonjour,
on-device AI, port forwarding, Android.

## Already at parity (do not re-audit)

New session / new worktree (machine, repo, base branch, branch naming, agent,
model, effort, repo-hook consent); session rename and settings; take over;
grouping by machine or project; federated sessions; pairing, re-pair, forget;
Inbox answer-in-place and background Allow/Deny; slash and @ mention pickers;
send, steer, stop; rejected-send recovery; full prompt queue; usage sheet;
permission / question / plan / elicitation cards; visual aids; console with
lease and resize; changes list, stage/unstage/discard per file and in bulk,
commit, push, pull, fetch; shepherd menu; plain unified diff; file tree.

## Slices (ship in order)

1. **Session screen quick wins** (no protocol change)
   - Persistent agent-issue banner (needsSetup / needsAuth / failed) above the
     composer, with Install for `needsSetup` (`installAdapter`, gated on
     `PeerAdapterInstallCapability.v1`). Mac: `NativePeerSessionView` ~546.
   - Usage ring also for quota-only usage (no context window). Mac:
     `ACPContextUsageButton`.
   - Pending request cards stay visible on the Changes / Files / Terminal tabs.
   - Paste images from the clipboard into the composer.
2. **Commit drill-down**: tap a commit for its files, tap a file for its diff
   (`listCommitFiles`, `commitFileDiff`; host already serves them).
3. **Diff reading**: syntax colour in the phone diff, reusing the transcript
   highlighter (shipped with slice 2). The Mac diff has no word-level
   highlights, so neither does the phone. Image diffs via `fileBytes` remain.
4. **Session and worktree lifecycle**: close / reopen sessions
   (`closeSessionTab`, `openSessionTab`), archive session, archive / delete /
   rename-branch worktrees over the host channel (`worktreesLifecycleV1`),
   with the destructive confirmation the Mac uses. Worktree actions sit in the
   session's title menu, where the phone already talks to the host channel;
   `RemoteWorktreeSummary.lineageID` lets the host refuse a replaced checkout.
5. **Hunk actions**: stage / unstage / discard a single hunk.
6. **PR and run**: PR status and checks with open-in-browser (`reviewStatus`);
   run scripts list with run / stop / rerun and output (`listRunScripts`,
   `startRun`, `stopRun`, `restartRun`, `runOutput`).
7. **Smaller list items**: sort choice, connection banner with manual
   reconnect, "delegated from" back link, mention picker scope tabs and empty
   state, `/ship` slash entry, auto-run chip, copy path / branch.

## Parked (need host or protocol work, or low phone value)

- Inbox beyond sessions (run failures, git ops, reviews, host updates) and new
  push kinds with actions for questions/plans: needs an attention feed protocol.
- Review comments (L), comparison-mode / base-branch picker, per-file history,
  file search and markdown/image preview in Files, file editing.
- Amend, force-with-lease, stash, cherry-pick, revert, merge, rebase, conflict
  resolution, checkpoints: deliberate phone safety choice for now.
- Commit message generation (needs a model call on the phone or a host request).
- Dictation button (iOS keyboard mic covers it), camera attach.
- Mac-local features with no wire support: goal pill, MCP status, recap, side
  questions, symbol mentions.
