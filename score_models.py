#!/usr/bin/env python3
"""Score model answers against the hand labels in cmo_test_data/labeled/labels.tsv.

Usage: score_models.py <results.jsonl> [<results.jsonl> ...]

Each results file comes from model_agreement.bash. Several files (for example
one run with thumbnail frames and one with motion frames) are shown side by
side, labelled by file name. Fields marked "?" in labels.tsv are skipped.

Prints, as markdown tables:
  - per model: clips with all six answers right, false alarms, misses, seconds, context and tokens
  - per model and field: accuracy
  - when there are two files: the clips each model got right in one and wrong
    in the other
"""
import csv
import json
import os
import sys

FIELDS = ["legs", "person", "cat", "dog", "raccoon", "animal"]
HERE = os.path.dirname(os.path.abspath(__file__))


def test_data_dir():
    """Where the private cmo_test_data repo is: $cmo_test_data, else what ollama_common.bash works out
    (its default, or this machine's ollama_env_props.bash), else next to this repo."""
    if os.environ.get("cmo_test_data"):
        return os.environ["cmo_test_data"]
    try:
        import subprocess
        out = subprocess.run(["bash", "-c", 'source "$1" >/dev/null 2>&1; printf %s "$cmo_test_data"', "_",
                              os.path.join(HERE, "ollama_common.bash")],
                             capture_output=True, text=True, timeout=30).stdout
        if out:
            return out
    except (OSError, subprocess.SubprocessError):
        pass
    return os.path.join(os.path.dirname(HERE), "cmo_test_data")


TEST_DATA = test_data_dir()
LABELS = os.path.join(TEST_DATA, "labeled", "labels.tsv")


def wrong_fields(answer, truth):
    return [f for f in FIELDS if truth[f] != "?" and (truth[f] == "1") != bool(answer.get(f))]


def load(path):
    runs = {}
    for line in open(path):
        if line.strip():
            r = json.loads(line)
            runs[(r["model"], r["me_name"])] = r
    return runs


def average(rows, key, fmt):
    """The average of rows' key, formatted, or "-" (older results files have no token counts)."""
    vals = [r[key] for r in rows if r.get(key)]
    return format(sum(vals) / len(vals), fmt) if vals else "-"


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    truth = {r["me_name"]: r for r in csv.DictReader(open(LABELS), delimiter="\t")}
    files = sys.argv[1:]
    runs = {os.path.basename(p): load(p) for p in files}
    models = sorted({m for run in runs.values() for m, _ in run})

    print("| run | model | all 6 right | false alarms | misses | failed calls | avg seconds | context | avg prompt tokens | avg output tokens |")
    print("| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |")
    for name, run in runs.items():
        for m in models:
            rows = [r for (rm, n), r in run.items() if rm == m and n in truth]
            if not rows:
                continue
            right = alarms = misses = failed = 0
            for r in rows:
                if not r["answer"]:
                    failed += 1
                    continue
                t = truth[r["me_name"]]
                bad = wrong_fields(r["answer"], t)
                right += not bad
                alarms += sum(1 for f in bad if t[f] == "0")
                misses += sum(1 for f in bad if t[f] == "1")
            ctx = ",".join(str(c) for c in sorted({r["num_ctx"] for r in rows if r.get("num_ctx")})) or "-"
            print(f"| {name} | {m} | {right}/{len(rows)} | {alarms} | {misses} | {failed} | {average(rows, 'seconds', '.1f')} | "
                  f"{ctx} | {average(rows, 'prompt_tokens', '.0f')} | {average(rows, 'output_tokens', '.0f')} |")

    print("\n| run | model | " + " | ".join(FIELDS) + " |")
    print("| --- " * (2 + len(FIELDS)) + "|")
    for name, run in runs.items():
        for m in models:
            rows = [r for (rm, n), r in run.items() if rm == m and n in truth and r["answer"]]
            if not rows:
                continue
            cells = []
            for f in FIELDS:
                scored = [r for r in rows if truth[r["me_name"]][f] != "?"]
                ok = sum(1 for r in scored if f not in wrong_fields(r["answer"], truth[r["me_name"]]))
                cells.append(f"{100 * ok / len(scored):.0f}%")
            print(f"| {name} | {m} | " + " | ".join(cells) + " |")

    if len(runs) == 2:
        (a_name, a), (b_name, b) = runs.items()
        print(f"\n### Clips that changed from {a_name} to {b_name}\n")
        print("| model | clip | category | in " + a_name + " | in " + b_name + " |")
        print("| --- | --- | --- | --- | --- |")
        for m in models:
            for n, t in sorted(truth.items(), key=lambda x: (x[1]["category"], x[0])):
                ra, rb = a.get((m, n)), b.get((m, n))
                if not ra or not rb or not ra["answer"] or not rb["answer"]:
                    continue
                wa, wb = wrong_fields(ra["answer"], t), wrong_fields(rb["answer"], t)
                if bool(wa) != bool(wb) or set(wa) != set(wb):
                    show = lambda w: "right" if not w else "wrong on " + ",".join(w)
                    print(f"| {m} | {n} | {t['category']} | {show(wa)} | {show(wb)} |")


if __name__ == "__main__":
    main()
