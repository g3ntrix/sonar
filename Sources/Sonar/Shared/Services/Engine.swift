import AppKit
import Foundation
import Network

/// Spawns and supervises relayd (ICMP transport) and Xray (Hysteria2 client and local proxies).
///
///     Xray (hysteria outbound) -> 127.0.0.1:18096 -> relayd icmp -> server
@MainActor
final class Engine: ObservableObject {
    enum StartError: LocalizedError {
        case missingBinary(String)
        case portBusy(PortCheck.Holder)
        case noSecrets
        case badAddress(String)

        var errorDescription: String? {
            switch self {
            case .missingBinary(let n): return "The bundled \(n) program is missing. Reinstall Sonar."
            case .portBusy(let h): return "Port \(h.port) is already used by \(h.friendly)."
            case .noSecrets: return "This server's keys are missing on this Mac. Create new credentials in Servers, then run the install command again."
            case .badAddress(let a): return "Cannot resolve the server address \(a)."
            }
        }
    }

    struct Stats: Equatable {
        var upBps: Double = 0
        var downBps: Double = 0
        var upTotal: Int64 = 0
        var downTotal: Int64 = 0
        var lossPct: Double = 0
        var pollRate: Double = 0
        var idleSeconds: Double = -1
    }

    /// One throughput sample for the live chart.
    struct Sample: Identifiable {
        let id = UUID()
        var down: Double
        var up: Double
    }

    @Published private(set) var status: ConnectionStatus = .disconnected
    @Published private(set) var stats = Stats()
    /// Rolling history of recent down/up speeds (newest last), for the dashboard sparkline.
    @Published private(set) var history: [Sample] = []
    private let historyCap = 60
    @Published private(set) var connectedSince: Date?
    @Published private(set) var exitIP: String?
    @Published private(set) var busyPort: PortCheck.Holder?
    @Published private(set) var authRejected = false
    @Published private(set) var lastEgressOK: Date?

    let log: LogStore
    var onEvent: ((Event) -> Void)?

    enum Event { case connected, lost(String), networkChanged, authRejected }

    private var relayd: Process?
    private var xray: Process?
    private var guardProc: Process?
    private var configURL: URL?
    private var profile: ServerProfile?
    private var serverIP: String?
    private var secrets: ProfileSecrets?
    private var settings = TunnelSettings.default
    private var lan: XrayConfig.LAN?
    private var userStopped = true
    private var restartAttempts = 0
    private var restartTask: Task<Void, Never>?
    private var monitor: NWPathMonitor?
    private var lastPathSignature = ""
    private var observers: [NSObjectProtocol] = []

    init(log: LogStore) {
        self.log = log
        startPathMonitor()
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleWake() }
        })
    }

    var activeProfileID: UUID? { status.isActive ? profile?.id : nil }

    // MARK: Start / stop

    func start(profile: ServerProfile, secrets: ProfileSecrets, settings: TunnelSettings, lan: XrayConfig.LAN?) async {
        if status.isActive { await stop() }
        self.profile = profile
        self.secrets = secrets
        self.settings = settings
        self.lan = lan
        userStopped = false
        restartAttempts = 0
        authRejected = false
        busyPort = nil
        log.setSecrets([secrets.hysteriaPassword, secrets.obfsPassword, secrets.certPin, secrets.lanPassword])
        history.removeAll()
        await launch(reason: "Starting Sonar")
    }

    private func launch(reason: String) async {
        guard let profile, let secrets else { return }
        status = restartAttempts == 0 ? .connecting(reason) : .reconnecting(reason)
        do {
            guard let relaydPath = Paths.relayd else { throw StartError.missingBinary("relayd") }
            guard let xrayPath = Paths.xray else { throw StartError.missingBinary("xray") }
            guard let ip = await Task.detached(operation: { Probe.resolveIPv4(profile.address) }).value else {
                throw StartError.badAddress(profile.address)
            }
            serverIP = ip
            var tcp = [settings.socksPort, settings.socks2Port, settings.httpPort]
            if lan != nil { tcp.append(settings.lanPort) }
            for p in tcp { if let h = PortCheck.holder(tcp: p) { throw StartError.portBusy(h) } }
            if let h = PortCheck.holder(udp: settings.relayLocalPort) { throw StartError.portBusy(h) }

            let cfg = XrayConfig.build(secrets: secrets, settings: settings, lan: lan)
            let url = try XrayConfig.writeTemp(cfg)
            configURL = url

            let pid = ProcessInfo.processInfo.processIdentifier
            relayd = try spawn(relaydPath, ["run", "--server", ip, "--listen", "127.0.0.1:\(settings.relayLocalPort)",
                                            "--cap", String(settings.pollCap), "--dup", String(settings.dup),
                                            "--parent-pid", String(pid)], tag: "relayd")
            try await Task.sleep(nanoseconds: 400_000_000)
            xray = try spawn(xrayPath, ["run", "-c", url.path], tag: "xray")
            if let r = relayd, let x = xray {
                guardProc = try? spawn(relaydPath, ["watch", "--parent-pid", String(pid), String(r.processIdentifier), String(x.processIdentifier)], tag: "guard", quiet: true)
            }

            status = .connecting("Waiting for the local proxy")
            var up = false
            for _ in 0..<30 {
                if await PortCheck.listening(settings.socksPort, timeout: 0.5) { up = true; break }
                if xray?.isRunning != true { break }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            guard up else { throw NSError(domain: "Sonar", code: 1, userInfo: [NSLocalizedDescriptionKey: "Xray did not start (see Logs)."]) }

            status = .connecting("Checking the exit IP through the tunnel")
            if await egressCheck(tries: 4) {
                restartAttempts = 0
                if connectedSince == nil { connectedSince = Date() }
                status = .connected
                onEvent?(.connected)
            } else if !userStopped {
                let why = authRejected ? "The server rejected the credentials." : "The tunnel did not reach the server (exit IP check failed)."
                status = .error(why)
                scheduleRestart(why)
            }
        } catch let e as StartError {
            if case .portBusy(let h) = e { busyPort = h }
            killChildren()
            status = .error(e.localizedDescription)
            userStopped = true
        } catch {
            killChildren()
            status = .error(error.localizedDescription)
            scheduleRestart(error.localizedDescription)
        }
    }

    /// The real test: the exit IP through SOCKS must equal the server IP (HTTP 200 alone proves nothing).
    @discardableResult
    func egressCheck(tries: Int = 4) async -> Bool {
        for i in 0..<tries {
            if userStopped { return false }
            if let ip = await Egress.ip(socksPort: settings.socksPort) {
                exitIP = ip
                if ip == serverIP {
                    lastEgressOK = Date()
                    return true
                }
                log.add("sonar", "Exit IP is \(ip), expected the server IP. Traffic is not going through the tunnel.")
            }
            if i < tries - 1 { try? await Task.sleep(nanoseconds: 1_500_000_000) }
        }
        return false
    }

    func stop() async {
        userStopped = true
        restartTask?.cancel()
        restartTask = nil
        guard status != .disconnected else { return }
        status = .disconnecting
        killChildren()
        connectedSince = nil
        exitIP = nil
        stats = Stats()
        history.removeAll()
        status = .disconnected
    }

    /// Synchronous stop for app termination.
    func stopNow() {
        userStopped = true
        killChildren()
    }

    private func killChildren() {
        for p in [xray, relayd] { if let p, p.isRunning { p.terminate() } }
        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline, [xray, relayd].contains(where: { $0?.isRunning == true }) { usleep(50_000) }
        for p in [xray, relayd] { if let p, p.isRunning { kill(p.processIdentifier, SIGKILL) } }
        if let g = guardProc, g.isRunning { g.terminate() }
        xray = nil
        relayd = nil
        guardProc = nil
        if let u = configURL { try? FileManager.default.removeItem(at: u) }
        configURL = nil
    }

    private func spawn(_ path: String, _ args: [String], tag: String, quiet: Bool = false) throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.environment = Shell.cleanEnvironment
        p.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty else { h.readabilityHandler = nil; return }
            let s = String(decoding: d, as: UTF8.self)
            Task { @MainActor in self?.handleOutput(tag, s, quiet: quiet) }
        }
        p.terminationHandler = { [weak self] proc in
            Task { @MainActor in self?.childExited(tag, proc) }
        }
        try p.run()
        log.add("sonar", "started \(friendly(tag)) (pid \(p.processIdentifier))")
        return p
    }

    /// Neutral log source names so logs never name the underlying programs.
    private func friendly(_ tag: String) -> String {
        switch tag {
        case "relayd": return "net"
        case "xray": return "core"
        default: return "sonar"
        }
    }

    /// Lines from the core that would reveal which program it is.
    private func isBannerLine(_ l: String) -> Bool {
        let low = l.lowercased()
        return low.contains("xray") || low.contains("penetrates") || low.contains("anti-censorship")
            || low.contains("hysteria") || low.contains("salamander")
    }

    private func handleOutput(_ tag: String, _ s: String, quiet: Bool) {
        for line in s.split(separator: "\n") {
            if tag == "relayd", line.hasPrefix("STATS ") {
                parseStats(String(line))
                continue
            }
            if tag == "xray" {
                let l = line.lowercased()
                if l.contains("auth") && (l.contains("fail") || l.contains("reject") || l.contains("401")) {
                    if !authRejected { authRejected = true; onEvent?(.authRejected) }
                }
                if isBannerLine(String(line)) { continue }
            }
            if !quiet { log.add(friendly(tag), String(line)) }
        }
    }

    private func parseStats(_ line: String) {
        var kv: [String: String] = [:]
        for part in line.split(separator: " ").dropFirst() {
            let p = part.split(separator: "=", maxSplits: 1)
            if p.count == 2 { kv[String(p[0])] = String(p[1]) }
        }
        stats = Stats(upBps: Double(kv["up"] ?? "") ?? 0, downBps: Double(kv["down"] ?? "") ?? 0,
                      upTotal: Int64(kv["upTotal"] ?? "") ?? 0, downTotal: Int64(kv["downTotal"] ?? "") ?? 0,
                      lossPct: Double(kv["loss"] ?? "") ?? 0, pollRate: Double(kv["rate"] ?? "") ?? 0,
                      idleSeconds: Double(kv["idle"] ?? "") ?? -1)
        history.append(Sample(down: stats.downBps, up: stats.upBps))
        if history.count > historyCap { history.removeFirst(history.count - historyCap) }
    }

    private func childExited(_ tag: String, _ p: Process) {
        guard tag != "guard" else { return }
        let mine = (tag == "relayd" && p === relayd) || (tag == "xray" && p === xray)
        guard mine else { return }
        log.add("sonar", "\(friendly(tag)) exited (status \(p.terminationStatus))")
        if userStopped { return }
        killChildren()
        scheduleRestart("A component stopped unexpectedly")
    }

    private func scheduleRestart(_ why: String) {
        guard !userStopped else { return }
        restartAttempts += 1
        let delay = min(30.0, pow(2.0, Double(min(restartAttempts - 1, 5))))
        status = .reconnecting("\(why). Retrying in \(Int(delay)) s")
        if restartAttempts == 3 { onEvent?(.lost(why)) }
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled, !self.userStopped else { return }
            self.killChildren()
            await self.launch(reason: "Reconnecting")
        }
    }

    // MARK: Network changes, sleep and wake

    private func startPathMonitor() {
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] path in
            let sig = path.availableInterfaces.map(\.name).joined(separator: ",") + "|\(path.status)"
            Task { @MainActor in self?.pathChanged(sig, satisfied: path.status == .satisfied) }
        }
        m.start(queue: DispatchQueue(label: "sonar.path"))
        monitor = m
    }

    private func pathChanged(_ sig: String, satisfied: Bool) {
        defer { lastPathSignature = sig }
        guard !lastPathSignature.isEmpty, sig != lastPathSignature else { return }
        onEvent?(.networkChanged)
        guard !userStopped, satisfied else { return }
        log.add("sonar", "Network changed, checking the connection")
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await recheckOrReconnect()
        }
    }

    private func handleWake() {
        guard !userStopped else { return }
        log.add("sonar", "Woke from sleep, reconnecting")
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            killChildren()
            restartAttempts = 0
            await launch(reason: "Reconnecting after sleep")
        }
    }

    func recheckOrReconnect() async {
        guard !userStopped else { return }
        if await egressCheck(tries: 2) {
            if status != .connected { status = .connected }
        } else {
            killChildren()
            restartAttempts = 0
            await launch(reason: "Reconnecting after a network change")
        }
    }

    var isRelaydRunning: Bool { relayd?.isRunning == true }
    var isXrayRunning: Bool { xray?.isRunning == true }
    var currentServerIP: String? { serverIP }
    var currentSettings: TunnelSettings { settings }
}

#if DEBUG
// SONAR_DEMO=1 (debug builds): fake live stats for checking the dashboard layout.
extension Engine {
    func startDemoIfRequested() {
        guard ProcessInfo.processInfo.environment["SONAR_DEMO"] == "1" else { return }
        status = .connected
        connectedSince = Date().addingTimeInterval(-754)
        exitIP = "203.0.113.42"
        serverIP = "203.0.113.42"
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let t = Date().timeIntervalSince1970
                let down = 1_200_000 + 500_000 * sin(t / 3) + Double.random(in: 0...250_000)
                let up = 90_000 + 40_000 * cos(t / 4) + Double.random(in: 0...20_000)
                self.stats.downBps = down
                self.stats.upBps = up
                self.stats.downTotal += Int64(down)
                self.stats.upTotal += Int64(up)
                self.stats.lossPct = 4
                self.stats.idleSeconds = 0.2
                self.history.append(Sample(down: down, up: up))
                if self.history.count > 60 { self.history.removeFirst() }
            }
        }
    }
}
#endif
