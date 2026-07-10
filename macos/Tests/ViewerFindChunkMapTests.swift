@testable import MrMark
import XCTest

final class ViewerFindChunkMapTests: XCTestCase {
    // MARK: - Fixtures

    private func tableAttachment(_ text: String) -> TableAttachment {
        TableAttachment(grid: NSAttributedString(string: text), naturalWidth: 800, gridHeight: 100)
    }

    /// Builds an outer attributed string from a mix of plain strings and
    /// attachments, mirroring how the renderer interleaves prose and table
    /// placeholders.
    private func doc(_ parts: [Any]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for part in parts {
            switch part {
            case let text as String:
                result.append(NSAttributedString(string: text))
            case let attachment as NSTextAttachment:
                result.append(NSAttributedString(attachment: attachment))
            default:
                XCTFail("unsupported fixture part: \(part)")
            }
        }
        return result
    }

    // MARK: - 1. No attachments — identity mapping

    func testNoAttachmentsIsIdentityMapping() {
        let source = "plain prose with no tables at all"
        let map = ViewerFindChunkMap(outerString: NSAttributedString(string: source))

        XCTAssertEqual(map.length, (source as NSString).length)
        XCTAssertEqual(map.chunks.count, 1)
        let chunk = map.chunks[0]
        XCTAssertEqual(chunk.virtualRange, NSRange(location: 0, length: map.length))
        XCTAssertEqual(chunk.text as String, source)
        guard case let .outer(range) = chunk.source else { return XCTFail("expected .outer") }
        XCTAssertEqual(range, NSRange(location: 0, length: map.length))
    }

    // MARK: - 2. Prose–table–prose (offsets & boundaries)

    func testProseTableProseOffsetsAndBoundaries() {
        let table = tableAttachment("Name\tValue\n────\none\t1")
        let attributed = doc(["before ", table, " after"])
        let map = ViewerFindChunkMap(outerString: attributed)

        XCTAssertEqual(map.chunks.count, 3)

        let first = map.chunks[0]
        guard case let .outer(firstOuter) = first.source else { return XCTFail("expected .outer") }
        XCTAssertEqual(firstOuter, NSRange(location: 0, length: 7)) // "before "
        XCTAssertEqual(first.virtualRange, NSRange(location: 0, length: 7))
        XCTAssertTrue(first.endsWithSearchBoundary)

        let middle = map.chunks[1]
        guard case let .table(attachment, outerIndex) = middle.source else { return XCTFail("expected .table") }
        XCTAssertTrue(attachment === table)
        XCTAssertEqual(outerIndex, 7) // right after "before "
        let gridLength = (table.grid.string as NSString).length
        XCTAssertEqual(middle.virtualRange, NSRange(location: 7, length: gridLength))
        XCTAssertTrue(middle.endsWithSearchBoundary)

        let last = map.chunks[2]
        guard case let .outer(lastOuter) = last.source else { return XCTFail("expected .outer") }
        XCTAssertEqual(lastOuter, NSRange(location: 8, length: 6)) // " after"
        XCTAssertEqual(last.virtualRange.location, middle.virtualRange.location + middle.virtualRange.length)
        XCTAssertTrue(last.endsWithSearchBoundary)
        XCTAssertEqual(map.length, last.virtualRange.location + last.virtualRange.length)
    }

    // MARK: - 3. Table at document start/end — no empty chunks

    func testTableAtDocumentStartHasNoLeadingEmptyChunk() {
        let table = tableAttachment("grid")
        let map = ViewerFindChunkMap(outerString: doc([table, "after"]))

        XCTAssertEqual(map.chunks.count, 2)
        guard case .table = map.chunks[0].source else { return XCTFail("expected .table first") }
        guard case let .outer(range) = map.chunks[1].source else { return XCTFail("expected .outer second") }
        XCTAssertEqual(range, NSRange(location: 1, length: 5)) // "after"
    }

    func testTableAtDocumentEndHasNoTrailingEmptyChunk() {
        let table = tableAttachment("grid")
        let map = ViewerFindChunkMap(outerString: doc(["before", table]))

        XCTAssertEqual(map.chunks.count, 2)
        guard case let .outer(range) = map.chunks[0].source else { return XCTFail("expected .outer first") }
        XCTAssertEqual(range, NSRange(location: 0, length: 6)) // "before"
        guard case let .table(_, outerIndex) = map.chunks[1].source else { return XCTFail("expected .table second") }
        XCTAssertEqual(outerIndex, 6)
    }

    // MARK: - 4. Consecutive tables — no gap chunk between them

    func testConsecutiveTablesHaveNoGapChunk() {
        let tableA = tableAttachment("gridA")
        let tableB = tableAttachment("gridB")
        let map = ViewerFindChunkMap(outerString: doc(["before", tableA, tableB, "after"]))

        XCTAssertEqual(map.chunks.count, 4)
        guard case let .table(attachmentA, outerIndexA) = map.chunks[1].source
        else { return XCTFail("expected .table A") }
        guard case let .table(attachmentB, outerIndexB) = map.chunks[2].source
        else { return XCTFail("expected .table B") }
        XCTAssertTrue(attachmentA === tableA)
        XCTAssertTrue(attachmentB === tableB)
        XCTAssertEqual(outerIndexB, outerIndexA + 1) // back to back in outer storage
        XCTAssertEqual(
            map.chunks[2].virtualRange.location,
            map.chunks[1].virtualRange.location + map.chunks[1].virtualRange.length
        ) // back to back in virtual space too
    }

    // MARK: - 5. Table-only document

    func testTableOnlyDocument() {
        let table = tableAttachment("solo grid")
        let map = ViewerFindChunkMap(outerString: doc([table]))

        XCTAssertEqual(map.chunks.count, 1)
        guard case let .table(attachment, outerIndex) = map.chunks[0].source else { return XCTFail("expected .table") }
        XCTAssertTrue(attachment === table)
        XCTAssertEqual(outerIndex, 0)
        XCTAssertEqual(map.length, (table.grid.string as NSString).length)
    }

    // MARK: - 6. Non-table (image) attachment stays embedded in the outer chunk

    func testImageAttachmentStaysInOuterChunk() {
        let image = NSTextAttachment(data: nil, ofType: nil)
        let attributed = doc(["before ", image, " after"])
        let map = ViewerFindChunkMap(outerString: attributed)

        XCTAssertEqual(map.chunks.count, 1, "the image placeholder must not split the outer chunk")
        XCTAssertEqual(map.length, attributed.length)
        guard case let .outer(range) = map.chunks[0].source else { return XCTFail("expected .outer") }
        XCTAssertEqual(range, NSRange(location: 0, length: attributed.length))
        XCTAssertTrue(map.chunks[0].text.contains("\u{FFFC}"), "the placeholder character must remain in place")
    }

    // MARK: - 7. chunk(at:) at the 3 points around a chunk boundary

    func testChunkAtBoundaryThreePoints() {
        let table = tableAttachment("XY") // 2-character grid, virtual span length 2
        let attributed = doc(["abc", table, "de"])
        let map = ViewerFindChunkMap(outerString: attributed)
        // virtual layout: "abc" [0,3) | table "XY" [3,5) | "de" [5,7)

        let lastOfProse = map.chunk(at: 2) // 'c', last character of the first chunk
        guard case .outer = lastOfProse.source else { return XCTFail("expected .outer") }
        XCTAssertEqual(lastOfProse.virtualRange, NSRange(location: 0, length: 3))

        let boundary = map.chunk(at: 3) // the boundary index itself belongs to the next chunk
        guard case .table = boundary.source else { return XCTFail("expected .table") }
        XCTAssertEqual(boundary.virtualRange, NSRange(location: 3, length: 2))

        let insideTable = map.chunk(at: 4) // strictly inside the table chunk
        guard case .table = insideTable.source else { return XCTFail("expected .table") }
        XCTAssertEqual(insideTable.virtualRange, NSRange(location: 3, length: 2))
    }

    // MARK: - 8. Tiling invariant

    func testChunksTileWithoutGapsOverlapsOrEmptySpans() {
        let tableA = tableAttachment("gridA")
        let tableB = tableAttachment("gridB longer text")
        let image = NSTextAttachment(data: nil, ofType: nil)
        let attributed = doc(["start ", tableA, " middle ", image, tableB, " end"])
        let map = ViewerFindChunkMap(outerString: attributed)

        XCTAssertFalse(map.chunks.isEmpty)
        var cursor = 0
        for chunk in map.chunks {
            XCTAssertGreaterThan(chunk.virtualRange.length, 0, "no empty chunks")
            XCTAssertEqual(chunk.virtualRange.location, cursor, "no gaps or overlaps")
            XCTAssertEqual(chunk.virtualRange.length, chunk.text.length, "range must match the chunk's own text")
            XCTAssertTrue(chunk.endsWithSearchBoundary)
            cursor += chunk.virtualRange.length
        }
        XCTAssertEqual(cursor, map.length, "chunks must tile the full [0, length) span")
    }

    // MARK: - 9. resolve() at a boundary vs. spanning across one

    func testResolveAtBoundaryAndAcrossBoundaryIsMixed() {
        let table = tableAttachment("XY")
        let attributed = doc(["abc", table, "de"])
        let map = ViewerFindChunkMap(outerString: attributed)
        // virtual layout: "abc" [0,3) | table "XY" [3,5) | "de" [5,7)

        // Ends exactly at the boundary — fully inside the first chunk, not spanning.
        switch map.resolve(NSRange(location: 0, length: 3)) {
        case let .outer(range): XCTAssertEqual(range, NSRange(location: 0, length: 3))
        default: XCTFail("expected .outer")
        }

        // Starts exactly at the boundary — fully inside the table chunk.
        switch map.resolve(NSRange(location: 3, length: 2)) {
        case let .table(_, local, outerIndex):
            XCTAssertEqual(local, NSRange(location: 0, length: 2))
            XCTAssertEqual(outerIndex, 3)
        default: XCTFail("expected .table")
        }

        // Spans from the prose chunk across the boundary into the table chunk.
        switch map.resolve(NSRange(location: 2, length: 2)) {
        case .mixed: break
        default: XCTFail("expected .mixed for a range spanning a chunk boundary")
        }
    }

    // MARK: - 10. virtualRange(fromOuter:) expansion + round trip through resolve()

    func testVirtualRangeFromOuterExpandsAcrossAttachmentAndRoundTrips() {
        let table = tableAttachment("cell one\tcell two")
        let attributed = doc(["before ", table, " after"])
        let map = ViewerFindChunkMap(outerString: attributed)
        let tableOuterIndex = 7 // right after "before "
        let gridLength = (table.grid.string as NSString).length

        // A collapsed cursor sitting on the placeholder character expands to
        // the table's whole virtual chunk — there's no finer-grained position
        // to address from the outer side alone.
        let expanded = map.virtualRange(fromOuter: NSRange(location: tableOuterIndex, length: 1))
        XCTAssertEqual(expanded, NSRange(location: 7, length: gridLength))

        switch map.resolve(expanded) {
        case let .table(attachment, local, outerIndex):
            XCTAssertTrue(attachment === table)
            XCTAssertEqual(local, NSRange(location: 0, length: gridLength))
            XCTAssertEqual(outerIndex, tableOuterIndex)
        default: XCTFail("expected .table")
        }

        // A selection entirely inside surrounding prose maps 1:1 (accounting
        // for the earlier table's virtual/outer length delta) and round-trips
        // back to the same outer range.
        let outerAfterRange = NSRange(location: tableOuterIndex + 2, length: 4) // "afte" inside " after"
        let proseVirtual = map.virtualRange(fromOuter: outerAfterRange)
        switch map.resolve(proseVirtual) {
        case let .outer(range): XCTAssertEqual(range, outerAfterRange)
        default: XCTFail("expected .outer")
        }
    }

    // MARK: - 11. Emoji / Hangul UTF-16 offsets

    func testEmojiAndHangulUseUTF16Offsets() {
        let prefix = "😀한글 " // 2 (surrogate pair) + 2 (Hangul syllables) + 1 (space) = 5 UTF-16 units
        let table = tableAttachment("한\t🎉")
        let attributed = doc([prefix, table])
        let map = ViewerFindChunkMap(outerString: attributed)

        XCTAssertEqual((prefix as NSString).length, 5)
        XCTAssertEqual(map.chunks[0].virtualRange, NSRange(location: 0, length: 5))

        guard case let .table(_, outerIndex) = map.chunks[1].source else { return XCTFail("expected .table") }
        XCTAssertEqual(outerIndex, 5, "outer index must count UTF-16 units, not grapheme clusters")

        let gridLength = (table.grid.string as NSString).length // "한" (1) + "\t" (1) + "🎉" (2) = 4
        XCTAssertEqual(gridLength, 4)
        XCTAssertEqual(map.chunks[1].virtualRange, NSRange(location: 5, length: 4))
        XCTAssertEqual(map.length, 9)
    }

    // MARK: - 12. Empty document

    func testEmptyDocument() {
        let map = ViewerFindChunkMap(outerString: NSAttributedString())

        XCTAssertEqual(map.length, 0)
        XCTAssertTrue(map.chunks.isEmpty)
        switch map.resolve(NSRange(location: 0, length: 0)) {
        case let .outer(range): XCTAssertEqual(range, NSRange(location: 0, length: 0))
        default: XCTFail("expected .outer for an empty document")
        }
        XCTAssertEqual(map.virtualRange(fromOuter: NSRange(location: 0, length: 0)), NSRange(location: 0, length: 0))
        XCTAssertEqual(
            map.maximalOuterViewVirtualRange(containing: 0, isTableLoaded: { _ in false }),
            NSRange(location: 0, length: 0)
        )
    }

    // MARK: - 13. maximalOuterViewVirtualRange — loaded vs. unloaded tables

    func testMaximalOuterViewRangeMergesUnloadedTablesAndSurroundingProse() {
        let tableA = tableAttachment("A grid")
        let tableB = tableAttachment("B grid")
        let attributed = doc(["start ", tableA, " middle ", tableB, " end"])
        let map = ViewerFindChunkMap(outerString: attributed)
        let middleChunk = map.chunks[2] // "start "[0] tableA[1] " middle "[2] tableB[3] " end"[4]

        // Nothing is loaded: the whole document is displayed by the single
        // outer view, so the merge must reach both document edges.
        let range = map.maximalOuterViewVirtualRange(
            containing: middleChunk.virtualRange.location,
            isTableLoaded: { _ in false }
        )
        XCTAssertEqual(range, NSRange(location: 0, length: map.length))
    }

    func testMaximalOuterViewRangeStopsAtALoadedTable() {
        let tableA = tableAttachment("A grid")
        let tableB = tableAttachment("B grid")
        let attributed = doc(["start ", tableA, " middle ", tableB, " end"])
        let map = ViewerFindChunkMap(outerString: attributed)
        let middleChunk = map.chunks[2]

        // tableA has loaded its own inner view; tableB hasn't. The merge must
        // stop at tableA's boundary but still absorb tableB and the trailing
        // prose on the other side.
        let range = map.maximalOuterViewVirtualRange(
            containing: middleChunk.virtualRange.location,
            isTableLoaded: { $0 === tableA }
        )
        XCTAssertEqual(range.location, middleChunk.virtualRange.location)
        XCTAssertEqual(range.location + range.length, map.length)

        // Starting inside the loaded table itself returns just that table's
        // own chunk — callers are expected to route to its inner view instead.
        guard case let .table(_, tableAOuterIndex) = map.chunks[1].source else { return XCTFail("expected .table") }
        let insideLoaded = map.virtualRange(fromOuter: NSRange(location: tableAOuterIndex, length: 1))
        let selfRange = map.maximalOuterViewVirtualRange(
            containing: insideLoaded.location,
            isTableLoaded: { $0 === tableA }
        )
        XCTAssertEqual(selfRange, map.chunks[1].virtualRange)
    }

    // MARK: - 14. Renderer integration: wide table renders, maps, resolves as .table

    func testRendererIntegrationWideTableCellResolvesAsTable() {
        let renderer = MarkdownRenderer(baseURL: nil)
        let wide = String(repeating: "very wide cell content", count: 8)
        let source = "before\n\n| Name | Value |\n| ---- | ----- |\n| \(wide) | 1 |\n\nafter"
        let rendered = renderer.render(source)

        let map = ViewerFindChunkMap(outerString: rendered)
        guard let tableChunk = map.chunks.first(where: {
            if case .table = $0.source { return true }
            return false
        }) else { return XCTFail("expected a .table chunk for the wide table") }

        let needleRange = (tableChunk.text as String as NSString).range(of: wide)
        XCTAssertNotEqual(needleRange.location, NSNotFound)

        let virtualNeedle = NSRange(
            location: tableChunk.virtualRange.location + needleRange.location,
            length: needleRange.length
        )
        switch map.resolve(virtualNeedle) {
        case let .table(_, local, _):
            XCTAssertEqual(local, needleRange)
        default:
            XCTFail("expected the wide cell's text to resolve as .table")
        }
    }

    // MARK: - Finder client: ObjC runtime exposure

    // NSTextFinder discovers the client's optional protocol members via
    // respondsToSelector, not Swift witness tables. A "near miss" — e.g. a
    // `stringLength` *property* where the requirement is a *method* — compiles
    // without error but leaves the selector unexposed, and since the client
    // deliberately never implements `string`, every search would silently
    // return zero matches (regression: 설계/zebra searches showed 0).
    func testFinderClientExposesRequiredSelectorsToObjCRuntime() {
        let textView = ViewerTextView(usingTextLayoutManager: true)
        let client = ViewerTextFinderClient(textView: textView)

        for selector in [
            "stringLength",
            "stringAtIndex:effectiveRange:endsWithSearchBoundary:",
            "firstSelectedRange",
            "selectedRanges",
            "setSelectedRanges:",
            "scrollRangeToVisible:",
            "contentViewAtIndex:effectiveCharacterRange:",
            "rectsForCharacterRange:",
            "drawCharactersInRange:forContentView:",
            "visibleCharacterRanges",
            "isSelectable",
            "isEditable",
            "allowsMultipleSelection",
        ] {
            XCTAssertTrue(client.responds(to: Selector((selector))), "missing @objc exposure: \(selector)")
        }
        XCTAssertFalse(
            client.responds(to: Selector(("string"))),
            "`string` must stay unimplemented so chunk search boundaries can't be bypassed"
        )
    }

    // Walks the entire virtual string through the same chunked API
    // NSTextFinder uses, asserting the chunks tile it exactly and that both
    // prose and wide-table text (including non-ASCII) come back out.
    func testFinderClientServesTheWholeVirtualStringInChunks() {
        let wide = String(repeating: "wide cell content ", count: 8)
        let source = "before 설계\n\n| Name | Value |\n| ---- | ----- |\n| \(wide) | zebra |\n\nafter"
        let textView = ViewerTextView(usingTextLayoutManager: true)
        textView.textStorage?.setAttributedString(MarkdownRenderer(baseURL: nil).render(source))
        let client = ViewerTextFinderClient(textView: textView)

        let length = client.stringLength()
        XCTAssertGreaterThan(length, 0)

        var assembled = ""
        var index = 0
        while index < length {
            var effective = NSRange(location: NSNotFound, length: 0)
            var boundary = ObjCBool(false)
            assembled += client.string(at: index, effectiveRange: &effective, endsWithSearchBoundary: &boundary)
            XCTAssertEqual(effective.location, index, "chunks must tile the virtual space in order")
            XCTAssertGreaterThan(effective.length, 0)
            index = effective.location + effective.length
        }
        XCTAssertEqual(index, length)
        XCTAssertTrue(assembled.contains("설계"), "prose must be searchable")
        XCTAssertTrue(assembled.contains("zebra"), "wide-table cell text must be searchable")
    }
}
