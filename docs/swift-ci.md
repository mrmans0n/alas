# Swift CI coverage

CI builds the test target once, then asks Xcode to enumerate the compiled tests
with `test-without-building -enumerate-tests -test-enumeration-style flat
-test-enumeration-format json`. No Swift source is parsed. The inventory and
execution therefore use the same toolchain, target, configuration, and canonical
test identifiers.

`scripts/ci_swift_tests.py plan` rejects enumeration errors even if Xcode returns
zero, empty inventories, duplicate identifiers, stale policy selectors, overlapping
policies, and disabled tests without an explicit exclusion. Every discovered test
is assigned once to execution or an exclusion in `scripts/ci-swift-test-policy.tsv`.
New tests default to ordinary execution without editing that file or the workflow.

The policy records selectors, execution requirements, reasons, and tracking issues.
Ghostty runtime smoke, SSH integration, live LSP verification, and Gemini E2E
remain explicit opt-ins outside PR CI. The three historically disabled subprocess
suites retain #23 as their follow-up. The subprocess list preserves the conservative
isolation baseline gathered during #1277; it does not assert every listed suite
individually reproduced a hang. Shrink it using measured runs, not source heuristics.

Six ordinary batches run sequentially on one runner. The subprocess lane also has
six batches, each containing invocations of at most three suites. Each invocation
has a wall-clock deadline, including startup and teardown: 360 seconds ordinary,
120 seconds subprocess. Tests retain Xcode's 60-second execution allowance.
Failures do not prevent later invocations or batches from collecting evidence.

Each invocation stores its selectors, expected tests, duration, exit status, logs,
result bundle, and structured test outcomes. The final audit rejects missing tests,
unexpected tests, failed tests, unapproved runtime skips, and incomplete invocations.
Counts refer to test definitions, so a parameterized function counts once; its
individual arguments remain visible in the result bundle. Quarantine counts and
runtime skip counts are separate. GitHub's job summary publishes counts and timings.
The always-run artifact step uploads `.build/xcode/results`, including partial
evidence from failed or timed-out invocations.

Local checks:

```sh
bash scripts/tests/swift-test-inventory/run.sh
bash scripts/tests/ci-workflow/run.sh
```

To validate an existing Xcode JSON inventory without building or executing tests:

```sh
python3 scripts/ci_swift_tests.py plan --enumeration /path/to/enumeration.json --directory /tmp/swift-plan
```

Use a fresh output directory per run. `SWIFT_TEST_DERIVED_DATA` can select an
existing local build for focused verification. CI uses `.build/xcode/DerivedData`.
Distributed sharding is deferred until the published durations provide a baseline.
