#pragma once
// GFM-subset parser for the fast native viewer — a direct C++ port of the
// C# MarkdownParser/InlineParser in windows/MrMark (which is itself the spec
// mirror of the macOS renderer). Input uses "\n" line endings.

#include <string>
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
std::vector<Inline> ParseInlines(const std::wstring& text);
std::wstring PlainText(const std::vector<Inline>& inlines);


} // namespace md
