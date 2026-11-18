import AppKit
import Foundation

/// One-time admin install of a tiny wrapper plus a scoped NOPASSWD sudoers rule for `/usr/local/bin/sonar-proxy`
/// (Loole's ProxyHelper pattern). Afterwards the app toggles the system proxy without a password prompt.
/// Works without code signing.
enum ProxyHelper {
    static let sudoersPath = "/etc/sudoers.d/sonar-proxy"
    static let helperPath = "/usr/local/bin/sonar-proxy"
    static let helperVersion = "1.0.0"

    enum HelperError: LocalizedError {
        case promptCancelled
        case installFailed(String)
        var errorDescription: String? {
            switch self {
            case .promptCancelled: return "Admin permission was cancelled."
            case .installFailed(let m): return "System proxy helper install failed: \(m)"
            }
        }
    }

    /// Quick check (files only), safe on the main thread.
    static var looksInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: helperPath) && FileManager.default.fileExists(atPath: sudoersPath)
    }

    /// Full check off the main thread.
    static func checkInstalled() async -> Bool {
        await Task.detached { isInstalled() }.value
    }

    static func isInstalled() -> Bool {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: helperPath), fm.fileExists(atPath: sudoersPath) else { return false }
        let r = Shell.runSync("/usr/bin/sudo", ["-n", helperPath, "--self-check"], timeout: 5)
        return r.ok && r.out.trimmingCharacters(in: .whitespacesAndNewlines) == helperVersion
    }

    @discardableResult
    static func run(_ args: [String]) -> Int32 {
        Shell.runSync("/usr/bin/sudo", ["-n", helperPath] + args, timeout: 20).status
    }

    static func install() throws {
        let user = NSUserName()
        // Only networksetup on all services; the ports are validated as numbers.
        let script = #"""
        #!/bin/bash
        # sonar-proxy: scoped wrapper for the Sonar app's system proxy toggles (SOCKS, HTTP, HTTPS).
        set -uo pipefail
        if [ "${1:-}" = "--self-check" ]; then echo "__VERSION__"; exit 0; fi
        ACTION="${1:-}"; SOCKS="${2:-}"; HTTP="${3:-}"
        services() { /usr/sbin/networksetup -listallnetworkservices | /usr/bin/tail -n +2 | /usr/bin/grep -v '^[*]'; }
        case "$ACTION" in
          enable)
            [[ "$SOCKS" =~ ^[0-9]{1,5}$ && "$HTTP" =~ ^[0-9]{1,5}$ ]] || { echo "usage: $0 enable SOCKS_PORT HTTP_PORT" >&2; exit 1; }
            services | while IFS= read -r svc; do
              /usr/sbin/networksetup -setsocksfirewallproxy "$svc" 127.0.0.1 "$SOCKS" off 2>/dev/null || true
              /usr/sbin/networksetup -setwebproxy "$svc" 127.0.0.1 "$HTTP" off 2>/dev/null || true
              /usr/sbin/networksetup -setsecurewebproxy "$svc" 127.0.0.1 "$HTTP" off 2>/dev/null || true
            done ;;
          disable)
            services | while IFS= read -r svc; do
              /usr/sbin/networksetup -setsocksfirewallproxystate "$svc" off 2>/dev/null || true
              /usr/sbin/networksetup -setwebproxystate "$svc" off 2>/dev/null || true
              /usr/sbin/networksetup -setsecurewebproxystate "$svc" off 2>/dev/null || true
            done ;;
          *) echo "usage: $0 enable SOCKS_PORT HTTP_PORT | disable" >&2; exit 1 ;;
        esac
        """#.replacingOccurrences(of: "__VERSION__", with: helperVersion)

        let helperB64 = Data(script.utf8).base64EncodedString()
        let sudoersB64 = Data("\(user) ALL=(ALL) NOPASSWD: \(helperPath)\n".utf8).base64EncodedString()
        let shell = """
        set -e
        mkdir -p /usr/local/bin
        echo '\(helperB64)' | /usr/bin/base64 -D > '\(helperPath)'
        chown root:wheel '\(helperPath)'
        chmod 755 '\(helperPath)'
        echo '\(sudoersB64)' | /usr/bin/base64 -D > '\(sudoersPath).tmp'
        chown root:wheel '\(sudoersPath).tmp'
        chmod 440 '\(sudoersPath).tmp'
        /usr/sbin/visudo -cf '\(sudoersPath).tmp' >/dev/null
        mv -f '\(sudoersPath).tmp' '\(sudoersPath)'
        """
        try runAdmin(shell, prompt: "Sonar needs one-time permission to install a small system proxy helper. After this, turning the system proxy on or off needs no password.")
    }

    static func uninstall() throws {
        try runAdmin("rm -f '\(helperPath)' '\(sudoersPath)'", prompt: "Sonar wants to remove its system proxy helper.")
    }

    static func runAdmin(_ shell: String, prompt: String) throws {
        let esc = { (s: String) in s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        let source = "do shell script \"\(esc(shell))\" with administrator privileges with prompt \"\(esc(prompt))\""
        var err: NSDictionary?
        guard let script = NSAppleScript(source: source) else { throw HelperError.installFailed("NSAppleScript init failed") }
        _ = script.executeAndReturnError(&err)
        if let e = err {
            if (e[NSAppleScript.errorNumber] as? Int) == -128 { throw HelperError.promptCancelled }
            throw HelperError.installFailed((e[NSAppleScript.errorMessage] as? String) ?? "unknown")
        }
    }
}

enum SystemProxy {
    static func enable(socks: Int, http: Int) async throws {
        try await Task.detached {
            if !ProxyHelper.isInstalled() { try ProxyHelper.install() }
            let rc = ProxyHelper.run(["enable", String(socks), String(http)])
            if rc != 0 { throw ProxyHelper.HelperError.installFailed("enable returned \(rc)") }
        }.value
    }

    static func disable() async {
        await Task.detached { disableSync() }.value
    }

    /// Restores the system proxy (no prompt when the helper is installed). Called on quit and disconnect.
    static func disableSync() {
        if ProxyHelper.isInstalled() { ProxyHelper.run(["disable"]) }
    }

    /// True when the system proxy currently points at the given local SOCKS port.
    static func isEnabled(socks: Int) -> Bool {
        let out = Shell.runSync("/usr/sbin/scutil", ["--proxy"], timeout: 5).out
        return out.contains("SOCKSEnable : 1") && out.contains("SOCKSPort : \(socks)")
    }
}
