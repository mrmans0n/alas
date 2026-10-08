# Visual aids in the phone web client

Closes [#1838](https://github.com/mrmans0n/alas/issues/1838). Builds on
`docs/superpowers/specs/2026-10-07-acp-visual-aids-design.md`, which shipped
`visual_show` for the desktop transcript and listed the phone client under
"Later".

Today the phone gets a hidden placeholder for a visual aid, and the
`visual_show` tool-call row ships the raw HTML to the phone as inert tool-card
text, twice (`content` and `rawInput`). This design renders the visual on the
phone, lets the user answer its question there, and stops sending the HTML as
text.

## Goals

- A visual aid shows on the phone as a card with a sandboxed rendering of its
  HTML, next to the turn that produced it.
- The user can answer or dismiss a visual's question from the phone. The answer
  goes through the same Mac-side path as a desktop answer.
- Agent-written HTML cannot reach the phone page's bearer token, its control
  socket, or the rest of its DOM.
- Old phone clients keep working: they show the visual's title instead of a
  blank row.

## Non-goals

- Click-to-select inside the visual (`data-choice`) on the phone. A question
  visual is display-only there. See [Question visuals](#question-visuals).
- Opening links from inside a visual. Links do nothing on the phone in this
  version.
- Phone-side theme sync. The frame uses the phone's fixed dark palette.
- Changing the desktop renderer or the desktop answer rules.

## Decisions in brief

- **Wire.** A new row kind `visualAid`. `text` is the title (the fallback an
  older phone renders), `json` carries the visual. It reuses the positional
  `stableId`, the delta path and the row budget.
- **Redaction.** The remote projection of a `visual_show` tool call keeps its
  title and status and drops `content` and `rawInput`.
- **Sandbox.** The phone builds a `srcdoc` iframe with `sandbox="allow-scripts"`
  and no `allow-same-origin`, so the frame has an opaque origin. The desktop CSP
  is injected as the first element of the document.
- **Question visuals.** The iframe is inert. Options, note, Submit and Dismiss
  are phone-native controls under it. The page never sees a selection, so
  nothing can leak it, and `https:` CDN loads keep working.
- **Answering.** A new client message `visualAidResponse`, routed to
  `ACPSessionManager.answerVisualAid`. The question is read-only when the phone
  cannot drive the session.
- **Lifecycle.** Frames load lazily and at most three are live at once.

## Wire and gateway

### Row projection

`RemoteSessionGateway.toWire` handles `.visualAid` by returning:

```
RemoteWireMessage(stableId: "m<index>", kind: "visualAid", text: visual.title,
                  json: encodeJSON(RemoteVisualAid(visual)), index: index)
```

and no longer sets `isHidden`. `RemoteVisualAid` is a Codable DTO:

| Field | Type | Notes |
|---|---|---|
| `id` | string | The visual's UUID. The phone sends it back in `visualAidResponse`. |
| `title` | string | |
| `html` | string | At most 512 KiB, enforced when the visual was created. |
| `question` | object or null | `{prompt, options: [{id, label}], allowMultiple}`. |
| `answer` | object or null | `{kind: "answered", selectedOptionIds, note} or {kind: "dismissed"}`. The timestamp is not sent. |

The row goes through `boundedForTransport`. A visual whose escaped payload
exceeds the 4 MiB row budget becomes the existing "too large for remote
display" notice at the same position, so paging past it keeps working.

An answer, a dismissal or a rollback replaces the same transcript row, so the
change log marks that index dirty and the existing delta path updates the card.
No new sync mechanism is needed.

### Redaction

`remoteToolCall` blanks `content` and `rawInput` when the call is a
`visual_show` call. The match is the one `ACPToolCallPresentation` uses: the
tool name or title contains `visual_show`. Title, status, kind and locations
stay, so the generic tool card still shows that a visual was shown. The
full-content rehydration path (`cachedFullToolCallContent`) is skipped for these
calls, so a truncated off-window body is not reloaded from SQLite only to be
discarded.

## Client message and Mac-side path

### Protocol

`RemoteClientMessage` gains:

```
visualAidResponse(sessionId, visualId, action, selectedOptionIds, note)
```

`action` is `"answer"` or `"dismiss"`. `selectedOptionIds` and `note` are
optional and ignored for a dismissal. The server stamps the time. `RemoteServerMessage` gains:

```
visualAidRejected(sessionId, visualId, reason)
```

`reason` is one of `notWriter`, `notFound`, `alreadyAnswered`, `invalid`,
`failed`. Both cases are additive. An older server drops an unknown client
message (enum decode fails and is ignored), and an older phone ignores an
unknown server message, so `RemoteProtocol.current` stays 1.

### Gateway

`RemoteSessionGateway.handle` for `visualAidResponse`:

1. `provider.isWriter(for: sessionId)` must hold, else `notWriter`.
2. The visual must exist in the session's transcript, else `notFound`.
3. It must have a question and no answer yet, else `alreadyAnswered`.
4. For `answer`, every option id must belong to the question and at least one
   must be chosen. Exactly one is allowed unless `allowMultiple`. The note is
   trimmed and limited to `ACPVisualAidQuestionForm.noteMaxLength`. Otherwise
   `invalid`.
5. It builds the `ACPVisualAid.Answer` (`.answered` or `.dismissed`, `Date()`
   as the time) and calls `provider.answerVisualAid(...)`. A false return maps
   to `failed`.

`RemoteSessionsProvider` gains `answerVisualAid(sessionId:visualId:answer:) async -> Bool`,
implemented in `AppState` by routing to the owning `ACPSessionManager`'s
`answerVisualAid(id:answer:in:)`. That reuses everything desktop answers get:
the wait for the card's first write, the double-submit guard, the confirmed
persistence, the dismissal that sends nothing, the answer prompt, and the
rollback with its session-owned error.

A rollback after a failed send clears the answer on the row, so the phone sees
the card reopen through the normal delta. The phone shows the existing failure
text for that case. It does not wait for a `visualAidRejected`, which is only
for answers the server refuses up front.

## Phone rendering

All phone code is plain JavaScript under `Alas/Resources/RemoteWeb/`. The new
logic lives in `visual-aid.js`, a pure module loaded before `app.js`, with
`app.js` doing the DOM work.

### Card

`renderMessage` gets a `visualAid` case that builds a card: the title, then the
sandboxed frame area, then, when there is a question, the answer area. A card
keeps its frame across delta updates. When the row changes only in `answer`,
only the answer area re-renders, so the iframe does not reload and lose its
state.

An unknown or unparsable `json` falls back to a plain-text row with the title,
like any unknown kind.

### Document

`visual-aid.js` exports `buildDocument(html, parse)` where `parse` is
`DOMParser`'s `parseFromString` in the browser. It returns the `srcdoc` string:

- A fragment (`isFullDocument` false) is wrapped in the phone's copy of the
  themed frame, with the frame colors mapped from the phone's CSS variables
  (`--alas-text`, `--alas-background`, `--alas-dim`, `--alas-line`,
  `--alas-accent`, tone colors).
- A full document is parsed, and the following are inserted as the first
  children of `<head>` (created if missing): the CSP `<meta>`, the lockdown
  script, then the bridge script. It is serialized back with its doctype. The
  agent's own markup is otherwise left as parsed.
- `isFullDocument` is a port of the desktop rule: after whitespace and
  comments, a doctype or `<html` followed by whitespace, `>` or `/`.

The CSP is exactly the desktop string:

```
default-src 'none'; script-src 'unsafe-inline' https:;
style-src 'unsafe-inline' https:; img-src data: blob: https:;
font-src data: https:; connect-src 'none'; frame-src 'none';
worker-src 'none'; form-action 'none'; base-uri 'none'
```

The lockdown script runs first and deletes every `(webkit)?RTC*` global. It is
best effort in a browser: a no-`src` child frame is a clean realm that CSP does
not cover. That is acceptable here because the page has no user state to send
(see below) and cannot read the token. The bridge script observes the document
height and posts `{alasVisual: true, id, height}` to the parent, and swallows
link clicks (`preventDefault`, no navigation).

### Frame

```html
<iframe sandbox="allow-scripts" referrerpolicy="no-referrer" srcdoc="...">
```

`allow-same-origin`, `allow-forms`, `allow-popups`, `allow-top-navigation*`,
`allow-downloads`, `allow-modals` and `allow-storage-access-by-user-activation`
are never set. Omitting `allow-same-origin` is the property that protects the
bearer token in `localStorage` and the same-origin `/ws`, so a test pins it.

The parent listens for `message` events and accepts a height only when
`event.source === iframe.contentWindow` and `data.id` matches the card. The
height is clamped to 120 to 720 px, as on desktop. A page can spam the channel,
which only moves its own card's height inside that clamp.

### Question visuals

When the visual has a question, the iframe gets `inert`, `tabindex="-1"` and
`pointer-events: none`. No click, keyboard or assistive input reaches the page,
and the page is never told which option is selected, so there is no state for it
to send out. For the same reason it keeps the `https:` loads of a no-question
visual. Scripts still run, so a Tailwind CDN visual renders.

A visual without a question is interactive (scripts and clicks work), with
links dead.

### Answer area

Rendered by `app.js` from state computed in `visual-aid.js`:

- **Open and drivable.** The prompt, then radios (`allowMultiple` false) or
  checkboxes, a note textarea (2,000 characters), Submit and Dismiss. Submit is
  disabled until the choice rules hold. Submit and Dismiss disable while a
  request is in flight.
- **Open, `canDrive` false.** The same content disabled, with "Take over to
  answer", wired to the existing Take Over pill. The phone does not take over
  by itself.
- **Answered.** Read-only summary: the chosen labels and the note.
- **Dismissed.** "Dismissed".
- **Error.** An inline message from `visualAidRejected`, or the failure text
  when a delta reopens a card the phone just answered. The controls come back
  enabled.

A submit builds `{type: "visualAidResponse", sessionId, visualId, action, selectedOptionIds, note}`
and sends it on the existing socket helper.

## Lifecycle and limits

- A card creates its iframe when it first comes within about one screen of the
  viewport (`IntersectionObserver`).
- At most 3 iframes are live. Creating a fourth replaces the least recently
  shown one with a "Show visual" placeholder. A card scrolled well away keeps
  its placeholder state, and tapping the placeholder recreates the frame.
- A visual over the row budget shows the existing too-large notice, not a card.
- The phone creates no iframe for a row whose `json` fails to parse.

## Compatibility

The row kind, the client message and the server message are all additive.

| Peer | Behavior |
|---|---|
| Old phone, new server | The row renders as a plain-text row with the title. |
| New phone, old server | The phone never receives a `visualAid` row. If it sends `visualAidResponse` (it cannot, there is no visual), an old server drops it. |
| Native peer (`NativePeerTranscript`) | An unknown kind maps to a system notice with the title. A native renderer is not part of this change. |

## Testing

Following the repository testing policy: parsers, state logic and the security
boundary get tests, view composition does not.

- **Gateway** (`RemoteSessionGatewayTests`): the visual row appears in a
  snapshot, a delta and a history page with `kind`, title text and JSON; an
  answer produces a delta that updates the same index; the `visual_show` tool
  call is projected without `content` and `rawInput` and still shows title and
  status; an over-budget visual becomes the too-large notice at its position.
- **Handler** (`RemoteSessionGatewayTests`): answer, dismiss, unknown option id,
  no choice, two choices without `allowMultiple`, note over the limit, not
  writer, unknown visual, already answered, and a manager failure mapping to
  `failed`. Each rejection checks the manager was not called.
- **Protocol** (`RemoteProtocolTests`): round trips for the two new messages,
  and decoding with the optional fields absent.
- **Pure module** (Node runner `scripts/tests/remote-web-visual-aid/run.sh`,
  added to the `Remote web tests` job): `isFullDocument` with the desktop test
  vectors, the answer state machine (single and multiple selection, note limit,
  submit enablement, in-flight, read-only), the response message builder, height
  clamping, and the live-frame LRU.
- **Document builder** (`RemoteWebAssetTests`, WebKit): loads `visual-aid.js` in
  a `WKWebView` and runs `buildDocument` with the real `DOMParser`. Asserts the
  CSP meta is the first element of `<head>` for fragments and for full documents
  with and without `<head>`, that the doctype survives, and that markup
  containing `<head>` inside an attribute or script is not mangled.
- **Asset assertions** (`RemoteWebAssetTests`): the iframe `sandbox` value is
  exactly `allow-scripts`, the CSP in `visual-aid.js` equals
  `VisualAidWebPolicy.contentSecurityPolicy`, every class selector in
  `Alas/Resources/VisualAid/frame.html` also appears in the phone frame copy,
  question visuals get `inert`, and `app.js` registers the `visualAid` kind.

Smoke run: pair a phone-width browser to a running app, show a fragment visual,
a full-document visual and a question visual from a real agent, answer one,
dismiss one, and confirm a read-only question when the session is a mirror.

## Documentation

- `docs/web-previews.md`: replace "The phone client does not show visuals yet"
  with the phone behavior (display-only question visuals, links off, the sandbox,
  the live-frame cap).
- `CHANGELOG.md`: a Features line under Unreleased.
- The protocol comments in `RemoteMessageWireJSON.swift` and `RemoteProtocol.swift`
  list the new kind and messages.

## Later

- Open `https` links from a visual after a confirm step.
- Click-to-select on the phone, which needs a browser-side network lock that a
  one-shot iframe cannot give today.
- A native peer renderer for visuals.
- Sync the phone frame colors with the desktop theme.
