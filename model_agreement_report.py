#!/usr/bin/env python3
"""Summarise how often models agree, from the results.jsonl written by
model_agreement.bash.

Usage: model_agreement_report.py <results.jsonl>

Prints, as markdown tables:
  - failures, average seconds and average tokens per model
  - per field: how often all models agree, and each pair's agreement
  - per sample label: how often all models give the identical answer
  - each model's agreement with the labels already on the server
  - the clips where the models disagree
"""
import itertools
import json
import sys
from collections import defaultdict

FIELDS = ["legs", "person", "cat", "dog", "raccoon", "animal"]


def pct(n, d):
    return f"{100 * n / d:.0f}% ({n}/{d})" if d else "-"


def short(model):
    return model.split(":")[-1]


def answer_key(answer):
    return "".join("1" if answer.get(f) else "0" for f in FIELDS)


rows = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
models = list(dict.fromkeys(r["model"] for r in rows))
by_clip = defaultdict(dict)
meta = {}
for r in rows:
    by_clip[r["me_name"]][r["model"]] = r["answer"]
    meta[r["me_name"]] = (r["sample_label"], r["server"])

# only clips every model answered (a {} answer means the call failed)
clips = [c for c, a in by_clip.items() if len(a) == len(models) and all(a.values())]
pairs = list(itertools.combinations(models, 2))

print(f"## {len(clips)} clips answered by all of {', '.join(models)}\n")

def avg(mine, key, fmt):
    vals = [r[key] for r in mine if r.get(key) is not None]
    return format(sum(vals) / len(vals), fmt) if vals else "-"


print("| model | failed calls | avg seconds | context | avg prompt tokens | max prompt tokens | avg output tokens |\n"
      "| --- | --- | --- | --- | --- | --- | --- |")
for m in models:
    mine = [r for r in rows if r["model"] == m]
    failed = sum(1 for r in mine if not r["answer"])
    ctx = sorted({r["num_ctx"] for r in mine if r.get("num_ctx")})
    peak = max((r["prompt_tokens"] for r in mine if r.get("prompt_tokens") is not None), default=None)
    print(f"| {m} | {failed}/{len(mine)} | {avg(mine, 'seconds', '.1f')} | {','.join(map(str, ctx)) or '-'} | "
          f"{avg(mine, 'prompt_tokens', '.0f')} | {peak if peak is not None else '-'} | {avg(mine, 'output_tokens', '.0f')} |")

print("\n### Agreement per field\n")
print("| field | all agree | " + " | ".join(f"{short(a)} vs {short(b)}" for a, b in pairs) + " |")
print("| --- " * (2 + len(pairs)) + "|")
for f in FIELDS + ["whole answer"]:
    get = (lambda a: answer_key(a)) if f == "whole answer" else (lambda a, f=f: bool(a.get(f)))
    all_agree = sum(1 for c in clips if len({get(by_clip[c][m]) for m in models}) == 1)
    cells = [pct(sum(1 for c in clips if get(by_clip[c][a]) == get(by_clip[c][b])), len(clips)) for a, b in pairs]
    print(f"| {f} | {pct(all_agree, len(clips))} | " + " | ".join(cells) + " |")

print("\n### Identical answers from all models, by sample label\n")
print("| sample label | clips | all agree on that label | identical whole answer |\n| --- | --- | --- | --- |")
for label in dict.fromkeys(meta[c][0] for c in clips):
    mine = [c for c in clips if meta[c][0] == label]
    field = "animal" if label in ("other_animal", "none") else label
    on_label = sum(1 for c in mine if len({bool(by_clip[c][m].get(field)) for m in models}) == 1)
    whole = sum(1 for c in mine if len({answer_key(by_clip[c][m]) for m in models}) == 1)
    print(f"| {label} | {len(mine)} | {pct(on_label, len(mine))} | {pct(whole, len(mine))} |")

print("\n### Agreement with the labels already on the server (me_ollama.json)\n")
print("| model | " + " | ".join(FIELDS) + " | whole answer |\n| --- " * 1 + "| --- " * (len(FIELDS) + 1) + "|")
served = [c for c in clips if meta[c][1]]
for m in models:
    cells = [pct(sum(1 for c in served if bool(by_clip[c][m].get(f)) == bool(meta[c][1].get(f))), len(served)) for f in FIELDS]
    whole = sum(1 for c in served if answer_key(by_clip[c][m]) == answer_key(meta[c][1]))
    print(f"| {m} | " + " | ".join(cells) + f" | {pct(whole, len(served))} |")

print("\n### Clips where the models disagree\n")
print(f"Answers are {'/'.join(FIELDS)} as 1/0.\n")
print("| clip | sample label | server | " + " | ".join(short(m) for m in models) + " |")
print("| --- " * (3 + len(models)) + "|")
for c in sorted(clips, key=lambda c: (meta[c][0], c)):
    keys = [answer_key(by_clip[c][m]) for m in models]
    if len(set(keys)) > 1:
        server = answer_key(meta[c][1]) if meta[c][1] else "-"
        print(f"| {c} | {meta[c][0]} | {server} | " + " | ".join(keys) + " |")
