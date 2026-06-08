import SwiftUI
import StrandDesign

/// Support — attribution + optional crypto donations. Never a paywall; the whole app works without it.
struct SupportView: View {
    @State private var copied: String?
    @State private var selected = "BTC"

    var body: some View {
        ScreenScaffold(title: "Support",
                       subtitle: "\(ProjectInfo.appName) is free and always will be. If it's useful to you, you can chip in to help with development and testing costs. Totally optional.") {
            builtOnCard
            donateCard
            contactCard
            disclaimerCard
        }
    }

    private var contactCard: some View {
        StrandCard(padding: 20) {
            HStack(spacing: 12) {
                Image(systemName: "envelope.fill").foregroundStyle(StrandPalette.accent).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Get in touch").font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                    Text("Questions, feedback, bugs — \(ProjectInfo.contactEmail)")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                }
                Spacer(minLength: 8)
                Button {
                    if let url = URL(string: "mailto:\(ProjectInfo.contactEmail)") { PlatformOpen.url(url) }
                } label: { Label("Email", systemImage: "paperplane.fill") }
                .buttonStyle(.bordered).tint(StrandPalette.accent)
                .help("Email \(ProjectInfo.contactEmail)")
            }
        }
    }

    private var builtOnCard: some View {
        StrandCard(padding: 20) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "hands.clap.fill").foregroundStyle(StrandPalette.accent).accessibilityHidden(true)
                    Text("Built on").font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                }
                Text("This stands on community reverse-engineering. Huge thanks:")
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                ForEach(ProjectInfo.attributions, id: \.repo) { a in
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(StrandPalette.accent).accessibilityHidden(true)
                        Text(a.repo).font(StrandFont.mono(12)).foregroundStyle(StrandPalette.textPrimary)
                        Text("· \(a.note)").font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                    }
                }
            }
        }
    }

    private var donateCard: some View {
        StrandCard(padding: 20) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Image(systemName: "heart.fill").foregroundStyle(StrandPalette.metricRose).accessibilityHidden(true)
                    Text("Support the build").font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                    Spacer()
                }
                Text("NOOP is free and always will be, nothing is locked. It cost real money and a lot of unpaid hours to build, and there's a Windows app, an Android app and an iOS app I want to ship next. If it's useful to you and you want to help with the development and testing costs, even a few quid in crypto genuinely keeps it moving, and honestly it keeps me motivated to keep building.")
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "lock.shield.fill").foregroundStyle(StrandPalette.accent)
                        .font(.system(size: 13)).accessibilityHidden(true)
                    Text("I keep this project anonymous, so crypto is the only way to chip in — no Patreon, no PayPal, no name attached. Quick, global, and private for both of us.")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                // Pick a coin → scan the QR or copy the address.
                HStack(spacing: 8) {
                    ForEach(ProjectInfo.donations) { coin in
                        let on = selected == coin.symbol
                        Button { withAnimation(.easeOut(duration: 0.15)) { selected = coin.symbol } } label: {
                            Text(coin.symbol).font(.system(size: 12, weight: .bold))
                                .padding(.horizontal, 14).padding(.vertical, 7)
                                .background(Capsule().fill(on ? StrandPalette.accent : StrandPalette.surfaceInset))
                                .foregroundStyle(on ? StrandPalette.surfaceBase : StrandPalette.textSecondary)
                                .overlay(Capsule().strokeBorder(on ? Color.clear : StrandPalette.hairline, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Show \(coin.name) donation address")
                    }
                    Spacer(minLength: 0)
                }

                if let coin = ProjectInfo.donations.first(where: { $0.symbol == selected }) {
                    HStack(alignment: .top, spacing: 16) {
                        qrView(coin.address)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Scan with any \(coin.name) wallet")
                                .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                            Text(coin.address)
                                .font(StrandFont.mono(11)).foregroundStyle(StrandPalette.textSecondary)
                                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            Button {
                                PlatformPasteboard.copy(coin.address)
                                withAnimation { copied = coin.symbol }
                            } label: {
                                Label(copied == coin.symbol ? "Copied!" : "Copy address",
                                      systemImage: copied == coin.symbol ? "checkmark" : "doc.on.doc")
                            }
                            .buttonStyle(.bordered).tint(StrandPalette.accent)
                            .accessibilityLabel("Copy \(coin.name) address")
                        }
                        Spacer(minLength: 0)
                    }
                }

                Text("Any amount helps. Thank you — genuinely.")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }

    /// Black-on-white QR so wallet cameras read it cleanly against the dark UI.
    private func qrView(_ address: String) -> some View {
        Group {
            if let img = QRCode.image(for: address) {
                Image(platformImage: img).resizable().interpolation(.none)
            } else {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(StrandPalette.surfaceInset)
            }
        }
        .frame(width: 150, height: 150)
        .padding(10)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityLabel("Donation QR code")
    }

    private var disclaimerCard: some View {
        StrandCard(padding: 18) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "info.circle.fill").foregroundStyle(StrandPalette.textTertiary)
                    .font(.system(size: 13)).accessibilityHidden(true)
                Text("Not affiliated with, endorsed by, or connected to WHOOP. Interoperability software for hardware you own and your own data. Use it only with a device you own, and not in breach of any agreement that applies to you. Not a medical device.")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Hosts ``SupportView`` as a centred panel over a dimmed backdrop. Clicking anywhere
/// outside the panel — or pressing Esc, or the ✕ — closes it. Taps on the panel itself
/// are absorbed (the panel is opaque) so its controls keep working.
struct SupportModalOverlay: View {
    @Binding var isPresented: Bool

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.black.opacity(0.45))
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { isPresented = false }

            SupportView()
                .frame(width: 560, height: 680)
                .background(StrandPalette.surfaceBase,
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(StrandPalette.hairline, lineWidth: 1)
                )
                .overlay(alignment: .topTrailing) {
                    Button { isPresented = false } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(StrandPalette.textTertiary)
                            .padding(12)
                    }
                    .buttonStyle(.plain)
                    .help("Close")
                    .accessibilityLabel("Close Support")
                }
                .shadow(color: Color.black.opacity(0.5), radius: 30, x: 0, y: 14)
        }
        #if os(macOS)
        .onExitCommand { isPresented = false }
        #endif
        .transition(.opacity)
    }
}
