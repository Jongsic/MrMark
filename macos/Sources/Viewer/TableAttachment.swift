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

        let textView = NSTextView()
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
