import Foundation

/// Pre-parse sanitizer for Apple Health `export.xml` (#100).
///
/// NSXMLParser (libxml2) has no recover mode and cannot resume after a fatal error, so ONE
/// malformed byte among millions of records kills the whole import. Real exports contain such
/// bytes: 15 years of third-party sources (legacy Garmin / Amazfit / Withings / Nike) are known
/// to write unescaped quotes into attribute values (libxml error 65, "attributes construct
/// error" — the exact failure reported in #100), raw control bytes, bare ampersands, and
/// illegal numeric character references; Apple itself has shipped malformed internal DTD
/// subsets. Tolerance therefore has to happen BEFORE the parser.
///
/// This is a streaming, line-oriented byte transformer (Apple's export is one element per
/// line; see the test fixture). Every byte it touches is < 0x80, so multi-byte UTF-8
/// sequences pass through untouched. Transforms, per line:
///  1. `<!DOCTYPE …>` blocks are stripped entirely (the SAX delegate never reads the DTD;
///     malformed internal subsets are a known failure class).
///  2. XML-1.0-illegal control bytes (0x00–0x08, 0x0B, 0x0C, 0x0E–0x1F) become spaces.
///  3. `&` that does not start a valid entity/charref becomes `&amp;`; numeric charrefs to
///     illegal controls (e.g. `&#x0B;`) become a space.
///  4. A `"` INSIDE an attribute value followed by anything other than an attribute
///     terminator (space, tab, `/`, `>`) is content, not a delimiter — it becomes `&quot;`
///     (the inverse of libxml's error-65 rule, repairing `value="said "hi""` exactly where
///     stock parsing dies).
///  5. A line whose attribute value never terminates (truncated write) is dropped when it is
///     a self-closing leaf (`<Record`/`<MetadataEntry`); structural lines pass through so
///     real corruption still surfaces as a (now line-numbered) parse error.
///
/// The transform is byte-identity for well-formed input (pinned by tests), so clean exports
/// import exactly as before.
struct HealthXMLSanitizer {

    struct Stats: Equatable {
        /// Lines where at least one byte was repaired (quote/amp/control/charref).
        var repairedLines = 0
        /// Malformed leaf lines dropped entirely (unterminated attribute value).
        var skippedLines = 0
        /// Lines removed as part of a DOCTYPE declaration.
        var strippedDoctypeLines = 0
    }

    /// Chunked file → file sanitize (1 MiB reads; a partial trailing line is carried across
    /// chunk boundaries so lines are always transformed whole). RAM stays bounded.
    @discardableResult
    func sanitize(input: URL, output: URL) throws -> Stats {
        guard let inStream = InputStream(url: input) else {
            throw ImportError.fileNotFound(input.path)
        }
        FileManager.default.createFile(atPath: output.path, contents: nil)
        guard let outHandle = try? FileHandle(forWritingTo: output) else {
            throw ImportError.xmlParseFailed("could not open a temp file for sanitizing")
        }
        defer { try? outHandle.close() }

        inStream.open()
        defer { inStream.close() }

        var stats = Stats()
        var inDoctype = false
        var carry: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 1 << 20)

        while true {
            let n = inStream.read(&buffer, maxLength: buffer.count)
            if n < 0 {
                throw ImportError.xmlParseFailed(
                    inStream.streamError?.localizedDescription ?? "read failed during sanitize")
            }
            if n == 0 { break }
            var out: [UInt8] = []
            out.reserveCapacity(n + 64)
            var lineStart = 0
            var i = 0
            // Process complete lines; stash the trailing partial into `carry`.
            while i < n {
                if buffer[i] == 0x0A {   // \n
                    var line = carry
                    line.append(contentsOf: buffer[lineStart...i])
                    carry = []
                    if let t = transformLine(line, stats: &stats, inDoctype: &inDoctype) {
                        out.append(contentsOf: t)
                    }
                    lineStart = i + 1
                }
                i += 1
            }
            if lineStart < n { carry.append(contentsOf: buffer[lineStart..<n]) }
            if !out.isEmpty { try outHandle.write(contentsOf: Data(out)) }
        }
        if !carry.isEmpty,
           let t = transformLine(carry, stats: &stats, inDoctype: &inDoctype) {
            try outHandle.write(contentsOf: Data(t))
        }
        return stats
    }

    /// In-memory variant (the Data import path and tests). Same transform.
    func sanitize(data: Data) -> (Data, Stats) {
        var stats = Stats()
        var inDoctype = false
        var out = [UInt8]()
        out.reserveCapacity(data.count + 64)
        var line = [UInt8]()
        for b in data {
            line.append(b)
            if b == 0x0A {
                if let t = transformLine(line, stats: &stats, inDoctype: &inDoctype) {
                    out.append(contentsOf: t)
                }
                line.removeAll(keepingCapacity: true)
            }
        }
        if !line.isEmpty, let t = transformLine(line, stats: &stats, inDoctype: &inDoctype) {
            out.append(contentsOf: t)
        }
        return (Data(out), stats)
    }

    // MARK: - Per-line transform

    private static let quotEntity = Array("&quot;".utf8)
    private static let aposEntity = Array("&apos;".utf8)
    private static let ampEntity = Array("&amp;".utf8)
    private static let ltEntity = Array("&lt;".utf8)

    /// Transform one complete line (including its trailing \n when present).
    /// Returns nil to drop the line.
    func transformLine(_ line: [UInt8], stats: inout Stats, inDoctype: inout Bool) -> [UInt8]? {
        if inDoctype {
            stats.strippedDoctypeLines += 1
            if contains(line, ascii: "]>") { inDoctype = false }
            return nil
        }
        if startsWithTrimmed(line, ascii: "<!DOCTYPE") {
            stats.strippedDoctypeLines += 1
            // A single-line DOCTYPE (with or without an internal subset) ends here; one that
            // OPENS a `[` subset without closing it spans lines until a line containing "]>".
            if contains(line, ascii: "[") && !contains(line, ascii: "]>") { inDoctype = true }
            return nil
        }

        var out = [UInt8]()
        out.reserveCapacity(line.count + 16)
        var repaired = false
        var inTag = false
        var quote: UInt8? = nil
        var i = 0
        let n = line.count

        while i < n {
            let b = line[i]
            // 2. Illegal control bytes → space (tab/LF/CR are legal and kept).
            if b < 0x20, b != 0x09, b != 0x0A, b != 0x0D {
                out.append(0x20)
                repaired = true
                i += 1
                continue
            }
            if let q = quote {
                if b == q {
                    // Delimiter only when what FOLLOWS reads as the rest of a tag: the close
                    // (`>`/`/>`/EOL) immediately or after whitespace, or whitespace followed by
                    // another `name=` attribute. Otherwise the quote is CONTENT (the libxml
                    // error-65 signature) → entity-escape it. The token lookahead disambiguates
                    // `…="Joe's "smart" scale" value="…`: the quotes around `smart` and before
                    // ` scale` are followed by content words WITHOUT `=`, the real closer by
                    // ` value=` — lookahead-1 alone closed early on quote-then-space and
                    // corrupted the rest of the line.
                    if closesAttributeValue(line, afterQuoteAt: i) {
                        quote = nil
                        out.append(b)
                    } else {
                        out.append(contentsOf: q == UInt8(ascii: "\"")
                                   ? Self.quotEntity : Self.aposEntity)
                        repaired = true
                    }
                    i += 1
                    continue
                }
                if b == UInt8(ascii: "&") {
                    i = appendAmpersand(line, at: i, into: &out, repaired: &repaired)
                    continue
                }
                if b == UInt8(ascii: "<") {   // raw '<' inside a value is equally illegal
                    out.append(contentsOf: Self.ltEntity)
                    repaired = true
                    i += 1
                    continue
                }
                out.append(b)
                i += 1
                continue
            }
            switch b {
            case UInt8(ascii: "<"):
                // Quote-repair applies to ELEMENT tags only. Processing instructions and
                // declarations (`<?xml …?>`, `<!--…-->`) pass through untracked — without this
                // bypass the universal export prolog `encoding="UTF-8"?>` (closing quote
                // followed by `?`, not an attribute terminator) was corrupted to
                // `encoding="UTF-8&quot;?>`, killing EVERY import at line 1.
                let next: UInt8? = i + 1 < n ? line[i + 1] : nil
                inTag = next != UInt8(ascii: "?") && next != UInt8(ascii: "!")
                out.append(b)
            case UInt8(ascii: ">"):
                inTag = false
                out.append(b)
            case UInt8(ascii: "\""), UInt8(ascii: "'"):
                if inTag { quote = b }
                out.append(b)
            case UInt8(ascii: "&"):
                i = appendAmpersand(line, at: i, into: &out, repaired: &repaired)
                continue
            default:
                out.append(b)
            }
            i += 1
        }

        if quote != nil {
            // Unterminated attribute value at end-of-line (truncated write). Drop self-closing
            // leaves; pass structural lines through so genuine corruption still surfaces.
            if startsWithTrimmed(line, ascii: "<Record")
                || startsWithTrimmed(line, ascii: "<MetadataEntry") {
                stats.skippedLines += 1
                return nil
            }
        }
        if repaired { stats.repairedLines += 1 }
        return out
    }

    /// Does the quote at `i` (inside an attribute value) CLOSE the value? True when the bytes
    /// after it read as the rest of a tag: end-of-line, `>`/`/` (immediately or after
    /// whitespace), or whitespace followed by an attribute-name token and `=`. False means the
    /// quote is content. A content quote followed by ` word=` is inherently ambiguous to any
    /// local heuristic and reads as a closer — acceptable: that shape also defeated libxml.
    private func closesAttributeValue(_ line: [UInt8], afterQuoteAt i: Int) -> Bool {
        let n = line.count
        var j = i + 1
        if j >= n { return true }                              // EOL closes
        let b = line[j]
        if b == UInt8(ascii: ">") || b == UInt8(ascii: "/")
            || b == 0x0D || b == 0x0A { return true }          // tag close / EOL
        if b != 0x20, b != 0x09 { return false }               // content butts right up (error-65)
        // Whitespace: skip it, then require `name=`, the tag close, or EOL.
        while j < n, line[j] == 0x20 || line[j] == 0x09 { j += 1 }
        if j >= n { return true }
        let c = line[j]
        if c == UInt8(ascii: ">") || c == UInt8(ascii: "/")
            || c == 0x0D || c == 0x0A { return true }
        // Attribute-name token: [A-Za-z_][A-Za-z0-9_.:-]* immediately followed by '='.
        func isNameStart(_ x: UInt8) -> Bool {
            (x >= 0x41 && x <= 0x5A) || (x >= 0x61 && x <= 0x7A) || x == UInt8(ascii: "_")
        }
        func isNameByte(_ x: UInt8) -> Bool {
            isNameStart(x) || (x >= 0x30 && x <= 0x39) || x == UInt8(ascii: ".")
                || x == UInt8(ascii: ":") || x == UInt8(ascii: "-")
        }
        guard isNameStart(c) else { return false }
        var k = j + 1
        while k < n, isNameByte(line[k]) { k += 1 }
        return k < n && line[k] == UInt8(ascii: "=")
    }

    /// Handle a `&` at `i`: copy a valid entity/charref verbatim, neutralise an illegal
    /// charref to a space, escape a bare ampersand as `&amp;`. Returns the next index.
    private func appendAmpersand(_ line: [UInt8], at i: Int,
                                 into out: inout [UInt8], repaired: inout Bool) -> Int {
        let n = line.count
        // Find the ';' within a sane lookahead window (longest legal ref is short).
        var semi = -1
        var j = i + 1
        while j < n, j <= i + 12 {
            if line[j] == UInt8(ascii: ";") { semi = j; break }
            j += 1
        }
        if semi > i + 1 {
            let body = Array(line[(i + 1)..<semi])
            if isNamedEntity(body) {
                out.append(contentsOf: line[i...semi])
                return semi + 1
            }
            if let v = charrefValue(body) {
                let legal = v == 9 || v == 10 || v == 13 || v >= 0x20
                if legal {
                    out.append(contentsOf: line[i...semi])
                } else {
                    out.append(0x20)   // e.g. &#x0B; — illegal in XML 1.0, poisons the parse
                    repaired = true
                }
                return semi + 1
            }
        }
        out.append(contentsOf: Self.ampEntity)   // bare '&'
        repaired = true
        return i + 1
    }

    private func isNamedEntity(_ body: [UInt8]) -> Bool {
        let s = String(decoding: body, as: UTF8.self)
        return s == "amp" || s == "lt" || s == "gt" || s == "quot" || s == "apos"
    }

    /// Numeric charref body ("#34" / "#x22") → scalar value, or nil if not a charref.
    private func charrefValue(_ body: [UInt8]) -> Int? {
        guard body.first == UInt8(ascii: "#"), body.count > 1 else { return nil }
        let digits = Array(body.dropFirst())
        if digits.first == UInt8(ascii: "x") || digits.first == UInt8(ascii: "X") {
            let hex = String(decoding: digits.dropFirst(), as: UTF8.self)
            return hex.isEmpty ? nil : Int(hex, radix: 16)
        }
        let dec = String(decoding: digits, as: UTF8.self)
        return dec.isEmpty ? nil : Int(dec)
    }

    // MARK: - Small byte helpers

    private func contains(_ line: [UInt8], ascii s: String) -> Bool {
        let pat = Array(s.utf8)
        guard pat.count <= line.count else { return false }
        return (0...(line.count - pat.count)).contains { off in
            (0..<pat.count).allSatisfy { line[off + $0] == pat[$0] }
        }
    }

    private func startsWithTrimmed(_ line: [UInt8], ascii s: String) -> Bool {
        let pat = Array(s.utf8)
        var start = 0
        while start < line.count, line[start] == 0x20 || line[start] == 0x09 { start += 1 }
        guard line.count - start >= pat.count else { return false }
        return (0..<pat.count).allSatisfy { line[start + $0] == pat[$0] }
    }
}
