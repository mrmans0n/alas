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
a bounded system DNS lookup and reject unresolved names or any returned loopback
address, including hosts-file aliases. Enter a reachable remote URL instead.
This feature does not create tunnels or infer local port forwarding.

These checks prevent accidental local endpoint routing; they are not a network
sandbox. WebKit uses this Mac's network and its own connections, so preflight
DNS checks cannot pin a later connection or prevent DNS rebinding and arbitrary
page subresource requests.

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

Captures return PNG image data plus URL, capture time, CSS viewport dimensions,
device pixel ratio, scroll position, region, and available element metadata.
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
and 128 KiB; PNG captures at 8 megapixels and 8 MiB. Browser content and tool
results remain untrusted application data.
