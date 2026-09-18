import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True


SCRIPT = Path(__file__).resolve().parents[2] / "swift_build_metrics.py"


def task(rule, target, start, duration, children=()):
    return {"title": f"{rule} (in target '{target}' from project 'Alas')",
            "startTime": start, "duration": duration, "subsections": list(children)}


class MetricsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if SCRIPT.exists():
            spec = importlib.util.spec_from_file_location("metrics", SCRIPT)
            cls.metrics = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(cls.metrics)

    def setUp(self):
        self.assertTrue(SCRIPT.exists(), "Build measurement tool has not been implemented")

    def test_overlapping_tasks_are_not_reported_as_wall_time(self):
        log = {"title": "Build", "startTime": 100, "duration": 30, "subsections": [
            task("SwiftCompile normal arm64 A.swift", "Alas", 100, 10),
            task("SwiftCompile normal arm64 B.swift", "Alas", 105, 10),
            task("SwiftCompile normal arm64 ATests.swift", "AlasTests", 115, 5),
            task("SwiftEmitModule normal arm64", "Markdown", 102, 3),
            task("PhaseScriptExecution Build Ghostty", "Alas", 120, 2),
        ]}
        report = self.metrics.summarize(log)
        self.assertEqual(report["groups"]["app"]["task_seconds"], 20)
        self.assertEqual(report["groups"]["app"]["active_seconds"], 15)
        self.assertEqual(report["groups"]["tests"]["task_seconds"], 5)
        self.assertEqual(report["groups"]["dependencies"]["task_seconds"], 3)
        self.assertEqual(report["groups"]["scripts"]["task_seconds"], 2)
        self.assertEqual(report["build_seconds"], 30)

    def test_nested_compile_details_are_not_double_counted(self):
        log = task("SwiftCompile normal arm64 A.swift", "Alas", 100, 10, [
            task("SwiftCompile normal arm64 A.swift", "Alas", 100, 10)])
        self.assertEqual(self.metrics.summarize(log)["groups"]["app"]["task_seconds"], 10)

    def test_noop_does_not_invent_compiler_reuse(self):
        report = self.metrics.summarize({"duration": 2, "subsections": []})
        self.assertEqual(report["groups"]["app"]["tasks"], 0)
        self.assertEqual(report["groups"]["tests"]["tasks"], 0)

    def test_target_context_is_inherited_when_only_parent_names_target(self):
        log = {"title": "Build target AlasTests of project Alas", "duration": 10,
               "subsections": [{"title": "Compile ATests.swift", "startTime": 100,
                                "duration": 5, "commandInvocationDetails": {
                                    "commandDetails": "SwiftCompile normal arm64 ATests.swift"}}]}
        self.assertEqual(self.metrics.summarize(log)["groups"]["tests"]["tasks"], 1)

    def test_xcode_timing_summary_sections_are_not_executed_tasks(self):
        log = {"duration": 10, "subsections": [{"title": "SwiftCompile (121 tasks)",
               "domainType": "com.apple.dt.IDE.timing.aggregate", "startTime": 100,
               "duration": 0.001, "commandInvocationDetails": {
                   "commandDetails": "SwiftCompile (121 tasks) | 2603.337 seconds"}}]}
        self.assertEqual(self.metrics.summarize(log)["groups"]["dependencies"]["tasks"], 0)

    def test_compiler_reuse_comes_from_xcodes_metrics_attachment(self):
        log = {"duration": 10, "attachments": [{
            "uniformTypeIdentifier": "com.apple.dt.ActivityLogSectionAttachment.BuildOperationMetrics",
            "data": '{"counters":{"swiftCacheHits":12,"swiftCacheMisses":2},"taskCounters":{}}'}]}
        self.assertEqual(self.metrics.summarize(log)["cache_counters"],
                         {"swiftCacheHits": 12, "swiftCacheMisses": 2})
        self.assertEqual(self.metrics.summarize({"duration": 2})["cache_counters"], {})

    def test_runner_retains_failure_and_refuses_to_overwrite_evidence(self):
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp) / "measurement"
            command = [sys.executable, str(SCRIPT), "run", "--output", str(output), "--",
                       sys.executable, "-c", "print('compiler failed'); raise SystemExit(7)"]
            result = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(result.returncode, 7, result.stderr)
            metadata = json.loads((output / "run.json").read_text())
            self.assertEqual(metadata["exit_code"], 7)
            self.assertGreater(metadata["wall_seconds"], 0)
            self.assertIn("compiler failed", (output / "build.log").read_text())
            second = subprocess.run(command, capture_output=True, text=True)
            self.assertNotEqual(second.returncode, 0)
            self.assertEqual((output / "run.json").read_text(), json.dumps(metadata, indent=2) + "\n")


if __name__ == "__main__":
    unittest.main()
