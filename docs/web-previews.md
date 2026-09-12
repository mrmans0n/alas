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
