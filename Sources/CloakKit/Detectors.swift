import Foundation

// MARK: - Regex fast-pass (deterministic, no model)
//
// praxis-cloak's biggest de-risker: hard identifiers with rigid formats are
// caught deterministically by regex BEFORE the model ever runs, and again as
// a final backstop sweep AFTER substitution. No model, no nondeterminism, no
// recall risk for these categories. The on-device model is then responsible
// only for the fuzzy contextual PII (names, employers, locations).
//
// NOTE: these patterns are US/English-centric (E.164/NANP phones, US SSN,
// 16-digit cards). Non-US identifiers (IBAN, national IDs) fall through to
// the model layer, which is weaker — a documented gap, see README.

// NSRegularExpression is documented thread-safe (immutable after creation) but
// isn't marked Sendable, so the compiled-once `all` table needs @unchecked.
struct RegexDetector: @unchecked Sendable {
    let kind: HardIDKind
    let pattern: NSRegularExpression
}

public enum HardIDKind: String {
    case email          = "email"
    case phone          = "phone"
    case ssn            = "ssn"
    case creditCard     = "credit_card"
    case ipAddress      = "ip_address"
    case apiKey         = "api_key"
    case ipv6           = "ipv6"
    case internalHost   = "internal_host"
}

enum Detectors {

    /// Compiled once. Order matters only for overlap resolution (longest-match
    /// wins downstream), not for correctness of any single detector.
    static let all: [RegexDetector] = {
        func rx(_ p: String) -> NSRegularExpression {
            // swiftlint:disable:next force_try
            try! NSRegularExpression(pattern: p, options: [.caseInsensitive])
        }
        return [
            // Email — RFC-ish, good enough for scrubbing.
            RegexDetector(kind: .email,
                pattern: rx(#"\b[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}\b"#)),
            // Long opaque API keys / tokens (sk-..., ghp_..., AKIA..., generic 32+ hex/base62).
            RegexDetector(kind: .apiKey,
                pattern: rx(#"\b(?:sk-[A-Za-z0-9\-_]{16,}|ghp_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|xox[baprs]-[A-Za-z0-9\-]{10,}|[A-Za-z0-9]{32,})\b"#)),
            // Provider-style secret keys + object IDs with distinctive prefixes
            // (Stripe et al.): sk_live_/pk_test_/rk_… and acct_/cus_/sub_/ch_/pi_…
            // These use underscores, so the generic 32+ rule above misses them.
            RegexDetector(kind: .apiKey,
                pattern: rx(#"\b(?:[a-z]{2}_(?:live|test)_[A-Za-z0-9]{8,}|(?:acct|cus|sub|ch|pi|in|price|prod|re|txn|seti|pm)_[A-Za-z0-9]{6,})\b"#)),
            // Internal / private hostnames — safe because the suffix is restricted
            // to non-public zones, so public domains are never matched.
            RegexDetector(kind: .internalHost,
                pattern: rx(#"\b[a-z0-9][a-z0-9.\-]*\.(?:internal|corp|local|lan|intranet)(?:\.[a-z]{2,})?\b"#)),
            // IPv4.
            RegexDetector(kind: .ipAddress,
                pattern: rx(#"\b(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)\b"#)),
            // IPv6 (loose).
            RegexDetector(kind: .ipv6,
                pattern: rx(#"\b(?:[A-F0-9]{1,4}:){2,7}[A-F0-9]{1,4}\b"#)),
            // Credit card — 13-16 digits, optional spaces/dashes between groups.
            RegexDetector(kind: .creditCard,
                pattern: rx(#"\b(?:\d[ \-]?){13,19}\b"#)),
            // US SSN.
            RegexDetector(kind: .ssn,
                pattern: rx(#"\b\d{3}-\d{2}-\d{4}\b"#)),
            // Phone — NANP / E.164-ish.
            RegexDetector(kind: .phone,
                pattern: rx(#"(?:\+?1[ \-.]?)?(?:\(\d{3}\)|\d{3})[ \-.]\d{3}[ \-.]\d{4}\b"#)),
        ]
    }()

    /// All hard-ID matches in `text`, as (range-in-string, matched substring, kind).
    /// Credit-card hits are Luhn-validated to avoid eating long ID numbers.
    static func scan(_ text: String) -> [(text: String, kind: HardIDKind)] {
        let ns = text as NSString
        var out: [(String, HardIDKind)] = []
        var seen = Set<String>()
        for det in all {
            for m in det.pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let s = ns.substring(with: m.range)
                let trimmed = s.trimmingCharacters(in: .whitespaces)
                if trimmed.count < 4 { continue }
                if det.kind == .creditCard && !luhnValid(trimmed) { continue }
                // Avoid the generic-32+ api_key rule swallowing pure-digit strings
                // that are really cards/ssn handled above.
                if det.kind == .apiKey && trimmed.allSatisfy({ $0.isNumber }) { continue }
                if seen.insert(trimmed).inserted {
                    out.append((trimmed, det.kind))
                }
            }
        }
        return out
    }

    /// Luhn checksum — keeps the card detector from flagging arbitrary digit runs.
    static func luhnValid(_ s: String) -> Bool {
        let digits = s.compactMap { $0.wholeNumberValue }
        guard digits.count >= 13 else { return false }
        var sum = 0
        for (i, d) in digits.reversed().enumerated() {
            if i % 2 == 1 {
                let doubled = d * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += d
            }
        }
        return sum % 10 == 0
    }
}
