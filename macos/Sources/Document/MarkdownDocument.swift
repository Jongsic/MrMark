import AppKit

/// Both the viewer and the editor can present a document and refresh from it.
protocol DocumentContentController: AnyObject {
    func reload()
}

/// One Markdown file. NSDocument provides file association, dirty tracking,
/// the close-with-unsaved-changes prompt, Cmd+S, the title-bar file name,
/// window restoration, and changed-on-disk detection.
///
/// Saving is manual by policy — no autosave. `autosavesInPlace == false`
/// gives the classic OS behavior: edits stay in memory until the user saves,
/// and closing a dirty document asks Save / Cancel / Don't Save.
final class MarkdownDocument: NSDocument {
    private(set) var text: String = ""

    /// Windows line endings / UTF-8 BOM are normalized away for editing and
    /// restored byte-exactly on save, so opening + saving never rewrites a
    /// file's encoding conventions.
    private var usesCRLF = false
    private var hasBOM = false
    private static let utf8BOM: [UInt8] = [0xEF, 0xBB, 0xBF]

    override class var autosavesInPlace: Bool {
        false
    }

    override var displayName: String! {
        get { fileURL == nil ? "Untitled.md" : super.displayName }
        set { super.displayName = newValue }
    }

    override func makeWindowControllers() {
        addWindowController(DocumentWindowController(document: self))
    }

    override func read(from data: Data, ofType typeName: String) throws {
        var data = data
        hasBOM = data.starts(with: Self.utf8BOM)
        if hasBOM {
            data = data.dropFirst(Self.utf8BOM.count)
        }
        guard let string = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        usesCRLF = string.contains("\r\n")
        text = usesCRLF ? string.replacingOccurrences(of: "\r\n", with: "\n") : string
        LaunchClock.mark("document-read")
        refreshContentControllers()
    }

    override func data(ofType typeName: String) throws -> Data {
        let output = usesCRLF ? text.replacingOccurrences(of: "\n", with: "\r\n") : text
        var data = hasBOM ? Data(Self.utf8BOM) : Data()
        data.append(contentsOf: output.utf8)
        return data
    }

    /// Windows already exist when reading again (e.g. Revert to Saved,
    /// external-change reload).
    private func refreshContentControllers() {
        for controller in windowControllers {
            (controller.contentViewController as? DocumentContentController)?.reload()
        }
    }

    /// Called by the editor on every change; undo (and therefore dirty state)
    /// is already routed through this document's undoManager.
    func editorTextDidChange(_ newText: String) {
        text = newText
    }

    // MARK: - Checkbox toggling (viewer)

    /// Flips `- [ ]` ↔ `- [x]` on the given 1-based source line, with undo.
    /// Like any other edit it only marks the document dirty — saving is
    /// manual (⌘S), and closing prompts if the toggle is unsaved.
    func toggleCheckbox(atSourceLine line: Int) {
        var lines = text.components(separatedBy: "\n")
        guard line >= 1, line <= lines.count else { return }
        let toggled = Self.togglingCheckboxMarker(in: lines[line - 1])
        guard toggled != lines[line - 1] else { return }
        lines[line - 1] = toggled
        setTextUndoable(lines.joined(separator: "\n"))
    }

    static func togglingCheckboxMarker(in line: String) -> String {
        guard let range = line.range(of: #"\[( |x|X)\]"#, options: .regularExpression) else {
            return line
        }
        let replacement = line[range] == "[ ]" ? "[x]" : "[ ]"
        return line.replacingCharacters(in: range, with: replacement)
    }

    /// Undoable text replacement with explicit change counting — NSDocument's
    /// undo-driven dirty tracking is not reliable outside window-hosted
    /// editing, so the change count is updated by hand. The explicit group
    /// closes synchronously, which keeps an immediate undo() working.
    private func setTextUndoable(_ newText: String) {
        guard newText != text else { return }
        let previous = text
        let needsGroup = undoManager.map { $0.groupingLevel == 0 } ?? false
        if needsGroup { undoManager?.beginUndoGrouping() }
        undoManager?.registerUndo(withTarget: self) { document in
            document.setTextUndoable(previous)
        }
        if needsGroup { undoManager?.endUndoGrouping() }

        let changeKind: NSDocument.ChangeType = if undoManager?.isUndoing == true {
            .changeUndone
        } else if undoManager?.isRedoing == true {
            .changeRedone
        } else {
            .changeDone
        }
        updateChangeCount(changeKind)

        text = newText
        refreshContentControllers()
    }

    // MARK: - External writers (other apps, vim, git, scripts, …)

    // Reload silently while the document is clean; never touch unsaved
    // edits — the standard save-time conflict alert owns that case.
    // Detection is belt and suspenders: file-presenter notifications cover
    // coordinated writers (other document-based apps), and a kqueue watcher
    // covers everyone else (vim, git, scripts) plus any missed coordination.

    private var fileWatcher: DispatchSourceFileSystemObject?
    private var externalChangeCheck: DispatchWorkItem?

    override func presentedItemDidChange() {
        super.presentedItemDidChange()
        DispatchQueue.main.async { [weak self] in
            self?.scheduleExternalChangeCheck()
        }
    }

    override var fileURL: URL? {
        didSet {
            DispatchQueue.main.async { [weak self] in
                self?.startWatchingFile()
            }
        }
    }

    override func close() {
        externalChangeCheck?.cancel()
        fileWatcher?.cancel()
        fileWatcher = nil
        super.close()
    }

    deinit {
        externalChangeCheck?.cancel()
        fileWatcher?.cancel()
    }

    private func startWatchingFile() {
        fileWatcher?.cancel()
        fileWatcher = nil
        guard let path = fileURL?.path else { return }

        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let watcher = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .rename, .delete],
            queue: .main
        )
        watcher.setEventHandler { [weak self] in
            self?.scheduleExternalChangeCheck()
        }
        watcher.setCancelHandler {
            Darwin.close(descriptor)
        }
        watcher.resume()
        fileWatcher = watcher
    }

    /// Editors often produce several events per save (or replace the file,
    /// leaving the watcher on a dead inode) — debounce, then check and re-arm.
    private func scheduleExternalChangeCheck() {
        externalChangeCheck?.cancel()
        let check = DispatchWorkItem { [weak self] in
            self?.reloadIfChangedExternally()
            self?.startWatchingFile()
        }
        externalChangeCheck = check
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: check)
    }

    private func reloadIfChangedExternally() {
        guard let fileURL else { return }
        // Unsaved edits: hands off, exactly like the OS (conflict surfaces on save).
        guard !isDocumentEdited, !hasUnautosavedChanges else { return }
        guard
            let diskDate = (try? FileManager.default
                .attributesOfItem(atPath: fileURL.path))?[.modificationDate] as? Date,
            let knownDate = fileModificationDate,
            diskDate != knownDate
        else { return }

        do {
            try revert(toContentsOf: fileURL, ofType: fileType ?? "net.daringfireball.markdown")
        } catch {
            // Mid-rewrite or momentarily unreadable; the next event retries.
        }
    }
}
