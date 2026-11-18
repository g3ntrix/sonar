import Foundation

/// Builds the Xray JSON with the tested outbound shape.
enum XrayConfig {
    struct LAN {
        var user: String
        var password: String
    }

    static func build(secrets: ProfileSecrets, settings s: TunnelSettings, lan: LAN?, logLevel: String = "warning") -> [String: Any] {
        let sniff: [String: Any] = ["enabled": true, "destOverride": ["http", "tls"]]
        var inbounds: [[String: Any]] = [
            ["tag": "socks", "port": s.socksPort, "listen": "127.0.0.1", "protocol": "socks",
             "settings": ["udp": true], "sniffing": sniff],
            ["tag": "socks2", "port": s.socks2Port, "listen": "127.0.0.1", "protocol": "socks",
             "settings": ["udp": true], "sniffing": sniff],
            ["tag": "http", "port": s.httpPort, "listen": "127.0.0.1", "protocol": "http"],
        ]
        if let lan {
            inbounds.append([
                "tag": "lan", "port": s.lanPort, "listen": "0.0.0.0", "protocol": "socks",
                "settings": ["auth": "password", "accounts": [["user": lan.user, "pass": lan.password]], "udp": true],
            ])
        }
        let outbound: [String: Any] = [
            "tag": "proxy",
            "protocol": "hysteria",
            "settings": ["version": 2, "address": "127.0.0.1", "port": s.relayLocalPort],
            "streamSettings": [
                "network": "hysteria",
                "hysteriaSettings": ["version": 2, "auth": secrets.hysteriaPassword],
                "security": "tls",
                "tlsSettings": ["serverName": s.sni, "pinnedPeerCertSha256": secrets.certPin, "alpn": ["h3"]],
                "finalmask": [
                    "udp": [["type": "salamander", "settings": ["password": secrets.obfsPassword]]],
                    "quicParams": ["congestion": "brutal", "brutalUp": "\(s.brutalUpMbps)mbps", "brutalDown": "\(s.brutalDownMbps)mbps"],
                ],
            ],
        ]
        return ["log": ["loglevel": logLevel], "inbounds": inbounds, "outbounds": [outbound]]
    }

    static func data(_ config: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
    }

    /// Writes the config to a private (0600) temp file. The caller deletes it on stop.
    static func writeTemp(_ config: [String: Any]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sonar-\(UUID().uuidString.prefix(8)).json")
        let d = try data(config)
        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let h = try FileHandle(forWritingTo: url)
        try h.write(contentsOf: d)
        try h.close()
        return url
    }
}
