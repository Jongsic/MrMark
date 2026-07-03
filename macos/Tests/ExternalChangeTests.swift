@testable import MrMark
import XCTest

/// Verifies that external file changes follow stock NSDocument behavior
/// (project decision: whenever the OS has a default behavior, follow it):
/// clean documents reload from disk automatically; documents with unsaved
/// edits keep them (the standard conflict alert appears at save time).
final class ExternalChangeTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MrMarkTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func coordinatedWrite(_ content: String, to url: URL) throws {
        var coordinatorError: NSError?
        var writeError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: url,
            options: .forReplacing,
            error: &coordinatorError
        ) { writeURL in
            do {
                try content.write(to: writeURL, atomically: true, encoding: .utf8)
            } catch {
                writeError = error
            }
        }
        if let coordinatorError { throw coordinatorError }
        if let writeError { throw writeError }
    }

    private func openDocument(at url: URL) throws -> MarkdownDocument {
        var document: MarkdownDocument?
        let opened = expectation(description: "document opened")
        NSDocumentController.shared.openDocument(withContentsOf: url, display: false) { doc, _, error in
            XCTAssertNil(error)
            document = doc as? MarkdownDocument
            opened.fulfill()
        }
        wait(for: [opened], timeout: 10)
        return try XCTUnwrap(document)
    }

    private func waitForReload(of document: MarkdownDocument, to expected: String) {
        let reloaded = expectation(description: "auto-reloaded from disk")
        let timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { timer in
            if document.text == expected {
                timer.invalidate()
                reloaded.fulfill()
            }
        }
        defer { timer.invalidate() }
        wait(for: [reloaded], timeout: 15)
    }

    func testCleanDocumentAutoReloadsOnCoordinatedWrite() throws {
        let url = directory.appendingPathComponent("coordinated.md")
        try "# before\n".write(to: url, atomically: true, encoding: .utf8)

        let document = try openDocument(at: url)
        defer { document.close() }
        XCTAssertEqual(document.text, "# before\n")

        // Like another document-based app saving the file. This path is pure
        // stock NSDocument (file presenter notification).
        try coordinatedWrite("# after\n", to: url)
        waitForReload(of: document, to: "# after\n")
    }

    func testCleanDocumentAutoReloadsOnUncoordinatedInPlaceWrite() throws {
        let url = directory.appendingPathComponent("inplace.md")
        try "# before\n".write(to: url, atomically: true, encoding: .utf8)

        let document = try openDocument(at: url)
        defer { document.close() }

        // Like `echo > file.md` or vim without 'backupcopy=no': same inode.
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data("# after\n".utf8))
        try handle.close()

        waitForReload(of: document, to: "# after\n")
    }

    func testCleanDocumentAutoReloadsOnUncoordinatedAtomicReplace() throws {
        let url = directory.appendingPathComponent("replace.md")
        try "# before\n".write(to: url, atomically: true, encoding: .utf8)

        let document = try openDocument(at: url)
        defer { document.close() }

        // Like most editors and git: write a temp file, rename it over the
        // original. The watched inode dies; exercises the re-arm path.
        try "# after\n".write(to: url, atomically: true, encoding: .utf8)
        waitForReload(of: document, to: "# after\n")
    }

    // The unsaved-edits case is deliberately NOT unit-tested: the watcher
    // refuses to touch dirty documents (guarded on isDocumentEdited) and the
    // OS surfaces the standard "changed by another application" alert at
    // save time — machinery that needs a real window + foreground app, so it
    // is verified manually.
}
