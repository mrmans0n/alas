import { test } from "node:test";
import assert from "node:assert/strict";
import { seal, open } from "../src/seal.js";

const secret = Buffer.alloc(32, 7).toString("base64");
const payload = { apnsToken: "ab12", topic: "io.nlopez.alas", environment: "sandbox" };

test("seal then open round-trips", async () => {
  assert.deepEqual(await open(secret, await seal(secret, payload)), payload);
});

test("wrong secret or a flipped character opens to null", async () => {
  const token = await seal(secret, payload);
  assert.equal(await open(Buffer.alloc(32, 8).toString("base64"), token), null);
  const i = 20;
  const flipped = token.slice(0, i) + (token[i] === "A" ? "B" : "A") + token.slice(i + 1);
  assert.equal(await open(secret, flipped), null);
  assert.equal(await open(secret, "not a token!"), null);
});

test("sealing twice gives different tokens", async () => {
  assert.notEqual(await seal(secret, payload), await seal(secret, payload));
});
