#!/usr/bin/env python3
"""Checks that AlasCore's folders only depend downward on the module layering
in docs/plans/2026-10-20-alascore-modules.md, ahead of splitting the folders
into SwiftPM targets.

Each top-level folder of the sources belongs to a module, and the modules are
ordered bottom to top. A file may name a type declared in its own module or in
a lower one; naming a type declared in a higher module is a violation, reported
as `<file>: <Type> (<from module> -> <to module>)`.

Known violations are listed in the allowlist, one `<file> <Type>` per line. The
check fails on a violation the allowlist does not list, and on an allowlist
entry that is no longer a violation, so the list only shrinks.

A type counts when it is declared at the top level of a file (`struct`,
`class`, `enum`, `protocol`, `actor`, `typealias`) in exactly one module. A
reference is any occurrence of its name, comments included: precise enough to
guide the moves, and the compiler takes over once the targets exist.

Usage: check-alascore-layers.py [--sources DIR] [--allowlist FILE] [--update]
  --update rewrites the allowlist to the current violations.
"""
import argparse
import os
import re
import sys

# Bottom to top. A folder not listed here fails the check, so a new folder
# gets a module when it is created.
MODULES = [
    ("AlasFoundation", ["Helpers", "SQLiteKit", "JSONRPC", "Watch", "Dialogs", "Diagnostics"]),
    ("AlasModel", ["Persistence"]),
    ("AlasPlatform", ["SSH", "Git", "Search", "RepoHooks", "Zmx", "Updates"]),
    ("AlasFeatures", ["Integrations", "Issues", "Center", "Shepherd", "Checkpoints", "Projects",
                      "Workspace", "RunScripts", "Schedules", "Attention"]),
    ("AlasCode", ["Code"]),
    ("AlasAgents", ["ACP", "Agents", "Harness", "Plugins", "FailureBriefs", "Right"]),
    ("AlasHostCore", ["Core", "Remote"]),
]

DECLARATION = re.compile(
    r"^(?:@\w+(?:\([^)]*\))?\s+)*"
    r"(?:(?:public|internal|package|final|open|indirect|nonisolated)\s+)*"
    r"(?:struct|class|enum|protocol|actor|typealias)\s+([A-Z]\w*)",
    re.M,
)
WORD = re.compile(r"\b[A-Z]\w*\b")


def module_of(folder):
    for index, (name, folders) in enumerate(MODULES):
        if folder in folders:
            return index, name
    return None


def violations(sources):
    files = {}
    unmapped = set()
    for directory, _, names in os.walk(sources):
        for name in names:
            if not name.endswith(".swift"):
                continue
            path = os.path.join(directory, name)
            relative = os.path.relpath(path, sources)
            folder = relative.split(os.sep)[0]
            module = module_of(folder) if os.sep in relative else None
            if module is None:
                unmapped.add(folder if os.sep in relative else relative)
                continue
            with open(path, encoding="utf-8", errors="replace") as handle:
                files[relative] = (module, handle.read())
    declared = {}
    for relative, (module, text) in files.items():
        for match in DECLARATION.finditer(text):
            declared.setdefault(match.group(1), set()).add(module)
    owner = {name: next(iter(modules)) for name, modules in declared.items() if len(modules) == 1}
    found = set()
    for relative, ((level, name), text) in files.items():
        for word in set(WORD.findall(text)):
            target = owner.get(word)
            if target and target[0] > level:
                found.add((relative, word, name, target[1]))
    return found, unmapped


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    root = os.path.dirname(here)
    parser = argparse.ArgumentParser()
    parser.add_argument("--sources", default=os.path.join(root, "Packages/AlasCore/Sources/AlasCore"))
    parser.add_argument("--allowlist", default=os.path.join(here, "alascore-layers-allowlist.txt"))
    parser.add_argument("--update", action="store_true")
    args = parser.parse_args()

    found, unmapped = violations(args.sources)
    if unmapped:
        for folder in sorted(unmapped):
            print(f"error: {folder} belongs to no module; add it to MODULES in {os.path.basename(__file__)}")
        return 1
    current = {f"{path} {name}" for path, name, _, _ in found}
    if args.update:
        with open(args.allowlist, "w", encoding="utf-8") as handle:
            handle.write("".join(f"{line}\n" for line in sorted(current)))
        print(f"wrote {len(current)} entries to {args.allowlist}")
        return 0
    try:
        with open(args.allowlist, encoding="utf-8") as handle:
            allowed = {line.strip() for line in handle if line.strip() and not line.startswith("#")}
    except FileNotFoundError:
        allowed = set()
    failed = False
    for path, name, source, target in sorted(found):
        if f"{path} {name}" not in allowed:
            print(f"error: {path}: {name} ({source} -> {target}) depends on a higher module")
            failed = True
    for line in sorted(allowed - current):
        print(f"error: allowlisted '{line}' is no longer a violation; remove it from the allowlist")
        failed = True
    if not failed:
        print(f"alascore layers: ok ({len(current)} known violations)")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
