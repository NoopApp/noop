import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

/// Live workout mode (#238) — the in-exercise screen: a big live heart rate, the current HR zone,
/// elapsed time, and live effort building, all from the SAME live feed and scorers the rest of the
/// app uses (no invented numbers). Presented while a manual workout is active, entered from the
/// Start-workout control on Live. End stops the workout and dismisses.
///
/// Live HR is the smoothed `AppModel.bpm`; the zone is derived from the user's HR-max via the shared
/// `HRZones` model; elapsed time ticks from the workout's start (a TimelineView, no manual Timer);
/// effort is the running `ActiveWorkout.liveStrain` (StrainScorer over the captured window).
struct LiveWorkoutView: View {
    @EnvironmentObject private var model: AppModel
    let onClose: () -> Void

    /// Effort display scale (#268) — routes the live Effort read-out through the shared helper so it
    /// matches every other surface. Display-only; the captured value stays stored 0–100.
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue
    private var effortScale: EffortScale { UnitPrefs.resolveEffortScale(effortScaleRaw) }

    private var zoneSet: HRZoneSet { HRZones.zones(maxHR: Double(model.profile.hrMax)) }
    private var zone: Int { model.bpm.map { zoneSet.zoneNumber(forBPM: Double($0)) } ?? 0 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                heroHeartRate
                effortGauge
                zoneRail
                statsGrid
                Spacer(minLength: 12)
                endButton
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // A scenic Effort-tinted backdrop behind the whole in-exercise screen, fading to the base — the
        // live workout reads as an Effort-world hero, not a flat panel.
        .background {
            ScenicHeroBackground(domain: .effort)
                .ignoresSafeArea()
        }
        // If the workout ended elsewhere (process restart cleared it), close the screen.
        .onChangeCompat(of: model.activeWorkout == nil) { _, gone in if gone { onClose() } }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("RECORDING WORKOUT")
                    .font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.metricRose)
                Text("Workout")
                    .font(StrandFont.title1).foregroundStyle(StrandPalette.textPrimary)
            }
            Spacer()
            if let start = model.activeWorkout?.start {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(Self.elapsed(since: start))
                        .font(StrandFont.number(34)).monospacedDigit()
                        .foregroundStyle(StrandPalette.textPrimary)
                }
            }
        }
    }

    private var heroHeartRate: some View {
        let tint = zone >= 1 ? StrandPalette.hrZoneColor(zone) : StrandPalette.effortColor
        return NoopCard(padding: 24, tint: StrandPalette.effortColor) {
            VStack(spacing: 6) {
                Text("HEART RATE")
                    .font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textSecondary)
                Text(model.bpm.map { "\($0)" } ?? "—")
                    .font(StrandFont.rounded(80, weight: .semibold))
                    .foregroundStyle(tint)
                    // A soft zone-tinted halo behind the numeral — the Bevel glow.
                    .background(
                        Circle().fill(tint.opacity(model.bpm == nil ? 0 : 0.16)).blur(radius: 30)
                    )
                    .contentTransition(.numericText())
                    .animation(.snappy, value: model.bpm)
                Text("bpm").font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                Text(zone >= 1 ? "Zone \(zone) · \(Self.zoneName(zone))" : "Below Zone 1")
                    .font(StrandFont.captionNumber)
                    .foregroundStyle(tint)
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// The accumulating Effort, on the same layered StrainGauge the rest of the app uses — the live
    /// `liveStrain` is on NOOP's 0–100 Effort axis. The gauge renders on the user's selected Effort
    /// scale (#313): 0–100 native, or rescaled to WHOOP's 0–21, matching the rest of the app's
    /// read-outs (mirrors TodayView's effort hero). Display-only — the captured value stays 0–100.
    private var effortGauge: some View {
        let strain = model.activeWorkout?.liveStrain ?? 0
        return NoopCard(padding: 18, tint: StrandPalette.effortColor) {
            VStack(spacing: 10) {
                Text("EFFORT BUILDING")
                    .font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.effortColor)
                StrainGauge(
                    strain: UnitFormatter.effortValue(strain, scale: effortScale),
                    outOf: effortScale == .whoop ? 21 : 100,
                    diameter: 150, lineWidth: 14, showsHover: false,
                    valueFormat: { _ in UnitFormatter.effortDisplay(strain, scale: effortScale) }
                )
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var zoneRail: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("HR ZONE")
                .font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                .foregroundStyle(StrandPalette.textSecondary)
            HStack(spacing: 6) {
                ForEach(1...5, id: \.self) { z in
                    let active = z == zone
                    let color = StrandPalette.hrZoneColor(z)
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(active ? color : color.opacity(0.18))
                        .frame(height: active ? 44 : 34)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(active ? color : StrandPalette.hairline, lineWidth: 1)
                        )
                        .overlay(
                            Text("Z\(z)")
                                .font(StrandFont.captionNumber)
                                .foregroundStyle(active ? StrandPalette.surfaceBase : StrandPalette.textTertiary)
                        )
                }
            }
            if let band = zoneSet.zones.first(where: { $0.number == zone }) {
                Text("Zone \(zone): \(Int(band.lower))–\(Int(band.upper)) bpm (\(Int(band.lowerPct * 100))–\(Int(band.upperPct * 100))% max HR)")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
            } else {
                Text("Warming up — keep moving to climb into Zone 1.")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }

    private var statsGrid: some View {
        let w = model.activeWorkout
        return HStack(spacing: NoopMetrics.gap) {
            stat("AVG", (w?.avgHr ?? 0) > 0 ? "\(w!.avgHr)" : "—",
                 tint: (w?.avgHr ?? 0) > 0 ? StrandPalette.metricRose : StrandPalette.textPrimary)
            stat("PEAK", (w?.peakHr ?? 0) > 0 ? "\(w!.peakHr)" : "—",
                 tint: (w?.peakHr ?? 0) > 0 ? StrandPalette.metricRose : StrandPalette.textPrimary)
            stat("EFFORT", UnitFormatter.effortDisplay(w?.liveStrain ?? 0, scale: effortScale),
                 tint: StrandPalette.strainColor(w?.liveStrain ?? 0))
        }
    }

    private func stat(_ title: String, _ value: String, tint: Color = StrandPalette.textPrimary) -> some View {
        NoopCard(padding: 14, tint: tint) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textSecondary)
                Text(value)
                    .font(StrandFont.number(26))
                    .foregroundStyle(tint)
                    .lineLimit(1).minimumScaleFactor(0.6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var endButton: some View {
        Button(role: .destructive) {
            model.endWorkout()
            onClose()
        } label: {
            Text("End workout")
                .font(StrandFont.headline)
                .frame(maxWidth: .infinity).padding(.vertical, 10)
        }
        .buttonStyle(.borderedProminent)
        .tint(StrandPalette.statusCritical)
    }

    // MARK: - Helpers

    private static func elapsed(since start: Date) -> String {
        let s = max(0, Int(Date().timeIntervalSince(start)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private static func zoneName(_ zone: Int) -> String {
        switch zone {
        case 1: return "Recovery"
        case 2: return "Fat burn"
        case 3: return "Aerobic"
        case 4: return "Threshold"
        case 5: return "Maximum"
        default: return ""
        }
    }
}
