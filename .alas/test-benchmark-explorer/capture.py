from __future__ import annotations

import argparse
import ctypes
import ctypes.util
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import re
import select
import shutil
import signal
import socket
import stat
import struct
import subprocess
import sys
import tempfile
import threading
import time
import uuid
import xml.etree.ElementTree as ET

SCHEMA = 1
HELPER_VERSION = "1.0.0"
GENERATED = ".alas/test-benchmark-explorer"
MAX_DETAIL = 16 * 1024 * 1024
MAX_ROWS = 100000
MAX_PAGE = 64 * 1024
MAX_ARTIFACTS = 2000
MAX_BUNDLE = 128 * 1024 * 1024


def canonical(value):
    return json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(",", ":"), allow_nan=False)


def finite(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def number(value):
    try:
        result = float(value)
        return result if math.isfinite(result) and result >= 0 else None
    except (ValueError, TypeError):
        return None


def digest(data):
    return hashlib.sha256(data).hexdigest()


def path_parts(path):
    if not isinstance(path, str) or not path or len(path) > 4096 or "\x00" in path or "\\" in path:
        raise ValueError("Expected a nonempty relative path")
    parts = path.split("/")
    if any(p in ("", ".", "..") or p.casefold() == ".git" for p in parts):
        raise ValueError("Paths must stay inside the worktree and cannot include .git")
    return parts


def parent_fd(root, path, create=False):
    parts = path_parts(path)
    fd = os.open(str(root), os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        for part in parts[:-1]:
            if create:
                try:
                    os.mkdir(part, mode=0o700, dir_fd=fd)
                except FileExistsError:
                    pass
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = child
        return fd, parts[-1]
    except BaseException:
        os.close(fd)
        raise


def safe_read(root, path, limit=MAX_DETAIL):
    parent, name = parent_fd(root, path)
    try:
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
        try:
            before = os.fstat(fd)
            if not stat.S_ISREG(before.st_mode) or before.st_size > limit:
                raise ValueError("Artifact is not a regular file or exceeds the byte limit")
            with os.fdopen(fd, "rb", closefd=False) as stream:
                data = stream.read(limit + 1)
            after = os.fstat(fd)
            if len(data) > limit or (before.st_size, before.st_mtime_ns, before.st_ctime_ns) != (after.st_size, after.st_mtime_ns, after.st_ctime_ns):
                raise ValueError("Artifact changed while being read or exceeds the byte limit")
            return data
        finally:
            os.close(fd)
    finally:
        os.close(parent)


def safe_write(root, path, data):
    parent, name = parent_fd(root, path, create=True)
    temporary = "." + uuid.uuid4().hex + ".tmp"
    try:
        try:
            if stat.S_ISLNK(os.stat(name, dir_fd=parent, follow_symlinks=False).st_mode):
                raise ValueError("Refusing to replace a symlink")
        except FileNotFoundError:
            pass
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=parent)
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, name, src_dir_fd=parent, dst_dir_fd=parent)
    finally:
        try:
            os.unlink(temporary, dir_fd=parent)
        except FileNotFoundError:
            pass
        os.close(parent)


def safe_json(root, path):
    return json.loads(safe_read(root, path).decode("utf-8"))


def write_json(root, path, value):
    data = canonical(value).encode("utf-8")
    if len(data) > MAX_DETAIL:
        raise ValueError("Normalized result exceeds 16 MiB")
    safe_write(root, path, data)


def walk_files(root, path):
    """Enumerate regular files using held directory FDs, never following symlinks."""
    parent, name = parent_fd(root, path)
    found = []
    def visit(fd, relative):
        for entry in sorted(os.listdir(fd)):
            mode = os.stat(entry, dir_fd=fd, follow_symlinks=False).st_mode
            child_path = relative + "/" + entry
            if entry.casefold() == ".git" or stat.S_ISLNK(mode):
                raise ValueError("Report directories cannot contain symlinks or .git")
            if stat.S_ISDIR(mode):
                child = os.open(entry, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
                try:
                    visit(child, child_path)
                finally:
                    os.close(child)
            elif stat.S_ISREG(mode):
                found.append(child_path)
                if len(found) > MAX_ARTIFACTS:
                    raise ValueError("Report directory exceeds 2000 files")
            else:
                raise ValueError("Report directories cannot contain special files")
    try:
        fd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
        try:
            visit(fd, path)
        finally:
            os.close(fd)
    finally:
        os.close(parent)
    return found


def tool_output(argv, limit=MAX_DETAIL, timeout=60):
    """Drain to a bounded spool; terminate oversized output rather than allocating it."""
    with tempfile.TemporaryFile() as out, tempfile.TemporaryFile() as err:
        process = subprocess.Popen(argv, stdout=out, stderr=err)
        deadline = time.monotonic() + timeout
        while process.poll() is None:
            if time.monotonic() >= deadline or os.fstat(out.fileno()).st_size + os.fstat(err.fileno()).st_size > limit:
                process.kill()
                process.wait()
                raise ValueError("Importer tool timed out or exceeded its output limit")
            try:
                process.wait(timeout=0.05)
            except subprocess.TimeoutExpired:
                pass
        if os.fstat(out.fileno()).st_size + os.fstat(err.fileno()).st_size > limit:
            raise ValueError("Importer tool exceeded its output limit")
        out.seek(0)
        err.seek(0)
        if process.returncode:
            raise ValueError("Importer tool failed: " + err.read(4096).decode("utf-8", "replace"))
        return out.read(limit).decode("utf-8")


def location(value):
    if not isinstance(value, dict):
        return None
    path = value.get("filePath", value.get("file"))
    line = value.get("lineNumber", value.get("line"))
    if not isinstance(path, str) or not path:
        return None
    result = {"path": path}
    if number(line) is not None and float(line).is_integer() and float(line) > 0:
        result["line"] = int(line)
    return result


# Concatenated with common.py into the shipped, standalone capture.py.

def parse_junit(text, artifact):
    if re.search(r"<!\s*(DOCTYPE|ENTITY)\b", text, re.I):
        raise ValueError("JUnit DTDs and entity declarations are not supported")
    try:
        root = ET.fromstring(text)
    except ET.ParseError as error:
        raise ValueError("Malformed JUnit XML: " + str(error)) from error
    local = lambda element: element.tag.rsplit("}", 1)[-1]
    if local(root) not in ("testsuite", "testsuites"):
        raise ValueError("Expected a testsuite or testsuites JUnit root")
    rows = []
    def visit(element, ancestry):
        tag = local(element)
        if tag == "testsuite" and element.get("name"):
            ancestry = ancestry + [element.get("name")]
        if tag == "testcase":
            name = element.get("name")
            if not name:
                raise ValueError("JUnit testcase has no name")
            status = "passed"
            messages = []
            for child in element:
                kind = local(child)
                if kind in ("failure", "error", "skipped"):
                    if kind == "error" or status != "error" and kind == "failure":
                        status = "error" if kind == "error" else "failed"
                    elif kind == "skipped" and status == "passed":
                        status = "skipped"
                    messages.append("\n".join(filter(None, [child.get("type"), child.get("message"), "".join(child.itertext())])))
            index = len(rows)
            row = {"id": canonical(["junit", ancestry, element.get("classname"), name]),
                   "name": name, "suite": ancestry, "status": status,
                   "attempt": {"id": artifact + ":" + str(index), "ordered": False},
                   "evidence": {"artifact": artifact, "selector": "testcase[" + str(index) + "]"}}
            if element.get("classname"):
                row["classname"] = element.get("classname")
            duration = number(element.get("time"))
            if duration is not None:
                row["duration"] = duration
            source = location({"file": element.get("file"), "line": element.get("line")})
            if source:
                row["source"] = source
            if messages:
                row["failure"] = "\n\n".join(messages)
            rows.append(row)
            if len(rows) > MAX_ROWS:
                raise ValueError("JUnit exceeds 100,000 test attempts")
            return
        for child in element:
            visit(child, ancestry)
    visit(root, [])
    return rows


def measurement_key(row):
    return canonical([row["id"], row.get("parameters", {}), row["metric"], row["unit"],
                      row["direction"], row.get("statistic")])


def parse_benchmarks(text, artifact):
    document = json.loads(text)
    if not isinstance(document, dict) or document.get("format") != "alas-benchmarks" or document.get("version") != 1:
        raise ValueError("Expected alas-benchmarks version 1")
    measurements = document.get("measurements")
    if not isinstance(measurements, list) or len(measurements) > MAX_ROWS:
        raise ValueError("Expected at most 100,000 benchmark measurements")
    rows = []
    keys = set()
    for index, row in enumerate(measurements):
        if not isinstance(row, dict) or any(not isinstance(row.get(key), str) or not row[key] for key in ("id", "metric", "unit")):
            raise ValueError("Each benchmark needs an id, metric and unit")
        if not finite(row.get("value")) or row.get("direction") not in ("lower", "higher"):
            raise ValueError("A benchmark needs a finite value and lower/higher direction")
        if not isinstance(row.get("parameters", {}), dict):
            raise ValueError("Benchmark parameters must be a JSON object")
        if "statistic" in row and (not isinstance(row["statistic"], str) or not row["statistic"]):
            raise ValueError("Benchmark statistic must be a nonempty string when supplied")
        if "samples" in row and (not isinstance(row["samples"], list) or len(row["samples"]) > 10000 or not all(finite(v) for v in row["samples"])):
            raise ValueError("Benchmark samples must contain at most 10,000 finite numbers")
        canonical(row)  # Reject nonfinite values in nested parameters/metadata too.
        key = measurement_key(row)
        if key in keys:
            raise ValueError("Duplicate benchmark identity; supply one measurement with explicit samples/statistic")
        keys.add(key)
        result = {k: row[k] for k in ("id", "parameters", "metric", "value", "unit", "direction", "statistic", "samples", "summary") if k in row}
        if "conditions" in document:
            result["conditions"] = document["conditions"]
        result["evidence"] = {"artifact": artifact, "selector": "measurements[" + str(index) + "]"}
        rows.append(result)
    return rows


def parse_xcresult(tree, details, artifact):
    if not isinstance(tree, dict) or not isinstance(tree.get("testNodes"), list):
        raise ValueError("Unsupported xcresult tests schema")
    rows = []
    statuses = {"Passed": "passed", "Failed": "failed", "Skipped": "skipped", "Expected Failure": "passed"}
    def messages(node):
        found, source = [], None
        def descend(n):
            nonlocal source
            if n.get("nodeType") in ("Failure Message", "Skip Message", "Test Case Run") and n.get("name"):
                found.append(n["name"])
            source = source or location(n.get("sourceLocation"))
            for child in n.get("children", []):
                descend(child)
        descend(node)
        return "\n\n".join(dict.fromkeys(found)), source
    def emit(node, suite, case, suffix="", order=None, destination=None):
        identifier = case.get("nodeIdentifierURL", case.get("nodeIdentifier"))
        if not identifier:
            raise ValueError("xcresult test is missing its identifier")
        row = {"id": canonical(["xcresult", identifier, suffix, destination]), "name": case.get("name", identifier) + suffix,
               "suite": suite, "status": statuses.get(node.get("result", case.get("result")), "unknown"),
               "attempt": {"id": artifact + ":" + str(len(rows)), "ordered": order is not None},
               "evidence": {"artifact": artifact, "selector": identifier, "repetition": node.get("nodeIdentifier")}}
        if order is not None:
            row["attempt"]["order"] = order
        if destination:
            row["destination"] = destination
        duration = number(node.get("durationInSeconds"))
        if duration is not None:
            row["duration"] = duration
        failure, source = messages(node)
        if failure:
            row["failure"] = failure
        if source:
            row["source"] = source
        rows.append(row)
    def case_rows(case, suite, destination=None):
        detail = details.get(case.get("nodeIdentifierURL"), details.get(case.get("nodeIdentifier"), {}))
        root = dict(case)
        if detail.get("testRuns"):
            root["children"] = detail["testRuns"]
        execution_kinds = {"Device", "Test Plan Configuration", "Arguments", "Test Case Arguments", "Repetition"}
        def executions(node, suffix="", where=destination, order=None, identifier=None):
            kind = node.get("nodeType")
            identifier = node.get("nodeIdentifierURL", identifier)
            if kind == "Device":
                where = dict(where or {}, device=node.get("nodeIdentifier", node.get("name")))
            elif kind == "Test Plan Configuration":
                where = dict(where or {}, configuration=node.get("nodeIdentifier", node.get("name")))
            elif kind in ("Arguments", "Test Case Arguments"):
                suffix = " " + node.get("name", "unknown arguments")
            children = [c for c in node.get("children", []) if c.get("nodeType") in execution_kinds
                        and (c.get("nodeType") not in ("Arguments", "Test Case Arguments") or "result" in c or "nodeIdentifierURL" in c)]
            if children:
                for index, child in enumerate(children):
                    child_order = index if child.get("nodeType") == "Repetition" else order
                    executions(child, suffix, where, child_order, identifier)
            else:
                metadata = dict(case)
                if identifier:
                    metadata["nodeIdentifierURL"] = identifier
                emit(node, suite, metadata, suffix, order, where)
        executions(root)
    def visit(node, suite, destination=None):
        kind = node.get("nodeType")
        if kind == "Device":
            destination = dict(destination or {}, device=node.get("nodeIdentifier", node.get("name")))
        elif kind == "Test Plan Configuration":
            destination = dict(destination or {}, configuration=node.get("nodeIdentifier", node.get("name")))
        if kind == "Test Case":
            case_rows(node, suite, destination)
            return
        if kind in ("Test Suite", "Unit test bundle", "UI test bundle", "Test Plan"):
            suite = suite + [node.get("name", "Unknown suite")]
        for child in node.get("children", []):
            visit(child, suite, destination)
    for node in tree["testNodes"]:
        visit(node, [])
    if len(rows) > MAX_ROWS:
        raise ValueError("xcresult exceeds 100,000 test attempts")
    return rows


def xcresult_import(root, path):
    # Copy only regular files into a bounded snapshot so xcresulttool never follows
    # artifact symlinks or a concurrently replaced ancestor outside the worktree.
    files = walk_files(root, path)
    hasher, size = hashlib.sha256(), 0
    with tempfile.TemporaryDirectory(prefix="alas-xcresult-") as directory:
        bundle = Path(directory) / "Report.xcresult"
        bundle.mkdir()
        for file in files:
            data = safe_read(root, file, MAX_BUNDLE)
            size += len(data)
            if size > MAX_BUNDLE:
                raise ValueError("xcresult exceeds the 128 MiB bundle import limit")
            relative = file[len(path) + 1:]
            hasher.update(canonical([relative, digest(data)]).encode("utf-8"))
            destination = bundle / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(data)
        version = tool_output(["xcrun", "xcresulttool", "version"], 4096).strip()
        if "schema version: 0.4.0" not in version:
            raise ValueError("Unsupported xcresulttool schema; this importer requires schema 0.4.0. Tool: " + version)
        def query(kind, extra=None):
            return json.loads(tool_output(["xcrun", "xcresulttool", "get", "test-results", kind,
                                          "--schema-version", "0.4.0", "--path", str(bundle), "--compact"] + (extra or [])))
        summary, tree = query("summary"), query("tests")
        preliminary = parse_xcresult(tree, {}, "pending")
        details = {}
        # Detail queries are necessary only when the tree did not contain failure evidence.
        for row in preliminary:
            selector = row["evidence"]["selector"]
            if row["status"] in ("failed", "unknown") and not row.get("source") and selector not in details:
                if len(details) >= 100:
                    raise ValueError("xcresult needs more than 100 detail queries; import is incomplete")
                details[selector] = query("test-details", ["--test-id", selector])
        return hasher.hexdigest(), tree, details, summary, version


def import_artifacts(root, specs):
    root = Path(root)
    result = {"schema": SCHEMA, "complete": True, "tests": [], "benchmarks": [], "artifacts": [], "issues": []}
    seen = set()
    if not specs:
        result["complete"] = False
        result["issues"].append({"message": "No artifacts configured"})
    expanded = []
    for spec in specs:
        try:
            path, kind = spec["path"], spec["format"]
            path_parts(path)
            if kind not in ("junit", "benchmark", "xcresult"):
                raise ValueError("Unknown artifact format")
            if spec.get("directory") and kind != "xcresult":
                paths = [p for p in walk_files(root, path) if p.endswith(".xml" if kind == "junit" else ".json")]
                if not paths:
                    raise ValueError("Configured report directory contains no matching artifacts")
                expanded.extend({"path": p, "format": kind} for p in paths)
            else:
                expanded.append({"path": path, "format": kind})
        except (ValueError, OSError, KeyError) as error:
            result["complete"] = False
            result["issues"].append({"path": spec.get("path"), "message": str(error)})
    for spec in expanded:
        path, kind = spec["path"], spec["format"]
        if path in seen:
            continue
        seen.add(path)
        try:
            if len(seen) > MAX_ARTIFACTS:
                raise ValueError("Import exceeds 2000 artifacts")
            if kind == "xcresult":
                checksum, tree, details, summary, version = xcresult_import(root, path)
            else:
                data = safe_read(root, path)
                checksum = digest(data)
            identity = digest(canonical([path, checksum]).encode("utf-8"))
            artifact = {"id": identity, "path": path, "digest": checksum, "format": kind,
                        "importer": kind, "version": HELPER_VERSION, "available": True}
            result["artifacts"].append(artifact)
            if kind == "xcresult":
                artifact["toolVersion"] = version
                artifact["originalSummary"] = summary
                rows = parse_xcresult(tree, details, identity)
                result["tests"].extend(rows)
            else:
                text = data.decode("utf-8-sig")
                rows = parse_junit(text, identity) if kind == "junit" else parse_benchmarks(text, identity)
                result["tests" if kind == "junit" else "benchmarks"].extend(rows)
            if len(result["tests"]) + len(result["benchmarks"]) > MAX_ROWS or len(canonical(result).encode("utf-8")) > MAX_DETAIL:
                raise ValueError("Normalized capture exceeds 16 MiB or 100,000 rows")
        except (ValueError, OSError, UnicodeError, RecursionError) as error:
            result["complete"] = False
            result["issues"].append({"path": path, "message": str(error)[:4096]})
            # Never retain an over-budget partially appended artifact as a complete result.
            while len(result["tests"]) + len(result["benchmarks"]) > MAX_ROWS or len(canonical(result).encode("utf-8")) > MAX_DETAIL - 8192:
                rows = result["tests"] or result["benchmarks"]
                if not rows:
                    break
                del rows[max(0, len(rows) - max(1, len(rows) // 4)):]
    if any(row.get("status") == "unknown" for row in result["tests"]):
        result["complete"] = False
        result["issues"].append({"message": "Some test outcomes are unknown"})
    return result


# Pure normalized-model operations, also used by the on-host bridge.

def logical_tests(result):
    groups = {}
    for row in result.get("tests", []):
        groups.setdefault(row["id"], []).append(row)
    output = {}
    for key, attempts in groups.items():
        ordered = all(a.get("attempt", {}).get("ordered") and "order" in a["attempt"] for a in attempts)
        if ordered and len({a["attempt"]["order"] for a in attempts}) == len(attempts):
            status = max(attempts, key=lambda a: a["attempt"]["order"])["status"]
        else:
            status = next((s for s in ("error", "failed", "unknown", "passed", "skipped") if any(a["status"] == s for a in attempts)), "unknown")
        logical = {"id": key, "name": attempts[0]["name"], "suite": attempts[0].get("suite", []),
                   "status": status, "attempts": len(attempts)}
        if all(finite(a.get("duration")) for a in attempts):
            logical["duration"] = sum(a["duration"] for a in attempts)
        output[key] = logical
    return output


def result_counts(result):
    tests = logical_tests(result)
    counts = {status: sum(row["status"] == status for row in tests.values()) for status in ("passed", "failed", "error", "skipped", "unknown")}
    counts.update(tests=len(tests), attempts=len(result.get("tests", [])), benchmarks=len(result.get("benchmarks", [])))
    counts["state"] = "incomplete" if not result.get("complete") else "failed" if counts["failed"] + counts["error"] else "unknown" if counts["unknown"] else "passed" if counts["passed"] else "no tests"
    return counts


def compare_results(base, current):
    before, after = logical_tests(base), logical_tests(current)
    tests = []
    failed = lambda row: row["status"] in ("failed", "error")
    for key in sorted(before.keys() | after.keys()):
        b, c = before.get(key), after.get(key)
        change = "unchanged"
        if b is None:
            change = "added" if base.get("complete") else "unknown"
        elif c is None:
            change = "removed" if current.get("complete") else "unknown"
        elif not base.get("complete") or not current.get("complete"):
            change = "unknown"
        elif failed(b) and c["status"] == "passed":
            change = "recovered"
        elif b["status"] == "passed" and failed(c):
            change = "newly failing"
        row = {"id": key, "name": (c or b)["name"], "change": change,
               "baseline": b, "current": c}
        if base.get("complete") and current.get("complete") and b and c and finite(b.get("duration")) and finite(c.get("duration")):
            row["durationDelta"] = c["duration"] - b["duration"]
        tests.append(row)
    bg, cg = {}, {}
    for result, groups in ((base, bg), (current, cg)):
        for measurement in result.get("benchmarks", []):
            groups.setdefault(measurement_key(measurement), []).append(measurement)
    benchmarks = []
    for key in sorted(bg.keys() | cg.keys()):
        bs, cs = bg.get(key, []), cg.get(key, [])
        b, c = bs[0] if bs else None, cs[0] if cs else None
        example = c or b
        row = {"key": key, "id": example["id"], "parameters": example.get("parameters", {}), "metric": example["metric"],
               "unit": example["unit"], "direction": example["direction"], "statistic": example.get("statistic"),
               "baseline": b["value"] if b else None, "current": c["value"] if c else None,
               "compatible": False, "significance": "not assessed",
               "baselineSamples": b.get("samples") if b else None, "currentSamples": c.get("samples") if c else None}
        bc, cc = (b or {}).get("conditions", base.get("conditions", {})), (c or {}).get("conditions", current.get("conditions", {}))
        row["conditions"] = {"baseline": bc, "current": cc}
        if not b or not c:
            row["reason"] = "No matching measurement with the same parameters, metric, unit, direction and statistic"
        elif len(bs) != 1 or len(cs) != 1:
            row["reason"] = "Multiple measurements have this identity; no unambiguous pairing"
        elif not base.get("complete") or not current.get("complete"):
            row["reason"] = "An import is incomplete"
        else:
            different = [field for field in ("host", "toolchain", "configuration", "target") if not bc.get(field) or not cc.get(field) or bc[field] != cc[field]]
            if different:
                row["reason"] = "Different or unknown execution conditions: " + ", ".join(different)
            else:
                row["compatible"] = True
                absolute = c["value"] - b["value"]
                row["absolute"] = absolute if finite(absolute) else None
                percent = absolute / abs(b["value"]) * 100 if b["value"] else None
                row["percent"] = percent if finite(percent) else None
                if not finite(absolute):
                    row["reason"] = "Difference exceeds the finite numeric range; raw measurements are preserved"
                threshold = current.get("thresholds", {}).get(example["id"])
                if finite(threshold) and threshold >= 0 and row["percent"] is not None:
                    row["threshold"] = threshold
                    row["regression"] = row["percent"] * (1 if example["direction"] == "lower" else -1) > threshold
        benchmarks.append(row)
    return {"tests": tests, "benchmarks": benchmarks}


def bounded_page(rows, offset=0, limit=100):
    offset = max(0, int(offset))
    limit = min(100, max(1, int(limit)))
    page, size = [], 0
    for row in rows[offset:offset + limit]:
        # Long evidence text is available separately, not silently erased in storage.
        display = dict(row)
        for key, count_key in (("samples", "sampleCount"), ("baselineSamples", "baselineSampleCount"), ("currentSamples", "currentSampleCount")):
            if isinstance(display.get(key), list):
                display[count_key] = len(display[key])
                if len(display[key]) > 10:
                    display[key] = display[key][:10]
                    display["sampleDataTruncated"] = True
        for key in ("failure", "name", "id"):
            if isinstance(display.get(key), str) and len(display[key]) > 4096:
                display[key] = display[key][:4096]
                display["textTruncated"] = True
        encoded = len(canonical(display).encode("utf-8"))
        if encoded > MAX_PAGE - 8192:
            display = {"id": str(row.get("id", ""))[:1024], "name": str(row.get("name", row.get("id", "")))[:1024],
                       "rowIndex": row.get("rowIndex"), "evidenceTooLarge": True, "message": "Use the evidence text view to inspect this row"}
            for key in ("value", "unit", "direction", "statistic", "sampleCount"):
                if key in row:
                    display[key] = row[key] if finite(row[key]) else str(row[key])[:512]
            encoded = len(canonical(display).encode("utf-8"))
        if size + encoded > MAX_PAGE - 8192:
            break
        page.append(display)
        size += encoded
    end = offset + len(page)
    return {"rows": page, "total": len(rows), "offset": offset, "next": end if end < len(rows) else None}


def query_result(result, request):
    kind = request.get("kind", "tests")
    rows = result.get("benchmarks" if kind == "benchmarks" else "tests", [])
    search, status = str(request.get("search", "")).casefold(), request.get("status", "all") if kind == "tests" else "all"
    filtered = [dict(row, rowIndex=index) for index, row in enumerate(rows)
                if (not search or search in (str(row.get("name", row.get("id"))) + " " + " / ".join(row.get("suite", []))).casefold())
                and (status == "all" or row.get("status") == status)]
    return bounded_page(filtered, request.get("offset", 0))


def investigation_brief(result, selected=None, comparison=None, selected_benchmarks=None):
    lines = ["Test & Benchmark investigation", "Capture: " + result.get("id", "unknown"),
             "Run: " + (result.get("run") or "unassociated"), "Worktree: " + result.get("worktree", "unknown"),
             "Host: " + result.get("host", "unknown"), "Captured: " + str(result.get("capturedAt", "unknown")),
             "Source: " + canonical(result.get("source", {})), "Command: " + canonical(result.get("command", {})),
             "Conditions: " + canonical(result.get("conditions", {})), "Import complete: " + str(result.get("complete", False))]
    selected = set(selected or [])
    benchmarks = set(selected_benchmarks or [])
    explicit = bool(selected or benchmarks)
    evidence_ids, test_ids, benchmark_keys = set(), set(), set()
    for index, row in enumerate(result.get("tests", [])):
        if explicit and index not in selected or not explicit and row["status"] not in ("failed", "error"):
            continue
        evidence_ids.add(row.get("evidence", {}).get("artifact"))
        test_ids.add(row["id"])
        lines += ["", row["status"] + ": " + row["name"], str(row.get("failure", "")),
                  "Location: " + canonical(row.get("source")), "Evidence: " + canonical(row.get("evidence"))]
    for index, row in enumerate(result.get("benchmarks", [])):
        if explicit and index not in benchmarks:
            continue
        evidence_ids.add(row.get("evidence", {}).get("artifact"))
        benchmark_keys.add(measurement_key(row))
        lines += ["", "Measurement: " + canonical(row)]
    if comparison:
        if explicit:
            comparison = {"tests": [row for row in comparison["tests"] if row["id"] in test_ids],
                          "benchmarks": [row for row in comparison["benchmarks"] if row["key"] in benchmark_keys]}
        lines += ["", "Comparison: " + canonical(comparison), "Statistical significance has not been assessed."]
    for artifact in result.get("artifacts", []):
        if not explicit or artifact["id"] in evidence_ids:
            lines.append("Artifact: " + canonical(artifact))
    for issue in result.get("issues", []):
        lines.append("Import issue: " + canonical(issue))
    text = "\n".join(lines).encode("utf-8")
    return text[:48000].decode("utf-8", "ignore") + ("\n[Brief truncated; inspect the retained evidence for the remainder.]" if len(text) > 48000 else "")


def git_output(root, args, binary=False):
    env = dict(os.environ, GIT_OPTIONAL_LOCKS="0", GIT_TERMINAL_PROMPT="0")
    result = subprocess.run(["git", "-C", str(root)] + args, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, env=env, timeout=30)
    if result.returncode or len(result.stdout) > MAX_DETAIL:
        raise ValueError("Could not capture git source state: " + result.stderr[:1024].decode("utf-8", "replace"))
    return result.stdout if binary else result.stdout.decode("utf-8").strip()


def source_listing(root):
    index = git_output(root, ["ls-files", "--stage", "-z"], binary=True)
    staged = []
    for entry in index.split(b"\0"):
        if entry:
            metadata, path = entry.split(b"\t", 1)
            name = os.fsdecode(path)
            if name == GENERATED or name.startswith(GENERATED + "/"):
                continue
            mode = metadata.split(b" ", 1)[0]
            if mode == b"160000":
                raise ValueError("Submodule source capture is not supported; provenance remains unknown")
            staged.append((name, metadata.decode("ascii")))
    untracked = [os.fsdecode(path) for path in git_output(root, ["ls-files", "--others", "--exclude-standard", "-z"], binary=True).split(b"\0") if path]
    untracked = [p for p in untracked if p != GENERATED and not p.startswith(GENERATED + "/")]
    paths = sorted(set([p for p, _ in staged] + untracked))
    if len(paths) > MAX_ROWS:
        raise ValueError("Source capture exceeds 100,000 files")
    return staged, paths


def fingerprint(root):
    root = Path(root).resolve()
    try:
        repository = git_output(root, ["rev-parse", "--path-format=absolute", "--git-common-dir"])
        git_dir = git_output(root, ["rev-parse", "--absolute-git-dir"])
        top = git_output(root, ["rev-parse", "--show-toplevel"])
        if Path(top).resolve() != root:
            raise ValueError("Capture requires a project rooted at its git worktree; nested project roots remain unknown")
        head = git_output(root, ["rev-parse", "--verify", "HEAD"])
        staged, paths = source_listing(root)
        hasher = hashlib.sha256(canonical([str(root), repository, head, staged]).encode("utf-8"))
        states = {}
        for path in paths:
            parent, name = parent_fd(root, path)
            try:
                try:
                    before = os.stat(name, dir_fd=parent, follow_symlinks=False)
                except FileNotFoundError:
                    states[path] = None
                    hasher.update(canonical([path, "deleted"]).encode("utf-8"))
                    continue
                if stat.S_ISLNK(before.st_mode):
                    contents = os.fsencode(os.readlink(name, dir_fd=parent))
                elif stat.S_ISREG(before.st_mode):
                    contents = safe_read(root, path, 64 * 1024 * 1024)
                else:
                    raise ValueError("Source contains an unsupported special file")
                states[path] = (before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns, before.st_mode)
                hasher.update(canonical([path, stat.S_IMODE(before.st_mode), digest(contents)]).encode("utf-8"))
            finally:
                os.close(parent)
        if git_output(root, ["rev-parse", "--verify", "HEAD"]) != head or source_listing(root) != (staged, paths):
            raise ValueError("Git state changed while capturing source")
        for path, before in states.items():
            try:
                after = os.lstat(root / path)
                after = (after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns, after.st_mode)
            except FileNotFoundError:
                after = None
            if after != before:
                raise ValueError("Source changed while capturing its fingerprint")
        return {"known": True, "digest": hasher.hexdigest(), "head": head, "repository": repository,
                "root": str(root), "gitDir": git_dir, "files": len(paths), "capturedAt": time.time(),
                "exclusions": [GENERATED, "nontracked gitignored files"]}
    except (ValueError, OSError, UnicodeError, subprocess.SubprocessError) as error:
        return {"known": False, "reason": str(error), "capturedAt": time.time()}


def source_freshness(root, source, current=None):
    checked = time.time()
    before, after = source.get("before", {}), source.get("after", {})
    observation = source.get("observation", {})
    if not before.get("known") or not after.get("known") or not observation.get("supported") or observation.get("reason"):
        return {"state": "unknown", "reason": source.get("reason") or observation.get("reason") or before.get("reason") or after.get("reason") or "No trustworthy source capture", "checkedAt": checked}
    if observation.get("changed") or before["digest"] != after["digest"]:
        return {"state": "changed during run", "reason": "Source changed during the enclosing capture interval", "checkedAt": checked}
    current = fingerprint(root) if current is None else current
    if not current.get("known"):
        return {"state": "unknown", "reason": current.get("reason"), "checkedAt": checked}
    return {"state": "current" if current["digest"] == after["digest"] else "stale", "head": before.get("head"), "checkedAt": checked}


def event_relevant(root, path, git_dirs):
    absolute = os.path.abspath(path)
    for directory in sorted(git_dirs, key=len, reverse=True):
        if absolute == directory or absolute.startswith(directory + os.sep):
            relative = os.path.relpath(absolute, directory)
            return relative in ("HEAD", "index", "packed-refs", "config") or relative.startswith("refs/")
    try:
        relative = str(Path(absolute).relative_to(root))
    except ValueError:
        return False
    if relative == ".":
        return False  # Root metadata is not a tracked input; per-file events are required.
    if relative == GENERATED or relative.startswith(GENERATED + "/") or relative == ".git" or relative.startswith(".git/"):
        return False
    result = subprocess.run(["git", "-C", str(root), "check-ignore", "-q", "--", relative],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                            env=dict(os.environ, GIT_OPTIONAL_LOCKS="0"), timeout=10)
    if result.returncode not in (0, 1):
        raise ValueError("Could not classify source observation against gitignore")
    return result.returncode == 1


class UnknownObserver:
    def __init__(self, reason):
        self.reason = reason

    def finish(self):
        return {"supported": False, "changed": False, "reason": self.reason}


class MacObserver:
    """FSEvents with a running CFRunLoop and synchronous delivery barriers."""
    def __init__(self, root, git_dirs):
        self.root, self.git_dirs = root, git_dirs
        self.paths, self.reason = set(), None
        self.ready, self.stop = threading.Event(), threading.Event()
        self.stream = None
        self.cf = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
        self.fs = ctypes.CDLL("/System/Library/Frameworks/CoreServices.framework/CoreServices")
        ptr = ctypes.c_void_p
        self.cf.CFStringCreateWithCString.argtypes = [ptr, ctypes.c_char_p, ctypes.c_uint32]
        self.cf.CFStringCreateWithCString.restype = ptr
        self.cf.CFArrayCreate.argtypes = [ptr, ctypes.POINTER(ptr), ctypes.c_long, ptr]
        self.cf.CFArrayCreate.restype = ptr
        self.cf.CFRelease.argtypes = [ptr]
        self.cf.CFRunLoopGetCurrent.restype = ptr
        self.cf.CFRunLoopRunInMode.argtypes = [ptr, ctypes.c_double, ctypes.c_ubyte]
        self.cf.CFRunLoopRunInMode.restype = ctypes.c_int32
        self.mode = ptr.in_dll(self.cf, "kCFRunLoopDefaultMode")
        callback_type = ctypes.CFUNCTYPE(None, ptr, ptr, ctypes.c_size_t, ptr,
                                         ctypes.POINTER(ctypes.c_uint32), ctypes.POINTER(ctypes.c_uint64))
        def receive(stream, context, count, paths, flags, ids):
            try:
                names = ctypes.cast(paths, ctypes.POINTER(ctypes.c_char_p))
                for index in range(count):
                    flag = flags[index]
                    if flag & (0x1 | 0x2 | 0x4 | 0x8 | 0x20 | 0x40 | 0x80):
                        self.reason = "FSEvents lost coverage, changed roots or requires a rescan"
                    if flag & (0x100 | 0x200 | 0x400 | 0x800 | 0x1000 | 0x2000 | 0x4000 | 0x8000 | 0x400000):
                        self.paths.add(os.fsdecode(names[index]))
                    if len(self.paths) > 10000:
                        self.reason = "Source observation exceeded 10,000 paths"
            except BaseException as error:
                self.reason = "FSEvents callback could not classify an event: " + str(error)
        self.callback = callback_type(receive)
        self.fs.FSEventStreamCreate.argtypes = [ptr, callback_type, ptr, ptr, ctypes.c_uint64, ctypes.c_double, ctypes.c_uint32]
        self.fs.FSEventStreamCreate.restype = ptr
        self.fs.FSEventStreamScheduleWithRunLoop.argtypes = [ptr, ptr, ptr]
        self.fs.FSEventStreamStart.argtypes = [ptr]
        self.fs.FSEventStreamStart.restype = ctypes.c_ubyte
        for name in ("FSEventStreamFlushSync", "FSEventStreamStop", "FSEventStreamInvalidate", "FSEventStreamRelease"):
            getattr(self.fs, name).argtypes = [ptr]
        def run():
            strings, array = [], None
            try:
                strings = [self.cf.CFStringCreateWithCString(None, os.fsencode(p), 0x08000100) for p in sorted(set([str(root)] + git_dirs))]
                array = self.cf.CFArrayCreate(None, (ptr * len(strings))(*strings), len(strings), None)
                self.stream = self.fs.FSEventStreamCreate(None, self.callback, None, array, 0xFFFFFFFFFFFFFFFF, 0.01, 0x10 | 0x4 | 0x2)
                if not self.stream:
                    raise ValueError("Could not create FSEvents stream")
                self.fs.FSEventStreamScheduleWithRunLoop(self.stream, self.cf.CFRunLoopGetCurrent(), self.mode)
                if not self.fs.FSEventStreamStart(self.stream):
                    raise ValueError("Could not start FSEvents stream")
                self.ready.set()
                while not self.stop.is_set():
                    self.cf.CFRunLoopRunInMode(self.mode, 0.05, False)
            except BaseException as error:
                self.reason = "FSEvents unavailable: " + str(error)
                self.ready.set()
            finally:
                if self.stream:
                    self.fs.FSEventStreamStop(self.stream)
                    self.fs.FSEventStreamInvalidate(self.stream)
                    self.fs.FSEventStreamRelease(self.stream)
                if array:
                    self.cf.CFRelease(array)
                for item in strings:
                    if item:
                        self.cf.CFRelease(item)
        self.thread = threading.Thread(target=run, daemon=True)
        self.thread.start()
        if not self.ready.wait(5):
            self.reason = "FSEvents did not establish coverage before execution"
        if not self.reason:
            self.fs.FSEventStreamFlushSync(self.stream)
            self.paths.clear()

    def finish(self):
        if self.stream and self.thread.is_alive():
            self.fs.FSEventStreamFlushSync(self.stream)
        self.stop.set()
        self.thread.join(5)
        if self.thread.is_alive():
            self.reason = "FSEvents drain did not finish"
        try:
            changed = any(event_relevant(self.root, p, self.git_dirs) for p in self.paths)
        except (ValueError, OSError, subprocess.SubprocessError) as error:
            self.reason, changed = str(error), False
        return {"supported": self.reason is None, "changed": changed,
                "reason": self.reason, "mechanism": "FSEvents", "observedPaths": len(self.paths)}


class LinuxObserver:
    def __init__(self, root, git_dirs):
        self.root, self.git_dirs, self.paths, self.reason = root, git_dirs, {}, None
        self.libc = ctypes.CDLL(None, use_errno=True)
        self.libc.inotify_init1.argtypes = [ctypes.c_int]
        self.libc.inotify_init1.restype = ctypes.c_int
        self.libc.inotify_add_watch.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_uint32]
        self.libc.inotify_add_watch.restype = ctypes.c_int
        self.fd = self.libc.inotify_init1(os.O_NONBLOCK | os.O_CLOEXEC)
        if self.fd < 0:
            raise OSError(ctypes.get_errno(), "Could not start inotify")
        try:
            for base in sorted(set([str(root)] + git_dirs)):
                for directory, dirs, files in os.walk(base, followlinks=False):
                    dirs[:] = [d for d in dirs if not os.path.islink(os.path.join(directory, d))
                               and (base in git_dirs or event_relevant(root, os.path.join(directory, d), git_dirs))]
                    watch = self.libc.inotify_add_watch(self.fd, os.fsencode(directory), 0x2 | 0x4 | 0x8 | 0x40 | 0x80 | 0x100 | 0x200 | 0x400 | 0x800 | 0x2000000)
                    if watch < 0:
                        raise OSError(ctypes.get_errno(), "Could not register complete inotify coverage")
                    self.paths[watch] = directory
                    if len(self.paths) > 20000:
                        raise ValueError("Source observer exceeds 20,000 directories")
        except BaseException:
            os.close(self.fd)
            raise

    def finish(self):
        changed, events = False, 0
        try:
            while True:
                try:
                    data = os.read(self.fd, 256 * 1024)
                except BlockingIOError:
                    break  # Kernel read barrier after the second source fingerprint.
                if not data:
                    break
                offset = 0
                while offset < len(data):
                    watch, mask, cookie, size = struct.unpack_from("iIII", data, offset)
                    name = os.fsdecode(data[offset + 16:offset + 16 + size].split(b"\0", 1)[0])
                    offset += 16 + size
                    events += 1
                    if mask & (0x4000 | 0x8000 | 0x400 | 0x800) or watch not in self.paths:
                        self.reason = "inotify lost coverage or its watched root changed"
                    else:
                        path = os.path.join(self.paths[watch], name)
                        if event_relevant(self.root, path, self.git_dirs):
                            changed = True
                    if events > 10000:
                        raise ValueError("Source observation exceeded 10,000 events")
        except (ValueError, OSError, subprocess.SubprocessError) as error:
            self.reason = str(error)
        finally:
            os.close(self.fd)
        return {"supported": self.reason is None, "changed": changed, "reason": self.reason,
                "mechanism": "inotify", "observedEvents": events}


def mac_filesystem_type(path):
    # Darwin stat(1) %T is a file type marker, unlike GNU stat -f %T.
    # Match the public statfs64 layout in sys/mount.h instead.
    class StatFS(ctypes.Structure):
        _fields_ = [("bsize", ctypes.c_uint32), ("iosize", ctypes.c_int32),
                    ("blocks", ctypes.c_uint64), ("bfree", ctypes.c_uint64), ("bavail", ctypes.c_uint64),
                    ("files", ctypes.c_uint64), ("ffree", ctypes.c_uint64), ("fsid", ctypes.c_int32 * 2),
                    ("owner", ctypes.c_uint32), ("type", ctypes.c_uint32), ("flags", ctypes.c_uint32),
                    ("subtype", ctypes.c_uint32), ("name", ctypes.c_char * 16),
                    ("mount", ctypes.c_char * 1024), ("from_name", ctypes.c_char * 1024),
                    ("flags_ext", ctypes.c_uint32), ("reserved", ctypes.c_uint32 * 7)]
    libc = ctypes.CDLL(None, use_errno=True)
    function = getattr(libc, "statfs64", libc.statfs)
    function.argtypes = [ctypes.c_char_p, ctypes.POINTER(StatFS)]
    function.restype = ctypes.c_int
    value = StatFS()
    if function(os.fsencode(path), ctypes.byref(value)) != 0:
        raise OSError(ctypes.get_errno(), "Could not inspect the source filesystem")
    return value.name.decode("ascii") if value.flags & 0x1000 else "network filesystem"


def source_observer(root):
    try:
        root = Path(root).resolve()
        git_dirs = sorted(set([git_output(root, ["rev-parse", "--absolute-git-dir"]),
                               git_output(root, ["rev-parse", "--path-format=absolute", "--git-common-dir"])]))
        if sys.platform == "darwin":
            if any(mac_filesystem_type(path) != "apfs" for path in [root] + git_dirs):
                return UnknownObserver("Source observation is verified only on local APFS on macOS")
            return MacObserver(root, git_dirs)
        if sys.platform.startswith("linux"):
            filesystem = tool_output(["stat", "-f", "-c", "%T", str(root)], 4096).strip()
            if filesystem not in ("ext2/ext3", "ext4", "xfs"):
                return UnknownObserver("Source observation is unverified on filesystem " + filesystem)
            return LinuxObserver(root, git_dirs)
        return UnknownObserver("This operating system has no supported source observer")
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        return UnknownObserver(str(error))


def validate_config(value):
    if not isinstance(value, dict) or not isinstance(value.get("profiles"), list) or len(value["profiles"]) > 16:
        raise ValueError("Configuration needs profiles, at most 16")
    if len(canonical(value).encode("utf-8")) > 16384:
        raise ValueError("Configuration exceeds 16 KiB")
    seen = set()
    for profile in value["profiles"]:
        if not isinstance(profile, dict) or not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,31}", str(profile.get("id", ""))):
            raise ValueError("Profile IDs use 1–32 lowercase letters, numbers or hyphens")
        if profile["id"] in seen or not isinstance(profile.get("script"), str) or not profile["script"] or len(profile["script"]) > 1024:
            raise ValueError("Profiles need unique IDs and a run-script key")
        seen.add(profile["id"])
        for field in ("toolchain", "configuration", "target"):
            if field in profile and (not isinstance(profile[field], str) or len(profile[field]) > 512):
                raise ValueError("Profile condition labels must be strings up to 512 characters")
        artifacts = profile.get("artifacts")
        if not isinstance(artifacts, list) or not 1 <= len(artifacts) <= 16:
            raise ValueError("Each profile needs 1–16 artifact declarations")
        for artifact in artifacts:
            path_parts(artifact["path"])
            if artifact.get("format") not in ("junit", "benchmark", "xcresult"):
                raise ValueError("Unknown artifact format")
        thresholds = profile.get("thresholds", {})
        if not isinstance(thresholds, dict) or any(not finite(v) or v < 0 for v in thresholds.values()):
            raise ValueError("Regression thresholds must be nonnegative finite percentages")
    return value


def installation(root, identity):
    value = safe_json(root, GENERATED + "/installation.json")
    for field in ("project", "worktree", "hostKey"):
        if value.get(field) != identity.get(field):
            raise ValueError("Capture belongs to another " + field)
    if value.get("root") != str(Path(root).resolve()):
        raise ValueError("Worktree moved; reinstall the capture wrapper before running it")
    return value


def install_helper(root, identity, config, program):
    root = Path(root).resolve()
    validate_config(config)
    for field in ("project", "worktree", "hostKey"):
        if not isinstance(identity.get(field), str) or not identity[field] or len(identity[field]) > 4096:
            raise ValueError("Missing installation " + field)
    try:
        old = installation(root, identity)
    except (ValueError, OSError):
        old = {}
    value = {**identity, "root": str(root), "token": old.get("token", uuid.uuid4().hex),
             "helperVersion": HELPER_VERSION, "helperDigest": digest(program.encode("utf-8"))}
    safe_write(root, GENERATED + "/capture.py", program.encode("utf-8"))
    write_json(root, GENERATED + "/configuration.json", config)
    write_json(root, GENERATED + "/installation.json", value)
    return {"installed": True, "path": GENERATED + "/capture.py", "helperVersion": HELPER_VERSION}


def capture_key(value):
    if not isinstance(value, str) or not re.fullmatch(r"[a-f0-9]{32}|[a-f0-9]{64}", value):
        raise ValueError("Invalid capture identity")
    return value


def run_key(value):
    try:
        return str(uuid.UUID(value))
    except (ValueError, TypeError, AttributeError) as error:
        raise ValueError("Expected an Alas run UUID") from error


def summarize_result(result):
    source = result.get("source", {})
    summary = {key: result.get(key) for key in ("id", "schema", "project", "worktree", "hostKey", "host", "run", "script", "capturedAt", "conditions", "complete")}
    command = result.get("command", {})
    summary["command"] = {"outcome": command.get("outcome", "unknown"), "exit": command.get("exit"),
                          "argv": [str(a)[:256] for a in command.get("argv", [])[:8]],
                          "truncated": len(command.get("argv", [])) > 8 or any(len(str(a)) > 256 for a in command.get("argv", [])),
                          "startedAt": command.get("startedAt"), "endedAt": command.get("endedAt")}
    if command.get("hostOutcome"):
        summary["command"]["outcome"] = command["hostOutcome"]
    summary["counts"] = result_counts(result)
    summary["source"] = {"state": source.get("state", "unknown"), "reason": str(source.get("reason", ""))[:1024],
                         "head": source.get("before", {}).get("head"), "checkedAt": source.get("checkedAt")}
    summary["sourceEvidence"] = {point: {key: source.get(point, {}).get(key) for key in ("known", "digest", "head", "reason")} for point in ("before", "after")}
    summary["sourceEvidence"]["observation"] = {key: source.get("observation", {}).get(key) for key in ("supported", "changed", "reason")}
    summary["detail"] = "available"
    summary["issues"] = [{"message": str(i.get("message", ""))[:512], "path": str(i.get("path", ""))[:256]} for i in result.get("issues", [])[:8]]
    summary["artifacts"] = [{k: str(a.get(k, ""))[:512] for k in ("id", "path", "digest", "format")} for a in result.get("artifacts", [])[:4]]
    summary["artifactCount"] = len(result.get("artifacts", []))
    return summary


def persist_result(root, result):
    key = capture_key(result["id"])
    write_json(root, GENERATED + "/results/" + key + ".json", result)
    summary = summarize_result(result)
    write_json(root, GENERATED + "/summaries/" + key + ".json", summary)
    return summary


def validate_result(result, identity):
    if not isinstance(result, dict) or result.get("schema") != SCHEMA:
        raise ValueError("Unsupported normalized result model")
    for field in ("project", "worktree", "hostKey"):
        if result.get(field) != identity.get(field):
            raise ValueError("Result belongs to another " + field)
    if not isinstance(result.get("tests"), list) or not isinstance(result.get("benchmarks"), list):
        raise ValueError("Normalized detail is malformed")
    if len(result["tests"]) + len(result["benchmarks"]) > MAX_ROWS:
        raise ValueError("Normalized result exceeds its row budget")
    capture_key(result.get("id"))
    return result


def load_result(root, identity, capture):
    result = validate_result(safe_json(root, GENERATED + "/results/" + capture_key(capture) + ".json"), identity)
    try:
        summary = safe_json(root, GENERATED + "/summaries/" + capture_key(capture) + ".json")
        if summary.get("id") == result["id"]:
            result.setdefault("source", {}).update(summary.get("source", {}))
    except FileNotFoundError:
        pass
    return result


def load_run(root, identity, run):
    record = safe_json(root, GENERATED + "/runs/" + run_key(run) + ".json")
    if record.get("run") != run:
        raise ValueError("Run manifest does not match the requested run")
    result = load_result(root, identity, record["capture"])
    installed = installation(root, identity)
    if result.get("run") != run or result.get("installation") != installed["token"]:
        raise ValueError("Run capture identity did not validate")
    return result


def manual_import(root, request):
    result = import_artifacts(root, request.get("specs", []))
    identity = {key: request[key] for key in ("project", "worktree", "hostKey")}
    references = sorted((a["path"], a["digest"], a["format"]) for a in result["artifacts"])
    key = digest(canonical([identity, references, None if references else request.get("specs")]).encode("utf-8"))
    result.update(identity, id=key, capturedAt=time.time(), host=socket.gethostname(),
                  source={"state": "unknown", "reason": "Manual artifact import has no execution-boundary source capture"},
                  command={"outcome": "unknown", "argv": []}, conditions=request.get("conditions", {}))
    persist_result(root, result)
    return result


def list_summaries(root, identity):
    try:
        files = walk_files(root, GENERATED + "/summaries")
    except FileNotFoundError:
        return []
    summaries = []
    for path in files:
        if not re.fullmatch(r"(?:[a-f0-9]{32}|[a-f0-9]{64})\.json", path.rsplit("/", 1)[-1]):
            continue
        summary = safe_json(root, path)
        if all(summary.get(k) == identity.get(k) for k in ("project", "worktree", "hostKey")):
            summaries.append(summary)
    return sorted(summaries, key=lambda s: s.get("capturedAt", 0), reverse=True)


def refresh_summary_sources(root, summaries):
    def needs_current(summary):
        proof = summary.get("sourceEvidence", {})
        before, after, observer = proof.get("before", {}), proof.get("after", {}), proof.get("observation", {})
        return before.get("known") and after.get("known") and observer.get("supported") and not observer.get("reason") and not observer.get("changed") and before.get("digest") == after.get("digest")
    current = fingerprint(root) if any(needs_current(s) for s in summaries) else {"known": False, "reason": "No stable source capture"}
    for summary in summaries:
        proof = summary.get("sourceEvidence", {})
        summary["source"].update(source_freshness(root, proof, current))
        write_json(root, GENERATED + "/summaries/" + capture_key(summary["id"]) + ".json", summary)
    return summaries


def remove_generated_file(root, path):
    parent, name = parent_fd(root, path)
    try:
        os.unlink(name, dir_fd=parent)
    except FileNotFoundError:
        pass
    finally:
        os.close(parent)


def prune_results(root, identity, pinned=None, now=None, max_bytes=128 * 1024 * 1024):
    now = time.time() if now is None else now
    pinned = set((pinned or [])[:2])
    write_json(root, GENERATED + "/pins.json", list(pinned))
    prune_comparisons(root, "")
    summaries = list_summaries(root, identity)
    retained, total = 0, 0
    ordered = sorted(summaries, key=lambda s: (s["id"] not in pinned, -s.get("capturedAt", 0)))
    for summary in ordered:
        path = GENERATED + "/results/" + capture_key(summary["id"]) + ".json"
        try:
            data = safe_read(root, path)
        except FileNotFoundError:
            summary["detail"] = "pruned" if summary.get("detail") == "pruned" else "missing"
        else:
            expired = now - summary.get("capturedAt", 0) > 30 * 86400 and summary["id"] not in pinned
            if retained >= 30 or total + len(data) > max_bytes or expired:
                remove_generated_file(root, path)
                summary["detail"] = "pruned"
            else:
                total += len(data)
                retained += 1
        write_json(root, GENERATED + "/summaries/" + summary["id"] + ".json", summary)
    keep = sorted(summaries, key=lambda s: (s["id"] not in pinned, -s.get("capturedAt", 0)))[:40]
    for summary in summaries:
        if summary not in keep:
            remove_generated_file(root, GENERATED + "/summaries/" + summary["id"] + ".json")
            if summary.get("run"):
                for suffix in (".json", ".claim"):
                    remove_generated_file(root, GENERATED + "/runs/" + run_key(summary["run"]) + suffix)
    return sorted(keep, key=lambda s: s.get("capturedAt", 0), reverse=True)


def prune_comparisons(root, keep, max_bytes=32 * 1024 * 1024):
    try:
        files = walk_files(root, GENERATED + "/comparisons")
    except FileNotFoundError:
        return
    total = 0
    files.sort(key=lambda path: (path.endswith("/" + keep + ".json"), os.lstat(Path(root) / path).st_mtime), reverse=True)
    for path in files:
        if not re.fullmatch(r"(?:[a-f0-9]{32}|[a-f0-9]{64})\.json", path.rsplit("/", 1)[-1]):
            continue
        metadata = os.lstat(Path(root) / path)
        if total + metadata.st_size > max_bytes or time.time() - metadata.st_mtime > 1800:
            remove_generated_file(root, path)
        else:
            total += metadata.st_size


def check_evidence(root, result):
    states = []
    for artifact in result.get("artifacts", []):
        item = {"id": artifact["id"], "path": artifact["path"], "state": "unknown"}
        try:
            if artifact["format"] == "xcresult":
                hasher, size = hashlib.sha256(), 0
                for file in walk_files(root, artifact["path"]):
                    data = safe_read(root, file, MAX_BUNDLE)
                    size += len(data)
                    if size > MAX_BUNDLE:
                        raise ValueError("Artifact exceeds the evidence verification limit")
                    hasher.update(canonical([file[len(artifact["path"]) + 1:], digest(data)]).encode("utf-8"))
                checksum = hasher.hexdigest()
            else:
                checksum = digest(safe_read(root, artifact["path"]))
            item["state"] = "available" if checksum == artifact["digest"] else "replaced"
        except FileNotFoundError:
            item["state"] = "missing"
        except (OSError, ValueError) as error:
            item["reason"] = str(error)
        states.append(item)
    return states


def capture_command(root, profile_id, argv):
    root = Path(root).resolve()
    execution_directory = Path.cwd().resolve()
    if execution_directory != root and root not in execution_directory.parents:
        raise ValueError("Command directory is outside the owning worktree")
    installed = safe_json(root, GENERATED + "/installation.json")
    installation(root, installed)
    config = validate_config(safe_json(root, GENERATED + "/configuration.json"))
    profile = next((p for p in config["profiles"] if p["id"] == profile_id), None)
    if profile is None or not argv:
        raise ValueError("Select a configured profile and supply the command after --")
    if digest(Path(__file__).read_bytes()) != installed["helperDigest"]:
        raise ValueError("Installed capture wrapper changed; reinstall it from the plugin")
    environment_identity = {"project": os.environ.get("ALAS_PROJECT_ID"), "worktree": os.environ.get("ALAS_WORKTREE_ID")}
    run = os.environ.get("ALAS_RUN_ID")
    if run:
        run_key(run)
        if any(environment_identity[k] != installed[k] for k in environment_identity) or os.environ.get("ALAS_RUN_SCRIPT_KEY") != profile["script"]:
            raise ValueError("API 16 launch identity does not match this worktree/profile")
        if str(Path(os.environ.get("ALAS_WORKTREE_ROOT", "")).resolve()) != str(root):
            raise ValueError("API 16 launch root does not match the installed worktree")
        parent, name = parent_fd(root, GENERATED + "/runs/" + run_key(run) + ".claim", create=True)
        try:
            fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=parent)
            os.close(fd)
        except FileExistsError as error:
            raise ValueError("This run already has a capture or an interrupted capture; use a new Alas run") from error
        finally:
            os.close(parent)
    capture_id = uuid.uuid4().hex
    output_relative = GENERATED + "/output/" + capture_id
    parent, name = parent_fd(root, output_relative, create=True)
    try:
        os.mkdir(name, mode=0o700, dir_fd=parent)
    finally:
        os.close(parent)
    captured_at = time.time()
    observer = source_observer(root)
    before = fingerprint(root)
    child_env = dict(os.environ, ALAS_RESULTS_DIR=str(root / output_relative))
    stopped = False
    child = None
    def interrupt(signum, frame):
        nonlocal stopped
        stopped = True
        if child is not None and child.poll() is None:
            try:
                child.send_signal(signum)
            except ProcessLookupError:
                pass
    previous = {s: signal.signal(s, interrupt) for s in (signal.SIGTERM, signal.SIGINT)}
    started = time.time()
    launch_error = None
    try:
        child = subprocess.Popen(argv, cwd=execution_directory, env=child_env)
        code = child.wait()
    except OSError as error:
        code, launch_error = 127, str(error)
    finally:
        ended = time.time()
        after = fingerprint(root)
        observation = observer.finish()
        for s, handler in previous.items():
            signal.signal(s, handler)
    try:
        result = import_artifacts(root / output_relative, profile["artifacts"])
    except (ValueError, OSError, UnicodeError, RecursionError) as error:
        result = {"schema": SCHEMA, "complete": False, "tests": [], "benchmarks": [], "artifacts": [],
                  "issues": [{"message": "Normalization failed: " + str(error)[:2048]}]}
    for artifact in result["artifacts"]:
        artifact["path"] = output_relative + "/" + artifact["path"]
    if stopped or code < 0 or launch_error:
        result["complete"] = False
        result["issues"].append({"message": launch_error or "Command was stopped; artifacts may be incomplete"})
    source = {"before": before, "after": after, "observation": observation,
              "captureStartedAt": captured_at, "captureEndedAt": time.time(), "state": "unknown"}
    source.update(source_freshness(root, source))
    result.update({k: installed[k] for k in ("project", "worktree", "hostKey")},
                  id=capture_id, run=run, script=profile["script"], host=socket.gethostname(), cwd=str(execution_directory),
                  capturedAt=captured_at, installation=installed["token"], source=source,
                  command={"argv": argv, "startedAt": started, "endedAt": ended, "exit": code,
                           "outcome": "stopped" if stopped or code < 0 else "unknown" if launch_error else "succeeded" if code == 0 else "failed"},
                  conditions={"host": socket.gethostname(), "toolchain": profile.get("toolchain"),
                              "configuration": profile.get("configuration"), "target": profile.get("target")},
                  thresholds=profile.get("thresholds", {}), helperVersion=HELPER_VERSION)
    try:
        persist_result(root, result)
        if run:
            write_json(root, GENERATED + "/runs/" + run_key(run) + ".json", {"run": run, "capture": capture_id})
        try:
            pinned = safe_json(root, GENERATED + "/pins.json")
        except FileNotFoundError:
            pinned = []
        prune_results(root, installed, pinned)
        print("Structured results captured: " + capture_id, flush=True)
    except (OSError, ValueError) as error:
        print("Structured results unavailable: " + str(error), file=sys.stderr, flush=True)
    return 128 - code if code < 0 else code


def bridge(root, request, program):
    if not isinstance(request, dict):
        raise ValueError("Malformed helper request")
    operation = request.get("operation")
    root = Path(root).resolve()
    identity = {key: request[key] for key in ("project", "worktree", "hostKey")}
    if operation == "install":
        return install_helper(root, identity, request["config"], program)
    if operation == "configure":
        installation(root, identity)
        write_json(root, GENERATED + "/configuration.json", validate_config(request["config"]))
        return {"configured": True}
    if operation == "list":
        summaries = refresh_summary_sources(root, prune_results(root, identity, request.get("pinned")))
        page = bounded_page(summaries, request.get("offset", 0), 5)
        return {"summaries": page["rows"], "next": page["next"]}
    if operation == "manual":
        result = manual_import(root, request)
        return {"summary": summarize_result(result)}
    if operation == "importRun":
        result = load_run(root, identity, request["run"])
        if request.get("script") and request["script"] != result.get("script"):
            raise ValueError("Capture belongs to another script")
        if request.get("outcome") in ("succeeded", "failed", "stopped", "unknown"):
            result["command"]["hostOutcome"] = request["outcome"]
            if request["outcome"] in ("stopped", "unknown"):
                result["complete"] = False
                message = "Alas reports a stopped/unknown command outcome; capture completion cannot be verified"
                if not any(i.get("message") == message for i in result["issues"]):
                    result["issues"].append({"message": message})
        result["source"].update(source_freshness(root, result.get("source", {})))
        return {"summary": persist_result(root, result)}
    if operation == "stage":
        token = capture_key(request["token"])
        path = GENERATED + "/comparisons/" + token + ".json"
        chunk = request.get("chunk")
        if not isinstance(chunk, str) or len(chunk.encode("utf-8")) > MAX_PAGE:
            raise ValueError("Comparison chunk is too large")
        data = b"" if request.get("offset") == 0 else safe_read(root, path)
        if len(data.decode("utf-8")) != request.get("offset"):
            raise ValueError("Comparison chunks arrived out of order")
        data += chunk.encode("utf-8")
        if len(data) > MAX_DETAIL:
            raise ValueError("Comparison exceeds the detail limit")
        safe_write(root, path, data)
        prune_comparisons(root, token)
        return {"staged": True}
    result = load_result(root, identity, request["capture"])
    if operation == "export":
        text = canonical(result)
        offset = max(0, int(request.get("offset", 0)))
        chunk = text[offset:offset + 12000]
        end = offset + len(chunk)
        return {"chunk": chunk, "offset": offset, "next": end if end < len(text) else None}
    if operation == "detail":
        summary = summarize_result(result)
        evidence = check_evidence(root, result)
        return {"summary": summary, "page": query_result(result, request), "evidence": bounded_page(evidence)["rows"], "evidenceTotal": len(evidence)}
    if operation == "freshness":
        source = source_freshness(root, result.get("source", {}))
        result["source"].update(source)
        return {"summary": persist_result(root, result)}
    if operation == "evidence":
        rows = result.get("benchmarks" if request.get("kind") == "benchmarks" else "tests", [])
        index = int(request["rowIndex"])
        if not 0 <= index < len(rows):
            raise ValueError("Evidence row is outside the retained result")
        row = rows[index]
        artifact = next((a for a in result.get("artifacts", []) if a["id"] == row.get("evidence", {}).get("artifact")), None)
        text = canonical({"row": row, "artifact": artifact, "capture": result["id"]})
        offset = max(0, int(request.get("offset", 0)))
        end = offset + 12000
        return {"text": text[offset:end], "next": end if end < len(text) else None}
    if operation in ("compare", "brief"):
        base = None
        if request.get("baseline"):
            base = load_result(root, identity, request["baseline"])
        elif request.get("foreignBaseline"):
            base = safe_json(root, GENERATED + "/comparisons/" + capture_key(request["foreignBaseline"]) + ".json")
            if base.get("schema") != SCHEMA or base.get("project") != identity["project"]:
                raise ValueError("Foreign baseline belongs to another project/model")
        comparison = compare_results(base, result) if base else None
        if operation == "brief":
            return {"text": investigation_brief(result, request.get("selected"), comparison, request.get("selectedBenchmarks"))}
        if not comparison:
            raise ValueError("Choose a baseline to compare")
        rows = comparison["benchmarks" if request.get("kind") == "benchmarks" else "tests"]
        search = str(request.get("search", "")).casefold()
        if search:
            rows = [row for row in rows if search in canonical([row.get("name"), row.get("id"), row.get("parameters"), row.get("metric")]).casefold()]
        return {"page": bounded_page(rows, request.get("offset", 0)),
                "baseline": {"id": base["id"], "host": base.get("host"), "source": base.get("source")}}
    raise ValueError("Unknown helper operation")


if __name__ == "__main__":
    if "request" in globals():
        try:
            reply = {"ok": True, "result": bridge(Path.cwd(), request, program)}
        except (ValueError, OSError, KeyError, TypeError, IndexError, RecursionError, subprocess.SubprocessError) as error:
            reply = {"ok": False, "error": str(error)[:4096]}
        encoded = canonical(reply)
        if len(encoded.encode("utf-8")) > 128 * 1024:
            encoded = canonical({"ok": False, "error": "Helper reply exceeds the bounded transport limit"})
        print(encoded)
    else:
        parser = argparse.ArgumentParser(description="Capture structured test and benchmark evidence for Alas")
        parser.add_argument("operation", choices=["capture"])
        parser.add_argument("--profile", required=True)
        separator = sys.argv.index("--") if "--" in sys.argv else len(sys.argv)
        args = parser.parse_args(sys.argv[1:separator])
        argv = sys.argv[separator + 1:]
        try:
            root = Path(os.environ.get("ALAS_WORKTREE_ROOT", Path.cwd())).resolve()
            sys.exit(capture_command(root, args.profile, argv))
        except (ValueError, OSError, KeyError, subprocess.SubprocessError) as error:
            print("Capture failed: " + str(error), file=sys.stderr)
            sys.exit(2)
