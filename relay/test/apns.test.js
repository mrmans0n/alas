import { test } from "node:test";
import assert from "node:assert/strict";
import { makeEnv } from "./helpers.js";
import { apnsJWT, apnsRequest } from "../src/apns.js";

const b64u = (s) => JSON.parse(Buffer.from(s, "base64url").toString());

test("apnsJWT is a verifiable ES256 token", async () => {
  const { pair, env } = await makeEnv();
  const now = 1_800_000_000;
  const [h, c, s] = (await apnsJWT(env, now)).split(".");
  assert.deepEqual(b64u(h), { alg: "ES256", kid: "KEY123" });
  assert.deepEqual(b64u(c), { iss: "TEAM456", iat: now });
  const ok = await crypto.subtle.verify(
    { name: "ECDSA", hash: "SHA-256" }, pair.publicKey,
    Buffer.from(s, "base64url"), new TextEncoder().encode(`${h}.${c}`));
  assert.ok(ok);
});

const opened = (environment) => ({ apnsToken: "abcd", topic: "io.nlopez.alas", environment });
const body = { kind: "attention", collapseId: "cid", serverId: "srv", sessionId: "sess", status: "awaitingInput" };

test("attention request", async () => {
  const now = 1_800_000_000;
  for (const [env, host] of [["sandbox", "api.sandbox.push.apple.com"], ["production", "api.push.apple.com"]]) {
    const r = apnsRequest(body, opened(env), "JWT", now);
    assert.equal(r.url, `https://${host}/3/device/abcd`);
  }
  const r = apnsRequest(body, opened("sandbox"), "JWT", now);
  assert.equal(r.method, "POST");
  assert.equal(r.headers.get("authorization"), "bearer JWT");
  assert.equal(r.headers.get("apns-topic"), "io.nlopez.alas");
  assert.equal(r.headers.get("apns-push-type"), "alert");
  assert.equal(r.headers.get("apns-priority"), "10");
  assert.equal(r.headers.get("apns-collapse-id"), "cid");
  assert.equal(r.headers.get("apns-expiration"), String(now + 3600));
  assert.deepEqual(await r.json(), {
    aps: { alert: { title: "Alas", body: "An agent needs you." }, "mutable-content": 1, category: "attention", "thread-id": "sess" },
    alas: { serverId: "srv", sessionId: "sess", status: "awaitingInput" },
  });
});

test("clear request is a silent background push", async () => {
  const r = apnsRequest({ ...body, kind: "clear" }, opened("sandbox"), "JWT", 1_800_000_000);
  assert.equal(r.headers.get("apns-push-type"), "background");
  assert.equal(r.headers.get("apns-priority"), "5");
  assert.equal(r.headers.get("apns-collapse-id"), "cid");
  const j = await r.json();
  assert.equal(j.aps["content-available"], 1);
  assert.equal(j.aps.alert, undefined);
  assert.equal(j.alas.clear, true);
  assert.equal(j.alas.sessionId, "sess");
});
