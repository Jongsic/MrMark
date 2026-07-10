import AppKit

/// NSTextFinderClient bridging the viewer's find UI to text that spans both
/// the outer NSTextView's own storage and each wide table's separate inner
/// grid text. NSTextView doesn't publicly conform to NSTextFinderClient, so
/// none of this can simply forward to it — everything here is built from
/// ViewerFindChunkMap's coordinate mapping instead.
///
/// Only `stringLength` + `string(at:effectiveRange:endsWithSearchBoundary:)`
/// are implemented for content access — never `string` (see the chunk map's
/// own doc comment: a flattened string would defeat the whole point of
/// chunking and silently drop table cell text from search again).
///
/// A table's own content (rects, contentView, scroll, selection) is only
/// addressable once `TableAttachment.loadedInnerTextView` exists — until a
/// table's provider has built its inner view, those paths degrade to
/// reporting the attachment's single placeholder character in the outer view,
/// which self-corrects within a frame once the table scrolls into view.
final class ViewerTextFinderClient: NSObject, NSTextFinderClient {
    private weak var textView: ViewerTextView?

    init(textView: ViewerTextView) {
        self.textView = textView
        super.init()
        // object: nil — a loaded table's own inner view also needs watching
        // (firstSelectedRange must reflect a manual selection made directly
        // inside a table, not just outer/find-driven ones), and there's no
        // stable set of inner views to target individually since tables load
        // and unload as they scroll through the viewport. The handler filters
        // to this window's own outer/inner views before doing anything.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(textViewSelectionDidChange(_:)),
            name: NSTextView.didChangeSelectionNotification,
            object: nil
        )
        syncSelectionFromOuter()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Chunk map

    // Lazy + atomically replaced: NSTextFinder's incremental search reads
    // strings from a background queue, so building/discarding the snapshot is
    // guarded by a lock even though each returned snapshot is itself immutable
    // and safe to read from any thread without further synchronization.
    private let mapLock = NSLock()
    private var cachedMap: ViewerFindChunkMap?

    private var map: ViewerFindChunkMap {
        mapLock.lock()
        defer { mapLock.unlock() }
        if let cachedMap { return cachedMap }
        let built = ViewerFindChunkMap(outerString: textView?.textStorage ?? NSAttributedString())
        cachedMap = built
        return built
    }

    /// Must be called after `NSTextFinder.noteClientStringWillChange()` and
    /// before the text storage is actually mutated (see
    /// ViewerViewController.setContent) so the next access rebuilds from the
    /// fresh content instead of serving a snapshot of storage that's about to
    /// go stale.
    func invalidateMap() {
        mapLock.lock()
        defer { mapLock.unlock() }
        cachedMap = nil
    }

    // MARK: - Selection

    // Single source of truth for firstSelectedRange — a table match with no
    // other tracked selection would otherwise send Cmd-G into an infinite loop.
    private var currentVirtualSelection = NSRange(location: 0, length: 0)
    private var isProgrammaticSelection = false

    /// The inner table view an outer→table selection move last selected into,
    /// so the next move away (to prose or a different table) can clear it —
    /// otherwise a stale blue selection would linger inside a table nobody's
    /// pointing at anymore.
    private weak var lastSelectedInnerView: TableGridTextView?

    private func clearStaleInnerSelection(keeping keptView: TableGridTextView?) {
        guard let stale = lastSelectedInnerView, stale !== keptView else { return }
        stale.setSelectedRange(NSRange(location: 0, length: 0))
    }

    @objc
    private func textViewSelectionDidChange(_ notification: Notification) {
        guard !isProgrammaticSelection, let textView,
              let changedView = notification.object as? NSTextView else { return }
        if changedView === textView {
            syncSelectionFromOuter()
        } else if let innerView = changedView as? TableGridTextView, innerView.window != nil,
                  innerView.window === textView.window
        {
            syncSelectionFromInner(innerView)
        }
    }

    private func syncSelectionFromOuter() {
        guard let textView else { return }
        currentVirtualSelection = map.virtualRange(fromOuter: textView.selectedRange())
    }

    private func syncSelectionFromInner(_ innerView: TableGridTextView) {
        guard let attachment = tableAttachment(loadedAs: innerView) else { return }
        currentVirtualSelection = map.virtualRange(fromGridLocal: innerView.selectedRange(), attachment: attachment)
        lastSelectedInnerView = innerView
    }

    private func tableAttachment(loadedAs innerView: TableGridTextView) -> TableAttachment? {
        for chunk in map.chunks {
            if case let .table(attachment, _) = chunk.source, attachment.loadedInnerTextView === innerView {
                return attachment
            }
        }
        return nil
    }

    // MARK: - NSTextFinderClient

    var isSelectable: Bool {
        true
    }

    var isEditable: Bool {
        false
    }

    var allowsMultipleSelection: Bool {
        false
    }

    // Declared as a method, not a property: the protocol requirement is
    // `func stringLength()`, and NSTextFinder discovers these optional members
    // via respondsToSelector — a property "near miss" compiles fine but leaves
    // the selector unexposed, and with no `string` fallback every search would
    // silently return zero matches.
    func stringLength() -> Int {
        map.length
    }

    func string(
        at characterIndex: Int,
        effectiveRange outRange: NSRangePointer,
        endsWithSearchBoundary outFlag: UnsafeMutablePointer<ObjCBool>
    ) -> String {
        let chunk = map.chunk(at: characterIndex)
        outRange.pointee = chunk.virtualRange
        outFlag.pointee = ObjCBool(chunk.endsWithSearchBoundary)
        return chunk.text as String
    }

    var firstSelectedRange: NSRange {
        currentVirtualSelection
    }

    var selectedRanges: [NSValue] {
        get { [NSValue(range: currentVirtualSelection)] }
        set {
            guard let outerTextView = textView, let first = newValue.first?.rangeValue else { return }
            // The map may have been rebuilt since NSTextFinder computed this
            // range against an older one — drop it rather than resolve garbage.
            guard first.location + first.length <= map.length else { return }

            isProgrammaticSelection = true
            defer { isProgrammaticSelection = false }

            switch map.resolve(first) {
            case let .outer(outerRange):
                currentVirtualSelection = first
                outerTextView.setSelectedRange(outerRange)
                clearStaleInnerSelection(keeping: nil)
                lastSelectedInnerView = nil
            case let .table(attachment, local, outerIndex):
                currentVirtualSelection = first
                // Collapse the outer selection instead of highlighting the
                // attachment character itself — a stray selected-placeholder
                // box would look broken. The real selection shows inside the
                // table's own inner view instead.
                outerTextView.setSelectedRange(NSRange(location: outerIndex, length: 0))
                if let innerView = attachment.loadedInnerTextView {
                    clearStaleInnerSelection(keeping: innerView)
                    innerView.setSelectedRange(local)
                    lastSelectedInnerView = innerView
                } else {
                    clearStaleInnerSelection(keeping: nil)
                    lastSelectedInnerView = nil
                    attachment.pendingSelection = local
                }
            case .mixed:
                break
            }
        }
    }

    func scrollRangeToVisible(_ range: NSRange) {
        guard let outerTextView = textView, let textLayoutManager = outerTextView.textLayoutManager else { return }
        switch map.resolve(range) {
        case let .outer(outerRange):
            outerTextView.scrollRangeToVisible(outerRange)
        case let .table(attachment, local, outerIndex):
            outerTextView.scrollRangeToVisible(NSRange(location: outerIndex, length: 1))
            // Materialize the attachment's provider view NOW: the finder
            // snapshots its found-indicator (rects + drawn text) right after
            // this call returns, so the inner view must exist and be scrolled
            // by then — otherwise the indicator freezes as a whole-table
            // fallback block. loadView() runs inside viewport layout.
            textLayoutManager.textViewportLayoutController.layoutViewport()
            if attachment.loadedInnerTextView == nil {
                outerTextView.layoutSubtreeIfNeeded()
                textLayoutManager.textViewportLayoutController.layoutViewport()
            }
            if let innerView = attachment.loadedInnerTextView {
                attachment.pendingReveal = nil
                innerView.scrollRangeToVisible(local)
            } else {
                // Still deferred (shouldn't happen after a targeted scroll) —
                // fall back to consuming the reveal on a later run-loop turn.
                attachment.pendingReveal = local
                retryInnerReveal(attachment: attachment, attemptsRemaining: 3)
            }
        case .mixed:
            break
        }
    }

    private func retryInnerReveal(attachment: TableAttachment, attemptsRemaining: Int) {
        if let innerView = attachment.loadedInnerTextView {
            // The common case: the table was already on screen, so loadView —
            // the other consumer of pendingReveal — will never run again and
            // the horizontal scroll must happen here. When loadView just ran
            // (and consumed the reveal itself), this finds nothing to do.
            guard let reveal = attachment.pendingReveal else { return }
            attachment.pendingReveal = nil
            innerView.scrollRangeToVisible(reveal)
            return
        }
        guard attemptsRemaining > 0 else {
            // Give up: the outer scroll above already shows the table region.
            // Clear the reveal so it can't fire as a surprise scroll when the
            // user happens to bring this table into view much later.
            attachment.pendingReveal = nil
            return
        }
        RunLoop.main.perform { [weak self] in
            self?.retryInnerReveal(attachment: attachment, attemptsRemaining: attemptsRemaining - 1)
        }
    }

    func contentView(at index: Int, effectiveCharacterRange outRange: NSRangePointer) -> NSView {
        guard let outerTextView = textView else { return NSView() }
        let chunk = map.chunk(at: index)
        if case let .table(attachment, _) = chunk.source, let innerView = attachment.loadedInnerTextView {
            outRange.pointee = chunk.virtualRange
            return innerView
        }
        let range = map.maximalOuterViewVirtualRange(
            containing: index,
            isTableLoaded: { $0.loadedInnerTextView != nil }
        )
        outRange.pointee = range
        return outerTextView
    }

    func rects(forCharacterRange range: NSRange) -> [NSValue]? {
        switch map.resolve(range) {
        case let .outer(outerRange):
            return outerRects(forOuter: outerRange)
        case let .table(attachment, local, outerIndex):
            if let innerView = attachment.loadedInnerTextView {
                return innerRects(forGridLocal: local, in: innerView)
            }
            // Degraded: not loaded yet — report the attachment character's
            // own segment in the outer view (the whole table shows).
            return outerRects(forOuter: NSRange(location: outerIndex, length: 1))
        case .mixed:
            return nil
        }
    }

    private func outerRects(forOuter outerRange: NSRange) -> [NSValue]? {
        guard let outerTextView = textView, let textLayoutManager = outerTextView.textLayoutManager,
              let textRange = textLayoutManager.textRange(fromOuter: outerRange)
        else { return nil }

        var rects: [NSValue] = []
        textLayoutManager.enumerateTextSegments(in: textRange, type: .highlight) { _, frame, _, _ in
            var adjusted = frame
            adjusted.origin.x += outerTextView.textContainerOrigin.x
            adjusted.origin.y += outerTextView.textContainerOrigin.y
            rects.append(NSValue(rect: adjusted))
            return true
        }
        return rects
    }

    /// TextKit 1: the cell's paragraph style is `.byClipping` (MarkdownRenderer's
    /// grid layout), so a range never wraps — one glyph run, one rect.
    private func innerRects(forGridLocal localRange: NSRange, in innerView: TableGridTextView) -> [NSValue]? {
        guard let layoutManager = innerView.layoutManager,
              let textContainer = innerView.textContainer else { return nil }
        let glyphRange = layoutManager.glyphRange(forCharacterRange: localRange, actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        rect.origin.x += innerView.textContainerOrigin.x
        rect.origin.y += innerView.textContainerOrigin.y
        return [NSValue(rect: rect)]
    }

    /// Draws the matched text into the finder's own highlight/lens overlay.
    /// Without this, the finder falls back to the content view's drawRect: —
    /// which renders nothing for a TextKit 2 NSTextView (its content doesn't
    /// go through classic drawRect), leaving blank yellow chips where the
    /// matched text should be. The finder clips to rects(forCharacterRange:),
    /// so drawing whole fragments/lines here is fine.
    func drawCharacters(in range: NSRange, forContentView view: NSView) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        switch map.resolve(range) {
        case let .outer(outerRange):
            guard let outerTextView = textView, view === outerTextView,
                  let layoutManager = outerTextView.textLayoutManager,
                  let textRange = layoutManager.textRange(fromOuter: outerRange)
            else { return }
            let origin = outerTextView.textContainerOrigin
            layoutManager.enumerateTextLayoutFragments(
                from: textRange.location,
                options: [.ensuresLayout]
            ) { fragment in
                let frame = fragment.layoutFragmentFrame
                fragment.draw(at: CGPoint(x: frame.minX + origin.x, y: frame.minY + origin.y), in: context)
                return fragment.rangeInElement.endLocation.compare(textRange.endLocation) == .orderedAscending
            }
        case let .table(attachment, local, outerIndex):
            if let innerView = attachment.loadedInnerTextView, view === innerView,
               let layoutManager = innerView.layoutManager, innerView.textContainer != nil
            {
                let glyphRange = layoutManager.glyphRange(forCharacterRange: local, actualCharacterRange: nil)
                let origin = innerView.textContainerOrigin
                layoutManager.drawBackground(forGlyphRange: glyphRange, at: origin)
                layoutManager.drawGlyphs(forGlyphRange: glyphRange, at: origin)
                return
            }
            // Degraded: the finder snapshotted this match against the outer
            // view while the table wasn't loaded yet, so its highlight covers
            // the whole attachment. Draw the grid there directly (offset by
            // the inner text inset the provider uses, and by the inner scroll
            // position when one exists) so the block shows the table's text
            // instead of a blank sheet of highlight color.
            guard let outerTextView = textView, view === outerTextView,
                  let attachmentRect = outerRects(forOuter: NSRange(location: outerIndex, length: 1))?
                  .first?.rectValue
            else { return }
            var origin = CGPoint(x: attachmentRect.minX + 4, y: attachmentRect.minY + 2)
            if let innerView = attachment.loadedInnerTextView {
                origin.x -= innerView.enclosingScrollView?.contentView.bounds.origin.x ?? 0
            }
            attachment.grid.draw(at: origin)
        case .mixed:
            break
        }
    }

    var visibleCharacterRanges: [NSValue] {
        guard let outerTextView = textView,
              let textLayoutManager = outerTextView.textLayoutManager,
              let viewportRange = textLayoutManager.textViewportLayoutController.viewportRange
        else { return [] }
        let outerViewport = textLayoutManager.outerRange(from: viewportRange)
        let viewportEnd = outerViewport.location + outerViewport.length

        var ranges: [NSRange] = []
        for chunk in map.chunks {
            let span = chunk.outerSpan
            let spanEnd = span.location + span.length
            guard span.location < viewportEnd,
                  spanEnd > outerViewport.location else { continue } // outside the viewport

            switch chunk.source {
            case .outer:
                // Precisely clip to the overlapping portion.
                let start = max(span.location, outerViewport.location)
                let end = min(spanEnd, viewportEnd)
                ranges.append(map.virtualRange(fromOuter: NSRange(location: start, length: end - start)))
            case let .table(attachment, _):
                // Unloaded tables are omitted entirely rather than counted as
                // fully visible — they self-correct within a frame once
                // entering the viewport triggers their provider to load.
                guard let innerView = attachment.loadedInnerTextView,
                      let layoutManager = innerView.layoutManager,
                      let textContainer = innerView.textContainer
                else { continue }
                let visibleGlyphs = layoutManager.glyphRange(forBoundingRect: innerView.visibleRect, in: textContainer)
                let visibleChars = layoutManager.characterRange(forGlyphRange: visibleGlyphs, actualGlyphRange: nil)
                ranges.append(map.virtualRange(fromGridLocal: visibleChars, attachment: attachment))
            }
        }
        return ranges.map { NSValue(range: $0) }
    }
}

extension NSTextLayoutManager {
    /// TextKit 2 has no direct NSRange↔NSTextRange convenience, so these walk
    /// `documentRange.location` via the NSTextSelectionDataSource offset API
    /// ViewerTextView already uses for the single-location case (see
    /// `copyButtonHit`).
    func textRange(fromOuter range: NSRange) -> NSTextRange? {
        guard let start = location(documentRange.location, offsetBy: range.location),
              let end = location(start, offsetBy: range.length)
        else { return nil }
        return NSTextRange(location: start, end: end)
    }

    func outerRange(from textRange: NSTextRange) -> NSRange {
        let location = offset(from: documentRange.location, to: textRange.location)
        let length = offset(from: textRange.location, to: textRange.endLocation)
        return NSRange(location: location, length: length)
    }
}
