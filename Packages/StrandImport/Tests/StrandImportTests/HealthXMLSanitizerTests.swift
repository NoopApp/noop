import XCTest
@testable import StrandImport

/// Pins the #100 pre-parse sanitizer: every malformed-byte class observed in real multi-source
/// Apple Health exports must survive into a successful parse, and well-formed input must pass
/// through byte-identical (no behavior change for clean exports).
final class HealthXMLSanitizerTests: XCTestCase {

    private let sanitizer = HealthXMLSanitizer()

    private func sanitize(_ xml: String) -> (String, HealthXMLSanitizer.Stats) {
        let (data, stats) = sanitizer.sanitize(data: Data(xml.utf8))
        return (String(decoding: data, as: UTF8.self), stats)
    }

    /// A minimal valid export wrapper around one record line.
    private func wrap(_ recordLine: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <HealthData locale="en_US">
        \(recordLine)
        </HealthData>
        """
    }

    func testXMLDeclarationPassesThroughUntouched() {
        // Regression: the close-quote heuristic must never touch processing instructions —
        // `encoding="UTF-8"?>` has its closing quote followed by `?`, which an element-tag
        // rule reads as content. Corrupting the prolog kills EVERY import at line 1.
        let decl = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<HealthData locale=\"en_US\">\n</HealthData>"
        let (out, stats) = sanitize(decl)
        XCTAssertEqual(out, decl)
        XCTAssertEqual(stats, HealthXMLSanitizer.Stats())
    }

    func testCleanInputPassesThroughByteIdentical() {
        let xml = wrap(#"<Record type="HKQuantityTypeIdentifierBodyMass" value="80.5" unit="kg" startDate="2026-01-02 08:00:00 +0000" endDate="2026-01-02 08:00:00 +0000"/>"#)
        let (out, stats) = sanitize(xml)
        XCTAssertEqual(out, xml)
        XCTAssertEqual(stats, HealthXMLSanitizer.Stats())
    }

    func testUnescapedQuoteInsideAttributeValueIsRepaired() {
        // The libxml error-65 signature from #100: a quote followed by a non-terminator is
        // CONTENT — it must become &quot; and the record must parse with the quote preserved.
        let xml = wrap(#"<Record type="HKQuantityTypeIdentifierBodyMass" sourceName="Joe's "smart" scale" value="80.5" unit="kg" startDate="2026-01-02 08:00:00 +0000" endDate="2026-01-02 08:00:00 +0000"/>"#)
        let (out, stats) = sanitize(xml)
        XCTAssertTrue(out.contains(#"sourceName="Joe's &quot;smart&quot; scale""#), out)
        XCTAssertEqual(stats.repairedLines, 1)
        XCTAssertNoThrow(try AppleHealthImporter().importXML(data: Data(xml.utf8)))
    }

    func testIllegalControlByteBecomesSpace() {
        var bytes = Array(wrap(#"<Record type="X" value="1" sourceName="ab"/>"#).utf8)
        // Inject a vertical tab (0x0B) into the sourceName value.
        if let idx = bytes.firstIndex(of: UInt8(ascii: "b")) { bytes[idx] = 0x0B }
        let (data, stats) = sanitizer.sanitize(data: Data(bytes))
        XCTAssertFalse(data.contains(0x0B))
        XCTAssertEqual(stats.repairedLines, 1)
        XCTAssertNoThrow(try XCTUnwrap(String(data: data, encoding: .utf8)))
    }

    func testBareAmpersandIsEscapedAndValidRefsAreKept() {
        let xml = wrap(#"<Record type="X" sourceName="Fish & Chips &amp; Co &#x41;" value="1"/>"#)
        let (out, stats) = sanitize(xml)
        XCTAssertTrue(out.contains("Fish &amp; Chips &amp; Co &#x41;"), out)
        XCTAssertEqual(stats.repairedLines, 1)
    }

    func testIllegalCharrefBecomesSpace() {
        let xml = wrap(#"<Record type="X" sourceName="bad&#x0B;ref" value="1"/>"#)
        let (out, _) = sanitize(xml)
        XCTAssertFalse(out.contains("&#x0B;"))
        XCTAssertTrue(out.contains("bad ref"), out)
    }

    func testMalformedDoctypeIsStripped() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE HealthData [
        <!ENTITY broken"missing-space">
        ]>
        <HealthData locale="en_US">
        <Record type="X" value="1"/>
        </HealthData>
        """
        let (out, stats) = sanitize(xml)
        XCTAssertFalse(out.contains("DOCTYPE"))
        XCTAssertEqual(stats.strippedDoctypeLines, 3)
        XCTAssertNoThrow(try AppleHealthImporter().importXML(data: Data(xml.utf8)))
    }

    func testUnterminatedLeafLineIsDroppedAndRestSurvives() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <HealthData locale="en_US">
        <Record type="X" sourceName="truncated value
        <Record type="HKQuantityTypeIdentifierBodyMass" value="80.5" unit="kg" startDate="2026-01-02 08:00:00 +0000" endDate="2026-01-02 08:00:00 +0000"/>
        </HealthData>
        """
        let (out, stats) = sanitize(xml)
        XCTAssertEqual(stats.skippedLines, 1)
        XCTAssertFalse(out.contains("truncated value"))
        XCTAssertNoThrow(try AppleHealthImporter().importXML(data: Data(xml.utf8)))
    }

    func testRepairedExportImportsEndToEnd() throws {
        // The #100 shape end-to-end: a legacy record with an embedded quote between two good
        // records; the import must succeed and keep all three records' worth of data.
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <HealthData locale="en_US">
        <Record type="HKQuantityTypeIdentifierBodyMass" value="80.5" unit="kg" startDate="2026-01-02 08:00:00 +0000" endDate="2026-01-02 08:00:00 +0000"/>
        <Record type="HKQuantityTypeIdentifierBodyMass" sourceName="Joe's "smart" scale" value="80.7" unit="kg" startDate="2026-01-03 08:00:00 +0000" endDate="2026-01-03 08:00:00 +0000"/>
        <Record type="HKQuantityTypeIdentifierBodyMass" value="80.9" unit="kg" startDate="2026-01-04 08:00:00 +0000" endDate="2026-01-04 08:00:00 +0000"/>
        </HealthData>
        """
        let result = try AppleHealthImporter().importXML(data: Data(xml.utf8))
        XCTAssertEqual(result.samples.count, 3)
    }
}
