import SwiftUI
import UniformTypeIdentifiers

struct ServersView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var engine: Engine
    @State private var sheet: SheetKind?
    @State private var confirmDelete: ServerProfile?
    @State private var confirmRotate: ServerProfile?
    @State private var importError: String?

    enum SheetKind: Identifiable {
        case changeIP(ServerProfile), install(ServerProfile), health(ServerProfile), rename(ServerProfile), cleanup(ServerProfile)
        var id: String {
            switch self {
            case .changeIP(let p): return "ip\(p.id)"
            case .install(let p): return "in\(p.id)"
            case .health(let p): return "h\(p.id)"
            case .rename(let p): return "r\(p.id)"
            case .cleanup(let p): return "c\(p.id)"
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Servers").font(.system(size: 28, weight: .bold, design: .rounded))
                    Spacer()
                    Button { importProfile() } label: { Label("Import", systemImage: "square.and.arrow.down") }
                    Button { app.stored.wizard = WizardProgress(); app.showWizard = true } label: { Label("New server", systemImage: "plus") }
                        .buttonStyle(.borderedProminent)
                }
                if let e = importError { ErrorCard(cause: "Import failed", fix: e) }
                if app.profiles.isEmpty {
                    Card { Text("No servers yet. Click New server to set one up.").foregroundStyle(.secondary) }
                }
                ForEach(app.profiles) { p in row(p) }
            }
            .padding(28)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .sheet(item: $sheet) { s in
            switch s {
            case .changeIP(let p): ChangeIPSheet(profile: p)
            case .install(let p): InstallSheet(profile: p)
            case .health(let p): HealthSheet(profile: p)
            case .rename(let p): RenameSheet(profile: p)
            case .cleanup(let p): CleanupSheet(profile: p)
            }
        }
        .alert("Delete \(confirmDelete?.name ?? "")?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Delete", role: .destructive) { if let p = confirmDelete { Task { await app.delete(p) } } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the server and its keys from Sonar on this Mac. The server itself isn't changed. To clean it up too, use Remove from server first.")
        }
        .alert("Rotate credentials for \(confirmRotate?.name ?? "")?", isPresented: Binding(get: { confirmRotate != nil }, set: { if !$0 { confirmRotate = nil } })) {
            Button("Rotate") {
                if let p = confirmRotate {
                    Task {
                        try? await app.rotateCredentials(p)
                        if let q = app.profile(p.id) { sheet = .install(q) }
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Sonar creates new passwords and a new certificate. The old ones stop working once you run the new install command on the server. Phones will need the new QR code.")
        }
    }

    private func row(_ p: ServerProfile) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "server.rack").font(.title2).foregroundStyle(Brand.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(p.name).font(.headline)
                            if app.selectedProfile?.id == p.id { Text("Active").font(.caption).padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(Brand.accent.opacity(0.18))) }
                            if p.needsServerUpdate { Text("Server update available").font(.caption).foregroundStyle(.orange) }
                        }
                        Text("\(p.address) · ssh \(p.sshUser) · scripts v\(p.installedVersion.map(String.init) ?? "?")")
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                        if let c = p.lastCheck {
                            Text("\(c.ok ? "✓" : "✗") \(c.note) · \(c.date.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(c.ok ? .green : .orange)
                        }
                    }
                    Spacer()
                    if app.selectedProfile?.id != p.id { Button("Use") { Task { await app.select(p) } } }
                }
                HStack(spacing: 8) {
                    Button("Change IP") { sheet = .changeIP(p) }
                    Button("Install command") { sheet = .install(p) }
                    Button("Check health") { sheet = .health(p) }
                    Menu("More") {
                        Button("Rename") { sheet = .rename(p) }
                        Button("Duplicate") { app.duplicate(p) }
                        Button("Rotate credentials…") { confirmRotate = p }
                        Button("Export…") { export(p) }
                        Divider()
                        Button("Remove from server…") { sheet = .cleanup(p) }
                        Button("Delete from Sonar…", role: .destructive) { confirmDelete = p }
                    }
                    .fixedSize()
                }
                .controlSize(.small)
            }
        }
    }

    private func export(_ p: ServerProfile) {
        guard let s = app.secrets(for: p), let data = try? ProfileTransfer.export(p, s) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(p.name)-CONTAINS-SECRETS.\(ProfileTransfer.fileExtension)"
        panel.message = "This file contains your server's passwords and private key. Keep it private."
        if panel.runModal() == .OK, let url = panel.url {
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    private func importProfile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: ProfileTransfer.fileExtension) ?? .json, .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try app.importProfile(try Data(contentsOf: url)); importError = nil } catch { importError = error.localizedDescription }
    }
}

/// Same VPS, new IP: only the profile changes. Probes the new address and warns if the old one still answers.
struct ChangeIPSheet: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var tester: ConnectionTester
    @EnvironmentObject var engine: Engine
    @Environment(\.dismiss) private var dismiss
    let profile: ServerProfile
    @State private var newAddress = ""
    @State private var paste = ""
    @State private var checking = false
    @State private var newProbe: Probe.Result?
    @State private var oldProbe: Probe.Result?
    @State private var sshNew = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Change IP of \(profile.name)").font(.title2.bold())
            Text("If it is the same VPS with a new address, nothing changes on the server. Sonar only updates the profile and reconnects.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("Current: \(profile.address)").font(.callout.monospaced()).foregroundStyle(.secondary)
            }
            TextField("New IP address", text: $newAddress).textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
            if checking { HStack { ProgressRing(size: 18); Text("Probing \(newAddress)…").foregroundStyle(.secondary) } }
            if let r = newProbe { verdictView(r) }
            if let o = oldProbe, o.relayAnswers {
                Label("The old address \(profile.address) still responds as your Sonar server. Make sure you really want to switch.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange).font(.callout)
            }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Probe") { Task { await probe() } }.disabled(!valid || checking)
                Button("Save and reconnect") {
                    Task {
                        await app.changeAddress(profile, to: newAddress.trimmingCharacters(in: .whitespaces))
                        dismiss()
                        app.selection = .test
                        if let p = app.profile(profile.id) {
                            await app.select(p)
                            if engine.status != .connected { await app.connect() }
                            tester.run(engine: engine, profile: p)
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!valid || checking)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private var valid: Bool {
        let a = newAddress.trimmingCharacters(in: .whitespaces)
        return (IPv4.isValid(a) || IPv4.isHostname(a)) && a != profile.address
    }

    @ViewBuilder private func verdictView(_ r: Probe.Result) -> some View {
        if r.relayAnswers {
            Label("Your Sonar server responds at the new address. You can save.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        } else if r.kernelAnswers || (r.silent && sshNew) {
            ErrorCard(cause: "This server is online, but Sonar isn't set up on it.",
                      fix: "Run the setup command on it again. Your keys stay the same. If it still doesn't answer, check the firewall step in Setup.")
        } else {
            ErrorCard(cause: "No answer from \(newAddress).", fix: "Check the IP and that the server is running. Its firewall may also be blocking Sonar. See the firewall step in Setup.")
        }
    }

    private func probe() async {
        checking = true
        let a = newAddress.trimmingCharacters(in: .whitespaces)
        let ip = Probe.resolveIPv4(a) ?? a
        async let n = Probe.probe(ip, count: 10)
        async let o = Probe.probe(Probe.resolveIPv4(profile.address) ?? profile.address, count: 6)
        async let s = TCPReach.check(host: ip, port: 22)
        newProbe = await n
        oldProbe = await o
        sshNew = await s
        checking = false
    }
}

struct InstallSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    let profile: ServerProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Install command for \(profile.name)").font(.title2.bold())
            Text("Run it on the server over SSH. You can run it again any time, for example after a rebuild, an update or new credentials.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            CommandBlock(command: profile.sshCommand, terminalCommand: profile.sshCommand, caption: "1. Log in")
            if let c = app.installCommand(profile) { CommandBlock(command: c, caption: "2. Paste this on the VPS", copyOnly: true) }
            CodeBlock(label: "REMOVE SONAR FROM THE VPS", code: ServerScript.uninstallCommand)
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(24)
        .frame(width: 620)
    }
}

struct HealthSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    let profile: ServerProfile
    @State private var paste = ""
    @State private var parsed = PasteParser.Result()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Check server health").font(.title2.bold())
            CommandBlock(command: ServerScript.statusCommand, caption: "Run this on the VPS")
            PasteBox(prompt: "Paste the output here:", text: $paste) { s in
                parsed = PasteParser.parse(s)
                if let st = parsed.status { app.recordStatus(st, for: profile) }
            }
            if !parsed.isEmpty { PasteFindings(result: parsed) }
            if let st = parsed.status, let v = st.scriptsVersion, v < Versions.serverScripts {
                Label("The server has version \(v) and this app has version \(Versions.serverScripts). Run the install command again to update.", systemImage: "arrow.up.circle")
                    .foregroundStyle(.orange)
            }
            if let st = parsed.status, let pid = st.profileID, !pid.isEmpty, pid != profile.id.uuidString {
                Label("This server was set up by a different Sonar profile. Run this profile's install command to take it over.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(24)
        .frame(width: 560)
    }
}

struct RenameSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    let profile: ServerProfile
    @State private var name = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename").font(.title2.bold())
            TextField("Name", text: $name).textFieldStyle(.roundedBorder)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") { var p = profile; p.name = name; app.update(p); dismiss() }
                    .buttonStyle(.borderedProminent).disabled(name.isEmpty).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 360)
        .onAppear { name = profile.name }
    }
}

/// Remove everything Sonar installed on the VPS, then optionally forget the profile here.
struct CleanupSheet: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var engine: Engine
    @Environment(\.dismiss) private var dismiss
    let profile: ServerProfile
    @State private var alsoDelete = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "trash.circle.fill").font(.title).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Remove Sonar from \(profile.name)").font(.title2.bold())
                    Text(profile.address).font(.callout.monospaced()).foregroundStyle(.secondary)
                }
            }
            Text("Run this on the server. It stops and deletes everything Sonar added and leaves the machine as it was.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Card {
                VStack(alignment: .leading, spacing: 6) {
                    Text("What it removes").font(.headline)
                    ForEach([
                        "The Sonar services and the local endpoint program's config",
                        "The Sonar helper and its files",
                        "The firewall rule Sonar added",
                        "The network setting Sonar changed (reverted)",
                        "The system user Sonar created",
                    ], id: \.self) { Label($0, systemImage: "minus").font(.callout) }
                    Text("The server program itself stays installed in case something else uses it. The command shows how to remove it too.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            CommandBlock(command: command, terminalCommand: profile.sshCommand,
                         caption: "1. Log in with Open Terminal, then 2. paste this and press Enter", copyOnly: true)
            Toggle("Also delete this profile from Sonar after", isOn: $alsoDelete)
            HStack {
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(alsoDelete ? "Done, delete from Sonar" : "Done") {
                    if alsoDelete { let p = profile; Task { await app.delete(p) } }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(alsoDelete ? .red : Brand.accent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
    }

    private var command: String { (try? ServerScript.fullUninstallCommand()) ?? ServerScript.uninstallCommand }
}
