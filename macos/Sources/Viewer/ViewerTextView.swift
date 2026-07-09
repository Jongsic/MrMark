import AppKit

/// Read-only text view that makes task-list checkboxes clickable and copies a
/// fenced code block when its copy button is clicked.
final class ViewerTextView: NSTextView {
    /// Called with the 1-based source line of the clicked checkbox.
    var onCheckboxClick: ((Int) -> Void)?

    override func mouseDown(with event: NSEvent) {
        if let code = codeToCopy(at: event) {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(code, forType: .string)
            return
        }
        if let line = checkboxSourceLine(at: event) {
            onCheckboxClick?(line)
            return
        }
        super.mouseDown(with: event)
    }

    /// The code string when the click landed on a code block's copy button. The
    /// button sits at the box's top-right; the first line carries both the copy
    /// text and the top-edge marker, so a hit is that line plus the button's
    /// horizontal band (the box math mirrors CodeBlockLayoutFragment).
    private func codeToCopy(at event: NSEvent) -> String? {
        guard let container = textContainer, let storage = textStorage, storage.length > 0 else { return nil }
        let containerWidth = container.size.width
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)

        var code: String?
        for candidate in [index, index - 1] where candidate >= 0 && candidate < storage.length {
            let attributes = storage.attributes(at: candidate, effectiveRange: nil)
            guard let raw = attributes[.mrmarkCodeBlockEdge] as? Int,
                  let edge = CodeBlockEdge(rawValue: raw), edge.hasTop,
                  let target = attributes[.mrmarkCodeCopy] as? String else { continue }
            code = target
            break
        }
        guard let code else { return nil }

        let columnRight = CodeBlockMetrics.boxMaxX(
            containerWidth: containerWidth,
            lineFragmentPadding: container.lineFragmentPadding
        )
        let boxMaxX = textContainerOrigin.x + columnRight
        let buttonMinX = boxMaxX - CodeBlockMetrics.badgeInset - CodeBlockMetrics.buttonSize
        let buttonMaxX = boxMaxX - CodeBlockMetrics.badgeInset
        return (point.x >= buttonMinX - 4 && point.x <= buttonMaxX + 4) ? code : nil
    }

    private func checkboxSourceLine(at event: NSEvent) -> Int? {
        guard let storage = textStorage, storage.length > 0 else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let insertionIndex = characterIndexForInsertion(at: point)
        // The insertion index sits between characters; the glyph that was
        // clicked can be on either side of it.
        for index in [insertionIndex, insertionIndex - 1] where index >= 0 && index < storage.length {
            if let line = storage.attribute(.mrmarkCheckboxLine, at: index, effectiveRange: nil) as? Int {
                return line
            }
        }
        return nil
    }
}
