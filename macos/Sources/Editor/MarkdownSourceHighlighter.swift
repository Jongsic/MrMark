import AppKit
import Markdown

extension NSAttributedString.Key {
    /// Present on syntax delimiters that are currently hidden (Typora-style).
    static let mrmarkConcealed = NSAttributedString.Key("mrmark.concealed")
}

/// Live styling for the editor's hybrid (Typora-style) mode.
///
/// The text storage always holds the Markdown source — saving, undo, and
/// copy are trivially exact. Styling is applied in place, and syntax
/// delimiters (`#`, `**`, backticks, link chrome) are *visually concealed*
/// unless their paragraph intersects `revealing` — the paragraph the cursor
/// is in, which shows plain styled source.
///
/// Parsing is whole-document but cached per source string (selection moves
/// re-use the parse); the expensive part — attribute application — is limited
/// to the edited paragraph, honoring the "no full re-render per keystroke"
/// budget. Editing a line that contains a code fence restyles from that point
/// down instead, because a fence changes the meaning of everything below it.
final class MarkdownSourceHighlighter {
    /// Text zoom factor (1 = 100%). Per-window, never persisted.
    var scale: CGFloat = 1

    private var cachedSource: String?
    private var cachedDocument: Document?
    private var cachedMap: SourceOffsetMap?

    private var bodyFont: NSFont {
        .systemFont(ofSize: 15 * scale)
    }

    private var codeFont: NSFont {
        .monospacedSystemFont(ofSize: 13 * scale, weight: .regular)
    }

    private func headingFont(_ level: Int) -> NSFont {
        let sizes: [CGFloat] = [26, 21, 18, 16, 15, 15]
        return .systemFont(ofSize: sizes[min(max(level, 1), 6) - 1] * scale, weight: .bold)
    }

    var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: bodyFont, .foregroundColor: NSColor.labelColor]
    }

    /// Delimiters keep their characters (source model is untouched); they are
    /// hidden by collapsing the glyphs to (near) zero and clearing the color.
    private static let concealedAttributes: [NSAttributedString.Key: Any] = [
        .mrmarkConcealed: true,
        .font: NSFont.systemFont(ofSize: 0.1),
        .foregroundColor: NSColor.clear,
    ]

    func highlightAll(_ storage: NSTextStorage, revealing: NSRange? = nil) {
        highlight(storage, dirtyRange: NSRange(location: 0, length: storage.length), revealing: revealing)
    }

    func highlight(_ storage: NSTextStorage, dirtyRange: NSRange, revealing: NSRange? = nil) {
        let text = storage.string as NSString
        let clamped = NSIntersectionRange(dirtyRange, NSRange(location: 0, length: text.length))
        var target = text.paragraphRange(for: clamped)
        if text.substring(with: target).contains("```") {
            target = NSRange(location: target.location, length: text.length - target.location)
        }

        // Too deeply nested to parse safely — leave the source plain rather than
        // crash swift-markdown's parser (see markdownNestingExceedsLimit).
        if markdownNestingExceedsLimit(storage.string) {
            storage.beginEditing()
            storage.setAttributes(baseAttributes, range: target)
            storage.endEditing()
            return
        }

        let (document, map) = parse(storage.string)

        storage.beginEditing()
        storage.setAttributes(baseAttributes, range: target)
        apply(document, to: storage, limit: target, map: map, text: text, revealing: revealing)
        storage.endEditing()
    }

    private func parse(_ source: String) -> (Document, SourceOffsetMap) {
        if source == cachedSource, let document = cachedDocument, let map = cachedMap {
            return (document, map)
        }
        let document = Document(parsing: source)
        let map = SourceOffsetMap(source)
        cachedSource = source
        cachedDocument = document
        cachedMap = map
        return (document, map)
    }

    private func apply(
        _ markup: Markup, to storage: NSTextStorage, limit: NSRange,
        map: SourceOffsetMap, text: NSString, revealing: NSRange?
    ) {
        if let range = markup.range.flatMap(map.nsRange) {
            let intersection = NSIntersectionRange(range, limit)
            guard intersection.length > 0 else { return } // subtree is outside the dirty range
            addAttributes(for: markup, in: intersection, to: storage)

            if shouldConceal(nodeRange: range, revealing: revealing, text: text) {
                for delimiter in concealableDelimiters(for: markup, in: range, text: text, map: map) {
                    let clipped = NSIntersectionRange(delimiter, limit)
                    if clipped.length > 0 {
                        storage.addAttributes(Self.concealedAttributes, range: clipped)
                    }
                }
            }
        }
        for child in markup.children {
            apply(child, to: storage, limit: limit, map: map, text: text, revealing: revealing)
        }
    }

    /// The cursor's paragraph shows plain styled source; everything else
    /// conceals its delimiters.
    private func shouldConceal(nodeRange: NSRange, revealing: NSRange?, text: NSString) -> Bool {
        guard let revealing else { return true }
        let paragraph = text.paragraphRange(for: nodeRange)
        if NSLocationInRange(revealing.location, paragraph) { return false } // caret (possibly empty range)
        return NSIntersectionRange(paragraph, revealing).length == 0
    }

    // MARK: - Delimiter geometry

    /// Ranges of pure syntax chrome inside `range` — computed from the source
    /// text itself and verified character by character, so malformed or
    /// unexpected shapes simply conceal nothing.
    private func concealableDelimiters(
        for markup: Markup, in range: NSRange, text: NSString, map: SourceOffsetMap
    ) -> [NSRange] {
        switch markup {
        case let heading as Heading:
            // "## Title" → conceal "## " (ATX only; setext underlines don't match).
            let prefixLength = heading.level + 1
            guard range.length > prefixLength else { return [] }
            let prefix = text.substring(with: NSRange(location: range.location, length: prefixLength))
            guard prefix == String(repeating: "#", count: heading.level) + " " else { return [] }
            return [NSRange(location: range.location, length: prefixLength)]

        case is Strong:
            return symmetricDelimiters(in: range, text: text, length: 2, oneOf: ["**", "__"])

        case is Emphasis:
            return symmetricDelimiters(in: range, text: text, length: 1, oneOf: ["*", "_"])

        case is Strikethrough:
            return symmetricDelimiters(in: range, text: text, length: 2, oneOf: ["~~"])

        case is InlineCode:
            // `code`, ``code with ` inside`` — count the actual backtick run.
            var backticks = 0
            while backticks < range.length,
                  text.character(at: range.location + backticks) == UInt16(UInt8(ascii: "`"))
            {
                backticks += 1
            }
            guard backticks > 0, range.length >= backticks * 2 else { return [] }
            let closing = NSRange(location: NSMaxRange(range) - backticks, length: backticks)
            guard text.substring(with: closing) == String(repeating: "`", count: backticks) else { return [] }
            return [NSRange(location: range.location, length: backticks), closing]

        case is Markdown.Link, is Markdown.Image:
            // Conceal whatever surrounds the visible children:
            // [text](url) → "[" and "](url)"; ![alt](src) → "![" and "](src)";
            // autolinks <url> → "<" and ">".
            let childRanges = markup.children.compactMap { $0.range.flatMap(map.nsRange) }
            guard let first = childRanges.first, let last = childRanges.last else { return [] }
            let opening = NSRange(location: range.location, length: first.location - range.location)
            let closing = NSRange(location: NSMaxRange(last), length: NSMaxRange(range) - NSMaxRange(last))
            return [opening, closing].filter { $0.length > 0 && NSMaxRange($0) <= text.length }

        default:
            return []
        }
    }

    private func symmetricDelimiters(
        in range: NSRange, text: NSString, length: Int, oneOf allowed: Set<String>
    ) -> [NSRange] {
        guard range.length >= length * 2 else { return [] }
        let opening = NSRange(location: range.location, length: length)
        let closing = NSRange(location: NSMaxRange(range) - length, length: length)
        guard allowed.contains(text.substring(with: opening)),
              allowed.contains(text.substring(with: closing))
        else { return [] }
        return [opening, closing]
    }

    // MARK: - Styling

    private func addAttributes(for markup: Markup, in range: NSRange, to storage: NSTextStorage) {
        switch markup {
        case let heading as Heading:
            storage.addAttribute(.font, value: headingFont(heading.level), range: range)

        case is Strong:
            addFontTraits(.bold, in: range, to: storage)

        case is Emphasis:
            addFontTraits(.italic, in: range, to: storage)

        case is Strikethrough:
            storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)

        case is InlineCode, is CodeBlock:
            storage.addAttributes(
                [.font: codeFont, .backgroundColor: NSColor.quaternarySystemFill],
                range: range
            )

        case is Markdown.Link, is Markdown.Image:
            storage.addAttribute(.foregroundColor, value: NSColor.linkColor, range: range)

        case is BlockQuote:
            storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: range)

        default:
            break
        }
    }

    private func addFontTraits(
        _ traits: NSFontDescriptor.SymbolicTraits, in range: NSRange, to storage: NSTextStorage
    ) {
        storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
            let font = value as? NSFont ?? bodyFont
            let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(traits))
            storage.addAttribute(.font, value: NSFont(descriptor: descriptor, size: font.pointSize) ?? font,
                                 range: subrange)
        }
    }
}

/// Converts swift-markdown source locations (1-based line, 1-based UTF-8
/// column) into NSString UTF-16 ranges. Korean and emoji make these differ,
/// so the conversion must be exact.
struct SourceOffsetMap {
    private let lines: [Substring]
    private let lineStartsUTF16: [Int]

    init(_ text: String) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var starts: [Int] = []
        starts.reserveCapacity(lines.count)
        var offset = 0
        for line in lines {
            starts.append(offset)
            offset += line.utf16.count + 1 // "\n"
        }
        self.lines = lines
        lineStartsUTF16 = starts
    }

    func nsRange(_ range: SourceRange) -> NSRange? {
        guard let start = utf16Offset(of: range.lowerBound),
              let end = utf16Offset(of: range.upperBound),
              end >= start
        else { return nil }
        return NSRange(location: start, length: end - start)
    }

    private func utf16Offset(of location: SourceLocation) -> Int? {
        let lineIndex = location.line - 1
        guard lineIndex >= 0, lineIndex < lines.count else { return nil }
        let line = lines[lineIndex]
        let utf8 = line.utf8
        guard let index = utf8.index(utf8.startIndex, offsetBy: location.column - 1, limitedBy: utf8.endIndex)
        else { return lineStartsUTF16[lineIndex] + line.utf16.count }
        return lineStartsUTF16[lineIndex] + line.utf16.distance(from: line.utf16.startIndex, to: index)
    }
}
