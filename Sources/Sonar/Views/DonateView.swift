import SwiftUI

struct DonateView: View {
    struct Coin: Identifiable {
        let id: String
        let name: String
        let network: String
        let address: String
        let warning: String
    }

    static let coins: [Coin] = [
        Coin(id: "usdt", name: "USDT", network: "BEP20 · BNB Smart Chain",
             address: "0x71F41696c60C4693305e67eE3Baa650a4E3dA796",
             warning: "Send USDT on BNB Smart Chain (BEP20) only. Other networks will be lost."),
        Coin(id: "ton", name: "TON", network: "The Open Network",
             address: "UQCriHkMUa6h9oN059tyC23T13OsQhGGM3hUS2S4IYRBZgvx",
             warning: "Send TON on the TON network only."),
        Coin(id: "trx", name: "TRX", network: "TRON",
             address: "TFrCzU7bDey9WSh3fhqCBqhaiMzr8VhcUV",
             warning: "Send TRX on the TRON network only."),
    ]

    @State private var selected = coins[0].id

    var body: some View {
        let coin = Self.coins.first { $0.id == selected } ?? Self.coins[0]
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Donate").font(.system(size: 28, weight: .bold, design: .rounded))
                    Text("Sonar is free and has no ads or tracking. If it keeps you connected, a donation helps pay for test servers and keeps updates coming.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }

                Picker("", selection: $selected) {
                    ForEach(Self.coins) { Text($0.name).tag($0.id) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 320)

                HStack(alignment: .top, spacing: 16) {
                    Panel(stretch: true) {
                        VStack(spacing: 10) {
                            if let img = LANShare.qr(coin.address) {
                                Image(nsImage: img).interpolation(.none).resizable().scaledToFit()
                                    .frame(width: 168, height: 168)
                                    .padding(12)
                                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white))
                                    .accessibilityLabel("QR code for the \(coin.name) address")
                            }
                            Text("Scan with your wallet").font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .frame(width: 252)

                    Panel(stretch: true) {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack(spacing: 10) {
                                Text(coin.name).font(.system(size: 20, weight: .bold, design: .rounded))
                                Text(coin.network).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(Capsule().fill(Color.primary.opacity(0.07)))
                            }
                            Text(verbatim: coin.address)
                                .font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(1).minimumScaleFactor(0.6)
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
                            CopyAddressButton(address: coin.address)
                            Label(coin.warning, systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)

                Text("Thank you.").font(.callout).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 28)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}

private struct CopyAddressButton: View {
    let address: String
    @State private var copied = false
    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(address, forType: .string)
            withAnimation { copied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { withAnimation { copied = false } }
        } label: {
            Label(copied ? "Address copied" : "Copy address", systemImage: copied ? "checkmark" : "doc.on.doc")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent).tint(copied ? .green : Brand.accent)
        .controlSize(.large)
    }
}
