// Pure state for the multi-server hub: the persisted server registry,
// pairing-link parsing, and aggregation over session lists. No DOM access,
// no timers, no sockets — those live in hub-links.js and app.js. Mirrors the
// shape of repo-filter.js / session-ordering.js so node can load it directly.

const HUB_STORAGE_KEY = "alas.remote.hub";
const LEGACY_TOKEN_KEY = "alas.remote.token";
const HUB_SCHEMA_VERSION = 1;
const DEFAULT_PORT = "8765";
const ATTENTION_STATUSES = new Set(["awaitingPermission", "awaitingInput"]);

function safeParse(text) {
  try { return JSON.parse(text); } catch (_) { return null; }
}

function newClientId() {
  return "c-" + Math.random().toString(36).slice(2, 10) + Date.now().toString(36);
}

function stripScheme(text) {
  return text.replace(/^[a-z][a-z0-9+.-]*:\/\//i, "");
}

// `new URL` drops default ports, so "did the user name a port" is decided on
// the raw text: `host:8765`, `[::1]:8765`, `http://host:80` all count.
function hasExplicitPort(text) {
  const authority = stripScheme(text).split(/[/?#]/)[0];
  const afterHost = authority.startsWith("[") ? authority.slice(authority.indexOf("]") + 1) : authority;
  return /:\d+$/.test(afterHost);
}

// "100.64.1.5:8765", "http://100.64.1.5:8765", "[::1]:8765", "nacho.local"
// → "http://100.64.1.5:8765". A missing scheme means http; a missing port on
// http means Alas's default port. Null for anything that is not an http(s)
// origin.
function normalizeOrigin(input) {
  const text = String(input || "").trim();
  if (!text) return null;
  const hadScheme = /^[a-z][a-z0-9+.-]*:\/\//i.test(text);
  const withScheme = hadScheme ? text : "http://" + text;
  let url;
  try { url = new URL(withScheme); } catch (_) { return null; }
  if (url.protocol !== "http:" && url.protocol !== "https:") return null;
  if (!url.hostname || url.username || url.password) return null;
  // Only a bare, schemeless input (the manual "Add server" entry UX) gets
  // Alas's own default port assumed. A caller-supplied complete http(s) URL
  // (e.g. a browser's own location.origin during legacy-token migration, or
  // a reverse-proxied address on port 80) is left exactly as given — its
  // absence of a port is a deliberate fact, not something to default.
  if (!hadScheme && !url.port && url.protocol === "http:" && !hasExplicitPort(withScheme)) url.port = DEFAULT_PORT;
  return url.origin;
}

function uniqueOrigins(origins) {
  const out = [];
  for (const origin of origins || []) {
    const normalized = normalizeOrigin(origin);
    if (normalized && !out.includes(normalized)) out.push(normalized);
  }
  return out;
}

// The string encoded in the QR / Copy button:
//   http://<host>:<port>/?code=<CODE>&hosts=<origin>,<origin>,…
// or a legacy link without `hosts`. Returns { origins, code } with the
// `hosts` order preserved (preferred first) and the link's own origin as the
// last fallback, or null when the text is not a pairing link.
function parsePairingLink(text) {
  const trimmed = String(text || "").trim();
  if (!trimmed) return null;
  let url;
  try { url = new URL(trimmed); } catch (_) { return null; }
  if (url.protocol !== "http:" && url.protocol !== "https:") return null;
  const code = (url.searchParams.get("code") || "").trim();
  if (!code) return null;
  const candidates = [];
  const hosts = url.searchParams.get("hosts");
  if (hosts) candidates.push(...hosts.split(","));
  candidates.push(url.origin);
  const origins = uniqueOrigins(candidates);
  return origins.length ? { origins, code } : null;
}

function parseManualPairing(address, code) {
  const origin = normalizeOrigin(address);
  const trimmedCode = String(code || "").trim();
  if (!origin || !trimmedCode) return null;
  return { origins: [origin], code: trimmedCode };
}

function emptyDocument() {
  return { version: HUB_SCHEMA_VERSION, activeId: null, servers: [] };
}

function makeServer({ origins, token, name, now }) {
  const normalized = uniqueOrigins(origins);
  return {
    id: newClientId(),
    serverId: null,
    name: name || normalized[0],
    origins: normalized,
    lastOrigin: normalized[0],
    token,
    protocolVersion: null,
    hubEnabled: false,
    addedAt: now,
  };
}

// Drops entries that cannot connect (no token, no usable origin), normalizes
// origins, and repairs a dangling activeId.
function normalizeDocument(doc) {
  const servers = (doc.servers || [])
    .filter((s) => s && typeof s.id === "string" && typeof s.token === "string" && Array.isArray(s.origins))
    .map((s) => {
      const origins = uniqueOrigins(s.origins);
      const lastOrigin = normalizeOrigin(s.lastOrigin);
      return {
        ...s,
        origins,
        lastOrigin: lastOrigin && origins.includes(lastOrigin) ? lastOrigin : origins[0],
        hubEnabled: s.hubEnabled === true,
      };
    })
    .filter((s) => s.origins.length > 0);
  const activeId = servers.some((s) => s.id === doc.activeId) ? doc.activeId : (servers[0] ? servers[0].id : null);
  return { version: HUB_SCHEMA_VERSION, activeId, servers };
}

// `storage` is anything with localStorage's getItem/setItem/removeItem. A
// pre-hub client stored one token for the page's own origin; fold it into a
// single server entry once and drop the old key.
function load(storage, pageOrigin, pageHostname, now) {
  const parsed = safeParse(storage.getItem(HUB_STORAGE_KEY) || "");
  if (parsed && parsed.version === HUB_SCHEMA_VERSION && Array.isArray(parsed.servers)) {
    return normalizeDocument(parsed);
  }
  const doc = emptyDocument();
  const legacyToken = storage.getItem(LEGACY_TOKEN_KEY);
  if (legacyToken) {
    const server = makeServer({ origins: [pageOrigin], token: legacyToken, name: pageHostname, now });
    doc.servers.push(server);
    doc.activeId = server.id;
    storage.removeItem(LEGACY_TOKEN_KEY);
    save(storage, doc);
  }
  return doc;
}

function save(storage, doc) {
  storage.setItem(HUB_STORAGE_KEY, JSON.stringify(doc));
}

// Records a successful pairing. A server that already shares any of the
// origins is re-paired in place (new token, merged origin list, new origins
// first); otherwise a new entry is appended and becomes active when nothing
// was.
function upsertPaired(doc, { origins, token, now }) {
  const normalized = uniqueOrigins(origins);
  const existing = doc.servers.find((s) => s.origins.some((o) => normalized.includes(o)));
  if (existing) {
    existing.token = token;
    existing.origins = uniqueOrigins([...normalized, ...existing.origins]);
    existing.lastOrigin = normalized[0];
    return { server: existing, rePaired: true };
  }
  const server = makeServer({ origins: normalized, token, now });
  doc.servers.push(server);
  if (!doc.activeId) doc.activeId = server.id;
  return { server, rePaired: false };
}

// Applies a `hello` to the entry that received it. When another entry already
// carries the same serverId (the same Mac paired twice under different
// addresses) the OLDER entry survives with the fresh token and the union of
// origins; the caller drops the link for `mergedFromId`.
function applyHello(doc, clientId, hello) {
  const server = doc.servers.find((s) => s.id === clientId);
  if (!server) return null;
  const serverId = typeof hello.serverId === "string" && hello.serverId ? hello.serverId : null;
  const helloName = typeof hello.name === "string" ? hello.name.trim() : "";
  const name = helloName || server.name;
  const protocolVersion = Number.isInteger(hello.protocolVersion) ? hello.protocolVersion : null;
  const hubEnabled = hello.hubEnabled === true;
  const twin = serverId ? doc.servers.find((s) => s.id !== clientId && s.serverId === serverId) : null;
  if (twin) {
    twin.token = server.token;
    twin.origins = uniqueOrigins([...server.origins, ...twin.origins]);
    twin.lastOrigin = server.lastOrigin;
    twin.name = name;
    twin.protocolVersion = protocolVersion;
    twin.hubEnabled = hubEnabled;
    doc.servers = doc.servers.filter((s) => s.id !== clientId);
    if (doc.activeId === clientId) doc.activeId = twin.id;
    return { server: twin, mergedFromId: clientId };
  }
  server.serverId = serverId;
  server.name = name;
  server.protocolVersion = protocolVersion;
  server.hubEnabled = hubEnabled;
  return { server, mergedFromId: null };
}

function forgetServer(doc, id) {
  doc.servers = doc.servers.filter((s) => s.id !== id);
  if (doc.activeId === id) doc.activeId = null;
}

function setActive(doc, id) {
  if (doc.servers.some((s) => s.id === id)) doc.activeId = id;
}

function setLastOrigin(doc, id, origin) {
  const server = doc.servers.find((s) => s.id === id);
  const normalized = normalizeOrigin(origin);
  if (server && normalized && server.origins.includes(normalized)) server.lastOrigin = normalized;
}

// Launch/forget fallback: the first server (registry order) that is online,
// else the first server at all, else null.
function fallbackActiveId(doc, onlineIds) {
  const online = doc.servers.find((s) => onlineIds.includes(s.id));
  if (online) return online.id;
  return doc.servers[0] ? doc.servers[0].id : null;
}

// Derived from a `sessionList` payload. Closed sessions never need attention.
function attentionCounts(sessions) {
  const counts = { attention: 0, running: 0 };
  for (const session of sessions || []) {
    if (!session || session.isActive === false) continue;
    if (ATTENTION_STATUSES.has(session.status)) counts.attention += 1;
    else if (session.status === "streaming") counts.running += 1;
  }
  return counts;
}

// Badge on the Settings tab: attention across every server except the one
// being viewed. `links` is any array of { id, counts }.
function otherAttentionTotal(links, activeId) {
  let total = 0;
  for (const link of links || []) {
    if (link.id !== activeId) total += (link.counts && link.counts.attention) || 0;
  }
  return total;
}

globalThis.RemoteHubRegistry = {
  HUB_STORAGE_KEY,
  LEGACY_TOKEN_KEY,
  normalizeOrigin,
  parsePairingLink,
  parseManualPairing,
  load,
  save,
  upsertPaired,
  applyHello,
  forgetServer,
  setActive,
  setLastOrigin,
  fallbackActiveId,
  attentionCounts,
  otherAttentionTotal,
};
