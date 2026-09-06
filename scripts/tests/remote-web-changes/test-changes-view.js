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
  assert.equal(view.formatFileCounts({ add: 12, del: 3 }), "+12 −3");
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
}

console.log("remote-web-changes: ok");
