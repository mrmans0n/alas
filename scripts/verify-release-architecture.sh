#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "usage: $0 <Alas.app> <expected-architecture>" >&2
    exit 64
fi

app="$1"
expected_arch="$2"

verify_exact_arch() {
    local binary="$1"
    local actual
    actual="$(lipo -archs "${binary}")"
    if [ "${actual}" != "${expected_arch}" ]; then
        echo "${binary} has architectures '${actual}'; expected exactly '${expected_arch}'" >&2
        return 1
    fi
}

verify_contains_arch() {
    local binary="$1"
    local actual
    local arch
    actual="$(lipo -archs "${binary}")"
    for arch in ${actual}; do
        if [ "${arch}" = "${expected_arch}" ]; then
            return 0
        fi
    done
    echo "${binary} has architectures '${actual}'; expected to contain '${expected_arch}'" >&2
    return 1
}

verify_exact_arch "${app}/Contents/MacOS/Alas"
verify_exact_arch "${app}/Contents/Resources/zmx/zmx"
verify_exact_arch "${app}/Contents/Frameworks/libfff_c.dylib"

while IFS= read -r -d '' library; do
    case "$(basename "${library}")" in
        libswiftCompatibility*.dylib)
            # Xcode embeds these Apple compatibility shims as universal SDK
            # artifacts. They are not produced by Alas, but the release slice
            # still has to be present for the app to launch on that architecture.
            verify_contains_arch "${library}"
            ;;
        *)
            verify_exact_arch "${library}"
            ;;
    esac
done < <(find "${app}/Contents/Frameworks" -type f -name '*.dylib' -print0)
