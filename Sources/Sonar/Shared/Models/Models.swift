import Foundation

/// One server the user set up. Secrets live in SecretStore (`ProfileSecrets`), never here.
struct ServerProfile: Codable, Identifiable, Equatable, Hashable {
    var id: UUID = UUID()
    var name: String
    /// Public IPv4 or a hostname. ICMP has no port.
    var address: String
    var sshUser: String = "ubuntu"
    var created: Date = Date()
    /// Server scripts version reported by the server (pasted status table). nil = never seen.
    var installedVersion: Int?
    var lastCheck: CheckSummary?

    struct CheckSummary: Codable, Equatable, Hashable {
        var date: Date
        var ok: Bool
        var note: String
    }

    var sshCommand: String { "ssh \(sshUser)@\(address)" }

    var needsServerUpdate: Bool {
        guard let v = installedVersion else { return false }
        return v < Versions.serverScripts
    }
}

/// App-generated secrets for one profile. Deterministic server install comes from the app owning these.
struct ProfileSecrets: Codable, Equatable {
    var hysteriaPassword: String
    var obfsPassword: String
    var certPEM: String
    var keyPEM: String
    /// Lowercase hex SHA-256 of the certificate DER (Xray `pinnedPeerCertSha256`).
    var certPin: String
    var lanPassword: String
}

/// Tunnel constants. Tuning values are tested defaults; change only after testing on a real
/// network (exposed as hidden Advanced settings).
struct TunnelSettings: Codable, Equatable {
    var socksPort = 10808
    var socks2Port = 10809
    var httpPort = 10810
    var lanPort = 10811
    var relayLocalPort = 18096
    var pollCap = 1800
    var dup = 1
    var brutalUpMbps = 10
    var brutalDownMbps = 20
    var sni = "www.bing.com"
    var lanUser = "phone"

    static let `default` = TunnelSettings()
}

enum Versions {
    /// Version of the server scripts this app generates (install.sh). Bump when Resources/Server changes.
    static let serverScripts = 1
    /// Version of icmp_server.py this app ships (`# version:` line).
    static let serverRelay = 1

    static var app: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }
}

enum ConnectionStatus: Equatable {
    case disconnected
    case connecting(String)
    case connected
    case reconnecting(String)
    case disconnecting
    case error(String)

    var isActive: Bool {
        switch self {
        case .connecting, .connected, .reconnecting: return true
        default: return false
        }
    }

    var title: String {
        switch self {
        case .disconnected: return "Not connected"
        case .connecting: return "Connecting"
        case .connected: return "Connected"
        case .reconnecting: return "Reconnecting"
        case .disconnecting: return "Disconnecting"
        case .error: return "Error"
        }
    }

    var detail: String? {
        switch self {
        case .connecting(let s), .reconnecting(let s), .error(let s): return s
        default: return nil
        }
    }
}

/// Health of one layer of the tunnel (dashboard layer view and tester).
enum Health: String, Codable {
    case ok, degraded, down, unknown
}
