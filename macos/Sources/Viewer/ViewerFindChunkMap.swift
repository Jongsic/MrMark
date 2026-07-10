import AppKit

/// Pure mapping between the viewer's "virtual" find coordinate space and the
/// two real coordinate spaces NSTextFinder must read from. The virtual space
/// is the outer rendered text with each TableAttachment's U+FFFC placeholder
/// replaced by that table's own grid string — this is what makes a wide
/// table's cell text searchable even though the attachment collapses it to a
/// single character in the outer text storage.
///
/// No view or text-system type is touched here, so the whole mapping is
/// unit-testable without building any UI (see ViewerFindChunkMapTests).
/// ViewerTextFinderClient owns an immutable snapshot of this map and rebuilds
/// it lazily after invalidateMap() (see setContent in ViewerViewController).
struct ViewerFindChunkMap {
    /// One contiguous span of the virtual string, backed by either outer prose
    /// or a single table's grid. Chunks tile [0, length) with no gaps,
    /// overlaps, or empty spans.
    struct Chunk {
        enum Source {
            /// A span of the outer text storage, untouched — including any
            /// non-table attachment characters (e.g. images).
            case outer(NSRange)
            /// A table's grid string, substituted in place of the single
            /// U+FFFC character at `outerIndex` in the outer text storage.
            case table(TableAttachment, outerIndex: Int)
        }

        let virtualRange: NSRange
        let text: NSString
        let source: Source
        /// Always true here: every chunk boundary is a source transition
        /// (prose can only be interrupted by inserting a table chunk), so a
        /// search match may never span from one chunk into the next.
        let endsWithSearchBoundary: Bool

        /// This chunk's span in outer-storage coordinates: the stored range
        /// for prose, or the attachment's single placeholder character for a
        /// table.
        var outerSpan: NSRange {
            switch source {
            case let .outer(range):
                range
            case let .table(_, outerIndex):
                NSRange(location: outerIndex, length: 1)
            }
        }
    }

    /// Where a virtual range's content actually lives.
    enum Resolution {
        case outer(NSRange)
        case table(TableAttachment, local: NSRange, outerIndex: Int)
        /// Defensive fallback for a range spanning a chunk boundary — should
        /// be unreachable given `endsWithSearchBoundary`, but resolve() must
        /// not crash if it's ever handed such a range.
        case mixed
    }

    let chunks: [Chunk]
    let length: Int

    init(outerString: NSAttributedString) {
        let full = NSRange(location: 0, length: outerString.length)
        let flatString = outerString.string as NSString
        var built: [Chunk] = []
        var virtualCursor = 0
        var pendingOuterStart = 0

        func flushOuterSpan(upTo outerEnd: Int) {
            guard outerEnd > pendingOuterStart else { return } // no empty chunks
            let outerRange = NSRange(location: pendingOuterStart, length: outerEnd - pendingOuterStart)
            let text = flatString.substring(with: outerRange) as NSString
            built.append(Chunk(
                virtualRange: NSRange(location: virtualCursor, length: text.length),
                text: text,
                source: .outer(outerRange),
                endsWithSearchBoundary: true
            ))
            virtualCursor += text.length
        }

        if full.length > 0 {
            outerString.enumerateAttribute(.attachment, in: full) { value, range, _ in
                guard let table = value as? TableAttachment else { return } // images stay embedded in outer text
                flushOuterSpan(upTo: range.location)
                let gridText = table.grid.string as NSString
                if gridText.length > 0 { // no empty chunks
                    built.append(Chunk(
                        virtualRange: NSRange(location: virtualCursor, length: gridText.length),
                        text: gridText,
                        source: .table(table, outerIndex: range.location),
                        endsWithSearchBoundary: true
                    ))
                    virtualCursor += gridText.length
                }
                pendingOuterStart = range.location + range.length
            }
            flushOuterSpan(upTo: full.length)
        }

        chunks = built
        length = virtualCursor
    }

    // MARK: - Lookup

    /// The chunk containing `virtualIndex`, clamped to the last chunk for an
    /// end-of-document index (e.g. the caret after the final character).
    /// Returns a synthetic empty chunk for an empty map rather than crashing.
    func chunk(at virtualIndex: Int) -> Chunk {
        guard !chunks.isEmpty else {
            return Chunk(
                virtualRange: NSRange(location: 0, length: 0),
                text: "",
                source: .outer(NSRange(location: 0, length: 0)),
                endsWithSearchBoundary: true
            )
        }
        return chunks[chunkIndex(at: virtualIndex)]
    }

    /// Maps a virtual-space match/selection range back to the real content it
    /// came from.
    func resolve(_ range: NSRange) -> Resolution {
        guard !chunks.isEmpty else { return .outer(NSRange(location: 0, length: 0)) }
        let startChunk = chunk(at: range.location)
        let chunkEnd = startChunk.virtualRange.location + startChunk.virtualRange.length
        guard range.location + range.length <= chunkEnd else { return .mixed }

        let offset = range.location - startChunk.virtualRange.location
        switch startChunk.source {
        case let .outer(outerRange):
            return .outer(NSRange(location: outerRange.location + offset, length: range.length))
        case let .table(attachment, outerIndex):
            return .table(attachment, local: NSRange(location: offset, length: range.length), outerIndex: outerIndex)
        }
    }

    /// Converts a selection expressed in the outer text view's own storage
    /// coordinates into virtual coordinates. A selection touching a table's
    /// placeholder character can't address a position inside its substituted
    /// grid text, so any endpoint landing on one expands to that table's
    /// whole chunk (used for Cmd-E "use selection for find" against the outer
    /// view's native selection).
    func virtualRange(fromOuter outerRange: NSRange) -> NSRange {
        guard !chunks.isEmpty else { return NSRange(location: 0, length: 0) }

        // Only a table's chunk needs to snap to its full virtual span — a
        // single outer-storage offset can't address a position inside its
        // substituted grid text. Plain outer prose maps its exact offset
        // within the chunk, so a range that never touches a table round-trips
        // through resolve() unchanged instead of snapping to whole chunks.
        func virtualStart(forOuterIndex outerIndex: Int) -> Int {
            let chunk = chunk(forOuterIndex: outerIndex)
            switch chunk.source {
            case .outer:
                return chunk.virtualRange.location + (outerIndex - chunk.outerSpan.location)
            case .table:
                return chunk.virtualRange.location
            }
        }
        // The exclusive end boundary itself doesn't identify its owning chunk
        // unambiguously when it lands exactly on a chunk transition (it would
        // naively match the *next* chunk's start) — so the owning chunk is the
        // one containing the last actually-included index, `outerExclusiveEnd
        // - 1`, but the arithmetic still uses the boundary position itself so
        // an .outer chunk's exact offset is preserved rather than trimmed by
        // one character.
        func virtualEnd(forOuterExclusiveEnd outerExclusiveEnd: Int) -> Int {
            let chunk = chunk(forOuterIndex: outerExclusiveEnd - 1)
            switch chunk.source {
            case .outer:
                return chunk.virtualRange.location + (outerExclusiveEnd - chunk.outerSpan.location)
            case .table:
                return chunk.virtualRange.location + chunk.virtualRange.length
            }
        }

        let start = virtualStart(forOuterIndex: outerRange.location)
        let outerEnd = outerRange.location + outerRange.length
        let end = outerRange.length > 0 ? virtualEnd(forOuterExclusiveEnd: outerEnd) : start
        return NSRange(location: start, length: end - start)
    }

    /// Converts a selection expressed in one table's inner grid-text
    /// coordinates into virtual coordinates. Direct 1:1 mapping — unlike the
    /// outer case there's no ambiguity, since the inner view only ever
    /// addresses its own grid string.
    func virtualRange(fromGridLocal localRange: NSRange, attachment: TableAttachment) -> NSRange {
        guard let match = chunks.first(where: {
            if case let .table(candidate, _) = $0.source { return candidate === attachment }
            return false
        }) else { return NSRange(location: 0, length: 0) }
        return NSRange(location: match.virtualRange.location + localRange.location, length: localRange.length)
    }

    /// The maximal virtual range around `virtualIndex` that the outer view is
    /// responsible for displaying: this chunk plus any adjacent chunks that
    /// are either outer prose or a table whose inner view hasn't loaded yet
    /// (nothing distinct is on screen for those, so contentView(at:) must
    /// still report the outer view for them). Stops at the first loaded
    /// table's chunk boundary, since that table has its own view.
    /// `isTableLoaded` is injected so this is testable without any real view.
    func maximalOuterViewVirtualRange(
        containing virtualIndex: Int,
        isTableLoaded: (TableAttachment) -> Bool
    ) -> NSRange {
        guard !chunks.isEmpty else { return NSRange(location: 0, length: 0) }

        func isOuterTerritory(_ chunk: Chunk) -> Bool {
            switch chunk.source {
            case .outer:
                true
            case let .table(attachment, _):
                !isTableLoaded(attachment)
            }
        }

        let startIdx = chunkIndex(at: virtualIndex)
        guard isOuterTerritory(chunks[startIdx]) else { return chunks[startIdx].virtualRange }

        var lo = startIdx
        while lo > 0, isOuterTerritory(chunks[lo - 1]) {
            lo -= 1
        }
        var hi = startIdx
        while hi < chunks.count - 1, isOuterTerritory(chunks[hi + 1]) {
            hi += 1
        }

        let start = chunks[lo].virtualRange.location
        let end = chunks[hi].virtualRange.location + chunks[hi].virtualRange.length
        return NSRange(location: start, length: end - start)
    }

    // MARK: - Private helpers

    private func chunkIndex(at virtualIndex: Int) -> Int {
        chunks.firstIndex(where: { NSLocationInRange(virtualIndex, $0.virtualRange) }) ?? chunks.count - 1
    }

    private func chunk(forOuterIndex outerIndex: Int) -> Chunk {
        chunks.first(where: { NSLocationInRange(outerIndex, $0.outerSpan) }) ?? chunks[chunks.count - 1]
    }
}
