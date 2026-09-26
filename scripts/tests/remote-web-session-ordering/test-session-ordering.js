const assert = require("node:assert/strict");

require("../../../Alas/Resources/RemoteWeb/session-ordering.js");

const ordering = globalThis.RemoteSessionOrdering;

function session(
  id,
  projectId,
  projectName,
  worktreeId,
  updatedAt,
  isActive,
  title = id
) {
  return {
    id, title, projectId, worktreeId, updatedAt, isActive,
    worktree: projectName ? {
      projectName,
      worktreeName: `${worktreeId}-worktree`,
      path: `/worktrees/${worktreeId}`,
    } : null,
  };
}

const sections = ordering.groupSessions([
  session("a-closed", "repo-a", "Alpha", "a-primary", 100, false),
  session("a-active-old", "repo-a", "Alpha", "a-primary", 90, true),
  session("a-active-new", "repo-a", "Alpha", "a-primary", 110, true),
  session("a-secondary", "repo-a", "Alpha", "a-secondary", 105, true),
  session("b-active", "repo-b", "Beta", "b-primary", 105, true),
  session("orphan-active", null, null, null, 999, true),
  session("orphan-closed", null, null, null, 998, false),
]);

assert.deepStrictEqual(sections.map(({ id }) => id), ["repo-a", "repo-b", "other"]);
assert.deepStrictEqual(sections[0].worktrees.map(({ id }) => id), ["a-primary", "a-secondary"]);
assert.deepStrictEqual(
  sections[0].worktrees[0].activeSessions.map(({ id }) => id),
  ["a-active-new", "a-active-old"]
);
assert.deepStrictEqual(sections[0].worktrees[0].closedSessions.map(({ id }) => id), ["a-closed"]);
assert.deepStrictEqual(sections[2].worktrees[0].activeSessions.map(({ id }) => id), ["orphan-active"]);
assert.deepStrictEqual(sections[2].worktrees[0].closedSessions.map(({ id }) => id), ["orphan-closed"]);

const legacy = ordering.groupSessions([
  session("legacy-a", "repo-legacy", "Legacy", null, 50, true),
  session("legacy-b", "repo-legacy", "Legacy", null, 40, true),
]);
assert.deepStrictEqual(legacy[0].worktrees.map(({ id }) => id), ["/worktrees/null"]);
assert.deepStrictEqual(legacy[0].worktrees[0].activeSessions.map(({ id }) => id), ["legacy-a", "legacy-b"]);

const equalTimestamps = ordering.groupSessions([
  session("z-id", "repo-ties", "Ties", "ties", 50, true, "alpha"),
  session("a-id", "repo-ties", "Ties", "ties", 50, true, "Alpha"),
  session("b-id", "repo-ties", "Ties", "ties", 50, true, "beta"),
]);
assert.deepStrictEqual(equalTimestamps[0].worktrees[0].activeSessions.map(({ id }) => id), ["a-id", "z-id", "b-id"]);

const caseSensitiveIds = ordering.groupSessions([
  session("a-id", "repo-case", "Case", "case", 50, true, "same"),
  session("A-id", "repo-case", "Case", "case", 50, true, "Same"),
]);
assert.deepStrictEqual(caseSensitiveIds[0].worktrees[0].activeSessions.map(({ id }) => id), ["A-id", "a-id"]);

const equalRecencySections = ordering.groupSessions([
  session("z-session", "repo-z", "Zulu", "z", 50, true),
  session("a-session", "repo-a", "Alpha", "a", 50, true),
]);
assert.deepStrictEqual(equalRecencySections.map(({ id }) => id), ["repo-a", "repo-z"]);

// --- groupSessionsByServer -----------------------------------------------------

const withPeers = ordering.groupSessionsByServer([
  session("local-a", "repo-a", "Alpha", "a-primary", 100, true),
  {
    id: "peer-1", title: "peer session", projectId: "repo-x", worktreeId: "x-wt", updatedAt: 90, isActive: true,
    worktree: { projectName: "PeerRepo", worktreeName: "x-wt-worktree", path: "/worktrees/x-wt" },
    serverId: "srv-B", serverName: "Nacho's Studio",
  },
  {
    id: "peer-2", title: "peer orphan", projectId: null, worktreeId: null, updatedAt: 80, isActive: true, worktree: null,
    serverId: "srv-B", serverName: "Nacho's Studio",
  },
]);
assert.deepStrictEqual(withPeers.map((s) => s.id), ["repo-a", "server:srv-B"]);
const peerSection = withPeers[1];
assert.equal(peerSection.title, "Nacho's Studio");
assert.equal(peerSection.isPeer, true);
assert.deepStrictEqual(peerSection.worktrees.map((w) => w.id), ["x-wt", "other"]);
assert.deepStrictEqual(peerSection.worktrees[0].activeSessions.map((s) => s.id), ["peer-1"]);
assert.deepStrictEqual(peerSection.worktrees[1].activeSessions.map((s) => s.id), ["peer-2"]);

// A pre-federation sessionList (no serverId anywhere) must group identically
// to groupSessions() itself.
const noServerId = [
  session("a", "repo-a", "Alpha", "a-wt", 10, true),
  session("b", "repo-b", "Beta", "b-wt", 20, true),
];
assert.deepStrictEqual(ordering.groupSessionsByServer(noServerId), ordering.groupSessions(noServerId));

// Two peers each get their own section, sorted by server name, after every
// local section including this Mac's own "Other" bucket (orphan local
// sessions) — peer sections represent an entirely different Mac each.
const twoPeers = ordering.groupSessionsByServer([
  session("orphan-local", null, null, null, 5, true),
  { id: "z1", title: "z", projectId: null, worktreeId: null, updatedAt: 1, isActive: true, worktree: null, serverId: "srv-Z", serverName: "Zulu" },
  { id: "a1", title: "a", projectId: null, worktreeId: null, updatedAt: 1, isActive: true, worktree: null, serverId: "srv-A", serverName: "Alpha Studio" },
]);
assert.deepStrictEqual(twoPeers.map((s) => s.id), ["other", "server:srv-A", "server:srv-Z"]);
assert.equal(twoPeers[0].isOther, true);

console.log("session ordering tests passed");
