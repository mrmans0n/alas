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
assert.deepEqual(
  full,
  { origins: ["http://100.64.1.5:8765", "http://192.168.1.20:8765"], code: "ABC123", originKinds: {} },
  "no kind prefixes → an empty originKinds map, exactly like a link built before kind encoding existed"
);

const legacy = registry.parsePairingLink("http://192.168.1.20:8765/?code=XYZ");
assert.deepEqual(legacy, { origins: ["http://192.168.1.20:8765"], code: "XYZ", originKinds: {} }, "legacy link → its own origin");

const lastFallback = registry.parsePairingLink("http://192.168.1.20:8765/?code=Q&hosts=http%3A%2F%2F10.0.0.2%3A8765");
assert.deepEqual(lastFallback.origins, ["http://10.0.0.2:8765", "http://192.168.1.20:8765"], "link origin is the last fallback");

// Regression (#1341): each origin's advertised-address kind rides in its
// own "kinds" query parameter — a same-length, same-order parallel list to
// "hosts" — never folded into an origin string itself, so a client that
// predates this encoding (an older Mac or web client redeeming a link a
// newer one generated) still parses "hosts" as plain origins and simply
// ignores the unrecognized "kinds" parameter. See test-hub-links.js for
// the behavioral half (pair()'s authoritative-origin check).
const withKinds = registry.parsePairingLink(
  "http://100.64.1.5:8765/?code=ABC123&hosts=http%3A%2F%2F100.64.1.5%3A8765,http%3A%2F%2Fproxy.example%3A8765&kinds=tailnet,custom"
);
assert.deepEqual(withKinds.origins, ["http://100.64.1.5:8765", "http://proxy.example:8765"]);
assert.deepEqual(withKinds.originKinds, { "http://100.64.1.5:8765": "tailnet", "http://proxy.example:8765": "custom" });

// An older client redeeming a link a newer one generated ignores "kinds"
// entirely and gets exactly the same origins from "hosts" either way.
assert.deepEqual(
  registry.parsePairingLink("http://100.64.1.5:8765/?code=ABC123&hosts=http%3A%2F%2F100.64.1.5%3A8765,http%3A%2F%2Fproxy.example%3A8765").origins,
  withKinds.origins,
  "hosts alone (kinds param absent) must still yield the identical origin list"
);

// An unrecognized kind value at a position is not one this format defines;
// that origin is simply treated as having no kind info at all — the
// origin itself was always parsed from "hosts" alone, so it is never
// dropped or corrupted by an unknown "kinds" entry.
const unknownKind = registry.parsePairingLink("http://10.0.0.1:8765/?code=ABC123&hosts=http%3A%2F%2F10.0.0.9%3A8765&kinds=evil");
assert.deepEqual(unknownKind.origins, ["http://10.0.0.9:8765", "http://10.0.0.1:8765"]);
assert.deepEqual(unknownKind.originKinds, {});

// A "kinds" list shorter than "hosts" leaves the remaining origins with no
// kind info rather than misaligning or throwing.
const shortKinds = registry.parsePairingLink(
  "http://10.0.0.1:8765/?code=ABC123&hosts=http%3A%2F%2F10.0.0.9%3A8765,http%3A%2F%2F10.0.0.8%3A8765&kinds=lan"
);
assert.deepEqual(shortKinds.originKinds, { "http://10.0.0.9:8765": "lan" });

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
        { id: "c-1", token: "t", origins: ["10.0.0.1:8765", "http://10.0.0.1:8765"], lastOrigin: "nope", hubEnabled: true },
        { id: "c-bad", origins: [] },
      ],
    }),
  });
  const doc = registry.load(storage, "http://a:1", "a", 1);
  assert.equal(doc.servers.length, 1, "entries without a token or origins are dropped");
  assert.deepEqual(doc.servers[0].origins, ["http://10.0.0.1:8765"], "origins normalized and deduped");
  assert.equal(doc.servers[0].lastOrigin, "http://10.0.0.1:8765", "unknown lastOrigin falls back to the first origin");
  assert.equal(Object.hasOwn(doc.servers[0], "hubEnabled"), false, "legacy hub flag is removed from loaded entries");
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

{
  // Regression: every pairing link includes
  // "localhost" alongside the server's real addresses, so two different
  // Macs on the same default port used to collide on that shared origin —
  // pairing the second Mac silently overwrote the first's registry entry
  // instead of adding a new one.
  const doc = { version: 1, activeId: null, servers: [] };
  const first = registry.upsertPaired(doc, { origins: ["http://localhost:8765", "http://10.0.0.1:8765"], token: "t1", now: 1 });
  const second = registry.upsertPaired(doc, { origins: ["http://localhost:8765", "http://10.0.0.2:8765"], token: "t2", now: 2 });
  assert.equal(second.rePaired, false, "a shared localhost origin must not merge two different Macs");
  assert.equal(doc.servers.length, 2);
  assert.notEqual(second.server.id, first.server.id);

  // Re-pairing the same Mac still matches on its real, non-loopback origin.
  const rePair = registry.upsertPaired(doc, { origins: ["http://localhost:8765", "http://10.0.0.1:8765"], token: "t3", now: 3 });
  assert.equal(rePair.rePaired, true, "a real shared origin still re-pairs in place");
  assert.equal(rePair.server.id, first.server.id);
  assert.equal(doc.servers.length, 2);
}

{
  // Regression: a non-loopback origin can also be
  // reused — a DHCP-reassigned LAN address, or two Macs behind the same
  // custom hostname — so origin overlap must stop being trusted once an
  // entry has confirmed its identity via hello. Before that point (no
  // serverId yet) origin overlap is still the only signal available and
  // re-pairing in place is correct.
  const doc = { version: 1, activeId: null, servers: [] };
  const first = registry.upsertPaired(doc, { origins: ["http://10.0.0.5:8765"], token: "t1", now: 1 });
  registry.applyHello(doc, first.server.id, { type: "hello", protocolVersion: 1, serverId: "srv-A", name: "Studio A" });
  assert.equal(first.server.serverId, "srv-A");

  // 10.0.0.5 got reassigned to a different Mac; pairing it must not merge
  // into srv-A's already-confirmed entry.
  const second = registry.upsertPaired(doc, { origins: ["http://10.0.0.5:8765"], token: "t2", now: 2 });
  assert.equal(second.rePaired, false, "an already-identified server must not be re-paired by origin overlap alone");
  assert.notEqual(second.server.id, first.server.id);
  assert.equal(doc.servers.length, 2);

  // If it later turns out to really be the same Mac (its hello reports the
  // same serverId), applyHello's own merge reconciles the two entries.
  const result = registry.applyHello(doc, second.server.id, { type: "hello", protocolVersion: 1, serverId: "srv-A", name: "Studio A" });
  assert.equal(result.mergedFromId, second.server.id);
  assert.equal(result.server.id, first.server.id, "the older, already-identified entry survives the merge");
  assert.equal(doc.servers.length, 1);
}

{
  // Regression: re-pairing a specific unauthorized/blocked
  // entry (the "Re-pair" flow) whose address changed entirely no longer
  // overlaps that entry's stored origins, so origin-based matching alone
  // could never find it again — it would silently create a second row
  // instead of updating the one the user picked. Passing targetId forces
  // the explicitly selected entry to be updated regardless of overlap.
  const doc = { version: 1, activeId: null, servers: [] };
  const original = registry.upsertPaired(doc, { origins: ["http://10.0.0.1:8765"], token: "old", now: 1 }).server;
  const result = registry.upsertPaired(doc, { origins: ["http://10.0.0.99:8765"], token: "new", now: 2, targetId: original.id });
  assert.equal(result.rePaired, true, "an explicit target is always treated as a re-pair");
  assert.equal(result.server.id, original.id);
  assert.equal(result.server.token, "new");
  assert.ok(result.server.origins.includes("http://10.0.0.99:8765"));
  assert.equal(doc.servers.length, 1, "no duplicate row is created");
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
  assert.equal(Object.hasOwn(server, "hubEnabled"), false);

  const blankName = registry.applyHello(doc, server.id, { type: "hello", protocolVersion: 1, serverId: "srv-A", name: "  " });
  assert.equal(blankName.server.name, "Studio", "blank hello name keeps the previous name");
  assert.equal(Object.hasOwn(blankName.server, "hubEnabled"), false);

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

// --- federationEnabled on hello -----------------------------------------------

{
  const doc = { version: 1, activeId: null, servers: [] };
  const { server } = registry.upsertPaired(doc, { origins: ["http://10.0.0.1:8765"], token: "t1", now: 1 });
  registry.applyHello(doc, server.id, { type: "hello", protocolVersion: 1, serverId: "srv-A", name: "Studio", federationEnabled: true });
  assert.equal(server.federationEnabled, true);
}

{
  const doc = { version: 1, activeId: null, servers: [] };
  const { server } = registry.upsertPaired(doc, { origins: ["http://10.0.0.2:8765"], token: "t2", now: 1 });
  registry.applyHello(doc, server.id, { type: "hello", protocolVersion: 1, serverId: "srv-B", name: "Legacy" });
  assert.equal(server.federationEnabled, false, "hello without federationEnabled means a pre-federation Mac");
}

// --- peerSessionCounts / serverBadgeCounts ------------------------------------

assert.deepEqual(
  [...registry.peerSessionCounts([
    { id: "1", serverId: "srv-B", status: "awaitingPermission" },
    { id: "2", serverId: "srv-B", status: "streaming" },
    { id: "3", serverId: "srv-C", status: "streaming" },
    { id: "4", status: "awaitingPermission" },
    { id: "5", serverId: "srv-B", status: "awaitingInput", isActive: false },
  ]).entries()],
  [["srv-B", { attention: 1, running: 1 }], ["srv-C", { attention: 0, running: 1 }]],
  "only serverId-tagged, still-active rows count; local rows and closed rows are excluded"
);
assert.deepEqual([...registry.peerSessionCounts(undefined).entries()], []);

{
  const gatewayCounts = new Map([["srv-B", { attention: 4, running: 0 }]]);
  const federatedActive = { federationEnabled: true };
  const idleCounts = { attention: 1, running: 0 };

  assert.deepEqual(
    registry.serverBadgeCounts({ serverId: "srv-B" }, idleCounts, federatedActive, gatewayCounts),
    { attention: 4, running: 0 },
    "a federated gateway's pushed count for a known peer wins over idle polling"
  );
  assert.deepEqual(
    registry.serverBadgeCounts({ serverId: "srv-Z" }, idleCounts, federatedActive, gatewayCounts),
    idleCounts,
    "a paired server the active Mac does not gateway falls back to idle polling"
  );
  assert.deepEqual(
    registry.serverBadgeCounts({ serverId: "srv-B" }, idleCounts, { federationEnabled: false }, gatewayCounts),
    idleCounts,
    "a non-federated active server never trusts gatewayCounts"
  );
  assert.deepEqual(
    registry.serverBadgeCounts({ serverId: null }, idleCounts, federatedActive, gatewayCounts),
    idleCounts,
    "a server with no confirmed serverId yet cannot be matched against gatewayCounts"
  );
  assert.deepEqual(
    registry.serverBadgeCounts({ serverId: "srv-B" }, null, federatedActive, new Map()),
    { attention: 0, running: 0 },
    "no link and no gateway data yet -> zero, not a crash"
  );
}

// --- hello.peers persistence ---------------------------------------------------

{
  const doc = { version: 1, activeId: null, servers: [] };
  const { server } = registry.upsertPaired(doc, { origins: ["http://10.0.0.3:8765"], token: "t1", now: 1 });
  registry.applyHello(doc, server.id, {
    type: "hello", protocolVersion: 1, serverId: "srv-GW", name: "Gateway", federationEnabled: true,
    peers: [{ serverId: "srv-B", name: "Peer B", state: "online" }, { serverId: "srv-C", name: "Peer C", state: "online" }, { serverId: null, name: "bad", state: "online" }],
  });
  assert.deepEqual(server.peers, ["srv-B", "srv-C"], "peer serverIds are extracted; malformed entries are dropped");
}

{
  const doc = { version: 1, activeId: null, servers: [] };
  const { server } = registry.upsertPaired(doc, { origins: ["http://10.0.0.4:8765"], token: "t1", now: 1 });
  registry.applyHello(doc, server.id, { type: "hello", protocolVersion: 1, serverId: "srv-GW2", name: "Gateway2" });
  assert.deepEqual(server.peers, [], "hello with no peers field means an empty roster, not a crash");
}

// peerSessionCounts seeds a zero entry for every known peer so an emptied-out
// gateway peer reads as authoritative zero, not "ungatewayed" (serverBadgeCounts
// only trusts gatewayCounts when it `has` an entry for that serverId).
assert.deepEqual(
  [...registry.peerSessionCounts(
    [{ id: "1", serverId: "srv-B", status: "awaitingPermission" }],
    ["srv-B", "srv-C"]
  ).entries()],
  [["srv-B", { attention: 1, running: 0 }], ["srv-C", { attention: 0, running: 0 }]],
  "srv-C is a known peer with no rows in this sessionList -> seeded zero, not absent"
);
assert.deepEqual(
  [...registry.peerSessionCounts([{ id: "1", serverId: "srv-B", status: "awaitingPermission" }]).entries()],
  [["srv-B", { attention: 1, running: 0 }]],
  "no knownServerIds argument behaves exactly as before (rows-only)"
);

{
  const gatewayCounts = registry.peerSessionCounts([], ["srv-B"]);
  assert.deepEqual(
    registry.serverBadgeCounts({ serverId: "srv-B" }, { attention: 3, running: 0 }, { federationEnabled: true }, gatewayCounts),
    { attention: 0, running: 0 },
    "a known peer with zero current rows overrides a stale nonzero idle-polled count"
  );
}

console.log("hub-registry tests passed");
