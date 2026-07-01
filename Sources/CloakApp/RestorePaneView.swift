import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct RestorePaneView: View {
    @ObservedObject var vm: CloakViewModel
    @State private var showImporter = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox {
                HStack(spacing: 8) {
                    Picker("Mapping", selection: $vm.selectedRecordID) {
                        Text("Select a recent scrub\u{2026}").tag(String?.none)
                        ForEach(vm.recent) { rec in
                            Text("\(rec.sourceName)  \u{00B7}  \(rec.date.formatted(date: .abbreviated, time: .shortened))")
                                .tag(String?.some(rec.id))
                        }
                    }
                    Button { vm.refreshRecent() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Refresh recent scrubs")
                    Button { showImporter = true } label: {
                        Label("Load File\u{2026}", systemImage: "folder")
                    }
                }
            } label: {
                Label("Which scrub is this reply from?", systemImage: "key.horizontal")
                    .font(.subheadline)
            }

            GroupBox {
                TextEditor(text: $vm.restoreInput)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 150)
            } label: {
                Label("Paste the reply from the cloud LLM", systemImage: "text.append")
                    .font(.subheadline)
            }

            HStack {
                Button {
                    vm.restore(usingRecordID: vm.selectedRecordID)
                } label: {
                    Label("Restore", systemImage: "arrow.uturn.backward")
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(vm.restoreInput.isEmpty)
                Spacer()
                Button { copy(vm.restoredText) } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .disabled(vm.restoredText.isEmpty)
            }

            GroupBox {
                TextEditor(text: .constant(vm.restoredText))
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 150)
            } label: {
                Label("Restored \u{2014} your real values", systemImage: "checkmark.seal")
                    .font(.subheadline)
            }
        }
        .padding(16)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
            if case .success(let url) = result { vm.restore(mapURL: url) }
        }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}
