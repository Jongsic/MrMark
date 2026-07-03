#pragma once
// Per-line style analysis for the editor's hybrid (Typora-style) mode:
// which ranges get which style, and which delimiter ranges are pure syntax
// chrome to conceal. Pure and unit-testable; the editor maps the spans onto
// the OS text control. Delimiter geometry is verified character by
// character, so malformed shapes simply conceal nothing.

#include <string>
#include <vector>

namespace md {

enum StyleFlags {
    kBold = 1 << 0,
    kItalic = 1 << 1,
    kStrike = 1 << 2,
    kCodeSpan = 1 << 3,
    kLinkSpan = 1 << 4,
    kConcealed = 1 << 5, // syntax chrome hidden unless the line is revealed
};

struct StyleSpan {
    int start, length, flags;
};

struct LineStyle {
    int headingLevel = 0;
    bool isQuote = false;
    bool isCode = false; // inside a fenced block (or a fence line itself)
    std::vector<StyleSpan> spans;
};

bool IsFenceLine(const std::wstring& line);

/// Fence state per line: true = the line belongs to a fenced code block
/// (including the fence lines themselves).
std::vector<char> CodeLineMap(const std::vector<std::wstring>& lines);

LineStyle AnalyzeLine(const std::wstring& line, bool isCodeLine);

} // namespace md
