import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ServiceManagement
import UserNotifications

/// Share the Mac's proxy with a phone on the same Wi-Fi (V2Box, NekoRay).
enum LANShare {
    /// The Mac's current LAN IPv4 (Wi-Fi or Ethernet), preferring en0/en1.
    static func currentIP() -> String? {
        var addrs: [(String, String)] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            let ifa = cur.pointee
            if let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET), (ifa.ifa_flags & UInt32(IFF_UP)) != 0,
               (ifa.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                let name = String(cString: ifa.ifa_name)
                let ip = String(cString: host)
                if IPv4.isPrivate(ip), !ip.hasPrefix("127."), !ip.hasPrefix("169.254.") { addrs.append((name, ip)) }
            }
            p = ifa.ifa_next
        }
        for pref in ["en0", "en1", "en2"] { if let a = addrs.first(where: { $0.0 == pref }) { return a.1 } }
        return addrs.first(where: { $0.0.hasPrefix("en") })?.1 ?? addrs.first?.1
    }

    static func link(ip: String, port: Int, user: String, password: String, name: String = "Sonar") -> String {
        let cred = Data("\(user):\(password)".utf8).base64EncodedString()
        return "socks://\(cred)@\(ip):\(port)#\(name.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? name)"
    }

    /// Plain form many apps also accept.
    static func plainLink(ip: String, port: Int, user: String, password: String) -> String {
        "socks5://\(user):\(password)@\(ip):\(port)"
    }

    static func qr(_ text: String, size: CGFloat = 220) -> NSImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8)
        f.correctionLevel = "M"
        guard let img = f.outputImage else { return nil }
        let scale = size / img.extent.width
        let scaled = img.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let ns = NSImage(size: rep.size)
        ns.addRepresentation(rep)
        return ns
    }

    /// Rough public Wi-Fi hint: captive or open networks often use these ranges; we simply warn when not 192.168/172.16.
    static func looksPublic(_ ip: String) -> Bool { ip.hasPrefix("10.") || ip.hasPrefix("100.") }
}

/// Launch at login: SMAppService first; if it fails for an unsigned app, a LaunchAgent plist.
enum LoginItem {
    static let agentLabel = "com.g3ntrix.sonar.login"
    static var agentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
    }

    static var isEnabled: Bool {
        if SMAppService.mainApp.status == .enabled { return true }
        return FileManager.default.fileExists(atPath: agentURL.path)
    }

    static func set(_ on: Bool) throws {
        if on {
            do {
                try SMAppService.mainApp.register()
                if SMAppService.mainApp.status == .enabled { return }
            } catch {}
            try writeAgent()
        } else {
            try? SMAppService.mainApp.unregister()
            try? FileManager.default.removeItem(at: agentURL)
        }
    }

    private static func writeAgent() throws {
        let plist: [String: Any] = [
            "Label": agentLabel,
            "ProgramArguments": ["/usr/bin/open", "-g", "-a", Bundle.main.bundlePath],
            "RunAtLoad": true,
        ]
        try FileManager.default.createDirectory(at: agentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let d = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try d.write(to: agentURL)
    }
}

/// Notifications only for events that need the user. Silently does nothing when running outside an .app bundle.
enum Notifier {
    private static var available: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app") }

    static func requestPermission() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(_ title: String, _ body: String) {
        guard available else { return }
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}

/// Checks GitHub releases for a newer version.
enum UpdateService {
    struct Release: Equatable {
        var version: String
        var url: URL
        var notes: String
    }

    /// nil when the check itself failed (offline, releases page missing); `.some(nil)` when there is no release.
    static func check() async -> Release?? {
        guard let url = URL(string: "https://api.github.com/repos/\(Brand.releasesRepo)/releases/latest") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Sonar-macOS", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String,
              let html = (obj["html_url"] as? String).flatMap(URL.init(string:)) else { return .some(nil) }
        let v = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return .some(Release(version: v, url: html, notes: obj["body"] as? String ?? ""))
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }, pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}

enum Terminal {
    /// Opens Terminal.app with the command typed but not run (the user presses Enter).
    static func open(typing command: String) {
        let esc = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let src = """
        tell application "Terminal"
            activate
            if (count of windows) is 0 then do script ""
            delay 0.3
        end tell
        tell application "System Events" to tell process "Terminal" to keystroke "\(esc)"
        """
        var err: NSDictionary?
        NSAppleScript(source: src)?.executeAndReturnError(&err)
        if err != nil {
            // No Accessibility permission for keystrokes: open Terminal and put the command on the clipboard.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
        }
    }
}
