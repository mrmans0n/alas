// Pure logic for the Changes tab: ordering, labels, and the diff row model.
// DOM wiring lives in app.js; everything here is unit-tested under
// scripts/tests/remote-web-changes.

function sortFiles(files) {
  return (files || []).slice().sort((a, b) => (a.path < b.path ? -1 : a.path > b.path ? 1 : 0));
}

function splitPath(path) {
  const value = path || "";
  const index = value.lastIndexOf("/");
  if (index < 0) return { dir: "", name: value };
  return { dir: value.slice(0, index + 1), name: value.slice(index + 1) };
}

function fileRows(files) {
  const rows = [];
  let previousDirectory = null;
  const sortedByDirectory = (files || []).slice().sort((a, b) => {
    const aParts = splitPath(a.path);
    const bParts = splitPath(b.path);
    if (aParts.dir < bParts.dir) return -1;
    if (aParts.dir > bParts.dir) return 1;
    return aParts.name < bParts.name ? -1 : aParts.name > bParts.name ? 1 : 0;
  });
  for (const file of sortedByDirectory) {
    const parts = splitPath(file.path);
    if (parts.dir && parts.dir !== previousDirectory) {
      rows.push({ type: "directory", dir: parts.dir.slice(0, -1) });
    }
    rows.push({ type: "file", file, path: file.path, dir: parts.dir, name: parts.name });
    previousDirectory = parts.dir;
  }
  return rows;
}

function formatFileCounts(file) {
  const add = file && file.add ? file.add : 0;
  const del = file && file.del ? file.del : 0;
  return "+" + add + " −" + del;
}

function changeSections(state) {
  const sections = [];
  const files = sortFiles(state && state.files);
  const staged = sortFiles(state && state.staged);
  const unstaged = sortFiles(state && state.unstaged);
  const commits = (state && state.commits) || [];
  if (files.length && (commits.length || (!staged.length && !unstaged.length))) sections.push({ title: "Branch changes", files });
  if (staged.length || unstaged.length) sections.push({ title: "Working tree" });
  if (staged.length) sections.push({ title: "Staged", files: staged, stage: "staged" });
  if (unstaged.length) sections.push({ title: "Unstaged", files: unstaged, stage: "unstaged" });
  if (commits.length) sections.push({ title: "Commits", commits });
  return sections;
}

function changedFiles(state) {
  const staged = (state && state.staged) || [];
  const unstaged = (state && state.unstaged) || [];
  const allFiles = (state && state.files) || [];
  return allFiles.length
    ? allFiles
    : Array.from(new Map(staged.concat(unstaged).map((file) => [file.path, file])).values());
}

function changedFileCount(state) {
  return changedFiles(state).length;
}

function formatSummary(state) {
  const files = changedFiles(state);
  let add = 0;
  let del = 0;
  for (const file of files) {
    add += file.add || 0;
    del += file.del || 0;
  }
  const count = files.length + (files.length === 1 ? " file" : " files");
  const totals = count + " · +" + add + " −" + del;
  const ref = state && state.comparisonRef;
  const commitCount = ((state && state.commits) || []).length;
  const commits = commitCount ? " · " + commitCount + (state && state.commitsTruncated ? "+" : "") + (commitCount === 1 ? " commit" : " commits") : "";
  return (ref ? "vs " + ref + " · " : "") + totals + commits;
}

function diffRows(hunks) {
  const rows = [];
  for (const hunk of hunks || []) {
    rows.push({ type: "hunk", text: hunk.header, kind: null, oldNumber: null, newNumber: null, noTrailingNewline: false });
    for (const line of hunk.lines || []) {
      rows.push({
        type: "line",
        text: line.text,
        kind: line.kind,
        oldNumber: typeof line.oldNumber === "number" ? line.oldNumber : null,
        newNumber: typeof line.newNumber === "number" ? line.newNumber : null,
        noTrailingNewline: !!line.noTrailingNewline
      });
    }
  }
  return rows;
}

function truncationNotice(truncated, kind) {
  if (!truncated) return "";
  if (kind === "files") return "File list truncated — too many changed files to show.";
  if (kind === "lines") return "File truncated — too many lines to show.";
  if (kind === "directory") return "Directory truncated — too many entries to show.";
  return "Diff truncated — open this file on the desktop to see the rest.";
}

// A pure rename/copy or executable-bit-only change has no `@@` hunks to
// render — an empty diff would look indistinguishable from "nothing
// changed", so the server sends `metadataNote` describing what actually
// happened (see `ParsedDiff.metadataSummary`). Only surfaced when there
// really are no hunks: a rename/mode change alongside real content edits
// already has hunks to show, and the note would just be noise there.
function metadataOnlyNotice(hunks, metadataNote) {
  if ((hunks || []).length > 0) return "";
  return metadataNote || "";
}

// One exact patch's hunks as the host flattens them into a tool call's
// `content` (ACPToolCallDiff.flattenedText): from the first `@@` line, without
// the final newline, or "Change unavailable: <path>".
function toolDiffHunks(diff) {
  const unavailable = "Change unavailable: " + diff.path;
  const text = diff.patch;
  if (typeof text !== "string" || !text) return unavailable;
  let start = 0;
  while (start < text.length && !text.startsWith("@@", start)) {
    const newline = text.indexOf("\n", start);
    if (newline < 0) return unavailable;
    start = newline + 1;
  }
  if (start >= text.length) return unavailable;
  return text.slice(start, text.endsWith("\n") ? text.length - 1 : text.length);
}

// A tool call's text for the transcript. When its `content` is exactly its
// patches' hunks run together, each file's hunks get a `--- <path>` line, so
// a multi-file edit reads per file. Content with anything else in it (a
// standard diff, text, a fallback block) is shown as sent.
function toolDiffText(content, diffs) {
  if (typeof content !== "string" || !Array.isArray(diffs) || !diffs.length) return content;
  const hunks = diffs.map(toolDiffHunks);
  if (content !== hunks.join("\n")) return content;
  return diffs.map((diff, index) => "--- " + diff.path + "\n" + hunks[index]).join("\n\n");
}

// The host's hunks as a unified patch, for @pierre/diffs. Each header's counts come from its
// lines rather than the host's header, so a hunk cut short by truncation still parses.
function unifiedPatch(path, hunks) {
  const out = ["--- " + path, "+++ " + path];
  for (const hunk of hunks || []) {
    const lines = hunk.lines || [];
    const oldCount = lines.filter(line => line.kind !== "add").length;
    const newCount = lines.filter(line => line.kind !== "delete").length;
    const section = String(hunk.header || "").replace(/^@@[^@]*@@/, "");
    out.push("@@ -" + hunk.oldStart + "," + oldCount + " +" + hunk.newStart + "," + newCount + " @@" + section);
    for (const line of lines) {
      out.push((line.kind === "add" ? "+" : line.kind === "delete" ? "-" : " ") + line.text);
      if (line.noTrailingNewline) out.push("\\ No newline at end of file");
    }
  }
  return out.join("\n") + "\n";
}

// --- Draft review comments (host.reviews.*) -----------------------------------
// The web files diff comments where the phone does: the worktree's local-changes review, under the
// diff's stage, or "branch" for the branch diff.

// ReviewDraftSessionID.localChanges(worktreeID:worktreePath:scope: .all), as RemoteReviewRequest builds it.
// ponytail: trims trailing slashes but doesn't resolve "." or ".."; host paths come already standardized.
function localChangesReviewID(worktreeId, worktreePath) {
  const path = String(worktreePath).replace(/\/+$/, "") || "/";
  return ["local-changes", String(worktreeId), path, "all"]
    .map(field => field.replace(/\\/g, "\\\\").replace(/\u001f/g, "\\u001f"))
    .join("\u001f");
}

function reviewNamespace(stage) {
  return stage || "branch";
}

// The comment anchor for a gutter selection ({ start, side, end, endSide }, sides "additions" or
// "deletions"): one side, as the Mac anchors lines, with the quoted lines a comment follows when its
// code moves. A range over both added and removed lines anchors to the new side.
function commentAnchor(hunks, range) {
  if (!range) return null;
  const rows = diffRows(hunks).filter(row => row.type === "line");
  const index = (side, line) => rows.findIndex(row => (side === "deletions" ? row.oldNumber : row.newNumber) === line);
  let from = index(range.side, range.start);
  let to = index(range.endSide || range.side, range.end);
  if (from < 0 || to < 0) return null;
  if (from > to) [from, to] = [to, from];
  const slice = rows.slice(from, to + 1);
  const oldOnly = range.side === "deletions" && (range.endSide || range.side) === "deletions";
  const useNew = !oldOnly && slice.some(row => row.newNumber !== null);
  const picked = slice.filter(row => (useNew ? row.newNumber : row.oldNumber) !== null);
  const numbers = picked.map(row => (useNew ? row.newNumber : row.oldNumber));
  return {
    side: useNew ? "new" : "old",
    startLine: Math.min(...numbers),
    endLine: Math.max(...numbers),
    selectedText: picked.map(row => row.text).join("\n")
  };
}

function openComments(comments) {
  return (comments || []).filter(comment => comment && comment.state === "active");
}

function fileComments(comments, namespace, path) {
  return openComments(comments).filter(comment => comment.fileID && comment.fileID.namespace === namespace && comment.fileID.path === path);
}

// A file's open comments as diff annotations: under a comment's last line when the diff shows it,
// else above the first hunk (line 0), as the phone drops a comment whose lines are gone.
// ponytail: placed by saved line numbers, without the phone's relocation by quoted lines
// (ReviewQuotedLines.locate); port it if comments whose code moved land on the wrong lines.
function commentAnnotations(hunks, comments, namespace, path) {
  const rows = diffRows(hunks).filter(row => row.type === "line");
  const shown = { new: new Set(rows.map(row => row.newNumber)), old: new Set(rows.map(row => row.oldNumber)) };
  return fileComments(comments, namespace, path).map(comment => {
    const line = comment.anchor && comment.anchor.line;
    const side = line && line.side === "old" ? "old" : "new";
    const end = line ? line.endLine || line.startLine : 0;
    return { side: side === "old" ? "deletions" : "additions", lineNumber: line && shown[side].has(end) ? end : 0, metadata: { comment } };
  });
}

// "You" for the user, else the agent's name, as the Mac names comment authors.
function commentAuthor(comment) {
  const agent = comment && comment.author && comment.author.agent;
  return agent ? agent.name || "Agent" : "You";
}

function commentLines(comment) {
  const line = comment && comment.anchor && comment.anchor.line;
  if (!line) return "File";
  const end = line.endLine || line.startLine;
  return end > line.startLine ? "Lines " + line.startLine + "–" + end : "Line " + line.startLine;
}

globalThis.RemoteChangesView = {
  sortFiles,
  splitPath,
  fileRows,
  changeSections,
  changedFileCount,
  formatSummary,
  formatFileCounts,
  diffRows,
  truncationNotice,
  metadataOnlyNotice,
  toolDiffText,
  unifiedPatch,
  localChangesReviewID,
  reviewNamespace,
  commentAnchor,
  openComments,
  fileComments,
  commentAnnotations,
  commentAuthor,
  commentLines
};
