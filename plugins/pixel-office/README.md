# Pixel Office

A plugin that draws your project as a pixel-art office: one desk per worktree,
one character per agent session. It uses plugin API 2 (canvas tabs).

## Build and install

From the repository root:

```bash
rustup target add wasm32-unknown-unknown
plugins/pixel-office/build.sh
```

`build.sh` works from any directory and installs into `~/Library/Application Support/Alas/Plugins/pixel-office`.

Then turn on **Settings → Debug → Experimental → Plugins** (the section is
called Advanced in the config and appears as **Debug** in the sidebar; it only
shows when `~/.alas/.debug` exists). Open **Settings → Plugins**, click
**Approve…** on Pixel Office, and open **View → Plugins → Office**.

## Reading the office

Characters:

| State | Look |
| --- | --- |
| Working | Seated at the desk, typing, monitor lit, plan progress bar |
| Awaiting input | Hand raised with a "?" |
| Permission request | Hand raised with a blinking red "!" |
| Idle | Wanders the lounge; asleep on the couch after 5 idle minutes |
| Unknown | Dimmed |

Desks:

- A lamp marks the current worktree.
- Paper piles show changed files.
- A red sign means conflicts.
- "+N" means more sessions than seats.
- A "+N more" sign means N worktrees did not fit in the room.

Click a character to open its session. Click a desk to switch to its worktree.

## Art rules

- Art is palette-only PNGs in `assets/`. `build.rs` rejects any off-palette colour.
- Sprite sheet layouts live in `src/atlas.rs`.
