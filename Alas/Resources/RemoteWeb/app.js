const tokenKey = "alas.remote.token";
const $ = (id) => document.getElementById(id);
let ws, currentSession = null, messages = new Map();

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
  history.replaceState({}, "", "/");   // strip code from URL
  return token;
}

async function connect() {
  const token = await ensureToken();
  ws = new WebSocket(`ws://${location.host}/ws`, [token]);   // token as subprotocol
  ws.onopen = () => { setStatus("connected"); send({ type: "listSessions" }); };
  ws.onclose = () => { setStatus("disconnected — reconnecting…"); setTimeout(connect, 1500); };
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
    case "sessionClosed": if (msg.sessionId === currentSession) showSessions(); break;
    case "error": setStatus("error: " + msg.message); break;
  }
}

function renderSessions(sessions) {
  const ul = $("session-list"); ul.innerHTML = "";
  sessions.forEach(s => {
    const li = document.createElement("li");
    li.innerHTML = `<span>${escapeHTML(s.title)}</span><span class="status">${s.status}</span>`;
    li.onclick = () => openSession(s.id);
    ul.appendChild(li);
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
  const box = $("messages"); box.innerHTML = "";
  for (const m of messages.values()) {
    const div = document.createElement("div");
    div.className = "m-" + m.kind;
    div.textContent = m.text != null ? m.text : (m.json != null ? prettyStructured(m) : "");
    box.appendChild(div);
  }
  box.scrollTop = box.scrollHeight;
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
      send({ type: "permissionDecision", sessionId, requestId: payload.requestId, optionId: o.optionId, persistScope: o.kind.endsWith("always") ? "project" : "session" });
      hidePermission();
    };
    box.appendChild(b);
  });
  $("permission").classList.remove("hidden");
}
function hidePermission() { $("permission").classList.add("hidden"); permState = null; }

function escapeHTML(s) { const d = document.createElement("div"); d.textContent = s; return d.innerHTML; }

$("back").onclick = showSessions;
connect().catch(() => {});
