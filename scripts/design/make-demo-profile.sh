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
  git -C "$tmp/lantern" add -A
  git -C "$tmp/lantern" commit -q -m "feat: first ledger"
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
}

if [[ ! -d "$repo/.git" ]]; then
  build_fixture
fi

rm -rf "$profile/seed"
mkdir -p "$profile/seed"
cp "$script_dir/fake-acp-agent.py" "$profile/fake-acp-agent.py"

selected_path="$fixture/worktrees/${selected_branch//\//-}"
WORKTREES="$(printf '%s\n' "${worktrees[@]}")" \
PROFILE="$profile" REPO="$repo" SELECTED_WORKTREE="$selected_path" /usr/bin/python3 - <<'PY'
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
PY

echo "demo profile ready: $profile"
