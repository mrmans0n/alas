#!/usr/bin/env python3
"""Assemble a judging panel: one folder per app, files named for the screen.

    build-panel.py --alas <capture-round> --refs <refs-dir> --out <panel-dir>

<capture-round> holds dark/ and light/ (capture.sh output). <refs-dir> holds
one folder per reference app, with any image names. Images are copied as-is.
"""
import argparse
import re
import shutil
import sys
from pathlib import Path

IMAGES = {".png", ".jpg", ".jpeg", ".webp", ".gif"}
SCREENS = ("sidebar", "transcript", "window")


def slug(text):
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-") or "image"


def images(folder):
    return sorted(p for p in folder.iterdir() if p.suffix.lower() in IMAGES)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--alas", required=True, type=Path)
    ap.add_argument("--refs", required=True, type=Path)
    ap.add_argument("--out", required=True, type=Path)
    args = ap.parse_args()

    copied = []
    alas_out = args.out / "Alas"
    for theme in ("dark", "light"):
        for screen in SCREENS:
            src = args.alas / theme / f"{screen}.png"
            if src.is_file():
                alas_out.mkdir(parents=True, exist_ok=True)
                dest = alas_out / f"{screen}-{theme}.png"
                shutil.copy2(src, dest)
                copied.append(dest)
    if not copied:
        sys.exit(f"error: no Alas captures found under {args.alas}/{{dark,light}}")

    apps = []
    if args.refs.is_dir():
        apps = sorted(d for d in args.refs.iterdir() if d.is_dir() and not d.name.startswith("."))
    if not apps:
        print(f"warning: no reference apps in {args.refs}; panel has Alas only", file=sys.stderr)
    for app in apps:
        files = images(app)
        if not files:
            print(f"warning: no images for reference app {app.name}; skipped", file=sys.stderr)
            continue
        out = args.out / app.name
        out.mkdir(parents=True, exist_ok=True)
        for f in files:
            dest = out / f"{slug(f.stem)}{f.suffix.lower()}"
            if dest.exists():
                sys.exit(f"error: {app.name}: {f.name} collides with another file as {dest.name}")
            shutil.copy2(f, dest)
            copied.append(dest)

    for p in copied:
        print(p.resolve())


if __name__ == "__main__":
    main()
