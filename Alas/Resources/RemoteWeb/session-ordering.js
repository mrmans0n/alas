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

// Sessions bucketed by worktree only, ignoring project grouping — used for
// a single peer server's sessions, which get one section per server rather
// than the full project/worktree nesting `groupSessions` builds for the
// local Mac's own repos.
function bucketWorktrees(sessions) {
  const worktrees = new Map();
  const other = { id: "other", title: "Other", activeSessions: [], closedSessions: [] };
  let hasOther = false;

  sessions.forEach((session) => {
    const worktreeID = worktreeIdentity(session);
    if (!session.worktree || !worktreeID) {
      (sessionIsActive(session) ? other.activeSessions : other.closedSessions).push(session);
      hasOther = true;
      return;
    }
    const worktree = worktrees.get(worktreeID) || {
      id: worktreeID,
      title: session.worktree.worktreeName,
      summary: session.worktree,
      activeSessions: [],
      closedSessions: [],
    };
    (sessionIsActive(session) ? worktree.activeSessions : worktree.closedSessions).push(session);
    worktrees.set(worktreeID, worktree);
  });

  const list = [...worktrees.values()].map((worktree) => {
    worktree.activeSessions.sort(compareSessions);
    worktree.closedSessions.sort(compareSessions);
    return worktree;
  }).sort(compareWorktrees);

  if (hasOther) {
    other.activeSessions.sort(compareSessions);
    other.closedSessions.sort(compareSessions);
    list.push(other);
  }
  return list;
}

// Splits a sessionList into this Mac's own sessions (grouped exactly as
// `groupSessions` already does) plus one additional section per peer
// server whose rows the active gateway forwarded (`session.serverId` set).
// A pre-federation sessionList carries no serverId on any row, so the peer
// map stays empty and the local sections come back unchanged.
function groupSessionsByServer(sessions) {
  const local = [];
  const peers = new Map(); // serverId -> { serverId, serverName, sessions }

  sessions.forEach((session) => {
    if (session.serverId) {
      const peer = peers.get(session.serverId) || {
        serverId: session.serverId,
        serverName: session.serverName || session.serverId,
        sessions: [],
      };
      peer.sessions.push(session);
      peers.set(session.serverId, peer);
    } else {
      local.push(session);
    }
  });

  const sections = groupSessions(local);
  if (peers.size === 0) return sections;

  // `groupSessions` already sorts its own "Other" bucket (this Mac's own
  // orphan sessions) last among local sections — peer sections, each
  // representing an entirely different Mac, belong after ALL local content,
  // Other included.
  const peerSections = [...peers.values()]
    .sort((a, b) => a.serverName.localeCompare(b.serverName, undefined, { sensitivity: "accent" }))
    .map((peer) => ({
      id: "server:" + peer.serverId,
      title: peer.serverName,
      isOther: false,
      isPeer: true,
      worktrees: bucketWorktrees(peer.sessions),
    }));

  return [...sections, ...peerSections];
}

globalThis.RemoteSessionOrdering = { groupSessions, groupSessionsByServer, sessionIsActive };
