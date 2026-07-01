import Foundation
import CloakKit

@MainActor
final class CloakViewModel: ObservableObject {
    // Shared / status
    @Published var isWorking = false
    @Published var statusText = ""
    @Published var errorMessage: String?
    @Published var availabilityWarning: String?

    // Scrub pane
    @Published var loadedDoc: DocText?
    @Published var scrubbedText = ""
    @Published var spans: [ScrubbedSpan] = []
    @Published private(set) var currentMap: SubstitutionMap?
    @Published var sourceName = ""

    // Restore pane
    @Published var recent: [ScrubRecord] = []
    @Published var selectedRecordID: String?
    @Published var restoreInput = ""
    @Published var restoredText = ""

    private let engine = ScrubEngine()

    init() {
        availabilityWarning = FoundationModelSpanFinder.availabilityError()
        refreshRecent()
    }

    var modelAvailable: Bool { availabilityWarning == nil }

    // MARK: Scrub

    func loadAndScrub(url: URL) {
        errorMessage = nil
        do {
            let doc = try DocumentIO.readText(from: url)
            loadedDoc = doc
            sourceName = url.lastPathComponent
            scrub(doc: doc)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func scrub(doc: DocText) {
        guard modelAvailable else {
            errorMessage = availabilityWarning
            return
        }
        isWorking = true
        statusText = "Scrubbing \(sourceName)…"
        scrubbedText = ""; spans = []; currentMap = nil
        let engine = self.engine
        Task {
            do {
                let result = try await engine.scrub(doc.text)
                let record = try MappingStore.save(sourceName: sourceName,
                                                   map: result.map,
                                                   epoch: Date().timeIntervalSince1970)
                self.scrubbedText = result.scrubbed
                self.spans = result.spans
                self.currentMap = result.map
                let scrubbedCount = result.spans.filter { $0.scrubbed }.count
                self.statusText = "Scrubbed \(scrubbedCount) item(s); mapping saved."
                // Non-fatal degradations (e.g. model guardrail refused a section).
                self.availabilityWarning = result.warnings.isEmpty ? nil
                    : "\(result.warnings.count) section(s) were only pattern-scrubbed by the fast-pass; review them for names/orgs."
                self.refreshRecent()
                self.selectedRecordID = record.id
            } catch {
                self.errorMessage = String(describing: error)
                self.statusText = ""
            }
            self.isWorking = false
        }
    }

    /// Write the scrubbed document to `url` in its original format.
    func saveScrubbed(to url: URL) {
        guard let doc = loadedDoc, let map = currentMap else { return }
        do {
            try DocumentIO.writeScrubbed(doc: doc, scrubbedFullText: scrubbedText, map: map, to: url)
            statusText = "Saved scrubbed file → \(url.lastPathComponent)"
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func suggestedOutputURL() -> URL? {
        guard let doc = loadedDoc else { return nil }
        return DocumentIO.suggestedOutputURL(for: doc)
    }

    // MARK: Restore

    func refreshRecent() {
        recent = MappingStore.recent()
        if selectedRecordID == nil { selectedRecordID = recent.first?.id }
    }

    func restore(usingRecordID id: String?) {
        errorMessage = nil
        guard let id, let record = recent.first(where: { $0.id == id }) else {
            errorMessage = "Choose a saved scrub (or load a mapping file) first."
            return
        }
        restore(mapURL: record.url)
    }

    func restore(mapURL: URL) {
        do {
            let map = try MappingStore.loadMap(from: mapURL)
            let r = StreamingRehydrator(map: map)
            var out = r.feed(restoreInput); out += r.flush()
            restoredText = out
            statusText = "Restored \(map.fakeToReal.count) item(s)."
        } catch {
            errorMessage = String(describing: error)
        }
    }
}
