# Web previews

Previews use macOS WebKit (`WKWebView`) in center tabs. The Run panel opens
configured endpoints and provides a manual URL launcher. Each preview belongs
to a worktree or Workspace Checkout, using the same owner key as its tabs and
agent sessions.

WebKit provides native embedding, viewport snapshots, and DOM access without
shipping and maintaining a separate Chromium distribution. Element inspection
reports the rendered DOM and selected computed styles. It does not infer a
React component or source file. Frame selection reports the frame element,
not the contents of the embedded document. Console collection includes errors
observed after navigation, not a complete developer-tools protocol or history.
Collection stops after the first 100 messages per page load. Reloading starts
a new collection. Both the page-side console hook and the native message bridge
enforce a budget so repeated errors cannot keep updating the app's UI.

## Storage and restoration

Each open preview has its own nonpersistent WebKit data store. Cookies, login
state, navigation history, and the live page survive switching tabs/worktrees.
Closing the preview, removing its owner, or quitting Alas releases that private
session. The storage menu also clears the preview's cookies and website data.
Tabs restore their owner, URL, and remote-host restriction after an app restart;
logins and navigation history do not persist across restarts.

## Viewport size

A preview fills its pane by default. The size menu in its toolbar sets a fixed
page size instead: Phone (390×844), Tablet (820×1180), Laptop (1280×800),
Desktop (1920×1080), or a custom width and height from 200 to 4096 CSS pixels.
The size is saved with the tab.

A page smaller than the pane shows at real size, centered. A larger one uses
WebKit page zoom to fit, with the percentage shown, so `innerWidth` and media
queries still see the full size. While zoomed, the page's `devicePixelRatio`
drops to match, so `srcset` may pick smaller images. Only the size changes:
WebKit cannot emulate touch input or a device's pixel density, and the user
agent stays the same.

## Feedback

Viewport capture, rectangular selection, and element selection create a local
draft. The review sheet displays the screenshot and metadata, accepts a message,
and requires an explicit recipient choice. Screenshots can be enlarged before
sending. Console errors are optional and unchecked initially.

Sending revalidates the recipient's owner and writer status, stages the PNG
through the existing image attachment store, and uses the normal session prompt
delivery path. Canceling a capture does not stage an attachment or send a prompt.

## Page boundaries

Only HTTP(S) navigation is allowed. Page messages can append bounded console
text; they cannot call privileged Alas operations. Element queries run in an
isolated JavaScript world. All captured page content is labeled as untrusted
context in feedback.

A remote preview retains its execution host. Remote loopback URLs are blocked
on launch and navigation, including redirects. Remote navigations also perform
a bounded system DNS lookup and reject unresolved names or any address that is
loopback, link-local (`169.254.0.0/16`, `fe80::/10`), or one of this Mac's own
LAN or tailnet addresses, including hosts-file aliases. Enter a reachable
remote URL instead. This feature does not create tunnels or infer local port
forwarding.

Every other request a remote page makes is checked too: fetch, XHR, images,
scripts, styles, frames, WebSockets, workers, and redirects.

- **Names** go through a per-preview HTTP CONNECT proxy that Alas runs on
  `127.0.0.1`. It resolves each name once, refuses the connection unless every
  answer is allowed, and connects to the exact address it checked, so DNS
  rebinding has nothing to act on. A refused request fails in the page and
  adds a console line such as `Blocked request to app.test:5432: resolves to
  this Mac`, which `preview_console` and captures include. The proxy is set
  with failover off: if it stops, requests fail rather than going direct. Each
  proxy keeps at most 128 connections open, answering `503` beyond, and looks
  up at most 4 names at once; further requests wait their turn. It answers
  `407` to any request without its random per-preview password, which only
  that preview's WebKit data store is given, so other processes on this Mac
  cannot tunnel through it.
- **IP literals** for loopback and this Mac's own addresses never reach a
  proxy, because WebKit connects to them directly. A WebKit content rule list
  blocks them by URL: `localhost`, `*.localhost`, `127.0.0.0/8`, `0.0.0.0`,
  `[::1]`, `[::]`, `169.254.0.0/16`, IPv4-mapped forms of these, and each of
  this Mac's current interface addresses, and Tailscale's service addresses
  `100.100.100.100` and `fd7a:115c:a1e0::53`. The list is recompiled when the
  Mac's addresses change, and checked again before each navigation.

A paired host's forwarded preview keeps exactly its forward's address and port
reachable; every other address on this Mac stays blocked. If the rules cannot
be compiled or the proxy cannot start, the preview loads nothing and retries on
the next navigation. Local previews use neither and may load `localhost`.

These checks keep remote pages off this Mac; they are not a network sandbox.
Other hosts on the LAN or tailnet stay reachable, since the remote host is
usually one of them. Known gaps:

- WebRTC and other UDP traffic do not use the proxy.
- HTTP/3 (QUIC) cannot run through an HTTP CONNECT tunnel, and WebKit does
  not try it around the proxy. On macOS 27.0.1, a web view loading
  `cloudflare-quic.com` used HTTP/3 with no proxy and a persistent data store.
  With the proxy set, the same store used HTTP/2 through the proxy even though
  it had cached the site's HTTP/3 `Alt-Svc` entry. When the proxy refused
  every connection, every load failed. Remote previews use a non-persistent
  data store, which did not use HTTP/3 even without a proxy. This is WebKit's
  current behaviour, not a documented guarantee, and there is no public API to
  turn HTTP/3 off.
- After this Mac gets a new address, a literal URL for it is reachable until
  the rules are recompiled, typically within tens of milliseconds. Names are
  refused immediately.
- WebKit may still look up names for DNS prefetch; that opens no connection.
- The proxy listens on TCP, since WebKit ignores a Unix socket proxy endpoint
  and connects directly. The password keeps other processes out unless they
  can read Alas's memory.
- A local process can still fill the proxy's 128-connection cap without the
  password by reopening idle connections, which are dropped after 5 seconds,
  so the preview's requests get `503`. That denies service; it reaches
  nothing.

## MCP and CLI automation

The built-in Alas server controls the same WebKit browser shown in the center
tab. `preview_list` returns previews belonging to the caller's worktree or
Workspace Checkout. `preview_open` opens an explicit URL or a configured Run
endpoint and returns a `preview_id`. Other operations require that handle.
Closing the tab, changing its execution host, or restarting Alas invalidates
the handle; list or open again to get its replacement. UI selection does not
change the caller's owner.

The CLI provides matching commands:

```sh
alas preview open --url http://localhost:3000
alas preview open --script-key repo:dev.sh
alas preview list
alas preview inspect <preview-id> --selector 'button' --limit 20
alas preview click <preview-id> <element-id>
alas preview type <preview-id> <element-id> 'Example text'
alas preview scroll <preview-id> 0 400
alas preview resize <preview-id> 390 844
alas preview resize <preview-id> --fill
alas preview wait <preview-id> visible '#result' --timeout-ms 5000
alas preview capture <preview-id>
alas preview capture <preview-id> --region 10 20 320 200
alas preview console <preview-id> --clear
alas preview cancel <preview-id>
```

`navigate`, `reload`, `back`, and `forward` operate on browser history. Open
without an argument focuses an existing preview or resolves a unique configured
endpoint. Multiple configured endpoints require `--script-key` or `--url`.
Workspace Checkout previews accept explicit URLs. Run endpoints preserve the
active run's execution host.

Inspection returns bounded main-document metadata and opaque element references.
Navigation and detached elements invalidate references. Frame contents and
trusted browser gestures are unsupported. Click and type use DOM events;
pages requiring trusted user gestures may need manual interaction. Inspection
omits password and file-input values, and automation cannot populate file inputs.

`preview_resize` sets the viewport size described above, for the same browser
the user sees, so their tab changes too. It accepts `width` and `height` or
`fill`, works while the tab is hidden, and returns once the page has laid out
at the new size. The `viewport` field there and in `preview_list` gives the size
the page sees, whether it is fixed or fills the pane, and its on-screen scale.

Captures return PNG image data plus URL, capture time, CSS viewport dimensions,
device pixel ratio, scroll position, region, and available element metadata.
Regions stay in CSS pixels at any scale. A capture is as sharp as the page is
on screen, so a viewport scaled to fit yields fewer pixels. One that would
exceed the 8-megapixel limit comes back at lower resolution, with
`reduced_to_fit_limit` set.
MCP returns native image content; the CLI prints JSON with base64 image data.
Requested captures go only to the calling tool. They do not create a feedback
draft, stage a session attachment, or send another session a prompt.

MCP annotations distinguish reads from operations with possible external side
effects. The host's tool approval controls calls. CLI invocation explicitly
requests the action; Alas adds no confirmation dialog. The Unix socket retains
the existing local-user trust boundary. It is not a security boundary against
other processes running as the same user. ACP callers require an open writable
session, and each operation revalidates ownership and session access.

Each browser accepts one operation at a time. Concurrent callers receive a busy
error and can retry. Waits default to five seconds and are capped at twenty.
Use cancel to interrupt outstanding work. DOM output is capped at 100 elements
and 128 KiB; PNG captures at 8 megapixels (reduced to fit) and 8 MiB (an error). Browser content and tool
results remain untrusted application data.

## Visual aids in the transcript

The built-in Alas server's `visual_show` tool shows an HTML visual inline in an
ACP session's transcript: a UI prototype, layout, diagram, or side-by-side
comparison. It is an MCP tool only, has no `alas` CLI command, and applies to
ACP sessions, including Workspace Checkout sessions. The phone web
client shows visuals too; see the phone section below.

In a session whose project runs over SSH, the agent gets `visual_show` plus
`pr_create` and `pr_status`, and no other Alas tool. An SSH Workspace Checkout
session gets `visual_show` only, since the PR shepherd does not support
Workspace Checkouts. The remote helper relays these tools back to the Mac that
owns the session, so the visual, its question, and the answer behave as in a
local session. It needs a helper that advertises the visual relay (Alas upgrades it
on connect) and an agent that consumes ACP-provided MCP servers. Pi ignores
those, so SSH Pi sessions have no visual tool. Turning off the built-in tools,
or configuring a server named `alas`, removes it as for local sessions. When
the relay cannot be prepared, the MCP status shows the built-in server as
unavailable on the SSH host and says why.

| Argument | Meaning |
|---|---|
| `title` | Required. 1 to 120 characters, shown above the visual. |
| `html` | Required. A fragment, which Alas wraps in a themed frame, or a full document (starting with `<!DOCTYPE` or `<html`), used as is. At most 512 KiB of UTF-8. |
| `question` | Optional. A `prompt` (1 to 500 characters) and 2 to 8 `options`, each with a unique `id` and a `label`; `allow_multiple` permits more than one choice. |

The visual runs in a sandboxed `WKWebView`. Scripts, styles, fonts, and images
may load from https URLs while the page loads; `fetch`, XHR, WebSockets, and
WebRTC are blocked. A visual with a `question` takes no input until it has
loaded (or 10 seconds have passed): no click, keyboard focus or key press, and
no accessibility action reaches the page. From then on it can load nothing:
locking cancels any load still in flight. Page script therefore cannot send
out the user's choices before they submit. Links in a question visual do
nothing until the question is answered, and stay off if it is dismissed.

With a `question`, elements carrying `data-choice="<option id>"` select that
option when clicked on the Mac, and the answer card appears under the visual. The tool
returns immediately and does not wait: the user's answer, if any, arrives as
their next message, so the agent should end its turn after asking.

On the phone web client the visual renders in a sandboxed frame that cannot
reach the app or its token. It makes the same https loads as on the Mac, and
`fetch`, XHR, and WebSockets are blocked. A visual with a question is
display-only on the phone, so `data-choice` clicks do nothing there. The
question is answered from phone controls under the visual, and the answer goes
through the same path as a Mac answer. Links inside a visual do nothing on the
phone. A visual's frame cannot be navigated away, even by its own script: the
phone page's `frame-src 'none'` policy blocks every navigation of the frame, and
the in-frame and load-count guards remain as backstops. The question is
read-only until the phone drives the session; a "Take over to answer" hint
appears and the phone never takes over silently. Frames
load lazily and at most three stay live; older ones show "Show visual". The
raw HTML no longer appears in the `visual_show` tool card on the phone.
