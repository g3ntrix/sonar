import XCTest
@testable import Sonar

final class SonarTests: XCTestCase {
    private func secrets() throws -> ProfileSecrets { try SecretGenerator.newSecrets() }

    func testXrayOutboundShape() throws {
        let s = try secrets()
        let cfg = XrayConfig.build(secrets: s, settings: .default, lan: nil)
        let out = (cfg["outbounds"] as! [[String: Any]])[0]
        XCTAssertEqual(out["protocol"] as? String, "hysteria")
        let settings = out["settings"] as! [String: Any]
        XCTAssertEqual(settings["version"] as? Int, 2)
        XCTAssertEqual(settings["address"] as? String, "127.0.0.1")
        XCTAssertEqual(settings["port"] as? Int, 18096)
        let ss = out["streamSettings"] as! [String: Any]
        XCTAssertEqual(ss["network"] as? String, "hysteria")
        XCTAssertEqual(ss["security"] as? String, "tls")
        let tls = ss["tlsSettings"] as! [String: Any]
        XCTAssertEqual(tls["serverName"] as? String, "www.bing.com")
        XCTAssertEqual(tls["alpn"] as? [String], ["h3"])
        XCTAssertEqual(tls["pinnedPeerCertSha256"] as? String, s.certPin)
        let fm = ss["finalmask"] as! [String: Any]
        let udp = (fm["udp"] as! [[String: Any]])[0]
        XCTAssertEqual(udp["type"] as? String, "salamander")
        let q = fm["quicParams"] as! [String: Any]
        XCTAssertEqual(q["congestion"] as? String, "brutal")
        XCTAssertEqual(q["brutalUp"] as? String, "10mbps")
        XCTAssertEqual(q["brutalDown"] as? String, "20mbps")
        let inbounds = cfg["inbounds"] as! [[String: Any]]
        XCTAssertEqual(inbounds.map { $0["port"] as? Int }, [10808, 10809, 10810])
        XCTAssertTrue(inbounds.allSatisfy { $0["listen"] as? String == "127.0.0.1" })
    }

    func testLANInboundRequiresPassword() throws {
        let cfg = XrayConfig.build(secrets: try secrets(), settings: .default, lan: .init(user: "phone", password: "pw123456"))
        let lan = (cfg["inbounds"] as! [[String: Any]]).first { $0["tag"] as? String == "lan" }!
        XCTAssertEqual(lan["listen"] as? String, "0.0.0.0")
        XCTAssertEqual(lan["port"] as? Int, 10811)
        XCTAssertEqual((lan["settings"] as! [String: Any])["auth"] as? String, "password")
    }

    func testConfigFileIsPrivate() throws {
        let url = try XrayConfig.writeTemp(XrayConfig.build(secrets: try secrets(), settings: .default, lan: nil))
        defer { try? FileManager.default.removeItem(at: url) }
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
    }

    func testInstallScriptIsDeterministicAndComplete() throws {
        let s = try secrets()
        let p = ServerProfile(name: "t", address: "203.0.113.10")
        let a = try ServerScript.installScript(profile: p, secrets: s)
        let b = try ServerScript.installScript(profile: p, secrets: s)
        XCTAssertEqual(a, b, "same profile must give the same script (re-running keeps the pin)")
        XCTAssertFalse(a.contains("__"), "unfilled placeholder in install script")
        XCTAssertTrue(a.contains(s.hysteriaPassword))
        XCTAssertTrue(a.contains("listen: 127.0.0.1:$HY_PORT"))
        XCTAssertTrue(a.contains("icmp_echo_ignore_all"))
        let cmd = ServerScript.oneLiner(for: a)
        XCTAssertFalse(cmd.contains("\n"), "install command must be one line")
    }

    func testInstallCommandDecodesOnThisMac() throws {
        let p = ServerProfile(name: "t", address: "203.0.113.10")
        let script = try ServerScript.installScript(profile: p, secrets: try secrets())
        let cmd = ServerScript.oneLiner(for: script)
        let payload = cmd.components(separatedBy: "echo '")[1].components(separatedBy: "'")[0]
        let r = Shell.runSync("/bin/sh", ["-c", "echo '\(payload)' | base64 -D | gunzip | bash -n && echo ok"])
        XCTAssertEqual(r.out.trimmingCharacters(in: .whitespacesAndNewlines), "ok", r.err)
    }

    func testUninstallCommandIsSecretFreeAndValid() throws {
        let script = try ServerScript.uninstallScript()
        XCTAssertFalse(script.contains("__"), "unfilled placeholder in uninstall script")
        let cmd = try ServerScript.fullUninstallCommand()
        XCTAssertTrue(cmd.contains("--uninstall"))
        XCTAssertFalse(cmd.contains("\n"), "uninstall command must be one line")
        // Decodes and parses as bash on this Mac.
        let payload = cmd.components(separatedBy: "echo '")[1].components(separatedBy: "'")[0]
        let r = Shell.runSync("/bin/sh", ["-c", "echo '\(payload)' | base64 -D | gunzip | bash -n && echo ok"])
        XCTAssertEqual(r.out.trimmingCharacters(in: .whitespacesAndNewlines), "ok", r.err)
        // No app-generated secret leaks into a removal command.
        let s = try SecretGenerator.newSecrets()
        XCTAssertFalse(script.contains(s.hysteriaPassword))
    }

    func testCountryFlag() {
        XCTAssertEqual(Egress.Info(ip: "1.2.3.4", countryCode: "US").flag, "🇺🇸")
        XCTAssertEqual(Egress.Info(ip: "1.2.3.4", countryCode: "de").flag, "🇩🇪")
        XCTAssertNil(Egress.Info(ip: "1.2.3.4", countryCode: nil).flag)
        XCTAssertNil(Egress.Info(ip: "1.2.3.4", countryCode: "X").flag)
    }

    func testCertificateParsesAndPinMatches() throws {
        let s = try secrets()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cert = dir.appendingPathComponent("c.pem"), key = dir.appendingPathComponent("k.pem")
        try s.certPEM.write(to: cert, atomically: true, encoding: .utf8)
        try s.keyPEM.write(to: key, atomically: true, encoding: .utf8)
        let text = Shell.runSync("/usr/bin/openssl", ["x509", "-in", cert.path, "-noout", "-text"])
        XCTAssertTrue(text.ok, text.err)
        XCTAssertTrue(text.out.contains("DNS:www.bing.com"))
        if let dir = ProcessInfo.processInfo.environment["SONAR_CERT_OUT"], !dir.isEmpty {
            try s.certPEM.write(toFile: dir + "/c.pem", atomically: true, encoding: .utf8)
            try s.keyPEM.write(toFile: dir + "/k.pem", atomically: true, encoding: .utf8)
        }
        let fp = Shell.runSync("/usr/bin/openssl", ["x509", "-in", cert.path, "-noout", "-fingerprint", "-sha256"]).out
        let hex = fp.split(separator: "=").last!.replacingOccurrences(of: ":", with: "").lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(hex, s.certPin)
        // Key and certificate belong together.
        let pub1 = Shell.runSync("/usr/bin/openssl", ["x509", "-in", cert.path, "-noout", "-pubkey"]).out
        let pub2 = Shell.runSync("/usr/bin/openssl", ["pkey", "-in", key.path, "-pubout"]).out
        XCTAssertEqual(pub1, pub2)
    }

    func testPasteParserFindsAddressAndStatus() {
        XCTAssertEqual(PasteParser.findAddress("ssh -i ~/k.key ubuntu@203.0.113.7")?.address, "203.0.113.7")
        XCTAssertEqual(PasteParser.findAddress("ssh -i ~/k.key ubuntu@203.0.113.7")?.user, "ubuntu")
        XCTAssertEqual(PasteParser.findAddress("Public IP: 10.0.0.5 and 198.51.100.20")?.address, "198.51.100.20")
        let out = """
        ubuntu@vps:~$ sudo sonar-server --status
        ==== Sonar server status ====
        OK    hysteria2  Hysteria2 on 127.0.0.1:2095 (local only)
        FAIL  sysctl     kernel leaves pings to the relay
        SONAR-STATUS: result=fail profile=ABC scripts=1 relay=1 hy=1 sysctl=0 fw=iptables probe=kernel
        """
        let r = PasteParser.parse(out)
        XCTAssertEqual(r.status?.ok, false)
        XCTAssertEqual(r.status?.scriptsVersion, 1)
        XCTAssertEqual(r.status?.failedRows.count, 1)
    }

    func testPasteParserKnownErrors() {
        let ids = PasteParser.parse("E: Could not get lock /var/lib/dpkg/lock-frontend").errors.map(\.id)
        XCTAssertEqual(ids, ["apt-lock"])
        XCTAssertTrue(PasteParser.parse("ubuntu@1.2.3.4: Permission denied (publickey).").errors.contains { $0.id == "ssh-key" })
        XCTAssertTrue(PasteParser.parse("SONAR-ERROR: Another ICMP relay (icmp-relay.service) is already running").errors.contains { $0.id == "other-relay" })
        let chk = PasteParser.parse("SONAR-CHECK root=sudo-password\nSONAR-CHECK systemd=yes\nSONAR-CHECK other_relay=yes")
        XCTAssertEqual(chk.check["root"], "sudo-password")
        XCTAssertTrue(chk.errors.contains { $0.id == "chk-relay" })
    }

    func testIPv4Validation() {
        XCTAssertTrue(IPv4.isValid("203.0.113.1"))
        XCTAssertFalse(IPv4.isValid("256.1.1.1"))
        XCTAssertFalse(IPv4.isValid("01.2.3.4"))
        XCTAssertTrue(IPv4.isPrivate("192.168.1.160"))
        XCTAssertTrue(IPv4.isHostname("vps.example.com"))
    }

    func testRedaction() async {
        await MainActor.run {
            let l = LogStore()
            l.setSecrets(["supersecretpw"])
            l.add("x", "auth supersecretpw failed")
            XCTAssertEqual(l.lines.last?.text, "auth ‹redacted› failed")
        }
    }

    func testVersionCompare() {
        XCTAssertTrue(UpdateService.isNewer("1.0.1", than: "1.0.0"))
        XCTAssertFalse(UpdateService.isNewer("1.0", than: "1.0.0"))
        XCTAssertTrue(UpdateService.isNewer("2.0", than: "1.9.9"))
    }

    func testSecretStoreRoundTripAndPrivateFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sonar-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        SecretStore.fileURL = dir.appendingPathComponent("secrets.json")
        SecretStore.skipLegacyMigration = true
        SecretStore.resetCacheForTesting()

        let id = UUID(), s = try secrets()
        XCTAssertNil(try SecretStore.load(for: id))
        try SecretStore.save(s, for: id)

        SecretStore.resetCacheForTesting()   // force a read from disk
        XCTAssertEqual(try SecretStore.load(for: id), s)

        let fileMode = try FileManager.default.attributesOfItem(atPath: SecretStore.fileURL.path)[.posixPermissions] as? Int
        let dirMode = try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int
        XCTAssertEqual(fileMode, 0o600)
        XCTAssertEqual(dirMode, 0o700)

        SecretStore.delete(for: id)
        SecretStore.resetCacheForTesting()
        XCTAssertNil(try SecretStore.load(for: id))
    }
}
