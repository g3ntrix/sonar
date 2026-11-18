import Foundation
import Network

/// Who holds a local port (Sonar refuses to start on a busy port and says who has it).
enum PortCheck {
    struct Holder: Equatable {
        var port: Int
        var process: String
        var pid: Int32
        var isSonar: Bool { process.lowercased().contains("sonar") || process == "relayd" }
        var friendly: String {
            switch process.lowercased() {
            case let p where p.contains("sonar") || p == "relayd": return "Sonar is already running (\(process), pid \(pid))"
            case let p where p.contains("veil"): return "the Veil app (\(process), pid \(pid))"
            case let p where p.contains("nekoray") || p.contains("nekobox"): return "NekoRay (\(process), pid \(pid))"
            case "xray": return "another Xray (pid \(pid)), maybe Veil or a script"
            default: return "\(process) (pid \(pid))"
            }
        }
    }

    static func holder(tcp port: Int) -> Holder? { parse(Shell.runSync(Paths.lsof, ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fpc"], timeout: 5).out, port) }
    static func holder(udp port: Int) -> Holder? { parse(Shell.runSync(Paths.lsof, ["-nP", "-iUDP:\(port)", "-Fpc"], timeout: 5).out, port) }

    static func parse(_ out: String, _ port: Int) -> Holder? {
        var pid: Int32?
        for line in out.split(separator: "\n") {
            if line.hasPrefix("p") { pid = Int32(line.dropFirst()) }
            if line.hasPrefix("c"), let pid { return Holder(port: port, process: String(line.dropFirst()), pid: pid) }
        }
        return nil
    }

    /// True when something accepts TCP connections on 127.0.0.1:port.
    static func listening(_ port: Int, timeout: TimeInterval = 1) async -> Bool {
        await TCPReach.check(host: "127.0.0.1", port: UInt16(port), timeout: timeout)
    }
}

enum TCPReach {
    /// Opens a TCP connection and closes it again. Used for "is SSH reachable" (port 22) and local ports.
    static func check(host: String, port: UInt16, timeout: TimeInterval = 3) async -> Bool {
        await withCheckedContinuation { cont in
            let conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            let lock = NSLock()
            var done = false
            func finish(_ v: Bool) {
                lock.lock(); defer { lock.unlock() }
                guard !done else { return }
                done = true
                conn.cancel()
                cont.resume(returning: v)
            }
            conn.stateUpdateHandler = { st in
                switch st {
                case .ready: finish(true)
                case .failed, .cancelled: finish(false)
                case .waiting: finish(false)
                default: break
                }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(false) }
        }
    }
}

/// Wraps `relayd probe` and `relayd doctor`.
enum Probe {
    struct Result: Codable, Equatable {
        var server: String
        var pingSent: Int
        var pingReplies: Int
        var rttMs: Double
        var pollSent: Int
        var relayReplies: Int
        var kernelReplies: Int
        var lossPct: Double
        var verdict: String
        var error: String?

        var relayAnswers: Bool { verdict == "relay" || verdict == "relay+kernel" }
        var kernelAnswers: Bool { verdict == "kernel-only" || verdict == "relay+kernel" }
        var silent: Bool { verdict == "silent" }
    }

    struct Doctor: Codable, Equatable {
        var icmp: Bool
        var icmpHost: String?
        var icmpRttMs: Double?
        var udp: Bool
        var udpHost: String?
        var udpRttMs: Double?
        var error: String?
    }

    static func probe(_ server: String, count: Int = 20) async -> Result? {
        guard let relayd = Paths.relayd else { return nil }
        let r = await Shell.run(relayd, ["check", "--server", server, "--count", String(count)], timeout: 30)
        return decode(Result.self, r.out)
    }

    static func doctor() async -> Doctor? {
        guard let relayd = Paths.relayd else { return nil }
        return decode(Doctor.self, await Shell.run(relayd, ["net"], timeout: 40).out)
    }

    private static func decode<T: Decodable>(_ t: T.Type, _ out: String) -> T? {
        guard let line = out.split(separator: "\n").last(where: { $0.hasPrefix("{") }) else { return nil }
        return try? JSONDecoder().decode(T.self, from: Data(line.utf8))
    }

    /// Resolves a hostname to its first IPv4 address (profiles may hold a hostname).
    static func resolveIPv4(_ host: String) -> String? {
        if IPv4.isValid(host) { return host }
        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0, let first = res else { return nil }
        defer { freeaddrinfo(res) }
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        let sin = first.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
        var addr = sin.sin_addr
        inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN))
        return String(cString: buf)
    }
}

enum IPv4 {
    static func isValid(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { p in
            guard !p.isEmpty, p.count <= 3, p.allSatisfy(\.isNumber), let v = Int(p) else { return false }
            return v <= 255 && !(p.count > 1 && p.hasPrefix("0"))
        }
    }

    static func isPrivate(_ s: String) -> Bool {
        let o = s.split(separator: ".").compactMap { Int($0) }
        guard o.count == 4 else { return false }
        return o[0] == 10 || o[0] == 127 || (o[0] == 172 && (16...31).contains(o[1])) || (o[0] == 192 && o[1] == 168)
            || (o[0] == 100 && (64...127).contains(o[1])) || (o[0] == 169 && o[1] == 254) || o[0] == 0
    }

    static func isHostname(_ s: String) -> Bool {
        let r = s.range(of: #"^(?=.{1,253}$)([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}$"#, options: .regularExpression)
        return r != nil
    }
}

/// curl through the local proxy. Never combines a proxy with --noproxy.
enum ProxyCurl {
    struct Timing {
        var ok: Bool
        var code: Int
        var seconds: Double
        var speedBps: Double
        var body: String
    }

    static func get(_ url: String, proxy: String, maxTime: Int = 15, saveBody: Bool = true, extra: [String] = []) async -> Timing {
        var args = ["-s", "-m", String(maxTime), "-x", proxy, "-w", "\n%{http_code} %{time_total} %{speed_download} %{speed_upload}"]
        if !saveBody { args += ["-o", "/dev/null"] }
        args += extra + [url]
        let r = await Shell.run(Paths.curl, args, timeout: TimeInterval(maxTime + 5))
        var lines = r.out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let stats = (lines.popLast() ?? "").split(separator: " ").map(String.init)
        let code = Int(stats.first ?? "") ?? 0
        let secs = Double(stats.count > 1 ? stats[1] : "") ?? 0
        let down = Double(stats.count > 2 ? stats[2] : "") ?? 0
        let up = Double(stats.count > 3 ? stats[3] : "") ?? 0
        return Timing(ok: r.ok && code > 0, code: code, seconds: secs, speedBps: max(down, up),
                      body: lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// Exit IP and location through the tunnel (pattern from Cloak's EgressInfoService).
enum Egress {
    struct Info: Equatable {
        var ip: String
        var country: String?
        var countryCode: String?
        var city: String?
        var org: String?
        var place: String { [city, country].compactMap { $0 }.joined(separator: ", ") }
        /// Flag emoji from the ISO country code (e.g. "US" -> 🇺🇸).
        var flag: String? {
            guard let cc = countryCode, cc.count == 2 else { return nil }
            let base: UInt32 = 0x1F1E6
            var s = ""
            for u in cc.uppercased().unicodeScalars {
                guard u.value >= 65, u.value <= 90, let scalar = Unicode.Scalar(base + (u.value - 65)) else { return nil }
                s.unicodeScalars.append(scalar)
            }
            return s
        }
    }

    static func ip(socksPort: Int) async -> String? {
        let t = await ProxyCurl.get("https://api.ipify.org", proxy: "socks5h://127.0.0.1:\(socksPort)", maxTime: 10)
        let ip = t.body.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.code == 200 && IPv4.isValid(ip) ? ip : nil
    }

    static func info(socksPort: Int) async -> Info? {
        let t = await ProxyCurl.get("https://ipwho.is/?fields=ip,country,country_code,city,connection", proxy: "socks5h://127.0.0.1:\(socksPort)", maxTime: 10)
        guard t.code == 200, let obj = try? JSONSerialization.jsonObject(with: Data(t.body.utf8)) as? [String: Any],
              let ip = obj["ip"] as? String else { return nil }
        let org = (obj["connection"] as? [String: Any])?["org"] as? String
        return Info(ip: ip, country: obj["country"] as? String, countryCode: obj["country_code"] as? String,
                    city: obj["city"] as? String, org: org)
    }
}
