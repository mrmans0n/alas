#!/usr/bin/env python3
"""Rank Swift test durations from the result bundles of one CI run.

Download a green run's test plan and both `swift-test-results-*` artifacts
into a fresh directory used only for that run, then point this script at it:

    run=<run-id>
    gh run download "$run" -n swift-test-plan-1 -D "/tmp/alas-run-$run/plan"
    for s in 1 2; do
      gh run download "$run" -n swift-test-results-1-$s -D "/tmp/alas-run-$run/shard-$s"
    done
    python3 scripts/swift_test_durations.py "/tmp/alas-run-$run" --tsv "/tmp/alas-run-$run/durations.tsv"

It reads every `*.xcresult` bundle under that directory with
`xcrun xcresulttool`, writes one TSV row per test case, and prints how test
time is distributed. Totals are only meaningful for a complete run, so it
refuses to continue unless the bundles match exactly the invocations in the
run's `plan.json` and every runner report marks its invocation successful for
that same plan.
"""

import argparse
from collections import defaultdict
import json
from pathlib import Path
import subprocess
import sys


def planned_invocations(root):
    """Return the plan ID and invocation names the CI planner scheduled."""
    plans = sorted(root.rglob("plan.json"))
    if len(plans) != 1:
        sys.exit(f"expected exactly one plan.json under {root}, found {len(plans)}; "
                 "download the run's swift-test-plan artifact next to its results")
    plan = json.loads(plans[0].read_text())
    names = {f"{batch['id']}-{number}"
             for batch in plan["batches"]
             for number in range(1, len(batch["invocations"]) + 1)}
    return plan["id"], names


def validate(root, bundles):
    """Exit unless the bundles are the complete, successful output of one plan."""
    plan_id, expected = planned_invocations(root)
    found = {}
    for bundle in bundles:
        if bundle.stem in found:
            sys.exit(f"invocation {bundle.stem} appears twice ({found[bundle.stem]} and {bundle}); "
                     "point the script at a directory holding a single run")
        found[bundle.stem] = bundle
    missing = sorted(expected - found.keys())
    unexpected = sorted(found.keys() - expected)
    if missing or unexpected:
        sys.exit(f"bundles do not match the plan: missing {missing[:5]}, unexpected {unexpected[:5]}; "
                 "download every shard of the same run")
    for bundle in bundles:
        report_path = bundle.with_suffix(".report.json")
        if not report_path.exists():
            sys.exit(f"missing {report_path.name}; cannot confirm {bundle.name} is complete")
        report = json.loads(report_path.read_text())
        if report.get("plan_id") != plan_id:
            sys.exit(f"{bundle.name} belongs to a different CI plan than plan.json")
        # The runner writes `ok: false` before an invocation starts and only
        # flips it once every expected test is accounted for.
        if report.get("ok") is not True:
            sys.exit(f"{bundle.name} did not finish successfully; "
                     "use the result artifacts of a run whose invocations all passed")


def collect(bundle):
    proc = subprocess.run(
        ["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", str(bundle)],
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        # A partial run understates every total, so never report one as complete.
        sys.exit(f"cannot read {bundle}: {proc.stderr.strip()[:200]}")

    rows = []

    def walk(node, suite):
        if node.get("nodeType") == "Test Suite":
            suite = node.get("name", "")
        if node.get("nodeType") == "Test Case":
            rows.append((
                suite,
                node.get("name", ""),
                float(node.get("durationInSeconds") or 0.0),
                node.get("result", ""),
                bundle.stem,
            ))
            return
        for child in node.get("children") or []:
            walk(child, suite)

    for node in json.loads(proc.stdout).get("testNodes", []):
        walk(node, "")
    return rows


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("root", type=Path, help="directory holding one run's plan and result artifacts")
    parser.add_argument("--tsv", type=Path, help="write every test case to this TSV file")
    parser.add_argument("--top", type=int, default=30, help="rows to print per ranking")
    args = parser.parse_args()

    bundles = sorted(p for p in args.root.rglob("*.xcresult") if p.is_dir())
    validate(args.root, bundles)
    rows = [row for bundle in bundles for row in collect(bundle)]
    if not rows:
        sys.exit("no test cases found")

    if args.tsv:
        with args.tsv.open("w") as out:
            out.write("suite\ttest\tseconds\tresult\tinvocation\n")
            for suite, test, seconds, result, invocation in rows:
                out.write(f"{suite}\t{test}\t{seconds:.3f}\t{result}\t{invocation}\n")

    durations = sorted((row[2] for row in rows), reverse=True)
    total = sum(durations)
    print(f"bundles: {len(bundles)}  test cases: {len(rows)}  summed test seconds: {total:.0f}")
    for share in (0.01, 0.05, 0.10, 0.20):
        count = max(1, int(len(durations) * share))
        print(f"slowest {share:>4.0%} ({count} tests) = {sum(durations[:count]) / total:.0%} of test time")
    for threshold in (0.01, 0.1, 1.0):
        faster = [d for d in durations if d < threshold]
        print(f"tests under {threshold}s: {len(faster)} ({sum(faster):.0f}s)")

    by_suite = defaultdict(lambda: [0.0, 0])
    for suite, _, seconds, _, _ in rows:
        by_suite[suite][0] += seconds
        by_suite[suite][1] += 1
    print("\nslowest suites")
    for suite, (seconds, count) in sorted(by_suite.items(), key=lambda kv: -kv[1][0])[: args.top]:
        print(f"{seconds:8.1f}s {count:5d} tests {seconds / count:6.2f}s avg  {suite}")

    print("\nslowest tests")
    for suite, test, seconds, result, _ in sorted(rows, key=lambda row: -row[2])[: args.top]:
        print(f"{seconds:7.2f}s  {suite}/{test}  [{result}]")


if __name__ == "__main__":
    main()
