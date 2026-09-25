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

// Every server advertises "localhost" alongside its real addresses so a
// browser running on the same Mac can reach it — but that means every
// server's pairing link shares this origin with every other server on the
// same default port. It can never disambiguate which Mac a pairing belongs
// to, so it must never be used to decide two pairings are the same server.
function isLoopbackOrigin(origin) {
  try {
    const hostname = new URL(origin).hostname;
    return hostname === "localhost" || hostname === "127.0.0.1" || hostname === "::1" || hostname === "[::1]";
  } catch (_) {
    return false;
  }
}

// Kinds `RemotePairingLink.build` may list in `kinds`, mirroring
// `RemoteAdvertisedAddress.Kind`'s raw values. Only "lan" and "tailnet" are
// derived live from current interfaces; "custom" (a configured reverse-proxy
// host, or this Mac's own .local Bonjour name) is static and can go stale
// after the link was generated, and "localhost" is shared by every Mac on
// the same default port. `pair()` in hub-links.js uses this to decide
// whether a 401/403 from an origin is authoritative for the target Mac.
const PAIRING_LINK_KINDS = new Set(["localhost", "lan", "tailnet", "custom"]);

// The string encoded in the QR / Copy button:
//   http://<host>:<port>/?code=<CODE>&hosts=<origin>,<origin>,…&kinds=<kind>,<kind>,…
// or a legacy link without `hosts`/`kinds`, or one built before origin
// kinds were encoded. `kinds` is a same-length, same-order parallel list to
// `hosts` ("" for "no kind" at that position) — a SEPARATE query parameter
// from `hosts`, never folded into an origin string, so `hosts` stays
// parseable as plain origins by a client that predates this encoding (an
// older Mac or web client redeeming a link a newer one generated); an
// unknown `kinds` param is simply ignored by one, exactly like any other
// unrecognized query parameter.
//
// Returns { origins, code, originKinds } with the `hosts` order preserved
// (preferred first) and the link's own origin as the last fallback, or null
// when the text is not a pairing link. `originKinds` maps each returned
// origin to its advertised-address kind when the link carried one; an
// origin with no entry there had no kind info (a legacy link, one built
// before kind encoding existed, or the link's own bare origin fallback,
// which never carries a kind of its own).
function parsePairingLink(text) {
  const trimmed = String(text || "").trim();
  if (!trimmed) return null;
  let url;
  try { url = new URL(trimmed); } catch (_) { return null; }
  if (url.protocol !== "http:" && url.protocol !== "https:") return null;
  const code = (url.searchParams.get("code") || "").trim();
  if (!code) return null;
  const hosts = url.searchParams.get("hosts");
  const hostTokens = hosts ? hosts.split(",") : [];
  const kindTokens = (url.searchParams.get("kinds") || "").split(",");
  const candidates = hostTokens.map((origin, index) => ({ origin, kind: kindTokens[index] || null }));
  candidates.push({ origin: url.origin, kind: null });
  const origins = [];
  const originKinds = {};
  for (const { origin: rawOrigin, kind } of candidates) {
    const origin = normalizeOrigin(rawOrigin);
    if (!origin || origins.includes(origin)) continue;
    origins.push(origin);
    if (kind && PAIRING_LINK_KINDS.has(kind)) originKinds[origin] = kind;
  }
  return origins.length ? { origins, code, originKinds } : null;
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
      const normalizedServer = { ...s };
      delete normalizedServer.hubEnabled;
      return {
        ...normalizedServer,
        origins,
        lastOrigin: lastOrigin && origins.includes(lastOrigin) ? lastOrigin : origins[0],
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

// Records a successful pairing. `targetId`, when given, names an existing
// entry the caller explicitly chose to re-pair (the "Re-pair" flow for an
// unauthorized/blocked server) — it's always updated in place, since the
// fresh origins may no longer overlap the stale ones at all (the address
// changed) and there may be no serverId yet for applyHello to reconcile
// with later. Without a target, a server that already shares any of the
// origins is re-paired in place (new token, merged origin list, new origins
// first); otherwise a new entry is appended and becomes active when nothing
// was. Origin overlap only re-pairs an entry that has never confirmed its
// identity via `hello` (serverId is null) — a DHCP-reused LAN address or a
// shared custom origin must not let a pairing silently take over a Mac
// that's already been identified. Once identity is known, applyHello's own
// serverId-based merge is the authority: a fresh entry that turns out to
// share a confirmed Mac's serverId gets reconciled there instead.
function upsertPaired(doc, { origins, token, now, targetId }) {
  const normalized = uniqueOrigins(origins);
  const target = targetId ? doc.servers.find((s) => s.id === targetId) : null;
  const matchable = normalized.filter((o) => !isLoopbackOrigin(o));
  const existing = target || (matchable.length
    ? doc.servers.find((s) => !s.serverId && s.origins.some((o) => !isLoopbackOrigin(o) && matchable.includes(o)))
    : undefined);
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
  const federationEnabled = hello.federationEnabled === true;
  const twin = serverId ? doc.servers.find((s) => s.id !== clientId && s.serverId === serverId) : null;
  if (twin) {
    twin.token = server.token;
    twin.origins = uniqueOrigins([...server.origins, ...twin.origins]);
    twin.lastOrigin = server.lastOrigin;
    twin.name = name;
    twin.protocolVersion = protocolVersion;
    twin.federationEnabled = federationEnabled;
    doc.servers = doc.servers.filter((s) => s.id !== clientId);
    if (doc.activeId === clientId) doc.activeId = twin.id;
    return { server: twin, mergedFromId: clientId };
  }
  server.serverId = serverId;
  server.name = name;
  server.protocolVersion = protocolVersion;
  server.federationEnabled = federationEnabled;
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
function classifySessionCount(session, counts) {
  if (!session || session.isActive === false) return;
  if (ATTENTION_STATUSES.has(session.status)) counts.attention += 1;
  else if (session.status === "streaming") counts.running += 1;
}

function attentionCounts(sessions) {
  const counts = { attention: 0, running: 0 };
  for (const session of sessions || []) classifySessionCount(session, counts);
  return counts;
}

// Attention/running counts per peer serverId found in a gateway's pushed
// sessionList — only rows carrying a serverId (forwarded from a peer)
// contribute. Local rows (no serverId) are the gateway's own sessions,
// already counted toward that gateway's own idle-poll-derived link.counts.
function peerSessionCounts(sessions) {
  const byServer = new Map();
  for (const session of sessions || []) {
    if (!session || !session.serverId) continue;
    const counts = byServer.get(session.serverId) || { attention: 0, running: 0 };
    classifySessionCount(session, counts);
    byServer.set(session.serverId, counts);
  }
  return byServer;
}

// Which counts the Servers list should show for `server`: the active
// gateway's pushed peer counts when the active server federates and has
// actually forwarded rows for this server's serverId, otherwise this
// server's own idle-polled link.counts (the pre-federation and
// non-gateway-peer fallback).
function serverBadgeCounts(server, linkCounts, activeServer, gatewayCounts) {
  if (
    activeServer && activeServer.federationEnabled &&
    server.serverId && gatewayCounts && gatewayCounts.has(server.serverId)
  ) {
    return gatewayCounts.get(server.serverId);
  }
  return linkCounts || { attention: 0, running: 0 };
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
  isLoopbackOrigin,
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
  peerSessionCounts,
  serverBadgeCounts,
  otherAttentionTotal,
};
