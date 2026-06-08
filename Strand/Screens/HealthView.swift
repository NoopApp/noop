import SwiftUI
import StrandDesign
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
                    valueFormat: { "\(Int($0.rounded())) bpm" }
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
}

// MARK: - Vitals grid (uniform StatTiles)

/// Static vitals grid, split into its own view so it depends only on `repo` and is
/// not re-rendered by the ~1Hz live HR stream.
private struct VitalsSection: View {
    @EnvironmentObject var repo: Repository

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Vital Signs", overline: "Today", trailing: vitalsAsOf)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 168), spacing: NoopMetrics.gap)],
                alignment: .leading,
                spacing: NoopMetrics.gap
            ) {
                ForEach(vitals) { v in
                    StatTile(
                        label: "\(v.label)",
                        value: v.formattedValue ?? "—",
                        caption: v.stateCaption,
                        accent: v.accent
                    )
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(v.accessibilityText)
                }
            }
        }
    }

    /// "as of" caption sourced from the most recent imported day.
    private var vitalsAsOf: String? {
        guard let day = repo.today?.day else { return nil }
        return "as of \(day)"
    }

    /// The vitals row, built from the most recent imported day.
    private var vitals: [Vital] {
        let d = repo.today
        return [
            Vital(key: "resp", label: "Resp Rate", unit: "rpm",
                  value: d?.respRateBpm, format: { String(format: "%.1f", $0) },
                  inRange: 12...20, metricColor: StrandPalette.metricCyan),
            Vital(key: "spo2", label: "Blood O₂", unit: "%",
                  value: d?.spo2Pct, format: { String(format: "%.0f", $0) },
                  inRange: 95...100, metricColor: StrandPalette.metricCyan),
            Vital(key: "rhr", label: "Resting HR", unit: "bpm",
                  value: d?.restingHr.map(Double.init), format: { String(Int($0.rounded())) },
                  inRange: 40...60, metricColor: StrandPalette.metricRose),
            Vital(key: "hrv", label: "HRV", unit: "ms",
                  value: d?.avgHrv, format: { String(Int($0.rounded())) },
                  inRange: 40...120, metricColor: StrandPalette.metricPurple),
            Vital(key: "skin", label: "Skin Temp", unit: "°C",
                  value: d?.skinTempDevC, format: { String(format: "%.1f", $0) },
                  inRange: 33...36, metricColor: StrandPalette.metricAmber),
        ]
    }
}

// MARK: - Vital model

private struct Vital: Identifiable {
    let key: String
    let label: String
    let unit: String
    let value: Double?
    let format: (Double) -> String
    /// Healthy range used to compute the in-range state.
    let inRange: ClosedRange<Double>
    /// The metric's category colour (used only when in range).
    let metricColor: Color

    var id: String { key }
    var isInRange: Bool { value.map { inRange.contains($0) } ?? false }

    /// Value with its unit appended, or nil when no data.
    var formattedValue: String? { value.map { "\(format($0)) \(unit)" } }

    /// Colour communicates state: in-range = the metric's category colour,
    /// out-of-range = warning amber, no data = tertiary.
    var accent: Color {
        guard value != nil else { return StrandPalette.textTertiary }
        return isInRange ? metricColor : StrandPalette.statusWarning
    }

    /// The textual in-range caption that stands in for a StatePill inside the
    /// fixed-height tile (keeps the row pixel-uniform).
    var stateCaption: String {
        guard value != nil else { return "No data" }
        return isInRange ? "In range" : "Out of range"
    }

    var accessibilityText: String {
        guard let v = formattedValue else { return "\(label): no data" }
        return "\(label): \(v), \(isInRange ? "in range" : "out of range")"
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
