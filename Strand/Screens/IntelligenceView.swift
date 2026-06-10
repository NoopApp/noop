import SwiftUI
import StrandDesign

/// Intelligence — NOOP's own recovery/strain/sleep scores, computed on-device from raw strap data
/// using the WHOOP model shape. Makes the app independent of WHOOP's cloud for live-collected days.
struct IntelligenceView: View {
    @EnvironmentObject var intelligence: IntelligenceEngine
    @EnvironmentObject var live: LiveState

    var body: some View {
        ScreenScaffold(title: "Intelligence",
                       subtitle: "NOOP scores your recovery, strain and sleep itself — on-device, no cloud.") {
            explainerCard
            if intelligence.computing {
                StrandCard(padding: 20) {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Crunching your raw streams…").font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                }
            } else if let note = intelligence.note {
                StrandCard(padding: 20) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "moon.zzz.fill").foregroundStyle(StrandPalette.accent)
                            .accessibilityHidden(true)
                        Text(note).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else if intelligence.results.isEmpty {
                // While the strap is mid-offload, say so — "no days" reads as final otherwise (#77).
                if live.backfilling { SyncingHistoryNote(chunks: live.syncChunksThisSession) }
                DataPendingNote(
                    title: "Building from your strap",
                    message: "This builds from the strap as it syncs. Strain and sleep appear after you have worn it and slept a night. Recovery needs about a week of nights to learn your baseline, or import your WHOOP export to skip the wait.",
                    symbol: "brain.head.profile"
                )
            } else {
                ForEach(intelligence.results) { day in
                    dayCard(day)
                }
            }
        }
        .task { if intelligence.results.isEmpty { await intelligence.analyzeRecent() } }
        .toolbar {
            ToolbarItem {
                Button { Task { await intelligence.analyzeRecent() } } label: {
                    Label("Recompute", systemImage: "arrow.clockwise")
                }
                .disabled(intelligence.computing)
            }
        }
    }

    private var explainerCard: some View {
        StrandCard(padding: 20) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "brain.head.profile").foregroundStyle(StrandPalette.accent)
                        .accessibilityHidden(true)
                    Text("How this works").font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                }
                Text("Recovery weighs your HRV against your personal baseline (~60%), resting heart rate (~20%), sleep performance (~15%) and respiration (~5%). Day strain is a 0–21 cardiovascular load from time in heart-rate zones. Sleep is staged from movement and heart rate. Everything is computed here from the strap's raw data — it works for any day NOOP collected raw streams.")
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func dayCard(_ d: IntelligenceEngine.Computed) -> some View {
        StrandCard(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(d.day).font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                    Spacer()
                    SourceBadge("NOOP-computed")
                }
                HStack(spacing: 0) {
                    stat("Recovery", d.recovery.map { "\(Int($0.rounded()))%" } ?? "—", recoveryColor(d.recovery))
                    stat("Strain", d.strain.map { String(format: "%.1f", $0) } ?? "—", StrandPalette.metricCyan)
                    stat("Sleep", d.sleepMin.map { "\(Int(($0 / 60).rounded()))h \(Int($0.truncatingRemainder(dividingBy: 60)))m" } ?? "—", StrandPalette.metricPurple)
                    stat("HRV", d.hrv.map { "\(Int($0.rounded()))" } ?? "—", StrandPalette.metricPurple)
                    stat("RHR", d.rhr.map { "\($0)" } ?? "—", StrandPalette.metricRose)
                }
            }
        }
    }

    private func stat(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased()).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
            Text(value).font(StrandFont.number(20)).foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func recoveryColor(_ r: Double?) -> Color {
        guard let r else { return StrandPalette.textSecondary }
        if r >= 67 { return StrandPalette.statusPositive }
        if r >= 34 { return StrandPalette.statusWarning }
        return StrandPalette.statusCritical
    }
}
