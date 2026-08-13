# GG Stack Query Timeout

## Goal

Allow `gg ls --json` to finish in repositories where forge metadata lookup takes longer than Git's 30-second read timeout, so detached stack navigation can publish the complete stack.

## Design

`ProcessGGCommandRunner` will use its existing 600-second GG command timeout for stack queries instead of `Process.defaultTimeout`. No new setting, retry policy, cache behavior, or presentation state will be introduced.

The existing timeout-routing test will assert that `gg ls --json`, including the client-operation-ID form, receives 600 seconds. Other GG commands continue using the same 600-second timeout they use today.

## Failure Behavior

Commands that exceed 600 seconds continue through the existing timeout error and stack fallback path. Cancellation behavior is unchanged.

## Out of Scope

- Making `gg ls --json` local-only or reducing its forge API work.
- Retaining stale stack rows after a failed refresh.
- Adding configurable timeouts, retries, or new UI.
