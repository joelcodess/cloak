import Foundation

// MARK: - CSV / tabular-aware scrubbing
//
// The on-device model does poor NER on tabular data: with no sentence context
// it either ignores a row or grabs the whole comma-joined row as one span. So
// for CSV we bypass the model and classify COLUMNS by their header, then scrub
// the cells of PII-bearing columns deterministically. This is both far more
// reliable and format-appropriate (an "end users" export is the canonical case).
//
// v1 scope: header-driven. Recognized PII columns (names, org, location,
// identifiers) are scrubbed; known non-PII columns (title, department, status,
// dates, booleans) are left; unrecognized columns are left untouched (a
// free-text/"notes" column is a documented limitation — it is not model-scanned
// here). Regex fast-pass still runs over the whole text for emails/phones/keys.

public enum Tabular {

    /// Heuristic: real CSV, not prose-with-commas. Deliberately strict to avoid
    /// misrouting multi-line prose (which skips the model and leaks): needs a
    /// comma header with >=3 columns, >=2 data rows, and >=80% of data rows with
    /// EXACTLY the header's field count (prose comma-counts vary; CSV rows don't).
    public static func looksLikeCSV(_ text: String) -> Bool {
        // components(separatedBy: .newlines), not split(separator: "\n"):
        // "\r\n" is a single grapheme cluster in Swift, so a Character split on
        // "\n" never fires on CRLF files and the whole document reads as 1 line.
        let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard lines.count >= 3 else { return false }               // header + >=2 data rows
        let cols = parseRow(lines[0]).count
        guard cols >= 3, lines[0].contains(",") else { return false }
        let sample = Array(lines.dropFirst().prefix(30))
        let exact = sample.filter { parseRow($0).count == cols }.count
        return Double(exact) >= Double(sample.count) * 0.8
    }

    /// Column semantics inferred from the header cell.
    enum ColumnKind {
        case person, organization, location, identifier, skip
    }

    static func classify(header: String) -> ColumnKind {
        // snake_case / kebab-case exports ("contact_name", "org-name") must
        // match the space-separated needles below.
        let h = header.lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespaces)
        func has(_ needles: [String]) -> Bool { needles.contains { h.contains($0) } }

        // Username / email / login columns → identifier (emails also caught by regex).
        if has(["user name", "username", "login", "email", "e-mail", "upn", "userid", "user id"]) { return .identifier }
        if h == "mail" || h.hasSuffix(" mail") { return .identifier }
        // Device / machine identifiers.
        if has(["device name", "hostname", "host name", "computer", "machine name"]) { return .identifier }
        // Hard per-person identifiers.
        if has(["serial", "imei", "udid", "uuid", "agent id", "external id", "employee number",
                "employee id", "badge", "asset tag", "phone", "mobile", "tel", "fax", "ssn", "national id"]) { return .identifier }
        // Organization / customer.
        if has(["organization", "organisation", " org", "org ", "company", "employer",
                "customer", "tenant", "account name", "client"]) || h == "org" || h == "account" { return .organization }
        // Location.
        if has(["address", "street", "city", "state", "province", "country", "location",
                "region", "zip", "postal", "postcode"]) { return .location }
        // Person names (do this after the specific "* name" cases above so
        // "user name"/"device name" don't fall here).
        if has(["display name", "first name", "last name", "middle name", "full name",
                "preferred name", "contact name", "employee name", "manager", "owner",
                "assignee", "requester", "reports to", "assigned to", "employee",
                "attendee", "reporter", "staff"]) { return .person }
        if ["name", "contact", "person", "individual", "member", "user"].contains(h)
            || h.hasSuffix(" name") { return .person }
        // Everything else (title, department, division, type, status, active, dates…).
        return .skip
    }

    /// Detect + bind PII cells for a CSV `text`, returning scrubbed spans. Cells
    /// are bound in `map`; `seen` dedups across the whole document.
    public static func detect(_ text: String, map: SubstitutionMap, seen: inout Set<String>) -> [ScrubbedSpan] {
        let lines = text.components(separatedBy: .newlines)   // CRLF-safe; see looksLikeCSV
        guard let headerLine = lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return [] }
        let headers = parseRow(headerLine)
        let kinds = headers.map(classify)
        guard kinds.contains(where: { $0 != .skip }) else { return [] }

        var spans: [ScrubbedSpan] = []
        var passedHeader = false
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            if !passedHeader { passedHeader = true; continue }   // skip header row
            let cells = parseRow(line)
            for (i, cell) in cells.enumerated() where i < kinds.count {
                let value = cell.trimmingCharacters(in: .whitespaces)
                guard value.count >= 2 else { continue }
                let colKind = kinds[i]
                guard colKind != .skip else { continue }
                guard seen.insert(value).inserted else { continue }
                let piiKind: PIIKind
                switch colKind {
                case .person:        piiKind = .personName
                case .organization:  piiKind = .organization
                case .location:      piiKind = .location
                case .identifier:    piiKind = .otherSensitive
                case .skip:          continue
                }
                let fake = map.bind(real: value, kind: piiKind)
                spans.append(ScrubbedSpan(text: value, fake: fake, category: piiKind.rawValue,
                                          source: "csv", essential: false, scrubbed: true))
            }
        }
        return spans
    }

    // MARK: minimal RFC-4180-ish row parser (handles double-quoted fields)

    static func parseRow(_ line: String) -> [String] {
        var fields: [String] = []
        var field = ""
        var inQuotes = false
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" { field.append("\""); i += 1 }
                    else { inQuotes = false }
                } else { field.append(c) }
            } else if c == "\"" {
                inQuotes = true
            } else if c == "," {
                fields.append(field); field = ""
            } else {
                field.append(c)
            }
            i += 1
        }
        fields.append(field)
        return fields
    }
}
