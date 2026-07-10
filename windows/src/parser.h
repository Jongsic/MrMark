#pragma once
// GFM-subset parser for the fast native viewer — a direct C++ port of the
// C# MarkdownParser/InlineParser in windows/MrMark (which is itself the spec
// mirror of the macOS renderer). Input uses "\n" line endings.

#include <string>
#include <utility>
#include <vector>

namespace md {

enum class InlineType {
    Text,
    Strong,
    Emphasis,
    Strike,
    Code,
    Link,
    Image,
    Html,
    SoftBreak,
    HardBreak,
};

struct Inline {
    InlineType type = InlineType::Text;
    std::wstring text;            // Text/Code/Html content; Image alt
    std::wstring dest;            // Link/Image destination
    std::vector<Inline> children; // Strong/Emphasis/Strike/Link
};

enum class BlockType {
    Heading,
    Paragraph,
    Code,
    Quote,
    List,
    Table,
    Rule,
    Html,
};

struct Block;

struct ListItem {
    int check = -1; // -1 plain item, 0 unchecked task, 1 checked task
    int sourceLine = 0; // 1-based line of the marker (what a click toggles)
    std::vector<Block> children;
};

struct Block {
    BlockType type = BlockType::Paragraph;
    int level = 0;             // heading level
    std::wstring code;         // Code content / Html raw
    std::wstring lang;         // Code fence info
    std::vector<Inline> inlines;   // Heading/Paragraph
    std::vector<Block> children;   // Quote
    bool ordered = false;
    int start = 1;
    std::vector<ListItem> items;   // List
    std::vector<std::vector<Inline>> header;             // Table
    std::vector<std::vector<std::vector<Inline>>> rows;  // Table
};

std::vector<Block> Parse(const std::wstring& source);
/// `firstSourceLine` is what line 1 of `source` is in the original document —
/// used when a leading frontmatter block was peeled off, so checkbox source
/// lines keep pointing at the right lines of the full text.
std::vector<Block> Parse(const std::wstring& source, int firstSourceLine);
std::vector<Inline> ParseInlines(const std::wstring& text);
std::wstring PlainText(const std::vector<Inline>& inlines);

/// A leading YAML frontmatter block peeled off the source before Markdown
/// parsing (the spec mirror of the macOS Frontmatter.swift): the viewer shows
/// it as a compact key/value properties block instead of rendering the fences
/// as thematic breaks around stray prose.
struct Frontmatter {
    /// Ordered key/value pairs; `flatMap` is false when the block isn't a
    /// flat key/value map (nested maps, unexpected indentation) — callers
    /// show `rawBlock` verbatim in that case.
    std::vector<std::pair<std::wstring, std::wstring>> properties;
    bool flatMap = false;
    /// The text between the fences — used for the verbatim fallback.
    std::wstring rawBlock;
    /// The Markdown that follows the closing fence.
    std::wstring body;
    /// How many source lines were peeled off ahead of `body` (both fences
    /// plus the block).
    int lineOffset = 0;
};

/// Detects and peels a leading YAML frontmatter block. False (leaving the
/// source untouched) unless it opens on the very first line with `---`, a
/// later `---`/`...` closes it, and the lines between have the shape of a
/// frontmatter mapping: a top-level `key:` line first, then indented
/// continuations, `- ` items, or more `:` lines — no blank lines. When in
/// doubt the document stays Markdown. Input is newline-normalized.
bool ExtractFrontmatter(const std::wstring& source, Frontmatter& out);

} // namespace md
