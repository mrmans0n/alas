# Task 1 report

Status: DONE

Implemented the host-aware editor request contract and UTF-16 position
conversion. `EditorLSPBinding` synchronizes outstanding editor changes before
capturing an `EditorRequestContext`, and context validity is tied to the
document host, URI, served version, and holder generation. Remote LSP holders
and external-document attachment now retain the resolved remote-host identity,
while remote editor buffers have one explicit document-open lifecycle owner.

`LSPClient` negotiates `utf-16` explicitly and rejects incompatible server
position encodings. The position codec covers CRLF, final empty lines, invalid
positions, and surrogate-pair boundaries.

Verification:

- `rtk xcodegen` — passed.
- `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -derivedDataPath /private/tmp/alas-code-editor-lsp-dd -quiet build` — passed.
- `xcodebuild ... -quiet build-for-testing` — completed before the focused run.
- `xcodebuild ... -quiet test-without-building -only-testing:AlasTests/LSPPositionCodecTests -only-testing:AlasTests/EditorLSPBindingTests -only-testing:AlasTests/LSPClientLifecycleTests -only-testing:AlasTests/EditorBufferTests` — passed; result bundle reports 100 passed, 0 failed, 0 skipped.
- SwiftFormat completed for Task 1 files; `git diff --check` — passed.

Infrastructure note: foreground Xcode invocations can return before their
SwiftBuild child completes in this environment. The isolated build database was
inspected with `lsof`; its owner was the active `build-for-testing` process,
which completed normally. No DerivedData or lock file was removed.
