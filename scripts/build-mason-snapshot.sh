#!/usr/bin/env bash
# Generates Alas/Resources/mason-lsps.json from the upstream Mason package
# registry (https://github.com/mason-org/mason-registry, Apache-2). Run this
# when refreshing the snapshot — say, when adding new presets, or quarterly.
#
# Requirements: bash, git, yq (v4), jq, brew (for the `brew search` probe).
#
# This script is NOT run on CI. The output file is committed to the repo.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$REPO_ROOT/Alas/Resources/mason-lsps.json"

for bin in git yq jq brew; do
    if ! command -v "$bin" >/dev/null 2>&1; then
        echo "error: $bin is required but not on PATH" >&2
        exit 1
    fi
done

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Mason's package.yaml lists `languages` (display names like "Rust", "TOML")
# but not file extensions. We need extensions so the Add-language picker can
# write a non-empty `extensions` array — without that, the LSP would never
# be matched to a file. Maintain a hand-curated map here. Unknown languages
# fall back to an empty array; the dialog blocks save until the user fills
# them in manually.
LANG_EXT_MAP=$(cat <<'JSON'
{
  "AsciiDoc": ["adoc", "asciidoc"],
  "Astro": ["astro"],
  "Bash": ["sh", "bash"],
  "Bicep": ["bicep"],
  "C": ["c", "h"],
  "C#": ["cs"],
  "C++": ["cc", "cpp", "cxx", "hh", "hpp", "hxx"],
  "CMake": ["cmake"],
  "CSS": ["css"],
  "Clojure": ["clj", "cljs", "cljc", "edn"],
  "CoffeeScript": ["coffee"],
  "Crystal": ["cr"],
  "Cue": ["cue"],
  "D": ["d"],
  "Dart": ["dart"],
  "Dockerfile": ["dockerfile"],
  "EJS": ["ejs"],
  "Elixir": ["ex", "exs"],
  "Elm": ["elm"],
  "Erlang": ["erl", "hrl"],
  "F#": ["fs", "fsi", "fsx"],
  "Fennel": ["fnl"],
  "Fish": ["fish"],
  "Gleam": ["gleam"],
  "Go": ["go"],
  "GraphQL": ["graphql", "gql"],
  "Groovy": ["groovy", "gradle"],
  "HCL": ["hcl"],
  "HTML": ["html", "htm"],
  "Haskell": ["hs", "lhs"],
  "Helm": ["yaml", "yml"],
  "JSON": ["json"],
  "JSONC": ["jsonc"],
  "Java": ["java"],
  "JavaScript": ["js", "mjs", "cjs", "jsx"],
  "Julia": ["jl"],
  "Kotlin": ["kt", "kts"],
  "LaTeX": ["tex"],
  "Lean": ["lean"],
  "Liquid": ["liquid"],
  "Lua": ["lua"],
  "Markdown": ["md", "markdown"],
  "Nim": ["nim"],
  "Nix": ["nix"],
  "OCaml": ["ml", "mli"],
  "PHP": ["php"],
  "Perl": ["pl", "pm"],
  "PowerShell": ["ps1", "psm1"],
  "Prisma": ["prisma"],
  "Protobuf": ["proto"],
  "PureScript": ["purs"],
  "Python": ["py", "pyi"],
  "R": ["r"],
  "ReScript": ["res", "resi"],
  "Reason": ["re", "rei"],
  "Ruby": ["rb"],
  "Rust": ["rs"],
  "SCSS": ["scss"],
  "SQL": ["sql"],
  "Sass": ["sass"],
  "Scala": ["scala", "sbt", "sc"],
  "Shell": ["sh", "bash", "zsh"],
  "Solidity": ["sol"],
  "Stylus": ["styl"],
  "Svelte": ["svelte"],
  "Swift": ["swift"],
  "TOML": ["toml"],
  "Tcl": ["tcl"],
  "Terraform": ["tf", "tfvars"],
  "TypeScript": ["ts", "mts", "cts", "tsx"],
  "Twig": ["twig"],
  "V": ["v"],
  "Vala": ["vala"],
  "Vim": ["vim"],
  "Vue": ["vue"],
  "Vimscript": ["vim"],
  "WebAssembly": ["wat", "wasm"],
  "XML": ["xml"],
  "YAML": ["yaml", "yml"],
  "Zig": ["zig"],
  "Zsh": ["zsh"],
  "haxe": ["hx"],
  "shellscript": ["sh", "bash", "zsh"]
}
JSON
)

echo "Cloning mason-org/mason-registry into $TMP..." >&2
git clone --depth 1 https://github.com/mason-org/mason-registry.git "$TMP/registry" >&2

echo "[" > "$OUT.partial"
FIRST=1

shopt -s nullglob
for pkg_yaml in "$TMP/registry/packages"/*/package.yaml; do
    # Only keep packages categorized as LSP.
    if ! yq -e '.categories[] | select(. == "LSP")' "$pkg_yaml" >/dev/null 2>&1; then
        continue
    fi
    name=$(yq -r '.name' "$pkg_yaml")
    description=$(yq -r '.description // ""' "$pkg_yaml" | tr -d '\n')
    languages=$(yq -o=json -I=0 '.languages // []' "$pkg_yaml")
    bin_entry=$(yq -r '.bin | to_entries | .[0].key // ""' "$pkg_yaml" 2>/dev/null || true)
    source_id=$(yq -r '.source.id // ""' "$pkg_yaml")

    # Translate source.id into install recipes we know how to run.
    # The purl spec URL-encodes '@' as '%40' for scoped npm packages (e.g.
    # pkg:npm/%40angular/language-server@21.2.13). We decode %40 -> @ and
    # strip the trailing @VERSION qualifier. The version pattern is
    # `@[^@]*$` (last @ to end-of-string) rather than `@[0-9]` because some
    # Go modules use `@vX.Y.Z` semver tags — anchoring to the final @ also
    # correctly preserves npm scope prefixes (e.g. @biomejs/biome).
    recipes="[]"
    case "$source_id" in
        pkg:cargo/*)
            crate=$(printf '%s' "$source_id" | sed -E 's|^pkg:cargo/||; s|@[^@]*$||')
            recipes=$(jq -n --arg pkg "$crate" '[{installer:"cargo", package:$pkg, extraArgs:[]}]')
            ;;
        pkg:npm/*)
            n=$(printf '%s' "$source_id" | sed -E 's|^pkg:npm/||; s|%40|@|g; s|@[^@]*$||')
            recipes=$(jq -n --arg pkg "$n" '[{installer:"npm", package:$pkg, extraArgs:[]}]')
            ;;
        pkg:pypi/*)
            n=$(printf '%s' "$source_id" | sed -E 's|^pkg:pypi/||; s|@[^@]*$||')
            recipes=$(jq -n --arg pkg "$n" '[{installer:"pipx", package:$pkg, extraArgs:[]}]')
            ;;
        pkg:golang/*)
            # Mason Go source ids may carry both `@vX.Y.Z` and `#cmd/subpath`
            # qualifiers (e.g. cuelang.org/go@v0.16.1#cmd/cue). Strip just the
            # version (any chars between `@` and either `#` or end), then
            # turn the `#subpath` separator into `/` so the final string is
            # the full importable command path. `LSPInstaller.argv` appends
            # `@latest` later.
            n=$(printf '%s' "$source_id" | sed -E 's|^pkg:golang/||; s|@[^#]*||; s|#|/|')
            recipes=$(jq -n --arg pkg "$n" '[{installer:"go", package:$pkg, extraArgs:[]}]')
            ;;
        pkg:github/*)
            # GitHub binary downloads — out of scope, skip the package entirely.
            continue
            ;;
        *)
            # Unknown source kind — skip.
            continue
            ;;
    esac

    # Probe brew for an exact-name formula and prepend a brew recipe if found.
    # Uses --eval-all to search offline without hitting the API.
    if brew search --formula --eval-all "/^${name}\$/" 2>/dev/null | grep -qx "$name"; then
        recipes=$(jq --arg pkg "$name" '[{installer:"brew", package:$pkg, extraArgs:[]}] + .' <<<"$recipes")
    fi

    cmd="$bin_entry"
    if [ -z "$cmd" ]; then cmd="$name"; fi

    # Look up each language in the curated extension map and union the
    # results. Unknown languages contribute nothing; the dialog blocks save
    # if the final list is empty so the user has to fill them in.
    extensions=$(jq -n --argjson langs "$languages" --argjson map "$LANG_EXT_MAP" \
        '[$langs[] | $map[.] // empty] | add // [] | unique')

    entry=$(jq -n \
        --arg masonId "$name" \
        --arg displayName "$name" \
        --argjson languages "$languages" \
        --argjson extensions "$extensions" \
        --arg command "$cmd" \
        --argjson recipes "$recipes" \
        '{
            masonId: $masonId,
            displayName: $displayName,
            languages: $languages,
            extensions: $extensions,
            command: $command,
            args: [],
            recipes: $recipes
        }')

    if [ $FIRST -eq 1 ]; then FIRST=0; else echo "," >> "$OUT.partial"; fi
    printf "%s" "$entry" >> "$OUT.partial"
done
echo "" >> "$OUT.partial"
echo "]" >> "$OUT.partial"

# Wrap in an envelope with attribution.
jq '{
    _notice: "Derived from mason-org/mason-registry (Apache-2.0). Regenerated by scripts/build-mason-snapshot.sh.",
    packages: .
}' "$OUT.partial" > "$OUT"
rm -f "$OUT.partial"

echo "Wrote $OUT" >&2
echo "Package count: $(jq '.packages | length' "$OUT")" >&2
