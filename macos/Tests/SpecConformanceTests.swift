@testable import MrMark
import XCTest

/// Feeds every CommonMark spec input — plus pathological deeply-nested ones —
/// through the viewer renderer. The parser is a deliberate GFM subset, so this
/// is a *stability* suite, not a conformance one: nothing may crash, hang, or
/// overflow the stack. The pathological inputs lock in the nesting guards.
final class SpecConformanceTests: XCTestCase {
    private let renderer = MarkdownRenderer(baseURL: nil)

    private var corpus: [String] {
        specCorpusBase64.compactMap {
            Data(base64Encoded: $0).map { String(decoding: $0, as: UTF8.self) }
        }
    }

    func testDecodesEntireCorpus() {
        XCTAssertEqual(corpus.count, specCorpusBase64.count)
    }

    func testRendersEveryCorpusInputWithoutCrashing() {
        for input in corpus {
            _ = renderer.render(input) // must not crash, hang, or overflow
        }
    }

    func testNestingGuardCatchesPathologicalInputAndSparesNormalText() {
        XCTAssertTrue(markdownNestingExceedsLimit(String(repeating: "> ", count: 5000) + "x"))
        XCTAssertTrue(markdownNestingExceedsLimit(
            (0 ..< 3000).map { String(repeating: "  ", count: $0) + "- x" }.joined(separator: "\n")
        ))
        XCTAssertTrue(markdownNestingExceedsLimit(String(repeating: "*", count: 5000) + "x"))
        XCTAssertFalse(markdownNestingExceedsLimit("# Title\n\n- a\n  - b\n    - c\n\n> quote\n\n**bold**\n"))
    }

    func testUnsafeLinkSchemesAreNotClickable() {
        for scheme in ["javascript:alert(1)", "file:///etc/passwd", "data:text/html,<x>"] {
            let rendered = renderer.render("[tap](\(scheme))")
            let attrs = rendered.attributes(at: 0, effectiveRange: nil)
            XCTAssertNil(attrs[.link], "\(scheme) should not be a live link")
        }
        let ok = renderer.render("[tap](https://example.com)")
        XCTAssertNotNil(ok.attributes(at: 0, effectiveRange: nil)[.link])
    }
}
