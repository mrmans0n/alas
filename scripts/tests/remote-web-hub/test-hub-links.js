const assert = require("node:assert/strict");

require("../../../Alas/Resources/RemoteWeb/hub-registry.js");
require("../../../Alas/Resources/RemoteWeb/hub-links.js");

const { createLinks, HANDSHAKE_TIMEOUT_MS, IDLE_POLL_MS, INITIAL_RECONNECT_MS, MAX_RECONNECT_MS } = globalThis.RemoteHubLinks;

function makeClock() {
  let now = 0;
  let seq = 0;
  const timers = new Map();
  return {
    setTimeout(fn, ms) { const id = ++seq; timers.set(id, { at: now + ms, fn }); return id; },
    clearTimeout(id) { timers.delete(id); },
    pending() { return timers.size; },
    async tick(ms) {
      const target = now + ms;
      for (;;) {
        const due = [...timers.entries()].filter(([, t]) => t.at <= target).sort((a, b) => a[1].at - b[1].at)[0];
        if (!due) break;
        now = due[1].at;
        timers.delete(due[0]);
        due[1].fn();
        await settle();
      }
      now = target;
    },
  };
}

// Let promise chains (probes, pairing) run to completion.
async function settle() { for (let i = 0; i < 10; i++) await new Promise((r) => setImmediate(r)); }

class FakeSocket {
  constructor(url, protocols) { this.url = url; this.protocols = protocols; this.readyState = 0; this.sent = []; this.closed = false; }
  send(text) { this.sent.push(JSON.parse(text)); }
  close() { this.closed = true; this.readyState = 3; }
  open() { this.readyState = 1; if (this.onopen) this.onopen(); }
  message(obj) { if (this.onmessage) this.onmessage({ data: JSON.stringify(obj) }); }
  drop() { this.readyState = 3; if (this.onclose) this.onclose(); }
}

function harness({ fetchImpl } = {}) {
  const clock = makeClock();
  const sockets = [];
  const events = [];
  const links = createLinks(
    {
      createSocket: (url, protocols) => { const s = new FakeSocket(url, protocols); sockets.push(s); return s; },
      fetch: fetchImpl || (() => Promise.reject(new Error("unreachable"))),
      setTimeout: clock.setTimeout,
      clearTimeout: clock.clearTimeout,
    },
    {
      onStateChange: (l) => events.push([l.id, l.state, l.role]),
      onHello: (l, hello) => events.push([l.id, "hello", hello.serverId]),
      onLegacy: (l) => events.push([l.id, "legacy"]),
      onMessage: (l, m) => events.push([l.id, "msg", m.type]),
      onCounts: (l) => events.push([l.id, "counts", l.counts.attention, l.counts.running]),
    }
  );
  return { clock, sockets, events, links };
}

const serverA = { id: "a", origins: ["http://10.0.0.1:8765", "http://100.64.0.1:8765"], lastOrigin: "http://100.64.0.1:8765", token: "tok-a" };
const serverB = { id: "b", origins: ["http://10.0.0.2:8765"], lastOrigin: "http://10.0.0.2:8765", token: "tok-b" };

(async () => {
  // --- origin order and fallback --------------------------------------------
  {
    const { clock, sockets, links } = harness();
    links.add(serverA);
    links.setActive("a");
    links.connect("a");
    assert.equal(sockets.length, 1);
    assert.equal(sockets[0].url, "ws://100.64.0.1:8765/ws", "lastOrigin is tried first");
    assert.deepEqual(sockets[0].protocols, ["tok-a"], "token rides as the subprotocol");
    assert.equal(links.get("a").state, "connecting");

    await clock.tick(HANDSHAKE_TIMEOUT_MS);
    assert.equal(sockets[0].closed, true, "handshake timeout abandons the socket");
    assert.equal(sockets.length, 2);
    assert.equal(sockets[1].url, "ws://10.0.0.1:8765/ws", "next origin in order");

    sockets[1].open();
    assert.equal(links.get("a").state, "online");
    assert.equal(links.get("a").lastOrigin, "http://10.0.0.1:8765", "the origin that answered is promoted");
  }

  // --- hello / legacy / active message routing ------------------------------
  {
    const { sockets, events, links } = harness();
    links.add(serverA);
    links.setActive("a");
    links.connect("a");
    sockets[0].open();
    sockets[0].message({ type: "hello", protocolVersion: 1, serverId: "srv-A", name: "Studio" });
    assert.ok(events.some((e) => e[0] === "a" && e[1] === "hello" && e[2] === "srv-A"));
    assert.equal(links.get("a").legacy, false);
    sockets[0].message({ type: "sessionList", sessions: [{ id: "s", status: "awaitingInput" }] });
    assert.ok(events.some((e) => e[1] === "counts" && e[2] === 1), "active link still derives counts");
    assert.ok(events.some((e) => e[1] === "msg" && e[2] === "sessionList"), "active link forwards sessionList to the app");
    sockets[0].message({ type: "transcriptDelta" });
    assert.ok(events.some((e) => e[1] === "msg" && e[2] === "transcriptDelta"));
  }
  {
    const { sockets, events, links } = harness();
    links.add(serverA);
    links.setActive("a");
    links.connect("a");
    sockets[0].open();
    sockets[0].message({ type: "sessionList", sessions: [] });
    assert.equal(links.get("a").legacy, true, "a first frame that is not hello marks the server legacy");
    assert.ok(events.some((e) => e[1] === "legacy"));
    assert.ok(events.some((e) => e[1] === "msg" && e[2] === "sessionList"), "the legacy first frame is still delivered");
  }

  // --- idle polling and counts ----------------------------------------------
  {
    const { clock, sockets, events, links } = harness();
    links.add(serverA);
    links.add(serverB);
    links.setActive("a");
    links.connect("b");
    sockets[0].open();
    assert.deepEqual(sockets[0].sent, [{ type: "listSessions" }], "idle link asks for the list on open");
    sockets[0].message({ type: "hello", protocolVersion: 1, serverId: "srv-B", name: "Laptop" });
    sockets[0].message({ type: "sessionList", sessions: [{ id: "1", status: "awaitingPermission" }, { id: "2", status: "streaming" }] });
    assert.deepEqual(links.get("b").counts, { attention: 1, running: 1 });
    assert.ok(!events.some((e) => e[0] === "b" && e[1] === "msg"), "idle links never forward messages to the app");
    await clock.tick(IDLE_POLL_MS);
    assert.equal(sockets[0].sent.length, 2, "polls again after IDLE_POLL_MS");
    sockets[0].message({ type: "sessionList", sessions: [{ id: "1", status: "awaitingPermission" }, { id: "2", status: "streaming" }] });
    assert.equal(events.filter((e) => e[0] === "b" && e[1] === "counts").length, 1, "unchanged counts do not re-notify");
  }

  // --- unauthorized vs offline ----------------------------------------------
  {
    const { clock, sockets, links } = harness({ fetchImpl: () => Promise.resolve({ ok: true, status: 200 }) });
    links.add(serverB);
    links.setActive("b");
    links.connect("b");
    sockets[0].drop();
    await settle();
    assert.equal(links.get("b").state, "unauthorized", "socket refused but /health answers → token revoked");
    assert.equal(clock.pending(), 0, "no reconnect timer while unauthorized");
    links.connect("b");
    assert.equal(sockets.length, 1, "connect() is a no-op while unauthorized");
    links.retry("b");
    assert.equal(sockets.length, 2, "retry() clears unauthorized and reconnects");
  }
  {
    const { clock, sockets, links } = harness();
    links.add(serverB);
    links.setActive("b");
    links.connect("b");
    sockets[0].drop();
    await settle();
    assert.equal(links.get("b").state, "offline", "socket refused and /health unreachable → offline");
    await clock.tick(INITIAL_RECONNECT_MS - 1);
    assert.equal(sockets.length, 1);
    await clock.tick(1);
    assert.equal(sockets.length, 2, "reconnects after the initial delay");
    sockets[1].drop();
    await settle();
    await clock.tick(INITIAL_RECONNECT_MS * 2);
    assert.equal(sockets.length, 3, "delay doubles");
    for (let i = 0; i < 8; i++) { sockets[sockets.length - 1].drop(); await settle(); await clock.tick(MAX_RECONNECT_MS); }
    const before = sockets.length;
    sockets[sockets.length - 1].drop();
    await settle();
    await clock.tick(MAX_RECONNECT_MS - 1);
    assert.equal(sockets.length, before, "capped at MAX_RECONNECT_MS");
    await clock.tick(1);
    assert.equal(sockets.length, before + 1);
    sockets[sockets.length - 1].open();
    sockets[sockets.length - 1].drop();
    await settle();
    await clock.tick(INITIAL_RECONNECT_MS);
    assert.equal(sockets.length, before + 2, "a successful open resets the backoff");
  }

  // --- visibility ------------------------------------------------------------
  {
    const { clock, sockets, links } = harness();
    links.add(serverA);
    links.add(serverB);
    links.setActive("a");
    links.connectAll();
    sockets[0].open();
    sockets[1].open();
    links.setVisible(false);
    assert.equal(links.get("a").state, "online", "the active link stays up when hidden");
    assert.equal(sockets[1].closed, true, "idle links close when hidden");
    assert.equal(links.get("b").state, "idle");
    await clock.tick(MAX_RECONNECT_MS);
    assert.equal(sockets.length, 2, "no reconnects while hidden");
    links.setVisible(true);
    assert.equal(sockets.length, 3, "idle links reconnect when visible again");
  }

  // --- role switching --------------------------------------------------------
  {
    const { sockets, links } = harness();
    links.add(serverA);
    links.add(serverB);
    links.setActive("a");
    links.connectAll();
    sockets[0].open();
    sockets[1].open();
    links.sendActive({ type: "listSessions" });
    assert.deepEqual(sockets[0].sent, [{ type: "listSessions" }]);
    const b = links.setActive("b");
    assert.equal(b.role, "active");
    assert.equal(links.get("a").role, "idle");
    assert.ok(sockets[0].sent.length >= 2, "the demoted link starts polling");
    links.sendActive({ type: "subscribe", sessionId: "s" });
    assert.deepEqual(sockets[1].sent[sockets[1].sent.length - 1], { type: "subscribe", sessionId: "s" });
    assert.equal(links.get("b").socket, sockets[1], "switching reuses the existing socket");
  }

  // --- update / remove -------------------------------------------------------
  {
    const { sockets, links } = harness();
    links.add(serverA);
    links.setActive("a");
    links.connect("a");
    sockets[0].open();
    links.update({ ...serverA, token: "tok-a2", origins: ["http://10.0.0.9:8765"], lastOrigin: "http://10.0.0.9:8765" });
    assert.equal(sockets[0].closed, true, "re-pair drops the old socket");
    assert.equal(sockets[1].url, "ws://10.0.0.9:8765/ws");
    assert.deepEqual(sockets[1].protocols, ["tok-a2"]);
    links.remove("a");
    assert.equal(sockets[1].closed, true);
    assert.equal(links.get("a"), null);
    assert.equal(links.activeLink(), null);
  }

  // --- pair ------------------------------------------------------------------
  {
    const calls = [];
    const { links } = harness({
      fetchImpl: (url) => {
        calls.push(url);
        if (url.startsWith("http://10.0.0.1")) return Promise.reject(new Error("net"));
        return Promise.resolve({ ok: true, status: 200, json: () => Promise.resolve({ token: "fresh" }) });
      },
    });
    const result = await links.pair(["http://10.0.0.1:8765", "http://100.64.0.1:8765"], "CODE", "phone");
    assert.deepEqual(result, { origin: "http://100.64.0.1:8765", token: "fresh" });
    assert.deepEqual(calls, ["http://10.0.0.1:8765/pair", "http://100.64.0.1:8765/pair"]);
  }
  {
    const { links } = harness({ fetchImpl: () => Promise.resolve({ ok: false, status: 401 }) });
    await assert.rejects(links.pair(["http://10.0.0.1:8765", "http://10.0.0.2:8765"], "CODE", "phone"), (err) => err.reason === "expired");
  }
  {
    const { links } = harness({ fetchImpl: () => Promise.resolve({ ok: false, status: 403 }) });
    await assert.rejects(links.pair(["http://10.0.0.1:8765"], "CODE", "phone"), (err) => err.reason === "origin");
  }
  {
    const { links } = harness();
    await assert.rejects(links.pair(["http://10.0.0.1:8765", "http://10.0.0.2:8765"], "CODE", "phone"), (err) => err.reason === "net");
  }
  {
    const { clock, links } = harness({ fetchImpl: () => new Promise(() => {}) });
    const pending = links.pair(["http://10.0.0.1:8765"], "CODE", "phone");
    pending.catch(() => {}); // observed immediately so the rejection below is never "unhandled" during the awaited tick
    await clock.tick(globalThis.RemoteHubLinks.PAIR_TIMEOUT_MS);
    await assert.rejects(pending, (err) => err.reason === "net");
  }

  console.log("hub-links tests passed");
})().catch((err) => { console.error(err); process.exit(1); });
