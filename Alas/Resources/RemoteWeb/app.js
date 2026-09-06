const tokenKey = "alas.remote.token";
const $ = (id) => document.getElementById(id);
function listen(id, event, handler) {
  const element = $(id);
  if (element && typeof element.addEventListener === "function") element.addEventListener(event, handler);
}
let ws, currentSession = null, messages = new Map();   // stableId → wire message
let messageNodes = new Map();                          // stableId → DOM node
let transcriptMeta = null;   // {epoch, revision, firstIndex, totalCount} for the open session
let olderFetchInFlight = false;
let stopPending = false;
let queueItems = [];             // [{id, text, imageCount, resourceCount, status, lastError}] from queueState
let steerUndoAvailable = false;
let lastStreamingState = "idle"; // so composer state can be recomputed on text input
let sessionTitles = new Map();
let listedSessions = new Map();
let canDrive = false, canDriveKnown = false;
let reconnectDelay = 1500;
let reconnectTimer = null;
let connectAttempt = 0;
let pairingPromise = null;
let pairingController = null;
const initialReconnectDelay = 1500;
const maxReconnectDelay = 30000;
let everConnected = false;      // has any onopen fired this page load? separates "loading" from "disconnected"
let escalationTimer = null;     // fires after a continuous not-connected grace window, then shows the alarming gate
let escalated = false;          // true once the grace window elapsed and the alarming gate is showing
const GRACE_MS = 5000;          // total not-connected budget before escalating "Connecting…" → "Can't reach Alas"
let dismissedQuestion = null;   // {sessionId, requestId} the user closed; suppress re-shows of that exact prompt (ids aren't unique across sessions)
let lastSentText = null;        // text of the most recent sendPrompt, kept so a server promptRejected can restore it instead of losing the message
let lastSentAttachments = [];   // images of the most recent sendPrompt, restored alongside the text on promptRejected
let sessionConfig = null;       // {models,modes,currentModel,currentMode,autoRunEnabled,acceptsImages} for the open session, or null
let pendingAttachments = [];    // [{name, mimeType, dataBase64}] staged for the next sendPrompt
let renameTarget = null;
let deferredCreatePrompt = null;
let createState = {
  open: false,
  step: "worktree",
  worktrees: [],
  agents: [],
  selectedWorktreeId: null,
  selectedAgentId: null,
  filter: "",
  busy: false,
  error: ""
};
const worktreeCreation = RemoteWorktreeCreation.createFlow(send);
worktreeCreation.subscribe(() => renderCreateSheet());
const changesTree = RemoteFileBrowser.createTree();
let activeTab = "chat";
let changesState = { comparisonRef: null, metricsAvailable: true, files: [], truncated: false, loaded: false };
let detailStack = [];   // [{ tab, path }] for the in-tab list → detail level
const ATTACH_CAP = 10 * 1000 * 1000;   // 10 MB running total — matches the server's maxAttachmentsBytes

// state ∈ {connecting, ok, bad} drives the chip's dot/border color via [data-state].
function setStatus(s, state) { const e = $("status"); e.textContent = s; e.dataset.state = state || "connecting"; }
function showGate(title, msg, retry) {
  $("gate").classList.remove("connecting");   // default to the plain (alarming/pairing) look
  $("gate-title").textContent = title;
  $("gate-msg").textContent = msg;
  $("gate-retry").classList.toggle("hidden", !retry);
  $("gate").classList.remove("hidden");
}
function hideGate() {
  $("gate").classList.add("hidden");
  $("gate").classList.remove("connecting");
}

function showUnreachableGate() {
  showGate("Can't reach Alas", "Make sure your Mac is awake, Alas is running, and this device is on the same Wi-Fi or tailnet.", true);
}

// Neutral loading overlay shown while we're still trying to reach the Mac for
// the first time. Reuses the gate DOM; the `connecting` class swaps the icon
// for a spinner (see style.css) and there is no "Try again" button.
function showConnectingGate() {
  showGate("Connecting…", "Reaching your Mac…", false);
  $("gate").classList.add("connecting");
}

// Single continuous-not-connected timer: armed once and NOT reset per retry, so
// the grace period is a total budget across attempts rather than per-attempt.
function armEscalation() {
  if (escalationTimer || escalated) return;   // don't re-arm while pending, or after we've already escalated
  escalationTimer = setTimeout(() => {
    escalationTimer = null;
    escalated = true;
    showUnreachableGate();
  }, GRACE_MS);
}
function clearEscalation() {
  if (escalationTimer) {
    clearTimeout(escalationTimer);
    escalationTimer = null;
  }
  escalated = false;
}

// Pure: what should a socket close reflect, given whether we ever connected?
//   "loading"      → still on initial load: show the neutral Connecting overlay
//   "reconnecting" → mid-session drop: keep the transcript, just flag the chip
function closeState(everConnectedFlag) {
  return everConnectedFlag ? "reconnecting" : "loading";
}

function scheduleReconnect() {
  if (reconnectTimer) clearTimeout(reconnectTimer);
  reconnectTimer = setTimeout(() => {
    reconnectTimer = null;
    connect();
  }, reconnectDelay);
  reconnectDelay = Math.min(reconnectDelay * 2, maxReconnectDelay);
}

function retryConnection() {
  if (reconnectTimer) {
    clearTimeout(reconnectTimer);
    reconnectTimer = null;
  }
  if (pairingController) {
    pairingController.abort();
    pairingController = null;
    pairingPromise = null;
  }
  reconnectDelay = initialReconnectDelay;
  clearEscalation();               // start a fresh grace budget for the manual retry
  setStatus("Connecting…", "connecting");
  showConnectingGate();
  armEscalation();
  connect();
}

async function ensureToken() {
  // A freshly-scanned QR (?code present) always re-pairs, REPLACING any stored
  // token — otherwise a phone holding a stale/rejected token could never
  // recover by scanning a new code (it would keep reusing the dead token).
  const code = new URLSearchParams(location.search).get("code");
  if (code) {
    if (!pairingPromise) {
      const controller = new AbortController();
      pairingController = controller;
      pairingPromise = pairWithCode(code, controller.signal).finally(() => {
        if (pairingController === controller) pairingController = null;
        pairingPromise = null;
      });
    }
    return await pairingPromise;
  }
  const token = localStorage.getItem(tokenKey);
  if (token) return token;
  showGate("Pair this device", "On your Mac, open Alas → Settings → Remote and scan the QR code shown there.");
  throw new Error("no code");
}

async function pairWithCode(code, signal) {
  let res;
  try {
    res = await fetch("/pair", { method: "POST", body: JSON.stringify({ code, deviceName: navigator.userAgent.slice(0, 40) }), signal });
  } catch (err) {
    if (err && err.name === "AbortError") throw new Error("aborted");
    showUnreachableGate();
    throw new Error("net");
  }
  if (!res.ok) {
    localStorage.removeItem(tokenKey);
    showGate("Pairing link expired", "That code timed out. In Alas, open Settings → Remote, tap “New code”, and scan the fresh QR.");
    throw new Error("pair failed");
  }
  const token = (await res.json()).token;
  localStorage.setItem(tokenKey, token);
  history.replaceState({}, "", "/");   // strip code from URL (history + referrer)
  return token;
}

async function connect() {
  const attempt = ++connectAttempt;
  let token;
  try {
    token = await ensureToken();
  } catch (err) {
    if (attempt !== connectAttempt) return;
    if (err && err.message === "net") { scheduleReconnect(); return; }   // keep escalation armed; retrying
    clearEscalation();   // pairing / no-token is a user-action state, not an outage — cancel the doom timer
    return;              // status/gate already set by ensureToken — wait for the user
  }
  if (attempt !== connectAttempt) return;
  if (ws) { try { ws.close(); } catch (_) {} }   // drop any prior (possibly half-open) socket
  const wsScheme = location.protocol === "https:" ? "wss:" : "ws:";
  const socket = new WebSocket(`${wsScheme}//${location.host}/ws`, [token]);   // token as subprotocol
  ws = socket;
  socket.onopen = () => {
    if (socket !== ws) return;
    everConnected = true;
    clearEscalation();
    setStatus("Connected", "ok");
    hideGate();
    if (reconnectTimer) {
      clearTimeout(reconnectTimer);
      reconnectTimer = null;
    }
    reconnectDelay = initialReconnectDelay;   // reset back-off after a good connection
    send({ type: "listSessions" });
    if (currentSession) send({ type: "subscribe", sessionId: currentSession });   // re-sync after reconnect
    if (createState.open) {
      createState.error = "";
      requestCreateLists();
      reloadNewWorktreeCatalog();
      renderCreateSheet();
    }
  };
  socket.onclose = () => {
    if (socket !== ws) return;
    failCreateOnDisconnect();
    if (closeState(everConnected) === "loading") {
      // Initial load still in progress — keep the neutral loading overlay up
      // instead of flashing the alarming "Can't reach Alas" screen. Once we've
      // escalated, leave the alarming gate up rather than flapping back to it.
      if (!escalated) {
        setStatus("Connecting…", "connecting");
        showConnectingGate();
      }
    } else {
      // Mid-session drop — keep the transcript visible; only the chip changes.
      setStatus("Reconnecting…", "bad");
    }
    armEscalation();     // no-op if already armed → grace stays a total budget
    scheduleReconnect();
  };
  socket.onmessage = (e) => {
    if (socket !== ws) return;
    handle(JSON.parse(e.data));
  };
}

function send(obj) { ws && ws.readyState === 1 && ws.send(JSON.stringify(obj)); }

function handle(msg) {
  switch (msg.type) {
    case "sessionList":
      renderSessions(msg.sessions);
      worktreeCreation.markRecoveryListLoaded("sessions");
      break;
    case "transcriptSnapshot": applySnapshot(msg); break;
    case "transcriptDelta": applyDelta(msg); break;
    case "transcriptPage": applyPage(msg); break;
    case "stopPending": if (msg.sessionId === currentSession) markStopping(true); break;
    case "queueState": applyQueueState(msg); break;
    case "queueEditRestored": applyQueueEditRestored(msg); break;
    // Scope prompt events to the session currently open — a stale/in-flight
    // event for a session the user already left must not pop or close a sheet.
    case "permissionRequest": handlePromptRequest("permission", msg.sessionId, msg.payload); break;
    case "permissionResolved": if (msg.sessionId === currentSession) { clearDeferredCreatePrompt("permission", msg.sessionId); hidePermission(); } break;
    case "questionRequest": handlePromptRequest("question", msg.sessionId, msg.payload); break;
    case "questionResolved": if (msg.sessionId === currentSession) { clearDeferredCreatePrompt("question", msg.sessionId); dismissedQuestion = null; hideQuestion(); } break;
    case "elicitationRequest": handlePromptRequest("elicitation", msg.sessionId, msg.payload); break;
    case "elicitationResolved": if (msg.sessionId === currentSession) { clearDeferredCreatePrompt("elicitation", msg.sessionId); hideElicitation(); } break;
    case "sessionConfig": if (msg.sessionId === currentSession) { sessionConfig = msg; renderConfigAffordances(); } break;
    case "sessionRenamed": applySessionRenamed(msg.sessionId, msg.title); break;
    case "worktreeList":
      createState.worktrees = msg.worktrees || [];
      const recoveredWorktreeId = worktreeCreation.snapshot().selectedWorktreeId;
      if (recoveredWorktreeId && createState.worktrees.some(w => w.id === recoveredWorktreeId)) {
        createState.selectedWorktreeId = recoveredWorktreeId;
      } else if (!createState.worktrees.some(w => w.id === createState.selectedWorktreeId)) {
        createState.selectedWorktreeId = null;
      }
      worktreeCreation.markRecoveryListLoaded("worktrees");
      renderCreateSheet();
      break;
    case "agentList":
      createState.agents = msg.agents || [];
      if (!createState.selectedAgentId || !createState.agents.some(a => a.id === createState.selectedAgentId)) {
        const preferred = createState.agents.find(a => a.isDefault) || createState.agents[0];
        createState.selectedAgentId = preferred ? preferred.id : null;
      }
      worktreeCreation.reconcileAgents(createState.agents);
      renderCreateSheet();
      break;
    case "sessionCreated":
      applyCreatedSession(msg.session);
      break;
    case "createSessionFailed":
      createState.busy = false;
      createState.error = msg.message || "Could not create session.";
      renderCreateSheet();
      break;
    case "projectList":
    case "branchList":
    case "branchListFailed":
      worktreeCreation.receive(msg);
      break;
    case "worktreeSessionCreated":
      if (worktreeCreation.receive(msg)) applyCreatedSession(msg.session);
      break;
    case "worktreeSessionCreationFailed":
      if (worktreeCreation.receive(msg)) {
        const state = worktreeCreation.snapshot();
        if (state.selectedWorktreeId) createState.selectedWorktreeId = state.selectedWorktreeId;
        renderCreateSheet();
      }
      break;
    case "sessionClosed": if (msg.sessionId === currentSession) showSessions(); break;
    case "promptRejected": if (msg.sessionId === currentSession) restoreRejectedPrompt(); break;
    case "error": setStatus("Error", "bad"); $("status").title = msg.message ?? ""; break;
    default: console.warn("unknown message type", msg.type);
  }
}

function renderSessions(sessions) {
  const list = $("session-list"); list.innerHTML = "";
  listedSessions.clear();
  sessions.forEach(s => listedSessions.set(s.id, s));
  sessionTitles = new Map(sessions.map(s => [s.id, s.title]));
  RemoteSessionOrdering.groupSessions(sessions).forEach(section => {
    const element = el("section", "session-section");
    element.append(el("h2", "session-section-title", section.title));
    const rows = el("div", "session-section-list");
    section.sessions.forEach(s => rows.appendChild(renderSessionRow(s)));
    element.append(rows);
    list.appendChild(element);
  });
  if (currentSession) setDetailTitle(currentSession);
}

function renderSessionRow(s) {
  const row = document.createElement("div");
  row.dataset.sessionId = s.id;
  row.className = "session-row";
  const active = RemoteSessionOrdering.sessionIsActive(s);
  row.classList.add(active ? "session-row-active" : "session-row-inactive");

  const open = document.createElement("button");
  open.type = "button";
  open.className = "session-open";
  open.onclick = () => openSession(s.id);

  const head = el("div", "session-head");
  const title = el("span", "session-title", s.title);
  const state = el("span", active ? "session-state session-state-active" : "session-state session-state-inactive", active ? "Active" : "Closed");
  const status = el("span", "status", s.status);
  head.append(title, state, status);
  open.append(head);

  const rename = el("button", "rename-btn", "✎");
  rename.type = "button";
  rename.setAttribute("aria-label", "Rename session");
  rename.onclick = () => showRenameSheet(s.id);

  if (s.worktree) {
    row.classList.add("session-row-card");
    open.append(el("div", "session-worktree", s.worktree.worktreeName));
    const meta = el("div", "session-meta");
    const parts = sessionMetaParts(s.worktree);
    parts.forEach(part => meta.append(part));
    open.append(meta);
    row.title = s.worktree.path || "";
  } else {
    row.classList.add("session-row-minimal");
  }

  row.append(open, rename);
  return row;
}

function sessionMetaParts(worktree) {
  if (!worktree.metricsAvailable) return [el("span", "", "changes unavailable")];

  const parts = [];
  if (worktree.commitCount > 0) parts.push(el("span", "", plural(worktree.commitCount, "commit")));
  if (worktree.conflictCount > 0) parts.push(el("span", "meta-conflict", plural(worktree.conflictCount, "conflict")));
  if (worktree.changedFileCount > 0) parts.push(el("span", "", plural(worktree.changedFileCount, "file")));

  const line = [];
  if (worktree.addedLines > 0) line.push(el("span", "meta-add", "+" + worktree.addedLines));
  if (worktree.deletedLines > 0) line.push(el("span", "meta-del", "-" + worktree.deletedLines));
  if (line.length) {
    const group = el("span", "meta-lines");
    line.forEach(item => group.append(item));
    parts.push(group);
  }

  return parts.length ? parts : [el("span", "", "clean")];
}

function plural(count, singular) {
  return `${count} ${singular}${count === 1 ? "" : "s"}`;
}

function openSession(id) {
  clearSessionSheetsForOpen();
  currentSession = id; messages = new Map(); messageNodes = new Map(); transcriptMeta = null; olderFetchInFlight = false;
  dismissedQuestion = null; canDrive = false; canDriveKnown = false;
  sessionConfig = null; clearAttachments(); markStopping(false);
  $("back").classList.remove("hidden"); $("nav-title").classList.add("hidden");   // bar shows ‹ Sessions
  $("detail-title").classList.remove("hidden"); $("detail-rename").classList.remove("hidden"); setDetailTitle(id);
  $("sessions").classList.add("hidden"); $("transcript").classList.remove("hidden");
  $("messages").innerHTML = ""; renderConfigAffordances();
  queueItems = []; steerUndoAvailable = false; renderQueue();
  renderDriveBar("idle"); send({ type: "subscribe", sessionId: id });
  changesTree.reset();
  changesState = { comparisonRef: null, metricsAvailable: true, files: [], truncated: false, loaded: false };
  detailStack = [];
  const summary = listedSessions.get(id);
  $("detail-tabs").classList.toggle("hidden", !summary || !summary.worktree);
  showTab("chat");
}

function showTab(name) {
  activeTab = name;
  detailStack = [];
  $("diff-view").classList.add("hidden");
  $("file-view").classList.add("hidden");
  for (const [id, tab] of [["tab-chat", "chat"], ["tab-changes", "changes"], ["tab-files", "files"]]) {
    $(id).classList.toggle("is-active", tab === name);
  }
  $("transcript").classList.toggle("hidden", name !== "chat");
  $("changes").classList.toggle("hidden", name !== "changes");
  $("files").classList.toggle("hidden", name !== "files");
  if (name === "changes") requestChanges();
  if (name === "files" && changesTree.needsChildren(null)) {
    send({ type: "listFiles", sessionId: currentSession });
  }
}

function requestChanges() {
  if (!currentSession) return;
  send({ type: "listChanges", sessionId: currentSession });
}

$("tab-chat").addEventListener("click", () => showTab("chat"));
$("tab-changes").addEventListener("click", () => showTab("changes"));
$("tab-files").addEventListener("click", () => showTab("files"));
$("changes-refresh").addEventListener("click", requestChanges);

function clearSessionSheetsForOpen() {
  hidePermission();
  hideQuestion();
  hideElicitation();
  hideConfig();
  hideRenameSheet();
  hideCreateSheet(true);
}

function showSessions() {
  if (currentSession) send({ type: "unsubscribe", sessionId: currentSession });
  currentSession = null; canDrive = false; canDriveKnown = false;
  messages = new Map(); messageNodes = new Map(); transcriptMeta = null; olderFetchInFlight = false;
  sessionConfig = null; clearAttachments(); hideConfig(); renderConfigAffordances(); markStopping(false);
  hidePermission(); hideQuestion(); hideElicitation(); hideRenameSheet(); hideCreateSheet();   // never leave a sheet over the list
  $("back").classList.add("hidden"); $("nav-title").classList.remove("hidden");   // bar shows app title
  $("detail-title").classList.add("hidden"); $("detail-rename").classList.add("hidden");
  $("drivebar").classList.add("hidden");
  $("transcript").classList.add("hidden"); $("sessions").classList.remove("hidden");
  changesTree.reset();
  changesState = { comparisonRef: null, metricsAvailable: true, files: [], truncated: false, loaded: false };
  detailStack = [];
  activeTab = "chat";
  $("detail-tabs").classList.add("hidden");
  $("changes").classList.add("hidden");
  $("files").classList.add("hidden");
  send({ type: "listSessions" });
}

function setDetailTitle(sessionId) {
  $("detail-title").textContent = sessionTitles.get(sessionId) || "Session";
}

function handlePromptRequest(kind, sessionId, payload) {
  if (sessionId !== currentSession) return;
  if (createState.open) {
    deferredCreatePrompt = { kind, sessionId, payload };
    return;
  }
  showPromptRequest(kind, sessionId, payload);
}

function showPromptRequest(kind, sessionId, payload) {
  if (kind === "permission") {
    showPermission(sessionId, payload);
  } else if (kind === "question") {
    showQuestion(sessionId, payload);
  } else {
    showElicitation(sessionId, payload);
  }
}

function replayDeferredCreatePrompt() {
  const prompt = deferredCreatePrompt;
  deferredCreatePrompt = null;
  if (!prompt || prompt.sessionId !== currentSession) return;
  showPromptRequest(prompt.kind, prompt.sessionId, prompt.payload);
}

function clearDeferredCreatePrompt(kind, sessionId) {
  if (deferredCreatePrompt && deferredCreatePrompt.kind === kind && deferredCreatePrompt.sessionId === sessionId) {
    deferredCreatePrompt = null;
  }
}

function showRenameSheet(sessionId) {
  renameTarget = sessionId;
  const input = $("rename-input");
  input.value = sessionTitles.get(sessionId) || "";
  $("rename-sheet").classList.remove("hidden");
  requestAnimationFrame(() => { input.focus(); input.select(); });
}

function hideRenameSheet() {
  $("rename-sheet").classList.add("hidden");
  renameTarget = null;
}

function submitRename() {
  if (!renameTarget) return;
  const title = $("rename-input").value.trim();
  if (!title) return;
  send({ type: "renameSession", sessionId: renameTarget, title });
  hideRenameSheet();
}

function applySessionRenamed(sessionId, title) {
  sessionTitles.set(sessionId, title);
  const row = Array.from(document.querySelectorAll("[data-session-id]"))
    .find(candidate => candidate.dataset.sessionId === sessionId);
  const rowTitle = row && row.querySelector(".session-title");
  if (rowTitle) rowTitle.textContent = title;
  if (currentSession === sessionId) setDetailTitle(sessionId);
  if (renameTarget === sessionId) $("rename-input").value = title;
}

function showCreateSheet() {
  const preserveRecovery = worktreeCreation.snapshot().outcomeUnknown && !worktreeCreation.canRetry();
  if (!preserveRecovery) worktreeCreation.reset();
  createState = {
    ...createState,
    open: true,
    step: "worktree",
    worktrees: [],
    agents: [],
    selectedWorktreeId: null,
    selectedAgentId: null,
    filter: "",
    busy: false,
    error: ""
  };
  $("worktree-search").value = "";
  $("new-session-sheet").classList.remove("hidden");
  renderCreateSheet();
  requestCreateLists();
  requestAnimationFrame(() => $("worktree-search").focus());
}

function requestCreateLists() {
  send({ type: "listWorktrees" });
  send({ type: "listAgents" });
}

function reloadNewWorktreeCatalog() {
  if (worktreeCreation.snapshot().mode !== "new") return;
  worktreeCreation.reloadCatalog();
}

function startNewWorktree() {
  if (!worktreeCreation.startNewWorktree()) return;
  worktreeCreation.loadProjects();
  requestAnimationFrame(() => $("project-select").focus());
}

function hideCreateSheet(force) {
  const forced = force === true;
  const creationState = worktreeCreation.snapshot();
  const recoveryPending = creationState.outcomeUnknown && !worktreeCreation.canRetry();
  if (recoveryPending || ((createState.busy || creationState.submitting) && !forced)) return;
  createState.open = false;
  createState.busy = false;
  createState.error = "";
  $("new-session-sheet").classList.add("hidden");
  worktreeCreation.reset();
  if (forced) {
    deferredCreatePrompt = null;
  } else {
    replayDeferredCreatePrompt();
  }
}

function failCreateOnDisconnect() {
  const disconnectedWorktreeCreation = worktreeCreation.disconnect();
  if (!createState.open) return;
  if (disconnectedWorktreeCreation) return;
  const wasBusy = createState.busy;
  createState.busy = false;
  createState.error = wasBusy ? "Connection lost. Reconnect and try again." : "Connection lost. Reconnecting...";
  renderCreateSheet();
}

function visibleCreateWorktrees() {
  const query = createState.filter.trim().toLowerCase();
  if (!query) return createState.worktrees;
  return createState.worktrees.filter(w => [
    w.projectName,
    w.worktreeName,
    w.branch,
    w.path,
    w.comparisonRef
  ].some(value => String(value || "").toLowerCase().includes(query)));
}

function renderCreateSheet() {
  if (!createState.open) return;

  const creationState = worktreeCreation.snapshot();
  const isNewWorktree = creationState.mode === "new";
  const busy = createState.busy || creationState.submitting;
  const recoveryPending = creationState.outcomeUnknown && !worktreeCreation.canRetry();
  const inWorktreeStep = isNewWorktree ? creationState.step === "worktree" : createState.step === "worktree";
  $("worktree-step").classList.toggle("hidden", !inWorktreeStep);
  $("agent-step").classList.toggle("hidden", inWorktreeStep);
  $("existing-worktree-picker").classList.toggle("hidden", isNewWorktree);
  $("new-worktree-form").classList.toggle("hidden", !isNewWorktree);
  $("create-back").classList.toggle("hidden", inWorktreeStep && !isNewWorktree);
  $("create-back").disabled = busy || recoveryPending;
  $("create-cancel").disabled = busy || recoveryPending;
  $("worktree-search").disabled = busy;

  const error = $("create-error");
  const creationError = creationState.error && creationState.error.stage !== "branches"
    ? creationState.error
    : null;
  const errorMessage = creationError
    ? creationError.message
    : createState.error;
  error.textContent = errorMessage;
  error.classList.toggle("hidden", !errorMessage);

  renderCreateWorktrees(busy);
  renderNewWorktreeForm(creationState, busy);
  renderCreateAgents(creationState, isNewWorktree, busy);
  renderNewWorktreeReview(creationState, isNewWorktree && !inWorktreeStep);

  const next = $("create-next");
  const canProceed = isNewWorktree
    ? (inWorktreeStep ? worktreeCreation.canAdvance() : worktreeCreation.canSubmit())
    : (inWorktreeStep ? !!createState.selectedWorktreeId : !!createState.selectedWorktreeId && !!createState.selectedAgentId);
  next.disabled = busy || !canProceed;
  next.textContent = inWorktreeStep
    ? "Next"
    : (busy ? "Creating..." : (isNewWorktree ? "Create worktree and session" : "Create"));
}

function renderNewWorktreeForm(state, busy) {
  const projectSelect = $("project-select");
  projectSelect.innerHTML = "";
  const placeholder = document.createElement("option");
  placeholder.value = "";
  placeholder.disabled = true;
  placeholder.textContent = state.projectsLoading ? "Loading repositories..." : "Choose a repository";
  projectSelect.append(placeholder);
  state.projects.forEach(project => {
    const option = document.createElement("option");
    option.value = project.id;
    option.textContent = project.name || project.id;
    projectSelect.append(option);
  });
  projectSelect.value = state.projectId || "";
  projectSelect.disabled = busy || state.projectsLoading || state.projects.length === 0;
  $("project-guidance").textContent = state.projectsLoading
    ? "Loading repositories..."
    : (state.projects.length === 0 ? "No repositories are available." : "Choose the repository for the new worktree.");

  const baseSelect = $("base-select");
  baseSelect.innerHTML = "";
  const basePlaceholder = document.createElement("option");
  basePlaceholder.value = "";
  basePlaceholder.disabled = true;
  basePlaceholder.textContent = state.branchStatus === "loading" ? "Loading branches..." : "Choose a base branch";
  baseSelect.append(basePlaceholder);
  state.branches.forEach(branch => {
    const option = document.createElement("option");
    option.value = branch;
    option.textContent = branch;
    baseSelect.append(option);
  });
  baseSelect.value = state.base || "";
  baseSelect.disabled = busy || state.branchStatus !== "loaded";
  const branchStatus = $("branch-status");
  branchStatus.textContent = state.branchStatus === "loading"
    ? "Loading branches..."
    : (state.branchStatus === "failed" ? state.branchError || "Could not load branches."
      : (state.branchStatus === "loaded" ? "Choose the branch to base this worktree on." : "Choose a repository to load branches."));
  $("retry-branches").classList.toggle("hidden", state.branchStatus !== "failed");
  $("retry-branches").disabled = busy;

  const branchInput = $("new-branch");
  if (branchInput.value !== state.branch) branchInput.value = state.branch;
  branchInput.disabled = busy;
}

function renderNewWorktreeReview(state, visible) {
  const review = $("new-worktree-review");
  review.classList.toggle("hidden", !visible);
  review.innerHTML = "";
  if (!visible) return;
  const project = state.projects.find(candidate => candidate.id === state.projectId);
  review.append(el("strong", "", "Review"));
  review.append(el("div", "", project ? project.name || project.id : "Repository not selected"));
  review.append(el("div", "", state.base || "Base branch not selected"));
  review.append(el("div", "", state.branch || "New branch not entered"));
}

function renderCreateWorktrees(busy) {
  const list = $("worktree-list");
  list.innerHTML = "";
  const worktrees = visibleCreateWorktrees();
  if (worktrees.length === 0) {
    list.append(el("div", "create-empty", "No worktrees found."));
    return;
  }

  worktrees.forEach(worktree => {
    const row = el("button", "create-row");
    row.type = "button";
    row.disabled = busy;
    row.classList.toggle("is-selected", worktree.id === createState.selectedWorktreeId);
    row.setAttribute("aria-pressed", String(worktree.id === createState.selectedWorktreeId));
    row.onclick = () => {
      if (busy) return;
      createState.selectedWorktreeId = worktree.id;
      createState.error = "";
      renderCreateSheet();
    };
    row.append(el("div", "create-row-title", `${worktree.projectName} / ${worktree.worktreeName}`));
    if (worktree.path) row.append(el("div", "create-row-detail", worktree.path));
    const meta = createWorktreeMeta(worktree);
    if (meta.length) {
      const box = el("div", "create-row-meta");
      meta.forEach(part => box.append(el("span", "", part)));
      row.append(box);
    }
    list.append(row);
  });
}

function createWorktreeMeta(worktree) {
  if (!worktree.metricsAvailable) return ["changes unavailable"];

  const parts = [];
  if (worktree.branch) parts.push(worktree.branch);
  if (worktree.commitCount > 0) parts.push(plural(worktree.commitCount, "commit"));
  if (worktree.conflictCount > 0) parts.push(plural(worktree.conflictCount, "conflict"));
  if (worktree.changedFileCount > 0) parts.push(plural(worktree.changedFileCount, "file"));

  const line = [];
  if (worktree.addedLines > 0) line.push("+" + worktree.addedLines);
  if (worktree.deletedLines > 0) line.push("-" + worktree.deletedLines);
  if (line.length) parts.push(line.join(" / "));

  return parts.length ? parts : ["clean"];
}

function renderCreateAgents(creationState, isNewWorktree, busy) {
  const list = $("agent-list");
  list.innerHTML = "";
  if (createState.agents.length === 0) {
    list.append(el("div", "create-empty", "No agents available."));
    return;
  }

  createState.agents.forEach(agent => {
    const row = el("button", "create-row");
    row.type = "button";
    const selectedAgentId = isNewWorktree ? creationState.agentId : createState.selectedAgentId;
    row.disabled = busy;
    row.classList.toggle("is-selected", agent.id === selectedAgentId);
    row.setAttribute("aria-pressed", String(agent.id === selectedAgentId));
    row.onclick = () => {
      if (busy) return;
      if (isNewWorktree) {
        worktreeCreation.setAgent(agent.id);
      } else {
        createState.selectedAgentId = agent.id;
        createState.error = "";
        renderCreateSheet();
      }
    };
    row.append(el("div", "create-row-title", agent.name || agent.id));
    if (agent.isDefault) row.append(el("div", "create-row-detail", "Default agent"));
    list.append(row);
  });
}

function advanceCreateSheet() {
  const creationState = worktreeCreation.snapshot();
  if (createState.busy || creationState.submitting) return;
  if (creationState.mode === "new") {
    if (creationState.step === "worktree") worktreeCreation.next();
    else worktreeCreation.submit();
    return;
  }
  createState.error = "";

  if (createState.step === "worktree") {
    if (!createState.selectedWorktreeId) return;
    createState.step = "agent";
    renderCreateSheet();
    return;
  }

  if (!createState.selectedWorktreeId || !createState.selectedAgentId) return;
  createState.busy = true;
  renderCreateSheet();
  send({ type: "createSession", worktreeId: createState.selectedWorktreeId, agentId: createState.selectedAgentId });
}

function backCreateSheet() {
  const creationState = worktreeCreation.snapshot();
  if (createState.busy || creationState.submitting) return;
  if (creationState.mode === "new") {
    if (worktreeCreation.back() && worktreeCreation.snapshot().mode === "existing") {
      requestAnimationFrame(() => $("worktree-search").focus());
    }
    return;
  }
  createState.step = "worktree";
  createState.error = "";
  renderCreateSheet();
  requestAnimationFrame(() => $("worktree-search").focus());
}

function applyCreatedSession(session) {
  if (!session || !session.id) {
    createState.busy = false;
    createState.error = "Could not create session.";
    renderCreateSheet();
    return;
  }

  const previousSession = currentSession;
  hideCreateSheet(true);
  listedSessions.set(session.id, session);
  renderSessions([...listedSessions.values()]);
  if (previousSession && previousSession !== session.id) send({ type: "unsubscribe", sessionId: previousSession });
  openSession(session.id);
}

function applySnapshot(msg) {
  if (msg.sessionId !== currentSession) return;
  canDrive = msg.canDrive; canDriveKnown = true;
  transcriptMeta = { epoch: msg.epoch, revision: msg.revision, firstIndex: msg.firstIndex, totalCount: msg.totalCount };
  olderFetchInFlight = false;
  const box = $("messages");
  const open = new Set();
  box.querySelectorAll(".m-collapsible.is-open").forEach(d => { if (d.dataset.sid) open.add(d.dataset.sid); });
  box.innerHTML = "";
  messages = new Map(); messageNodes = new Map();
  msg.messages.forEach(m => insertMessage(m, open));
  requestAnimationFrame(() => { box.scrollTop = box.scrollHeight; });
  syncStreamingState(msg.streamingState);
}

function applyDelta(msg) {
  if (msg.sessionId !== currentSession || !transcriptMeta) return;
  // Epoch moved or a delta was missed → the server's view diverged; resync.
  if (msg.epoch !== transcriptMeta.epoch || msg.revision !== transcriptMeta.revision + 1) {
    resubscribe();
    return;
  }
  transcriptMeta.revision = msg.revision;
  canDrive = msg.canDrive; canDriveKnown = true;
  const box = $("messages");
  const atBottom = box.scrollTop + box.clientHeight >= box.scrollHeight - 120;
  msg.upserts.forEach(m => upsertMessage(m));
  if (atBottom) requestAnimationFrame(() => { box.scrollTop = box.scrollHeight; });
  syncStreamingState(msg.streamingState);
}

function applyQueueState(msg) {
  if (msg.sessionId !== currentSession) return;
  queueItems = msg.items || [];
  steerUndoAvailable = !!msg.steerUndoAvailable;
  renderQueue();
  renderDriveBar(lastStreamingState);
}

// Append rather than replace, mirroring the native pane's
// composerDraft.appending(restored) — the user may have started typing
// something else before tapping Edit, and that must not be clobbered.
function applyQueueEditRestored(msg) {
  if (msg.sessionId !== currentSession || !msg.text) return;
  const ta = $("prompt");
  ta.value = ta.value ? ta.value + "\n" + msg.text : msg.text;
  autoGrowPrompt();
  renderDriveBar(lastStreamingState);
  ta.focus();
}

// The server owns the snapshot and its expiry (ACPSession.steerUndo +
// ACPSessionRunner.armSteerUndoExpiry), so this is render-and-dispatch only:
// the toast disappears when the next queueState reports the window closed.
function steerUndoToast() {
  const toast = el("div", "steer-undo");
  toast.appendChild(el("span", null, "Queue cleared by steer"));
  const undo = el("button", "steer-undo-btn", "Undo");
  undo.onclick = () => queueAction("queueSteerUndo", null);
  toast.appendChild(undo);
  return toast;
}

let openQueuedId = null;   // which bubble has its actions revealed (tap-to-reveal)

function setQueuedOpen(id) {
  openQueuedId = openQueuedId === id ? null : id;
  renderQueue();
}

function queueAction(type, itemId) {
  if (!currentSession) return;
  ensureWriter();
  const msg = { type, sessionId: currentSession };
  if (itemId) msg.itemId = itemId;
  send(msg);
  openQueuedId = null;
}

function renderQueue() {
  const box = $("queued");
  box.innerHTML = "";
  // A .sending item stays in session.queue for the whole RPC round-trip
  // (flushQueueIfIdle marks the head .sending before sendNow records the
  // prompt into the transcript), but never gets its own bubble here —
  // mirroring native's ACPMessageList.shouldRenderQueueBubble, which also
  // returns false for .sending. Rendering it would double-show the same
  // text: once as the transcript's user bubble, once as a ghosted queued
  // one, for the entire duration of the turn.
  const visible = queueItems.filter(i => i.status !== "sending");
  box.classList.toggle("hidden", visible.length === 0 && !steerUndoAvailable);
  if (steerUndoAvailable) box.appendChild(steerUndoToast());
  if (visible.length === 0) return;

  const waiting = queueBadgeCount();
  if (waiting > 1) {
    const header = el("div", "queued-header");
    header.appendChild(el("span", null, waiting + " queued"));
    const clear = el("button", "queued-clear", "Clear queue");
    clear.onclick = () => queueAction("queueClear", null);
    header.appendChild(clear);
    box.appendChild(header);
  }

  visible.forEach(item => box.appendChild(queuedRow(item)));
}

// Only ever called with a `.pending` item — renderQueue() filters `.sending`
// out before it reaches here — so every row always gets its actions and its
// "Queued" status.
function queuedRow(item) {
  const row = el("div", "queued-row");
  if (openQueuedId === item.id) row.classList.add("is-open");

  row.appendChild(queuedActions(item));

  const stack = el("div", "queued-stack");
  const status = el("div", "queued-status");
  status.appendChild(el("span", null, "Queued"));
  if (item.lastError) status.appendChild(el("span", "queued-error", " · " + item.lastError));
  stack.appendChild(status);

  const bubble = el("div", "queued-bubble");
  if (item.imageCount > 0) {
    bubble.appendChild(el("span", "queued-images", "🖼 ×" + item.imageCount));
  }
  if (item.resourceCount > 0) {
    bubble.appendChild(el("span", "queued-resources", "📎 ×" + item.resourceCount));
  }
  bubble.appendChild(document.createTextNode(item.text || ""));
  bubble.onclick = () => setQueuedOpen(item.id);
  stack.appendChild(bubble);

  row.appendChild(stack);
  return row;
}

function queuedActions(item) {
  const actions = el("div", "queued-actions");
  const button = (cls, glyph, label, onclick) => {
    const b = el("button", cls, glyph);
    b.setAttribute("aria-label", label);
    b.onclick = onclick;
    return b;
  };
  actions.appendChild(button("qa-send", "▲", "Send now",
    () => queueAction("queueForceSend", item.id)));
  if (item.lastError) {
    actions.appendChild(button("qa-retry", "↻", "Retry",
      () => queueAction("queueRetry", item.id)));
  }
  // Editing an item whose images or file mentions the web client never
  // received would silently drop them, so the pencil is withheld rather
  // than made lossy.
  if (item.imageCount === 0 && item.resourceCount === 0) {
    actions.appendChild(button("qa-edit", "✎", "Edit",
      () => queueAction("queueEdit", item.id)));
  }
  actions.appendChild(button("qa-remove", "✕", "Remove from queue",
    () => queueAction("queueRemove", item.id)));
  return actions;
}

function applyPage(msg) {
  // Check the session BEFORE touching shared in-flight state: these globals
  // track the CURRENT session only, so a stale page for a session the user
  // already left must not clear (or otherwise affect) whatever the current
  // session's own in-flight backfill is doing.
  if (msg.sessionId !== currentSession || !transcriptMeta) return;
  olderFetchInFlight = false;
  removeLoadingRow();
  if (msg.epoch !== transcriptMeta.epoch) return;   // stale page; a resync snapshot is coming
  const box = $("messages");
  const prevHeight = box.scrollHeight;
  // Pages arrive oldest-first; insert in reverse so each lands at the front.
  [...msg.messages].reverse().forEach(m => { if (!messages.has(m.stableId)) insertMessage(m, null); });
  transcriptMeta.firstIndex = Math.min(transcriptMeta.firstIndex, msg.firstIndex);
  box.scrollTop += box.scrollHeight - prevHeight;   // keep the viewport anchored
}

function resubscribe() {
  if (currentSession) send({ type: "subscribe", sessionId: currentSession });
}

// Insert a message node at its index-ordered DOM position. Nodes carry
// dataset.index; the common case (append at the tail) is O(1).
function insertMessage(m, open) {
  const box = $("messages");
  const node = renderMessage(m, m.stableId, open);
  node.dataset.sid = m.stableId;
  node.dataset.index = m.index;
  messages.set(m.stableId, m);
  messageNodes.set(m.stableId, node);
  let anchor = box.lastElementChild;
  while (anchor && Number(anchor.dataset.index) > m.index) anchor = anchor.previousElementSibling;
  if (anchor) anchor.after(node); else box.prepend(node);
}

function upsertMessage(m) {
  const existing = messageNodes.get(m.stableId);
  if (existing) {
    const wasOpen = existing.classList.contains("is-open") ? new Set([m.stableId]) : null;
    const node = renderMessage(m, m.stableId, wasOpen);
    node.dataset.sid = m.stableId;
    node.dataset.index = m.index;
    existing.replaceWith(node);
    messages.set(m.stableId, m);
    messageNodes.set(m.stableId, node);
    return;
  }
  // A message older than the loaded window (rare late mutation): skip —
  // it will arrive if the user backfills that far.
  if (transcriptMeta && m.index < transcriptMeta.firstIndex) return;
  insertMessage(m, null);
}

function el(tag, cls, text) { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; }
function jparse(s) { try { return JSON.parse(s); } catch { return null; } }

function linkifyBareUrls(text) {
  if (!text || (!text.includes("http://") && !text.includes("https://"))) return text || "";
  return rewriteMarkdownBareUrls(text, true);
}

function rewriteMarkdownBareUrls(text, preserveFencedCodeBlocks) {
  if (!preserveFencedCodeBlocks) return rewriteInlineBareUrls(text);

  let out = "";
  let lineStart = 0;
  let openingFence = null;
  let openingHtmlBlockTag = null;
  let allowsIndentedCodeBlock = true;
  let referenceDefinitionContinuation = null;
  const inlineState = {
    codeSpanDelimiterLength: null,
    referenceLabels: markdownReferenceLabels(text),
  };

  while (lineStart < text.length) {
    const newline = text.indexOf("\n", lineStart);
    const lineEnd = newline === -1 ? text.length : newline + 1;
    const line = text.slice(lineStart, lineEnd);

    if (openingFence) {
      out += line;
      const closingFence = closingCodeFenceDelimiter(line);
      const closedFence = closingFence && closesCodeFence(closingFence, openingFence);
      if (closedFence) openingFence = null;
      allowsIndentedCodeBlock = !!closedFence;
    } else if (openingHtmlBlockTag) {
      out += line;
      const closedHtmlBlock = closingRawHtmlBlockTag(line, openingHtmlBlockTag) ||
        rawHtmlBlockEndsAtBlankLine(line, openingHtmlBlockTag);
      if (closedHtmlBlock) openingHtmlBlockTag = null;
      allowsIndentedCodeBlock = closedHtmlBlock;
    } else if (inlineState.codeSpanDelimiterLength == null &&
               referenceDefinitionContinuation === "destination" &&
               markdownReferenceDefinitionDestinationContinuationLine(line)) {
      out += line;
      referenceDefinitionContinuation = "title";
      allowsIndentedCodeBlock = false;
    } else if (inlineState.codeSpanDelimiterLength == null &&
               referenceDefinitionContinuation === "title" &&
               markdownReferenceDefinitionTitleContinuationLine(line)) {
      out += line;
      referenceDefinitionContinuation = null;
      allowsIndentedCodeBlock = false;
    } else if (inlineState.codeSpanDelimiterLength == null) {
      const referenceDefinition = markdownReferenceDefinition(line);
      if (referenceDefinition) {
        out += line;
        referenceDefinitionContinuation = referenceDefinition.hasDestination ? "title" : "destination";
        allowsIndentedCodeBlock = false;
      } else {
        referenceDefinitionContinuation = null;
        const lineFence = openingCodeFenceDelimiter(line);
        if (lineFence) {
          out += line;
          openingFence = lineFence;
          allowsIndentedCodeBlock = false;
        } else {
          const htmlBlockTag = openingRawHtmlBlockTag(line);
          if (htmlBlockTag) {
            out += line;
            if (!closingRawHtmlBlockTag(line, htmlBlockTag)) openingHtmlBlockTag = htmlBlockTag;
            allowsIndentedCodeBlock = !openingHtmlBlockTag;
          } else if (allowsIndentedCodeBlock && markdownIndentedCodeBlockLine(line)) {
            out += line;
            allowsIndentedCodeBlock = true;
          } else {
            out += rewriteInlineBareUrls(line, inlineState, text, lineEnd);
            allowsIndentedCodeBlock = markdownAllowsIndentedCodeBlockAfterLine(line);
          }
        }
      }
    } else {
      out += rewriteInlineBareUrls(line, inlineState, text, lineEnd);
      allowsIndentedCodeBlock = markdownAllowsIndentedCodeBlockAfterLine(line);
    }

    lineStart = lineEnd;
  }

  return out;
}

function rewriteInlineBareUrls(text, state, remainingTextSource, remainingTextStart) {
  const inlineState = state || { codeSpanDelimiterLength: null };
  let out = "";
  let i = 0;

  while (i < text.length) {
    if (inlineState.codeSpanDelimiterLength != null) {
      if (text[i] === "`") {
        const closingLength = repeatedCharacterRunLength(text, i, "`");
        if (closingLength === inlineState.codeSpanDelimiterLength) {
          out += text.slice(i, i + closingLength);
          i += closingLength;
          inlineState.codeSpanDelimiterLength = null;
          continue;
        }
      }

      out += text[i];
      i += 1;
      continue;
    }

    if (text[i] === "`") {
      const delimiterLength = repeatedCharacterRunLength(text, i, "`");
      if (isFenceLikeBacktickDelimiterLine(text, i, delimiterLength)) {
        out += text.slice(i, i + delimiterLength);
        i += delimiterLength;
        continue;
      }

      const end = codeSpanEnd(text, i);
      if (end !== -1) {
        out += text.slice(i, end + 1);
        i = end + 1;
        continue;
      }

      out += text.slice(i, i + delimiterLength);
      i += delimiterLength;
      const remainingTextAfterSegment = remainingTextSource == null ? text.slice(i) : remainingTextSource.slice(remainingTextStart);
      if (hasCodeSpanEnd(remainingTextAfterSegment, delimiterLength)) {
        inlineState.codeSpanDelimiterLength = delimiterLength;
      }
      continue;
    }

    if (text[i] === "<" && startsWithWebScheme(text, i + 1)) {
      const end = text.indexOf(">", i + 1);
      if (end !== -1) {
        out += text.slice(i, end + 1);
        i = end + 1;
        continue;
      }
    }

    if (text[i] === "<") {
      const end = rawHtmlTagEnd(text, i);
      if (end !== -1) {
        out += text.slice(i, end + 1);
        i = end + 1;
        continue;
      }
    }

    if (text[i] === "[") {
      const end = markdownBracketedLinkEnd(text, i, inlineState.referenceLabels);
      if (end !== -1) {
        out += text.slice(i, end + 1);
        i = end + 1;
        continue;
      }
    }

    if (startsWithWebScheme(text, i) && hasValidBoundaryBefore(text, i)) {
      const rawEnd = rawUrlEnd(text, i);
      const trimmedEnd = trimmedUrlEnd(text, i, rawEnd);
      if (trimmedEnd > i) {
        const urlText = text.slice(i, trimmedEnd);
        if (isValidBareWebURL(urlText)) {
          out += "<" + urlText + ">";
          out += text.slice(trimmedEnd, rawEnd);
          i = rawEnd;
          continue;
        }
      }
    }

    out += text[i];
    i += 1;
  }

  return out;
}

function openingCodeFenceDelimiter(line) {
  return codeFenceDelimiter(line, true);
}

function closingCodeFenceDelimiter(line) {
  return codeFenceDelimiter(line, false);
}

function codeFenceDelimiter(line, allowsTrailingText) {
  let contentEnd = line.length;
  while (contentEnd > 0 && /\s/.test(line[contentEnd - 1])) contentEnd -= 1;

  let i = 0;
  let leadingSpaces = 0;
  while (i < contentEnd && line[i] === " ") {
    leadingSpaces += 1;
    i += 1;
  }
  if (leadingSpaces > 3 || i >= contentEnd) return null;

  const marker = line[i];
  if (marker !== "`" && marker !== "~") return null;

  const length = repeatedCharacterRunLength(line, i, marker);
  i += length;

  if (!allowsTrailingText && i !== contentEnd) return null;
  if (marker === "`" && line.slice(i, contentEnd).includes("`")) return null;
  return length >= 3 ? { marker, length } : null;
}

function closesCodeFence(candidate, openingFence) {
  return candidate.marker === openingFence.marker && candidate.length >= openingFence.length;
}

function markdownBlankLine(line) {
  return /^[\s]*$/.test(line);
}

function markdownAllowsIndentedCodeBlockAfterLine(line) {
  return markdownBlankLine(line) || markdownAtxHeadingLine(line) || markdownThematicBreakLine(line);
}

function markdownAtxHeadingLine(line) {
  let i = 0;
  let leadingSpaces = 0;
  while (i < line.length && line[i] === " ") {
    leadingSpaces += 1;
    if (leadingSpaces > 3) return false;
    i += 1;
  }

  let markerCount = 0;
  while (i < line.length && line[i] === "#" && markerCount < 6) {
    markerCount += 1;
    i += 1;
  }
  if (markerCount === 0) return false;
  if (i >= line.length) return true;
  return /\s/.test(line[i]);
}

function markdownThematicBreakLine(line) {
  let i = 0;
  let leadingSpaces = 0;
  while (i < line.length && line[i] === " ") {
    leadingSpaces += 1;
    if (leadingSpaces > 3) return false;
    i += 1;
  }

  let marker = null;
  let markerCount = 0;
  while (i < line.length) {
    const ch = line[i];
    if (ch === "\n" || ch === "\r") break;
    if (ch === " " || ch === "\t") {
      i += 1;
      continue;
    }
    if (marker === null) {
      if (ch !== "-" && ch !== "_" && ch !== "*") return false;
      marker = ch;
    }
    if (ch !== marker) return false;
    markerCount += 1;
    i += 1;
  }

  return markerCount >= 3;
}

function markdownIndentedCodeBlockLine(line) {
  let leadingSpaces = 0;
  for (let i = 0; i < line.length; i += 1) {
    if (line[i] === "\t") return true;
    if (line[i] !== " ") return false;
    leadingSpaces += 1;
    if (leadingSpaces >= 4) return true;
  }
  return false;
}

const rawHtmlBlockTags = new Set([
  "address", "article", "aside", "base", "basefont", "blockquote", "body",
  "caption", "center", "col", "colgroup", "dd", "details", "dialog", "dir",
  "div", "dl", "dt", "fieldset", "figcaption", "figure", "footer", "form",
  "frame", "frameset", "h1", "h2", "h3", "h4", "h5", "h6", "head", "header",
  "hr", "html", "iframe", "legend", "li", "link", "main", "menu", "menuitem",
  "nav", "noframes", "ol", "optgroup", "option", "p", "param", "section",
  "summary", "table", "tbody", "td", "tfoot", "th", "thead", "title", "tr",
  "track", "ul", "pre", "script", "style",
]);

const rawHtmlVoidBlockTags = new Set([
  "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta",
  "param", "source", "track", "wbr",
]);

const rawHtmlExplicitCloseBlockTags = new Set(["pre", "script", "style"]);

function openingRawHtmlBlockTag(line) {
  let i = 0;
  let leadingSpaces = 0;
  while (i < line.length && line[i] === " ") {
    leadingSpaces += 1;
    i += 1;
  }
  if (leadingSpaces > 3 || line[i] !== "<") return null;

  const rest = line.slice(i);
  if (rest.startsWith("<!--")) return "#comment";
  if (rest.startsWith("<?")) return "#processing-instruction";
  if (rest.startsWith("<![CDATA[")) return "#cdata";
  if (/^<![A-Z]/.test(rest)) return "#declaration";

  const match = rest.match(/^<([A-Za-z][A-Za-z0-9-]*)(?:\s|>|\/>)/);
  if (!match) return null;

  const tag = match[1].toLowerCase();
  if (!rawHtmlBlockTags.has(tag) || rawHtmlVoidBlockTags.has(tag)) return null;
  return tag;
}

function rawHtmlBlockEndsAtBlankLine(line, tag) {
  return !tag.startsWith("#") && !rawHtmlExplicitCloseBlockTags.has(tag) && markdownBlankLine(line);
}

function closingRawHtmlBlockTag(line, tag) {
  if (tag === "#comment") return line.includes("-->");
  if (tag === "#processing-instruction") return line.includes("?>");
  if (tag === "#cdata") return line.includes("]]>");
  if (tag === "#declaration") return line.includes(">");
  return new RegExp("</\\s*" + escapeRegExp(tag) + "\\s*>", "i").test(line);
}

function escapeRegExp(text) {
  return text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function repeatedCharacterRunLength(text, start, character) {
  let count = 0;
  let i = start;
  while (i < text.length && text[i] === character) {
    count += 1;
    i += 1;
  }
  return count;
}

function isFenceLikeBacktickDelimiterLine(text, start, delimiterLength) {
  if (delimiterLength < 3) return false;

  let lineStart = start;
  while (lineStart > 0 && text[lineStart - 1] !== "\n") lineStart -= 1;
  for (let i = lineStart; i < start; i += 1) {
    if (text[i] !== " ") return false;
  }

  let lineEnd = start;
  while (lineEnd < text.length && text[lineEnd] !== "\n") lineEnd += 1;
  return !text.slice(start + delimiterLength, lineEnd).includes("`");
}

function codeSpanEnd(text, start) {
  const delimiterLength = repeatedCharacterRunLength(text, start, "`");
  let i = start + delimiterLength;
  let currentLineIsBlank = false;

  while (i < text.length) {
    const ch = text[i];
    if (ch === "\n") {
      if (currentLineIsBlank) return -1;
      currentLineIsBlank = true;
      i += 1;
    } else if (/\s/.test(ch)) {
      i += 1;
    } else if (ch === "`") {
      currentLineIsBlank = false;
      const closingLength = repeatedCharacterRunLength(text, i, "`");
      if (closingLength === delimiterLength) return i + closingLength - 1;
      i += closingLength;
    } else {
      currentLineIsBlank = false;
      i += 1;
    }
  }

  return -1;
}

function hasCodeSpanEnd(text, delimiterLength) {
  let i = 0;
  let currentLineIsBlank = true;

  while (i < text.length) {
    const ch = text[i];
    if (ch === "\n") {
      if (currentLineIsBlank) return false;
      currentLineIsBlank = true;
      i += 1;
    } else if (/\s/.test(ch)) {
      i += 1;
    } else if (ch === "`") {
      currentLineIsBlank = false;
      const closingLength = repeatedCharacterRunLength(text, i, "`");
      if (closingLength === delimiterLength) return true;
      i += closingLength;
    } else {
      currentLineIsBlank = false;
      i += 1;
    }
  }

  return false;
}

function rawHtmlTagEnd(text, start) {
  if (!isRawHtmlTagStart(text, start)) return -1;

  let quote = null;
  for (let i = start + 1; i < text.length; i += 1) {
    const ch = text[i];
    if (quote) {
      if (ch === quote) quote = null;
    } else if (ch === "\"" || ch === "'") {
      quote = ch;
    } else if (ch === ">") {
      return i;
    }
  }

  return -1;
}

function isRawHtmlTagStart(text, start) {
  if (start >= text.length || text[start] !== "<" || start + 1 >= text.length) return false;
  const next = text[start + 1];
  return /[A-Za-z!/]/.test(next) || next === "?";
}

function startsWithWebScheme(text, i) {
  return text.startsWith("https://", i) || text.startsWith("http://", i);
}

function hasValidBoundaryBefore(text, i) {
  if (i === 0) return true;
  const previous = text[i - 1];
  if (/[*_~]/.test(previous)) {
    let delimiterRunStart = i - 1;
    while (delimiterRunStart > 0 && text[delimiterRunStart - 1] === previous) delimiterRunStart -= 1;
    if (delimiterRunStart === 0) return true;
    return /\s|[\(\[\{"']/.test(text[delimiterRunStart - 1]);
  }
  return /\s|[\(\[\{"']/.test(previous);
}

function rawUrlEnd(text, start) {
  let i = start;
  while (i < text.length && !/[\s<>\x00-\x1F\x7F]/.test(text[i])) {
    if (text[i] === "]" && text[i + 1] === "[") break;
    i += 1;
  }
  return i;
}

function trimmedUrlEnd(text, start, rawEnd) {
  let end = rawEnd;
  const surplusClosings = unbalancedClosingSurplus(text, start, rawEnd);
  const emphasisDelimiterRun = markdownEmphasisDelimiterRunBeforeUrlStart(text, start);
  let remainingEmphasisDelimitersToTrim = emphasisDelimiterRun ? emphasisDelimiterRun.length : 0;
  while (end > start) {
    const ch = text[end - 1];
    if (emphasisDelimiterRun &&
        remainingEmphasisDelimitersToTrim > 0 &&
        ch === emphasisDelimiterRun.delimiter) {
      remainingEmphasisDelimitersToTrim -= 1;
      end -= 1;
      continue;
    }
    if (".,;:!?\"'".includes(ch)) {
      end -= 1;
      continue;
    }
    if (surplusClosings[ch] > 0) {
      surplusClosings[ch] -= 1;
      end -= 1;
      continue;
    }
    break;
  }
  return end;
}

function markdownEmphasisDelimiterRunBeforeUrlStart(text, start) {
  if (start === 0) return null;
  const delimiter = text[start - 1];
  if (!/[*_~]/.test(delimiter)) return null;
  let length = 1;
  for (let i = start - 2; i >= 0 && text[i] === delimiter; i -= 1) length += 1;
  return { delimiter, length };
}

function unbalancedClosingSurplus(text, start, end) {
  const counts = {
    "(": 0, ")": 0,
    "[": 0, "]": 0,
    "{": 0, "}": 0,
    "<": 0, ">": 0,
  };
  for (let i = start; i < end; i += 1) {
    if (counts[text[i]] != null) counts[text[i]] += 1;
  }
  return {
    ")": Math.max(0, counts[")"] - counts["("]),
    "]": Math.max(0, counts["]"] - counts["["]),
    "}": Math.max(0, counts["}"] - counts["{"]),
    ">": Math.max(0, counts[">"] - counts["<"]),
  };
}

function isValidBareWebURL(text) {
  let hostStart;
  if (text.startsWith("https://")) {
    hostStart = "https://".length;
  } else if (text.startsWith("http://")) {
    hostStart = "http://".length;
  } else {
    return false;
  }

  if (hostStart >= text.length) return false;
  let hostEnd = text.length;
  for (const marker of ["/", "?", "#"]) {
    const markerIndex = text.indexOf(marker, hostStart);
    if (markerIndex !== -1) hostEnd = Math.min(hostEnd, markerIndex);
  }
  return /[A-Za-z0-9]/.test(text.slice(hostStart, hostEnd));
}

function markdownBracketedLinkEnd(text, start, referenceLabels) {
  const labelEnd = markdownLabelEnd(text, start);
  if (labelEnd === -1) return -1;

  const label = normalizeMarkdownReferenceLabel(text.slice(start + 1, labelEnd));
  if (referenceLabels && referenceLabels.has(label)) return labelEnd;

  const next = labelEnd + 1;
  if (next >= text.length || text.slice(next).trim() === "") {
    return referenceLabels && referenceLabels.has(label) ? labelEnd : -1;
  }

  if (text[next] === "(") {
    const destinationEnd = markdownDestinationEnd(text, next);
    if (destinationEnd !== -1) return destinationEnd;
  }

  if (text[next] === "[") {
    const referenceEnd = markdownLabelEnd(text, next);
    if (referenceEnd !== -1) {
      const referenceLabel = text.slice(next + 1, referenceEnd);
      const normalizedReference = normalizeMarkdownReferenceLabel(referenceLabel) || label;
      return referenceLabels && referenceLabels.has(normalizedReference) ? referenceEnd : -1;
    }
  }

  return -1;
}

function markdownReferenceLabels(text) {
  const labels = new Set();
  let lineStart = 0;
  let openingFence = null;
  let openingHtmlBlockTag = null;
  let pendingDefinitionLabel = null;

  while (lineStart < text.length) {
    const newline = text.indexOf("\n", lineStart);
    const lineEnd = newline === -1 ? text.length : newline + 1;
    const line = text.slice(lineStart, lineEnd);

    if (openingFence) {
      const closingFence = closingCodeFenceDelimiter(line);
      if (closingFence && closesCodeFence(closingFence, openingFence)) openingFence = null;
    } else if (openingHtmlBlockTag) {
      if (closingRawHtmlBlockTag(line, openingHtmlBlockTag) ||
          rawHtmlBlockEndsAtBlankLine(line, openingHtmlBlockTag)) {
        openingHtmlBlockTag = null;
      }
    } else if (pendingDefinitionLabel !== null) {
      if (markdownReferenceDefinitionDestinationContinuationLine(line)) {
        labels.add(normalizeMarkdownReferenceLabel(pendingDefinitionLabel));
      }
      pendingDefinitionLabel = null;
    } else {
      const lineFence = openingCodeFenceDelimiter(line);
      if (lineFence) {
        openingFence = lineFence;
      } else {
        const htmlBlockTag = openingRawHtmlBlockTag(line);
        if (htmlBlockTag) {
          if (!closingRawHtmlBlockTag(line, htmlBlockTag)) openingHtmlBlockTag = htmlBlockTag;
          lineStart = lineEnd;
          continue;
        }

        const definition = markdownReferenceDefinition(line);
        if (definition) {
          if (definition.hasDestination) {
            labels.add(normalizeMarkdownReferenceLabel(definition.label));
          } else {
            pendingDefinitionLabel = definition.label;
          }
        }
      }
    }

    lineStart = lineEnd;
  }

  return labels;
}

function markdownReferenceDefinitionLabel(line) {
  const definition = markdownReferenceDefinition(line);
  return definition ? definition.label : null;
}

function markdownReferenceDefinition(line) {
  let i = 0;
  let leadingSpaces = 0;
  while (i < line.length && line[i] === " ") {
    leadingSpaces += 1;
    i += 1;
  }
  if (leadingSpaces > 3 || line[i] !== "[") return null;

  const labelEnd = markdownLabelEnd(line, i);
  if (labelEnd === -1 || line[labelEnd + 1] !== ":") return null;

  const label = line.slice(i + 1, labelEnd);
  if (!normalizeMarkdownReferenceLabel(label)) return null;

  const afterColon = line.slice(labelEnd + 2).trim();
  if (afterColon.length === 0) return { label, hasDestination: false };
  if (!markdownReferenceDefinitionDestinationContent(afterColon)) return null;
  return { label, hasDestination: true };
}

function markdownReferenceDefinitionDestinationContinuationLine(line) {
  return markdownReferenceDefinitionDestinationContent(line.trim());
}

function markdownReferenceDefinitionTitleContinuationLine(line) {
  const content = indentedReferenceDefinitionContinuationContent(line);
  if (content === null) return false;

  return markdownReferenceDefinitionTitleContent(content.trim());
}

function markdownReferenceDefinitionDestinationContent(content) {
  if (!content) return false;

  let i = 0;
  if (content[i] === "<") {
    i += 1;
    let isEscaped = false;
    while (i < content.length) {
      const ch = content[i];
      if (isEscaped) {
        isEscaped = false;
      } else if (ch === "\\") {
        isEscaped = true;
      } else if (ch === ">") {
        const rest = content.slice(i + 1).trim();
        return rest.length === 0 || markdownReferenceDefinitionTitleContent(rest);
      } else if (ch === "\n" || ch === "\r") {
        return false;
      }
      i += 1;
    }
    return false;
  }

  while (i < content.length && !/\s/.test(content[i])) i += 1;
  if (i === 0) return false;

  const rest = content.slice(i).trim();
  return rest.length === 0 || markdownReferenceDefinitionTitleContent(rest);
}

function markdownReferenceDefinitionTitleContent(content) {
  if (!content) return false;

  const opener = content[0];
  const closer = opener === "(" ? ")" : opener;
  if (opener !== "\"" && opener !== "'" && opener !== "(") return false;

  let isEscaped = false;
  for (let j = 1; j < content.length; j += 1) {
    const ch = content[j];
    if (isEscaped) {
      isEscaped = false;
    } else if (ch === "\\") {
      isEscaped = true;
    } else if (ch === closer) {
      return j === content.length - 1;
    }
  }

  return false;
}

function indentedReferenceDefinitionContinuationContent(line) {
  let contentEnd = line.length;
  while (contentEnd > 0 && /\s/.test(line[contentEnd - 1])) contentEnd -= 1;

  let i = 0;
  let leadingWhitespace = 0;
  while (i < contentEnd && (line[i] === " " || line[i] === "\t")) {
    leadingWhitespace += 1;
    i += 1;
  }
  if (leadingWhitespace === 0 || i >= contentEnd) return null;
  return line.slice(i, contentEnd);
}

function normalizeMarkdownReferenceLabel(label) {
  return label.trim().replace(/\s+/g, " ").toLowerCase();
}

function markdownLabelEnd(text, start) {
  if (start >= text.length || text[start] !== "[") return -1;

  let depth = 0;
  let isEscaped = false;
  for (let i = start; i < text.length; i += 1) {
    const ch = text[i];
    if (isEscaped) {
      isEscaped = false;
    } else if (ch === "\\") {
      isEscaped = true;
    } else if (ch === "[") {
      depth += 1;
    } else if (ch === "]") {
      depth -= 1;
      if (depth === 0) return i;
    }
  }

  return -1;
}

function markdownDestinationEnd(text, start) {
  if (start >= text.length || text[start] !== "(") return -1;

  let depth = 1;
  let isEscaped = false;
  let quote = null;
  let isAngleBracketDestination = false;
  let hasDestinationContent = false;
  let canStartTitleQuote = false;

  for (let i = start + 1; i < text.length; i += 1) {
    const ch = text[i];
    if (isEscaped) {
      isEscaped = false;
    } else if (ch === "\\") {
      isEscaped = true;
    } else if (quote) {
      if (ch === quote) quote = null;
    } else if (isAngleBracketDestination) {
      if (ch === ">") isAngleBracketDestination = false;
      hasDestinationContent = true;
      canStartTitleQuote = false;
    } else if (canStartTitleQuote && (ch === "\"" || ch === "'")) {
      quote = ch;
      canStartTitleQuote = false;
    } else if (ch === "<" && !hasDestinationContent && depth === 1) {
      isAngleBracketDestination = true;
      hasDestinationContent = true;
      canStartTitleQuote = false;
    } else if (ch === "(") {
      depth += 1;
      hasDestinationContent = true;
      canStartTitleQuote = false;
    } else if (ch === ")") {
      depth -= 1;
      if (depth === 0) return i;
      hasDestinationContent = true;
      canStartTitleQuote = false;
    } else if (/\s/.test(ch)) {
      if (hasDestinationContent && depth === 1) canStartTitleQuote = true;
    } else {
      if (canStartTitleQuote) return -1;
      hasDestinationContent = true;
      canStartTitleQuote = false;
    }
  }

  return -1;
}

// Render markdown to sanitized HTML (agent/user prose is untrusted — DOMPurify
// strips any script/event-handler injection). Falls back to escaped plain text
// if the libraries didn't load.
function md(text) {
  if (typeof marked === "undefined" || typeof DOMPurify === "undefined") {
    const d = document.createElement("div"); d.textContent = text || ""; return d.innerHTML;
  }
  return DOMPurify.sanitize(marked.parse(linkifyBareUrls(text), { gfm: true, breaks: true }));
}
function cap(s) { return s ? s.charAt(0).toUpperCase() + s.slice(1) : s; }

const TOOL_VERB = { read: "Read", search: "Searched", execute: "Ran", run: "Ran", edit: "Edit" };
const TOOL_STATUS = { completed: ["✓", "ok"], failed: ["✕", "err"], in_progress: ["•", "run"], pending: ["•", "run"], canceled: ["■", "run"], cancelled: ["■", "run"] };

// Mirrors the native ACP pane: plain agent prose, accent user bubbles, a
// collapsed "Thinking…" row, and collapsed tool/structured cards.
function renderMessage(m, sid, open) {
  let node;
  if (m.kind === "user" || m.kind === "agent") {
    node = el("div", "msg md m-" + m.kind);
    node.innerHTML = md(m.text);            // markdown-rendered like the native pane
  } else if (m.kind === "systemNotice") {
    node = el("div", "msg m-systemNotice", m.text || "");
  } else if (m.kind === "thought") {
    node = thoughtCard(m.text || "");
  } else if (m.kind === "toolCall") {
    node = toolCard(jparse(m.json) || {});
  } else if (m.kind === "fileEdit") {
    const o = jparse(m.json) || {};
    node = structCard("Edit", o.path || o.title || "file", o.diff || o.content || m.json || "");
  } else if (m.kind === "plan") {
    node = structCard("Plan", "", planText(jparse(m.json)) || m.json || "");
  } else {
    node = el("div", "msg m-agent", m.text || "");
  }
  if (node.classList?.contains("m-collapsible")) {            // restore prior expand state
    node.dataset.sid = sid;
    if (open && open.has(sid)) setCardOpen(node, true);
  }
  return node;
}

function thoughtCard(text) {
  const d = el("div", "msg m-thought m-collapsible");
  const button = el("button", "thought-toggle", "Thinking…");
  button.type = "button";
  button.dataset.cardToggle = "true";
  button.setAttribute("aria-expanded", "false");
  const body = el("div", "thought-body", text);
  body.dataset.cardBody = "true";
  body.hidden = true;
  button.onclick = () => setCardOpen(d, !d.classList.contains("is-open"));
  d.append(button, body);
  return d;
}

function toolCard(tc) {
  const verb = TOOL_VERB[tc.kind] || (tc.kind ? cap(tc.kind) : "Tool");
  const name = toolDisplayName(tc, verb);
  const card = structCard(verb, name, toolBody(tc), tc.preview || toolCollapsedPreview(tc));
  const [ch, scls] = TOOL_STATUS[tc.status] || [tc.status || "", "run"];
  card.querySelector(".tool-chev").insertAdjacentElement("beforebegin", el("span", "tool-status " + scls, ch));
  return card;
}

function toolBody(tc) {
  const rows = toolMetadataRows(tc);
  if (typeof tc.content === "string" && tc.content) {
    return rows.length ? rows.map(([key, value]) => `${key}: ${value}`).join("\n") + "\n\n" + tc.content : tc.content;
  }
  if (!rows.length) {
    if (tc.status === "in_progress" || tc.status === "pending") return "Working…";
    if (tc.status === "canceled" || tc.status === "cancelled") return "Canceled.";
    return "Tool invoked.";
  }
  return rows.map(([key, value]) => `${key}: ${value}`).join("\n");
}

function toolDisplayName(tc, verb) {
  const candidates = [
    tc.title,
    Array.isArray(tc.locations) ? tc.locations[0] : "",
    tc.toolCallId
  ];
  const name = candidates.find(v => typeof v === "string" && v.trim().length > 0) || "";
  return name.toLowerCase() !== verb.toLowerCase() ? name : "";
}

function toolCollapsedPreview(tc) {
  const rows = toolMetadataRows(tc);
  const priority = ["rawInput", "params", "input", "arguments", "locations", "toolCallId"];
  for (const key of priority) {
    const row = rows.find(([k]) => k === key);
    if (row) return `${row[0]}: ${singleLine(row[1])}`;
  }
  if (tc.status === "in_progress" || tc.status === "pending") return "Working…";
  if (tc.status === "completed") return "Completed";
  if (tc.status === "failed") return "Failed";
  if (tc.status === "canceled" || tc.status === "cancelled") return "Canceled";
  return "Tool executed";
}

function toolMetadataRows(tc) {
  return [
    ["toolCallId", tc.toolCallId],
    ["title", tc.title],
    ["kind", tc.kind],
    ["status", tc.status],
    ["preview", tc.preview],
    ["rawInput", valuePreview(tc.rawInput)],
    ["params", valuePreview(tc.params)],
    ["input", valuePreview(tc.input)],
    ["arguments", valuePreview(tc.arguments)],
    ["rawOutput", valuePreview(tc.rawOutput)],
    ["locations", Array.isArray(tc.locations) ? tc.locations.join("\n") : ""],
    ["terminalIds", Array.isArray(tc.terminalIds) ? tc.terminalIds.join("\n") : ""]
  ].filter(([, value]) => typeof value === "string" && value.length > 0);
}

function valuePreview(value) {
  if (value === null || value === undefined) return "";
  if (typeof value === "string") return value;
  try { return JSON.stringify(value, null, 2); } catch { return String(value); }
}

function singleLine(value) {
  return (value || "").replace(/\s+/g, " ").trim();
}

function handleCardToggleKeydown(event) {
  if (event.key !== "Enter" && event.key !== " ") return;
  event.preventDefault();
  const card = event.currentTarget.closest(".m-collapsible");
  if (card) setCardOpen(card, !card.classList.contains("is-open"));
}

function toolGlyph(verb) {
  const v = (verb || "").toLowerCase();
  if (v === "read") return "□";
  if (v === "searched") return "⌕";
  if (v === "ran") return "›";
  if (v === "edit") return "✎";
  return "⚙";
}

function structCard(verb, name, body, preview) {
  const d = el("div", "msg m-tool m-collapsible");
  const toggle = el("div", "tool-toggle");
  toggle.dataset.cardToggle = "true";
  toggle.setAttribute("role", "button");
  toggle.setAttribute("aria-expanded", "false");
  toggle.tabIndex = 0;
  toggle.append(el("span", "tool-glyph", toolGlyph(verb)));
  toggle.append(el("span", "tool-verb", verb));
  toggle.append(el("span", "tool-name", name || ""));
  toggle.append(el("span", "tool-preview", preview || ""));
  toggle.append(el("span", "tool-chev", "⌄"));
  const content = el("pre", "tool-body", body || "");
  content.dataset.cardBody = "true";
  content.hidden = true;
  toggle.onclick = () => setCardOpen(d, !d.classList.contains("is-open"));
  toggle.onkeydown = handleCardToggleKeydown;
  d.append(toggle, content);
  return d;
}

function setCardOpen(card, isOpen) {
  card.classList.toggle("is-open", isOpen);
  const body = card.querySelector("[data-card-body]");
  if (body) body.hidden = !isOpen;
  const toggle = card.querySelector("[data-card-toggle]");
  if (toggle) toggle.setAttribute("aria-expanded", isOpen ? "true" : "false");
}

function planText(o) {
  if (Array.isArray(o)) return o.map(it => "• " + (it.content || it.title || JSON.stringify(it)) + (it.status ? "  (" + it.status + ")" : "")).join("\n");
  return o ? JSON.stringify(o, null, 2) : "";
}

let permState = null;
function showPermission(sessionId, payload) {
  permState = { sessionId, requestId: payload.requestId };
  $("perm-tool").textContent = "Allow “" + payload.toolName + "”?";
  const box = $("perm-options"); box.innerHTML = "";
  payload.options.forEach(o => {
    const b = document.createElement("button");
    b.textContent = o.name;
    b.className = o.kind.startsWith("allow") ? "btn-allow" : "btn-deny";
    b.onclick = () => {
      // "once" kinds send null so the server reproduces the local prompt's
      // mapping (once → don't persist / re-ask next time); only "*_always"
      // persists. Sending "session" here would silently auto-approve later calls.
      send({ type: "permissionDecision", sessionId, requestId: payload.requestId, optionId: o.optionId, persistScope: o.kind.endsWith("always") ? "project" : null });
      hidePermission();
    };
    box.appendChild(b);
  });
  $("permission").classList.remove("hidden");
}
function hidePermission() { $("permission").classList.add("hidden"); permState = null; }

// --- Question sheet ---
let questionState = null;
// Map<questionId, Set<optionId>> — tracks selected option ids per question.
let questionSelections = new Map();

function showQuestion(sessionId, payload) {
  const questions = payload.questions || [];
  if (questions.length === 0) { hideQuestion(); return; }   // nothing to answer — don't show a trapping empty sheet
  if (dismissedQuestion && dismissedQuestion.sessionId === sessionId && dismissedQuestion.requestId === payload.requestId) { hideQuestion(); return; }   // user already closed this exact prompt
  questionState = { sessionId, requestId: payload.requestId };
  questionSelections = new Map();

  const titleEl = $("question-title");
  if (payload.title) {
    titleEl.textContent = payload.title;
    titleEl.classList.remove("hidden");
  } else {
    titleEl.textContent = "";
    titleEl.classList.add("hidden");
  }

  const body = $("question-body");
  body.innerHTML = "";

  questions.forEach(q => {
    questionSelections.set(q.id, new Set());

    const block = document.createElement("div");
    block.className = "question-block";

    const prompt = document.createElement("p");
    prompt.className = "question-prompt";
    prompt.textContent = q.prompt;
    block.appendChild(prompt);

    q.options.forEach(o => {
      const btn = document.createElement("button");
      btn.className = "option-btn";
      btn.textContent = o.label;
      btn.onclick = () => {
        const sel = questionSelections.get(q.id);
        if (q.allowMultiple) {
          if (sel.has(o.id)) {
            sel.delete(o.id);
            btn.classList.remove("is-selected");
          } else {
            sel.add(o.id);
            btn.classList.add("is-selected");
          }
        } else {
          // Single-select: deselect all siblings, then select this one.
          const allBtns = block.querySelectorAll(".option-btn");
          sel.clear();
          allBtns.forEach(b => b.classList.remove("is-selected"));
          sel.add(o.id);
          btn.classList.add("is-selected");
        }
        updateSubmitState();
      };
      block.appendChild(btn);
    });

    body.appendChild(block);
  });

  updateSubmitState();
  $("question").classList.remove("hidden");
}

function updateSubmitState() {
  // Submit is enabled only when every question has at least one selected option.
  let complete = questionSelections.size > 0;
  questionSelections.forEach(sel => { if (sel.size === 0) complete = false; });
  $("question-submit").disabled = !complete;
}

function submitQuestion() {
  if (!questionState) return;
  const answers = [];
  questionSelections.forEach((sel, questionId) => {
    answers.push({ questionId, selectedOptionIds: Array.from(sel) });
  });
  send({ type: "questionAnswer", sessionId: questionState.sessionId, requestId: questionState.requestId, answers });
  hideQuestion();
}

function hideQuestion() {
  $("question").classList.add("hidden");
  questionState = null;
  questionSelections = new Map();
}

function dismissQuestion() {
  if (questionState) dismissedQuestion = { sessionId: questionState.sessionId, requestId: questionState.requestId };   // keep this exact prompt dismissed across re-sends
  hideQuestion();
}

// --- Standard ACP elicitation sheet ---
let elicitationState = null;
let elicitationInputs = new Map();

function showElicitation(sessionId, payload) {
  elicitationState = { sessionId, payload };
  elicitationInputs = new Map();
  $("elicitation-title").textContent = payload.title || (payload.mode === "url" ? "Continue in browser" : "Input requested");
  $("elicitation-message").textContent = payload.message || "";
  $("elicitation-error").classList.add("hidden");
  const body = $("elicitation-body");
  body.innerHTML = "";

  if (payload.mode === "url") {
    const host = safeURLHost(payload.url);
    if (host) body.appendChild(el("p", "elicitation-label", host));
    body.appendChild(el("div", "elicitation-url", payload.url || ""));
    $("elicitation-submit").textContent = "Open Browser";
  } else {
    (payload.fields || []).forEach(field => body.appendChild(renderElicitationField(field)));
    $("elicitation-submit").textContent = "Submit";
  }
  $("elicitation").classList.remove("hidden");
}

function renderElicitationField(field) {
  const block = el("div", "elicitation-field");
  block.appendChild(el("label", "elicitation-label", field.title + (field.required ? " · Required" : "")));
  if (field.description) block.appendChild(el("p", "elicitation-description", field.description));

  if (!["string", "number", "integer", "boolean", "array"].includes(field.type)) {
    elicitationInputs.set(field.key, { field, unsupported: true });
    block.appendChild(el("p", "elicitation-description", "This field type is not supported."));
    return block;
  }

  if ((field.type === "string" && field.options.length > 0) || field.type === "array") {
    const hasDefault = field.defaultValue !== null && field.defaultValue !== undefined;
    const selected = new Set(Array.isArray(field.defaultValue) ? field.defaultValue : (typeof field.defaultValue === "string" ? [field.defaultValue] : []));
    elicitationInputs.set(field.key, { field, selected, touched: hasDefault });
    field.options.forEach(option => {
      const button = el("button", "option-btn", option.title || option.value);
      if (selected.has(option.value)) button.classList.add("is-selected");
      button.onclick = () => {
        const multiple = field.type === "array";
        if (!multiple) {
          selected.clear();
          block.querySelectorAll(".option-btn").forEach(item => item.classList.remove("is-selected"));
        }
        if (multiple && selected.has(option.value)) {
          selected.delete(option.value);
          button.classList.remove("is-selected");
        } else if (!field.maxItems || selected.size < field.maxItems) {
          selected.add(option.value);
          button.classList.add("is-selected");
        }
        elicitationInputs.get(field.key).touched = true;
      };
      block.appendChild(button);
    });
    return block;
  }

  if (field.type === "boolean") {
    const label = el("label", "elicitation-check");
    const input = document.createElement("input");
    input.type = "checkbox";
    input.checked = field.defaultValue === true;
    const state = { field, input, touched: field.defaultValue !== null && field.defaultValue !== undefined };
    input.onchange = () => { state.touched = true; };
    elicitationInputs.set(field.key, state);
    label.append(input, document.createTextNode(field.title));
    block.appendChild(label);
    return block;
  }

  const input = document.createElement("input");
  input.className = "elicitation-input";
  input.type = field.format === "date" ? "date"
    : (field.format === "date-time" ? "datetime-local"
      : (field.format === "email" ? "email"
        : (field.format === "uri" ? "url"
          : ((field.type === "number" || field.type === "integer") ? "number" : "text"))));
  if (field.type === "integer") input.step = "1";
  if (field.format === "date-time") input.step = "0.001";
  if (field.minimum !== null && field.minimum !== undefined) input.min = String(field.minimum);
  if (field.maximum !== null && field.maximum !== undefined) input.max = String(field.maximum);
  if (field.minLength !== null && field.minLength !== undefined) input.minLength = field.minLength;
  if (field.maxLength !== null && field.maxLength !== undefined) input.maxLength = field.maxLength;
  if (field.defaultValue !== null && field.defaultValue !== undefined) {
    input.value = field.format === "date-time"
      ? elicitationDateTimeLocalValue(field.defaultValue)
      : String(field.defaultValue);
  }
  const state = { field, input, touched: input.value.length > 0 };
  input.oninput = () => { state.touched = true; };
  elicitationInputs.set(field.key, state);
  block.appendChild(input);
  return block;
}

function submitElicitation() {
  if (!elicitationState) return;
  const { sessionId, payload } = elicitationState;
  if (payload.mode === "url") {
    const opened = window.open("about:blank", "_blank");
    if (!opened) {
      showElicitationError("The browser blocked this URL. Allow pop-ups and try again.");
      return;
    }
    opened.opener = null;
    send({ type: "elicitationResponse", sessionId, requestId: payload.requestId, action: "accept" });
    opened.location.replace(payload.url);
    hideElicitation();
    return;
  }

  const content = {};
  for (const [key, state] of elicitationInputs) {
    const field = state.field;
    if (state.unsupported) {
      if (field.required) return showElicitationError(`Cannot submit the unsupported field ${field.title}.`);
      continue;
    }
    if (state.selected) {
      if (!field.required && !state.touched) continue;
      if (field.required && state.selected.size === 0) return showElicitationError(`Choose a value for ${field.title}.`);
      if (field.minItems && state.selected.size < field.minItems) return showElicitationError(`Choose at least ${field.minItems} values for ${field.title}.`);
      if (field.type === "array") content[key] = Array.from(state.selected);
      else if (state.selected.size > 0) content[key] = Array.from(state.selected)[0];
      continue;
    }
    const input = state.input;
    if (!input.checkValidity()) return showElicitationError(`Check the value for ${field.title}.`);
    if (!field.required && !state.touched) continue;
    if (elicitationRequiredValueIsMissing(field, input.value)) {
      return showElicitationError(`Enter a value for ${field.title}.`);
    }
    if (!field.required && (field.type === "number" || field.type === "integer") && input.value.trim() === "") {
      continue;
    }
    if (!field.required && field.type === "string" && input.value === "") {
      continue;
    }
    if (!elicitationFormatIsValid(field, input.value)) {
      return showElicitationError(`Check the value for ${field.title}.`);
    }
    if (field.type === "boolean") content[key] = input.checked;
    else if (field.type === "number") content[key] = Number(input.value);
    else if (field.type === "integer") {
      const value = Number(input.value);
      if (!Number.isInteger(value)) return showElicitationError(`Enter a whole number for ${field.title}.`);
      content[key] = value;
    }
    else if (field.format === "date-time" && input.value) content[key] = new Date(input.value).toISOString();
    else content[key] = input.value;
  }
  send({ type: "elicitationResponse", sessionId, requestId: payload.requestId, action: "accept", content });
}

function elicitationRequiredValueIsMissing(field, value) {
  if (!field.required || value !== "") return false;
  if (field.type === "number" || field.type === "integer") return true;
  if (["date", "date-time", "email", "uri"].includes(field.format)) return true;
  if (field.minLength && field.minLength > 0) return true;
  if (field.pattern) {
    try { return !new RegExp(field.pattern).test(value); } catch { return false; }
  }
  return false;
}

function elicitationFormatIsValid(field, value) {
  if (field.pattern) {
    try {
      if (!new RegExp(field.pattern).test(value)) return false;
    } catch {}
  }
  if (field.format === "email") {
    const parts = value.split("@");
    return parts.length === 2 && parts[0].length > 0 && parts[1].includes(".");
  }
  if (field.format === "uri") {
    try { return new URL(value).protocol.length > 0; } catch { return false; }
  }
  return true;
}

function elicitationDateTimeLocalValue(raw) {
  const date = new Date(raw);
  if (Number.isNaN(date.getTime())) return "";
  const pad = value => String(value).padStart(2, "0");
  const base = `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`
    + `T${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())}`;
  return date.getMilliseconds() === 0
    ? base
    : `${base}.${String(date.getMilliseconds()).padStart(3, "0")}`;
}

function resolveElicitation(action) {
  if (!elicitationState) return;
  const { sessionId, payload } = elicitationState;
  send({ type: "elicitationResponse", sessionId, requestId: payload.requestId, action });
  hideElicitation();
}

function showElicitationError(message) {
  const error = $("elicitation-error");
  error.textContent = message;
  error.classList.remove("hidden");
}

function safeURLHost(raw) {
  try { return new URL(raw).host; } catch { return ""; }
}

function hideElicitation() {
  $("elicitation").classList.add("hidden");
  elicitationState = null;
  elicitationInputs = new Map();
}

// Direct port of composerAction(...) in ComposerAction.swift. Kept as a pure
// function of (streamingState, hasText) so the two implementations can be
// diffed against each other by eye.
function composerAction(streamingState, hasText) {
  if (streamingState === "idle") {
    return hasText ? "send" : "hidden";
  }
  return hasText ? "queue" : "stop";
}

// Mirrors ACPSession.visibleQueueCount: the in-flight .sending head gets its
// own bubble but is not part of the "still waiting" count.
function queueBadgeCount() {
  return queueItems.filter(i => i.status !== "sending").length;
}

function renderDriveBar(streamingState) {
  // Keep the whole bar hidden until the first snapshot tells us the real
  // canDrive — otherwise the take-over banner flashes while opening a session
  // we actually own, and an empty bar strip shows before any state arrives.
  const known = !!currentSession && canDriveKnown;
  $("drivebar").classList.toggle("hidden", !known);
  if (!known) return;
  // The composer is always available — typing/acting as a non-writer
  // auto-takes the wheel (ensureWriter). The take-over PILL only appears when
  // we don't hold the lease, as a no-typing way to grab it.
  $("composer").classList.remove("hidden");
  $("takeover").classList.toggle("hidden", canDrive);
  // A turn is interruptible in every non-idle state — including while it's
  // blocked on a permission/question prompt — mirroring the native composer
  // (composerAction returns .stop for sending/streaming/awaiting*). Without
  // the awaiting states, dismissing a prompt sheet would strand the user on
  // Send with no way to cancel the running turn.
  lastStreamingState = streamingState;
  const hasText = !!$("prompt").value.trim() || pendingAttachments.length > 0;
  const action = composerAction(streamingState, hasText);
  $("send").classList.toggle("hidden", action !== "send");
  $("queue-capsule").classList.toggle("hidden", action !== "queue");
  $("stop").classList.toggle("hidden", action !== "stop");
  renderQueueBadges();
}

function renderQueueBadges() {
  const count = queueBadgeCount();
  ["send-badge", "queue-badge"].forEach(badgeId => {
    const badge = $(badgeId);
    badge.textContent = String(count);
    badge.classList.toggle("hidden", count === 0);
  });
}

let stopFallbackTimer = null;
function markStopping(on) {
  stopPending = on;
  const btn = $("stop");
  btn.disabled = on;
  btn.classList.toggle("is-stopping", on);
  if (stopFallbackTimer) { clearTimeout(stopFallbackTimer); stopFallbackTimer = null; }
  // If the cancel RPC fails and the turn keeps streaming, re-enable Stop so
  // the user can retry instead of being stranded on a dead button.
  if (on) stopFallbackTimer = setTimeout(() => markStopping(false), 15000);
}

function syncStreamingState(streamingState) {
  if (streamingState === "idle" && stopPending) markStopping(false);
  renderDriveBar(streamingState);
}

// takeOver seizes the lease synchronously server-side and messages are ordered,
// so a follow-up action sent right after lands as the writer.
function ensureWriter() {
  if (!canDrive && currentSession) send({ type: "takeOver", sessionId: currentSession });
}

function autoGrowPrompt() {
  const ta = $("prompt");
  ta.style.height = "auto";                          // shrink back before measuring
  ta.style.height = Math.min(ta.scrollHeight, window.innerHeight * 0.4) + "px";
}
function submitPrompt(intent) {
  const ta = $("prompt");
  const text = ta.value.trim();
  if (!currentSession) return;
  if (!text && pendingAttachments.length === 0) return;   // nothing to send
  ensureWriter();                                    // grab the wheel first; ordered before the prompt
  send({
    type: "sendPrompt",
    sessionId: currentSession,
    text,
    attachments: pendingAttachments,
    intent: intent || "auto",
  });
  lastSentText = text;                               // keep until the server accepts (or rejects) it
  lastSentAttachments = pendingAttachments;          // ditto for the staged images
  ta.value = "";
  clearAttachments();
  autoGrowPrompt();                                  // collapse back to one row
  renderDriveBar(lastStreamingState);
}

function sendPrompt() { submitPrompt("auto"); }

// The server dropped our prompt (lease went stale, materialize failed, etc.).
// Put the text AND staged images back so the message isn't silently lost — but
// only if the user hasn't started composing a new one.
function restoreRejectedPrompt() {
  const ta = $("prompt");
  // Only restore if the user hasn't started a new message — no new text AND no
  // newly-staged images — otherwise we'd splice the failed prompt's content
  // into their new draft.
  const composingNew = !!ta.value || pendingAttachments.length > 0;
  if (!composingNew) {
    if (lastSentText) { ta.value = lastSentText; autoGrowPrompt(); }
    if (lastSentAttachments.length) { pendingAttachments = lastSentAttachments.slice(); renderChips(); }
  }
  lastSentText = null;
  lastSentAttachments = [];
  // renderChips() above only runs when there were attachments — a text-only
  // restore would otherwise leave the composer action (Send/Queue/hidden)
  // stale at "hidden" from the submit that just got rejected, stranding the
  // restored text with no way to send it.
  renderDriveBar(lastStreamingState);
}

// --- Session config sheet (⚙) + attachments (📎) ---
// Show/hide the 📎 button and rebuild the config sheet from the latest
// sessionConfig. Called on every sessionConfig and when entering/leaving a
// session so affordances reflect the open session (or nothing).
function renderConfigAffordances() {
  const cfg = sessionConfig;
  $("attach").classList.toggle("hidden", !(cfg && cfg.acceptsImages));
  renderConfigSheet();
}

function renderConfigSheet() {
  const cfg = sessionConfig;
  const models = (cfg && cfg.models) || [];
  const modes = (cfg && cfg.modes) || [];
  $("cfg-model-section").classList.toggle("hidden", models.length === 0);
  $("cfg-mode-section").classList.toggle("hidden", modes.length === 0);

  const fill = (box, items, current, act) => {
    box.innerHTML = "";
    items.forEach(it => {
      const btn = el("button", "option-btn", it.name);
      if (it.id === current) btn.classList.add("is-selected");
      btn.onclick = () => { ensureWriter(); act(it.id); };
      box.appendChild(btn);
    });
  };
  fill($("cfg-models"), models, cfg && cfg.currentModel, id => send({ type: "setModel", sessionId: currentSession, modelId: id }));
  fill($("cfg-modes"), modes, cfg && cfg.currentMode, id => send({ type: "setMode", sessionId: currentSession, modeId: id }));
  $("cfg-autorun").checked = !!(cfg && cfg.autoRunEnabled);
}

function showConfig() { renderConfigSheet(); $("cfg").classList.remove("hidden"); }
function hideConfig() { $("cfg").classList.add("hidden"); }

function showSteerSheet() { $("steer-sheet").classList.remove("hidden"); }
function hideSteerSheet() { $("steer-sheet").classList.add("hidden"); }

// --- Attachments ---
function b64Bytes(b64) { return Math.floor(b64.length * 3 / 4); }   // decoded size estimate, good enough for the cap
function attachedBytes() { return pendingAttachments.reduce((n, a) => n + b64Bytes(a.dataBase64), 0); }

function clearAttachments() { pendingAttachments = []; renderChips(); }

function renderChips() {
  const box = $("chips");
  box.innerHTML = "";
  pendingAttachments.forEach((a, i) => {
    const chip = el("div", "chip");
    const img = el("img");
    img.src = "data:" + a.mimeType + ";base64," + a.dataBase64;
    img.alt = a.name;
    const x = el("button", "chip-x", "✕");
    x.setAttribute("aria-label", "Remove attachment");
    x.onclick = () => { pendingAttachments.splice(i, 1); renderChips(); };
    chip.append(img, x);
    box.appendChild(chip);
  });
  box.classList.toggle("hidden", pendingAttachments.length === 0);
  // pendingAttachments feeds hasText in composerAction — an image-only message
  // must be able to flip Send/Queue visible without any unrelated event (a
  // keystroke, an incoming delta) happening to call renderDriveBar first.
  renderDriveBar(lastStreamingState);
}

function readAttachment(file) {
  return new Promise((resolve, reject) => {
    const r = new FileReader();
    r.onload = () => {
      const s = String(r.result);
      const comma = s.indexOf(",");                  // strip the "data:<mime>;base64," prefix
      resolve(comma >= 0 ? s.slice(comma + 1) : s);
    };
    r.onerror = () => reject(r.error);
    r.readAsDataURL(file);
  });
}

async function onFilesPicked(files) {
  for (const file of files) {
    const b64 = await readAttachment(file);
    if (attachedBytes() + b64Bytes(b64) > ATTACH_CAP) {
      alert("Attachments can total at most 10 MB.");
      break;
    }
    pendingAttachments.push({ name: file.name, mimeType: file.type, dataBase64: b64 });
    renderChips();
  }
}

$("new-session").onclick = showCreateSheet;
$("create-cancel").onclick = hideCreateSheet;
$("create-next").onclick = advanceCreateSheet;
$("create-back").onclick = backCreateSheet;
$("create-new-worktree").onclick = startNewWorktree;
$("retry-branches").onclick = () => worktreeCreation.retryBranches();
$("new-session-sheet").onclick = (e) => { if (e.target.id === "new-session-sheet" && !createState.busy) hideCreateSheet(); };
listen("worktree-search", "input", (e) => {
  createState.filter = e.target.value || "";
  renderCreateSheet();
});
listen("project-select", "change", (e) => worktreeCreation.selectProject(e.target.value));
listen("base-select", "change", (e) => worktreeCreation.setBase(e.target.value));
listen("new-branch", "input", (e) => worktreeCreation.setBranch(e.target.value));
$("config").onclick = showConfig;
$("cfg-close").onclick = hideConfig;
$("cfg").onclick = (e) => { if (e.target.id === "cfg") hideConfig(); };
$("queue-primary").onclick = () => submitPrompt("auto");
$("queue-menu").onclick = showSteerSheet;
$("steer-now").onclick = () => { hideSteerSheet(); submitPrompt("steer"); };
$("steer-stop").onclick = () => { hideSteerSheet(); $("stop").click(); };
$("steer-close").onclick = hideSteerSheet;
$("steer-sheet").onclick = (e) => { if (e.target.id === "steer-sheet") hideSteerSheet(); };
$("cfg-autorun").onchange = (e) => { ensureWriter(); send({ type: "setAutoRun", sessionId: currentSession, enabled: e.target.checked }); };
$("detail-rename").onclick = () => { if (currentSession) showRenameSheet(currentSession); };
$("rename-submit").onclick = submitRename;
$("rename-cancel").onclick = hideRenameSheet;
$("rename-sheet").onclick = (e) => { if (e.target.id === "rename-sheet") hideRenameSheet(); };
listen("rename-input", "keydown", (e) => {
  if (e.key === "Enter") { e.preventDefault(); submitRename(); }
  if (e.key === "Escape") { e.preventDefault(); hideRenameSheet(); }
});
$("attach").onclick = () => $("file").click();
$("file").onchange = async (e) => {
  const files = Array.from(e.target.files || []);
  $("file").value = "";                              // reset so the same file can be re-picked
  await onFilesPicked(files);
};

const LOAD_OLDER_THRESHOLD_PX = 600;
const OLDER_PAGE_SIZE = 90;

listen("messages", "scroll", () => {
  if (!currentSession || !transcriptMeta || olderFetchInFlight) return;
  if (transcriptMeta.firstIndex <= 0) return;
  if ($("messages").scrollTop > LOAD_OLDER_THRESHOLD_PX) return;
  olderFetchInFlight = true;
  showLoadingRow();
  send({ type: "fetchOlder", sessionId: currentSession, beforeIndex: transcriptMeta.firstIndex, limit: OLDER_PAGE_SIZE });
});

function showLoadingRow() {
  if ($("messages").querySelector(".load-older")) return;
  const row = el("div", "load-older", "Loading earlier messages…");
  row.dataset.index = "-1";
  $("messages").prepend(row);
}
function removeLoadingRow() {
  const row = $("messages").querySelector(".load-older");
  if (row) row.remove();
}

$("takeover").onclick = () => { if (currentSession) send({ type: "takeOver", sessionId: currentSession }); };
$("send").onclick = sendPrompt;
$("stop").onclick = () => {
  if (!currentSession) return;
  send({ type: "stop", sessionId: currentSession });   // stop is leaseless — no lease takeover first
  markStopping(true);
};
listen("prompt", "input", () => { autoGrowPrompt(); renderDriveBar(lastStreamingState); });
listen("prompt", "keydown", (e) => {
  if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); sendPrompt(); }
});

$("question-submit").onclick = submitQuestion;
// Explicit Close + backdrop tap — a sheet can always be dismissed, and a closed
// question stays closed even if the server keeps re-sending it.
$("question-close").onclick = dismissQuestion;
$("perm-close").onclick = hidePermission;
$("elicitation-submit").onclick = submitElicitation;
$("elicitation-decline").onclick = () => resolveElicitation("decline");
$("elicitation-cancel").onclick = () => resolveElicitation("cancel");
$("question").onclick = (e) => { if (e.target.id === "question") dismissQuestion(); };
$("permission").onclick = (e) => { if (e.target.id === "permission") hidePermission(); };
$("elicitation").onclick = (e) => { if (e.target.id === "elicitation") resolveElicitation("cancel"); };

$("back").onclick = showSessions;
$("gate-retry").onclick = retryConnection;

// iOS overlays the keyboard without shrinking the layout viewport, so a
// 100dvh shell ends up taller than the visible area when the field is focused.
// Drive the shell height from the *visual* viewport (which does shrink for the
// keyboard) and keep the transcript pinned to the bottom as it resizes.
const vp = window.visualViewport;
if (vp) {
  const syncViewport = () => {
    // Pin the fixed shell to the visual viewport's box: height shrinks for the
    // keyboard, and top follows offsetTop so the shell doesn't slide off-screen
    // when iOS scrolls the page to reveal the focused field.
    document.body.style.height = vp.height + "px";
    document.body.style.top = vp.offsetTop + "px";
    const box = $("messages");
    if (box) box.scrollTop = box.scrollHeight;
  };
  vp.addEventListener("resize", syncViewport);
  vp.addEventListener("scroll", syncViewport);
  syncViewport();
}

setStatus("Connecting…", "connecting");
showConnectingGate();
armEscalation();
connect();
