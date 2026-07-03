import AppKit
import UniformTypeIdentifiers

/// Becoming the default app for Markdown files — never silently, ask exactly
/// once, and only after the user has actually opened a .md file. A manual
/// path stays available in the MrMark menu for anyone who changes their mind.
enum DefaultMarkdownApp {
    static let contentType = UTType(importedAs: "net.daringfireball.markdown")

    private static let askedDefaultsKey = "AskedToBecomeDefaultMarkdownApp"
    private static var scheduledThisRun = false

    static var isDefault: Bool {
        guard let currentURL = NSWorkspace.shared.urlForApplication(toOpen: contentType),
              let currentIdentifier = Bundle(url: currentURL)?.bundleIdentifier
        else { return false }
        return currentIdentifier == Bundle.main.bundleIdentifier
    }

    /// The decision, kept pure so it is unit-testable apart from system state.
    static func shouldOffer(hasFileURL: Bool, alreadyAsked: Bool, alreadyDefault: Bool) -> Bool {
        hasFileURL && !alreadyAsked && !alreadyDefault
    }

    /// One-time offer, triggered when a real file document is shown
    /// (untitled documents don't count — no user intent yet).
    static func offerIfAppropriate(for document: NSDocument) {
        guard !scheduledThisRun,
              !ProcessInfo.processInfo.arguments.contains("--benchmark"),
              shouldOffer(
                  hasFileURL: document.fileURL != nil,
                  alreadyAsked: UserDefaults.standard.bool(forKey: askedDefaultsKey),
                  alreadyDefault: isDefault
              )
        else { return }
        scheduledThisRun = true

        // Let the document window settle before putting up a modal.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            // Whatever the answer, never ask again.
            UserDefaults.standard.set(true, forKey: askedDefaultsKey)

            let alert = NSAlert()
            alert.messageText = "Use MrMark for Markdown files?"
            alert.informativeText = """
            Make MrMark the default application for opening .md files. \
            You can change this anytime in Finder's Get Info panel, \
            or later via the MrMark menu.
            """
            alert.addButton(withTitle: "Set as Default")
            alert.addButton(withTitle: "No Thanks")
            if alert.runModal() == .alertFirstButtonReturn {
                makeDefault(interactive: false)
            }
        }
    }

    /// `interactive` adds explicit feedback (the MrMark ▸ Set as Default…
    /// menu path); errors are always surfaced.
    static func makeDefault(interactive: Bool) {
        if interactive, isDefault {
            let alert = NSAlert()
            alert.messageText = "MrMark is already the default app for Markdown files."
            alert.runModal()
            return
        }
        NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: contentType) { error in
            DispatchQueue.main.async {
                let alert = NSAlert()
                if let error {
                    alert.alertStyle = .warning
                    alert.messageText = "Couldn't set the default app"
                    alert.informativeText = error.localizedDescription
                } else if interactive {
                    alert.messageText = "MrMark is now the default app for Markdown files."
                } else {
                    return
                }
                alert.runModal()
            }
        }
    }
}
