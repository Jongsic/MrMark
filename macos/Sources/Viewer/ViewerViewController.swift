import AppKit

/// Read-only fast path shown the moment a document opens. Must stay lean:
/// no undo manager, highlighter, or editing toolbar work happens here
/// (AGENTS.md). Edit mode (0.2) initializes that machinery lazily.
final class ViewerViewController: NSViewController {
    private weak var document: MarkdownDocument?
    private var textView: NSTextView!
    private let codeBlockLayoutDelegate = CodeBlockLayoutDelegate()

    /// Per-window text zoom; intentionally not persisted — new windows start at 100%.
    private(set) var zoomScale: CGFloat = 1

    /// Invalidates in-flight background renders when the content changes again.
    private var renderGeneration = 0

    /// Documents above this size render off the main thread so they never
    /// block first paint (measured: 10k lines ≈ 300ms of rendering).
    private static let asyncRenderThreshold = 100_000 // UTF-8 bytes

    /// Fired on every zoom change so the toolbar control stays in sync with
    /// wheel/pinch/menu zooming.
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
        let textView = ViewerTextView(usingTextLayoutManager: true)
        textView.onCheckboxClick = { [weak self] sourceLine in
            self?.document?.toggleCheckbox(atSourceLine: sourceLine)
        }
        textView.isEditable = false
        textView.isSelectable = true
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
        // Full-width backgrounds behind fenced code blocks.
        textView.textLayoutManager?.delegate = codeBlockLayoutDelegate
        // The scroll view handles file drops; the text view must not swallow them.
        textView.unregisterDraggedTypes()

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
        LaunchClock.viewerDidAppear()
        if let document {
            DefaultMarkdownApp.offerIfAppropriate(for: document)
        }
    }

    func reload() {
        guard let document else { return }
        let renderer = MarkdownRenderer(
            baseURL: document.fileURL?.deletingLastPathComponent(),
            scale: zoomScale
        )
        let source = document.text
        renderGeneration += 1
        let generation = renderGeneration

        // Small documents render synchronously — no intermediate state.
        if source.utf8.count <= Self.asyncRenderThreshold {
            setContent(renderer.render(source))
            LaunchClock.mark("markdown-render")
            return
        }

        // Large documents must not block first paint. Show the plain source
        // instantly (TextKit 2 lays out lazily) and swap in the rendered
        // version when it is ready. Later reloads (zoom, checkbox toggles,
        // external changes) keep the current rich content while the
        // replacement renders.
        if textView.string.isEmpty {
            setContent(NSAttributedString(string: source, attributes: [
                .font: NSFont.systemFont(ofSize: 15 * zoomScale),
                .foregroundColor: NSColor.labelColor,
            ]))
            LaunchClock.mark("plain-first-paint")
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let content = renderer.render(source)
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == renderGeneration else { return }
                setContent(content)
            }
        }
    }

    /// Keeps the reading position across checkbox toggles / external reloads.
    private func setContent(_ content: NSAttributedString) {
        if isViewLoaded, let scrollView = view as? NSScrollView {
            scrollView.preservingScrollFraction {
                textView.textStorage?.setAttributedString(content)
            }
        } else {
            textView.textStorage?.setAttributedString(content)
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
        onZoomChanged?(clamped)
        guard isViewLoaded else { return } // applied by the initial reload()
        (view as? NSScrollView)?.preservingScrollFraction { reload() }
    }
}

extension ViewerViewController: DocumentContentController {}
extension ViewerViewController: ZoomableContent {}
