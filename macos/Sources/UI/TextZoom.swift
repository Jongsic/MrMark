import AppKit

/// Shared zoom range for both viewer and editor.
enum TextZoom {
    static let minimum: CGFloat = 0.5
    static let maximum: CGFloat = 3.0
    static let step: CGFloat = 0.1
}

/// Content view controllers that support per-window text zoom.
protocol ZoomableContent: AnyObject {
    var zoomScale: CGFloat { get }
    /// Fired on every zoom change so the toolbar control stays in sync with
    /// wheel/pinch/menu zooming.
    var onZoomChanged: ((CGFloat) -> Void)? { get set }
    func setZoomScale(_ scale: CGFloat)
}

extension NSScrollView {
    /// Zoom re-renders and reflows the text; keep the reader roughly where
    /// they were by preserving the vertical scroll fraction.
    func preservingScrollFraction(_ body: () -> Void) {
        guard let documentView else {
            body()
            return
        }
        let clip = contentView
        let scrollableHeight = max(documentView.frame.height - clip.bounds.height, 1)
        let fraction = min(max(clip.bounds.origin.y / scrollableHeight, 0), 1)

        body()

        layoutSubtreeIfNeeded()
        let newScrollableHeight = max((self.documentView?.frame.height ?? 0) - clip.bounds.height, 0)
        clip.scroll(to: NSPoint(x: 0, y: newScrollableHeight * fraction))
        reflectScrolledClipView(clip)
    }
}
