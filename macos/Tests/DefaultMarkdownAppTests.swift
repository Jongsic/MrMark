@testable import MrMark
import XCTest

final class DefaultMarkdownAppTests: XCTestCase {
    func testOffersOnlyForRealFilesNeverAskedNotYetDefault() {
        XCTAssertTrue(DefaultMarkdownApp.shouldOffer(
            hasFileURL: true, alreadyAsked: false, alreadyDefault: false
        ))
    }

    func testNeverOffersForUntitledDocuments() {
        XCTAssertFalse(DefaultMarkdownApp.shouldOffer(
            hasFileURL: false, alreadyAsked: false, alreadyDefault: false
        ))
    }

    func testNeverAsksTwice() {
        XCTAssertFalse(DefaultMarkdownApp.shouldOffer(
            hasFileURL: true, alreadyAsked: true, alreadyDefault: false
        ))
    }

    func testNeverOffersWhenAlreadyDefault() {
        XCTAssertFalse(DefaultMarkdownApp.shouldOffer(
            hasFileURL: true, alreadyAsked: false, alreadyDefault: true
        ))
    }

    func testMarkdownContentTypeCoversTheCommonExtensions() {
        XCTAssertEqual(DefaultMarkdownApp.contentType.identifier, "net.daringfireball.markdown")
        // macOS ships its own declaration of this UTI, which wins over our
        // imported one and only tags md/markdown — the extensions that matter.
        for ext in ["md", "markdown"] {
            XCTAssertTrue(
                DefaultMarkdownApp.contentType.tags[.filenameExtension]?.contains(ext) ?? false,
                "\(ext) should map to the markdown UTI"
            )
        }
    }
}
