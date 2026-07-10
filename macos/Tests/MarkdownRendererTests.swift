@testable import MrMark
import XCTest

final class MarkdownRendererTests: XCTestCase {
    private let renderer = MarkdownRenderer(baseURL: nil)

    private func attributes(of rendered: NSAttributedString, containing needle: String)
        -> [NSAttributedString.Key: Any]
    {
        let range = (rendered.string as NSString).range(of: needle)
        XCTAssertNotEqual(range.location, NSNotFound, "'\(needle)' not found in: \(rendered.string)")
        return rendered.attributes(at: range.location, effectiveRange: nil)
    }

    func testHeadingIsLargerAndBold() throws {
        let rendered = renderer.render("# Title\n\nbody text")
        let headingFont = attributes(of: rendered, containing: "Title")[.font] as? NSFont
        let bodyFont = attributes(of: rendered, containing: "body text")[.font] as? NSFont

        XCTAssertNotNil(headingFont)
        XCTAssertNotNil(bodyFont)
        XCTAssertGreaterThan(try XCTUnwrap(headingFont?.pointSize), try XCTUnwrap(bodyFont?.pointSize))
        XCTAssertTrue(try XCTUnwrap(headingFont?.fontDescriptor.symbolicTraits.contains(.bold)))
    }

    func testStrongAndEmphasisApplyFontTraits() {
        let rendered = renderer.render("plain **bold** and *italic*")
        let boldFont = attributes(of: rendered, containing: "bold")[.font] as? NSFont
        let italicFont = attributes(of: rendered, containing: "italic")[.font] as? NSFont

        XCTAssertTrue(boldFont?.fontDescriptor.symbolicTraits.contains(.bold) ?? false)
        XCTAssertTrue(italicFont?.fontDescriptor.symbolicTraits.contains(.italic) ?? false)
    }

    func testCodeBlockIsOneVisualBlock() throws {
        let rendered = renderer.render("```\nfirst\nmiddle\nlast\n```\n\nafter")
        let firstStyle = attributes(of: rendered, containing: "first")[.paragraphStyle] as? NSParagraphStyle
        let lastStyle = attributes(of: rendered, containing: "last")[.paragraphStyle] as? NSParagraphStyle

        // No gaps between the block's own lines; trailing spacing after the last.
        XCTAssertEqual(try XCTUnwrap(firstStyle).paragraphSpacing, 0)
        XCTAssertEqual(try XCTUnwrap(lastStyle).paragraphSpacing, 28)

        // Every code line is marked for the full-width background fragment.
        for needle in ["first", "middle", "last"] {
            XCTAssertNotNil(attributes(of: rendered, containing: needle)[.mrmarkCodeBlock], needle)
        }
        XCTAssertNil(attributes(of: rendered, containing: "after")[.mrmarkCodeBlock])
    }

    func testCodeBlockCarriesEdgeLanguageAndCopyMarkers() {
        let rendered = renderer.render("```swift\nlet a = 1\nlet b = 2\n```\n\nafter")

        let first = attributes(of: rendered, containing: "let a = 1")
        XCTAssertEqual(first[.mrmarkCodeBlockEdge] as? Int, CodeBlockEdge.top.rawValue)
        XCTAssertEqual(first[.mrmarkCodeLanguage] as? String, "swift")
        XCTAssertNotNil(first[.mrmarkCodeCopy])

        let last = attributes(of: rendered, containing: "let b = 2")
        XCTAssertEqual(last[.mrmarkCodeBlockEdge] as? Int, CodeBlockEdge.bottom.rawValue)
        XCTAssertNil(last[.mrmarkCodeLanguage])
        XCTAssertNil(last[.mrmarkCodeCopy])
    }

    func testSingleLineCodeBlockIsBothEdges() {
        let rendered = renderer.render("```\nonly line\n```")
        let attrs = attributes(of: rendered, containing: "only line")
        XCTAssertEqual(attrs[.mrmarkCodeBlockEdge] as? Int, CodeBlockEdge.both.rawValue)
        XCTAssertNotNil(attrs[.mrmarkCodeCopy])
    }

    func testCodeBlockWithBlankFirstLineKeepsEdgeAndCopyMarkers() {
        let rendered = renderer.render("```swift\n\nlet a = 1\n```\n\nafter")
        // The blank first line is a lone newline character; the top edge,
        // language, and copy marker must land on it instead of vanishing on a
        // zero-length range (which silently drops the box top and the button).
        let blankFirst = (rendered.string as NSString).range(of: "\nlet a = 1").location
        let attrs = rendered.attributes(at: blankFirst, effectiveRange: nil)
        XCTAssertEqual(attrs[.mrmarkCodeBlockEdge] as? Int, CodeBlockEdge.top.rawValue)
        XCTAssertNotNil(attrs[.mrmarkCodeCopy])
        XCTAssertEqual(attrs[.mrmarkCodeLanguage] as? String, "swift")
        XCTAssertEqual(
            attributes(of: rendered, containing: "let a = 1")[.mrmarkCodeBlockEdge] as? Int,
            CodeBlockEdge.bottom.rawValue
        )
    }

    func testCodeBlockWithTrailingBlankLineKeepsBottomEdge() {
        // One content line plus a trailing blank: the box is a single visual
        // paragraph, so it carries both edges.
        let single = renderer.render("```\nlet a = 1\n\n```")
        XCTAssertEqual(
            attributes(of: single, containing: "let a = 1")[.mrmarkCodeBlockEdge] as? Int,
            CodeBlockEdge.both.rawValue
        )

        // Two content lines plus a trailing blank: the bottom edge anchors on
        // the last paragraph that owns characters, not past the final newline.
        let multi = renderer.render("```\nfirst\nsecond\n\n```")
        XCTAssertEqual(
            attributes(of: multi, containing: "first")[.mrmarkCodeBlockEdge] as? Int,
            CodeBlockEdge.top.rawValue
        )
        XCTAssertEqual(
            attributes(of: multi, containing: "second")[.mrmarkCodeBlockEdge] as? Int,
            CodeBlockEdge.bottom.rawValue
        )
    }

    func testCopyDerivesCodeFromStorageRun() {
        let rendered = renderer.render("```\nfirst block\ncode line\n```\n\n```\nsecond block\n```\n\nafter")
        let string = rendered.string as NSString
        XCTAssertEqual(
            ViewerTextView.codeBlockText(in: rendered, at: string.range(of: "first").location),
            "first block\ncode line"
        )
        // The newline joining the two blocks carries no code attribute, so the
        // runs stay separate.
        XCTAssertEqual(
            ViewerTextView.codeBlockText(in: rendered, at: string.range(of: "second").location),
            "second block"
        )
        XCTAssertNil(ViewerTextView.codeBlockText(in: rendered, at: string.range(of: "after").location))
    }

    func testTableRendersAsAlignedGridNotRawSource() throws {
        let source = """
        | Name | Value |
        | ---- | ----- |
        | one  | 1     |
        | 한글 | 둘    |
        """
        let rendered = renderer.render(source)

        XCTAssertFalse(rendered.string.contains("|"), "raw pipes must not leak into the grid")
        XCTAssertTrue(rendered.string.contains("Name\tValue"))
        XCTAssertTrue(rendered.string.contains("one\t1"))
        XCTAssertTrue(rendered.string.contains("한글\t둘"))
        XCTAssertTrue(rendered.string.contains("─"), "hairline rule under the header")

        let headerFont = attributes(of: rendered, containing: "Name")[.font] as? NSFont
        XCTAssertTrue(headerFont?.fontDescriptor.symbolicTraits.contains(.bold) ?? false)

        let rowStyle = attributes(of: rendered, containing: "one")[.paragraphStyle] as? NSParagraphStyle
        XCTAssertEqual(try XCTUnwrap(rowStyle).tabStops.count, 2, "one tab stop per column")
        // Both columns must clear the widest cell (헤더가 굵은 폰트라도 포함해 측정).
        XCTAssertGreaterThan(try XCTUnwrap(rowStyle).tabStops[0].location, 0)
    }

    func testCheckboxLinesAccountForFrontmatter() {
        let rendered = renderer.render("---\ntitle: x\n---\n\n- [ ] first\n- [x] second")
        // Lines are 1-based in the *original* document — toggling edits the
        // original text, and the parser only ever saw the peeled body.
        XCTAssertEqual(attributes(of: rendered, containing: "☐")[.mrmarkCheckboxLine] as? Int, 5)
        XCTAssertEqual(attributes(of: rendered, containing: "☑")[.mrmarkCheckboxLine] as? Int, 6)
    }

    func testFrontmatterRendersAsPropertiesNotHeading() throws {
        let rendered = renderer.render("---\ntitle: Hi There\ntags: a, b\n---\n\n# Real Heading")
        XCTAssertTrue(rendered.string.contains("title"))
        XCTAssertTrue(rendered.string.contains("Hi There"))
        XCTAssertTrue(rendered.string.contains("Real Heading"))

        // The frontmatter key uses the medium-weight key font (15pt), not the
        // 21pt bold H2 the broken setext parse used to produce.
        let keyFont = attributes(of: rendered, containing: "title")[.font] as? NSFont
        XCTAssertEqual(keyFont?.pointSize, 15)
        XCTAssertFalse(keyFont?.fontDescriptor.symbolicTraits.contains(.bold) ?? true)

        // The real body heading below the frontmatter still renders large.
        let headingFont = attributes(of: rendered, containing: "Real Heading")[.font] as? NSFont
        XCTAssertGreaterThan(try XCTUnwrap(headingFont?.pointSize), 15)
    }

    func testSyntaxMarkersAreNotRendered() {
        let rendered = renderer.render("# Title\n\n**bold** and `code`")
        XCTAssertFalse(rendered.string.contains("#"))
        XCTAssertFalse(rendered.string.contains("**"))
        XCTAssertFalse(rendered.string.contains("`"))
    }

    func testBulletAndOrderedListMarkers() {
        let rendered = renderer.render("- first\n- second\n\n1. one\n2. two")
        XCTAssertTrue(rendered.string.contains("•  first"))
        XCTAssertTrue(rendered.string.contains("1.  one"))
        XCTAssertTrue(rendered.string.contains("2.  two"))
    }

    func testTaskListCheckboxes() {
        let rendered = renderer.render("- [ ] todo\n- [x] done")
        XCTAssertTrue(rendered.string.contains("☐"))
        XCTAssertTrue(rendered.string.contains("☑"))
    }

    func testCheckboxGlyphsCarryTheirSourceLine() {
        let rendered = renderer.render("# Title\n\n- [ ] first\n- [x] second\n- plain bullet")
        XCTAssertEqual(attributes(of: rendered, containing: "☐")[.mrmarkCheckboxLine] as? Int, 3)
        XCTAssertEqual(attributes(of: rendered, containing: "☑")[.mrmarkCheckboxLine] as? Int, 4)
        XCTAssertNil(attributes(of: rendered, containing: "•")[.mrmarkCheckboxLine])
    }

    func testLinkGetsLinkAttribute() {
        let rendered = renderer.render("see [the site](https://example.com)")
        let url = attributes(of: rendered, containing: "the site")[.link] as? URL
        XCTAssertEqual(url?.absoluteString, "https://example.com")
    }

    func testInlineCodeAndCodeBlockUseMonospacedFont() {
        let rendered = renderer.render("run `mrmark`\n\n```\nlet x = 1\n```")
        let inlineFont = attributes(of: rendered, containing: "mrmark")[.font] as? NSFont
        let blockFont = attributes(of: rendered, containing: "let x = 1")[.font] as? NSFont

        XCTAssertTrue(inlineFont?.fontDescriptor.symbolicTraits.contains(.monoSpace) ?? false)
        XCTAssertTrue(blockFont?.fontDescriptor.symbolicTraits.contains(.monoSpace) ?? false)
        XCTAssertTrue(rendered.string.contains("let x = 1"))
    }

    func testRemoteImageIsNotFetchedButLinked() {
        let rendered = renderer.render("![alt text](https://example.com/pic.png)")
        XCTAssertTrue(rendered.string.contains("alt text"))
        let url = attributes(of: rendered, containing: "alt text")[.link] as? URL
        XCTAssertEqual(url?.host, "example.com")
    }

    func testScaleMultipliesAllFontSizes() {
        let source = "# Title\n\nbody with `code`"
        let normal = MarkdownRenderer(baseURL: nil, scale: 1).render(source)
        let zoomed = MarkdownRenderer(baseURL: nil, scale: 2).render(source)

        for needle in ["Title", "body", "code"] {
            let normalFont = attributes(of: normal, containing: needle)[.font] as? NSFont
            let zoomedFont = attributes(of: zoomed, containing: needle)[.font] as? NSFont
            XCTAssertEqual(zoomedFont?.pointSize, (normalFont?.pointSize ?? 0) * 2, "font for '\(needle)'")
        }
    }

    func testRendersLargeDocumentQuickly() {
        let source = (1 ... 10000).map { line -> String in
            switch line % 7 {
            case 0: return "## Section \(line)"
            case 1: return "- [ ] task \(line) with **bold**"
            default: return "Line \(line) with a [link](https://example.com/\(line)) and `code`."
            }
        }.joined(separator: "\n\n")

        let started = CFAbsoluteTimeGetCurrent()
        let rendered = renderer.render(source)
        let elapsed = CFAbsoluteTimeGetCurrent() - started

        XCTAssertGreaterThan(rendered.length, 100_000)
        // Generous CI-safe bound; local runs are far faster. Real budget work is M3.
        XCTAssertLessThan(elapsed, 5.0, "10k-line render took \(elapsed)s")
    }
}
