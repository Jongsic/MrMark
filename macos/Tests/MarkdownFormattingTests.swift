@testable import MrMark
import XCTest

final class MarkdownFormattingTests: XCTestCase {
    private func applied(_ edit: MarkdownFormatting.Edit, to text: String) -> String {
        (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
    }

    // MARK: - Inline wrap (bold / italic)

    func testBoldWrapsSelection() {
        let text = "hello world" as NSString
        let edit = MarkdownFormatting.toggleInlineWrap(
            text,
            selection: NSRange(location: 6, length: 5),
            delimiter: "**"
        )
        XCTAssertEqual(applied(edit, to: text as String), "hello **world**")
        XCTAssertEqual(edit.selection, NSRange(location: 8, length: 5))
    }

    func testBoldUnwrapsWhenDelimitersSurroundSelection() {
        let text = "hello **world**" as NSString
        let edit = MarkdownFormatting.toggleInlineWrap(
            text,
            selection: NSRange(location: 8, length: 5),
            delimiter: "**"
        )
        XCTAssertEqual(applied(edit, to: text as String), "hello world")
    }

    func testBoldUnwrapsWhenSelectionIncludesDelimiters() {
        let text = "hello **world**" as NSString
        let edit = MarkdownFormatting.toggleInlineWrap(
            text,
            selection: NSRange(location: 6, length: 9),
            delimiter: "**"
        )
        XCTAssertEqual(applied(edit, to: text as String), "hello world")
    }

    func testBoldWithEmptySelectionInsertsPairAndPlacesCaretInside() {
        let text = "hello " as NSString
        let edit = MarkdownFormatting.toggleInlineWrap(
            text,
            selection: NSRange(location: 6, length: 0),
            delimiter: "**"
        )
        XCTAssertEqual(applied(edit, to: text as String), "hello ****")
        XCTAssertEqual(edit.selection, NSRange(location: 8, length: 0))
    }

    // MARK: - Headings

    func testSetHeadingAddsPrefix() {
        let text = "title line" as NSString
        let edit = MarkdownFormatting.setHeading(text, selection: NSRange(location: 3, length: 0), level: 2)
        XCTAssertEqual(applied(edit, to: text as String), "## title line")
    }

    func testSetHeadingReplacesExistingLevel() {
        let text = "# title" as NSString
        let edit = MarkdownFormatting.setHeading(text, selection: NSRange(location: 3, length: 0), level: 3)
        XCTAssertEqual(applied(edit, to: text as String), "### title")
    }

    func testSetHeadingTogglesOffAtSameLevel() {
        let text = "## title" as NSString
        let edit = MarkdownFormatting.setHeading(text, selection: NSRange(location: 3, length: 0), level: 2)
        XCTAssertEqual(applied(edit, to: text as String), "title")
    }

    // MARK: - Lists

    func testBulletListAddsPrefixToSelectedLines() {
        let text = "one\ntwo\nthree" as NSString
        let edit = MarkdownFormatting.toggleBulletList(text, selection: NSRange(location: 0, length: text.length))
        XCTAssertEqual(applied(edit, to: text as String), "- one\n- two\n- three")
    }

    func testBulletListTogglesOff() {
        let text = "- one\n- two" as NSString
        let edit = MarkdownFormatting.toggleBulletList(text, selection: NSRange(location: 0, length: text.length))
        XCTAssertEqual(applied(edit, to: text as String), "one\ntwo")
    }

    func testNumberedListNumbersSequentially() {
        let text = "one\ntwo\nthree" as NSString
        let edit = MarkdownFormatting.toggleNumberedList(text, selection: NSRange(location: 0, length: text.length))
        XCTAssertEqual(applied(edit, to: text as String), "1. one\n2. two\n3. three")
    }

    func testNumberedListConvertsBullets() {
        let text = "- one\n- two" as NSString
        let edit = MarkdownFormatting.toggleNumberedList(text, selection: NSRange(location: 0, length: text.length))
        XCTAssertEqual(applied(edit, to: text as String), "1. one\n2. two")
    }

    func testChecklistAddsAndRemoves() {
        let text = "task" as NSString
        let add = MarkdownFormatting.toggleChecklist(text, selection: NSRange(location: 0, length: 4))
        XCTAssertEqual(applied(add, to: text as String), "- [ ] task")

        let done = "- [x] task" as NSString
        let remove = MarkdownFormatting.toggleChecklist(done, selection: NSRange(location: 0, length: done.length))
        XCTAssertEqual(applied(remove, to: done as String), "task")
    }

    // MARK: - Insertions

    func testInsertLinkUsesSelectionAsLabelAndSelectsURL() {
        let text = "see docs here" as NSString
        let edit = MarkdownFormatting.insertLink(text, selection: NSRange(location: 4, length: 4))
        let result = applied(edit, to: text as String)
        XCTAssertEqual(result, "see [docs](url) here")
        XCTAssertEqual((result as NSString).substring(with: edit.selection), "url")
    }

    func testInsertImagePlaceholder() {
        let text = "" as NSString
        let edit = MarkdownFormatting.insertImage(text, selection: NSRange(location: 0, length: 0))
        let result = applied(edit, to: text as String)
        XCTAssertEqual(result, "![alt](path)")
        XCTAssertEqual((result as NSString).substring(with: edit.selection), "path")
    }

    func testInsertCodeBlockWrapsCurrentLine() {
        let text = "let x = 1" as NSString
        let edit = MarkdownFormatting.insertCodeBlock(text, selection: NSRange(location: 2, length: 0))
        XCTAssertEqual(applied(edit, to: text as String), "```\nlet x = 1\n```")
    }

    // MARK: - Unicode safety

    func testBoldWithKoreanText() {
        let text = "안녕 세상아" as NSString
        let edit = MarkdownFormatting.toggleInlineWrap(
            text,
            selection: NSRange(location: 3, length: 3),
            delimiter: "**"
        )
        XCTAssertEqual(applied(edit, to: text as String), "안녕 **세상아**")
    }
}
