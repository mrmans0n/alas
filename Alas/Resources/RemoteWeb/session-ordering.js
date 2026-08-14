function sessionIsActive(session) {
  return session.isActive !== false;
}

function sessionRecency(session) {
  const updatedAt = Number(session.updatedAt);
  return Number.isFinite(updatedAt) ? updatedAt : 0;
}

function compareSessions(a, b) {
  const active = Number(sessionIsActive(b)) - Number(sessionIsActive(a));
  if (active) return active;

  const recency = sessionRecency(b) - sessionRecency(a);
  if (recency) return recency;

  const title = String(a.title || "").localeCompare(String(b.title || ""), undefined, { sensitivity: "accent" });
  if (title) return title;

  const aID = String(a.id || "");
  const bID = String(b.id || "");
  return aID === bID ? 0 : aID < bID ? -1 : 1;
}

function groupSessions(sessions) {
  const groups = new Map();
  const other = [];

  sessions.forEach((session) => {
    if (!session.projectId || !session.worktree) {
      other.push(session);
      return;
    }

    const group = groups.get(session.projectId) || {
      id: session.projectId,
      title: session.worktree.projectName,
      sessions: [],
      isOther: false,
    };
    group.sessions.push(session);
    groups.set(session.projectId, group);
  });

  const sections = [...groups.values()];
  if (other.length) sections.push({ id: "other", title: "Other", sessions: other, isOther: true });

  sections.forEach((section) => section.sessions.sort(compareSessions));
  return sections.sort((a, b) => {
    if (a.isOther) return 1;
    if (b.isOther) return -1;
    return Math.max(...b.sessions.map(sessionRecency)) - Math.max(...a.sessions.map(sessionRecency));
  });
}

globalThis.RemoteSessionOrdering = { groupSessions, sessionIsActive };
