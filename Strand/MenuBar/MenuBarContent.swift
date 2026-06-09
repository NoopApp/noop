import SwiftUI
import Foundation
import StrandDesign
import WhoopStore

// MARK: - Menu-Bar Extra (NOOP)
//
// A glanceable presence in the macOS menu bar. The label shows a tiny heart-dot
// tinted by the current HR zone plus the live HR (or "—" when not streaming).
// The popover gives a compact recovery ring, the live HR, the strap battery, and
// a small action area to start/stop the live feed or reconnect.
//
// The MenuBarExtra Scene itself is wired in StrandApp centrally; this file only
// supplies the two content views.

// MARK: - Label

/// The compact menu-bar item: a zone-tinted dot + the live HR number.
public struct MenuBarLabel: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var live: LiveState

    public init() {}

    /// HR to display: reported value when >0, else derived from the latest R-R.
    private var displayHR: Int? {
        if let hr = live.heartRate, hr > 0 { return hr }
        if let last = live.rr.last, last > 0 { return Int((60_000.0 / Double(last)).rounded()) }
        return nil
    }

    // A glanceable HR-zone estimate using a typical adult max (~190 bpm). The full
    // profile-aware zoning lives on the main screens; the menu bar only needs a tint.
    private let assumedHrMax: Double = 190

    /// HR zone 1...5 from %max, or nil when there's no live reading.
    private var zone: Int? {
        guard let hr = displayHR else { return nil }
        let pct = Double(hr) / assumedHrMax
        switch pct {
        case ..<0.60: return 1
        case ..<0.70: return 2
        case ..<0.80: return 3
        case ..<0.90: return 4
        default:      return 5
        }
    }

    private var dotColor: Color {
        guard live.connected else { return StrandPalette.textTertiary }
        if let zone { return StrandPalette.hrZoneColor(zone) }
        return StrandPalette.statusPositive
    }

    public var body: some View {
        HStack(spacing: 4) {
            Image(systemName: live.connected ? "heart.fill" : "heart")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(dotColor)
            Text(displayHR.map(String.init) ?? "—")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(displayHR.map { "Heart rate \($0) beats per minute" } ?? "Strap not connected")
    }
}

// MARK: - Popover content

/// The popover shown when the menu-bar item is clicked.
public struct MenuBarContent: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var live: LiveState
    @EnvironmentObject private var model: AppModel

    public init() {}

    // MARK: Derived values

    private var displayHR: Int? {
        if let hr = live.heartRate, hr > 0 { return hr }
        if let last = live.rr.last, last > 0 { return Int((60_000.0 / Double(last)).rounded()) }
        return nil
    }

    private var recovery: Double? { repo.today?.recovery }

    private var connectionTone: StrandTone {
        live.bonded ? .positive : live.connected ? .accent : .critical
    }

    private var connectionTitle: String {
        live.bonded ? "STREAMING" : live.connected ? "CONNECTED" : "OFFLINE"
    }

    private var batteryTone: StrandTone {
        guard let pct = live.batteryPct else { return .neutral }
        switch pct {
        case ..<15: return .critical
        case ..<35: return .warning
        default:    return .positive
        }
    }

    /// Public-palette color for a tone (StrandTone.color is module-internal).
    private func toneColor(_ tone: StrandTone) -> Color {
        switch tone {
        case .neutral:  return StrandPalette.textSecondary
        case .accent:   return StrandPalette.accent
        case .positive: return StrandPalette.statusPositive
        case .warning:  return StrandPalette.statusWarning
        case .critical: return StrandPalette.statusCritical
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            recoveryBlock
            Divider().overlay(StrandPalette.hairline)
            statsRow
            Divider().overlay(StrandPalette.hairline)
            actions
        }
        .padding(16)
        .frame(width: 268)
        .background(StrandPalette.surfaceOverlay)
        .preferredColorScheme(.dark)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("NOOP")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("ALL YOUR DATA · NONE OF THE CLOUD")
                    .font(StrandFont.overline)
                    .tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            Spacer(minLength: 8)
            StatePill("\(connectionTitle)", tone: connectionTone, pulsing: live.bonded)
        }
    }

    // MARK: Recovery + HR

    private var recoveryBlock: some View {
        HStack(spacing: 16) {
            if let recovery {
                RecoveryRing(score: recovery, diameter: 96, lineWidth: 9, showsLabel: true)
            } else {
                emptyRing
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 2) {
                Text("HEART RATE")
                    .font(StrandFont.overline)
                    .tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textTertiary)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(displayHR.map(String.init) ?? "—")
                        .font(StrandFont.number(40))
                        .foregroundStyle(displayHR == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                        .contentTransition(.numericText())
                        .animation(StrandMotion.gentle, value: displayHR)
                    Text("bpm")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
    }

    private var emptyRing: some View {
        ZStack {
            Circle()
                .stroke(StrandPalette.hairline.opacity(0.55), style: StrokeStyle(lineWidth: 9, lineCap: .round))
                .frame(width: 96, height: 96)
            VStack(spacing: 2) {
                Text("—")
                    .font(StrandFont.number(28))
                    .foregroundStyle(StrandPalette.textTertiary)
                Text("NO DATA")
                    .font(StrandFont.overline)
                    .tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .frame(width: 96, height: 96)
    }

    // MARK: Stats row

    private var statsRow: some View {
        HStack(spacing: 0) {
            statCell(
                "BATTERY",
                live.batteryPct.map { "\(Int($0.rounded()))%" } ?? "—",
                tint: live.batteryPct == nil ? StrandPalette.textPrimary : toneColor(batteryTone)
            )
            cellDivider
            statCell(
                "RESTING HR",
                repo.today?.restingHr.map { "\($0)" } ?? "—",
                tint: StrandPalette.textPrimary
            )
            cellDivider
            statCell(
                "HRV",
                repo.today?.avgHrv.map { "\(Int($0.rounded()))" } ?? "—",
                tint: StrandPalette.textPrimary
            )
        }
    }

    private func statCell(_ label: String, _ value: String, tint: Color) -> some View {
        VStack(spacing: 3) {
            Text(label)
                .font(StrandFont.overline)
                .tracking(StrandFont.overlineTracking)
                .foregroundStyle(StrandPalette.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(value)
                .font(StrandFont.number(17, weight: .medium))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity)
    }

    private var cellDivider: some View {
        Rectangle()
            .fill(StrandPalette.hairline)
            .frame(width: 1, height: 26)
    }

    // MARK: Actions

    private var actions: some View {
        VStack(spacing: 8) {
            if live.bonded {
                menuButton(
                    live.heartRate != nil ? "Stop live feed" : "Start live feed",
                    systemImage: live.heartRate != nil ? "pause.fill" : "play.fill",
                    tone: .accent
                ) {
                    if live.heartRate != nil { model.stopRealtimeHR() } else { model.startRealtimeHR() }
                }
            } else {
                menuButton(
                    live.connected ? "Re-scan strap" : "Scan & connect",
                    systemImage: "antenna.radiowaves.left.and.right",
                    tone: .accent
                ) {
                    model.scan()
                }
            }

            HStack(spacing: 8) {
                menuButton("Refresh battery", systemImage: "battery.100", tone: .neutral, compact: true) {
                    model.getBattery()
                }
                if live.connected {
                    menuButton("Disconnect", systemImage: "xmark.circle", tone: .critical, compact: true) {
                        model.disconnect()
                    }
                }
            }
        }
    }

    private func menuButton(
        _ title: String,
        systemImage: String,
        tone: StrandTone,
        compact: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .font(StrandFont.subhead)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(toneColor(tone))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(toneColor(tone).opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(toneColor(tone).opacity(0.26), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

#if DEBUG
private extension DailyMetric {
    static func sample(recovery: Double, restingHr: Int, hrv: Double) -> DailyMetric {
        DailyMetric(
            day: "2026-06-06",
            totalSleepMin: 452, efficiency: 92, deepMin: 96, remMin: 110, lightMin: 240,
            disturbances: 7, restingHr: restingHr, avgHrv: hrv, recovery: recovery,
            strain: 12.4, exerciseCount: 1, spo2Pct: 97, skinTempDevC: 0.2, respRateBpm: 14.6
        )
    }
}

@MainActor
private func previewEnv(
    connected: Bool,
    bonded: Bool,
    hr: Int?,
    battery: Double?,
    metric: DailyMetric?
) -> (Repository, LiveState, AppModel) {
    let repo = Repository(deviceId: "preview")
    if let metric { repo.days = [metric] }
    repo.loaded = true
    let model = AppModel()
    let live = model.live
    live.connected = connected
    live.bonded = bonded
    live.heartRate = hr
    live.batteryPct = battery
    return (repo, live, model)
}

#Preview("Label — zones") {
    let (repo, live, model) = previewEnv(
        connected: true, bonded: true, hr: 148, battery: 78,
        metric: .sample(recovery: 71, restingHr: 51, hrv: 62)
    )
    return HStack(spacing: 20) {
        MenuBarLabel()
        MenuBarLabel()
    }
    .padding(24)
    .background(StrandPalette.surfaceBase)
    .environmentObject(repo)
    .environmentObject(live)
    .environmentObject(model)
    .preferredColorScheme(.dark)
}

#Preview("Popover — streaming") {
    let (repo, live, model) = previewEnv(
        connected: true, bonded: true, hr: 132, battery: 78,
        metric: .sample(recovery: 71, restingHr: 51, hrv: 62)
    )
    return MenuBarContent()
        .environmentObject(repo)
        .environmentObject(live)
        .environmentObject(model)
}

#Preview("Popover — offline / no data") {
    let (repo, live, model) = previewEnv(
        connected: false, bonded: false, hr: nil, battery: nil, metric: nil
    )
    return MenuBarContent()
        .environmentObject(repo)
        .environmentObject(live)
        .environmentObject(model)
}
#endif
