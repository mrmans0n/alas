function sessionIsActive(session) {
  return session.isActive !== false;
}

function sessionRecency(session) {
  const updatedAt = Number(session.updatedAt);
  return Number.isFinite(updatedAt) ? updatedAt : 0;
}

function compareSessions(a, b) {
  const recency = sessionRecency(b) - sessionRecency(a);
  if (recency) return recency;

  const title = String(a.title || "").localeCompare(String(b.title || ""), undefined, { sensitivity: "accent" });
  if (title) return title;

  const aID = String(a.id || "");
  const bID = String(b.id || "");
  return aID === bID ? 0 : aID < bID ? -1 : 1;
}

function worktreeIdentity(session) {
  const worktreeID = String(session.worktreeId || "").trim();
  if (worktreeID) return worktreeID;

  const path = String(session.worktree?.path || "").trim();
  return path || null;
}

function worktreeRecency(worktree) {
  return Math.max(
    ...worktree.activeSessions.map(sessionRecency),
    ...worktree.closedSessions.map(sessionRecency)
  );
}

function worktreeOptionKey(option) {
  const id = String(option?.id || "");
  const projectId = String(option?.projectId || "");
  return JSON.stringify([projectId || null, id]);
}

function createSessionRequest(worktree, agentId) {
  const worktreeId = String(worktree?.id || "");
  const projectId = String(worktree?.projectId || "");
  if (projectId) {
    return { type: "createSessionInProject", worktreeId, projectId, agentId };
  }
  return { type: "createSession", worktreeId, agentId };
}

function compareWorktrees(a, b) {
  const recency = worktreeRecency(b) - worktreeRecency(a);
  if (recency) return recency;

  const title = a.title.localeCompare(b.title, undefined, { sensitivity: "accent" });
  if (title) return title;
  return a.id === b.id ? 0 : a.id < b.id ? -1 : 1;
}

function groupSessions(sessions) {
  const groups = new Map();
  const other = { id: "other", title: "Other", activeSessions: [], closedSessions: [] };

  sessions.forEach((session) => {
    const worktreeID = worktreeIdentity(session);
    if (!session.projectId || !session.worktree || !worktreeID) {
      (sessionIsActive(session) ? other.activeSessions : other.closedSessions).push(session);
      return;
    }

    const group = groups.get(session.projectId) || {
      id: session.projectId,
      title: session.worktree.projectName,
      worktrees: new Map(),
      isOther: false,
    };
    const worktree = group.worktrees.get(worktreeID) || {
      id: worktreeID,
      title: session.worktree.worktreeName,
      summary: session.worktree,
      activeSessions: [],
      closedSessions: [],
    };
    (sessionIsActive(session) ? worktree.activeSessions : worktree.closedSessions).push(session);
    group.worktrees.set(worktreeID, worktree);
    groups.set(session.projectId, group);
  });

  const sections = [...groups.values()].map((group) => ({
    id: group.id,
    title: group.title,
    isOther: false,
    worktrees: [...group.worktrees.values()].map((worktree) => {
      worktree.activeSessions.sort(compareSessions);
      worktree.closedSessions.sort(compareSessions);
      return worktree;
    }).sort(compareWorktrees),
  }));
  if (other.activeSessions.length || other.closedSessions.length) {
    other.activeSessions.sort(compareSessions);
    other.closedSessions.sort(compareSessions);
    sections.push({ id: "other", title: "Other", isOther: true, worktrees: [other] });
  }

  return sections.sort((a, b) => {
    if (a.isOther) return 1;
    if (b.isOther) return -1;
    const recency = Math.max(...b.worktrees.map(worktreeRecency)) - Math.max(...a.worktrees.map(worktreeRecency));
    if (recency) return recency;

    const title = a.title.localeCompare(b.title, undefined, { sensitivity: "accent" });
    if (title) return title;
    return a.id === b.id ? 0 : a.id < b.id ? -1 : 1;
  });
}

globalThis.RemoteSessionOrdering = { groupSessions, sessionIsActive, worktreeOptionKey, createSessionRequest };
