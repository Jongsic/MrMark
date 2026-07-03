#include "document.h"

namespace md {

Decoded DecodeUtf8(const std::vector<char>& bytes)
{
    Decoded out;
    size_t offset = 0;
    out.hasBom = bytes.size() >= 3 && (unsigned char)bytes[0] == 0xEF
        && (unsigned char)bytes[1] == 0xBB && (unsigned char)bytes[2] == 0xBF;
    if (out.hasBom) offset = 3;

    int chars = MultiByteToWideChar(CP_UTF8, 0, bytes.data() + offset,
                                    (int)(bytes.size() - offset), nullptr, 0);
    std::wstring decoded(chars, L'\0');
    if (chars > 0) {
        MultiByteToWideChar(CP_UTF8, 0, bytes.data() + offset, (int)(bytes.size() - offset),
                            decoded.data(), chars);
    }

    out.usesCrLf = decoded.find(L"\r\n") != std::wstring::npos;
    if (out.usesCrLf) {
        std::wstring normalized;
        normalized.reserve(decoded.size());
        for (size_t i = 0; i < decoded.size(); i++) {
            if (decoded[i] == L'\r' && i + 1 < decoded.size() && decoded[i + 1] == L'\n') continue;
            normalized += decoded[i];
        }
        decoded = std::move(normalized);
    }
    out.text = std::move(decoded);
    return out;
}

std::vector<char> EncodeUtf8(const std::wstring& text, bool usesCrLf, bool hasBom)
{
    std::wstring output;
    if (usesCrLf) {
        output.reserve(text.size() + text.size() / 20);
        for (wchar_t c : text) {
            if (c == L'\n') output += L'\r';
            output += c;
        }
    } else {
        output = text;
    }

    int bytes = WideCharToMultiByte(CP_UTF8, 0, output.c_str(), (int)output.size(),
                                    nullptr, 0, nullptr, nullptr);
    std::vector<char> encoded;
    encoded.reserve(bytes + 3);
    if (hasBom) {
        encoded.push_back((char)0xEF);
        encoded.push_back((char)0xBB);
        encoded.push_back((char)0xBF);
    }
    size_t payload = encoded.size();
    encoded.resize(payload + bytes);
    WideCharToMultiByte(CP_UTF8, 0, output.c_str(), (int)output.size(),
                        encoded.data() + payload, bytes, nullptr, nullptr);
    return encoded;
}

std::wstring ToggleCheckboxMarker(const std::wstring& line)
{
    for (size_t i = 0; i + 2 < line.size(); i++) {
        if (line[i] == L'[' && line[i + 2] == L']'
            && (line[i + 1] == L' ' || line[i + 1] == L'x' || line[i + 1] == L'X')) {
            std::wstring out = line;
            out[i + 1] = line[i + 1] == L' ' ? L'x' : L' ';
            return out;
        }
    }
    return line;
}

static bool ReadFileTime(const std::wstring& path, FILETIME& out)
{
    WIN32_FILE_ATTRIBUTE_DATA data;
    if (!GetFileAttributesExW(path.c_str(), GetFileExInfoStandard, &data)) return false;
    out = data.ftLastWriteTime;
    return true;
}

std::wstring Document::DisplayName() const
{
    if (path.empty()) return L"Untitled.md";
    size_t slash = path.find_last_of(L'\\');
    return slash == std::wstring::npos ? path : path.substr(slash + 1);
}

bool Document::Load(const wchar_t* file)
{
    HANDLE h = CreateFileW(file, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
                           OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (h == INVALID_HANDLE_VALUE) return false;
    LARGE_INTEGER size;
    GetFileSizeEx(h, &size);
    std::vector<char> bytes((size_t)size.QuadPart);
    DWORD read = 0;
    if (!bytes.empty()) ReadFile(h, bytes.data(), (DWORD)bytes.size(), &read, nullptr);
    CloseHandle(h);

    Decoded decoded = DecodeUtf8(bytes);
    wchar_t full[MAX_PATH];
    GetFullPathNameW(file, MAX_PATH, full, nullptr);
    path = full;
    text = std::move(decoded.text);
    savedText = text;
    usesCrLf = decoded.usesCrLf;
    hasBom = decoded.hasBom;
    dirty = false;
    undoStack.clear();
    redoStack.clear();
    ReadFileTime(path, knownWrite);
    return true;
}

bool Document::SaveAsPath(const wchar_t* file)
{
    auto encoded = EncodeUtf8(text, usesCrLf, hasBom);
    HANDLE h = CreateFileW(file, GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
                           FILE_ATTRIBUTE_NORMAL, nullptr);
    if (h == INVALID_HANDLE_VALUE) return false;
    DWORD written = 0;
    if (!encoded.empty()) WriteFile(h, encoded.data(), (DWORD)encoded.size(), &written, nullptr);
    CloseHandle(h);

    wchar_t full[MAX_PATH];
    GetFullPathNameW(file, MAX_PATH, full, nullptr);
    path = full;
    savedText = text;
    dirty = false;
    ReadFileTime(path, knownWrite);
    return true;
}

void Document::SetTextUndoable(std::wstring newText)
{
    if (newText == text) return;
    undoStack.push_back(text);
    redoStack.clear();
    text = std::move(newText);
    dirty = text != savedText;
}

void Document::SetTextFromEditor(std::wstring newText)
{
    if (newText == text) return;
    text = std::move(newText);
    dirty = text != savedText;
}

void Document::Undo()
{
    if (undoStack.empty()) return;
    redoStack.push_back(text);
    text = undoStack.back();
    undoStack.pop_back();
    dirty = text != savedText;
}

void Document::Redo()
{
    if (redoStack.empty()) return;
    undoStack.push_back(text);
    text = redoStack.back();
    redoStack.pop_back();
    dirty = text != savedText;
}

void Document::ClearHistory()
{
    undoStack.clear();
    redoStack.clear();
}

bool Document::DiskChanged() const
{
    if (path.empty()) return false;
    FILETIME now;
    if (!ReadFileTime(path, now)) return false;
    return CompareFileTime(&now, &knownWrite) != 0;
}

bool Document::ToggleCheckbox(int sourceLine)
{
    int line = 1;
    size_t start = 0;
    for (size_t i = 0; i <= text.size(); i++) {
        if (i == text.size() || text[i] == L'\n') {
            if (line == sourceLine) {
                std::wstring lineText = text.substr(start, i - start);
                std::wstring toggled = ToggleCheckboxMarker(lineText);
                if (toggled == lineText) return false;
                SetTextUndoable(text.substr(0, start) + toggled + text.substr(i));
                return true;
            }
            line++;
            start = i + 1;
        }
    }
    return false;
}

} // namespace md
