const assert = require("node:assert/strict");

require("../../../Alas/Resources/RemoteWeb/hub-registry.js");

const registry = globalThis.RemoteHubRegistry;

function fakeStorage(initial = {}) {
  const map = new Map(Object.entries(initial));
  return {
    getItem: (key) => (map.has(key) ? map.get(key) : null),
    setItem: (key, value) => map.set(key, String(value)),
    removeItem: (key) => map.delete(key),
    dump: () => Object.fromEntries(map),
  };
}

// --- normalizeOrigin ---------------------------------------------------------

assert.equal(registry.normalizeOrigin("100.64.1.5:8765"), "http://100.64.1.5:8765");
assert.equal(registry.normalizeOrigin("http://100.64.1.5:8765"), "http://100.64.1.5:8765");
assert.equal(registry.normalizeOrigin("HTTP://Nacho-MBP.local:8765/"), "http://nacho-mbp.local:8765");
assert.equal(registry.normalizeOrigin("[::1]:8765"), "http://[::1]:8765");
assert.equal(registry.normalizeOrigin("nacho-mbp.local"), "http://nacho-mbp.local:8765", "no port → Alas default port");
assert.equal(registry.normalizeOrigin("https://app.alas.build"), "https://app.alas.build", "https keeps its default port");
assert.equal(registry.normalizeOrigin("ftp://x:1"), null);
assert.equal(registry.normalizeOrigin("http://user:pw@host:1"), null);
assert.equal(registry.normalizeOrigin(""), null);
assert.equal(registry.normalizeOrigin("not a url at all"), null);
assert.equal(registry.normalizeOrigin("http://alas.lan"), "http://alas.lan", "an explicit scheme with no port is left alone, not defaulted (e.g. a reverse proxy on port 80)");

// --- parsePairingLink --------------------------------------------------------

const full = registry.parsePairingLink(
  "http://100.64.1.5:8765/?code=ABC123&hosts=http%3A%2F%2F100.64.1.5%3A8765,http%3A%2F%2F192.168.1.20%3A8765"
);
assert.deepEqual(full, { origins: ["http://100.64.1.5:8765", "http://192.168.1.20:8765"], code: "ABC123" });

const legacy = registry.parsePairingLink("http://192.168.1.20:8765/?code=XYZ");
assert.deepEqual(legacy, { origins: ["http://192.168.1.20:8765"], code: "XYZ" }, "legacy link → its own origin");

const lastFallback = registry.parsePairingLink("http://192.168.1.20:8765/?code=Q&hosts=http%3A%2F%2F10.0.0.2%3A8765");
assert.deepEqual(lastFallback.origins, ["http://10.0.0.2:8765", "http://192.168.1.20:8765"], "link origin is the last fallback");

assert.equal(registry.parsePairingLink("http://192.168.1.20:8765/"), null, "no code → not a pairing link");
assert.equal(registry.parsePairingLink("garbage"), null);
assert.equal(registry.parsePairingLink(""), null);

assert.deepEqual(registry.parseManualPairing("192.168.1.20", " ABC "), { origins: ["http://192.168.1.20:8765"], code: "ABC" });
assert.equal(registry.parseManualPairing("192.168.1.20", ""), null);
assert.equal(registry.parseManualPairing("", "ABC"), null);

// --- load / migrate ----------------------------------------------------------

{
  const storage = fakeStorage({ "alas.remote.token": "legacy-token" });
  const doc = registry.load(storage, "http://192.168.1.20:8765", "192.168.1.20", 1000);
  assert.equal(doc.version, 1);
  assert.equal(doc.servers.length, 1);
  const [server] = doc.servers;
  assert.equal(server.token, "legacy-token");
  assert.deepEqual(server.origins, ["http://192.168.1.20:8765"]);
  assert.equal(server.lastOrigin, "http://192.168.1.20:8765");
  assert.equal(server.name, "192.168.1.20");
  assert.equal(server.serverId, null);
  assert.equal(server.addedAt, 1000);
  assert.equal(doc.activeId, server.id);
  assert.equal(storage.getItem("alas.remote.token"), null, "legacy key removed");
  assert.ok(storage.getItem("alas.remote.hub"), "migrated document persisted");
}

{
  const storage = fakeStorage();
  const doc = registry.load(storage, "http://192.168.1.20:8765", "192.168.1.20", 1);
  assert.deepEqual(doc, { version: 1, activeId: null, servers: [] });
  assert.equal(storage.getItem("alas.remote.hub"), null, "nothing persisted for an empty hub");
}

{
  const storage = fakeStorage({ "alas.remote.hub": "{not json" });
  const doc = registry.load(storage, "http://a:1", "a", 1);
  assert.deepEqual(doc.servers, []);
}

{
  const storage = fakeStorage({
    "alas.remote.hub": JSON.stringify({
      version: 1,
      activeId: "gone",
      servers: [
        { id: "c-1", token: "t", origins: ["10.0.0.1:8765", "http://10.0.0.1:8765"], lastOrigin: "nope" },
        { id: "c-bad", origins: [] },
      ],
    }),
  });
  const doc = registry.load(storage, "http://a:1", "a", 1);
  assert.equal(doc.servers.length, 1, "entries without a token or origins are dropped");
  assert.deepEqual(doc.servers[0].origins, ["http://10.0.0.1:8765"], "origins normalized and deduped");
  assert.equal(doc.servers[0].lastOrigin, "http://10.0.0.1:8765", "unknown lastOrigin falls back to the first origin");
  assert.equal(doc.activeId, "c-1", "dangling activeId falls back to the first server");
}

// --- upsertPaired ------------------------------------------------------------

{
  const doc = { version: 1, activeId: null, servers: [] };
  const first = registry.upsertPaired(doc, { origins: ["http://10.0.0.1:8765", "http://100.64.0.1:8765"], token: "t1", now: 5 });
  assert.equal(first.rePaired, false);
  assert.equal(doc.servers.length, 1);
  assert.equal(doc.activeId, first.server.id, "first server becomes active");
  assert.equal(first.server.lastOrigin, "http://10.0.0.1:8765");

  const again = registry.upsertPaired(doc, { origins: ["http://100.64.0.1:8765", "http://172.16.0.9:8765"], token: "t2", now: 6 });
  assert.equal(again.rePaired, true, "overlapping origin → re-pair in place");
  assert.equal(again.server.id, first.server.id);
  assert.equal(again.server.token, "t2");
  assert.deepEqual(again.server.origins, ["http://100.64.0.1:8765", "http://172.16.0.9:8765", "http://10.0.0.1:8765"]);
  assert.equal(again.server.lastOrigin, "http://100.64.0.1:8765");

  const other = registry.upsertPaired(doc, { origins: ["http://10.0.0.2:8765"], token: "t3", now: 7 });
  assert.equal(other.rePaired, false);
  assert.equal(doc.servers.length, 2);
  assert.equal(doc.activeId, first.server.id, "active server is not changed by adding another");
}

// --- applyHello --------------------------------------------------------------

{
  const doc = { version: 1, activeId: null, servers: [] };
  const { server } = registry.upsertPaired(doc, { origins: ["http://10.0.0.1:8765"], token: "t1", now: 1 });
  const result = registry.applyHello(doc, server.id, { type: "hello", protocolVersion: 1, serverId: "srv-A", name: "Studio", hubEnabled: true });
  assert.equal(result.mergedFromId, null);
  assert.equal(server.serverId, "srv-A");
  assert.equal(server.name, "Studio");
  assert.equal(server.protocolVersion, 1);
  assert.equal(server.hubEnabled, true);

  const blankName = registry.applyHello(doc, server.id, { type: "hello", protocolVersion: 1, serverId: "srv-A", name: "  " });
  assert.equal(blankName.server.name, "Studio", "blank hello name keeps the previous name");
  assert.equal(blankName.server.hubEnabled, false, "missing hubEnabled means off");

  assert.equal(registry.applyHello(doc, "nope", { type: "hello", serverId: "x", name: "y" }), null);
}

{
  // The same Mac paired twice (e.g. once by LAN address, once by tailnet):
  // the hello's serverId reveals the twin; the older entry survives.
  const doc = { version: 1, activeId: null, servers: [] };
  const older = registry.upsertPaired(doc, { origins: ["http://10.0.0.1:8765"], token: "old", now: 1 }).server;
  registry.applyHello(doc, older.id, { type: "hello", protocolVersion: 1, serverId: "srv-A", name: "Studio" });
  const newer = registry.upsertPaired(doc, { origins: ["http://100.64.0.1:8765"], token: "new", now: 2 }).server;
  registry.setActive(doc, newer.id);
  const result = registry.applyHello(doc, newer.id, { type: "hello", protocolVersion: 1, serverId: "srv-A", name: "Studio" });
  assert.equal(result.mergedFromId, newer.id);
  assert.equal(result.server.id, older.id);
  assert.equal(doc.servers.length, 1);
  assert.equal(result.server.token, "new", "merged entry takes the fresh token");
  assert.deepEqual(result.server.origins, ["http://100.64.0.1:8765", "http://10.0.0.1:8765"]);
  assert.equal(result.server.lastOrigin, "http://100.64.0.1:8765");
  assert.equal(doc.activeId, older.id, "active id follows the surviving entry");
}

// --- forget / active / lastOrigin -------------------------------------------

{
  const doc = { version: 1, activeId: null, servers: [] };
  const a = registry.upsertPaired(doc, { origins: ["http://10.0.0.1:8765"], token: "a", now: 1 }).server;
  const b = registry.upsertPaired(doc, { origins: ["http://10.0.0.2:8765"], token: "b", now: 2 }).server;
  registry.setActive(doc, b.id);
  assert.equal(doc.activeId, b.id);
  registry.setActive(doc, "missing");
  assert.equal(doc.activeId, b.id, "unknown id is ignored");

  registry.setLastOrigin(doc, a.id, "http://10.0.0.1:8765");
  assert.equal(a.lastOrigin, "http://10.0.0.1:8765");
  registry.setLastOrigin(doc, a.id, "http://not-listed:1");
  assert.equal(a.lastOrigin, "http://10.0.0.1:8765", "lastOrigin must be one of the server's origins");

  registry.forgetServer(doc, b.id);
  assert.equal(doc.servers.length, 1);
  assert.equal(doc.activeId, null, "forgetting the active server clears activeId");
  assert.equal(registry.fallbackActiveId(doc, []), a.id, "no online servers → first remaining");
  registry.forgetServer(doc, a.id);
  assert.equal(registry.fallbackActiveId(doc, []), null);
}

{
  const doc = { version: 1, activeId: null, servers: [] };
  const a = registry.upsertPaired(doc, { origins: ["http://10.0.0.1:8765"], token: "a", now: 1 }).server;
  const b = registry.upsertPaired(doc, { origins: ["http://10.0.0.2:8765"], token: "b", now: 2 }).server;
  assert.equal(registry.fallbackActiveId(doc, [b.id]), b.id, "first ONLINE server wins");
  assert.equal(registry.fallbackActiveId(doc, [a.id, b.id]), a.id, "ties break in registry order");
}

// --- counts ------------------------------------------------------------------

assert.deepEqual(
  registry.attentionCounts([
    { id: "1", status: "awaitingPermission" },
    { id: "2", status: "awaitingInput" },
    { id: "3", status: "streaming" },
    { id: "4", status: "idle" },
    { id: "5", status: "awaitingPermission", isActive: false },
    null,
  ]),
  { attention: 2, running: 1 }
);
assert.deepEqual(registry.attentionCounts(undefined), { attention: 0, running: 0 });
assert.equal(
  registry.otherAttentionTotal(
    [{ id: "a", counts: { attention: 2, running: 0 } }, { id: "b", counts: { attention: 3, running: 1 } }, { id: "c", counts: { attention: 1, running: 0 } }],
    "b"
  ),
  3,
  "sums attention across every server but the active one"
);

console.log("hub-registry tests passed");
