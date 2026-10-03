#!/usr/bin/env bash
set -euo pipefail

this_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "${this_dir}/../../.." && pwd)"
tmp="$(mktemp -d -t prepare-release-project.XXXXXX)"
trap 'rm -rf "${tmp}"' EXIT

project="${tmp}/project.yml"
cat > "${project}" <<'YAML'
name: Fixture
targets:
  Alas:
    type: application
    platform: macOS
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: io.nlopez.alas
        PRODUCT_NAME: Alas
  Helper:
    type: tool
    platform: macOS
    settings:
      base:
        PRODUCT_NAME: Helper
schemes:
  Alas:
    build:
      targets:
        Alas: all
YAML

ruby "${repo_root}/scripts/prepare-release-project.rb" "${project}"

ruby -ryaml -e '
  project = YAML.safe_load(File.read(ARGV.fetch(0)), aliases: true)
  alas = project.fetch("targets").fetch("Alas").fetch("settings").fetch("base")
  abort "missing target-scoped ARCHS mapping" unless alas["ARCHS"] == "$(ALAS_APP_ARCHS)"
  abort "missing default architecture selection" unless alas["ALAS_APP_ARCHS"] == "$(ARCHS_STANDARD)"
  helper = project.fetch("targets").fetch("Helper").fetch("settings").fetch("base")
  abort "modified an unrelated target" unless helper == {"PRODUCT_NAME" => "Helper"}
' "${project}"

grep -Fq 'PRODUCT_BUNDLE_IDENTIFIER: io.nlopez.alas' "${project}"
cp "${project}" "${tmp}/once.yml"
ruby "${repo_root}/scripts/prepare-release-project.rb" "${project}"
cmp "${tmp}/once.yml" "${project}"

echo "prepare-release-project tests: ok"
