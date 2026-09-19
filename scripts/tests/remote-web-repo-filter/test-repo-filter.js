const assert = require("node:assert/strict");

require("../../../Alas/Resources/RemoteWeb/repo-filter.js");

const filter = globalThis.RemoteRepoFilter;

function summary(overrides = {}) {
  return {
    projectName: "alas",
    worktreeName: "main",
    branch: "main",
    path: "/repos/alas",
    metricsAvailable: true,
    comparisonRef: "origin/main",
    commitCount: 0,
    changedFileCount: 0,
    addedLines: 0,
    deletedLines: 0,
    conflictCount: 0,
    ...overrides,
  };
}

function worktree(activeSessions, closedSessions = [], summaryOverrides = {}) {
  return { id: "wt", title: "main", summary: summary(summaryOverrides), activeSessions, closedSessions };
}

// --- running / status --------------------------------------------------------

assert.equal(filter.sessionIsRunning({ status: "streaming" }), true);
assert.equal(filter.sessionIsRunning({ status: "awaitingPermission" }), true);
assert.equal(filter.sessionIsRunning({ status: "idle" }), false);
assert.equal(filter.sessionIsRunning({}), false, "a session with no status is not running");

assert.equal(filter.worktreeIsRunning(worktree([{ status: "idle" }, { status: "streaming" }])), true);
assert.equal(filter.worktreeIsRunning(worktree([{ status: "idle" }])), false);
assert.equal(
  filter.worktreeIsRunning(worktree([], [{ status: "streaming" }])),
  false,
  "closed sessions never count as running"
);

assert.deepEqual(filter.worktreeStatus(worktree([{ status: "streaming" }], [], { changedFileCount: 3 })),
  { kind: "run", label: "running" }, "running beats dirty");
assert.deepEqual(filter.worktreeStatus(worktree([{ status: "idle" }], [], { changedFileCount: 3 })),
  { kind: "dirty", label: "3 files" });
assert.deepEqual(filter.worktreeStatus(worktree([{ status: "idle" }], [], { changedFileCount: 1 })),
  { kind: "dirty", label: "1 file" });
assert.deepEqual(filter.worktreeStatus(worktree([{ status: "idle" }], [], { changedFileCount: 2, conflictCount: 1 })),
  { kind: "dirty", label: "1 conflict" }, "conflicts beat plain file counts");
assert.deepEqual(filter.worktreeStatus(worktree([{ status: "idle" }])), { kind: "idle", label: "clean" });
assert.deepEqual(filter.worktreeStatus(worktree([{ status: "idle" }], [], { metricsAvailable: false, changedFileCount: 9 })),
  { kind: "idle", label: "changes unavailable" });
assert.deepEqual(filter.worktreeStatus({ id: "other", title: "Other", activeSessions: [], closedSessions: [] }),
  { kind: "idle", label: "clean" }, "the synthetic Other group has no summary");

// --- recency -----------------------------------------------------------------

const now = 1_800_000_000_000;
assert.equal(
  filter.worktreeRecencyMs(worktree([{ updatedAt: 1_700_000_000 }], [{ updatedAt: 1_700_000_500 }]), now),
  1_700_000_500_000,
  "closed sessions participate in recency and seconds convert to milliseconds"
);
assert.equal(filter.worktreeRecencyMs(worktree([{}], []), now), now, "no timestamps falls back to now");
assert.equal(filter.worktreeRecencyMs(worktree([{ updatedAt: 0 }], []), now), now, "a zero timestamp is treated as missing");

// --- filters -----------------------------------------------------------------

const running = { id: "a", title: "alpha", isOther: false, worktrees: [worktree([{ status: "streaming" }])] };
const dirty = { id: "b", title: "beta", isOther: false, worktrees: [worktree([{ status: "idle" }], [], { changedFileCount: 2 })] };
const quiet = { id: "c", title: "gamma", isOther: false, worktrees: [worktree([{ status: "idle" }])] };

assert.equal(filter.sectionMatchesFilter(running, "running"), true);
assert.equal(filter.sectionMatchesFilter(dirty, "running"), false);
assert.equal(filter.sectionMatchesFilter(dirty, "dirty"), true);
assert.equal(filter.sectionMatchesFilter(quiet, "all"), true);
assert.deepEqual(filter.sectionCounts([running, dirty, quiet]), { all: 3, running: 1, dirty: 1 });

// --- existing helpers keep their contracts -----------------------------------

assert.equal(filter.repoInitials(".dotfiles"), "DO");
assert.equal(filter.repoInitials("git-gud"), "GG");
assert.equal(filter.repoTileColor("alas"), filter.repoTileColor("alas"), "tile color is deterministic");
assert.equal(filter.relativeTimeShort(now - 30_000, now), "now");
assert.equal(filter.relativeTimeShort(now - 21 * 60_000, now), "21 min");
assert.equal(filter.relativeTimeShort(now - 15 * 3_600_000, now), "15 hr");
assert.equal(filter.relativeTimeShort(now - 4 * 86_400_000, now), "4 d");
assert.deepEqual(filter.diffBarSegments(999, 1), [true, true, true, true, false], "a lone delete keeps a segment");
assert.deepEqual(filter.diffBarSegments(0, 0), [false, false, false, false, false]);

console.log("repo-filter tests passed");
