# Concepts

How plugins run, what they are trusted with, and how they fail. For exact field
names and numbers, see the [API v1 reference](api-v1.md).

## A plugin is passive

A plugin does nothing on its own. Its code runs only when Alas hands it a
message, and only for the length of that one call. There are no threads, no
timers, and no background work. Between calls the plugin sleeps, and everything
it keeps in memory (globals, the heap) is still there when the next message
arrives.

This shapes how you write one: react to a message, send your replies, return.

## One instance per plugin, per project

Alas starts a separate instance of your plugin for every project. Instances have
their own memory and share nothing, so a plugin can assume that everything it
sees, and everything it may act on, belongs to the one project named in its
activation message.

## Messages, not function calls

All communication is JSON-RPC 2.0 messages:

- **Alas → plugin.** Alas writes one message into the plugin's memory and calls
  `alas_handle`. That is one *delivery*.
- **Plugin → Alas.** While it runs, the plugin calls `alas.send` for each message
  it wants to send. Alas does not act on them immediately. It collects them and
  processes them **after `alas_handle` returns**, so Alas never calls back into a
  plugin that is still running.
- **Replies.** If a plugin sent a *request*, Alas answers in a **later**
  `alas_handle` call. The plugin matches replies to requests by `id`.

Startup looks like this:

```
Alas                                         Plugin
 │                                             │
 │── alas/activate (id 0) ────────────────────▶│  alas_handle #1
 │◀── response to id 0 ────────────────────────│  (plugin must answer here)
 │◀── request: workspace/snapshot (id 1) ──────│
 │                                             │
 │── response to id 1 (the snapshot) ─────────▶│  alas_handle #2
 │◀── notification: log ───────────────────────│
 │                                             │
 │── workspace/changed (later, on change) ────▶│  alas_handle #3
```

The activation response must be sent during the very first call. A plugin that
does not answer is stopped.

## Lifecycle

An instance moves through these states, which **Debug → Plugins…** shows per row:

```
 loaded → activating → active → deactivating → stopped
              │           │
              └───────────┴──────▶ failed(reason)
```

- **activating** — the module is loaded and `alas/activate` was delivered.
- **active** — the plugin answered activation; it now receives notifications and
  replies.
- **deactivating / stopped** — Alas sent `alas/deactivate`, then discarded the
  instance whatever the plugin did. Anything sent in response is ignored.
- **failed** — Alas stopped the plugin because it broke a rule (see below). The
  reason is shown and logged. **Restart** creates a fresh instance and activates
  it again, with empty memory.

### What stops a plugin

A plugin is stopped when it:

- traps (an `unreachable`, out-of-bounds access, stack overflow, and so on),
- runs out of its execution budget,
- sends something that is not valid JSON-RPC 2.0,
- hands Alas a pointer or length outside its own memory,
- sends a message larger than 1 MiB, or more than 64 messages in one call,
- keeps asking for replies without end (more than 64 calls in one delivery),
- or does not answer `alas/activate`.

A request that is merely *refused* is different. An unknown method, a missing
capability, or bad parameters produce an **error response**, and the plugin keeps
running. See [Errors](api-v1.md#6-errors) for the exact reasons.

If a call fails, the messages the plugin sent earlier in that same call are
discarded along with it. That includes `log` messages, so a plugin that crashes
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

- Alas computes a SHA-256 hash over the manifest bytes and the wasm bytes.
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

- A plugin has **no ambient access**: no filesystem, network, environment, clock,
  or randomness. A module that imports anything other than `alas.send` fails to
  load, which rules out WASI.
- A plugin has **hard limits** on execution time, memory, table size, and message
  volume, so a buggy or hostile plugin cannot hang or exhaust Alas.
- Alas **validates every pointer** a plugin passes it before reading memory.
- Capability checks happen on every request.

What it does not give you:

- Plugins run **inside Alas's process**, in a WebAssembly interpreter. The sandbox
  contains what plugin code can do, but a flaw in the interpreter itself would
  not be contained. Approve a plugin as you would install any software.
- What a plugin does with the data it may read is up to the plugin. `workspace.read`
  exposes branch names, session titles, and agent state for one project.

## Versioning

- The manifest's `api` field is a whole number naming the contract the plugin was
  written against. This Alas supports API `1`. A plugin declaring anything else
  is refused, with a message that names both versions.
- Unknown manifest fields are ignored, so a newer manifest still loads on an
  older Alas as long as its `api` is supported.
- New behaviour arrives as new methods, new fields on existing messages, or new
  capabilities. Plugins should ignore fields and notifications they do not know.
