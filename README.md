# 🧥 cloak

Local **PII scrubbing** built on **Apple's on-device Foundation Models**. Swaps
your sensitive entities for realistic fakes *before* text leaves your machine,
then rehydrates the real values back into any reply you paste back. 100%
on-device detection, no third-party service. Ships in two forms:

- **Cloak.app** — a native macOS app: drop in a document (.txt/.md/.csv/.json/code,
  **.docx**, **.pdf**), get a scrubbed file + a saved mapping; later paste the
  cloud LLM's reply into **Restore** to reverse the fakes. This is the primary UI.
- **cloak CLI** — `scrub`, `scrub-file`, `rehydrate`, `doctor`, and an
  (experimental) Anthropic-compatible `proxy`.

## The macOS app

```sh
./scripts/make-app.sh          # build + bundle (Command Line Tools, no Xcode)
open ./Cloak.app               # first run: right-click ▸ Open (unnotarized)
```

- **Scrub pane** — drop a document or Choose File. cloak extracts the text, scrubs
  it on-device, shows the scrubbed text + a table of every detected span
  (original → replacement, type), and auto-saves the mapping. "Save Scrubbed File…"
  writes the result in the original format (.docx keeps its formatting; .pdf saves
  as .txt since PDF layout can't be rebuilt).
- **Restore pane** — pick a recent scrub (or load a `.cloakmap.json`), paste the
  reply that came back from the cloud LLM, and Restore reverses fakes → real values.

Mappings are saved to `~/Library/Application Support/Cloak/mappings/` as flat
`{fake: real}` JSON — byte-identical to what `cloak rehydrate` reads, so the app and
CLI interoperate.

## Why this shape (not a Claude Code proxy)

Putting cloak in front of Claude Code on a Pro/Max subscription isn't viable —
Anthropic's 2026 ToS forbids using subscription OAuth outside the official client,
and ~30 auth/admin endpoints bypass a custom base URL. So cloak is its own surface:
scrub a document → take the scrubbed text to any cloud LLM yourself → paste the
result back to restore. (The CLI `proxy` still works with a Console API key.)

Inspired by [praxis-cloak](https://github.com/Praxis-Society/praxis-cloak)
(which uses two fine-tuned Qwen-3B models via Ollama). cloak rebuilds the same
idea on Apple Intelligence's single on-device model — see
[The crux](#the-crux-one-model-no-fine-tuning) for what that costs.

```
you ──▶ Claude Code ──/v1/messages──▶  cloak proxy (localhost)  ──▶ api.anthropic.com
                                        │  scrub: regex + on-device model
        rehydrated reply ◀── fake→real ─┘  forward fakes only, real key held here
```

## How it works

A pipeline modelled on praxis-cloak's `fast_scrub`, adapted to one local model:

1. **Regex fast-pass** (`Detectors.swift`) — emails, phones, SSNs, credit cards
   (Luhn-checked), IPs, API keys (incl. provider keys like `sk_live_…`/`acct_…`),
   internal hostnames. Deterministic, no model, no recall risk. This is the
   biggest de-risker: hard identifiers never depend on the LLM.
1b. **CSV / tabular path** (`Tabular.swift`) — the on-device model does poor NER
   on tabular cells (it grabs whole rows), so CSV input is detected and scrubbed
   **column-wise**: headers are classified (name/org/location/identifier vs.
   non-PII like title/department/status) and PII columns are scrubbed
   deterministically. This is the reliable path for exports like a user roster.
2. **On-device contextual NER + relevance** (`FoundationModelSpanFinder.swift`) —
   Apple's `SystemLanguageModel` finds names, employers, locations, job titles,
   relationships, and internal project codenames, and flags whether each is
   *essential* (load-bearing for a factual answer). Greedy decoding → deterministic.
3. **Deterministic substitution** (`Synthetics.swift`, `Substitution.swift`) —
   each real value maps to a coherent, format-preserving fake. The map is
   **injective** (distinct reals → distinct fakes) so rehydration is unambiguous
   and **fails closed**: a value it can't confidently map back stays as the fake,
   never the wrong real value. Fakes are seeded by a stable hash so the same real
   always produces the same bytes — which keeps Anthropic prompt-caching alive.
4. **Hard-ID backstop** — a final regex sweep over the scrubbed text catches any
   identifier that slipped through, without re-scrubbing our own fakes.
5. **Streaming rehydration** (`StreamingRehydrator`) — reverses fake→real on the
   live SSE stream, holding back a carry-over tail so a fake straddling two
   `text_delta` chunks can't leak.

`essential` spans are **kept** (not scrubbed) because substituting them would
change a factual answer (e.g. "knife laws in *Miami*"). For drafting/coding/
summarizing, nothing is essential — the fake round-trips losslessly.

## Requirements

- macOS 26+ on Apple Silicon, **Apple Intelligence enabled** (System Settings ▸
  Apple Intelligence & Siri) with the on-device model downloaded.
- Swift 6.3+. **Command Line Tools is enough** — full Xcode not required.

## Build & install

```sh
swift build -c release
ln -sf "$PWD/.build/release/cloak" ~/.local/bin/cloak
cloak doctor          # confirm the on-device model is available
```

## Use

### As a scrubber (testable now)

```sh
echo "Email jordan@example.com about Hermes for Jordan Ellison at Kestrel Systems in Miami" | cloak scrub
# → Email lennox20@example.com about Project Tessera for Ellis Sinclair at Ironvale in Stonebridge

cloak scrub --json    # full result: scrubbed text + spans + fake→real mapping
```

### In front of Claude Code (the proxy)

```sh
export ANTHROPIC_API_KEY=sk-ant-...        # held by the proxy, never sent to the model
cloak proxy --port 8765 &
ANTHROPIC_BASE_URL=http://localhost:8765 claude
```

The proxy forwards every request to `api.anthropic.com` and scrubs/rehydrates
`/v1/messages`. Inbound is plain HTTP on localhost; the only TLS hop is the
outbound one to Anthropic.

> **Status.** The scrub engine and eval loop are exercised directly and pass.
> The proxy's request→scrub→forward→response pipe is verified against the live
> API; its **streaming SSE rehydration** is built but still needs a real
> end-to-end Claude Code session to road-test. Treat the proxy as beta.

## The crux: one model, no fine-tuning

praxis-cloak's edge is **two fine-tuned** Qwen-3B models (one for NER, one for
relevance). Apple gives third-party apps **one shared ~3B base model** and no way
to load Qwen weights. cloak closes the gap as far as it can — regex owns the hard
IDs, and structured-reasoning prompting (an enumerate-then-classify trick that
lifted look-alike accuracy 0.76→0.94 in a prior on-device CLI experiment) drives
the contextual layer — but the base model is genuinely **mediocre at fuzzy
contextual NER**. The eval harness exists to measure and shrink that gap.

**Known gaps** (all surfaced by `evals/`):
- Bare first names in context ("my colleague Devon") and invented codenames
  ("Bluejay", "Foundry") are sometimes missed by the model.
- CSV scrubbing is header-driven: a free-text/"notes" column or an unrecognized
  header is left untouched (not model-scanned), and fakes are bound per cell, so
  a full-name column won't match its first/last columns after scrubbing.
- Detectors are US/English-centric; non-US identifiers (IBAN, national IDs) fall
  to the weaker model layer.
- Proxy v0 leaves `tool_use.input` JSON un-scrubbed (text content blocks only).

**Upgrade path (full Xcode):** swap the line-format parse in
`FoundationModelSpanFinder` for a `@Generable [PIISpan]` result to get Apple's
constrained-decoding format guarantee for free. The macro plugin ships only with
full Xcode, so this CLT-only build parses text and leans on the regex backstop.

## Evals

See [`evals/`](evals/). The harness drives `cloak scrub --json` over a labeled
dataset and scores **leaks** (gold PII surviving verbatim — the metric that
matters), **recall**, and **over-scrub**. Greedy decoding makes scores stable;
results are cached by input hash.

```sh
python3 evals/harness.py            # score the dataset
python3 evals/harness.py --no-cache # force re-scrub after a change
```

The default detection harness (`dual-lens`) was chosen by a **tournament** of six
strategies over a 52-case dev/holdout dataset — see [`evals/TOURNAMENT.md`](evals/TOURNAMENT.md).
It runs the generalist pass plus a narrow "name-hunter" pass and unions them, so it
strictly dominates the single-pass baseline (dev: recall 0.828 → 0.901, leaks 13 → 8).
Switch harnesses with `CLOAK_STRATEGY=<name>` (baseline, dual-lens, fewshot,
enumerate-classify, candidate-inject, residual-audit); the eval harness compares
them with `--strategies a,b,c` and gates the pick on the holdout split.

## License

MIT.
