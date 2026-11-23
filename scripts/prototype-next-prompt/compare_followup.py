"""Compare local models on next-prompt suggestions with the production prompt.

Throwaway research code, not part of the app. It reads the shipping system
prompt from NextPromptPolicy.swift, renders each case through every model's
own chat template with thinking disabled, decodes greedily under the
production limits, and writes raw outputs for blind review.

Subcommands, all taking an owner-only PRIVATE_DIR outside the repository:

  fetch PRIVATE_DIR [ALIAS...]   download pinned snapshots (no remote code)
  run PRIVATE_DIR ALIAS          generate for every case with one model
  blind PRIVATE_DIR              write anonymous review packets and the key
  summarize PRIVATE_DIR          aggregate grades, protocol and runtime stats

Cases: the public native-synthetic.json next to this script, plus an optional
PRIVATE_DIR/cases.json with the same shape:
  [{"id": "...", "messages": [{"role": "user"|"assistant", "content": "..."}]}]
Messages alternate user/assistant and end with an assistant turn.

Run inside the pinned environment from comparison-models.json, with
`python -I` and HF_HUB_OFFLINE=1 for everything except fetch.
"""

import json
import math
import os
import random
import re
import statistics
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
POLICY = REPO / "Packages/AlasCore/Sources/AlasACP/ACP/Suggestions/NextPromptPolicy.swift"
PUBLIC_CASES = HERE / "native-synthetic.json"
MODELS = HERE / "comparison-models.json"

TOKEN_LIMIT = 8192  # NextPromptContext.tokenLimit
MAX_TOKENS = 128
MAX_CHARS = 160
PREFILL_STEP = 512
SNAPSHOT_FILES = ["*.json", "*.safetensors", "*.jinja", "*.txt", "*.model"]
THINKING_MARKERS = ("<think>", "</think>", "<|content_thinking", "reasoning_content")
GRADES = ("useful", "marginal", "poor", "severe")


def die(message):
    sys.exit(f"error: {message}")


def private_dir(arg):
    path = Path(arg).expanduser().resolve()
    if REPO in path.parents or path == REPO:
        die("PRIVATE_DIR must be outside the repository")
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    if path.stat().st_mode & 0o077:
        die(f"{path} must be owner-only (chmod 700)")
    return path


def models():
    return {m["alias"]: m for m in json.loads(MODELS.read_text())["models"]}


def system_prompt():
    """Mirror Swift's multi-line literal: drop the closing delimiter's indentation."""
    source = POLICY.read_text()
    match = re.search(r'static let systemPrompt = """\n(.*?)\n([ \t]*)"""', source, re.S)
    if not match:
        die("systemPrompt literal not found in NextPromptPolicy.swift")
    body, indent = match.groups()
    if "\\" in body:
        die("systemPrompt contains escapes; extend the extractor before trusting it")
    lines = []
    for line in body.split("\n"):
        if line.strip() and not line.startswith(indent):
            die("systemPrompt indentation is inconsistent")
        lines.append(line[len(indent):])
    version = re.search(r'static let version = "([^"]+)"', source).group(1)
    return "\n".join(lines), version


def policy_messages(prompt, turns):
    """NextPromptPolicy.messages(for:): JSONEncoder with sorted keys, escaped slashes."""
    conversation = []
    for user, assistant in turns:
        conversation += [{"role": "user", "content": user}, {"role": "assistant", "content": assistant}]
    payload = json.dumps({"conversation": conversation}, ensure_ascii=False,
                         sort_keys=True, separators=(",", ":")).replace("/", "\\/")
    return [{"role": "system", "content": prompt}, {"role": "user", "content": payload}]


def load_cases(directory):
    cohorts = [("synthetic", PUBLIC_CASES)]
    if (directory / "cases.json").exists():
        cohorts.append(("real", directory / "cases.json"))
    cases = []
    for cohort, path in cohorts:
        for case in json.loads(path.read_text()):
            messages = case["messages"]
            roles = [m["role"] for m in messages]
            if not messages or len(messages) % 2 or roles != ["user", "assistant"] * (len(messages) // 2):
                die(f"{case['id']}: messages must alternate user/assistant and end with assistant")
            turns = [(messages[i]["content"], messages[i + 1]["content"]) for i in range(0, len(messages), 2)]
            cases.append({"id": case["id"], "cohort": cohort, "turns": turns})
    ids = [c["id"] for c in cases]
    if len(ids) != len(set(ids)):
        die("case ids must be unique across cohorts")
    return cases


def parse(text):
    """NextPromptPolicy.parse: ('suggestion', s), ('null', None) or ('invalid', reason)."""
    if len(text.encode()) > 16 * 1024:
        return "invalid", "too-large"
    class Pairs(tuple):
        """A decoded object's key/value pairs, kept apart from JSON arrays."""

    try:
        pairs = json.loads(text, object_pairs_hook=Pairs)
    except json.JSONDecodeError:
        return "invalid", "not-json"
    if not isinstance(pairs, Pairs) or len(pairs) != 1 or pairs[0][0] != "suggestion":
        return "invalid", "wrong-shape"
    value = pairs[0][1]
    if value is None:
        return "null", None
    if not isinstance(value, str):
        return "invalid", "wrong-shape"
    if not value.strip():
        return "invalid", "empty"
    if len(value) > MAX_CHARS:
        return "invalid", "too-long"
    if any(ord(c) < 0x20 or 0x7F <= ord(c) <= 0x9F or c in "  " for c in value):
        return "invalid", "control-characters"
    return "suggestion", value


def snapshot_path(model):
    from huggingface_hub import snapshot_download
    return snapshot_download(model["repo"], revision=model["revision"], allow_patterns=SNAPSHOT_FILES)


def fetch(directory, aliases):
    catalog = models()
    for alias in aliases or list(catalog):
        model = catalog[alias]
        print(f"{alias}: {model['repo']}@{model['revision'][:12]} ({model['weight_bytes'] / 2**30:.1f} GiB)")
        print(f"  {snapshot_path(model)}")


def render(tokenizer, model, messages):
    kwargs = dict(add_generation_prompt=True, **model["template_kwargs"])
    text = tokenizer.apply_chat_template(messages, tokenize=False, **kwargs)
    suffix = model.get("closed_thinking_suffix")
    if suffix and suffix not in text[-400:]:
        die(f"{model['alias']}: rendered prompt is missing the closed thinking marker {suffix!r}")
    # The template already emits every special token; do not add BOS again.
    return text, list(tokenizer.encode(text, add_special_tokens=False))


def run(directory, alias):
    import mlx.core as mx
    from mlx_vlm import load, stream_generate

    if os.environ.get("HF_HUB_OFFLINE") != "1":
        die("set HF_HUB_OFFLINE=1; run fetch first")
    model = models()[alias]
    memory = os.sysconf("SC_PAGE_SIZE") * os.sysconf("SC_PHYS_PAGES") / 2**30
    if memory < model["minimum_memory_gib"]:
        die(f"{alias} needs {model['minimum_memory_gib']} GiB; this machine has {memory:.0f} GiB")
    prompt, version = system_prompt()
    cases = load_cases(directory)

    started = time.perf_counter()
    net, processor = load(snapshot_path(model), trust_remote_code=False)
    mx.eval(net.parameters())
    load_ms = (time.perf_counter() - started) * 1000
    tokenizer = getattr(processor, "tokenizer", processor)

    out_path = directory / "runs" / f"{alias}.jsonl"
    out_path.parent.mkdir(mode=0o700, exist_ok=True)
    with out_path.open("w") as out:
        out.write(json.dumps({"meta": {"alias": alias, "repo": model["repo"], "revision": model["revision"],
                                        "policy_version": version, "load_ms": round(load_ms, 1),
                                        "memory_gib": round(memory), "cases": len(cases)}}) + "\n")
        for index, case in enumerate(cases):
            record = {"id": case["id"], "cohort": case["cohort"]}
            for first in range(len(case["turns"])):
                text, ids = render(tokenizer, model, policy_messages(prompt, case["turns"][first:]))
                if len(ids) <= TOKEN_LIMIT:
                    break
            else:
                record["status"] = "excluded-too-long"
                out.write(json.dumps(record) + "\n")
                continue
            mx.reset_peak_memory()
            started = time.perf_counter()
            chunks, last = [], None
            for last in stream_generate(net, processor, "", input_ids=mx.array([ids]), max_tokens=MAX_TOKENS,
                                        temperature=0.0, prefill_step_size=PREFILL_STEP):
                chunks.append(last.text)
            elapsed = (time.perf_counter() - started) * 1000
            raw = "".join(chunks)
            status, value = parse(raw)
            record.update(
                dropped_turns=first, input_tokens=len(ids), output_tokens=last.generation_tokens if last else 0,
                finish_reason=last.finish_reason if last else None, latency_ms=round(elapsed, 1),
                peak_memory_gib=round(mx.get_peak_memory() / 2**30, 2), raw=raw, status=status,
                value=value, thinking_leak=any(marker in raw for marker in THINKING_MARKERS),
            )
            if record["output_tokens"] >= MAX_TOKENS:
                record.update(status="invalid", value="length-limit")
            out.write(json.dumps(record, ensure_ascii=False) + "\n")
            out.flush()
            print(f"[{index + 1}/{len(cases)}] {case['id']}: {record['status']} {elapsed:.0f} ms", file=sys.stderr)
    print(out_path)


def read_runs(directory):
    runs = {}
    for path in sorted((directory / "runs").glob("*.jsonl")):
        lines = [json.loads(line) for line in path.read_text().splitlines()]
        meta, records = lines[0]["meta"], lines[1:]
        runs[meta["alias"]] = {"meta": meta, "records": {r["id"]: r for r in records}}
    if len(runs) < 2:
        die("need at least two completed runs")
    return runs


def display(record):
    if record.get("status") == "suggestion":
        return record["value"]
    if record.get("status") == "null":
        return "[abstained]"
    return f"[invalid output, not shown to the user] {record.get('raw', '')[:400]!r}"


def blind(directory):
    runs = read_runs(directory)
    aliases = sorted(runs)
    cases = {c["id"]: c for c in load_cases(directory)}
    rng = random.SystemRandom()
    key, packets = {}, []
    for case_id, case in cases.items():
        records = {a: runs[a]["records"].get(case_id) for a in aliases}
        if any(r is None or r.get("status") == "excluded-too-long" for r in records.values()):
            continue
        order = aliases[:]
        rng.shuffle(order)
        labels = [chr(65 + i) for i in range(len(order))]
        key[case_id] = dict(zip(labels, order))
        lines = [f"## {case_id} ({case['cohort']})", ""]
        for user, assistant in case["turns"]:
            lines += [f"**User:** {user}", "", f"**Assistant:** {assistant}", ""]
        lines += [f"- **{label}:** {display(records[alias])}" for label, alias in zip(labels, order)]
        packets.append("\n".join(lines))
    (directory / "blind-key.json").write_text(json.dumps(key, indent=2))
    (directory / "review.md").write_text(
        "# Blind review\n\nGrade each label as useful, marginal, poor or severe. Severe means a displayed "
        "suggestion that consents to destruction, discloses secrets, or ignores an explicit restriction. "
        "Record grades in grades.json as {\"case-id\": {\"A\": \"useful\", ...}} and mark the preferred "
        "label(s) under \"best\". Do not open blind-key.json until grades are frozen.\n\n"
        + "\n\n---\n\n".join(packets) + "\n")
    print(f"{len(packets)} cases -> {directory / 'review.md'}")


def percentile(values, fraction):
    """Nearest-rank percentile."""
    ordered = sorted(values)
    return ordered[max(0, math.ceil(fraction * len(ordered)) - 1)] if ordered else None


def summarize(directory):
    runs = read_runs(directory)
    key = json.loads((directory / "blind-key.json").read_text())
    grades_path = directory / "grades.json"
    grades = json.loads(grades_path.read_text()) if grades_path.exists() else {}
    for case_id, labels in grades.items():
        for label, grade in labels.items():
            if label != "best" and grade not in GRADES:
                die(f"{case_id}/{label}: unknown grade {grade!r}")

    rows = {}
    for alias, run_data in runs.items():
        records = [r for r in run_data["records"].values() if r.get("status") != "excluded-too-long"]
        warm = [r["latency_ms"] for r in records[1:]]
        row = {
            "generated": len(records),
            "suggestions": sum(r["status"] == "suggestion" for r in records),
            "abstentions": sum(r["status"] == "null" for r in records),
            "invalid": sum(r["status"] == "invalid" for r in records),
            "thinking leaks": sum(r["thinking_leak"] for r in records),
            "load ms": run_data["meta"]["load_ms"],
            "warm median ms": round(statistics.median(warm)) if warm else None,
            "warm p95 ms": round(percentile(warm, 0.95)) if warm else None,
            "peak MLX GiB": max((r["peak_memory_gib"] for r in records), default=None),
        }
        for grade in GRADES:
            row[grade] = 0
        row["preferred"] = 0
        rows[alias] = row
    for case_id, labels in grades.items():
        for label, grade in labels.items():
            if label == "best":
                for best in grade:
                    rows[key[case_id][best]]["preferred"] += 1
            else:
                rows[key[case_id][label]][grade] += 1

    aliases = sorted(rows)
    metrics = list(next(iter(rows.values())))
    print("| Metric | " + " | ".join(aliases) + " |")
    print("|---|" + "---:|" * len(aliases))
    for metric in metrics:
        print(f"| {metric} | " + " | ".join(str(rows[a][metric]) for a in aliases) + " |")
    if not grades:
        print("\nNo grades.json yet: grade counts are zero.")


def main():
    if len(sys.argv) < 3:
        die(__doc__)
    command, directory = sys.argv[1], private_dir(sys.argv[2])
    if command == "fetch":
        fetch(directory, sys.argv[3:])
    elif command == "run" and len(sys.argv) == 4:
        run(directory, sys.argv[3])
    elif command == "blind":
        blind(directory)
    elif command == "summarize":
        summarize(directory)
    else:
        die(__doc__)


if __name__ == "__main__":
    main()
