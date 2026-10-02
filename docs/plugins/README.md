# Alas plugins

Alas plugins are JavaScript files that extend Alas without changing or
rebuilding the app. A plugin never touches Alas's internals. It exchanges small
JSON messages with Alas, and Alas answers only the requests the user approved.

> **Status: experimental.** Plugins are off by default. Turn them on in
> **Settings → Advanced → Experimental → Plugins**; the Advanced section appears
> as **Debug** in the settings sidebar and shows only when `~/.alas/.debug`
> exists. **Settings → Plugins** then lists installed plugins, where you approve,
> enable, revoke and restart them and read their logs. Canvas tabs open from
> **View → Plugins**. The API may still change: API 4 replaced the WebAssembly
> runtime of API 1 to 3 with JavaScript, and older plugins no longer load (see
> [Migrating](api-v4.md#6-migrating-from-api-1-to-3)). Progress is tracked in
> [#1560](https://github.com/mrmans0n/alas/issues/1560).

## The idea in one picture

```
   Alas (Swift)                                        Your plugin (JavaScriptCore)
 ┌──────────────────────────┐   one JSON message    ┌──────────────────────────┐
 │ PluginHost               │ ──── handle(json) ───▶│  your code               │
 │  · checks capabilities   │                       │  (JavaScript or          │
 │  · limits time per call  │◀──── alas.send() ──── │   TypeScript, bundled)   │
 └──────────────────────────┘   JSON messages       └──────────────────────────┘
```

Alas calls into the plugin with one message at a time. The plugin answers by
sending messages back. That is the whole interface: there is no file, network,
timer, or environment access.

## What a plugin can do today

- **Read** a snapshot of one project: its worktrees, whether each is dirty, and
  what every agent session in it is doing (running, waiting for input, waiting
  for permission, idle).
- **Be told** when that snapshot changes.
- **Switch** Alas to another worktree of the same project.
- **Draw** canvas tabs with clickable regions, and focus an agent session.
- **Build native view tabs**, **start tasks** (a new worktree with an agent) and
  **store data** per project.
- **Log** lines that show up in **Settings → Plugins**.

## What it cannot do yet

Add sidebars or panels outside a tab, make network requests, or read or write
files. These are planned; see the roadmap in
[#1560](https://github.com/mrmans0n/alas/issues/1560).

## Where to go next

| I want to… | Read |
|---|---|
| Run the sample plugin and see it work | [Getting started](getting-started.md) |
| Understand how plugins run, what they are trusted with, and how they fail | [Concepts](concepts.md) |
| Look up the runtime, limits, and every method | [API v4 reference](api-v4.md) |
| Look up an exact message, field, or error | [API v1](api-v1.md), [API v2](api-v2.md), [API v3](api-v3.md) message references |
| Write a plugin: structure, testing, TypeScript | [Writing plugins](writing-plugins.md) |
| Work out why my plugin does not load or stops | [Troubleshooting](troubleshooting.md) |

A complete working plugin lives in
[`plugins/samples/hello-workspace`](../../plugins/samples/hello-workspace).

Kanban, Pixel Office, the TypeScript SDK (`@alas/plugin`, in progress) and any
plugin you want others to install live in
[mrmans0n/alas-plugins](https://github.com/mrmans0n/alas-plugins).
