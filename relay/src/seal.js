// Stateless relay tokens: AES-256-GCM over the registration, key derived from RELAY_SECRET.
const enc = new TextEncoder();

async function key(secret) {
  const raw = Uint8Array.from(atob(secret), (c) => c.charCodeAt(0));
  const base = await crypto.subtle.importKey("raw", raw, "HKDF", false, ["deriveKey"]);
  return crypto.subtle.deriveKey(
    { name: "HKDF", hash: "SHA-256", salt: enc.encode("alas-relay"), info: enc.encode("relay-token-v1") },
    base, { name: "AES-GCM", length: 256 }, false, ["encrypt", "decrypt"]);
}

const toB64u = (b) => btoa(String.fromCharCode(...b)).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
const fromB64u = (s) => {
  const t = s.replaceAll("-", "+").replaceAll("_", "/");
  return Uint8Array.from(atob(t + "=".repeat((4 - (t.length % 4)) % 4)), (c) => c.charCodeAt(0));
};

export async function seal(secret, payload) {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ct = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv }, await key(secret), enc.encode(JSON.stringify(payload))));
  const out = new Uint8Array(12 + ct.length);
  out.set(iv); out.set(ct, 12);
  return toB64u(out);
}

export async function open(secret, token) {
  try {
    const b = fromB64u(token);
    const pt = await crypto.subtle.decrypt({ name: "AES-GCM", iv: b.slice(0, 12) }, await key(secret), b.slice(12));
    return JSON.parse(new TextDecoder().decode(pt));
  } catch {
    return null;
  }
}
