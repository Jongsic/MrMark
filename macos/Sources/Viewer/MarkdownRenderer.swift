import AppKit
import Markdown

extension NSAttributedString.Key {
    /// Marks code-block paragraphs so the viewer draws a full-width background
    /// behind them (see CodeBlockLayoutFragment).
    static let mrmarkCodeBlock = NSAttributedString.Key("mrmark.codeBlock")
    /// On a task-list checkbox glyph: the 1-based source line it toggles.
    static let mrmarkCheckboxLine = NSAttributedString.Key("mrmark.checkboxLine")
    /// On a fenced code block's first/last line: which rounded edge to draw
    /// (a `CodeBlockEdge` raw value). Absent on interior lines.
    static let mrmarkCodeBlockEdge = NSAttributedString.Key("mrmark.codeBlockEdge")
    /// On a fenced code block's first line: the fence info string (language).
    static let mrmarkCodeLanguage = NSAttributedString.Key("mrmark.codeLanguage")
    /// On a fenced code block's first line: marks the copy button. The button
    /// copies the enclosing `.mrmarkCodeBlock` run out of the text storage, so
    /// the code text isn't stored a second time here.
    static let mrmarkCodeCopy = NSAttributedString.Key("mrmark.codeCopy")
}

/// Deepest block nesting we let reach swift-markdown. Its parser recurses once
/// per nesting level and large documents parse on a background thread with a
/// small (~512 KB) stack, so pathologically nested input (thousands of `>` or
/// deeply indented lists) crashes inside `Document(parsing:)` — an
/// uncatchable SIGSEGV — before any of our own code runs. Real documents nest a
/// handful of levels; measured overflow is ~200, so this leaves wide margin.
let markdownMaxParseNesting = 64
/// Inline emphasis/strike nesting shows up only as a long run of the same
/// delimiter (`***…`); alternating markers and links don't nest. Kept well
/// above decorative separators (`****`) but far below the parser's limit.
let markdownMaxDelimiterRun = 256

/// Cheap conservative pre-parse guard. Two things upper-bound how deep
/// swift-markdown will recurse: the leading `>` + indentation on a line (block
/// nesting) and the longest run of `* _ ~` (inline nesting). One UTF-8 pass with
/// early-exit (~6 ms on a 4 MB document, µs on typical ones). When this is true,
/// callers must skip parsing and fall back to plain text rather than crash.
func markdownNestingExceedsLimit(
    _ source: String,
    blockLimit: Int = markdownMaxParseNesting,
    runLimit: Int = markdownMaxDelimiterRun
) -> Bool {
    var atLineStart = true
    var quotes = 0
    var spaces = 0
    var runByte: UInt8 = 0
    var runLength = 0
    for byte in source.utf8 {
        if byte == 0x2A || byte == 0x5F || byte == 0x7E { // * _ ~
            if byte == runByte { runLength += 1 } else { runByte = byte; runLength = 1 }
            if runLength > runLimit { return true }
        } else {
            runByte = 0; runLength = 0
        }
        if byte == 0x0A { // newline — a line made only of markers still counts
            if quotes + spaces / 2 > blockLimit { return true }
            atLineStart = true; quotes = 0; spaces = 0
            continue
        }
        if atLineStart {
            switch byte {
            case 0x20: spaces += 1 // space
            case 0x09: spaces += 4 // tab
            case 0x3E: quotes += 1; spaces = 0 // '>'
            default:
                if quotes + spaces / 2 > blockLimit { return true }
                atLineStart = false
            }
        }
    }
    return quotes + spaces / 2 > blockLimit // last line without a trailing newline
}

/// Renders GFM Markdown into an NSAttributedString for the read-only viewer.
/// Uses semantic NSColors throughout so dark mode works without re-rendering.
final class MarkdownRenderer {
    /// Base directory for resolving relative image paths (the document's folder).
    let baseURL: URL?
    /// Text zoom factor (1 = 100%). Per-window, never persisted.
    let scale: CGFloat

    // Fonts, attribute dictionaries, and common metrics are created once per
    // renderer — building them per markup node dominated large-document
    // rendering (measured: ~290ms → ~90ms for 10k lines).
    private let bodyFont: NSFont
    private let codeFont: NSFont
    private let boldBodyFont: NSFont
    private let italicBodyFont: NSFont
    private let headingFonts: [NSFont]
    private let bodyAttributes: Attributes
    private let constantPrefixWidths: [String: CGFloat]

    // Pathologically nested markup (thousands of `>`/`[`, or alternating
    // list/quote) would recurse until the stack overflows — swift-markdown can
    // build such trees, and large documents render on a background thread with a
    // small (~512 KB) stack. Stop descending well before that and show an
    // ellipsis. Real documents nest a handful of levels; measured overflow is a
    // few hundred, so this leaves wide margin on both sides. `depth` (visual
    // indentation) can't serve here: renderInlineContainer resets it to 0.
    private static let maxNestingDepth = 80
    private var nestingDepth = 0

    // When frontmatter is peeled off, the parser sees only the body, so parsed
    // line numbers are short by the peeled lines. Checkbox toggling edits the
    // *original* text by line (MarkdownDocument.toggleCheckbox), so the offset
    // is added back wherever a source line is stored on the rendered output.
    private var checkboxLineOffset = 0

    init(baseURL: URL? = nil, scale: CGFloat = 1) {
        self.baseURL = baseURL
        self.scale = scale
        let body = NSFont.systemFont(ofSize: 15 * scale)
        bodyFont = body
        codeFont = .monospacedSystemFont(ofSize: 13 * scale, weight: .regular)
        boldBodyFont = Self.applying(.bold, to: body)
        italicBodyFont = Self.applying(.italic, to: body)
        headingFonts = [26, 21, 18, 16, 15, 15].map { .systemFont(ofSize: $0 * scale, weight: .bold) }
        bodyAttributes = [.font: body, .foregroundColor: NSColor.labelColor]
        constantPrefixWidths = Dictionary(uniqueKeysWithValues: ["•  ", "☐  ", "☑  "].map {
            ($0, ($0 as NSString).size(withAttributes: [.font: body]).width)
        })
    }

    func render(_ source: String) -> NSAttributedString {
        // Too deeply nested to parse safely — show the raw source instead of
        // crashing the parser (see markdownNestingExceedsLimit).
        if markdownNestingExceedsLimit(source) {
            return NSAttributedString(string: source, attributes: bodyAttributes)
        }
        let result = NSMutableAttributedString()
        var first = true

        // YAML frontmatter isn't Markdown. Peel it off and show it as a compact
        // properties block, then parse only the body — otherwise cmark renders
        // the fences as a thematic break plus a setext heading.
        var body = source
        checkboxLineOffset = 0
        if let frontmatter = extractFrontmatter(source) {
            body = frontmatter.body
            checkboxLineOffset = frontmatter.lineOffset
            if let block = renderFrontmatter(frontmatter) {
                result.append(block)
                first = false
            }
        }

        let document = Document(parsing: body)
        for block in document.children {
            if !first {
                result.append(NSAttributedString(string: "\n", attributes: [.font: bodyFont]))
            }
            result.append(renderBlock(block, depth: 0))
            first = false
        }
        return result
    }

    // MARK: - Style

    enum Style {
        static func paragraph(spacingBefore: CGFloat = 0, spacing: CGFloat = 8,
                              indent: CGFloat = 0, hanging: CGFloat = 0,
                              tailIndent: CGFloat = 0) -> NSParagraphStyle
        {
            let style = NSMutableParagraphStyle()
            style.paragraphSpacingBefore = spacingBefore
            style.paragraphSpacing = spacing
            style.firstLineHeadIndent = indent
            style.headIndent = indent + hanging
            style.tailIndent = tailIndent
            style.lineHeightMultiple = 1.15
            return style
        }
    }

    private typealias Attributes = [NSAttributedString.Key: Any]

    private func headingFont(_ level: Int) -> NSFont {
        headingFonts[min(max(level, 1), 6) - 1]
    }

    // MARK: - Frontmatter

    /// Peeled YAML frontmatter as a compact metadata block: a two-column
    /// key/value grid closed by a hairline rule, or a verbatim monospace block
    /// when the frontmatter wasn't a flat map. Returns nil for an empty block.
    private func renderFrontmatter(_ frontmatter: ParsedFrontmatter) -> NSAttributedString? {
        if let properties = frontmatter.properties, !properties.isEmpty {
            return renderProperties(properties)
        }
        let raw = frontmatter.rawBlock.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        var attributes = bodyAttributes
        attributes[.font] = codeFont
        attributes[.foregroundColor] = NSColor.secondaryLabelColor
        attributes[.paragraphStyle] = Style.paragraph(spacing: 8)
        return NSAttributedString(string: raw, attributes: attributes)
    }

    private func renderProperties(_ properties: [(key: String, value: String)]) -> NSAttributedString {
        let keyFont = NSFont.systemFont(ofSize: 15 * scale, weight: .medium)
        var keyAttributes = bodyAttributes
        keyAttributes[.font] = keyFont
        keyAttributes[.foregroundColor] = NSColor.secondaryLabelColor

        let gap = 16 * scale
        let keyWidth = properties.reduce(CGFloat(0)) { widest, property in
            max(widest, ceil((property.key as NSString).size(withAttributes: [.font: keyFont]).width))
        }

        let rowStyle = NSMutableParagraphStyle()
        rowStyle.tabStops = [NSTextTab(textAlignment: .left, location: keyWidth + gap)]
        rowStyle.headIndent = keyWidth + gap // wrapped values stay under the value column
        rowStyle.paragraphSpacing = 4
        rowStyle.lineHeightMultiple = 1.15

        let rows = NSMutableAttributedString()
        var first = true
        for property in properties {
            if !first { rows.append(NSAttributedString(string: "\n", attributes: bodyAttributes)) }
            first = false
            rows.append(NSAttributedString(string: property.key, attributes: keyAttributes))
            rows.append(NSAttributedString(string: "\t", attributes: bodyAttributes))
            rows.append(NSAttributedString(string: property.value, attributes: bodyAttributes))
        }
        rows.addAttribute(.paragraphStyle, value: rowStyle, range: NSRange(location: 0, length: rows.length))

        var ruleAttributes = bodyAttributes
        ruleAttributes[.foregroundColor] = NSColor.separatorColor
        ruleAttributes[.paragraphStyle] = Style.paragraph(spacingBefore: 2, spacing: 8)
        rows.append(NSAttributedString(string: "\n" + String(repeating: "─", count: 24), attributes: ruleAttributes))
        return rows
    }

    // MARK: - Blocks

    private func renderBlock(_ markup: Markup, depth: Int) -> NSAttributedString {
        nestingDepth += 1
        defer { nestingDepth -= 1 }
        if nestingDepth > Self.maxNestingDepth {
            return NSAttributedString(string: "…", attributes: bodyAttributes)
        }
        switch markup {
        case let heading as Heading:
            var attributes = bodyAttributes
            attributes[.font] = headingFont(heading.level)
            attributes[.paragraphStyle] = Style.paragraph(spacingBefore: heading.level <= 2 ? 14 : 10)
            return renderChildren(of: heading, attributes: attributes)

        case let paragraph as Paragraph:
            var attributes = bodyAttributes
            attributes[.paragraphStyle] = Style.paragraph(indent: CGFloat(depth) * 24)
            return renderChildren(of: paragraph, attributes: attributes)

        case let codeBlock as CodeBlock:
            // Text is inset from the box the layout fragment draws: `indent`/
            // `tail` give the left/right padding, and the first/last lines carry
            // the vertical breathing room the fragment extends the box over.
            let indent = CGFloat(depth) * 24 + 16
            let tail: CGFloat = -16
            var attributes = bodyAttributes
            attributes[.font] = codeFont
            attributes[.mrmarkCodeBlock] = true
            attributes[.paragraphStyle] = Style.paragraph(spacing: 0, indent: indent, tailIndent: tail)
            let code = codeBlock.code.hasSuffix("\n") ? String(codeBlock.code.dropLast()) : codeBlock.code
            let block = NSMutableAttributedString(string: code, attributes: attributes)

            // Line ranges for the edge attributes. Degenerate shapes need care:
            // a blank first line would make the naive first range zero-length
            // (attributes on an empty range are silently dropped — top edge,
            // badge, and copy button vanish), and a trailing blank line would
            // put the naive last range past the final newline. Clamp the first
            // range to at least its newline character, and anchor the bottom
            // edge on the last paragraph that owns any characters.
            let nsCode = code as NSString
            let firstLineEnd = nsCode.range(of: "\n").location
            let firstRange = NSRange(
                location: 0,
                length: firstLineEnd == NSNotFound ? block.length : max(firstLineEnd, 1)
            )
            var lastLineStart = block.length
            if block.length > 0 {
                let beforeEnd = NSRange(location: 0, length: block.length - 1)
                let lastNewline = nsCode.range(of: "\n", options: .backwards, range: beforeEnd)
                lastLineStart = lastNewline.location == NSNotFound ? 0 : lastNewline.location + 1
            }
            // The last content paragraph collapsing into the first means the
            // box is one visual line — both edges live on the first range.
            let singleLine = lastLineStart <= 0
            let lastRange = NSRange(location: lastLineStart, length: block.length - lastLineStart)

            // The first line leaves room above for the box's top padding; the
            // last line leaves room below plus the block's trailing gap.
            block.addAttribute(
                .paragraphStyle,
                value: Style.paragraph(
                    spacingBefore: 26,
                    spacing: singleLine ? 28 : 0,
                    indent: indent,
                    tailIndent: tail
                ),
                range: firstRange
            )
            if !singleLine {
                block.addAttribute(
                    .paragraphStyle,
                    value: Style.paragraph(spacing: 28, indent: indent, tailIndent: tail),
                    range: lastRange
                )
            }

            // The first line carries the rounded top edge, the language badge,
            // and the copy-button marker; the last line carries the rounded
            // bottom edge (drawn by the layout fragment). A single-line block
            // is both edges at once.
            block.addAttribute(
                .mrmarkCodeBlockEdge,
                value: (singleLine ? CodeBlockEdge.both : .top).rawValue,
                range: firstRange
            )
            block.addAttribute(.mrmarkCodeCopy, value: true, range: firstRange)
            if let language = codeBlock.language, !language.isEmpty {
                block.addAttribute(.mrmarkCodeLanguage, value: language, range: firstRange)
            }
            if !singleLine {
                block.addAttribute(.mrmarkCodeBlockEdge, value: CodeBlockEdge.bottom.rawValue, range: lastRange)
            }
            return block

        case let quote as BlockQuote:
            let content = NSMutableAttributedString()
            var first = true
            for child in quote.children {
                if !first { content.append(NSAttributedString(string: "\n")) }
                content.append(renderBlock(child, depth: depth + 1))
                first = false
            }
            content.addAttribute(
                .foregroundColor,
                value: NSColor.secondaryLabelColor,
                range: NSRange(location: 0, length: content.length)
            )
            return content

        case let list as UnorderedList:
            return renderList(items: Array(list.listItems), depth: depth) { _ in "•  " }

        case let list as OrderedList:
            let start = Int(list.startIndex)
            return renderList(items: Array(list.listItems), depth: depth) { index in "\(start + index).  " }

        case is ThematicBreak:
            var attributes = bodyAttributes
            attributes[.foregroundColor] = NSColor.separatorColor
            attributes[.paragraphStyle] = Style.paragraph(spacingBefore: 8)
            return NSAttributedString(string: "────────────", attributes: attributes)

        case let html as HTMLBlock:
            var attributes = bodyAttributes
            attributes[.font] = codeFont
            attributes[.foregroundColor] = NSColor.secondaryLabelColor
            return NSAttributedString(string: html.rawHTML.trimmingCharacters(in: .newlines), attributes: attributes)

        case let table as Markdown.Table:
            return renderTable(table)

        default:
            var attributes = bodyAttributes
            attributes[.paragraphStyle] = Style.paragraph()
            return renderChildren(of: markup, attributes: attributes)
        }
    }

    private func renderList(items: [ListItem], depth: Int, marker: (Int) -> String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let indent = CGFloat(depth) * 24 + 4
        var first = true

        for (index, item) in items.enumerated() {
            if !first { result.append(NSAttributedString(string: "\n")) }
            first = false

            var prefixAttributes = bodyAttributes
            let prefix: String
            switch item.checkbox {
            case .checked:
                prefix = "☑  "
                prefixAttributes[.foregroundColor] = NSColor.controlAccentColor
            case .unchecked:
                prefix = "☐  "
                prefixAttributes[.foregroundColor] = NSColor.secondaryLabelColor
            case nil:
                prefix = marker(index)
                prefixAttributes[.foregroundColor] = NSColor.secondaryLabelColor
            }
            if item.checkbox != nil, let sourceLine = item.range?.lowerBound.line {
                prefixAttributes[.mrmarkCheckboxLine] = sourceLine + checkboxLineOffset
            }

            let line = NSMutableAttributedString(string: prefix, attributes: prefixAttributes)
            var itemFirst = true
            for child in item.children {
                if child is UnorderedList || child is OrderedList {
                    line.append(NSAttributedString(string: "\n"))
                    line.append(renderBlock(child, depth: depth + 1))
                } else {
                    if !itemFirst { line.append(NSAttributedString(string: "\n")) }
                    line.append(renderInlineContainer(child, attributes: bodyAttributes))
                }
                itemFirst = false
            }

            let hanging = constantPrefixWidths[prefix]
                ?? (prefix as NSString).size(withAttributes: [.font: bodyFont]).width
            let style = Style.paragraph(spacing: 4, indent: indent, hanging: hanging)
            line.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: line.length)) { value, range, _ in
                if value == nil {
                    line.addAttribute(.paragraphStyle, value: style, range: range)
                }
            }
            // Strikethrough completed tasks for glanceability.
            if item.checkbox == .checked {
                line.addAttribute(
                    .foregroundColor,
                    value: NSColor.secondaryLabelColor,
                    range: NSRange(location: prefix.utf16.count, length: line.length - prefix.utf16.count)
                )
            }
            result.append(line)
        }
        return result
    }

    /// Borderless aligned grid: bold header, hairline rule, columns sized to
    /// content via tab stops. Full table layout (borders, cell wrapping) is
    /// out of scope by design; selection and copy stay plain text.
    private func renderTable(_ table: Markdown.Table) -> NSAttributedString {
        var headerAttributes = bodyAttributes
        headerAttributes[.font] = applying(.bold, to: bodyFont)

        let headCells = table.head.children
            .compactMap { $0 as? Markdown.Table.Cell }
            .map { renderChildren(of: $0, attributes: headerAttributes) }
        let bodyRows = table.body.children
            .compactMap { $0 as? Markdown.Table.Row }
            .map { row in
                row.children
                    .compactMap { $0 as? Markdown.Table.Cell }
                    .map { renderChildren(of: $0, attributes: bodyAttributes) }
            }

        let columnCount = max(headCells.count, bodyRows.map(\.count).max() ?? 0)
        guard columnCount > 0 else { return NSAttributedString() }

        var columnWidths = [CGFloat](repeating: 0, count: columnCount)
        for row in [headCells] + bodyRows {
            for (column, cell) in row.enumerated() where column < columnCount {
                columnWidths[column] = max(columnWidths[column], ceil(cell.size().width))
            }
        }

        let columnGap = 24 * scale
        var location: CGFloat = 0
        var tabStops: [NSTextTab] = []
        for width in columnWidths {
            location += width + columnGap
            tabStops.append(NSTextTab(textAlignment: .left, location: location))
        }

        let rowStyle = NSMutableParagraphStyle()
        rowStyle.tabStops = tabStops
        rowStyle.defaultTabInterval = columnGap
        rowStyle.paragraphSpacing = 4
        rowStyle.lineHeightMultiple = 1.15
        rowStyle.lineBreakMode = .byClipping // a wrapped cell would wreck the grid

        func gridRow(_ cells: [NSAttributedString]) -> NSAttributedString {
            let line = NSMutableAttributedString()
            for (index, cell) in cells.enumerated() {
                if index > 0 { line.append(NSAttributedString(string: "\t", attributes: bodyAttributes)) }
                line.append(cell)
            }
            line.addAttribute(.paragraphStyle, value: rowStyle, range: NSRange(location: 0, length: line.length))
            return line
        }

        let result = NSMutableAttributedString()
        result.append(gridRow(headCells))

        var ruleAttributes = bodyAttributes
        ruleAttributes[.foregroundColor] = NSColor.separatorColor
        ruleAttributes[.paragraphStyle] = rowStyle
        let dash = "─"
        let dashWidth = max((dash as NSString).size(withAttributes: [.font: bodyFont]).width, 1)
        let ruleLength = max(4, Int((location - columnGap) / dashWidth))
        result.append(NSAttributedString(
            string: "\n" + String(repeating: dash, count: ruleLength),
            attributes: ruleAttributes
        ))

        for cells in bodyRows {
            result.append(NSAttributedString(string: "\n"))
            result.append(gridRow(cells))
        }

        return result
    }

    private func renderInlineContainer(_ markup: Markup, attributes: Attributes) -> NSAttributedString {
        if markup is Paragraph || markup is Heading {
            return renderChildren(of: markup, attributes: attributes)
        }
        return renderBlock(markup, depth: 0)
    }

    // MARK: - Inlines

    private func renderChildren(of markup: Markup, attributes: Attributes) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for child in markup.children {
            result.append(renderInline(child, attributes: attributes))
        }
        return result
    }

    private func renderInline(_ markup: Markup, attributes: Attributes) -> NSAttributedString {
        nestingDepth += 1
        defer { nestingDepth -= 1 }
        if nestingDepth > Self.maxNestingDepth {
            return NSAttributedString(string: "…", attributes: attributes)
        }
        var attributes = attributes
        switch markup {
        case let text as Markdown.Text:
            return NSAttributedString(string: text.string, attributes: attributes)

        case is SoftBreak:
            return NSAttributedString(string: " ", attributes: attributes)

        case is LineBreak:
            return NSAttributedString(string: "\n", attributes: attributes)

        case is Strong:
            attributes[.font] = applying(.bold, to: font(in: attributes))
            return renderChildren(of: markup, attributes: attributes)

        case is Emphasis:
            attributes[.font] = applying(.italic, to: font(in: attributes))
            return renderChildren(of: markup, attributes: attributes)

        case is Strikethrough:
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            return renderChildren(of: markup, attributes: attributes)

        case let code as InlineCode:
            attributes[.font] = codeFont
            attributes[.backgroundColor] = NSColor.quaternarySystemFill
            return NSAttributedString(string: code.code, attributes: attributes)

        case let link as Markdown.Link:
            if let url = safeLinkURL(link.destination) {
                attributes[.link] = url
            }
            return renderChildren(of: markup, attributes: attributes)

        case let image as Markdown.Image:
            return renderImage(image, attributes: attributes)

        case let html as InlineHTML:
            attributes[.font] = codeFont
            attributes[.foregroundColor] = NSColor.secondaryLabelColor
            return NSAttributedString(string: html.rawHTML, attributes: attributes)

        default:
            return renderChildren(of: markup, attributes: attributes)
        }
    }

    private func renderImage(_ image: Markdown.Image, attributes: Attributes) -> NSAttributedString {
        let alt = image.plainText
        guard let source = image.source else {
            return NSAttributedString(string: alt, attributes: attributes)
        }

        // Local images render inline; remote images are never fetched (SECURITY.md)
        // and appear as a link instead.
        if let url = resolveLocalURL(source), let nsImage = NSImage(contentsOf: url) {
            let attachment = NSTextAttachment()
            attachment.image = nsImage
            let size = nsImage.size
            let maxWidth: CGFloat = 620
            if size.width > maxWidth, size.width > 0 {
                let scale = maxWidth / size.width
                attachment.bounds = NSRect(x: 0, y: 0, width: maxWidth, height: size.height * scale)
            }
            return NSAttributedString(attachment: attachment)
        }

        var linkAttributes = attributes
        if let url = safeLinkURL(source) {
            linkAttributes[.link] = url
        }
        return NSAttributedString(string: "🖼 \(alt.isEmpty ? source : alt)", attributes: linkAttributes)
    }

    /// Only http(s) and mailto destinations are made clickable; everything else
    /// — javascript:, file:, data:, custom app schemes — renders as plain text,
    /// so a crafted document can't trigger actions or local access on click.
    /// Same allowlist GitHub and markdown-it apply.
    private func safeLinkURL(_ destination: String?) -> URL? {
        guard let destination,
              let url = URL(string: destination),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" || scheme == "mailto"
        else { return nil }
        return url
    }

    private func resolveLocalURL(_ source: String) -> URL? {
        if source.hasPrefix("http://") || source.hasPrefix("https://") {
            return nil
        }
        if source.hasPrefix("/") {
            return URL(fileURLWithPath: source)
        }
        guard let baseURL else { return nil }
        return URL(fileURLWithPath: source, relativeTo: baseURL)
    }

    // MARK: - Font helpers

    private func font(in attributes: Attributes) -> NSFont {
        attributes[.font] as? NSFont ?? bodyFont
    }

    private func applying(_ traits: NSFontDescriptor.SymbolicTraits, to font: NSFont) -> NSFont {
        // Fast path for the overwhelmingly common case: styling body text.
        if font === bodyFont {
            if traits == .bold { return boldBodyFont }
            if traits == .italic { return italicBodyFont }
        }
        return Self.applying(traits, to: font)
    }

    private static func applying(_ traits: NSFontDescriptor.SymbolicTraits, to font: NSFont) -> NSFont {
        let combined = font.fontDescriptor.symbolicTraits.union(traits)
        let descriptor = font.fontDescriptor.withSymbolicTraits(combined)
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }
}
