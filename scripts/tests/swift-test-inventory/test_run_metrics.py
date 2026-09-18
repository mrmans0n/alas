import importlib.util
from pathlib import Path
import sys
import unittest


SCRIPT = Path(__file__).resolve().parents[2] / "ci_run_metrics.py"
sys.path.insert(0, str(SCRIPT.parent))


class RunMetricsTests(unittest.TestCase):
    def test_queue_wait_and_execution_are_separate_and_incomplete_jobs_stay_unknown(self):
        self.assertTrue(SCRIPT.exists(), "CI run timing report has not been implemented")
        spec = importlib.util.spec_from_file_location("ci_run_metrics", SCRIPT)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        jobs = [{"name": "Swift tests (shard 1)", "created_at": "2026-09-18T11:00:00Z",
                 "started_at": "2026-09-18T11:02:00Z", "completed_at": "2026-09-18T11:10:00Z",
                 "conclusion": "success", "steps": [
                     {"name": "Wait for compiled Swift test products", "conclusion": "success",
                      "started_at": "2026-09-18T11:03:00Z", "completed_at": "2026-09-18T11:07:00Z"},
                     {"name": "Run measured Swift shard", "conclusion": "success",
                      "started_at": "2026-09-18T11:07:00Z", "completed_at": "2026-09-18T11:09:00Z"},
                     {"name": "Skipped step", "conclusion": "skipped",
                      "started_at": "0001-01-01T00:00:00Z", "completed_at": "2026-09-18T11:09:00Z"}]},
                {"name": "Swift coverage audit", "created_at": "2026-09-18T11:10:00Z",
                 "started_at": "2026-09-18T11:10:10Z", "completed_at": None,
                 "conclusion": None, "steps": []}]
        rows = module.job_timings(jobs)
        self.assertEqual(rows[0]["queue_seconds"], 120)
        self.assertEqual(rows[0]["runner_seconds"], 480)
        self.assertEqual(rows[0]["steps"], {
            "Wait for compiled Swift test products": 240, "Run measured Swift shard": 120})
        self.assertIsNone(rows[1]["runner_seconds"])
        markdown = module.render(rows, {"cache_counters": {"swiftCacheHits": 188, "swiftCacheMisses": 78}},
                                 {"wall_seconds": 663})
        self.assertIn("188", markdown)
        self.assertIn("78", markdown)
        self.assertIn("240.00", markdown)
        self.assertNotIn("0001", markdown)

    def test_missing_build_evidence_does_not_look_like_zero_cache_misses(self):
        self.assertTrue(SCRIPT.exists(), "CI run timing report has not been implemented")
        spec = importlib.util.spec_from_file_location("ci_run_metrics", SCRIPT)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        self.assertIn("unavailable", module.render([], None, None))


if __name__ == "__main__":
    unittest.main()
