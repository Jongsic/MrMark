import AppKit

/// Hybrid Markdown editor (Typora-style): the paragraph holding the cursor
/// shows its Markdown source with live styling; everywhere else the syntax
/// delimiters (#, **, backticks, link chrome) are concealed and only the
/// styled text shows. The storage always holds the exact source. Created
/// lazily — only when the user enters edit mode — so the viewer fast path
/// never pays for any of this (AGENTS.md).
final class EditorViewController: NSViewController {
    private weak var document: MarkdownDocument?
    private var textView: NSTextView!
    private let highlighter = MarkdownSourceHighlighter()
    private var pendingDirtyRange: NSRange?

    /// The revealed (cursor) paragraph — everything outside it conceals its
    /// Markdown delimiters.
    private var activeParagraphRange = NSRange(location: 0, length: 0)

    /// Per-window text zoom, shared with the viewer through the window
    /// controller; never persisted.
    private(set) var zoomScale: CGFloat = 1

    var onZoomChanged: ((CGFloat) -> Void)?

    init(document: MarkdownDocument) {
        self.document = document
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        let textView = NSTextView(usingTextLayoutManager: true)
        textView.isEditable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 24, height: 24)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.typingAttributes = highlighter.baseAttributes

        // Smart substitutions corrupt Markdown syntax ("smart" quotes in code,
        // -- into em dash, etc.). All off.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false

        textView.delegate = self
        textView.textStorage?.delegate = self

        let scrollView = FileDropScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.onZoom = { [weak self] factor in
            guard let self else { return }
            setZoomScale(zoomScale * factor)
        }

        self.textView = textView
        view = scrollView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        reload()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(textView)
        LaunchClock.viewerDidAppear() // untitled documents launch straight into the editor
    }

    func reload() {
        textView.string = document?.text ?? ""
        if let storage = textView.textStorage {
            activeParagraphRange = (storage.string as NSString).paragraphRange(for: textView.selectedRange())
            highlighter.highlightAll(storage, revealing: activeParagraphRange)
        }
    }

    // MARK: - Zoom

    @objc func zoomIn(_ sender: Any?) {
        setZoomScale(zoomScale + TextZoom.step)
    }

    @objc func zoomOut(_ sender: Any?) {
        setZoomScale(zoomScale - TextZoom.step)
    }

    @objc func resetZoom(_ sender: Any?) {
        setZoomScale(1)
    }

    func setZoomScale(_ scale: CGFloat) {
        let clamped = min(max(scale, TextZoom.minimum), TextZoom.maximum)
        guard abs(clamped - zoomScale) > 0.001 else { return }
        zoomScale = clamped
        highlighter.scale = clamped
        onZoomChanged?(clamped)
        guard isViewLoaded else { return } // applied by the initial reload()
        textView.typingAttributes = highlighter.baseAttributes
        (view as? NSScrollView)?.preservingScrollFraction {
            if let storage = textView.textStorage {
                highlighter.highlightAll(storage, revealing: activeParagraphRange)
            }
        }
    }

    // MARK: - Formatting actions (toolbar + Format menu)

    @objc func toggleBold(_ sender: Any?) {
        applyFormatting { MarkdownFormatting.toggleInlineWrap($0, selection: $1, delimiter: "**") }
    }

    @objc func toggleItalic(_ sender: Any?) {
        applyFormatting { MarkdownFormatting.toggleInlineWrap($0, selection: $1, delimiter: "*") }
    }

    @objc func heading1(_ sender: Any?) {
        applyFormatting { MarkdownFormatting.setHeading($0, selection: $1, level: 1) }
    }

    @objc func heading2(_ sender: Any?) {
        applyFormatting { MarkdownFormatting.setHeading($0, selection: $1, level: 2) }
    }

    @objc func heading3(_ sender: Any?) {
        applyFormatting { MarkdownFormatting.setHeading($0, selection: $1, level: 3) }
    }

    @objc func toggleBulletList(_ sender: Any?) {
        applyFormatting { MarkdownFormatting.toggleBulletList($0, selection: $1) }
    }

    @objc func toggleNumberedList(_ sender: Any?) {
        applyFormatting { MarkdownFormatting.toggleNumberedList($0, selection: $1) }
    }

    @objc func toggleChecklist(_ sender: Any?) {
        applyFormatting { MarkdownFormatting.toggleChecklist($0, selection: $1) }
    }

    @objc func insertLink(_ sender: Any?) {
        applyFormatting { MarkdownFormatting.insertLink($0, selection: $1) }
    }

    @objc func insertImage(_ sender: Any?) {
        applyFormatting { MarkdownFormatting.insertImage($0, selection: $1) }
    }

    @objc func insertCodeBlock(_ sender: Any?) {
        applyFormatting { MarkdownFormatting.insertCodeBlock($0, selection: $1) }
    }

    private func applyFormatting(_ make: (NSString, NSRange) -> MarkdownFormatting.Edit) {
        guard let storage = textView.textStorage else { return }
        let edit = make(storage.string as NSString, textView.selectedRange())
        guard textView.shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return }
        storage.replaceCharacters(in: edit.range, with: edit.replacement)
        textView.didChangeText()
        textView.setSelectedRange(edit.selection)
    }
}

extension EditorViewController: DocumentContentController {}
extension EditorViewController: ZoomableContent {}

// MARK: - NSTextViewDelegate

extension EditorViewController: NSTextViewDelegate {
    /// Route undo through the document so dirty state and the
    /// close-with-unsaved prompt track edits for free.
    func undoManager(for view: NSTextView) -> UndoManager? {
        document?.undoManager
    }

    func textDidChange(_ notification: Notification) {
        document?.editorTextDidChange(textView.string)
    }

    /// Typora behavior: moving the cursor re-conceals the paragraph it left
    /// and reveals the source of the one it entered.
    func textViewDidChangeSelection(_ notification: Notification) {
        guard let storage = textView.textStorage else { return }
        let newActive = (storage.string as NSString).paragraphRange(for: textView.selectedRange())
        guard newActive != activeParagraphRange else { return }
        let previous = activeParagraphRange
        activeParagraphRange = newActive

        highlighter.highlight(storage, dirtyRange: previous, revealing: newActive)
        highlighter.highlight(storage, dirtyRange: newActive, revealing: newActive)
        // Never inherit concealed attributes (clear color, collapsed font)
        // from a neighboring hidden delimiter.
        textView.typingAttributes = highlighter.baseAttributes
    }
}

// MARK: - NSTextStorageDelegate (live restyle)

extension EditorViewController: NSTextStorageDelegate {
    func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        guard editedMask.contains(.editedCharacters) else { return }

        // Attribute edits are not allowed while the storage is processing;
        // coalesce and restyle on the next runloop turn.
        if let pending = pendingDirtyRange {
            pendingDirtyRange = NSUnionRange(pending, editedRange)
            return
        }
        pendingDirtyRange = editedRange
        DispatchQueue.main.async { [weak self] in
            guard let self, let storage = textView.textStorage, let dirty = pendingDirtyRange else { return }
            pendingDirtyRange = nil
            activeParagraphRange = (storage.string as NSString).paragraphRange(for: textView.selectedRange())
            highlighter.highlight(storage, dirtyRange: dirty, revealing: activeParagraphRange)
        }
    }
}
