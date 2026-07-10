import AppKit

/// Read-only text view that makes task-list checkboxes clickable and copies a
/// fenced code block when its copy button is clicked.
final class ViewerTextView: NSTextView {
    /// Called with the 1-based source line of the clicked checkbox.
    var onCheckboxClick: ((Int) -> Void)?

    /// Owns the actual NSTextFinder; weak since the view controller owns this
    /// view. NSTextView doesn't publicly conform to NSTextFinderClient, so
    /// find actions can't just fall through to a superclass implementation —
    /// they're forwarded here instead of routing through NSTextView's own
    /// (disabled) find-bar machinery.
    weak var findActionTarget: ViewerViewController?

    override func performTextFinderAction(_ sender: Any?) {
        findActionTarget?.performTextFinderAction(sender)
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        // Only find actions are ours to answer — everything else (Cut, Paste,
        // Select All, …) must keep NSTextView's own validation, or read-only
        // edit items would show enabled.
        guard item.action == #selector(NSResponder.performTextFinderAction(_:)),
              let target = findActionTarget
        else { return super.validateUserInterfaceItem(item) }
        return target.validateUserInterfaceItem(item)
    }

    /// Closes the find bar on Escape instead of falling through to
    /// NSTextView's own cancel behavior (which would just clear the
    /// selection) while the bar is open.
    override func cancelOperation(_ sender: Any?) {
        guard findActionTarget?.isFindBarVisible == true else {
            super.cancelOperation(sender)
            return
        }
        findActionTarget?.hideFindInterfaceIfVisible()
    }

    override func mouseDown(with event: NSEvent) {
        if let hit = copyButtonHit(at: event) {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(hit.code, forType: .string)
            showCopiedFeedback(nextTo: hit.buttonRect, covering: hit.language)
            return
        }
        if let line = checkboxSourceLine(at: event) {
            onCheckboxClick?(line)
            return
        }
        super.mouseDown(with: event)
    }

    /// The code text, button rect (view coordinates), and language badge text
    /// when the click landed on a code block's copy button. The button rect is
    /// rebuilt with the same box math CodeBlockLayoutFragment draws with, so
    /// hit-testing agrees with what's on screen — a click anywhere else in the
    /// block falls through to text selection instead of silently replacing the
    /// pasteboard.
    private func copyButtonHit(at event: NSEvent) -> (code: String, buttonRect: NSRect, language: String?)? {
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
        return (
            code,
            button.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y),
            attributes[.mrmarkCodeLanguage] as? String
        )
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

    private static let copiedFeedbackID = NSUserInterfaceItemIdentifier("mrmark.copiedFeedback")

    /// Brief "Copied" confirmation that fades out in place of the language
    /// badge. Opaque and sized to span the badge — the layout fragment keeps
    /// drawing the badge underneath, so a transparent label would garble the
    /// two on top of each other. Created only on click, so the viewer fast
    /// path allocates nothing for it.
    private func showCopiedFeedback(nextTo buttonRect: NSRect, covering language: String?) {
        // A rapid re-click replaces the previous label instead of stacking.
        for view in subviews where view.identifier == Self.copiedFeedbackID {
            view.removeFromSuperview()
        }
        let label = NSTextField(labelWithString: "Copied")
        label.identifier = Self.copiedFeedbackID
        label.font = .systemFont(ofSize: 10)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.sizeToFit()

        // The badge hugs the button's left edge minus an 8pt gap and uses the
        // 10pt monospaced font (CodeBlockLayoutFragment.drawBadges) — span at
        // least its width so it is fully hidden while the label shows.
        let badgeFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        let badgeWidth = language.map { ceil(($0 as NSString).size(withAttributes: [.font: badgeFont]).width) } ?? 0
        let width = max(label.frame.width, badgeWidth) + 10
        let height = label.frame.height + 2
        label.wantsLayer = true
        label.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        label.layer?.cornerRadius = 3
        label.frame = NSRect(
            x: buttonRect.minX - 5 - width,
            y: buttonRect.midY - height / 2,
            width: width,
            height: height
        )
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
