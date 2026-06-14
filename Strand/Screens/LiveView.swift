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

    /// Drives the focal HR ring's gentle pulse — toggled on every new HR value so the ring "beats".
    @State private var heartPulse = false

    var body: some View {
        ScreenScaffold(title: "Live Body Console",
                       subtitle: "Current physiology, strap trust, and session controls in one working view.") {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                consoleHeader
                // Can't-connect-at-all guidance: the strap wiped its bond (firmware update / WHOOP app
                // re-bond), so connects loop on "Peer removed pairing information". Show the re-pair steps
                // right here instead of silently retrying. (5/MG firmware reset, 2026-06)
                if let guide = live.reconnectGuide { reconnectGuideBanner(guide) }
                // Bond-refused guidance, shown right here on Live where people actually connect (it
                // also appears in Settings). A 5/MG strap still bonded to the WHOOP app refuses pairing
                // with "Encryption is insufficient" — this tells the user to free it and re-pair.
                if let hint = live.pairingHint { pairingHintBanner(hint) }
                bodyConsole
                // Low-bandwidth fallback note (#80): the radio couldn't sustain the WHOOP 4 R10/R11 raw
                // realtime burst, so live HR is riding the standard BLE Heart-Rate profile instead. Live HR
                // still works — this is informational, not an error — so it sits right under the readout in
                // a calm accent treatment rather than the amber warning banners above.
                if Self.shouldShowStandardHRNote(live.standardHRMode) {
                    standardHRNote(live.standardHRMode ?? "")
                }
                signalTrustRail
                sessionConsole
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
        .onChange(of: displayHR) { _ in
            withAnimation(StrandMotion.pulse) { heartPulse.toggle() }
        }
    }

    // MARK: - Console header

    /// The console's top band: the connection pill + a connection-mode badge (+ a live SYNCING badge
    /// while a history offload runs), with battery / worn / last-sync stats pushed to the trailing edge.
    private var consoleHeader: some View {
        NoopCard(padding: 14) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) {
                    connectionPill
                    SourceBadge(connectionModeBadge, tint: connectionModeColor)
                    if live.backfilling {
                        SourceBadge("SYNCING \(live.syncChunksThisSession)", tint: StrandPalette.metricCyan)
                    }
                    Spacer(minLength: 8)
                    headerStats
                }
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        connectionPill
                        SourceBadge(connectionModeBadge, tint: connectionModeColor)
                        if live.backfilling {
                            SourceBadge("SYNCING \(live.syncChunksThisSession)", tint: StrandPalette.metricCyan)
                        }
                        Spacer(minLength: 0)
                    }
                    headerStats
                }
            }
        }
    }

    private var headerStats: some View {
        HStack(spacing: 16) {
            headerStat("Battery", live.batteryPct.map { "\(Int($0))%" } ?? "—")
            headerStat("Worn", activeConnection ? (live.worn ? "Yes" : "No") : "—")
            headerStat("Last sync", lastSyncLabel)
        }
    }

    private func headerStat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(title.uppercased())
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
            Text(value)
                .font(StrandFont.captionNumber)
                .foregroundStyle(StrandPalette.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    private var connectionModeBadge: LocalizedStringKey {
        if activeConnection && live.encryptedBond { return "FULL BOND" }
        if activeConnection { return "LIVE HR ONLY" }
        if live.connected { return "CONNECTING" }
        if live.encryptedBond { return "PAIRED" }
        return "OFFLINE"
    }

    private var connectionModeColor: Color {
        if activeConnection && live.encryptedBond { return StrandPalette.accent }
        if activeConnection || live.connected { return StrandPalette.statusWarning }
        return StrandPalette.metricRose
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

    // MARK: - Body console (focal HR + live physiology)

    /// The console's centrepiece: a pulsing focal HR ring beside a live-physiology stack (R-R strip,
    /// rolling RMSSD, last frame/event). Side-by-side on a wide window (Mac), stacked on a narrow one
    /// (iPhone) via ViewThatFits.
    private var bodyConsole: some View {
        NoopCard(padding: 20) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 24) {
                    heartReadout
                        .frame(minWidth: 260, maxWidth: 340)
                    Divider().overlay(StrandPalette.hairline)
                    physiologyStack
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: 18) {
                    heartReadout
                    Divider().overlay(StrandPalette.hairline)
                    physiologyStack
                }
            }
        }
    }

    private var heartReadout: some View {
        VStack(alignment: .center, spacing: 8) {
            Text("HEART RATE")
                .font(StrandFont.overline)
                .tracking(StrandFont.overlineTracking)
                .foregroundStyle(StrandPalette.textSecondary)
            ZStack {
                Circle()
                    .stroke((displayHR == nil ? StrandPalette.hairline : StrandPalette.accent)
                        .opacity(heartPulse ? 0.28 : 0.10), lineWidth: 2)
                    .scaleEffect(heartPulse ? 1.07 : 0.96)
                Circle()
                    .stroke(StrandPalette.hairline, lineWidth: 1)
                    .padding(10)
                VStack(spacing: 0) {
                    Text(displayHR.map(String.init) ?? "—")
                        .font(.system(size: 96, weight: .semibold).monospacedDigit())
                        .foregroundStyle(displayHR == nil ? StrandPalette.textTertiary : StrandPalette.accent)
                        .contentTransition(.numericText())
                        .animation(.snappy, value: displayHR)
                    Text("bpm")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
            .frame(width: 210, height: 210)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(displayHR.map { "Heart rate \($0) beats per minute" } ?? "Heart rate not available")
            Text(signalTrustSummary)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }

    private var physiologyStack: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("LIVE PHYSIOLOGY")
                        .font(StrandFont.overline)
                        .tracking(StrandFont.overlineTracking)
                        .foregroundStyle(StrandPalette.textSecondary)
                    Text(connectionModeDetail)
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                Spacer()
                if let rmssd = rollingRMSSD {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("RMSSD")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                        Text("\(Int(rmssd.rounded())) ms")
                            .font(StrandFont.number(24))
                            .foregroundStyle(StrandPalette.metricCyan)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Rolling RMSSD \(Int(rmssd.rounded())) milliseconds")
                }
            }
            rrStrip
            HStack(spacing: NoopMetrics.gap) {
                liveProofMetric("R-R", rrSummary, StrandPalette.metricCyan)
                liveProofMetric("Frame", live.lastFrameType ?? "—", StrandPalette.accent)
                liveProofMetric("Event", live.lastEvent ?? "—", StrandPalette.statusWarning)
            }
        }
    }

    /// A compact bar strip of the recent R-R buffer — the proof the console is genuinely live (a
    /// single HR number can look frozen; a moving R-R strip can't). Empty state shows muted ticks.
    private var rrStrip: some View {
        let values = Array(live.rrRecent.suffix(18))
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 5) {
                if values.isEmpty {
                    ForEach(0..<18, id: \.self) { _ in
                        Capsule().fill(StrandPalette.hairline).frame(width: 6, height: 18)
                    }
                } else {
                    ForEach(Array(values.enumerated()), id: \.offset) { _, rr in
                        Capsule()
                            .fill(StrandPalette.metricCyan.opacity(0.35 + min(0.45, Double(rr % 180) / 400.0)))
                            .frame(width: 6, height: rrBarHeight(rr))
                    }
                }
            }
            .accessibilityHidden(true)
            Text(values.isEmpty
                 ? "Waiting for R-R intervals."
                 : "Recent intervals: " + values.suffix(5).map(String.init).joined(separator: " · ") + " ms")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    private func liveProofMetric(_ label: String, _ value: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
            Text(value)
                .font(StrandFont.captionNumber)
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(StrandPalette.hairline, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }

    private func rrBarHeight(_ rr: Int) -> CGFloat {
        let clamped = min(max(rr, 420), 1_180)
        return 16 + CGFloat(clamped - 420) / 760 * 42
    }

    /// A "feel" RMSSD over the recent R-R buffer — time-gap-unaware on purpose (a live indicator, not a
    /// clinical figure; it's blanked on disconnect by clearBiometrics). nil until ≥3 intervals land.
    private var rollingRMSSD: Double? {
        let values = Array(live.rrRecent.suffix(12)).map(Double.init)
        guard values.count >= 3 else { return nil }
        let diffs = zip(values.dropFirst(), values).map { $0 - $1 }
        let meanSquare = diffs.map { $0 * $0 }.reduce(0, +) / Double(diffs.count)
        return sqrt(meanSquare)
    }

    private var rrSummary: String {
        guard let last = live.rr.last else { return "—" }
        return "\(last) ms"
    }

    private var signalTrustSummary: String {
        if activeConnection && live.encryptedBond { return "Encrypted stream — deep controls and history sync available." }
        if activeConnection { return "Live heart rate is flowing; full strap controls need an encrypted bond." }
        if live.connected { return "Connected, waiting for a streaming state." }
        return "Scan and connect to start a live stream."
    }

    private var connectionModeDetail: String {
        if activeConnection && live.encryptedBond { return "Full strap stream is active." }
        if activeConnection { return "Heart rate stream is active." }
        if live.connected { return "Radio connected, stream not yet trusted." }
        return "No live stream."
    }

    // MARK: - Signal trust

    /// The "Signal Trust" rail — one tile per signal that has to be current for the console to be
    /// trustworthy (HR, R-R, connection, history sync, battery, wear). Each tile's value AND tint are
    /// gated on a live link where it matters, so an offline console never shows a false-green signal.
    private var signalTrustRail: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Signal Trust", overline: "Proof that the console is current")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 168), spacing: NoopMetrics.gap)],
                      spacing: NoopMetrics.gap) {
                ForEach(signalTiles) { tile in
                    SignalTrustTile(tile: tile)
                }
            }
        }
    }

    private var signalTiles: [SignalTrustTile.Model] {
        [
            .init(title: "Heart rate",
                  value: displayHR.map { "\($0) bpm" } ?? "Missing",
                  detail: activeConnection ? "Streaming now" : "No active stream",
                  icon: "waveform.path.ecg",
                  tint: displayHR == nil ? StrandPalette.textTertiary : StrandPalette.accent),
            .init(title: "R-R intervals",
                  value: live.rrRecent.isEmpty ? "Missing" : "\(live.rrRecent.count) recent",
                  detail: rollingRMSSD.map { "RMSSD \(Int($0.rounded())) ms" } ?? "Needs interval frames",
                  icon: "point.3.connected.trianglepath.dotted",
                  tint: live.rrRecent.isEmpty ? StrandPalette.textTertiary : StrandPalette.metricCyan),
            .init(title: "Connection",
                  value: activeConnection && live.encryptedBond ? "Encrypted" : activeConnection ? "Partial" : live.connected ? "Connected" : "Offline",
                  detail: activeConnection && live.encryptedBond ? "Controls unlocked" : "Standard HR is not a full bond",
                  icon: "lock.shield",
                  tint: connectionModeColor),
            .init(title: "History sync",
                  value: live.backfilling ? "\(live.syncChunksThisSession) chunks" : lastSyncLabel,
                  detail: syncDetail,
                  icon: "clock.arrow.circlepath",
                  tint: live.backfilling ? StrandPalette.metricCyan : StrandPalette.textSecondary),
            .init(title: "Battery",
                  value: live.batteryPct.map { "\(Int($0))%" } ?? "Unknown",
                  detail: live.charging == true ? "Charging" : "Last reported by strap",
                  icon: "battery.75percent",
                  tint: batteryTint),
            // Wear is only trustworthy on a live link: `worn` defaults true (LiveState) and is only
            // updated by WRIST_ON/OFF events, so while OFFLINE it would otherwise read a false-green
            // "On wrist". Gate the value AND tint on activeConnection (triage fix for PR#191).
            .init(title: "Wear state",
                  value: activeConnection ? (live.worn ? "On wrist" : "Off wrist") : "Unknown",
                  detail: activeConnection ? (live.worn ? "Eligible for live physiology" : "Wear the strap for scoring") : "Connect to read wear state",
                  icon: "sensor.tag.radiowaves.forward",
                  tint: !activeConnection ? StrandPalette.textTertiary : live.worn ? StrandPalette.accent : StrandPalette.statusWarning)
        ]
    }

    private var batteryTint: Color {
        guard let pct = live.batteryPct else { return StrandPalette.textTertiary }
        if pct <= 15 { return StrandPalette.metricRose }
        if pct <= 30 { return StrandPalette.statusWarning }
        return StrandPalette.accent
    }

    private var lastSyncLabel: String {
        guard let ts = live.lastSyncedAt else { return "Never" }
        let date = Date(timeIntervalSince1970: ts)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private var syncDetail: String {
        if let err = live.lastSyncError { return err }
        if live.backfilling { return "\(live.decodedChunksThisSession) decoded, \(live.consoleChunksThisSession) console" }
        return live.lastSyncedAt == nil ? "No completed offload yet" : "Last offload completed"
    }

    // MARK: - Session console (record / inspect the current stream)

    @ViewBuilder private var sessionConsole: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Session", overline: "Record or inspect the current stream")
            if let w = model.activeWorkout {
                activeWorkoutCard(w)
            } else {
                NoopCard {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .center, spacing: 14) {
                            sessionPrompt
                            Spacer(minLength: 12)
                            sessionActions
                        }
                        VStack(alignment: .leading, spacing: 14) {
                            sessionPrompt
                            sessionActions
                        }
                    }
                }
                if let last = model.lastWorkout {
                    workoutSavedRow(last)
                }
            }
        }
    }

    private var sessionPrompt: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Ready for a marked effort.")
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textPrimary)
            Text(activeConnection
                 ? "Start a workout when the stream matters. NOOP records the interval, HR, peak, average and effort from the same live feed."
                 : "Connect the strap first, then mark a workout from the live stream.")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var sessionActions: some View {
        HStack(spacing: 10) {
            Button { model.startWorkout() } label: {
                Label("Start workout", systemImage: "figure.run")
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            .buttonStyle(.borderedProminent)
            .tint(StrandPalette.accent)
            .disabled(!activeConnection)
            .help("Track a workout manually — records heart rate and effort until you end it.")

            Button { model.getBattery() } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            .buttonStyle(.bordered)
            .tint(StrandPalette.accent)
            .disabled(!activeConnection)
            .help("Refresh strap battery and connection state.")
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
        // Three equal thirds can't hold all three labels at a legible size on a phone — the longest
        // ("Scan & Connect") truncates to "Scan &…" even after shrink-to-fit (#175). So on iOS the
        // primary action takes a full-width row and the two secondary actions share the row beneath;
        // macOS keeps the single three-up row, where the window is always wide enough. (#175)
        #if os(iOS)
        VStack(spacing: 12) {
            scanButton
            HStack(spacing: 12) {
                buzzButton
                disconnectButton
            }
        }
        #else
        HStack(spacing: 12) {
            scanButton
            buzzButton
            disconnectButton
        }
        #endif
    }

    private var scanButton: some View {
        Button { model.scan(model: selectedModel) } label: {
            Label(live.connected ? "Re-scan" : "Scan & Connect",
                  systemImage: "antenna.radiowaves.left.and.right")
                .lineLimit(1).minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity).padding(.vertical, 8)
        }
        .buttonStyle(.borderedProminent).tint(StrandPalette.accent)
    }

    private var buzzButton: some View {
        Button { model.buzz() } label: {
            Label("Buzz strap", systemImage: "waveform.path")
                .lineLimit(1).minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity).padding(.vertical, 8)
        }
        .buttonStyle(.bordered).tint(StrandPalette.accent)
        .disabled(!activeConnection)
        .help("Fire a test haptic buzz on the strap (requires an active strap connection)")
    }

    private var disconnectButton: some View {
        Button(role: .destructive) { model.disconnect() } label: {
            Label("Disconnect", systemImage: "xmark.circle")
                .lineLimit(1).minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity).padding(.vertical, 8)
        }
        .buttonStyle(.bordered)
        .disabled(!live.connected)
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
        var header = "NOOP strap log — \(osName)\nApp: \(v)\n\(osName): "
            + ProcessInfo.processInfo.operatingSystemVersionString + "\n"
        #if os(iOS)
        // The iOS variables that actually cause iOS issues — device/beta, Data Protection lock state
        // (#222), background-refresh, low-power, sideload + cert expiry — so a shared log carries them.
        // Reached only from the Copy/Save button taps, i.e. on the main thread.
        let diagLines = IOSDiagnostics.capture().summaryLines()
        if !diagLines.isEmpty {
            header += diagLines.joined(separator: "\n") + "\n"
        }
        #endif
        header += String(repeating: "-", count: 40) + "\n"
        return header + live.log.joined(separator: "\n")
    }

    private func copyStrapLog() {
        PlatformPasteboard.copy(strapLogText())
    }

    private func saveStrapLog() {
        FileExport.exportText(strapLogText(), suggestedName: "noop-strap-log.txt")
    }
}

// MARK: - Signal Trust tile

/// One card in the Signal Trust rail: an icon + ALL-CAPS title, a coloured value, and a one-line
/// detail. The whole card is combined into a single accessibility element so VoiceOver reads
/// "Heart rate: 62 bpm. Streaming now." rather than three disjoint fragments.
private struct SignalTrustTile: View {
    struct Model: Identifiable {
        let title: String
        let value: String
        let detail: String
        let icon: String
        let tint: Color
        var id: String { title }
    }

    let tile: Model

    var body: some View {
        NoopCard(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: tile.icon)
                        .foregroundStyle(tile.tint)
                        .frame(width: 18)
                        .accessibilityHidden(true)
                    Text(tile.title.uppercased())
                        .font(StrandFont.overline)
                        .tracking(StrandFont.overlineTracking)
                        .foregroundStyle(StrandPalette.textSecondary)
                    Spacer(minLength: 0)
                }
                Text(tile.value)
                    .font(StrandFont.headline)
                    .foregroundStyle(tile.tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                Text(tile.detail)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(minHeight: 112)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(tile.title): \(tile.value). \(tile.detail)")
    }
}
