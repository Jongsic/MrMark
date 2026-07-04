// MrMark for Windows — an ultra-fast, minimal Markdown viewer & editor.
// One file = one window. Native Win32; the document view is the OS text
// control (RichEdit), so selection, copy, IME, accessibility, and zoom all
// behave exactly like Windows. Two modes share that one control:
//
//   Viewer (the fast path): the parsed document streamed in as RTF —
//     read-only, clickable checkboxes and links, instant first paint.
//   Editor (hybrid, Typora-style): the buffer holds the exact Markdown
//     source; the caret's paragraph shows it plainly while everywhere else
//     the syntax chrome is concealed via hidden-text formatting. Undo is the
//     control's own; styling passes are excluded from it (TOM undo suspend).
//
// Pure logic lives beside this file (parser / formatting / styler /
// document) and is unit-tested in ../tests.

#define NOMINMAX
#define _RICHEDIT_VER 0x0800
#include <windows.h>
#include <windowsx.h>
#include <commctrl.h>
#include <commdlg.h>
#include <dwmapi.h>
#include <richedit.h>
#include <richole.h>
#include <tom.h>
#include <shellapi.h>
#include <shlobj.h>
#include <shlwapi.h>
#include <uxtheme.h>
#include <wincodec.h>
#include <wrl/client.h>

#include <algorithm>
#include <cstdio>
#include <string>
#include <vector>

#include "document.h"
#include "formatting.h"
#include "parser.h"
#include "styler.h"

#pragma comment(lib, "comctl32.lib")
#pragma comment(lib, "comdlg32.lib")
#pragma comment(lib, "dwmapi.lib")
#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "oleaut32.lib")
#pragma comment(lib, "shell32.lib")
#pragma comment(lib, "shlwapi.lib")
#pragma comment(lib, "uxtheme.lib")
#pragma comment(lib, "version.lib")
#pragma comment(lib, "windowscodecs.lib")

using Microsoft::WRL::ComPtr;

// MARK: - Command IDs

enum {
    IDM_NEW = 40001, IDM_OPEN, IDM_SAVE, IDM_SAVEAS, IDM_CLOSE,
    IDM_UNDO, IDM_REDO, IDM_FIND, IDM_FINDNEXT, IDM_FINDPREV,
    IDM_TOGGLEMODE, IDM_ZOOMIN, IDM_ZOOMOUT, IDM_ZOOMRESET,
    IDM_BOLD, IDM_ITALIC, IDM_H1, IDM_H2, IDM_H3,
    IDM_BULLET, IDM_NUMBERED, IDM_CHECKLIST, IDM_LINK, IDM_IMAGE, IDM_CODEBLOCK,
    IDM_SETDEFAULT, IDM_ABOUT,
    IDM_RECENT_FIRST = 40100, IDM_RECENT_LAST = 40109,
};

static const UINT kActivateMagic = 0x4D4D4B31; // 'MMK1' — WM_COPYDATA "own this file?"

// MARK: - Launch clock (--benchmark)

namespace clockmarks {
static LARGE_INTEGER start, freq;
static bool enabled = false;
static bool reported = false;

static void Init(bool on)
{
    QueryPerformanceFrequency(&freq);
    QueryPerformanceCounter(&start);
    enabled = on;
    if (enabled) AttachConsole(ATTACH_PARENT_PROCESS);
}

static void Emit(const wchar_t* line)
{
    fputws(line, stdout);
    fflush(stdout);
    wchar_t path[MAX_PATH];
    if (GetTempPathW(MAX_PATH, path)) {
        wcscat_s(path, L"MrMark-benchmark.log");
        FILE* f = nullptr;
        if (_wfopen_s(&f, path, L"a, ccs=UTF-8") == 0 && f) {
            fputws(line, f);
            fclose(f);
        }
    }
}

static long Elapsed()
{
    LARGE_INTEGER now;
    QueryPerformanceCounter(&now);
    return (long)((now.QuadPart - start.QuadPart) * 1000 / freq.QuadPart);
}

static void Mark(const wchar_t* label)
{
    if (!enabled || reported) return;
    wchar_t line[128];
    swprintf_s(line, L"  %s: %ld ms\n", label, Elapsed());
    Emit(line);
}

static void Done()
{
    if (reported) return;
    reported = true;
    if (!enabled) return;
    wchar_t line[128];
    swprintf_s(line, L"launch-to-viewer: %ld ms\n", Elapsed());
    Emit(line);
}
} // namespace clockmarks

// MARK: - Theme

struct Theme {
    COLORREF windowBg, barBg, label, secondary, separator, link, accent, codeBg;
    bool dark;
};

static Theme LightTheme()
{
    return { RGB(0xFF, 0xFF, 0xFF), RGB(0xF7, 0xF7, 0xF7), RGB(0x1A, 0x1A, 0x1A),
             RGB(0x77, 0x77, 0x77), RGB(0xD9, 0xD9, 0xD9), RGB(0x00, 0x66, 0xCC),
             RGB(0x00, 0x78, 0xD4), RGB(0xF2, 0xF2, 0xF2), false };
}

static Theme DarkTheme()
{
    return { RGB(0x1E, 0x1E, 0x1E), RGB(0x25, 0x25, 0x25), RGB(0xE8, 0xE8, 0xE8),
             RGB(0x9A, 0x9A, 0x9A), RGB(0x3F, 0x3F, 0x3F), RGB(0x4D, 0xA3, 0xFF),
             RGB(0x4C, 0xC2, 0xFF), RGB(0x2B, 0x2B, 0x2B), true };
}

static bool SystemUsesDarkApps()
{
    DWORD value = 1, size = sizeof(value);
    RegGetValueW(HKEY_CURRENT_USER,
                 L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
                 L"AppsUseLightTheme", RRF_RT_REG_DWORD, nullptr, &value, &size);
    return value == 0;
}

// MARK: - App state

static const int kTopBar = 38;
static const int kFindBar = 36;
static const float kHeadingSizesPx[6] = { 26, 21, 18, 16, 15, 15 };

enum class Mode { Viewer, Editor };

struct BarButton {
    int id;              // 0 = separator
    const wchar_t* glyph; // MDL2 glyph, or nullptr for a text label
    const wchar_t* label; // text label / tooltip
    RECT rect{};
};

struct App {
    HWND hwnd = nullptr;
    HWND richEdit = nullptr;
    HWND findEdit = nullptr;
    HWND zoomSlider = nullptr;
    HWND tooltip = nullptr;
    md::Document doc;
    Mode mode = Mode::Viewer;
    Theme theme = LightTheme();
    std::wstring monoFamily = L"Consolas";
    float dpi = 1.0f;
    float zoom = 1.0f;

    HFONT uiFont = nullptr, uiBoldFont = nullptr, uiItalicFont = nullptr, iconFont = nullptr,
          bodyFont = nullptr, bodyBoldFont = nullptr;
    HBRUSH barBrush = nullptr, findEditBrush = nullptr;

    // Viewer: checkbox glyph positions (cp) -> source line, plus link fields.
    struct CheckboxHit { LONG cpMin, cpMax; int line; };
    std::vector<CheckboxHit> checkboxes;

    // Editor: source mirror for incremental restyling.
    std::vector<std::wstring> lines;
    std::vector<char> codeMap;
    int activeLine = 0;
    bool internalChange = false;
    ComPtr<ITextDocument> tom;

    // Find bar
    bool findOpen = false;
    std::wstring findQuery;
    int findTotal = 0, findIndex = 0;

    // Bar chrome (client px)
    std::vector<BarButton> buttons; // left side, current mode
    BarButton toggleButton{ IDM_TOGGLEMODE }, aboutButton{ IDM_ABOUT };
    RECT zoomMinus{}, zoomPlus{}, zoomLabel{};
    RECT findPrev{}, findNext{}, findClose{};
    bool handCursor = false;

    int ContentTop() const { return (int)((kTopBar + (findOpen ? kFindBar : 0)) * dpi); }
};

static App g_app;
static std::wstring g_baseDir; // document folder, for relative image paths

// MARK: - Small utilities

static std::wstring GetControlText()
{
    GETTEXTLENGTHEX lenSpec{ GTL_DEFAULT, 1200 };
    LONG length = (LONG)SendMessageW(g_app.richEdit, EM_GETTEXTLENGTHEX, (WPARAM)&lenSpec, 0);
    std::wstring buffer(length + 1, L'\0');
    GETTEXTEX spec{};
    spec.cb = (DWORD)((length + 1) * sizeof(wchar_t));
    spec.flags = GT_DEFAULT;
    spec.codepage = 1200;
    LONG copied = (LONG)SendMessageW(g_app.richEdit, EM_GETTEXTEX, (WPARAM)&spec,
                                     (LPARAM)buffer.data());
    buffer.resize(copied);
    for (auto& c : buffer) {
        if (c == L'\r') c = L'\n'; // RichEdit paragraph breaks are '\r'
    }
    return buffer;
}

static std::vector<std::wstring> SplitLines(const std::wstring& s)
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

static size_t LineStartOffset(int line)
{
    size_t offset = 0;
    for (int i = 0; i < line && i < (int)g_app.lines.size(); i++) {
        offset += g_app.lines[i].size() + 1;
    }
    return offset;
}

static int LineOfOffset(size_t offset)
{
    size_t position = 0;
    for (int i = 0; i < (int)g_app.lines.size(); i++) {
        position += g_app.lines[i].size() + 1;
        if (offset < position) return i;
    }
    return std::max(0, (int)g_app.lines.size() - 1);
}

static bool ResolveLocalImage(const std::wstring& src, std::wstring& outPath)
{
    if (src.rfind(L"http://", 0) == 0 || src.rfind(L"https://", 0) == 0) return false;
    std::wstring candidate = src;
    for (auto& c : candidate) {
        if (c == L'/') c = L'\\';
    }
    if (!(candidate.size() >= 2 && (candidate[1] == L':' || candidate[0] == L'\\'))) {
        if (g_baseDir.empty()) return false;
        candidate = g_baseDir + L"\\" + candidate;
    }
    if (GetFileAttributesW(candidate.c_str()) == INVALID_FILE_ATTRIBUTES) return false;
    outPath = candidate;
    return true;
}

// MARK: - RTF generation (viewer mode)

// The rendered view is standard RTF streamed into the control: theme colors,
// hanging indents for lists, tab-stop aligned tables (the macOS renderer's
// borderless grid), hyperlink fields, and placeholder tokens replaced by
// EM_INSERTIMAGE afterwards.

namespace rtf {

enum { ColLabel = 1, ColSecondary, ColLink, ColAccent, ColCodeBg, ColSeparator };

static void Escape(std::string& out, const std::wstring& text)
{
    for (wchar_t c : text) {
        if (c == L'\\' || c == L'{' || c == L'}') {
            out += '\\';
            out += (char)c;
        } else if (c == L'\n') {
            out += "\\line ";
        } else if (c < 128) {
            out += (char)c;
        } else {
            char buf[16];
            sprintf_s(buf, "\\u%d?", (int)(short)c);
            out += buf;
        }
    }
}

struct Builder {
    std::string out;
    const Theme* theme = nullptr;
    std::vector<int> checkboxLines;
    std::vector<std::wstring> images;
    int imageCount = 0;

    static int HalfPt(float px) { return (int)(px * 0.75f * 2 + 0.5f); }
    static int Twips(float px) { return (int)(px * 15 + 0.5f); }

    void Color(COLORREF c)
    {
        char buf[64];
        sprintf_s(buf, "\\red%d\\green%d\\blue%d;", GetRValue(c), GetGValue(c), GetBValue(c));
        out += buf;
    }

    void Header()
    {
        out += "{\\rtf1\\ansi\\deff0{\\fonttbl{\\f0\\fswiss Segoe UI;}{\\f1\\fmodern ";
        std::wstring family = g_app.monoFamily;
        out += std::string(family.begin(), family.end()); // ASCII family names only
        out += ";}}{\\colortbl;";
        Color(theme->label);
        Color(theme->secondary);
        Color(theme->link);
        Color(theme->accent);
        Color(theme->codeBg);
        Color(theme->separator);
        out += "}";
    }

    // Exact line spacing matching the macOS renderer: paragraph styles
    // there use lineHeightMultiple 1.15 on the system font (~1.19em natural),
    // i.e. a ~1.37em line pitch. RichEdit's own default is much looser.
    static int LinePitchTwips(float sizePx) { return (int)(sizePx * 1.37f * 15 + 0.5f); }

    void BeginPara(float indentPx, float hangPx, float beforePx, float afterPx,
                   float lineSizePx = 15)
    {
        char buf[160];
        sprintf_s(buf, "\\pard\\li%d\\fi%d\\sb%d\\sa%d\\sl-%d\\slmult0 ",
                  Twips(indentPx + hangPx), -Twips(hangPx), Twips(beforePx),
                  Twips(afterPx), LinePitchTwips(lineSizePx));
        out += buf;
    }

    void Run(const std::wstring& text, float sizePx, bool bold, bool italic, bool strike,
             bool mono, int color, bool codeBg)
    {
        char buf[96];
        sprintf_s(buf, "{\\f%d\\fs%d\\cf%d%s%s%s ", mono ? 1 : 0, HalfPt(sizePx), color,
                  bold ? "\\b" : "", italic ? "\\i" : "", strike ? "\\strike" : "");
        out += buf;
        if (codeBg) {
            sprintf_s(buf, "\\highlight%d ", ColCodeBg);
            out += buf;
        }
        Escape(out, text);
        out += "}";
    }

    void Link(const std::wstring& url, const std::wstring& text, float sizePx)
    {
        out += "{\\field{\\*\\fldinst{HYPERLINK \"";
        Escape(out, url);
        out += "\"}}{\\fldrslt{";
        char buf[64];
        sprintf_s(buf, "\\f0\\fs%d\\cf%d ", HalfPt(sizePx), ColLink);
        out += buf;
        Escape(out, text);
        out += "}}}";
    }

    struct InlineState {
        bool bold = false, italic = false, strike = false;
        int color = ColLabel;
        float size = 15;
    };

    void Inlines(const std::vector<md::Inline>& nodes, InlineState s)
    {
        for (const auto& node : nodes) {
            switch (node.type) {
            case md::InlineType::Text:
                Run(node.text, s.size, s.bold, s.italic, s.strike, false, s.color, false);
                break;
            case md::InlineType::SoftBreak:
                Run(L" ", s.size, false, false, false, false, s.color, false);
                break;
            case md::InlineType::HardBreak:
                out += "\\line ";
                break;
            case md::InlineType::Strong: {
                auto t = s; t.bold = true;
                Inlines(node.children, t);
                break;
            }
            case md::InlineType::Emphasis: {
                auto t = s; t.italic = true;
                Inlines(node.children, t);
                break;
            }
            case md::InlineType::Strike: {
                auto t = s; t.strike = true;
                Inlines(node.children, t);
                break;
            }
            case md::InlineType::Code:
                Run(node.text, 13, false, false, s.strike, true, s.color, true);
                break;
            case md::InlineType::Link:
                Link(node.dest, md::PlainText(node.children), s.size);
                break;
            case md::InlineType::Image: {
                std::wstring local;
                if (ResolveLocalImage(node.dest, local)) {
                    wchar_t token[32];
                    swprintf_s(token, L"⦾IMG%d⦾", imageCount++);
                    images.push_back(local);
                    Run(token, s.size, false, false, false, false, s.color, false);
                } else if (node.dest.rfind(L"http://", 0) == 0
                           || node.dest.rfind(L"https://", 0) == 0) {
                    Link(node.dest,
                         L"\U0001F5BC " + (node.text.empty() ? node.dest : node.text), s.size);
                } else {
                    Run(L"\U0001F5BC " + (node.text.empty() ? node.dest : node.text), s.size,
                        false, false, false, false, s.color, false);
                }
                break;
            }
            case md::InlineType::Html:
                Run(node.text, 13, false, false, false, true, ColSecondary, true);
                break;
            }
        }
    }

    void Blocks(const std::vector<md::Block>& blocks, float depth, bool secondary)
    {
        for (const auto& block : blocks) {
            int baseColor = secondary ? ColSecondary : ColLabel;
            switch (block.type) {
            case md::BlockType::Heading: {
                float headingSize = kHeadingSizesPx[std::clamp(block.level, 1, 6) - 1];
                BeginPara(depth * 24, 0, block.level <= 2 ? 14.0f : 10.0f, 8, headingSize);
                InlineState s;
                s.bold = true;
                s.size = headingSize;
                s.color = baseColor;
                Inlines(block.inlines, s);
                out += "\\par\n";
                break;
            }
            case md::BlockType::Paragraph: {
                BeginPara(depth * 24, 0, 0, 8);
                InlineState s;
                s.color = baseColor;
                Inlines(block.inlines, s);
                out += "\\par\n";
                break;
            }
            case md::BlockType::Code:
                BeginPara(depth * 24 + 12, 0, 0, 8, 13);
                Run(block.code, 13, false, false, false, true, baseColor, true);
                out += "\\par\n";
                break;
            case md::BlockType::Quote:
                Blocks(block.children, depth + 1, true);
                break;
            case md::BlockType::List:
                List(block, depth, secondary);
                break;
            case md::BlockType::Rule:
                BeginPara(0, 0, 8, 8);
                Run(std::wstring(12, L'─'), 15, false, false, false, false, ColSeparator,
                    false);
                out += "\\par\n";
                break;
            case md::BlockType::Html:
                BeginPara(depth * 24, 0, 0, 8, 13);
                Run(block.code, 13, false, false, false, true, ColSecondary, true);
                out += "\\par\n";
                break;
            case md::BlockType::Table:
                Table(block, secondary);
                break;
            }
        }
    }

    void List(const md::Block& list, float depth, bool secondary)
    {
        for (size_t index = 0; index < list.items.size(); index++) {
            const auto& item = list.items[index];
            std::wstring prefix;
            int prefixColor = ColSecondary;
            if (item.check == 1) { prefix = L"☑  "; prefixColor = ColAccent; }
            else if (item.check == 0) { prefix = L"☐  "; }
            else if (list.ordered) { prefix = std::to_wstring(list.start + (int)index) + L".  "; }
            else { prefix = L"•  "; }

            bool contentSecondary = secondary || item.check == 1;
            bool first = true;
            for (const auto& child : item.children) {
                if (child.type == md::BlockType::List) {
                    List(child, depth + 1, secondary);
                    first = false;
                    continue;
                }
                if (first
                    && (child.type == md::BlockType::Paragraph
                        || child.type == md::BlockType::Heading)) {
                    BeginPara(depth * 24 + 4, 22, 0, 4);
                    if (item.check >= 0) checkboxLines.push_back(item.sourceLine);
                    Run(prefix, 15, false, false, false, false, prefixColor, false);
                    InlineState s;
                    s.color = contentSecondary ? ColSecondary : ColLabel;
                    Inlines(child.inlines, s);
                    out += "\\par\n";
                    first = false;
                    continue;
                }
                if (first) {
                    BeginPara(depth * 24 + 4, 0, 0, 4);
                    if (item.check >= 0) checkboxLines.push_back(item.sourceLine);
                    Run(prefix, 15, false, false, false, false, prefixColor, false);
                    out += "\\par\n";
                    first = false;
                }
                std::vector<md::Block> one = { child };
                Blocks(one, depth + 1, contentSecondary);
            }
            if (first) {
                BeginPara(depth * 24 + 4, 0, 0, 4);
                if (item.check >= 0) checkboxLines.push_back(item.sourceLine);
                Run(prefix, 15, false, false, false, false, prefixColor, false);
                out += "\\par\n";
            }
        }
    }

    void Table(const md::Block& table, bool secondary)
    {
        // Rows are plain paragraphs with tab stops at column edges — the
        // borderless aligned grid, with a hairline of dashes under the
        // header. (Real RTF tables get gridlines painted by the control.)
        size_t columns = table.header.size();
        for (const auto& row : table.rows) columns = std::max(columns, row.size());
        if (columns == 0) return;

        std::vector<int> widths(columns, 0);
        HDC dc = GetDC(nullptr);
        auto measure = [&](const std::wstring& text, bool bold) {
            SelectObject(dc, bold ? g_app.bodyBoldFont : g_app.bodyFont);
            SIZE size{};
            GetTextExtentPoint32W(dc, text.c_str(), (int)text.size(), &size);
            return (int)(size.cx / g_app.dpi);
        };
        for (size_t c = 0; c < table.header.size(); c++) {
            widths[c] = std::max(widths[c], measure(md::PlainText(table.header[c]), true));
        }
        for (const auto& row : table.rows) {
            for (size_t c = 0; c < row.size() && c < columns; c++) {
                widths[c] = std::max(widths[c], measure(md::PlainText(row[c]), false));
            }
        }
        ReleaseDC(nullptr, dc);

        std::string tabs;
        int x = 0;
        int totalPx = 0;
        char buf[64];
        for (size_t c = 0; c < columns; c++) {
            totalPx += widths[c] + 24;
            x += Twips((float)widths[c] + 24);
            sprintf_s(buf, "\\tx%d", x);
            tabs += buf;
        }

        auto emitRow = [&](const std::vector<std::vector<md::Inline>>& cells, bool header) {
            out += "\\pard";
            out += tabs;
            char sl[48];
            sprintf_s(sl, "\\sa40\\sl-%d\\slmult0 ", LinePitchTwips(15));
            out += sl;
            for (size_t c = 0; c < columns; c++) {
                if (c > 0) out += "\\tab ";
                InlineState s;
                s.bold = header;
                s.color = secondary ? ColSecondary : ColLabel;
                if (c < cells.size()) Inlines(cells[c], s);
            }
            out += "\\par\n";
        };

        emitRow(table.header, true);
        int dashes = std::max(4, (totalPx - 24) / 8);
        out += "\\pard\\sa40 ";
        Run(std::wstring(dashes, L'─'), 15, false, false, false, false, ColSeparator, false);
        out += "\\par\n";
        for (const auto& row : table.rows) emitRow(row, false);
        out += "\\pard\\sa80\\par\n";
    }

    void Build(const std::vector<md::Block>& blocks)
    {
        Header();
        Blocks(blocks, 0, false);
        out += "}";
    }
};

} // namespace rtf

// MARK: - RichEdit plumbing

static DWORD CALLBACK StreamInProc(DWORD_PTR cookie, LPBYTE buffer, LONG cb, LONG* read)
{
    auto* data = (std::pair<const char*, size_t>*)cookie;
    size_t take = std::min((size_t)cb, data->second);
    memcpy(buffer, data->first, take);
    data->first += take;
    data->second -= take;
    *read = (LONG)take;
    return 0;
}

static ComPtr<ITextDocument> Tom()
{
    if (!g_app.tom) {
        ComPtr<IRichEditOle> ole;
        SendMessageW(g_app.richEdit, EM_GETOLEINTERFACE, 0, (LPARAM)ole.GetAddressOf());
        if (ole) ole.As(&g_app.tom);
    }
    return g_app.tom;
}

static void InsertImages(const std::vector<std::wstring>& paths)
{
    if (paths.empty()) return;
    ComPtr<IWICImagingFactory> wic;
    CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&wic));

    for (int i = 0; i < (int)paths.size(); i++) {
        wchar_t token[32];
        swprintf_s(token, L"⦾IMG%d⦾", i);
        FINDTEXTEXW find{};
        find.chrg = { 0, -1 };
        find.lpstrText = token;
        if ((LONG)SendMessageW(g_app.richEdit, EM_FINDTEXTEXW, FR_DOWN, (LPARAM)&find) < 0) {
            continue;
        }
        SendMessageW(g_app.richEdit, EM_SETSEL, find.chrgText.cpMin, find.chrgText.cpMax);

        UINT w = 0, h = 0;
        if (wic) {
            ComPtr<IWICBitmapDecoder> decoder;
            if (SUCCEEDED(wic->CreateDecoderFromFilename(paths[i].c_str(), nullptr, GENERIC_READ,
                                                         WICDecodeMetadataCacheOnDemand,
                                                         &decoder))) {
                ComPtr<IWICBitmapFrameDecode> frame;
                if (SUCCEEDED(decoder->GetFrame(0, &frame))) frame->GetSize(&w, &h);
            }
        }
        if (w == 0 || h == 0) {
            SendMessageW(g_app.richEdit, EM_REPLACESEL, FALSE, (LPARAM)L"");
            continue;
        }
        float drawW = std::min((float)w, 620.0f);
        float drawH = h * (drawW / w);

        ComPtr<IStream> stream;
        if (FAILED(SHCreateStreamOnFileEx(paths[i].c_str(), STGM_READ | STGM_SHARE_DENY_WRITE,
                                          FILE_ATTRIBUTE_NORMAL, FALSE, nullptr, &stream))) {
            SendMessageW(g_app.richEdit, EM_REPLACESEL, FALSE, (LPARAM)L"");
            continue;
        }
        RICHEDIT_IMAGE_PARAMETERS params{};
        params.xWidth = (LONG)(drawW * 2540 / 96); // HIMETRIC
        params.yHeight = (LONG)(drawH * 2540 / 96);
        params.Ascent = 0;
        params.Type = TA_BASELINE;
        params.pwszAlternateText = L"image";
        params.pIStream = stream.Get();
        if (SendMessageW(g_app.richEdit, EM_INSERTIMAGE, 0, (LPARAM)&params) != S_OK) {
            SendMessageW(g_app.richEdit, EM_REPLACESEL, FALSE, (LPARAM)L"");
            continue;
        }
        // The exact line spacing every paragraph carries (macOS-matching
        // text pitch) would clip the image to one text line; let the
        // image's paragraph size itself naturally instead.
        CHARRANGE imageAt{ find.chrgText.cpMin, find.chrgText.cpMin + 1 };
        SendMessageW(g_app.richEdit, EM_EXSETSEL, 0, (LPARAM)&imageAt);
        PARAFORMAT2 pf{};
        pf.cbSize = sizeof(pf);
        pf.dwMask = PFM_LINESPACING;
        pf.bLineSpacingRule = 0; // single: the line grows to fit its content
        SendMessageW(g_app.richEdit, EM_SETPARAFORMAT, 0, (LPARAM)&pf);
    }
}

/// Checkboxes are plain glyphs; their character positions are indexed after
/// streaming, in document order, and mapped back to source lines.
static void IndexCheckboxes(const std::vector<int>& lines)
{
    g_app.checkboxes.clear();
    LONG from = 0;
    for (int line : lines) {
        wchar_t unchecked[] = L"☐";
        wchar_t checked[] = L"☑";
        FINDTEXTEXW findA{};
        findA.chrg = { from, -1 };
        findA.lpstrText = unchecked;
        LONG a = (LONG)SendMessageW(g_app.richEdit, EM_FINDTEXTEXW, FR_DOWN, (LPARAM)&findA);
        FINDTEXTEXW findB{};
        findB.chrg = { from, -1 };
        findB.lpstrText = checked;
        LONG b = (LONG)SendMessageW(g_app.richEdit, EM_FINDTEXTEXW, FR_DOWN, (LPARAM)&findB);

        LONG pos;
        if (a < 0 && b < 0) break;
        if (a < 0) pos = b;
        else if (b < 0) pos = a;
        else pos = std::min(a, b);

        g_app.checkboxes.push_back({ pos, pos + 2, line });
        from = pos + 1;
    }
}

static void UpdateTitle()
{
    std::wstring title = g_app.doc.DisplayName();
    if (g_app.doc.dirty) title += L"*";
    title += L" - MrMark";
    SetWindowTextW(g_app.hwnd, title.c_str());
}

static void UpdateFindCounts();
static void InvalidateBars();

/// Viewer mode: parse + build RTF + stream into the control.
static void StreamDocument(bool preserveScroll)
{
    LONG firstVisible = preserveScroll
        ? (LONG)SendMessageW(g_app.richEdit, EM_GETFIRSTVISIBLELINE, 0, 0)
        : 0;

    auto blocks = md::Parse(g_app.doc.text);
    clockmarks::Mark(L"parse");

    rtf::Builder builder;
    builder.theme = &g_app.theme;
    builder.Build(blocks);
    clockmarks::Mark(L"rtf");

    g_app.internalChange = true;
    SendMessageW(g_app.richEdit, WM_SETREDRAW, FALSE, 0);
    SendMessageW(g_app.richEdit, EM_SETREADONLY, FALSE, 0);

    std::pair<const char*, size_t> cookie{ builder.out.data(), builder.out.size() };
    EDITSTREAM stream{ (DWORD_PTR)&cookie, 0, StreamInProc };
    SendMessageW(g_app.richEdit, EM_STREAMIN, SF_RTF, (LPARAM)&stream);

    InsertImages(builder.images);
    IndexCheckboxes(builder.checkboxLines);

    SendMessageW(g_app.richEdit, EM_SETSEL, 0, 0);
    SendMessageW(g_app.richEdit, EM_SETREADONLY, TRUE, 0);
    // Replacing the whole content resets the control's zoom; restore it so
    // the visual scale survives viewer/editor round trips.
    SendMessageW(g_app.richEdit, EM_SETZOOM, (WPARAM)(g_app.zoom * 100 + 0.5f), 100);
    if (firstVisible > 0) SendMessageW(g_app.richEdit, EM_LINESCROLL, 0, firstVisible);
    SendMessageW(g_app.richEdit, WM_SETREDRAW, TRUE, 0);
    InvalidateRect(g_app.richEdit, nullptr, TRUE);
    g_app.internalChange = false;

    UpdateTitle();
    if (g_app.findOpen) UpdateFindCounts();
}

// MARK: - Editor mode (hybrid styling on the same control)

static COLORREF ThemeLabel() { return g_app.theme.label; }

/// Restyles one source line: reset to body format, apply the line's style
/// spans, conceal delimiters unless revealed. Runs outside the undo history.
static void RestyleLine(ITextDocument* tom, int line, bool reveal)
{
    if (line < 0 || line >= (int)g_app.lines.size()) return;
    const std::wstring& text = g_app.lines[line];
    LONG start = (LONG)LineStartOffset(line);
    LONG end = start + (LONG)text.size();

    ComPtr<ITextRange> range;
    if (FAILED(tom->Range(start, end + 1, &range)) || !range) return; // +1: the line break
    ComPtr<ITextFont> font;
    if (FAILED(range->GetFont(&font)) || !font) return;

    md::LineStyle style = md::AnalyzeLine(text, g_app.codeMap[line] != 0);

    // Base reset. Sizes are in points; the control's zoom scales visually.
    {
        BSTR name = SysAllocString(style.isCode ? g_app.monoFamily.c_str() : L"Segoe UI");
        font->SetName(name);
        SysFreeString(name);
    }
    font->SetSize(style.isCode ? 13 * 0.75f : 15 * 0.75f);
    font->SetBold(tomFalse);
    font->SetItalic(tomFalse);
    font->SetStrikeThrough(tomFalse);
    font->SetHidden(tomFalse);
    font->SetForeColor(style.isQuote ? g_app.theme.secondary : ThemeLabel());
    font->SetBackColor(style.isCode ? g_app.theme.codeBg : tomAutoColor);

    if (style.headingLevel > 0) {
        font->SetSize(kHeadingSizesPx[std::clamp(style.headingLevel, 1, 6) - 1] * 0.75f);
        font->SetBold(tomTrue);
    }

    for (const auto& span : style.spans) {
        ComPtr<ITextRange> sub;
        if (FAILED(tom->Range(start + span.start, start + span.start + span.length, &sub))
            || !sub) {
            continue;
        }
        ComPtr<ITextFont> subFont;
        if (FAILED(sub->GetFont(&subFont)) || !subFont) continue;

        if (span.flags & md::kBold) subFont->SetBold(tomTrue);
        if (span.flags & md::kItalic) subFont->SetItalic(tomTrue);
        if (span.flags & md::kStrike) subFont->SetStrikeThrough(tomTrue);
        if (span.flags & md::kCodeSpan) {
            BSTR mono = SysAllocString(g_app.monoFamily.c_str());
            subFont->SetName(mono);
            SysFreeString(mono);
            subFont->SetSize(13 * 0.75f);
            subFont->SetBackColor(g_app.theme.codeBg);
        }
        if (span.flags & md::kLinkSpan) subFont->SetForeColor(g_app.theme.link);
        if ((span.flags & md::kConcealed) && !reveal) subFont->SetHidden(tomTrue);
    }
}

/// Styling passes must not pollute the user's undo history.
struct UndoSuspender {
    ITextDocument* tom;
    explicit UndoSuspender(ITextDocument* t) : tom(t)
    {
        if (tom) tom->Undo(tomSuspend, nullptr);
    }
    ~UndoSuspender()
    {
        if (tom) tom->Undo(tomResume, nullptr);
    }
};

static void RestyleRange(int from, int to, bool bulk)
{
    auto tom = Tom();
    if (!tom) return;
    g_app.internalChange = true;
    UndoSuspender guard(tom.Get());
    if (bulk) SendMessageW(g_app.richEdit, WM_SETREDRAW, FALSE, 0);
    for (int i = std::max(0, from); i <= to && i < (int)g_app.lines.size(); i++) {
        RestyleLine(tom.Get(), i, i == g_app.activeLine);
    }
    if (bulk) {
        SendMessageW(g_app.richEdit, WM_SETREDRAW, TRUE, 0);
        InvalidateRect(g_app.richEdit, nullptr, TRUE);
    }
    g_app.internalChange = false;
}

static void EditorTextChanged()
{
    std::wstring newText = GetControlText();
    const std::wstring& oldText = g_app.doc.text;
    if (newText == oldText) return;

    // Narrow the change to a line span (common prefix/suffix).
    size_t prefix = 0;
    size_t maxCommon = std::min(oldText.size(), newText.size());
    while (prefix < maxCommon && oldText[prefix] == newText[prefix]) prefix++;
    size_t suffix = 0;
    while (suffix < maxCommon - prefix
           && oldText[oldText.size() - 1 - suffix] == newText[newText.size() - 1 - suffix]) {
        suffix++;
    }
    auto countNewlines = [](const std::wstring& s, size_t end) {
        int n = 0;
        for (size_t i = 0; i < end && i < s.size(); i++) {
            if (s[i] == L'\n') n++;
        }
        return n;
    };
    int firstChanged = countNewlines(newText, prefix);
    int lastChanged = std::max(firstChanged, countNewlines(newText, newText.size() - suffix));
    int lastChangedOld = std::max(firstChanged, countNewlines(oldText, oldText.size() - suffix));

    auto oldLines = std::move(g_app.lines);
    g_app.doc.SetTextFromEditor(std::move(newText));
    g_app.lines = SplitLines(g_app.doc.text);
    g_app.codeMap = md::CodeLineMap(g_app.lines);

    // A fence line changes the meaning of everything below it.
    bool touchesFence = false;
    for (int i = firstChanged; i <= lastChanged && i < (int)g_app.lines.size(); i++) {
        if (md::IsFenceLine(g_app.lines[i])) { touchesFence = true; break; }
    }
    for (int i = firstChanged; !touchesFence && i <= lastChangedOld && i < (int)oldLines.size();
         i++) {
        if (md::IsFenceLine(oldLines[i])) touchesFence = true;
    }

    CHARRANGE sel{};
    SendMessageW(g_app.richEdit, EM_EXGETSEL, 0, (LPARAM)&sel);
    g_app.activeLine = LineOfOffset(sel.cpMin);

    int restyleTo = touchesFence ? (int)g_app.lines.size() - 1 : lastChanged;
    RestyleRange(firstChanged, restyleTo, restyleTo - firstChanged > 4);
    UpdateTitle();
}

static void EditorSelectionChanged()
{
    CHARRANGE sel{};
    SendMessageW(g_app.richEdit, EM_EXGETSEL, 0, (LPARAM)&sel);
    int caretLine = LineOfOffset(sel.cpMin);
    if (caretLine == g_app.activeLine) return;

    // Typora behavior: re-conceal the paragraph the caret left and reveal
    // the source of the one it entered.
    int previous = g_app.activeLine;
    g_app.activeLine = caretLine;
    RestyleRange(previous, previous, false);
    RestyleRange(caretLine, caretLine, false);
}

/// Formatting toolbar actions go through the control's editing path
/// (EM_REPLACESEL), so they are one undo step each.
static void ApplyFormatEdit(const md::FormatEdit& edit)
{
    std::wstring replacement = edit.replacement;
    for (auto& c : replacement) {
        if (c == L'\n') c = L'\r';
    }
    SendMessageW(g_app.richEdit, EM_SETSEL, (WPARAM)edit.start,
                 (LPARAM)(edit.start + edit.length));
    SendMessageW(g_app.richEdit, EM_REPLACESEL, TRUE, (LPARAM)replacement.c_str());
    // EN_CHANGE has synced the mirror and restyled; place the selection.
    SendMessageW(g_app.richEdit, EM_SETSEL, (WPARAM)edit.selStart,
                 (LPARAM)(edit.selStart + edit.selLength));
    SetFocus(g_app.richEdit);
}

static void RunFormatAction(int command)
{
    if (g_app.mode != Mode::Editor) return;
    CHARRANGE sel{};
    SendMessageW(g_app.richEdit, EM_EXGETSEL, 0, (LPARAM)&sel);
    size_t start = (size_t)sel.cpMin;
    size_t length = (size_t)(sel.cpMax - sel.cpMin);
    const std::wstring& text = g_app.doc.text;

    md::FormatEdit edit;
    switch (command) {
    case IDM_BOLD: edit = md::ToggleInlineWrap(text, start, length, L"**"); break;
    case IDM_ITALIC: edit = md::ToggleInlineWrap(text, start, length, L"*"); break;
    case IDM_H1: edit = md::SetHeading(text, start, length, 1); break;
    case IDM_H2: edit = md::SetHeading(text, start, length, 2); break;
    case IDM_H3: edit = md::SetHeading(text, start, length, 3); break;
    case IDM_BULLET: edit = md::ToggleBulletList(text, start, length); break;
    case IDM_NUMBERED: edit = md::ToggleNumberedList(text, start, length); break;
    case IDM_CHECKLIST: edit = md::ToggleChecklist(text, start, length); break;
    case IDM_LINK: edit = md::InsertLink(text, start, length); break;
    case IDM_IMAGE: edit = md::InsertImage(text, start, length); break;
    case IDM_CODEBLOCK: edit = md::InsertCodeBlock(text, start, length); break;
    default: return;
    }
    ApplyFormatEdit(edit);
}

// MARK: - Mode switching

static void LayoutBars();

static void EnterEditorMode()
{
    if (g_app.mode == Mode::Editor) return;
    g_app.mode = Mode::Editor;
    g_app.doc.ClearHistory(); // the control owns undo while editing

    std::wstring source = g_app.doc.text;
    for (auto& c : source) {
        if (c == L'\n') c = L'\r';
    }

    g_app.internalChange = true;
    SendMessageW(g_app.richEdit, WM_SETREDRAW, FALSE, 0);
    SendMessageW(g_app.richEdit, EM_SETREADONLY, FALSE, 0);
    SetWindowTextW(g_app.richEdit, source.c_str());
    g_app.internalChange = false;

    g_app.lines = SplitLines(g_app.doc.text);
    g_app.codeMap = md::CodeLineMap(g_app.lines);
    g_app.activeLine = 0;
    RestyleRange(0, (int)g_app.lines.size() - 1, false);

    SendMessageW(g_app.richEdit, EM_SETZOOM, (WPARAM)(g_app.zoom * 100 + 0.5f), 100);
    SendMessageW(g_app.richEdit, EM_SETSEL, 0, 0);
    SendMessageW(g_app.richEdit, EM_EMPTYUNDOBUFFER, 0, 0);
    SendMessageW(g_app.richEdit, WM_SETREDRAW, TRUE, 0);
    InvalidateRect(g_app.richEdit, nullptr, TRUE);

    LayoutBars();
    InvalidateBars();
    UpdateTitle();
    SetFocus(g_app.richEdit);
}

static void EnterViewerMode()
{
    if (g_app.mode == Mode::Viewer) return;
    g_app.mode = Mode::Viewer;
    StreamDocument(false);
    LayoutBars();
    InvalidateBars();
    SetFocus(g_app.richEdit);
}

static void ToggleMode()
{
    if (g_app.mode == Mode::Viewer) EnterEditorMode();
    else EnterViewerMode();
}

// MARK: - Standard OS flows (prompts, recents, placement, default app)

static bool SaveAsInteractive();

static bool SaveInteractive()
{
    if (g_app.doc.path.empty()) return SaveAsInteractive();
    if (g_app.doc.DiskChanged()) {
        int chosen = 0;
        TaskDialog(g_app.hwnd, nullptr, L"MrMark",
                   L"This file has been changed by another application.",
                   L"Saving will overwrite those changes.",
                   TDCBF_YES_BUTTON | TDCBF_CANCEL_BUTTON, TD_WARNING_ICON, &chosen);
        if (chosen != IDYES) return false;
    }
    if (!g_app.doc.Save()) {
        TaskDialog(g_app.hwnd, nullptr, L"MrMark", L"Couldn't save the document.", nullptr,
                   TDCBF_OK_BUTTON, TD_ERROR_ICON, nullptr);
        return false;
    }
    UpdateTitle();
    return true;
}

static void NoteRecent(const std::wstring& path);

static bool SaveAsInteractive()
{
    wchar_t buffer[MAX_PATH];
    wcscpy_s(buffer, g_app.doc.DisplayName().c_str());
    OPENFILENAMEW ofn{ sizeof(ofn) };
    ofn.hwndOwner = g_app.hwnd;
    ofn.lpstrFilter = L"Markdown (*.md)\0*.md\0All files\0*.*\0";
    ofn.lpstrFile = buffer;
    ofn.nMaxFile = MAX_PATH;
    ofn.lpstrDefExt = L"md";
    ofn.Flags = OFN_OVERWRITEPROMPT;
    if (!GetSaveFileNameW(&ofn)) return false;
    if (!g_app.doc.SaveAsPath(buffer)) {
        TaskDialog(g_app.hwnd, nullptr, L"MrMark", L"Couldn't save the document.", nullptr,
                   TDCBF_OK_BUTTON, TD_ERROR_ICON, nullptr);
        return false;
    }
    g_baseDir = g_app.doc.path.substr(0, g_app.doc.path.find_last_of(L'\\'));
    SHAddToRecentDocs(SHARD_PATHW, g_app.doc.path.c_str());
    NoteRecent(g_app.doc.path);
    UpdateTitle();
    return true;
}

/// The classic three-way close prompt: 101 = Save, 102 = Don't Save.
static int ConfirmClose()
{
    TASKDIALOGCONFIG config{ sizeof(config) };
    config.hwndParent = g_app.hwnd;
    config.pszWindowTitle = L"MrMark";
    config.pszMainInstruction = L"Do you want to save the changes you made?";
    config.pszContent = L"Your changes will be lost if you don't save them.";
    TASKDIALOG_BUTTON buttons[] = { { 101, L"Save" }, { 102, L"Don't Save" } };
    config.pButtons = buttons;
    config.cButtons = 2;
    config.dwCommonButtons = TDCBF_CANCEL_BUTTON;
    config.nDefaultButton = 101;
    int chosen = IDCANCEL;
    TaskDialogIndirect(&config, &chosen, nullptr, nullptr);
    return chosen;
}

static void OpenUrl(const std::wstring& url)
{
    if (url.rfind(L"http://", 0) == 0 || url.rfind(L"https://", 0) == 0
        || url.rfind(L"mailto:", 0) == 0) {
        ShellExecuteW(nullptr, L"open", url.c_str(), nullptr, nullptr, SW_SHOWNORMAL);
    }
}

// One file = one window; each window is its own process. Opening an
// already-open file — a second launch, a drop, Open Recent — activates its
// window instead (WM_COPYDATA query). The caller does the focusing: it is
// the foreground process, so SetForegroundWindow is allowed to succeed.

struct ActivateQuery {
    const wchar_t* path;
    HWND found = nullptr;
};

static BOOL CALLBACK ActivateEnumProc(HWND hwnd, LPARAM lp)
{
    wchar_t className[32];
    if (!GetClassNameW(hwnd, className, 32) || wcscmp(className, L"MrMark") != 0) return TRUE;
    if (hwnd == g_app.hwnd) return TRUE;
    auto* query = (ActivateQuery*)lp;
    COPYDATASTRUCT data{};
    data.dwData = kActivateMagic;
    data.lpData = (void*)query->path;
    data.cbData = (DWORD)((wcslen(query->path) + 1) * sizeof(wchar_t));
    DWORD_PTR result = 0;
    if (SendMessageTimeoutW(hwnd, WM_COPYDATA, 0, (LPARAM)&data, SMTO_ABORTIFHUNG, 500, &result)
        && result) {
        query->found = hwnd;
        return FALSE;
    }
    return TRUE;
}

static bool ActivateExistingWindow(const std::wstring& fullPath)
{
    ActivateQuery query{ fullPath.c_str() };
    EnumWindows(ActivateEnumProc, (LPARAM)&query);
    if (!query.found) return false;
    if (IsIconic(query.found)) ShowWindow(query.found, SW_RESTORE);
    SetForegroundWindow(query.found);
    return true;
}

static void SpawnWindow(const std::wstring& args)
{
    wchar_t self[MAX_PATH];
    GetModuleFileNameW(nullptr, self, MAX_PATH);
    ShellExecuteW(nullptr, L"open", self, args.c_str(), nullptr, SW_SHOWNORMAL);
}

static void OpenPath(const std::wstring& path)
{
    wchar_t full[MAX_PATH];
    GetFullPathNameW(path.c_str(), MAX_PATH, full, nullptr);
    if (!g_app.doc.path.empty() && _wcsicmp(full, g_app.doc.path.c_str()) == 0) return;
    if (ActivateExistingWindow(full)) return; // already open elsewhere

    // A pristine untitled window takes the file itself.
    if (g_app.doc.path.empty() && !g_app.doc.dirty) {
        if (g_app.doc.Load(path.c_str())) {
            g_baseDir = g_app.doc.path.substr(0, g_app.doc.path.find_last_of(L'\\'));
            SHAddToRecentDocs(SHARD_PATHW, g_app.doc.path.c_str());
            NoteRecent(g_app.doc.path);
            g_app.mode = Mode::Editor; // force the switch below
            EnterViewerMode();
        }
        return;
    }
    SpawnWindow(L"\"" + path + L"\"");
}

static void OpenInteractive()
{
    wchar_t buffer[MAX_PATH] = L"";
    OPENFILENAMEW ofn{ sizeof(ofn) };
    ofn.hwndOwner = g_app.hwnd;
    ofn.lpstrFilter =
        L"Markdown (*.md;*.markdown;*.mdown;*.mkd)\0*.md;*.markdown;*.mdown;*.mkd\0All files\0*.*\0";
    ofn.lpstrFile = buffer;
    ofn.nMaxFile = MAX_PATH;
    ofn.Flags = OFN_FILEMUSTEXIST;
    if (GetOpenFileNameW(&ofn)) OpenPath(buffer);
}

// Recent files: shell recents (SHAddToRecentDocs) power the jump list; the
// File menu keeps its own small MRU in the registry.

static std::vector<std::wstring> ReadRecents()
{
    std::vector<std::wstring> out;
    HKEY key;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, L"Software\\MrMark\\Recent", 0, KEY_READ, &key)
        != ERROR_SUCCESS) {
        return out;
    }
    for (int i = 0; i < 10; i++) {
        wchar_t name[4];
        swprintf_s(name, L"%d", i);
        wchar_t value[MAX_PATH];
        DWORD size = sizeof(value);
        if (RegGetValueW(key, nullptr, name, RRF_RT_REG_SZ, nullptr, value, &size)
            == ERROR_SUCCESS) {
            if (GetFileAttributesW(value) != INVALID_FILE_ATTRIBUTES) out.push_back(value);
        }
    }
    RegCloseKey(key);
    return out;
}

static void NoteRecent(const std::wstring& path)
{
    auto recents = ReadRecents();
    recents.erase(std::remove_if(recents.begin(), recents.end(),
                                 [&](const std::wstring& p) {
                                     return _wcsicmp(p.c_str(), path.c_str()) == 0;
                                 }),
                  recents.end());
    recents.insert(recents.begin(), path);
    if (recents.size() > 10) recents.resize(10);

    HKEY key;
    if (RegCreateKeyExW(HKEY_CURRENT_USER, L"Software\\MrMark\\Recent", 0, nullptr, 0, KEY_WRITE,
                        nullptr, &key, nullptr) != ERROR_SUCCESS) {
        return;
    }
    for (int i = 0; i < 10; i++) {
        wchar_t name[4];
        swprintf_s(name, L"%d", i);
        if (i < (int)recents.size()) {
            RegSetValueExW(key, name, 0, REG_SZ, (const BYTE*)recents[i].c_str(),
                           (DWORD)((recents[i].size() + 1) * sizeof(wchar_t)));
        } else {
            RegDeleteValueW(key, name);
        }
    }
    RegCloseKey(key);
}

// Window placement, remembered the standard way.

static void SavePlacement()
{
    WINDOWPLACEMENT wp{ sizeof(wp) };
    if (!GetWindowPlacement(g_app.hwnd, &wp)) return;
    HKEY key;
    if (RegCreateKeyExW(HKEY_CURRENT_USER, L"Software\\MrMark", 0, nullptr, 0, KEY_WRITE,
                        nullptr, &key, nullptr) == ERROR_SUCCESS) {
        RegSetValueExW(key, L"Placement", 0, REG_BINARY, (BYTE*)&wp, sizeof(wp));
        RegCloseKey(key);
    }
}

static bool RestorePlacement(WINDOWPLACEMENT& wp)
{
    DWORD size = sizeof(wp);
    return RegGetValueW(HKEY_CURRENT_USER, L"Software\\MrMark", L"Placement", RRF_RT_REG_BINARY,
                        nullptr, &wp, &size) == ERROR_SUCCESS
        && wp.length == sizeof(wp);
}

// Becoming the default app for Markdown files: never silently, ask exactly
// once, and only after a real file was opened. Windows requires the user to
// confirm in its own Settings UI; MrMark registers per-user and sends them
// there — the OS-sanctioned flow.

static bool IsDefaultMarkdownApp()
{
    wchar_t value[64];
    DWORD size = sizeof(value);
    return RegGetValueW(HKEY_CURRENT_USER,
                        L"Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\FileExts\\.md\\UserChoice",
                        L"ProgId", RRF_RT_REG_SZ, nullptr, value, &size) == ERROR_SUCCESS
        && wcscmp(value, L"MrMark.md") == 0;
}

static void RegisterProgId()
{
    wchar_t exe[MAX_PATH];
    GetModuleFileNameW(nullptr, exe, MAX_PATH);

    HKEY progId;
    if (RegCreateKeyExW(HKEY_CURRENT_USER, L"Software\\Classes\\MrMark.md", 0, nullptr, 0,
                        KEY_WRITE, nullptr, &progId, nullptr) == ERROR_SUCCESS) {
        const wchar_t* name = L"Markdown Document";
        RegSetValueExW(progId, nullptr, 0, REG_SZ, (const BYTE*)name,
                       (DWORD)((wcslen(name) + 1) * sizeof(wchar_t)));
        HKEY sub;
        std::wstring icon = L"\"" + std::wstring(exe) + L"\",1"; // the document icon
        if (RegCreateKeyExW(progId, L"DefaultIcon", 0, nullptr, 0, KEY_WRITE, nullptr, &sub,
                            nullptr) == ERROR_SUCCESS) {
            RegSetValueExW(sub, nullptr, 0, REG_SZ, (const BYTE*)icon.c_str(),
                           (DWORD)((icon.size() + 1) * sizeof(wchar_t)));
            RegCloseKey(sub);
        }
        std::wstring command = L"\"" + std::wstring(exe) + L"\" \"%1\"";
        if (RegCreateKeyExW(progId, L"shell\\open\\command", 0, nullptr, 0, KEY_WRITE, nullptr,
                            &sub, nullptr) == ERROR_SUCCESS) {
            RegSetValueExW(sub, nullptr, 0, REG_SZ, (const BYTE*)command.c_str(),
                           (DWORD)((command.size() + 1) * sizeof(wchar_t)));
            RegCloseKey(sub);
        }
        RegCloseKey(progId);
    }

    for (const wchar_t* ext : { L".md", L".markdown", L".mdown", L".mkd" }) {
        std::wstring keyPath = L"Software\\Classes\\" + std::wstring(ext) + L"\\OpenWithProgids";
        HKEY key;
        if (RegCreateKeyExW(HKEY_CURRENT_USER, keyPath.c_str(), 0, nullptr, 0, KEY_WRITE,
                            nullptr, &key, nullptr) == ERROR_SUCCESS) {
            RegSetValueExW(key, L"MrMark.md", 0, REG_NONE, nullptr, 0);
            RegCloseKey(key);
        }
    }
}

static void MakeDefaultInteractive(bool interactive)
{
    if (interactive && IsDefaultMarkdownApp()) {
        TaskDialog(g_app.hwnd, nullptr, L"MrMark",
                   L"MrMark is already the default app for Markdown files.", nullptr,
                   TDCBF_OK_BUTTON, TD_INFORMATION_ICON, nullptr);
        return;
    }
    RegisterProgId();
    ShellExecuteW(nullptr, L"open", L"ms-settings:defaultapps", nullptr, nullptr, SW_SHOWNORMAL);
    TaskDialog(g_app.hwnd, nullptr, L"One more step",
               L"MrMark is registered.",
               L"In the Settings page that just opened, search for \".md\" (or \"MrMark\") "
               L"and choose MrMark as the default.",
               TDCBF_OK_BUTTON, TD_INFORMATION_ICON, nullptr);
}

static void OfferDefaultIfAppropriate()
{
    if (g_app.doc.path.empty()) return; // no user intent yet
    DWORD asked = 0, size = sizeof(asked);
    RegGetValueW(HKEY_CURRENT_USER, L"Software\\MrMark", L"AskedDefault", RRF_RT_REG_DWORD,
                 nullptr, &asked, &size);
    if (asked || IsDefaultMarkdownApp()) return;

    // Whatever the answer, never ask again.
    HKEY key;
    if (RegCreateKeyExW(HKEY_CURRENT_USER, L"Software\\MrMark", 0, nullptr, 0, KEY_WRITE,
                        nullptr, &key, nullptr) == ERROR_SUCCESS) {
        DWORD one = 1;
        RegSetValueExW(key, L"AskedDefault", 0, REG_DWORD, (BYTE*)&one, sizeof(one));
        RegCloseKey(key);
    }

    int chosen = 0;
    TaskDialog(g_app.hwnd, nullptr, L"Use MrMark for Markdown files?",
               L"Make MrMark the default application for opening .md files?",
               L"Windows will show its standard picker so you can confirm. "
               L"You can change this anytime in Settings, or later via the Help menu.",
               TDCBF_YES_BUTTON | TDCBF_NO_BUTTON, TD_INFORMATION_ICON, &chosen);
    if (chosen == IDYES) MakeDefaultInteractive(false);
}

// MARK: - Zoom (the control's own)

static void SetZoom(float zoom)
{
    zoom = std::clamp(zoom, 0.5f, 3.0f);
    g_app.zoom = zoom;
    SendMessageW(g_app.richEdit, EM_SETZOOM, (WPARAM)(zoom * 100 + 0.5f), 100);
    SendMessageW(g_app.zoomSlider, TBM_SETPOS, TRUE, (LPARAM)(zoom * 100 + 0.5f));
    InvalidateBars();
}

// MARK: - Find (Ctrl+F): the OS-standard select-and-scroll model

/// A hyperlink field stores its URL as hidden text, and EM_FINDTEXTEX
/// matches inside it. Matches that touch hidden text are invisible junk.
static bool RangeIsHidden(LONG cpMin, LONG cpMax)
{
    auto tom = Tom();
    if (!tom) return false;
    ComPtr<ITextRange> range;
    if (FAILED(tom->Range(cpMin, cpMax, &range)) || !range) return false;
    ComPtr<ITextFont> font;
    if (FAILED(range->GetFont(&font)) || !font) return false;
    long hidden = tomFalse;
    font->GetHidden(&hidden);
    return hidden != tomFalse;
}

static std::vector<CHARRANGE> CollectMatches()
{
    std::vector<CHARRANGE> matches;
    if (g_app.findQuery.empty()) return matches;
    FINDTEXTEXW find{};
    find.chrg = { 0, -1 };
    find.lpstrText = g_app.findQuery.c_str();
    while ((LONG)SendMessageW(g_app.richEdit, EM_FINDTEXTEXW, FR_DOWN, (LPARAM)&find) >= 0) {
        if (!RangeIsHidden(find.chrgText.cpMin, find.chrgText.cpMax)) {
            matches.push_back(find.chrgText);
        }
        find.chrg.cpMin = find.chrgText.cpMin + 1;
        if (matches.size() >= 5000) break;
    }
    return matches;
}

static void UpdateFindCounts()
{
    auto matches = CollectMatches();
    g_app.findTotal = (int)matches.size();
    g_app.findIndex = 0;
    CHARRANGE sel{};
    SendMessageW(g_app.richEdit, EM_EXGETSEL, 0, (LPARAM)&sel);
    for (size_t i = 0; i < matches.size(); i++) {
        if (sel.cpMin <= matches[i].cpMin
            && matches[i].cpMin < std::max(sel.cpMax, sel.cpMin + 1)) {
            g_app.findIndex = (int)i + 1;
            break;
        }
    }
}

static void FindStep(int direction, bool fromCaret)
{
    auto matches = CollectMatches();
    g_app.findTotal = (int)matches.size();
    g_app.findIndex = 0;

    if (!matches.empty()) {
        CHARRANGE sel{};
        SendMessageW(g_app.richEdit, EM_EXGETSEL, 0, (LPARAM)&sel);

        int index;
        if (direction > 0) {
            LONG from = fromCaret ? sel.cpMax : sel.cpMin;
            index = 0;
            for (int i = 0; i < (int)matches.size(); i++) {
                if (matches[i].cpMin >= from) { index = i; break; }
            }
        } else {
            index = (int)matches.size() - 1;
            for (int i = (int)matches.size() - 1; i >= 0; i--) {
                if (matches[i].cpMin < sel.cpMin) { index = i; break; }
            }
        }

        CHARRANGE target = matches[index];
        SendMessageW(g_app.richEdit, EM_EXSETSEL, 0, (LPARAM)&target);
        SendMessageW(g_app.richEdit, EM_SCROLLCARET, 0, 0);
        g_app.findIndex = index + 1;
    }
    InvalidateBars();
}

static void OpenFind()
{
    g_app.findOpen = true;
    LayoutBars();
    ShowWindow(g_app.findEdit, SW_SHOW);
    SetFocus(g_app.findEdit);
    SendMessageW(g_app.findEdit, EM_SETSEL, 0, -1);
    UpdateFindCounts();
    InvalidateRect(g_app.hwnd, nullptr, TRUE);
}

static void CloseFind()
{
    g_app.findOpen = false;
    ShowWindow(g_app.findEdit, SW_HIDE);
    LayoutBars();
    SetFocus(g_app.richEdit);
    InvalidateRect(g_app.hwnd, nullptr, TRUE);
}

// MARK: - Bars (chrome above the document)

static const BarButton kEditorButtons[] = {
    { IDM_SAVE, L"", L"Save (Ctrl+S)" },
    { 0 },
    { IDM_UNDO, L"", L"Undo (Ctrl+Z)" },
    { IDM_REDO, L"", L"Redo (Ctrl+Y)" },
    { 0 },
    { IDM_BOLD, nullptr, L"B" },
    { IDM_ITALIC, nullptr, L"I" },
    { IDM_H1, nullptr, L"H1" },
    { IDM_H2, nullptr, L"H2" },
    { IDM_H3, nullptr, L"H3" },
    { 0 },
    { IDM_BULLET, L"", L"Bullet list" },
    { IDM_NUMBERED, nullptr, L"1." },
    { IDM_CHECKLIST, L"", L"Checklist" },
    { 0 },
    { IDM_LINK, L"", L"Insert link (Ctrl+K)" },
    { IDM_IMAGE, L"", L"Insert image" },
    { IDM_CODEBLOCK, nullptr, L"{ }" },
};

static const wchar_t* ButtonTip(int id)
{
    switch (id) {
    case IDM_SAVE: return L"Save (Ctrl+S)";
    case IDM_UNDO: return L"Undo (Ctrl+Z)";
    case IDM_REDO: return L"Redo (Ctrl+Y)";
    case IDM_BOLD: return L"Bold (Ctrl+B)";
    case IDM_ITALIC: return L"Italic (Ctrl+I)";
    case IDM_H1: return L"Heading 1 (Ctrl+1)";
    case IDM_H2: return L"Heading 2 (Ctrl+2)";
    case IDM_H3: return L"Heading 3 (Ctrl+3)";
    case IDM_BULLET: return L"Bullet list";
    case IDM_NUMBERED: return L"Numbered list";
    case IDM_CHECKLIST: return L"Checklist";
    case IDM_LINK: return L"Insert link (Ctrl+K)";
    case IDM_IMAGE: return L"Insert image";
    case IDM_CODEBLOCK: return L"Code block";
    case IDM_TOGGLEMODE:
        return g_app.mode == Mode::Editor ? L"Back to the reading view (Ctrl+E)"
                                          : L"Edit this document (Ctrl+E)";
    case IDM_ABOUT: return L"About MrMark";
    default: return L"";
    }
}

static void AddTool(int id, const RECT& rect)
{
    TOOLINFOW tool{ sizeof(tool) };
    tool.uFlags = TTF_SUBCLASS;
    tool.hwnd = g_app.hwnd;
    tool.uId = id;
    tool.rect = rect;
    tool.lpszText = (LPWSTR)ButtonTip(id);
    SendMessageW(g_app.tooltip, TTM_ADDTOOLW, 0, (LPARAM)&tool);
}

static void LayoutBars()
{
    RECT rc;
    GetClientRect(g_app.hwnd, &rc);
    float d = g_app.dpi;
    int barH = (int)(kTopBar * d);

    // Clear tooltips; they are re-added below with fresh rects.
    if (g_app.tooltip) {
        while (SendMessageW(g_app.tooltip, TTM_GETTOOLCOUNT, 0, 0) > 0) {
            TOOLINFOW tool{ sizeof(tool) };
            if (!SendMessageW(g_app.tooltip, TTM_ENUMTOOLSW, 0, (LPARAM)&tool)) break;
            SendMessageW(g_app.tooltip, TTM_DELTOOLW, 0, (LPARAM)&tool);
        }
    }

    // Zoom cluster: [-] slider [+] 100%
    int x = (int)(10 * d);
    int glyphSize = (int)(22 * d);
    int top = (barH - glyphSize) / 2;
    g_app.zoomMinus = { x, top, x + glyphSize, top + glyphSize };
    x += glyphSize + (int)(2 * d);
    int sliderW = (int)(96 * d);
    int sliderH = (int)(22 * d);
    MoveWindow(g_app.zoomSlider, x, (barH - sliderH) / 2, sliderW, sliderH, TRUE);
    x += sliderW + (int)(2 * d);
    g_app.zoomPlus = { x, top, x + glyphSize, top + glyphSize };
    x += glyphSize + (int)(4 * d);
    g_app.zoomLabel = { x, 0, x + (int)(44 * d), barH };
    x = g_app.zoomLabel.right + (int)(10 * d);

    // Editor tool buttons.
    g_app.buttons.clear();
    if (g_app.mode == Mode::Editor) {
        int buttonSize = (int)(28 * d);
        int buttonTop = (barH - buttonSize) / 2;
        for (const auto& religion : kEditorButtons) {
            BarButton button = religion;
            if (button.id == 0) {
                x += (int)(8 * d);
                continue;
            }
            int width = button.glyph ? buttonSize : (int)(30 * d);
            button.rect = { x, buttonTop, x + width, buttonTop + buttonSize };
            AddTool(button.id, button.rect);
            g_app.buttons.push_back(button);
            x += width + (int)(2 * d);
        }
    }

    // Right side: mode toggle + about.
    int rightSize = (int)(30 * d);
    int rightTop = (barH - rightSize) / 2;
    g_app.aboutButton.rect = { rc.right - rightSize - (int)(8 * d), rightTop,
                               rc.right - (int)(8 * d), rightTop + rightSize };
    g_app.toggleButton.rect = { g_app.aboutButton.rect.left - rightSize - (int)(4 * d), rightTop,
                                g_app.aboutButton.rect.left - (int)(4 * d),
                                rightTop + rightSize };
    AddTool(IDM_TOGGLEMODE, g_app.toggleButton.rect);
    AddTool(IDM_ABOUT, g_app.aboutButton.rect);

    // Find bar buttons.
    if (g_app.findOpen) {
        int findTop = barH;
        int findH = (int)(kFindBar * d);
        MoveWindow(g_app.findEdit, (int)(12 * d), findTop + (int)(6 * d), (int)(240 * d),
                   findH - (int)(12 * d), TRUE);
        int size = (int)(26 * d);
        int y = findTop + (findH - size) / 2;
        g_app.findPrev = { (int)(336 * d), y, (int)(336 * d) + size, y + size };
        g_app.findNext = { g_app.findPrev.right + (int)(2 * d), y,
                           g_app.findPrev.right + (int)(2 * d) + size, y + size };
        g_app.findClose = { g_app.findNext.right + (int)(10 * d), y,
                            g_app.findNext.right + (int)(10 * d) + size, y + size };
    }

    // The document fills the rest.
    int contentTop = g_app.ContentTop();
    MoveWindow(g_app.richEdit, 0, contentTop, rc.right, rc.bottom - contentTop, TRUE);
}

static void InvalidateBars()
{
    RECT rc;
    GetClientRect(g_app.hwnd, &rc);
    rc.bottom = g_app.ContentTop();
    InvalidateRect(g_app.hwnd, &rc, FALSE);
}

static void DrawBars(HDC dc)
{
    RECT rc;
    GetClientRect(g_app.hwnd, &rc);
    float d = g_app.dpi;
    int barH = (int)(kTopBar * d);

    HBRUSH sepBrush = CreateSolidBrush(g_app.theme.separator);
    RECT bar{ 0, 0, rc.right, barH };
    FillRect(dc, &bar, g_app.barBrush);
    RECT sep{ 0, barH - 1, rc.right, barH };
    FillRect(dc, &sep, sepBrush);

    SetBkMode(dc, TRANSPARENT);

    // Zoom cluster.
    SelectObject(dc, g_app.uiFont);
    SetTextColor(dc, g_app.theme.label);
    DrawTextW(dc, L"−", 1, &g_app.zoomMinus, DT_SINGLELINE | DT_VCENTER | DT_CENTER);
    DrawTextW(dc, L"+", 1, &g_app.zoomPlus, DT_SINGLELINE | DT_VCENTER | DT_CENTER);
    SetTextColor(dc, g_app.theme.secondary);
    wchar_t zoomText[16];
    swprintf_s(zoomText, L"%d%%", (int)(g_app.zoom * 100 + 0.5f));
    DrawTextW(dc, zoomText, -1, &g_app.zoomLabel, DT_SINGLELINE | DT_VCENTER | DT_LEFT);

    // Editor tool buttons.
    for (const auto& button : g_app.buttons) {
        SetTextColor(dc, g_app.theme.label);
        if (button.glyph) {
            SelectObject(dc, g_app.iconFont);
            DrawTextW(dc, button.glyph, 1, (RECT*)&button.rect,
                      DT_SINGLELINE | DT_VCENTER | DT_CENTER);
        } else {
            SelectObject(dc, button.id == IDM_ITALIC ? g_app.uiItalicFont : g_app.uiBoldFont);
            DrawTextW(dc, button.label, -1, (RECT*)&button.rect,
                      DT_SINGLELINE | DT_VCENTER | DT_CENTER);
        }
    }

    // Right side.
    SelectObject(dc, g_app.iconFont);
    SetTextColor(dc, g_app.theme.label);
    DrawTextW(dc, g_app.mode == Mode::Editor ? L"" : L"", 1,
              &g_app.toggleButton.rect, DT_SINGLELINE | DT_VCENTER | DT_CENTER);
    DrawTextW(dc, L"", 1, &g_app.aboutButton.rect, DT_SINGLELINE | DT_VCENTER | DT_CENTER);

    // Find bar.
    if (g_app.findOpen) {
        int findTop = barH;
        int findH = (int)(kFindBar * d);
        RECT findBar{ 0, findTop, rc.right, findTop + findH };
        FillRect(dc, &findBar, g_app.barBrush);
        RECT findSep{ 0, findTop + findH - 1, rc.right, findTop + findH };
        FillRect(dc, &findSep, sepBrush);

        SelectObject(dc, g_app.uiFont);
        SetTextColor(dc, g_app.theme.secondary);
        wchar_t count[48];
        if (g_app.findQuery.empty()) count[0] = 0;
        else if (g_app.findTotal == 0) wcscpy_s(count, L"0");
        else if (g_app.findIndex > 0) {
            swprintf_s(count, L"%d/%d", g_app.findIndex, g_app.findTotal);
        } else {
            swprintf_s(count, L"%d", g_app.findTotal);
        }
        RECT countRect{ (int)(262 * d), findTop, (int)(330 * d), findTop + findH };
        DrawTextW(dc, count, -1, &countRect, DT_SINGLELINE | DT_VCENTER | DT_LEFT);

        SelectObject(dc, g_app.iconFont);
        SetTextColor(dc, g_app.theme.label);
        DrawTextW(dc, L"", 1, &g_app.findPrev, DT_SINGLELINE | DT_VCENTER | DT_CENTER);
        DrawTextW(dc, L"", 1, &g_app.findNext, DT_SINGLELINE | DT_VCENTER | DT_CENTER);
        DrawTextW(dc, L"", 1, &g_app.findClose, DT_SINGLELINE | DT_VCENTER | DT_CENTER);
    }

    DeleteObject(sepBrush);
}

// MARK: - Menu

static HMENU BuildMenu()
{
    HMENU file = CreatePopupMenu();
    AppendMenuW(file, MF_STRING, IDM_NEW, L"&New\tCtrl+N");
    AppendMenuW(file, MF_STRING, IDM_OPEN, L"&Open...\tCtrl+O");
    HMENU recent = CreatePopupMenu();
    AppendMenuW(recent, MF_STRING | MF_GRAYED, 0, L"(empty)");
    AppendMenuW(file, MF_POPUP, (UINT_PTR)recent, L"Open &Recent");
    AppendMenuW(file, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(file, MF_STRING, IDM_SAVE, L"&Save\tCtrl+S");
    AppendMenuW(file, MF_STRING, IDM_SAVEAS, L"Save &As...\tCtrl+Shift+S");
    AppendMenuW(file, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(file, MF_STRING, IDM_CLOSE, L"&Close\tCtrl+W");

    HMENU edit = CreatePopupMenu();
    AppendMenuW(edit, MF_STRING, IDM_UNDO, L"&Undo\tCtrl+Z");
    AppendMenuW(edit, MF_STRING, IDM_REDO, L"&Redo\tCtrl+Y");
    AppendMenuW(edit, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(edit, MF_STRING, IDM_FIND, L"&Find...\tCtrl+F");
    AppendMenuW(edit, MF_STRING, IDM_FINDNEXT, L"Find &Next\tF3");
    AppendMenuW(edit, MF_STRING, IDM_FINDPREV, L"Find &Previous\tShift+F3");

    HMENU view = CreatePopupMenu();
    AppendMenuW(view, MF_STRING, IDM_TOGGLEMODE, L"Toggle &Edit Mode\tCtrl+E");
    AppendMenuW(view, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(view, MF_STRING, IDM_ZOOMIN, L"Zoom &In\tCtrl+=");
    AppendMenuW(view, MF_STRING, IDM_ZOOMOUT, L"Zoom &Out\tCtrl+-");
    AppendMenuW(view, MF_STRING, IDM_ZOOMRESET, L"&Reset Zoom\tCtrl+0");

    HMENU help = CreatePopupMenu();
    AppendMenuW(help, MF_STRING, IDM_SETDEFAULT, L"Set as &Default Markdown App...");
    AppendMenuW(help, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(help, MF_STRING, IDM_ABOUT, L"&About MrMark");

    HMENU bar = CreateMenu();
    AppendMenuW(bar, MF_POPUP, (UINT_PTR)file, L"&File");
    AppendMenuW(bar, MF_POPUP, (UINT_PTR)edit, L"&Edit");
    AppendMenuW(bar, MF_POPUP, (UINT_PTR)view, L"&View");
    AppendMenuW(bar, MF_POPUP, (UINT_PTR)help, L"&Help");
    return bar;
}

static void RefreshRecentMenu()
{
    HMENU bar = GetMenu(g_app.hwnd);
    HMENU file = GetSubMenu(bar, 0);
    HMENU recent = GetSubMenu(file, 2);
    while (GetMenuItemCount(recent) > 0) DeleteMenu(recent, 0, MF_BYPOSITION);

    auto recents = ReadRecents();
    if (recents.empty()) {
        AppendMenuW(recent, MF_STRING | MF_GRAYED, 0, L"(empty)");
        return;
    }
    for (size_t i = 0; i < recents.size() && i < 10; i++) {
        AppendMenuW(recent, MF_STRING, IDM_RECENT_FIRST + (UINT)i, recents[i].c_str());
    }
}

// MARK: - Actions

/// The version baked into the exe's VERSIONINFO — one source of truth
/// (the release workflow stamps the tag into app.rc).
static std::wstring AppVersion()
{
    wchar_t path[MAX_PATH];
    GetModuleFileNameW(nullptr, path, MAX_PATH);
    DWORD handle = 0;
    DWORD size = GetFileVersionInfoSizeW(path, &handle);
    if (size) {
        std::vector<char> data(size);
        VS_FIXEDFILEINFO* info = nullptr;
        UINT length = 0;
        if (GetFileVersionInfoW(path, 0, size, data.data())
            && VerQueryValueW(data.data(), L"\\", (void**)&info, &length) && info) {
            wchar_t buffer[32];
            swprintf_s(buffer, L"%u.%u.%u", HIWORD(info->dwFileVersionMS),
                       LOWORD(info->dwFileVersionMS), HIWORD(info->dwFileVersionLS));
            return buffer;
        }
    }
    return L"dev";
}

static void ShowAbout()
{
    std::wstring title = L"MrMark " + AppVersion();
    TaskDialog(g_app.hwnd, nullptr, L"About MrMark", title.c_str(),
               L"An ultra-fast, minimal Markdown viewer & editor.\n"
               L"One file = one window. No tabs, no plugins, no cloud, no telemetry.\n\n"
               L"MIT License - github.com/Jongsic/MrMark",
               TDCBF_OK_BUTTON, TD_INFORMATION_ICON, nullptr);
}

static void DoUndo()
{
    if (g_app.mode == Mode::Editor) {
        SendMessageW(g_app.richEdit, EM_UNDO, 0, 0);
    } else if (!g_app.doc.undoStack.empty()) {
        g_app.doc.Undo();
        StreamDocument(true);
    }
}

static void DoRedo()
{
    if (g_app.mode == Mode::Editor) {
        SendMessageW(g_app.richEdit, EM_REDO, 0, 0);
    } else if (!g_app.doc.redoStack.empty()) {
        g_app.doc.Redo();
        StreamDocument(true);
    }
}

static void HandleCommand(int id)
{
    switch (id) {
    case IDM_NEW: SpawnWindow(L"--new"); break;
    case IDM_OPEN: OpenInteractive(); break;
    case IDM_SAVE: SaveInteractive(); break;
    case IDM_SAVEAS: SaveAsInteractive(); break;
    case IDM_CLOSE: PostMessageW(g_app.hwnd, WM_CLOSE, 0, 0); break;
    case IDM_UNDO: DoUndo(); break;
    case IDM_REDO: DoRedo(); break;
    case IDM_FIND: OpenFind(); break;
    case IDM_FINDNEXT: FindStep(+1, true); break;
    case IDM_FINDPREV: FindStep(-1, true); break;
    case IDM_TOGGLEMODE: ToggleMode(); break;
    case IDM_ZOOMIN: SetZoom(g_app.zoom + 0.1f); break;
    case IDM_ZOOMOUT: SetZoom(g_app.zoom - 0.1f); break;
    case IDM_ZOOMRESET: SetZoom(1.0f); break;
    case IDM_SETDEFAULT: MakeDefaultInteractive(true); break;
    case IDM_ABOUT: ShowAbout(); break;
    default:
        if (id >= IDM_BOLD && id <= IDM_CODEBLOCK) {
            RunFormatAction(id);
        } else if (id >= IDM_RECENT_FIRST && id <= IDM_RECENT_LAST) {
            auto recents = ReadRecents();
            size_t index = id - IDM_RECENT_FIRST;
            if (index < recents.size()) OpenPath(recents[index]);
        }
        break;
    }
}

// MARK: - Subclasses

static WNDPROC g_richEditBaseProc = nullptr;

static LRESULT CALLBACK RichEditProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp)
{
    switch (msg) {
    case WM_MOUSEWHEEL:
        if (GetKeyState(VK_CONTROL) & 0x8000) {
            SetZoom(g_app.zoom + (GET_WHEEL_DELTA_WPARAM(wp) > 0 ? 0.1f : -0.1f));
            return 0;
        }
        break;

    case WM_PASTE:
        // Rich pastes would corrupt the source model; paste as plain text.
        if (g_app.mode == Mode::Editor) {
            SendMessageW(hwnd, EM_PASTESPECIAL, CF_UNICODETEXT, 0);
            return 0;
        }
        break;

    case WM_KEYDOWN: {
        bool ctrl = (GetKeyState(VK_CONTROL) & 0x8000) != 0;
        bool shift = (GetKeyState(VK_SHIFT) & 0x8000) != 0;
        if (ctrl) {
            switch (wp) {
            case 'F': OpenFind(); return 0;
            case 'S':
                if (shift) SaveAsInteractive();
                else SaveInteractive();
                return 0;
            case 'E': ToggleMode(); return 0;
            case 'N': SpawnWindow(L"--new"); return 0;
            case 'O': OpenInteractive(); return 0;
            case 'W': PostMessageW(g_app.hwnd, WM_CLOSE, 0, 0); return 0;
            case 'Z': DoUndo(); return 0;
            case 'Y': DoRedo(); return 0;
            case 'B': RunFormatAction(IDM_BOLD); return 0;
            case 'I': RunFormatAction(IDM_ITALIC); return 0;
            case 'K': RunFormatAction(IDM_LINK); return 0;
            case '1': RunFormatAction(IDM_H1); return 0;
            case '2': RunFormatAction(IDM_H2); return 0;
            case '3': RunFormatAction(IDM_H3); return 0;
            case VK_OEM_PLUS: case VK_ADD: SetZoom(g_app.zoom + 0.1f); return 0;
            case VK_OEM_MINUS: case VK_SUBTRACT: SetZoom(g_app.zoom - 0.1f); return 0;
            case '0': case VK_NUMPAD0: SetZoom(1.0f); return 0;
            }
        }
        if (wp == VK_F3) {
            FindStep(shift ? -1 : +1, true);
            return 0;
        }
        if (wp == VK_ESCAPE && g_app.findOpen) {
            CloseFind();
            return 0;
        }
        break;
    }

    case WM_LBUTTONDOWN:
        if (g_app.mode == Mode::Viewer) {
            POINTL pt{ GET_X_LPARAM(lp), GET_Y_LPARAM(lp) };
            LONG cp = (LONG)SendMessageW(hwnd, EM_CHARFROMPOS, 0, (LPARAM)&pt);
            for (const auto& box : g_app.checkboxes) {
                if (cp >= box.cpMin && cp < box.cpMax) {
                    if (g_app.doc.ToggleCheckbox(box.line)) StreamDocument(true);
                    return 0;
                }
            }
        }
        break;

    case WM_MOUSEMOVE:
        if (g_app.mode == Mode::Viewer) {
            POINTL pt{ GET_X_LPARAM(lp), GET_Y_LPARAM(lp) };
            LONG cp = (LONG)SendMessageW(hwnd, EM_CHARFROMPOS, 0, (LPARAM)&pt);
            for (const auto& box : g_app.checkboxes) {
                if (cp >= box.cpMin && cp < box.cpMax) {
                    SetCursor(LoadCursorW(nullptr, IDC_HAND));
                    break;
                }
            }
        }
        break;
    }
    return CallWindowProcW(g_richEditBaseProc, hwnd, msg, wp, lp);
}

static WNDPROC g_findEditBaseProc = nullptr;

static LRESULT CALLBACK FindEditProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp)
{
    if (msg == WM_KEYDOWN) {
        bool shift = (GetKeyState(VK_SHIFT) & 0x8000) != 0;
        if (wp == VK_RETURN || wp == VK_F3) {
            FindStep(shift ? -1 : +1, true);
            return 0;
        }
        if (wp == VK_ESCAPE) {
            CloseFind();
            return 0;
        }
    }
    if (msg == WM_CHAR && (wp == L'\r' || wp == 27)) return 0;
    return CallWindowProcW(g_findEditBaseProc, hwnd, msg, wp, lp);
}

// MARK: - Theme application

static void CreateFonts()
{
    float d = g_app.dpi;
    for (HFONT* f : { &g_app.uiFont, &g_app.uiBoldFont, &g_app.uiItalicFont, &g_app.iconFont,
                      &g_app.bodyFont, &g_app.bodyBoldFont }) {
        if (*f) DeleteObject(*f);
    }
    g_app.uiFont = CreateFontW(-(int)(13 * d), 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE,
                               DEFAULT_CHARSET, 0, 0, CLEARTYPE_QUALITY, 0, L"Segoe UI");
    g_app.uiBoldFont = CreateFontW(-(int)(13 * d), 0, 0, 0, FW_SEMIBOLD, FALSE, FALSE, FALSE,
                                   DEFAULT_CHARSET, 0, 0, CLEARTYPE_QUALITY, 0, L"Segoe UI");
    g_app.uiItalicFont = CreateFontW(-(int)(13 * d), 0, 0, 0, FW_SEMIBOLD, TRUE, FALSE, FALSE,
                                     DEFAULT_CHARSET, 0, 0, CLEARTYPE_QUALITY, 0, L"Segoe UI");
    g_app.iconFont = CreateFontW(-(int)(15 * d), 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE,
                                 DEFAULT_CHARSET, 0, 0, CLEARTYPE_QUALITY, 0,
                                 L"Segoe MDL2 Assets");
    g_app.bodyFont = CreateFontW(-(int)(15 * d), 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE,
                                 DEFAULT_CHARSET, 0, 0, CLEARTYPE_QUALITY, 0, L"Segoe UI");
    g_app.bodyBoldFont = CreateFontW(-(int)(15 * d), 0, 0, 0, FW_BOLD, FALSE, FALSE, FALSE,
                                     DEFAULT_CHARSET, 0, 0, CLEARTYPE_QUALITY, 0, L"Segoe UI");
    SendMessageW(g_app.findEdit, WM_SETFONT, (WPARAM)g_app.uiFont, TRUE);
}

static void ApplyTheme(bool rebuildContent = true)
{
    BOOL dark = g_app.theme.dark;
    DwmSetWindowAttribute(g_app.hwnd, 20 /*DWMWA_USE_IMMERSIVE_DARK_MODE*/, &dark, sizeof(dark));
    SetWindowTheme(g_app.richEdit, dark ? L"DarkMode_Explorer" : L"Explorer", nullptr);
    SendMessageW(g_app.richEdit, EM_SETBKGNDCOLOR, FALSE, (LPARAM)g_app.theme.windowBg);

    if (g_app.barBrush) DeleteObject(g_app.barBrush);
    g_app.barBrush = CreateSolidBrush(g_app.theme.barBg);
    if (g_app.findEditBrush) {
        DeleteObject(g_app.findEditBrush);
        g_app.findEditBrush = nullptr;
    }

    // Colors are baked into the content; rebuild the current mode.
    if (rebuildContent) {
        if (g_app.mode == Mode::Viewer) StreamDocument(true);
        else RestyleRange(0, (int)g_app.lines.size() - 1, true);
    }
    InvalidateRect(g_app.hwnd, nullptr, TRUE);
}

// MARK: - Window proc

static LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp)
{
    switch (msg) {
    case WM_PAINT: {
        PAINTSTRUCT ps;
        HDC dc = BeginPaint(hwnd, &ps);
        DrawBars(dc);
        EndPaint(hwnd, &ps);
        return 0;
    }

    case WM_ERASEBKGND:
        return 1;

    case WM_SIZE:
        LayoutBars();
        InvalidateRect(hwnd, nullptr, TRUE);
        return 0;

    case WM_GETMINMAXINFO: {
        auto* info = (MINMAXINFO*)lp;
        info->ptMinTrackSize = { (LONG)(320 * g_app.dpi), (LONG)(240 * g_app.dpi) };
        return 0;
    }

    case WM_DPICHANGED: {
        g_app.dpi = HIWORD(wp) / 96.0f;
        CreateFonts();
        auto* suggested = (RECT*)lp;
        SetWindowPos(hwnd, nullptr, suggested->left, suggested->top,
                     suggested->right - suggested->left, suggested->bottom - suggested->top,
                     SWP_NOZORDER | SWP_NOACTIVATE);
        LayoutBars();
        return 0;
    }

    case WM_INITMENUPOPUP:
        RefreshRecentMenu();
        return 0;

    case WM_COMMAND:
        if (HIWORD(wp) == EN_CHANGE && (HWND)lp == g_app.findEdit) {
            wchar_t buffer[512];
            GetWindowTextW(g_app.findEdit, buffer, 512);
            g_app.findQuery = buffer;
            SendMessageW(g_app.richEdit, EM_SETSEL, 0, 0);
            FindStep(+1, false);
            return 0;
        }
        if (HIWORD(wp) == EN_CHANGE && (HWND)lp == g_app.richEdit) {
            if (g_app.mode == Mode::Editor && !g_app.internalChange) EditorTextChanged();
            return 0;
        }
        HandleCommand(LOWORD(wp));
        return 0;

    case WM_HSCROLL:
        if ((HWND)lp == g_app.zoomSlider) {
            int pos = (int)SendMessageW(g_app.zoomSlider, TBM_GETPOS, 0, 0);
            SetZoom(pos / 100.0f);
        }
        return 0;

    case WM_CTLCOLOREDIT:
        if ((HWND)lp == g_app.findEdit) {
            HDC dc = (HDC)wp;
            SetTextColor(dc, g_app.theme.label);
            SetBkColor(dc, g_app.theme.dark ? RGB(0x2B, 0x2B, 0x2B) : RGB(0xFF, 0xFF, 0xFF));
            if (!g_app.findEditBrush) {
                g_app.findEditBrush = CreateSolidBrush(
                    g_app.theme.dark ? RGB(0x2B, 0x2B, 0x2B) : RGB(0xFF, 0xFF, 0xFF));
            }
            return (LRESULT)g_app.findEditBrush;
        }
        break;

    case WM_CTLCOLORSTATIC: // the trackbar asks through this
        if ((HWND)lp == g_app.zoomSlider) return (LRESULT)g_app.barBrush;
        break;

    case WM_LBUTTONDOWN: {
        POINT pt{ GET_X_LPARAM(lp), GET_Y_LPARAM(lp) };
        if (PtInRect(&g_app.toggleButton.rect, pt)) { ToggleMode(); return 0; }
        if (PtInRect(&g_app.aboutButton.rect, pt)) { ShowAbout(); return 0; }
        if (PtInRect(&g_app.zoomMinus, pt)) { SetZoom(g_app.zoom - 0.1f); return 0; }
        if (PtInRect(&g_app.zoomPlus, pt)) { SetZoom(g_app.zoom + 0.1f); return 0; }
        for (const auto& button : g_app.buttons) {
            if (PtInRect(&button.rect, pt)) { HandleCommand(button.id); return 0; }
        }
        if (g_app.findOpen) {
            if (PtInRect(&g_app.findPrev, pt)) { FindStep(-1, true); return 0; }
            if (PtInRect(&g_app.findNext, pt)) { FindStep(+1, true); return 0; }
            if (PtInRect(&g_app.findClose, pt)) { CloseFind(); return 0; }
        }
        return 0;
    }

    case WM_MOUSEMOVE: {
        POINT pt{ GET_X_LPARAM(lp), GET_Y_LPARAM(lp) };
        bool hand = PtInRect(&g_app.toggleButton.rect, pt)
            || PtInRect(&g_app.aboutButton.rect, pt) || PtInRect(&g_app.zoomMinus, pt)
            || PtInRect(&g_app.zoomPlus, pt);
        for (const auto& button : g_app.buttons) {
            hand = hand || PtInRect(&button.rect, pt);
        }
        if (g_app.findOpen) {
            hand = hand || PtInRect(&g_app.findPrev, pt) || PtInRect(&g_app.findNext, pt)
                || PtInRect(&g_app.findClose, pt);
        }
        g_app.handCursor = hand;
        return 0;
    }

    case WM_SETCURSOR:
        if (LOWORD(lp) == HTCLIENT && g_app.handCursor) {
            SetCursor(LoadCursorW(nullptr, IDC_HAND));
            return TRUE;
        }
        break;

    case WM_KEYDOWN: {
        // Focus is usually inside the RichEdit; this covers the window itself.
        bool ctrl = (GetKeyState(VK_CONTROL) & 0x8000) != 0;
        bool shift = (GetKeyState(VK_SHIFT) & 0x8000) != 0;
        if (ctrl && wp == 'F') { OpenFind(); return 0; }
        if (ctrl && wp == 'S') { SaveInteractive(); return 0; }
        if (ctrl && wp == 'E') { ToggleMode(); return 0; }
        if (ctrl && wp == 'W') { PostMessageW(hwnd, WM_CLOSE, 0, 0); return 0; }
        if (wp == VK_F3) { FindStep(shift ? -1 : +1, true); return 0; }
        if (wp == VK_ESCAPE && g_app.findOpen) { CloseFind(); return 0; }
        return 0;
    }

    case WM_NOTIFY: {
        auto* header = (NMHDR*)lp;
        if (header->hwndFrom == g_app.richEdit && header->code == EN_LINK) {
            auto* link = (ENLINK*)lp;
            if (link->msg == WM_LBUTTONUP && g_app.mode == Mode::Viewer) {
                if (auto tom = Tom()) {
                    ComPtr<ITextRange> range;
                    tom->Range(link->chrg.cpMin, link->chrg.cpMax, &range);
                    ComPtr<ITextRange2> range2;
                    if (range && SUCCEEDED(range.As(&range2))) {
                        BSTR url = nullptr;
                        if (SUCCEEDED(range2->GetURL(&url)) && url) {
                            std::wstring target(url);
                            SysFreeString(url);
                            if (!target.empty() && target.front() == L'"') target.erase(0, 1);
                            if (!target.empty() && target.back() == L'"') target.pop_back();
                            OpenUrl(target);
                        }
                    }
                }
                return 1;
            }
        }
        if (header->hwndFrom == g_app.richEdit && header->code == EN_SELCHANGE) {
            if (g_app.mode == Mode::Editor && !g_app.internalChange) EditorSelectionChanged();
            if (g_app.findOpen) {
                UpdateFindCounts();
                InvalidateBars();
            }
            return 0;
        }
        return 0;
    }

    case WM_COPYDATA: {
        // "Do you own this file?" from a second launch of the same document.
        auto* data = (COPYDATASTRUCT*)lp;
        if (data->dwData == kActivateMagic && !g_app.doc.path.empty()) {
            std::wstring asked((const wchar_t*)data->lpData,
                               data->cbData / sizeof(wchar_t));
            if (!asked.empty() && asked.back() == L'\0') asked.pop_back();
            if (_wcsicmp(asked.c_str(), g_app.doc.path.c_str()) == 0) {
                if (IsIconic(hwnd)) ShowWindow(hwnd, SW_RESTORE);
                SetForegroundWindow(hwnd);
                return TRUE;
            }
        }
        return FALSE;
    }

    case WM_DROPFILES: {
        auto drop = (HDROP)wp;
        UINT count = DragQueryFileW(drop, 0xFFFFFFFF, nullptr, 0);
        bool first = true;
        for (UINT i = 0; i < count; i++) {
            wchar_t file[MAX_PATH];
            if (!DragQueryFileW(drop, i, file, MAX_PATH)) continue;
            const wchar_t* ext = wcsrchr(file, L'.');
            if (!ext
                || (_wcsicmp(ext, L".md") != 0 && _wcsicmp(ext, L".markdown") != 0
                    && _wcsicmp(ext, L".mdown") != 0 && _wcsicmp(ext, L".mkd") != 0)) {
                continue;
            }
            if (first) {
                OpenPath(file); // pristine untitled adopts; otherwise a new window
                first = false;
            } else {
                SpawnWindow(L"\"" + std::wstring(file) + L"\"");
            }
        }
        DragFinish(drop);
        return 0;
    }

    case WM_TIMER:
        // External writers (other editors, git, scripts): a clean document
        // reloads automatically; unsaved edits are never touched.
        if (wp == 1 && g_app.mode == Mode::Viewer && !g_app.doc.dirty
            && g_app.doc.DiskChanged()) {
            md::Document fresh;
            if (fresh.Load(g_app.doc.path.c_str())) {
                g_app.doc = std::move(fresh);
                StreamDocument(true);
            }
        }
        return 0;

    case WM_SETTINGCHANGE: {
        bool dark = SystemUsesDarkApps();
        if (dark != g_app.theme.dark) {
            g_app.theme = dark ? DarkTheme() : LightTheme();
            ApplyTheme();
        }
        return 0;
    }

    case WM_CLOSE:
        if (g_app.doc.dirty) {
            int chosen = ConfirmClose();
            if (chosen == IDCANCEL) return 0;
            if (chosen == 101 && !SaveInteractive()) return 0;
        }
        SavePlacement();
        DestroyWindow(hwnd);
        return 0;

    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}

// MARK: - Entry point

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE, PWSTR, int showCmd)
{
    int argc = 0;
    LPWSTR* argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    bool benchmark = false;
    std::wstring file;
    for (int i = 1; i < argc; i++) {
        if (wcscmp(argv[i], L"--benchmark") == 0) benchmark = true;
        else if (wcsncmp(argv[i], L"--", 2) != 0) file = argv[i]; // "--new" implied by no file
    }
    clockmarks::Init(benchmark);

    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    INITCOMMONCONTROLSEX icc{ sizeof(icc), ICC_BAR_CLASSES };
    InitCommonControlsEx(&icc);
    LoadLibraryW(L"msftedit.dll");

    // Launched with no file: a fresh untitled document, straight into the
    // editor (matching the macOS app). File > Open is there when needed.
    if (!file.empty()) {
        wchar_t full[MAX_PATH];
        GetFullPathNameW(file.c_str(), MAX_PATH, full, nullptr);

        // Already open in another window? Activate it instead (one file =
        // one window).
        if (!benchmark && ActivateExistingWindow(full)) return 0;

        if (!g_app.doc.Load(full)) {
            TaskDialog(nullptr, nullptr, L"MrMark", L"Couldn't open the file.", nullptr,
                       TDCBF_OK_BUTTON, TD_ERROR_ICON, nullptr);
            return 1;
        }
        clockmarks::Mark(L"document-read");
        g_baseDir = g_app.doc.path.substr(0, g_app.doc.path.find_last_of(L'\\'));
        SHAddToRecentDocs(SHARD_PATHW, g_app.doc.path.c_str());
        NoteRecent(g_app.doc.path);
    }

    // Prefer Cascadia Mono when installed; Consolas ships everywhere.
    {
        HDC dc = GetDC(nullptr);
        LOGFONTW probe{};
        wcscpy_s(probe.lfFaceName, L"Cascadia Mono");
        probe.lfCharSet = DEFAULT_CHARSET;
        bool found = false;
        EnumFontFamiliesExW(
            dc, &probe,
            [](const LOGFONTW*, const TEXTMETRICW*, DWORD, LPARAM p) -> int {
                *(bool*)p = true;
                return 0;
            },
            (LPARAM)&found, 0);
        ReleaseDC(nullptr, dc);
        if (found) g_app.monoFamily = L"Cascadia Mono";
    }

    g_app.theme = SystemUsesDarkApps() ? DarkTheme() : LightTheme();

    WNDCLASSW wc{};
    wc.lpfnWndProc = WndProc;
    wc.hInstance = instance;
    wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    wc.lpszClassName = L"MrMark";
    wc.hIcon = LoadIconW(instance, MAKEINTRESOURCEW(1));
    RegisterClassW(&wc);

    HDC screen = GetDC(nullptr);
    g_app.dpi = GetDeviceCaps(screen, LOGPIXELSX) / 96.0f;
    ReleaseDC(nullptr, screen);

    int width = (int)(760 * g_app.dpi);
    int height = (int)(820 * g_app.dpi);
    RECT work;
    SystemParametersInfoW(SPI_GETWORKAREA, 0, &work, 0);
    int x = work.left + ((work.right - work.left) - width) / 2;
    int y = work.top + ((work.bottom - work.top) - height) / 2;

    g_app.hwnd = CreateWindowExW(0, wc.lpszClassName, L"MrMark", WS_OVERLAPPEDWINDOW, x, y,
                                 width, height, nullptr, BuildMenu(), instance, nullptr);
    if (!g_app.hwnd) return 1;
    g_app.dpi = GetDpiForWindow(g_app.hwnd) / 96.0f;
    DragAcceptFiles(g_app.hwnd, TRUE);

    // The document view: one RichEdit for both modes — selection, copy, IME,
    // accessibility, undo, and zoom are the OS control's own.
    g_app.richEdit = CreateWindowExW(0, MSFTEDIT_CLASS, L"",
                                     WS_CHILD | WS_VISIBLE | WS_VSCROLL | ES_MULTILINE
                                         | ES_AUTOVSCROLL | ES_NOOLEDRAGDROP | ES_NOHIDESEL,
                                     0, 0, 10, 10, g_app.hwnd, (HMENU)(INT_PTR)200, instance,
                                     nullptr);
    SendMessageW(g_app.richEdit, EM_SETEVENTMASK, 0, ENM_LINK | ENM_CHANGE | ENM_SELCHANGE);
    SendMessageW(g_app.richEdit, EM_SETEDITSTYLE, SES_HYPERLINKTOOLTIPS, SES_HYPERLINKTOOLTIPS);
    SendMessageW(g_app.richEdit, EM_SETMARGINS, EC_LEFTMARGIN | EC_RIGHTMARGIN,
                 MAKELONG((int)(24 * g_app.dpi), (int)(24 * g_app.dpi)));
    g_richEditBaseProc =
        (WNDPROC)SetWindowLongPtrW(g_app.richEdit, GWLP_WNDPROC, (LONG_PTR)RichEditProc);

    g_app.findEdit = CreateWindowExW(0, L"EDIT", L"", WS_CHILD | ES_AUTOHSCROLL | ES_LEFT, 0, 0,
                                     10, 10, g_app.hwnd, (HMENU)(INT_PTR)100, instance, nullptr);
    g_findEditBaseProc =
        (WNDPROC)SetWindowLongPtrW(g_app.findEdit, GWLP_WNDPROC, (LONG_PTR)FindEditProc);

    g_app.zoomSlider = CreateWindowExW(0, TRACKBAR_CLASSW, L"",
                                       WS_CHILD | WS_VISIBLE | TBS_HORZ | TBS_NOTICKS, 0, 0, 10,
                                       10, g_app.hwnd, (HMENU)(INT_PTR)101, instance, nullptr);
    SendMessageW(g_app.zoomSlider, TBM_SETRANGE, FALSE, MAKELPARAM(50, 300));
    SendMessageW(g_app.zoomSlider, TBM_SETPOS, TRUE, 100);

    g_app.tooltip = CreateWindowExW(0, TOOLTIPS_CLASSW, nullptr, WS_POPUP | TTS_ALWAYSTIP, 0, 0,
                                    0, 0, g_app.hwnd, nullptr, instance, nullptr);

    CreateFonts();
    ApplyTheme(false); // the initial content is streamed just below
    LayoutBars();

    if (g_app.doc.path.empty()) {
        // A brand-new document has nothing to view — start writing.
        g_app.mode = Mode::Viewer;
        EnterEditorMode();
    } else {
        StreamDocument(false);
        clockmarks::Mark(L"stream");
    }
    UpdateTitle();
    SetTimer(g_app.hwnd, 1, 1000, nullptr);

    WINDOWPLACEMENT wp{ sizeof(wp) };
    if (RestorePlacement(wp)) {
        wp.showCmd = showCmd == SW_SHOWNORMAL ? SW_SHOWNORMAL : showCmd;
        SetWindowPlacement(g_app.hwnd, &wp);
        ShowWindow(g_app.hwnd, wp.showCmd);
    } else {
        ShowWindow(g_app.hwnd, showCmd);
    }
    SetFocus(g_app.richEdit);
    UpdateWindow(g_app.hwnd);
    clockmarks::Done();

    if (!g_app.doc.path.empty() && !benchmark) OfferDefaultIfAppropriate();

    MSG msg;
    while (GetMessageW(&msg, nullptr, 0, 0)) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
    return 0;
}
