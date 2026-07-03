import AppKit

/// Read-only text view that makes task-list checkboxes clickable.
final class ViewerTextView: NSTextView {
    /// Called with the 1-based source line of the clicked checkbox.
    var onCheckboxClick: ((Int) -> Void)?

    override func mouseDown(with event: NSEvent) {
        if let line = checkboxSourceLine(at: event) {
            onCheckboxClick?(line)
            return
        }
        super.mouseDown(with: event)
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
