# Security Policy

## Security model

MrMark is a **local-only** desktop application:

- It makes **no network requests**. There is no telemetry, no update pinging,
  no account system, and no cloud sync.
- It reads and writes only the files you explicitly open (or drag onto it).
- Remote images referenced in a Markdown document are **not** fetched
  automatically.

## Reporting a vulnerability

If you discover a security issue in MrMark itself (e.g. a crash or memory
corruption triggered by a crafted `.md` file), please report it privately via
GitHub's **"Report a vulnerability"** (Security advisories) on the repository,
rather than opening a public issue.

Only the latest release and the default branch are supported.

## Disclaimer

MrMark is provided **"AS IS"**, without warranty of any kind, under the
[MIT License](LICENSE).
