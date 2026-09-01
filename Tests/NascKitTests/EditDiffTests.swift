import XCTest

@testable import NascKit

final class EditDiffTests: XCTestCase {
    func testParsesAnEditFileDiff() {
        let d = EditDiff.parse("edited a.txt (+1 -1)\n\n- BETA\n+ delta")

        XCTAssertEqual(d?.summary, "edited a.txt (+1 -1)")
        XCTAssertEqual(d?.added, 1)
        XCTAssertEqual(d?.removed, 1)
        XCTAssertEqual(d?.lines.first(where: { $0.kind == .remove })?.text, "BETA")
        XCTAssertEqual(d?.lines.first(where: { $0.kind == .add })?.text, "delta")
    }

    func testParsesANewFileWrite() {
        let d = EditDiff.parse("wrote foo.ex (+2 -0)\n\n+ one\n+ two")

        XCTAssertEqual(d?.added, 2)
        XCTAssertEqual(d?.removed, 0)
        XCTAssertEqual(d?.lines.filter { $0.kind == .add }.map(\.text), ["one", "two"])
    }

    func testParsesAMultiEditWithHeader() {
        let content = """
            applied edits to 2 file(s): a.ex, b.ex

            a.ex (+1 -1)
            - x
            + y

            b.ex (+1 -1)
            - p
            + q
            """
        let d = EditDiff.parse(content)

        XCTAssertNotNil(d)
        XCTAssertEqual(d?.added, 2)
        XCTAssertEqual(d?.removed, 2)
        XCTAssertEqual(d?.summary, "applied edits to 2 file(s): a.ex, b.ex")
    }

    func testKeepsContextLines() {
        let d = EditDiff.parse("edited m.ex (+1 -1)\n\n  before\n- old\n+ new\n  after")

        XCTAssertEqual(d?.lines.filter { $0.kind == .context }.map(\.text), ["", "before", "after"])
    }

    func testIgnoresNonDiffContent() {
        // A file read whose lines start with "- " must NOT be mistaken for a diff.
        XCTAssertNil(EditDiff.parse("- shopping\n- list\n- items"))
        XCTAssertNil(EditDiff.parse("exit 0\nhello-from-ogma"))
        XCTAssertNil(EditDiff.parse(""))
    }
}
