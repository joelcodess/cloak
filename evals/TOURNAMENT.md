# PII detection-harness tournament

Cloak's regex fast-pass catches hard IDs deterministically; the on-device model
is responsible for the fuzzy contextual layer (names, orgs, locations, internal
codenames). This tournament compared six harness designs for that model layer,
scored on a labeled dataset with a dev/holdout split, and picked a winner.

## Method
- **Strategies** live behind `CLOAK_STRATEGY` (`Sources/CloakKit/Strategies.swift`).
  Greedy decoding is deterministic, so ensemble diversity comes from prompt/input
  variation, never reruns — and scores are stable/cacheable.
- **Scoring** (`harness.py`): leaks (gold PII surviving verbatim — the money
  metric), recall, over-scrub (essential values wrongly removed), extra (noise).
  Ranking: fewest leaks → highest recall → least over-scrub → least noise.
- **Dataset**: 52 labeled cases, split `dev` (37) / `holdout` (15). 20 hard cases
  target the known weakness class (bare first names, invented codenames,
  common-word names like Grant/Summer/Chase), plus no-PII controls that punish
  over-detection. Winner chosen on dev, confirmed on the untouched holdout.

## Results (dev, 37 cases)

| Rank | Strategy | Recall | Leaks | Over-scrub | Passes |
|------|----------|-------:|------:|-----------:|:------:|
| 1 | **dual-lens** | **0.901** | **8** | 8 | 2 |
| 2 | baseline | 0.828 | 13 | 8 | 1 |
| 3 | residual-audit | 0.762 | 21 | 12 | 2 |
| 4 | fewshot | 0.641 | 39 | 7 | 1 |
| 5 | candidate-inject | 0.377 | 51 | 1 | 1 |
| 6 | enumerate-classify | 0.406 | 56 | 3 | 2 |

Holdout (15 cases) confirmed the order: dual-lens 0.756 / 9 leaks vs baseline
0.744 / 10 leaks.

## Winner: `dual-lens`
Two greedy passes on each chunk, unioned:
- **Pass A** — the current generalist scrubber (unchanged), the only source of
  `essential=yes` verdicts.
- **Pass B** — a narrow "name-hunter" prompted *only* for the miss class (bare
  first names, nicknames, invented codenames), guarded by an uppercase-start
  requirement, a public-product denylist, and containment dedup against Pass A.

Because it is a **strict superset** of baseline, it can never regress baseline's
recall — the safest possible win. Cost is 2× model latency per chunk (fine for a
document app). Catches baseline misses like Foundry, Bluejay, Peregrine, Larkspur,
Summer.

## The key finding
The three strategies that **replaced** the working prompt (fewshot,
enumerate-classify, candidate-inject) *collapsed* — 39–56 leaks, worse than doing
nothing — because they lost recall on easy cases the baseline nails (full names,
even a hardcoded API key). The two that **kept baseline's pass and added to it**
(dual-lens, residual-audit) were the only ones that helped. Lesson, matching a
prior on-device tournament: on a ~3B model, **augment the prompt that works;
don't replace it.**

## Reproduce
```sh
swift build
python3 evals/harness.py --strategies baseline,dual-lens,enumerate-classify,candidate-inject,fewshot,residual-audit --split dev
python3 evals/harness.py --strategies baseline,dual-lens --split holdout   # confirm
```

## Known follow-ups (strategy-independent, surfaced by the eval)
- **Structured-ID leaks** (`#4482`, `48213`, `C02XR4KTJGH5`, `acct_…`) are missing
  *regex detectors*, not a model failure — a cheap deterministic win.
- **Over-scrub** on essential values (Ontario/Okta/Ireland/Germany) is the
  `essential`-gate under-firing — a separate relevance-tuning problem, uniform
  across all strategies.
