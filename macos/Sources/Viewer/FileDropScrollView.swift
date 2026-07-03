import AppKit

/// Scroll view that accepts `.md` file drops and opens each in its own window.
/// Also routes zoom gestures (⌘+scroll wheel, trackpad pinch) to the viewer.
final class FileDropScrollView: NSScrollView {
    private static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd"]

    /// Called with a relative zoom factor (e.g. 1.1 = zoom in 10%).
    var onZoom: ((CGFloat) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - Zoom gestures

    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.command), let onZoom else {
            super.scrollWheel(with: event)
            return
        }
        let delta = event.scrollingDeltaY
        guard delta != 0 else { return }
        let magnitude = event.hasPreciseScrollingDeltas
            ? min(abs(delta) * 0.004, 0.15) // trackpad: smooth, proportional
            : 0.1 // mouse wheel: one step per notch
        onZoom(1 + (delta > 0 ? magnitude : -magnitude))
    }

    override func magnify(with event: NSEvent) {
        guard let onZoom else {
            super.magnify(with: event)
            return
        }
        onZoom(1 + event.magnification)
    }

    // MARK: - File drops

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        markdownURLs(from: sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = markdownURLs(from: sender)
        for url in urls {
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
        }
        return !urls.isEmpty
    }

    private func markdownURLs(from info: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
        return urls.filter { Self.markdownExtensions.contains($0.pathExtension.lowercased()) }
    }
}
