import SwiftUI

struct RootView: View {
    @StateObject private var vm = CloakViewModel()
    @State private var tab: Tab = .scrub

    enum Tab: String, CaseIterable, Identifiable {
        case scrub = "Scrub", restore = "Restore"
        var id: String { rawValue }
        var symbol: String { self == .scrub ? "eye.slash" : "arrow.uturn.backward" }
    }

    var body: some View {
        NavigationStack {
            Group {
                switch tab {
                case .scrub:   ScrubPaneView(vm: vm)
                case .restore: RestorePaneView(vm: vm)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Cloak")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("View", selection: $tab) {
                        ForEach(Tab.allCases) { t in
                            Label(t.rawValue, systemImage: t.symbol).tag(t)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelStyle(.titleAndIcon)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) { banners }
            .safeAreaInset(edge: .bottom, spacing: 0) { statusBar }
        }
        .tint(Theme.accent)
    }

    @ViewBuilder private var banners: some View {
        VStack(spacing: 0) {
            if let warning = vm.availabilityWarning {
                NoticeBanner(text: warning, systemImage: "exclamationmark.triangle.fill", tint: .orange)
            }
            if let err = vm.errorMessage {
                NoticeBanner(text: err, systemImage: "xmark.octagon.fill", tint: Theme.danger)
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if vm.isWorking {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: vm.modelAvailable ? "cpu" : "cpu.fill")
                    .foregroundStyle(vm.modelAvailable ? Theme.accent : .secondary)
            }
            Text(vm.statusText.isEmpty
                 ? (vm.modelAvailable ? "On-device model ready" : "On-device model unavailable")
                 : vm.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

/// A macOS-style inline notice: leading color bar + tinted background, used for
/// non-modal warnings/errors.
struct NoticeBanner: View {
    let text: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(tint)
            Text(text).font(.callout)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(tint.opacity(0.10))
        .overlay(Rectangle().fill(tint).frame(width: 3), alignment: .leading)
    }
}
