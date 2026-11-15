import { test, afterEach } from "node:test";
import assert from "node:assert/strict";
import worker from "../src/index.js";
import { makeEnv } from "./helpers.js";

const realFetch = globalThis.fetch;
afterEach(() => { globalThis.fetch = realFetch; });

const secret = Buffer.alloc(32, 9).toString("base64");
const post = (path, body) => new Request(`https://relay.test${path}`, { method: "POST", body: typeof body === "string" ? body : JSON.stringify(body) });
const reg = { apnsToken: "abcd", topic: "io.nlopez.alas", environment: "sandbox" };
const push = (relayToken) => ({ relayToken, kind: "attention", collapseId: "cid", serverId: "s", sessionId: "x", status: "awaitingInput" });

async function setup(apnsResponse) {
  const { env } = await makeEnv();
  env.RELAY_SECRET = secret;
  const calls = [];
  globalThis.fetch = async (req) => { calls.push(req); return apnsResponse; };
  const res = await worker.fetch(post("/register", reg), env);
  assert.equal(res.status, 200);
  return { env, calls, relayToken: (await res.json()).relayToken };
}

test("register then push delivers", async () => {
  const { env, calls, relayToken } = await setup(new Response(null, { status: 200 }));
  const res = await worker.fetch(post("/push", push(relayToken)), env);
  assert.equal(res.status, 204);
  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, "https://api.sandbox.push.apple.com/3/device/abcd");
});

test("tampered token is 403", async () => {
  const { env, relayToken } = await setup(new Response(null, { status: 200 }));
  const bad = relayToken.slice(0, -2) + (relayToken.endsWith("AA") ? "BB" : "AA");
  assert.equal((await worker.fetch(post("/push", push(bad)), env)).status, 403);
});

test("APNs 410 and BadDeviceToken are 410; other failures 502", async () => {
  for (const [r, want] of [
    [new Response("{}", { status: 410 }), 410],
    [new Response('{"reason":"BadDeviceToken"}', { status: 400 }), 410],
    [new Response('{"reason":"InternalServerError"}', { status: 500 }), 502],
  ]) {
    const { env, relayToken } = await setup(r);
    assert.equal((await worker.fetch(post("/push", push(relayToken)), env)).status, want);
  }
});

test("rate limit is 429 and skipped when the binding is missing", async () => {
  const { env, relayToken } = await setup(new Response(null, { status: 200 }));
  env.PUSH_LIMIT = { limit: async () => ({ success: false }) };
  assert.equal((await worker.fetch(post("/push", push(relayToken)), env)).status, 429);
});

test("bad bodies and routes", async () => {
  const { env, relayToken } = await setup(new Response(null, { status: 200 }));
  const status = async (req) => (await worker.fetch(req, env)).status;
  assert.equal(await status(post("/register", { ...reg, topic: "evil.app" })), 400);
  assert.equal(await status(post("/register", { ...reg, environment: "dev" })), 400);
  assert.equal(await status(post("/register", { ...reg, apnsToken: "xyz" })), 400);
  assert.equal(await status(post("/register", "not json")), 400);
  assert.equal(await status(post("/register", "x".repeat(5000))), 400);
  assert.equal(await status(post("/push", { ...push(relayToken), kind: "nope" })), 400);
  assert.equal(await status(post("/push", { ...push(relayToken), collapseId: "c".repeat(65) })), 400);
  assert.equal(await status(post("/push", { ...push(relayToken), collapseId: "bad\nid" })), 400);
  assert.equal(await status(post("/nope", {})), 404);
});

test("a network failure reaching APNs is 502", async () => {
  const { env, relayToken } = await setup(new Response(null, { status: 200 }));
  globalThis.fetch = async () => { throw new TypeError("network down"); };
  assert.equal((await worker.fetch(post("/push", push(relayToken)), env)).status, 502);
});
