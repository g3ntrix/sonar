import AppKit
import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable {
    case dashboard, servers, test, share, logs, settings, donate
    var id: String { rawValue }
    var title: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .servers: return "Servers"
        case .test: return "Connection test"
        case .share: return "Share to phone"
        case .logs: return "Logs"
        case .settings: return "Settings"
        case .donate: return "Donate"
        }
    }
    var icon: String {
        switch self {
        case .dashboard: return "dot.radiowaves.left.and.right"
        case .servers: return "server.rack"
        case .test: return "checklist"
        case .share: return "iphone.radiowaves.left.and.right"
        case .logs: return "text.alignleft"
        case .settings: return "gearshape"
        case .donate: return "heart"
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var stored: StoredState { didSet { ProfileStore.save(stored) } }
    @Published var selection: SidebarItem = .dashboard
    @Published var showWizard = false
    @Published var lanIP: String?
    @Published var lanIPChanged = false
    @Published var egressInfo: Egress.Info?
    @Published var update: UpdateService.Release?
    @Published var lastError: String?
    @Published var systemProxyOn = false

    let log = LogStore()
    let engine: Engine
    let tester = ConnectionTester()

    init() {
        var loaded = ProfileStore.load()
        // Ports and limits are fixed; reset values edited in older versions.
        loaded.tunnel = .default
        stored = loaded
        engine = Engine(log: log)
        lanIP = LANShare.currentIP()
        engine.onEvent = { [weak self] e in self?.handle(e) }
        if stored.profiles.isEmpty || !stored.onboardingDone { showWizard = true }
        if stored.selectedID == nil { stored.selectedID = stored.profiles.first?.id }
        Notifier.requestPermission()
        #if DEBUG
        engine.startDemoIfRequested()
        #endif
        Task {
            await checkForUpdates()
            if stored.autoConnect, selectedProfile != nil, !showWizard { await connect() }
        }
    }

    // MARK: Profiles

    var profiles: [ServerProfile] { stored.profiles }

    var selectedProfile: ServerProfile? {
        stored.profiles.first { $0.id == stored.selectedID } ?? stored.profiles.first
    }

    func profile(_ id: UUID?) -> ServerProfile? { stored.profiles.first { $0.id == id } }

    func secrets(for p: ServerProfile, retry: Bool = false) -> ProfileSecrets? { try? SecretStore.load(for: p.id, retry: retry) }

    @discardableResult
    func createProfile(name: String, address: String, user: String) throws -> ServerProfile {
        let p = ServerProfile(name: name.isEmpty ? address : name, address: address, sshUser: user)
        try SecretStore.save(try SecretGenerator.newSecrets(sni: stored.tunnel.sni), for: p.id)
        stored.profiles.append(p)
        stored.selectedID = p.id
        return p
    }

    func update(_ p: ServerProfile) {
        guard let i = stored.profiles.firstIndex(where: { $0.id == p.id }) else { return }
        stored.profiles[i] = p
    }

    func select(_ p: ServerProfile) async {
        let wasActive = engine.status.isActive
        stored.selectedID = p.id
        if wasActive { await connect() }
    }

    func delete(_ p: ServerProfile) async {
        if engine.activeProfileID == p.id { await disconnect() }
        SecretStore.delete(for: p.id)
        stored.profiles.removeAll { $0.id == p.id }
        if stored.selectedID == p.id { stored.selectedID = stored.profiles.first?.id }
    }

    func duplicate(_ p: ServerProfile) {
        guard let s = secrets(for: p) else { return }
        var c = p
        c.id = UUID()
        c.name = p.name + " copy"
        c.created = Date()
        // Same secrets: a duplicate points at the same server setup (useful for a second address).
        try? SecretStore.save(s, for: c.id)
        stored.profiles.append(c)
    }

    /// New secrets: the old install stops working until the new install command runs on the VPS.
    func rotateCredentials(_ p: ServerProfile) async throws {
        let s = try SecretGenerator.newSecrets(sni: stored.tunnel.sni)
        try SecretStore.save(s, for: p.id)
        var q = p
        q.installedVersion = nil
        q.lastCheck = nil
        update(q)
        if engine.activeProfileID == p.id { await disconnect() }
    }

    func installCommand(_ p: ServerProfile) -> String? {
        guard let s = secrets(for: p) else { return nil }
        return try? ServerScript.installCommand(profile: p, secrets: s)
    }

    /// Same VPS, new IP: nothing changes on the server, only the profile.
    func changeAddress(_ p: ServerProfile, to address: String) async {
        var q = p
        q.address = address
        update(q)
        if engine.activeProfileID == p.id || selectedProfile?.id == p.id && engine.status.isActive {
            await connect()
        }
    }

    func recordStatus(_ s: PasteParser.Status, for p: ServerProfile) {
        var q = p
        if let v = s.scriptsVersion { q.installedVersion = v }
        q.lastCheck = .init(date: Date(), ok: s.ok, note: s.ok ? "Server status OK" : "Failed: \(s.failedRows.joined(separator: "; "))")
        update(q)
    }

    func importProfile(_ data: Data) throws {
        var (p, s) = try ProfileTransfer.import(data)
        if stored.profiles.contains(where: { $0.id == p.id }) { p.id = UUID() }
        try SecretStore.save(s, for: p.id)
        stored.profiles.append(p)
        stored.selectedID = p.id
    }

    // MARK: Connect

    func connect() async {
        guard let p = selectedProfile else { lastError = "Add a server first."; return }
        let s: ProfileSecrets
        do {
            guard let found = try SecretStore.load(for: p.id, retry: true) else { lastError = Engine.StartError.noSecrets.localizedDescription; return }
            s = found
        } catch { lastError = error.localizedDescription; return }
        lastError = nil
        let lan = stored.lanSharing ? XrayConfig.LAN(user: stored.tunnel.lanUser, password: s.lanPassword) : nil
        await engine.start(profile: p, secrets: s, settings: stored.tunnel, lan: lan)
    }

    func disconnect() async {
        if systemProxyOn { await SystemProxy.disable(); systemProxyOn = false }
        await engine.stop()
        egressInfo = nil
    }

    func toggleConnection() async {
        if engine.status.isActive { await disconnect() } else { await connect() }
    }

    /// Stops whatever holds the busy port when it is another Sonar (or the user confirmed), then retries.
    func stopBusyPortHolder() async {
        guard let h = engine.busyPort else { return }
        kill(h.pid, SIGTERM)
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        await connect()
    }

    func setSystemProxy(_ on: Bool) async {
        stored.systemProxy = on
        if on, engine.status == .connected {
            do {
                try await SystemProxy.enable(socks: stored.tunnel.socksPort, http: stored.tunnel.httpPort)
                systemProxyOn = true
            } catch {
                stored.systemProxy = false
                lastError = error.localizedDescription
            }
        } else if !on, systemProxyOn {
            await SystemProxy.disable()
            systemProxyOn = false
        }
    }

    func setLANSharing(_ on: Bool) async {
        stored.lanSharing = on
        lanIP = LANShare.currentIP()
        if engine.status.isActive { await connect() }
    }

    private func handle(_ e: Engine.Event) {
        switch e {
        case .connected:
            if stored.systemProxy, !systemProxyOn { Task { await setSystemProxy(true) } }
            Task { egressInfo = await Egress.info(socksPort: stored.tunnel.socksPort) }
        case .lost(let why):
            Notifier.post("Sonar cannot reach the server", "Sonar keeps retrying.")
        case .authRejected:
            Notifier.post("Server rejected the credentials", "Run this profile's setup command again on your server.")
        case .networkChanged:
            let ip = LANShare.currentIP()
            if ip != lanIP {
                let old = lanIP
                lanIP = ip
                if stored.lanSharing, old != nil {
                    lanIPChanged = true
                    Notifier.post("Your Mac's network address changed", "Phones using Sonar must switch to \(ip ?? "the new address"). Open Share to phone for a new QR code.")
                }
            }
        }
    }

    // MARK: Updates

    @Published var updateCheckOK = true
    @Published var lastUpdateCheck: Date?

    func checkForUpdates() async {
        guard let result = await UpdateService.check() else { updateCheckOK = false; return }
        updateCheckOK = true
        lastUpdateCheck = Date()
        if let r = result, UpdateService.isNewer(r.version, than: Versions.app) { update = r } else { update = nil }
    }

    // MARK: Layer view

    struct Layer: Identifiable {
        let id: String
        let title: String
        var health: Health
        var detail: String
        var action: String?
    }

    var layers: [Layer] {
        let st = engine.status
        let s = engine.stats
        let active = st.isActive
        let mac = Layer(id: "mac", title: "App",
                        health: !active ? .unknown : (engine.isRelaydRunning && engine.isXrayRunning ? .ok : .down),
                        detail: !active ? "Not running" : (engine.isRelaydRunning && engine.isXrayRunning ? "Running" : "Restarting"),
                        action: active && !(engine.isRelaydRunning && engine.isXrayRunning) ? "Sonar restarts it automatically. See Logs for details." : nil)
        let pathHealth: Health = !active ? .unknown : (s.idleSeconds < 0 ? .unknown : (s.idleSeconds > 5 ? .down : (s.lossPct > 15 ? .degraded : .ok)))
        let path = Layer(id: "path", title: "Connection",
                         health: pathHealth,
                         detail: !active ? "—" : (s.idleSeconds > 5 ? "No response for \(Int(s.idleSeconds)) s" : String(format: "Loss %.0f%%", s.lossPct)),
                         action: pathHealth == .down ? "Run the connection test to see what is blocking it." : nil)
        let relay = Layer(id: "relay", title: "Your server",
                          health: !active ? .unknown : (s.idleSeconds >= 0 && s.idleSeconds < 5 ? .ok : .down),
                          detail: !active ? "—" : (s.idleSeconds >= 0 && s.idleSeconds < 5 ? "Responding" : "No response"),
                          action: active && !(s.idleSeconds >= 0 && s.idleSeconds < 5) ? "On your server run: \(ServerScript.statusCommand)" : nil)
        let hy = Layer(id: "hy", title: "Secure session",
                       health: !active ? .unknown : (engine.authRejected ? .down : (st == .connected ? .ok : .degraded)),
                       detail: !active ? "—" : (engine.authRejected ? "Credentials rejected" : (st == .connected ? "Established" : "Connecting")),
                       action: engine.authRejected ? "Run this profile's setup command on your server again." : nil)
        let net = Layer(id: "net", title: "Internet",
                        health: !active ? .unknown : (st == .connected && engine.exitIP == engine.currentServerIP ? .ok : .degraded),
                        detail: !active ? "—" : (engine.exitIP.map { "Exit IP \($0)" } ?? "Checking"),
                        action: nil)
        return [mac, path, relay, hy, net]
    }

    func diagnostics() -> String {
        var s = "Sonar \(Versions.app), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)\n"
        s += "Status: \(engine.status.title) \(engine.status.detail ?? "")\n"
        if let p = selectedProfile { s += "Profile: \(p.name), scripts v\(p.installedVersion.map(String.init) ?? "?")\n" }
        for l in layers { s += "\(l.title): \(l.health.rawValue) \(l.detail)\n" }
        s += "\n" + log.text()
        return log.redact(s)
    }
}
