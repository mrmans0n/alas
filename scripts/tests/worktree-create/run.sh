#!/usr/bin/env bash
set -euo pipefail

this_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${this_dir}/../../.." && pwd)"
sandbox="$(mktemp -d)"
trap 'rm -rf "${sandbox}"' EXIT

export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
# The fixture's upstream is another local repository instead of GitHub.
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=protocol.file.allow GIT_CONFIG_VALUE_0=always

# Reuse one tiny repository for all three submodules; no network or builds.
module_repo="${sandbox}/module"
main_repo="${sandbox}/main"
checkout="${sandbox}/checkout"
git init -q "${module_repo}"
printf 'submodule payload\n' > "${module_repo}/payload"
git -C "${module_repo}" add payload
git -C "${module_repo}" commit -qm initial
base_commit="$(git -C "${module_repo}" rev-parse HEAD)"
git init -q "${main_repo}"
for module in fff ghostty zmx; do
  git -C "${main_repo}" -c protocol.file.allow=always submodule add -q \
    "${module_repo}" "ThirdParty/${module}"
done
git -C "${main_repo}" commit -qm initial
git -C "${main_repo}" worktree add -q --detach "${checkout}"
mkdir -p "${main_repo}/.build/fff/arm64"
printf 'finished artifact\n' > "${main_repo}/.build/fff/arm64/fingerprint"

# Alas passes the hook's contents to zsh -c and may append further setup.
hook_script="$(cat "${repo_root}/.alas/hooks/worktree-create.sh")"$'\n'
hook_script+='[[ "$PATH" == "$WORKTREE_TEST_PATH" ]] || {
  print -u2 -- "worktree-create hook changed PATH to $PATH"
  exit 1
}
git status --porcelain >/dev/null'
run_hook() {
  if ! (cd "${checkout}" && WORKTREE_TEST_PATH="${PATH}" /bin/zsh -f -c "${hook_script}") \
    > "${sandbox}/hook.log" 2>&1; then
    cat "${sandbox}/hook.log" >&2
    exit 1
  fi
}

assert_upstream_urls() {
  for module in fff ghostty zmx; do
    test "$(git -C "${checkout}" config "submodule.ThirdParty/${module}.url")" = "${module_repo}"
    test "$(git -C "${checkout}/ThirdParty/${module}" remote get-url origin)" = "${module_repo}"
  done
}

assert_no_warnings() {
  if grep -Eq 'command not found|worktree-init: warning:' "${sandbox}/hook.log"; then
    cat "${sandbox}/hook.log" >&2
    exit 1
  fi
}

# A complete local cache must work even when upstream is unavailable.
mv "${module_repo}" "${module_repo}.offline"
run_hook
assert_no_warnings
assert_upstream_urls
for module in fff ghostty zmx; do
  test "$(git -C "${checkout}/ThirdParty/${module}" rev-parse HEAD)" = "${base_commit}"
done
cmp "${main_repo}/.build/fff/arm64/fingerprint" "${checkout}/.build/fff/arm64/fingerprint"
mv "${module_repo}.offline" "${module_repo}"
echo "worktree-create hook preserves zsh PATH and reuses local submodules offline: ok"

# Advance only upstream and the gitlink, leaving the main checkout's cache stale.
printf 'new upstream payload\n' > "${module_repo}/payload"
git -C "${module_repo}" commit -qam newer
new_commit="$(git -C "${module_repo}" rev-parse HEAD)"
git -C "${main_repo}" update-index --cacheinfo "160000,${new_commit},ThirdParty/zmx"
git -C "${main_repo}" commit -qm 'pin newer zmx'
checkout="${sandbox}/stale-checkout"
git -C "${main_repo}" worktree add -q --detach "${checkout}"
run_hook
assert_no_warnings
assert_upstream_urls
test "$(git -C "${checkout}/ThirdParty/zmx" rev-parse HEAD)" = "${new_commit}"
echo "worktree-create hook fetches the pinned commit when the local cache is stale: ok"

# Reproduce a checkout already poisoned by an earlier failed local clone.
checkout="${sandbox}/failed-checkout"
git -C "${main_repo}" worktree add -q --detach "${checkout}"
git clone -q "${main_repo}/ThirdParty/zmx" "${checkout}/ThirdParty/zmx"
git -C "${checkout}" config submodule.ThirdParty/zmx.url "${main_repo}/ThirdParty/zmx"
mv "${module_repo}" "${module_repo}.offline"
run_hook
grep -q 'worktree-init: warning: submodule update failed for zmx' "${sandbox}/hook.log"
assert_upstream_urls
cmp "${main_repo}/.build/fff/arm64/fingerprint" "${checkout}/.build/fff/arm64/fingerprint"
mv "${module_repo}.offline" "${module_repo}"
git -C "${checkout}" submodule update -- ThirdParty/zmx > "${sandbox}/retry.log" 2>&1
test "$(git -C "${checkout}/ThirdParty/zmx" rev-parse HEAD)" = "${new_commit}"

echo "worktree-create hook restores upstream URLs after failure so a later retry succeeds: ok"
