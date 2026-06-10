import SwiftUI
import StrandDesign

/// Standard scrollable screen container: title + dark surface + content column.
struct ScreenScaffold<Content: View>: View {
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(StrandFont.title1).foregroundStyle(StrandPalette.textPrimary)
                    if let subtitle {
                        Text(subtitle).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                    }
                }
                content()
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(StrandPalette.surfaceBase)
    }
}

/// Placeholder body for screens the design agents are still building.
struct ComingSoon: View {
    let what: LocalizedStringKey
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Coming together")
                .font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
            Text(what)
                .font(StrandFont.body).foregroundStyle(StrandPalette.textSecondary)
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .background(StrandPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 14))
    }
}

/// A reusable "what shows now vs what needs an import" note. Bold title line plus a
/// body line, with an info/sparkles SF Symbol. Used for empty/pending data states so
/// every screen explains the live-now path and the import path with timing.
/// Pulsing "history sync in progress" line (#77). Shown above a screen's empty state while the
/// strap's historical offload runs, so a half-loaded screen ("No nights here yet") reads as
/// in-progress rather than final. Shows the honest live signal — chunks pulled so far — never a
/// percent (total pending is unknowable from the protocol, so a determinate bar would lie).
struct SyncingHistoryNote: View {
    let chunks: Int

    var body: some View {
        HStack(spacing: 10) {
            StatePill("Syncing strap history…", tone: .accent, pulsing: true)
            if chunks > 0 {
                Text("\(chunks) chunks pulled")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
        }
    }
}

struct DataPendingNote: View {
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    var symbol: String = "sparkles"

    var body: some View {
        StrandCard(padding: 20) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol)
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(message)
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
