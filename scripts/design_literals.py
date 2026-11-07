#!/usr/bin/env python3
"""Count hardcoded font sizes, paddings and corner radii in Swift sources.

    python3 scripts/design_literals.py [paths...]
    python3 scripts/design_literals.py --migrated

Paths are files or directories (searched for *.swift) and default to Alas/.
Prints per-file counts and a final "total <n>" line. With --migrated, the
paths come from scripts/design-migrated-paths.txt (one per line, relative to
the repo root, '#' starts a comment) and the exit status is 1 if any count is
above zero.

A line ending in "// design-literal: <reason>" is exempt; the reason must be
non-empty.

Only these literals are counted: .system(size:), NSFont.systemFont(ofSize:),
.padding(...) and cornerRadius:. Stack `spacing:` and `frame()` literals are
not counted, so a zero count does not mean a surface is fully migrated.
"""

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MIGRATED_LIST = ROOT / "scripts" / "design-migrated-paths.txt"

PATTERNS = [
    re.compile(r"font\(\.system\(size: ?[0-9]"),
    re.compile(r"NSFont\.systemFont\(ofSize: ?[0-9]"),
    re.compile(r"\.padding\((\.[a-zA-Z]+, )?[0-9]"),
    re.compile(r"cornerRadius: ?[0-9]"),
]
EXEMPT = re.compile(r"//\s*design-literal:\s*\S")


def count_file(path):
    total = 0
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if EXEMPT.search(line):
            continue
        total += sum(len(p.findall(line)) for p in PATTERNS)
    return total


def swift_files(paths):
    for path in paths:
        if path.is_dir():
            yield from sorted(path.rglob("*.swift"))
        elif path.is_file():
            yield path
        else:
            sys.exit(f"design_literals: no such path: {path}")


def migrated_paths(list_file):
    paths = []
    for line in list_file.read_text(encoding="utf-8").splitlines():
        line = line.split("#", 1)[0].strip()
        if line:
            paths.append(ROOT / line)
    return paths


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("paths", nargs="*", type=Path)
    parser.add_argument("--migrated", action="store_true", help="check the migrated path list; exit 1 on any literal")
    parser.add_argument("--paths-file", type=Path, default=MIGRATED_LIST, help="override the migrated path list")
    args = parser.parse_args()

    if args.migrated:
        paths = migrated_paths(args.paths_file)
    else:
        paths = args.paths or [ROOT / "Alas"]

    total = 0
    for path in swift_files(paths):
        n = count_file(path)
        if n:
            print(f"{n:5d}  {path}")
        total += n
    print(f"total {total}")
    return 1 if args.migrated and total else 0


if __name__ == "__main__":
    sys.exit(main())
