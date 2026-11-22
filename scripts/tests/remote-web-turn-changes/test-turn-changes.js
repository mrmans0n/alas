const assert = require("node:assert/strict");

require("../../../Alas/Resources/RemoteWeb/turn-changes.js");

const tc = globalThis.RemoteTurnChanges;

// The same cases as turnChangesSumTheEditsOfAFinishedTurnUnderItsAnswer in RemoteTranscriptFoldTests:
// `u` user, `a` agent, `o` anything else, `e<path>` a file write and `t<paths>` a tool call's patches,
// each adding and removing one line per path.
function items(transcript) {
  return transcript.split(" ").map((token) => {
    if (token === "u") return { type: "user" };
    if (token === "a") return { type: "agent" };
    if (token === "o") return { type: "other" };
    const file = (path) => ({ path, added: 1, removed: 1 });
    return token[0] === "t"
      ? { type: "toolCallEdits", files: [...token.slice(1)].map(file) }
      : { type: "fileEdit", file: file(token.slice(1)) };
  });
}

function summary(transcript, answer, isTurnActive) {
  const changes = tc.forAnswer(items(transcript), answer, isTurnActive);
  return changes && changes.files.map((f) => `${f.path}+${f.added}-${f.removed}`).join(" ");
}

assert.equal(summary("u ea eb ea a", 4, false), "a+2-2 b+1-1");
assert.equal(summary("u ea eb ea a", 4, true), null);
assert.equal(summary("u ea eb a u o", 3, true), "a+1-1 b+1-1");
assert.equal(summary("u ea eb a o a", 3, false), null);
assert.equal(summary("u ea o a", 3, false), null);
assert.equal(summary("ea u eb ec a", 4, false), "b+1-1 c+1-1");
assert.equal(summary("eb ec a", 2, false), null);
assert.equal(summary("u tab a", 2, false), "a+1-1 b+1-1");
assert.equal(summary("u ea ta eb a", 4, false), "a+1-1 b+1-1");

const totals = tc.forAnswer(items("u ea eb ea a"), 4, false);
assert.equal(totals.added, 3);
assert.equal(totals.removed, 3);

// --- wire rows ----------------------------------------------------------------

const root = "/repos/alas/";
const call = (status, diffs) => ({ kind: "toolCall", json: JSON.stringify({ status, diffs }) });
const diff = (path, extra = {}) => ({ path, source: "toolCall", added: 2, removed: 1, ...extra });

assert.deepEqual(tc.itemOf(call("completed", [diff("/repos/alas/src/a.swift"), diff("/elsewhere/b.swift")]), root), {
  type: "toolCallEdits",
  files: [{ path: "src/a.swift", added: 2, removed: 1 }, { path: "/elsewhere/b.swift", added: 2, removed: 1 }],
});
// Proposed and unreadable patches, and unfinished calls, change nothing.
assert.deepEqual(tc.itemOf(call("completed", [diff("a", { source: "permissionRequest" }), diff("b", { failure: "truncated" })]), root).files, []);
assert.deepEqual(tc.itemOf(call("in_progress", [diff("a")]), root).files, []);
assert.deepEqual(tc.itemOf({ kind: "fileEdit", json: '{"path":"x.md","added":3,"removed":0}' }, root),
  { type: "fileEdit", file: { path: "x.md", added: 3, removed: 0 } });
assert.equal(tc.itemOf({ kind: "user", isHidden: true }, root).type, "other");
assert.equal(tc.relativePath("/repos/alas", root), "/repos/alas");

console.log("turn-changes tests passed");
