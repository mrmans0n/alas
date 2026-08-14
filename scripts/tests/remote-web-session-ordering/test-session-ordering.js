const assert = require("node:assert/strict");

require("../../../Alas/Resources/RemoteWeb/session-ordering.js");

const ordering = globalThis.RemoteSessionOrdering;

function session(id, projectId, projectName, updatedAt, isActive, title = id) {
  return {
    id, title, projectId, updatedAt, isActive,
    worktree: projectName ? { projectName, worktreeName: `${id}-worktree` } : null,
  };
}

const sections = ordering.groupSessions([
  session("a-closed", "repo-a", "Alpha", 100, false),
  session("a-active-old", "repo-a", "Alpha", 90, true),
  session("a-active-new", "repo-a", "Alpha", 110, true),
  session("b-active", "repo-b", "Beta", 105, true),
  session("orphan", null, null, 999, true),
]);

assert.deepStrictEqual(sections.map(({ id }) => id), ["repo-a", "repo-b", "other"]);
assert.deepStrictEqual(sections[0].sessions.map(({ id }) => id), ["a-active-new", "a-active-old", "a-closed"]);
assert.equal(sections[2].title, "Other");

const equalTimestamps = ordering.groupSessions([
  session("z-id", "repo-ties", "Ties", 50, true, "alpha"),
  session("a-id", "repo-ties", "Ties", 50, true, "Alpha"),
  session("b-id", "repo-ties", "Ties", 50, true, "beta"),
]);

assert.deepStrictEqual(equalTimestamps[0].sessions.map(({ id }) => id), ["a-id", "z-id", "b-id"]);

const caseSensitiveIds = ordering.groupSessions([
  session("a-id", "repo-case", "Case", 50, true, "same"),
  session("A-id", "repo-case", "Case", 50, true, "Same"),
]);

assert.deepStrictEqual(caseSensitiveIds[0].sessions.map(({ id }) => id), ["A-id", "a-id"]);

console.log("session ordering tests passed");
