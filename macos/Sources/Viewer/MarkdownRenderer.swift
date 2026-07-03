import AppKit
import Markdown

extension NSAttributedString.Key {
    /// Marks code-block paragraphs so the viewer draws a full-width background
    /// behind them (see CodeBlockLayoutFragment).
    static let mrmarkCodeBlock = NSAttributedString.Key("mrmark.codeBlock")
    /// On a task-list checkbox glyph: the 1-based source line it toggles.
    static let mrmarkCheckboxLine = NSAttributedString.Key("mrmark.checkboxLine")
}

/// Renders GFM Markdown into an NSAttributedString for the read-only viewer.
/// Uses semantic NSColors throughout so dark mode works without re-rendering.
struct MarkdownRenderer {
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
        let document = Document(parsing: source)
        let result = NSMutableAttributedString()
        var first = true
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
                              indent: CGFloat = 0, hanging: CGFloat = 0) -> NSParagraphStyle
        {
            let style = NSMutableParagraphStyle()
            style.paragraphSpacingBefore = spacingBefore
            style.paragraphSpacing = spacing
            style.firstLineHeadIndent = indent
            style.headIndent = indent + hanging
            style.lineHeightMultiple = 1.15
            return style
        }
    }

    private typealias Attributes = [NSAttributedString.Key: Any]

    private func headingFont(_ level: Int) -> NSFont {
        headingFonts[min(max(level, 1), 6) - 1]
    }

    // MARK: - Blocks

    private func renderBlock(_ markup: Markup, depth: Int) -> NSAttributedString {
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
            var attributes = bodyAttributes
            attributes[.font] = codeFont
            // The full-width block background is drawn by CodeBlockLayoutFragment.
            attributes[.mrmarkCodeBlock] = true
            let indent = CGFloat(depth) * 24 + 12
            // Inner lines are one visual block — no spacing between them; the
            // last line carries the block's trailing spacing.
            attributes[.paragraphStyle] = Style.paragraph(spacing: 0, indent: indent)
            let code = codeBlock.code.hasSuffix("\n") ? String(codeBlock.code.dropLast()) : codeBlock.code
            let block = NSMutableAttributedString(string: code, attributes: attributes)
            let lastNewline = (code as NSString).range(of: "\n", options: .backwards)
            let lastLineStart = lastNewline.location == NSNotFound ? 0 : lastNewline.location + 1
            block.addAttribute(
                .paragraphStyle,
                value: Style.paragraph(spacing: 8, indent: indent),
                range: NSRange(location: lastLineStart, length: block.length - lastLineStart)
            )
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
                prefixAttributes[.mrmarkCheckboxLine] = sourceLine
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
            if let destination = link.destination, let url = URL(string: destination) {
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
        if let url = URL(string: source) {
            linkAttributes[.link] = url
        }
        return NSAttributedString(string: "🖼 \(alt.isEmpty ? source : alt)", attributes: linkAttributes)
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
