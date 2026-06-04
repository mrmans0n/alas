const tokenKey = "alas.remote.token";
const $ = (id) => document.getElementById(id);
let ws, currentSession = null, messages = new Map();
let canDrive = false;
let reconnectDelay = 1500;
const maxReconnectDelay = 30000;
let dismissedQuestion = null;   // {sessionId, requestId} the user closed; suppress re-shows of that exact prompt (ids aren't unique across sessions)

function setStatus(s) { $("status").textContent = s; }
function showGate(title, msg, retry) {
  $("gate-title").textContent = title;
  $("gate-msg").textContent = msg;
  $("gate-retry").classList.toggle("hidden", !retry);
  $("gate").classList.remove("hidden");
}
function hideGate() { $("gate").classList.add("hidden"); }

async function ensureToken() {
  // A freshly-scanned QR (?code present) always re-pairs, REPLACING any stored
  // token — otherwise a phone holding a stale/rejected token could never
  // recover by scanning a new code (it would keep reusing the dead token).
  const code = new URLSearchParams(location.search).get("code");
  if (code) {
    let res;
    try {
      res = await fetch("/pair", { method: "POST", body: JSON.stringify({ code, deviceName: navigator.userAgent.slice(0, 40) }) });
    } catch (_) {
      showGate("Can’t reach Alas", "Make sure your Mac is awake and on the same Wi-Fi, then scan the QR again.", true);
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
  const token = localStorage.getItem(tokenKey);
  if (token) return token;
  showGate("Pair this device", "On your Mac, open Alas → Settings → Remote and scan the QR code shown there.");
  throw new Error("no code");
}

async function connect() {
  let token;
  try {
    token = await ensureToken();
  } catch (_) {
    return;   // no code/token yet (or pairing failed); status is set — wait for the user
  }
  if (ws) { try { ws.close(); } catch (_) {} }   // drop any prior (possibly half-open) socket
  ws = new WebSocket(`ws://${location.host}/ws`, [token]);   // token as subprotocol
  ws.onopen = () => {
    setStatus("connected");
    hideGate();
    reconnectDelay = 1500;   // reset back-off after a good connection
    send({ type: "listSessions" });
    if (currentSession) send({ type: "subscribe", sessionId: currentSession });   // re-sync after reconnect
  };
  ws.onclose = () => {
    setStatus("disconnected — reconnecting…");
    setTimeout(connect, reconnectDelay);
    reconnectDelay = Math.min(reconnectDelay * 2, maxReconnectDelay);   // capped exponential back-off
  };
  ws.onmessage = (e) => handle(JSON.parse(e.data));
}

function send(obj) { ws && ws.readyState === 1 && ws.send(JSON.stringify(obj)); }

function handle(msg) {
  switch (msg.type) {
    case "sessionList": renderSessions(msg.sessions); break;
    case "transcriptSnapshot": messages = new Map(); msg.messages.forEach(m => messages.set(m.stableId, m)); if (msg.sessionId === currentSession) { canDrive = msg.canDrive; renderMessages(true); renderDriveBar(msg.streamingState); } break;
    // The server re-sends the full transcript each time, keyed by stable position
    // ids, so replace (don't append) to avoid accumulating duplicate copies.
    case "transcriptDelta": messages = new Map(); msg.upserts.forEach(m => messages.set(m.stableId, m)); if (msg.sessionId === currentSession) { canDrive = msg.canDrive; renderMessages(false); renderDriveBar(msg.streamingState); } break;
    // Scope prompt events to the session currently open — a stale/in-flight
    // event for a session the user already left must not pop or close a sheet.
    case "permissionRequest": if (msg.sessionId === currentSession) showPermission(msg.sessionId, msg.payload); break;
    case "permissionResolved": if (msg.sessionId === currentSession) hidePermission(); break;
    case "questionRequest": if (msg.sessionId === currentSession) showQuestion(msg.sessionId, msg.payload); break;
    case "questionResolved": if (msg.sessionId === currentSession) { dismissedQuestion = null; hideQuestion(); } break;
    case "sessionClosed": if (msg.sessionId === currentSession) showSessions(); break;
    case "error": setStatus("error: " + (msg.message ?? "(unknown)")); break;
    default: console.warn("unknown message type", msg.type);
  }
}

function renderSessions(sessions) {
  const list = $("session-list"); list.innerHTML = "";
  sessions.forEach(s => {
    // A real <button> is natively tappable on iOS Safari (a plain <li> with a
    // JS click handler is not, even with cursor:pointer).
    const row = document.createElement("button");
    row.type = "button";
    row.className = "session-row";
    const title = document.createElement("span");
    title.textContent = s.title;                 // textContent: safe against agent-set titles
    const status = document.createElement("span");
    status.className = "status";
    status.textContent = s.status;
    row.append(title, status);
    row.onclick = () => openSession(s.id);
    list.appendChild(row);
  });
}

function openSession(id) {
  currentSession = id; messages = new Map(); dismissedQuestion = null; canDrive = false;
  $("sessions").classList.add("hidden"); $("transcript").classList.remove("hidden");
  $("messages").innerHTML = ""; renderDriveBar("idle"); send({ type: "subscribe", sessionId: id });
}
function showSessions() {
  if (currentSession) send({ type: "unsubscribe", sessionId: currentSession });
  currentSession = null; canDrive = false;
  hidePermission(); hideQuestion();          // never leave a sheet over the list
  $("takeover").classList.add("hidden");
  $("composer").classList.add("hidden");
  $("transcript").classList.add("hidden"); $("sessions").classList.remove("hidden");
  send({ type: "listSessions" });
}

function renderMessages(forceBottom) {
  const box = $("messages");
  // The page itself scrolls (sticky bar + body), so use window scroll metrics.
  const atBottom = forceBottom || (window.innerHeight + window.scrollY >= document.body.scrollHeight - 120);
  // Preserve which tool/thought cards the user expanded across re-renders.
  const open = new Set();
  box.querySelectorAll("details[open]").forEach(d => { if (d.dataset.sid) open.add(d.dataset.sid); });
  box.innerHTML = "";
  for (const [sid, m] of messages) box.appendChild(renderMessage(m, sid, open));
  if (atBottom) requestAnimationFrame(() => window.scrollTo(0, document.body.scrollHeight));
}

function el(tag, cls, text) { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; }
function jparse(s) { try { return JSON.parse(s); } catch { return null; } }
// Render markdown to sanitized HTML (agent/user prose is untrusted — DOMPurify
// strips any script/event-handler injection). Falls back to escaped plain text
// if the libraries didn't load.
function md(text) {
  if (typeof marked === "undefined" || typeof DOMPurify === "undefined") {
    const d = document.createElement("div"); d.textContent = text || ""; return d.innerHTML;
  }
  return DOMPurify.sanitize(marked.parse(text || "", { gfm: true, breaks: true }));
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
    node = el("details", "msg m-thought");
    node.append(el("summary", null, "Thinking…"), el("div", "thought-body", m.text || ""));
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
  if (node.tagName === "DETAILS") {            // restore prior expand state
    node.dataset.sid = sid;
    if (open && open.has(sid)) node.open = true;
  }
  return node;
}

function toolCard(tc) {
  const verb = TOOL_VERB[tc.kind] || (tc.kind ? cap(tc.kind) : "Tool");
  const name = tc.title || (tc.locations && tc.locations[0]) || "";
  const card = structCard(verb, name && name.toLowerCase() !== verb.toLowerCase() ? name : "",
                          (typeof tc.content === "string" && tc.content) ? tc.content : "No output.", tc.preview);
  const [ch, scls] = TOOL_STATUS[tc.status] || [tc.status || "", "run"];
  card.querySelector(".tool-chev").insertAdjacentElement("beforebegin", el("span", "tool-status " + scls, ch));
  return card;
}

function structCard(verb, name, body, preview) {
  const d = el("details", "msg m-tool");
  const sum = el("summary");
  sum.append(el("span", "tool-verb", verb));
  sum.append(el("span", "tool-name", name || ""));
  sum.append(el("span", "tool-preview", preview || ""));
  sum.append(el("span", "tool-chev", "⌄"));
  d.append(sum, el("pre", "tool-body", body || ""));
  return d;
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
function renderDriveBar(streamingState) {
  const driving = currentSession && canDrive;
  $("takeover").classList.toggle("hidden", !currentSession || canDrive);
  $("composer").classList.toggle("hidden", !driving);
  if (driving) {
    const busy = streamingState === "streaming" || streamingState === "sending";
    $("send").classList.toggle("hidden", busy);
    $("stop").classList.toggle("hidden", !busy);
  }
}

function sendPrompt() {
  const ta = $("prompt");
  const text = ta.value.trim();
  if (!text || !currentSession || !canDrive) return;
  send({ type: "sendPrompt", sessionId: currentSession, text });
  ta.value = "";
}

$("takeover").onclick = () => { if (currentSession) send({ type: "takeOver", sessionId: currentSession }); };
$("send").onclick = sendPrompt;
$("stop").onclick = () => { if (currentSession) send({ type: "stop", sessionId: currentSession }); };
$("prompt").addEventListener("keydown", (e) => {
  if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); sendPrompt(); }
});

$("question-submit").onclick = submitQuestion;
// Explicit Close + backdrop tap — a sheet can always be dismissed, and a closed
// question stays closed even if the server keeps re-sending it.
$("question-close").onclick = dismissQuestion;
$("perm-close").onclick = hidePermission;
$("question").onclick = (e) => { if (e.target.id === "question") dismissQuestion(); };
$("permission").onclick = (e) => { if (e.target.id === "permission") hidePermission(); };

$("back").onclick = showSessions;
$("gate-retry").onclick = () => location.reload();
connect();
