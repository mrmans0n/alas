# Alas plugins

Alas plugins are WebAssembly modules that extend Alas without changing or
rebuilding the app. A plugin never touches Alas's internals. It exchanges small
JSON messages with Alas, and Alas answers only the requests the user approved.

> **Status: experimental.** Plugins are off by default. Turn them on in
> **Settings → Advanced → Experimental → Plugins**; the Advanced section appears
> as **Debug** in the settings sidebar and shows only when `~/.alas/.debug`
> exists. **Settings → Plugins** then lists installed plugins, where you approve,
> enable, revoke and restart them and read their logs. Canvas tabs open from
> **View → Plugins**. The API may still change. Progress is tracked in
> [#1560](https://github.com/mrmans0n/alas/issues/1560).

## The idea in one picture

```
   Alas (Swift)                                        Your plugin (WebAssembly)
 ┌──────────────────────────┐   one JSON message    ┌──────────────────────────┐
 │ PluginHost               │ ── alas_handle(ptr) ─▶│  your code               │
 │  · checks capabilities   │                       │  (Rust, C, Zig, …)       │
 │  · limits CPU and memory │◀──── alas.send() ──── │                          │
 └──────────────────────────┘   JSON messages       └──────────────────────────┘
```

Alas calls into the plugin with one message at a time. The plugin answers by
sending messages back. That is the whole interface: there is no file, network,
clock, or environment access.

## What a plugin can do today

- **Read** a snapshot of one project: its worktrees, whether each is dirty, and
  what every agent session in it is doing (running, waiting for input, waiting
  for permission, idle).
- **Be told** when that snapshot changes.
- **Switch** Alas to another worktree of the same project.
- **Draw** canvas tabs with clickable regions (API 2), and focus an agent session.
- **Build native view tabs**, **start tasks** (a new worktree with an agent) and
  **store data** per project (API 3, see [API v3](api-v3.md)).
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
| Look up an exact field, message, error, or limit | [API v1 reference](api-v1.md), [API v2 additions](api-v2.md), [API v3 additions](api-v3.md) |
| Write a plugin: Rust patterns, testing, other languages | [Writing plugins](writing-plugins.md) |
| Work out why my plugin does not load or stops | [Troubleshooting](troubleshooting.md) |

A complete working plugin lives in
[`plugins/samples/hello-workspace`](../../plugins/samples/hello-workspace).

Kanban, Pixel Office, the Rust SDK and any plugin you want others to install live in
[mrmans0n/alas-plugins](https://github.com/mrmans0n/alas-plugins).
