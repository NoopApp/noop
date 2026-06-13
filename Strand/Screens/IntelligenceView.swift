import SwiftUI
import StrandDesign

/// Intelligence — NOOP's own recovery/strain/sleep scores, computed on-device from raw strap data
/// using the WHOOP model shape. Makes the app independent of WHOOP's cloud for live-collected days.
struct IntelligenceView: View {
    @EnvironmentObject var intelligence: IntelligenceEngine
    @EnvironmentObject var live: LiveState

    var body: some View {
        ScreenScaffold(title: "Intelligence",
                       subtitle: "NOOP scores your charge, effort and rest itself — on-device, no cloud.") {
            analysisSummaryCard
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
                    message: "This builds from the strap as it syncs. Effort and rest appear after you have worn it and slept a night. Charge needs about a week of nights to learn your baseline, or import your WHOOP export to skip the wait.",
                    symbol: "brain.head.profile"
                )
            } else {
                ForEach(intelligence.results) { day in
                    dayCard(day)
                }
            }
            if !intelligence.audits.isEmpty {
                auditList
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

    private var analysisSummaryCard: some View {
        StrandCard(padding: 20) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Label("Analysis State", systemImage: "brain.head.profile")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Spacer()
                    SourceBadge("\(intelligence.computing ? "RUNNING" : "LOCAL")", tint: intelligence.computing ? StrandPalette.statusWarning : StrandPalette.accent)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 138), spacing: 10)], spacing: 10) {
                    summaryStat("Candidates", intelligence.lastRun.map { "\($0.candidateDays)" } ?? "—")
                    summaryStat("Computed", intelligence.lastRun.map { "\($0.computedDays)" } ?? "\(intelligence.results.count)")
                    summaryStat("Partial", intelligence.lastRun.map { "\($0.partialDays)" } ?? "—")
                    summaryStat("Values", intelligence.lastRun.map { "\($0.metricPoints)" } ?? "—")
                }
                if let run = intelligence.lastRun {
                    Text(run.compactDetail)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                } else {
                    Text(live.backfilling ? "History is syncing before analysis." : "Run analysis after live history or import lands.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
        }
    }

    private func dayCard(_ d: IntelligenceEngine.Computed) -> some View {
        let audit = auditByDay[d.day]
        return StrandCard(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(d.day).font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                    Spacer()
                    SourceBadge("\(audit?.status.rawValue ?? "NOOP-computed")", tint: statusColor(audit?.status))
                }
                HStack(spacing: 0) {
                    stat("Charge", d.recovery.map { "\(Int($0.rounded()))%" } ?? "—", recoveryColor(d.recovery))
                    stat("Effort", d.strain.map { String(format: "%.1f", $0) } ?? "—", StrandPalette.metricCyan)
                    stat("Rest", d.sleepMin.map { "\(Int($0 / 60))h \(Int($0.truncatingRemainder(dividingBy: 60)))m" } ?? "—", StrandPalette.metricPurple)
                    stat("HRV", d.hrv.map { "\(Int($0.rounded()))" } ?? "—", StrandPalette.metricPurple)
                    stat("RHR", d.rhr.map { "\($0)" } ?? "—", StrandPalette.metricRose)
                }
                if let audit {
                    HStack(spacing: 10) {
                        Text(audit.detail)
                        Spacer(minLength: 0)
                        Text("\(audit.hrSamples) HR · \(audit.rrIntervals) R-R")
                    }
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
                }
            }
        }
    }

    private var auditList: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Analysis Audit", overline: "Recent candidate days")
            ForEach(intelligence.audits.prefix(10)) { audit in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    SourceBadge("\(audit.status.rawValue)", tint: statusColor(audit.status))
                    Text(audit.day)
                        .font(StrandFont.captionNumber)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .frame(width: 92, alignment: .leading)
                    Text(audit.detail)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Spacer(minLength: 0)
                    Text("\(audit.metricPoints) values")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                .padding(12)
                .background(StrandPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(StrandPalette.hairline, lineWidth: 1))
            }
        }
    }

    private var auditByDay: [String: IntelligenceEngine.AnalysisDayAudit] {
        Dictionary(uniqueKeysWithValues: intelligence.audits.map { ($0.day, $0) })
    }

    private func summaryStat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
            Text(value)
                .font(StrandFont.number(22))
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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

    private func statusColor(_ status: IntelligenceEngine.AnalysisDayStatus?) -> Color {
        switch status {
        case .computed: return StrandPalette.statusPositive
        case .partial: return StrandPalette.statusWarning
        case .skipped: return StrandPalette.statusCritical
        case nil: return StrandPalette.accent
        }
    }
}
