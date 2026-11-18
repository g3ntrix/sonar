import Foundation

/// Runs helper commands. The environment is cleaned of proxy variables so a tester never measures a different
/// proxy by accident (when the shell has HTTP(S)_PROXY set).
enum Shell {
    struct Result {
        var status: Int32
        var out: String
        var err: String
        var ok: Bool { status == 0 }
    }

    static var cleanEnvironment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        for k in ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy", "NO_PROXY", "no_proxy"] {
            env.removeValue(forKey: k)
        }
        return env
    }

    /// Runs a program and waits (off the main thread). `timeout` kills it when it takes too long.
    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 60) async -> Result {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: runSync(path, args, timeout: timeout))
            }
        }
    }

    static func runSync(_ path: String, _ args: [String], timeout: TimeInterval = 60) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.environment = cleanEnvironment
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { outData = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        do { try p.run() } catch {
            return Result(status: -1, out: "", err: error.localizedDescription)
        }
        let deadline = DispatchTime.now() + timeout
        DispatchQueue.global().asyncAfter(deadline: deadline) { if p.isRunning { p.terminate() } }
        p.waitUntilExit()
        group.wait()
        return Result(status: p.terminationStatus,
                      out: String(decoding: outData, as: UTF8.self),
                      err: String(decoding: errData, as: UTF8.self))
    }
}

/// Where the bundled helpers live: inside the .app, or in the repo's `bundle/` folder during development.
enum Paths {
    static var appSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Sonar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // Shipped under neutral names so the bundle does not reveal what the helpers are.
    static var relayd: String? { find(bundle: "SonarNet", dev: "relayd") }
    static var xray: String? { find(bundle: "SonarCore", dev: "xray") }

    private static func find(bundle: String, dev: String) -> String? {
        let fm = FileManager.default
        if let r = Bundle.main.resourceURL {
            let p = r.appendingPathComponent(bundle).path
            if fm.isExecutableFile(atPath: p) { return p }
        }
        // Development: walk up from the executable to a folder that has bundle/<dev>.
        var dir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<6 {
            let p = dir.appendingPathComponent("bundle").appendingPathComponent(dev).path
            if fm.isExecutableFile(atPath: p) { return p }
            dir.deleteLastPathComponent()
        }
        return nil
    }

    static let curl = "/usr/bin/curl"
    static let lsof = "/usr/sbin/lsof"
}
