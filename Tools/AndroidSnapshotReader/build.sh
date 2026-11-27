#!/usr/bin/env bash
# Regenerate the bundled helper. The macOS app build does not need an Android SDK or JDK.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
sdk=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}
platform="$sdk/platforms/android-36"
d8="$sdk/build-tools/36.1.0/lib/d8.jar"
target=${1:-"$here/../../Alas/Resources/AndroidSnapshotReader.jar"}
target="$(cd "$(dirname "$target")" && pwd)/$(basename "$target")"
java=${JAVA_HOME:+$JAVA_HOME/bin/}java
javac=${JAVA_HOME:+$JAVA_HOME/bin/}javac
if ! [[ $("$javac" -version) == 'javac 24.0.2' && -f $d8 ]] || ! grep -Fxq 'Pkg.Revision=2' "$platform/source.properties"; then
    printf '%s\n' 'Use JDK 24.0.2, Android platform 36 revision 2, and build-tools 36.1.0.' >&2
    exit 1
fi
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mkdir "$scratch/classes" "$scratch/dex"
"$javac" --release 11 -cp "$platform/android.jar" -d "$scratch/classes" "$here/ReadTree.java"
"$java" -cp "$d8" com.android.tools.r8.D8 --min-api 36 --lib "$platform/android.jar" \
    --output "$scratch/dex" "$scratch/classes/io/nlopez/alas/android/ReadTree.class"
(
    cd "$scratch/dex"
    export TZ=UTC
    touch -t 198001010000.00 classes.dex
    zip -X -q -0 reader.jar classes.dex
)
cp "$scratch/dex/reader.jar" "$target"
