import SwiftUI

/// Setup wizard: from "I have a VPS" to a working tunnel with copy-paste commands. Resumable at every step.
@MainActor
final class WizardModel: ObservableObject {
    enum Step: Int, CaseIterable {
        case welcome, vps, terminal, install, firewall, test, finish
        var title: String {
            switch self {
            case .welcome: return "Welcome"
            case .vps: return "Your VPS"
            case .terminal: return "Open a terminal on your VPS"
            case .install: return "Install"
            case .firewall: return "Cloud firewall"
            case .test: return "Test it"
            case .finish: return "Done"
            }
        }
        var minutes: String {
            switch self {
            case .welcome: return "about 10 seconds"
            case .vps: return "1 minute"
            case .terminal: return "1 minute"
            case .install: return "2 to 4 minutes"
            case .firewall: return "3 minutes"
            case .test: return "about 1 minute"
            case .finish: return "1 minute"
            }
        }
    }

    @Published var step: Step = .welcome
    @Published var forward = true
    @Published var doctor: Probe.Doctor?
    @Published var doctorRunning = false
    @Published var sshReachable: CheckState = .waiting
    @Published var relayCheck: CheckState = .waiting
    @Published var relayDetail = ""
    @Published var handshake: CheckState = .waiting
    @Published var handshakeDetail = ""
    @Published var cloudFirewallBlocks = false
    @Published var paste = ""
    @Published var parsed = PasteParser.Result()
    @Published var checkPaste = ""
    @Published var checkParsed = PasteParser.Result()
    @Published var showPrecheck = false

    private var pollTask: Task<Void, Never>?
    weak var app: AppState?

    func restore(from p: WizardProgress) { step = Step(rawValue: p.step) ?? .welcome }

    func go(_ s: Step) {
        forward = s.rawValue >= step.rawValue
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { step = s }
        app?.stored.wizard.step = s.rawValue
        stopPolling()
    }

    func runDoctor() async {
        doctorRunning = true
        doctor = await Probe.doctor()
        doctorRunning = false
    }

    func stopPolling() { pollTask?.cancel(); pollTask = nil }

    /// Polls the server during install: SSH, relay reply, then a tunnel handshake.
    func startInstallWatch(profile: ServerProfile, engine: Engine) {
        stopPolling()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let ip = Probe.resolveIPv4(profile.address) ?? profile.address
                if self.sshReachable != .ok { self.sshReachable = .checking }
                let ssh = await TCPReach.check(host: ip, port: 22, timeout: 3)
                self.sshReachable = ssh ? .ok : .failed
                if self.relayCheck != .ok { self.relayCheck = .checking }
                if let p = await Probe.probe(ip, count: 6) {
                    switch p.verdict {
                    case "relay", "relay+kernel":
                        self.relayCheck = .ok
                        self.cloudFirewallBlocks = false
                        self.relayDetail = p.verdict == "relay" ? String(format: "Your server responds (%.0f ms).", p.rttMs) : "Your server responds, but is not fully set up (run the setup command again)."
                    case "kernel-only":
                        self.relayCheck = .waiting
                        self.cloudFirewallBlocks = false
                        self.relayDetail = "The server is reachable. Waiting for Sonar to answer there…"
                    case "silent":
                        self.relayCheck = ssh ? .failed : .waiting
                        self.cloudFirewallBlocks = ssh
                        self.relayDetail = ssh ? "The server is online, but Sonar can't reach it yet. Its cloud firewall is probably blocking it. The next step fixes that." : "No reply yet."
                    default:
                        self.relayCheck = .failed
                        self.relayDetail = p.error ?? "Could not reach the server from this Mac."
                    }
                }
                if self.relayCheck == .ok, self.handshake != .ok {
                    await self.tryHandshake(engine: engine)
                }
                if self.relayCheck == .ok, self.handshake == .ok { return }
                try? await Task.sleep(nanoseconds: 4_000_000_000)
            }
        }
    }

    func tryHandshake(engine: Engine) async {
        guard let app else { return }
        handshake = .checking
        handshakeDetail = "Establishing the secure session…"
        if engine.status != .connected { await app.connect() }
        switch engine.status {
        case .connected:
            handshake = .ok
            handshakeDetail = "Connected. Exit IP \(engine.exitIP ?? "?") is your server."
        case .error(let e):
            handshake = .failed
            handshakeDetail = e
        default:
            handshake = .checking
            handshakeDetail = engine.status.detail ?? "Still connecting…"
        }
    }

    func watchFirewall(profile: ServerProfile, engine: Engine) {
        stopPolling()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let ip = Probe.resolveIPv4(profile.address) ?? profile.address
                self.relayCheck = .checking
                if let p = await Probe.probe(ip, count: 6), p.relayAnswers {
                    self.relayCheck = .ok
                    self.cloudFirewallBlocks = false
                    await self.tryHandshake(engine: engine)
                    if self.handshake == .ok { return }
                } else {
                    self.relayCheck = .failed
                }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }
}

struct WizardView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var engine: Engine
    @EnvironmentObject var tester: ConnectionTester
    @StateObject private var m = WizardModel()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var address = ""
    @State private var user = "ubuntu"
    @State private var name = ""
    @State private var addressError: String?
    @State private var showNoVPS = false
    @State private var provider = FirewallGuide.all[0].id

    private var profile: ServerProfile? { app.profile(app.stored.wizard.profileID) }

    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack {
                content
                    .id(m.step)
                    .transition(reduceMotion ? .opacity : .asymmetric(
                        insertion: .move(edge: m.forward ? .trailing : .leading).combined(with: .opacity),
                        removal: .move(edge: m.forward ? .leading : .trailing).combined(with: .opacity)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .clipped()
            footer
        }
        .background(AppBackground())
        .onAppear {
            m.app = app
            m.restore(from: app.stored.wizard)
            address = app.stored.wizard.draftAddress
            user = app.stored.wizard.draftUser
            name = app.stored.wizard.draftName
            enter(m.step)
        }
        .onChange(of: m.step) { enter($0) }
        .onChange(of: m.handshake) { h in
            guard h == .ok, [.terminal, .install, .firewall].contains(m.step) else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { if m.handshake == .ok, m.step != .test { m.go(.test) } }
        }
        .onChange(of: m.cloudFirewallBlocks) { blocks in
            let installed = app.stored.wizard.installConfirmed || m.parsed.status?.ok == true
            if blocks, installed, m.step == .install { m.go(.firewall) }
        }
        .onDisappear { m.stopPolling() }
    }

    private func enter(_ s: WizardModel.Step) {
        switch s {
        case .welcome: if m.doctor == nil { Task { await m.runDoctor() } }
        case .terminal: if let p = profile { m.startInstallWatch(profile: p, engine: engine) }
        case .install: if let p = profile { m.startInstallWatch(profile: p, engine: engine) }
        case .firewall: if let p = profile { m.watchFirewall(profile: p, engine: engine) }
        case .test: if let p = profile, engine.status == .connected, tester.finished == nil, !tester.running { tester.run(engine: engine, profile: p) }
        default: break
        }
    }

    // MARK: Header and footer

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(Brand.accent)
                Text("Sonar setup").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("Step \(m.step.rawValue + 1) of \(WizardModel.Step.allCases.count) · \(m.step.minutes)")
                    .font(.caption).foregroundStyle(.secondary)
                if !app.profiles.isEmpty || m.step == .finish {
                    Button("Close") { closeWizard() }.keyboardShortcut(.cancelAction).controlSize(.small)
                }
            }
            StepIndicator(current: m.step.rawValue, total: WizardModel.Step.allCases.count)
            Text(m.step.title).font(.system(size: 28, weight: .bold, design: .rounded))
        }
        .padding(.horizontal, 32).padding(.top, 28).padding(.bottom, 12)
    }

    private var footer: some View {
        HStack {
            if m.step != .welcome {
                Button { back() } label: { Label("Back", systemImage: "chevron.left") }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
            }
            Spacer()
            if let skip = skipTarget {
                Button("Skip") { m.go(skip) }.help("This step is optional")
            }
            Button { next() } label: {
                Text(nextTitle).frame(minWidth: 110)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canContinue)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 32).padding(.vertical, 18)
        .background(.bar)
    }

    private var skipTarget: WizardModel.Step? {
        switch m.step {
        case .firewall: return .test
        case .test: return .finish
        default: return nil
        }
    }

    private var nextTitle: String {
        switch m.step {
        case .welcome: return "Start"
        case .install where !(m.relayCheck == .ok && m.handshake == .ok): return "I ran it"
        case .finish: return "Open Sonar"
        default: return "Continue"
        }
    }

    private var canContinue: Bool {
        switch m.step {
        case .welcome: return true
        case .vps: return validAddress != nil
        default: return true
        }
    }

    private var validAddress: String? {
        let a = address.trimmingCharacters(in: .whitespacesAndNewlines)
        return IPv4.isValid(a) || IPv4.isHostname(a) ? a : nil
    }

    private func back() {
        let prev: WizardModel.Step
        switch m.step {
        case .test: prev = m.cloudFirewallBlocks ? .firewall : .install
        default: prev = WizardModel.Step(rawValue: max(0, m.step.rawValue - 1)) ?? .welcome
        }
        m.go(prev)
    }

    private func next() {
        switch m.step {
        case .welcome: m.go(.vps)
        case .vps: saveProfileDraft(); m.go(.terminal)
        case .terminal: m.go(.install)
        case .install:
            app.stored.wizard.installConfirmed = true
            if m.relayCheck == .ok && m.handshake == .ok { m.go(.test) }
            else if m.cloudFirewallBlocks || m.relayCheck == .failed { m.go(.firewall) }
            else if let p = profile { m.startInstallWatch(profile: p, engine: engine) }
        case .firewall: m.go(.test)
        case .test: m.go(.finish)
        case .finish: closeWizard()
        }
    }

    private func closeWizard() {
        m.stopPolling()
        app.stored.onboardingDone = true
        if m.step == .finish { app.stored.wizard = WizardProgress() }
        app.showWizard = false
    }

    private func saveProfileDraft() {
        guard let a = validAddress else { return }
        app.stored.wizard.draftAddress = a
        app.stored.wizard.draftUser = user
        app.stored.wizard.draftName = name
        if var p = profile {
            p.address = a
            p.sshUser = user
            if !name.isEmpty { p.name = name }
            app.update(p)
            app.stored.selectedID = p.id
        } else if let p = try? app.createProfile(name: name, address: a, user: user) {
            app.stored.wizard.profileID = p.id
        }
    }

    // MARK: Steps

    @ViewBuilder private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                switch m.step {
                case .welcome: welcome
                case .vps: vps
                case .terminal: terminal
                case .install: install
                case .firewall: firewall
                case .test: testStep
                case .finish: finish
                }
            }
            .padding(.horizontal, 32).padding(.vertical, 8)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 20) {
                SonarPulse(active: m.doctorRunning || m.doctor?.icmp == true, size: 110)
                VStack(alignment: .leading, spacing: 8) {
                    Text(Brand.tagline).font(.title3)
                    Text("Sonar connects you to your own server. Websites see your server's address, and your traffic doesn't pass through anyone else.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Network check").font(.headline)
                        Spacer()
                        if !m.doctorRunning { Button("Check again") { Task { await m.runDoctor() } }.controlSize(.small) }
                    }
                    ChecklistRow(title: "This network lets Sonar connect", state: m.doctorRunning ? .checking : (m.doctor?.icmp == true ? .ok : (m.doctor == nil ? .waiting : .failed)),
                                 detail: m.doctor?.icmp == true ? String(format: "Responded via %@ in %.0f ms.", m.doctor?.icmpHost ?? "", m.doctor?.icmpRttMs ?? 0) : nil)
                    ChecklistRow(title: "Direct UDP works here (optional)", state: m.doctorRunning ? .checking : (m.doctor?.udp == true ? .ok : (m.doctor == nil ? .waiting : .skipped)),
                                 detail: m.doctor == nil ? nil : (m.doctor!.udp ? "Direct UDP works here." : "Direct UDP is blocked here, which is what Sonar is built for."))
                    if let d = m.doctor, !d.icmp {
                        ErrorCard(cause: d.udp ? "This network blocks the kind of connection Sonar needs." : "This network blocks both Sonar and direct UDP.",
                                  fix: "Sonar cannot work here. Try another network (for example mobile data), then check again.",
                                  retry: { Task { await m.runDoctor() } })
                    } else if let d = m.doctor, d.udp {
                        HStack(alignment: .top) {
                            Image(systemName: "lightbulb").foregroundStyle(.yellow)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("UDP works on this network, so Veil will be faster here. Sonar still works as a backup.")
                                    .font(.callout)
                                if let u = Brand.veilReleasesURL { Link("Get Veil", destination: u).font(.callout) }
                            }
                        }
                    }
                }
            }
            DisclosureWhy(text: "Sonar reaches your server using traffic that most restrictive networks still let through. The connection between your Mac and your server is encrypted.")
        }
    }

    private var vps: some View {
        VStack(alignment: .leading, spacing: 16) {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    Text("You need").font(.headline)
                    ForEach(["Ubuntu or Debian", "1 vCPU and 1 GB RAM are enough",
                             "A public IPv4 address", "Login as root or a user with sudo"], id: \.self) { t in
                        Label(t, systemImage: "checkmark").font(.callout)
                    }
                    Button("I don't have a VPS yet") { showNoVPS.toggle() }.buttonStyle(.link)
                    if showNoVPS {
                        Text("Rent a small Ubuntu 22.04 or 24.04 server from a provider such as Hetzner, DigitalOcean or Vultr. Pick a location outside your country and note the server's public IP. Then come back here.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Server IP address").font(.headline)
                TextField("for example 203.0.113.10", text: $address)
                    .textFieldStyle(.roundedBorder).font(.system(size: 15, design: .monospaced))
                    .accessibilityLabel("Server IP address")
                if !address.isEmpty, validAddress == nil {
                    Text("That does not look like an IPv4 address or hostname.").font(.caption).foregroundStyle(.red)
                }
            }
            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("SSH user").font(.headline)
                    Picker("", selection: $user) {
                        Text("ubuntu").tag("ubuntu")
                        Text("root").tag("root")
                        if !["ubuntu", "root"].contains(user) { Text(user).tag(user) }
                    }
                    .pickerStyle(.segmented).frame(width: 220).labelsHidden()
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Name (optional)").font(.headline)
                    TextField("My server", text: $name).textFieldStyle(.roundedBorder).frame(width: 220)
                }
            }
            DisclosureWhy(text: "Sonar creates the passwords and certificate for this server and keeps them on this Mac. Nothing needs to be copied back from the server.")
        }
    }

    private var terminal: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Open a terminal on your Mac and log in to your VPS.").font(.title3)
            if let p = profile {
                CommandBlock(command: p.sshCommand, terminalCommand: p.sshCommand, caption: "Press Open Terminal, then Enter. Type yes if it asks about the fingerprint.")
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        ChecklistRow(title: "SSH on \(p.address) is reachable", state: m.sshReachable,
                                     detail: m.sshReachable == .failed ? "Port 22 doesn't answer. Check the IP and that the server is running." : nil)
                    }
                }
                Text("If your provider gave you a key file, use: ssh -i path/to/key \(p.sshUser)@\(p.address)")
                    .font(.caption).foregroundStyle(.secondary)
                DisclosureWhy(text: "Sonar never logs in to your server and never stores your SSH key. Every command runs in your own terminal.")
            }
        }
    }

    private var install: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let p = profile, let cmd = app.installCommand(p) {
                Text("Paste this one command into the VPS terminal and press Enter.").font(.title3)
                CommandBlock(command: cmd, caption: "Setup command for \(p.name). You can run it again any time.", copyOnly: true)
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Watching your server").font(.headline)
                            Spacer()
                            if m.relayCheck == .checking || m.handshake == .checking { ProgressRing(size: 18) }
                        }
                        ChecklistRow(title: "SSH reachable", state: m.sshReachable)
                        ChecklistRow(title: "Sonar is answering on your server", state: m.relayCheck, detail: m.relayDetail)
                        ChecklistRow(title: "Secure session established", state: m.handshake, detail: m.handshakeDetail)
                        if case .error = engine.status, let busy = engine.busyPort {
                            ErrorCard(cause: "Port \(busy.port) is used by \(busy.friendly).",
                                      fix: busy.isSonar ? "Stop the other copy and retry." : "Quit that app, then try again.",
                                      retry: { Task { await app.stopBusyPortHolder() } })
                        }
                        if m.relayCheck == .ok && m.handshake == .ok {
                            Label("Your server is ready.", systemImage: "checkmark.seal.fill").foregroundStyle(.green).font(.headline)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                }
                .animation(.spring(), value: m.handshake)
                Text("Sonar checks your server and continues on its own when it's ready.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                DisclosureWhy(text: "The command installs Sonar's server part and adjusts the network settings it needs. It opens no new public port. It lists every change it makes. To undo it later, run: sudo sonar-server --uninstall")
            } else {
                ErrorCard(cause: "This profile's keys are missing.", fix: "Go back one step and continue again.")
            }
        }
    }

    private var firewall: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Your server's cloud firewall is blocking Sonar. Add this rule in your provider's control panel. It can't be changed from the server itself.").font(.title3)
                .fixedSize(horizontal: false, vertical: true)
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("", selection: $provider) {
                        ForEach(FirewallGuide.all) { Text($0.name).tag($0.id) }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    let g = FirewallGuide.all.first { $0.id == provider } ?? FirewallGuide.all[0]
                    ForEach(Array(g.steps.enumerated()), id: \.offset) { i, t in
                        HStack(alignment: .top, spacing: 10) {
                            Text("\(i + 1)").font(.system(size: 11, weight: .bold, design: .rounded)).foregroundStyle(Brand.accent)
                                .frame(width: 20, height: 20).background(Circle().fill(Brand.accent.opacity(0.15)))
                            Text(t).font(.callout).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if let note = g.note {
                        Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    ChecklistRow(title: "Sonar reaches your server", state: m.relayCheck,
                                 detail: m.relayCheck == .failed ? "Still blocked. Sonar checks every few seconds." : nil)
                    ChecklistRow(title: "Secure session", state: m.handshake, detail: m.handshakeDetail)
                }
            }
        }
    }

    private var testStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            if engine.status != .connected {
                HStack {
                    ProgressRing(size: 22)
                    Text(engine.status.detail ?? "Connecting first…").foregroundStyle(.secondary)
                    Spacer()
                    Button("Connect") { Task { await app.connect() } }
                }
            }
            TesterPanel(compact: true)
        }
    }

    private var finish: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                SonarPulse(color: .green, size: 80)
                Text("Sonar is ready. Pick how you want to use it.").font(.title3)
            }
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Use Sonar for the whole Mac (system proxy)", isOn: Binding(get: { app.stored.systemProxy }, set: { v in Task { await app.setSystemProxy(v) } }))
                    Toggle("Share to my phone on this Wi-Fi", isOn: Binding(get: { app.stored.lanSharing }, set: { v in Task { await app.setLANSharing(v) } }))
                    Toggle("Open Sonar at login", isOn: Binding(get: { LoginItem.isEnabled }, set: { try? LoginItem.set($0) }))
                    Toggle("Connect automatically when Sonar opens", isOn: $app.stored.autoConnect)
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Tips").font(.headline)
                    Label("The radar icon in the menu bar connects, disconnects and shows your exit IP.", systemImage: "menubar.rectangle")
                    Label("Apps can use SOCKS5 127.0.0.1:\(String(app.stored.tunnel.socksPort)) or HTTP 127.0.0.1:\(String(app.stored.tunnel.httpPort)).", systemImage: "network")
                    Label("When you switch networks, Sonar reconnects on its own. Phones need the new address from Share to phone.", systemImage: "wifi")
                    Label("If your server's IP changes, use Servers → Change IP. Nothing needs to change on the server.", systemImage: "arrow.triangle.2.circlepath")
                }.font(.callout)
            }
        }
    }
}

/// Cloud firewall steps per provider.
struct FirewallGuide: Identifiable {
    let id: String
    let name: String
    let steps: [String]
    var note: String? = nil

    static let all: [FirewallGuide] = [
        FirewallGuide(id: "hetzner", name: "Hetzner", steps: [
            "Open console.hetzner.cloud, pick your project, then Firewalls.",
            "Open the firewall attached to your server.",
            "Under Inbound rules, add a rule: Protocol ICMP, Source Any IPv4.",
            "Click Save changes. No restart needed.",
        ], note: "If no firewall is attached to the server, Hetzner already allows this. Run the setup command again and wait a few seconds."),
        FirewallGuide(id: "do", name: "DigitalOcean", steps: [
            "Open Networking → Firewalls and pick the firewall on your Droplet.",
            "Under Inbound Rules, choose New rule → ICMP.",
            "Set Sources to All IPv4, then save.",
        ]),
        FirewallGuide(id: "vultr", name: "Vultr", steps: [
            "Open Network → Firewall and pick the group used by your server.",
            "Add an IPv4 rule: Protocol ICMP, Source Anywhere (0.0.0.0/0).",
            "Click the + button to save.",
        ]),
        FirewallGuide(id: "aws", name: "AWS", steps: [
            "Open EC2 → Security Groups and pick your instance's group.",
            "Edit inbound rules → Add rule: Type Custom ICMP - IPv4, Protocol Echo Request, Source 0.0.0.0/0.",
            "Save rules.",
        ]),
        FirewallGuide(id: "other", name: "Other", steps: [
            "Open your provider's firewall or security group for this server.",
            "Add an inbound rule allowing ICMP type 8 (Echo Request) from anywhere (0.0.0.0/0).",
            "Save. No restart needed.",
        ]),
    ]
}
