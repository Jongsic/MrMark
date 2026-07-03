#include "styler.h"

#include <algorithm>
#include <cwctype>

namespace md {

namespace {

int RunLength(const std::wstring& s, size_t pos, size_t end, wchar_t c)
{
    int n = 0;
    while (pos + n < end && s[pos + n] == c) n++;
    return n;
}

int FindClosing(const std::wstring& line, wchar_t marker, int length, size_t from, size_t to)
{
    size_t i = from;
    while (i < to) {
        wchar_t c = line[i];
        if (c == L'\\') { i += 2; continue; }
        if (c != marker) { i++; continue; }
        int run = RunLength(line, i, to, marker);
        if (run == length && i > from && !iswspace(line[i - 1])) {
            if (marker == L'_' && i + run < to && iswalnum(line[i + run])) {
                i += run;
                continue;
            }
            return (int)i;
        }
        i += run;
    }
    return -1;
}

int FindBacktickRun(const std::wstring& line, size_t from, size_t to, int length)
{
    size_t i = from;
    while (i < to) {
        if (line[i] != L'`') { i++; continue; }
        int run = RunLength(line, i, to, L'`');
        if (run == length) return (int)i;
        i += run;
    }
    return -1;
}

void ScanInlines(const std::wstring& line, size_t from, size_t to,
                 std::vector<StyleSpan>& spans);

bool TryEmphasis(const std::wstring& line, size_t pos, size_t to,
                 std::vector<StyleSpan>& spans, size_t& end)
{
    wchar_t marker = line[pos];
    int run = std::min(RunLength(line, pos, to, marker), 3);

    size_t contentStart = pos + run;
    if (contentStart >= to || iswspace(line[contentStart])) return false;
    if (marker == L'_' && pos > 0 && iswalnum(line[pos - 1])) return false;

    for (int length = run; length >= 1; length--) {
        int close = FindClosing(line, marker, length, pos + length, to);
        if (close < 0 || close == (int)pos + length) continue;

        int flags = length == 3 ? (kBold | kItalic) : (length == 2 ? kBold : kItalic);
        spans.push_back({ (int)pos, close + length - (int)pos, flags });
        spans.push_back({ (int)pos, length, kConcealed });
        spans.push_back({ close, length, kConcealed });
        ScanInlines(line, pos + length, close, spans);
        end = close + length;
        return true;
    }
    return false;
}

bool TryLink(const std::wstring& line, size_t pos, size_t to,
             std::vector<StyleSpan>& spans, size_t& end)
{
    bool isImage = line[pos] == L'!';
    size_t bracket = isImage ? pos + 1 : pos;
    if (bracket >= to || line[bracket] != L'[') return false;

    int depth = 0;
    int closeBracket = -1;
    for (size_t i = bracket; i < to; i++) {
        wchar_t c = line[i];
        if (c == L'\\') { i++; continue; }
        if (c == L'[') depth++;
        else if (c == L']') {
            depth--;
            if (depth == 0) { closeBracket = (int)i; break; }
        }
    }
    if (closeBracket < 0 || closeBracket + 1 >= (int)to || line[closeBracket + 1] != L'(') {
        return false;
    }

    int parens = 0;
    int endParen = -1;
    for (size_t i = closeBracket + 1; i < to; i++) {
        wchar_t c = line[i];
        if (c == L'\\') { i++; continue; }
        if (c == L'(') parens++;
        else if (c == L')') {
            parens--;
            if (parens == 0) { endParen = (int)i; break; }
        }
    }
    if (endParen < 0) return false;

    // [text](url) -> conceal "[" and "](url)"; ![alt](src) -> "![" and "](src)".
    spans.push_back({ (int)pos, endParen + 1 - (int)pos, kLinkSpan });
    spans.push_back({ (int)pos, (int)bracket + 1 - (int)pos, kConcealed });
    spans.push_back({ closeBracket, endParen + 1 - closeBracket, kConcealed });
    ScanInlines(line, bracket + 1, closeBracket, spans);
    end = endParen + 1;
    return true;
}

bool TryAutolink(const std::wstring& line, size_t pos, size_t to,
                 std::vector<StyleSpan>& spans, size_t& end)
{
    size_t close = line.find(L'>', pos + 1);
    if (close == std::wstring::npos || close >= to) return false;
    std::wstring inner = line.substr(pos + 1, close - pos - 1);
    if (inner.empty()) return false;
    for (wchar_t c : inner) {
        if (iswspace(c)) return false;
    }
    size_t colon = inner.find(L':');
    bool isUri = colon != std::wstring::npos && colon > 0
        && ((inner[0] >= L'a' && inner[0] <= L'z') || (inner[0] >= L'A' && inner[0] <= L'Z'));
    if (isUri) {
        for (size_t k = 0; k < colon; k++) {
            wchar_t c = inner[k];
            bool ok = (c >= L'a' && c <= L'z') || (c >= L'A' && c <= L'Z')
                || (c >= L'0' && c <= L'9') || c == L'+' || c == L'.' || c == L'-';
            if (!ok) { isUri = false; break; }
        }
    }
    if (!isUri) return false;

    spans.push_back({ (int)pos, (int)close + 1 - (int)pos, kLinkSpan });
    spans.push_back({ (int)pos, 1, kConcealed });
    spans.push_back({ (int)close, 1, kConcealed });
    end = close + 1;
    return true;
}

void ScanInlines(const std::wstring& line, size_t from, size_t to,
                 std::vector<StyleSpan>& spans)
{
    size_t pos = from;
    while (pos < to) {
        wchar_t c = line[pos];

        if (c == L'\\' && pos + 1 < to) {
            pos += 2;
            continue;
        }

        if (c == L'`') {
            int open = RunLength(line, pos, to, L'`');
            int close = FindBacktickRun(line, pos + open, to, open);
            if (close >= 0) {
                spans.push_back({ (int)pos, close + open - (int)pos, kCodeSpan });
                spans.push_back({ (int)pos, open, kConcealed });
                spans.push_back({ close, open, kConcealed });
                pos = close + open;
                continue;
            }
            pos += open;
            continue;
        }

        if (c == L'*' || c == L'_') {
            size_t end;
            if (TryEmphasis(line, pos, to, spans, end)) {
                pos = end;
                continue;
            }
            pos += RunLength(line, pos, to, c);
            continue;
        }

        if (c == L'~' && RunLength(line, pos, to, L'~') >= 2) {
            int close = FindClosing(line, L'~', 2, pos + 2, to);
            if (close > (int)pos + 2) {
                spans.push_back({ (int)pos, close + 2 - (int)pos, kStrike });
                spans.push_back({ (int)pos, 2, kConcealed });
                spans.push_back({ close, 2, kConcealed });
                ScanInlines(line, pos + 2, close, spans);
                pos = close + 2;
                continue;
            }
            pos += 2;
            continue;
        }

        if (c == L'[' || (c == L'!' && pos + 1 < to && line[pos + 1] == L'[')) {
            size_t end;
            if (TryLink(line, pos, to, spans, end)) {
                pos = end;
                continue;
            }
            pos++;
            continue;
        }

        if (c == L'<') {
            size_t end;
            if (TryAutolink(line, pos, to, spans, end)) {
                pos = end;
                continue;
            }
            pos++;
            continue;
        }

        pos++;
    }
}

} // namespace

bool IsFenceLine(const std::wstring& line)
{
    size_t indent = 0;
    while (indent < line.size() && line[indent] == L' ' && indent < 4) indent++;
    if (indent > 3 || indent >= line.size()) return false;
    wchar_t marker = line[indent];
    if (marker != L'`' && marker != L'~') return false;
    return RunLength(line, indent, line.size(), marker) >= 3;
}

std::vector<char> CodeLineMap(const std::vector<std::wstring>& lines)
{
    std::vector<char> map(lines.size(), 0);
    bool inFence = false;
    for (size_t i = 0; i < lines.size(); i++) {
        if (IsFenceLine(lines[i])) {
            map[i] = 1;
            inFence = !inFence;
        } else {
            map[i] = inFence ? 1 : 0;
        }
    }
    return map;
}

LineStyle AnalyzeLine(const std::wstring& line, bool isCodeLine)
{
    LineStyle style;
    if (isCodeLine) {
        style.isCode = true;
        return style;
    }

    size_t contentStart = 0;

    // ATX heading: "## Title" -> style the line, conceal "## ".
    int level = 0;
    while ((size_t)level < line.size() && line[level] == L'#' && level < 7) level++;
    if (level >= 1 && level <= 6 && (size_t)level < line.size() && line[level] == L' ') {
        style.headingLevel = level;
        style.spans.push_back({ 0, level + 1, kConcealed });
        contentStart = level + 1;
    }

    // Blockquote: the whole line reads secondary; the '>' stays visible.
    if (style.headingLevel == 0) {
        size_t indent = 0;
        while (indent < line.size() && line[indent] == L' ' && indent < 4) indent++;
        if (indent < line.size() && line[indent] == L'>') style.isQuote = true;
    }

    ScanInlines(line, contentStart, line.size(), style.spans);
    return style;
}

} // namespace md
