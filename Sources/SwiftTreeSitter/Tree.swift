import TreeSitter

/// An immutable tree-sitter tree structure.
public final class Tree: Sendable {
	private let internalTreePointer: SendableOpaquePointer
	
	let source:String?

	init(internalTree: OpaquePointer,source:String? = nil) {
		self.internalTreePointer = SendableOpaquePointer(internalTree)
		self.source = source
	}

	deinit {
		ts_tree_delete(internalTree)
	}

	var internalTree: OpaquePointer {
		internalTreePointer.pointer
	}

	public func copy() -> Tree? {
		guard let copiedTree = ts_tree_copy(self.internalTree) else {
			return nil
		}

		return Tree(internalTree: copiedTree)
	}

	public func mutableCopy() -> MutableTree? {
		guard let tree = copy() else { return nil }

		return MutableTree(tree: tree)
	}

	// Create a new Tree with the edit applied.
	public func edit(_ inputEdit: InputEdit) -> Tree? {
		guard let copiedTree = ts_tree_copy(self.internalTree) else {
			return nil
		}

		withUnsafePointer(to: inputEdit.internalInputEdit) { (ptr) -> Void in
			ts_tree_edit(copiedTree, ptr)
		}

		return Tree(internalTree: copiedTree)
	}
}

extension Tree {
	public var rootNode: Node? {
		let node = ts_tree_root_node(internalTree)

		return Node(internalNode: node, internalTree: self)
	}

	public var includedRanges: [TSRange] {
		var count: UInt32 = 0

		guard let tsRanges = ts_tree_included_ranges(internalTree, &count) else {
			return []
		}

		let bufferPointer = UnsafeBufferPointer(start: tsRanges, count: Int(count))

		// there is a bug in the current tree sitter version
		// that can produce ranges with invalid points (but seemingly correct) byte
		// offsets. We have to be more careful with those.
		let ranges = bufferPointer.map({ TSRange(potentiallyInvalidRange: $0) })

		free(tsRanges)

		return ranges
	}
}

extension Tree {
	public func changedRanges(from other: Tree) -> [TSRange] {
		var count: UInt32 = 0

		guard let tsRanges = ts_tree_get_changed_ranges(internalTree, other.internalTree, &count) else {
			return []
		}

		let bufferPointer = UnsafeBufferPointer(start: tsRanges, count: Int(count))

		// there is a bug in the current tree sitter version
		// that can produce ranges with invalid points (but seemingly correct) byte
		// offsets. We have to be more careful with those.
		let ranges = bufferPointer.map({ TSRange(potentiallyInvalidRange: $0) })

		free(tsRanges)

		return ranges
	}

	public func changedRanges(from other: MutableTree) -> [TSRange] {
		changedRanges(from: other.tree)
	}
}

extension Tree {
	public func enumerateNodes(in byteRange: Range<UInt32>, block: (Node) throws -> Void) rethrows {
		guard let root = rootNode else { return }

		guard let node = root.descendant(in: byteRange) else { return }

		try block(node)

		let cursor = node.treeCursor

		if cursor.goToFirstChild(for: byteRange.lowerBound) == false {
			return
		}

		try cursor.enumerateCurrentAndDescendents(block: block)

		while cursor.gotoNextSibling() {
			guard let node = cursor.currentNode else {
				assertionFailure("no current node when gotoNextSibling succeeded")
				break
			}

			// once we are past the interesting range, stop
			if node.byteRange.lowerBound > byteRange.upperBound {
				break
			}

			try cursor.enumerateCurrentAndDescendents(block: block)
		}
	}
}

public final class MutableTree {
	let tree: Tree

	init(internalTree: OpaquePointer,source: String?) {
		self.tree = Tree(internalTree: internalTree,source: source)
	}

	init(tree: Tree) {
		self.tree = tree
	}

	public func copy() -> Tree? {
		tree.copy()
	}

	public func mutableCopy() -> MutableTree? {
		guard let tree = copy() else { return nil }

		return MutableTree(tree: tree)
	}
}

extension MutableTree {
	public var rootNode: Node? {
		tree.rootNode
	}

	public var includedRanges: [TSRange] {
		tree.includedRanges
	}
}

extension MutableTree {
	public func edit(_ inputEdit: InputEdit) {
		withUnsafePointer(to: inputEdit.internalInputEdit) { (ptr) -> Void in
			ts_tree_edit(tree.internalTree, ptr)
		}
	}

	public func changedRanges(from other: Tree) -> [TSRange] {
		tree.changedRanges(from: other)
	}

	public func changedRanges(from other: MutableTree) -> [TSRange] {
		tree.changedRanges(from: other.tree)
	}
}

extension MutableTree {
	public func enumerateNodes(in byteRange: Range<UInt32>, block: (Node) throws -> Void) rethrows {
		try tree.enumerateNodes(in: byteRange, block: block)
	}
}
