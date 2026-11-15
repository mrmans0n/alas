const enc = new TextEncoder();
const b64u = (b) => btoa(String.fromCharCode(...new Uint8Array(b))).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");

// Cached for 50 minutes: APNs wants a token refreshed no more than hourly, and rejects ones older than an hour.
let cached = null;

export async function apnsJWT(env, now) {
  if (cached && cached.keyId === env.APNS_KEY_ID && now - cached.iat < 50 * 60) return cached.jwt;
  const der = Uint8Array.from(atob(env.APNS_KEY_P8.replace(/-----[^-]+-----|\s/g, "")), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const head = b64u(enc.encode(JSON.stringify({ alg: "ES256", kid: env.APNS_KEY_ID })));
  const claims = b64u(enc.encode(JSON.stringify({ iss: env.APNS_TEAM_ID, iat: now })));
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, enc.encode(`${head}.${claims}`));
  const jwt = `${head}.${claims}.${b64u(sig)}`;
  cached = { jwt, iat: now, keyId: env.APNS_KEY_ID };
  return jwt;
}

export function apnsRequest(body, opened, jwt, now) {
  const host = opened.environment === "production" ? "api.push.apple.com" : "api.sandbox.push.apple.com";
  const alas = { serverId: body.serverId, sessionId: body.sessionId, status: body.status };
  const attention = body.kind === "attention";
  const payload = attention
    ? {
        aps: { alert: { title: "Alas", body: "An agent needs you." }, "mutable-content": 1, category: "attention", "thread-id": body.sessionId },
        alas,
      }
    : { aps: { "content-available": 1 }, alas: { ...alas, clear: true } };
  return new Request(`https://${host}/3/device/${opened.apnsToken}`, {
    method: "POST",
    headers: {
      authorization: `bearer ${jwt}`,
      "apns-topic": opened.topic,
      "apns-push-type": attention ? "alert" : "background",
      "apns-priority": attention ? "10" : "5",
      "apns-collapse-id": body.collapseId,
      "apns-expiration": String(attention ? now + 3600 : 0),
    },
    body: JSON.stringify(payload),
  });
}
