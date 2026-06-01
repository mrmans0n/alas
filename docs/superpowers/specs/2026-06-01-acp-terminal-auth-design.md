# ACP Terminal Auth Design

Date: 2026-06-01

## Problem

Alas can launch ACP adapters and talk to agents, but it does not participate in ACP authentication negotiation. On machines where an adapter requires authentication, the ACP pane can fail with raw JSON-RPC errors such as:

```text
ACP error -32603: Internal error: Failed to authenticate. API Error: 401 Invalid authentication credentials
```

The same provider can still work in a normal terminal because terminal CLI auth and ACP auth are separate surfaces. Cursor showing similar ACP-only auth failure indicates this should be fixed at the ACP client layer, not with Claude-specific credential handling.

## Goals

- Advertise ACP terminal-auth support during `initialize`.
- Decode advertised ACP auth methods with enough structure to support terminal login.
- Surface auth-required failures as a clear pane-level auth state instead of a generic internal error.
- Let the user launch the provider's advertised terminal auth command from Alas.
- Retry ACP attach after the auth command exits.
- Keep the first implementation narrowly focused on terminal auth.

## Non-Goals

- Do not build a secrets UI for environment-variable auth in the first pass.
- Do not invent provider-specific Claude or Cursor login commands when the adapter advertises one.
- Do not persist auth methods or auth state beyond the runtime session.
- Do not change terminal CLI auth behavior outside ACP panes.

## Current Behavior

`ACPConnection.initialize()` sends only filesystem and terminal capabilities, then returns only prompt capabilities to callers. The client does decode `authMethods`, but only as `id` and `name`; method type, terminal arguments, environment variables, and `_meta` are discarded. There is also no `authenticate` method wrapper.

The existing `ACPSession.SetupState` has only:

- `checking`
- `ready`
- `needsSetup(reason:)`

That state is already used by `ACPTabView` to show adapter install/update banners and retry attach after setup changes. ACP auth should reuse that pane-level setup surface rather than adding a detached alert or global settings flow.

## Design

### Protocol Model

Extend `ACPClientCapabilities` to include:

- `auth.terminal = true`
- `_meta["terminal-auth"] = true`

The `_meta` field is included because the current Claude ACP adapter checks it when returning richer terminal-auth command metadata. The standard `auth.terminal` field is the primary capability.

Extend auth method decoding to model at least:

- `agent`: default type, agent handles auth itself.
- `terminal`: client launches an interactive terminal auth command.
- `env_var`: provider needs credentials as environment variables.

Terminal auth methods should retain:

- `id`
- `name`
- `description`
- `args`
- `env`
- `_meta["terminal-auth"].command`
- `_meta["terminal-auth"].args`
- `_meta["terminal-auth"].label`

The login command resolution should prefer `_meta["terminal-auth"].command` and args when present, because that gives Alas a complete command line. If only `args` are present, run the current ACP adapter command with those args. If neither produces a runnable command, surface an unsupported-auth message.

### Connection API

Change initialization to return a richer value, for example:

```swift
struct ACPInitializedSession {
    let promptCapabilities: ACPInitializeResult.ACPPromptCapabilities
    let authMethods: [ACPAuthMethod]
}
```

`ACPSessionManager.attach` stores the prompt capabilities as it does today and keeps the auth methods on the session runtime state.

Add an `authenticate(methodId:)` wrapper for the ACP `authenticate` request, but do not require it for terminal auth unless a provider's advertised method needs it. The first implementation can launch terminal auth and then retry attach. The wrapper exists so future agent-handled methods have a protocol entry point.

### Session State

Extend `ACPSession.SetupState` with an auth-specific case:

```swift
case needsAuth(methods: [ACPAuthMethod], reason: String?)
```

This is runtime-only, matching the existing setup state. The session can also retain `authMethods` as a published runtime field if that keeps the enum lightweight and SwiftUI updates simpler.

When `initialize`, `session/new`, `session/load`, or `session/prompt` fails with an auth-required ACP error or a recognizable 401 authentication message, translate it to `needsAuth` if auth methods are known. Do not leave the user with only `lastError`.

If no auth methods are known, show a clear authentication-required message and keep the raw error available in `lastError` for diagnostics.

### UI Flow

Add an auth banner in the same top-of-pane region as the adapter setup nudge.

For terminal auth:

- Show a concise message such as `Claude needs sign-in to continue.`
- Use the advertised label when available for the button, otherwise `Sign In`.
- Launch the advertised terminal auth command in an Alas terminal surface using the same augmented ACP process environment.
- When the auth command exits, clear the prior auth error and retry `attach`.

For env-var auth in the first pass:

- Decode the method.
- Show a clear unsupported message such as `This provider requires environment credentials. Configure them in the environment used to launch Alas, then reconnect.`
- Do not build a credential-entry UI yet.

For agent auth in the first pass:

- Decode the method.
- If the provider returns auth-required and only agent methods are available, show a clear unsupported message rather than retrying blindly.

### Data Flow

1. `ACPSessionManager.attach` resolves the `ACPLaunchSpec`.
2. Setup check passes and the ACP adapter process starts.
3. `initialize` sends auth terminal capabilities.
4. The manager stores prompt capabilities and advertised auth methods.
5. If session creation succeeds, session state becomes ready as today.
6. If session creation fails because auth is required, session state becomes `needsAuth`.
7. The banner renders the best supported auth method.
8. The user clicks `Sign In`.
9. Alas launches the advertised terminal command with the ACP process environment.
10. When that process exits, Alas retries attach.

### Error Handling

- Auth-required JSON-RPC errors should not be shown as generic internal errors.
- Preserve the detailed raw message in `lastError` for debugging.
- If terminal auth exits nonzero, keep `needsAuth` visible and show the exit failure in the banner.
- If retry attach fails with auth again, keep the auth banner visible.
- If retry attach succeeds, clear the auth state and last auth error.

### Testing Strategy

Use Swift Testing and test-first implementation.

Protocol tests:

- initialize request encodes `clientCapabilities.auth.terminal = true`.
- initialize request encodes `_meta["terminal-auth"] = true`.
- terminal auth methods decode command, args, label, and env.
- env-var auth methods decode without crashing.

Connection/manager tests:

- initialize returns prompt capabilities and auth methods.
- auth-required session creation sets `setupState = .needsAuth`.
- non-auth JSON-RPC errors still surface as failures.
- retry after auth uses the normal attach path.

UI/copy tests:

- auth banner chooses the first supported terminal auth method.
- unsupported env-var-only auth produces clear copy.
- sign-in button label uses advertised terminal auth label when present.

## Rollout

Keep the first PR scoped to terminal auth negotiation and launch. Do not include env-var credential storage or provider-specific command guesses. After terminal auth is working for Claude and Cursor, revisit env-var auth only if a real provider requires it.

