@testable import MrMark
import XCTest

final class MarkdownSourceHighlighterTests: XCTestCase {
    private let highlighter = MarkdownSourceHighlighter()

    /// By default everything is revealed (plain styled source), like when the
    /// whole document is the cursor's paragraph.
    private func highlightedStorage(_ source: String, revealing: NSRange? = nil) -> NSTextStorage {
        let storage = NSTextStorage(string: source)
        let reveal = revealing ?? NSRange(location: 0, length: storage.length)
        highlighter.highlightAll(storage, revealing: reveal)
        return storage
    }

    private func range(of needle: String, in storage: NSTextStorage) -> NSRange {
        let range = (storage.string as NSString).range(of: needle)
        XCTAssertNotEqual(range.location, NSNotFound, "'\(needle)' not found")
        return range
    }

    private func font(in storage: NSTextStorage, at needle: String) -> NSFont? {
        storage.attribute(.font, at: range(of: needle, in: storage).location, effectiveRange: nil) as? NSFont
    }

    private func isConcealed(_ needle: String, in storage: NSTextStorage) -> Bool {
        let location = range(of: needle, in: storage).location
        return storage.attribute(.mrmarkConcealed, at: location, effectiveRange: nil) != nil
    }

    private func paragraphRange(of needle: String, in storage: NSTextStorage) -> NSRange {
        (storage.string as NSString).paragraphRange(for: range(of: needle, in: storage))
    }

    // MARK: - Styled source (the revealed paragraph)

    func testHeadingLineIncludingMarkerIsStyled() {
        let storage = highlightedStorage("# Title\n\nbody")
        // Revealed source: the "#" marker stays visible and gets the heading style too.
        XCTAssertEqual(font(in: storage, at: "#")?.pointSize, 26)
        XCTAssertFalse(isConcealed("#", in: storage))
        XCTAssertEqual(font(in: storage, at: "Title")?.pointSize, 26)
        XCTAssertEqual(font(in: storage, at: "body")?.pointSize, 15)
    }

    func testBoldKeepsMarkersVisibleAndAppliesTraitWhenRevealed() {
        let storage = highlightedStorage("some **bold** text")
        XCTAssertTrue(storage.string.contains("**")) // markers preserved
        XCTAssertFalse(isConcealed("**", in: storage))
        let boldFont = font(in: storage, at: "bold")
        XCTAssertTrue(boldFont?.fontDescriptor.symbolicTraits.contains(.bold) ?? false)
        let plainFont = font(in: storage, at: "some")
        XCTAssertFalse(plainFont?.fontDescriptor.symbolicTraits.contains(.bold) ?? true)
    }

    func testCodeBlockContentIsMonospaced() {
        let storage = highlightedStorage("```\nlet x = 1\n```\n\nplain")
        let codeFont = font(in: storage, at: "let x = 1")
        XCTAssertTrue(codeFont?.fontDescriptor.symbolicTraits.contains(.monoSpace) ?? false)
        let plainFont = font(in: storage, at: "plain")
        XCTAssertFalse(plainFont?.fontDescriptor.symbolicTraits.contains(.monoSpace) ?? true)
    }

    func testKoreanTextOffsetsAreExact() {
        // UTF-8 columns differ from UTF-16 offsets for Hangul; a bad mapping
        // would style the wrong range.
        let storage = highlightedStorage("한글 **굵게** 그리고 평문")
        let boldFont = font(in: storage, at: "굵게")
        XCTAssertTrue(boldFont?.fontDescriptor.symbolicTraits.contains(.bold) ?? false)
        let plainFont = font(in: storage, at: "평문")
        XCTAssertFalse(plainFont?.fontDescriptor.symbolicTraits.contains(.bold) ?? true)
    }

    // MARK: - Concealment (paragraphs away from the cursor)

    func testDelimitersConcealOutsideTheActiveParagraph() {
        let source = "some **bold** text\n\ncursor lives here"
        let storage = NSTextStorage(string: source)
        highlighter.highlightAll(storage, revealing: paragraphRange(of: "cursor", in: storage))

        XCTAssertTrue(isConcealed("**", in: storage), "delimiters away from the cursor hide")
        XCTAssertFalse(isConcealed("bold", in: storage), "content never hides")
        let boldFont = font(in: storage, at: "bold")
        XCTAssertTrue(boldFont?.fontDescriptor.symbolicTraits.contains(.bold) ?? false, "styling survives concealment")
    }

    func testHeadingPrefixConcealsButTitleKeepsHeadingFont() {
        let source = "## Title\n\ncursor"
        let storage = NSTextStorage(string: source)
        highlighter.highlightAll(storage, revealing: paragraphRange(of: "cursor", in: storage))

        XCTAssertTrue(isConcealed("##", in: storage))
        XCTAssertFalse(isConcealed("Title", in: storage))
        XCTAssertEqual(font(in: storage, at: "Title")?.pointSize, 21)
    }

    func testLinkChromeConcealsButTextStaysStyled() {
        let source = "see [text](https://example.com) end\n\ncursor"
        let storage = NSTextStorage(string: source)
        highlighter.highlightAll(storage, revealing: paragraphRange(of: "cursor", in: storage))

        XCTAssertTrue(isConcealed("[", in: storage))
        XCTAssertTrue(isConcealed("](https://example.com)", in: storage))
        XCTAssertFalse(isConcealed("text", in: storage))
        let color = storage.attribute(
            .foregroundColor, at: range(of: "text", in: storage).location, effectiveRange: nil
        ) as? NSColor
        XCTAssertEqual(color, .linkColor)
    }

    func testInlineCodeBackticksConceal() {
        let source = "run `mrmark` now\n\ncursor"
        let storage = NSTextStorage(string: source)
        highlighter.highlightAll(storage, revealing: paragraphRange(of: "cursor", in: storage))

        XCTAssertTrue(isConcealed("`", in: storage))
        XCTAssertFalse(isConcealed("mrmark", in: storage))
        XCTAssertTrue(font(in: storage, at: "mrmark")?.fontDescriptor.symbolicTraits.contains(.monoSpace) ?? false)
    }

    func testMovingTheCursorReconcealsTheParagraphItLeft() {
        let source = "first **one** here\n\nsecond *two* here"
        let storage = NSTextStorage(string: source)
        let first = paragraphRange(of: "first", in: storage)
        let second = paragraphRange(of: "second", in: storage)

        highlighter.highlightAll(storage, revealing: first)
        XCTAssertFalse(isConcealed("**", in: storage))
        XCTAssertTrue(isConcealed("*two*", in: storage))

        // Cursor moves to the second paragraph: restyle both, like the editor does.
        highlighter.highlight(storage, dirtyRange: first, revealing: second)
        highlighter.highlight(storage, dirtyRange: second, revealing: second)
        XCTAssertTrue(isConcealed("**", in: storage))
        XCTAssertFalse(isConcealed("*two*", in: storage))
    }

    func testCaretRevealIsPositionBasedEvenForEmptyRanges() {
        // An empty caret range at the start of a paragraph must still reveal it.
        let source = "alpha **b** end\n\nomega"
        let storage = NSTextStorage(string: source)
        highlighter.highlightAll(storage, revealing: NSRange(location: 0, length: 0))
        XCTAssertFalse(isConcealed("**", in: storage))
    }

    // MARK: - Incremental behavior

    func testPartialHighlightOnlyTouchesEditedParagraph() {
        let storage = highlightedStorage("# One\n\nfirst\n\n# Two\n\nsecond")
        // Wipe all attributes, then restyle only the "first" paragraph.
        storage.setAttributes([:], range: NSRange(location: 0, length: storage.length))
        let dirty = (storage.string as NSString).range(of: "first")
        highlighter.highlight(storage, dirtyRange: dirty, revealing: NSRange(location: 0, length: storage.length))

        XCTAssertEqual(font(in: storage, at: "first")?.pointSize, 15)
        // The heading outside the dirty paragraph was intentionally not touched:
        // it kept the text-storage default instead of the 26pt heading style.
        XCTAssertNotEqual(font(in: storage, at: "# Two")?.pointSize, 26)
    }

    func testScaleMultipliesFontSizes() {
        let storage = NSTextStorage(string: "# Title\n\nbody")
        let zoomed = MarkdownSourceHighlighter()
        zoomed.scale = 2
        zoomed.highlightAll(storage, revealing: NSRange(location: 0, length: storage.length))

        XCTAssertEqual(font(in: storage, at: "Title")?.pointSize, 52)
        XCTAssertEqual(font(in: storage, at: "body")?.pointSize, 30)
    }

    func testEditingFenceLineRestylesToEndOfDocument() {
        let source = "```\ncode\n```\n\ntail"
        let storage = highlightedStorage(source)
        storage.setAttributes([:], range: NSRange(location: 0, length: storage.length))
        // Edit on the opening fence line → everything below must be restyled.
        highlighter.highlight(
            storage, dirtyRange: NSRange(location: 0, length: 1),
            revealing: NSRange(location: 0, length: storage.length)
        )

        XCTAssertNotNil(font(in: storage, at: "tail"))
        XCTAssertTrue(font(in: storage, at: "code")?.fontDescriptor.symbolicTraits.contains(.monoSpace) ?? false)
    }
}
