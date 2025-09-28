import XCTest

import SwiftTreeSitter
import TestTreeSitterSwift

final class NodeTests: XCTestCase {
	#if !os(WASI)
		func testTreeNodeLifecycle() throws {
			let language = Language(language: tree_sitter_swift())

			let text = """
				func main() {
				}
				"""

			let parser = Parser()
			try parser.setLanguage(language)

			var tree: MutableTree? = try XCTUnwrap(parser.parse(text))
			let root = try XCTUnwrap(tree?.rootNode)

			tree = nil

			XCTAssertTrue(root.childCount != 0)
		}
	#endif

	func testTreeNodeText() throws {
		let language = Language(language: tree_sitter_swift())

		let text = """
			func greet(name: String){
				   print("hello,\(name)")
			   }
			   greet("world")
			"""

		let parser = Parser()
		try parser.setLanguage(language)

		let tree: MutableTree? = try XCTUnwrap(parser.parse(text))
		let root = try XCTUnwrap(tree?.rootNode)

		// function_declaration
		let function_declaration_node = try XCTUnwrap(root.child(at: 0))
		
		for i in (0..<function_declaration_node.namedChildCount) {
			let node = try XCTUnwrap(function_declaration_node.namedChild(at: i))
			let nodeType = try XCTUnwrap(node.nodeType)
			let nodeText = try XCTUnwrap(node.text)
		
			switch nodeType {
			case "simple_identifier":
				XCTAssertEqual(nodeText, "greet")
			case "parameter":
				XCTAssertEqual(nodeText, "name: String")
			default:
				break
			}
		}

		// call_expression
		let call_expression_node = try XCTUnwrap(root.child(at: 1))
		let call_expression_text = try XCTUnwrap(call_expression_node.text)
		XCTAssertEqual(call_expression_text, "greet(\"world\")")
		
		for i in (0..<call_expression_node.namedChildCount) {
			let node = try XCTUnwrap(call_expression_node.namedChild(at: i))
			let nodeType = try XCTUnwrap(node.nodeType)
			let nodeText = try XCTUnwrap(node.text)

			switch nodeType {
			case "simple_identifier":
				XCTAssertEqual(nodeText, "greet")
			case "call_suffix":
				XCTAssertEqual(nodeText, "(\"world\")")
			default:
				break
			}
		}
	}
}
