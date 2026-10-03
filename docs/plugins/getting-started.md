# Getting started

This walks you from nothing to a running plugin, then to a plugin of your own.
It takes about five minutes. There is nothing to compile: a plugin is a manifest
and one JavaScript file.

## Before you start

- **Alas**, running.

## 1. Install the sample

From the repository root:

```bash
plugins/samples/hello-workspace/build.sh
```

This copies two files into Alas's plugins folder:

```
~/Library/Application Support/Alas/Plugins/hello-workspace/
├── plugin.json      # the manifest: identity, API version, requested capabilities
└── plugin.js        # the plugin
```

## 2. Approve and run it

1. Open **Settings → Plugins** and check that **Enable plugins** is on (it is
   by default).
2. Find **Hello Workspace 0.2.0**. It asks for one capability:
   *Read this project's worktrees and what their agent sessions are doing*.
3. Click **Approve…**.

In Debug builds of Alas, **Debug → Plugins…** is also available as a message
inspector.

Plugins never run until you approve them. Alas remembers the approval against the
exact bytes of `plugin.json` and `plugin.js`, so changing either file asks
again. See [Concepts → Trust](concepts.md#trust-and-approval).

## 3. See what it does

Every project in Alas gets its own instance of the plugin. **Settings → Plugins**
lists them under the plugin as `<project>: <state>`. You should see
`my-project: Active`; expand it for log lines like these:

```
[info] activated for my-project
[info] snapshot: 3 worktrees, 2 sessions (1 running)
[warn] worktree/switch replied -32001 capability not granted: worktree.switch
```

- The first line is the plugin acknowledging that Alas started it.
- The second is the answer to a `workspace/snapshot` request.
- The third is deliberate. The sample also asks to switch worktree, which it
  never declared in its manifest. Alas refuses with error `-32001` and the plugin
  carries on. A refused request is not a failure.

Now change something. Start an agent session, or let one change state (start
working, or stop to ask for permission). Within about a second a `changed: …`
line appears.

In a Debug build of Alas, open **Debug → Plugins…** and then **Messages** on the
row to see every JSON message going in each direction, `→` to the plugin and `←`
from it. This is the fastest way to learn the protocol.

## 4. Make your own

Copy the sample:

```bash
cp -R plugins/samples/hello-workspace ~/code/my-plugin
cd ~/code/my-plugin
```

Edit `plugin.json` to change its identity:

```json
{
  "id": "com.example.my-plugin",
  "name": "My Plugin",
  "version": "0.1.0",
  "api": 4,
  "entry": "plugin.js",
  "capabilities": ["workspace.read"]
}
```

`id` must be unique and written like a reverse domain name. It is how Alas tells
plugins apart. If two folders share an `id`, neither loads.

Change what the plugin logs in `plugin.js`, then:

```bash
./build.sh
```

`build.sh` copies the two files into a folder named after the directory you run
it from, so this one lands in `…/Plugins/my-plugin`. In **Settings → Plugins**
click **Rescan**. Because `plugin.js` changed, Alas asks you to **Approve…**
again.

## Next steps

- [Pixel Office](https://github.com/mrmans0n/alas-plugins/tree/main/plugins/pixel-office) is a full canvas-tab plugin
  to install and read.
- [Writing plugins](writing-plugins.md) explains the pieces of the sample, how to
  test without Alas, and how to use TypeScript.
- The [API v4 reference](api-v4.md) covers the runtime and lists every message.
- If something does not work, start with [Troubleshooting](troubleshooting.md).
