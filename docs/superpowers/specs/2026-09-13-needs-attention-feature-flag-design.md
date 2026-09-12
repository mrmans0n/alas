# Needs attention feature flag

**Date:** 2026-09-13  
**Status:** Approved in conversation

## Goal

Keep Needs Attention experimental by hiding its sidebar entry point and project-level counts until a user enables it in Settings > Debug. The feature is off by default.

## Behavior

`AppConfig` gains a persisted `needsAttentionEnabled` Boolean. New configurations and configurations written before this key existed decode it as `false`.

Settings > Debug > Experimental gains a `Needs attention` toggle. It saves the flag through the existing app configuration flow.

When disabled, the sidebar header does not show the attention inbox button and project rows do not show their unresolved-item counts. If the inbox is open when the user disables the setting, the app closes it.

Attention signals, persistence, aggregation, history, and navigation continue to run while disabled. Re-enabling the setting immediately reveals the current unresolved count and stored history.

## Implementation

`SidebarView` owns the presentation decision because it already derives the aggregation and supplies both affected sidebar views. It will conditionally construct the header entry point and pass zero project attention counts while the flag is off.

No producer, store, aggregation, or navigation code changes. The existing `SidebarHeaderView` and `RepoGroupView` APIs stay intact, keeping the flag outside the attention domain model.

## Testing

- Assert the flag defaults to disabled in `AppConfig.defaults`.
- Assert an older encoded configuration without the key decodes with the flag disabled.
- Cover the sidebar presentation decision so a disabled flag removes the header entry point and project counts, while enabled preserves the aggregated values.

## Verification

Run focused Swift Testing coverage while developing. Before opening the pull request, run:

```bash
rtk xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test
rtk git diff --check
```
