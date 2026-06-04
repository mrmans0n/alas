const tokenKey = "alas.remote.token";
const $ = (id) => document.getElementById(id);
let ws, currentSession = null, messages = new Map();
let reconnectDelay = 1500;
const maxReconnectDelay = 30000;

function setStatus(s) { $("status").textContent = s; }

async function ensureToken() {
  let token = localStorage.getItem(tokenKey);
  if (token) return token;
  const code = new URLSearchParams(location.search).get("code");
  if (!code) { setStatus("open the QR link from Alas to pair"); throw new Error("no code"); }
  const res = await fetch("/pair", { method: "POST", body: JSON.stringify({ code, deviceName: navigator.userAgent.slice(0, 40) }) });
  if (!res.ok) { setStatus("pairing failed — get a fresh QR"); throw new Error("pair failed"); }
  token = (await res.json()).token;
  localStorage.setItem(tokenKey, token);
  history.replaceState({}, "", "/");   // strip code from URL (history + referrer)
  return token;
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
    case "transcriptSnapshot": messages = new Map(); msg.messages.forEach(m => messages.set(m.stableId, m)); if (msg.sessionId === currentSession) renderMessages(); break;
    case "transcriptDelta": msg.upserts.forEach(m => messages.set(m.stableId, m)); if (msg.sessionId === currentSession) renderMessages(); break;
    case "permissionRequest": showPermission(msg.sessionId, msg.payload); break;
    case "permissionResolved": hidePermission(); break;
    case "questionRequest": showQuestion(msg.sessionId, msg.payload); break;
    case "questionResolved": hideQuestion(); break;
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
  currentSession = id; messages = new Map();
  $("sessions").classList.add("hidden"); $("transcript").classList.remove("hidden");
  $("messages").innerHTML = ""; send({ type: "subscribe", sessionId: id });
}
function showSessions() {
  if (currentSession) send({ type: "unsubscribe", sessionId: currentSession });
  currentSession = null;
  $("transcript").classList.add("hidden"); $("sessions").classList.remove("hidden");
  send({ type: "listSessions" });
}

function renderMessages() {
  const box = $("messages");
  // Preserve the user's scroll position unless they're already at the bottom.
  const atBottom = box.scrollHeight - box.scrollTop - box.clientHeight < 80;
  box.innerHTML = "";
  for (const m of messages.values()) {
    const div = document.createElement("div");
    const kind = /^[a-zA-Z][a-zA-Z0-9]*$/.test(m.kind) ? m.kind : "unknown";
    div.className = "m-" + kind;
    div.textContent = m.text != null ? m.text : (m.json != null ? prettyStructured(m) : "");
    box.appendChild(div);
  }
  if (atBottom) box.scrollTop = box.scrollHeight;
}
function prettyStructured(m) { try { return m.kind + ": " + JSON.stringify(JSON.parse(m.json)).slice(0, 400); } catch { return m.kind; } }

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

  payload.questions.forEach(q => {
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

$("question-submit").onclick = submitQuestion;

$("back").onclick = showSessions;
connect();
