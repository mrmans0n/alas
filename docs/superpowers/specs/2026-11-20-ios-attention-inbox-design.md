# Phone inbox: the Mac's attention items

## Why

The phone's Inbox only lists sessions waiting for permission or input. The
Mac's inbox also raises run-script failures, merge conflicts, failed agents,
review replies and unreachable hosts. Away from the Mac, those are invisible
until you sit back down.

## Goals

- The phone's Inbox shows the same open items as the Mac's inbox. Agent waits
  are left out because the phone already lists them as sessions.
- Dismissing on the phone dismisses on the Mac, and the other way round. There
  is one shared store.
- A later PR pushes new items to the phone, with a Dismiss action.

## Non-goals

- New attention sources. The phone shows what the Mac already records.
- Acting on an item beyond opening its session or dismissing it. Resolving a
  conflict or rerunning a script stays on the Mac or in the session's
  workspace.
- Federated hosts. Each Mac serves its own items only.

## Approaches

1. **(Picked) Host request on the existing `.host` channel.** It adds
   `HostRequest.attention` and `dismissAttention(eventIDs:)`, phone-only, under
   capability `host.attention.phone.v1`. The phone fetches when a host comes
   online, when the Inbox appears, on pull to refresh, and every 30 s while
   the app is open; connections only live in the foreground anyway. It reuses
   the git verbs' plumbing and touches no list or federation code.
2. **A pushed `attentionList` server message**, like `worktreeList`. Updates
   would be instant, but it is a new top-level message, and every exhaustive
   switch would have to change, including federation scoping. That is not
   worth it while pushes (PR 2) carry the urgency.
3. **Host events via `subscribeAccepting`.** The phone does not consume host
   events at all today, so this needs a whole new subscription path.

## Design

- **Wire type:** `RemoteAttentionItem` (AlasRemoteKit) with id, kind, title,
  body, project, branch, occurredAt and an optional sessionID, taken from the
  `.session` jump target.
- **Building the list on the host:** `AttentionSignalAggregator` over the
  store's document, with no live signals. It keeps current, requiring-action,
  unacknowledged events, minus `agentAwaiting` and `agentPermission`. A
  headless host records none, so its list is empty.
- **Phone:** an `AttentionFeed`, created in the app root, holds the items per
  host. The tab badge counts the waiting sessions plus the items.
- **Inbox section:** a "From your Macs" section lists the items: a kind icon,
  the title, project · branch, the time, and up to 3 lines of the body.
  - Tapping an item with a session opens the session. Tapping any other item
    expands its body.
  - Each item has a Dismiss button, and the dismissal shows on the phone at
    once.
