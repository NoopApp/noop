import XCTest
import WhoopStore
@testable import Strand

/// Pins the native-journal merge logic, mirroring the Android JournalLogTest value-for-value so the
/// two platforms merge catalogs and entries identically — question strings are opaque exact-match
/// keys to the effects engines on both sides.
final class JournalLogicTests: XCTestCase {

    private func e(_ day: String, _ q: String, _ yes: Bool) -> JournalEntry {
        JournalEntry(day: day, question: q, answeredYes: yes, notes: nil)
    }

    func testNativeWinsOnCollision() {
        let imported = [e("2026-06-09", "Did you drink any alcohol?", false)]
        let native = [e("2026-06-09", "Did you drink any alcohol?", true)]
        let merged = Repository.mergeJournal(imported: imported, native: native)
        XCTAssertEqual(merged.count, 1)
        XCTAssertTrue(merged[0].answeredYes)
    }

    func testDisjointKeysUnionAndSort() {
        let imported = [e("2026-06-09", "B?", true)]
        let native = [e("2026-06-10", "A?", false), e("2026-06-09", "A?", true)]
        let merged = Repository.mergeJournal(imported: imported, native: native)
        XCTAssertEqual(merged.count, 3)
        // Sorted day ASC then question ASC — matches the DAO/store read order.
        XCTAssertEqual(merged.map(\.question), ["A?", "B?", "A?"])
        XCTAssertEqual(merged.map(\.day), ["2026-06-09", "2026-06-09", "2026-06-10"])
    }

    @MainActor
    func testCatalogAdoptsImportedCasing() {
        let cat = JournalCatalogStore.mergeCatalog(imported: ["DID YOU DRINK ANY ALCOHOL?"], custom: [])
        XCTAssertEqual(cat.first, "DID YOU DRINK ANY ALCOHOL?")
        // The starter alcohol question deduped case-insensitively: 9 starters survive + 1 imported.
        XCTAssertEqual(cat.count, JournalCatalogStore.starterQuestions.count)
    }

    @MainActor
    func testCustomsAppendAndBlanksDrop() {
        let cat = JournalCatalogStore.mergeCatalog(imported: [],
                                                   custom: ["  ", "Did you nap?", "did you NAP?"])
        XCTAssertEqual(Array(cat.prefix(JournalCatalogStore.starterQuestions.count)),
                       JournalCatalogStore.starterQuestions)
        XCTAssertEqual(cat.last, "Did you nap?")
        XCTAssertEqual(cat.count, JournalCatalogStore.starterQuestions.count + 1)
    }
}
