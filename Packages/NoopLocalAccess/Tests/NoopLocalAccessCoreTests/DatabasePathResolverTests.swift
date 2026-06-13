import XCTest
@testable import NoopLocalAccessCore

final class DatabasePathResolverTests: XCTestCase {
    func testPersonalBundleIsNotADefaultCandidate() {
        let candidates = DatabasePathResolver.candidates(home: "/Users/example")

        XCTAssertTrue(candidates.contains("/Users/example/Library/Containers/com.noopapp.noop/Data/Library/Application Support/OpenWhoop/whoop.sqlite"))
        XCTAssertFalse(candidates.contains { $0.contains("com.noopapp.noop.personal") })
    }

    func testCustomBundleIDIsExplicitOptIn() {
        let candidates = DatabasePathResolver.candidates(bundleID: "com.example.noop", home: "/Users/example")

        XCTAssertEqual(
            candidates.first,
            "/Users/example/Library/Containers/com.example.noop/Data/Library/Application Support/OpenWhoop/whoop.sqlite"
        )
        XCTAssertTrue(candidates.contains("/Users/example/Library/Containers/com.noopapp.noop/Data/Library/Application Support/OpenWhoop/whoop.sqlite"))
    }

    func testExplicitPathMustExist() throws {
        let url = try TemporaryDatabase.emptyFileURL()
        let config = LocalAccessConfiguration(databasePath: url.path)

        XCTAssertEqual(try DatabasePathResolver.resolve(configuration: config), url.path)
    }

    func testExplicitPathFailureDoesNotFallBack() {
        let config = LocalAccessConfiguration(databasePath: "/definitely/not/noop/whoop.sqlite")

        XCTAssertThrowsError(try DatabasePathResolver.resolve(configuration: config)) { error in
            XCTAssertEqual(error as? LocalAccessError, .databaseUnavailable("NOOP database not found at NOOP_DB_PATH."))
        }
    }
}
