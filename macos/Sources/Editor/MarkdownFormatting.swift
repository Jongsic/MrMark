import Foundation

/// Pure text transformations behind the formatting toolbar/menu.
/// Operates on (text, selection) and returns a single replacement edit so the
/// text view can apply it through the undo-aware editing path. Fully unit-tested.
enum MarkdownFormatting {
    struct Edit: Equatable {
        /// Range of the original text to replace.
        let range: NSRange
        let replacement: String
        /// Selection after the edit, in post-edit coordinates.
        let selection: NSRange
    }

    // MARK: - Inline wrapping (bold, italic, inline code)

    static func toggleInlineWrap(_ text: NSString, selection: NSRange, delimiter: String) -> Edit {
        let delimiterLength = (delimiter as NSString).length
        let selected = text.substring(with: selection)

        // Selection already includes the delimiters → unwrap.
        if selected.hasPrefix(delimiter), selected.hasSuffix(delimiter),
           (selected as NSString).length >= delimiterLength * 2
        {
            let inner = (selected as NSString).substring(
                with: NSRange(location: delimiterLength, length: (selected as NSString).length - delimiterLength * 2)
            )
            return Edit(
                range: selection,
                replacement: inner,
                selection: NSRange(location: selection.location, length: (inner as NSString).length)
            )
        }

        // Delimiters directly around the selection → unwrap.
        let before = NSRange(location: selection.location - delimiterLength, length: delimiterLength)
        let after = NSRange(location: NSMaxRange(selection), length: delimiterLength)
        if before.location >= 0, NSMaxRange(after) <= text.length,
           text.substring(with: before) == delimiter, text.substring(with: after) == delimiter
        {
            return Edit(
                range: NSRange(location: before.location, length: selection.length + delimiterLength * 2),
                replacement: selected,
                selection: NSRange(location: before.location, length: selection.length)
            )
        }

        // Wrap. Empty selection puts the caret between the delimiters.
        return Edit(
            range: selection,
            replacement: delimiter + selected + delimiter,
            selection: NSRange(location: selection.location + delimiterLength, length: selection.length)
        )
    }

    // MARK: - Headings

    /// Sets the heading level of every selected line; a line already at that
    /// level loses its heading instead (toggle).
    static func setHeading(_ text: NSString, selection: NSRange, level: Int) -> Edit {
        transformLines(text, selection: selection) { line in
            let existing = headingPrefixLength(of: line)
            let content = String(line.dropFirst(existing)).trimmingLeadingSpace(ifWasPrefixed: existing > 0)
            let currentLevel = line.prefix(existing).filter { $0 == "#" }.count
            if currentLevel == level {
                return content
            }
            return String(repeating: "#", count: level) + " " + content
        }
    }

    private static func headingPrefixLength(of line: String) -> Int {
        var count = 0
        for character in line {
            if character == "#", count < 6 {
                count += 1
            } else {
                break
            }
        }
        return count
    }

    // MARK: - List prefixes

    static func toggleBulletList(_ text: NSString, selection: NSRange) -> Edit {
        toggleLinePrefix(text, selection: selection, prefix: "- ", strip: stripBullet)
    }

    static func toggleChecklist(_ text: NSString, selection: NSRange) -> Edit {
        toggleLinePrefix(text, selection: selection, prefix: "- [ ] ", strip: stripChecklist)
    }

    static func toggleNumberedList(_ text: NSString, selection: NSRange) -> Edit {
        let lines = selectedLines(text, selection: selection)
        let allNumbered = lines.allSatisfy { stripNumber($0) != nil || $0.isEmpty }
        var number = 0
        return transformLines(text, selection: selection) { line in
            if allNumbered {
                return stripNumber(line) ?? line
            }
            if line.isEmpty { return line }
            number += 1
            return "\(number). " + (stripNumber(line) ?? stripBullet(line) ?? stripChecklist(line) ?? line)
        }
    }

    private static func toggleLinePrefix(
        _ text: NSString, selection: NSRange, prefix: String, strip: (String) -> String?
    ) -> Edit {
        let lines = selectedLines(text, selection: selection)
        let allPrefixed = lines.allSatisfy { strip($0) != nil || $0.isEmpty }
        return transformLines(text, selection: selection) { line in
            if allPrefixed {
                return strip(line) ?? line
            }
            if line.isEmpty { return line }
            return prefix + (strip(line) ?? line)
        }
    }

    private static func stripBullet(_ line: String) -> String? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count))
        }
        return nil
    }

    private static func stripChecklist(_ line: String) -> String? {
        for marker in ["- [ ] ", "- [x] ", "- [X] "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count))
        }
        return nil
    }

    private static func stripNumber(_ line: String) -> String? {
        guard let dotIndex = line.firstIndex(of: "."), dotIndex != line.startIndex else { return nil }
        let digits = line[line.startIndex ..< dotIndex]
        guard digits.allSatisfy(\.isNumber) else { return nil }
        let rest = line[line.index(after: dotIndex)...]
        guard rest.hasPrefix(" ") else { return nil }
        return String(rest.dropFirst())
    }

    // MARK: - Insertions

    static func insertLink(_ text: NSString, selection: NSRange) -> Edit {
        let selected = text.substring(with: selection)
        let label = selected.isEmpty ? "text" : selected
        let replacement = "[\(label)](url)"
        let urlLocation = selection.location + 1 + (label as NSString).length + 2
        return Edit(
            range: selection,
            replacement: replacement,
            selection: NSRange(location: urlLocation, length: 3)
        )
    }

    static func insertImage(_ text: NSString, selection: NSRange) -> Edit {
        let selected = text.substring(with: selection)
        let alt = selected.isEmpty ? "alt" : selected
        let replacement = "![\(alt)](path)"
        let pathLocation = selection.location + 2 + (alt as NSString).length + 2
        return Edit(
            range: selection,
            replacement: replacement,
            selection: NSRange(location: pathLocation, length: 4)
        )
    }

    static func insertCodeBlock(_ text: NSString, selection: NSRange) -> Edit {
        let lineRange = text.lineRange(for: selection)
        var content = text.substring(with: lineRange)
        let hadTrailingNewline = content.hasSuffix("\n")
        if hadTrailingNewline { content.removeLast() }
        let replacement = "```\n\(content)\n```" + (hadTrailingNewline ? "\n" : "")
        return Edit(
            range: lineRange,
            replacement: replacement,
            // Caret on the fence line, ready to type a language.
            selection: NSRange(location: lineRange.location + 3, length: 0)
        )
    }

    // MARK: - Line plumbing

    private static func selectedLines(_ text: NSString, selection: NSRange) -> [String] {
        let lineRange = text.lineRange(for: selection)
        var content = text.substring(with: lineRange)
        if content.hasSuffix("\n") { content.removeLast() }
        return content.components(separatedBy: "\n")
    }

    private static func transformLines(
        _ text: NSString, selection: NSRange, transform: (String) -> String
    ) -> Edit {
        let lineRange = text.lineRange(for: selection)
        var content = text.substring(with: lineRange)
        let hadTrailingNewline = content.hasSuffix("\n")
        if hadTrailingNewline { content.removeLast() }

        let replaced = content
            .components(separatedBy: "\n")
            .map(transform)
            .joined(separator: "\n") + (hadTrailingNewline ? "\n" : "")

        return Edit(
            range: lineRange,
            replacement: replaced,
            selection: NSRange(location: lineRange.location, length: (replaced as NSString).length)
        )
    }
}

private extension String {
    func trimmingLeadingSpace(ifWasPrefixed wasPrefixed: Bool) -> String {
        guard wasPrefixed, hasPrefix(" ") else { return self }
        return String(dropFirst())
    }
}
