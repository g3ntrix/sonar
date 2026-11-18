import SwiftUI

// MARK: - Dashboard
// Fits the window without scrolling; the traffic chart takes the spare height.

struct DashboardView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var engine: Engine
    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    banners
                    hero
                    if let busy = engine.busyPort { busyCard(busy) }
                    if let e = app.lastError { ErrorCard(cause: e, fix: "Fix the cause above, then connect again.") }
                    trafficPanel.frame(maxHeight: .infinity)
                    pathPanel
                    quickBar
                }
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 20)
                .frame(maxWidth: 880)
                .frame(maxWidth: .infinity)
                .frame(minHeight: geo.size.height)
            }
        }
        .onReceive(tick) { now = $0 }
    }

    // MARK: State styling

    private var tint: Color {
        switch engine.status {
        case .connected: return Brand.accent
        case .connecting, .reconnecting, .disconnecting: return .orange
        case .error: return .red
        case .disconnected: return Color.secondary
        }
    }

    private var eyebrow: String {
        switch engine.status {
        case .connected: return "PROTECTED"
        case .connecting: return "CONNECTING"
        case .reconnecting: return "RECONNECTING"
        case .disconnecting: return "DISCONNECTING"
        case .error: return "NEEDS ATTENTION"
        case .disconnected: return "OFF"
        }
    }

    private var headline: String {
        switch engine.status {
        case .connected: return "You're connected"
        case .connecting: return "Connecting…"
        case .reconnecting: return "Reconnecting…"
        case .disconnecting: return "Disconnecting…"
        case .error: return "Couldn't connect"
        case .disconnected: return "Not connected"
        }
    }

    private var subline: String {
        if let d = engine.status.detail, !d.isEmpty { return d }
        switch engine.status {
        case .connected: return "Apps using Sonar go out through your own server."
        case .disconnected:
            if let p = app.selectedProfile { return "Ready to connect through \(p.name)." }
            return "Set up a server to get started."
        default: return ""
        }
    }

    // MARK: Banners

    @ViewBuilder private var banners: some View {
        if let u = app.update {
            banner(icon: "arrow.down.circle.fill", text: "Sonar \(u.version) is available.", action: "Download") { NSWorkspace.shared.open(u.url) }
        }
        if let p = app.selectedProfile, p.needsServerUpdate {
            banner(icon: "server.rack", text: "Server update available for \(p.name).", action: "Show command") { app.selection = .servers }
        }
        if app.lanIPChanged {
            banner(icon: "wifi.exclamationmark", text: "Your Mac's network address changed. Phones need the new address.", action: "Show QR") {
                app.lanIPChanged = false
                app.selection = .share
            }
        }
    }

    // MARK: Hero

    private var hero: some View {
        HStack(alignment: .center, spacing: 24) {
            PowerOrb(tint: tint, active: engine.status.isActive, connected: engine.status == .connected,
                     disabled: app.selectedProfile == nil || engine.status == .disconnecting) {
                Task { await app.toggleConnection() }
            }

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Circle().fill(tint).frame(width: 7, height: 7)
                    Text(eyebrow).font(.system(size: 11, weight: .bold)).tracking(1.2).foregroundStyle(tint)
                }
                Text(headline)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .lineLimit(1).minimumScaleFactor(0.7)
                if !subline.isEmpty {
                    Text(subline).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                if engine.status == .connected { exitChip }
                HStack(spacing: 10) {
                    serverMenu
                    Text(engine.status.isActive ? "⌘K to disconnect" : "⌘K to connect")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 24).padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.primary.opacity(0.045))
                .overlay(
                    RadialGradient(colors: [tint.opacity(engine.status.isActive ? 0.28 : 0.10), .clear],
                                   center: UnitPoint(x: 0.14, y: 0.5), startRadius: 4, endRadius: 200)
                        .allowsHitTesting(false)
                )
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        )
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        .animation(.easeInOut(duration: 0.35), value: engine.status)
    }

    private var exitChip: some View {
        HStack(spacing: 8) {
            if let f = app.egressInfo?.flag { Text(f).font(.system(size: 15)) }
            else { Image(systemName: "globe").foregroundStyle(Brand.accent) }
            if let place = app.egressInfo?.place, !place.isEmpty {
                Text(place).font(.callout.weight(.medium)).lineLimit(1)
                Text("·").foregroundStyle(.tertiary)
            }
            Text(engine.exitIP ?? "Checking…")
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary).textSelection(.enabled).lineLimit(1)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill(Brand.accent.opacity(0.12)))
        .overlay(Capsule().strokeBorder(Brand.accent.opacity(0.25)))
        .help("Websites see this address and location")
    }

    @ViewBuilder private var serverMenu: some View {
        if let p = app.selectedProfile {
            Menu {
                ForEach(app.profiles) { prof in
                    Button { Task { await app.select(prof) } } label: {
                        if prof.id == p.id { Label(prof.name, systemImage: "checkmark") } else { Text(prof.name) }
                    }
                }
                Divider()
                Button("Manage servers…") { app.selection = .servers }
                Button("Add a server…") { app.showWizard = true }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "server.rack").font(.caption)
                    Text(p.name).font(.callout.weight(.medium))
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
            .disabled(engine.status.isActive && app.profiles.count < 2)
            .help("Choose which server to use")
        } else {
            Button { app.showWizard = true } label: { Label("Set up a server", systemImage: "plus") }
                .buttonStyle(.borderedProminent).tint(Brand.accent)
        }
    }

    // MARK: Live traffic

    private var trafficPanel: some View {
        let s = engine.stats
        let live = engine.status.isActive
        return Panel {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 22) {
                    BigRate(label: "Download", icon: "arrow.down", value: live ? Fmt.rate(s.downBps) : "—", color: Brand.accent)
                    BigRate(label: "Upload", icon: "arrow.up", value: live ? Fmt.rate(s.upBps) : "—", color: Palette.upload)
                    Spacer(minLength: 8)
                    Metric(label: "Session", value: live ? Fmt.bytes(s.downTotal + s.upTotal) : "—")
                    Metric(label: "Uptime", value: live ? Fmt.duration(since: engine.connectedSince) : "—")
                    Metric(label: "Loss", value: live ? String(format: "%.0f%%", s.lossPct) : "—")
                    if live { quality }
                }
                Group {
                    if live {
                        ThroughputChart(samples: engine.history, downColor: Brand.accent, upColor: Palette.upload)
                    } else {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.primary.opacity(0.03))
                            .overlay(
                                Label("Live speed shows here while connected", systemImage: "chart.xyaxis.line")
                                    .font(.callout).foregroundStyle(.secondary)
                            )
                    }
                }
                .frame(minHeight: 64, maxHeight: .infinity)
            }
        }
    }

    /// Link quality from packet loss.
    private var signal: (String, Color, Int) {
        if engine.stats.idleSeconds > 5 { return ("Stalled", .red, 0) }
        switch engine.stats.lossPct {
        case ..<6: return ("Excellent", .green, 4)
        case ..<12: return ("Good", .green, 3)
        case ..<20: return ("Fair", .orange, 2)
        default: return ("Weak", .red, 1)
        }
    }

    private var quality: some View {
        let (label, color, bars) = signal
        return HStack(spacing: 7) {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<4) { i in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(i < bars ? color : Color.primary.opacity(0.15))
                        .frame(width: 3, height: CGFloat(5 + i * 3))
                }
            }
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(color)
        }
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(0.12)))
        .help("Connection quality")
    }

    // MARK: Connection path

    private var pathPanel: some View {
        let layers = app.layers
        return Panel {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    PanelTitle("Connection path", icon: "point.topleft.down.curvedto.point.bottomright.up")
                    WhyButton(text: "Each stage from this Mac to the open internet. When something stops working, the first stage that isn't green is where to look. Click a stage for details.")
                    Spacer()
                    Button {
                        app.selection = .test
                        if let p = app.selectedProfile { app.tester.run(engine: engine, profile: p) }
                    } label: { Label("Run test", systemImage: "stethoscope") }
                    .controlSize(.small)
                    .disabled(app.selectedProfile == nil)
                }
                HStack(alignment: .top, spacing: 0) {
                    ForEach(Array(layers.enumerated()), id: \.element.id) { i, l in
                        PathStage(layer: l, icon: Self.icon(for: l.id),
                                  leftLit: i > 0 && Self.lit(layers[i - 1], l),
                                  rightLit: i < layers.count - 1 && Self.lit(l, layers[i + 1]),
                                  isFirst: i == 0, isLast: i == layers.count - 1)
                    }
                }
            }
        }
    }

    private static func lit(_ a: AppState.Layer, _ b: AppState.Layer) -> Bool {
        a.health == .ok && (b.health == .ok || b.health == .degraded)
    }

    private static func icon(for id: String) -> String {
        switch id {
        case "mac": return "laptopcomputer"
        case "path": return "antenna.radiowaves.left.and.right"
        case "relay": return "server.rack"
        case "hy": return "lock.shield"
        case "net": return "globe"
        default: return "circle"
        }
    }

    // MARK: Quick bar

    private var quickBar: some View {
        let port = app.stored.tunnel.socksPort
        return Panel(padding: 12) {
            HStack(spacing: 0) {
                QuickToggle(icon: "macwindow", color: .blue, title: "Whole-Mac proxy",
                            isOn: Binding(get: { app.stored.systemProxy }, set: { v in Task { await app.setSystemProxy(v) } }))
                    .help("Send every app on this Mac through Sonar")
                Divider().frame(height: 26).padding(.horizontal, 14)
                QuickToggle(icon: "iphone", color: .purple, title: "Share to phone",
                            isOn: Binding(get: { app.stored.lanSharing }, set: { v in Task { await app.setLANSharing(v) } }))
                    .help("Let a phone on this Wi-Fi use Sonar. The QR code is in Share to phone.")
                Divider().frame(height: 26).padding(.horizontal, 14)
                HStack(spacing: 8) {
                    Text("SOCKS5").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                    Text("127.0.0.1:\(String(port))").font(.system(.callout, design: .monospaced)).lineLimit(1)
                    CopyIconButton(text: "socks5://127.0.0.1:\(String(port))", help: "Copy proxy address")
                }
                .fixedSize()
            }
        }
    }

    // MARK: Alerts

    private func busyCard(_ h: PortCheck.Holder) -> some View {
        Panel(accent: .orange) {
            VStack(alignment: .leading, spacing: 10) {
                Label("Port \(String(h.port)) is already used by \(h.friendly).", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.headline)
                Text("Sonar uses the same ports as Veil and most NekoRay setups, so only one can run at a time.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Stop it and connect") { Task { await app.stopBusyPortHolder() } }
                    .buttonStyle(.borderedProminent).tint(.orange)
            }
        }
    }

    private func banner(icon: String, text: String, action: String, _ run: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(Brand.accent)
            Text(text).font(.callout)
            Spacer()
            Button(action, action: run).controlSize(.small)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Brand.accent.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Brand.accent.opacity(0.22)))
    }
}

// MARK: - Palette

private enum Palette {
    static let upload = Color(red: 0.55, green: 0.50, blue: 0.95)
}

// MARK: - Building blocks

/// Connect / disconnect button.
struct PowerOrb: View {
    let tint: Color
    let active: Bool
    let connected: Bool
    let disabled: Bool
    let action: () -> Void
    @State private var hover = false
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let size: CGFloat = 108

    var body: some View {
        VStack(spacing: 10) {
            Button(action: action) {
                ZStack {
                    // radar rings while active
                    ForEach(0..<2) { i in
                        Circle()
                            .stroke(tint.opacity(0.45), lineWidth: 1.5)
                            .scaleEffect(pulse && active && !reduceMotion ? 1.35 : 0.85)
                            .opacity(pulse && active && !reduceMotion ? 0 : (active ? 0.7 : 0))
                            .animation(active && !reduceMotion
                                       ? .easeOut(duration: 2.2).repeatForever(autoreverses: false).delay(Double(i) * 1.1)
                                       : .default, value: pulse)
                    }
                    Circle()
                        .fill(Color.primary.opacity(0.06))
                    Circle()
                        .strokeBorder(
                            AngularGradient(colors: [tint, tint.opacity(active ? 0.35 : 0.15), tint], center: .center),
                            lineWidth: active ? 4 : 2.5)
                        .padding(6)
                    Circle()
                        .fill(RadialGradient(colors: [tint.opacity(active ? 0.55 : 0.18), tint.opacity(active ? 0.18 : 0.04)],
                                             center: .center, startRadius: 2, endRadius: size * 0.36))
                        .padding(18)
                        .shadow(color: tint.opacity(active ? 0.55 : 0), radius: 18)
                    Image(systemName: "power")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(active ? Color.white : Color.primary.opacity(0.75))
                }
                .frame(width: size, height: size)
                .scaleEffect(hover && !disabled ? 1.03 : 1)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(disabled)
            .opacity(disabled ? 0.55 : 1)
            .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
            .help(active ? "Disconnect (⌘K)" : "Connect (⌘K)")
            .accessibilityLabel(active ? "Disconnect" : "Connect")

        }
        .onAppear { pulse = true }
    }
}

private struct BigRate: View {
    let label: String
    let icon: String
    let value: String
    let color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10, weight: .bold))
                    .foregroundStyle(color)
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(color.opacity(0.16)))
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct Metric: View {
    let label: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.body, design: .rounded).weight(.semibold)).monospacedDigit().lineLimit(1)
        }
        .frame(minWidth: 64, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}



/// One stage on the connection path. Click for details.
private struct PathStage: View {
    let layer: AppState.Layer
    let icon: String
    let leftLit: Bool
    let rightLit: Bool
    let isFirst: Bool
    let isLast: Bool
    @State private var show = false

    private let badge: CGFloat = 34

    var body: some View {
        Button { show.toggle() } label: {
            VStack(spacing: 6) {
                ZStack {
                    HStack(spacing: 0) {
                        Rectangle().fill(leftLit ? Brand.accent.opacity(0.7) : Color.primary.opacity(0.12))
                            .frame(height: 2).opacity(isFirst ? 0 : 1)
                        Color.clear.frame(width: badge)
                        Rectangle().fill(rightLit ? Brand.accent.opacity(0.7) : Color.primary.opacity(0.12))
                            .frame(height: 2).opacity(isLast ? 0 : 1)
                    }
                    ZStack(alignment: .bottomTrailing) {
                        Circle()
                            .fill(layer.health == .unknown ? Color.primary.opacity(0.06) : layer.health.color.opacity(0.16))
                            .overlay(Circle().strokeBorder(layer.health == .unknown ? Color.primary.opacity(0.1) : layer.health.color.opacity(0.5)))
                            .overlay(
                                Image(systemName: icon).font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(layer.health == .unknown ? Color.secondary : layer.health.color)
                            )
                            .frame(width: badge, height: badge)
                        if layer.health != .unknown {
                            Circle().fill(layer.health.color).frame(width: 10, height: 10)
                                .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
                        }
                    }
                }
                .frame(height: badge)
                VStack(spacing: 2) {
                    Text(layer.title).font(.caption.weight(.medium))
                        .lineLimit(1).minimumScaleFactor(0.8)
                    Text(layer.health == .unknown ? "Idle" : layer.health.label)
                        .font(.caption2)
                        .foregroundStyle(layer.health == .unknown ? Color.secondary : layer.health.color)
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $show, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(layer.title).font(.headline)
                    Text(layer.health.label).font(.caption).foregroundStyle(layer.health.color)
                }
                Text(layer.detail).font(.callout).foregroundStyle(.secondary)
                if let a = layer.action { Text(a).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
            }
            .padding(14).frame(width: 260).fixedSize(horizontal: false, vertical: true)
        }
        .help(layer.detail)
    }
}

private struct QuickToggle: View {
    let icon: String
    let color: Color
    let title: String
    @Binding var isOn: Bool
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(color.gradient))
            Text(title).font(.callout.weight(.medium)).lineLimit(1).fixedSize()
            Spacer(minLength: 8)
            Toggle("", isOn: $isOn).toggleStyle(.switch).labelsHidden().controlSize(.small)
        }
        .frame(maxWidth: .infinity)
    }
}
