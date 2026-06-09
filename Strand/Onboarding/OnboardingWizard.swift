import SwiftUI
import UniformTypeIdentifiers
import StrandDesign
import WhoopStore

// MARK: - OnboardingWizard
//
// A full-screen, paged onboarding + pairing flow for NOOP. Cinematic and calm:
// a dark surfaceBase substrate with a slow ambient glow, a bottom progress "thread"
// that fills as you advance, Back always available, and a forward CTA per step.
//
// Steps:
//  1 Welcome           — NOOP + "all your data, none of the cloud"
//  2 What it does      — 3 calm value slides
//  3 Bluetooth priming — explain BEFORE the OS prompt
//  4 Wear & wake       — put your strap on, make sure it's charged
//  5 Scan              — radar sweep; auto-scans, Scan retries via model.scan()
//  6 Bonding           — celebration when live.bonded (a RecoveryRing blooms in)
//  7 Profile           — age / sex / weight / height bound to ProfileStore
//  8 Import (optional)  — WHOOP / Apple Health import from the wizard
//  9 Done              — "Your thread starts here." → onFinished()
//
// Presentation is wired centrally; this view only calls onFinished() when complete.

public struct OnboardingWizard: View {

    /// Called when the user finishes (or skips to the end of) onboarding.
    public var onFinished: () -> Void

    public init(onFinished: @escaping () -> Void) {
        self.onFinished = onFinished
    }

    // NOTE: the root deliberately does NOT observe the fast-updating model/live/profile
    // env objects — doing so re-rendered the whole animated wizard on every HR tick and
    // caused flicker. Child steps observe what they need; a hidden BondWatcher (below)
    // handles the bond→celebration transition without re-rendering the root.

    private enum Step: Int, CaseIterable {
        case welcome, what, expectations, bluetooth, wear, scan, bonded, profile, importData, notifications, done

        var isFirst: Bool { self == .welcome }
        var isLast: Bool { self == .done }
    }

    @State private var step: Step = .welcome
    @State private var glow = false

    public var body: some View {
        ZStack {
            background

            VStack(spacing: 0) {
                // Top chrome: a small back affordance + a step counter.
                topBar
                    .padding(.horizontal, 36)
                    .padding(.top, 42)

                // The paged content.
                ZStack {
                    switch step {
                    case .welcome:    WelcomeStep()
                    case .what:       WhatItDoesStep()
                    case .expectations: ExpectationsStep()
                    case .bluetooth:  BluetoothStep()
                    case .wear:       WearStep()
                    case .scan:       ScanStep(advance: advance)
                    case .bonded:     BondedStep()
                    case .profile:    ProfileStep()
                    case .importData: ImportStep()
                    case .notifications: NotificationsStep()
                    case .done:       DoneStep()
                    }
                }
                .frame(maxWidth: 620, maxHeight: .infinity)
                .transition(stepTransition)
                .id(step)                       // re-runs the transition per step
                .padding(.horizontal, 40)

                // Bottom: the thread (progress) + the forward CTA.
                bottomBar
                    .padding(.horizontal, 40)
                    .padding(.top, 24)
                    .padding(.bottom, 36)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onAppear { glow = true }
        // Isolated live observation — a hidden watcher slides Scan → celebration on bond
        // without subscribing the whole wizard to per-tick updates.
        .background(BondWatcher(onBonded: handleBond))
    }

    private func handleBond() {
        if step == .scan { withAnimation(StrandMotion.hero) { step = .bonded } }
    }

    // MARK: Backgrounds

    private var background: some View {
        ZStack {
            StrandPalette.surfaceBase
            // A slow ambient bloom that breathes — the substrate feels alive.
            RadialGradient(
                colors: [StrandPalette.glowAmbient.opacity(0.55), .clear],
                center: .center,
                startRadius: 40,
                endRadius: glow ? 620 : 480
            )
            .blendMode(.plusLighter)
            .opacity(glow ? 0.9 : 0.6)
            .animation(StrandMotion.breathe, value: glow)
            .ignoresSafeArea()

            // A faint indigo wash from the top — instrument-grade depth.
            LinearGradient(
                colors: [StrandPalette.accentMuted.opacity(0.20), .clear],
                startPoint: .top,
                endPoint: .center
            )
            .ignoresSafeArea()
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack {
            if step.isFirst {
                Color.clear.frame(width: 64, height: 28)
            } else {
                Button(action: back) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                        Text("Back")
                    }
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
            }

            Spacer()

            Text("\(step.rawValue + 1) / \(Step.allCases.count)")
                .font(StrandFont.captionNumber)
                .foregroundStyle(StrandPalette.textTertiary)
        }
    }

    // MARK: Bottom bar (the thread + CTA)

    @ViewBuilder
    private var bottomBar: some View {
        VStack(spacing: 28) {
            ThreadProgress(progress: progress)
                .frame(height: 3)
                .frame(maxWidth: 620)

            HStack(spacing: 14) {
                PrimaryButton(title: ctaTitle, systemImage: ctaIcon, action: primaryAction)
                    .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: 620)
        }
    }

    private var progress: Double {
        guard Step.allCases.count > 1 else { return 1 }
        return Double(step.rawValue) / Double(Step.allCases.count - 1)
    }

    private var ctaTitle: String {
        switch step {
        case .welcome:    return "Get Started"
        case .what:       return "Continue"
        case .expectations: return "I understand"
        case .bluetooth:  return "Continue"
        case .wear:       return "I'm wearing it"
        case .scan:       return "Continue"
        case .bonded:     return "Continue"
        case .profile:    return "Save & Continue"
        case .importData: return "Continue"
        case .notifications: return "Continue"
        case .done:       return "Enter NOOP"
        }
    }

    private var ctaIcon: String? {
        switch step {
        case .done:    return "arrow.right"
        case .bonded:  return "checkmark"
        default:       return nil
        }
    }

    private func primaryAction() {
        if step.isLast {
            onFinished()
        } else {
            advance()
        }
    }

    // MARK: Navigation

    private func advance() {
        guard let next = Step(rawValue: step.rawValue + 1) else { onFinished(); return }
        withAnimation(StrandMotion.gentle) { step = next }
    }

    private func back() {
        guard let prev = Step(rawValue: step.rawValue - 1) else { return }
        withAnimation(StrandMotion.gentle) { step = prev }
    }

    private var stepTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)
        )
    }
}

/// Hidden, isolated observer — re-renders on live updates (it's just Color.clear, so no
/// visible cost) and fires `onBonded` when the strap bonds, keeping the main wizard body
/// out of the per-tick re-render path that caused flicker.
private struct BondWatcher: View {
    @EnvironmentObject private var live: LiveState
    let onBonded: () -> Void
    var body: some View {
        Color.clear.onChange(of: live.bonded) { newValue in if newValue { onBonded() } }
    }
}

// MARK: - Step 1 · Welcome

private struct WelcomeStep: View {
    @State private var appear = false
    var body: some View {
        StepShell {
            VStack(spacing: 24) {
                Spacer()
                // The mark, with a soft halo.
                ZStack {
                    Circle()
                        .fill(StrandPalette.accent)
                        .frame(width: 120, height: 120)
                        .blur(radius: 60)
                        .opacity(appear ? 0.55 : 0.0)
                        .blendMode(.plusLighter)
                    Text("NOOP")
                        .font(StrandFont.display(64))
                        .foregroundStyle(StrandPalette.textPrimary)
                        .scaleEffect(appear ? 1 : 0.92)
                        .opacity(appear ? 1 : 0)
                }
                Text("all your data, none of the cloud")
                    .font(StrandFont.title2)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .opacity(appear ? 1 : 0)
                Text("A private window into your recovery, sleep and strain — read straight from your strap, kept only on this Mac.")
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                    .opacity(appear ? 1 : 0)
                Spacer()
            }
        }
        .onAppear { withAnimation(StrandMotion.hero) { appear = true } }
    }
}

// MARK: - Step 2 · What it does

private struct WhatItDoesStep: View {
    private struct Slide: Identifiable {
        let id = UUID()
        let icon: String
        let tint: Color
        let title: String
        let body: String
    }

    private let slides: [Slide] = [
        .init(icon: "circle.dashed.inset.filled",
              tint: StrandPalette.accent,
              title: "See recovery, beautifully",
              body: "A signature ring distils HRV, resting heart rate and sleep into one calm read on whether to push or rest."),
        .init(icon: "waveform.path.ecg",
              tint: StrandPalette.accent,
              title: "Watch your heart, live",
              body: "Connect your strap and watch each beat in real time — heart rate, variability and zones as they happen."),
        .init(icon: "lock.shield",
              tint: StrandPalette.statusPositive,
              title: "Own your data, offline",
              body: "Everything lives on this Mac. No account, no sync, no cloud. Your thread is yours alone."),
    ]

    var body: some View {
        StepShell(title: "What NOOP does", subtitle: "Three quiet promises.") {
            VStack(spacing: 14) {
                ForEach(Array(slides.enumerated()), id: \.element.id) { index, slide in
                    SlideRow(slide: slide, index: index)
                }
            }
        }
    }

    private struct SlideRow: View {
        let slide: Slide
        let index: Int
        @State private var shown = false
        var body: some View {
            StrandCard {
                HStack(spacing: 16) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(slide.tint.opacity(0.14))
                            .frame(width: 46, height: 46)
                        Image(systemName: slide.icon)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(slide.tint)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(slide.title)
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text(slide.body)
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
            }
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 14)
            .onAppear {
                withAnimation(StrandMotion.gentle.delay(Double(index) * 0.10)) { shown = true }
            }
        }
    }
}

// MARK: - Step 2.5 · What to expect (independent / experimental / 5-MG framing)

private struct ExpectationsStep: View {
    @State private var shown = false
    var body: some View {
        StepShell(title: "What to expect",
                  subtitle: "A few honest words, so nothing's a surprise.") {
            VStack(spacing: 12) {
                ForEach(Array(AppChangelog.expectations.enumerated()), id: \.element.id) { index, e in
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: e.icon)
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(StrandPalette.accent)
                            .frame(width: 26)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(e.title).font(StrandFont.headline)
                                .foregroundStyle(StrandPalette.textPrimary)
                            Text(e.body).font(StrandFont.subhead)
                                .foregroundStyle(StrandPalette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(14)
                    .frame(maxWidth: 520, alignment: .leading)
                    .background(StrandPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(StrandPalette.hairline))
                    .opacity(shown ? 1 : 0)
                    .offset(y: shown ? 0 : 8)
                    .animation(StrandMotion.gentle.delay(Double(index) * 0.08), value: shown)
                }
            }
        }
        .onAppear { shown = true }
    }
}

// MARK: - Step 3 · Bluetooth priming

private struct BluetoothStep: View {
    @State private var pulse = false
    var body: some View {
        StepShell(title: "A quick word before we connect",
                  subtitle: "macOS will ask for Bluetooth in a moment.") {
            VStack(spacing: 24) {
                ZStack {
                    Circle()
                        .stroke(StrandPalette.accent.opacity(0.25), lineWidth: 2)
                        .frame(width: 120, height: 120)
                        .scaleEffect(pulse ? 1.25 : 0.9)
                        .opacity(pulse ? 0 : 0.8)
                    Circle()
                        .fill(StrandPalette.accentMuted.opacity(0.5))
                        .frame(width: 86, height: 86)
                    Image(systemName: "wave.3.right")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(StrandPalette.accent)
                }
                .frame(height: 130)

                InfoCard(
                    icon: "lock.fill",
                    tint: StrandPalette.statusPositive,
                    title: "Nothing leaves your Mac",
                    message: "NOOP talks to your strap directly over Bluetooth Low Energy. There's no server in the middle — the connection is local, and so is every reading it pulls in."
                )

                Text("When the system prompt appears, choose Allow so NOOP can find your strap.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }
        }
        .onAppear { withAnimation(StrandMotion.breathe) { pulse = true } }
    }
}

// MARK: - Step 4 · Wear & wake

private struct WearStep: View {
    var body: some View {
        StepShell(title: "Put your strap on",
                  subtitle: "And make sure it's charged.") {
            VStack(spacing: 22) {
                ZStack {
                    Circle()
                        .fill(StrandPalette.accent.opacity(0.16))
                        .frame(width: 130, height: 130)
                        .blur(radius: 24)
                    Image(systemName: "applewatch.side.right")
                        .font(.system(size: 58, weight: .regular))
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                .frame(height: 140)

                VStack(spacing: 12) {
                    Checkline(text: "Wear it snug on your wrist or bicep — sensor against skin.")
                    Checkline(text: "Give it a few minutes of charge if the battery is low.")
                    Checkline(text: "Keep it within about a metre of this Mac.")
                }
                .frame(maxWidth: 440)
            }
        }
    }
}

// MARK: - Step 5 · Scan (radar sweep + reassurance)

private struct ScanStep: View {
    let advance: () -> Void
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var live: LiveState

    @State private var scanning = false
    @State private var showHelp = false
    @State private var autoScanStarted = false

    /// Which strap to look for — shared with the Live screen via the same key.
    @AppStorage("selectedWhoopModel") private var selectedModelRaw = WhoopModel.whoop4.rawValue
    private var selectedModel: WhoopModel { WhoopModel(rawValue: selectedModelRaw) ?? .whoop4 }

    var body: some View {
        StepShell(title: "Find your strap",
                  subtitle: live.bonded ? "Bonded. You're set." : "NOOP starts looking as soon as this step appears. You can keep going while it bonds.") {
            VStack(spacing: 24) {
                RadarSweep(active: scanning && !live.bonded, bonded: live.bonded)
                    .frame(width: 220, height: 220)

                statusLine

                if !live.bonded {
                    VStack(spacing: 8) {
                        Text("Which strap?").font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textSecondary)
                        SegmentedPillControl(
                            WhoopModel.allCases,
                            selection: Binding(
                                get: { selectedModel },
                                set: { restartScan(for: $0) }
                            ),
                            label: { $0.displayName }
                        )
                    }

                    Button(action: { startScan() }) {
                        Label(scanning ? "Scanning…" : "Scan again", systemImage: "dot.radiowaves.left.and.right")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(scanning)

                    DisclosureToggle(open: $showHelp, label: "Don't see it?")

                    if showHelp { reassurance }
                }
            }
        }
        .onAppear(perform: startAutoScanIfNeeded)
        .onDisappear { scanning = false }
    }

    private var statusLine: some View {
        Group {
            if live.bonded {
                StatePill("Connected", tone: .positive)
            } else if live.connected {
                StatePill("Connecting…", tone: .warning, pulsing: true)
            } else if scanning {
                StatePill("Searching", tone: .accent, pulsing: true)
            } else {
                StatePill("Ready to scan", tone: .neutral, showsDot: false)
            }
        }
    }

    private func startScan(model scanModel: WhoopModel? = nil) {
        let modelToScan = scanModel ?? selectedModel
        scanning = true
        showHelp = false
        model.scan(model: modelToScan)
        // Surface the reassurance card if we haven't bonded after a calm beat.
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
            if !live.bonded {
                scanning = false
                withAnimation(StrandMotion.gentle) { showHelp = true }
            }
        }
    }

    private func restartScan(for newModel: WhoopModel) {
        selectedModelRaw = newModel.rawValue
        guard !live.bonded else { return }
        model.disconnect()
        startScan(model: newModel)
    }

    private func startAutoScanIfNeeded() {
        guard !autoScanStarted, !live.bonded, !live.connected else { return }
        autoScanStarted = true
        startScan()
    }

    // The calm, never-alarmist "can't find it" card.
    private var reassurance: some View {
        StrandCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(StrandPalette.statusWarning)
                    Text("Don't see it? That's normal.")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                }

                Text("WHOOP straps don't appear in macOS System Settings → Bluetooth. They advertise on a custom profile that only apps like NOOP can find — so there's nothing to pair there, and you shouldn't try.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider().overlay(StrandPalette.hairline)

                VStack(alignment: .leading, spacing: 10) {
                    Checkline(text: "It's charged and worn — the sensor needs skin contact to wake.")
                    Checkline(text: "It isn't held by the WHOOP phone app. Only one host at a time — close the app or turn off its Bluetooth.")
                    Checkline(text: "It's within about a metre of this Mac.")
                }

                Button(action: retry) {
                    Label("Try again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(SecondaryButtonStyle())
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: 480)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    private func retry() {
        withAnimation(StrandMotion.gentle) { showHelp = false }
        startScan()
    }
}

// MARK: - Step 6 · Bonding celebration

private struct BondedStep: View {
    @EnvironmentObject private var live: LiveState
    @State private var bloom = false
    var body: some View {
        StepShell {
            VStack(spacing: 26) {
                Spacer()
                ZStack {
                    Circle()
                        .fill(StrandPalette.statusPositive)
                        .frame(width: 160, height: 160)
                        .blur(radius: 70)
                        .opacity(bloom ? 0.5 : 0.0)
                        .blendMode(.plusLighter)
                    // A ring materialises — a taste of the signature component.
                    RecoveryRing(score: 100, supporting: nil, diameter: 200, lineWidth: 14, showsLabel: false)
                        .scaleEffect(bloom ? 1 : 0.7)
                        .opacity(bloom ? 1 : 0)
                    Image(systemName: "checkmark")
                        .font(.system(size: 44, weight: .bold))
                        .foregroundStyle(StrandPalette.statusPositive)
                        .scaleEffect(bloom ? 1 : 0.4)
                        .opacity(bloom ? 1 : 0)
                }
                .frame(height: 210)

                VStack(spacing: 8) {
                    Text("You're connected.")
                        .font(StrandFont.title1)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text(batteryLine)
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                .opacity(bloom ? 1 : 0)
                Spacer()
            }
        }
        .onAppear { withAnimation(StrandMotion.hero) { bloom = true } }
    }

    private var batteryLine: String {
        if let pct = live.batteryPct {
            return "Your strap is bonded · \(Int(pct))% battery."
        }
        return "Your strap is bonded and ready to stream."
    }
}

// MARK: - Step 7 · Profile

private struct ProfileStep: View {
    @EnvironmentObject private var profile: ProfileStore

    private let sexes: [(String, String)] = [
        ("male", "Male"), ("female", "Female"), ("nonbinary", "Other")
    ]

    var body: some View {
        StepShell(title: "About you",
                  subtitle: "So your zones, calories and baselines are accurate.") {
            VStack(spacing: 16) {
                StrandCard {
                    VStack(spacing: 18) {
                        Stepper(value: $profile.age, in: 13...100) {
                            FieldRow(label: "Age", value: "\(profile.age) yrs")
                        }

                        Divider().overlay(StrandPalette.hairline)

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Sex").strandOverline()
                            Picker("Sex", selection: $profile.sex) {
                                ForEach(sexes, id: \.0) { key, label in
                                    Text(label).tag(key)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                        }

                        Divider().overlay(StrandPalette.hairline)

                        // Steppers, not sliders — matches the Age row above and the macOS Settings
                        // profile editor (same ranges/steps), so every numeric profile field is
                        // consistent across onboarding and Settings on both platforms.
                        Stepper(value: $profile.weightKg, in: 30...250, step: 0.5) {
                            FieldRow(label: "Weight", value: "\(String(format: "%.1f", profile.weightKg)) kg")
                        }

                        Divider().overlay(StrandPalette.hairline)

                        Stepper(value: $profile.heightCm, in: 120...230, step: 1) {
                            FieldRow(label: "Height", value: "\(String(format: "%.0f", profile.heightCm)) cm")
                        }
                    }
                }

                HStack(spacing: 8) {
                    Image(systemName: "bolt.heart")
                        .foregroundStyle(StrandPalette.accent)
                    Text("Estimated max heart rate · \(profile.hrMax) bpm")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
    }
}

// MARK: - Step 8 · Import (optional)

private struct ImportStep: View {
    @EnvironmentObject private var model: AppModel
    @State private var showingImporter = false
    @State private var importTarget: ImportTarget = .whoop

    var body: some View {
        StepShell(title: "Bring your history",
                  subtitle: "Optional — import now, or continue and return to Data Sources later.") {
            VStack(spacing: 18) {
                ZStack {
                    Circle()
                        .fill(StrandPalette.accentMuted.opacity(0.45))
                        .frame(width: 96, height: 96)
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 40, weight: .regular))
                        .foregroundStyle(StrandPalette.accent)
                }

                InfoCard(
                    icon: "clock.arrow.circlepath",
                    tint: StrandPalette.accent,
                    title: "History fills the dashboard immediately",
                    message: "A WHOOP export backfills recovery, strain, sleep and workouts. Apple Health can add HR, HRV, sleep, SpO₂, steps, workouts and weight."
                )

                StrandCard {
                    VStack(spacing: 10) {
                        ImportActionButton(
                            title: model.isImporting(.whoop) ? "Importing…" : "Import WHOOP export",
                            systemImage: "tray.and.arrow.down",
                            disabled: model.hasActiveImport
                        ) {
                            presentImporter(.whoop)
                        }
                        ImportActionButton(
                            title: model.isImporting(.appleHealth) ? "Working…" : "Import Apple Health export",
                            systemImage: "heart.fill",
                            disabled: model.hasActiveImport
                        ) {
                            presentImporter(.appleHealth)
                        }
                    }
                }
                .frame(maxWidth: 480)

                if model.hasActiveImport {
                    ProgressView()
                        .controlSize(.small)
                        .tint(StrandPalette.accent)
                }

                // Show the summary for the source the user last imported, styled off the typed
                // failure flag (not a substring match) so real errors read as warnings.
                if let summary = lastSummary {
                    Text(summary)
                        .font(StrandFont.subhead)
                        .foregroundStyle(model.importFailed(importKind) ? StrandPalette.statusWarning : StrandPalette.statusPositive)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 460)
                }
            }
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: importTarget.allowedContentTypes,
            allowsMultipleSelection: false
        ) { result in
            handleImportResult(result, for: importTarget)
        }
    }

    /// The AppModel source kind matching the last-chosen import target.
    private var importKind: DataSourceImportKind {
        switch importTarget {
        case .whoop: return .whoop
        case .appleHealth: return .appleHealth
        }
    }

    /// The summary for the source the user last imported in this step.
    private var lastSummary: String? {
        switch importTarget {
        case .whoop: return model.whoopImportSummary
        case .appleHealth: return model.appleHealthImportSummary
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
        }
    }

    private enum ImportTarget {
        case whoop
        case appleHealth

        var allowedContentTypes: [UTType] {
            switch self {
            case .whoop:
                return [.zip, .folder]
            case .appleHealth:
                return [.zip, .xml, .folder]
            }
        }
    }
}

// MARK: - Step 9 · Notifications (wrist alerts priming)

private struct NotificationsStep: View {
    @State private var pulse = false
    var body: some View {
        StepShell(title: "Stay in the loop",
                  subtitle: "NOOP can tap your wrist when your Mac needs you — no glance at the screen required.") {
            VStack(spacing: 24) {
                ZStack {
                    Circle()
                        .stroke(StrandPalette.accent.opacity(0.25), lineWidth: 2)
                        .frame(width: 120, height: 120)
                        .scaleEffect(pulse ? 1.2 : 0.9)
                        .opacity(pulse ? 0 : 0.8)
                    Circle()
                        .fill(StrandPalette.accentMuted.opacity(0.5))
                        .frame(width: 86, height: 86)
                    Image(systemName: "bell.badge")
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundStyle(StrandPalette.accent)
                }
                .frame(height: 130)

                InfoCard(
                    icon: "applewatch.radiowaves.left.and.right",
                    tint: StrandPalette.statusPositive,
                    title: "A buzz, not a banner",
                    message: "When the Mac apps you choose send a notification, NOOP taps your strap — Slack, Calendar, Messages, whatever matters. Everything stays on this Mac."
                )

                VStack(spacing: 12) {
                    Checkline(text: "Pick which apps reach your wrist in Settings → Notifications.")
                    Checkline(text: "Strain nudges and your smart alarm tap your wrist the same way.")
                }
                .frame(maxWidth: 460)
            }
        }
        .onAppear { withAnimation(StrandMotion.breathe) { pulse = true } }
    }
}

// MARK: - Step 10 · Done

private struct DoneStep: View {
    @State private var appear = false
    var body: some View {
        StepShell {
            VStack(spacing: 22) {
                Spacer()
                ZStack {
                    Circle()
                        .fill(StrandPalette.recovery100)
                        .frame(width: 120, height: 120)
                        .blur(radius: 64)
                        .opacity(appear ? 0.5 : 0)
                        .blendMode(.plusLighter)
                    Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
                        .font(.system(size: 52, weight: .light))
                        .foregroundStyle(
                            LinearGradient(gradient: StrandPalette.recoveryGradient,
                                           startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                        .scaleEffect(appear ? 1 : 0.8)
                        .opacity(appear ? 1 : 0)
                }
                .frame(height: 130)

                VStack(spacing: 10) {
                    Text("Your thread starts here.")
                        .font(StrandFont.title1)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("Every beat, every night, every day — woven into one quiet picture of you. Welcome to NOOP.")
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }
                .opacity(appear ? 1 : 0)
                Spacer()
            }
        }
        .onAppear { withAnimation(StrandMotion.hero) { appear = true } }
    }
}

// MARK: - Step shell (shared layout for each page)

private struct StepShell<Content: View>: View {
    var title: String? = nil
    var subtitle: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 20) {
                if title != nil || subtitle != nil {
                    VStack(spacing: 8) {
                        if let title {
                            Text(title)
                                .font(StrandFont.title1)
                                .foregroundStyle(StrandPalette.textPrimary)
                                .multilineTextAlignment(.center)
                        }
                        if let subtitle {
                            Text(subtitle)
                                .font(StrandFont.body)
                                .foregroundStyle(StrandPalette.textSecondary)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .padding(.top, 8)
                }
                content()
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        }
    }
}

// MARK: - Radar sweep

private struct RadarSweep: View {
    var active: Bool
    var bonded: Bool
    @State private var angle: Double = 0
    @State private var ping = false

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            ZStack {
                // Concentric rings.
                ForEach(1...3, id: \.self) { i in
                    Circle()
                        .stroke(StrandPalette.hairline.opacity(0.7), lineWidth: 1)
                        .frame(width: size * Double(i) / 3, height: size * Double(i) / 3)
                }
                // Cross hairs.
                Path { p in
                    p.move(to: CGPoint(x: size / 2, y: 0)); p.addLine(to: CGPoint(x: size / 2, y: size))
                    p.move(to: CGPoint(x: 0, y: size / 2)); p.addLine(to: CGPoint(x: size, y: size / 2))
                }
                .stroke(StrandPalette.hairline.opacity(0.5), lineWidth: 1)

                // The sweeping wedge.
                if active {
                    sweepWedge(size: size)
                        .rotationEffect(.degrees(angle))
                }

                // Center node — accent while searching, mint when bonded.
                Circle()
                    .fill(bonded ? StrandPalette.recovery100 : StrandPalette.accent)
                    .frame(width: 14, height: 14)
                    .shadow(color: (bonded ? StrandPalette.recovery100 : StrandPalette.accent).opacity(0.8),
                            radius: ping ? 10 : 4)

                // A discovered "blip" once bonded.
                if bonded {
                    Circle()
                        .fill(StrandPalette.statusPositive)
                        .frame(width: 12, height: 12)
                        .shadow(color: StrandPalette.statusPositive.opacity(0.9), radius: 8)
                        .position(x: size * 0.70, y: size * 0.36)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(width: size, height: size)
        }
        .onAppear {
            if active { startSweep() }
            ping = true
        }
        .onChange(of: active) { isActive in
            if isActive { startSweep() }
        }
        .animation(StrandMotion.breathe, value: ping)
    }

    private func sweepWedge(size: CGFloat) -> some View {
        let radius = size / 2
        return AngularGradient(
            gradient: Gradient(colors: [StrandPalette.accent.opacity(0.0),
                                        StrandPalette.accent.opacity(0.45)]),
            center: .center,
            startAngle: .degrees(-50),
            endAngle: .degrees(0)
        )
        .mask(
            Path { p in
                let c = CGPoint(x: radius, y: radius)
                p.move(to: c)
                p.addArc(center: c, radius: radius,
                         startAngle: .degrees(-50), endAngle: .degrees(0), clockwise: false)
                p.closeSubpath()
            }
        )
        .frame(width: size, height: size)
        .blendMode(.plusLighter)
    }

    private func startSweep() {
        angle = 0
        withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: false)) {
            angle = 360
        }
    }
}

// MARK: - The bottom "thread" progress

private struct ThreadProgress: View {
    var progress: Double           // 0...1
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(StrandPalette.hairline)
                Capsule()
                    .fill(LinearGradient(gradient: StrandPalette.recoveryGradient,
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(6, geo.size.width * progress))
                    .shadow(color: StrandPalette.recovery078.opacity(0.6), radius: 6)
                    .animation(StrandMotion.gentle, value: progress)
            }
        }
    }
}

// MARK: - Reusable pieces

private struct InfoCard: View {
    let icon: String
    let tint: Color
    let title: String
    let message: String
    var body: some View {
        StrandCard {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(tint.opacity(0.14))
                        .frame(width: 40, height: 40)
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(tint)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text(message)
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: 480)
    }
}

private struct Checkline: View {
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(StrandPalette.statusPositive)
                .padding(.top, 1)
            Text(text)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

private struct FieldRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack {
            Text(label).strandOverline()
            Spacer()
            Text(value)
                .font(StrandFont.bodyNumber)
                .foregroundStyle(StrandPalette.textPrimary)
        }
    }
}

private struct DisclosureToggle: View {
    @Binding var open: Bool
    let label: String
    var body: some View {
        Button {
            withAnimation(StrandMotion.gentle) { open.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: open ? "chevron.up" : "chevron.down")
                Text(label)
            }
            .font(StrandFont.subhead)
            .foregroundStyle(StrandPalette.accent)
        }
        .buttonStyle(.plain)
    }
}

private struct ImportActionButton: View {
    let title: String
    let systemImage: String
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 18)
                Text(title)
                    .font(StrandFont.subhead.weight(.semibold))
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(SecondaryButtonStyle())
        .disabled(disabled)
        .opacity(disabled ? 0.55 : 1)
    }
}

// MARK: - Button styles

private struct PrimaryButton: View {
    let title: String
    var systemImage: String? = nil
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title).font(StrandFont.headline)
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 14, weight: .semibold))
                }
            }
        }
        .buttonStyle(PrimaryButtonStyle())
    }
}

private struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity)
            .foregroundStyle(Color.white)
            .padding(.vertical, 14)
            .padding(.horizontal, 20)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(configuration.isPressed ? StrandPalette.accentHover : StrandPalette.accent)
            )
            .shadow(color: StrandPalette.accent.opacity(0.4), radius: 12, y: 4)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(StrandMotion.interactive, value: configuration.isPressed)
    }
}

private struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(StrandFont.subhead.weight(.semibold))
            .foregroundStyle(StrandPalette.textPrimary)
            .padding(.vertical, 11)
            .padding(.horizontal, 18)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(StrandPalette.surfaceOverlay)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(configuration.isPressed ? StrandPalette.hairlineStrong : StrandPalette.hairline, lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(StrandMotion.interactive, value: configuration.isPressed)
    }
}

// MARK: - Preview

#if DEBUG
private struct OnboardingPreview: View {
    @StateObject private var model = AppModel()
    var body: some View {
        OnboardingWizard(onFinished: {})
            .environmentObject(model)
            .environmentObject(model.live)
            .environmentObject(model.profile)
            .frame(width: 1100, height: 780)
            .preferredColorScheme(.dark)
    }
}

#Preview("Onboarding") { OnboardingPreview() }
#endif
