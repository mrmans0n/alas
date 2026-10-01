# Getting started

This walks you from nothing to a running plugin, then to a plugin of your own.
It takes about ten minutes, most of it the first build.

## Before you start

- **Alas**, running.
- **Rust** with the WebAssembly target:

  ```bash
  rustup target add wasm32-unknown-unknown
  ```

## 1. Build and install the sample

From the repository root:

```bash
plugins/samples/hello-workspace/build.sh
```

This compiles the plugin and copies two files into Alas's plugins folder:

```
~/Library/Application Support/Alas/Plugins/hello-workspace/
├── plugin.json      # the manifest: identity, API version, requested capabilities
└── plugin.wasm      # the compiled plugin
```

## 2. Approve and run it

1. Turn on **Settings → Advanced → Experimental → Plugins**. The Advanced
   section appears as **Debug** in the settings sidebar and shows only when
   `~/.alas/.debug` exists.
2. Open **Settings → Plugins** and find **Hello Workspace 0.1.0**. It asks for one capability:
   *Read this project's worktrees and what their agent sessions are doing*.
3. Click **Approve…**.

In Debug builds of Alas, **Debug → Plugins…** is also available as a message
inspector.

Plugins never run until you approve them. Alas remembers the approval against the
exact bytes of `plugin.json` and `plugin.wasm`, so changing either file asks
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

Copy the sample and change its identity:

```bash
cp -R plugins/samples/hello-workspace ~/code/my-plugin
cd ~/code/my-plugin
rm -rf target
```

Edit `plugin.json`:

```json
{
  "id": "com.example.my-plugin",
  "name": "My Plugin",
  "version": "0.1.0",
  "api": 1,
  "entry": "plugin.wasm",
  "capabilities": ["workspace.read"]
}
```

- `id` must be unique and written like a reverse domain name. It is how Alas
  tells plugins apart. If two folders share an `id`, neither loads.
- Rename the crate in `Cargo.toml` if you like; `build.sh` finds the built file
  itself.

Change what the plugin logs in `src/lib.rs`, then:

```bash
./build.sh
```

`build.sh` installs into a folder named after the directory you run it from, so
this one lands in `…/Plugins/my-plugin`. In **Settings → Plugins** click
**Rescan**. Because the wasm changed, Alas asks you to **Approve…** again.

## Next steps

- [Pixel Office](https://github.com/mrmans0n/alas-plugins/tree/main/plugins/pixel-office) is a full canvas-tab plugin
  to install and read.
- [Writing plugins](writing-plugins.md) shows a structure that keeps your logic
  unit-testable and explains the pieces of the sample.
- The [API v1 reference](api-v1.md) lists every message and its exact shape.
- If something does not work, start with [Troubleshooting](troubleshooting.md).
