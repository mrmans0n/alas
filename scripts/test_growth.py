#!/usr/bin/env python3
"""Report how a change grows or shrinks the Swift test suite relative to the app.

    python3 scripts/test_growth.py <base-ref> [<head-ref>]

Compares the merge base of the two refs with the head. Prints a Markdown
summary, appends it to $GITHUB_STEP_SUMMARY when set, and emits a GitHub
notice annotation when the test code grows faster than the app code, so the
testing policy in AGENTS.md is visible during review without failing the build.
"""

import os
import re
import subprocess
import sys

TESTS = "AlasTests"
APP = "Alas"
TEST_ATTRIBUTE = re.compile(r"^\s*@Test\b", re.MULTILINE)


def git(*args):
    return subprocess.run(["git", *args], check=True, capture_output=True, text=True).stdout


def line_delta(base, head, path):
    added = removed = 0
    for row in git("diff", "--numstat", f"{base}...{head}", "--", path).splitlines():
        plus, minus, _ = row.split("\t", 2)
        if plus != "-":  # binary files report "-"
            added += int(plus)
            removed += int(minus)
    return added, removed


def test_count(ref):
    total = 0
    for name in git("ls-tree", "-r", "--name-only", ref, "--", TESTS).splitlines():
        if name.endswith(".swift"):
            total += len(TEST_ATTRIBUTE.findall(git("show", f"{ref}:{name}")))
    return total


def report(base, head):
    merge_base = git("merge-base", base, head).strip()
    test_added, test_removed = line_delta(merge_base, head, TESTS)
    app_added, app_removed = line_delta(merge_base, head, APP)
    before, after = test_count(merge_base), test_count(head)
    test_net = test_added - test_removed
    app_net = app_added - app_removed
    lines = [
        "## Test growth",
        "",
        "| | Added | Removed | Net |",
        "|---|---:|---:|---:|",
        f"| Test lines (`{TESTS}`) | {test_added} | {test_removed} | {test_net:+d} |",
        f"| App lines (`{APP}`) | {app_added} | {app_removed} | {app_net:+d} |",
        "",
        f"`@Test` definitions: {before} → {after} ({after - before:+d}).",
        "",
        "See the testing policy in AGENTS.md: fewer, sharper tests; extend an existing suite before adding a file; deleting redundant tests is part of the job.",
    ]
    grew_faster = test_net > 0 and test_net > max(app_net, 0)
    return "\n".join(lines) + "\n", grew_faster, test_net, app_net


def main():
    if len(sys.argv) not in (2, 3):
        sys.exit(__doc__.strip())
    base = sys.argv[1]
    head = sys.argv[2] if len(sys.argv) == 3 else "HEAD"
    markdown, grew_faster, test_net, app_net = report(base, head)
    print(markdown)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a") as out:
            out.write(markdown)
    if grew_faster and os.environ.get("GITHUB_ACTIONS"):
        print(f"::notice title=Test growth::This change adds {test_net:+d} net test lines "
              f"against {app_net:+d} net app lines. Check it against the testing policy in AGENTS.md.")


if __name__ == "__main__":
    main()
