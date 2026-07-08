// Unit tests for MrMark's pure logic: parser, formatting actions, the
// document codec, and the editor's line styler. Console app; exits non-zero
// on the first failure. Run via `build.cmd test`.

#include <cstdio>
#include <string>

#include "document.h"
#include "formatting.h"
#include "parser.h"
#include "spec_corpus.h"
#include "styler.h"

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond)                                                                    \
    do {                                                                               \
        g_checks++;                                                                    \
        if (!(cond)) {                                                                 \
            g_failures++;                                                              \
            wprintf(L"FAIL %S:%d  %S\n", __FILE__, __LINE__, #cond);                   \
        }                                                                              \
    } while (0)

static std::wstring Apply(const md::FormatEdit& edit, const std::wstring& text)
{
    return text.substr(0, edit.start) + edit.replacement
        + text.substr(edit.start + edit.length);
}

// MARK: - Parser

static void TestParser()
{
    // ATX headings
    {
        auto blocks = md::Parse(L"## 다람쥐 헌 쳇바퀴");
        CHECK(blocks.size() == 1 && blocks[0].type == md::BlockType::Heading);
        CHECK(blocks[0].level == 2);
        CHECK(md::PlainText(blocks[0].inlines) == L"다람쥐 헌 쳇바퀴");
    }
    CHECK(md::Parse(L"####### nope")[0].type == md::BlockType::Paragraph);
    CHECK(md::PlainText(md::Parse(L"\\# not a heading")[0].inlines) == L"# not a heading");

    // Emphasis nesting: **한글 *중첩* 스타일**
    {
        auto blocks = md::Parse(L"**bold *nested* tail**");
        const auto& inlines = blocks[0].inlines;
        CHECK(inlines.size() == 1 && inlines[0].type == md::InlineType::Strong);
        bool hasEmphasis = false;
        for (const auto& child : inlines[0].children) {
            if (child.type == md::InlineType::Emphasis) hasEmphasis = true;
        }
        CHECK(hasEmphasis);
    }
    // ***both*** = Emphasis(Strong)
    {
        auto blocksKeep = md::Parse(L"***both***");
        const auto& inlines = blocksKeep[0].inlines;
        CHECK(inlines.size() == 1 && inlines[0].type == md::InlineType::Emphasis);
        CHECK(inlines[0].children.size() == 1
              && inlines[0].children[0].type == md::InlineType::Strong);
    }
    CHECK(md::Parse(L"~~gone~~")[0].inlines[0].type == md::InlineType::Strike);
    CHECK(md::PlainText(md::Parse(L"\\*not italic\\*")[0].inlines) == L"*not italic*");

    // Code spans
    {
        auto blocksKeep = md::Parse(L"`a * b * c`");
        const auto& inlines = blocksKeep[0].inlines;
        CHECK(inlines.size() == 1 && inlines[0].type == md::InlineType::Code);
        CHECK(inlines[0].text == L"a * b * c");
    }
    {
        auto blocksKeep = md::Parse(L"``code with ` inside``");
        const auto& inlines = blocksKeep[0].inlines;
        CHECK(inlines[0].type == md::InlineType::Code);
        CHECK(inlines[0].text == L"code with ` inside");
    }

    // Breaks
    {
        bool hard = false;
        auto keep = md::Parse(L"first  \nsecond");
        for (const auto& node : keep[0].inlines) {
            if (node.type == md::InlineType::HardBreak) hard = true;
        }
        CHECK(hard);
    }
    {
        bool soft = false;
        auto keep = md::Parse(L"first\nsecond");
        for (const auto& node : keep[0].inlines) {
            if (node.type == md::InlineType::SoftBreak) soft = true;
        }
        CHECK(soft);
    }

    // Links / autolinks / images / HTML
    {
        auto blocksKeep = md::Parse(L"[MrMark](https://example.com/경로?쿼리=값)");
        const auto& inlines = blocksKeep[0].inlines;
        CHECK(inlines[0].type == md::InlineType::Link);
        CHECK(inlines[0].dest == L"https://example.com/경로?쿼리=값");
        CHECK(md::PlainText(inlines[0].children) == L"MrMark");
    }
    {
        auto blocksKeep = md::Parse(L"<https://www.example.com>");
        const auto& inlines = blocksKeep[0].inlines;
        CHECK(inlines[0].type == md::InlineType::Link);
        CHECK(inlines[0].dest == L"https://www.example.com");
    }
    {
        auto blocksKeep = md::Parse(L"![MrMark icon](design/M.png)");
        const auto& inlines = blocksKeep[0].inlines;
        CHECK(inlines[0].type == md::InlineType::Image);
        CHECK(inlines[0].dest == L"design/M.png");
        CHECK(inlines[0].text == L"MrMark icon");
    }
    {
        bool kbdOpen = false, kbdClose = false;
        auto keep = md::Parse(L"press <kbd>S</kbd> now");
        for (const auto& node : keep[0].inlines) {
            if (node.type == md::InlineType::Html && node.text == L"<kbd>") kbdOpen = true;
            if (node.type == md::InlineType::Html && node.text == L"</kbd>") kbdClose = true;
        }
        CHECK(kbdOpen && kbdClose);
    }
    {
        auto blocks = md::Parse(L"<div align=\"center\">raw HTML block</div>");
        CHECK(blocks[0].type == md::BlockType::Html);
        CHECK(blocks[0].code == L"<div align=\"center\">raw HTML block</div>");
    }

    // Lists
    {
        auto blocks = md::Parse(L"- first\n  - nested\n- second");
        CHECK(blocks.size() == 1 && blocks[0].type == md::BlockType::List);
        CHECK(blocks[0].items.size() == 2);
        bool nested = false;
        for (const auto& child : blocks[0].items[0].children) {
            if (child.type == md::BlockType::List) nested = true;
        }
        CHECK(nested);
    }
    {
        auto blocks = md::Parse(L"3. three\n4. four");
        CHECK(blocks[0].ordered && blocks[0].start == 3 && blocks[0].items.size() == 2);
    }
    {
        auto blocks = md::Parse(L"- [ ] todo\n- [x] done\n- plain");
        CHECK(blocks[0].items[0].check == 0 && blocks[0].items[0].sourceLine == 1);
        CHECK(blocks[0].items[1].check == 1 && blocks[0].items[1].sourceLine == 2);
        CHECK(blocks[0].items[2].check == -1);
    }
    {
        auto blocks = md::Parse(L"# Title\n\n- [ ] task on line 3");
        CHECK(blocks[1].items[0].sourceLine == 3);
    }
    {
        auto blocks = md::Parse(L"1. One\n2. Two\n   1. Two-one\n3. Three");
        CHECK(blocks[0].items.size() == 3);
    }

    // Fenced code
    {
        auto blocks = md::Parse(L"```\n  two spaces\n\ta tab\n```");
        CHECK(blocks[0].type == md::BlockType::Code);
        CHECK(blocks[0].code == L"  two spaces\n\ta tab");
        CHECK(blocks[0].lang.empty());
    }
    {
        auto blocks = md::Parse(L"```swift\nlet x = 1\n```");
        CHECK(blocks[0].lang == L"swift" && blocks[0].code == L"let x = 1");
    }
    CHECK(md::Parse(L"```\nabc")[0].code == L"abc");
    CHECK(md::Parse(L"```\n# not a heading\n```")[0].code == L"# not a heading");

    // Quotes
    {
        auto blocks = md::Parse(L"> outer\n>\n> > inner");
        CHECK(blocks[0].type == md::BlockType::Quote);
        bool nested = false;
        for (const auto& child : blocks[0].children) {
            if (child.type == md::BlockType::Quote) nested = true;
        }
        CHECK(nested);
    }

    // Tables
    {
        auto blocks = md::Parse(
            L"| Language | Hello |\n| --- | --- |\n| Korean | 안녕하세요 |\n| Arabic | مرحبا |");
        CHECK(blocks[0].type == md::BlockType::Table);
        CHECK(blocks[0].header.size() == 2 && blocks[0].rows.size() == 2);
        CHECK(md::PlainText(blocks[0].rows[0][1]) == L"안녕하세요");
    }
    {
        auto blocks = md::Parse(L"| a | b | c |\n| - | - | - |\n| only |");
        CHECK(blocks[0].rows[0].size() == 3); // padded to header width
    }
    CHECK(md::Parse(L"just | a pipe")[0].type == md::BlockType::Paragraph);
    { // a table interrupts a paragraph (no blank line before it)
        auto blocks = md::Parse(
            L"**Section**\n| File | Note |\n|------|------|\n| a.md | x |");
        CHECK(blocks.size() == 2);
        CHECK(blocks[0].type == md::BlockType::Paragraph);
        CHECK(blocks[1].type == md::BlockType::Table);
        CHECK(blocks[1].header.size() == 2 && blocks[1].rows.size() == 1);
    }
    { // a block-level HTML tag interrupts a paragraph (no blank line before it)
        auto blocks = md::Parse(L"paragraph text\n<div>HTML content</div>");
        CHECK(blocks.size() == 2);
        CHECK(blocks[0].type == md::BlockType::Paragraph);
        CHECK(blocks[1].type == md::BlockType::Html);
        CHECK(blocks[1].code == L"<div>HTML content</div>");
    }
    { // comments and closing block tags interrupt too
        auto blocks = md::Parse(L"para\n<!-- note -->");
        CHECK(blocks.size() == 2 && blocks[1].type == md::BlockType::Html);
        auto closing = md::Parse(L"para\n</div>");
        CHECK(closing.size() == 2 && closing[1].type == md::BlockType::Html);
    }
    { // an inline (type 7) tag does not interrupt a paragraph
        auto blocks = md::Parse(L"para with\n<span>inline</span> html");
        CHECK(blocks.size() == 1 && blocks[0].type == md::BlockType::Paragraph);
        auto autolink = md::Parse(L"see\n<https://example.com> for more");
        CHECK(autolink.size() == 1 && autolink[0].type == md::BlockType::Paragraph);
    }

    // Thematic breaks
    for (const wchar_t* source : { L"---", L"***", L"- - -" }) {
        CHECK(md::Parse(source)[0].type == md::BlockType::Rule);
    }
}

// MARK: - Formatting

static void TestFormatting()
{
    // Inline wrap
    {
        auto edit = md::ToggleInlineWrap(L"hello world", 0, 5, L"**");
        CHECK(Apply(edit, L"hello world") == L"**hello** world");
        CHECK(edit.selStart == 2 && edit.selLength == 5);
    }
    {
        auto edit = md::ToggleInlineWrap(L"**hello** world", 0, 9, L"**");
        CHECK(Apply(edit, L"**hello** world") == L"hello world");
    }
    {
        auto edit = md::ToggleInlineWrap(L"**hello** world", 2, 5, L"**");
        CHECK(Apply(edit, L"**hello** world") == L"hello world");
    }
    {
        auto edit = md::ToggleInlineWrap(L"ab", 1, 0, L"*");
        CHECK(Apply(edit, L"ab") == L"a**b");
        CHECK(edit.selStart == 2 && edit.selLength == 0);
    }

    // Headings
    CHECK(Apply(md::SetHeading(L"Title", 0, 0, 2), L"Title") == L"## Title");
    CHECK(Apply(md::SetHeading(L"# Title", 3, 0, 3), L"# Title") == L"### Title");
    CHECK(Apply(md::SetHeading(L"## Title", 4, 0, 2), L"## Title") == L"Title");
    CHECK(Apply(md::SetHeading(L"one\ntwo", 0, 7, 1), L"one\ntwo") == L"# one\n# two");

    // Lists
    CHECK(Apply(md::ToggleBulletList(L"alpha\nbeta", 0, 10), L"alpha\nbeta")
          == L"- alpha\n- beta");
    CHECK(Apply(md::ToggleBulletList(L"- alpha\n- beta", 0, 14), L"- alpha\n- beta")
          == L"alpha\nbeta");
    CHECK(Apply(md::ToggleChecklist(L"task", 0, 4), L"task") == L"- [ ] task");
    CHECK(Apply(md::ToggleChecklist(L"- [x] done\n- [ ] todo", 0, 21),
                L"- [x] done\n- [ ] todo")
          == L"done\ntodo");
    CHECK(Apply(md::ToggleNumberedList(L"a\nb\nc", 0, 5), L"a\nb\nc") == L"1. a\n2. b\n3. c");
    CHECK(Apply(md::ToggleNumberedList(L"- a\n- b", 0, 7), L"- a\n- b") == L"1. a\n2. b");
    CHECK(Apply(md::ToggleNumberedList(L"1. a\n2. b", 0, 9), L"1. a\n2. b") == L"a\nb");
    CHECK(Apply(md::ToggleBulletList(L"a\n\nb", 0, 4), L"a\n\nb") == L"- a\n\n- b");

    // Insertions
    {
        auto edit = md::InsertLink(L"visit here now", 6, 4);
        std::wstring result = Apply(edit, L"visit here now");
        CHECK(result == L"visit [here](url) now");
        CHECK(result.substr(edit.selStart, edit.selLength) == L"url");
    }
    CHECK(Apply(md::InsertLink(L"", 0, 0), L"") == L"[text](url)");
    {
        auto edit = md::InsertImage(L"", 0, 0);
        std::wstring result = Apply(edit, L"");
        CHECK(result == L"![alt](path)");
        CHECK(result.substr(edit.selStart, edit.selLength) == L"path");
    }
    {
        auto edit = md::InsertCodeBlock(L"before\nprint(1)\nafter", 8, 0);
        CHECK(Apply(edit, L"before\nprint(1)\nafter") == L"before\n```\nprint(1)\n```\nafter");
        CHECK(edit.selStart == 10); // caret on the fence line
    }

    // Line plumbing
    CHECK(md::LineRange(L"aa\nbb\ncc", 4, 0) == std::make_pair((size_t)3, (size_t)3));
    CHECK(md::LineRange(L"aa\nbb\ncc", 1, 4) == std::make_pair((size_t)0, (size_t)6));
    CHECK(md::LineRange(L"aa\nbb\ncc", 8, 0) == std::make_pair((size_t)6, (size_t)2));
}

// MARK: - Document codec

static void TestDocument()
{
    auto roundTrip = [](const char* payload, size_t size, bool bom) {
        std::vector<char> bytes;
        if (bom) {
            bytes.push_back((char)0xEF);
            bytes.push_back((char)0xBB);
            bytes.push_back((char)0xBF);
        }
        bytes.insert(bytes.end(), payload, payload + size);
        auto decoded = md::DecodeUtf8(bytes);
        auto encoded = md::EncodeUtf8(decoded.text, decoded.usesCrLf, decoded.hasBom);
        return encoded == bytes;
    };
    const char plain[] = "plain\nunix\n";
    const char crlf[] = "windows\r\nline endings\r\n";
    const char noEol[] = "no trailing newline";
    const char korean[] = "\xed\x95\x9c\xea\xb8\x80\r\ncontent\r\n";
    for (bool bom : { false, true }) {
        CHECK(roundTrip(plain, sizeof(plain) - 1, bom));
        CHECK(roundTrip(crlf, sizeof(crlf) - 1, bom));
        CHECK(roundTrip(noEol, sizeof(noEol) - 1, bom));
        CHECK(roundTrip(korean, sizeof(korean) - 1, bom));
    }

    {
        std::vector<char> bytes = { 'a', '\r', '\n', 'b' };
        auto decoded = md::DecodeUtf8(bytes);
        CHECK(decoded.text == L"a\nb" && decoded.usesCrLf && !decoded.hasBom);
    }

    // Checkbox toggling
    CHECK(md::ToggleCheckboxMarker(L"- [ ] task") == L"- [x] task");
    CHECK(md::ToggleCheckboxMarker(L"- [x] task") == L"- [ ] task");
    CHECK(md::ToggleCheckboxMarker(L"- [X] task") == L"- [ ] task");
    CHECK(md::ToggleCheckboxMarker(L"  - [ ] nested") == L"  - [x] nested");
    CHECK(md::ToggleCheckboxMarker(L"no checkbox here") == L"no checkbox here");

    {
        md::Document doc;
        doc.text = L"# Title\n- [ ] one\n- [x] two";
        doc.savedText = doc.text;
        CHECK(doc.ToggleCheckbox(2));
        CHECK(doc.text == L"# Title\n- [x] one\n- [x] two");
        CHECK(doc.dirty);
        doc.Undo();
        CHECK(doc.text == L"# Title\n- [ ] one\n- [x] two");
        CHECK(!doc.dirty);
        doc.Redo();
        CHECK(doc.text == L"# Title\n- [x] one\n- [x] two");
        CHECK(!doc.ToggleCheckbox(0) && !doc.ToggleCheckbox(9));
    }
}

// MARK: - Styler

static bool HasSpan(const md::LineStyle& style, int start, int length, int flags)
{
    for (const auto& span : style.spans) {
        if (span.start == start && span.length == length && span.flags == flags) return true;
    }
    return false;
}

static void TestStyler()
{
    {
        auto style = md::AnalyzeLine(L"## Title", false);
        CHECK(style.headingLevel == 2);
        CHECK(HasSpan(style, 0, 3, md::kConcealed));
    }
    CHECK(md::AnalyzeLine(L"#hashtag", false).headingLevel == 0);

    {
        auto style = md::AnalyzeLine(L"a **bold** z", false);
        CHECK(HasSpan(style, 2, 8, md::kBold));
        CHECK(HasSpan(style, 2, 2, md::kConcealed));
        CHECK(HasSpan(style, 8, 2, md::kConcealed));
    }
    {
        bool both = false;
        for (const auto& span : md::AnalyzeLine(L"***x***", false).spans) {
            if ((span.flags & md::kBold) && (span.flags & md::kItalic)) both = true;
        }
        CHECK(both);
    }
    {
        bool concealed = false;
        for (const auto& span : md::AnalyzeLine(L"just **unclosed", false).spans) {
            if (span.flags & md::kConcealed) concealed = true;
        }
        CHECK(!concealed);
    }
    {
        bool italic = false;
        for (const auto& span : md::AnalyzeLine(L"snake_case_name here", false).spans) {
            if (span.flags & md::kItalic) italic = true;
        }
        CHECK(!italic);
    }
    {
        auto style = md::AnalyzeLine(L"see `code` here", false);
        CHECK(HasSpan(style, 4, 6, md::kCodeSpan));
        CHECK(HasSpan(style, 4, 1, md::kConcealed));
        CHECK(HasSpan(style, 9, 1, md::kConcealed));
    }
    {
        bool italic = false;
        for (const auto& span : md::AnalyzeLine(L"`a * b * c`", false).spans) {
            if (span.flags & md::kItalic) italic = true;
        }
        CHECK(!italic);
    }
    {
        std::wstring line = L"[text](https://x.y)";
        auto style = md::AnalyzeLine(line, false);
        CHECK(HasSpan(style, 0, (int)line.size(), md::kLinkSpan));
        CHECK(HasSpan(style, 0, 1, md::kConcealed));
        CHECK(HasSpan(style, 5, (int)line.size() - 5, md::kConcealed));
    }
    CHECK(HasSpan(md::AnalyzeLine(L"![alt](img.png)", false), 0, 2, md::kConcealed));
    CHECK(md::AnalyzeLine(L"> quoted", false).isQuote);

    {
        std::vector<std::wstring> lines = { L"before", L"```swift", L"let x = 1", L"```",
                                            L"after" };
        auto map = md::CodeLineMap(lines);
        CHECK(map.size() == 5 && !map[0] && map[1] && map[2] && map[3] && !map[4]);
    }
    {
        auto style = md::AnalyzeLine(L"# looks like a heading", true);
        CHECK(style.isCode && style.spans.empty() && style.headingLevel == 0);
    }
}

// MARK: - Spec corpus (robustness)

static std::string Base64Decode(const char* s)
{
    auto sextet = [](char c) -> int {
        if (c >= 'A' && c <= 'Z') return c - 'A';
        if (c >= 'a' && c <= 'z') return c - 'a' + 26;
        if (c >= '0' && c <= '9') return c - '0' + 52;
        if (c == '+') return 62;
        if (c == '/') return 63;
        return -1; // '=' padding and anything else
    };
    std::string out;
    int buffer = 0, bits = 0;
    for (const char* p = s; *p; ++p) {
        int v = sextet(*p);
        if (v < 0) continue;
        buffer = (buffer << 6) | v;
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            out.push_back(static_cast<char>((buffer >> bits) & 0xFF));
        }
    }
    return out;
}

// UTF-8 bytes -> UTF-16 wstring (surrogate pairs for astral code points), the
// same encoding the app feeds the parser after reading a file.
static std::wstring WidenUtf8(const std::string& s)
{
    std::wstring out;
    size_t i = 0, n = s.size();
    while (i < n) {
        unsigned char b = static_cast<unsigned char>(s[i]);
        unsigned int cp;
        int extra;
        if (b < 0x80) { cp = b; extra = 0; }
        else if (b >= 0xF0) { cp = b & 0x07; extra = 3; }
        else if (b >= 0xE0) { cp = b & 0x0F; extra = 2; }
        else if (b >= 0xC0) { cp = b & 0x1F; extra = 1; }
        else { cp = b; extra = 0; } // stray continuation byte, pass through
        if (i + extra >= n) extra = 0;
        for (int k = 1; k <= extra; ++k) cp = (cp << 6) | (static_cast<unsigned char>(s[i + k]) & 0x3F);
        i += extra + 1;
        if (cp > 0xFFFF) {
            cp -= 0x10000;
            out.push_back(static_cast<wchar_t>(0xD800 + (cp >> 10)));
            out.push_back(static_cast<wchar_t>(0xDC00 + (cp & 0x3FF)));
        } else {
            out.push_back(static_cast<wchar_t>(cp));
        }
    }
    return out;
}

// The parser is a GFM subset, so we don't diff against the spec's HTML; this is
// a stability suite — every CommonMark example (and the pathological nesting
// cases appended by the generator) must parse without crashing or hanging.
static void TestSpecCorpus()
{
    int processed = 0;
    for (int i = 0; i < spec::kCorpusCount; ++i) {
        std::wstring source = WidenUtf8(Base64Decode(spec::kCorpusBase64[i]));
        auto blocks = md::Parse(source);
        for (const auto& block : blocks) {
            if (block.type == md::BlockType::Paragraph || block.type == md::BlockType::Heading) {
                (void)md::PlainText(block.inlines);
            }
        }
        (void)md::PlainText(md::ParseInlines(source));
        processed++;
    }
    CHECK(processed == spec::kCorpusCount);
}

int wmain()
{
    TestParser();
    TestFormatting();
    TestDocument();
    TestStyler();
    TestSpecCorpus();
    wprintf(L"%d checks, %d failures\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
