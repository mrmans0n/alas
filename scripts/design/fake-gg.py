#!/usr/bin/env python3
"""A scripted stand-in for git-gud (`gg`), for design captures.

make-demo-profile.sh installs this as <profile>/bin/gg and capture.sh puts that
directory first on the PATH Alas resolves, so the gg screens render the demo
data below without a forge, a network or a real gg. It answers only what Alas
reads; every command that would change a repository exits 1 and does nothing.
See README.md.
"""
import json
import subprocess
import sys

VERSION = "0.9.14"
BASE = "main"
USER = "nacho"
PR_URL = "https://github.com/lantern-dev/lantern/pull/{}"

# stack name -> worktree branch (the stack lives on that branch when it exists)
# and its entries, bottom first. State is the forge's: merged, open or draft.
# "failed_refresh" marks the one PR whose forge lookup fails.
STACKS = [
    {
        "name": "refactor-transcript-scroller-row-height-cache",
        "branch": "nacho/refactor-transcript-scroller-row-height-cache",
        "behind": 0,
        "current": 2,
        "entries": [
            ("a41c7e2", "perf(transcript): cache measured row heights", 455, "merged", True, "success"),
            ("b92d0f5", "refactor(transcript): scroller owns the height cache", 456, "open", True, "success"),
            ("c07e3a9", "test(transcript): row height cache invalidation", 457, "open", False, "pending"),
        ],
    },
    {
        "name": "invoice-export",
        "branch": "feat/invoice-export",
        "behind": 0,
        "entries": [
            ("d1f40b8", "feat(billing): add CSV export for invoices", 412, "open", True, "success"),
            ("e5a2c61", "feat(billing): stream large exports to disk", 413, "open", True, "success"),
            ("f3b9d04", "feat(web): export button on the invoice list", 414, "open", False, "success"),
            ("0a6e8d7", "docs: describe the export format", 415, "draft", False, None),
        ],
    },
    {
        "name": "team-invites",
        "branch": "feat/team-invites",
        "behind": 0,
        "entries": [
            ("1b7c4e3", "feat(auth): invite token model", 388, "merged", True, "success"),
            ("2c8d5f4", "feat(auth): send invite emails", 389, "open", False, "success", "changes"),
            ("3d9e6a5", "feat(web): invite dialog", 390, "open", False, "failed"),
            ("4eaf7b6", "feat(web): pending invites table", 391, "open", False, "pending"),
            ("5fb08c7", "test: invite flow end to end", 392, "draft", False, None),
        ],
    },
    {
        "name": "retry-backoff-jitter",
        "branch": "fix/retry-backoff-jitter",
        "behind": 0,
        "entries": [
            ("6a019d8", "fix(queue): add jitter to retry backoff", 401, "open", False, "failed"),
            ("7b12ae9", "test(queue): cover jitter bounds", 402, "open", False, "running"),
        ],
    },
    {
        "name": "usage-charts",
        "branch": "feat/usage-charts",
        "behind": 0,
        "entries": [
            ("8c23bfa", "feat(charts): daily usage series", 420, "open", False, "success"),
            ("9d34c0b", "feat(charts): stack the series by plan", 421, "open", False, "success"),
        ],
    },
    {
        "name": "job-queue",
        "branch": "refactor/job-queue",
        "behind": 6,
        "entries": [
            ("ae45d1c", "refactor(queue): extract the scheduler", 377, "open", True, "success"),
            ("bf56e2d", "refactor(queue): lease-based workers", 378, "open", False, "success"),
            ("c067f3e", "refactor(queue): drop the legacy poller", 379, "open", False, "success", "refresh_failed"),
        ],
    },
    {
        "name": "api-quickstart",
        "branch": "docs/api-quickstart",
        "behind": 0,
        "entries": [
            ("d178a4f", "docs(api): quickstart guide", 430, "draft", False, None),
        ],
    },
]

BUCKET_KEYS = [
    "refresh_failed", "ready_to_land", "changes_requested", "blocked_on_ci",
    "awaiting_review", "behind_base", "draft",
]


def gg_id(stack, position):
    return "c-%s%02d" % (stack.replace("-", "")[:6], position)


def flag(entry):
    return entry[6] if len(entry) > 6 else None


def bucket_for(stack, entry):
    """Where gg's inbox files an entry, or None for one it leaves out."""
    _, _, _, state, approved, ci = entry[:6]
    if state == "merged":
        return None
    if flag(entry) == "refresh_failed":
        return "refresh_failed"
    if state == "draft":
        return "draft"
    if flag(entry) == "changes":
        return "changes_requested"
    if ci in ("failed", "pending", "running"):
        return "blocked_on_ci"
    if stack["behind"] > 0:
        return "behind_base"
    if approved and ci == "success":
        return "ready_to_land"
    return "awaiting_review"


def inbox_entry(stack, position, entry):
    sha, title, pr, _, _, ci = entry[:6]
    failed = flag(entry) == "refresh_failed"
    return {
        "stack_name": stack["name"],
        "position": position,
        "sha": sha,
        "title": title,
        "pr_number": pr,
        "pr_url": "" if failed else PR_URL.format(pr),
        "ci_status": None if failed else ci,
        "behind_base": stack["behind"] or None,
    }


def inbox_events():
    candidates = [(s, i + 1, e) for s in STACKS for i, e in enumerate(s["entries"])]
    total = len(candidates)
    envelope = {"version": 1, "command": "inbox"}
    buckets = {key: [] for key in BUCKET_KEYS}
    yield {**envelope, "event": "start", "total_candidates": total, "total_stack_errors": 0}
    for completed, (stack, position, entry) in enumerate(candidates, start=1):
        bucket = bucket_for(stack, entry)
        row = inbox_entry(stack, position, entry)
        if flag(entry) == "refresh_failed":
            buckets[bucket].append({**row, "refresh_error": "GitHub API rate limit exceeded"})
            yield {
                **envelope, "event": "entry_error", "completed": completed, "total_candidates": total,
                "included": True, "bucket": bucket, "entry": row,
                "error": "GitHub API rate limit exceeded",
            }
            continue
        if bucket is not None:
            buckets[bucket].append(row)
        yield {
            **envelope, "event": "entry", "completed": completed, "total_candidates": total,
            "included": bucket is not None, "bucket": bucket, "remote_state": entry[3], "entry": row,
        }
    for rows in buckets.values():
        rows.sort(key=lambda r: (r["stack_name"], r["position"], r["sha"]))
    yield {
        **envelope, "event": "summary",
        "total_items": sum(len(rows) for rows in buckets.values()),
        "buckets": buckets, "stack_errors": [],
    }


def stack_json(stack):
    entries = []
    current = stack.get("current")
    previous = None
    for position, entry in enumerate(stack["entries"], start=1):
        sha, title, pr, state, approved, ci = entry[:6]
        gid = gg_id(stack["name"], position)
        item = {
            "position": position, "sha": sha, "title": title, "gg_id": gid,
            "pr_number": pr, "pr_state": state, "approved": approved,
            "is_current": position == current,
        }
        if previous:
            item["gg_parent"] = previous
        if ci:
            item["ci_status"] = ci
        entries.append(item)
        previous = gid
    return {
        "name": stack["name"], "base": BASE, "total_commits": len(entries),
        "synced_commits": len(entries), "current_position": current,
        "behind_base": stack["behind"], "entries": entries,
    }


def directory_json():
    return {"version": 1, "stacks": [
        {
            "name": s["name"], "base": BASE, "commit_count": len(s["entries"]),
            "commits": [{"position": i + 1, "sha": e[0], "title": e[1]} for i, e in enumerate(s["entries"])],
        }
        for s in STACKS
    ]}


def remote_json():
    return {"version": 1, "stacks": [
        {"name": s["name"], "commit_count": len(s["entries"]), "pr_numbers": [e[2] for e in s["entries"]]}
        for s in STACKS
    ]}


def current_branch():
    try:
        out = subprocess.run(
            ["git", "rev-parse", "--abbrev-ref", "HEAD"], capture_output=True, text=True, timeout=10,
        )
        return out.stdout.strip()
    except Exception:
        return ""


def emit(value):
    print(json.dumps(value))


def help_text(command):
    flags = {
        None: "--client-operation-id <ID>  Correlate this run with a client operation",
        "split": "--describe  Print the split plan\n  --plan-json  Apply a split plan",
        "unstack": "--keep-current  Keep the current commit on the branch",
        "sc": "--staged-only  Amend only what is staged",
        "sync": "--jsonl  Stream progress as JSON lines\n  --until <ENTRY>  Sync up to an entry\n  --draft  Open new requests as drafts",
        "land": "--jsonl  Stream progress as JSON lines\n  --wait  Wait for readiness",
        "ls": "--json  Print JSON\n  --no-refresh  Skip the forge lookup\n  --remote  List stacks on the forge\n  --all  List every stack",
    }
    return "gg %s (design demo)\n\nOptions:\n  %s\n" % (command or "", flags.get(command, "--help"))


def main(argv):
    args = argv[1:]
    if args[:1] == ["--version"] or args[:1] == ["-V"]:
        print("gg %s" % VERSION)
        return 0
    if "--help" in args or "-h" in args or not args:
        print(help_text(args[0] if args and not args[0].startswith("-") else None), end="")
        return 0
    command = args[0]
    if command == "ls" and "--json" in args:
        if "--remote" in args:
            emit(remote_json())
        elif "--all" in args:
            emit(directory_json())
        else:
            branch = current_branch()
            stack = next((s for s in STACKS if s["branch"] == branch), None)
            emit({"version": 1, "stack": stack_json(stack)} if stack else directory_json())
        return 0
    if command == "inbox":
        events = list(inbox_events())
        if "--jsonl" in args:
            for event in events:
                emit(event)
        else:
            summary = dict(events[-1])
            summary.pop("event")
            summary.pop("command")
            emit(summary)
        return 0
    sys.stderr.write("fake gg (design demo): '%s' is not available; nothing was changed\n" % command)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
