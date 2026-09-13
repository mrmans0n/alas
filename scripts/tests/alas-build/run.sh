#!/usr/bin/env bash
set -euo pipefail

this_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "${this_dir}/../../.." && pwd)"
tmp="$(mktemp -d -t alas-build-script-test.XXXXXX)"
trap 'rm -rf "${tmp}"' EXIT

fake_bin="${tmp}/bin"
log="${tmp}/commands.log"
mkdir -p "${fake_bin}"

cat > "${fake_bin}/fake-command" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

command_name="$(basename "$0")"
printf '%s\t%s\t%s\n' "${command_name}" "${PWD}" "$*" >> "${ALAS_BUILD_TEST_LOG}"

if [ "${command_name}" = "xcodebuild" ] && [ -n "${ALAS_BUILD_TEST_XCODEBUILD_EXIT:-}" ]; then
    exit "${ALAS_BUILD_TEST_XCODEBUILD_EXIT}"
fi
EOF
chmod +x "${fake_bin}/fake-command"
ln -s fake-command "${fake_bin}/xcodegen"
ln -s fake-command "${fake_bin}/xcodebuild"
ln -s fake-command "${fake_bin}/open"

run_build_script() {
    PATH="${fake_bin}:${PATH}" \
        ALAS_BUILD_TEST_LOG="${log}" \
        "${repo_root}/.alas/scripts/build.sh"
}

assert_successful_build_launches_worktree_app() {
    : > "${log}"

    run_build_script

    expected="${tmp}/expected.log"
    printf 'xcodegen\t%s\t\n' "${repo_root}" > "${expected}"
    printf 'xcodebuild\t%s\t-project Alas.xcodeproj -scheme Alas -configuration Debug -destination platform=macOS -derivedDataPath %s/.build/xcode/DerivedData build\n' \
        "${repo_root}" "${repo_root}" >> "${expected}"
    printf 'open\t%s\t-n %s/.build/xcode/DerivedData/Build/Products/Debug/Alas.app\n' \
        "${repo_root}" "${repo_root}" >> "${expected}"
    diff -u "${expected}" "${log}"
}

assert_failed_build_does_not_launch() {
    : > "${log}"

    set +e
    PATH="${fake_bin}:${PATH}" \
        ALAS_BUILD_TEST_LOG="${log}" \
        ALAS_BUILD_TEST_XCODEBUILD_EXIT=42 \
        "${repo_root}/.alas/scripts/build.sh"
    status=$?
    set -e

    [ "${status}" -eq 42 ] || {
        echo "expected xcodebuild exit status 42, got ${status}" >&2
        exit 1
    }

    if cut -f1 "${log}" | grep -qx open; then
        echo "launched Alas after xcodebuild failed" >&2
        exit 1
    fi
}

assert_successful_build_launches_worktree_app
assert_failed_build_does_not_launch

echo "all tests passed"
