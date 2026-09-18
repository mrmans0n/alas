#!/usr/bin/env python3
"""Report queue, runner, step, and compiler-cache measurements for one CI attempt."""

import argparse
from datetime import datetime
import json
import os
from pathlib import Path

from ci_swift_tests import github_pages, write_json


def seconds(start, end):
    if not start or not end:
        return None
    elapsed = (datetime.fromisoformat(end.replace("Z", "+00:00"))
               - datetime.fromisoformat(start.replace("Z", "+00:00"))).total_seconds()
    return round(elapsed, 2) if elapsed >= 0 else None


def job_timings(jobs):
    return [{"name": job["name"], "conclusion": job.get("conclusion"),
             "queue_seconds": seconds(job.get("created_at"), job.get("started_at")),
             "runner_seconds": seconds(job.get("started_at"), job.get("completed_at")),
             "steps": {step["name"]: seconds(step.get("started_at"), step.get("completed_at"))
                       for step in job.get("steps", [])
                       if step.get("conclusion") and step["conclusion"] != "skipped"}}
            for job in jobs]


def render(rows, build_summary, build_run):
    def display(value):
        return "unavailable" if value is None else f"{value:.2f}"

    lines = ["## CI elapsed time", "",
             "Queue time is job creation to runner start. Runner time includes setup and artifact waits.",
             "Jobs overlap; these durations must not be added to estimate workflow latency.",
             "When collected inside CI, the audit is still running; incomplete durations are unavailable.", "",
             "| Job | Queue seconds | Runner seconds | Result |", "|---|---:|---:|---|"]
    for row in rows:
        lines.append(f"| {row['name']} | {display(row['queue_seconds'])} | "
                     f"{display(row['runner_seconds'])} | {row['conclusion'] or 'in progress'} |")
    lines += ["", "| Job | Step | Seconds |", "|---|---|---:|"]
    for row in rows:
        if row["name"] == "build-test" or row["name"].startswith("Swift"):
            for name, elapsed in row["steps"].items():
                lines.append(f"| {row['name']} | {name} | {display(elapsed)} |")
    lines += ["", f"Build command wall seconds: {display((build_run or {}).get('wall_seconds'))}.",
              "Compiler cache counters: " + (f"`{json.dumps(build_summary['cache_counters'], sort_keys=True)}`."
                  if build_summary and build_summary.get("cache_counters") else "unavailable."), "",
              "Cache counters measure compiler reuse. A restored cache archive alone does not establish reuse.", ""]
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", default=os.environ.get("GITHUB_REPOSITORY"), required=False)
    parser.add_argument("--run-id", default=os.environ.get("GITHUB_RUN_ID"))
    parser.add_argument("--attempt", default=os.environ.get("GITHUB_RUN_ATTEMPT"))
    parser.add_argument("--directory", type=Path, default=Path(".build/xcode/run-metrics"))
    parser.add_argument("--build-directory", type=Path, default=Path(".build/xcode/build-summary"))
    args = parser.parse_args()
    if not all((args.repository, args.run_id, args.attempt)):
        parser.error("repository, run-id, and attempt are required")
    pages = github_pages(f"repos/{args.repository}/actions/runs/{args.run_id}/attempts/{args.attempt}/jobs?per_page=100")
    jobs = [job for page in pages for job in page["jobs"]]
    rows = job_timings(jobs)

    def read_optional(name):
        path = args.build_directory / name
        return json.loads(path.read_text()) if path.exists() else None

    summary, run = read_optional("summary.json"), read_optional("run.json")
    write_json(args.directory / "metrics.json", {"repository": args.repository, "run_id": args.run_id,
        "attempt": args.attempt, "jobs": rows, "build_summary": summary, "build_run": run})
    markdown = render(rows, summary, run)
    (args.directory / "summary.md").write_text(markdown)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as output:
            output.write(markdown)
    print(markdown)


if __name__ == "__main__":
    main()
