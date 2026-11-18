import AppKit
import SwiftUI

@main
struct SonarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var state = AppState()

    var body: some Scene {
        Window("Sonar", id: "main") {
            RootView()
                .environmentObject(state)
                .environmentObject(state.engine)
                .environmentObject(state.tester)
                .environmentObject(state.log)
                .tint(Brand.accent)
                .frame(minWidth: 860, minHeight: 640)
                .onAppear { delegate.state = state }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .appSettings) { OpenPageCommand(title: "Settings…", item: .settings, state: state).keyboardShortcut(",") }
            CommandGroup(after: .newItem) {
                Button("Set Up a New Server…") { state.showWizard = true }.keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandMenu("Connection") {
                Button(state.engine.status.isActive ? "Disconnect" : "Connect") { Task { await state.toggleConnection() } }
                    .keyboardShortcut("k")
                Button("Run Connection Test") {
                    state.selection = .test
                    if let p = state.selectedProfile { state.tester.run(engine: state.engine, profile: p) }
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                Divider()
                ForEach(Array(SidebarItem.allCases.enumerated()), id: \.element) { i, item in
                    Button(item.title) { state.selection = item }.keyboardShortcut(KeyEquivalent(Character("\(i + 1)")))
                }
            }
        }

        MenuBarExtra {
            MenuBarView()
                .environmentObject(state)
                .environmentObject(state.engine)
        } label: {
            MenuBarLabel(status: state.engine.status)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var state: AppState?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        // Restore the system proxy and stop helpers; the guard process covers crashes.
        MainActor.assumeIsolated {
            if state?.systemProxyOn == true { SystemProxy.disableSync() }
            state?.engine.stopNow()
        }
    }
}

struct MenuBarLabel: View {
    let status: ConnectionStatus
    var body: some View {
        switch status {
        case .connected: Image(systemName: "dot.radiowaves.left.and.right")
        case .connecting, .reconnecting: Image(systemName: "antenna.radiowaves.left.and.right")
        case .error: Image(systemName: "exclamationmark.triangle")
        default: Image(systemName: "dot.radiowaves.right")
        }
    }
}

/// Menu item that opens a sidebar page, reopening the window if needed.
struct OpenPageCommand: View {
    let title: String
    let item: SidebarItem
    let state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(title) {
            state.selection = item
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
