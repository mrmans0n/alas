// Pure helpers for the turn changes card: the files a finished turn changed, listed under its answer.
// No DOM access, no mutable state. A port of ACPTurnChanges in AlasRemoteKit, so the web, the Mac and
// the phone app list the same files.

// Where `path` sits under `worktreeRoot`, or `path` as sent when it is elsewhere.
function relativePath(path, worktreeRoot) {
  if (!worktreeRoot) return path;
  const root = String(worktreeRoot).replace(/\/+$/, "") || "/";
  const prefix = root + "/";
  return root !== "/" && path.startsWith(prefix) && path.length > prefix.length ? path.slice(prefix.length) : path;
}

function parse(json) {
  try { return JSON.parse(json); } catch (_) { return null; }
}

function count(value) {
  return typeof value === "number" && Number.isFinite(value) ? value : 0;
}

// The facts the card reads from one wire row:
//   { type: "user" } | { type: "agent" } | { type: "other" }
//   { type: "fileEdit", file }  a write the client handled
//   { type: "toolCallEdits", files }  the patches a completed tool call wrote; proposed or unreadable
//                                     patches and unfinished calls change nothing
function itemOf(message, worktreeRoot) {
  if (!message || message.isHidden === true) return { type: "other" };
  if (message.kind === "user") return { type: "user" };
  if (message.kind === "agent") return { type: "agent" };
  if (message.kind === "fileEdit") {
    const edit = parse(message.json);
    if (!edit || typeof edit.path !== "string") return { type: "other" };
    return { type: "fileEdit", file: { path: edit.path, added: count(edit.added), removed: count(edit.removed) } };
  }
  if (message.kind === "toolCall") {
    const call = parse(message.json);
    if (!call || call.status !== "completed" || !Array.isArray(call.diffs)) return { type: "toolCallEdits", files: [] };
    const files = call.diffs
      .filter((diff) => diff && diff.source === "toolCall" && diff.failure == null && typeof diff.path === "string")
      .map((diff) => ({ path: relativePath(diff.path, worktreeRoot), added: count(diff.added), removed: count(diff.removed) }));
    return { type: "toolCallEdits", files };
  }
  return { type: "other" };
}

// The changes of the turn whose answer is items[index]: the last agent row before the next user row,
// or before the end once the turn is over. Null for any other row, for a turn with fewer than two
// edits (its one edit card already says it all), or one whose user row is not loaded.
// Returns { files, added, removed }, files merged by path in the order each was first edited.
function forAnswer(items, index, isTurnActive) {
  if (index < 0 || index >= items.length || items[index].type !== "agent") return null;
  let next = index + 1;
  while (next < items.length && items[next].type !== "user") {
    if (items[next].type === "agent") return null;
    next++;
  }
  if (next === items.length && isTurnActive) return null;

  // Walking back from the answer, so newest first.
  let edits = [];
  let start = index - 1;
  for (; start >= 0 && items[start].type !== "user"; start--) {
    const item = items[start];
    if (item.type === "fileEdit") edits.push({ file: item.file, fromToolCall: false });
    else if (item.type === "toolCallEdits") edits.push(...item.files.slice().reverse().map((file) => ({ file, fromToolCall: true })));
  }
  // An adapter can report a write as a patch on its tool call and also make it through the client, so a
  // path a tool call reports leaves out the turn's file writes to it.
  const reported = new Set(edits.filter((edit) => edit.fromToolCall).map((edit) => edit.file.path));
  edits = edits.filter((edit) => edit.fromToolCall || !reported.has(edit.file.path));
  if (start < 0 || edits.length < 2) return null;

  const files = [];
  const position = new Map();
  for (const { file } of edits.reverse()) {
    if (position.has(file.path)) {
      const merged = files[position.get(file.path)];
      merged.added += file.added;
      merged.removed += file.removed;
    } else {
      position.set(file.path, files.length);
      files.push({ ...file });
    }
  }
  return {
    files,
    added: files.reduce((sum, file) => sum + file.added, 0),
    removed: files.reduce((sum, file) => sum + file.removed, 0),
  };
}

globalThis.RemoteTurnChanges = { relativePath, itemOf, forAnswer };
