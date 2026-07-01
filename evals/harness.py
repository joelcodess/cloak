#!/usr/bin/env python3
"""
Eval harness for the cloak scrub engine (mirrors superman's harness pattern).

Drives `cloak scrub --json` over a labeled dataset and scores the metrics that
matter for a privacy scrubber:

  LEAK   — a gold PII value that survives VERBATIM in the scrubbed text. This is
           the money metric: every leak is real PII that left the machine. Lower
           is better; the target is zero.
  RECALL — fraction of gold PII values that were successfully removed.
  OVER-SCRUB — a value annotated `essential` (load-bearing for a factual answer)
           that got scrubbed anyway. These break answer correctness.
  EXTRA  — spans the engine scrubbed whose text isn't any gold value (rough
           over-detection noise signal).

The model is deterministic (greedy), so scores are stable. Results are cached by
(strategy, input) hash in .cache/; pass --no-cache to force re-scrub.

Detection strategies (the tournament): the Swift engine reads CLOAK_STRATEGY.
    python3 harness.py                                   # default strategy, all cases
    python3 harness.py --strategy fewshot                # one strategy
    python3 harness.py --strategies baseline,fewshot,... # tournament comparison table
    python3 harness.py --split dev|holdout|all           # dataset split (default all)
    python3 harness.py --id draft-email --no-cache       # one case, fresh
"""
import argparse
import hashlib
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
CACHE_DIR = os.path.join(HERE, ".cache")
TIMEOUT = 240


def binary(release):
    name = "release" if release else "debug"
    path = os.path.join(ROOT, ".build", name, "cloak")
    if not os.path.exists(path):
        sys.exit(f"cloak binary not found at {path} — run `swift build{' -c release' if release else ''}` first.")
    return path


def load_dataset(split):
    with open(os.path.join(HERE, "dataset.jsonl")) as f:
        cases = [json.loads(line) for line in f if line.strip()]
    if split != "all":
        cases = [c for c in cases if c.get("split", "dev") == split]
    return cases


def scrub(binpath, text, strategy, use_cache):
    key = hashlib.sha256((binpath + "\0" + strategy + "\0" + text).encode()).hexdigest()[:16]
    cache_file = os.path.join(CACHE_DIR, key + ".json")
    if use_cache and os.path.exists(cache_file):
        with open(cache_file) as f:
            return json.load(f)
    env = dict(os.environ, CLOAK_STRATEGY=strategy)
    proc = subprocess.run([binpath, "scrub", "--json"], input=text, env=env,
                          capture_output=True, text=True, timeout=TIMEOUT)
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.strip()[:200])
    result = json.loads(proc.stdout)
    os.makedirs(CACHE_DIR, exist_ok=True)
    with open(cache_file, "w") as f:
        json.dump(result, f)
    return result


def score_case(case, result):
    scrubbed = result["scrubbed"]
    gold = case.get("pii", [])
    essential = set(case.get("essential", []))
    must_remove = [p for p in gold if p not in essential]

    leaks = [p for p in must_remove if p in scrubbed]
    removed = [p for p in must_remove if p not in scrubbed]
    recall = 1.0 if not must_remove else len(removed) / len(must_remove)

    over_scrubbed = [e for e in essential if e not in scrubbed]

    scrubbed_texts = [s["text"] for s in result["spans"] if s.get("scrubbed")]
    extra = [t for t in scrubbed_texts if t not in gold]

    return {
        "id": case["id"],
        "task": case.get("task", "?"),
        "recall": round(recall, 3),
        "leaks": leaks,
        "over_scrubbed": over_scrubbed,
        "extra_scrubbed": extra,
        "n_pii": len(must_remove),
    }


def run_strategy(binpath, cases, strategy, use_cache):
    rows, recalls = [], []
    total_leaks = total_over = total_extra = 0
    for case in cases:
        try:
            result = scrub(binpath, case["text"], strategy, use_cache)
        except Exception as e:  # noqa: BLE001
            rows.append({"id": case["id"], "task": case.get("task", "?"), "recall": 0.0,
                         "leaks": ["<error>"], "over_scrubbed": [], "extra_scrubbed": [],
                         "n_pii": len(case.get("pii", [])), "error": str(e)})
            total_leaks += 1
            recalls.append(0.0)
            continue
        r = score_case(case, result)
        rows.append(r)
        total_leaks += len(r["leaks"])
        total_over += len(r["over_scrubbed"])
        total_extra += len(r["extra_scrubbed"])
        recalls.append(r["recall"])
    return {
        "strategy": strategy,
        "mean_recall": round(sum(recalls) / len(recalls), 3) if recalls else 0.0,
        "total_leaks": total_leaks,
        "total_over_scrub": total_over,
        "total_extra": total_extra,
        "cases": rows,
    }


def print_cases(summary):
    print(f"{'CASE':<22} {'TASK':<10} {'RECALL':>6} {'LEAKS':>6} {'OVER':>5}  NOTES", file=sys.stderr)
    print("-" * 84, file=sys.stderr)
    for r in summary["cases"]:
        notes = []
        if r["leaks"]:
            notes.append("LEAK:" + ",".join(r["leaks"])[:36])
        if r["over_scrubbed"]:
            notes.append("over:" + ",".join(r["over_scrubbed"])[:20])
        print(f"{r['id']:<22} {r['task']:<10} {r['recall']:>6.2f} "
              f"{len(r['leaks']):>6} {len(r['over_scrubbed']):>5}  {'; '.join(notes)}",
              file=sys.stderr)
    print("-" * 84, file=sys.stderr)
    print(f"[{summary['strategy']}] mean recall {summary['mean_recall']:.3f}   "
          f"leaks {summary['total_leaks']}   over-scrub {summary['total_over_scrub']}   "
          f"extra {summary['total_extra']}   cases {len(summary['cases'])}", file=sys.stderr)


def print_tournament(summaries):
    # Rank: fewest leaks, then highest recall, then least over-scrub, then least extra noise.
    ranked = sorted(summaries, key=lambda s: (s["total_leaks"], -s["mean_recall"],
                                              s["total_over_scrub"], s["total_extra"]))
    print("", file=sys.stderr)
    print(f"{'RANK':<5} {'STRATEGY':<22} {'RECALL':>7} {'LEAKS':>6} {'OVER':>5} {'EXTRA':>6}", file=sys.stderr)
    print("-" * 56, file=sys.stderr)
    for i, s in enumerate(ranked, 1):
        print(f"{i:<5} {s['strategy']:<22} {s['mean_recall']:>7.3f} {s['total_leaks']:>6} "
              f"{s['total_over_scrub']:>5} {s['total_extra']:>6}", file=sys.stderr)
    return ranked


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--id", help="score only this case id")
    ap.add_argument("--strategy", default=os.environ.get("CLOAK_STRATEGY", "baseline"))
    ap.add_argument("--strategies", help="comma-separated list -> tournament comparison")
    ap.add_argument("--split", default="all", choices=["dev", "holdout", "all"])
    ap.add_argument("--no-cache", action="store_true")
    ap.add_argument("--release", action="store_true")
    ap.add_argument("--json", action="store_true", help="emit full JSON to stdout")
    args = ap.parse_args()

    binpath = binary(args.release)
    cases = load_dataset(args.split)
    if args.id:
        cases = [c for c in cases if c["id"] == args.id]
        if not cases:
            sys.exit(f"no case with id {args.id}")

    if args.strategies:
        names = [s.strip() for s in args.strategies.split(",") if s.strip()]
        summaries = []
        for name in names:
            print(f"\n=== {name} ({args.split}) ===", file=sys.stderr)
            s = run_strategy(binpath, cases, name, use_cache=not args.no_cache)
            print_cases(s)
            summaries.append(s)
        ranked = print_tournament(summaries)
        if args.json:
            print(json.dumps({"split": args.split, "ranking": [s["strategy"] for s in ranked],
                              "results": ranked}, indent=2))
    else:
        s = run_strategy(binpath, cases, args.strategy, use_cache=not args.no_cache)
        print_cases(s)
        if args.json:
            print(json.dumps(s, indent=2))


if __name__ == "__main__":
    main()
