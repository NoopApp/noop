import Foundation

enum FreshnessTone: Equatable {
    case good
    case warning
    case missing
    case neutral
}

struct DataPipelineStep: Identifiable, Equatable {
    let id: String
    let title: String
    let value: String
    let detail: String
    let symbol: String
    let tone: FreshnessTone
}

enum FreshnessSnapshot {
    @MainActor
    static func pipelineSteps(
        live: LiveState,
        repo: Repository,
        intelligence: IntelligenceEngine
    ) -> [DataPipelineStep] {
        let freshness = repo.freshness
        let analysis = intelligence.lastRun
        return [
            DataPipelineStep(
                id: "connection",
                title: "Connection",
                value: live.bonded ? "Bonded" : live.connected ? "Connected" : "Offline",
                detail: live.encryptedBond ? "Full strap channel" : live.connected ? "Live link not fully paired" : "No live strap link",
                symbol: "antenna.radiowaves.left.and.right",
                tone: live.bonded ? .good : live.connected ? .warning : .missing
            ),
            DataPipelineStep(
                id: "live",
                title: "Live stream",
                value: live.heartRate.map { "\($0) bpm" } ?? "Waiting",
                detail: live.rrRecent.isEmpty ? "HR and R-R reported separately" : "\(live.rrRecent.count) R-R intervals buffered",
                symbol: "waveform.path.ecg",
                tone: live.heartRate == nil ? .warning : .good
            ),
            DataPipelineStep(
                id: "history",
                title: "History sync",
                value: live.backfilling ? "\(live.syncChunksThisSession) chunks" : live.lastSyncedAt == nil ? "Never" : "Complete",
                detail: live.backfilling ? "\(live.decodedChunksThisSession) decoded chunks" : live.lastSyncError ?? "Latest completed offload feeds analysis",
                symbol: "clock.arrow.circlepath",
                tone: live.backfilling ? .warning : live.lastSyncedAt == nil ? .missing : .good
            ),
            DataPipelineStep(
                id: "store",
                title: "Local store",
                value: freshness.hasAnyHistory ? "\(freshness.importedDays + freshness.computedDays + freshness.appleDays) days" : "Empty",
                detail: "\(freshness.importedDays) WHOOP · \(freshness.computedDays) computed · \(freshness.appleDays) Apple",
                symbol: "externaldrive.fill",
                tone: freshness.hasAnyHistory ? .good : .missing
            ),
            DataPipelineStep(
                id: "analysis",
                title: "Analysis",
                value: intelligence.computing ? "Running" : analysis.map { "\($0.computedDays) days" } ?? "Not run",
                detail: analysis?.compactDetail ?? "Waiting for raw strap coverage",
                symbol: "brain.head.profile",
                tone: intelligence.computing ? .warning : (analysis?.computedDays ?? 0) > 0 ? .good : .missing
            ),
            DataPipelineStep(
                id: "explore",
                title: "Explore freshness",
                value: repo.loaded ? "Ready" : "Loading",
                detail: freshness.latestDay.map { "Latest local day \($0)" } ?? "No chartable days yet",
                symbol: "chart.xyaxis.line",
                tone: repo.loaded && freshness.hasAnyHistory ? .good : .warning
            )
        ]
    }
}
