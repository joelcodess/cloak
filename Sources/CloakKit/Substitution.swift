import Foundation

// MARK: - Substitution map + streaming rehydration
//
// The map is the load-bearing invariant of the whole system:
//   - COHERENT: the same real value always maps to the same fake.
//   - INJECTIVE: distinct reals map to distinct fakes — so rehydration is
//     unambiguous and "fails closed" (a fake we can't confidently map back
//     stays as the fake; we never surface the wrong real value).
// Substitution happens longest-first with word boundaries so short spans can't
// corrupt longer ones. Rehydration runs as a STREAMING replace with a
// carry-over buffer, because a fake can straddle two SSE text deltas — naive
// per-delta replace would leak the fake (and thus break the round-trip).

// Mutated only during scrub(); read-only thereafter (display, save, restore),
// so @unchecked Sendable is safe for handing the finished map across actors.
public final class SubstitutionMap: @unchecked Sendable {
    public private(set) var realToFake: [String: String] = [:]
    public private(set) var fakeToReal: [String: String] = [:]
    private var usedFakes: Set<String> = []

    public init() {}

    /// Bind a contextual span to a fake (idempotent, injective).
    public func bind(real: String, kind: PIIKind) -> String {
        if let f = realToFake[real] { return f }
        var nudge = 0
        var fake = Synthetics.fakeFor(kind: kind, real: real, nudge: nudge)
        while usedFakes.contains(fake) || fake == real {
            nudge += 7
            fake = Synthetics.fakeFor(kind: kind, real: real, nudge: nudge)
            if nudge > 700 { fake = "\(fake)-\(nudge)"; break }   // pathological guard
        }
        register(real: real, fake: fake)
        return fake
    }

    /// Bind a hard identifier to a format-preserving fake (idempotent, injective).
    public func bindHardID(real: String, kind: HardIDKind) -> String {
        if let f = realToFake[real] { return f }
        var nudge = 0
        var fake = Synthetics.fakeForHardID(kind: kind, real: real, nudge: nudge)
        while usedFakes.contains(fake) || fake == real {
            nudge += 7
            fake = Synthetics.fakeForHardID(kind: kind, real: real, nudge: nudge)
            if nudge > 700 { fake = "\(fake)\(nudge)"; break }
        }
        register(real: real, fake: fake)
        return fake
    }

    /// Adopt a pre-existing fake->real pair (used when rehydrating from a
    /// serialized mapping, e.g. the `cloak rehydrate` subcommand).
    @discardableResult
    public func adopt(fake: String, real: String) -> String {
        register(real: real, fake: fake)
        return fake
    }

    private func register(real: String, fake: String) {
        realToFake[real] = fake
        fakeToReal[fake] = real
        usedFakes.insert(fake)
    }

    public var longestFakeLength: Int { fakeToReal.keys.map(\.count).max() ?? 0 }
}

// MARK: - Outbound substitution

public enum Substitution {
    /// Replace every bound real value with its fake, longest-first and on word
    /// boundaries, so "Dana" doesn't get replaced inside "Danacorp" and a short
    /// span can't eat into a longer one.
    public static func apply(to text: String, map: SubstitutionMap) -> String {
        var result = text
        for real in map.realToFake.keys.sorted(by: { $0.count > $1.count }) {
            guard let fake = map.realToFake[real] else { continue }
            result = boundaryReplace(in: result, target: real, with: fake)
        }
        return result
    }

    /// Whole-token replace: the target may not be flanked by an alphanumeric
    /// character (so it matches as a standalone entity). Falls back to plain
    /// replace for targets that already contain non-word delimiters (emails,
    /// phones, multi-word org names), where boundary anchoring is unnecessary.
    public static func boundaryReplace(in text: String, target: String, with replacement: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: target)
        let pattern = "(?<![A-Za-z0-9])\(escaped)(?![A-Za-z0-9])"
        guard let rx = try? NSRegularExpression(pattern: pattern) else {
            return text.replacingOccurrences(of: target, with: replacement)
        }
        let ns = text as NSString
        let repl = NSRegularExpression.escapedTemplate(for: replacement)
        return rx.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length), withTemplate: repl)
    }
}

// MARK: - Streaming rehydration

/// Rehydrates a streamed cloud response (fake -> real) without leaking a fake
/// that straddles two chunks. Hold back a tail of (longestFake - 1) characters
/// on every feed; that tail can never be safely emitted because it might be the
/// prefix of an incomplete fake. flush() drains the remainder at stream end.
public final class StreamingRehydrator {
    private let map: SubstitutionMap
    private let fakesByLength: [String]
    private let keepBack: Int
    private var buffer = ""

    public init(map: SubstitutionMap) {
        self.map = map
        self.fakesByLength = map.fakeToReal.keys.sorted { $0.count > $1.count }
        self.keepBack = max(0, map.longestFakeLength - 1)
    }

    /// Feed a chunk of streamed text; returns the portion that is now safe to emit.
    public func feed(_ chunk: String) -> String {
        buffer += chunk
        buffer = replaceAll(buffer)
        guard buffer.count > keepBack else { return "" }
        let cut = buffer.index(buffer.endIndex, offsetBy: -keepBack)
        let emit = String(buffer[..<cut])
        buffer = String(buffer[cut...])
        return emit
    }

    /// Drain whatever is left once the stream is complete.
    public func flush() -> String {
        let out = replaceAll(buffer)
        buffer = ""
        return out
    }

    private func replaceAll(_ s: String) -> String {
        guard !fakesByLength.isEmpty else { return s }
        var r = s
        for fake in fakesByLength {
            if r.contains(fake), let real = map.fakeToReal[fake] {
                r = r.replacingOccurrences(of: fake, with: real)
            }
        }
        return r
    }
}
