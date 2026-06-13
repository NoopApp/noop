import SwiftUI
import Foundation
import StrandDesign
import StrandAnalytics
import WhoopStore

/// NOOP — Health Monitor.
/// Live heart rate hero (ChartCard with a streaming sparkline + HR-zone footer),
/// then a uniform LazyVGrid of the body's vital signs (respiratory rate, blood
/// oxygen, resting HR, HRV, skin temp) as fixed-height StatTiles, each tinted and
/// captioned with its in-range state. Re-skinned to the locked NOOP component
/// system: every surface is a NoopCard, every metric is a StatTile, every chart is
/// a ChartCard — no ad-hoc card heights or paddings.
struct HealthView: View {
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var live: LiveState
    @EnvironmentObject var profile: ProfileStore

    // MARK: - Derived live HR

    /// HR to display: reported value when >0, else derived from the latest R-R
    /// interval (the strap streams R-R even when its HR field reads 0).
    private var displayHR: Int? {
        if let hr = live.heartRate, hr > 0 { return hr }
        if let last = live.rr.last, last > 0 { return Int((60_000.0 / Double(last)).rounded()) }
        return nil
    }
    private var hasLiveHR: Bool { displayHR != nil }

    // MARK: - Body

    var body: some View {
        ScreenScaffold(title: "Health Monitor",
                       subtitle: "Live vitals, streamed from the strap.") {
            if repo.today == nil && !hasLiveHR {
                emptyState
            } else {
                VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                    // The live HR section is its own view: it owns `live`/`profile`,
                    // so the ~1Hz HR stream re-renders only this subtree — the static
                    // vitals grid below does not re-render on each HR tick.
                    HeartRateSection()
                    // The static vitals grid is its own view depending only on `repo`,
                    // so it is unaffected by live HR ticks.
                    VitalsSection()
                }
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        ComingSoon(what: "No biometrics yet. Import your WHOOP export (and Apple Health if you have it) in Data Sources to fill this in.")
    }
}

// MARK: - Heart rate hero (live)

/// Live HR hero, split into its own view so the ~1Hz HR stream only re-renders this
/// subtree — the static vitals grid does not. Depends on `live` and `profile` only.
private struct HeartRateSection: View {
    @EnvironmentObject var live: LiveState
    @EnvironmentObject var profile: ProfileStore

    /// Rolling buffer of recently-streamed live HR (newest last), so the hero graph builds a real
    /// continuous time-series instead of collapsing to a 2-point flat line when the strap streams HR
    /// but little/no R-R (the #105 case — Live HR works, but the Health graph showed only 2 samples).
    /// Capped to ~3 min @ ~1 Hz; resets when the view is recreated, which is fine for a live trace.
    @State private var hrHistory: [(date: Date, value: Double)] = []

    /// HR to display: reported value when >0, else derived from the latest R-R
    /// interval (the strap streams R-R even when its HR field reads 0).
    private var displayHR: Int? {
        if let hr = live.heartRate, hr > 0 { return hr }
        if let last = live.rr.last, last > 0 { return Int((60_000.0 / Double(last)).rounded()) }
        return nil
    }
    private var hrIsDerived: Bool { (live.heartRate ?? 0) <= 0 && !live.rr.isEmpty }

    /// HR as a fraction of HR-max (0…1).
    private func hrFraction(_ hr: Int?) -> Double {
        guard let hr = hr, profile.hrMax > 0 else { return 0 }
        return min(max(Double(hr) / Double(profile.hrMax), 0), 1)
    }

    /// Current zone 1…5 from %HR-max (WHOOP/Karvonen-style bands: 50/60/70/80/90).
    private func hrZone(_ fraction: Double) -> Int {
        switch fraction {
        case ..<0.60: return 1
        case ..<0.70: return 2
        case ..<0.80: return 3
        case ..<0.90: return 4
        default:      return 5
        }
    }

    /// A short HR series for the hero sparkline, derived from streamed R-R intervals
    /// (newest last). Falls back to a flat line at the current HR when R-R is sparse.
    private func hrSeries(_ hr: Int?) -> [Double] {
        // Prefer the accumulated live HR time-series — that's what a "live" graph should show, and it
        // keeps growing even when the strap streams HR but sparse R-R (#105). Fall back to R-R-derived
        // beats, then a flat line at the current HR.
        if hrHistory.count > 1 { return hrHistory.map(\.value) }
        let beats = live.rr.suffix(60).compactMap { rr -> Double? in
            rr > 0 ? 60_000.0 / Double(rr) : nil
        }
        if beats.count > 1 { return Array(beats) }
        if let hr = hr { return [Double(hr), Double(hr)] }
        return []
    }

    var body: some View {
        // Compute the derived live values ONCE per body pass and thread them into the
        // subviews, instead of re-evaluating heavy computed properties multiple times.
        let displayHR = self.displayHR
        let hasLiveHR = displayHR != nil
        let fraction = hrFraction(displayHR)
        let zone = hrZone(fraction)
        let series = hrSeries(displayHR)

        return VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Heart Rate", overline: "Live", trailing: hrIsDerived ? "from R-R" : nil)

            ChartCard(
                title: "Heart Rate",
                subtitle: hrIsDerived ? "Estimated from R-R interval"
                    : (hasLiveHR ? "Streaming live" : "Awaiting strap"),
                trailing: hasLiveHR ? "\(displayHR!) bpm" : "—"
            ) {
                heroChart(displayHR: displayHR, hasLiveHR: hasLiveHR,
                          fraction: fraction, zone: zone, series: series)
            } footer: {
                ChartFooter([
                    ("Zone", hasLiveHR ? "Z\(zone)" : "—"),
                    ("% Max", hasLiveHR ? "\(Int((fraction * 100).rounded()))%" : "—"),
                    ("Max HR", "\(profile.hrMax)"),
                    ("State", hasLiveHR ? "STREAMING" : "IDLE"),
                ])
            }
        }
        .onAppear { appendLiveSample() }
        .onChange(of: live.biometricSampleSeq) { _ in
            appendLiveSample()
        }
        .onChange(of: live.connected) { connected in
            if !connected { hrHistory.removeAll() }
        }
    }

    private func appendLiveSample() {
        guard let v = displayHR else { return }
        let now = Date()
        hrHistory.append((date: now, value: Double(v)))
        hrHistory.removeAll { now.timeIntervalSince($0.date) > 180 }
        if hrHistory.count > 240 { hrHistory.removeFirst(hrHistory.count - 240) }
    }

    /// The hero chart body: a tall HR sparkline tinted to the current zone, with a
    /// status pill floated top-trailing. Fixed to NoopMetrics.chartHeight via ChartCard.
    private func heroChart(displayHR: Int?, hasLiveHR: Bool,
                           fraction: Double, zone: Int, series: [Double]) -> some View {
        ZStack(alignment: .topTrailing) {
            if series.count > 1 {
                Sparkline(
                    values: series,
                    gradient: Gradient(colors: [
                        StrandPalette.hrZoneColor(max(1, zone - 1)),
                        StrandPalette.hrZoneColor(zone),
                    ]),
                    lineWidth: 2.5,
                    showsArea: true,
                    valueFormat: { "\(Int($0.rounded())) bpm" },
                    indexLabel: hrHistory.count > 1 ? liveSampleLabel : nil
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 8) {
                    Text(displayHR.map(String.init) ?? "—")
                        .font(StrandFont.display(72))
                        .foregroundStyle(hasLiveHR ? StrandPalette.hrZoneColor(zone) : StrandPalette.textTertiary)
                        .contentTransition(.numericText())
                        .animation(StrandMotion.interactive, value: displayHR)
                    Text("bpm").font(StrandFont.subhead).foregroundStyle(StrandPalette.textTertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            StatePill("\(zoneLabel(hasLiveHR: hasLiveHR, zone: zone, fraction: fraction))",
                      tone: hasLiveHR ? .accent : .neutral,
                      showsDot: hasLiveHR,
                      pulsing: hasLiveHR)
        }
    }

    private func zoneLabel(hasLiveHR: Bool, zone: Int, fraction: Double) -> String {
        guard hasLiveHR else { return "Idle" }
        return "Zone \(zone) · \(Int((fraction * 100).rounded()))%"
    }

    private func liveSampleLabel(_ index: Int) -> String {
        guard hrHistory.indices.contains(index) else { return "sample \(index + 1)" }
        let seconds = max(0, Int(Date().timeIntervalSince(hrHistory[index].date).rounded()))
        if seconds <= 1 { return "now" }
        return "\(seconds)s ago"
    }
}

// MARK: - Vitals grid (uniform StatTiles)

/// Static vitals grid, split into its own view so it depends only on `repo` and is
/// not re-rendered by the ~1Hz live HR stream.
private struct VitalsSection: View {
    @EnvironmentObject var repo: Repository

    // Temperature display preference (D#103). Skin temp is stored in °C (absolute or a ±deviation); the
    // toggle re-labels it to °F. Display-only — banding still runs on the stored °C value.
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.temperatureKey) private var temperatureRaw = ""
    private var temperatureUnit: TemperatureUnit {
        let system = UnitSystem(rawValue: unitSystemRaw) ?? .metric
        return UnitPrefs.resolveTemperature(system: system, override: temperatureRaw)
    }

    var body: some View {
        let vitals = BodyVitalSigns.readings(
            days: repo.days,
            today: repo.today,
            temperatureUnit: temperatureUnit
        )
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Vital Signs", overline: "Latest", trailing: BodyVitalSigns.latestDayLabel(vitals))
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 168), spacing: NoopMetrics.gap)],
                alignment: .leading,
                spacing: NoopMetrics.gap
            ) {
                ForEach(vitals) { v in
                    StatTile(
                        label: LocalizedStringKey(v.label),
                        value: v.formattedValue ?? "—",
                        caption: v.stateCaption,
                        accent: v.accent
                    )
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(v.accessibilityText)
                }
            }
            Text("Once NOOP has 14 nights of history, in-range compares each vital to your own baseline (approximate — not medical advice); until then, typical adult ranges apply.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Health Monitor") {
    let repo = Repository(deviceId: "preview")
    repo.days = [
        DailyMetric(
            day: "2026-06-06",
            totalSleepMin: 462, efficiency: 92,
            deepMin: 96, remMin: 108, lightMin: 240, disturbances: 7,
            restingHr: 52, avgHrv: 74, recovery: 81, strain: 11.4,
            exerciseCount: 1,
            spo2Pct: 97, skinTempDevC: 34.2, respRateBpm: 14.6
        )
    ]
    repo.loaded = true

    let live = LiveState()
    live.connected = true
    live.bonded = true
    live.heartRate = 132
    live.rr = [455, 460, 448, 470, 452, 461, 449, 458, 463, 451]

    return HealthView()
        .environmentObject(repo)
        .environmentObject(live)
        .environmentObject(ProfileStore())
        .frame(width: 900, height: 760)
        .preferredColorScheme(.dark)
}
#endif
