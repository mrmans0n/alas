#!/usr/bin/env bash
# PROTOTYPE, throwaway. Not wired into the app or CI.
#
# Question: if Alas slims an iOS simulator with simslim
# (https://github.com/MobAI-App/simslim), how much memory does it save on this
# Mac, and which of the simulator features Alas drives through `simctl` stop
# working?
#
# It creates one scratch simulator, runs the same checks against it in four
# states, prints a table, and deletes the simulator. No existing simulator is
# touched.
#
#   stock  as created
#   slim   `simslim on`, the default profile
#   keep   `simslim on --except store,web`, which keeps apsd (push) and swcd (universal links)
#   live   stock, then `simslim on --no-reboot` while booted
#
# Not covered: AlasSimService's stream and input (they need the app; the
# screenshot row is the nearest stand-in), and a real universal link, which
# needs a server with an apple-app-site-association file. iOS asks "Open in
# <app>?" before it hands an app-scheme URL from `simctl openurl` to the app,
# and nothing here can tap, so that row checks the prompt came up.
#
# Usage: scripts/prototype-simslim/run.sh
#   SIMSLIM=/path/to/simslim   use this binary instead of PATH or a download
#   SETTLE=60                  seconds to wait after boot before measuring
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "${here}/../.." && pwd)"
work="${root}/.build/simslim-prototype"
settle="${SETTLE:-60}"
bundle="io.nlopez.alas.simslim-probe"
simslim_version="v0.14.0"
configs="stock slim keep live"
mkdir -p "${work}"
results="${work}/results.tsv"
: > "${results}"

simslim="${SIMSLIM:-$(command -v simslim || true)}"
if [ -z "${simslim}" ]; then
    simslim="${work}/simslim"
    if [ ! -x "${simslim}" ]; then
        curl -fsSL "https://github.com/MobAI-App/simslim/releases/download/${simslim_version}/simslim-${simslim_version}-macos-arm64.tar.gz" \
            | tar xz -C "${work}" simslim
    fi
fi

sim() { xcrun simctl "$@"; }

config=""
put() {
    printf '%s\t%s\t%s\n' "${config}" "$1" "$2" >> "${results}"
    printf '[%s] %s: %s\n' "${config}" "$1" "$2"
}
check() {
    local name="$1"
    shift
    if "$@" > /dev/null 2>&1; then put "${name}" ok; else put "${name}" FAIL; fi
}

# The probe app: built without Xcode, ad-hoc signed.
app="${work}/SimslimProbe.app"
rm -rf "${app}"
mkdir -p "${app}"
xcrun -sdk iphonesimulator swiftc -target arm64-apple-ios17.0-simulator -swift-version 5 -parse-as-library -O \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __entitlements -Xlinker "${here}/Probe.entitlements" \
    "${here}/ProbeApp.swift" -o "${app}/AlasSimslimProbe"
cp "${here}/Info.plist" "${app}/"
codesign -s - --force "${app}" 2> /dev/null

"${root}/scripts/build-sim-ax-settings.sh"
ax_helper="${root}/.build/sim-ax-settings/alas-sim-ax-settings"

runtime="$(sim list runtimes --json | jq -r '[.runtimes[] | select(.isAvailable and .platform == "iOS")]
    | sort_by(.version | split(".") | map(tonumber)) | last | .identifier')"
udid="$(sim create "Alas simslim prototype" com.apple.CoreSimulator.SimDeviceType.iPhone-17 "${runtime}")"
cleanup() {
    sim shutdown "${udid}" > /dev/null 2>&1 || true
    sim delete "${udid}" > /dev/null 2>&1 || true
}
trap cleanup EXIT
echo "scratch simulator ${udid} on ${runtime}, simslim $("${simslim}" --version 2>&1 | head -1)"

boot() {
    sim boot "${udid}"
    sim bootstatus "${udid}" -b > /dev/null
}
timed() {
    local name="$1" start="${SECONDS}"
    shift
    "$@"
    put "${name}" "$((SECONDS - start))s"
}

# A simulator's first boot migrates its data, so it isn't a fair boot time.
boot
sim shutdown "${udid}"

events=""
wait_event() {
    local deadline=$((SECONDS + ${2:-15}))
    while [ "${SECONDS}" -lt "${deadline}" ]; do
        if grep -qF -- "$1" "${events}" 2> /dev/null; then return 0; fi
        sleep 0.5
    done
    return 1
}
wait_running() {
    local deadline=$((SECONDS + 15))
    while [ "${SECONDS}" -lt "${deadline}" ]; do
        if sim spawn "${udid}" launchctl list | grep -qF "UIKitApplication:$1["; then return 0; fi
        sleep 0.5
    done
    return 1
}
log_lines() {
    sim spawn "${udid}" log show --last "${3:-3m}" --style ndjson --predicate "$1" 2> /dev/null | grep -cF "$2" || true
}

check_launch() {
    sim privacy "${udid}" grant location "${bundle}" \
        && sim launch --terminate-running-process "${udid}" "${bundle}" \
        && events="$(sim get_app_container "${udid}" "${bundle}" data)/Documents/events.log" \
        && wait_event "launched"
}
check_location() {
    sim location "${udid}" set 41.385,2.173 && wait_event "location 41.385,2.173"
}
check_push() {
    wait_event "auth granted=true" \
        && printf '{"aps":{"alert":{"title":"probe","body":"probe-%s"}}}' "${config}" | sim push "${udid}" "${bundle}" - \
        && wait_event "push probe-${config}"
}
check_url_scheme() {
    sim openurl "${udid}" "alasprobe://${config}" || return 1
    local deadline=$((SECONDS + 10))
    while [ "${SECONDS}" -lt "${deadline}" ]; do
        sleep 1
        if [ "$(log_lines 'process == "SpringBoard" AND eventMessage CONTAINS "Received request to activate alertItem" AND eventMessage CONTAINS "Open in"' \
            SimslimProbe 20s)" -gt 0 ]; then return 0; fi
    done
    return 1
}
check_ui() {
    sim ui "${udid}" appearance dark && [ "$(sim ui "${udid}" appearance)" = dark ] \
        && sim ui "${udid}" content_size extra-large && [ "$(sim ui "${udid}" content_size)" = extra-large ] \
        && sim ui "${udid}" increase_contrast enabled && [ "$(sim ui "${udid}" increase_contrast)" = enabled ] \
        && sim ui "${udid}" appearance light && sim ui "${udid}" content_size large \
        && sim ui "${udid}" increase_contrast disabled
}
check_pasteboard() {
    printf 'probe-ñ' | LC_ALL=en_US.UTF-8 sim pbcopy "${udid}" && [ "$(sim pbpaste "${udid}")" = "probe-ñ" ]
}
check_accessibility() {
    sim spawn "${udid}" "${ax_helper}" set reduce-motion on \
        && [ "$(sim spawn "${udid}" "${ax_helper}" get reduce-motion)" = on ] \
        && sim spawn "${udid}" "${ax_helper}" set reduce-motion off
}
check_https() {
    sim openurl "${udid}" https://example.com && wait_running com.apple.mobilesafari
}
check_screenshot() {
    sim io "${udid}" screenshot "${work}/after.png" && ! cmp -s "${work}/before.png" "${work}/after.png"
}
doctor() {
    "${simslim}" doctor "${udid}" --requires "$1" --json | jq -e '.ok'
}

for config in ${configs}; do
    profile=""
    case "${config}" in
        stock) ;;
        slim) timed "apply" "${simslim}" on "${udid}" --preserve-boot-state ;;
        # Applied over `slim` without `off` in between: the verify row says
        # whether `on` also turns services back on.
        keep)
            profile="--except store,web"
            timed "apply" "${simslim}" on "${udid}" --preserve-boot-state ${profile}
            ;;
        live) "${simslim}" off "${udid}" --preserve-boot-state > /dev/null ;;
    esac

    timed "boot" boot
    if [ "${config}" = live ]; then
        sleep "${settle}"
        timed "apply" "${simslim}" on "${udid}" --no-reboot
    fi
    put "simslim status" "$("${simslim}" status "${udid}" --json | jq -r '"\(.verdict) \(.managedDisabled)/\(.managedTotal)"')"
    if [ "${config}" != stock ]; then
        check "simslim verify" "${simslim}" verify "${udid}" ${profile}
    fi

    sleep "${settle}"
    memory="$("${simslim}" measure "${udid}" --json)"
    put "processes" "$(jq -r '.processes' <<< "${memory}")"
    put "memory" "$(jq -r '.bytes / 1073741824 * 100 | round / 100 | "\(.) GB"' <<< "${memory}")"

    sim uninstall "${udid}" "${bundle}" > /dev/null 2>&1 || true
    check "install" sim install "${udid}" "${app}"
    check "launch" check_launch
    check "list apps" bash -c "xcrun simctl listapps '${udid}' | grep -qF '${bundle}'"
    check "privacy + location" check_location
    check "simctl push" check_push
    check "remote push token" wait_event "token ok" 10
    check "open URL (app scheme) prompts" check_url_scheme
    put "app log lines" "$(log_lines "subsystem == \"${bundle}\"" "${bundle}")"
    put "foreground log lines" "$(log_lines 'process == "SpringBoard" AND (eventMessage CONTAINS "Setting process visibility to:" OR eventMessage CONTAINS "Bootstrap success!")' "${bundle}")"
    check "appearance, text size, contrast" check_ui
    check "pasteboard" check_pasteboard
    check "accessibility helper" check_accessibility
    sim io "${udid}" screenshot "${work}/before.png" > /dev/null 2>&1 || true
    check "open URL (https, Safari)" check_https
    sleep 2
    check "screenshot changes" check_screenshot
    check "doctor: push" doctor push
    check "doctor: universal-links" doctor universal-links
    sim shutdown "${udid}"
done

echo
awk -F'\t' -v configs="${configs}" '
    { if (!($2 in seen)) { seen[$2] = 1; order[++n] = $2 } value[$2, $1] = $3 }
    END {
        count = split(configs, names, " ")
        line = "check"
        for (c = 1; c <= count; c++) line = line "\t" names[c]
        print line
        for (i = 1; i <= n; i++) {
            line = order[i]
            for (c = 1; c <= count; c++) {
                cell = value[order[i], names[c]]
                line = line "\t" (cell == "" ? "-" : cell)
            }
            print line
        }
    }' "${results}" | column -t -s "$(printf '\t')"
