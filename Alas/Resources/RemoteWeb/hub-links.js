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
      serverId: server.serverId || null,
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
    if (server.serverId) link.serverId = server.serverId;
    link.reconnectDelay = INITIAL_RECONNECT_MS;
    link.state = "idle";
    notify(link);
    // The active link always reconnects; an idle link only does when the
    // hub is actually enabled — otherwise this would resurrect a socket
    // disableIdle() (via applyHubFlag(false)) just suspended, e.g. when
    // handleLinkHello's duplicate-merge branch calls update() right after
    // the fresh hello turned the aggregate hub flag off.
    if (link.role === "active" || idleAllowed) connect(link.id);
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

  // The health probe (see probeAny below) needs a known-good identity to
  // verify a /health response against, independent of whatever app.js's
  // hook does with the registry — recorded here so it's always current.
  function rememberServerId(link, msg) {
    if (typeof msg.serverId === "string" && msg.serverId) link.serverId = msg.serverId;
  }

  function receive(link, msg) {
    if (!msg || typeof msg.type !== "string") return;
    if (link.awaitingHello) {
      link.awaitingHello = false;
      if (msg.type === "hello") { rememberServerId(link, msg); if (h.onHello) h.onHello(link, msg); return; }
      // A pre-hub Mac never says hello; treat its first frame as ordinary.
      link.legacy = true;
      if (h.onLegacy) h.onLegacy(link);
    } else if (msg.type === "hello") {
      rememberServerId(link, msg);
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
    probeAny(order, link.serverId).then(({ reachable, blocked }) => {
      if (attempt !== link.attempt) return;
      if (reachable) { setState(link, "unauthorized"); return; }
      if (blocked) { setState(link, "blocked"); return; }
      setState(link, "offline");
      scheduleReconnect(link);
    });
  }

  function probeAny(origins, expectedServerId) {
    // Every server advertises "localhost" alongside its real addresses, but
    // that origin only actually reaches the paired Mac when the browser
    // happens to run on that same machine — otherwise it silently answers
    // for whatever Alas instance is local to THIS device. Probing it for a
    // genuinely remote link could report a healthy, unrelated Mac and
    // misclassify an offline remote Mac as "unauthorized" (which stops
    // reconnecting for good) instead of "offline" (which keeps retrying).
    // Prefer real addresses; only fall back to loopback when it's all a
    // link has, since then it's the only signal available.
    const isLoopback = globalThis.RemoteHubRegistry.isLoopbackOrigin;
    const candidates = origins.filter((o) => !isLoopback(o));
    const toProbe = candidates.length ? candidates : origins;
    return Promise.all(toProbe.map(probe)).then((results) => {
      // A non-loopback address can *also* be reused (DHCP, a reassigned
      // reverse proxy) and answer for a completely different — possibly
      // older, pre-identity — Alas instance. Once this link has a known
      // serverId, only an explicit match may establish revocation; an
      // identity-free 2xx is no longer proof, since we can no longer tell
      // "a legacy version of the actual paired Mac" apart from "a different
      // Mac that happens to sit at a reused address." Without a known
      // serverId yet (this link has never received its first hello), a bare
      // 2xx is the only signal available, so it's still trusted.
      const confirmsIdentity = (r) => !expectedServerId || r.serverId === expectedServerId;
      return {
        reachable: results.some((r) => r && r.status >= 200 && r.status < 300 && confirmsIdentity(r)),
        blocked: results.some((r) => r && r.status === 403),
      };
    });
  }

  // Resolves { status, serverId } from the /health response, or null on
  // timeout/network failure. serverId is null when the response has no
  // parseable JSON body with one (a legacy Mac, or a non-2xx response).
  function probe(origin) {
    return new Promise((resolve) => {
      let done = false;
      const controller = new AbortController();
      // Every retry cycle probes anew; without aborting the underlying
      // fetch, a blackholed address would leave one more outstanding HTTP
      // request pending forever per cycle.
      const finish = (value) => { if (!done) { done = true; deps.clearTimeout(timer); resolve(value); } };
      const timer = deps.setTimeout(() => { controller.abort(); finish(null); }, PROBE_TIMEOUT_MS);
      Promise.resolve()
        .then(() => deps.fetch(origin + "/health", { method: "GET", signal: controller.signal }))
        .then(
          (res) => {
            if (!res) { finish(null); return; }
            if (res.status !== 200 || typeof res.json !== "function") { finish({ status: res.status, serverId: null }); return; }
            res.json().then(
              (data) => finish({ status: res.status, serverId: (data && typeof data.serverId === "string") ? data.serverId : null }),
              () => finish({ status: res.status, serverId: null })
            );
          },
          () => finish(null)
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
    // Every pairing link includes "localhost" alongside the target Mac's
    // real addresses, so it can answer from a completely unrelated local
    // Alas instance that has never heard of this code — a 401 from there
    // isn't proof the code is expired, it's a false read from the wrong
    // server. Only a loopback origin gets that benefit of the doubt: the
    // non-loopback addresses in one pairing link all come from the same
    // Mac's own advertisedAddresses(), so a 401/403 from any of them is
    // authoritative for the real target and must stop immediately —
    // otherwise a single expired/mistyped code recursively posts to every
    // advertised address and can burn through the whole 5-per-60s
    // redemption-failure budget (RemotePairingService.redeem) in one
    // submission, locking out even a freshly generated valid code.
    const isLoopback = globalThis.RemoteHubRegistry.isLoopbackOrigin;
    const tryAt = (index, bestError) => {
      if (index >= origins.length) return Promise.reject(bestError || pairError("net"));
      const origin = origins[index];
      const controller = new AbortController();
      const request = deps.fetch(origin + "/pair", { method: "POST", body: JSON.stringify({ code, deviceName }), signal: controller.signal });
      return withTimeout(request, PAIR_TIMEOUT_MS, () => controller.abort())
        .then(
          (res) => {
            if (res.status === 401) {
              const err = bestError || pairError("expired");
              return isLoopback(origin) ? tryAt(index + 1, err) : Promise.reject(err);
            }
            if (res.status === 403) {
              const err = bestError || pairError("origin");
              return isLoopback(origin) ? tryAt(index + 1, err) : Promise.reject(err);
            }
            if (!res.ok) return tryAt(index + 1, bestError);
            // A 2xx from an unrelated responder (a captive portal, a
            // reverse proxy's own error page) may not even be JSON, or may
            // be JSON without a usable token — either must fall through to
            // the next origin rather than aborting the whole attempt or
            // creating a registry entry with a garbage token. The rejection
            // handler here must only catch res.json() itself failing to
            // parse — using .then().catch() instead would also catch the
            // *next* tryAt() call's own eventual rejection and retry the
            // same remaining origins a second time.
            return Promise.resolve(res.json()).then(
              (body) => {
                if (!body || typeof body.token !== "string" || !body.token) return tryAt(index + 1, bestError);
                return { origin, token: body.token };
              },
              () => tryAt(index + 1, bestError)
            );
          },
          () => tryAt(index + 1, bestError)
        );
    };
    return tryAt(0, null);
  }

  return { add, remove, update, get, all, activeLink, setActive, sendActive, connect, connectAll, suspendIdle, disableIdle, setVisible, retry, pair };
}

globalThis.RemoteHubLinks = {
  createLinks,
  wsUrl,
  HANDSHAKE_TIMEOUT_MS,
  PAIR_TIMEOUT_MS,
  PROBE_TIMEOUT_MS,
  IDLE_POLL_MS,
  INITIAL_RECONNECT_MS,
  MAX_RECONNECT_MS,
};
