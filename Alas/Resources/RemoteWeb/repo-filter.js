// Pure helpers for the Repos list: repo tile color/initials, relative time,
// diff-bar segments, and the search/filter predicates. No DOM access, no
// mutable state — mirrors the shape of session-ordering.js.

// A small fixed palette (not the full accent hue) so tiles read as distinct
// but stay in the app's cool-slate family. Picked deterministically from the
// repo name's hash so the same repo always gets the same color without any
// stored/persisted state.
const REPO_TILE_HUES = [200, 230, 260, 300, 330, 15, 45, 85, 130, 165];

function hashString(str) {
  let hash = 0;
  for (let i = 0; i < str.length; i++) {
    hash = (hash * 31 + str.charCodeAt(i)) | 0;
  }
  return Math.abs(hash);
}

function repoTileColor(name) {
  const hue = REPO_TILE_HUES[hashString(String(name || "")) % REPO_TILE_HUES.length];
  return `oklch(0.5 0.13 ${hue})`;
}

function repoInitials(name) {
  const cleaned = String(name || "").replace(/^[.]/, "");
  const parts = cleaned.split(/[\s\-_]+/).filter(Boolean);
  if (parts.length === 0) return "?";
  if (parts.length === 1) return parts[0].slice(0, 2).toUpperCase();
  return (parts[0][0] + parts[1][0]).toUpperCase();
}

function worktreeIsPrimaryBranch(name) {
  return name === "main" || name === "master";
}

function worktreeIsActive(worktree) {
  return worktree.activeSessions.length > 0;
}

// "Running" = an open session whose agent is mid-turn (streaming, or parked
// on a permission/question prompt). Idle open tabs don't count — the chip is
// about which agents are working right now, not which tabs exist.
function sessionIsRunning(session) {
  return !!session && session.status != null && session.status !== "idle";
}

function worktreeIsRunning(worktree) {
  return worktree.activeSessions.some(sessionIsRunning);
}

function worktreeIsDirty(worktree) {
  return !!(worktree.summary && worktree.summary.changedFileCount > 0);
}

// The card's second-row status: what the agent is doing beats what the tree
// looks like, and the tree's dirtiness beats "clean".
//   { kind: "run" | "dirty" | "idle", label }
function worktreeStatus(worktree) {
  if (worktreeIsRunning(worktree)) return { kind: "run", label: "running" };
  const summary = worktree.summary;
  if (summary && summary.metricsAvailable === false) return { kind: "idle", label: "changes unavailable" };
  if (summary && summary.conflictCount > 0) {
    return { kind: "dirty", label: `${summary.conflictCount} conflict${summary.conflictCount === 1 ? "" : "s"}` };
  }
  if (summary && summary.changedFileCount > 0) {
    return { kind: "dirty", label: `${summary.changedFileCount} file${summary.changedFileCount === 1 ? "" : "s"}` };
  }
  return { kind: "idle", label: "clean" };
}

// Most recent activity across every session in the worktree, in Unix
// milliseconds. The wire's `updatedAt` is Unix seconds.
function worktreeRecencyMs(worktree, nowMs) {
  const stamps = [...worktree.activeSessions, ...worktree.closedSessions]
    .map((session) => Number(session.updatedAt))
    .filter((value) => Number.isFinite(value) && value > 0)
    .map((seconds) => seconds * 1000);
  return stamps.length ? Math.max(...stamps) : nowMs;
}

function relativeTimeShort(updatedAtMs, nowMs) {
  const deltaSeconds = Math.max(0, Math.round((nowMs - updatedAtMs) / 1000));
  if (deltaSeconds < 60) return "now";
  const minutes = Math.round(deltaSeconds / 60);
  if (minutes < 60) return `${minutes} min`;
  const hours = Math.round(minutes / 60);
  if (hours < 24) return `${hours} hr`;
  const days = Math.round(hours / 24);
  return `${days} d`;
}

// Returns 5 booleans, left-to-right, `true` where that segment should render
// in the "add" color rather than the "delete" color — proportional to the
// add/delete ratio, always at least one segment on whichever side has any
// lines at all.
function diffBarSegments(added, deleted) {
  const total = added + deleted;
  if (total <= 0) return [false, false, false, false, false];
  const cap = deleted > 0 ? 4 : 5;
  const addSegments = Math.min(cap, Math.max(added > 0 ? 1 : 0, Math.round((5 * added) / total)));
  return Array.from({ length: 5 }, (_, i) => i < addSegments);
}

function sectionMatchesFilter(section, filter) {
  if (filter === "all") return true;
  if (filter === "running") return section.worktrees.some(worktreeIsRunning);
  if (filter === "dirty") return section.worktrees.some(worktreeIsDirty);
  return true;
}

function sessionTitlesOf(worktree) {
  return [...worktree.activeSessions, ...worktree.closedSessions].map((s) => s.title || "");
}

function sectionMatchesQuery(section, query) {
  const needle = String(query || "").trim().toLowerCase();
  if (!needle) return true;
  if (String(section.title || "").toLowerCase().includes(needle)) return true;
  return section.worktrees.some((worktree) => {
    if (String(worktree.title || "").toLowerCase().includes(needle)) return true;
    const branch = worktree.summary && worktree.summary.branch;
    if (branch && String(branch).toLowerCase().includes(needle)) return true;
    return sessionTitlesOf(worktree).some((title) => title.toLowerCase().includes(needle));
  });
}

function sectionCounts(sections) {
  const counts = { all: 0, running: 0, dirty: 0 };
  for (const section of sections) {
    counts.all += 1;
    if (sectionMatchesFilter(section, "running")) counts.running += 1;
    if (sectionMatchesFilter(section, "dirty")) counts.dirty += 1;
  }
  return counts;
}

globalThis.RemoteRepoFilter = {
  repoTileColor,
  repoInitials,
  worktreeIsPrimaryBranch,
  worktreeIsActive,
  sessionIsRunning,
  worktreeIsRunning,
  worktreeIsDirty,
  worktreeStatus,
  worktreeRecencyMs,
  relativeTimeShort,
  diffBarSegments,
  sectionMatchesFilter,
  sectionMatchesQuery,
  sectionCounts,
};
