# Drag Paths and Commit SHAs Into Agents and Terminals

## Summary

Extend Alas's existing AppKit drag system so files from the Files and Changes tabs, plus copyable commit SHA labels, can insert text into agent composers and terminal panes. Keep existing external file dragging intact while allowing remote and deleted paths to work as internal text-only drags.

## Interaction

- Files-tab files and directories, Working Tree rows, and conflict rows provide a typed path drag containing repo-relative and worktree-absolute forms.
- Copyable SHA labels in commit rows, commit-detail headers, and parent lists provide the full commit SHA.
- Dropping anywhere in an agent chat focuses its composer and inserts a repo-relative path or full SHA at the retained selection.
- Dropping on a terminal pane focuses that pane and inserts a POSIX-shell-escaped absolute path or full SHA.
- Drops insert text only. They do not insert surrounding whitespace, send Enter, submit a prompt, run a command, or create an attachment.

## Architecture

Use a private codable Alas pasteboard payload with file-path and commit-SHA cases. Existing local file drags retain public file URL and absolute-text pasteboard representations. Full SHAs expose a public text representation. Remote and deleted paths expose only the private internal representation, so they cannot be dragged into external applications.

Agent handling is split between a whole-chat drop destination and a small router to the live AppKit composer. Terminal handling lives on each Ghostty surface so split-pane routing follows the hovered pane. Both targets decode only the private Alas payload; existing agent image-drop behavior remains unchanged.

Malformed payloads, mirrored or unavailable composers, and unavailable terminal input reject the drop without changing state. V1 uses the standard drag preview and copy cursor without a custom drop overlay.

## Verification

Cover payload encoding, public representations, operation masks, remote/deleted behavior, shell escaping, ACP selection and draft updates, mirrored-composer rejection, terminal pane routing, full-SHA insertion, and absence of implicit newline/submission. Retain regression coverage for existing drag activation, external file dragging, and agent image drops.
