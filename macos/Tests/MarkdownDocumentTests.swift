@testable import MrMark
import XCTest

final class MarkdownDocumentTests: XCTestCase {
    private let markdownType = "net.daringfireball.markdown"

    func testRoundTripPreservesUTF8Source() throws {
        let source = "# Title\n\n- [ ] task with unicode: ✅ 한글 émoji\n\n```swift\nlet x = 1\n```\n"
        let document = MarkdownDocument()

        try document.read(from: Data(source.utf8), ofType: markdownType)
        XCTAssertEqual(document.text, source)

        let written = try document.data(ofType: markdownType)
        XCTAssertEqual(String(decoding: written, as: UTF8.self), source)
    }

    func testUntitledDocumentDisplayNameIsUntitledMd() {
        let document = MarkdownDocument()
        XCTAssertEqual(document.displayName, "Untitled.md")
    }

    func testInvalidUTF8Throws() {
        let document = MarkdownDocument()
        let invalid = Data([0xFF, 0xFE, 0x00, 0xD8])

        XCTAssertThrowsError(try document.read(from: invalid, ofType: markdownType)) { error in
            XCTAssertEqual((error as? CocoaError)?.code, .fileReadInapplicableStringEncoding)
        }
    }

    func testPrintOperationPrintsRenderedContentNotSource() throws {
        let document = MarkdownDocument()
        try document.read(from: Data("# Title\n\nBody text\n".utf8), ofType: markdownType)

        let operation = try document.printOperation(withSettings: [:])

        let printView = try XCTUnwrap(operation.view as? NSTextView)
        let printed = try XCTUnwrap(printView.textStorage)
        // Rendered output: heading markers are gone, the text itself remains.
        XCTAssertFalse(printed.string.contains("#"))
        XCTAssertTrue(printed.string.contains("Title"))
        XCTAssertTrue(printed.string.contains("Body text"))
        // Content must repaginate to the chosen paper, never clip.
        XCTAssertEqual(operation.printInfo.horizontalPagination, .fit)
        XCTAssertEqual(operation.printInfo.verticalPagination, .automatic)
    }

    func testManualSavePolicyAutosaveIsOff() {
        // Policy: saving is manual (⌘S / toolbar). autosavesInPlace == false
        // gives the classic OS behavior — closing a dirty document prompts
        // Save / Cancel / Don't Save instead of silently writing.
        XCTAssertFalse(MarkdownDocument.autosavesInPlace)
    }

    func testCRLFAndBOMSurviveRoundTripByteExactly() throws {
        let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
        let source = Data(bom) + Data("# Title\r\n\r\nline one\r\nline two\r\n".utf8)
        let document = MarkdownDocument()

        try document.read(from: source, ofType: markdownType)
        XCTAssertFalse(document.text.contains("\r"), "editing model must see plain \\n")

        let written = try document.data(ofType: markdownType)
        XCTAssertEqual(written, source, "unedited save must be byte-identical")
    }

    func testLFFilesStayLFWithoutBOM() throws {
        let source = "plain\nunix\nfile\n"
        let document = MarkdownDocument()

        try document.read(from: Data(source.utf8), ofType: markdownType)
        let written = try document.data(ofType: markdownType)
        XCTAssertEqual(written, Data(source.utf8))
    }

    func testTogglingCheckboxMarker() {
        XCTAssertEqual(MarkdownDocument.togglingCheckboxMarker(in: "- [ ] todo"), "- [x] todo")
        XCTAssertEqual(MarkdownDocument.togglingCheckboxMarker(in: "- [x] done"), "- [ ] done")
        XCTAssertEqual(MarkdownDocument.togglingCheckboxMarker(in: "  - [X] caps"), "  - [ ] caps")
        XCTAssertEqual(MarkdownDocument.togglingCheckboxMarker(in: "no checkbox here"), "no checkbox here")
    }

    func testToggleCheckboxAtSourceLineUpdatesTextAndDirtiesDocument() throws {
        let source = "# List\n\n- [ ] first\n- [x] second\n"
        let document = MarkdownDocument()
        try document.read(from: Data(source.utf8), ofType: markdownType)

        document.toggleCheckbox(atSourceLine: 3)
        XCTAssertEqual(document.text, "# List\n\n- [x] first\n- [x] second\n")
        XCTAssertTrue(document.isDocumentEdited)

        document.undoManager?.undo()
        XCTAssertEqual(document.text, source)
        XCTAssertFalse(document.isDocumentEdited, "undoing the only change restores the clean state")
    }
}
