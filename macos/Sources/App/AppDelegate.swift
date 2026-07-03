import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // One file = one window: never group document windows into tabs.
        NSWindow.allowsAutomaticWindowTabbing = false
        NSApp.mainMenu = MainMenu.build()
        LaunchClock.mark("app-will-finish-launching")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `MrMark file.md` from a shell (Finder/`open` go through Apple Events
        // instead). Also what `--benchmark` timing runs use.
        for url in Self.fileArguments {
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        Self.fileArguments.isEmpty
    }

    private static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd"]

    private static var fileArguments: [URL] {
        ProcessInfo.processInfo.arguments.dropFirst().compactMap { argument in
            guard !argument.hasPrefix("-") else { return nil }
            let url = URL(fileURLWithPath: argument)
            guard markdownExtensions.contains(url.pathExtension.lowercased()),
                  FileManager.default.fileExists(atPath: url.path)
            else { return nil }
            return url
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    @objc func openGitHub(_ sender: Any?) {
        NSWorkspace.shared.open(URL(string: "https://github.com/Jongsic/MrMark")!)
    }

    @objc func setAsDefaultMarkdownApp(_ sender: Any?) {
        DefaultMarkdownApp.makeDefault(interactive: true)
    }

    @objc func showAbout(_ sender: Any?) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let alert = NSAlert()
        alert.messageText = "MrMark \(version)"
        alert.informativeText = """
        An ultra-fast, minimal Markdown viewer & editor.
        One file, one window — nothing else.

        MIT License © 2026 Jongsic and MrMark contributors
        """
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "GitHub")
        if alert.runModal() == .alertSecondButtonReturn {
            openGitHub(sender)
        }
    }
}
