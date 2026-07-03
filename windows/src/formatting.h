#pragma once
// Pure text transformations behind the formatting toolbar. Operates on
// (text, selection) and returns a single replacement edit so the editor can
// apply it through the undo-aware editing path. Fully unit-tested; the same
// semantics as the macOS MarkdownFormatting so both platforms behave
// identically.

#include <string>
#include <utility>

namespace md {

struct FormatEdit {
    size_t start, length;       // range of the original text to replace
    std::wstring replacement;
    size_t selStart, selLength; // selection after the edit, post-edit coords
};

FormatEdit ToggleInlineWrap(const std::wstring& text, size_t selStart, size_t selLength,
                            const std::wstring& delimiter);
FormatEdit SetHeading(const std::wstring& text, size_t selStart, size_t selLength, int level);
FormatEdit ToggleBulletList(const std::wstring& text, size_t selStart, size_t selLength);
FormatEdit ToggleChecklist(const std::wstring& text, size_t selStart, size_t selLength);
FormatEdit ToggleNumberedList(const std::wstring& text, size_t selStart, size_t selLength);
FormatEdit InsertLink(const std::wstring& text, size_t selStart, size_t selLength);
FormatEdit InsertImage(const std::wstring& text, size_t selStart, size_t selLength);
FormatEdit InsertCodeBlock(const std::wstring& text, size_t selStart, size_t selLength);

/// Expands a selection to whole lines, including the trailing newline.
std::pair<size_t, size_t> LineRange(const std::wstring& text, size_t start, size_t length);

} // namespace md
