import SwiftUI

struct TesterView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Connection test").font(.system(size: 28, weight: .bold, design: .rounded))
                Text("Checks each step from this Mac to the internet. If the exit IP matches your server, everything works.")
                    .foregroundStyle(.secondary)
                TesterPanel(compact: false)
            }
            .padding(28)
            .frame(maxWidth: 820, alignment: .leading)
        }
    }
}

struct TesterPanel: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var engine: Engine
    @EnvironmentObject var tester: ConnectionTester
    var compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            summaryCard
            Card {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(tester.stages) { s in
                        StageRow(stage: s) { rerun() }
                        if s.id != tester.stages.last?.id { Divider().opacity(0.4).padding(.vertical, 6) }
                    }
                }
            }
        }
    }

    private var summaryCard: some View {
        Card {
            HStack(spacing: 14) {
                Circle().fill(summaryColor.gradient).frame(width: 14, height: 14)
                VStack(alignment: .leading, spacing: 2) {
                    Text(summaryTitle).font(.headline)
                    if let f = tester.finished { Text("Finished \(f.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                if !compact {
                    Toggle("Speed tests", isOn: Binding(get: { tester.includeSpeed }, set: { tester.includeSpeed = $0 }))
                        .toggleStyle(.checkbox).help("Downloads about 36 MB through the tunnel")
                }
                if tester.finished != nil {
                    Button { copyReport() } label: { Label("Copy report", systemImage: "doc.on.doc") }
                }
                if tester.running {
                    Button("Stop") { tester.cancel() }
                } else {
                    Button { rerun() } label: { Label(tester.finished == nil ? "Run test" : "Run again", systemImage: "play.fill") }
                        .buttonStyle(.borderedProminent)
                        .disabled(app.selectedProfile == nil)
                }
            }
        }
    }

    private var summaryColor: Color {
        switch tester.summary {
        case .green: return .green
        case .amber: return .orange
        case .red: return .red
        case .none: return tester.running ? Brand.accent : .secondary
        }
    }

    private var summaryTitle: String {
        if tester.running { return "Testing…" }
        switch tester.summary {
        case .green: return "Everything works"
        case .amber: return "Works, with warnings"
        case .red: return "A step failed. Check the red one below."
        case .none: return engine.status == .connected ? "Ready to test" : "Connect first for the full test"
        }
    }

    private func rerun() {
        guard let p = app.selectedProfile else { return }
        tester.run(engine: engine, profile: p)
    }

    private func copyReport() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(app.log.redact(tester.report(profile: app.selectedProfile)), forType: .string)
    }
}

struct StageRow: View {
    let stage: ConnectionTester.Stage
    var retry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            icon.frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("\(stage.id + 1). \(stage.title)").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if stage.seconds > 0 { Text(String(format: "%.1f s", stage.seconds)).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                }
                if !stage.detail.isEmpty { Text(stage.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                if let f = stage.fix, stage.state == .fail || stage.state == .warn {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(f).font(.callout).fixedSize(horizontal: false, vertical: true)
                        if let c = stage.command { CodeBlock(label: "ON THE VPS", code: c) }
                        if stage.state == .fail { Button("Retry", action: retry).controlSize(.small) }
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill((stage.state == .fail ? Color.red : Color.orange).opacity(0.08)))
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var icon: some View {
        switch stage.state {
        case .pending: Image(systemName: "circle").foregroundStyle(.tertiary)
        case .running: ProgressView().controlSize(.small)
        case .pass: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .warn: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
        case .fail: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .skipped: Image(systemName: "minus.circle").foregroundStyle(.secondary)
        }
    }
}
