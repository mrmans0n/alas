# Task 5 Review Fix Report

## Status

DONE

## Changes

- Immutable image cache entries now use decoded bitmap storage bytes as their cache cost, with a pixel-based fallback for images without a bitmap representation.
- Immutable image loads now preserve the first `ImageDiffSide` result. Successful images are cached; `.failed` and `.missing` outcomes return directly without re-running `loadImageBlob`.

## Focused tests

```bash
rtk env ALAS_FFF_TARGET_ARCH=arm64 ALAS_ZMX_OPTIONAL=1 /Applications/Xcode-26.4.1.app/Contents/Developer/usr/bin/xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/alas-img-task5-fix-dd -only-testing:AlasTests/ImageDiffDecodedCacheTests -only-testing:AlasTests/ImageDiffPairLoaderTests -only-testing:AlasTests/ReviewChangesLoaderTests -only-testing:AlasTests/StagedDiffLoaderTests -only-testing:AlasTests/CommitReviewLoaderTests test -quiet
```

Observed: exit 0. Xcode result bundle `/tmp/alas-img-task5-fix-dd/Logs/Test/Test-Alas-2026.07.23_21-05-50-+0200.xcresult` reports `38` passed tests, `0` failed tests.
