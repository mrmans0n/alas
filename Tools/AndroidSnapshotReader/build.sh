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
kotlinc=${KOTLINC:-kotlinc}
if ! [[ $("$java" -version 2>&1) == *'version "24.0.2"'* &&
        $("$kotlinc" -version 2>&1) == *'kotlinc-jvm 2.2.21 '* &&
        -f $d8 ]] || ! grep -Fxq 'Pkg.Revision=2' "$platform/source.properties"; then
    printf '%s\n' 'Use JDK 24.0.2, Kotlin 2.2.21, Android platform 36 revision 2, and build-tools 36.1.0.' >&2
    exit 1
fi
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mkdir "$scratch/dex"
"$kotlinc" -jvm-target 11 -classpath "$platform/android.jar" -include-runtime \
    "$here/ReadTree.kt" -d "$scratch/reader.jar"
# app_process loads the entry point by name. Shrink the runtime; the Kotlin nullability annotations are compile-time only.
cat > "$scratch/keep.pro" <<'EOF'
-keep class io.nlopez.alas.android.ReadTree { public static void main(java.lang.String[]); }
-dontwarn org.jetbrains.annotations.NotNull
-dontwarn org.jetbrains.annotations.Nullable
EOF
"$java" -cp "$d8" com.android.tools.r8.R8 --release --min-api 36 --lib "$platform/android.jar" \
    --pg-conf "$scratch/keep.pro" --output "$scratch/dex" "$scratch/reader.jar"
(
    cd "$scratch/dex"
    export TZ=UTC
    touch -t 198001010000.00 classes.dex
    zip -X -q -0 reader.jar classes.dex
)
cp "$scratch/dex/reader.jar" "$target"
