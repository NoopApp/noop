import Foundation

/// The user's custom journal questions + the starter behaviour catalog. Question strings are
/// opaque exact-match labels to BehaviorInsights, so imported question strings (merged in at
/// load time) always take precedence over these defaults. UserDefaults-backed (single-user).
@MainActor
final class JournalCatalogStore: ObservableObject {

    /// Mirrors Android STARTER_JOURNAL_QUESTIONS value-for-value (JournalLog.kt). These are
    /// DATA, not UI literals — stored verbatim in the journal table and rendered verbatim.
    nonisolated static let starterQuestions: [String] = [
        "Did you drink any alcohol?",
        "Did you have caffeine late in the day?",
        "Did you view a screen in bed?",
        "Did you eat close to bedtime?",
        "Did you feel stressed?",
        "Did you use a sauna?",
        "Did you share your bed?",
        "Did you feel sick or ill?",
        "Did you take magnesium?",
        "Did you read before bed?",
    ]

    @Published var customQuestions: [String] { didSet { d.set(customQuestions, forKey: K.custom) } }

    private let d = UserDefaults.standard
    private enum K { static let custom = "journal.customQuestions" }

    init() { customQuestions = d.stringArray(forKey: K.custom) ?? [] }

    /// imported > starter > custom; case-insensitive dedupe, first casing wins (the export's
    /// exact strings join logged and imported days into one behaviour).
    nonisolated static func mergeCatalog(imported: [String], custom: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for q in imported + starterQuestions + custom {
            let t = q.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty, seen.insert(t.lowercased()).inserted { out.append(t) }
        }
        return out
    }
}
