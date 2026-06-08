import XCTest
import ZIPFoundation
@testable import StrandImport

final class ImportCoordinatorTests: XCTestCase {

    private let appleHealthFixture = "sample_health_data.xml"
    private var tempDirs: [URL] = []

    override func tearDownWithError() throws {
        for d in tempDirs { try? FileManager.default.removeItem(at: d) }
        tempDirs.removeAll()
    }

    private func makeTempDir() -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("strandimport-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        tempDirs.append(d)
        return d
    }

    /// Build a zip from a set of (entryPath, fixtureName) pairs.
    private func makeZip(named: String, entries: [(String, String)]) throws -> URL {
        let dir = makeTempDir()
        let zipURL = dir.appendingPathComponent(named)
        let archive = try Archive(url: zipURL, accessMode: .create)
        for (entryPath, fixture) in entries {
            let data = Fixtures.data(fixture)
            try archive.addEntry(with: entryPath, type: .file,
                                 uncompressedSize: Int64(data.count)) { position, size in
                let start = data.startIndex + Int(position)
                let end = start + size
                return data.subdata(in: start..<end)
            }
        }
        return zipURL
    }

    // MARK: - Whoop zip (nested folder names)

    func testWhoopExportFromZipWithNestedFolder() throws {
        let zip = try makeZip(named: "my_whoop.zip", entries: [
            ("my_whoop_data_2024_01_05/physiological_cycles.csv", "physiological_cycles.csv"),
            ("my_whoop_data_2024_01_05/sleeps.csv", "sleeps.csv"),
            ("my_whoop_data_2024_01_05/workouts.csv", "workouts.csv"),
            ("my_whoop_data_2024_01_05/journal_entries.csv", "journal_entries.csv"),
        ])

        let result = try ImportCoordinator().importWhoopExport(from: zip)
        XCTAssertEqual(result.cycles.count, 2)
        XCTAssertEqual(result.sleeps.count, 2)
        XCTAssertEqual(result.workouts.count, 2)
        XCTAssertEqual(result.journal.count, 2)
        XCTAssertEqual(result.cycles[0].recoveryScore, 72)
    }

    // MARK: - Apple Health zip

    func testAppleHealthFromZipNested() throws {
        let zip = try makeZip(named: "export.zip", entries: [
            ("apple_health_export/export.xml", appleHealthFixture),
        ])
        let result = try ImportCoordinator().importAppleHealth(from: zip)
        XCTAssertGreaterThan(result.samples.count, 0)
        XCTAssertEqual(result.workouts.count, 1)
        XCTAssertEqual(result.sleepIntervals.count, 3)
        // OxygenSaturation still scaled when coming via the zip stream.
        let spo2 = result.samples.first { $0.type == "OxygenSaturation" }
        XCTAssertEqual(try XCTUnwrap(spo2?.value), 97.0, accuracy: 1e-9)
    }

    // MARK: - Auto detection

    func testDetectKindAppleHealthByXMLExtension() throws {
        let result = try ImportCoordinator().detectAndImport(from: Fixtures.url(appleHealthFixture))
        XCTAssertEqual(result.kind, .appleHealth)
        if case .appleHealth(let r) = result {
            XCTAssertGreaterThan(r.samples.count, 0)
        } else {
            XCTFail("expected appleHealth")
        }
    }

    func testDetectKindWhoopByFolderContents() throws {
        let folder = Fixtures.url("physiological_cycles.csv").deletingLastPathComponent()
        // The Resources folder contains BOTH whoop CSVs and export.xml. export.xml
        // detection wins per the documented order; verify both branches with
        // dedicated folders instead.
        let whoopOnly = makeTempDir()
        try FileManager.default.copyItem(
            at: Fixtures.url("physiological_cycles.csv"),
            to: whoopOnly.appendingPathComponent("physiological_cycles.csv"))
        let kind = try ImportCoordinator().detectKind(of: whoopOnly)
        XCTAssertEqual(kind, .whoopExport)
        _ = folder
    }

    func testDetectKindAppleHealthByZipEntry() throws {
        let zip = try makeZip(named: "export.zip", entries: [
            ("apple_health_export/export.xml", appleHealthFixture),
        ])
        let result = try ImportCoordinator().detectAndImport(from: zip)
        XCTAssertEqual(result.kind, .appleHealth)
    }

    func testDetectKindWhoopByZipEntry() throws {
        let zip = try makeZip(named: "whoop.zip", entries: [
            ("nested/deeper/physiological_cycles.csv", "physiological_cycles.csv"),
        ])
        let result = try ImportCoordinator().detectAndImport(from: zip)
        XCTAssertEqual(result.kind, .whoopExport)
        XCTAssertEqual(result.summary.sourceKind, .whoopExport)
    }

    // MARK: - Error handling

    func testMissingFileThrows() {
        let bogus = URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString).zip")
        XCTAssertThrowsError(try ImportCoordinator().importWhoopExport(from: bogus)) { err in
            XCTAssertTrue(err is ImportError)
        }
    }

    func testUndetectableInputThrows() throws {
        // A folder with no recognised files.
        let empty = makeTempDir()
        XCTAssertThrowsError(try ImportCoordinator().detectKind(of: empty))
    }
}
