#!/usr/bin/env bash
# Builds a demo profile for design captures: one invented git repo with 14
# linked worktrees, plus a seed of Alas's app-support files that selects a
# worktree with a restored chat tab on the fixture agent.
#
# Usage: make-demo-profile.sh <profile-dir>
#
#   <profile-dir>/fixture/   the git repo and worktrees, built once and reused
#   <profile-dir>/seed/      app-support template; capture.sh copies it per run
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <profile-dir>" >&2
  exit 2
fi

script_dir="$(cd -P "$(dirname "$0")" && pwd)"
mkdir -p "$1"
profile="$(cd -P "$1" && pwd)"
fixture="$profile/fixture"
repo="$fixture/lantern"
# Bump when build_fixture changes, so an older fixture is rebuilt.
fixture_version=9

# Fixed so commit metadata never varies between profiles.
export GIT_AUTHOR_NAME="Demo Author" GIT_AUTHOR_EMAIL="demo@example.invalid"
export GIT_COMMITTER_NAME="Demo Author" GIT_COMMITTER_EMAIL="demo@example.invalid"
export GIT_AUTHOR_DATE="2026-01-15T10:00:00Z" GIT_COMMITTER_DATE="2026-01-15T10:00:00Z"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

# branch|added lines|deleted lines. Mixed sizes, including none, so the sidebar
# shows clean rows, small diffs and large ones.
worktrees=(
  "nacho/refactor-transcript-scroller-row-height-cache|212|87"
  "feat/invoice-export|48|6"
  "feat/team-invites|1340|402"
  "feat/usage-charts|96|12"
  "feat/webhook-signing|0|0"
  "feat/dark-mode-emails|7|2"
  "fix/retry-backoff-jitter|3|1"
  "fix/timezone-rollover|0|0"
  "fix/null-avatar-crash|1|1"
  "fix/csv-escaping|25|25"
  "refactor/job-queue|640|733"
  "chore/bump-sqlite|2|2"
  "docs/api-quickstart|120|0"
  "spike/vector-search|0|0"
)
selected_branch="${worktrees[0]%%|*}"

build_fixture() {
  local tmp="$fixture.tmp"
  rm -rf "$tmp"
  mkdir -p "$tmp/lantern/src"
  git -C "$tmp/lantern" init -q -b main
  # The numbered lines give each worktree's diff something to delete.
  seq -f "line %g" 1 1000 > "$tmp/lantern/src/ledger.txt"
  printf '# Lantern\n\nInvoices and usage billing for small teams.\n' > "$tmp/lantern/README.md"
  # Enough of a tree for the Files tab to have folders to show.
  mkdir -p "$tmp/lantern/src/billing" "$tmp/lantern/src/web" "$tmp/lantern/docs" "$tmp/lantern/tests"
  local file
  for file in src/billing/Invoice.swift src/billing/UsageMeter.swift src/billing/TaxRules.swift \
    src/web/routes.ts src/web/server.ts docs/architecture.md docs/runbook.md \
    tests/InvoiceTests.swift tests/UsageMeterTests.swift Package.swift .gitignore; do
    printf '// %s\n' "$file" > "$tmp/lantern/$file"
  done
  # Real code for the editor captures.
  cat > "$tmp/lantern/src/billing/Invoice.swift" <<'SWIFT'
import Foundation

/// One customer's charges for a billing period.
struct Invoice: Identifiable, Hashable {
    let id: UUID
    var customer: String
    var lines: [Line]
    var issuedAt: Date

    struct Line: Hashable {
        var description: String
        var quantity: Int
        var unitPrice: Decimal
    }

    /// Sum of every line, before tax.
    var subtotal: Decimal {
        lines.reduce(0) { $0 + Decimal($1.quantity) * $1.unitPrice }
    }

    func total(applying rules: TaxRules) -> Decimal {
        subtotal + rules.tax(on: subtotal, for: customer)
    }
}
SWIFT
  # Committed versions of the files the selected worktree edits for the review captures.
  mkdir -p "$tmp/lantern/src/generated"
  cat > "$tmp/lantern/src/billing/TaxRules.swift" <<'SWIFT'
import Foundation

/// Tax rates by customer.
struct TaxRules {
    var rates: [String: Decimal]
    var defaultRate: Decimal = 0

    func tax(on subtotal: Decimal, for customer: String) -> Decimal {
        let rate = rates[customer] ?? defaultRate
        return subtotal * rate
    }
}
SWIFT
  cat > "$tmp/lantern/src/web/routes.ts" <<'TS'
import { Router } from "express";
import { getInvoice, listInvoices } from "./invoices";

export const routes = Router();

routes.get("/invoices", async (req, res) => {
  const invoices = await listInvoices();
  res.json(invoices);
});

routes.get("/invoices/:id", async (req, res) => {
  const invoice = await getInvoice(req.params.id);
  res.json(invoice);
});
TS
  printf 'region,rate\nDE,0.19\nFR,0.20\nES,0.21\nUS-CA,0.0725\nUS-NY,0.04\n' > "$tmp/lantern/src/generated/rates.csv"
  # A document for the Markdown preview, with a Mermaid diagram.
  cat > "$tmp/lantern/docs/architecture.md" <<'MARKDOWN'
# Lantern architecture

Lantern bills small teams for invoices and metered usage. Every request goes through one
API, and the ledger is the only place money is written.

## Services

- **Billing API** validates requests and prices usage.
- **Ledger** stores invoices and payments, append-only.
- **Exporter** streams invoices out as CSV for accountants.

## Request flow

```mermaid
flowchart LR
    Client[Client] --> API[Billing API]
    API --> Tax{Tax rules}
    Tax -->|EU| VAT[VAT service]
    Tax -->|US| Sales[Sales tax]
    API --> Ledger[(Ledger)]
    Ledger --> Export[CSV export]
```

## Pricing

```swift
let invoice = Invoice(customer: "Acme", lines: usage.lines)
let total = invoice.total(applying: rules)
```

See `src/billing/Invoice.swift` for the full model.
MARKDOWN
  # An image for the preview tab.
  /usr/bin/python3 - "$tmp/lantern/docs/usage-chart.png" <<'PY'
import struct, sys, zlib
w, h = 480, 270
rows = []
for y in range(h):
    row = bytearray([0])
    for x in range(w):
        bar = (x // 60) % 2 == 0 and y > h - (40 + (x // 60) * 25)
        row += bytes((95, 183, 196) if bar else (30, 36, 42))
    rows.append(bytes(row))
def chunk(t, d): return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(b"".join(rows))) + chunk(b"IEND", b"")
open(sys.argv[1], "wb").write(png)
PY
  # Run tab scripts, read from each worktree's .alas/scripts.
  mkdir -p "$tmp/lantern/.alas/scripts"
  printf '#!/bin/sh\n# alas-name: Dev server\n# alas-url: http://localhost:4173\nexec sleep 3600\n' \
    > "$tmp/lantern/.alas/scripts/dev.sh"
  printf '#!/bin/sh\n# alas-name: Tests\necho ok\n' > "$tmp/lantern/.alas/scripts/test.sh"
  printf '#!/bin/sh\n# alas-name: Lint\n# alas-console: hidden\necho ok\n' > "$tmp/lantern/.alas/scripts/lint.sh"
  chmod +x "$tmp/lantern/.alas/scripts/"*.sh
  git -C "$tmp/lantern" add -A
  git -C "$tmp/lantern" commit -q -m "feat: first ledger"
  # gg's own config: its presence turns the gg screens on, and the branch
  # username is what ties the nacho/ worktree to a stack.
  mkdir -p "$tmp/lantern/.git/gg"
  printf '{"defaults":{"branch_username":"nacho","base":"main"}}\n' > "$tmp/lantern/.git/gg/config.json"
  echo "$fixture_version" > "$tmp/version"
  mv "$tmp" "$fixture"

  local entry branch added deleted path
  for entry in "${worktrees[@]}"; do
    IFS='|' read -r branch added deleted <<<"$entry"
    path="$fixture/worktrees/${branch//\//-}"
    git -C "$repo" worktree add -q -b "$branch" "$path"
    if (( deleted > 0 )); then
      sed -i '' "1,${deleted}d" "$path/src/ledger.txt"
    fi
    if (( added > 0 )); then
      seq -f "new line %g" 1 "$added" >> "$path/src/ledger.txt"
    fi
  done

  # One stash on the selected worktree, so the Changes tab has a stash row.
  path="$fixture/worktrees/${selected_branch//\//-}"
  printf '# Runbook\n\nRotate the billing keys before the March close.\n' > "$path/docs/runbook.md"
  git -C "$path" stash push -q -m "runbook notes for the March close" -- docs/runbook.md

  # Edits for the Review Changes captures: small hunks in three source files, a
  # generated file large enough to be deferred ("Show full diff"), and an image
  # that fails to decode (the failed row with Retry).
  /usr/bin/python3 - "$path" <<'PY'
import pathlib, sys
root = pathlib.Path(sys.argv[1])
def edit(name, old, new):
    f = root / name
    text = f.read_text()
    assert old in text, name
    f.write_text(text.replace(old, new, 1))
edit("src/billing/Invoice.swift", "    var issuedAt: Date\n", "    var issuedAt: Date\n    var dueDate: Date\n")
edit("src/billing/Invoice.swift", "        subtotal + rules.tax(on: subtotal, for: customer)\n",
     "        let tax = rules.tax(on: subtotal, for: customer)\n        return max(0, subtotal + tax - discount)\n")
edit("src/billing/Invoice.swift", "    /// Sum of every line, before tax.\n", "    /// Credit applied before the invoice is issued.\n    var discount: Decimal = 0\n\n    /// Sum of every line, before tax.\n")
edit("src/billing/TaxRules.swift", "    var defaultRate: Decimal = 0\n", "    var defaultRate: Decimal = 0\n    var exemptCustomers: Set<String> = []\n")
edit("src/billing/TaxRules.swift", "        let rate = rates[customer] ?? defaultRate\n        return subtotal * rate\n",
     "        if exemptCustomers.contains(customer) { return 0 }\n        let rate = rates[customer] ?? defaultRate\n        var result = subtotal * rate\n        var rounded = Decimal()\n        NSDecimalRound(&rounded, &result, 2, .bankers)\n        return rounded\n")
edit("src/web/routes.ts", "  const invoices = await listInvoices();\n  res.json(invoices);\n",
     "  const limit = Math.min(Number(req.query.limit ?? 50), 200);\n  const invoices = await listInvoices({ limit });\n  res.json(invoices);\n")
edit("src/web/routes.ts", "  res.json(invoice);\n});\n", "  if (!invoice) {\n    res.status(404).json({ error: \"invoice not found\" });\n    return;\n  }\n  res.json(invoice);\n});\n")
with open(root / "src/generated/rates.csv", "a") as out:
    for i in range(22000):
        out.write(f"PC-{i:05d},{(i % 2500) / 10000:.4f}\n")
(root / "docs/usage-chart.png").write_bytes(b"\x89PNG\r\n\x1a\n\x00\x00not a real image\x00")
PY
}

if [[ "$(cat "$fixture/version" 2>/dev/null)" != "$fixture_version" ]]; then
  rm -rf "$fixture"
  build_fixture
fi

rm -rf "$profile/seed"
mkdir -p "$profile/seed"
cp "$script_dir/fake-acp-agent.py" "$profile/fake-acp-agent.py"

# Demo plugins, in the profile's own Plugins folder (never the user's). They stay inert until the
# Debug build's capture bridge starts them for a plugin-* target or the plugins settings section.
# Each folder is named after the plugin id, as the catalog and Settings expect.
plugins_seed="$profile/seed/Plugins"
mkdir -p "$plugins_seed"
install_demo_plugin() {
  local source="$1" id
  id="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$source/plugin.json")"
  mkdir -p "$plugins_seed/$id"
  cp "$source"/plugin.json "$plugins_seed/$id/"
  for file in plugin.js ui.js; do
    [[ -f "$source/$file" ]] && cp "$source/$file" "$plugins_seed/$id/"
  done
  return 0
}
for dir in "$script_dir"/demo-plugins/* "$script_dir/../../plugins/samples/hello-workspace"; do
  install_demo_plugin "$dir"
done

# The scripted gg, found first on the PATH capture.sh gives Alas. Alas reads that
# PATH from $SHELL, so $SHELL is a wrapper that runs the script with this PATH
# and skips the user's startup files, where a real gg could be found first.
mkdir -p "$profile/bin"
cp "$script_dir/fake-gg.py" "$profile/bin/gg"
cat > "$profile/bin/shell" <<SH
#!/bin/sh
# Stands in for \$SHELL: runs the last argument (the script) with a fixed PATH.
for script; do :; done
PATH="$profile/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export PATH
exec /bin/sh -c "\$script"
SH
chmod +x "$profile/bin/gg" "$profile/bin/shell"

selected_path="$fixture/worktrees/${selected_branch//\//-}"
WORKTREES="$(printf '%s\n' "${worktrees[@]}")" \
PROFILE="$profile" REPO="$repo" SELECTED_WORKTREE="$selected_path" SELECTED_BRANCH="$selected_branch" /usr/bin/python3 - <<'PY'
import json
import os
import pathlib
import sqlite3

profile = pathlib.Path(os.environ["PROFILE"])
seed = profile / "seed"
repo = os.environ["REPO"]


def worktree_id(path):
    """Worktree.makeId: Foundation's standardized path drops /private from /private/tmp."""
    return path.removeprefix("/private")


selected = worktree_id(os.environ["SELECTED_WORKTREE"])

PROJECT_ID = "00000000-0000-4000-8000-000000000001"
SPACE_ID = "00000000-0000-4000-8000-000000000002"
SESSION_ID = "00000000-0000-4000-8000-000000000003"
TIMESTAMP = "2026-01-15T10:00:00Z"
TIMESTAMP_SECONDS = 1768471200
SESSION_TITLE = "Invoice scrolling"


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2) + "\n")


# Only what differs from AppConfig.defaults; the decoder fills in the rest.
# capture.sh sets themeId per run. Anything that would surface a sheet, reach
# the network, or run a local model stays off.
write_json(seed / "app.json", {
    "themeId": "cool-slate",
    "matchSystemTheme": False,
    # Opaque theme colours, so the panes don't depend on what's behind the window.
    "sidebarMaterial": "none",
    "general": {
        "launchAtLogin": False,
        "closeToTray": False,
        "confirmQuit": False,
        "autoUpdate": False,
        "crashReports": False,
        "usageAnalytics": False,
    },
    "worktrees": {
        "autoFetch": False,
        "pruneStale": False,
        "defaultOrdering": "manual",
    },
    # The scripted agent never connects to the built-in MCP server, which would
    # turn the toolbar's MCP chip into a timed warning.
    "harness": {"notifyOnFinish": False, "notifyOnAwaiting": False, "exposeAlasMCP": False},
    "agents": {
        "builtinState": {},
        "custom": [],
        "registry": [{
            "registryID": "demo-agent",
            "displayName": "Demo Agent",
            "version": "1.0.0",
            "command": "/usr/bin/python3",
            "arguments": [
                str(profile / "fake-acp-agent.py"),
                "--done-marker", str(profile / "support" / "replay-done"),
            ],
            "environment": {},
            "isEnabled": True,
        }],
        "worktreeAutoLaunch": {"agentId": "registry-demo-agent", "useBypassPermissions": False},
        "defaultLauncherMode": "acp",
        "chatFontFamily": "",
        "chatFontSize": 13,
    },
    "pluginsEnabled": False,
})

branches = [line.split("|")[0] for line in os.environ["WORKTREES"].splitlines()]
order = [worktree_id(str(profile / "fixture" / "worktrees" / b.replace("/", "-"))) for b in branches]

write_json(seed / "projects.json", {
    "version": 1,
    "projects": [{
        "id": PROJECT_ID,
        "name": "lantern",
        "path": repo,
        "color": "teal",
        "addedAt": TIMESTAMP,
        "worktreeOrder": order,
        "worktreeOrderIsManual": True,
    }],
})

write_json(seed / "spaces.json", {
    "version": 1,
    "activeSpaceId": SPACE_ID,
    "spaces": [{
        "id": SPACE_ID,
        "name": "Main",
        "emoji": "🏠",
        "projectIds": [PROJECT_ID],
        "lastSelectedWorktreeId": selected,
        "createdAt": TIMESTAMP,
    }],
})

tab_id = f"acp:{SESSION_ID}"
write_json(seed / "tabs" / f"{selected.lstrip('/')}.json", {
    "version": 1,
    "activeTabId": tab_id,
    "tabs": [{"acpSession": {"_0": {"id": tab_id, "sessionId": SESSION_ID, "title": SESSION_TITLE}}}],
})

# A v5 session database: the app migrates it forward when it opens the file, so
# this needs only the columns restoring depends on. With a remote session id and
# an empty transcript, attaching calls session/load and shows the agent's replay.
database = seed / "acp-sessions" / f"{selected.lstrip('/')}.sqlite"
database.parent.mkdir(parents=True, exist_ok=True)
db = sqlite3.connect(database)
db.executescript("""
    CREATE TABLE schema_version (version INTEGER NOT NULL);
    INSERT INTO schema_version VALUES (5);
    CREATE TABLE sessions (
      id TEXT PRIMARY KEY,
      agent_id TEXT NOT NULL,
      title TEXT NOT NULL,
      current_model TEXT,
      current_mode TEXT,
      auto_run INTEGER NOT NULL DEFAULT 0,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL,
      last_opened_at INTEGER NOT NULL,
      archived INTEGER NOT NULL DEFAULT 0,
      title_source TEXT NOT NULL DEFAULT 'manual',
      remote_session_id TEXT
    );
    CREATE INDEX sessions_recent_idx ON sessions(archived, last_opened_at DESC);
    CREATE TABLE messages (
      id TEXT PRIMARY KEY,
      session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
      kind TEXT NOT NULL,
      seq INTEGER NOT NULL,
      payload BLOB NOT NULL,
      created_at INTEGER NOT NULL
    );
    CREATE INDEX messages_session_seq_idx ON messages(session_id, seq);
    CREATE TABLE permission_decisions (
      session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
      scope_key TEXT NOT NULL,
      decision TEXT NOT NULL,
      scope TEXT NOT NULL,
      decided_at INTEGER NOT NULL,
      PRIMARY KEY (session_id, scope_key)
    );
    CREATE TABLE composer_drafts (
      session_id TEXT PRIMARY KEY REFERENCES sessions(id) ON DELETE CASCADE,
      payload BLOB NOT NULL,
      updated_at INTEGER NOT NULL
    );
    CREATE TABLE session_queue (
      session_id TEXT PRIMARY KEY REFERENCES sessions(id) ON DELETE CASCADE,
      payload BLOB NOT NULL,
      updated_at INTEGER NOT NULL
    );
""")
db.execute(
    "INSERT INTO sessions (id, agent_id, title, created_at, updated_at, last_opened_at, remote_session_id)"
    " VALUES (?, ?, ?, ?, ?, ?, ?)",
    (SESSION_ID, "registry-demo-agent", SESSION_TITLE, TIMESTAMP_SECONDS, TIMESTAMP_SECONDS, TIMESTAMP_SECONDS, "demo-session"),
)
db.commit()
db.close()

# Finished runs for the Run tab's history; active runs live only in memory.
runs = [
    # id, script key, name, outcome, exit code, start, seconds, endpoint
    ("run-4", "repo:test.sh", "Tests", "failed", 1, TIMESTAMP_SECONDS - 600, 48, None),
    ("run-3", "repo:dev.sh", "Dev server", "stopped", None, TIMESTAMP_SECONDS - 4200, 1800, "http://localhost:4173"),
    ("run-2", "repo:lint.sh", "Lint", "succeeded", None, TIMESTAMP_SECONDS - 7400, 6, None),
    ("run-1", "repo:test.sh", "Tests", "succeeded", None, TIMESTAMP_SECONDS - 86400, 52, None),
]
history = sqlite3.connect(seed / "run-history.sqlite")
history.executescript("""
    CREATE TABLE run_history (
      run_id TEXT PRIMARY KEY, script_key TEXT NOT NULL, script_name TEXT NOT NULL,
      worktree_id TEXT NOT NULL, branch TEXT NOT NULL,
      target_host TEXT, target_working_directory TEXT NOT NULL, endpoint TEXT,
      outcome TEXT NOT NULL, exit_code INTEGER,
      started_at REAL NOT NULL, finished_at REAL NOT NULL,
      conflict_kind TEXT, conflict_worktree_id TEXT, conflict_branch TEXT, conflict_script_name TEXT,
      output_kind TEXT NOT NULL, output_text TEXT, output_truncated INTEGER NOT NULL DEFAULT 0
    );
    CREATE INDEX run_history_worktree_finished_idx ON run_history(worktree_id, finished_at DESC, run_id DESC);
""")
for run_id, key, name, outcome, code, start, seconds, endpoint in runs:
    history.execute(
        "INSERT INTO run_history VALUES (?, ?, ?, ?, ?, NULL, ?, ?, ?, ?, ?, ?, NULL, NULL, NULL, NULL, 'available', ?, 0)",
        (run_id, key, name, selected, os.environ["SELECTED_BRANCH"], selected, endpoint, outcome, code,
         float(start), float(start + seconds), f"{name} finished\n"),
    )
history.commit()
history.close()

# One schedule of each kind: a script on a timer and an agent in a fresh worktree.
# Dates are relative to TIMESTAMP, which capture.sh moves to the moment of capture;
# every nextFireAt stays in the future so nothing fires during a capture.
target = {"worktree": {"projectId": PROJECT_ID, "worktreeId": selected}}
write_json(seed / "run-schedules.json", {
    "version": 1,
    "schedules": [
        {
            "id": "schedule-tests", "name": "Hourly tests",
            "target": target, "scriptKey": "repo:test.sh",
            "trigger": {"interval": {"seconds": 3600}}, "missedRunPolicy": "skip",
            "isEnabled": True, "createdAt": TIMESTAMP,
        },
        {
            "id": "schedule-triage", "name": "Morning triage",
            "target": target,
            "trigger": {"timeOfDay": {"hour": 9, "minute": 0, "weekdays": [2, 3, 4, 5, 6]}},
            "missedRunPolicy": "runLatest",
            "composition": {"agentId": "registry-demo-agent", "prompt": "Triage yesterday's failed invoices"},
            "isEnabled": True, "createdAt": TIMESTAMP,
        },
        {
            "id": "schedule-lint", "name": "Nightly lint",
            "target": target, "scriptKey": "repo:lint.sh",
            "trigger": {"timeOfDay": {"hour": 2, "minute": 30, "weekdays": []}}, "missedRunPolicy": "skip",
            "isEnabled": False, "createdAt": TIMESTAMP,
        },
    ],
    "states": {
        "schedule-tests": {
            "lastFiredAt": "2026-01-15T09:50:00Z", "nextFireAt": "2026-01-15T10:50:00Z",
            "lastOutcome": {"failed": {"exitCode": 1}}, "lastOutcomeAt": "2026-01-15T09:50:48Z",
            "timeZoneIdentifier": "UTC",
            "firings": [{
                "id": "firing-1", "firedAt": "2026-01-15T09:50:00Z", "finishedAt": "2026-01-15T09:50:48Z",
                "wasManual": False, "outcome": {"failed": {"exitCode": 1}},
                "runs": [{"worktreeID": selected, "branch": os.environ["SELECTED_BRANCH"],
                          "runID": "run-4", "scriptName": "Tests"}],
            }],
        },
        "schedule-triage": {
            "lastFiredAt": "2026-01-15T09:00:00Z", "nextFireAt": "2026-01-16T09:00:00Z",
            "lastOutcome": {"succeeded": {}}, "lastOutcomeAt": "2026-01-15T09:04:00Z",
            "timeZoneIdentifier": "UTC",
        },
    },
    "pausedProjectIDs": [],
    "isPausedGlobally": False,
    "lastEvaluatedAt": TIMESTAMP,
})
PY

echo "demo profile ready: $profile"
