# Follow-ups during ACP turns

Adapter investigation for issue #1740, 2026-10-03. Initialize probes against
the installed adapters confirmed:

| Adapter | Version | Native steering |
| --- | --- | --- |
| `@agentclientprotocol/codex-acp` | 2.1.1 | Advertises `_meta.steering.supported: true` |
| `@agentclientprotocol/claude-agent-acp` | 0.85.1 | Advertises the same capability |
| `pi-acp` | 0.0.34 | No advertised steering extension |

The capability is in the **top-level** initialize `_meta`, beside
`agentCapabilities`. Supporting adapters accept `_session/steering` with
`sessionId` and `prompt`, using the ordinary prompt content-block shape.
`injected` joins the running turn, whose original `session/prompt` still owns
completion. A second concurrent `session/prompt` is not the steering API.

The turn can finish before the request arrives. Claude accepts
`_meta.steering.idleBehavior: "promptRequired"` and returns `promptRequired`
without consuming the prompt, allowing Alas to send a normal owned prompt.
Codex 2.1.1 instead returns `startedNewTurn`; its continuation completes through
`session_info_update._meta.codex.threadStatus` active/idle/systemError updates.
The queue must remain held until that continuation ends. Alas uses this detached
lifecycle only for an identified Codex adapter or a session that has emitted the
Codex status signal. An untracked `startedNewTurn` retains uncertain recovery
and reports an explicit completion error. The broker holds it as awaiting input
across reattachment, so earlier queued work remains held until an explicit stop
or restart establishes a safe boundary. An unknown or failed
steering result must not trigger a blind resend. Before dispatch, Alas persists
an unconfirmed steering item in the queue. If attachment or acknowledgement is
lost, it restores as delivery uncertain and requires an explicit retry; Alas
cannot safely infer whether the adapter consumed it. A confirmed `promptRequired`
continuation uses the normal persistent queued-send path. A method-not-found
response disables native steering and dispatches its cancel-and-resend fallback
through that same path, preserving the operation key and broker provenance.

Pi's RPC layer has steering concepts, but this installed ACP adapter forwards
ordinary prompts without a steering option. It retains cancel-and-resend.
Adapters without the advertised capability do the same. Steering during local
prompt preparation also uses that fallback because the original request may
not have reached the adapter yet.

Sources: [Codex steering example](https://github.com/agentclientprotocol/codex-acp/blob/main/examples/steering.ts),
[Claude steering example](https://github.com/agentclientprotocol/claude-agent-acp/blob/main/examples/steering.ts),
and the installed adapter implementations. The probes only initialized agents;
they did not run model turns.
