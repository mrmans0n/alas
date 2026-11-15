import { seal, open } from "./seal.js";
import { apnsJWT, apnsRequest } from "./apns.js";

const TOPICS = ["io.nlopez.alas", "io.nlopez.alas.dev"];
const ENVIRONMENTS = ["sandbox", "production"];
const MAX_BODY = 4096;
const str = (v, max) => typeof v === "string" && v.length > 0 && new TextEncoder().encode(v).length <= max;

async function readJSON(request) {
  const text = await request.text();
  if (text.length > MAX_BODY) return null;
  try {
    const v = JSON.parse(text);
    return v && typeof v === "object" ? v : null;
  } catch {
    return null;
  }
}

async function rateKey(token) {
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(token));
  return [...new Uint8Array(d)].slice(0, 8).map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function register(request, env) {
  const b = await readJSON(request);
  if (!b || !/^[0-9a-fA-F]{1,200}$/.test(b.apnsToken) || !TOPICS.includes(b.topic) || !ENVIRONMENTS.includes(b.environment)) {
    return new Response("bad request", { status: 400 });
  }
  const relayToken = await seal(env.RELAY_SECRET, { apnsToken: b.apnsToken, topic: b.topic, environment: b.environment });
  return Response.json({ relayToken });
}

async function push(request, env) {
  const b = await readJSON(request);
  if (!b || !str(b.relayToken, 1024) || !["attention", "clear"].includes(b.kind) || !str(b.collapseId, 64)
    || !str(b.serverId, 128) || !str(b.sessionId, 128) || !["awaitingPermission", "awaitingInput"].includes(b.status)) {
    return new Response("bad request", { status: 400 });
  }
  const opened = await open(env.RELAY_SECRET, b.relayToken);
  if (!opened) return new Response("forbidden", { status: 403 });
  if (env.PUSH_LIMIT && !(await env.PUSH_LIMIT.limit({ key: await rateKey(b.relayToken) })).success) {
    return new Response("rate limited", { status: 429 });
  }
  const now = Math.floor(Date.now() / 1000);
  const res = await fetch(apnsRequest(b, opened, await apnsJWT(env, now), now));
  if (res.ok) return new Response(null, { status: 204 });
  const reason = await res.json().then((j) => j.reason, () => undefined);
  if (res.status === 410 || (res.status === 400 && reason === "BadDeviceToken")) return new Response("gone", { status: 410 });
  return new Response("apns failure", { status: 502 });
}

export default {
  async fetch(request, env) {
    const { pathname } = new URL(request.url);
    if (request.method !== "POST" || (pathname !== "/register" && pathname !== "/push")) {
      return new Response("not found", { status: 404 });
    }
    return pathname === "/register" ? register(request, env) : push(request, env);
  },
};
