@testable import MrMark
import XCTest

final class FrontmatterTests: XCTestCase {
    func testExtractsFlatProperties() throws {
        let parsed = try XCTUnwrap(extractFrontmatter("---\nname: foo\ndesc: bar baz\n---\n\n# Body"))
        let props = try XCTUnwrap(parsed.properties)
        XCTAssertEqual(props.count, 2)
        XCTAssertEqual(props[0].key, "name")
        XCTAssertEqual(props[0].value, "foo")
        XCTAssertEqual(props[1].key, "desc")
        XCTAssertEqual(props[1].value, "bar baz")
        XCTAssertTrue(parsed.body.contains("# Body"))
        XCTAssertFalse(parsed.body.contains("name"))
    }

    func testKeyWithBlockSequenceValue() throws {
        let props = try XCTUnwrap(extractFrontmatter("---\ntriggers:\n- alpha\n- beta\nname: x\n---\nbody")?.properties)
        XCTAssertEqual(props[0].key, "triggers")
        XCTAssertEqual(props[0].value, "alpha, beta")
        XCTAssertEqual(props[1].key, "name")
        XCTAssertEqual(props[1].value, "x")
    }

    func testIndentedBlockSequenceValue() throws {
        let props = try XCTUnwrap(extractFrontmatter("---\ntriggers:\n  - alpha\n  - beta\n---\nbody")?.properties)
        XCTAssertEqual(props[0].value, "alpha, beta")
    }

    func testValueWithColonKeepsRemainder() throws {
        let props = try XCTUnwrap(extractFrontmatter("---\nhint: \"a: b [x]\"\n---\nbody")?.properties)
        XCTAssertEqual(props[0].key, "hint")
        XCTAssertEqual(props[0].value, "\"a: b [x]\"")
    }

    func testNoClosingFenceReturnsNil() {
        XCTAssertNil(extractFrontmatter("---\nname: foo\n\nbody without closing fence"))
    }

    func testFrontmatterMustStartAtFirstLine() {
        XCTAssertNil(extractFrontmatter("intro\n---\nname: foo\n---\nbody"))
    }

    func testMarkdownBetweenThematicBreaksIsNotFrontmatter() {
        // A document opening with a horizontal rule and containing another one
        // later must stay Markdown, not collapse into a verbatim blob.
        XCTAssertNil(extractFrontmatter("---\n\n# Title\n\nSome prose between two rules.\n\n---\nmore text"))
    }

    func testProseParagraphWithColonIsNotFrontmatter() {
        // "Note: …" prose between two rules contains a colon on every non-empty
        // line; the blank lines around the paragraph are what give it away.
        XCTAssertNil(extractFrontmatter("---\n\nNote: this document matters.\n\n---\n\n# Heading\n"))
    }

    func testLeadingBulletListIsNotFrontmatter() {
        // A frontmatter mapping opens with `key:` — a `- ` item first means a
        // Markdown list between two rules.
        XCTAssertNil(extractFrontmatter("---\n- first\n- second\n---\n\nbody"))
    }

    func testBlankLineInsideBlockDisqualifies() {
        XCTAssertNil(extractFrontmatter("---\ntitle: x\n\nauthor: y\n---\nbody"))
    }

    func testEmptyBlockIsNotFrontmatter() {
        // `---` directly followed by `---` reads as two thematic breaks.
        XCTAssertNil(extractFrontmatter("---\n---\nbody"))
    }

    func testLineOffsetCountsPeeledLines() throws {
        let parsed = try XCTUnwrap(extractFrontmatter("---\nname: foo\ndesc: bar\n---\nbody"))
        XCTAssertEqual(parsed.lineOffset, 4, "opening fence + two block lines + closing fence")
    }

    func testNestedMapFallsBackToVerbatim() throws {
        let parsed = try XCTUnwrap(extractFrontmatter("---\nmeta:\n  nested: value\n---\nbody"))
        XCTAssertNil(parsed.properties, "a nested map isn't a flat key/value map")
        XCTAssertTrue(parsed.rawBlock.contains("nested: value"))
        XCTAssertEqual(parsed.body, "body")
    }

    func testClosingDotsFence() throws {
        let parsed = try XCTUnwrap(extractFrontmatter("---\nname: foo\n...\nbody"))
        XCTAssertEqual(parsed.properties?.first?.key, "name")
        XCTAssertEqual(parsed.body, "body")
    }

    func testBodyEmptyWhenFenceIsLastLine() throws {
        let parsed = try XCTUnwrap(extractFrontmatter("---\nname: foo\n---"))
        XCTAssertEqual(parsed.body, "")
        XCTAssertEqual(parsed.properties?.first?.value, "foo")
    }
}
