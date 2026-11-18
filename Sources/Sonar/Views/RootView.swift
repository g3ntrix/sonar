import SwiftUI

struct RootView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var engine: Engine
    @SceneStorage("sidebar") private var savedSelection = SidebarItem.dashboard.rawValue

    var body: some View {
        Group {
            if app.showWizard {
                WizardView()
            } else {
                NavigationSplitView {
                    List(SidebarItem.allCases, selection: Binding(get: { app.selection }, set: { if let v = $0 { app.selection = v } })) { item in
                        Label(item.title, systemImage: item.icon).tag(item)
                    }
                    .navigationSplitViewColumnWidth(min: 190, ideal: 210)
                    .safeAreaInset(edge: .bottom) {
                        HStack(spacing: 8) {
                            StatusDot(color: engine.status.color, animated: engine.status.isActive)
                            Text(engine.status.title).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(12)
                    }
                } detail: {
                    detail.background(AppBackground())
                }
            }
        }
        .onAppear { app.selection = SidebarItem(rawValue: savedSelection) ?? .dashboard }
        .onChange(of: app.selection) { savedSelection = $0.rawValue }
    }

    @ViewBuilder private var detail: some View {
        switch app.selection {
        case .dashboard: DashboardView()
        case .servers: ServersView()
        case .test: TesterView()
        case .share: ShareView()
        case .logs: LogsView()
        case .settings: SettingsView()
        case .donate: DonateView()
        }
    }
}
