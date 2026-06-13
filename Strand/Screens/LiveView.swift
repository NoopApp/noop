import SwiftUI
#if os(macOS)
import AppKit
#endif
import StrandDesign
import WhoopProtocol
import WhoopStore

/// Live — the connected strap in real time. Built on the shared design system
/// (ScreenScaffold chrome, StrandPalette, StrandFont) so it lines up pixel-for-pixel
/// with every other screen instead of the old standalone Milestone-1 layout.
struct LiveView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var live: LiveState

    /// Which strap the user is pairing — persists across launches. Drives which
    /// BLE service we scan for so a WHOOP 4.0 scan never hangs on a WHOOP 5 wrist.
    @AppStorage("selectedWhoopModel") private var selectedModelRaw = WhoopModel.whoop4.rawValue
    private var selectedModel: WhoopModel { WhoopModel(rawValue: selectedModelRaw) ?? .whoop4 }

    /// Smoothed, spike-filtered live HR from AppModel (median over a short window).
    private var displayHR: Int? { model.bpm }
    private var activeConnection: Bool { live.connected && live.bonded }

    var body: some View {
        ScreenScaffold(title: "Live",
                       subtitle: "Your strap in real time — heart rate and frames as they arrive.") {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                connectionRow
                // Can't-connect-at-all guidance: the strap wiped its bond (firmware update / WHOOP app
                // re-bond), so connects loop on "Peer removed pairing information". Show the re-pair steps
                // right here instead of silently retrying. (5/MG firmware reset, 2026-06)
                if let guide = live.reconnectGuide { reconnectGuideBanner(guide) }
                // Bond-refused guidance, shown right here on Live where people actually connect (it
                // also appears in Settings). A 5/MG strap still bonded to the WHOOP app refuses pairing
                // with "Encryption is insufficient" — this tells the user to free it and re-pair.
                if let hint = live.pairingHint { pairingHintBanner(hint) }
                heartRateCard
                // Low-bandwidth fallback note (#80): the radio couldn't sustain the WHOOP 4 R10/R11 raw
                // realtime burst, so live HR is riding the standard BLE Heart-Rate profile instead. Live HR
                // still works — this is informational, not an error — so it sits right under the readout in
                // a calm accent treatment rather than the amber warning banners above.
                if Self.shouldShowStandardHRNote(live.standardHRMode) {
                    standardHRNote(live.standardHRMode ?? "")
                }
                statusGrid
                workoutSection
                // Show the strap picker whenever we're not actively streaming, so a user with both a
                // WHOOP 4 and a 5/MG can switch between them. (It used to hide once `bonded`, which is
                // sticky across disconnects — so after the first pairing the picker vanished for good.)
                if !activeConnection { modelPicker }
                controls
                logCard
            }
        }
        .onAppear { refreshLiveSession() }
        .onDisappear { model.stopRealtimeHR() }
        .onChange(of: live.bonded) { _ in refreshLiveSession() }
        .onChange(of: live.connected) { _ in refreshLiveSession() }
    }

    // MARK: - Connection

    private var connectionRow: some View {
        HStack {
            connectionPill
            Spacer()
        }
    }

    private var connectionPill: some View {
        // Distinguish a GENUINE encrypted bond from the 5/MG live-HR shortcut that flips `bonded` true
        // over the unbonded standard profile (#69): green "Bonded · streaming" only when encryptedBond,
        // amber "Live HR (not fully paired)" otherwise. The pairingHintBanner below gives the how-to.
        let (label, color): (String, Color) =
            (activeConnection && live.encryptedBond) ? ("Bonded · streaming", StrandPalette.accent)
            : activeConnection ? ("Live HR (not fully paired)", StrandPalette.statusWarning)
            : live.connected ? ("Connected", StrandPalette.statusWarning)
            : live.encryptedBond ? ("Paired · idle", StrandPalette.statusWarning)
            : ("Disconnected", StrandPalette.metricRose)
        return HStack(spacing: 8) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(label).font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(StrandPalette.surfaceRaised, in: Capsule())
    }

    // MARK: - Heart rate

    private var heartRateCard: some View {
        NoopCard {
            VStack(spacing: 6) {
                Text("HEART RATE").font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textSecondary)
                Text(displayHR.map(String.init) ?? "—")
                    .font(.system(size: 96, weight: .semibold).monospacedDigit())
                    .foregroundStyle(displayHR == nil ? StrandPalette.textTertiary : StrandPalette.accent)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: displayHR)
                Text("bpm").font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                Text(rrLine)
                    .font(StrandFont.mono)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 20)
        }
    }

    private var rrLine: String {
        guard !live.rrRecent.isEmpty else {
            return Self.rrEmptyMessage(hasLiveHeartRate: displayHR != nil, activeConnection: activeConnection)
        }
        return "R-R: " + live.rrRecent.suffix(6).map(String.init).joined(separator: " · ") + " ms"
    }

    static func rrEmptyMessage(hasLiveHeartRate: Bool, activeConnection: Bool) -> String {
        if hasLiveHeartRate { return "Heart rate is live; this stream has not delivered R-R intervals yet." }
        if activeConnection { return "Stream is active, waiting for R-R intervals." }
        return "Waiting for a live stream."
    }

    // MARK: - Status tiles

    private var statusGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: NoopMetrics.gap)],
                  spacing: NoopMetrics.gap) {
            stat("Battery", live.batteryPct.map { "\(Int($0))%" } ?? "—")
            stat("HR samples", "\(live.heartRateSamplesThisSession)")
            stat("R-R packets", "\(live.rrPacketsThisSession)")
            stat("Last frame", live.lastFrameType ?? "—")
            stat("Last event", live.lastEvent ?? "—")
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 4) {
                Text(title.uppercased()).font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textSecondary)
                Text(value).font(StrandFont.headline).monospacedDigit()
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1).minimumScaleFactor(0.6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Manual workout

    @ViewBuilder private var workoutSection: some View {
        if let w = model.activeWorkout {
            activeWorkoutCard(w)
        } else {
            if activeConnection {
                Button { model.startWorkout() } label: {
                    Label("Start workout", systemImage: "figure.run")
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent).tint(StrandPalette.accent)
                .help("Track a workout manually — records heart rate and effort until you end it.")
            }
            if let last = model.lastWorkout {
                workoutSavedRow(last)
            }
        }
    }

    private func activeWorkoutCard(_ w: AppModel.ActiveWorkout) -> some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Circle().fill(StrandPalette.metricRose).frame(width: 8, height: 8)
                    Text("RECORDING WORKOUT").font(StrandFont.overline)
                        .tracking(StrandFont.overlineTracking).foregroundStyle(StrandPalette.metricRose)
                    Spacer()
                    // Re-render once a second so the elapsed clock ticks without a manual Timer.
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(Self.elapsed(since: w.start)).font(StrandFont.headline).monospacedDigit()
                            .foregroundStyle(StrandPalette.textPrimary)
                    }
                }
                HStack(spacing: NoopMetrics.gap) {
                    workoutStat("HR", model.bpm.map { "\($0)" } ?? "—")
                    workoutStat("Avg", w.avgHr > 0 ? "\(w.avgHr)" : "—")
                    workoutStat("Peak", w.peakHr > 0 ? "\(w.peakHr)" : "—")
                    workoutStat("Effort", String(format: "%.1f", w.liveStrain))
                }
                Button(role: .destructive) { model.endWorkout() } label: {
                    Label("End workout", systemImage: "stop.circle.fill")
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent).tint(StrandPalette.metricRose)
            }
        }
    }

    private func workoutStat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased()).font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                .foregroundStyle(StrandPalette.textSecondary)
            Text(value).font(StrandFont.headline).monospacedDigit()
                .foregroundStyle(StrandPalette.textPrimary).lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func workoutSavedRow(_ row: WorkoutRow) -> some View {
        let mins = Int((row.durationS ?? 0) / 60)
        let parts = ["\(mins) min", row.avgHr.map { "\($0) avg bpm" },
                     row.strain.map { String(format: "effort %.1f", $0) }].compactMap { $0 }
        return HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(StrandPalette.accent)
            Text("Workout saved · \(parts.joined(separator: " · "))")
                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
    }

    private static func elapsed(since start: Date) -> String {
        let s = max(0, Int(Date().timeIntervalSince(start)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func reconnectGuideBanner(_ guide: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(StrandPalette.statusWarning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Can't connect — your strap's pairing was reset")
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                Text(guide)
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(StrandPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(StrandPalette.statusWarning.opacity(0.5), lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Reconnect help: \(guide)")
    }

    private func pairingHintBanner(_ hint: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(StrandPalette.statusWarning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Live HR works — free the strap to unlock buzz, alarms & sync")
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                Text(hint)
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(StrandPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(StrandPalette.statusWarning.opacity(0.5), lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Pairing help: \(hint)")
    }

    /// Whether the low-bandwidth standard-HR fallback note should render. The note explains that live HR
    /// is coming over the standard BLE Heart-Rate profile because the radio couldn't sustain the full
    /// stream (#80). Shown only when LiveState carries a non-empty note string; pure so it's unit-testable
    /// without standing up a SwiftUI view.
    static func shouldShowStandardHRNote(_ note: String?) -> Bool {
        guard let note, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return true
    }

    /// Calm inline note for the #80 low-bandwidth fallback. Unlike the amber pairing/reconnect banners this
    /// is NOT a warning — live HR is working — so it uses the accent (health-green) treatment with a signal
    /// glyph. Mirrors the banner layout (icon + headline + one-line explanation) for visual consistency.
    private func standardHRNote(_ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .foregroundStyle(StrandPalette.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Standard HR mode (low bandwidth)")
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                Text(detail)
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Other metrics (R-R, frames, battery, history) need a full sync.")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(StrandPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(StrandPalette.accent.opacity(0.4), lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Standard HR mode, low bandwidth. \(detail)")
    }

    // MARK: - Strap picker

    /// Pick the strap family to scan for. Switching the selection drops the current strap's bond so the
    /// newly-picked one connects fresh — letting a user move between a WHOOP 4 and a 5/MG.
    private var modelPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("Strap").font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                SegmentedPillControl(
                    WhoopModel.allCases,
                    selection: Binding(
                        get: { selectedModel },
                        set: { newModel in
                            guard newModel.rawValue != selectedModelRaw else { return }
                            selectedModelRaw = newModel.rawValue
                            // Clear the previous strap's sticky bond/connection so the next scan targets the
                            // new family's service and bonds it fresh.
                            model.prepareStrapSwitch()
                        }
                    ),
                    label: { $0.displayName }
                )
                Spacer()
            }
            // Proactive 5/MG guidance: the strap bonds to one host at a time, so if it's still paired in
            // the official WHOOP app a scan here finds nothing. Shown the moment 5/MG is picked — not only
            // after a failed scan (#130) or a bond-refusal (which is the separate `pairingHint` banner).
            if selectedModel == .whoop5mg { whoop5PairingNote }
        }
    }

    private var whoop5PairingNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle").foregroundStyle(StrandPalette.accent)
            Text("WHOOP 5.0/MG pairs with one app at a time. If a scan finds nothing, unpair it in the official WHOOP app and fully close that app, then Scan again.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Controls

    private var controls: some View {
        // Three buttons share the row's width equally, so on a narrow iPhone each label must shrink to
        // fit rather than wrap mid-word ("Dis-/con-/nect"). lineLimit(1)+minimumScaleFactor keeps them
        // on one line; the icon stays. (#175)
        HStack(spacing: 12) {
            Button { model.scan(model: selectedModel) } label: {
                Label(live.connected ? "Re-scan" : "Scan & Connect",
                      systemImage: "antenna.radiowaves.left.and.right")
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent).tint(StrandPalette.accent)

            Button { model.buzz() } label: {
                Label("Buzz strap", systemImage: "waveform.path")
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
            }
            .buttonStyle(.bordered).tint(StrandPalette.accent)
            .disabled(!activeConnection)
            .help("Fire a test haptic buzz on the strap (requires an active strap connection)")

            Button(role: .destructive) { model.disconnect() } label: {
                Label("Disconnect", systemImage: "xmark.circle")
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
            }
            .buttonStyle(.bordered)
            .disabled(!live.connected)
        }
    }

    private func refreshLiveSession() {
        guard activeConnection else { return }
        model.startRealtimeHR()
        model.getBattery()
    }

    // MARK: - Strap log

    private var logCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Text("STRAP LOG").font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                        .foregroundStyle(StrandPalette.textSecondary)
                    Spacer()
                    // Export the log so people can attach it to a bug report (issue #17 — macOS users
                    // had no way to share it). Copy → clipboard; Save… → a .txt file.
                    Button("Copy") { copyStrapLog() }
                        .buttonStyle(.plain).font(StrandFont.mono).foregroundStyle(StrandPalette.accent)
                    Button("Save…") { saveStrapLog() }
                        .buttonStyle(.plain).font(StrandFont.mono).foregroundStyle(StrandPalette.accent)
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(live.log.enumerated()), id: \.offset) { idx, line in
                                Text(line).font(StrandFont.mono)
                                    .foregroundStyle(StrandPalette.textSecondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(idx)
                            }
                        }
                    }
                    .frame(height: 200)
                    .onChange(of: live.log.count) { _ in
                        if let last = live.log.indices.last { proxy.scrollTo(last, anchor: .bottom) }
                    }
                }
            }
        }
    }

    // MARK: - Strap-log export (issue #17 — let macOS users share the log for bug reports)

    private func strapLogText() -> String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        #if os(iOS)
        let osName = "iOS"
        #else
        let osName = "macOS"
        #endif
        let header = "NOOP strap log — \(osName)\nApp: \(v)\n\(osName): "
            + ProcessInfo.processInfo.operatingSystemVersionString + "\n"
            + String(repeating: "-", count: 40) + "\n"
        return header + live.log.joined(separator: "\n")
    }

    private func copyStrapLog() {
        PlatformPasteboard.copy(strapLogText())
    }

    private func saveStrapLog() {
        FileExport.exportText(strapLogText(), suggestedName: "noop-strap-log.txt")
    }
}
