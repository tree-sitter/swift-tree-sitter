import XCTest
import Testing

import SwiftTreeSitter
import SwiftTreeSitterLayer
import TestTreeSitterSwift

extension Point {
	init(_ row: Int, _ column: Int) {
		self.init(row: row, column: column)
	}
}

#if !os(WASI)
final class LanguageLayerTests: XCTestCase {
	static let swiftConfig: LanguageConfiguration = {
		let language = Language(language: tree_sitter_swift())

		let queryText = """
["func"] @keyword.function
["var" "let"] @keyword
"""

		let highlightQuery = try! Query(language: language, data: queryText.data(using: .utf8)!)

		return LanguageConfiguration(language,
									 name: "Swift",
									 queries: [.highlights: highlightQuery])
	}()

	static let selfInjectingSwiftConfig: LanguageConfiguration = {
		let queryText = """
((line_str_text) @injection.content (#set! injection.language "swift"))
"""
		let injectionQuery = try! Query(language: swiftConfig.language, data: queryText.data(using: .utf8)!)

		var queries = swiftConfig.queries

		queries[.injections] = injectionQuery

		return LanguageConfiguration(swiftConfig.language,
									 name: swiftConfig.name,
									 queries: queries)
	}()
}

extension LanguageLayerTests {
	func testSingleInjection() throws {
		let config = LanguageLayer.Configuration(languageProvider: { name in
			precondition(name == "swift")

			return Self.swiftConfig
		})

		let tree = try LanguageLayer(languageConfig: Self.selfInjectingSwiftConfig, configuration: config)

		let text = """
let a = "var a = 1"

func main() {}
"""
		tree.replaceContent(with: text)

		let highlights = try tree.highlights(in: NSRange(0..<text.utf16.count), provider: { _, _ in nil })

		let expected = [
			NamedRange(name: "keyword", range: NSRange(0..<3), pointRange: Point(0, 0)..<Point(0, 6)),
			NamedRange(name: "keyword.function", range: NSRange(21..<25), pointRange: Point(2, 0)..<Point(2, 8)),
			NamedRange(name: "keyword", range: NSRange(9..<12), pointRange: Point(0, 18)..<Point(0, 24)),
		]

		XCTAssertEqual(highlights, expected)
	}


	func testReparsingWithinInjection() throws {
		let config = LanguageLayer.Configuration(languageProvider: { name in
			precondition(name == "swift")

			return Self.swiftConfig
		})

		let tree = try LanguageLayer(languageConfig: Self.selfInjectingSwiftConfig, configuration: config)

		let text = """
let a = "var a = 1"

func main() {}
"""
		tree.replaceContent(with: text)

		print(try tree.highlights(in: NSRange(0..<text.utf16.count), provider: { _, _ in nil }))

		// make a sufficient change so we can be sure we've actually invalidated the right stuff
let newText = """
let a = "func b() {}"

func main() {}
"""

		let edit = InputEdit(
			startByte: 9*2,
			oldEndByte: 18*2,
			newEndByte: 20*2,
			startPoint: Point(0, 9*2),
			oldEndPoint: Point(0, 18*2),
			newEndPoint: Point(0, 20*2)
		)

		let invalidation = tree.didChangeContent(.init(string: newText), using: edit, resolveSublayers: false)

		XCTAssertEqual(invalidation, IndexSet(integersIn: 9..<20))

		let highlights = try tree.highlights(in: NSRange(0..<newText.utf16.count), provider: { _, _ in nil })

		let expected = [
			NamedRange(name: "keyword", range: NSRange(0..<3), pointRange: Point(0, 0)..<Point(0, 6)),
			NamedRange(name: "keyword.function", range: NSRange(23..<27), pointRange: Point(2, 0)..<Point(2, 8)),
			NamedRange(name: "keyword.function", range: NSRange(9..<13), pointRange: Point(0, 9*2)..<Point(0, 13*2)),
		]

		XCTAssertEqual(highlights, expected)
	}

	func testMultipleInjectionsinSameLayer() throws {
		let config = LanguageLayer.Configuration(languageProvider: { name in
			precondition(name == "swift")

			return Self.swiftConfig
		})

		let tree = try LanguageLayer(languageConfig: Self.selfInjectingSwiftConfig, configuration: config)

		let text = """
let a = "var a = 1"
let b = "var b = 1"
"""
		tree.replaceContent(with: text)

		let highlights = try tree.highlights(in: NSRange(0..<text.utf16.count), provider: { _, _ in nil })

		let expected = [
			NamedRange(name: "keyword", range: NSRange(0..<3), pointRange: Point(0, 0)..<Point(0, 6)),
			NamedRange(name: "keyword", range: NSRange(20..<23), pointRange: Point(1, 0)..<Point(1, 6)),
			NamedRange(name: "keyword", range: NSRange(9..<12), pointRange: Point(0, 18)..<Point(0, 24)),
			NamedRange(name: "keyword", range: NSRange(29..<32), pointRange: Point(1, 18)..<Point(1, 24)),
		]

		XCTAssertEqual(highlights, expected)
	}

	func testExpandingQueryRangesByParentMatches() throws {
		let language = Language(language: tree_sitter_swift())

		// this query conflicts with the injection
		let queryText = """
["var" "let"] @keyword
(line_str_text) @string
"""

		let highlightQuery = try! Query(language: language, data: queryText.data(using: .utf8)!)

		let injectionQueryText = """
((line_str_text) @injection.content (#set! injection.language "swift"))
"""
		let injectionQuery = try! Query(language: language, data: injectionQueryText.data(using: .utf8)!)

		let queries: [Query.Definition: Query] = [
			.highlights: highlightQuery,
			.injections: injectionQuery,
		]

		let swiftConfig = LanguageConfiguration(
			language,
			name: "Swift",
			queries: queries
		)

		let config = LanguageLayer.Configuration(languageProvider: { name in
			precondition(name == "swift")

			return swiftConfig
		})

		let tree = try LanguageLayer(languageConfig: swiftConfig, configuration: config)

		let text = """
let a = "var a = 1"
"""
		tree.replaceContent(with: text)

		// target a space within the string. This will match in the root but not in the injection
		let highlights = try tree.highlights(in: NSRange(12..<13), provider: { _, _ in nil })

		let expected = [
			NamedRange(name: "string", range: NSRange(9..<18), pointRange: Point(0, 18)..<Point(0, 36)),
			NamedRange(name: "keyword", range: NSRange(9..<12), pointRange: Point(0, 18)..<Point(0, 24)),
		]

		XCTAssertEqual(highlights, expected)
	}

	func testInjectionsParsedOutOfOrder() throws {
		let config = LanguageLayer.Configuration(languageProvider: { name in
			precondition(name == "swift")

			return Self.swiftConfig
		})

		let layerTree = try LanguageLayer(languageConfig: Self.selfInjectingSwiftConfig, configuration: config)

		let text = """
let a = "var a = 1"
let b = "var b = 1"
let c = "var c = 1"
"""

		let content = LanguageLayer.Content(string: text)

		// process just the first line
		let content1 = LanguageLayer.Content(string: text, limit: 19)
		let input1 = InputEdit(
			startByte: 0,
			oldEndByte: 0,
			newEndByte: 19*2,
			startPoint: Point(0, 0),
			oldEndPoint: Point(0, 0),
			newEndPoint: Point(0, 19*2)
		)

		let invalidation1 = layerTree.didChangeContent(content1, using: input1, resolveSublayers: false)
		let target1 = IndexSet(integersIn: 0..<19)

		XCTAssertEqual(invalidation1, target1)

		// first line of highlights
		let resolve1 = try layerTree.resolveSublayers(with: content1, in: target1)
		XCTAssertEqual(resolve1, IndexSet(integersIn: 9..<18))

		// query for highlights
		let highlights1 = try layerTree.highlights(in: target1, provider: content1.textProvider)

		let expected1 = [
			NamedRange(name: "keyword", range: NSRange(0..<3), pointRange: Point(0, 0)..<Point(0, 6)),
			NamedRange(name: "keyword", range: NSRange(9..<12), pointRange: Point(0, 18)..<Point(0, 24)),
		]

		XCTAssertEqual(highlights1, expected1)

		// now process the entire content
		let input2 = InputEdit(
			startByte: input1.newEndByte,
			oldEndByte: input1.newEndByte,
			newEndByte: 60*2,
			startPoint: input1.newEndPoint,
			oldEndPoint: input1.newEndPoint,
			newEndPoint: Point(3, 60*2)
		)

		let invalidation2 = layerTree.didChangeContent(content, using: input2, resolveSublayers: false)
		XCTAssertEqual(invalidation2, IndexSet(integersIn: 19..<60))

		// resolve + highlight *just the third line* skipping the middle, which will result in an invalidation starting at the last node of the first injection and going all the way to the last node of the 3rd
		let target2 = IndexSet(integersIn: 40..<60)
		let resolve2 = try layerTree.resolveSublayers(with: content, in: target2)
		XCTAssertEqual(resolve2, IndexSet(9..<58))

		let highlights2 = try layerTree.highlights(in: target2, provider: content.textProvider)

		let expected2 = [
			NamedRange(name: "keyword", range: NSRange(40..<43), pointRange: Point(2, 0)..<Point(2, 6)),
			NamedRange(name: "keyword", range: NSRange(49..<52), pointRange: Point(2, 18)..<Point(2, 24)),
		]

		XCTAssertEqual(highlights2, expected2)

		// and now, finally, resolve and query the middle injection
		let target3 = IndexSet(integersIn: 20..<40)
		let resolve3 = try layerTree.resolveSublayers(with: content, in: target3)
		XCTAssertEqual(resolve3, IndexSet(29..<38))

		let highlights3 = try layerTree.highlights(in: target3, provider: content.textProvider)

		let expected3 = [
			NamedRange(name: "keyword", range: NSRange(20..<23), pointRange: Point(1, 0)..<Point(1, 6)),
			NamedRange(name: "keyword", range: NSRange(29..<32), pointRange: Point(1, 18)..<Point(1, 24)),
		]

		XCTAssertEqual(highlights3, expected3)
	}

	func testRemovingInjectionWithReplacement() throws {
		let text = """
let a = "var b = 1"
"""

		// turn the string into a comment
		try assertIncrementalParseMatchesFreshParse(of: text, replacing: NSRange(0..<8), with: "// ")
	}

	func testRemovingInjectionLeavingEmptyRange() throws {
		let text = """
let a = "var b = 1"
"""

		// the edit collapses the included range
		try assertIncrementalParseMatchesFreshParse(of: text, replacing: NSRange(8..<19), with: "1")
	}

	func testRemovingInjectionWithDeletion() throws {
		let text = """
let a = "var b = 1"
// c
let d = "var e = 2"
"""

		// join the last line to the comment, leaving the first injection as it is
		let invalidation = try assertIncrementalParseMatchesFreshParse(of: text, replacing: NSRange(24..<25), with: "")

		XCTAssertTrue(invalidation.contains(integersIn: 33..<42))
	}

	func testInsertingAtStartOfInjection() throws {
		let text = """
let a = "ar b = 1"
"""

		// the edited included range starts after the inserted character, but the injection does not
		try assertIncrementalParseMatchesFreshParse(of: text, replacing: NSRange(9..<9), with: "v")
	}

	func testInsertingAtEndOfInjection() throws {
		let text = """
let a = "var b = 1"
"""

		// the edited included range takes in the interpolation, but the injection does not
		try assertIncrementalParseMatchesFreshParse(of: text, replacing: NSRange(18..<18), with: #"\(x)"#)
	}

	func testSplittingInjection() throws {
		let text = """
let a = "var b = 1"
"""

		// the injection splits into two, both only touching the edited range
		try assertIncrementalParseMatchesFreshParse(of: text, replacing: NSRange(14..<15), with: #"\(y)"#)
	}

	func testResolvingInjectionAcrossDisjointSet() throws {
		let config = LanguageLayer.Configuration(languageProvider: { name in
			precondition(name == "swift")

			return Self.swiftConfig
		})

		let layer = try LanguageLayer(languageConfig: Self.selfInjectingSwiftConfig, configuration: config)

		let text = """
let a = "var b = 1"
"""
		let content = LanguageLayer.Content(string: text)
		let edit = InputEdit(
			startByte: 0,
			oldEndByte: 0,
			newEndByte: 19*2,
			startPoint: Point(0, 0),
			oldEndPoint: Point(0, 0),
			newEndPoint: Point(0, 19*2)
		)

		_ = layer.didChangeContent(content, using: edit, resolveSublayers: false)

		// the injection intersects both ranges of the set
		var set = IndexSet(integersIn: 9..<11)
		set.insert(integersIn: 14..<16)

		_ = try layer.resolveSublayers(with: content, in: set)

		let ranges = layer.snapshot()?.sublayerSnapshots.map { $0.rootSnapshot.tree.includedRanges.map(\.bytes.range) }

		XCTAssertEqual(ranges, [[NSRange(9..<18)]])
	}

	func testThrowsOnNoHighlightQuery() throws {
		let language = Language(language: tree_sitter_swift())
		let swiftConfig = LanguageConfiguration(
			language,
			name: "Swift",
			queries: [:]
		)

		let config = LanguageLayer.Configuration(languageProvider: { name in
			precondition(name == "swift")

			return swiftConfig
		})

		let tree = try LanguageLayer(languageConfig: swiftConfig, configuration: config)

		let text = """
let a = "var a = 1"
"""
		tree.replaceContent(with: text)

		XCTAssertThrowsError(try tree.highlights(in: NSRange(0..<10), provider: { _, _ in nil })) { error in
			XCTAssertEqual(error as? LanguageLayerError, LanguageLayerError.queryUnavailable("Swift", .highlights))
		}
	}
}

extension LanguageLayerTests {
	@discardableResult
	private func assertIncrementalParseMatchesFreshParse(
		of text: String,
		replacing range: NSRange,
		with replacement: String,
		file: StaticString = #filePath,
		line: UInt = #line
	) throws -> IndexSet {
		let config = LanguageLayer.Configuration(languageProvider: { name in
			precondition(name == "swift")

			return Self.swiftConfig
		})

		let newText = (text as NSString).replacingCharacters(in: range, with: replacement)
		let newEnd = range.location + replacement.utf16.count

		func point(at location: Int, in string: String) -> Point {
			let lines = (string as NSString).substring(to: location).components(separatedBy: "\n")

			return Point(lines.count - 1, lines.last!.utf16.count * 2)
		}

		let edit = InputEdit(
			startByte: UInt32(range.location * 2),
			oldEndByte: UInt32(range.upperBound * 2),
			newEndByte: UInt32(newEnd * 2),
			startPoint: point(at: range.location, in: text),
			oldEndPoint: point(at: range.upperBound, in: text),
			newEndPoint: point(at: newEnd, in: newText)
		)

		let layer = try LanguageLayer(languageConfig: Self.selfInjectingSwiftConfig, configuration: config)
		layer.replaceContent(with: text)

		let content = LanguageLayer.Content(string: newText)
		let invalidation = layer.didChangeContent(content, using: edit, resolveSublayers: false)
		let resolution = try layer.resolveSublayers(with: content, in: invalidation)

		let freshLayer = try LanguageLayer(languageConfig: Self.selfInjectingSwiftConfig, configuration: config)
		freshLayer.replaceContent(with: newText)

		let fullRange = NSRange(0..<newText.utf16.count)

		XCTAssertEqual(
			try layer.highlights(in: fullRange, provider: { _, _ in nil }),
			try freshLayer.highlights(in: fullRange, provider: { _, _ in nil }),
			file: file,
			line: line
		)

		// sublayers are only visible through snapshots
		func sublayerRanges(of layer: LanguageLayer) -> [[NSRange]]? {
			layer.snapshot()?.sublayerSnapshots.map { $0.rootSnapshot.tree.includedRanges.map(\.bytes.range) }
		}

		XCTAssertEqual(sublayerRanges(of: layer), sublayerRanges(of: freshLayer), file: file, line: line)

		return resolution
	}
}

#endif

struct NewLanguageLayerTests {
	@Test
	func executeQuery() async throws {
		let config = LanguageLayer.Configuration()
		let tree = try LanguageLayer(languageConfig: LanguageLayerTests.swiftConfig, configuration: config)

		let text = """
func main() {
}
"""
		tree.replaceContent(with: text)

		let cursor = try tree.executeQuery(.highlights, in: NSRange(0..<text.utf16.count))
		let highlights = cursor.highlights()

		let expected = [
			NamedRange(name: "keyword.function", range: NSRange(0..<4), pointRange: Point(row: 0, column: 0)..<Point(row: 0, column: 8)),
		]

		#expect(highlights == expected)
	}

	@Test
	func sublayersAreResolvedAfterEdit() async throws {
		let layerConfig = LanguageLayer.Configuration { name in
			precondition(name == "swift")
			print("asked for \(name)")

			return LanguageLayerTests.swiftConfig
		}
		
		let layer = try LanguageLayer(
			languageConfig: LanguageLayerTests.selfInjectingSwiftConfig,
			configuration: layerConfig
		)

		let text = """
let host = 0
"""
		layer.replaceContent(with: text)

		let initialRange = NSRange(0..<text.utf16.count)

		let initialExpected = [
			NamedRange(name: "keyword", range: NSRange(0..<3), pointRange: Point(row: 0, column: 0)..<Point(row: 0, column: 6)),
		]

		try #expect(initialExpected == layer.executeQuery(.highlights, in: initialRange).highlights())

		let newText = """
let host = "let inner = 1"
"""
		let editedRange = NSRange(0..<newText.utf16.count)

		let edit = InputEdit(
			startByte: 11*2,
			oldEndByte: 12*2,
			newEndByte: 26*2,
			startPoint: Point(0, 11*2),
			oldEndPoint: Point(0, 12*2),
			newEndPoint: Point(0, 26*2)
		)

		// turn off resolution explicitly here
		let invalidation = layer.didChangeContent(.init(string: newText), using: edit, resolveSublayers: false)

		#expect(invalidation == IndexSet(integersIn: 11..<26))

		// this is stale, but we have not done layer resolution yet
		try #expect(initialExpected == layer.executeQuery(.highlights, in: editedRange).highlights())

		// now, actually perform the resolution
		let resolutionInvalidation = try layer.resolveSublayers(with: .init(string: newText), in: editedRange)

		#expect(resolutionInvalidation == IndexSet(integersIn: 12..<25))

		let editedExpected = [
			NamedRange(name: "keyword", range: NSRange(0..<3), pointRange: Point(row: 0, column: 0)..<Point(row: 0, column: 6)),
			NamedRange(name: "keyword", range: NSRange(12..<15), pointRange: Point(row: 0, column: 12*2)..<Point(row: 0, column: 15*2)),
		]

		try #expect(editedExpected == layer.executeQuery(.highlights, in: editedRange).highlights())
	}
}
