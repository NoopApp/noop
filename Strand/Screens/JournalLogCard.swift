import SwiftUI
import StrandDesign
import WhoopStore

/// Native journal logging — yes/no chips for the merged behaviour catalog plus a custom-
/// question field, hosted at the top of Insights. Answers write under
/// `Repository.journalDeviceId` ("noop-journal"), never the imported source, so a CSV
/// re-import can't clobber them and clearing is safe. Tri-state: tapping the selected
/// chip again clears the answer. Day attribution follows the importer's wake-day
/// convention: answers describe the night/day leading into the selected morning.
struct JournalLogCard: View {
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var catalog: JournalCatalogStore

    /// Distinct imported question strings (from InsightsView's load).
    let importedQuestions: [String]
    /// question → answeredYes for the selected day, native rows only.
    let answers: [String: Bool]
    @Binding var dayOffset: Int            // 0 = today, 1 = yesterday
    let onChanged: () -> Void              // parent re-runs load() after a write

    @State private var customDraft = ""

    private var dayKey: String {
        Repository.localDayKey(
            Calendar.current.date(byAdding: .day, value: -dayOffset, to: Date()) ?? Date())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            HStack(alignment: .center) {
                SectionHeader("Journal", overline: "Log")
                Spacer()
                dayPill("Today", offset: 0)
                dayPill("Yesterday", offset: 1)
            }
            NoopCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Answers are about the night and day leading into this morning — the same attribution a WHOOP export uses, so logged and imported days line up.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(JournalCatalogStore.mergeCatalog(imported: importedQuestions,
                                                             custom: catalog.customQuestions),
                            id: \.self) { q in
                        HStack {
                            Text(verbatim: q)   // data, not a UI literal — stays out of the catalog
                                .font(StrandFont.body)
                                .foregroundStyle(StrandPalette.textPrimary)
                            Spacer()
                            answerPill("Yes", q: q, value: true)
                            answerPill("No", q: q, value: false)
                        }
                    }
                    Divider().overlay(StrandPalette.hairline)
                    HStack {
                        TextField("Add a custom question…", text: $customDraft)
                            .textFieldStyle(.roundedBorder)
                        Button("Add") {
                            let t = customDraft.trimmingCharacters(in: .whitespaces)
                            guard !t.isEmpty else { return }
                            catalog.customQuestions.append(t)
                            customDraft = ""
                        }
                        .buttonStyle(.bordered)
                        .disabled(customDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
    }

    private func dayPill(_ label: LocalizedStringKey, offset: Int) -> some View {
        pillButton(label, selected: dayOffset == offset) {
            dayOffset = offset
            onChanged()   // reload the selected day's answers
        }
    }

    private func answerPill(_ label: LocalizedStringKey, q: String, value: Bool) -> some View {
        let selected = answers[q] == value
        return pillButton(label, selected: selected) {
            Task {
                if selected {
                    await repo.clearJournalAnswer(day: dayKey, question: q)
                } else {
                    await repo.saveJournalAnswer(day: dayKey, question: q, answeredYes: value)
                }
                onChanged()
            }
        }
    }

    private func pillButton(_ label: LocalizedStringKey, selected: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(StrandFont.footnote)
                .foregroundStyle(selected ? StrandPalette.surfaceBase : StrandPalette.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(selected ? StrandPalette.accent : StrandPalette.surfaceInset,
                            in: Capsule())
                .overlay(Capsule().stroke(selected ? StrandPalette.accent : StrandPalette.hairline,
                                          lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
