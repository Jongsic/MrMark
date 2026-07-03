# Contributing

Thanks for your interest in MrMark! This document covers how to build, test,
and submit changes.

## Development setup

Requirements:

- macOS 14 or later
- Xcode 16 or later
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) and
  [SwiftFormat](https://github.com/nicklockwood/SwiftFormat)

```sh
brew install xcodegen swiftformat
cd macos
xcodegen generate
open MrMark.xcodeproj
```

The Xcode project is **generated** — never edit `MrMark.xcodeproj` directly.
Change [`macos/project.yml`](macos/project.yml) and re-run `xcodegen generate`.
New source files under `macos/Sources/` and `macos/Tests/` are picked up
automatically on regeneration.

## Scripts

All build/test commands run inside `macos/`; SwiftFormat runs at the repo root.

```sh
scripts/build-dmg.sh                                       # from the repo root: Release build → build/MrMark-<version>.dmg
xcodegen generate                                          # regenerate the project
xcodebuild -scheme MrMark -destination 'platform=macOS' test   # build & run tests
swiftformat .                                              # format
swiftformat --lint .                                       # what CI runs
```

## Before opening a pull request

1. `swiftformat --lint .` passes
2. `xcodebuild -scheme MrMark -destination 'platform=macOS' test` passes
3. The change respects the performance budgets (see below)

## Guidelines

- **Performance is a feature.** Budgets are hard requirements: <200ms
  perceived cold launch to viewer, <100MB per window, no full-document
  re-render per keystroke. A PR that regresses these will be asked to fix it.
- **Scope is a feature too.** MrMark deliberately has no plugins, tabs,
  sidebars, cloud, accounts, or telemetry (see the Non-goals section of the
  README). PRs adding these will be declined.
- **No new dependencies** without prior discussion in an issue. The current
  policy is: AppKit + swift-markdown (Apple's cmark-gfm wrapper), nothing else.
- Keep PRs small and focused — one logical change per PR.
- Do not include `Co-Authored-By` trailers for AI tools in commit messages.
  Attribution should be limited to human contributors.

## Testing policy

- Pure logic (parsing, source↔render mapping, formatting actions, save
  round-trips) must be unit-tested.
- UI behavior is verified manually; describe your manual test steps in the PR.

## Reporting bugs / requesting features

Use the GitHub issue templates. For bugs, include your macOS version, the app
version (About dialog), and if possible a sample `.md` file that reproduces
the problem.

## License

By contributing you agree that your contributions are licensed under the
[MIT License](LICENSE).
