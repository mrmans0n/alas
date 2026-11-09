#!/usr/bin/env bash
# Launches Alas Dev on a demo profile and writes window.png, sidebar.png,
# transcript.png and right-pane.png to <out-dir>. Everything comes from the seeded profile; nothing
# is clicked or typed. See README.md.
#
# Usage: capture.sh <profile-dir> <out-dir> <dark|light>
#
# ALAS_DEV_APP overrides the app; by default this checkout's Debug build is used.
# ALAS_CAPTURE_RIGHT_TAB (files, agent, run, schedules) opens the right pane on
# that tab instead of Changes.
# ALAS_CAPTURE_DIALOG (new-project, new-worktree, repo-selector, review-target,
# run-script, agent-launcher, file-search) opens that dialog before the capture.
# ALAS_CAPTURE_EXPECT_SIZE (such as 1648x1063, in points) fails the capture when
# the window has another size. The size is also written to window-size.txt.
set -euo pipefail

if [[ $# -ne 3 || ( "$3" != dark && "$3" != light ) ]]; then
  echo "usage: $0 <profile-dir> <out-dir> <dark|light>" >&2
  exit 2
fi

script_dir="$(cd -P "$(dirname "$0")" && pwd)"
repo_root="$(git -C "$script_dir" rev-parse --show-toplevel)"
profile="$(cd -P "$1" && pwd)"
mkdir -p "$2"
out_dir="$(cd -P "$2" && pwd)"
support="$profile/support"

if [[ ! -d "$profile/seed" ]]; then
  echo "no seed in $profile; run make-demo-profile.sh first" >&2
  exit 1
fi

# Layout metrics from the seeded config, in points. The chat is what remains.
sidebar_width_pt=244
right_pane_width_pt=320
capture_workspace="design-capture"
launch_width_pt=1440
launch_height_pt=900
# Below this the chat column is too narrow to judge.
min_width_pt=1200
app_stop_timeout_secs=10

find_app() {
  local dir
  for dir in "$HOME"/Library/Developer/Xcode/DerivedData/Alas-*; do
    if [[ "$(/usr/libexec/PlistBuddy -c 'Print :WorkspacePath' "$dir/info.plist" 2>/dev/null)" == "$repo_root/Alas.xcodeproj" ]]; then
      echo "$dir/Build/Products/Debug/Alas.app"
      return
    fi
  done
}
app="${ALAS_DEV_APP:-$(find_app)}"
if [[ ! -d "$app" ]]; then
  echo "no Alas Dev build found; set ALAS_DEV_APP" >&2
  exit 1
fi

# AlasProfile.runtimeDirectory: hashed from the standardized path, which drops
# the /private of /private/tmp.
runtime_dir="/tmp/alas-$(id -u)-$(printf %s "${support#/private}" | shasum -a 256 | cut -c1-8)"

# Stops only what this profile started. Chat agents run under a broker that
# outlives the app, so those are found by this profile's paths.
stop_profile_processes() {
  local pid
  [[ -n "${app_pid:-}" ]] && kill "$app_pid" 2>/dev/null || true
  ps ax -o pid=,command= | grep -F -e "$runtime_dir/" -e "$profile/fake-acp-agent.py" | grep -v grep \
    | while read -r pid _; do kill "$pid" 2>/dev/null || true; done || true
  [[ -n "${app_pid:-}" ]] || return 0
  local deadline=$(( SECONDS + app_stop_timeout_secs ))
  while kill -0 "$app_pid" 2>/dev/null; do
    if (( SECONDS >= deadline )); then
      echo "warning: pid $app_pid ignored SIGTERM for ${app_stop_timeout_secs}s; sending SIGKILL" >&2
      kill -9 "$app_pid" 2>/dev/null || true
      return 0
    fi
    /bin/sleep 0.2
  done
}

# macOS saves the main window's frame in the domain every Alas Dev build shares,
# not in the profile, so put back what was there before this run.
frame_key="NSWindow Frame main"
frame_domain="io.nlopez.alas.dev"
saved_frame="$(defaults read "$frame_domain" "$frame_key" 2>/dev/null)" && had_frame=1 || had_frame=0
restore_saved_frame() {
  if (( had_frame )); then
    defaults write "$frame_domain" "$frame_key" "$saved_frame"
  else
    defaults delete "$frame_domain" "$frame_key" 2>/dev/null || true
  fi
}
# Restores twice: first so a stuck shutdown can't leave the key changed, then
# again because the app saves its frame as it quits.
finish() {
  rm -rf "${shot:-}"
  restore_saved_frame
  stop_profile_processes
  restore_saved_frame
}
trap finish EXIT
trap 'exit 130' INT TERM HUP

# Every capture starts from the seed, since a run persists the replayed
# transcript and the next replay would duplicate it.
stop_profile_processes
rm -rf "$support" "$runtime_dir"
cp -R "$profile/seed" "$support"
chmod 700 "$support"

# The seed dates runs and schedules from a fixed anchor. Move them to now, so
# ages read the same in every capture and no schedule is ever due: a due one
# would fire while the app is up and add worktrees to the fixture.
SUPPORT="$support" /usr/bin/python3 - <<'PY'
import json, os, pathlib, re, sqlite3, time
from datetime import datetime, timedelta, timezone

support = pathlib.Path(os.environ["SUPPORT"])
anchor = datetime(2026, 1, 15, 10, tzinfo=timezone.utc)
delta = time.time() - anchor.timestamp()
iso = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")

def shift(value):
    if isinstance(value, dict):
        return {k: shift(v) for k, v in value.items()}
    if isinstance(value, list):
        return [shift(v) for v in value]
    if isinstance(value, str) and iso.match(value):
        moved = datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc) + timedelta(seconds=delta)
        return moved.strftime("%Y-%m-%dT%H:%M:%SZ")
    return value

schedules = support / "run-schedules.json"
if schedules.exists():
    schedules.write_text(json.dumps(shift(json.loads(schedules.read_text())), indent=2) + "\n")
history = support / "run-history.sqlite"
if history.exists():
    db = sqlite3.connect(history)
    db.execute("UPDATE run_history SET started_at = started_at + ?, finished_at = finished_at + ?", (delta, delta))
    db.commit()
    db.close()
PY
theme=$([[ "$3" == dark ]] && echo cool-slate || echo light)
APP_JSON="$support/app.json" THEME="$theme" DENSITY="${ALAS_CAPTURE_DENSITY:-}" /usr/bin/python3 - <<'PY'
import json
import os

path = os.environ["APP_JSON"]
config = json.load(open(path))
config["themeId"] = os.environ["THEME"]
if os.environ["DENSITY"]:
    config["density"] = os.environ["DENSITY"]
json.dump(config, open(path, "w"), indent=2)
PY

# These set the frame the window opens with, ignoring what other runs saved.
open -g -n --env "ALAS_APP_SUPPORT_DIR=$support" --env "ALAS_CAPTURE_RIGHT_TAB=${ALAS_CAPTURE_RIGHT_TAB:-}" "$app" --args \
  -ApplePersistenceIgnoreState YES "-$frame_key" "100 100 $launch_width_pt $launch_height_pt 0 0 1728 1084"

# Waits for a command to succeed, polling until a deadline in seconds.
wait_for() {
  local deadline=$(( SECONDS + $1 ))
  shift
  until "$@"; do
    if (( SECONDS >= deadline )); then
      echo "timed out waiting for: $*" >&2
      return 1
    fi
    /bin/sleep 0.5
  done
}

app_socket_exists() {
  compgen -G "$runtime_dir/hooks/pid-*" >/dev/null
}
wait_for 60 app_socket_exists
app_pid="$(basename "$(compgen -G "$runtime_dir/hooks/pid-*" | head -1)")"
app_pid="${app_pid#pid-}"

# Prints "<window id> <width> <height>" for the largest normal window of a pid.
window_info() {
  swift - "$app_pid" <<'SWIFT' 2>/dev/null
import CoreGraphics
let pid = Int(CommandLine.arguments[1])!
let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
let matches = windows.compactMap { w -> (Int, Int, Int)? in
    guard w["kCGWindowOwnerPID"] as? Int == pid, w["kCGWindowLayer"] as? Int == 0,
          let id = w["kCGWindowNumber"] as? Int,
          let b = w["kCGWindowBounds"] as? [String: Any],
          let width = b["Width"] as? Int, let height = b["Height"] as? Int else { return nil }
    return (id, width, height)
}
if let m = matches.max(by: { $0.1 * $0.2 < $1.1 * $1.2 }), m.1 > 200 { print(m.0, m.1, m.2) }
SWIFT
}

has_window() {
  [[ -n "$(window_info)" ]]
}
wait_for 30 has_window
read -r window_id _ _ <<<"$(window_info)"

# AeroSpace tiles a new window on the focused workspace, so leave at once for a
# hidden one, where it can't cover or reflow the user's windows. Nothing can size
# a window there, so it keeps the size it was tiled to; see README.md.
aerospace_knows_window() {
  # Not a pipe: grep -q exits at its first match, and under pipefail the SIGPIPE
  # that sends to aerospace would read as a failure.
  grep -qx "$window_id" <<<"$(aerospace list-windows --all --format '%{window-id}' 2>/dev/null)"
}
if command -v aerospace >/dev/null; then
  if ! wait_for 10 aerospace_knows_window; then
    echo "warning: AeroSpace never listed window $window_id; leaving it where it opened" >&2
  elif ! aerospace move-node-to-workspace --window-id "$window_id" "$capture_workspace"; then
    echo "warning: AeroSpace couldn't move window $window_id; leaving it where it opened" >&2
  fi
fi

replay_finished() {
  [[ -e "$support/replay-done" ]]
}
wait_for 60 replay_finished

# The sidebar scans a worktree's diff when it is first opened, so visit each one
# and end on the selection the seed chose, which holds the transcript.
cli="$app/Contents/Resources/alas-cli/macos-aarch64/alas"
visit_worktrees() {
  cd "$profile/fixture/lantern"
  export ALAS_SOCKET_PATH="$runtime_dir/hooks/pid-$app_pid"
  local selected
  # The seed orders it first, right after the main checkout.
  selected="$("$cli" wt list | awk 'NR==2 {print $1}')"
  "$cli" wt list | awk '{print $(NF-1)}' | while read -r branch; do
    "$cli" wt switch "$branch" >/dev/null
    /bin/sleep 0.7
  done
  "$cli" wt switch "$selected" >/dev/null
}
(visit_worktrees)

# ALAS_CAPTURE_DIALOG opens a dialog through the Debug build's capture bridge
# (DesignCaptureBridge in AlasApp.swift) once the worktrees are visited.
if [[ -n "${ALAS_CAPTURE_DIALOG:-}" ]]; then
  /usr/bin/swift - "$ALAS_CAPTURE_DIALOG" <<'SWIFT' 2>/dev/null
import Foundation
DistributedNotificationCenter.default().postNotificationName(
    Notification.Name("io.nlopez.alas.dev.capture.open"),
    object: CommandLine.arguments[1], userInfo: nil, deliverImmediately: true
)
SWIFT
  /bin/sleep 1.5
fi

# Ready once two captures a second apart match. Status indicators keep pulsing,
# so captures are compared as thumbnails with a small tolerance.
shot="$(mktemp -d)"
screen_is_stable() {
  /usr/sbin/screencapture -x -o "-l$window_id" "$shot/next.png"
  sips -Z 800 -s format bmp "$shot/next.png" --out "$shot/next.bmp" >/dev/null
  local stable=1
  if [[ -e "$shot/window.bmp" ]] && /usr/bin/python3 -c '
import pathlib, sys
a, b = (pathlib.Path(p).read_bytes() for p in sys.argv[1:])
different = sum(x != y for x, y in zip(a, b))
sys.exit(0 if len(a) == len(b) and different < len(a) // 500 else 1)
' "$shot/next.bmp" "$shot/window.bmp"; then
    stable=0
  fi
  mv "$shot/next.png" "$shot/window.png"
  mv "$shot/next.bmp" "$shot/window.bmp"
  /bin/sleep 1
  return "$stable"
}
if ! wait_for 45 screen_is_stable; then
  echo "warning: window never settled; capturing its latest state" >&2
fi

read -r _ width_pt height_pt <<<"$(window_info)"
window_size="${width_pt}x${height_pt}"
check_window_size() {
  if (( width_pt < min_width_pt )); then
    echo "window is only ${width_pt}pt wide; focus a workspace with room and run again" >&2
    exit 1
  fi
  if [[ -n "${ALAS_CAPTURE_EXPECT_SIZE:-}" && "$window_size" != "$ALAS_CAPTURE_EXPECT_SIZE" ]]; then
    echo "window is ${window_size}pt but ${ALAS_CAPTURE_EXPECT_SIZE}pt was expected; focus a workspace with the same layout and run again" >&2
    exit 1
  fi
}
check_window_size

mv "$shot/window.png" "$out_dir/window.png"
echo "$window_size" > "$out_dir/window-size.txt"
swift - "$out_dir" "$width_pt" "$sidebar_width_pt" "$right_pane_width_pt" <<'SWIFT' 2>/dev/null
import CoreGraphics
import Foundation
import ImageIO

let args = CommandLine.arguments
let dir = URL(fileURLWithPath: args[1])
let source = CGImageSourceCreateWithURL(dir.appendingPathComponent("window.png") as CFURL, nil)!
let window = CGImageSourceCreateImageAtIndex(source, 0, nil)!
let scale = window.width / Int(args[2])!
let sidebar = Int(args[3])! * scale
let rightPane = Int(args[4])! * scale
func write(_ name: String, x: Int, width: Int) {
    let rect = CGRect(x: x, y: 0, width: width, height: window.height)
    let out = CGImageDestinationCreateWithURL(dir.appendingPathComponent(name) as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(out, window.cropping(to: rect)!, nil)
    CGImageDestinationFinalize(out)
}
write("sidebar.png", x: 0, width: sidebar)
write("transcript.png", x: sidebar, width: window.width - sidebar - rightPane)
write("right-pane.png", x: window.width - rightPane, width: rightPane)
SWIFT

echo "captured $3 at ${window_size}pt to $out_dir"
