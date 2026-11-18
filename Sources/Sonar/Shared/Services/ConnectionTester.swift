import Foundation

/// Stage-by-stage connection test. Judges the tunnel by the exit IP, never by an HTTP status alone.
@MainActor
final class ConnectionTester: ObservableObject {
    enum State: Equatable { case pending, running, pass, warn, fail, skipped }

    struct Stage: Identifiable, Equatable {
        let id: Int
        let title: String
        var state: State = .pending
        var detail = ""
        var fix: String?
        var command: String?
        var seconds: Double = 0
    }

    static let titles = [
        "App", "Connection to your server", "Secure session", "Exit IP", "DNS",
        "Latency", "Speed", "Parallel load", "Popular sites",
    ]

    @Published private(set) var stages: [Stage] = ConnectionTester.titles.enumerated().map { Stage(id: $0.offset, title: $0.element) }
    @Published private(set) var running = false
    @Published private(set) var finished: Date?
    var includeSpeed = true

    enum Summary { case none, green, amber, red }
    var summary: Summary {
        guard finished != nil else { return .none }
        if stages.contains(where: { $0.state == .fail }) { return .red }
        if stages.contains(where: { $0.state == .warn }) { return .amber }
        return .green
    }

    private var task: Task<Void, Never>?

    func cancel() { task?.cancel(); running = false }

    func run(engine: Engine, profile: ServerProfile) {
        task?.cancel()
        task = Task { await runAll(engine: engine, profile: profile) }
    }

    private func set(_ i: Int, _ s: State, _ detail: String, fix: String? = nil, command: String? = nil, started: Date) {
        stages[i].state = s
        stages[i].detail = detail
        stages[i].fix = fix
        stages[i].command = command
        stages[i].seconds = Date().timeIntervalSince(started)
    }

    private func runAll(engine: Engine, profile: ServerProfile) async {
        running = true
        finished = nil
        for i in stages.indices { stages[i] = Stage(id: i, title: stages[i].title) }
        defer { running = false; finished = Date() }
        let s = engine.currentSettings
        let socks = "socks5h://127.0.0.1:\(s.socksPort)"
        let http = "http://127.0.0.1:\(s.httpPort)"
        let serverIP = engine.currentServerIP ?? Probe.resolveIPv4(profile.address) ?? profile.address

        // 1. Local engine
        var t = Date()
        stages[0].state = .running
        let socksUp = await PortCheck.listening(s.socksPort)
        let httpUp = await PortCheck.listening(s.httpPort)
        if engine.isRelaydRunning && engine.isXrayRunning && socksUp && httpUp {
            set(0, .pass, "Sonar is running. The local proxy is listening on ports \(s.socksPort) and \(s.httpPort).", started: t)
        } else {
            var missing: [String] = []
            if !engine.isRelaydRunning || !engine.isXrayRunning { missing.append("a Sonar component is not running") }
            if !socksUp { missing.append("port \(s.socksPort) is not listening") }
            if !httpUp { missing.append("port \(s.httpPort) is not listening") }
            set(0, .fail, "Not ready: " + missing.joined(separator: ", ") + ".", fix: "Press Connect. If it stops again, open Logs.", started: t)
        }

        // 2. Path to server (probe; the RT reply proves the relay answered, not the kernel)
        t = Date()
        stages[1].state = .running
        let probe = await Probe.probe(serverIP, count: engine.status.isActive ? 10 : 20)
        var pathOK = false
        if let p = probe {
            switch p.verdict {
            case "relay":
                pathOK = true
                let loss = Int(p.lossPct.rounded())
                let state: State = p.lossPct > 15 ? .warn : .pass
                set(1, state, "Your server responds. Loss \(loss)% (a few percent is normal), round trip \(Int(p.rttMs)) ms.",
                    fix: state == .warn ? "High loss on this network, so expect lower speed." : nil, started: t)
            case "relay+kernel":
                pathOK = true
                set(1, .warn, "Your server responds, but it is not fully set up for Sonar.",
                    fix: "Run this profile's setup command again on your server.",
                    command: ServerScript.statusCommand, started: t)
            case "kernel-only":
                set(1, .fail, "Your server is reachable but Sonar is not answering on it.",
                    fix: "Sonar is not running there, or this is a new server. Run the setup command again on your server.",
                    command: ServerScript.statusCommand, started: t)
            case "silent":
                let ssh = await TCPReach.check(host: serverIP, port: 22, timeout: 3)
                set(1, .fail, ssh ? "The server is online (SSH answers) but Sonar's traffic does not get through."
                                  : "No reply at all from \(serverIP).",
                    fix: ssh ? "Your provider's firewall is blocking it. The firewall step in Setup shows the rule to add."
                             : "Check the server address and that it is running. This network may be too restrictive for Sonar.",
                    started: t)
            default:
                set(1, .fail, "Could not reach the server: \(p.error ?? "unknown error").", fix: "Check the network connection.", started: t)
            }
        } else {
            set(1, .fail, "The check helper did not run.", fix: "Reinstall Sonar.", started: t)
        }

        guard stages[0].state == .pass else {
            for i in 2..<stages.count { stages[i].state = .skipped; stages[i].detail = "Needs the app running." }
            return
        }

        // 3. Secure session through the server
        t = Date()
        stages[2].state = .running
        let hs = await ProxyCurl.get("https://www.gstatic.com/generate_204", proxy: socks, maxTime: 15, saveBody: false)
        if hs.code == 204 || hs.code == 200 {
            set(2, .pass, String(format: "The encrypted session is up (first request %.2f s).", hs.seconds), started: t)
        } else if engine.authRejected {
            set(2, .fail, "The server rejected the credentials.",
                fix: "The server has different keys. Run this profile's setup command again on your server.", started: t)
        } else {
            set(2, .fail, "No secure session through the server.",
                fix: pathOK ? "The server responds but the session did not come up. Run the status command on your server and paste the output into Sonar."
                            : "Fix the connection to the server first.",
                command: pathOK ? ServerScript.statusCommand : nil, started: t)
        }

        // 4. Exit IP through SOCKS and HTTP
        t = Date()
        stages[3].state = .running
        let viaSocks = await ProxyCurl.get("https://api.ipify.org", proxy: socks, maxTime: 12).body
        let viaHTTP = await ProxyCurl.get("https://api.ipify.org", proxy: http, maxTime: 12).body
        if viaSocks == serverIP && viaHTTP == serverIP {
            set(3, .pass, "Exit IP is \(serverIP) through both proxies (your server).", started: t)
        } else if viaSocks == serverIP {
            set(3, .warn, "The SOCKS proxy exits at your server, but the HTTP proxy returned '\(viaHTTP.prefix(40))'.", fix: "Reconnect. If it keeps happening, open Logs.", started: t)
        } else {
            set(3, .fail, viaSocks.isEmpty ? "No answer through the connection." : "Exit IP is \(viaSocks.prefix(40)), not your server \(serverIP).",
                fix: "Traffic is not leaving through your server. Reconnect, then run the test again.", started: t)
        }

        // 5. DNS: names are resolved on the server. The site's seen IP is the server's IPv4, or its IPv6 when the
        //    server has one (a mismatch there is not a leak), so an IPv6 reply counts as a pass.
        t = Date()
        stages[4].state = .running
        let trace = await ProxyCurl.get("https://one.one.one.one/cdn-cgi/trace", proxy: socks, maxTime: 12)
        let traceIP = trace.body.split(separator: "\n").first(where: { $0.hasPrefix("ip=") }).map { String($0.dropFirst(3)) }
        let isIPv6 = traceIP?.contains(":") ?? false
        if trace.code == 200, traceIP == serverIP {
            set(4, .pass, "Names are resolved on your server, so no DNS leaks from this Mac.", started: t)
        } else if trace.code == 200, isIPv6 {
            set(4, .pass, "Names are resolved on your server (it reached the site over IPv6), so no DNS leaks from this Mac.", started: t)
        } else if trace.code == 200 {
            set(4, .warn, "Resolved, but the site saw \(traceIP ?? "?") instead of your server.", fix: "Reconnect, then run the test again.", started: t)
        } else {
            set(4, .fail, "Could not resolve a name through the connection.", fix: "Reconnect. If it keeps happening, open Logs.", started: t)
        }

        // 6. Latency: median of several requests
        t = Date()
        stages[5].state = .running
        var times: [Double] = []
        for _ in 0..<5 {
            let r = await ProxyCurl.get("https://www.gstatic.com/generate_204", proxy: socks, maxTime: 10, saveBody: false)
            if r.code == 204 { times.append(r.seconds) }
        }
        if times.count >= 3 {
            let med = times.sorted()[times.count / 2] * 1000
            set(5, med > 1500 ? .warn : .pass, "Median \(Int(med)) ms over \(times.count) requests.",
                fix: med > 1500 ? "Slow responses. Check the speed below." : nil, started: t)
        } else {
            set(5, .fail, "Only \(times.count) of 5 requests answered.", fix: "The tunnel is unstable. Reconnect.", started: t)
        }

        guard includeSpeed else {
            for i in 6...7 { stages[i].state = .skipped; stages[i].detail = "Speed tests turned off." }
            await popular(socks: socks)
            return
        }

        // 7. Speed: ~20 MB down, small upload. Expect about 1.5 MB/s down (ICMP ceiling about 1.9 MB/s).
        t = Date()
        stages[6].state = .running
        let down = await ProxyCurl.get("https://speed.cloudflare.com/__down?bytes=20000000", proxy: socks, maxTime: 60, saveBody: false)
        let upFile = FileManager.default.temporaryDirectory.appendingPathComponent("sonar-up-\(UUID().uuidString.prefix(6)).bin")
        try? Data((0..<2_000_000).map { _ in UInt8.random(in: 0...255) }).write(to: upFile)
        let up = await ProxyCurl.get("https://speed.cloudflare.com/__up", proxy: socks, maxTime: 30, saveBody: false,
                                     extra: ["--data-binary", "@\(upFile.path)", "-H", "Content-Type: application/octet-stream"])
        try? FileManager.default.removeItem(at: upFile)
        let mbps = down.speedBps / 1_000_000
        if down.code == 200 {
            let upText = up.code == 200 ? String(format: ", up %.2f MB/s", up.speedBps / 1_000_000) : ""
            let state: State = mbps < 0.5 ? .warn : .pass
            set(6, state, String(format: "Down %.2f MB/s%@ (typical: about 1.5 MB/s).", mbps, upText),
                fix: state == .warn ? "Much slower than normal. This network may be dropping traffic. Try again later or on another network." : nil, started: t)
        } else {
            set(6, .fail, "The download did not finish.", fix: "The tunnel stalled under load. Reconnect and test again.", started: t)
        }

        // 8. Parallel load: 4 concurrent downloads must all complete.
        t = Date()
        stages[7].state = .running
        let results = await withTaskGroup(of: ProxyCurl.Timing.self) { g -> [ProxyCurl.Timing] in
            for _ in 0..<4 {
                g.addTask { await ProxyCurl.get("https://speed.cloudflare.com/__down?bytes=4000000", proxy: socks, maxTime: 60, saveBody: false) }
            }
            var out: [ProxyCurl.Timing] = []
            for await r in g { out.append(r) }
            return out
        }
        let okCount = results.filter { $0.code == 200 }.count
        let each = results.filter { $0.code == 200 }.map(\.speedBps).reduce(0, +) / Double(max(okCount, 1)) / 1_000_000
        if okCount == 4 {
            set(7, .pass, String(format: "All 4 downloads finished (about %.2f MB/s each).", each), started: t)
        } else {
            set(7, .fail, "\(okCount) of 4 parallel downloads finished.", fix: "The tunnel struggles under load. Reconnect and test again.", started: t)
        }

        await popular(socks: socks)
    }

    private func popular(socks: String) async {
        let t = Date()
        stages[8].state = .running
        let sites = ["web.telegram.org", "www.google.com", "www.youtube.com", "github.com", "www.instagram.com"]
        var lines: [String] = []
        var failed = 0
        for site in sites {
            let r = await ProxyCurl.get("https://\(site)/", proxy: socks, maxTime: 15, saveBody: false, extra: ["-I"])
            if r.code > 0 { lines.append(String(format: "%@ %.2f s", site, r.seconds)) } else { failed += 1; lines.append("\(site) failed") }
        }
        set(8, failed == 0 ? .pass : (failed < sites.count ? .warn : .fail), lines.joined(separator: " · "),
            fix: failed > 0 ? "Some sites did not load through the tunnel." : nil, started: t)
    }

    /// Plain-text report without secrets (server IP is the user's own and shown, passwords never are).
    func report(profile: ServerProfile?) -> String {
        var s = "Sonar \(Versions.app) connection test, \(Date().formatted(date: .abbreviated, time: .standard))\n"
        if let p = profile { s += "Profile: \(p.name)\n" }
        for st in stages {
            let mark: String
            switch st.state {
            case .pass: mark = "PASS"
            case .warn: mark = "WARN"
            case .fail: mark = "FAIL"
            case .skipped: mark = "SKIP"
            default: mark = "----"
            }
            s += "\(mark) \(st.title): \(st.detail)"
            if st.seconds > 0 { s += String(format: " (%.1f s)", st.seconds) }
            if let f = st.fix { s += "\n     fix: \(f)" }
            s += "\n"
        }
        return s
    }
}
