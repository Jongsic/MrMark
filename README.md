# MrMark

[![CI](https://github.com/Jongsic/MrMark/actions/workflows/ci.yml/badge.svg)](https://github.com/Jongsic/MrMark/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/Jongsic/MrMark)](https://github.com/Jongsic/MrMark/releases)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black)

An **ultra-fast, minimal Markdown viewer & editor** for macOS.
Native Swift + AppKit + TextKit 2 — not Electron, not a webview.
One file = one window. No workspace, no tabs, no plugins, no cloud, no telemetry.

![MrMark](preview.gif)

Double-clicking a `.md` file shows a rendered, read-only view instantly.
Hit ✏️ to edit; hit 👁 to go back to reading. That's the whole app.

## Features

**Viewer (the fast path)**
- GitHub-flavored Markdown: headings, bold/italic/strikethrough, lists,
  blockquotes, fenced code blocks, inline code, links, images, tables
  (rendered as a borderless aligned grid)
- Task-list checkboxes are clickable — toggling writes `- [ ]` ↔ `- [x]`
  back to the file (undoable)
- Local images render inline; **remote images are never fetched**
- ⌘F find bar, text zoom (⌘+/⌘−/⌘0, pinch, ⌘+scroll), dark mode

**Editor**
- Hybrid, Typora-style: the paragraph you're editing shows its Markdown
  source; everywhere else the syntax markers (`#`, `**`, backticks, link
  URLs) melt away and you read styled text. What you save is exactly the
  Markdown you wrote
- Formatting toolbar: bold, italic, H1–H3, bullet/numbered/task lists, link,
  image, code block — plus undo/redo and save
- Incremental restyling: only the edited block is re-highlighted, so typing
  stays smooth in 10k-line files

**Files, handled like a native Mac app**
- Manual save, exactly like classic Mac documents: ⌘S / toolbar button,
  dirty indicator, a Save/Don't Save prompt when closing unsaved changes
- Open Recent, window restoration; new documents open straight into the editor
- Edited outside MrMark (another editor, git, a script)? A clean document
  reloads automatically; unsaved edits are never touched and conflicts
  surface through the standard macOS alert on save
- Windows line endings (CRLF) and UTF-8 BOM survive open + save byte-exactly
- Offers **once** to become your default Markdown app — never silently, and
  never asks twice (also available anytime via the MrMark menu)

## Performance

Measured on an Apple Silicon Mac, release build:

| | |
|---|---|
| Cold launch → readable document | ~250ms (content paints at ~165ms even for a 10k-line file) |
| Memory (`phys_footprint`) | ~25MB per window |
| App size | well under 1MB |

Large documents render off the main thread behind an instant plain-text first
paint; TextKit 2 lays out only the visible viewport. Reproduce the numbers
yourself: `MrMark --benchmark file.md` from a shell prints a stage breakdown.

## Install

Grab the `.dmg` from [Releases](https://github.com/Jongsic/MrMark/releases)
and drag MrMark into Applications.

> Builds are not notarized yet — on first launch, right-click the app and
> choose **Open**.

## Build from source

Requirements: macOS 14+, Xcode 16+, [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
cd macos
xcodegen generate
open MrMark.xcodeproj    # or:
xcodebuild -scheme MrMark -configuration Release build
```

The `.xcodeproj` is generated from [`macos/project.yml`](macos/project.yml)
and is not checked in. Dependencies: AppKit +
[swift-markdown](https://github.com/swiftlang/swift-markdown) (Apple's
cmark-gfm wrapper). That's the whole list.

## Non-goals

MrMark is deliberately small. There will be no plugins, tabs, sidebars, file
trees, split preview, cloud sync, accounts, AI, export suites, or telemetry.
If you need a knowledge system, this isn't it — it's the fast little app you
point `.md` files at.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Bug reports and small, focused PRs
are welcome; performance regressions and scope creep are the two things that
get a PR declined.

## License

[MIT](LICENSE)
