import Foundation

/// A leading YAML frontmatter block peeled off the source before Markdown
/// parsing. cmark-gfm has no frontmatter concept, so `MarkdownRenderer` uses
/// this to render the metadata as a small properties block instead of letting
/// the fences render as a thematic break + setext heading.
struct ParsedFrontmatter {
    /// Ordered key/value pairs, or `nil` when the block isn't a flat key/value
    /// map (nested maps, unexpected indentation). Callers show `rawBlock`
    /// verbatim in that case.
    let properties: [(key: String, value: String)]?
    /// The text between the fences — used for the verbatim fallback.
    let rawBlock: String
    /// The Markdown that follows the closing fence.
    let body: String
}

/// Detects and peels a leading YAML frontmatter block. Returns `nil` (leaving
/// the source untouched) unless it opens on the very first line with `---` and
/// has a later `---` or `...` closing fence. Input is assumed newline-normalized
/// (`MarkdownDocument` normalizes CRLF to `\n` before rendering).
func extractFrontmatter(_ source: String) -> ParsedFrontmatter? {
    guard source.hasPrefix("---") else { return nil }
    let lines = source.components(separatedBy: "\n")
    guard lines.first == "---" else { return nil }

    var closeIndex: Int?
    for index in 1 ..< lines.count where lines[index] == "---" || lines[index] == "..." {
        closeIndex = index
        break
    }
    guard let close = closeIndex else { return nil }

    let blockLines = Array(lines[1 ..< close])
    let bodyLines = close + 1 < lines.count ? Array(lines[(close + 1)...]) : []
    return ParsedFrontmatter(
        properties: parseFlatProperties(blockLines),
        rawBlock: blockLines.joined(separator: "\n"),
        body: bodyLines.joined(separator: "\n")
    )
}

/// Parses `key: value` lines plus the common `key:` + `- item` block-sequence
/// shape (list items joined with ", "). Returns `nil` on anything that isn't a
/// flat map — a signal to fall back to verbatim rendering.
private func parseFlatProperties(_ lines: [String]) -> [(key: String, value: String)]? {
    var result: [(key: String, value: String)] = []
    var index = 0
    while index < lines.count {
        let line = lines[index]
        index += 1
        if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
        // A top-level key must not be indented.
        if line.first == " " || line.first == "\t" { return nil }
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)

        // `key:` with no inline value may be followed by `- item` lines.
        if value.isEmpty {
            var items: [String] = []
            while index < lines.count {
                let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                guard candidate.hasPrefix("- ") else { break }
                items.append(String(candidate.dropFirst(2)).trimmingCharacters(in: .whitespaces))
                index += 1
            }
            value = items.joined(separator: ", ")
        }
        result.append((key: key, value: value))
    }
    return result.isEmpty ? nil : result
}
