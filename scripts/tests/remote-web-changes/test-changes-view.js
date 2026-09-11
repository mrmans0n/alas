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
  assert.deepEqual(sections.map((section) => section.title), ["Branch Changes", "Working Tree", "Staged", "Unstaged", "Commits"]);
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
  assert.deepEqual(sections.map((section) => section.title), ["Branch Changes"]);
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

console.log("remote-web-changes: ok");
