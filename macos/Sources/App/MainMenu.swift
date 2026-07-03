import AppKit

/// Programmatic main menu — no storyboards/xibs, so nothing is decoded at launch.
enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()
        main.addItem(wrap(appMenu()))
        main.addItem(wrap(fileMenu()))
        main.addItem(wrap(editMenu()))
        main.addItem(wrap(formatMenu()))
        main.addItem(wrap(viewMenu()))
        main.addItem(wrap(windowMenu()))
        main.addItem(wrap(helpMenu()))
        return main
    }

    private static func wrap(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem()
        item.submenu = menu
        return item
    }

    private static func appMenu() -> NSMenu {
        let menu = NSMenu(title: "MrMark")
        menu.addItem(
            withTitle: "About MrMark",
            action: #selector(AppDelegate.showAbout(_:)),
            keyEquivalent: ""
        )
        menu.addItem(
            withTitle: "Set as Default Markdown App…",
            action: #selector(AppDelegate.setAsDefaultMarkdownApp(_:)),
            keyEquivalent: ""
        )
        menu.addItem(.separator())
        menu.addItem(withTitle: "Hide MrMark", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = menu.addItem(
            withTitle: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(
            withTitle: "Show All",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        )
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit MrMark", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    private static func fileMenu() -> NSMenu {
        let menu = NSMenu(title: "File")
        menu.addItem(withTitle: "New", action: #selector(NSDocumentController.newDocument(_:)), keyEquivalent: "n")
        // AppKit automatically inserts the "Open Recent" submenu (with Clear
        // Menu) right after the item wired to openDocument(_:) — don't add one.
        menu.addItem(withTitle: "Open…", action: #selector(NSDocumentController.openDocument(_:)), keyEquivalent: "o")

        menu.addItem(.separator())
        menu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        menu.addItem(withTitle: "Save", action: #selector(NSDocument.save(_:)), keyEquivalent: "s")
        menu.addItem(withTitle: "Save As…", action: #selector(NSDocument.saveAs(_:)), keyEquivalent: "S")
        menu.addItem(withTitle: "Revert to Saved", action: #selector(NSDocument.revertToSaved(_:)), keyEquivalent: "")
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        menu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        menu.addItem(.separator())

        let find = NSMenu(title: "Find")
        find.addItem(finderItem("Find…", key: "f", action: .showFindInterface))
        find.addItem(finderItem("Find Next", key: "g", action: .nextMatch))
        find.addItem(finderItem("Find Previous", key: "G", action: .previousMatch))
        find.addItem(finderItem("Use Selection for Find", key: "e", action: .setSearchString))
        let findItem = NSMenuItem(title: "Find", action: nil, keyEquivalent: "")
        findItem.submenu = find
        menu.addItem(findItem)
        return menu
    }

    private static func finderItem(_ title: String, key: String, action: NSTextFinder.Action) -> NSMenuItem {
        let item = NSMenuItem(
            title: title,
            action: #selector(NSResponder.performTextFinderAction(_:)),
            keyEquivalent: key
        )
        item.tag = action.rawValue
        return item
    }

    private static func formatMenu() -> NSMenu {
        let menu = NSMenu(title: "Format")
        menu.addItem(withTitle: "Bold", action: #selector(EditorViewController.toggleBold(_:)), keyEquivalent: "b")
        menu.addItem(withTitle: "Italic", action: #selector(EditorViewController.toggleItalic(_:)), keyEquivalent: "i")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Heading 1", action: #selector(EditorViewController.heading1(_:)), keyEquivalent: "1")
        menu.addItem(withTitle: "Heading 2", action: #selector(EditorViewController.heading2(_:)), keyEquivalent: "2")
        menu.addItem(withTitle: "Heading 3", action: #selector(EditorViewController.heading3(_:)), keyEquivalent: "3")
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Bullet List",
            action: #selector(EditorViewController.toggleBulletList(_:)),
            keyEquivalent: ""
        )
        menu.addItem(
            withTitle: "Numbered List",
            action: #selector(EditorViewController.toggleNumberedList(_:)),
            keyEquivalent: ""
        )
        menu.addItem(
            withTitle: "Checklist",
            action: #selector(EditorViewController.toggleChecklist(_:)),
            keyEquivalent: ""
        )
        menu.addItem(.separator())
        menu.addItem(withTitle: "Link", action: #selector(EditorViewController.insertLink(_:)), keyEquivalent: "k")
        menu.addItem(withTitle: "Image", action: #selector(EditorViewController.insertImage(_:)), keyEquivalent: "")
        menu.addItem(
            withTitle: "Code Block",
            action: #selector(EditorViewController.insertCodeBlock(_:)),
            keyEquivalent: ""
        )
        return menu
    }

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: "View")
        menu.addItem(withTitle: "Zoom In", action: #selector(ViewerViewController.zoomIn(_:)), keyEquivalent: "+")
        // ⌘= zooms in too, so no shift is needed on layouts where + lives on =.
        let zoomInAlternate = menu.addItem(
            withTitle: "Zoom In",
            action: #selector(ViewerViewController.zoomIn(_:)),
            keyEquivalent: "="
        )
        zoomInAlternate.isHidden = true
        zoomInAlternate.allowsKeyEquivalentWhenHidden = true
        menu.addItem(withTitle: "Zoom Out", action: #selector(ViewerViewController.zoomOut(_:)), keyEquivalent: "-")
        menu.addItem(
            withTitle: "Actual Size",
            action: #selector(ViewerViewController.resetZoom(_:)),
            keyEquivalent: "0"
        )
        menu.addItem(.separator())
        let fullScreen = menu.addItem(
            withTitle: "Enter Full Screen",
            action: #selector(NSWindow.toggleFullScreen(_:)),
            keyEquivalent: "f"
        )
        fullScreen.keyEquivalentModifierMask = [.command, .control]
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        menu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Bring All to Front",
            action: #selector(NSApplication.arrangeInFront(_:)),
            keyEquivalent: ""
        )
        NSApp.windowsMenu = menu
        return menu
    }

    private static func helpMenu() -> NSMenu {
        let menu = NSMenu(title: "Help")
        menu.addItem(
            withTitle: "MrMark on GitHub",
            action: #selector(AppDelegate.openGitHub(_:)),
            keyEquivalent: ""
        )
        NSApp.helpMenu = menu
        return menu
    }
}
