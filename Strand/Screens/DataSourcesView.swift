import SwiftUI
import UniformTypeIdentifiers
import StrandDesign
import StrandImport
import WhoopStore

struct DataSourcesView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var live: LiveState
    @EnvironmentObject var intelligence: IntelligenceEngine
    @State private var showingImporter = false
    @State private var importTarget: ImportTarget = .whoop
    // Nutrition CSV import state — local to this screen (the import is a quick, self-contained
    // metric-series write; it doesn't need AppModel's heavyweight import pipeline).
    @State private var nutritionImporting = false
    @State private var nutritionSummary: String?
    @State private var nutritionFailed = false

    var body: some View {
        ScreenScaffold(title: "Data Sources",
                       subtitle: "Everything stays on this Mac. Bring your history in once, then it's yours.") {
            pipelineCard
            whoopCard
            appleHealthCard
            nutritionCard
            liveCard
        }
        // A single target-aware importer avoids SwiftUI collapsing competing importers on the same screen.
        .fileImporter(isPresented: $showingImporter,
                      allowedContentTypes: importTarget.allowedContentTypes,
                      allowsMultipleSelection: false) { result in
            handleImportResult(result, for: importTarget)
        }
    }

    private var whoopCard: some View {
        card(title: "WHOOP Export", icon: "square.and.arrow.down.fill",
             subtitle: "Import your full WHOOP history — recovery, strain, sleep, workouts — from a data export (.zip). Works for WHOOP 4.0, 5.0 and MG. Get one at app.whoop.com → Data Management.") {
            let importingWhoop = model.isImporting(.whoop)
            HStack(spacing: 12) {
                Button {
                    presentImporter(.whoop)
                } label: {
                    Label(importingWhoop ? "Importing…" : "Choose export…",
                          systemImage: "tray.and.arrow.down")
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(StrandPalette.accent)
                .disabled(model.hasActiveImport || nutritionImporting)
                if importingWhoop { ProgressView().controlSize(.small) }
            }
            if let s = model.whoopImportSummary {
                Text(s).font(StrandFont.subhead)
                    .foregroundStyle(model.whoopImportFailed ? StrandPalette.statusWarning : StrandPalette.statusPositive)
            }
            Text("\(repo.days.count) days · \(repo.sleeps.count) sleeps stored")
                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
            statusRow("Imported", "\(repo.freshness.importedDays) days", "\(repo.freshness.importedSleeps) sleeps", .good)
            statusRow("Computed fill", "\(repo.freshness.computedDays) days", "\(repo.freshness.computedSleeps) sleeps", .neutral)
        }
    }

    private var appleHealthCard: some View {
        card(title: "Apple Health", icon: "heart.fill",
             subtitle: "Import an Apple Health export (Health app → profile → Export All Health Data → export.zip). 7 years of HR, HRV, sleep, SpO₂, steps and more — streamed locally. Large exports take a minute or two.") {
            let importingAppleHealth = model.isImporting(.appleHealth)
            HStack(spacing: 12) {
                Button { presentImporter(.appleHealth) } label: {
                    Label(importingAppleHealth ? "Working…" : "Choose export.zip…", systemImage: "tray.and.arrow.down")
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent).tint(StrandPalette.accent)
                .disabled(model.hasActiveImport || nutritionImporting)
                if importingAppleHealth { ProgressView().controlSize(.small) }
            }
            if let s = model.appleHealthImportSummary {
                Text(s).font(StrandFont.subhead)
                    .foregroundStyle(model.appleHealthImportFailed ? StrandPalette.statusWarning : StrandPalette.statusPositive)
            }
            statusRow("Available", "\(repo.freshness.appleDays) days", "Used only as declared-compatible fill", repo.freshness.appleDays > 0 ? .good : .missing)
        }
    }

    private var nutritionCard: some View {
        card(title: "Nutrition (.csv)", icon: "fork.knife",
             subtitle: "Import daily nutrition totals — calories in, protein, carbs, fat (and weight if present) — from a Cronometer or MacroFactor CSV export. Other trackers work too if the file has a date column and daily totals.") {
            HStack(spacing: 12) {
                Button { presentImporter(.nutrition) } label: {
                    Label(nutritionImporting ? "Importing…" : "Choose .csv…", systemImage: "tray.and.arrow.down")
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent).tint(StrandPalette.accent)
                .disabled(model.hasActiveImport || nutritionImporting)
                if nutritionImporting { ProgressView().controlSize(.small) }
            }
            if let s = nutritionSummary {
                Text(s).font(StrandFont.subhead)
                    .foregroundStyle(nutritionFailed ? StrandPalette.statusWarning : StrandPalette.statusPositive)
            }
        }
    }

    private func presentImporter(_ target: ImportTarget) {
        importTarget = target
        showingImporter = true
    }

    private func handleImportResult(_ result: Result<[URL], Error>, for target: ImportTarget) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        switch target {
        case .whoop:
            model.importWhoop(url: url)
        case .appleHealth:
            model.importAppleHealth(url: url)
        case .nutrition:
            importNutrition(url: url)
        }
    }

    /// Parse a daily-nutrition CSV and upsert it into the metric-series store under the
    /// dedicated "nutrition-csv" source, then refresh so Explore/Insights see the new keys.
    private func importNutrition(url: URL) {
        nutritionImporting = true
        nutritionSummary = nil
        nutritionFailed = false
        Task {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                let result = NutritionCsvImporter.parse(data: data)
                guard result.importedDays > 0 else {
                    nutritionSummary = "No usable rows found — check the file has a date column (yyyy-MM-dd) and daily totals."
                    nutritionFailed = true
                    nutritionImporting = false
                    return
                }
                guard let store = await repo.storeHandle() else {
                    nutritionSummary = "Couldn't open the local store."
                    nutritionFailed = true
                    nutritionImporting = false
                    return
                }
                let points = result.metricPoints.map { MetricPoint(day: $0.day, key: $0.key, value: $0.value) }
                try await store.upsertMetricSeries(points, deviceId: NutritionCsvImporter.sourceId)
                await repo.refresh()
                var msg = "Imported \(result.importedDays) days (\(points.count) values)"
                if let a = result.earliestDay, let b = result.latestDay, a != b { msg += " · \(a) – \(b)" }
                if result.skippedRows > 0 { msg += " · \(result.skippedRows) rows skipped" }
                nutritionSummary = msg
                nutritionFailed = false
            } catch {
                nutritionSummary = "Import failed: \(error.localizedDescription)"
                nutritionFailed = true
            }
            nutritionImporting = false
        }
    }

    private enum ImportTarget {
        case whoop
        case appleHealth
        case nutrition

        var allowedContentTypes: [UTType] {
            // `.folder` lets macOS users point at an *unzipped* export directory. On iOS the Files
            // picker can't meaningfully pick a folder here, and including `UTType.folder` in the type
            // list greys out the .zip itself — so the picker opens but nothing is selectable
            // (issue #179). iOS therefore offers only the concrete file types.
            switch self {
            case .whoop:
                #if os(macOS)
                return [.zip, .folder]
                #else
                return [.zip]
                #endif
            case .appleHealth:
                #if os(macOS)
                return [.zip, .xml, .folder]
                #else
                return [.zip, .xml]
                #endif
            case .nutrition:
                return [.commaSeparatedText, .plainText]
            }
        }
    }
    private var liveCard: some View {
        card(title: "WHOOP Strap (Live BLE)", icon: "antenna.radiowaves.left.and.right",
             subtitle: "Pairs directly with your strap over Bluetooth — no WHOOP app, no cloud.") {
            HStack(spacing: 8) {
                // Three-state, consistent with the Live screen's connection pill — a connected-but-
                // not-yet-streaming strap (e.g. an experimental WHOOP 5/MG link) no longer reads as
                // "Not connected" on one screen and "Connected" on another (issue #8).
                let (dot, label): (Color, String) =
                    live.bonded ? (StrandPalette.statusPositive, "Bonded — streaming.")
                    : live.connected ? (StrandPalette.statusWarning, "Connected.")
                    : (StrandPalette.statusCritical, "Not connected — open Live to pair.")
                Circle().fill(dot).frame(width: 8, height: 8)
                Text(label).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
            }
            statusRow("Heart rate", live.heartRate.map { "\($0) bpm" } ?? "Waiting", "\(live.heartRateSamplesThisSession) samples this session", live.heartRate == nil ? .warning : .good)
            statusRow("R-R intervals", live.rrRecent.isEmpty ? "No intervals" : "\(live.rrRecent.count) buffered", "\(live.rrPacketsThisSession) packets this session", live.rrRecent.isEmpty ? .warning : .good)
            statusRow("History", live.backfilling ? "\(live.syncChunksThisSession) chunks" : lastSyncLabel, live.lastSyncError ?? "Offload feeds daily analysis", live.lastSyncedAt == nil ? .missing : .good)
        }
    }

    private var pipelineCard: some View {
        card(title: "Freshness Pipeline", icon: "point.3.connected.trianglepath.dotted",
             subtitle: "Current path from strap and imports into charts.") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                ForEach(FreshnessSnapshot.pipelineSteps(live: live, repo: repo, intelligence: intelligence)) { step in
                    pipelineTile(step)
                }
            }
        }
    }

    private func pipelineTile(_ step: DataPipelineStep) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: step.symbol)
                    .foregroundStyle(color(for: step.tone))
                    .frame(width: 16)
                Text(step.title)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            Text(step.value)
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(step.detail)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 106, alignment: .topLeading)
        .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(StrandPalette.hairline, lineWidth: 1))
    }

    private func statusRow(_ label: String, _ value: String, _ detail: String, _ tone: FreshnessTone) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle().fill(color(for: tone)).frame(width: 7, height: 7)
            Text(label.uppercased())
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .frame(width: 92, alignment: .leading)
            Text(value)
                .font(StrandFont.captionNumber)
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(detail)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
            Spacer(minLength: 0)
        }
    }

    private var lastSyncLabel: String {
        guard let ts = live.lastSyncedAt else { return "Never" }
        let date = Date(timeIntervalSince1970: ts)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func color(for tone: FreshnessTone) -> Color {
        switch tone {
        case .good: return StrandPalette.statusPositive
        case .warning: return StrandPalette.statusWarning
        case .missing: return StrandPalette.statusCritical
        case .neutral: return StrandPalette.textSecondary
        }
    }

    @ViewBuilder
    private func card<C: View>(title: String, icon: String, subtitle: String,
                              @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: icon).foregroundStyle(StrandPalette.accent)
                Text(title).font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
            }
            Text(subtitle).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StrandPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(StrandPalette.hairline))
    }
}
