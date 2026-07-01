import Foundation
import CloakKit

// Persists each scrub's real↔fake mapping so Restore works at any later time.
// Files live in ~/Library/Application Support/Cloak/mappings/ and are named
// "<epoch>-<source>.cloakmap.json". The payload is a flat {fake: real} dict —
// byte-identical to what the `cloak rehydrate` CLI reads, so CLI and app share.

struct ScrubRecord: Identifiable, Hashable {
    let id: String          // file name (stable, unique)
    let sourceName: String
    let date: Date
    let url: URL
}

enum MappingStore {
    static let dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("Cloak/mappings", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    /// Persist a finished scrub's mapping. `epoch` is passed in (the view model
    /// stamps the time) so this stays a pure function of its inputs.
    @discardableResult
    static func save(sourceName: String, map: SubstitutionMap, epoch: TimeInterval) throws -> ScrubRecord {
        let safe = sanitize(sourceName)
        let name = "\(Int(epoch))-\(safe).cloakmap.json"
        let url = dir.appendingPathComponent(name)
        let data = try JSONSerialization.data(withJSONObject: map.fakeToReal,
                                              options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url)
        return ScrubRecord(id: name, sourceName: sourceName, date: Date(timeIntervalSince1970: epoch), url: url)
    }

    /// Recent scrubs, newest first.
    static func recent(limit: Int = 40) -> [ScrubRecord] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" && $0.lastPathComponent.hasSuffix(".cloakmap.json") }
            .compactMap { record(from: $0) }
            .sorted { $0.date > $1.date }
            .prefix(limit)
            .map { $0 }
    }

    /// Rebuild a SubstitutionMap from a saved (or user-picked) `.cloakmap.json`.
    static func loadMap(from url: URL) throws -> SubstitutionMap {
        let data = try Data(contentsOf: url)
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: String] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let map = SubstitutionMap()
        for (fake, real) in dict { map.adopt(fake: fake, real: real) }
        return map
    }

    // MARK: helpers

    private static func record(from url: URL) -> ScrubRecord? {
        let name = url.lastPathComponent                      // "<epoch>-<source>.cloakmap.json"
        let stem = name.replacingOccurrences(of: ".cloakmap.json", with: "")
        guard let dash = stem.firstIndex(of: "-") else { return nil }
        let epochStr = String(stem[..<dash])
        let source = String(stem[stem.index(after: dash)...])
        let epoch = TimeInterval(epochStr) ?? 0
        return ScrubRecord(id: name, sourceName: source.isEmpty ? "document" : source,
                           date: Date(timeIntervalSince1970: epoch), url: url)
    }

    private static func sanitize(_ s: String) -> String {
        let base = (s as NSString).deletingPathExtension
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_")
        let cleaned = String(base.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return cleaned.isEmpty ? "document" : String(cleaned.prefix(40))
    }
}
