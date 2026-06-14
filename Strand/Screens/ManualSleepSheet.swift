import SwiftUI
import StrandDesign
import WhoopStore

// MARK: - Manual sleep sheet (#281)
//
// Add a sleep the strap missed — a nap, or a night recorded elsewhere. Three inputs: when you went to
// bed, when you woke, and how much of that you were actually asleep (pre-filled to the whole window).
// Validated by SleepSource.buildManualSession (the same honest rules the merge path uses). We store a
// COARSE stage summary only (asleep → light, the rest → awake) and never fabricate a deep/REM
// architecture we didn't measure — the sheet says so. Mirrors ManualWorkoutSheet's UX exactly.

struct ManualSleepSheet: View {
    /// Called with the validated session once the user taps Add.
    let onSave: (_ session: CachedSleepSession) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var bed: Date
    @State private var wake: Date
    @State private var asleepMin: Int

    init(onSave: @escaping (_ session: CachedSleepSession) -> Void) {
        self.onSave = onSave
        // Default to a plausible last-night window (23:00 → 07:00) ending no later than now.
        let now = Date()
        let defaultWake = min(now, Calendar.current.date(bySettingHour: 7, minute: 0, second: 0, of: now) ?? now)
        let defaultBed = defaultWake.addingTimeInterval(-8 * 3600)
        _bed = State(initialValue: defaultBed)
        _wake = State(initialValue: defaultWake)
        _asleepMin = State(initialValue: 8 * 60)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            VStack(alignment: .leading, spacing: 14) {
                field("Bedtime") {
                    DatePicker("", selection: $bed, in: ...Date(),
                               displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden()
                        .accessibilityLabel("Bed date and time")
                }
                field("Wake") {
                    DatePicker("", selection: $wake, in: ...Date(),
                               displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden()
                        .accessibilityLabel("Wake date and time")
                }
                field("Asleep") {
                    HStack(spacing: 12) {
                        Stepper(value: $asleepMin, in: 0...(18 * 60), step: 15) {
                            Text(durationLabel(asleepMin))
                                .font(StrandFont.bodyNumber)
                                .foregroundStyle(StrandPalette.textPrimary)
                        }
                        .accessibilityLabel("Time asleep in minutes")
                        Spacer()
                        Text("of \(durationLabel(inBedMin)) in bed")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                }
            }
            noteRow("Stages aren't measured for an added sleep — it's logged as time asleep only.")
            if let validationNote { warnRow(validationNote) }
            footer
        }
        .padding(24)
        .frame(width: 420)
        .background(StrandPalette.surfaceOverlay)
        // Keep "asleep" within the in-bed window as the user drags the pickers.
        .onChange(of: bed) { _ in clampAsleep() }
        .onChange(of: wake) { _ in clampAsleep() }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Add Sleep")
                .font(StrandFont.title2)
                .foregroundStyle(StrandPalette.textPrimary)
            Text("Log a nap or a night the strap missed.")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
        }
    }

    private var footer: some View {
        HStack {
            Button("Cancel") { dismiss() }
                .buttonStyle(.plain)
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textSecondary)
            Spacer()
            Button("Add") { save() }
                .buttonStyle(.borderedProminent)
                .tint(StrandPalette.accent)
                .disabled(builtSession == nil)
                .accessibilityLabel("Add sleep")
        }
    }

    private func field<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).strandOverline()
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func noteRow(_ text: String) -> some View {
        Text(text)
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(text)
    }

    private func warnRow(_ text: String) -> some View {
        Text(text)
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.statusWarning)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(text)
    }

    // MARK: - Validation / build

    private var inBedMin: Int { max(0, Int(wake.timeIntervalSince(bed) / 60)) }

    private func durationLabel(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        if h > 0 && m > 0 { return "\(h)h \(m)m" }
        if h > 0 { return "\(h)h" }
        return "\(m)m"
    }

    private func clampAsleep() {
        if asleepMin > inBedMin { asleepMin = inBedMin }
    }

    /// The validated session, or nil when the inputs can't make an honest one (drives the disabled Add
    /// and the inline note). Built through the same SleepSource.buildManualSession the merge path trusts.
    private var builtSession: CachedSleepSession? {
        SleepSource.buildManualSession(start: bed, end: wake, asleepMin: Double(asleepMin))
    }

    private var validationNote: String? {
        guard builtSession == nil else { return nil }
        if wake <= bed { return "Wake must be after bedtime." }
        if wake > Date() || bed > Date() { return "Times can't be in the future." }
        if inBedMin > 18 * 60 { return "A single sleep can't be longer than 18 hours." }
        return "Check the times and try again."
    }

    private func save() {
        guard let session = builtSession else { return }
        onSave(session)
        dismiss()
    }
}

#if DEBUG
#Preview("Add Sleep") {
    ManualSleepSheet { _ in }
        .preferredColorScheme(.dark)
}
#endif
