import Foundation

/// In-memory log with secret redaction. Every line goes through `redact` before it is stored.
@MainActor
final class LogStore: ObservableObject {
    struct Line: Identifiable, Equatable {
        let id = UUID()
        let date: Date
        let source: String
        let text: String
    }

    @Published private(set) var lines: [Line] = []
    private var secrets: [String] = []
    private let cap = 2000

    /// Values that must never appear in logs (passwords, pin, server-side secrets).
    func setSecrets(_ s: [String]) { secrets = s.filter { $0.count >= 6 } }

    func add(_ source: String, _ text: String) {
        for raw in text.split(separator: "\n") where !raw.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.append(Line(date: Date(), source: source, text: redact(String(raw))))
        }
        if lines.count > cap { lines.removeFirst(lines.count - cap) }
    }

    func clear() { lines.removeAll() }

    func redact(_ s: String) -> String {
        var out = s
        for v in secrets { out = out.replacingOccurrences(of: v, with: "‹redacted›") }
        return out
    }

    func text(last n: Int = 400) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return lines.suffix(n).map { "\(f.string(from: $0.date)) [\($0.source)] \($0.text)" }.joined(separator: "\n")
    }
}
