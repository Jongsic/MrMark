import AppKit

/// Read-only text view that makes task-list checkboxes clickable and copies a
/// fenced code block when its copy button is clicked.
final class ViewerTextView: NSTextView {
    /// Called with the 1-based source line of the clicked checkbox.
    var onCheckboxClick: ((Int) -> Void)?

    override func mouseDown(with event: NSEvent) {
        if let hit = copyButtonHit(at: event) {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(hit.code, forType: .string)
            showCopiedFeedback(nextTo: hit.buttonRect)
            return
        }
        if let line = checkboxSourceLine(at: event) {
            onCheckboxClick?(line)
            return
        }
        super.mouseDown(with: event)
    }

    /// The code text and button rect (view coordinates) when the click landed
    /// on a code block's copy button. The button rect is rebuilt with the same
    /// box math CodeBlockLayoutFragment draws with, so hit-testing agrees with
    /// what's on screen — a click anywhere else in the block falls through to
    /// text selection instead of silently replacing the pasteboard.
    private func copyButtonHit(at event: NSEvent) -> (code: String, buttonRect: NSRect)? {
        guard let layoutManager = textLayoutManager,
              let container = textContainer,
              let storage = textStorage, storage.length > 0 else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let containerPoint = CGPoint(
            x: point.x - textContainerOrigin.x,
            y: point.y - textContainerOrigin.y
        )
        guard let fragment = layoutManager.textLayoutFragment(for: containerPoint),
              let paragraph = fragment.textElement as? NSTextParagraph,
              paragraph.attributedString.length > 0 else { return nil }
        let attributes = paragraph.attributedString.attributes(at: 0, effectiveRange: nil)
        guard attributes[.mrmarkCodeCopy] != nil,
              let raw = attributes[.mrmarkCodeBlockEdge] as? Int,
              let edge = CodeBlockEdge(rawValue: raw), edge.hasTop else { return nil }

        // The fragment's box in container coordinates (the fragment computes
        // the same rect relative to its own frame): the full body-text column
        // horizontally, the text lines plus the present edges' padding
        // vertically.
        let lines = fragment.textLineFragments
        guard let firstLine = lines.first, let lastLine = lines.last else { return nil }
        let frame = fragment.layoutFragmentFrame
        let pad = container.lineFragmentPadding
        var box = CGRect(
            x: pad,
            y: frame.minY + firstLine.typographicBounds.minY - CodeBlockMetrics.verticalPadding,
            width: max(0, container.size.width - 2 * pad),
            height: lastLine.typographicBounds.maxY - firstLine.typographicBounds.minY
                + CodeBlockMetrics.verticalPadding
        )
        if edge.hasBottom {
            box.size.height += CodeBlockMetrics.verticalPadding
        }
        let button = CodeBlockMetrics.copyButtonRect(box: box)
        guard button.insetBy(dx: -4, dy: -4).contains(containerPoint) else { return nil }

        guard let elementStart = fragment.textElement?.elementRange?.location else { return nil }
        let index = layoutManager.offset(from: layoutManager.documentRange.location, to: elementStart)
        guard let code = Self.codeBlockText(in: storage, at: index) else { return nil }
        return (code, button.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y))
    }

    /// The full text of the fenced code block containing `index`: the longest
    /// contiguous `.mrmarkCodeBlock` run in the storage. The newline joining
    /// adjacent blocks never carries the attribute, so two blocks can't merge.
    static func codeBlockText(in storage: NSAttributedString, at index: Int) -> String? {
        guard index >= 0, index < storage.length else { return nil }
        var range = NSRange()
        guard storage.attribute(
            .mrmarkCodeBlock,
            at: index,
            longestEffectiveRange: &range,
            in: NSRange(location: 0, length: storage.length)
        ) != nil else { return nil }
        return storage.attributedSubstring(from: range).string
    }

    /// Brief "Copied" confirmation that fades out next to the button. Created
    /// only on click, so the viewer fast path allocates nothing for it.
    private func showCopiedFeedback(nextTo buttonRect: NSRect) {
        let label = NSTextField(labelWithString: "Copied")
        label.font = .systemFont(ofSize: 10)
        label.textColor = .secondaryLabelColor
        label.sizeToFit()
        label.setFrameOrigin(NSPoint(
            x: buttonRect.minX - label.frame.width - 6,
            y: buttonRect.midY - label.frame.height / 2
        ))
        addSubview(label)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                label.animator().alphaValue = 0
            } completionHandler: {
                label.removeFromSuperview()
            }
        }
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
