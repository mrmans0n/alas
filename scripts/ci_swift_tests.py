#!/usr/bin/env python3
"""Schedule Xcode's compiled test inventory and reconcile its result bundles."""

import argparse
from contextlib import suppress
import csv
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parent.parent
RESULTS = ROOT / ".build/xcode/results"


def make_plan(document, policy, batch_count):
    if batch_count < 1 or document.get("errors") != [] or not document.get("values"):
        raise ValueError(f"Invalid or failed Xcode enumeration: {document.get('errors')}")
    tests, disabled = [], set()
    for configuration in document["values"]:
        for key in ("enabledTests", "disabledTests"):
            for test in configuration[key]:
                identifier = test["identifier"]
                if not isinstance(identifier, str) or "/" not in identifier:
                    raise ValueError(f"Invalid Xcode identifier: {identifier!r}")
                tests.append(identifier)
                if key == "disabledTests":
                    disabled.add(identifier)
    if not tests or len(tests) != len(set(tests)):
        raise ValueError("Empty or duplicate Xcode inventory; use one test configuration")
    tests.sort()
    assignments = {}
    for selector, lane, reason, issue in policy:
        if (lane not in ("quarantine", "subprocess") or not reason.strip()
                or not issue.startswith("#") or not issue[1:].isdigit()):
            raise ValueError(f"Invalid execution policy: {selector}")
        matches = {test for test in tests if test == selector or test.startswith(selector + "/")}
        if not matches or matches & assignments.keys():
            raise ValueError(f"Stale or overlapping execution policy: {selector}")
        assignments.update(dict.fromkeys(matches, lane))
    excluded = [test for test in tests if assignments.get(test) == "quarantine"]
    if disabled - set(excluded):
        unassigned = sorted(disabled - set(excluded))
        raise ValueError(f"{len(unassigned)} tests disabled without an explicit exclusion; first five: {unassigned[:5]}")
    suite_lanes = {}
    for test in tests:
        suite = test.rsplit("/", 1)[0] if test.count("/") > 1 else test
        suite_lanes.setdefault(suite, set()).add(assignments.get(test, "ordinary"))
    batches = []
    for lane in ("ordinary", "subprocess"):
        groups = {}
        for test in tests:
            if assignments.get(test, "ordinary") == lane:
                # Canonical Xcode identifiers, not Swift source or display names.
                selector = test.rsplit("/", 1)[0] if test.count("/") > 1 else test
                if len(suite_lanes[selector]) > 1:
                    selector = test
                groups.setdefault(selector, []).append(test)
        selectors = sorted(groups)
        chunks = ([selectors[i:i + 3] for i in range(0, len(selectors), 3)]
                  if lane == "subprocess" else [selectors[i::batch_count] for i in range(batch_count)])
        for index in range(batch_count):
            invocations = chunks[index::batch_count] if lane == "subprocess" else [chunks[index]]
            invocations = [chunk for chunk in invocations if chunk]
            selected = [test for chunk in invocations for selector in chunk for test in groups[selector]]
            batches.append({"id": f"{lane}-{index + 1}", "lane": lane, "index": index,
                            "invocations": invocations, "tests": selected})
    scheduled = [test for batch in batches for test in batch["tests"]]
    if len(scheduled) != len(set(scheduled)) or set(scheduled) | set(excluded) != set(tests):
        raise ValueError("Inventory is not assigned exactly once")
    return {"id": str(uuid.uuid4()), "tests": tests, "excluded": excluded, "policy": policy, "batches": batches}


def account(expected, document):
    observed = {}

    def visit(node, target=None):
        if node.get("nodeType") == "Unit test bundle":
            target = node["name"]
        if node.get("nodeType") == "Test Case":
            if not target or not node.get("nodeIdentifier"):
                raise ValueError("Result test is missing its canonical identifier")
            identifier = target + "/" + node["nodeIdentifier"]
            if identifier in observed:
                raise ValueError(f"Duplicate result test: {identifier}")
            observed[identifier] = node.get("result")
        for child in node.get("children", []):
            visit(child, target)

    for node in document["testNodes"]:
        visit(node)
    missing = sorted(set(expected) - observed.keys())
    unexpected = sorted(observed.keys() - set(expected))
    failed = sorted(test for test, outcome in observed.items() if outcome not in ("Passed", "Skipped", "Expected Failure"))
    skipped = sum(outcome == "Skipped" for outcome in observed.values())
    executed = sum(outcome in ("Passed", "Failed", "Expected Failure") for outcome in observed.values())
    return {"ok": not (missing or unexpected or failed or skipped), "missing": missing,
            "unexpected": unexpected, "failed": failed, "skipped": skipped,
            "executed": executed, "outcomes": observed}


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n")
    temporary.replace(path)


def xcode_arguments():
    return ["xcodebuild", "-project", str(ROOT / "Alas.xcodeproj"), "-scheme", "Alas",
            "-destination", "platform=macOS,arch=arm64", "-derivedDataPath",
            os.environ.get("SWIFT_TEST_DERIVED_DATA", str(ROOT / ".build/xcode/DerivedData")),
            "-clonedSourcePackagesDirPath", str(ROOT / ".build/xcode/SourcePackages"),
            "-skipMacroValidation"]


def bounded(command, log, timeout):
    """Keep a log even on timeout; terminate the complete invocation process group."""
    with log.open("w") as output:
        process = subprocess.Popen(command, stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            return process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            with suppress(ProcessLookupError):
                os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                pass
            # The parent may have exited while a child ignored SIGTERM.
            with suppress(ProcessLookupError):
                os.killpg(process.pid, signal.SIGKILL)
            process.wait()
            return 124


def discover(directory):
    directory.mkdir(parents=True, exist_ok=True)
    output = directory / "enumeration.json"
    # Never reuse a previous successful enumeration after a failed invocation.
    output.unlink(missing_ok=True)
    status = bounded(xcode_arguments() + ["test-without-building", "-enumerate-tests",
        "-test-enumeration-style", "flat", "-test-enumeration-format", "json",
        "-test-enumeration-output-path", str(output)], directory / "enumeration.log", 120)
    if status:
        raise ValueError(f"Xcode enumeration failed ({status}); see {directory / 'enumeration.log'}")
    return output


def run_batch(plan, directory, lane, index):
    batch = next(batch for batch in plan["batches"] if batch["lane"] == lane and batch["index"] == index)
    success = True
    for number, selectors in enumerate(batch["invocations"], 1):
        name = f"{batch['id']}-{number}"
        bundle = directory / f"{name}.xcresult"
        expected = [test for test in batch["tests"] if any(test == s or test.startswith(s + "/") for s in selectors)]
        report = {"plan_id": plan["id"], "batch": batch["id"], "selectors": selectors, "expected": expected, "ok": False}
        report_path = directory / f"{name}.report.json"
        write_json(report_path, report)  # A cancelled invocation remains visibly incomplete.
        started = time.monotonic()
        try:
            command = xcode_arguments() + ["test-without-building", "-resultBundlePath", str(bundle),
                "-parallel-testing-enabled", "NO", "-test-timeouts-enabled", "YES",
                "-default-test-execution-time-allowance", "60", "-maximum-test-execution-time-allowance", "60"]
            for selector in selectors:
                command.extend(["-only-testing", selector])
            status = bounded(command, directory / f"{name}.log", 120 if lane == "subprocess" else 360)
            report["exit_status"] = status
            result = subprocess.run(["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", str(bundle)],
                                    capture_output=True, text=True, timeout=30, check=True)
            document = json.loads(result.stdout)
            write_json(directory / f"{name}.tests.json", document)
            report.update(account(expected, document))
            report["ok"] = report["ok"] and status == 0
        except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
            report.update(ok=False, error=str(error))
            if isinstance(error, subprocess.CalledProcessError):
                report["error"] += "\n" + (error.stderr or "")
        report["duration_seconds"] = round(time.monotonic() - started, 2)
        write_json(report_path, report)
        print(f"{name}: ok={report['ok']} executed={report.get('executed', 0)} "
              f"skipped={report.get('skipped', 0)} duration={report['duration_seconds']}s", flush=True)
        if not report["ok"]:
            print(f"Diagnostics: {report_path}; {bundle}", flush=True)
            for field in ("error", "failed", "missing", "unexpected"):
                if report.get(field):
                    print(f"{field}: {report[field]}", flush=True)
        success = success and report["ok"]
    return success


def summarize(plan, directory):
    rows, missing, observed = [], [], set()
    executed = skipped = 0
    success = True
    for batch in plan["batches"]:
        for number in range(1, len(batch["invocations"]) + 1):
            name = f"{batch['id']}-{number}"
            path = directory / f"{name}.report.json"
            if not path.exists():
                missing.append(name)
                success = False
                continue
            report = json.loads(path.read_text())
            if report.get("plan_id") != plan["id"]:
                missing.append(name + " (stale report)")
                success = False
                continue
            outcomes = report.get("outcomes", {})
            if observed & outcomes.keys():
                success = False
            observed.update(outcomes)
            executed += report.get("executed", 0)
            skipped += report.get("skipped", 0)
            success = success and report["ok"]
            rows.append(f"| {name} | {report.get('executed', 0)} | {report.get('skipped', 0)} | "
                        f"{report.get('duration_seconds', 'incomplete')} | {report['ok']} |")
    scheduled = set(plan["tests"]) - set(plan["excluded"])
    success = success and observed == scheduled
    summary = (f"## Swift coverage\n\nDiscovered: {len(plan['tests'])}; excluded: {len(plan['excluded'])}; "
               f"executed: {executed}; skipped at runtime: {skipped}; "
               f"unaccounted: {len(scheduled - observed)}.\n\n"
               "Counts are test definitions; parameter cases are retained in result bundles.\n\n"
               "| Invocation | Executed | Skipped | Seconds | OK |\n|---|---:|---:|---:|---|\n" + "\n".join(rows)
               + f"\n\nMissing invocation reports: {', '.join(missing) or 'none'}.\n")
    (directory / "summary.md").write_text(summary)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as output:
            output.write(summary)
    print(summary)
    return success


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["plan", "run", "summary"])
    parser.add_argument("--directory", type=Path, default=RESULTS)
    parser.add_argument("--enumeration", type=Path)
    parser.add_argument("--policy", type=Path, default=ROOT / "scripts/ci-swift-test-policy.tsv")
    parser.add_argument("--batch-count", type=int, default=6)
    parser.add_argument("--batch", type=int, default=0)
    parser.add_argument("--lane", choices=["ordinary", "subprocess"], default="ordinary")
    args = parser.parse_args()
    args.directory.mkdir(parents=True, exist_ok=True)
    plan_path = args.directory / "plan.json"
    if args.command == "plan":
        plan_path.unlink(missing_ok=True)
        source = args.enumeration or discover(args.directory)
        with args.policy.open() as policy:
            rows = [row for row in csv.reader(policy, delimiter="\t") if row and not row[0].startswith("#")]
        plan = make_plan(json.loads(source.read_text()), rows, args.batch_count)
        write_json(plan_path, plan)
        print(f"Discovered {len(plan['tests'])} tests; excluded {len(plan['excluded'])}; "
              f"scheduled {len(plan['tests']) - len(plan['excluded'])}")
        return True
    plan = json.loads(plan_path.read_text())
    return (run_batch(plan, args.directory, args.lane, args.batch) if args.command == "run"
            else summarize(plan, args.directory))


if __name__ == "__main__":
    try:
        sys.exit(0 if main() else 1)
    except (OSError, ValueError, KeyError, StopIteration) as error:
        print(f"Swift CI: {error}", file=sys.stderr)
        sys.exit(1)
