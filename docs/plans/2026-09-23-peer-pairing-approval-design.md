# Peer pairing by approval

Status: proposed for review.

## Intent

Pair two nearby Macs by clicking Pair on one and Allow on the other. The
receiving Mac must show the request without requiring the user to find Remote
settings, expand a QR section, or copy a code. Both Macs belong to the user;
this does not introduce accounts, a hosted service, or multi-user permissions.

Show a persistent bottom-right request card with Allow and Decline. This
specification defines its behavior and the approval protocol.

## User experience

1. In Settings > Remote > Peers, clicking Pair beside a nearby Mac starts an
   approval request when the target supports it.
2. The initiating Mac shows "Waiting for approval on <name>…" and Cancel.
3. The receiving Mac shows a persistent bottom-right card:

   > "<name>" wants to pair
   > Allow these Macs to view and control each other's sessions.
   > Device name supplied by the requester.
   > [Decline] [Allow]

4. Allow changes the card to "Pairing with <name>…" while the existing
   reciprocal pairing completes. Both Macs show success only after the
   reciprocal exchange is confirmed.
5. Decline ends the attempt and informs the initiating Mac. Closing the card
   means Decline. There is no default Return-key approval or automatic approval.

Use the existing in-app notification colors, border, typography, and motion.
The approval card has its own content and lifetime; ordinary notifications
expire after a few seconds and belong to a worktree, which does not fit this
request. Mount the card in the main window and Settings window using shared
application state. A decision in either window updates both immediately.
Switching worktrees, opening an empty workspace, or leaving Remote settings
must not hide a pending request. Do not steal keyboard focus or open Settings.

Names and request details are selectable, wrap within the card, and have
bounded lengths. Keep the original selectable code and Copy pairing link
fallback; add Copy code alongside the fallback code so long codes never have
to be typed. Do not expose internal approval credentials in the UI.

Requests wait for at most 120 seconds, with a visible remaining-time label.
Cancel, Decline, and expiry remove the pending card. Failure after Allow shows
a concise error and permits an explicit retry. No background retry may create
a new approval prompt after a terminal result. Closing the initiating settings
pane cancels its outstanding attempt. Receiving requests belong to the app,
not to the lifetime of any settings view.

## Scope and compatibility

Approval pairing requires remote access, federation, and discoverability on
the receiving Mac. Turning any of those off cancels pending approvals and
invalidates unconsumed authorization. Existing paired connections retain their
current configuration behavior. The requester must also have remote access
and federation enabled and a reachable return address for reciprocal pairing.

Advertise an optional approval-pairing capability in remote diagnostics.
Resolve and check the target's server ID before starting a request. Missing
capability uses the existing nearby-code UI, with instructions to open the
other Mac's pairing QR. Timeouts or invalid identity proofs are errors, not
signals to silently downgrade. Preserve browser QR/link pairing and the current
code-based /pair contract. No federation message-version bump is required for
an additive HTTP capability.

This release does not add macOS notification actions or background approval
while the app has no visible window. A request can expire if nobody sees it.

## Protocol and authorization

Add a versioned native-peer approval exchange alongside /pair. Use short HTTP
requests and bounded polling rather than holding a connection open for the
human decision. All new requests are POSTs with bounded JSON bodies. Apply
existing Host checks, require the approval capability's configuration gates,
and reject browser Origin headers on these native-only routes. Do not add
CORS access for them.

The exchange has three phases:

1. **Challenge and submit.** The requester supplies its identity and a fresh
   attempt nonce. The receiver returns a fresh challenge, request ID, expiry,
   and proof of its identity. The requester proves possession of its own key
   before a user-visible pending request is created.
2. **Wait for a decision.** The requester polls every two seconds, and can
   cancel. Responses distinguish pending, approved, declined, cancelled, and
   expired. An approval authorizes exactly the immutable request shown locally.
3. **Complete pairing.** The requester redeems that approval through a new
   peer-only authorization variant of /pair, then completes the existing
   reciprocal pairing. Generate the reciprocal counter-code at this point,
   so time spent waiting for the user does not expire it.

An approval is a server-side, single-use authorization bound to the request
ID, both server IDs and identity keys, the attempt nonce, and the approved
requester's display name and normalized return origins. It is not an ordinary
pairing code returned by a polling endpoint. Redemption requires a fresh
receiver challenge and proof from the approved requester's key. Supplying only
a request ID must never authorize pairing, polling, or cancellation.

Use purpose-specific signed transcripts for submission, polling, cancellation,
and redemption. Bind every operation to the request, both identities, relevant
payload fields, and its freshness value. Reject reused challenges and altered
payloads. Use deterministic encoding and separate signing domains from the
existing socket identity proof. Signed replies bind to the caller's fresh
nonce so stale status replies cannot be substituted. Identity-provider signing
support must remain encapsulated; do not export private key bytes.

Require valid persistent identity keys on both sides for this flow. Refuse
self-pairing and attempts to replace a pinned identity key. Device names and
Bonjour advertisements remain untrusted labels. Key possession does not prove
that a newly seen key belongs to the physical Mac the user has in mind.

This preserves the current trusted-LAN/tailnet transport assumptions. It does
not encrypt existing plaintext HTTP session tokens or establish independently
verified first-contact identity. The UI must not claim either property. An
encrypted transport migration or an optional fingerprint-comparison ceremony
would be separate work.

Approval expires after 120 seconds from submission. Allow does not extend that
deadline; redemption must happen before it. Once redeemed, the existing bounded
reciprocal completion timeout applies. A lost redemption reply must not mint
another credential: retain a bounded result for authenticated retries of the
same request. Check cancellation and settings changes before publishing any
pairing result, and roll back credentials created by a failed attempt.

## State and abuse limits

Add an application-owned observable approval coordinator with an injectable
clock. Keep challenges, pending requests, approvals, and terminal retry results
in memory only. Restarting the app cancels the exchange. Persist only the peer
and device records produced by successful pairing.

Use explicit states: challenged, pending, approved, redeeming, paired, declined,
cancelled, expired, and failed. Only a local UI action can move pending to
approved. Decide state transitions on the main actor. Concurrent Allow,
Decline, cancellation, expiry, and redemption must have one serialized outcome.
Cancellation during completion rolls back this attempt without revoking an
unrelated established relationship.

Bound unauthenticated work before allocating a prompt or doing outbound I/O:

- At most 32 live challenge records, expiring after 30 seconds.
- At most three pending prompts globally and one per requester key.
- At most five new submissions per requester key per minute and ten globally
  per minute. The global limit also bounds callers that keep changing keys.
- Duplicate submissions for the same attempt reuse the pending request and
  never reset its expiry or add another card.
- Decline suppresses new prompts from the same key for 60 seconds.
- Status responses and request bodies are capped at 16 KiB. Keep the existing
  limits for display strings and advertised origins, and strip control
  characters from names displayed in the prompt.
- Retain at most 64 terminal results, for at most 120 seconds. Limit polling
  per request and return a retry delay when throttled.

No remote callback to requester-advertised origins happens before Allow.
After approval, retain the existing origin validation and bounded network
fetching. Never log codes, bearer tokens, signatures containing credentials,
or complete pairing request bodies.

## Implementation boundaries

- `RemoteServerPane` starts approval pairing, displays outgoing status, and
  retains the legacy code fallback.
- A new approval coordinator owns the request state, limits, and local decisions.
  AppState owns it and cancels it when remote settings disable the feature.
- A dedicated approval client handles challenge exchange, polling, cancellation,
  and authenticated retries without enlarging the legacy code pairer.
- `RemoteHTTPResponder` and `RemoteServer` route bounded approval requests and
  expose capability information. Keep protocol validation outside view code.
- `RemotePairingService` and `RemotePeerManager` accept the bound approval as
  an alternative initial authorization and reuse reciprocal completion,
  identity pinning, revocation, and rollback behavior. Do not maintain a second
  independent peer store or duplicate the reciprocal state machine.
- A shared pairing-request card appears in `RootView` and `SettingsWindow`.
  Reuse notification styling without making approval prompts worktree-scoped.

## Verification and acceptance

Use Swift Testing with injected clocks and transport closures. Cover no
authorization before Allow; valid reciprocal completion; decline, cancellation,
expiry, and configuration shutdown; conflicting decisions; duplicate requests;
lost replies; invalid proofs; changed keys or payloads; replay; wrong-request
redemption; rate limits; and rollback without removing pre-existing peers.
Verify browser requests cannot create prompts and request IDs alone grant no
access. Preserve existing code/QR and reciprocal-pairing regression coverage.

Run only the affected approval, pairing, peer-manager, HTTP-responder, identity,
and discovery test suites as selected by the implementation changes. Build the
app for UI changes not covered by focused tests. Do not run the entire local
test plan by default.

Manually verify with two Macs that Pair produces a card on the receiver, Allow
pairs both sides without copying anything, Decline grants no access, and Cancel
removes the request. Check main-window and Settings visibility, worktree
switching, simultaneous windows, keyboard navigation, VoiceOver labels,
selectable long names, fallback code copying, expiry, and an older peer.

## Review boundary

This is a design document only. After review and approval, write the
implementation plan and select its execution method before changing product
code.
