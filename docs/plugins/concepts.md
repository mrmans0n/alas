# Concepts

How plugins run, what they are trusted with, and how they fail. For exact field
names and numbers, see the [API v4 reference](api-v4.md).

## A plugin is passive

A plugin does nothing on its own. Its code runs only when Alas hands it a
message, and only for the length of that one call. There are no threads, no
timers, and no background work. Between calls the plugin sleeps, and everything
it keeps in memory (module variables, objects) is still there when the next
message arrives.

This shapes how you write one: react to a message, send your replies, return.

## One instance per plugin, per project

Alas starts a separate instance of your plugin for every project. Each instance
evaluates your script in its own JavaScriptCore VM, so instances share nothing, so a plugin can assume that everything it
sees, and everything it may act on, belongs to the one project named in its
activation message.

## Messages, not function calls

All communication is JSON-RPC 2.0 messages:

- **Alas → plugin.** Alas calls your `globalThis.handle` with one message as a
  JSON string. That is one *delivery*.
- **Plugin → Alas.** While it runs, the plugin calls `alas.send` with a JSON
  string for each message it wants to send. Alas does not act on them
  immediately. It collects them and processes them **after `handle` returns**, so Alas never calls back into a
  plugin that is still running.
- **Replies.** If a plugin sent a *request*, Alas answers in a **later**
  `handle` call. The plugin matches replies to requests by `id`.

Startup looks like this:

```
Alas                                         Plugin
 │                                             │
 │── alas/activate (id 0) ────────────────────▶│  handle #1
 │◀── response to id 0 ────────────────────────│  (plugin must answer here)
 │◀── request: workspace/snapshot (id 1) ──────│
 │                                             │
 │── response to id 1 (the snapshot) ─────────▶│  handle #2
 │◀── notification: log ───────────────────────│
 │                                             │
 │── workspace/changed (later, on change) ────▶│  handle #3
```

The activation response must be sent during the very first call. A plugin that
does not answer is stopped.

## Lifecycle

An instance moves through these states, which **Settings → Plugins** shows per project
(as Loaded, Starting, Active, Stopping, Stopped, and `Stopped: <reason>` for failed):

```
 loaded → activating → active → deactivating → stopped
              │           │
              └───────────┴──────▶ failed(reason)
```

- **activating** — the script is evaluated and `alas/activate` was delivered.
- **active** — the plugin answered activation; it now receives notifications and
  replies.
- **deactivating / stopped** — Alas sent `alas/deactivate`, then discarded the
  instance whatever the plugin did. Anything sent in response is ignored.
- **failed** — Alas stopped the plugin because it broke a rule (see below). The
  reason is shown and logged. **Restart** creates a fresh instance and activates
  it again, with a fresh VM and empty memory.

### What stops a plugin

A plugin is stopped when it:

- throws an exception it does not catch, including a syntax error in the script,
- runs longer than 250 ms in one call (1 s to evaluate the script),
- sends something that is not valid JSON-RPC 2.0,
- passes `alas.send` or `alas.present` something they refuse, even if it
  catches the resulting exception,
- sends a message larger than 1 MiB, or more than 64 messages in one call,
- keeps asking for replies without end (more than 64 calls in one delivery),
- or does not answer `alas/activate`.

A request that is merely *refused* is different. An unknown method, a missing
capability, or bad parameters produce an **error response**, and the plugin keeps
running. See [Why a plugin stops](api-v4.md#5-why-a-plugin-stops) and
[Errors](api-v1.md#6-errors) for the exact reasons.

If a call fails, the messages the plugin sent earlier in that same call are
discarded along with it. That includes `log` messages, so a plugin that throws
loses its last words. Log before you do anything risky, in an earlier message.

## Capabilities

A capability is one permission listed in the manifest, for example
`workspace.read`. Each plugin request needs a specific capability. Alas checks the
capability **at the moment of the request** against what the user approved, not
against what the manifest asks for. A plugin cannot use a capability it was not
granted, whatever its code does.

Capabilities are also how the plugin API grows safely. Alas refuses to load a
plugin that lists a capability it does not know.

## Trust and approval

Nothing runs until the user approves it, and approval is tied to the exact files:

- Alas computes a SHA-256 hash over the manifest bytes and the script bytes.
- Approval stores that hash together with the capabilities the manifest requested.
- If either file changes by even one byte, the hash no longer matches and the
  plugin is treated as **unapproved** again. It is not started.

Approvals live in Alas's preferences under the key `pluginApprovals.v1`. There is
no revoke button yet. To forget every approval, run:

```bash
defaults delete io.nlopez.alas pluginApprovals.v1
```

## Security model

What the sandbox gives you:

- A plugin has **no ambient access**. Its global object holds the ECMAScript
  built-ins and `alas`, nothing else: no filesystem, network, timers, modules,
  environment, or bridge to native code.
- Each instance runs in **its own JavaScriptCore VM**, so plugins cannot reach
  each other's objects.
- A watchdog stops any call that runs past its **time limit**. Messages and
  frames have size and count limits, so a buggy or hostile plugin cannot hang
  Alas or flood it.
- Capability checks happen on every request.

What it does not give you:

- Plugins run **inside Alas's process**, in JavaScriptCore with the JIT off
  (Alas does not have the JIT entitlement, and the watchdog depends on that). The
  sandbox contains what plugin code can do, but a flaw in JavaScriptCore itself
  would not be contained. Approve a plugin as you would install any software.
- **Memory is not capped.** The time limit bounds how much one call can
  allocate, but a plugin can still grow across many calls.
- What a plugin does with the data it may read is up to the plugin. `workspace.read`
  exposes branch names, session titles, and agent state for one project.

## Versioning

- The manifest's `api` field is a whole number naming the contract the plugin was
  written against. This Alas supports API `4`, the first JavaScript API. API 1
  to 3 plugins were WebAssembly and are refused with a message asking for a
  rebuild; anything else is refused with a message that names both versions.
- Unknown manifest fields are ignored, so a newer manifest still loads on an
  older Alas as long as its `api` is supported.
- New behaviour arrives as new methods, new fields on existing messages, or new
  capabilities. Plugins should ignore fields and notifications they do not know.
