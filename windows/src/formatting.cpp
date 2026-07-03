#include "formatting.h"

#include <functional>
#include <vector>

namespace md {

namespace {

bool StartsWith(const std::wstring& s, const std::wstring& prefix)
{
    return s.size() >= prefix.size() && s.compare(0, prefix.size(), prefix) == 0;
}

bool EndsWith(const std::wstring& s, const std::wstring& suffix)
{
    return s.size() >= suffix.size()
        && s.compare(s.size() - suffix.size(), suffix.size(), suffix) == 0;
}

std::vector<std::wstring> Split(const std::wstring& s)
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

std::wstring Join(const std::vector<std::wstring>& lines)
{
    std::wstring out;
    for (size_t i = 0; i < lines.size(); i++) {
        if (i > 0) out += L'\n';
        out += lines[i];
    }
    return out;
}

int HeadingPrefixLength(const std::wstring& line)
{
    int count = 0;
    for (wchar_t c : line) {
        if (c == L'#' && count < 6) count++;
        else break;
    }
    return count;
}

bool StripBullet(const std::wstring& line, std::wstring& out)
{
    for (const wchar_t* marker : { L"- ", L"* ", L"+ " }) {
        if (StartsWith(line, marker)) {
            out = line.substr(2);
            return true;
        }
    }
    return false;
}

bool StripChecklist(const std::wstring& line, std::wstring& out)
{
    for (const wchar_t* marker : { L"- [ ] ", L"- [x] ", L"- [X] " }) {
        if (StartsWith(line, marker)) {
            out = line.substr(6);
            return true;
        }
    }
    return false;
}

bool StripNumber(const std::wstring& line, std::wstring& out)
{
    size_t dot = line.find(L'.');
    if (dot == std::wstring::npos || dot == 0) return false;
    for (size_t i = 0; i < dot; i++) {
        if (line[i] < L'0' || line[i] > L'9') return false;
    }
    if (dot + 1 >= line.size() || line[dot + 1] != L' ') return false;
    out = line.substr(dot + 2);
    return true;
}

std::vector<std::wstring> SelectedLines(const std::wstring& text, size_t selStart,
                                        size_t selLength)
{
    auto [start, length] = LineRange(text, selStart, selLength);
    std::wstring content = text.substr(start, length);
    if (EndsWith(content, L"\n")) content.pop_back();
    return Split(content);
}

FormatEdit TransformLines(const std::wstring& text, size_t selStart, size_t selLength,
                          const std::function<std::wstring(const std::wstring&)>& transform)
{
    auto [start, length] = LineRange(text, selStart, selLength);
    std::wstring content = text.substr(start, length);
    bool hadTrailingNewline = EndsWith(content, L"\n");
    if (hadTrailingNewline) content.pop_back();

    auto lines = Split(content);
    std::wstring replaced;
    for (size_t i = 0; i < lines.size(); i++) {
        if (i > 0) replaced += L'\n';
        replaced += transform(lines[i]);
    }
    if (hadTrailingNewline) replaced += L'\n';

    return { start, length, replaced, start, replaced.size() };
}

FormatEdit ToggleLinePrefix(const std::wstring& text, size_t selStart, size_t selLength,
                            const std::wstring& prefix,
                            bool (*strip)(const std::wstring&, std::wstring&))
{
    auto lines = SelectedLines(text, selStart, selLength);
    bool allPrefixed = true;
    for (const auto& line : lines) {
        std::wstring stripped;
        if (!line.empty() && !strip(line, stripped)) {
            allPrefixed = false;
            break;
        }
    }
    return TransformLines(text, selStart, selLength, [&](const std::wstring& line) {
        std::wstring stripped;
        if (allPrefixed) return strip(line, stripped) ? stripped : line;
        if (line.empty()) return line;
        return prefix + (strip(line, stripped) ? stripped : line);
    });
}

} // namespace

std::pair<size_t, size_t> LineRange(const std::wstring& text, size_t start, size_t length)
{
    size_t lineStart = 0;
    if (start > 0) {
        size_t from = (start < text.size() ? start : text.size()) - 1;
        size_t newline = text.rfind(L'\n', from);
        lineStart = newline == std::wstring::npos ? 0 : newline + 1;
    }

    size_t end = start + length;
    size_t scanFrom = length > 0 ? end - 1 : end;
    size_t newline = scanFrom >= text.size() ? std::wstring::npos : text.find(L'\n', scanFrom);
    size_t lineEnd = newline == std::wstring::npos ? text.size() : newline + 1;
    return { lineStart, lineEnd - lineStart };
}

FormatEdit ToggleInlineWrap(const std::wstring& text, size_t selStart, size_t selLength,
                            const std::wstring& delimiter)
{
    std::wstring selected = text.substr(selStart, selLength);
    size_t d = delimiter.size();

    // Selection already includes the delimiters -> unwrap.
    if (StartsWith(selected, delimiter) && EndsWith(selected, delimiter)
        && selected.size() >= d * 2) {
        std::wstring inner = selected.substr(d, selected.size() - d * 2);
        return { selStart, selLength, inner, selStart, inner.size() };
    }

    // Delimiters directly around the selection -> unwrap.
    if (selStart >= d && selStart + selLength + d <= text.size()
        && text.compare(selStart - d, d, delimiter) == 0
        && text.compare(selStart + selLength, d, delimiter) == 0) {
        return { selStart - d, selLength + d * 2, selected, selStart - d, selLength };
    }

    // Wrap. Empty selection puts the caret between the delimiters.
    return { selStart, selLength, delimiter + selected + delimiter, selStart + d, selLength };
}

FormatEdit SetHeading(const std::wstring& text, size_t selStart, size_t selLength, int level)
{
    return TransformLines(text, selStart, selLength, [&](const std::wstring& line) {
        int existing = HeadingPrefixLength(line);
        std::wstring content = line.substr(existing);
        if (existing > 0 && StartsWith(content, L" ")) content = content.substr(1);
        int currentLevel = 0;
        for (int i = 0; i < existing; i++) {
            if (line[i] == L'#') currentLevel++;
        }
        if (currentLevel == level) return content;
        return std::wstring(level, L'#') + L" " + content;
    });
}

FormatEdit ToggleBulletList(const std::wstring& text, size_t selStart, size_t selLength)
{
    return ToggleLinePrefix(text, selStart, selLength, L"- ", StripBullet);
}

FormatEdit ToggleChecklist(const std::wstring& text, size_t selStart, size_t selLength)
{
    return ToggleLinePrefix(text, selStart, selLength, L"- [ ] ", StripChecklist);
}

FormatEdit ToggleNumberedList(const std::wstring& text, size_t selStart, size_t selLength)
{
    auto lines = SelectedLines(text, selStart, selLength);
    bool allNumbered = true;
    for (const auto& line : lines) {
        std::wstring stripped;
        if (!line.empty() && !StripNumber(line, stripped)) {
            allNumbered = false;
            break;
        }
    }
    int number = 0;
    return TransformLines(text, selStart, selLength, [&](const std::wstring& line) {
        std::wstring stripped;
        if (allNumbered) return StripNumber(line, stripped) ? stripped : line;
        if (line.empty()) return line;
        number++;
        std::wstring rest = line;
        if (StripNumber(line, stripped) || StripBullet(line, stripped)
            || StripChecklist(line, stripped)) {
            rest = stripped;
        }
        return std::to_wstring(number) + L". " + rest;
    });
}

FormatEdit InsertLink(const std::wstring& text, size_t selStart, size_t selLength)
{
    std::wstring selected = text.substr(selStart, selLength);
    std::wstring label = selected.empty() ? L"text" : selected;
    std::wstring replacement = L"[" + label + L"](url)";
    size_t urlLocation = selStart + 1 + label.size() + 2;
    return { selStart, selLength, replacement, urlLocation, 3 };
}

FormatEdit InsertImage(const std::wstring& text, size_t selStart, size_t selLength)
{
    std::wstring selected = text.substr(selStart, selLength);
    std::wstring alt = selected.empty() ? L"alt" : selected;
    std::wstring replacement = L"![" + alt + L"](path)";
    size_t pathLocation = selStart + 2 + alt.size() + 2;
    return { selStart, selLength, replacement, pathLocation, 4 };
}

FormatEdit InsertCodeBlock(const std::wstring& text, size_t selStart, size_t selLength)
{
    auto [start, length] = LineRange(text, selStart, selLength);
    std::wstring content = text.substr(start, length);
    bool hadTrailingNewline = EndsWith(content, L"\n");
    if (hadTrailingNewline) content.pop_back();
    std::wstring replacement = L"```\n" + content + L"\n```" + (hadTrailingNewline ? L"\n" : L"");
    // Caret on the fence line, ready to type a language.
    return { start, length, replacement, start + 3, 0 };
}

} // namespace md
