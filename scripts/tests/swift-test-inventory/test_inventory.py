import importlib.util
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

    def test_plan_rejects_more_work_than_a_subprocess_step_can_finish(self):
        ids = [f"AlasTests/S{i}/test()" for i in range(16)]
        policy = [(f"AlasTests/S{i}", "slow-subprocess", "measured", "#23") for i in range(16)]
        with self.assertRaisesRegex(ValueError, "budget"):
            self.module.make_plan(enumeration(*ids), policy, 1)

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


if __name__ == "__main__":
    unittest.main()
