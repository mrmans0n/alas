#!/usr/bin/env python3
"""Capture build wall time and summarize xcresult activity intervals.

Task seconds can overlap. Active seconds are the union of intervals within one
category, not its contribution to the build's critical path.
"""

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import sys
import time


def union_seconds(intervals):
    end = float("-inf")
    total = 0.0
    for start, stop in sorted(intervals):
        total += max(0, stop - max(start, end))
        end = max(end, stop)
    return total


def summarize(log):
    groups = {name: [] for name in ("app", "tests", "dependencies", "scripts")}

    def visit(section, target_name=""):
        if section.get("domainType") == "com.apple.dt.IDE.timing.aggregate":
            return
        text = section.get("commandInvocationDetails", {}).get("commandDetails", "")
        text = section.get("title", "") + "\n" + text
        target = re.search(r"in target '([^']+)'|Build target (\S+) of project", text)
        if target:
            target_name = target[1] or target[2]
        if re.search(r"\bPhaseScriptExecution\b", text):
            group = "scripts"
        elif re.search(r"\b(SwiftCompile|SwiftEmitModule|CompileSwift|CompileC|PrecompileModule|SwiftCompileModuleFromInterface)\b", text):
            group = {"Alas": "app", "AlasTests": "tests"}.get(target_name, "dependencies")
        else:
            group = None
        if group is not None:
            groups[group].append({"title": section.get("title", ""),
                                  "start": section["startTime"],
                                  "seconds": section["duration"]})
            # Xcode may nest detail sections inside a task. Count the task once.
            return
        for child in section.get("subsections", []):
            visit(child, target_name)

    visit(log)
    cache_counters = {}
    for attachment in log.get("attachments", []):
        if attachment.get("uniformTypeIdentifier") == "com.apple.dt.ActivityLogSectionAttachment.BuildOperationMetrics":
            counters = json.loads(attachment["data"]).get("counters", {})
            cache_counters = {key: value for key, value in counters.items()
                              if "cache" in key.lower()}
    return {
        "build_seconds": log["duration"],
        "cache_counters": cache_counters,
        "groups": {name: {
            "tasks": len(tasks),
            "task_seconds": round(sum(task["seconds"] for task in tasks), 3),
            "active_seconds": round(union_seconds([
                (task["start"], task["start"] + task["seconds"]) for task in tasks]), 3),
            "slowest": sorted(tasks, key=lambda task: task["seconds"], reverse=True)[:10],
        } for name, tasks in groups.items()},
    }


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n")


def run(output, command):
    if not command:
        raise ValueError("A build command is required after --")
    output.mkdir(parents=True, exist_ok=False)
    metadata = {"command": command, "cwd": str(Path.cwd()),
                "host": platform.node(), "platform": platform.platform(),
                "started_at": datetime.now(timezone.utc).isoformat()}
    for name, arguments in (("revision", ["rev-parse", "HEAD"]),
                            ("git_status", ["status", "--porcelain"])):
        value = subprocess.run(["git", *arguments], capture_output=True, text=True)
        metadata[name] = value.stdout.strip() if value.returncode == 0 else None
    write_json(output / "run.json", metadata)
    print(f"Recording build output in {output / 'build.log'}", flush=True)
    started = time.monotonic()
    with (output / "build.log").open("w") as log:
        # Preserve the original command's status and raw output, including errors.
        try:
            result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT)
            code = result.returncode
        except OSError as error:
            log.write(str(error) + "\n")
            code = 127
    metadata.update(wall_seconds=round(time.monotonic() - started, 3), exit_code=code)
    write_json(output / "run.json", metadata)
    print(f"Build exit={code} wall={metadata['wall_seconds']}s; log: {output / 'build.log'}")
    if code:
        print("\n".join((output / "build.log").read_text(errors="replace").splitlines()[-80:]))
    return code if code >= 0 else 128 - code


def report(output, result):
    extraction = subprocess.run(["xcrun", "xcresulttool", "get", "log", "--type", "build",
                                 "--path", str(result)], capture_output=True, text=True, check=True)
    log = json.loads(extraction.stdout)
    write_json(output / "activity.json", log)
    summary = summarize(log)
    write_json(output / "summary.json", summary)
    metadata = json.loads((output / "run.json").read_text())
    lines = ["### Swift build measurement", "",
             f"Command wall time: {metadata['wall_seconds']}s. Exit status: {metadata['exit_code']}.",
             "", "| Category | Tasks | Summed task seconds | Active seconds |",
             "| --- | ---: | ---: | ---: |"]
    for name, values in summary["groups"].items():
        lines.append(f"| {name} | {values['tasks']} | {values['task_seconds']} | {values['active_seconds']} |")
    lines += ["", "Task intervals overlap. Neither column sums to build wall time.", ""]
    lines += [f"Compiler cache counters: `{json.dumps(summary['cache_counters'], sort_keys=True)}`.",
              "An empty object means Xcode did not report cache counters.", ""]
    markdown = "\n".join(lines)
    (output / "summary.md").write_text(markdown)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with Path(os.environ["GITHUB_STEP_SUMMARY"]).open("a") as destination:
            destination.write(markdown)
    print(markdown)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="action", required=True)
    runner = commands.add_parser("run")
    runner.add_argument("--output", type=Path, required=True)
    runner.add_argument("command", nargs=argparse.REMAINDER)
    reporter = commands.add_parser("report")
    reporter.add_argument("--output", type=Path, required=True)
    reporter.add_argument("--result", type=Path, required=True)
    args = parser.parse_args()
    try:
        if args.action == "run":
            command = args.command[1:] if args.command[:1] == ["--"] else args.command
            return run(args.output, command)
        report(args.output, args.result)
        return 0
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"swift-build-metrics: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
