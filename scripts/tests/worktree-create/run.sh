#!/usr/bin/env bash
set -euo pipefail

this_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${this_dir}/../../.." && pwd)"
sandbox="$(mktemp -d)"
trap 'rm -rf "${sandbox}"' EXIT

export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com

# Reuse one tiny repository for all three submodules; no network or builds.
module_repo="${sandbox}/module"
main_repo="${sandbox}/main"
checkout="${sandbox}/checkout"
git init -q "${module_repo}"
printf 'submodule payload\n' > "${module_repo}/payload"
git -C "${module_repo}" add payload
git -C "${module_repo}" commit -qm initial
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
if ! (cd "${checkout}" && WORKTREE_TEST_PATH="${PATH}" /bin/zsh -f -c "${hook_script}") \
  > "${sandbox}/hook.log" 2>&1; then
  cat "${sandbox}/hook.log" >&2
  exit 1
fi

if grep -Eq 'command not found|worktree-init: warning:' "${sandbox}/hook.log"; then
  cat "${sandbox}/hook.log" >&2
  exit 1
fi
for module in fff ghostty zmx; do
  cmp "${module_repo}/payload" "${checkout}/ThirdParty/${module}/payload"
  test "$(git -C "${checkout}" config "submodule.ThirdParty/${module}.url")" = "${module_repo}"
done
cmp "${main_repo}/.build/fff/arm64/fingerprint" "${checkout}/.build/fff/arm64/fingerprint"

echo "worktree-create hook preserves zsh PATH and initializes the checkout: ok"
