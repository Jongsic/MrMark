#pragma once
// One Markdown file: byte-exact UTF-8/CRLF/BOM round-trips, dirty state,
// and a small undo stack for viewer-mode edits (checkbox toggles). The
// editor mode uses the OS control's own undo instead.

#include <string>
#include <vector>
#include <windows.h>

namespace md {

// Pure codec, unit-testable: BOM and CRLF split off from the text.
struct Decoded {
    std::wstring text; // '\n' line endings
    bool usesCrLf = false;
    bool hasBom = false;
};
Decoded DecodeUtf8(const std::vector<char>& bytes);
std::vector<char> EncodeUtf8(const std::wstring& text, bool usesCrLf, bool hasBom);

// Flips "[ ]" <-> "[x]" in a single source line; returns the line unchanged
// when it holds no checkbox marker.
std::wstring ToggleCheckboxMarker(const std::wstring& line);

struct Document {
    std::wstring path; // empty = untitled
    std::wstring text;
    std::wstring savedText;
    bool usesCrLf = false;
    bool hasBom = false;
    bool dirty = false;
    FILETIME knownWrite{};
    std::vector<std::wstring> undoStack, redoStack;

    std::wstring DisplayName() const;
    bool Load(const wchar_t* file);
    bool SaveAsPath(const wchar_t* file);
    bool Save() { return SaveAsPath(path.c_str()); }

    /// Undoable text replacement (viewer checkbox toggles).
    void SetTextUndoable(std::wstring newText);
    /// Editor sync on every change; the control owns undo there.
    void SetTextFromEditor(std::wstring newText);
    void Undo();
    void Redo();
    void ClearHistory();

    bool DiskChanged() const;
    bool ToggleCheckbox(int sourceLine); // 1-based; true if the line changed
};

} // namespace md
