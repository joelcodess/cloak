import Foundation

// MARK: - Scrub orchestration
//
// Mirrors praxis-cloak's fast_scrub ordering, adapted to one on-device model:
//   1. regex fast-pass (deterministic hard IDs)            — Detectors
//   2. on-device contextual NER + relevance keep-gate      — FoundationModelSpanFinder
//   3. bind every scrubbed span to a coherent fake         — SubstitutionMap
//   4. apply substitution (longest-first, word-boundary)   — Substitution
//   5. hard-ID backstop sweep on the scrubbed text         — Detectors (again)
// Essential (load-bearing) contextual spans are KEPT, not scrubbed — but hard
// IDs are always scrubbed regardless, because a raw SSN/card/email is never
// something the cloud model needs verbatim.

public struct ScrubResult: @unchecked Sendable {  // map is a class, treated read-only post-scrub
    public var scrubbed: String
    public var spans: [ScrubbedSpan]
    public var map: SubstitutionMap
    /// Non-fatal degradations (e.g. Apple's model guardrail refused a section).
    /// Surfaced so callers can tell the user a section was only pattern-scrubbed.
    public var warnings: [String] = []
}

public struct ScrubbedSpan: Identifiable, Sendable {
    public let id = UUID()
    public var text: String
    public var fake: String
    public var category: String
    public var source: String      // "regex" | "model"
    public var essential: Bool
    public var scrubbed: Bool      // false when kept (essential)
}

public struct ScrubEngine: Sendable {
    /// Character budget per model call. The on-device window is ~4096 tokens
    /// total; a ~4000-char payload budget leaves room for
    /// instructions + output. Long inputs are chunked with overlap so an entity
    /// split across a boundary still gets seen in one window.
    public var chunkBudget = 3500
    public var chunkOverlap = 200

    let finder = FoundationModelSpanFinder()

    public init() {}

    public func scrub(_ text: String) async throws -> ScrubResult {
        let map = SubstitutionMap()
        var spans: [ScrubbedSpan] = []
        var seenReal = Set<String>()
        var warnings: [String] = []

        // 1) Regex fast-pass — always scrubbed, deterministic.
        for hit in Detectors.scan(text) where seenReal.insert(hit.text).inserted {
            let fake = map.bindHardID(real: hit.text, kind: hit.kind)
            spans.append(ScrubbedSpan(text: hit.text, fake: fake, category: hit.kind.rawValue,
                                      source: "regex", essential: false, scrubbed: true))
        }

        // 2) Contextual layer. Tabular data (CSV) is handled column-wise —
        //    deterministic and far more reliable than model NER on cells, which
        //    grabs whole rows. Free-text goes to the on-device model, chunked.
        if Tabular.looksLikeCSV(text) {
            spans.append(contentsOf: Tabular.detect(text, map: map, seen: &seenReal))
        } else {
        // Model availability is a hard failure (checked once); a per-chunk
        // generation error (e.g. Apple's safety guardrail false-firing) is NOT —
        // we skip that chunk's contextual detection, keep the regex fast-pass,
        // and warn, rather than aborting the whole document scrub.
        if let reason = FoundationModelSpanFinder.availabilityError() {
            throw FoundationModelError.unavailable(reason)
        }
        for chunk in Self.chunk(text, budget: chunkBudget, overlap: chunkOverlap) {
            let detected: [PIISpan]
            do {
                detected = try await finder.detect(in: chunk)
            } catch {
                warnings.append("A section couldn't be analyzed by the on-device model (\(error)); only pattern-based detectors ran on it — review that section for names/orgs.")
                continue
            }
            for span in detected where seenReal.insert(span.text).inserted {
                // Essential contextual spans are kept (not scrubbed); everything
                // else is bound to a coherent fake.
                if span.essential {
                    spans.append(ScrubbedSpan(text: span.text, fake: span.text,
                                              category: span.kind.rawValue, source: "model",
                                              essential: true, scrubbed: false))
                } else {
                    let fake = map.bind(real: span.text, kind: span.kind)
                    spans.append(ScrubbedSpan(text: span.text, fake: fake,
                                              category: span.kind.rawValue, source: "model",
                                              essential: false, scrubbed: true))
                }
            }
        }
        }

        // 3+4) Apply substitution for everything bound in the map.
        var scrubbed = Substitution.apply(to: text, map: map)

        // 5) Hard-ID backstop — catch any identifier that survived (e.g. a new
        //    one the model surfaced as text). Bind + replace anything still raw.
        for hit in Detectors.scan(scrubbed) {
            // If it's already a fake we generated — or a fragment of one — skip,
            // so the backstop never re-scrubs our own synthetic values.
            if map.fakeToReal[hit.text] != nil { continue }
            if map.realToFake.values.contains(where: { $0.contains(hit.text) }) { continue }
            let fake = map.bindHardID(real: hit.text, kind: hit.kind)
            scrubbed = Substitution.boundaryReplace(in: scrubbed, target: hit.text, with: fake)
            if seenReal.insert(hit.text).inserted {
                spans.append(ScrubbedSpan(text: hit.text, fake: fake, category: hit.kind.rawValue,
                                          source: "regex-backstop", essential: false, scrubbed: true))
            }
        }

        return ScrubResult(scrubbed: scrubbed, spans: spans, map: map, warnings: warnings)
    }

    /// Split into overlapping windows on paragraph/sentence boundaries where
    /// possible, falling back to a hard character cut.
    static func chunk(_ text: String, budget: Int, overlap: Int) -> [String] {
        if text.count <= budget { return [text] }
        var chunks: [String] = []
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let end = min(i + budget, chars.count)
            var cut = end
            if end < chars.count {
                // Prefer to break on a newline or space within the last 200 chars.
                let lo = max(i + budget - 200, i + 1)
                if let nl = (lo..<end).reversed().first(where: { chars[$0] == "\n" || chars[$0] == " " }) {
                    cut = nl + 1
                }
            }
            chunks.append(String(chars[i..<cut]))
            if cut >= chars.count { break }
            // Step back by `overlap` to preserve entities split across a boundary,
            // but always make forward progress past the previous window start.
            let next = cut - overlap
            i = next > i ? next : cut
        }
        return chunks
    }
}
