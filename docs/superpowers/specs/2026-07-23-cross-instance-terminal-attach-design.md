# Cross-Instance Persistent Terminal Attach Design

## Problem

When terminal persistence is enabled, an agent running inside an Alas terminal
can launch a second Alas build for validation. The second process inherits the
agent terminal's `ZMX_SESSION` environment variable. Alas currently removes
that key from the environment overrides it gives Ghostty, but Ghostty first
copies the app process environment and then overlays those overrides. Omitting
the key therefore leaves the inherited value present.

When the restored terminal runs `zmx attach`, zmx sees the inherited
`ZMX_SESSION` and interprets the command as a request to switch the existing
client instead of attaching another client. The original Ghostty child exits,
Alas treats that as the terminal process ending, and its normal close path
removes the shared persisted tab and kills the zmx session. Consequently, the
terminal tab disappears from both Alas instances.

## Desired Behavior

Two concurrently running Alas instances may attach to the same persisted zmx
terminal session. Both instances display a live view of the same shell, and
launching or attaching the second instance does not close the tab, terminate
the shell, or remove shared persisted tab state.

## Design

For local Ghostty terminal surfaces, `EnvBuilder` will explicitly emit
`ZMX_SESSION` with an empty value instead of merely omitting the inherited
value. Ghostty's environment overlay then shadows any `ZMX_SESSION` inherited
by the Alas process. zmx treats the empty value as no current session and
follows its normal multi-client attach path.

`ZMX_SESSION_PREFIX` remains inherited because it is user configuration and
must stay consistent across attach, list, and kill operations.

No tab ownership, persistence format, process-exit policy, or zmx lifecycle
behavior changes. Remote terminal launch remains unchanged: its environment is
separately filtered before the SSH command is created. `ZmxClient` subprocesses
also remain unchanged because `Foundation.Process.environment` replaces the
child environment rather than overlaying it.

## Alternatives Considered

- Launch zmx through `env -u ZMX_SESSION`. This removes the variable but adds a
  command wrapper and extra quoting complexity to every local terminal launch.
- Add environment-removal support to the embedded Ghostty API. This would be a
  clean general capability, but requires a vendored Ghostty change and a much
  larger integration surface than this bug warrants.

## Testing

- Update the `EnvBuilder` regression test to assert that an inherited
  `ZMX_SESSION` becomes an explicit empty override while
  `ZMX_SESSION_PREFIX` is preserved.
- Add focused coverage that the surface configuration passes an explicit empty
  environment override through to Ghostty's C configuration.
- Run the focused terminal environment/configuration tests, then the project
  build and test commands required by `AGENTS.md`.

## Acceptance Criteria

- Starting a second Alas instance from a persistent Alas terminal does not
  remove the terminal tab from either instance.
- Both instances can remain attached to and display the same zmx-backed shell.
- Explicit tab close and terminal-process-exit behavior remain unchanged.
- Non-persistent and remote terminal launch paths continue to work as before.
