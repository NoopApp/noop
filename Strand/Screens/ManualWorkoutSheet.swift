import SwiftUI
import StrandDesign
import WhoopStore

/// Retroactive add/edit of a manual workout (source "manual" under the strap deviceId —
/// the same place v1.67's live-tracked sessions land, so it surfaces with no read change).
/// Validation lives in WorkoutSource.buildManualRow (pure, mirrored on Android); strain and
/// zones stay nil — no captured HR window exists for a retro entry, and APPROXIMATE figures
/// are never fabricated.
struct ManualWorkoutSheet: View {
    @EnvironmentObject var repo: Repository
    @Environment(\.dismiss) private var dismiss
    let editing: WorkoutRow?            // nil = add
    let onSaved: () -> Void

    /// Sports offered by the sheet — names chosen to hit sportIcon's mappings. Sport names
    /// are DATA (stored in the workout table), not UI literals — they stay English.
    static let sports: [String] = ["Running", "Cycling", "Walking", "Hiking", "Swimming",
        "Strength Training", "Yoga", "Pilates", "Rowing", "HIIT", "Boxing", "Tennis",
        "Soccer", "Basketball", "Skiing", "Climbing", "Dance", "Golf", "Workout"]

    @State private var start: Date
    @State private var durationMin: Int
    @State private var sport: String
    @State private var avgHrText: String
    @State private var kcalText: String

    init(editing: WorkoutRow?, onSaved: @escaping () -> Void) {
        self.editing = editing
        self.onSaved = onSaved
        _start = State(initialValue: editing.map { Date(timeIntervalSince1970: TimeInterval($0.startTs)) }
            ?? Date().addingTimeInterval(-3600))
        _durationMin = State(initialValue: editing?.durationS.map { Int($0 / 60) } ?? 45)
        _sport = State(initialValue: editing?.sport ?? "Running")
        _avgHrText = State(initialValue: editing?.avgHr.map(String.init) ?? "")
        _kcalText = State(initialValue: editing?.energyKcal.map { String(Int($0.rounded())) } ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(editing == nil ? "Add workout" : "Edit workout")
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textPrimary)

            DatePicker("Start time", selection: $start, in: ...Date())

            Stepper(value: $durationMin, in: 1...1440, step: 5) {
                HStack {
                    Text("Duration")
                    Spacer()
                    Text("\(durationMin) min" as String)
                        .font(StrandFont.number(13, weight: .regular))
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }

            Picker("Sport", selection: $sport) {
                ForEach(Self.sports, id: \.self) { Text($0 as String) }
            }

            TextField("Avg HR (optional)", text: $avgHrText)
                .textFieldStyle(.roundedBorder)
            TextField("Calories (optional)", text: $kcalText)
                .textFieldStyle(.roundedBorder)

            Text("Strain isn't estimated for retroactive entries — there is no captured heart-rate window to base it on.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(builtRow == nil)
            }
        }
        .padding(24)
        .frame(width: 380)
    }

    /// Live-validated row — nil keeps Save disabled. Empty optional fields parse to nil.
    private var builtRow: WorkoutRow? {
        WorkoutSource.buildManualRow(start: start, durationMin: durationMin, sport: sport,
                                     avgHr: Int(avgHrText.trimmingCharacters(in: .whitespaces)),
                                     energyKcal: Double(kcalText.trimmingCharacters(in: .whitespaces)))
    }

    private func save() {
        guard let row = builtRow else { return }
        Task {
            await repo.saveManualWorkout(row, replacing: editing)
            onSaved()
            dismiss()
        }
    }
}
