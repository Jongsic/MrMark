#include "parser.h"

#include <algorithm>
#include <cwctype>

namespace md {

namespace {

struct Line {
    std::wstring text;
    int sourceLine; // 1-based
};

// Blockquotes, lists, links and emphasis all recurse on nested input, so a
// crafted document (e.g. thousands of `>` or `[`) could otherwise exhaust the
// stack. Cap nesting well above any real document and stop recursing past it.
constexpr int kMaxNestingDepth = 100;

std::vector<Block> ParseBlocks(const std::vector<Line>& lines, int depth);
std::vector<Inline> ParseInlinesImpl(const std::wstring& text, int depth);

// MARK: - Small helpers

bool IsBlank(const std::wstring& s)
{
    for (wchar_t c : s) {
        if (!iswspace(c)) return false;
    }
    return true;
}

int LeadingSpaces(const std::wstring& s)
{
    int n = 0;
    while (n < (int)s.size() && s[n] == L' ') n++;
    return n;
}

bool IsAsciiDigit(wchar_t c) { return c >= L'0' && c <= L'9'; }
bool IsAsciiLetter(wchar_t c) { return (c >= L'a' && c <= L'z') || (c >= L'A' && c <= L'Z'); }
bool IsAsciiAlnum(wchar_t c) { return IsAsciiLetter(c) || IsAsciiDigit(c); }

bool IsAsciiPunct(wchar_t c)
{
    return (c >= L'!' && c <= L'/') || (c >= L':' && c <= L'@')
        || (c >= L'[' && c <= L'`') || (c >= L'{' && c <= L'~');
}

std::wstring Trim(const std::wstring& s)
{
    size_t b = 0, e = s.size();
    while (b < e && iswspace(s[b])) b++;
    while (e > b && iswspace(s[e - 1])) e--;
    return s.substr(b, e - b);
}

std::wstring TrimEnd(const std::wstring& s)
{
    size_t e = s.size();
    while (e > 0 && iswspace(s[e - 1])) e--;
    return s.substr(0, e);
}

std::vector<std::wstring> SplitLines(const std::wstring& s)
{
    std::vector<std::wstring> out;
    size_t start = 0;
    for (size_t i = 0; i <= s.size(); i++) {
        if (i == s.size() || s[i] == L'\n') {
            out.push_back(s.substr(start, i - start));
            start = i + 1;
        }
    }
    return out;
}

int RunLength(const std::wstring& s, size_t pos, size_t end, wchar_t c)
{
    int n = 0;
    while (pos + n < end && s[pos + n] == c) n++;
    return n;
}

// MARK: - Fenced code

struct Fence {
    wchar_t marker;
    int length;
    int indent;
    std::wstring info;
};

bool FenceMarker(const std::wstring& line, Fence& out)
{
    int indent = LeadingSpaces(line);
    if (indent > 3 || indent >= (int)line.size()) return false;
    wchar_t marker = line[indent];
    if (marker != L'`' && marker != L'~') return false;
    int length = RunLength(line, indent, line.size(), marker);
    if (length < 3) return false;
    std::wstring info = Trim(line.substr(indent + length));
    if (marker == L'`' && info.find(L'`') != std::wstring::npos) return false;
    out = { marker, length, indent, info };
    return true;
}

bool TryParseFence(const std::vector<Line>& lines, size_t& i, std::vector<Block>& blocks)
{
    Fence fence;
    if (!FenceMarker(lines[i].text, fence)) return false;

    std::wstring content;
    bool first = true;
    size_t j = i + 1;
    for (; j < lines.size(); j++) {
        Fence close;
        if (FenceMarker(lines[j].text, close) && close.marker == fence.marker
            && close.length >= fence.length && close.info.empty()) {
            j++;
            break;
        }
        int strip = std::min(fence.indent, LeadingSpaces(lines[j].text));
        if (!first) content += L'\n';
        content += lines[j].text.substr(strip);
        first = false;
    }

    Block block;
    block.type = BlockType::Code;
    block.code = content;
    size_t space = fence.info.find(L' ');
    block.lang = space == std::wstring::npos ? fence.info : fence.info.substr(0, space);
    blocks.push_back(std::move(block));
    i = j;
    return true;
}

// MARK: - ATX headings

int HeadingLevel(const std::wstring& line)
{
    int indent = LeadingSpaces(line);
    if (indent > 3) return 0;
    int level = 0;
    while (indent + level < (int)line.size() && line[indent + level] == L'#' && level < 7) level++;
    if (level == 0 || level > 6) return 0;
    int after = indent + level;
    if (after < (int)line.size() && line[after] != L' ' && line[after] != L'\t') return 0;
    return level;
}

bool TryParseHeading(const std::vector<Line>& lines, size_t& i, std::vector<Block>& blocks)
{
    int level = HeadingLevel(lines[i].text);
    if (level == 0) return false;
    std::wstring text = lines[i].text;
    text = text.substr(LeadingSpaces(text));
    std::wstring content = Trim(text.substr(level));

    // Optional closing sequence "## Title ##" — strip if preceded by a space.
    size_t e = content.size();
    while (e > 0 && content[e - 1] == L'#') e--;
    if (e < content.size() && (e == 0 || content[e - 1] == L' ')) {
        content = TrimEnd(content.substr(0, e));
    }

    Block block;
    block.type = BlockType::Heading;
    block.level = level;
    block.inlines = ParseInlines(content);
    blocks.push_back(std::move(block));
    i++;
    return true;
}

// MARK: - Thematic breaks

bool IsThematicBreak(const std::wstring& line)
{
    int indent = LeadingSpaces(line);
    if (indent > 3) return false;
    std::wstring span = TrimEnd(line.substr(indent));
    if (span.size() < 3) return false;
    wchar_t marker = span[0];
    if (marker != L'-' && marker != L'*' && marker != L'_') return false;
    int count = 0;
    for (wchar_t c : span) {
        if (c == marker) count++;
        else if (c != L' ' && c != L'\t') return false;
    }
    return count >= 3;
}

// MARK: - Blockquotes

bool QuoteContent(const std::wstring& line, std::wstring& out)
{
    int indent = LeadingSpaces(line);
    if (indent > 3 || indent >= (int)line.size() || line[indent] != L'>') return false;
    std::wstring rest = line.substr(indent + 1);
    out = (!rest.empty() && rest[0] == L' ') ? rest.substr(1) : rest;
    return true;
}

bool TryParseQuote(const std::vector<Line>& lines, size_t& i, std::vector<Block>& blocks, int depth)
{
    if (depth >= kMaxNestingDepth) return false;
    std::wstring content;
    if (!QuoteContent(lines[i].text, content)) return false;
    std::vector<Line> inner;
    while (i < lines.size() && QuoteContent(lines[i].text, content)) {
        inner.push_back({ content, lines[i].sourceLine });
        i++;
    }
    Block block;
    block.type = BlockType::Quote;
    block.children = ParseBlocks(inner, depth + 1);
    blocks.push_back(std::move(block));
    return true;
}

// MARK: - Lists

struct Marker {
    bool ordered;
    int number;
    int contentIndent;
    std::wstring content;
};

bool ListMarker(const std::wstring& line, Marker& out)
{
    int indent = LeadingSpaces(line);
    if (indent >= (int)line.size()) return false;

    size_t pos = indent;
    wchar_t c = line[pos];
    if (c == L'-' || c == L'*' || c == L'+') {
        if (pos + 1 >= line.size() || line[pos + 1] != L' ') return false;
        size_t after = pos + 2;
        int extra = 0;
        while (after + extra < line.size() && line[after + extra] == L' ' && extra < 3) extra++;
        out = { false, 0, (int)(after + extra), line.substr(after + extra) };
        return true;
    }

    int digits = 0;
    while (pos + digits < line.size() && IsAsciiDigit(line[pos + digits]) && digits < 9) digits++;
    if (digits == 0) return false;
    size_t end = pos + digits;
    if (end >= line.size() || (line[end] != L'.' && line[end] != L')')) return false;
    if (end + 1 >= line.size() || line[end + 1] != L' ') return false;
    size_t start = end + 2;
    int pad = 0;
    while (start + pad < line.size() && line[start + pad] == L' ' && pad < 3) pad++;
    out = { true, std::stoi(line.substr(pos, digits)), (int)(start + pad), line.substr(start + pad) };
    return true;
}

bool TryParseList(const std::vector<Line>& lines, size_t& i, std::vector<Block>& blocks, int depth)
{
    if (depth >= kMaxNestingDepth) return false;
    Marker first;
    if (!ListMarker(lines[i].text, first) || LeadingSpaces(lines[i].text) > 3) return false;

    bool ordered = first.ordered;
    Block list;
    list.type = BlockType::List;
    list.ordered = ordered;
    list.start = ordered ? first.number : 1;

    while (i < lines.size()) {
        Marker marker;
        if (!ListMarker(lines[i].text, marker) || LeadingSpaces(lines[i].text) > 3
            || marker.ordered != ordered) break;

        int itemIndent = marker.contentIndent;
        std::vector<Line> itemLines = { { marker.content, lines[i].sourceLine } };
        int markerLine = lines[i].sourceLine;
        i++;

        while (i < lines.size()) {
            const std::wstring& text = lines[i].text;
            if (IsBlank(text)) {
                if (i + 1 < lines.size() && LeadingSpaces(lines[i + 1].text) >= itemIndent
                    && !IsBlank(lines[i + 1].text)) {
                    itemLines.push_back({ L"", lines[i].sourceLine });
                    i++;
                    continue;
                }
                break;
            }
            if (LeadingSpaces(text) >= itemIndent) {
                itemLines.push_back({ text.substr(itemIndent), lines[i].sourceLine });
                i++;
                continue;
            }
            break;
        }

        // Task-list checkbox on the item's first line.
        int check = -1;
        const std::wstring& head = itemLines[0].text;
        if (head.size() >= 4 && head[0] == L'[' && head[2] == L']' && head[3] == L' '
            && (head[1] == L' ' || head[1] == L'x' || head[1] == L'X')) {
            check = head[1] == L' ' ? 0 : 1;
            itemLines[0].text = head.substr(4);
        }

        ListItem item;
        item.check = check;
        item.sourceLine = markerLine;
        item.children = ParseBlocks(itemLines, depth + 1);
        list.items.push_back(std::move(item));

        // A blank line between items keeps the list going only if another item follows.
        if (i < lines.size() && IsBlank(lines[i].text) && i + 1 < lines.size()) {
            Marker next;
            if (ListMarker(lines[i + 1].text, next) && LeadingSpaces(lines[i + 1].text) <= 3
                && next.ordered == ordered) {
                i++;
            }
        }
    }

    blocks.push_back(std::move(list));
    return true;
}

// MARK: - Tables

std::vector<std::wstring> SplitTableRow(const std::wstring& line)
{
    std::wstring trimmed = Trim(line);
    if (!trimmed.empty() && trimmed.front() == L'|') trimmed.erase(0, 1);
    if (trimmed.size() >= 1 && trimmed.back() == L'|'
        && !(trimmed.size() >= 2 && trimmed[trimmed.size() - 2] == L'\\')) {
        trimmed.pop_back();
    }

    std::vector<std::wstring> cells;
    std::wstring current;
    for (size_t k = 0; k < trimmed.size(); k++) {
        wchar_t c = trimmed[k];
        if (c == L'\\' && k + 1 < trimmed.size() && trimmed[k + 1] == L'|') {
            current += L'|';
            k++;
        } else if (c == L'|') {
            cells.push_back(Trim(current));
            current.clear();
        } else {
            current += c;
        }
    }
    cells.push_back(Trim(current));
    return cells;
}

bool IsTableDelimiterRow(const std::wstring& line)
{
    if (line.find(L'-') == std::wstring::npos) return false;
    auto cells = SplitTableRow(line);
    if (cells.empty()) return false;
    for (const auto& cell : cells) {
        std::wstring span = Trim(cell);
        if (span.empty()) return false;
        int dashes = 0;
        for (size_t k = 0; k < span.size(); k++) {
            wchar_t c = span[k];
            if (c == L'-') dashes++;
            else if (c == L':' && (k == 0 || k == span.size() - 1)) continue;
            else return false;
        }
        if (dashes == 0) return false;
    }
    return true;
}

bool TryParseTable(const std::vector<Line>& lines, size_t& i, std::vector<Block>& blocks)
{
    if (i + 1 >= lines.size()) return false;
    const std::wstring& headerText = lines[i].text;
    if (headerText.find(L'|') == std::wstring::npos) return false;
    if (!IsTableDelimiterRow(lines[i + 1].text)) return false;

    auto header = SplitTableRow(headerText);
    auto delimiter = SplitTableRow(lines[i + 1].text);
    if (header.empty() || header.size() != delimiter.size()) return false;

    Block table;
    table.type = BlockType::Table;
    for (const auto& cell : header) {
        table.header.push_back(ParseInlines(cell));
    }

    size_t j = i + 2;
    while (j < lines.size() && !IsBlank(lines[j].text)
           && lines[j].text.find(L'|') != std::wstring::npos) {
        auto cells = SplitTableRow(lines[j].text);
        std::vector<std::vector<Inline>> row;
        for (size_t c = 0; c < header.size(); c++) {
            row.push_back(ParseInlines(c < cells.size() ? cells[c] : L""));
        }
        table.rows.push_back(std::move(row));
        j++;
    }

    blocks.push_back(std::move(table));
    i = j;
    return true;
}

// MARK: - HTML blocks

bool LooksLikeHtmlTagStart(const std::wstring& text, size_t lt)
{
    size_t pos = lt + 1;
    if (pos >= text.size()) return false;
    if (text[pos] == L'!') return true;
    if (text[pos] == L'/') pos++;
    if (pos >= text.size() || !IsAsciiLetter(text[pos])) return false;
    while (pos < text.size() && (IsAsciiAlnum(text[pos]) || text[pos] == L'-')) pos++;
    return pos >= text.size() || text[pos] == L' ' || text[pos] == L'\t'
        || text[pos] == L'>' || text[pos] == L'/';
}

bool TryParseHtmlBlock(const std::vector<Line>& lines, size_t& i, std::vector<Block>& blocks)
{
    const std::wstring& text = lines[i].text;
    int indent = LeadingSpaces(text);
    if (indent > 3 || indent >= (int)text.size() || text[indent] != L'<') return false;
    if (!LooksLikeHtmlTagStart(text, indent)) return false;

    std::wstring raw;
    bool first = true;
    while (i < lines.size() && !IsBlank(lines[i].text)) {
        if (!first) raw += L'\n';
        raw += lines[i].text;
        first = false;
        i++;
    }
    Block block;
    block.type = BlockType::Html;
    block.code = raw;
    blocks.push_back(std::move(block));
    return true;
}

// MARK: - Paragraphs

bool StartsTable(const std::vector<Line>& lines, size_t i)
{
    if (i + 1 >= lines.size()) return false;
    if (lines[i].text.find(L'|') == std::wstring::npos) return false;
    if (!IsTableDelimiterRow(lines[i + 1].text)) return false;
    auto header = SplitTableRow(lines[i].text);
    auto delimiter = SplitTableRow(lines[i + 1].text);
    return !header.empty() && header.size() == delimiter.size();
}

bool StartsOtherBlock(const std::wstring& line)
{
    Fence fence;
    Marker marker;
    std::wstring quote;
    return FenceMarker(line, fence) || HeadingLevel(line) > 0 || IsThematicBreak(line)
        || QuoteContent(line, quote) || ListMarker(line, marker);
}

void ParseParagraph(const std::vector<Line>& lines, size_t& i, std::vector<Block>& blocks)
{
    std::vector<std::wstring> collected;
    while (i < lines.size() && !IsBlank(lines[i].text)
           && (collected.empty()
               || (!StartsOtherBlock(lines[i].text) && !StartsTable(lines, i)))) {
        collected.push_back(lines[i].text);
        i++;
    }

    // Encode breaks: hard break ("  \n" or "\\\n") as '\r' — impossible in
    // normalized input — and soft break as '\n'.
    std::wstring joined;
    for (size_t k = 0; k < collected.size(); k++) {
        std::wstring line = Trim(collected[k]);
        if (k < collected.size() - 1) {
            const std::wstring& original = collected[k];
            bool endsTwoSpaces = original.size() >= 2
                && original[original.size() - 1] == L' ' && original[original.size() - 2] == L' ';
            bool endsBackslash = !line.empty() && line.back() == L'\\'
                && !(line.size() >= 2 && line[line.size() - 2] == L'\\');
            bool hard = endsTwoSpaces || endsBackslash;
            if (hard && !line.empty() && line.back() == L'\\') line.pop_back();
            joined += line;
            joined += hard ? L'\r' : L'\n';
        } else {
            joined += line;
        }
    }

    Block block;
    block.type = BlockType::Paragraph;
    block.inlines = ParseInlines(joined);
    blocks.push_back(std::move(block));
}

std::vector<Block> ParseBlocks(const std::vector<Line>& lines, int depth)
{
    std::vector<Block> blocks;
    size_t i = 0;
    while (i < lines.size()) {
        if (IsBlank(lines[i].text)) {
            i++;
            continue;
        }
        if (TryParseFence(lines, i, blocks)) continue;
        if (TryParseHeading(lines, i, blocks)) continue;
        if (IsThematicBreak(lines[i].text)) {
            Block rule;
            rule.type = BlockType::Rule;
            blocks.push_back(std::move(rule));
            i++;
            continue;
        }
        if (TryParseQuote(lines, i, blocks, depth)) continue;
        if (TryParseList(lines, i, blocks, depth)) continue;
        if (TryParseTable(lines, i, blocks)) continue;
        if (TryParseHtmlBlock(lines, i, blocks)) continue;
        ParseParagraph(lines, i, blocks);
    }
    return blocks;
}

// MARK: - Inline parsing

int FindClosingDelimiter(const std::wstring& text, wchar_t marker, int length, size_t from)
{
    size_t i = from;
    while (i < text.size()) {
        wchar_t c = text[i];
        if (c == L'\\') { i += 2; continue; }
        if (c != marker) { i++; continue; }
        int run = RunLength(text, i, text.size(), marker);
        if (run == length && i > from && !iswspace(text[i - 1])) {
            if (marker == L'_' && i + run < text.size() && iswalnum(text[i + run])) {
                i += run;
                continue;
            }
            return (int)i;
        }
        i += run;
    }
    return -1;
}

bool TryParseCodeSpan(const std::wstring& text, size_t pos, Inline& node, size_t& end)
{
    int open = RunLength(text, pos, text.size(), L'`');
    size_t search = pos + open;
    while (search < text.size()) {
        if (text[search] != L'`') { search++; continue; }
        int run = RunLength(text, search, text.size(), L'`');
        if (run == open) {
            std::wstring code = text.substr(pos + open, search - pos - open);
            for (auto& c : code) {
                if (c == L'\n' || c == L'\r') c = L' ';
            }
            if (code.size() >= 2 && code.front() == L' ' && code.back() == L' '
                && !Trim(code).empty()) {
                code = code.substr(1, code.size() - 2);
            }
            node.type = InlineType::Code;
            node.text = code;
            end = search + run;
            return true;
        }
        search += run;
    }
    return false;
}

bool TryParseEmphasis(const std::wstring& text, size_t pos, Inline& node, size_t& end, int depth)
{
    wchar_t marker = text[pos];
    int run = std::min(RunLength(text, pos, text.size(), marker), 3);

    size_t contentStart = pos + run;
    if (contentStart >= text.size() || iswspace(text[contentStart])) return false;
    if (marker == L'_' && pos > 0 && iswalnum(text[pos - 1])) return false;

    for (int length = run; length >= 1; length--) {
        int close = FindClosingDelimiter(text, marker, length, pos + length);
        if (close < 0) continue;
        std::wstring inner = text.substr(pos + length, close - (int)pos - length);
        if (inner.empty()) continue;
        auto children = ParseInlinesImpl(inner, depth + 1);
        if (length == 3) {
            Inline strong;
            strong.type = InlineType::Strong;
            strong.children = std::move(children);
            node.type = InlineType::Emphasis;
            node.children.clear();
            node.children.push_back(std::move(strong));
        } else {
            node.type = length == 2 ? InlineType::Strong : InlineType::Emphasis;
            node.children = std::move(children);
        }
        end = close + length;
        return true;
    }
    return false;
}

bool TryParseLink(const std::wstring& text, size_t bracket, Inline& node, size_t& end, int depth)
{
    int bracketDepth = 0;
    int close = -1;
    for (size_t i = bracket; i < text.size(); i++) {
        wchar_t c = text[i];
        if (c == L'\\') { i++; continue; }
        if (c == L'[') bracketDepth++;
        else if (c == L']') {
            bracketDepth--;
            if (bracketDepth == 0) { close = (int)i; break; }
        }
    }
    if (close < 0 || close + 1 >= (int)text.size() || text[close + 1] != L'(') return false;

    int parens = 0;
    int endParen = -1;
    for (size_t i = close + 1; i < text.size(); i++) {
        wchar_t c = text[i];
        if (c == L'\\') { i++; continue; }
        if (c == L'\n' || c == L'\r') return false;
        if (c == L'(') parens++;
        else if (c == L')') {
            parens--;
            if (parens == 0) { endParen = (int)i; break; }
        }
    }
    if (endParen < 0) return false;

    std::wstring destination = Trim(text.substr(close + 2, endParen - close - 2));
    if (!destination.empty() && destination.front() == L'<'
        && destination.find(L'>') != std::wstring::npos) {
        destination = destination.substr(1, destination.find(L'>') - 1);
    } else {
        size_t space = destination.find_first_of(L" \t");
        if (space != std::wstring::npos) destination = destination.substr(0, space);
    }

    node.type = InlineType::Link;
    node.dest = destination;
    node.children = ParseInlinesImpl(text.substr(bracket + 1, close - (int)bracket - 1), depth + 1);
    end = endParen + 1;
    return true;
}

bool TryParseAutolink(const std::wstring& text, size_t pos, Inline& node, size_t& end)
{
    size_t close = text.find(L'>', pos + 1);
    if (close == std::wstring::npos) return false;
    std::wstring inner = text.substr(pos + 1, close - pos - 1);
    if (inner.empty()) return false;
    for (wchar_t c : inner) {
        if (c == L' ' || c == L'\t' || c == L'\n' || c == L'\r' || c == L'<') return false;
    }

    size_t colon = inner.find(L':');
    bool isUri = colon != std::wstring::npos && colon > 0 && IsAsciiLetter(inner[0]);
    if (isUri) {
        for (size_t k = 0; k < colon; k++) {
            wchar_t c = inner[k];
            if (!IsAsciiAlnum(c) && c != L'+' && c != L'.' && c != L'-') { isUri = false; break; }
        }
    }
    size_t at = inner.find(L'@');
    bool isEmail = !isUri && at != std::wstring::npos && at > 0
        && inner.rfind(L'@') == at && inner.find(L'.', at) != std::wstring::npos;
    if (!isUri && !isEmail) return false;

    node.type = InlineType::Link;
    node.dest = isEmail ? L"mailto:" + inner : inner;
    Inline label;
    label.type = InlineType::Text;
    label.text = inner;
    node.children.clear();
    node.children.push_back(std::move(label));
    end = close + 1;
    return true;
}

bool TryParseInlineHtml(const std::wstring& text, size_t pos, Inline& node, size_t& end)
{
    if (pos + 1 >= text.size()) return false;
    wchar_t first = text[pos + 1];
    if (!IsAsciiLetter(first) && first != L'/' && first != L'!') return false;

    size_t close = text.find(L'>', pos + 1);
    if (close == std::wstring::npos) return false;
    std::wstring inner = text.substr(pos + 1, close - pos - 1);
    if (inner.find(L'\n') != std::wstring::npos || inner.find(L'\r') != std::wstring::npos) return false;
    size_t nameStart = first == L'/' ? 1 : 0;
    if (nameStart >= inner.size() || !IsAsciiLetter(inner[nameStart])) return false;

    node.type = InlineType::Html;
    node.text = text.substr(pos, close + 1 - pos);
    end = close + 1;
    return true;
}

std::vector<Inline> ParseInlinesImpl(const std::wstring& text, int depth)
{
    if (depth >= kMaxNestingDepth) {
        std::vector<Inline> nodes;
        if (!text.empty()) {
            Inline t;
            t.type = InlineType::Text;
            t.text = text;
            nodes.push_back(std::move(t));
        }
        return nodes;
    }

    std::vector<Inline> nodes;
    std::wstring buffer;

    auto flush = [&]() {
        if (!buffer.empty()) {
            Inline t;
            t.type = InlineType::Text;
            t.text = buffer;
            nodes.push_back(std::move(t));
            buffer.clear();
        }
    };

    size_t pos = 0;
    while (pos < text.size()) {
        wchar_t c = text[pos];

        if (c == L'\\' && pos + 1 < text.size() && IsAsciiPunct(text[pos + 1])) {
            buffer += text[pos + 1];
            pos += 2;
            continue;
        }
        if (c == L'\n') {
            flush();
            Inline br; br.type = InlineType::SoftBreak;
            nodes.push_back(std::move(br));
            pos++;
            continue;
        }
        if (c == L'\r') {
            flush();
            Inline br; br.type = InlineType::HardBreak;
            nodes.push_back(std::move(br));
            pos++;
            continue;
        }
        if (c == L'`') {
            Inline node; size_t end;
            if (TryParseCodeSpan(text, pos, node, end)) {
                flush();
                nodes.push_back(std::move(node));
                pos = end;
                continue;
            }
        }
        if (c == L'*' || c == L'_') {
            Inline node; size_t end;
            if (TryParseEmphasis(text, pos, node, end, depth)) {
                flush();
                nodes.push_back(std::move(node));
                pos = end;
                continue;
            }
        }
        if (c == L'~' && pos + 1 < text.size() && text[pos + 1] == L'~'
            && RunLength(text, pos, text.size(), L'~') == 2
            && pos + 2 < text.size() && !iswspace(text[pos + 2])) {
            int close = FindClosingDelimiter(text, L'~', 2, pos + 2);
            if (close > (int)pos + 2) {
                flush();
                Inline node;
                node.type = InlineType::Strike;
                node.children = ParseInlinesImpl(text.substr(pos + 2, close - (int)pos - 2), depth + 1);
                nodes.push_back(std::move(node));
                pos = close + 2;
                continue;
            }
        }
        if (c == L'!' && pos + 1 < text.size() && text[pos + 1] == L'[') {
            Inline link; size_t end;
            if (TryParseLink(text, pos + 1, link, end, depth)) {
                flush();
                Inline image;
                image.type = InlineType::Image;
                image.dest = link.dest;
                image.text = PlainText(link.children);
                nodes.push_back(std::move(image));
                pos = end;
                continue;
            }
        }
        if (c == L'[') {
            Inline link; size_t end;
            if (TryParseLink(text, pos, link, end, depth)) {
                flush();
                nodes.push_back(std::move(link));
                pos = end;
                continue;
            }
        }
        if (c == L'<') {
            Inline node; size_t end;
            if (TryParseAutolink(text, pos, node, end)) {
                flush();
                nodes.push_back(std::move(node));
                pos = end;
                continue;
            }
            if (TryParseInlineHtml(text, pos, node, end)) {
                flush();
                nodes.push_back(std::move(node));
                pos = end;
                continue;
            }
        }

        buffer += c;
        pos++;
    }

    flush();
    return nodes;
}

} // namespace

std::vector<Inline> ParseInlines(const std::wstring& text)
{
    return ParseInlinesImpl(text, 0);
}

std::wstring PlainText(const std::vector<Inline>& inlines)
{
    std::wstring out;
    for (const auto& node : inlines) {
        switch (node.type) {
        case InlineType::Text:
        case InlineType::Code:
            out += node.text;
            break;
        case InlineType::Strong:
        case InlineType::Emphasis:
        case InlineType::Strike:
        case InlineType::Link:
            out += PlainText(node.children);
            break;
        case InlineType::Image:
            out += node.text;
            break;
        case InlineType::SoftBreak:
        case InlineType::HardBreak:
            out += L' ';
            break;
        default:
            break;
        }
    }
    return out;
}

std::vector<Block> Parse(const std::wstring& source)
{
    auto raw = SplitLines(source);
    std::vector<Line> lines;
    lines.reserve(raw.size());
    for (size_t i = 0; i < raw.size(); i++) {
        lines.push_back({ std::move(raw[i]), (int)i + 1 });
    }
    return ParseBlocks(lines, 0);
}

} // namespace md
