const assert = require("node:assert/strict");

require("../../../Alas/Resources/RemoteWeb/changes-view.js");

const view = globalThis.RemoteChangesView;

{
  const sorted = view.sortFiles([
    { path: "src/b.txt" },
    { path: "a.txt" },
    { path: "src/a.txt" }
  ]);
  assert.deepEqual(sorted.map((f) => f.path), ["a.txt", "src/a.txt", "src/b.txt"]);
}

{
  assert.deepEqual(view.splitPath("a.txt"), { dir: "", name: "a.txt" });
  assert.deepEqual(view.splitPath("src/app/main.swift"), { dir: "src/app/", name: "main.swift" });
}

{
  // Removing directory rows or leaving full paths on file rows would make
  // filenames hard to find again on a narrow Changes tab.
  const rows = view.fileRows([
    { path: "README.md" },
    { path: "Alas/Resources/RemoteWeb/app.js" },
    { path: "Alas/Resources/RemoteWeb/index.html" },
    { path: "Alas/Sources/ACP/Session/ACPSession.swift" }
  ]);
  assert.deepEqual(rows.map((row) => ({ type: row.type, path: row.path, dir: row.dir, name: row.name })), [
    { type: "file", path: "README.md", dir: "", name: "README.md" },
    { type: "directory", path: undefined, dir: "Alas/Resources/RemoteWeb", name: undefined },
    { type: "file", path: "Alas/Resources/RemoteWeb/app.js", dir: "Alas/Resources/RemoteWeb/", name: "app.js" },
    { type: "file", path: "Alas/Resources/RemoteWeb/index.html", dir: "Alas/Resources/RemoteWeb/", name: "index.html" },
    { type: "directory", path: undefined, dir: "Alas/Sources/ACP/Session", name: undefined },
    { type: "file", path: "Alas/Sources/ACP/Session/ACPSession.swift", dir: "Alas/Sources/ACP/Session/", name: "ACPSession.swift" }
  ]);
}

{
  // Sorting only by full path would split src's direct children around
  // src/sub, emitting the src heading twice.
  const rows = view.fileRows([
    { path: "src/z.swift" },
    { path: "src/sub/b.swift" },
    { path: "src/a.swift" }
  ]);
  assert.deepEqual(rows.map((row) => row.type === "directory" ? row.dir : row.path), [
    "src",
    "src/a.swift",
    "src/z.swift",
    "src/sub",
    "src/sub/b.swift"
  ]);
}

{
  const summary = view.formatSummary({
    comparisonRef: "origin/main",
    files: [
      { path: "a.txt", add: 12, del: 3 },
      { path: "b.txt", add: 2, del: 0 }
    ],
    truncated: false
  });
  assert.equal(summary, "vs origin/main · 2 files · +14 −3");
}

{
  const summary = view.formatSummary({ comparisonRef: null, files: [{ path: "a.txt", add: 1, del: 0 }], truncated: false });
  assert.equal(summary, "1 file · +1 −0");
}

{
  const summary = view.formatSummary({
    comparisonRef: null,
    files: [{ path: "mixed.txt", add: 2, del: 0 }],
    staged: [{ path: "mixed.txt", add: 1, del: 0 }],
    unstaged: [{ path: "mixed.txt", add: 1, del: 0 }]
  });
  assert.equal(summary, "1 file · +2 −0");
}

{
  assert.equal(view.formatFileCounts({ add: 12, del: 3 }), "+12 −3");
}

{
  const sections = view.changeSections({
    files: [{ path: "committed.swift", add: 8, del: 2 }],
    staged: [{ path: "staged.swift", add: 3, del: 1 }],
    unstaged: [{ path: "unstaged.swift", add: 2, del: 0 }],
    commits: [{ shortSha: "abc1234", subject: "Add remote changes", author: "Nacho", add: 8, del: 2 }]
  });
  assert.deepEqual(sections.map((section) => section.title), ["Branch changes", "Working tree", "Staged", "Unstaged", "Commits"]);
  assert.equal(sections[0].files[0].path, "committed.swift");
  assert.equal(sections[2].stage, "staged");
  assert.equal(sections[2].files[0].path, "staged.swift");
  assert.equal(sections[4].commits[0].shortSha, "abc1234");
}

{
  const sections = view.changeSections({
    files: [{ path: "base-relative.swift", add: 1, del: 1 }],
    staged: [],
    unstaged: [],
    commits: []
  });
  assert.deepEqual(sections.map((section) => section.title), ["Branch changes"]);
  assert.equal(sections[0].files[0].path, "base-relative.swift");
}

{
  const rows = view.diffRows([
    {
      header: "@@ -1,2 +1,3 @@",
      oldStart: 1,
      newStart: 1,
      lines: [
        { kind: "context", text: "import Foundation", oldNumber: 1, newNumber: 1 },
        { kind: "add", text: "import Testing", oldNumber: null, newNumber: 2 }
      ]
    }
  ]);
  assert.equal(rows.length, 3);
  assert.equal(rows[0].type, "hunk");
  assert.equal(rows[0].text, "@@ -1,2 +1,3 @@");
  assert.equal(rows[1].type, "line");
  assert.equal(rows[1].kind, "context");
  assert.equal(rows[2].kind, "add");
  assert.equal(rows[2].newNumber, 2);
}

{
  assert.equal(view.truncationNotice(false, "diff"), "");
  assert.equal(view.truncationNotice(true, "diff"), "Diff truncated — open this file on the desktop to see the rest.");
  assert.equal(view.truncationNotice(true, "files"), "File list truncated — too many changed files to show.");
  assert.equal(view.truncationNotice(true, "lines"), "File truncated — too many lines to show.");
  assert.equal(view.truncationNotice(false, "lines"), "");
  assert.equal(view.truncationNotice(true, "directory"), "Directory truncated — too many entries to show.");
  assert.equal(view.truncationNotice(false, "directory"), "");
}

{
  // `noTrailingNewline` must round-trip through `diffRows` so a diff that
  // only adds/removes a trailing newline doesn't render as two
  // identical-looking lines with no visual distinction.
  const rows = view.diffRows([
    {
      header: "@@ -1,1 +1,1 @@",
      oldStart: 1,
      newStart: 1,
      lines: [
        { kind: "delete", text: "old", oldNumber: 1, newNumber: null, noTrailingNewline: true },
        { kind: "add", text: "new", oldNumber: null, newNumber: 1 }
      ]
    }
  ]);
  assert.equal(rows[1].noTrailingNewline, true);
  assert.equal(rows[2].noTrailingNewline, false);
}

{
  // No hunks and no note: a genuinely empty diff (shouldn't normally
  // happen, but must not crash or show a stray empty banner).
  assert.equal(view.metadataOnlyNotice([], null), "");
  assert.equal(view.metadataOnlyNotice([], undefined), "");

  // No hunks, note present: a pure rename/copy/mode change — the note IS
  // the payload.
  assert.equal(
    view.metadataOnlyNotice([], "Renamed from old.txt to new.txt — no content changes."),
    "Renamed from old.txt to new.txt — no content changes."
  );

  // Hunks present alongside a note: real content changes take priority —
  // the note would just be noise over an actual diff.
  const hunks = [{ header: "@@ -1,1 +1,1 @@", oldStart: 1, newStart: 1, lines: [] }];
  assert.equal(view.metadataOnlyNotice(hunks, "should not surface"), "");
}

{
  // A tool call's content that is exactly its patches' hunks gets one path
  // line per file; anything else is shown as sent.
  const diffs = [
    { path: "/w/a.txt", patch: "diff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n@@ -1 +1 @@\n-a\n+b\n" },
    { path: "/w/b.txt", patch: "--- a/b.txt\n+++ b/b.txt\n@@ -1 +1 @@\r\n-x\r\n+y\r\n" },
    { path: "/w/c.txt", patch: null }
  ];
  const content = "@@ -1 +1 @@\n-a\n+b\n@@ -1 +1 @@\r\n-x\r\n+y\r\nChange unavailable: /w/c.txt";
  assert.equal(
    view.toolDiffText(content, diffs),
    "--- /w/a.txt\n@@ -1 +1 @@\n-a\n+b\n\n--- /w/b.txt\n@@ -1 +1 @@\r\n-x\r\n+y\r\n\n--- /w/c.txt\nChange unavailable: /w/c.txt"
  );
  assert.equal(view.toolDiffText(content + "\nApplied.", diffs), content + "\nApplied.");
  assert.equal(view.toolDiffText("plain output", []), "plain output");
  assert.equal(view.toolDiffText("plain output", undefined), "plain output");
  assert.equal(view.toolDiffText(undefined, diffs), undefined);
}

// --- Draft review comments ---------------------------------------------------

// Old 10–12 → new 10–12: line 11 "b" became "B", with context around it.
const reviewHunks = [{ header: "@@ -10,3 +10,3 @@", oldStart: 10, newStart: 10, lines: [
  { kind: "context", text: "a", oldNumber: 10, newNumber: 10 },
  { kind: "delete", text: "b", oldNumber: 11, newNumber: null },
  { kind: "add", text: "B", oldNumber: null, newNumber: 11 },
  { kind: "context", text: "c", oldNumber: 12, newNumber: 12 }] }];

// One side stays on that side; a range over both sides, either way round, anchors to the new side.
for (const [range, expected] of [
  [{ start: 11, side: "additions", end: 12, endSide: "additions" }, { side: "new", startLine: 11, endLine: 12, selectedText: "B\nc" }],
  [{ start: 11, side: "deletions", end: 11, endSide: "deletions" }, { side: "old", startLine: 11, endLine: 11, selectedText: "b" }],
  [{ start: 11, side: "deletions", end: 11, endSide: "additions" }, { side: "new", startLine: 11, endLine: 11, selectedText: "B" }],
  [{ start: 12, side: "additions", end: 10, endSide: "additions" }, { side: "new", startLine: 10, endLine: 12, selectedText: "a\nB\nc" }],
]) assert.deepEqual(view.commentAnchor(reviewHunks, range), expected, JSON.stringify(range));
assert.equal(view.commentAnchor(reviewHunks, { start: 99, side: "additions", end: 99 }), null, "a line the diff doesn't show");
const twoHunks = reviewHunks.concat([{ header: "@@ -40,1 +40,1 @@", oldStart: 40, newStart: 40, lines: [
  { kind: "context", text: "z", oldNumber: 40, newNumber: 40 }] }]);
assert.equal(view.commentAnchor(twoHunks, { start: 12, side: "additions", end: 40, endSide: "additions" }), null,
  "a range across hunks, whose quote would miss the lines between them");

// Open comments on this file and namespace sit under their last line, or above the diff once their
// lines are gone; resolved ones and other files or stages are left out.
const reviewComment = (id, fileID, line, state = "active") => ({ id, fileID, state, anchor: line ? { line } : { file: {} } });
const here = { namespace: "unstaged", path: "src/a.swift" };
const annotations = view.commentAnnotations(reviewHunks, [
  reviewComment("shown", here, { side: "new", startLine: 10, endLine: 11 }),
  reviewComment("removed", here, { side: "old", startLine: 11, endLine: 11 }),
  reviewComment("gone", here, { side: "new", startLine: 40, endLine: 41 }),
  reviewComment("file", here, null),
  reviewComment("resolved", here, { side: "new", startLine: 10 }, "resolved"),
  reviewComment("staged", { namespace: "staged", path: "src/a.swift" }, { side: "new", startLine: 10 }),
], "unstaged", "src/a.swift");
assert.deepEqual(annotations.map(a => [a.metadata.comment.id, a.side, a.lineNumber]), [
  ["shown", "additions", 11], ["removed", "deletions", 11], ["gone", "additions", 0], ["file", "additions", 0]]);

// A comment that quotes its lines follows them: it stays while its anchor still reads the quote, moves
// to the one other run that does, and goes above the diff when the quote reads nowhere or in two places.
const moved = [{ header: "@@ -1,3 +1,5 @@", oldStart: 1, newStart: 1, lines: [
  { kind: "add", text: "inserted", oldNumber: null, newNumber: 1 },
  { kind: "context", text: "a", oldNumber: 1, newNumber: 2 },
  { kind: "context", text: "b", oldNumber: 2, newNumber: 3 },
  { kind: "add", text: "a", oldNumber: null, newNumber: 4 },
  { kind: "context", text: "c", oldNumber: 3, newNumber: 5 }] }];
const quoting = (id, startLine, endLine, selectedText) => reviewComment(id, here, { side: "new", startLine, endLine, selectedText });
assert.deepEqual(view.commentAnnotations(moved, [
  quoting("stayed", 3, 3, "b"),
  quoting("moved", 2, 2, "c"),
  quoting("gone", 2, 2, "zzz"),
  quoting("ambiguous", 3, 3, "a"),
  quoting("numbers", 2, 3, "only one line"),
], "unstaged", "src/a.swift").map(a => [a.metadata.comment.id, a.lineNumber, view.commentLines(a.metadata.comment, a.metadata.placed)]),
  [["stayed", 3, "Line 3"], ["moved", 5, "Line 5"], ["gone", 0, "Was line 2"], ["ambiguous", 0, "Was line 3"], ["numbers", 3, "Lines 2–3"]]);

// Comments whose file and stage the changes list no longer shows are the review bar's to list.
const listed = { loaded: true, staged: [{ path: "src/a.swift" }], unstaged: [{ path: "src/b.swift" }] };
assert.deepEqual(view.unlistedComments([
  reviewComment("shown", { namespace: "staged", path: "src/a.swift" }, null),
  reviewComment("restaged", { namespace: "unstaged", path: "src/a.swift" }, null),
  reviewComment("reverted", { namespace: "unstaged", path: "src/gone.swift" }, null),
  reviewComment("resolved", { namespace: "unstaged", path: "src/gone.swift" }, null, "resolved"),
], listed).map(c => c.id), ["restaged", "reverted"]);
assert.deepEqual(view.unlistedComments([reviewComment("x", here, null)], { loaded: false }), [], "nothing before the list loads");

// Only the user's own comments, by encoded author: an agent named "You" is still an agent.
assert.equal(view.isUserComment({ author: { user: {} } }), true);
assert.equal(view.isUserComment({ author: { agent: { name: "You" } } }), false);
assert.equal(view.isUserComment({}), true, "the Mac saves the user's comments without an author");

// The id the host gives the worktree's local-changes review, field separators escaped.
assert.equal(view.localChangesReviewID("w1", "/repo/a\u001fb/"), "local-changes\u001fw1\u001f/repo/a\\u001fb\u001fall");

// The bundled @pierre/diffs parses the patch built from the host's hunks: the file keeps its own
// name, counts come from the lines even when the host's header disagrees, and a missing final
// newline survives.
(async () => {
  const { getSingularPatch } = await import("../../../Alas/Resources/RemoteWeb/diffs/diffs.js");
  const diff = getSingularPatch(view.unifiedPatch("src/a.swift", [
    { header: "@@ -0,0 +1,2 @@", oldStart: 0, newStart: 1, lines: [{ kind: "add", text: "x" }, { kind: "add", text: "y" }] },
    { header: "@@ -9,9 +11,9 @@ func f()", oldStart: 9, newStart: 11, lines: [
      { kind: "context", text: "a" }, { kind: "delete", text: "b" }, { kind: "add", text: "c", noTrailingNewline: true }] }
  ]));
  assert.equal(diff.name, "src/a.swift");
  assert.equal(diff.type, "change");
  assert.deepEqual(diff.hunks.map(h => [h.deletionStart, h.deletionCount, h.additionStart, h.additionCount, h.hunkContext]),
    [[0, 0, 1, 2, undefined], [9, 2, 11, 2, "func f()"]]);
  assert.deepEqual(diff.additionLines, ["x\n", "y\n", "a\n", "c"]);
  assert.deepEqual(diff.deletionLines, ["a\n", "b\n"]);
  console.log("remote-web-changes: ok");
})().catch(error => { console.error(error); process.exit(1); });
