source="$(git worktree list --porcelain | awk '/^worktree /{print $2; exit}')"

# Reuse the main checkout's Git objects instead of downloading everything.
# `git submodule update --reference` still has the submodule helper clone
# from the .gitmodules URL (GitHub) for the transport handshake -- the
# reference only dedupes objects, it doesn't skip the network round trip.
# Pointing the submodule's url at the local sibling checkout instead makes
# it a same-machine clone (git hardlinks objects, no network at all): ~3.8s
# for all three submodules from a cold worktree here, vs ~23s for ghostty
# alone via the network path. `-c protocol.file.allow=always` is needed
# because git blocks the local-path/file transport for *nested* (submodule)
# clones by default (CVE-2022-39253) -- safe here since the source is our
# own trusted sibling checkout, not attacker-controlled input. Use the local
# checkout only when it contains the pinned commit; otherwise fetch upstream.
# Restore the upstream URL even after failures so later updates can retry.
#
# Best-effort throughout: a failure on one module or one file must not block
# the rest, since every artifact below is fingerprint-checked by its own
# build script and falls back to a real build on any mismatch or absence.
for module in fff ghostty zmx; do
  # zsh's `path` parameter is tied to PATH; keep the module path separate.
  module_path="ThirdParty/$module"
  local_src="$source/$module_path"
  git submodule init -- "$module_path" >/dev/null 2>&1
  # Also repair URLs left behind by an earlier failed hook.
  git submodule sync -- "$module_path" >/dev/null 2>&1
  module_commit="$(git rev-parse ":$module_path")"
  updated_locally=false
  if git -C "$local_src" cat-file -e "$module_commit^{commit}" 2>/dev/null; then
    if git -c protocol.file.allow=always -c "submodule.${module_path}.url=$local_src" \
      submodule update --reference "$local_src" -- "$module_path"; then
      updated_locally=true
    fi
    git submodule sync -- "$module_path" >/dev/null 2>&1
  fi
  if [[ "$updated_locally" == false ]] && ! git submodule update -- "$module_path"; then
    echo "worktree-init: warning: submodule update failed for $module, continuing" >&2
  fi
done

# Copy only finished build artifacts, not multi-gigabyte compiler caches.
# cp -c uses APFS clonefile: instant CoW regardless of file size, since
# worktrees share the same volume as the main checkout.
files=(
  .build/fff/arm64/fingerprint
  .build/fff/arm64/install/lib/libfff_c.dylib
  .build/fff/include/fff.h
  .build/fff/include/module.modulemap

  .build/treesitter-pack/arm64/fingerprint
  .build/treesitter-pack/arm64/install/lib/libalas_treesitter_pack.a
  .build/treesitter-pack/include/fingerprint
  .build/treesitter-pack/include/treesitter_pack.h
  .build/treesitter-pack/include/module.modulemap

  .build/zmx/linux-x86_64/fingerprint
  .build/zmx/linux-x86_64/install/bin/zmx
  .build/zmx/linux-aarch64/fingerprint
  .build/zmx/linux-aarch64/install/bin/zmx

  .build/alas-cli/fingerprint
  .build/alas-cli/x86_64-apple-darwin/release/alas
  .build/alas-cli/aarch64-apple-darwin/release/alas

  .build/alas-helper/fingerprint
  .build/alas-helper/x86_64-unknown-linux-musl/release/alas-helper
  .build/alas-helper/aarch64-unknown-linux-musl/release/alas-helper
  .build/alas-helper/x86_64-apple-darwin/release/alas-helper
  .build/alas-helper/aarch64-apple-darwin/release/alas-helper
)

for file in "${files[@]}"; do
  if [[ -f "$source/$file" ]]; then
    mkdir -p "$(dirname "$file")"
    cp -c "$source/$file" "$file" \
      || echo "worktree-init: warning: failed to copy $file, continuing" >&2
  fi
done
