#!/usr/bin/env python3
"""Schedule Xcode's compiled test inventory and reconcile its result bundles."""

import argparse
from collections import deque
from contextlib import suppress
import csv
import json
import math
import os
from pathlib import Path
import signal
import statistics
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
    policies = {"quarantine": set(), "subprocess": set()}
    slow_tests = set()
    for selector, lane, reason, issue in policy:
        if (lane not in ("quarantine", "subprocess", "slow-subprocess") or not reason.strip()
                or not issue.startswith("#") or not issue[1:].isdigit()):
            raise ValueError(f"Invalid execution policy: {selector}")
        matches = {test for test in tests if test == selector or test.startswith(selector + "/")}
        if lane == "slow-subprocess":
            slow_tests.update(matches)
            lane = "subprocess"
        if not matches or matches & policies[lane]:
            raise ValueError(f"Stale or overlapping execution policy: {selector}")
        policies[lane].update(matches)
    # Exclusions and execution requirements are separate: one excluded method
    # must not remove subprocess isolation from the rest of its suite.
    assignments = dict.fromkeys(policies["subprocess"], "subprocess")
    assignments.update(dict.fromkeys(policies["quarantine"], "quarantine"))
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
                groups.setdefault(selector, []).append(test)
        selectors = sorted(groups)
        chunks = ([selectors[i:i + 3] for i in range(0, len(selectors), 3)]
                  if lane == "subprocess" else [selectors[i::batch_count] for i in range(batch_count)])
        if lane == "subprocess":
            bounded_chunks = []
            for chunk in chunks:
                regular = []
                for selector in chunk:
                    if slow_tests.intersection(groups[selector]):
                        # Parameterized restore suites can consume the entire
                        # invocation deadline. Give small method selections
                        # independent deadlines, including result finalization.
                        methods = groups[selector]
                        bounded_chunks.extend(methods[i:i + 4] for i in range(0, len(methods), 4))
                    else:
                        regular.append(selector)
                if regular:
                    bounded_chunks.append(regular)
            chunks = bounded_chunks

        def invocation_timeout(chunk):
            return 360 if lane == "ordinary" or any(
                test in slow_tests for selector in chunk for test in groups.get(selector, [selector])) else 120

        if lane == "subprocess":
            # Spread the larger deadlines first so splitting a slow suite does
            # not overload one batch while another has room for more work.
            buckets = [[] for _ in range(batch_count)]
            budgets = [0] * batch_count
            for chunk in sorted(chunks, key=invocation_timeout, reverse=True):
                bucket = min(range(batch_count), key=lambda candidate: (budgets[candidate], candidate))
                buckets[bucket].append(chunk)
                budgets[bucket] += invocation_timeout(chunk) + 40
        for index in range(batch_count):
            invocations = buckets[index] if lane == "subprocess" else [chunks[index]]
            invocations = [chunk for chunk in invocations if chunk]
            selected = [test for chunk in invocations for selector in chunk for test in groups.get(selector, [selector])]
            # Keep partial suites together, but pass only their runnable test
            # identifiers to Xcode so an excluded sibling cannot execute.
            arguments = [[selector for suite in chunk
                          for selector in (groups[suite] if suite in groups and len(suite_lanes[suite]) > 1 else [suite])]
                         for chunk in invocations]
            timeouts = [invocation_timeout(chunk) for chunk in invocations]
            # Retain the logical batch's 30-minute planning limit, including
            # termination/result extraction and a minute for reporting. The
            # measured scheduler below redistributes invocations across jobs.
            if lane == "subprocess" and sum(timeout + 40 for timeout in timeouts) > 1740:
                raise ValueError(f"Subprocess batch {index + 1} exceeds its time budget; increase the batch count")
            batches.append({"id": f"{lane}-{index + 1}", "lane": lane, "index": index,
                            "invocations": arguments, "timeouts": timeouts, "tests": selected})
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


def suite_key(selectors):
    return tuple(sorted({selector.rsplit("/", 1)[0] if selector.count("/") > 1 else selector
                         for selector in selectors}))


def assign_shards(plan, timings):
    """Balance ordinary and isolated invocations across two test runners."""
    weights = {}
    groups, suites = {}, {}
    for entry in timings:
        key = tuple(entry["selectors"])
        seconds = entry["seconds"]
        if not key or key in weights or not math.isfinite(seconds) or seconds <= 0:
            raise ValueError("Invalid or duplicate invocation timing")
        weights[key] = seconds
        group = suite_key(key)
        groups.setdefault(group, []).append(seconds)
        # Apportion invocation wall time only as a fallback for regrouped suites.
        # These are estimates, not individually measured suite durations.
        for suite in group:
            suites.setdefault(suite, []).append(seconds / len(group))
    suite_weights = {suite: statistics.median(values) for suite, values in suites.items()}
    unknown = statistics.median(suite_weights.values()) if suite_weights else 10.0
    sources = dict.fromkeys(("exact", "suite-group", "estimated"), 0)
    pending = []
    for batch in plan["batches"]:
        batch["shards"] = [0] * len(batch["invocations"])
        batch["estimated_seconds"] = [None] * len(batch["invocations"])
        for index, selectors in enumerate(batch["invocations"]):
            group = suite_key(selectors)
            if tuple(selectors) in weights:
                seconds, source = weights[tuple(selectors)], "exact"
            elif group in groups:
                seconds, source = statistics.median(groups[group]), "suite-group"
            else:
                seconds = sum(suite_weights.get(suite, unknown) for suite in group)
                source = "estimated"
            sources[source] += 1
            batch["estimated_seconds"][index] = seconds
            pending.append((seconds, batch["id"], index, batch))
    totals = [0.0, 0.0]
    for seconds, _, index, batch in sorted(pending, key=lambda row: (-row[0], row[1], row[2])):
        shard = min(range(2), key=lambda candidate: (totals[candidate], candidate))
        batch["shards"][index] = shard + 1
        totals[shard] += seconds
    plan["shard_seconds"] = totals
    plan["timing_sources"] = sources


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n")
    temporary.replace(path)


def xcode_arguments():
    if os.environ.get("SWIFT_TEST_XCTESTRUN"):
        return ["xcodebuild", "-xctestrun", os.environ["SWIFT_TEST_XCTESTRUN"],
                "-destination", "platform=macOS,arch=arm64"]
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


def run_batch(plan, directory, lane, index, shard=None):
    batch = next(batch for batch in plan["batches"] if batch["lane"] == lane and batch["index"] == index)
    success = True
    for number, selectors in enumerate(batch["invocations"], 1):
        if shard is not None and batch["shards"][number - 1] != shard:
            continue
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
            status = bounded(command, directory / f"{name}.log", batch["timeouts"][number - 1])
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
            print(f"Selected tests: {', '.join(selectors)}", flush=True)
            if report.get("exit_status") == 124:
                print(f"Timed out after {batch['timeouts'][number - 1]} seconds", flush=True)
            print(f"Diagnostics: {report_path}; {bundle}", flush=True)
            for field in ("error", "failed", "missing", "unexpected"):
                if report.get(field):
                    print(f"{field}: {report[field]}", flush=True)
            log = directory / f"{name}.log"
            if log.exists():
                with log.open(errors="replace") as output:
                    tail = deque(output, maxlen=80)
                print("Last test output:\n" + "".join(tail), flush=True)
        success = success and report["ok"]
    return success


def run_shard(plan, directory, shard):
    if shard not in (1, 2):
        raise ValueError("Swift shard must be 1 or 2")
    success = True
    for batch in plan["batches"]:
        # Do not short-circuit: failed invocations must not suppress later work.
        passed = run_batch(plan, directory, batch["lane"], batch["index"], shard)
        success = success and passed
    return success


def summarize(plan, directory):
    rows, missing, observed = [], [], set()
    timings, shard_seconds = [], [0.0, 0.0, 0.0]
    timing_path = directory / "timings.json"
    timing_path.unlink(missing_ok=True)
    reports = {}
    for path in directory.rglob("*.report.json"):
        reports.setdefault(path.name, []).append(path)
    executed = skipped = 0
    success = True
    for batch in plan["batches"]:
        for number in range(1, len(batch["invocations"]) + 1):
            name = f"{batch['id']}-{number}"
            paths = reports.get(f"{name}.report.json", [])
            if len(paths) != 1:
                missing.append(name + (" (duplicate reports)" if paths else ""))
                success = False
                continue
            report = json.loads(paths[0].read_text())
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
            duration = report.get("duration_seconds")
            if isinstance(duration, (int, float)) and math.isfinite(duration) and duration > 0:
                shard = batch.get("shards", [0] * len(batch["invocations"]))[number - 1]
                shard_seconds[shard] += duration
                timings.append({"selectors": batch["invocations"][number - 1], "seconds": duration})
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
    if "shard_seconds" in plan:
        summary += "\n| Lane | Estimated seconds | Actual invocation seconds |\n|---|---:|---:|\n"
        for shard in (1, 2):
            seconds = shard_seconds[shard]
            estimate = f"{plan['shard_seconds'][shard - 1]:.2f}"
            summary += f"| {shard} | {estimate} | {seconds:.2f} |\n"
        summary += f"\nTiming sources: {json.dumps(plan.get('timing_sources', {}), sort_keys=True)}.\n"
        summary += "Actual totals include only reports with durations; check coverage above for incomplete lanes.\n"
    invocation_count = sum(len(batch["invocations"]) for batch in plan["batches"])
    if success and timings and len(timings) == invocation_count:
        source = (f"https://github.com/{os.environ['GITHUB_REPOSITORY']}/actions/runs/"
                  f"{os.environ['GITHUB_RUN_ID']}/attempts/{os.environ['GITHUB_RUN_ATTEMPT']}"
                  if all(os.environ.get(key) for key in ("GITHUB_REPOSITORY", "GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT"))
                  else f"plan:{plan['id']}")
        write_json(timing_path, {"source": source, "invocations": timings})
    (directory / "summary.md").write_text(summary)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as output:
            output.write(summary)
    print(summary)
    return success


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["plan", "run", "run-shard", "wait-products", "summary"])
    parser.add_argument("--directory", type=Path, default=RESULTS)
    parser.add_argument("--enumeration", type=Path)
    parser.add_argument("--policy", type=Path, default=ROOT / "scripts/ci-swift-test-policy.tsv")
    parser.add_argument("--batch-count", type=int, default=7)
    parser.add_argument("--batch", type=int, default=0)
    parser.add_argument("--shard", type=int, choices=[1, 2], default=1)
    parser.add_argument("--timings", type=Path, default=ROOT / "scripts/ci-swift-test-timings.json")
    parser.add_argument("--lane", choices=["ordinary", "subprocess"], default="ordinary")
    args = parser.parse_args()
    if args.command == "wait-products":
        started = time.monotonic()
        artifact = wait_for_products(os.environ["GITHUB_REPOSITORY"], os.environ["GITHUB_RUN_ID"],
                                     os.environ["GITHUB_RUN_ATTEMPT"], 3600)
        with open(os.environ["GITHUB_OUTPUT"], "a") as output:
            output.write(f"artifact_id={artifact}\n")
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as output:
            output.write(f"Waited {time.monotonic() - started:.1f}s for compiled Swift products.\n")
        return True
    args.directory.mkdir(parents=True, exist_ok=True)
    plan_path = args.directory / "plan.json"
    if args.command == "plan":
        plan_path.unlink(missing_ok=True)
        source = args.enumeration or discover(args.directory)
        with args.policy.open() as policy:
            rows = [row for row in csv.reader(policy, delimiter="\t") if row and not row[0].startswith("#")]
        plan = make_plan(json.loads(source.read_text()), rows, args.batch_count)
        assign_shards(plan, json.loads(args.timings.read_text())["invocations"])
        write_json(plan_path, plan)
        print(f"Discovered {len(plan['tests'])} tests; excluded {len(plan['excluded'])}; "
              f"scheduled {len(plan['tests']) - len(plan['excluded'])}")
        return True
    plan = json.loads(plan_path.read_text())
    if args.command == "run-shard":
        return run_shard(plan, args.directory, args.shard)
    return (run_batch(plan, args.directory, args.lane, args.batch) if args.command == "run"
            else summarize(plan, args.directory))


def github_pages(endpoint):
    result = subprocess.run(["gh", "api", "--paginate", "--slurp", endpoint],
                            check=True, capture_output=True, text=True, timeout=60)
    return json.loads(result.stdout)


def wait_for_products(repository, run_id, attempt, timeout):
    deadline = time.monotonic() + timeout
    name = f"swift-test-products-{attempt}"
    while time.monotonic() < deadline:
        pages = github_pages(f"repos/{repository}/actions/runs/{run_id}/artifacts?per_page=100")
        artifacts = [artifact for page in pages for artifact in page["artifacts"]
                     if artifact["name"] == name and not artifact["expired"]]
        if len(artifacts) == 1:
            return artifacts[0]["id"]
        if len(artifacts) > 1:
            raise ValueError("Duplicate compiled Swift products")
        pages = github_pages(f"repos/{repository}/actions/runs/{run_id}/attempts/{attempt}/jobs?per_page=100")
        if any(job["name"] == "build-test" and job["status"] == "completed"
               for page in pages for job in page["jobs"]):
            raise ValueError("Builder finished without publishing products for this attempt; rerun all jobs")
        time.sleep(15)
    raise ValueError("Timed out waiting for compiled Swift products; rerun all jobs")


if __name__ == "__main__":
    try:
        sys.exit(0 if main() else 1)
    except (OSError, ValueError, KeyError, StopIteration) as error:
        print(f"Swift CI: {error}", file=sys.stderr)
        sys.exit(1)
