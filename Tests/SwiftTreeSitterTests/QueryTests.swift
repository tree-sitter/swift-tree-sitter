import XCTest

import SwiftTreeSitter
import TestTreeSitterSwift

final class QueryTests: XCTestCase {
#if !os(WASI)
	func testParseQueryWithSetDirectives() throws {
		let language = Language(language: tree_sitter_swift())

		let queryText = """
("func" @keyword.function (#set! abc "def"))
"""
		let queryData = try XCTUnwrap(queryText.data(using: .utf8))
		let query = try Query(language: language, data: queryData)

		let text = """
func main() {
}
"""

		let parser = Parser()
		try parser.setLanguage(language)

		let tree = try XCTUnwrap(parser.parse(text))
		let root = try XCTUnwrap(tree.rootNode)

		let cursor = query.execute(node: root, in: tree)

		let match = try XCTUnwrap(cursor.next())
		XCTAssertEqual(match.metadata["abc"], "def")
	}

	func testParseQueryWithCaptureSetDirectives() throws {
		let language = Language(language: tree_sitter_swift())

		let queryText = """
("func" @keyword.function (#set! @keyword.function abc "def"))
"""
		let queryData = try XCTUnwrap(queryText.data(using: .utf8))
		let query = try Query(language: language, data: queryData)

		let text = """
func main() {
}
"""

		let parser = Parser()
		try parser.setLanguage(language)

		let tree = try XCTUnwrap(parser.parse(text))
		let root = try XCTUnwrap(tree.rootNode)

		let cursor = query.execute(node: root, in: tree)

		let match = try XCTUnwrap(cursor.next())
		XCTAssertTrue(match.metadata.isEmpty)

		let capture = try XCTUnwrap(match.captures.first)

		XCTAssertEqual(capture.metadata["abc"], "def")
	}

	func testHighlightsQuerySorting() throws {
		let language = Language(language: tree_sitter_swift())

		let queryText = """
("func" @a)

("func" @a.b.c)

("func" @a.b)
"""
		let queryData = try XCTUnwrap(queryText.data(using: .utf8))
		let query = try Query(language: language, data: queryData)
		let captureNames = (0..<query.captureCount).compactMap(query.captureName(for:))

		XCTAssertEqual(captureNames, ["a", "a.b.c", "a.b"])
		XCTAssertNil(query.captureName(for: query.captureCount))

		let text = """
func main() {
}
"""

		let parser = Parser()
		try parser.setLanguage(language)

		let tree = try XCTUnwrap(parser.parse(text))
		let root = try XCTUnwrap(tree.rootNode)

		let cursor = query.execute(node: root, in: tree)

		let expectedPoints = Point(row: 0, column: 0)..<Point(row: 0, column: 8)
		let expectedRange = TSRange(points: expectedPoints, bytes: 0..<8)
		let expected = [
			NamedRange(nameComponents: ["a"], tsRange: expectedRange),
			NamedRange(nameComponents: ["a", "b"], tsRange: expectedRange),
			NamedRange(nameComponents: ["a", "b", "c"], tsRange: expectedRange)
		]

		XCTAssertEqual(cursor.highlights(), expected)
	}
#endif
}
