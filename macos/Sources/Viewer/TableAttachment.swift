import AppKit

/// A wide GFM table rendered as its own horizontally scrollable region. The
/// viewer's single text container wraps prose to the window, so a wide table
/// can't scroll on its own there — it becomes a view attachment whose inner
/// scroll view holds the grid. The table shows at its natural width and scrolls
/// once the window is narrower than that. Selection and copy of the table
/// happen inside the inner view; the outer find bar and selection treat the
/// whole table as one object — which is why only tables too wide for the
/// default window use this (MarkdownRenderer.renderTable); narrower ones stay
/// inline plain text.
final class TableAttachment: NSTextAttachment {
    let grid: NSAttributedString
    let naturalWidth: CGFloat
    let gridHeight: CGFloat

    /// Set by TableAttachmentViewProvider.loadView() once the table has
    /// scrolled into view and built its own text view; nil (and cleared
    /// automatically, being weak) whenever that view doesn't exist — before
    /// first load, or after it's torn down. ViewerTextFinderClient uses this
    /// to address the table's real content directly instead of degrading to
    /// this attachment's single placeholder character in the outer view.
    weak var loadedInnerTextView: TableGridTextView?

    /// A grid-local selection/reveal the find client wants applied once the
    /// inner view exists — recorded when a match lands in a table that
    /// hasn't loaded yet, consumed by TableAttachmentViewProvider.loadView().
    var pendingSelection: NSRange?
    var pendingReveal: NSRange?

    init(grid: NSAttributedString, naturalWidth: CGFloat, gridHeight: CGFloat) {
        self.grid = grid
        self.naturalWidth = naturalWidth
        self.gridHeight = gridHeight
        super.init(data: nil, ofType: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewProvider(
        for parentView: NSView?,
        location: NSTextLocation,
        textContainer: NSTextContainer?
    ) -> NSTextAttachmentViewProvider? {
        let provider = TableAttachmentViewProvider(
            textAttachment: self,
            parentView: parentView,
            textLayoutManager: textContainer?.textLayoutManager,
            location: location
        )
        provider.tracksTextAttachmentViewBounds = true
        return provider
    }
}

/// The wide table's own inner text view. `performTextFinderAction:` is an
/// NSResponder selector dispatched to whichever responder implements it, and
/// plain NSTextView doesn't meaningfully implement it for our custom finder —
/// without this override, clicking into a table and then hitting Cmd-F/G/E
/// would silently do nothing (a pre-existing defect fixed as a side effect of
/// this override existing at all). Forwarding up the superview chain to the
/// outer ViewerTextView routes them to the one real NSTextFinder instead.
final class TableGridTextView: NSTextView {
    override func performTextFinderAction(_ sender: Any?) {
        outerViewerTextView?.performTextFinderAction(sender)
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        // Same scoping as ViewerTextView: forward only find actions; edit
        // items keep NSTextView's own (read-only) validation.
        guard item.action == #selector(NSResponder.performTextFinderAction(_:)),
              let outer = outerViewerTextView
        else { return super.validateUserInterfaceItem(item) }
        return outer.validateUserInterfaceItem(item)
    }

    private var outerViewerTextView: ViewerTextView? {
        var candidate = superview
        while let view = candidate {
            if let viewerTextView = view as? ViewerTextView { return viewerTextView }
            candidate = view.superview
        }
        return nil
    }
}

/// Builds the inner scroll view lazily on the main thread the moment the table
/// scrolls into view — the renderer only ever carries the grid data, so large
/// documents can still render off the main thread.
private final class TableAttachmentViewProvider: NSTextAttachmentViewProvider {
    private var table: TableAttachment? {
        textAttachment as? TableAttachment
    }

    override func loadView() {
        guard let table else {
            view = NSView()
            return
        }

        let textView = TableGridTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 4, height: 2)
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = false
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.size = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textStorage?.setAttributedString(table.grid)
        textView.frame = NSRect(x: 0, y: 0, width: table.naturalWidth, height: table.gridHeight)
        // The outer scroll view owns file drops.
        textView.unregisterDraggedTypes()

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        view = scrollView

        table.loadedInnerTextView = textView
        if let pendingSelection = table.pendingSelection {
            textView.setSelectedRange(pendingSelection)
            table.pendingSelection = nil
        }
        if let pendingReveal = table.pendingReveal {
            table.pendingReveal = nil
            // The scroll view's geometry isn't finalized until the text
            // layout system positions this attachment's view (right after
            // loadView returns), so scrolling synchronously here would
            // measure against a stale/zero size.
            DispatchQueue.main.async { [weak textView] in
                textView?.scrollRangeToVisible(pendingReveal)
            }
        }
    }

    override func attachmentBounds(
        for attributes: [NSAttributedString.Key: Any],
        location: NSTextLocation,
        textContainer: NSTextContainer?,
        proposedLineFragment: CGRect,
        position: CGPoint
    ) -> CGRect {
        guard let table else { return .zero }
        // Cap the visible width to the container's usable line width — inside
        // the line-fragment padding, or the right edge clips. The inner text
        // view stays at its natural width, so anything past that edge scrolls.
        let padding = 2 * (textContainer?.lineFragmentPadding ?? 0)
        let available = (textContainer?.size.width ?? table.naturalWidth) - padding
        let width = min(table.naturalWidth, max(available, 0))
        return CGRect(x: 0, y: 0, width: width, height: table.gridHeight)
    }
}
