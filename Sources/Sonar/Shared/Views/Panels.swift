import SwiftUI

/// Card background used across the app.
struct Panel<Content: View>: View {
    var accent: Color? = nil
    var padding: CGFloat = 18
    /// Fill the available height (equal-height cards side by side).
    var stretch = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: stretch ? .infinity : nil, alignment: .topLeading)
            .padding(padding)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill((accent ?? .primary).opacity(accent == nil ? 0.045 : 0.08)))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder((accent ?? .primary).opacity(accent == nil ? 0.08 : 0.3)))
    }
}

struct PanelTitle: View {
    let text: String
    let icon: String
    init(_ text: String, icon: String) { self.text = text; self.icon = icon }
    var body: some View {
        Label(text, systemImage: icon)
            .font(.system(size: 13, weight: .semibold))
            .labelStyle(TitleIconStyle())
    }
}

struct TitleIconStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 7) {
            configuration.icon.foregroundStyle(.secondary).font(.system(size: 12, weight: .semibold))
            configuration.title
        }
    }
}

/// Icon-only copy button.
struct CopyIconButton: View {
    let text: String
    var help: String = "Copy"
    @State private var copied = false
    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            withAnimation { copied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { withAnimation { copied = false } }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(copied ? Color.green : Color.secondary)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(copied ? "Copied" : help)
        .accessibilityLabel(help)
    }
}

/// Read-only label/value row.
struct InfoRow<Trailing: View>: View {
    let label: String
    let value: String
    var mono = true
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            Text(label).foregroundStyle(.secondary).frame(width: 82, alignment: .leading)
            Text(value)
                .font(mono ? .system(.body, design: .monospaced) : .body)
                .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 6)
            trailing
        }
        .padding(.horizontal, 14).frame(minHeight: 40)
    }
}

extension InfoRow where Trailing == EmptyView {
    init(label: String, value: String, mono: Bool = true) {
        self.init(label: label, value: value, mono: mono) { EmptyView() }
    }
}
