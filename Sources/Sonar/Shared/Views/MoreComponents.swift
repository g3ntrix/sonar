import AppKit
import SwiftUI

// MARK: - Big command block (one paste per step)

struct CommandBlock: View {
    let command: String
    var terminalCommand: String? = nil
    var caption: String = "Paste this into the terminal on your VPS"
    /// When true the command text is hidden entirely so no one hand-types part of a long one-line command.
    var copyOnly: Bool = false
    @State private var copied = false
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(caption).font(.callout).foregroundStyle(.secondary)
            if copyOnly {
                HStack(spacing: 12) {
                    Image(systemName: "doc.on.clipboard.fill").font(.title2).foregroundStyle(Brand.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("One long command (\(command.count) characters)").font(.system(size: 13, weight: .semibold))
                        Text("Use the Copy button instead of typing it. It's too long to show here.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Brand.accent.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Brand.accent.opacity(0.25)))
            } else {
                HStack(alignment: .top, spacing: 10) {
                    Text(display)
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(expanded ? nil : 3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.primary.opacity(0.08)))
                        .accessibilityLabel("Command")
                }
            }
            HStack(spacing: 10) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { copied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { withAnimation { copied = false } }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark.circle.fill" : "doc.on.doc")
                        .frame(minWidth: 110)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .accessibilityHint("Copies the command to the clipboard")
                if let t = terminalCommand {
                    Button { Terminal.open(typing: t) } label: {
                        Label("Open Terminal", systemImage: "terminal").padding(.vertical, 4)
                    }
                    .controlSize(.large)
                }
                if command.count > 200, !copyOnly {
                    Button(expanded ? "Show less" : "Show all") { withAnimation { expanded.toggle() } }
                        .buttonStyle(.link)
                }
                Spacer()
            }
        }
    }

    private var display: String {
        command.count > 200 && !expanded ? String(command.prefix(160)) + " … (\(command.count) characters)" : command
    }
}

// MARK: - Live checklist

enum CheckState: Equatable { case waiting, checking, ok, failed, skipped }

struct ChecklistRow: View {
    let title: String
    let state: CheckState
    var detail: String? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            icon.frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                if let d = detail, !d.isEmpty {
                    Text(d).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(label)")
    }

    @ViewBuilder private var icon: some View {
        switch state {
        case .waiting: Image(systemName: "circle").foregroundStyle(.tertiary)
        case .checking: ProgressView().controlSize(.small)
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).transition(.scale.combined(with: .opacity))
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .skipped: Image(systemName: "minus.circle").foregroundStyle(.secondary)
        }
    }

    private var label: String {
        switch state {
        case .waiting: return "waiting"
        case .checking: return "checking"
        case .ok: return "done"
        case .failed: return "failed"
        case .skipped: return "skipped"
        }
    }
}

// MARK: - Progress ring for long waits

struct ProgressRing: View {
    var progress: Double? = nil
    var size: CGFloat = 44
    @State private var spin = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.1), lineWidth: 4)
            Circle()
                .trim(from: 0, to: progress ?? 0.28)
                .stroke(Brand.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(progress == nil && spin ? 360 : -90))
                .animation(progress == nil && !reduceMotion ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: spin)
        }
        .frame(width: size, height: size)
        .onAppear { spin = true }
        .accessibilityLabel("Working")
    }
}

// MARK: - Ping animation

struct SonarPulse: View {
    var color: Color = Brand.accent
    var active = true
    var size: CGFloat = 120
    @State private var t = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            ForEach(0..<3) { i in
                Circle()
                    .stroke(color.opacity(0.5), lineWidth: 2)
                    .scaleEffect(t && active && !reduceMotion ? 1 : 0.2)
                    .opacity(t && active && !reduceMotion ? 0 : 0.8)
                    .animation(active && !reduceMotion ? .easeOut(duration: 2.4).repeatForever(autoreverses: false).delay(Double(i) * 0.8) : .default, value: t)
            }
            Circle().fill(color.gradient).frame(width: size * 0.22, height: size * 0.22)
                .shadow(color: color.opacity(0.6), radius: 10)
        }
        .frame(width: size, height: size)
        .onAppear { t = true }
        .accessibilityHidden(true)
    }
}

// MARK: - Paste box

struct PasteBox: View {
    let prompt: String
    @Binding var text: String
    var onChange: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(prompt).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button {
                    if let s = NSPasteboard.general.string(forType: .string) { text = s; onChange(s) }
                } label: { Label("Paste", systemImage: "doc.on.clipboard") }
                    .controlSize(.small)
                if !text.isEmpty { Button("Clear") { text = ""; onChange("") }.controlSize(.small) }
            }
            TextEditor(text: $text)
                .font(.system(size: 11, design: .monospaced))
                .frame(minHeight: 70, maxHeight: 140)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.1)))
                .onChange(of: text) { onChange($0) }
                .accessibilityLabel(prompt)
        }
    }
}

/// Shows what the app understood from a paste.
struct PasteFindings: View {
    let result: PasteParser.Result

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let a = result.address {
                Label("Found server \(a.address)\(a.user.map { ", user \($0)" } ?? "")", systemImage: "scope").foregroundStyle(.secondary)
            }
            if let s = result.status {
                Label(s.ok ? "Server status: all good" : "Server status: \(s.failedRows.count) problem(s)",
                      systemImage: s.ok ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(s.ok ? .green : .orange)
                ForEach(s.failedRows, id: \.self) { Text("• " + $0).font(.caption) }
            }
            if let e = result.scriptError {
                ErrorCard(cause: e.message, fix: e.fix ?? "Copy everything and keep it for the Logs.", command: nil)
            }
            ForEach(result.errors) { e in ErrorCard(cause: e.cause, fix: e.fix, command: e.command) }
            if !result.check.isEmpty {
                let c = result.check
                Text("Server: \(c["os"] ?? "?") \(c["os_version"] ?? "") \(c["arch"] ?? ""), user \(c["user"] ?? "?"), python3 \(c["python3"] ?? "?"), firewall \(c["firewall"] ?? "?")\(c["xui"] == "yes" ? ", x-ui present (left untouched)" : "")")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct ErrorCard: View {
    let cause: String
    let fix: String
    var command: String?
    var retry: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(cause, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.system(size: 13, weight: .semibold))
            Text(fix).font(.callout).fixedSize(horizontal: false, vertical: true)
            if let c = command { CodeBlock(label: "FIX", code: c) }
            if let retry { Button("Retry", action: retry).controlSize(.small) }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.08)))
    }
}

// MARK: - Help popover

struct WhyButton: View {
    let text: String
    @State private var show = false
    var body: some View {
        Button { show.toggle() } label: { Image(systemName: "questionmark.circle") }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .popover(isPresented: $show) {
                Text(text).font(.callout).padding(14).frame(width: 300).fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityLabel("Why")
    }
}

struct DisclosureWhy: View {
    let text: String
    @State private var open = false
    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 4)
        } label: { Text("Why?").font(.callout) }
    }
}

// MARK: - Throughput chart

/// Live speed chart: filled area for download, a line for upload.
struct ThroughputChart: View {
    let samples: [Engine.Sample]
    var downColor: Color = Brand.accent
    var upColor: Color = Color(red: 0.55, green: 0.5, blue: 0.95)

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let arr = Array(samples.suffix(60))
            let peak = max(arr.map { max($0.down, $0.up) }.max() ?? 1, 1)
            let n = max(arr.count, 2)
            let x: (Int) -> CGFloat = { i in n <= 1 ? 0 : w * CGFloat(i) / CGFloat(n - 1) }
            let y: (Double) -> CGFloat = { v in h - CGFloat(v / peak) * (h - 6) - 3 }

            ZStack {
                // horizontal guide lines
                ForEach(1..<3) { i in
                    let gy = h * CGFloat(i) / 3
                    Path { $0.move(to: CGPoint(x: 0, y: gy)); $0.addLine(to: CGPoint(x: w, y: gy)) }
                        .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                }
                if arr.count >= 2 {
                    // download area
                    downArea(arr, w: w, h: h, x: x, y: y)
                        .fill(LinearGradient(colors: [downColor.opacity(0.35), downColor.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    line(arr.map { $0.down }, x: x, y: y)
                        .stroke(downColor, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    line(arr.map { $0.up }, x: x, y: y)
                        .stroke(upColor.opacity(0.9), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                } else {
                    Text("Collecting…").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .accessibilityLabel("Live download and upload speed")
    }

    private func line(_ vals: [Double], x: (Int) -> CGFloat, y: (Double) -> CGFloat) -> Path {
        Path { p in
            for (i, v) in vals.enumerated() {
                let pt = CGPoint(x: x(i), y: y(v))
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
        }
    }

    private func downArea(_ arr: [Engine.Sample], w: CGFloat, h: CGFloat, x: (Int) -> CGFloat, y: (Double) -> CGFloat) -> Path {
        Path { p in
            p.move(to: CGPoint(x: 0, y: h))
            for (i, s) in arr.enumerated() { p.addLine(to: CGPoint(x: x(i), y: y(s.down))) }
            p.addLine(to: CGPoint(x: x(arr.count - 1), y: h))
            p.closeSubpath()
        }
    }
}

// MARK: - Formatting

enum Fmt {
    static func rate(_ bps: Double) -> String {
        if bps >= 1_000_000 { return String(format: "%.2f MB/s", bps / 1_000_000) }
        if bps >= 1000 { return String(format: "%.0f KB/s", bps / 1000) }
        return String(format: "%.0f B/s", bps)
    }

    static func bytes(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }

    static func duration(since d: Date?) -> String {
        guard let d else { return "—" }
        let s = Int(Date().timeIntervalSince(d))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

extension Health {
    var color: Color {
        switch self {
        case .ok: return .green
        case .degraded: return .orange
        case .down: return .red
        case .unknown: return .secondary
        }
    }
    var label: String {
        switch self {
        case .ok: return "OK"
        case .degraded: return "Degraded"
        case .down: return "Down"
        case .unknown: return "—"
        }
    }
}

extension ConnectionStatus {
    var color: Color {
        switch self {
        case .connected: return .green
        case .connecting, .reconnecting, .disconnecting: return .orange
        case .error: return .red
        case .disconnected: return .secondary
        }
    }
}
