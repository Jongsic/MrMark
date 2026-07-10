---
title: MrMark Feature Tour
tags:
- markdown
- viewer
- qa
status: living document
updated: 2026-07-10
note: "values with a colon: and a [x] checkbox-looking bit survive as-is"
---

# MrMark Feature Tour

A single document that exercises everything MrMark renders. Open it in the
viewer, then hit **Edit** and try the same constructs in the editor. Useful
for manual QA before a release — keep it in sync with what the renderer
supports.

---

## Headings

# H1 — The quick brown fox
## H2 — 다람쥐 헌 쳇바퀴에 타고파
### H3 — いろはにほへと ちりぬるを
#### H4 — 天地玄黃 宇宙洪荒
##### H5 — Съешь же ещё этих мягких булок
###### H6 — Portez ce vieux whisky au juge blond

## Inline styles

Plain, **bold**, *italic*, ***bold italic***, ~~strikethrough~~, and `inline code`.

한국어 **굵게**, *기울임*, ~~취소선~~, `코드` — 조합도 됩니다: **한글 *중첩* 스타일**.

日本語の**太字**と*斜体*、中文的**粗体**和*斜体*、عربى **غامق** — mixed RTL/LTR in one line.

Emoji pass-through: 🚀 ✅ 🇰🇷 👨‍👩‍👧‍👦 (ZWJ sequence), combining marks: café, ñ, 한글 + ḱṓḿḃīṉīṉḡ.

## Lists

### Bullets

- First level
- Second item with **bold** and a [link](https://example.com)
  - Nested level (한글 항목)
    - Third level（日本語の項目）
- Back to first level

### Numbered

1. One
2. Two — continues after a nested list:
   1. Two-point-one
   2. Two-point-two
3. Three

### Tasks

- [ ] Unchecked task
- [x] Checked task — should look done at a glance
- [ ] 한글 할 일 항목 with `inline code`
- [x] 済みタスク（日本語）

## Code blocks

```swift
// Swift with unicode identifiers and strings
func greet(이름: String) -> String {
    let 인사 = "안녕하세요, \(이름)!"
    return 인사 // returns a greeting
}
```

```python
# Python — indentation must survive round-trips
def fib(n: int) -> int:
    return n if n < 2 else fib(n - 1) + fib(n - 2)
```

```
Plain fenced block with no language.
  Leading spaces preserved.
	And a hard tab on this line.
```

## Links & images

- Inline link: [MrMark on GitHub](https://github.com/Jongsic/MrMark)
- Link with unicode text: [한국어 링크 텍스트](https://example.com/경로?쿼리=값)
- Autolink: <https://www.example.com>
- Local image (renders inline):

![MrMark icon](design/M.png)

- Remote image (never fetched — shown as a link by design):

![Remote placeholder](https://example.com/never-fetched.png)

## Blockquotes

> Single-level quote — 인용문은 회색으로 표시됩니다.
>
> > Nested quote, second level.
>
> Quote containing **bold**, `code`, and a [link](https://example.com).

## Table

Tables render as a borderless aligned grid — bold header, hairline rule,
columns sized to their widest cell (CJK widths measured exactly). Borders and
cell wrapping are intentionally out of scope:

| Language | Hello        | Direction |
| -------- | ------------ | --------- |
| Korean   | 안녕하세요     | LTR       |
| Arabic   | مرحبا        | RTL       |
| Japanese | こんにちは     | LTR       |

A table wider than the window (many columns, long cells) clips on the
right — rows never wrap (that would wreck the grid), and full table
layout is out of scope by design; zoom out to see more columns:

| Release | Date       | macOS Minimum | Highlights                                  | Viewer Changes                            | Editor Changes                     | Known Issues                        | Notes                       |
| ------- | ---------- | ------------- | ------------------------------------------- | ----------------------------------------- | ---------------------------------- | ----------------------------------- | --------------------------- |
| 1.0.0   | 2026-03-02 | 14.0          | First public release, viewer + lazy editor  | GFM rendering, checkboxes, 다크 모드 지원 | Formatting toolbar, source hi-lite | About dialog shows wrong version    | DMG notarized               |
| 1.2.0   | 2026-05-18 | 14.0          | CommonMark corpus tests, hardened links     | Safer link/image handling, 属性ブロック   | Checklist toggle, smart lists      | Wide tables wrap and garble         | 성능 예산 <200ms 콜드 런치  |
| 1.2.2   | 2026-07-08 | 14.0          | Windows viewer paragraph interruption fixes | Block-level HTML interrupts paragraphs    | —                                  | Frontmatter renders as setext head  | 이 표가 스크롤되는지 확인용 |

## Thematic breaks

Above the line.

---

Below the line.

## Edge cases

- Escaped markers: \*not italic\*, \`not code\`, \# not a heading
- Literal asterisks in code: `a * b * c`
- A very long unbroken line to test wrapping: Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore — 아주 긴 한 줄이 창 너비에 맞춰 잘 줄바꿈되는지 확인하는 문장입니다 — 長い行が正しく折り返されるかどうかを確認するための文章です.
- Line break with two trailing spaces:  
  this line follows a hard break.
- HTML passes through as raw source: <kbd>⌘S</kbd> and a block:

<div align="center">raw HTML block</div>
