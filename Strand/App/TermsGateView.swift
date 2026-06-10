import SwiftUI
import StrandDesign

/// First-run acknowledgment gate (clickwrap). Shown over EVERYTHING — before onboarding, pairing, or
/// any Bluetooth access — until the current `Terms.currentVersion` is accepted, and again if the
/// terms materially change. The user must tick the (un-pre-checked) box and tap Accept; the accepted
/// version is then stored locally, the on-device equivalent of a consent record. See `Terms` / `TERMS.md`.
struct TermsGateView: View {
    let onAccept: () -> Void
    @State private var checked = false

    var body: some View {
        ZStack {
            StrandPalette.surfaceBase.ignoresSafeArea()

            VStack(spacing: 0) {
                VStack(spacing: 6) {
                    Text("Before you use NOOP")
                        .font(StrandFont.title1)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("Please read and accept the points below.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                .padding(.top, 36)
                .padding(.bottom, 22)

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(Terms.points, id: \.0) { point in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(point.0)
                                    .font(StrandFont.headline)
                                    .foregroundStyle(StrandPalette.textPrimary)
                                Text(point.1)
                                    .font(StrandFont.footnote)
                                    .foregroundStyle(StrandPalette.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Text("The full terms are in TERMS.md, shipped with NOOP. This is not legal advice.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .padding(.top, 2)
                    }
                    .padding(.horizontal, 30)
                    .padding(.bottom, 18)
                }

                Rectangle()
                    .fill(StrandPalette.hairline)
                    .frame(height: 1)

                VStack(spacing: 16) {
                    Toggle(isOn: $checked) {
                        Text("I have read and accept these terms, and I'm using NOOP with my own device and my own data, at my own risk.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .toggleStyle(.checkbox)

                    Button(action: onAccept) {
                        Text("Accept & Continue")
                            .font(StrandFont.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(StrandPalette.accent)
                    .disabled(!checked)
                    .keyboardShortcut(.defaultAction)
                }
                .padding(26)
            }
            .frame(maxWidth: 560, maxHeight: 640)
        }
    }
}
