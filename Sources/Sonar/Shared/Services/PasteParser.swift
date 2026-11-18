import Foundation

/// Understands whatever the user pastes back from the VPS: an ssh line, the status table, the pre-check output,
/// or an error. Strips prompts, finds IPs, recognises known failures.
enum PasteParser {
    struct Address: Equatable {
        var address: String
        var user: String?
    }

    struct Status: Equatable {
        var ok: Bool
        var fields: [String: String]
        var failedRows: [String]
        var scriptsVersion: Int? { fields["scripts"].flatMap(Int.init) }
        var profileID: String? { fields["profile"] }
    }

    struct KnownError: Equatable, Identifiable {
        var id: String
        var cause: String
        var fix: String
        var command: String?
    }

    struct Result: Equatable {
        var address: Address?
        var status: Status?
        var check: [String: String] = [:]
        var errors: [KnownError] = []
        var scriptError: (message: String, fix: String?)? = nil

        static func == (a: Result, b: Result) -> Bool {
            a.address == b.address && a.status == b.status && a.check == b.check && a.errors == b.errors
                && a.scriptError?.message == b.scriptError?.message
        }

        var isEmpty: Bool { address == nil && status == nil && check.isEmpty && errors.isEmpty && scriptError == nil }
    }

    static func parse(_ text: String) -> Result {
        var r = Result()
        let lines = text.split(whereSeparator: \.isNewline).map { stripPrompt(String($0)) }
        r.address = findAddress(text)

        for l in lines {
            if l.hasPrefix("SONAR-STATUS:") {
                var f: [String: String] = [:]
                for part in l.dropFirst("SONAR-STATUS:".count).split(separator: " ") {
                    let kv = part.split(separator: "=", maxSplits: 1)
                    if kv.count == 2 { f[String(kv[0])] = String(kv[1]) }
                }
                let failed = lines.filter { $0.hasPrefix("FAIL ") }.map { String($0.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
                r.status = Status(ok: f["result"] == "ok", fields: f, failedRows: failed)
            }
            if l.hasPrefix("SONAR-CHECK ") {
                let kv = l.dropFirst("SONAR-CHECK ".count).split(separator: "=", maxSplits: 1)
                if kv.count == 2 { r.check[String(kv[0])] = String(kv[1]) }
            }
            if l.hasPrefix("SONAR-ERROR:") {
                let msg = l.dropFirst("SONAR-ERROR:".count).trimmingCharacters(in: .whitespaces)
                let fix = lines.first(where: { $0.hasPrefix("FIX:") }).map { $0.dropFirst(4).trimmingCharacters(in: .whitespaces) }
                r.scriptError = (msg, fix)
            }
        }
        r.errors = knownErrors(text) + checkWarnings(r.check)
        return r
    }

    /// Removes shell prompts like `ubuntu@vps:~$ `, `root@x:/# `, `$ `, `# `.
    static func stripPrompt(_ line: String) -> String {
        var s = line.trimmingCharacters(in: .whitespaces)
        if let r = s.range(of: #"^[\w.-]+@[\w.-]+:[^$#]*[$#]\s?"#, options: .regularExpression) { s.removeSubrange(r) }
        if s.hasPrefix("$ ") || s.hasPrefix("# ") || s.hasPrefix("% ") { s.removeFirst(2) }
        return s
    }

    /// Finds `user@host` from an ssh line, or the first public IPv4 in the text.
    static func findAddress(_ text: String) -> Address? {
        if let m = text.range(of: #"ssh\s+(?:-\S+\s+(?:\S+\s+)?)*([A-Za-z0-9._-]+)@([A-Za-z0-9.-]+)"#, options: .regularExpression) {
            let s = String(text[m])
            let last = s.split(separator: " ").last.map(String.init) ?? ""
            let parts = last.split(separator: "@", maxSplits: 1).map(String.init)
            if parts.count == 2, IPv4.isValid(parts[1]) || IPv4.isHostname(parts[1]) {
                return Address(address: parts[1], user: parts[0])
            }
        }
        let ipRegex = try! NSRegularExpression(pattern: #"(?<![\d.])(\d{1,3}(?:\.\d{1,3}){3})(?![\d.])"#)
        let ns = text as NSString
        for m in ipRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let ip = ns.substring(with: m.range(at: 1))
            if IPv4.isValid(ip), !IPv4.isPrivate(ip) { return Address(address: ip, user: nil) }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if IPv4.isHostname(trimmed) { return Address(address: trimmed, user: nil) }
        return nil
    }

    static func knownErrors(_ text: String) -> [KnownError] {
        let t = text.lowercased()
        var out: [KnownError] = []
        func add(_ id: String, _ cause: String, _ fix: String, _ cmd: String? = nil) {
            if !out.contains(where: { $0.id == id }) { out.append(KnownError(id: id, cause: cause, fix: fix, command: cmd)) }
        }
        if t.contains("could not get lock") || t.contains("dpkg was interrupted") || t.contains("apt lock") || t.contains("unable to acquire the dpkg") {
            add("apt-lock", "The server is busy installing updates (the package manager is locked).",
                "Wait a few minutes, then run the install command again. If it stays stuck, reboot the VPS.", "sudo reboot")
        }
        if t.contains("python3: command not found") || t.contains("python3: not found") || t.contains("no such file or directory: python3") {
            add("no-python", "python3 is not installed on the server.", "Install it, then run the install command again.",
                "sudo apt-get update && sudo apt-get install -y python3")
        }
        if t.contains("address already in use") {
            add("port-in-use", "A port on the server is already used by another program.",
                "Run the install command again. It picks a free local port. If it still fails, paste the status table here.")
        }
        if t.contains("firewalld") && (t.contains("not running") || t.contains("error")) {
            add("firewalld", "firewalld reported an error.", "Remove the firewalld block below, then run the install command again.",
                "sudo firewall-cmd --permanent --remove-icmp-block=echo-request; sudo firewall-cmd --reload")
        }
        if t.contains("x-ui") && (t.contains("reject") || t.contains("drop")) {
            add("xui-rules", "Firewall rules (for example from x-ui) sit ahead of Sonar's rule.",
                "Run the install command again. It moves Sonar's rule to the top.")
        }
        if t.contains("icmp-relay.service") || t.contains("another icmp relay") {
            add("other-relay", "Another tunnel service is already running on this server.",
                "Stop it, then run the install command again.", "sudo systemctl disable --now icmp-relay")
        }
        if t.contains("permission denied (publickey") {
            add("ssh-key", "SSH refused the login: this computer's key is not on the server.",
                "Use the key your provider gave you, for example: ssh -i ~/Downloads/your-key.key ubuntu@IP")
        }
        if t.contains("connection timed out") || t.contains("operation timed out") || t.contains("connection refused") {
            add("ssh-timeout", "SSH could not reach the server.",
                "Check the IP. In the cloud console make sure the instance is running and port 22 is open.")
        }
        if t.contains("is not in the sudoers file") || t.contains("a password is required") || t.contains("sudo: a terminal is required") {
            add("sudo", "This user cannot use sudo.", "Log in as root (ssh root@IP) or as the provider's default user, such as ubuntu or debian.")
        }
        if t.contains("host key verification failed") || t.contains("remote host identification has changed") {
            add("host-key", "The server's identity changed (usually a rebuilt VPS with the same IP).",
                "Remove the old key from this Mac, then connect again.", "ssh-keygen -R SERVER_IP")
        }
        if t.contains("could not set net.ipv4.icmp_echo_ignore_all") || t.contains("read-only file system") && t.contains("sysctl") {
            add("sysctl", "This VPS doesn't allow changing network settings. It's probably a container VPS.", "Use a full virtual machine (KVM). Hetzner, DigitalOcean and Vultr all offer these.")
        }
        if t.contains("hysteria2 installer failed") || t.contains("get.hy2.sh") && t.contains("fail") {
            add("hy2-download", "The server couldn't download a required component.", "Check that the server can reach github.com, then run the install command again.")
        }
        return out
    }

    static func checkWarnings(_ c: [String: String]) -> [KnownError] {
        guard !c.isEmpty else { return [] }
        var out: [KnownError] = []
        if c["root"] == "no" || c["root"] == "sudo-password" {
            out.append(KnownError(id: "chk-root", cause: c["root"] == "no" ? "This user has no sudo." : "sudo asks for a password on this server.",
                                  fix: c["root"] == "no" ? "Log in as root or the provider's default user." : "That's OK. Type the password when the install asks for it."))
        }
        if c["systemd"] == "no" {
            out.append(KnownError(id: "chk-systemd", cause: "This server has no systemd.", fix: "Use Ubuntu 20.04+ or Debian 11+."))
        }
        if c["apt_busy"] == "yes" {
            out.append(KnownError(id: "chk-apt", cause: "Automatic updates are running right now.", fix: "The install waits for them. It may take a few minutes."))
        }
        if c["other_relay"] == "yes" {
            out.append(KnownError(id: "chk-relay", cause: "Another tunnel service is running on this server.",
                                  fix: "Stop it before installing Sonar.", command: "sudo systemctl disable --now icmp-relay"))
        }
        if let a = c["arch"], !["x86_64", "aarch64", "arm64", "amd64"].contains(a) {
            out.append(KnownError(id: "chk-arch", cause: "Unsupported CPU type \(a).", fix: "Use an amd64 or arm64 server."))
        }
        return out
    }
}
