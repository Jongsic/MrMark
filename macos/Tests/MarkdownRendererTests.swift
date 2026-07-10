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

    private func firstAttachment(in string: NSAttributedString) -> NSTextAttachment? {
        var found: NSTextAttachment?
        string.enumerateAttribute(.attachment, in: NSRange(location: 0, length: string.length)) { value, _, stop in
            if let attachment = value as? NSTextAttachment {
                found = attachment
                stop.pointee = true
            }
        }
        return found
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

    func testNarrowTableStaysPlainFindableText() throws {
        let source = """
        | Name | Value |
        | ---- | ----- |
        | one  | 1     |
        | 한글 | 둘    |
        """
        let rendered = renderer.render(source)

        // A table that fits the default window keeps its grid in the outer
        // string, so the find bar and select-all copy still see it.
        XCTAssertNil(firstAttachment(in: rendered))
        XCTAssertFalse(rendered.string.contains("|"), "raw pipes must not leak into the grid")
        XCTAssertTrue(rendered.string.contains("Name\tValue"))
        XCTAssertTrue(rendered.string.contains("one\t1"))
        XCTAssertTrue(rendered.string.contains("한글\t둘"))
        XCTAssertTrue(rendered.string.contains("─"), "hairline rule under the header")

        let headerFont = attributes(of: rendered, containing: "Name")[.font] as? NSFont
        XCTAssertTrue(headerFont?.fontDescriptor.symbolicTraits.contains(.bold) ?? false)

        let rowStyle = attributes(of: rendered, containing: "one")[.paragraphStyle] as? NSParagraphStyle
        XCTAssertEqual(try XCTUnwrap(rowStyle).tabStops.count, 2, "one tab stop per column")
        XCTAssertGreaterThan(try XCTUnwrap(rowStyle).tabStops[0].location, 0)
    }

    func testWideTableBecomesScrollableGridAttachment() throws {
        let wide = String(repeating: "very wide cell content", count: 8)
        let source = "| Name | Value |\n| ---- | ----- |\n| \(wide) | 1 |"
        let rendered = renderer.render(source)

        // Too wide for the window: the whole grid moves into one scrollable
        // view attachment; its text lives inside the attachment.
        let attachment = try XCTUnwrap(firstAttachment(in: rendered) as? TableAttachment)
        XCTAssertFalse(rendered.string.contains("Name"))
        let grid = attachment.grid
        XCTAssertTrue(grid.string.contains("Name\tValue"))
        XCTAssertTrue(grid.string.contains(wide))
        XCTAssertTrue(grid.string.contains("─"), "hairline rule under the header")
        XCTAssertGreaterThan(attachment.naturalWidth, 640)
        XCTAssertGreaterThan(attachment.gridHeight, 0)

        let headerFont = grid.attributes(
            at: (grid.string as NSString).range(of: "Name").location,
            effectiveRange: nil
        )[.font] as? NSFont
        XCTAssertTrue(headerFont?.fontDescriptor.symbolicTraits.contains(.bold) ?? false)
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
