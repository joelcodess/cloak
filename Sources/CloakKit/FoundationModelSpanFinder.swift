import Foundation
import FoundationModels

// MARK: - On-device PII span detection via Apple Foundation Models
//
// praxis-cloak uses TWO fine-tuned Qwen-3B models: spanfinder-3b (NER) and
// relevance-3b (keep-gate). Apple gives third-party apps exactly ONE shared
// ~3B base model and no way to load Qwen weights, so we collapse both jobs
// into a single call: each detected span carries a `kind` AND an `essential`
// flag (the relevance keep-gate).
//
// Output format: we ask the model for one span per line as
//     verbatim text | kind | essential
// and parse it defensively. (praxis-cloak's spanfinder-3b uses the same
// "SPAN | CATEGORY" line shape.) The cleaner path is Apple's @Generable
// constrained decoding, but that macro plugin ships only with full Xcode;
// this build targets Command Line Tools only, so we parse text and lean on
// the regex backstop for recall.
// UPGRADE: when building under full Xcode, swap parse() for a @Generable
// [PIISpan] result to get a format guarantee for free (see README).
//
// Honest limitation (measured, see evals/): the base model
// is mediocre at exactly this NER discrimination, so the regex fast-pass owns
// the hard IDs and this layer is responsible only for the fuzzy contextual
// PII (names, employers, "a company called X", relationships, locations).
// The eval harness exists precisely to measure and harden this layer.

/// Kinds of contextual PII the on-device model is asked to surface.
public enum PIIKind: String {
    case personName        = "person_name"
    case organization      = "organization"
    case location          = "location"
    case jobTitle          = "job_title"
    case relationship      = "relationship"
    case projectOrProduct  = "project_or_product"
    case otherSensitive    = "other_sensitive"

    /// Lenient mapping from whatever label the model emits to a known kind.
    static func parse(_ raw: String) -> PIIKind {
        let k = raw.lowercased().trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "-", with: "_")
        if let exact = PIIKind(rawValue: k) { return exact }
        switch k {
        case "name", "person", "people", "full_name": return .personName
        case "org", "company", "employer", "client", "business", "school", "university": return .organization
        case "place", "city", "address", "venue", "country", "region": return .location
        case "title", "role", "position": return .jobTitle
        case "relation", "family", "spouse", "manager", "colleague": return .relationship
        case "project", "product", "codename", "internal_project": return .projectOrProduct
        default: return .otherSensitive
        }
    }
}

/// One detected span. `essential` is the keep-gate: when true the detail is
/// load-bearing for the answer and should survive (not be scrubbed).
public struct PIISpan {
    public var text: String
    public var kind: PIIKind
    public var essential: Bool
}

enum FoundationModelError: Error, CustomStringConvertible {
    case unavailable(String)

    var description: String {
        switch self {
        case .unavailable(let reason): return reason
        }
    }
}

public struct FoundationModelSpanFinder: Sendable {

    public init() {}

    /// Structured-reasoning instructions. A prior on-device tournament showed
    /// that forcing enumerate -> classify beats free-form on look-alike
    /// discrimination (0.76 -> 0.94); PII boundary/label disambiguation is the
    /// same failure mode, so we lean on the same shape here.
    static let instructions = """
    You are a privacy scrubber. You are given a chunk of text that a user is about to send to a cloud AI service. Find every piece of personally identifying or sensitive information (PII) so it can be replaced with a realistic fake before it leaves the machine. The fake is later swapped back in the reply, so replacing a name does NOT harm the answer.

    Think in two steps: first ENUMERATE every candidate (real people's names, organizations/employers/clients, specific locations, job titles tied to a person, relationships like "my wife" or "my manager Dana", and named internal projects/products); then for each decide its kind and whether it is essential.

    Output format — ONE span per line, nothing else, no commentary, no numbering:
    <verbatim text> | <kind> | <essential>

    where <kind> is one of: person_name, organization, location, job_title, relationship, project_or_product, other_sensitive
    and <essential> is yes or no.

    ESSENTIAL is RARE. Default to no. Answer yes ONLY when the request is a factual/lookup question whose CORRECT answer depends on this exact real value — e.g. "what are the knife laws in Miami" (the city changes the legal answer), or "what does company X's public API return" (the real org changes the facts). For drafting, writing, summarizing, brainstorming, coding, or any task where a realistic stand-in would work just as well, essential is ALWAYS no. When unsure, answer no (scrub it).

    Other rules:
    - Copy the span text VERBATIM from the input — same casing, no quotes, no paraphrase.
    - Prefer to over-detect real names, employers, and locations. When unsure whether something names a specific real entity, include it (with essential=no).
    - Do NOT flag generic words, common nouns, programming/technical terms, or well-known public product names that carry no personal information.
    - If there is no PII, output the single line: NONE
    """

    /// True when the on-device model is ready to use.
    public static func availabilityError() -> String? {
        if case .unavailable(let reason) = SystemLanguageModel.default.availability {
            return friendly(reason)
        }
        return nil
    }

    /// Detect PII spans in a single chunk that fits the model's context window.
    /// Greedy decoding makes this deterministic — essential for the eval
    /// harness and for prompt-cache stability downstream.
    public func detect(in text: String, maxTokens: Int = 1024) async throws -> [PIISpan] {
        if let reason = Self.availabilityError() {
            throw FoundationModelError.unavailable(reason)
        }
        // Strategy dispatch (see Strategies.swift). CLOAK_STRATEGY selects the
        // harness variant; "dual-lens" is the shipping default (tournament winner).
        return try await Self.run(strategy: Self.activeStrategy(), on: text, maxTokens: maxTokens)
    }

    /// Defensive parser for the `text | kind | essential` line format. Drops
    /// blank/NONE lines and any span whose text does not actually occur in the
    /// source (a cheap guard against the model paraphrasing or hallucinating).
    static func parse(_ raw: String, source: String) -> [PIISpan] {
        var out: [PIISpan] = []
        var seen = Set<String>()
        for lineRaw in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = lineRaw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.uppercased() == "NONE" { continue }
            // Tolerate "1. ", "- ", "* " prefixes the model sometimes adds.
            let cleaned = line.drop(while: { $0 == "-" || $0 == "*" || $0 == " " || $0.isNumber || $0 == "." })
            let parts = cleaned.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let first = parts.first, !first.isEmpty else { continue }
            let text = first
            guard source.contains(text) else { continue }   // verbatim guard
            // Sanity guard: a PII span is a short entity, never a sentence. The
            // small model sometimes returns the whole input as one span, which
            // would nuke everything to a single fake — reject those.
            if text.count > 64 { continue }
            if text.split(whereSeparator: { $0 == " " }).count > 8 { continue }
            if text.contains("?") || text.contains("!") || text.contains("\n") { continue }
            if !seen.insert(text).inserted { continue }      // dedup
            let kind = parts.count > 1 ? PIIKind.parse(parts[1]) : .otherSensitive
            let essential = parts.count > 2 && ["yes", "true", "1", "y"].contains(parts[2].lowercased())
            out.append(PIISpan(text: text, kind: kind, essential: essential))
        }
        return out
    }

    private static func friendly(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible:
            return "This Mac isn't eligible for Apple Intelligence (on-device Foundation Models)."
        case .appleIntelligenceNotEnabled:
            return "Apple Intelligence is off. Enable it in System Settings ▸ Apple Intelligence & Siri."
        case .modelNotReady:
            return "The on-device model is still downloading or warming up. Try again shortly."
        @unknown default:
            return "The on-device model is unavailable for an unknown reason."
        }
    }
}
