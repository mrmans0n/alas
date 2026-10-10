# Reviewed ACP draft cleanup

Issue: [#1439](https://github.com/mrmans0n/alas/issues/1439).

The composer toolbar offers **Clean up draft**. It uses the available Apple
Intelligence model on macOS 26 or later, without model downloads, MLX or cloud
fallback. Generation has no tools and treats JSON-quoted draft fragments as data.
The original remains editable and unchanged until the user accepts the preview.
Acceptance is one native undoable edit and has no submission path.

## Conservative edit boundary

This first implementation accepts removal of a leading `um` or `uh` before
recognized request phrasing, and addition of a final period to ordinary prose at
the end of the draft with a recognized complete prose clause, such as
`check this`, `do not push` or `no new tasks`. Ambiguous endings, including
commands embedded in prose, are left unchanged regardless of executable name.
All other words, punctuation and whitespace remain exact.
It refuses paraphrases, capitalization changes, interior punctuation changes,
and punctuation that could detach an attachment or condition. It preserves raw
technical tokens, commands, code and quoted content, including smart quotes.
Incomplete quotes/code and inputs over 2,000 editable UTF-8 bytes are refused.
The complete JSON-encoded prompt plus instructions reserves a 1,024-token
response allocation within the conservative 4,096-byte budget. The unchanged
JSON response plus 256 bytes for punctuation/formatting must fit that response
allocation, using bytes as a conservative token bound. This can refuse drafts
below the raw 2,000-byte limit; escaping-heavy or large echoes are refused before
generation.

Mention, image, command, path, upstream-reference and collapsed-paste objects
are retained in place. Their content is not generated or sent to the model.
The review marks attachments and collapsed pastes at their original positions.
Editor revision and session identity guard generation and acceptance. Editing,
restoring a draft, switching sessions, dictation, IME, pickers and Writing Tools
invalidate an outstanding preview. Editing and then undoing does not revive it.
Acceptance maps the caret and selection through filler deletion and period
insertion while retaining the single native undoable replacement.
Model availability is checked afresh when the user requests cleanup; an
unavailable model produces an explanation without changing the draft. No cached
availability result disables the action until an unrelated redraw.

## Focused checks

The relevant selectors are `AlasTests/ACPDraftCleanupTests`,
`AlasTests/ACPComposerDraftBridgeTests` and
`AlasTests/LocalTextAppleAvailabilityTests`. Run with the repository's normal
`xcodebuild test` flags, including `-skipMacroValidation`.

The bridge tests use the real composer text view and its native undo manager.
They cover accept/undo without submission, retained attachments after an image
file disappears, rejection/failure/cancellation, edit-then-undo, session changes,
Writing Tools and conflicting input. Policy tests cover restrictions, uncertain
and mixed-language text, exact technical content and late canceled results.

On 2026-10-10, the following native run succeeded on macOS 27 with Xcode 26.6:

```sh
ALAS_ZMX_OPTIONAL=1 ALAS_ZMX_ZIG_BIN=/tmp/alas-1439-missing-zig \
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -derivedDataPath .build/xcode/DerivedData \
  -skipPackagePluginValidation -skipMacroValidation \
  -only-testing AlasTests/ACPDraftCleanupTests \
  -only-testing AlasTests/ACPComposerDraftBridgeTests \
  -only-testing AlasTests/LocalTextAppleAvailabilityTests test
```

Swift Testing reported 128 tests in three suites. The result bundle confirms
127 passed, zero failed and one skipped (the opt-in live evaluation).
The build used the documented optional-ZMX mode because the pinned Zig helper
was unavailable; this run does not validate ZMX. `git diff --check` also passed.
Independent code review found no remaining concrete issues after preservation
and stale-generation regressions were corrected. CI has not been run.

The PR review then added byte-preserving Unicode comparisons and disabled
cleanup for whitespace/chip-only drafts. Both regressions failed before their
fixes. The same focused native command passed 129 tests in three suites after
the fixes (128 passed and the opt-in evaluation skipped). Full SwiftFormat lint
also passed. The first CI run stopped at formatting; its downstream coverage
failure had no test-plan artifact. Formatting was corrected for the next push.
Subsequent review added encoded-input budgeting and selection preservation.
Their regressions failed before the fixes; the final focused native run passed
130 tests in three suites (129 passed, zero failed, one opt-in evaluation skipped).
Unicode fixtures were refreshed to still fail without byte comparison after the
punctuation policy became stricter. Full formatting lint passed.

## Live evaluation and release gates

`ACPDraftCleanupTests.evaluateHeldOutDraft` contains 16 held-out typed/dictated
drafts, including mixed languages, technical tokens, negation, uncertain and
conditional requests, quoted code, injection text and structured attachments.
Enable it with `TEST_RUNNER_ALAS_DRAFT_CLEANUP_EVALUATION=1` when running the
Xcode selector. The test process reads `ALAS_DRAFT_CLEANUP_EVALUATION=1`.
The `DRAFT_CLEANUP_EVALUATION` records include input, raw output, accepted
output and elapsed time. A refused result is safe but does not prove usefulness.
Review accepted outputs for intent; passing deterministic tests is insufficient.

The 2026-10-10 standalone evaluation attempt on macOS 27 returned
`LocalTextAppleAvailability.modelNotReady` for all 16 cases. There were no model
outputs to assess. This is an unavailable-model result, not a successful live
evaluation. The feature remains unavailable until the system model is ready.
The native cleanup suite was then rerun with the evaluation environment enabled;
its held-out test failed the availability prerequisite with `modelNotReady`.
The other six cleanup tests passed. This confirms the native evaluation gate
actually ran, but provides no generated-output acceptance evidence.

Release remains blocked until an eligible Mac with a ready model passes:

- [ ] Review every held-out output. Any changed intent or lost restriction blocks release.
- [ ] Demonstrate the real composer with an identifier, flag, prohibition, mention and image.
- [ ] Reject, repeat, accept and undo. Confirm attachment positions and zero sends/queues.
- [ ] Edit during generation/review and switch sessions. Verify stale results cannot apply.
- [ ] Check dictation, IME, pickers and Writing Tools conflicts in the real composer.
- [ ] Confirm unavailable-model behavior and ordinary macOS 15 editing.

Do not count fixture-generated proposals or the isolated policy harness as
live-model or manual composer acceptance evidence.
