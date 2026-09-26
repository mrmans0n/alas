#!/usr/bin/env python3
"""Exercise scripts/test_growth.py against a throwaway git repository."""

import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / "test_growth.py"


def git(repo, *args):
    subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True, text=True)


def write(repo, path, text):
    target = repo / path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(text)


class TestGrowthReport(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = Path(self.tmp.name)
        git(self.repo, "init", "-q", "-b", "main")
        git(self.repo, "config", "user.email", "t@example.invalid")
        git(self.repo, "config", "user.name", "Test")
        write(self.repo, "Alas/App.swift", "struct App {}\n")
        write(self.repo, "AlasTests/AppTests.swift", "@Test func one() {}\n")
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "-q", "-m", "base")
        git(self.repo, "switch", "-q", "-c", "feature")

    def tearDown(self):
        self.tmp.cleanup()

    def run_report(self, *, actions=False):
        env = {k: v for k, v in os.environ.items() if k not in ("GITHUB_ACTIONS", "GITHUB_STEP_SUMMARY")}
        summary = self.repo / "summary.md"
        if actions:
            env["GITHUB_ACTIONS"] = "true"
            env["GITHUB_STEP_SUMMARY"] = str(summary)
        result = subprocess.run([sys.executable, str(SCRIPT), "main", "feature"], cwd=self.repo,
                                env=env, check=True, capture_output=True, text=True)
        return result.stdout, summary

    def test_reports_line_and_definition_deltas_and_notices_faster_test_growth(self):
        write(self.repo, "AlasTests/AppTests.swift",
              "@Test func one() {}\n@Test func two() {}\n    @Test(\"three\") func three() {}\n")
        write(self.repo, "AlasTests/Helpers.swift", "// not a test\nlet x = 1\n")
        write(self.repo, "Alas/App.swift", "struct App { var y = 0 }\n")
        git(self.repo, "commit", "-q", "-am", "grow")
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "-q", "-m", "helpers")

        stdout, summary = self.run_report(actions=True)

        self.assertIn("| Test lines (`AlasTests`) | 4 | 0 | +4 |", stdout)
        self.assertIn("| App lines (`Alas`) | 1 | 1 | +0 |", stdout)
        self.assertIn("`@Test` definitions: 1 → 3 (+2).", stdout)
        self.assertIn("::notice title=Test growth::", stdout)
        self.assertIn("## Test growth", summary.read_text())

    def test_shrinking_tests_emits_no_notice(self):
        write(self.repo, "AlasTests/AppTests.swift", "")
        git(self.repo, "commit", "-q", "-am", "prune")

        stdout, _ = self.run_report(actions=True)

        self.assertIn("`@Test` definitions: 1 → 0 (-1).", stdout)
        self.assertNotIn("::notice", stdout)

    def test_outside_actions_prints_the_report_without_annotations(self):
        write(self.repo, "AlasTests/MoreTests.swift", "@Test func more() {}\n")
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "-q", "-m", "more")

        stdout, summary = self.run_report()

        self.assertIn("(+1)", stdout)
        self.assertNotIn("::notice", stdout)
        self.assertFalse(summary.exists())


if __name__ == "__main__":
    unittest.main()
