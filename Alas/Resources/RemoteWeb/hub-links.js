// One WebSocket link per paired server. app.js drives the ACTIVE link through
// sendActive()/onMessage exactly as it drove its single socket; idle links
// only keep attention counts fresh. Sockets, timers, and fetch are injected so
// node tests can drive every transition deterministically.
//
// deps:  { createSocket(url, protocols), fetch(url, init), setTimeout(fn, ms), clearTimeout(id) }
// hooks: { onStateChange(link), onHello(link, hello), onLegacy(link), onMessage(link, msg),
//          onCounts(link), onOriginChange(link, origin) }
// link:  { id, origins, lastOrigin, token, role: "active"|"idle",
//          state: "idle"|"connecting"|"online"|"offline"|"unauthorized"|"blocked",
//          counts: {attention, running}, legacy, socket }

const HANDSHAKE_TIMEOUT_MS = 4000;
const PAIR_TIMEOUT_MS = 4000;
const PROBE_TIMEOUT_MS = 4000;
const IDLE_POLL_MS = 30 * 1000;
const INITIAL_RECONNECT_MS = 1500;
const MAX_RECONNECT_MS = 30000;

function wsUrl(origin) {
  return origin.replace(/^http/i, "ws") + "/ws";
}

function createLinks(deps, hooks) {
  const h = hooks || {};
  const links = new Map();
  let activeId = null;
  let visible = true;
  let idleAllowed = false;   // true once connectAll() has run; see disableIdle()

  function notify(link) { if (h.onStateChange) h.onStateChange(link); }
  function setState(link, state) {
    if (link.state === state) return;
    link.state = state;
    notify(link);
  }

  function add(server) {
    const link = {
      id: server.id,
      origins: [...server.origins],
      lastOrigin: server.lastOrigin || server.origins[0],
      token: server.token,
      role: "idle",
      state: "idle",
      socket: null,
      pendingSocket: null,
      attempt: 0,
      reconnectDelay: INITIAL_RECONNECT_MS,
      reconnectTimer: null,
      pollTimer: null,
      awaitingHello: false,
      legacy: false,
      counts: { attention: 0, running: 0 },
    };
    links.set(link.id, link);
    return link;
  }

  function get(id) { return links.get(id) || null; }
  function all() { return [...links.values()]; }
  function activeLink() { return activeId ? links.get(activeId) || null : null; }

  function clearTimers(link) {
    if (link.reconnectTimer) { deps.clearTimeout(link.reconnectTimer); link.reconnectTimer = null; }
    stopPolling(link);
  }

  // Closes both the adopted socket (`link.socket`) and, if a connection
  // attempt is still mid-handshake, the not-yet-adopted one
  // (`link.pendingSocket`) — otherwise a teardown mid-attempt (e.g. `remove()`
  // right after `update()` reconnects) orphans that socket: never closed,
  // and (on a real WebSocket) a live connection leaked indefinitely.
  function closeSocket(link) {
    const socket = link.socket;
    link.socket = null;
    if (socket) {
      socket.onopen = socket.onmessage = socket.onclose = socket.onerror = null;
      try { socket.close(); } catch (_) {}
    }
    const pending = link.pendingSocket;
    link.pendingSocket = null;
    if (pending) {
      pending.onopen = pending.onmessage = pending.onclose = pending.onerror = null;
      try { pending.close(); } catch (_) {}
    }
  }

  // Invalidates in-flight handshakes (their `attempt` no longer matches) and
  // drops the live socket without changing `state`.
  function teardown(link) {
    link.attempt += 1;
    clearTimers(link);
    closeSocket(link);
  }

  function remove(id) {
    const link = links.get(id);
    if (!link) return;
    teardown(link);
    links.delete(id);
    if (activeId === id) activeId = null;
  }

  // Re-pair: fresh token and origins; drop the old socket and reconnect.
  function update(server) {
    const link = links.get(server.id);
    if (!link) return null;
    teardown(link);
    link.origins = [...server.origins];
    link.lastOrigin = server.lastOrigin || server.origins[0];
    link.token = server.token;
    link.reconnectDelay = INITIAL_RECONNECT_MS;
    link.state = "idle";
    notify(link);
    connect(link.id);
    return link;
  }

  function setActive(id) {
    const previous = activeLink();
    if (previous && previous.id !== id) {
      previous.role = "idle";
      if (previous.state === "online") startPolling(previous);
      notify(previous);
    }
    activeId = id;
    const link = links.get(id);
    if (!link) return null;
    link.role = "active";
    stopPolling(link);
    notify(link);
    return link;
  }

  function sendTo(link, obj) {
    if (link && link.socket && link.socket.readyState === 1) link.socket.send(JSON.stringify(obj));
  }
  function sendActive(obj) { sendTo(activeLink(), obj); }

  function orderedOrigins(link) {
    if (!link.lastOrigin || !link.origins.includes(link.lastOrigin)) return [...link.origins];
    return [link.lastOrigin, ...link.origins.filter((o) => o !== link.lastOrigin)];
  }

  function connect(id) {
    const link = links.get(id);
    if (!link) return;
    if (link.state === "connecting" || link.state === "online" || link.state === "unauthorized" || link.state === "blocked") return;
    if (!visible && link.role !== "active") return;
    clearTimers(link);
    closeSocket(link);
    const attempt = ++link.attempt;
    setState(link, "connecting");
    attemptOrigin(link, orderedOrigins(link), 0, attempt);
  }

  // Tries one origin; on timeout or refusal moves to the next. `attempt`
  // guards against a stale handshake adopting a socket after a teardown.
  function attemptOrigin(link, order, index, attempt) {
    if (attempt !== link.attempt) return;
    if (index >= order.length) { onAllOriginsFailed(link, order, attempt); return; }
    const origin = order[index];
    let socket;
    try { socket = deps.createSocket(wsUrl(origin), [link.token]); }
    catch (_) { attemptOrigin(link, order, index + 1, attempt); return; }
    link.pendingSocket = socket;
    let settled = false;
    const timer = deps.setTimeout(() => {
      if (settled) return;
      settled = true;
      socket.onopen = socket.onclose = socket.onerror = null;
      try { socket.close(); } catch (_) {}
      attemptOrigin(link, order, index + 1, attempt);
    }, HANDSHAKE_TIMEOUT_MS);
    socket.onopen = () => {
      if (settled) return;
      settled = true;
      deps.clearTimeout(timer);
      if (attempt !== link.attempt) { try { socket.close(); } catch (_) {} return; }
      adopt(link, socket, origin);
    };
    socket.onerror = () => {};
    socket.onclose = () => {
      if (settled) return;
      settled = true;
      deps.clearTimeout(timer);
      attemptOrigin(link, order, index + 1, attempt);
    };
  }

  function adopt(link, socket, origin) {
    if (link.pendingSocket === socket) link.pendingSocket = null;
    // A successful connect on an origin other than the remembered one is
    // worth persisting — otherwise every future reload retries the dead
    // origin first and pays its full handshake timeout again before
    // falling through to the one that actually works.
    if (link.lastOrigin !== origin && h.onOriginChange) h.onOriginChange(link, origin);
    link.socket = socket;
    link.lastOrigin = origin;
    link.reconnectDelay = INITIAL_RECONNECT_MS;
    link.awaitingHello = true;
    link.legacy = false;
    socket.onmessage = (event) => {
      if (link.socket !== socket) return;
      let msg;
      try { msg = JSON.parse(event.data); } catch (_) { return; }
      receive(link, msg);
    };
    socket.onclose = () => {
      if (link.socket !== socket) return;
      link.socket = null;
      stopPolling(link);
      setState(link, "offline");
      scheduleReconnect(link);
    };
    socket.onerror = () => {};
    setState(link, "online");
    if (link.role === "idle") startPolling(link);
  }

  function receive(link, msg) {
    if (!msg || typeof msg.type !== "string") return;
    if (link.awaitingHello) {
      link.awaitingHello = false;
      if (msg.type === "hello") { if (h.onHello) h.onHello(link, msg); return; }
      // A pre-hub Mac never says hello; treat its first frame as ordinary.
      link.legacy = true;
      if (h.onLegacy) h.onLegacy(link);
    } else if (msg.type === "hello") {
      if (h.onHello) h.onHello(link, msg);
      return;
    }
    if (msg.type === "sessionList") {
      const next = globalThis.RemoteHubRegistry.attentionCounts(msg.sessions);
      if (next.attention !== link.counts.attention || next.running !== link.counts.running) {
        link.counts = next;
        if (h.onCounts) h.onCounts(link);
      }
      if (link.role !== "active") return;
    }
    if (link.role === "active" && h.onMessage) h.onMessage(link, msg);
  }

  function scheduleReconnect(link) {
    if (link.reconnectTimer) return;
    if (!visible && link.role !== "active") return;
    const delay = link.reconnectDelay;
    link.reconnectDelay = Math.min(link.reconnectDelay * 2, MAX_RECONNECT_MS);
    link.reconnectTimer = deps.setTimeout(() => {
      link.reconnectTimer = null;
      connect(link.id);
    }, delay);
  }

  // Every origin refused the handshake. A reachable /health means the Mac is
  // up but rejected the token (revoked → "Pair again"); a 403 means the Mac
  // is up but its origin policy rejects this address ("Blocked" → tell the
  // user where to fix it, not to re-pair); otherwise the Mac is simply
  // unreachable and we keep retrying.
  function onAllOriginsFailed(link, order, attempt) {
    probeAny(order).then(({ reachable, blocked }) => {
      if (attempt !== link.attempt) return;
      if (reachable) { setState(link, "unauthorized"); return; }
      if (blocked) { setState(link, "blocked"); return; }
      setState(link, "offline");
      scheduleReconnect(link);
    });
  }

  function probeAny(origins) {
    return Promise.all(origins.map(probe)).then((statuses) => ({
      reachable: statuses.some((s) => s != null && s >= 200 && s < 300),
      blocked: statuses.some((s) => s === 403),
    }));
  }

  // Resolves the /health response's status code, or null on timeout/network
  // failure — distinct from a 403, which means the Mac answered but this
  // origin isn't on its allowlist.
  function probe(origin) {
    return new Promise((resolve) => {
      let done = false;
      const timer = deps.setTimeout(() => { if (!done) { done = true; resolve(null); } }, PROBE_TIMEOUT_MS);
      Promise.resolve()
        .then(() => deps.fetch(origin + "/health", { method: "GET" }))
        .then(
          (res) => { if (!done) { done = true; deps.clearTimeout(timer); resolve(res ? res.status : null); } },
          () => { if (!done) { done = true; deps.clearTimeout(timer); resolve(null); } }
        );
    });
  }

  function startPolling(link) {
    stopPolling(link);
    if (!visible || link.role !== "idle" || link.state !== "online") return;
    sendTo(link, { type: "listSessions" });
    link.pollTimer = deps.setTimeout(() => {
      link.pollTimer = null;
      startPolling(link);
    }, IDLE_POLL_MS);
  }

  function stopPolling(link) {
    if (link.pollTimer) { deps.clearTimeout(link.pollTimer); link.pollTimer = null; }
  }

  function connectAll() {
    idleAllowed = true;
    for (const link of links.values()) connect(link.id);
  }

  // Closes every non-active socket (page hidden, or hub flag off). Does not
  // itself change `idleAllowed` — it's also called on a mere visibility
  // change (setVisible(false)), which must not "turn off" idle links for
  // good the way disableIdle() below does.
  function suspendIdle() {
    for (const link of links.values()) {
      if (link.role === "active") continue;
      teardown(link);
      if (link.state !== "unauthorized") setState(link, "idle");
    }
  }

  // Called specifically when the hub feature itself turns off, as opposed to
  // the page merely going to the background. Idle links must stay suspended
  // across a later visibility change until the hub is re-enabled — a plain
  // suspendIdle() (backgrounding) leaves them eligible to resume.
  function disableIdle() {
    idleAllowed = false;
    suspendIdle();
  }

  function setVisible(next) {
    visible = !!next;
    if (!visible) { suspendIdle(); return; }
    for (const link of links.values()) {
      // The active link always resumes on visible-again regardless of the
      // hub flag — that's ordinary single-server behavior. An idle link
      // only resumes if the hub is actually enabled; otherwise a mere
      // visibility cycle would resurrect the idle sockets disableIdle()
      // just suspended.
      if (link.role !== "active" && !idleAllowed) continue;
      if (link.state === "online" && link.role === "idle") startPolling(link);
      else connect(link.id);
    }
  }

  // Manual retry (gate button) or after a re-pair cleared "unauthorized".
  function retry(id) {
    const link = links.get(id);
    if (!link) return;
    teardown(link);
    link.reconnectDelay = INITIAL_RECONNECT_MS;
    link.state = "idle";
    notify(link);
    connect(id);
  }

  function pairError(reason) {
    const err = new Error("pairing failed: " + reason);
    err.reason = reason;
    return err;
  }

  // `onTimeout`, if given, runs exactly when the timer wins the race —
  // independent of whether `promise` itself ever settles. Used by `pair`
  // to abort the underlying fetch in real browsers; the retry-chain
  // advancement below stays driven by this same timer either way, so a
  // test's fetch mock need not honor AbortSignal for the timeout path to
  // behave deterministically.
  function withTimeout(promise, ms, onTimeout) {
    return new Promise((resolve, reject) => {
      const timer = deps.setTimeout(() => { if (onTimeout) onTimeout(); reject(new Error("timeout")); }, ms);
      Promise.resolve(promise).then(
        (value) => { deps.clearTimeout(timer); resolve(value); },
        (err) => { deps.clearTimeout(timer); reject(err); }
      );
    });
  }

  // Redeems `code` at the first origin that answers. A 401 (expired code)
  // or 403 (origin not allowed) stops immediately; network failures move
  // on to the next origin. The request stays a CORS "simple request" (no
  // explicit Content-Type) so no preflight is needed on the hot path.
  //
  // Each attempt gets its own AbortController so a request abandoned to
  // the timeout is actually cancelled in-flight — otherwise a merely-slow
  // (not actually down) origin can still process and consume the
  // single-use code after the client has already moved on to the next
  // origin, which then gets a legitimate-looking but misleading 401.
  function pair(origins, code, deviceName) {
    const tryAt = (index) => {
      if (index >= origins.length) return Promise.reject(pairError("net"));
      const origin = origins[index];
      const controller = new AbortController();
      const request = deps.fetch(origin + "/pair", { method: "POST", body: JSON.stringify({ code, deviceName }), signal: controller.signal });
      return withTimeout(request, PAIR_TIMEOUT_MS, () => controller.abort())
        .then(
          (res) => {
            if (res.status === 401) throw pairError("expired");
            if (res.status === 403) throw pairError("origin");
            if (!res.ok) return tryAt(index + 1);
            return Promise.resolve(res.json()).then((body) => ({ origin, token: body.token }));
          },
          () => tryAt(index + 1)
        );
    };
    return tryAt(0);
  }

  return { add, remove, update, get, all, activeLink, setActive, sendActive, connect, connectAll, suspendIdle, disableIdle, setVisible, retry, pair };
}

globalThis.RemoteHubLinks = {
  createLinks,
  wsUrl,
  HANDSHAKE_TIMEOUT_MS,
  PAIR_TIMEOUT_MS,
  IDLE_POLL_MS,
  INITIAL_RECONNECT_MS,
  MAX_RECONNECT_MS,
};
