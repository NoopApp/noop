import SwiftUI
import Foundation
import StrandDesign

/// Silent haptic HIIT interval timer.
///
/// Train hands-free: the strap buzzes every transition so you never have to look
/// at the screen. Strong triple-buzz at the start of each WORK block, a short
/// single buzz into REST, a 3-2-1 tick on the last seconds of every phase, and a
/// long 5-loop buzz when the whole session finishes. With no strap bonded it still
/// works as a big glanceable visual timer (just without haptics).
struct IntervalTimerView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var live: LiveState

    // MARK: Config (persisted only in-view)

    @State private var workSeconds: Int = 30
    @State private var restSeconds: Int = 15
    @State private var rounds: Int = 8

    // MARK: Run state

    private enum Phase { case work, rest, done
        var label: String {
            switch self {
            case .work: return "WORK"
            case .rest: return "REST"
            case .done: return "DONE"
            }
        }
    }

    @State private var phase: Phase = .work
    @State private var currentRound: Int = 1
    @State private var remaining: Int = 30          // seconds left in the current phase
    @State private var running: Bool = false
    @State private var elapsed: Int = 0             // total elapsed seconds across the session

    // MARK: iPhone haptics (iOS only)
    //
    // The strap buzz (`buzz`) only fires when a strap is bonded; on iPhone the device in
    // the user's hand has a Taptic Engine, so we mirror every transition cue with native
    // haptics that fire regardless of bond state. A monotonically-bumped Int token drives a
    // single `.sensoryFeedback`, so even a repeated cue (the 3-2-1 tick three seconds running)
    // re-fires because the trigger value always changes.
    #if os(iOS)
    private enum HapticCue { case work, rest, tick, done }
    @State private var lastHaptic: HapticCue = .work
    @State private var hapticTick: Int = 0
    #endif

    // 1Hz tick.
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    // MARK: Derived

    private var phaseDuration: Int {
        switch phase {
        case .work: return max(1, workSeconds)
        case .rest: return max(1, restSeconds)
        case .done: return 1
        }
    }

    /// 0...1 progress through the current interval.
    private var intervalProgress: Double {
        guard phaseDuration > 0 else { return 0 }
        let done = Double(phaseDuration - remaining)
        return min(1, max(0, done / Double(phaseDuration)))
    }

    /// Total planned session length in seconds (work*rounds + rest*(rounds-1)).
    private var totalPlanned: Int {
        guard rounds > 0 else { return 0 }
        return workSeconds * rounds + restSeconds * max(0, rounds - 1)
    }

    private var phaseColor: Color {
        switch phase {
        case .work: return StrandPalette.accent
        case .rest: return StrandPalette.metricCyan
        case .done: return StrandPalette.statusPositive
        }
    }

    private var phaseTone: StrandTone {
        switch phase {
        case .work: return .accent
        case .rest: return .neutral
        case .done: return .positive
        }
    }

    private var isFinished: Bool { phase == .done }

    // MARK: Body

    var body: some View {
        ScreenScaffold(title: "Interval Timer",
                       subtitle: "Silent haptic HIIT — the strap buzzes the transitions") {
            VStack(alignment: .leading, spacing: 20) {
                statusRow
                stageCard
                overviewCard
                configCard
            }
        }
        .onReceive(ticker) { _ in tick() }
        .onChange(of: workSeconds) { _ in if !running { resetToStart() } }
        .onChange(of: restSeconds) { _ in if !running { resetToStart() } }
        .onChange(of: rounds) { _ in
            if currentRound > rounds { currentRound = rounds }
            if !running { resetToStart() }
        }
        .onAppear { if remaining == 0 { resetToStart() } }
        // Keep the screen awake while a session runs (no-op on macOS). One onChange covers
        // every running→false transition — manual pause, auto-finish, and reset — and the
        // onDisappear is a safety net so navigating away mid-run never leaves the idle timer
        // disabled app-wide.
        .onChange(of: running) { ScreenIdle.keepAwake($0) }
        .onDisappear { ScreenIdle.keepAwake(false) }
        #if os(iOS)
        // iPhone haptics: one modifier emits a different feel per cue, re-firing on every
        // token bump. Fires regardless of strap bond so the timer is fully usable unstrapped.
        .sensoryFeedback(trigger: hapticTick) { _, _ in
            switch lastHaptic {
            case .work: return .impact(weight: .heavy)      // strong cue into WORK
            case .rest: return .impact(weight: .light)      // soft cue into REST
            case .tick: return .selection                   // 3-2-1 countdown tick
            case .done: return .success                     // session complete
            }
        }
        #endif
    }

    // MARK: Status row

    private var statusRow: some View {
        HStack(spacing: 10) {
            if live.bonded {
                StatePill("Buzz cues on", tone: .positive)
            } else {
                StatePill("Connect strap for buzz cues", tone: .warning)
            }
            Spacer()
            if running {
                StatePill("Running", tone: .accent, pulsing: true)
            } else if isFinished {
                StatePill("Complete", tone: .positive)
            } else {
                StatePill("Paused", tone: .neutral, showsDot: false)
            }
        }
    }

    // MARK: Stage card — the big glanceable face

    private var stageCard: some View {
        StrandCard(padding: 24) {
            VStack(spacing: 18) {
                // Phase + round line
                HStack(alignment: .firstTextBaseline) {
                    Text(phase.label)
                        .font(StrandFont.number(34, weight: .heavy))
                        .tracking(2)
                        .foregroundStyle(phaseColor)
                        .shadow(color: phaseColor.opacity(0.4), radius: 12)
                    Spacer()
                    HStack(spacing: 6) {
                        Text("ROUND").strandOverline()
                        Text("\(min(currentRound, rounds))")
                            .font(StrandFont.number(20))
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text("/ \(rounds)")
                            .font(StrandFont.number(20))
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                }

                // The ring + countdown
                ZStack {
                    intervalRing
                    VStack(spacing: 2) {
                        Text(isFinished ? "✓" : "\(remaining)")
                            .font(StrandFont.number(96, weight: .bold))
                            .foregroundStyle(isFinished ? StrandPalette.statusPositive : StrandPalette.textPrimary)
                            .contentTransition(.numericText())
                            .animation(.snappy, value: remaining)
                            .monospacedDigit()
                        Text(isFinished ? "SESSION DONE" : "SECONDS")
                            .font(StrandFont.footnote)
                            .tracking(1.2)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                }
                .frame(height: 260)
                .frame(maxWidth: .infinity)

                controls

                if !live.bonded {
                    Label("Bond your strap on the Live screen to feel the transitions hands-free.",
                          systemImage: "wave.3.right")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
        }
    }

    private var intervalRing: some View {
        ZStack {
            Circle()
                .stroke(StrandPalette.surfaceInset, lineWidth: 18)
            Circle()
                .stroke(StrandPalette.hairline, lineWidth: 1)
                .padding(8)
            Circle()
                .trim(from: 0, to: isFinished ? 1 : intervalProgress)
                .stroke(
                    AngularGradient(
                        gradient: Gradient(colors: [phaseColor.opacity(0.6), phaseColor]),
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: 18, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .shadow(color: phaseColor.opacity(0.5), radius: 8)
                .animation(.linear(duration: 0.9), value: intervalProgress)
        }
        .frame(width: 240, height: 240)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button {
                if isFinished { resetToStart() }
                toggleRunning()
            } label: {
                Label(running ? "Pause" : (isFinished ? "Restart" : "Start"),
                      systemImage: running ? "pause.fill" : "play.fill")
                    .font(StrandFont.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(StrandPalette.accent)

            Button {
                stopAndReset()
            } label: {
                Label("Reset", systemImage: "arrow.counterclockwise")
                    .font(StrandFont.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.bordered)
            .tint(StrandPalette.textSecondary)
            .disabled(!running && remaining == phaseDuration && currentRound == 1 && phase == .work && elapsed == 0)
        }
    }

    // MARK: Overview card — elapsed / planned

    private var overviewCard: some View {
        StrandCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Session").strandOverline()
                    Spacer()
                    Text("\(timeString(elapsed)) / \(timeString(totalPlanned))")
                        .font(StrandFont.bodyNumber)
                        .foregroundStyle(StrandPalette.textPrimary)
                }

                // Slim total-session progress bar
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(StrandPalette.surfaceInset)
                        Capsule()
                            .fill(StrandPalette.accent)
                            .frame(width: geo.size.width * sessionProgress)
                            .animation(.linear(duration: 0.9), value: sessionProgress)
                    }
                }
                .frame(height: 8)

                HStack(spacing: 0) {
                    overviewStat("Work", "\(workSeconds)s", StrandPalette.accent)
                    overviewStat("Rest", "\(restSeconds)s", StrandPalette.metricCyan)
                    overviewStat("Rounds", "\(rounds)", StrandPalette.textPrimary)
                    overviewStat("Remaining", timeString(max(0, totalPlanned - elapsed)), StrandPalette.textSecondary)
                }
            }
        }
    }

    private var sessionProgress: Double {
        guard totalPlanned > 0 else { return 0 }
        return min(1, max(0, Double(elapsed) / Double(totalPlanned)))
    }

    private func overviewStat(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased()).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
            Text(value).font(StrandFont.number(18)).foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Config card

    private var configCard: some View {
        StrandCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("Configure").strandOverline()
                configStepper(title: "Work", unit: "sec", value: $workSeconds,
                              range: 5...600, step: 5, tint: StrandPalette.accent)
                Divider().overlay(StrandPalette.hairline)
                configStepper(title: "Rest", unit: "sec", value: $restSeconds,
                              range: 5...600, step: 5, tint: StrandPalette.metricCyan)
                Divider().overlay(StrandPalette.hairline)
                configStepper(title: "Rounds", unit: nil, value: $rounds,
                              range: 1...30, step: 1, tint: StrandPalette.textPrimary)
            }
            .disabled(running)
            .opacity(running ? StrandPalette.disabledOpacity : 1)
        }
    }

    private func configStepper(title: String, unit: String?, value: Binding<Int>,
                               range: ClosedRange<Int>, step: Int, tint: Color) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                Text("\(range.lowerBound)–\(range.upperBound)\(unit.map { " \($0)" } ?? "") · step \(step)")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
            }
            Spacer()
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(value.wrappedValue)")
                    .font(StrandFont.number(24))
                    .foregroundStyle(tint)
                    .frame(minWidth: 44, alignment: .trailing)
                if let unit {
                    Text(unit).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                }
            }
            Stepper("", value: value, in: range, step: step)
                .labelsHidden()
                .accessibilityLabel("\(title) \(unit ?? "")")
        }
    }

    // MARK: Timer logic

    private func tick() {
        guard running, !isFinished else { return }

        // Optional 3-2-1 countdown tick on the last seconds of the current phase.
        if remaining <= 3 && remaining >= 1 {
            buzz(loops: 1)
            #if os(iOS)
            haptic(.tick)
            #endif
        }

        if remaining > 1 {
            remaining -= 1
            elapsed += 1
            return
        }

        // remaining hits 0 — advance to the next phase/round.
        elapsed += 1
        advancePhase()
    }

    private func advancePhase() {
        switch phase {
        case .work:
            if currentRound >= rounds {
                // Last work block finished → session complete.
                finishSession()
            } else {
                // Into rest.
                phase = .rest
                remaining = max(1, restSeconds)
                buzz(loops: 1)              // short cue into rest
                #if os(iOS)
                haptic(.rest)
                #endif
            }
        case .rest:
            // Rest done → next round's work.
            currentRound += 1
            phase = .work
            remaining = max(1, workSeconds)
            buzz(loops: 3)                  // strong cue into work
            #if os(iOS)
            haptic(.work)
            #endif
        case .done:
            break
        }
    }

    private func finishSession() {
        withAnimation(.snappy) {
            phase = .done
            remaining = 0
            running = false
        }
        buzz(loops: 5)                      // long completion cue
        #if os(iOS)
        haptic(.done)
        #endif
    }

    private func toggleRunning() {
        if isFinished { return }
        if running {
            running = false
        } else {
            // Starting fresh from a clean reset → fire the opening WORK cue.
            let startingFresh = (phase == .work && currentRound == 1
                                 && remaining == max(1, workSeconds) && elapsed == 0)
            running = true
            if startingFresh {
                buzz(loops: 3)
                #if os(iOS)
                haptic(.work)
                #endif
            }
        }
    }

    private func stopAndReset() {
        running = false
        resetToStart()
    }

    /// Reset run state back to round 1 / start of work, using current config.
    private func resetToStart() {
        phase = .work
        currentRound = 1
        remaining = max(1, workSeconds)
        elapsed = 0
    }

    /// Fire a strap buzz (no-op when not bonded — `buzz` already guards, but we
    /// also skip the call entirely so this stays a pure visual tool when unbonded).
    private func buzz(loops: UInt8) {
        guard live.bonded else { return }
        model.buzz(loops: loops)
    }

    #if os(iOS)
    /// Fire an iPhone haptic cue. Additive to `buzz` and unguarded by bond state, so the
    /// timer gives tactile feedback even with no strap. Bumping the token re-triggers
    /// `.sensoryFeedback` even when the same cue repeats.
    private func haptic(_ cue: HapticCue) {
        lastHaptic = cue
        hapticTick &+= 1
    }
    #endif

    // MARK: Formatting

    private func timeString(_ seconds: Int) -> String {
        let s = max(0, seconds)
        let m = s / 60
        let r = s % 60
        return String(format: "%d:%02d", m, r)
    }
}

#if DEBUG
#Preview("Interval Timer") {
    IntervalTimerView()
        .environmentObject(AppModel())
        .environmentObject(LiveState())
        .frame(width: 720, height: 900)
        .preferredColorScheme(.dark)
}
#endif
