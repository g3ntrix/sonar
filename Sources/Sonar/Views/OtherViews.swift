import SwiftUI

struct ShareView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var engine: Engine
    @State private var reveal = false
    @State private var lanPassword: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Share to phone").font(.system(size: 28, weight: .bold, design: .rounded))
                    Text("Use this Mac's connection on your phone over Wi-Fi. Both need to be on the same network.")
                        .foregroundStyle(.secondary)
                }
                switchPanel
                if app.stored.lanSharing { details } else { howItWorks }
            }
            .padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 28)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            app.lanIP = LANShare.currentIP(); app.lanIPChanged = false
            if let p = app.selectedProfile { lanPassword = app.secrets(for: p)?.lanPassword }
        }
        .onChange(of: app.stored.selectedID) { _ in
            if let p = app.selectedProfile { lanPassword = app.secrets(for: p)?.lanPassword }
        }
    }

    private var sharing: Binding<Bool> {
        Binding(get: { app.stored.lanSharing }, set: { v in Task { await app.setLANSharing(v) } })
    }

    private var switchPanel: some View {
        Panel {
            HStack(spacing: 14) {
                Image(systemName: "iphone.radiowaves.left.and.right")
                    .font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.purple.gradient))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Share on this Wi-Fi").font(.headline)
                    Text(app.stored.lanSharing
                         ? (app.lanIP.map { "On · \($0)" } ?? "On")
                         : "Off · Password protected when on")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: sharing).toggleStyle(.switch).labelsHidden()
            }
        }
    }

    @ViewBuilder private var details: some View {
        if let ip = app.lanIP, let pw = lanPassword {
            let port = app.stored.tunnel.lanPort, user = app.stored.tunnel.lanUser
            let link = LANShare.link(ip: ip, port: port, user: user, password: pw)

            if engine.status != .connected {
                notice("Connect Sonar on this Mac first. The phone uses this Mac's connection.", icon: "bolt.horizontal.circle", color: .orange)
            }

            HStack(alignment: .top, spacing: 16) {
                qrPanel(link).frame(width: 252)
                detailsPanel(ip: ip, port: port, user: user, password: pw, link: link)
            }
            .fixedSize(horizontal: false, vertical: true)

            if LANShare.looksPublic(ip) {
                notice("This looks like a public network. The password keeps others out, but a private Wi-Fi is safer.", icon: "exclamationmark.shield", color: .orange)
            }
            notice("If this Mac joins another network, its address changes. Sonar lets you know, and you scan the new code.", icon: "wifi", color: .secondary)
        } else if app.lanIP == nil {
            ErrorCard(cause: "This Mac isn't on Wi-Fi or Ethernet right now.", fix: "Join a network, then come back.")
        } else {
            ErrorCard(cause: "Sonar couldn't read this server's saved keys.", fix: "Click Allow if macOS asks, then open this page again.")
        }
    }

    private func qrPanel(_ link: String) -> some View {
        Panel(stretch: true) {
            VStack(spacing: 14) {
                if let img = LANShare.qr(link) {
                    Image(nsImage: img).interpolation(.none).resizable().scaledToFit()
                        .frame(width: 168, height: 168)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white))
                        .accessibilityLabel("QR code with the phone settings")
                }
                VStack(spacing: 3) {
                    Text("Scan with your phone").font(.headline)
                    Text("Open V2Box or NekoRay and scan this code.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                CopyLinkButton(link: link)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func detailsPanel(ip: String, port: Int, user: String, password: String, link: String) -> some View {
        Panel(stretch: true) {
            VStack(alignment: .leading, spacing: 12) {
                PanelTitle("Or enter it by hand", icon: "keyboard")
                VStack(spacing: 0) {
                    InfoRow(label: "Address", value: ip) { CopyIconButton(text: ip, help: "Copy address") }
                    Divider().opacity(0.4)
                    InfoRow(label: "Port", value: String(port)) { CopyIconButton(text: String(port), help: "Copy port") }
                    Divider().opacity(0.4)
                    InfoRow(label: "Type", value: "SOCKS5")
                    Divider().opacity(0.4)
                    InfoRow(label: "Username", value: user) { CopyIconButton(text: user, help: "Copy username") }
                    Divider().opacity(0.4)
                    InfoRow(label: "Password", value: reveal ? password : String(repeating: "•", count: 12)) {
                        Button { reveal.toggle() } label: {
                            Image(systemName: reveal ? "eye.slash" : "eye").font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary).frame(width: 26, height: 26).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).help(reveal ? "Hide password" : "Show password")
                        CopyIconButton(text: password, help: "Copy password")
                    }
                }
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
            }
        }
    }

    private var howItWorks: some View {
        Panel {
            VStack(alignment: .leading, spacing: 14) {
                PanelTitle("How it works", icon: "lightbulb")
                step(1, "Turn on sharing above.")
                step(2, "Install V2Box (iPhone) or NekoRay (Android) on your phone.")
                step(3, "Scan the QR code that appears here. Done.")
            }
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(spacing: 12) {
            Text("\(n)").font(.system(size: 12, weight: .bold, design: .rounded)).foregroundStyle(Brand.accent)
                .frame(width: 24, height: 24).background(Circle().fill(Brand.accent.opacity(0.15)))
            Text(text).font(.callout)
        }
    }

    private func notice(_ text: String, icon: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(color == .secondary ? Color.secondary : color)
            Text(text).font(.callout).foregroundStyle(color == .secondary ? Color.secondary : Color.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(color == .secondary ? Color.primary.opacity(0.03) : color.opacity(0.10)))
    }
}

private struct CopyLinkButton: View {
    let link: String
    @State private var copied = false
    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(link, forType: .string)
            withAnimation { copied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { withAnimation { copied = false } }
        } label: {
            Label(copied ? "Link copied" : "Copy link", systemImage: copied ? "checkmark" : "link")
                .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .help("Copy a link you can import on the phone")
    }
}

struct LogsView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var log: LogStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Logs").font(.system(size: 28, weight: .bold, design: .rounded))
                Spacer()
                Button { copy(app.diagnostics()) } label: { Label("Copy diagnostics", systemImage: "stethoscope") }
                Button("Clear") { log.clear() }
            }
            Text("Passwords and keys are removed from everything shown and copied here.").font(.caption).foregroundStyle(.secondary)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(log.lines) { l in
                            Text("\(l.date.formatted(date: .omitted, time: .standard))  [\(l.source)] \(l.text)")
                                .font(.system(size: 11, design: .monospaced)).textSelection(.enabled).id(l.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                }
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
                .onChange(of: log.lines.count) { _ in if let last = log.lines.last { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
        }
        .padding(28)
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

struct SettingsView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var engine: Engine
    @State private var helperInstalled = ProxyHelper.looksInstalled
    @State private var loginOn = false
    @State private var checkingUpdate = false

    var body: some View {
        Form {
            Section("Connection") {
                Toggle("Use Sonar for the whole Mac (system SOCKS and HTTP proxy)", isOn: Binding(get: { app.stored.systemProxy }, set: { v in Task { await app.setSystemProxy(v) } }))
                Toggle("Connect automatically when Sonar opens", isOn: $app.stored.autoConnect)
                Toggle("Open Sonar at login", isOn: Binding(get: { loginOn }, set: { v in loginOn = ((try? LoginItem.set(v)) != nil) ? v : LoginItem.isEnabled }))
                                HStack {
                    Text(helperInstalled ? "Proxy helper installed. Turning the system proxy on or off won't ask for your password." : "The first time you turn on the system proxy, macOS asks for your password once to install a small helper.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if helperInstalled { Button("Remove helper") { try? ProxyHelper.uninstall(); helperInstalled = ProxyHelper.looksInstalled }.controlSize(.small) }
                }
            }
            Section("Updates") {
                LabeledContent("Version", value: Versions.app)
                HStack {
                    if let u = app.update {
                        Link("Sonar \(u.version) is available", destination: u.url)
                    } else if !app.updateCheckOK {
                        Label("Couldn't check for updates. Try again later.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    } else if let d = app.lastUpdateCheck {
                        Text("Up to date · checked \(d.formatted(date: .omitted, time: .shortened))").foregroundStyle(.secondary)
                    } else {
                        Text("Not checked yet").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(checkingUpdate ? "Checking…" : "Check now") {
                        checkingUpdate = true
                        Task { await app.checkForUpdates(); checkingUpdate = false }
                    }.disabled(checkingUpdate)
                }
                Link("Releases page", destination: Brand.releasesURL)
            }
        }
        .formStyle(.grouped)
        .padding(12)
        .task {
            loginOn = LoginItem.isEnabled
            helperInstalled = await ProxyHelper.checkInstalled()
        }
    }
}

struct MenuBarView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var engine: Engine
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                StatusDot(color: engine.status.color, animated: engine.status.isActive)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Sonar · \(engine.status.title)").font(.headline)
                    if let ip = engine.exitIP, engine.status == .connected { Text("Exit IP \(ip)").font(.caption.monospaced()).foregroundStyle(.secondary) }
                    else if let d = engine.status.detail { Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                }
                Spacer()
            }
            Button {
                Task { await app.toggleConnection() }
            } label: { Text(engine.status.isActive ? "Disconnect" : "Connect").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(app.selectedProfile == nil)
            if engine.status == .connected {
                HStack {
                    Label(Fmt.rate(engine.stats.downBps), systemImage: "arrow.down")
                    Spacer()
                    Label(Fmt.rate(engine.stats.upBps), systemImage: "arrow.up")
                }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Divider()
            if app.profiles.count > 1 {
                Picker("Server", selection: Binding(get: { app.selectedProfile?.id ?? UUID() }, set: { id in if let p = app.profile(id) { Task { await app.select(p) } } })) {
                    ForEach(app.profiles) { Text($0.name).tag($0.id) }
                }
            }
            Toggle("System proxy", isOn: Binding(get: { app.stored.systemProxy }, set: { v in Task { await app.setSystemProxy(v) } }))
            Toggle("Share to phone", isOn: Binding(get: { app.stored.lanSharing }, set: { v in Task { await app.setLANSharing(v) } }))
            Divider()
            Button("Copy proxy address (socks5://127.0.0.1:\(String(app.stored.tunnel.socksPort)))") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("socks5://127.0.0.1:\(app.stored.tunnel.socksPort)", forType: .string)
            }.buttonStyle(.plain)
            Button("Run connection test") { show(.test); if let p = app.selectedProfile { app.tester.run(engine: engine, profile: p) } }.buttonStyle(.plain)
            Button("Open Sonar") { show(.dashboard) }.buttonStyle(.plain)
            Divider()
            Button("Quit Sonar") { NSApp.terminate(nil) }.buttonStyle(.plain).keyboardShortcut("q")
        }
        .padding(14)
        .frame(width: 300)
    }

    private func show(_ item: SidebarItem) {
        app.selection = item
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}
