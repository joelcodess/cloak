import Foundation

// MARK: - Format-preserving fake generation (deterministic)
//
// praxis-cloak's substitution produces REAL-LOOKING fakes, never [REDACTED] —
// so the cloud model reasons over coherent text and the answer reads naturally
// before rehydration. Fakes are:
//   - deterministic: same real value -> same fake (seeded by a stable hash, not
//     a per-run RNG), so repeated turns produce identical bytes. This is what
//     keeps Anthropic prompt-caching alive (cache keys are exact-byte prefixes).
//   - format-preserving: a phone stays a phone, an email stays an email, so the
//     scrubbed text is still well-formed.
// Injectivity (distinct reals -> distinct fakes) is enforced by SubstitutionMap,
// not here; this type just proposes a candidate fake from a counter nudge.

enum Synthetics {

    // Small curated pools. Hash selects an index, so selection is stable.
    private static let firstNames = [
        "Avery", "Quinn", "Rowan", "Sage", "Reese", "Emerson", "Harper", "Marlowe",
        "Sutton", "Ellis", "Blair", "Dakota", "Lennox", "Tatum", "Sloane", "Phoenix",
    ]
    private static let lastNames = [
        "Hartley", "Whitfield", "Castellano", "Nakamura", "Okafor", "Lindqvist",
        "Bauer", "Delgado", "Ashford", "Petrova", "Sinclair", "Vance", "Mercer", "Calloway",
    ]
    private static let companies = [
        "Northwind Labs", "Cobalt Systems", "Meridian Works", "Brightpath",
        "Larkspur Technologies", "Ironvale", "Solstice Dynamics", "Veraxis", "Tidemark",
    ]
    private static let cities = [
        "Brookhaven", "Fairmont", "Cedar Falls", "Port Alden", "Westbrook",
        "Glenmoor", "Ashbury", "Lakeshore", "Stonebridge", "Riverton",
    ]
    private static let titles = [
        "Operations Lead", "Account Director", "Staff Engineer", "Program Manager",
        "Regional Coordinator", "Principal Analyst", "Head of Delivery",
    ]
    private static let projects = [
        "Project Lighthouse", "Project Mistral", "Project Cascade", "Project Harbor",
        "Project Verdant", "Project Tessera", "Project Anvil",
    ]
    private static let relationships = [
        "my colleague", "my manager", "my teammate", "my client", "my partner",
    ]

    /// Stable 64-bit FNV-1a hash — deterministic across runs (unlike Swift's
    /// per-process-seeded Hasher), so fakes are reproducible.
    static func stableHash(_ s: String, salt: UInt64 = 0) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325 &+ salt
        for b in s.utf8 {
            h = (h ^ UInt64(b)) &* 0x100000001b3
        }
        return h
    }

    private static func pick(_ pool: [String], _ key: String, _ nudge: Int) -> String {
        pool[Int((stableHash(key, salt: UInt64(nudge)) % UInt64(pool.count)))]
    }

    /// Propose a fake for `real` of a given contextual kind. `nudge` is bumped by
    /// the SubstitutionMap when a proposed fake collides with one already in use.
    static func fakeFor(kind: PIIKind, real: String, nudge: Int) -> String {
        switch kind {
        case .personName:
            // Preserve single-token vs full-name shape.
            if real.contains(" ") {
                return "\(pick(firstNames, real, nudge)) \(pick(lastNames, real, nudge + 1))"
            }
            // A bare first name stays a bare name; a Capitalized surname-ish token too.
            return pick(firstNames, real, nudge)
        case .organization:    return pick(companies, real, nudge)
        case .location:        return pick(cities, real, nudge)
        case .jobTitle:        return pick(titles, real, nudge)
        case .projectOrProduct: return pick(projects, real, nudge)
        case .relationship:    return pick(relationships, real, nudge)
        case .otherSensitive:  return "[redacted-\(stableHash(real, salt: UInt64(nudge)) % 9973)]"
        }
    }

    /// Format-preserving fake for a hard identifier.
    static func fakeForHardID(kind: HardIDKind, real: String, nudge: Int) -> String {
        let h = stableHash(real, salt: UInt64(nudge))
        func digits(_ n: Int, _ seed: UInt64) -> String {
            var s = ""; var x = seed | 1
            for _ in 0..<n { x = x &* 6364136223846793005 &+ 1442695040888963407; s += String((x >> 33) % 10) }
            return s
        }
        switch kind {
        case .email:
            let user = pick(firstNames, real, nudge).lowercased()
            return "\(user)\(h % 100)@example.com"
        case .phone:
            let d = digits(7, h)
            return "(555) \(d.prefix(3))-\(d.suffix(4))"
        case .ssn:
            let d = digits(9, h)
            return "\(d.prefix(3))-\(d.dropFirst(3).prefix(2))-\(d.suffix(4))"
        case .creditCard:
            // Build a 16-digit Luhn-valid number deterministically.
            return luhnCard(seed: h)
        case .ipAddress:
            return "10.\(h % 256).\((h >> 8) % 256).\((h >> 16) % 256)"
        case .ipv6:
            return "fd00::\(String(h % 65536, radix: 16)):\(String((h >> 16) % 65536, radix: 16))"
        case .apiKey:
            // Preserve the recognizable SCHEME prefix only (never the secret
            // body — splitting on "-" would embed a dashless real key verbatim).
            // Keep the body in <32-char hyphenated groups so the generic
            // 32+-alnum detector can't re-flag fragments of our own fake.
            let lower = real.lowercased()
            let prefix: String
            if lower.hasPrefix("sk-ant") { prefix = "sk-ant-" }
            else if lower.hasPrefix("sk-") { prefix = "sk-" }
            else if lower.hasPrefix("ghp_") { prefix = "ghp_" }
            else if real.hasPrefix("AKIA") { prefix = "AKIA" }
            else if lower.hasPrefix("xox") { prefix = String(real.prefix(5)) + "-" }
            // Provider prefixes with underscores (sk_live_, acct_, cus_, …):
            // preserve everything through the trailing underscore of the scheme.
            else if let r = real.range(of: #"^[a-z]{2}_(?:live|test)_"#, options: .regularExpression) { prefix = String(real[r]) }
            else if let r = real.range(of: #"^[a-z]{2,6}_"#, options: .regularExpression) { prefix = String(real[r]) }
            else { prefix = "key-" }
            let b1 = String(format: "%012llx", h % 0x1000000000000)
            let b2 = String(format: "%012llx", (h &* 1099511628211) % 0x1000000000000)
            return "\(prefix)\(b1)-\(b2)"
        case .internalHost:
            // Preserve the private-zone suffix; fake the host label.
            let suffix = real.range(of: #"\.(?:internal|corp|local|lan|intranet)(?:\.[a-z]{2,})?$"#, options: .regularExpression)
                .map { String(real[$0]) } ?? ".internal"
            return "host-\(String(format: "%08llx", h % 0x100000000))\(suffix)"
        }
    }

    private static func luhnCard(seed: UInt64) -> String {
        var x = seed | 1
        var ds: [Int] = []
        for _ in 0..<15 { x = x &* 6364136223846793005 &+ 1442695040888963407; ds.append(Int((x >> 33) % 10)) }
        // Compute check digit so the whole 16 passes Luhn.
        var sum = 0
        for (i, d) in ds.reversed().enumerated() {
            // positions: check digit will be index 0 (even from right); existing
            // 15 digits occupy right-positions 1..15, so doubling applies at even i here.
            if i % 2 == 0 {
                let doubled = d * 2; sum += doubled > 9 ? doubled - 9 : doubled
            } else { sum += d }
        }
        let check = (10 - (sum % 10)) % 10
        let all = ds + [check]
        return stride(from: 0, to: 16, by: 4).map { i in
            all[i..<min(i + 4, 16)].map(String.init).joined()
        }.joined(separator: " ")
    }
}
