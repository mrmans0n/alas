import importlib.util
import io
import json
from pathlib import Path
import sys
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[2] / "ci_swift_tests.py"


def enumeration(*identifiers, disabled=(), errors=()):
    return {"errors": list(errors), "values": [{"testPlan": "Alas",
        "enabledTests": [{"identifier": value} for value in identifiers],
        "disabledTests": [{"identifier": value} for value in disabled]}]}


def results(*cases):
    return {"testNodes": [{"nodeType": "Unit test bundle", "name": "AlasTests",
        "children": [{"nodeType": "Test Case", "nodeIdentifier": identifier,
                      "result": outcome} for identifier, outcome in cases]}]}


class InventoryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if SCRIPT.exists():
            spec = importlib.util.spec_from_file_location("ci_swift_tests", SCRIPT)
            cls.module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(cls.module)

    def setUp(self):
        self.assertTrue(SCRIPT.exists(), "Xcode JSON scheduler has not been implemented")

    def test_new_suites_and_free_functions_default_to_execution(self):
        plan = self.module.make_plan(enumeration("AlasTests/CaféSpec/works()",
            "AlasTests/Namespace.Inner/argument(value:)", "AlasTests/freeTest()"), [], 2)
        self.assertEqual(plan["tests"], ["AlasTests/CaféSpec/works()",
            "AlasTests/Namespace.Inner/argument(value:)", "AlasTests/freeTest()"])
        assigned = [test for batch in plan["batches"] for test in batch["tests"]]
        self.assertCountEqual(assigned, plan["tests"])
        self.assertEqual(len(assigned), len(set(assigned)))

    def test_errors_empty_and_duplicate_inventories_fail_closed(self):
        for document in [enumeration(errors=["bundle failed to load"]), enumeration(),
                         enumeration("AlasTests/A/a()", "AlasTests/A/a()"),
                         {"values": []}]:
            with self.subTest(document=document), self.assertRaises(ValueError):
                self.module.make_plan(document, [], 2)

    def test_shards_balance_invocations_and_keep_ordinary_on_lane_zero(self):
        ids = [f"AlasTests/S{i}/test()" for i in range(12)]
        policy = [(f"AlasTests/S{i}", "subprocess", "isolation", "#23") for i in range(12)]
        plan = self.module.make_plan(enumeration("AlasTests/Ordinary/test()", *ids), policy, 2)
        chunks = [chunk for batch in plan["batches"] if batch["lane"] == "subprocess"
                  for chunk in batch["invocations"]]
        timings = [{"selectors": chunk, "seconds": seconds}
                   for chunk, seconds in zip(chunks, [90, 60, 40, 10])]
        self.module.assign_shards(plan, timings)
        self.assertEqual(plan["shard_seconds"], [100, 100])
        self.assertTrue(all(shard == 0 for batch in plan["batches"] if batch["lane"] == "ordinary"
                            for shard in batch["shards"]))
        self.assertCountEqual([shard for batch in plan["batches"] if batch["lane"] == "subprocess"
                               for shard in batch["shards"]], [1, 1, 2, 2])

    def test_unknown_invocations_are_assigned_and_bad_timings_rejected(self):
        plan = self.module.make_plan(enumeration("AlasTests/A/a()"), [
            ("AlasTests/A", "subprocess", "isolation", "#23")], 1)
        self.module.assign_shards(plan, [])
        self.assertEqual(plan["batches"][1]["shards"], [1])
        for seconds in [0, -1, float("nan"), float("inf")]:
            with self.subTest(seconds=seconds), self.assertRaises(ValueError):
                self.module.assign_shards(plan, [{"selectors": ["AlasTests/A"], "seconds": seconds}])

    def test_quarantine_changes_reuse_suite_group_timing_without_changing_selection(self):
        plan = self.module.make_plan(enumeration("AlasTests/A/a()", "AlasTests/A/b()"), [
            ("AlasTests/A", "subprocess", "isolation", "#23"),
            ("AlasTests/A/b()", "quarantine", "failure", "#23")], 1)
        self.module.assign_shards(plan, [{"selectors": ["AlasTests/A"], "seconds": 12}])
        self.assertEqual(plan["shard_seconds"], [12, 0])
        self.assertEqual(plan["batches"][1]["invocations"], [["AlasTests/A/a()"]])
        self.assertEqual(plan["batches"][1]["timeouts"], [120])

    def test_regrouped_and_unknown_suites_use_estimates_not_timeout_budgets(self):
        ids = [f"AlasTests/{suite}/test()" for suite in "ABCDEF"]
        policy = [(f"AlasTests/{suite}", "subprocess", "isolation", "#23") for suite in "ABCDEF"]
        plan = self.module.make_plan(enumeration(*ids), policy, 1)
        self.module.assign_shards(plan, [
            {"selectors": ["AlasTests/A", "AlasTests/D"], "seconds": 20},
            {"selectors": ["AlasTests/B", "AlasTests/E"], "seconds": 40}])
        # A/D contribute 10 each, B/E 20 each, unknown C/F use the median 15.
        self.assertEqual(plan["shard_seconds"], [45, 45])
        self.assertEqual(plan["timing_sources"], {"exact": 0, "suite-group": 0, "estimated": 2})
        self.assertEqual(plan["batches"][1]["timeouts"], [120, 120])

    def test_successful_audit_exports_refreshable_timings_without_result_bundles(self):
        plan = self.module.make_plan(enumeration("AlasTests/A/a()"), [
            ("AlasTests/A", "subprocess", "isolation", "#23")], 1)
        self.module.assign_shards(plan, [])
        report = self.module.account(["AlasTests/A/a()"], results(("A/a()", "Passed")))
        report.update(plan_id=plan["id"], selectors=["AlasTests/A"], duration_seconds=14)
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            self.module.write_json(directory / "shard-1/subprocess-1-1.report.json", report)
            with patch.dict("os.environ", {"GITHUB_STEP_SUMMARY": ""}):
                self.assertTrue(self.module.summarize(plan, directory))
            timings = json.loads((directory / "timings.json").read_text())
            self.assertEqual(timings["invocations"], [{"selectors": ["AlasTests/A"], "seconds": 14}])
            self.assertIn("Estimated seconds", (directory / "summary.md").read_text())
            report["ok"] = False
            self.module.write_json(directory / "shard-1/subprocess-1-1.report.json", report)
            with patch.dict("os.environ", {"GITHUB_STEP_SUMMARY": ""}):
                self.assertFalse(self.module.summarize(plan, directory))
            self.assertFalse((directory / "timings.json").exists())

    def test_shards_execute_every_invocation_once_and_propagate_failure(self):
        ids = [f"AlasTests/S{i}/test()" for i in range(7)]
        policy = [(f"AlasTests/S{i}", "subprocess", "isolation", "#23") for i in range(7)]
        plan = self.module.make_plan(enumeration("AlasTests/Ordinary/test()", *ids), policy, 2)
        self.module.assign_shards(plan, [])
        selected = []

        def execute(command, log, timeout):
            selectors = [command[i + 1] for i, value in enumerate(command) if value == "-only-testing"]
            selected.extend(selectors)
            execute.selectors = selectors
            return 65 if "AlasTests/S0" in selectors else 0

        def extract(*args, **kwargs):
            cases = [(selector.removeprefix("AlasTests/") + "/test()", "Passed")
                     for selector in execute.selectors]
            return subprocess.CompletedProcess([], 0, stdout=json.dumps(results(*cases)))

        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            with patch.object(self.module, "bounded", side_effect=execute), patch.object(
                    self.module.subprocess, "run", side_effect=extract):
                statuses = [self.module.run_shard(plan, directory, shard) for shard in range(3)]
            self.assertEqual(statuses, [True, False, True])
            self.assertCountEqual(selected, ["AlasTests/Ordinary"] + [f"AlasTests/S{i}" for i in range(7)])
            self.assertEqual(len(selected), len(set(selected)))
            self.assertEqual(len(list(directory.glob("*.report.json"))), 4)
            with self.assertRaises(ValueError):
                self.module.run_shard(plan, directory, 3)

    def test_portable_xctestrun_does_not_resolve_or_build_project(self):
        with patch.dict("os.environ", {"SWIFT_TEST_XCTESTRUN": "/tmp/products/Alas.xctestrun"}):
            args = self.module.xcode_arguments()
        self.assertEqual(args, ["xcodebuild", "-xctestrun", "/tmp/products/Alas.xctestrun",
                               "-destination", "platform=macOS,arch=arm64"])

    def test_artifact_wait_ignores_previous_attempt_and_returns_current_artifact(self):
        old = {"id": 1, "name": "swift-test-products-1", "expired": False}
        current = {"id": 2, "name": "swift-test-products-2", "expired": False}
        responses = [[{"artifacts": [old]}], [{"jobs": [{"name": "build-test", "status": "in_progress"}]}],
                     [{"artifacts": [old, current]}]]
        with patch.object(self.module, "github_pages", side_effect=responses), patch.object(self.module.time, "sleep"):
            self.assertEqual(self.module.wait_for_products("owner/repo", 123, 2, 30), 2)

    def test_artifact_wait_stops_when_builder_finishes_without_products(self):
        with patch.object(self.module, "github_pages", side_effect=[
                [{"artifacts": []}], [{"jobs": [{"name": "build-test", "status": "completed"}]}]]):
            with self.assertRaisesRegex(ValueError, "without publishing"):
                self.module.wait_for_products("owner/repo", 123, 1, 30)

    def test_artifact_wait_has_a_deadline(self):
        with patch.object(self.module.time, "monotonic", side_effect=[0, 31]):
            with self.assertRaisesRegex(ValueError, "Timed out"):
                self.module.wait_for_products("owner/repo", 123, 1, 30)

    def test_exclusions_require_reason_issue_and_matching_selector(self):
        document = enumeration("AlasTests/A/a()")
        for policy in [[("AlasTests/Missing", "quarantine", "reason", "#23")],
                       [("AlasTests/A", "quarantine", "", "#23")],
                       [("AlasTests/A", "quarantine", "reason", "")],
                       [("AlasTests/A", "unknown", "reason", "#23")]]:
            with self.subTest(policy=policy), self.assertRaises(ValueError):
                self.module.make_plan(document, policy, 2)

    def test_overlapping_policy_is_rejected(self):
        with self.assertRaises(ValueError):
            self.module.make_plan(enumeration("AlasTests/A/a()"), [
                ("AlasTests/A", "quarantine", "hang", "#23"),
                ("AlasTests/A/a()", "quarantine", "hang", "#23")], 2)

    def test_one_quarantined_test_preserves_subprocess_isolation_for_its_siblings(self):
        plan = self.module.make_plan(enumeration("AlasTests/A/a()", "AlasTests/A/b()", "AlasTests/A/c()"), [
            ("AlasTests/A", "subprocess", "isolation", "#23"),
            ("AlasTests/A/b()", "quarantine", "hang", "#23")], 1)
        self.assertEqual(plan["excluded"], ["AlasTests/A/b()"])
        self.assertEqual(plan["batches"][1]["invocations"], [["AlasTests/A/a()", "AlasTests/A/c()"]])

    def test_disabled_tests_need_explicit_exclusion(self):
        document = enumeration("AlasTests/A/a()", disabled=["AlasTests/B/b()"])
        with self.assertRaises(ValueError):
            self.module.make_plan(document, [], 2)
        plan = self.module.make_plan(document, [
            ("AlasTests/B", "quarantine", "needs service", "#1270")], 2)
        self.assertEqual(plan["excluded"], ["AlasTests/B/b()"])

    def test_subprocess_chunks_are_bounded_and_do_not_drop_tests(self):
        ids = [f"AlasTests/S{i}/test()" for i in range(8)]
        policy = [(f"AlasTests/S{i}", "subprocess", "isolation", "#23") for i in range(8)]
        plan = self.module.make_plan(enumeration(*ids), policy, 2)
        chunks = [chunk for batch in plan["batches"] for chunk in batch["invocations"]]
        self.assertTrue(all(len(chunk) <= 3 for chunk in chunks))
        self.assertCountEqual([test for batch in plan["batches"] for test in batch["tests"]], ids)

    def test_measured_slow_suite_gets_a_bounded_larger_invocation_budget(self):
        plan = self.module.make_plan(enumeration("AlasTests/A/a()"), [
            ("AlasTests/A", "slow-subprocess", "measured restore scenarios", "#23")], 1)
        self.assertEqual(plan["batches"][1]["timeouts"], [360])

    def test_slow_suite_methods_do_not_share_a_deadline_with_other_suites(self):
        slow = [f"AlasTests/B/test{i}()" for i in range(8)]
        ids = ["AlasTests/A/test()", *slow, "AlasTests/C/test()"]
        policy = [("AlasTests/A", "subprocess", "isolation", "#23"),
                  ("AlasTests/B", "slow-subprocess", "measured restore scenarios", "#23"),
                  ("AlasTests/C", "subprocess", "isolation", "#23"),
                  (slow[-1], "quarantine", "known failure", "#23")]
        plan = self.module.make_plan(enumeration(*ids), policy, 2)
        batches = [batch for batch in plan["batches"] if batch["lane"] == "subprocess"]
        invocations = [chunk for batch in batches for chunk in batch["invocations"]]
        selected_slow = [chunk for chunk in invocations if any("/B/" in s or s == "AlasTests/B" for s in chunk)]
        self.assertEqual(len(selected_slow), 2)
        self.assertTrue(all(len(chunk) <= 4 and all(s in slow[:-1] for s in chunk)
                            for chunk in selected_slow))
        self.assertCountEqual([s for chunk in selected_slow for s in chunk], slow[:-1])
        self.assertCountEqual([test for batch in batches for test in batch["tests"]],
                              ["AlasTests/A/test()", *slow[:-1], "AlasTests/C/test()"])
        for batch in batches:
            for chunk, timeout in zip(batch["invocations"], batch["timeouts"]):
                self.assertEqual(timeout, 360 if chunk in selected_slow else 120)

    def test_plan_rejects_more_work_than_a_subprocess_step_can_finish(self):
        ids = [f"AlasTests/S{i}/test()" for i in range(16)]
        policy = [(f"AlasTests/S{i}", "slow-subprocess", "measured", "#23") for i in range(16)]
        with self.assertRaisesRegex(ValueError, "budget"):
            self.module.make_plan(enumeration(*ids), policy, 1)

    def test_split_slow_suite_deadlines_fit_existing_batch_capacity(self):
        ids = [f"AlasTests/S{i:03}/test()" for i in range(156)]
        ids.extend(f"AlasTests/S036/extra{i}()" for i in range(13))
        policy = [(f"AlasTests/S{i:03}", "slow-subprocess" if i == 36 else "subprocess",
                   "isolation", "#23") for i in range(156)]
        plan = self.module.make_plan(enumeration(*ids), policy, 6)
        self.assertCountEqual([test for batch in plan["batches"] for test in batch["tests"]], ids)
        for batch in plan["batches"]:
            if batch["lane"] == "subprocess":
                self.assertLessEqual(sum(t + 40 for t in batch["timeouts"]), 1740)

    def test_partial_exclusion_never_selects_its_parent_suite(self):
        plan = self.module.make_plan(enumeration("AlasTests/A/a()", "AlasTests/A/b()"),
            [("AlasTests/A/b()", "quarantine", "needs credentials", "#1270")], 1)
        self.assertEqual(plan["batches"][0]["invocations"], [["AlasTests/A/a()"]])

    def test_bounded_command_preserves_log_and_nonzero_exit(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "command.log"
            status = self.module.bounded([sys.executable, "-c", "print('failure evidence'); exit(7)"], log, 5)
            self.assertEqual(status, 7)
            self.assertIn("failure evidence", log.read_text())

    def test_bounded_command_times_out_and_preserves_diagnostics(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "command.log"
            status = self.module.bounded([sys.executable, "-u", "-c",
                "import time; print('before hang'); time.sleep(10)"], log, 0.2)
            self.assertEqual(status, 124)
            self.assertIn("before hang", log.read_text())

    def test_timeout_also_stops_children_that_ignore_termination(self):
        child = "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(0.8); print('leaked', flush=True)"
        parent = f"import subprocess,sys,time; subprocess.Popen([sys.executable, '-c', {child!r}]); time.sleep(10)"
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "command.log"
            self.assertEqual(self.module.bounded([sys.executable, "-c", parent], log, 0.3), 124)
            time.sleep(0.8)
            self.assertNotIn("leaked", log.read_text())

    def test_summary_fails_if_a_batch_never_runs(self):
        plan = self.module.make_plan(enumeration("AlasTests/A/a()", "AlasTests/B/b()"), [], 2)
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            report = self.module.account(["AlasTests/A/a()"], results(("A/a()", "Passed")))
            report["plan_id"] = plan["id"]
            (directory / "ordinary-1-1.report.json").write_text(json.dumps(report))
            with patch.dict("os.environ", {"GITHUB_STEP_SUMMARY": ""}):
                self.assertFalse(self.module.summarize(plan, directory))
            self.assertIn("unaccounted: 1", (directory / "summary.md").read_text())

    def test_summary_rejects_success_from_a_previous_run(self):
        plan = self.module.make_plan(enumeration("AlasTests/A/a()"), [], 1)
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            report = self.module.account(["AlasTests/A/a()"], results(("A/a()", "Passed")))
            report["plan_id"] = "previous-run"
            (directory / "ordinary-1-1.report.json").write_text(json.dumps(report))
            with patch.dict("os.environ", {"GITHUB_STEP_SUMMARY": ""}):
                self.assertFalse(self.module.summarize(plan, directory))

    def test_summary_rejects_duplicate_invocation_reports_across_shard_artifacts(self):
        plan = self.module.make_plan(enumeration("AlasTests/A/a()"), [], 1)
        report = self.module.account(["AlasTests/A/a()"], results(("A/a()", "Passed")))
        report["plan_id"] = plan["id"]
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            self.module.write_json(directory / "shard-0/ordinary-1-1.report.json", report)
            with patch.dict("os.environ", {"GITHUB_STEP_SUMMARY": ""}):
                self.assertTrue(self.module.summarize(plan, directory))
                self.module.write_json(directory / "shard-1/ordinary-1-1.report.json", report)
                self.assertFalse(self.module.summarize(plan, directory))

    def test_missing_test_is_a_failure_even_when_other_tests_pass(self):
        report = self.module.account(["AlasTests/A/a()", "AlasTests/A/b()"],
                                     results(("A/a()", "Passed")))
        self.assertEqual(report["missing"], ["AlasTests/A/b()"])
        self.assertFalse(report["ok"])

    def test_runtime_skips_are_reported_separately_and_fail_ordinary_coverage(self):
        report = self.module.account(["AlasTests/A/a()", "AlasTests/A/b()"],
                                     results(("A/a()", "Passed"), ("A/b()", "Skipped")))
        self.assertEqual(report["executed"], 1)
        self.assertEqual(report["skipped"], 1)
        self.assertFalse(report["ok"])

    def test_parameter_arguments_do_not_inflate_definition_counts(self):
        document = results(("A/parameter(value:)", "Passed"))
        document["testNodes"][0]["children"][0]["children"] = [
            {"nodeType": "Arguments", "name": "one", "result": "Passed"},
            {"nodeType": "Arguments", "name": "two", "result": "Passed"}]
        report = self.module.account(["AlasTests/A/parameter(value:)"], document)
        self.assertTrue(report["ok"])
        self.assertEqual(report["executed"], 1)

    def test_unexpected_tests_and_unknown_outcomes_fail_closed(self):
        for document in [results(("A/a()", "Passed"), ("B/b()", "Passed")),
                         results(("A/a()", "Unknown")), results(("A/a()", "Failed"))]:
            with self.subTest(document=document):
                self.assertFalse(self.module.account(["AlasTests/A/a()"], document)["ok"])
        unknown = self.module.account(["AlasTests/A/a()"], results(("A/a()", "Unknown")))
        self.assertEqual(unknown["executed"], 0)

    def test_failed_invocation_does_not_prevent_later_chunks(self):
        ids = [f"AlasTests/S{i}/test()" for i in range(4)]
        policy = [(f"AlasTests/S{i}", "subprocess", "isolation", "#23") for i in range(4)]
        plan = self.module.make_plan(enumeration(*ids), policy, 1)
        first = results(("S0/test()", "Failed"), ("S1/test()", "Passed"), ("S2/test()", "Passed"))
        second = results(("S3/test()", "Passed"))
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            with patch.object(self.module, "bounded", side_effect=[65, 0]), patch.object(
                self.module.subprocess, "run", side_effect=[
                    subprocess.CompletedProcess([], 0, stdout=json.dumps(first)),
                    subprocess.CompletedProcess([], 0, stdout=json.dumps(second))]):
                self.assertFalse(self.module.run_batch(plan, directory, "subprocess", 0))
            first_report = json.loads((directory / "subprocess-1-1.report.json").read_text())
            second_report = json.loads((directory / "subprocess-1-2.report.json").read_text())
            self.assertEqual(first_report["failed"], ["AlasTests/S0/test()"])
            self.assertTrue(second_report["ok"])
            self.assertEqual(second_report["executed"], 1)

    def test_timeout_prints_test_progress_even_without_a_readable_result_bundle(self):
        plan = self.module.make_plan(enumeration("AlasTests/A/a()"), [], 1)
        def execute(command, log, timeout):
            log.write_text("old build noise\n" * 100 + "Test a() started.\n")
            return 124
        with tempfile.TemporaryDirectory() as directory:
            output = io.StringIO()
            with patch.object(self.module, "bounded", side_effect=execute), patch.object(
                    self.module.subprocess, "run", side_effect=subprocess.CalledProcessError(
                        64, ["xcresulttool"], stderr="missing Info.plist")), patch("sys.stdout", output):
                self.assertFalse(self.module.run_batch(plan, Path(directory), "ordinary", 0))
            self.assertIn("Test a() started.", output.getvalue())
            self.assertIn("Timed out after 360 seconds", output.getvalue())
            self.assertIn("AlasTests/A", output.getvalue())
            self.assertLess(output.getvalue().count("old build noise"), 100)


if __name__ == "__main__":
    unittest.main()
