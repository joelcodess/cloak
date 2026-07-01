import SwiftUI
import AppKit

// Entry point. SwiftPM executable targets allow top-level code only in main.swift;
// we set the activation policy to .regular so this becomes a real windowed,
// Dock-visible app (not a background process), then hand off to the SwiftUI App.

struct CloakMainApp: App {
    var body: some Scene {
        WindowGroup("Cloak") {
            RootView()
                .frame(minWidth: 760, minHeight: 560)
        }
        .windowResizability(.contentMinSize)
    }
}

NSApplication.shared.setActivationPolicy(.regular)
NSApplication.shared.activate(ignoringOtherApps: true)
CloakMainApp.main()
