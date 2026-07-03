import AppKit

/// TextKit 2 hook that gives fenced code blocks a full-width tinted
/// background. A glyph-level `.backgroundColor` only paints behind the
/// characters themselves; a custom layout fragment can paint the whole
/// block width, without dropping out of TextKit 2's viewport-lazy layout.
final class CodeBlockLayoutDelegate: NSObject, NSTextLayoutManagerDelegate {
    func textLayoutManager(
        _ textLayoutManager: NSTextLayoutManager,
        textLayoutFragmentFor location: NSTextLocation,
        in textElement: NSTextElement
    ) -> NSTextLayoutFragment {
        if let paragraph = textElement as? NSTextParagraph,
           paragraph.attributedString.length > 0,
           paragraph.attributedString.attribute(.mrmarkCodeBlock, at: 0, effectiveRange: nil) != nil
        {
            return CodeBlockLayoutFragment(textElement: textElement, range: textElement.elementRange)
        }
        return NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
    }
}

private final class CodeBlockLayoutFragment: NSTextLayoutFragment {
    override func draw(at point: CGPoint, in context: CGContext) {
        context.saveGState()
        var background = renderingSurfaceBounds
        if let containerWidth = textLayoutManager?.textContainer?.size.width, containerWidth > 8 {
            background.origin.x = 2
            background.size.width = max(background.width, containerWidth - 8)
        }
        background = background.offsetBy(dx: point.x, dy: point.y)
        context.setFillColor(NSColor.quaternarySystemFill.cgColor)
        context.fill(background)
        context.restoreGState()
        super.draw(at: point, in: context)
    }
}
