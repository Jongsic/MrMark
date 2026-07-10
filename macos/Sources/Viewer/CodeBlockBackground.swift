import AppKit

/// Which rounded border a fenced code-block line draws. A block is split into
/// one paragraph per line, so the box is assembled from per-line fragments: the
/// first line rounds the top, the last rounds the bottom, a one-line block does
/// both, and interior lines just draw the two sides.
enum CodeBlockEdge: Int {
    case none, top, bottom, both

    var hasTop: Bool {
        self == .top || self == .both
    }

    var hasBottom: Bool {
        self == .bottom || self == .both
    }
}

/// Shared geometry for the code-block box so drawing (CodeBlockLayoutFragment)
/// and hit-testing (ViewerTextView copy button) agree on the same constants.
enum CodeBlockMetrics {
    // The box spans the full body-text column; text is inset from it by a
    // uniform padding on all four sides — vertical here, horizontal via the code
    // paragraph's head/tail indent in MarkdownRenderer.
    static let cornerRadius: CGFloat = 6
    static let verticalPadding: CGFloat = 10
    static let badgeInset: CGFloat = 6
    static let buttonSize: CGFloat = 15

    /// The copy button's rect in the same space as `box`.
    static func copyButtonRect(box: CGRect) -> CGRect {
        CGRect(x: box.maxX - badgeInset - buttonSize, y: box.minY + badgeInset, width: buttonSize, height: buttonSize)
    }
}

/// TextKit 2 hook that gives fenced code blocks a bordered, rounded background
/// with a language badge and copy button. A glyph-level `.backgroundColor` only
/// paints behind the characters themselves; a custom layout fragment can paint
/// the whole block width without dropping out of TextKit 2's viewport-lazy layout.
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
        let edge = codeBlockEdge
        let box = relativeBox(edge: edge).offsetBy(dx: point.x, dy: point.y)
        let radius = CodeBlockMetrics.cornerRadius

        context.saveGState()
        context.addPath(fillPath(box, edge: edge, radius: radius))
        context.setFillColor(NSColor.quaternarySystemFill.cgColor)
        context.fillPath()
        context.addPath(borderPath(box, edge: edge, radius: radius))
        context.setStrokeColor(NSColor.separatorColor.cgColor)
        context.setLineWidth(1)
        context.strokePath()
        context.restoreGState()

        super.draw(at: point, in: context)

        if edge.hasTop {
            drawBadges(in: box, context: context)
        }
    }

    private var firstAttributes: [NSAttributedString.Key: Any]? {
        guard let paragraph = textElement as? NSTextParagraph, paragraph.attributedString.length > 0 else { return nil }
        return paragraph.attributedString.attributes(at: 0, effectiveRange: nil)
    }

    private var codeBlockEdge: CodeBlockEdge {
        guard let raw = firstAttributes?[.mrmarkCodeBlockEdge] as? Int, let edge = CodeBlockEdge(rawValue: raw) else {
            return .none
        }
        return edge
    }

    /// The box for this code line in fragment-relative coordinates (before the
    /// draw `point` offset): the full body-text column horizontally — re-anchored
    /// past the code paragraph's head indent, which is baked into the fragment
    /// origin — and the line height plus edge padding vertically.
    private func relativeBox(edge: CodeBlockEdge) -> CGRect {
        let base = super.renderingSurfaceBounds
        let container = textLayoutManager?.textContainer
        let containerWidth = container?.size.width ?? base.width
        let pad = container?.lineFragmentPadding ?? 0
        let x = pad - layoutFragmentFrame.origin.x
        let width = max(0, containerWidth - 2 * pad)

        // Fill exactly the text line(s) — not the paragraph spacing that pads the
        // first/last lines — so adjacent per-line fragments tile without overlap.
        // (Using the rendering bounds' height overshoots the line advance and the
        // translucent fills double up into horizontal seams.)
        let lines = textLineFragments
        var y = lines.first?.typographicBounds.minY ?? base.minY
        var height = (lines.last?.typographicBounds.maxY ?? base.maxY) - y
        if edge.hasTop {
            y -= CodeBlockMetrics.verticalPadding
            height += CodeBlockMetrics.verticalPadding
        }
        if edge.hasBottom {
            height += CodeBlockMetrics.verticalPadding
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Extend the drawing surface to the box so the full-width background isn't
    /// clipped to the code text's own (narrower) width.
    override var renderingSurfaceBounds: CGRect {
        relativeBox(edge: codeBlockEdge).union(super.renderingSurfaceBounds)
    }

    /// Closed rounded outline for the fill — only the present edges are curved.
    private func fillPath(_ box: CGRect, edge: CodeBlockEdge, radius: CGFloat) -> CGPath {
        let topR = edge.hasTop ? radius : 0
        let bottomR = edge.hasBottom ? radius : 0
        let path = CGMutablePath()
        path.move(to: CGPoint(x: box.minX, y: box.minY + topR))
        if edge.hasTop {
            path.addArc(tangent1End: CGPoint(x: box.minX, y: box.minY),
                        tangent2End: CGPoint(x: box.minX + topR, y: box.minY), radius: topR)
        }
        path.addLine(to: CGPoint(x: box.maxX - topR, y: box.minY))
        if edge.hasTop {
            path.addArc(tangent1End: CGPoint(x: box.maxX, y: box.minY),
                        tangent2End: CGPoint(x: box.maxX, y: box.minY + topR), radius: topR)
        }
        path.addLine(to: CGPoint(x: box.maxX, y: box.maxY - bottomR))
        if edge.hasBottom {
            path.addArc(tangent1End: CGPoint(x: box.maxX, y: box.maxY),
                        tangent2End: CGPoint(x: box.maxX - bottomR, y: box.maxY), radius: bottomR)
        }
        path.addLine(to: CGPoint(x: box.minX + bottomR, y: box.maxY))
        if edge.hasBottom {
            path.addArc(tangent1End: CGPoint(x: box.minX, y: box.maxY),
                        tangent2End: CGPoint(x: box.minX, y: box.maxY - bottomR), radius: bottomR)
        }
        path.closeSubpath()
        return path
    }

    /// The sides plus whichever caps are present — interior lines stroke only
    /// the two verticals so the block reads as one continuous box.
    private func borderPath(_ box: CGRect, edge: CodeBlockEdge, radius: CGFloat) -> CGPath {
        let topR = edge.hasTop ? radius : 0
        let bottomR = edge.hasBottom ? radius : 0
        let path = CGMutablePath()

        path.move(to: CGPoint(x: box.minX, y: box.maxY - bottomR))
        path.addLine(to: CGPoint(x: box.minX, y: box.minY + topR))
        if edge.hasTop {
            path.addArc(tangent1End: CGPoint(x: box.minX, y: box.minY),
                        tangent2End: CGPoint(x: box.minX + topR, y: box.minY), radius: topR)
            path.addLine(to: CGPoint(x: box.maxX - topR, y: box.minY))
            path.addArc(tangent1End: CGPoint(x: box.maxX, y: box.minY),
                        tangent2End: CGPoint(x: box.maxX, y: box.minY + topR), radius: topR)
        } else {
            path.move(to: CGPoint(x: box.maxX, y: box.minY))
        }
        path.addLine(to: CGPoint(x: box.maxX, y: box.maxY - bottomR))
        if edge.hasBottom {
            path.addArc(tangent1End: CGPoint(x: box.maxX, y: box.maxY),
                        tangent2End: CGPoint(x: box.maxX - bottomR, y: box.maxY), radius: bottomR)
            path.addLine(to: CGPoint(x: box.minX + bottomR, y: box.maxY))
            path.addArc(tangent1End: CGPoint(x: box.minX, y: box.maxY),
                        tangent2End: CGPoint(x: box.minX, y: box.maxY - bottomR), radius: bottomR)
        }
        return path
    }

    private func drawBadges(in box: CGRect, context: CGContext) {
        guard let attributes = firstAttributes else { return }
        var rightEdge = box.maxX - CodeBlockMetrics.badgeInset

        if attributes[.mrmarkCodeCopy] != nil {
            let rect = CodeBlockMetrics.copyButtonRect(box: box)
            drawCopyGlyph(in: rect, context: context)
            rightEdge = rect.minX - 8
        }

        if let language = attributes[.mrmarkCodeLanguage] as? String, !language.isEmpty {
            let labelAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            let size = (language as NSString).size(withAttributes: labelAttributes)
            let rect = CGRect(x: rightEdge - size.width, y: box.minY + CodeBlockMetrics.badgeInset,
                              width: size.width, height: size.height)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            (language as NSString).draw(in: rect, withAttributes: labelAttributes)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// A small two-sheet "copy" icon drawn as vector strokes so it needs no
    /// asset and tints itself to the current appearance.
    private func drawCopyGlyph(in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.setStrokeColor(NSColor.secondaryLabelColor.cgColor)
        context.setLineWidth(1)
        let corner: CGFloat = 2
        let back = CGRect(x: rect.minX + rect.width * 0.30, y: rect.minY + rect.height * 0.10,
                          width: rect.width * 0.52, height: rect.height * 0.60)
        let front = CGRect(x: rect.minX + rect.width * 0.14, y: rect.minY + rect.height * 0.30,
                           width: rect.width * 0.52, height: rect.height * 0.60)
        context.addPath(CGPath(roundedRect: back, cornerWidth: corner, cornerHeight: corner, transform: nil))
        context.addPath(CGPath(roundedRect: front, cornerWidth: corner, cornerHeight: corner, transform: nil))
        context.strokePath()
        context.restoreGState()
    }
}
