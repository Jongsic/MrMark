import AppKit

/// Owns the document window, its mode (viewer ↔ editor), and the matching
/// minimal toolbar. The window opens in viewer mode; the editor — and all of
/// its machinery — is created only when the user asks for it.
final class DocumentWindowController: NSWindowController, NSToolbarDelegate {
    private enum Mode: String {
        case viewer
        case editor
    }

    private enum ItemIdentifier {
        // Viewer
        static let zoom = NSToolbarItem.Identifier("mrmark.zoom")
        // Editor
        static let save = NSToolbarItem.Identifier("mrmark.save")
        static let undo = NSToolbarItem.Identifier("mrmark.undo")
        static let redo = NSToolbarItem.Identifier("mrmark.redo")
        static let bold = NSToolbarItem.Identifier("mrmark.bold")
        static let italic = NSToolbarItem.Identifier("mrmark.italic")
        static let heading1 = NSToolbarItem.Identifier("mrmark.h1")
        static let heading2 = NSToolbarItem.Identifier("mrmark.h2")
        static let heading3 = NSToolbarItem.Identifier("mrmark.h3")
        static let bullet = NSToolbarItem.Identifier("mrmark.bullet")
        static let numbered = NSToolbarItem.Identifier("mrmark.numbered")
        static let checklist = NSToolbarItem.Identifier("mrmark.checklist")
        static let link = NSToolbarItem.Identifier("mrmark.link")
        static let image = NSToolbarItem.Identifier("mrmark.image")
        static let codeBlock = NSToolbarItem.Identifier("mrmark.codeBlock")
    }

    /// NSDocument sets NSWindowController.document in addWindowController(_:).
    private var markdownDocument: MarkdownDocument? {
        document as? MarkdownDocument
    }

    /// This window's zoom. Survives viewer↔editor round trips, but is never
    /// persisted — new windows start at 100%.
    private var viewerZoom: CGFloat = 1
    private weak var zoomControl: ZoomControlView?
    private weak var modeToggleButton: NSButton?

    convenience init(document: MarkdownDocument) {
        let viewer = ViewerViewController(document: document)
        let window = NSWindow(contentViewController: viewer)
        window.setContentSize(NSSize(width: 760, height: 820))
        window.tabbingMode = .disallowed
        window.toolbarStyle = .unifiedCompact
        window.center()
        window.setFrameAutosaveName("MrMarkDocumentWindow")
        self.init(window: window)
        wireZoom(of: viewer)
        window.toolbar = makeToolbar(.viewer)
        // Mode toggle + About live in a trailing titlebar accessory, not the
        // toolbar: they stay pinned at the far right, and the toolbar's
        // overflow chevron (») appears to their LEFT when the window narrows.
        window.addTitlebarAccessoryViewController(makeTrailingAccessory())

        // A brand-new document has nothing to view — start writing. The
        // switch happens in `document`'s didSet: NSDocument only sets it
        // via addWindowController(_:), after this init returns.
        startsInEditMode = document.fileURL == nil
    }

    private var startsInEditMode = false

    override var document: AnyObject? {
        didSet {
            if startsInEditMode, markdownDocument != nil {
                startsInEditMode = false
                enterEditMode(nil)
            }
        }
    }

    // MARK: - Trailing titlebar accessory (mode toggle + About)

    private func makeTrailingAccessory() -> NSTitlebarAccessoryViewController {
        let toggle = NSButton(
            image: NSImage(systemSymbolName: "pencil", accessibilityDescription: "Edit")!,
            target: self,
            action: #selector(toggleMode(_:))
        )
        toggle.bezelStyle = .texturedRounded
        toggle.toolTip = "Edit this document"

        let about = NSButton(
            image: NSImage(systemSymbolName: "info.circle", accessibilityDescription: "About")!,
            target: nil,
            action: #selector(AppDelegate.showAbout(_:))
        )
        about.bezelStyle = .texturedRounded
        about.toolTip = "About MrMark"

        let stack = NSStackView(views: [toggle, about])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 10)
        stack.frame = NSRect(origin: .zero, size: stack.fittingSize)

        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = stack
        accessory.layoutAttribute = .trailing
        modeToggleButton = toggle
        return accessory
    }

    @objc func toggleMode(_ sender: Any?) {
        if contentViewController is EditorViewController {
            enterViewMode(sender)
        } else {
            enterEditMode(sender)
        }
    }

    private func wireZoom(of content: ZoomableContent) {
        content.onZoomChanged = { [weak self] scale in
            self?.viewerZoom = scale
            self?.zoomControl?.setDisplayedZoom(scale)
        }
    }

    // MARK: - Mode switching

    @objc func enterEditMode(_ sender: Any?) {
        switchContent(to: .editor)
    }

    @objc func enterViewMode(_ sender: Any?) {
        switchContent(to: .viewer)
    }

    private func switchContent(to mode: Mode) {
        guard let document = markdownDocument, let window else { return }
        switch mode {
        case .viewer:
            guard !(contentViewController is ViewerViewController) else { return }
        case .editor:
            guard !(contentViewController is EditorViewController) else { return }
        }

        // Swapping contentViewController must not move or resize the window.
        let frame = window.frame
        switch mode {
        case .viewer:
            let viewer = ViewerViewController(document: document)
            viewer.setZoomScale(viewerZoom) // this window's zoom survives the round trip
            wireZoom(of: viewer)
            contentViewController = viewer
        case .editor:
            let editor = EditorViewController(document: document)
            editor.setZoomScale(viewerZoom)
            wireZoom(of: editor)
            contentViewController = editor
        }
        window.setFrame(frame, display: true)
        window.toolbar = makeToolbar(mode)

        let isEditor = mode == .editor
        modeToggleButton?.image = NSImage(
            systemSymbolName: isEditor ? "eye" : "pencil",
            accessibilityDescription: isEditor ? "View" : "Edit"
        )
        modeToggleButton?.toolTip = isEditor ? "Back to the reading view" : "Edit this document"
    }

    // MARK: - Toolbars

    private func makeToolbar(_ mode: Mode) -> NSToolbar {
        let toolbar = NSToolbar(identifier: "mrmark.toolbar.\(mode.rawValue)")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        return toolbar
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        if toolbar.identifier == "mrmark.toolbar.editor" {
            return [
                // Document group: zoom + save, set apart from the editing tools.
                ItemIdentifier.zoom, ItemIdentifier.save,
                .space,
                ItemIdentifier.undo, ItemIdentifier.redo,
                ItemIdentifier.bold, ItemIdentifier.italic,
                ItemIdentifier.heading1, ItemIdentifier.heading2, ItemIdentifier.heading3,
                ItemIdentifier.bullet, ItemIdentifier.numbered, ItemIdentifier.checklist,
                ItemIdentifier.link, ItemIdentifier.image, ItemIdentifier.codeBlock,
            ]
        }
        return [ItemIdentifier.zoom]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        // Viewer
        case ItemIdentifier.zoom:
            // Collapses with the tools in edit mode, but not in the viewer.
            zoomControlItem(
                itemIdentifier,
                priority: toolbar.identifier == "mrmark.toolbar.editor" ? .low : .standard
            )
        // Editor
        case ItemIdentifier.save:
            button(itemIdentifier, symbol: "square.and.arrow.down", label: "Save",
                   tooltip: "Save (⌘S)", action: #selector(NSDocument.save(_:)))
        case ItemIdentifier.undo:
            button(itemIdentifier, symbol: "arrow.uturn.backward", label: "Undo",
                   tooltip: "Undo (⌘Z)", action: Selector(("undo:")))
        case ItemIdentifier.redo:
            button(itemIdentifier, symbol: "arrow.uturn.forward", label: "Redo",
                   tooltip: "Redo (⇧⌘Z)", action: Selector(("redo:")))
        case ItemIdentifier.bold:
            button(itemIdentifier, symbol: "bold", label: "Bold",
                   tooltip: "Bold (⌘B)", action: #selector(EditorViewController.toggleBold(_:)), priority: .low)
        case ItemIdentifier.italic:
            button(itemIdentifier, symbol: "italic", label: "Italic",
                   tooltip: "Italic (⌘I)", action: #selector(EditorViewController.toggleItalic(_:)), priority: .low)
        case ItemIdentifier.heading1:
            textButton(itemIdentifier, title: "H1", tooltip: "Heading 1 (⌘1)",
                       action: #selector(EditorViewController.heading1(_:)), priority: .low)
        case ItemIdentifier.heading2:
            textButton(itemIdentifier, title: "H2", tooltip: "Heading 2 (⌘2)",
                       action: #selector(EditorViewController.heading2(_:)), priority: .low)
        case ItemIdentifier.heading3:
            textButton(itemIdentifier, title: "H3", tooltip: "Heading 3 (⌘3)",
                       action: #selector(EditorViewController.heading3(_:)), priority: .low)
        case ItemIdentifier.bullet:
            button(itemIdentifier, symbol: "list.bullet", label: "Bullet List",
                   tooltip: "Bullet list", action: #selector(EditorViewController.toggleBulletList(_:)), priority: .low)
        case ItemIdentifier.numbered:
            button(itemIdentifier, symbol: "list.number", label: "Numbered List",
                   tooltip: "Numbered list", action: #selector(EditorViewController.toggleNumberedList(_:)),
                   priority: .low)
        case ItemIdentifier.checklist:
            button(itemIdentifier, symbol: "checklist", label: "Checklist",
                   tooltip: "Checklist", action: #selector(EditorViewController.toggleChecklist(_:)), priority: .low)
        case ItemIdentifier.link:
            button(itemIdentifier, symbol: "link", label: "Link",
                   tooltip: "Insert link (⌘K)", action: #selector(EditorViewController.insertLink(_:)), priority: .low)
        case ItemIdentifier.image:
            button(itemIdentifier, symbol: "photo", label: "Image",
                   tooltip: "Insert image", action: #selector(EditorViewController.insertImage(_:)), priority: .low)
        case ItemIdentifier.codeBlock:
            button(itemIdentifier, symbol: "curlybraces", label: "Code Block",
                   tooltip: "Code block", action: #selector(EditorViewController.insertCodeBlock(_:)), priority: .low)
        default:
            nil
        }
    }

    private func zoomControlItem(
        _ identifier: NSToolbarItem.Identifier,
        priority: NSToolbarItem.VisibilityPriority
    ) -> NSToolbarItem {
        let control = ZoomControlView(
            minimum: TextZoom.minimum,
            maximum: TextZoom.maximum,
            step: TextZoom.step
        )
        control.setDisplayedZoom(viewerZoom)
        control.onZoomChange = { [weak self] scale in
            (self?.contentViewController as? ZoomableContent)?.setZoomScale(scale)
        }
        zoomControl = control

        let item = NSToolbarItem(itemIdentifier: identifier)
        item.view = control
        item.label = "Zoom"
        item.visibilityPriority = priority
        return item
    }

    private func button(
        _ identifier: NSToolbarItem.Identifier, symbol: String, label: String,
        tooltip: String, action: Selector?,
        priority: NSToolbarItem.VisibilityPriority = .standard
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.label = label
        item.toolTip = tooltip
        item.isBordered = true
        item.autovalidates = false
        item.action = action
        item.visibilityPriority = priority
        return item
    }

    private func textButton(
        _ identifier: NSToolbarItem.Identifier, title: String, tooltip: String, action: Selector?,
        priority: NSToolbarItem.VisibilityPriority = .standard
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.title = title
        item.label = title
        item.toolTip = tooltip
        item.isBordered = true
        item.autovalidates = false
        item.action = action
        item.visibilityPriority = priority
        return item
    }
}
