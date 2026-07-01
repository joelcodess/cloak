# cloak evals

A deterministic harness for the on-device scrub engine. The on-device model runs
greedy, so scores are stable and re-runs are cached.

## Run

```sh
swift build                       # or -c release, then pass --release
python3 harness.py                # score the whole dataset (cached)
python3 harness.py --no-cache     # force re-scrub (after a prompt/engine change)
python3 harness.py --id transcript --no-cache   # one case
python3 harness.py --json         # machine-readable summary on stdout
```

## What it measures

For each case the engine scrubs the text; we compare against gold labels:

| metric | meaning | target |
|--------|---------|--------|
| **leaks** | gold PII values still present verbatim in the scrubbed text — real PII that left the machine | **0** |
| **recall** | fraction of must-remove PII that was successfully scrubbed | 1.0 |
| **over-scrub** | `essential` (load-bearing) values that were scrubbed anyway, breaking answer correctness | 0 |
| extra-scrubbed | replaced spans not in the gold list (rough over-detection signal; noisy) | low |

`leaks` is the money metric. A scrubber that misses PII is worse than useless, so
we optimize leaks → 0 first, then recall, then over-scrub.

## Dataset (`dataset.jsonl`)

One JSON object per line:

```json
{"id": "...", "task": "drafting",
 "text": "the prompt a user would send",
 "pii": ["every value that must be scrubbed"],
 "essential": ["values that must be KEPT because they drive a factual answer"]}
```

- `pii` minus `essential` = the must-remove set (leaks/recall are scored on this).
- `essential` values should remain present (over-scrub is scored on this).

Add cases that stress real failure modes: bare first names, invented codenames,
non-US identifiers, factual vs. generative tasks, no-PII controls.

## The hardening loop

This is the loop the build was made for:

1. `python3 harness.py --no-cache` → read the leaks.
2. Classify each leak: **deterministic** (regex/synthetics bug — fix in Swift,
   free win) or **model-recall** (the on-device model missed it).
3. For model-recall misses, try, in order: tighten the instructions, add a
   few-shot example to `FoundationModelSpanFinder.instructions`, run a
   self-consistency pass (detect twice, union), or add a gazetteer of known
   internal codenames/employees as a deterministic pre-pass.
4. Re-run. Keep leaks monotonically non-increasing; watch over-scrub doesn't rise.

The api-key leak fixed during the initial build is an example of step 2's
"deterministic" branch — the harness pinned it to a synthetics bug, not the model.
