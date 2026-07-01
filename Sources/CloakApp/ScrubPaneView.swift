import SwiftUI
import UniformTypeIdentifiers
import AppKit
import CloakKit

struct ScrubPaneView: View {
    @ObservedObject var vm: CloakViewModel
    @State private var isTargeted = false
    @State private var showImporter = false

    private static let docx = UTType(filenameExtension: "docx") ?? .data
    private var allowed: [UTType] { [.plainText, .text, .pdf, .commaSeparatedText, .json, Self.docx, .sourceCode] }

    var body: some View {
        Group {
            if vm.loadedDoc == nil {
                emptyState
            } else {
                loaded
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            guard let p = providers.first else { return false }
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url { Task { @MainActor in vm.loadAndScrub(url: url) } }
            }
            return true
        }
        .overlay(dropHighlight)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: allowed) { result in
            if case .success(let url) = result { vm.loadAndScrub(url: url) }
        }
    }

    // MARK: Empty state (HIG ContentUnavailableView)

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Drop a document to scrub", systemImage: "arrow.down.doc")
        } description: {
            Text("PII is detected on-device and replaced with realistic fakes.\nSupports .txt, .md, .csv, .json, code, .docx, and .pdf.")
        } actions: {
            Button {
                showImporter = true
            } label: {
                Label("Choose File\u{2026}", systemImage: "folder")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!vm.modelAvailable)
        }
    }

    private var dropHighlight: some View {
        RoundedRectangle(cornerRadius: Theme.cardRadius)
            .strokeBorder(Theme.accent, lineWidth: 2)
            .padding(6)
            .opacity(isTargeted ? 1 : 0)
            .allowsHitTesting(false)
    }

    // MARK: Loaded state

    private var loaded: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 12) {
                fileHeader
                spansGroup
            }
            .padding(16)
            .frame(minWidth: 320)

            VStack(alignment: .leading, spacing: 8) {
                scrubbedGroup
            }
            .padding(16)
            .frame(minWidth: 360)
        }
    }

    private var fileHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: icon(for: vm.loadedDoc?.kind))
                .font(.title2)
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(vm.sourceName).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                showImporter = true
            } label: {
                Label("Open Another\u{2026}", systemImage: "folder")
            }
            .controlSize(.small)
        }
    }

    private var spansGroup: some View {
        GroupBox {
            Table(vm.spans) {
                TableColumn("Original") { Text($0.text).font(.callout) }
                TableColumn("Replacement") { s in
                    Text(s.scrubbed ? s.fake : "kept")
                        .font(.callout)
                        .foregroundStyle(s.scrubbed ? Theme.accent : .secondary)
                }
                TableColumn("Type") {
                    Text($0.category.replacingOccurrences(of: "_", with: " "))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .tableStyle(.inset)
            .frame(minHeight: 200)
        } label: {
            Label("Detected \u{2014} \(vm.spans.count)", systemImage: "list.bullet.rectangle")
                .font(.subheadline)
        }
    }

    private var scrubbedGroup: some View {
        GroupBox {
            TextEditor(text: .constant(vm.scrubbedText))
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 260)
        } label: {
            HStack {
                Label("Scrubbed text", systemImage: "doc.plaintext")
                    .font(.subheadline)
                Spacer()
                Button { copy(vm.scrubbedText) } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .controlSize(.small)
                .disabled(vm.scrubbedText.isEmpty)
                Button { save() } label: {
                    Label("Save\u{2026}", systemImage: "square.and.arrow.down")
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .disabled(vm.scrubbedText.isEmpty)
            }
        }
    }

    // MARK: helpers

    private var subtitle: String {
        guard let doc = vm.loadedDoc else { return "" }
        switch doc.kind {
        case .plainText: return "Plain text"
        case .docx:      return "Word document \u{00B7} formatting preserved"
        case .pdf:       return "PDF \u{00B7} text extracted, saves as .txt (layout not preserved)"
        }
    }

    private func icon(for kind: DocKind?) -> String {
        switch kind {
        case .docx: return "doc.richtext"
        case .pdf:  return "doc.text.image"
        default:    return "doc.plaintext"
        }
    }

    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = vm.suggestedOutputURL()?.lastPathComponent ?? "scrubbed.txt"
        if let dir = vm.suggestedOutputURL()?.deletingLastPathComponent() { panel.directoryURL = dir }
        if panel.runModal() == .OK, let url = panel.url { vm.saveScrubbed(to: url) }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}
