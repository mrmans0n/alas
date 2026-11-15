# Alas push relay

A Cloudflare Worker that turns "an agent needs you" pings from your Macs into
APNs pushes for the Alas iOS app. It holds no database, no KV and no logs of
its own.

## Why it stores nothing

`POST /register` seals the phone's APNs token, topic and environment into a
relay token (AES-256-GCM, key derived from `RELAY_SECRET`). The phone hands that
token to its hosts; a host sends it back on `POST /push` and the relay opens it
to learn where to deliver. The relay never keeps the token, and a push carries
only IDs (`serverId`, `sessionId`, `status`), never titles, prompts, tool text,
host names or paths. Rotating `RELAY_SECRET` invalidates every token.

## Deploy

1. In the Apple developer portal, create an APNs auth key (`.p8`). A key for
   "Sandbox & Production" serves both; keys limited to one environment can be
   set per environment instead (step 2). Note each Key ID and your Team ID.
2. Set the secrets from this directory. Values from a pipe or file keep the
   `.p8` line breaks intact:
   ```sh
   openssl rand -base64 32 | npx wrangler secret put RELAY_SECRET
   echo -n TEAMID | npx wrangler secret put APNS_TEAM_ID
   # One key for both environments:
   npx wrangler secret put APNS_KEY_P8 < AuthKey_KEYID.p8
   echo -n KEYID | npx wrangler secret put APNS_KEY_ID
   # Or one key per environment (debug builds use sandbox, release builds production):
   npx wrangler secret put APNS_KEY_P8_SANDBOX < AuthKey_SANDBOXKEYID.p8
   echo -n SANDBOXKEYID | npx wrangler secret put APNS_KEY_ID_SANDBOX
   npx wrangler secret put APNS_KEY_P8_PRODUCTION < AuthKey_PRODKEYID.p8
   echo -n PRODKEYID | npx wrangler secret put APNS_KEY_ID_PRODUCTION
   ```
3. `npx wrangler deploy`
4. Put the resulting URL into the iOS build setting `ALAS_PUSH_RELAY_URL`
   (written `https:/$()/your-worker.workers.dev`).

## Test

`node --test 'relay/test/*.test.js'` from the repo root (Node 24, no dependencies).
