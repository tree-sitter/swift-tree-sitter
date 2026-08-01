import Foundation
import TreeSitter

/// Stores a query capture name together with its parsed hierarchy.
private struct CachedCaptureName: Sendable {
    /// The complete capture name returned by Tree-sitter.
    let value: String

    /// The hierarchy used by highlighting and injection consumers.
    let components: [String]
}

public enum QueryError: Error {
    case none
    case syntax(UInt32)
    case nodeType(UInt32)
    case field(UInt32)
    case capture(UInt32)
    case structure(UInt32)
    case unknown(UInt32)

    init(offset: UInt32, internalError: TSQueryError) {
        switch internalError {
        case TSQueryErrorNone:
            self = .none
        case TSQueryErrorSyntax:
            self = .syntax(offset)
        case TSQueryErrorNodeType:
            self = .nodeType(offset)
        case TSQueryErrorField:
            self = .field(offset)
        case TSQueryErrorCapture:
            self = .capture(offset)
        case TSQueryErrorStructure:
            self = .structure(offset)
        default:
            self = .unknown(offset)
        }
    }
}

public enum QueryPredicateError: Error {
    case valueNotFound
    case unrecognizedStepType
    case queryInvalid
    case textContentUnavailable
}

/// An object that represents a collection of tree-sitter query statements.
///
/// Typically, query definitions are stored in a `.scm` file.
///
/// Tree-sitter's official documentation: [Pattern Matching with Queries](https://tree-sitter.github.io/tree-sitter/using-parsers#pattern-matching-with-queries)
public final class Query: Sendable {
    let internalQueryPointer: SendableOpaquePointer
    let predicateList: [[Predicate]]

    /// Keeps capture names out of the cursor's per-capture hot path.
    private let captureNames: [CachedCaptureName?]

    /// Construct a query object from scm data
    ///
    /// This operation has do to a lot of work, especially if any
    /// patterns contain predicates. You should expect it will
    /// be expensive.
    public init(language: Language, data: Data) throws {
        let dataLength = data.count
        var errorOffset: UInt32 = 0
        var queryError: TSQueryError = TSQueryErrorNone

        let result = data.withUnsafeBytes { byteBuffer -> OpaquePointer? in
            guard let ptr = byteBuffer.baseAddress?.bindMemory(to: CChar.self, capacity: dataLength) else {
                return nil
            }

            return ts_query_new(language.tsLanguage,
                                ptr,
								UInt32(dataLength),
                                &errorOffset,
                                &queryError)
        }

        guard let queryPtr = result else {
            throw QueryError(offset: errorOffset, internalError: queryError)
        }

        self.internalQueryPointer = SendableOpaquePointer(queryPtr)
        self.predicateList = try PredicateParser().predicates(in: queryPtr)
        self.captureNames = (0..<Int(ts_query_capture_count(queryPtr))).map { id in
            var length: UInt32 = 0
            guard let value = ts_query_capture_name_for_id(queryPtr, UInt32(id), &length) else {
                return nil
            }

            let name = String(cString: value)
            return CachedCaptureName(
                value: name,
                components: name.components(separatedBy: ".")
            )
        }
    }

	/// Construct a query object from scm data located at a url
	public convenience init(language: Language, url: URL) throws {
		try self.init(language: language, data: try Data(contentsOf: url))
	}

    deinit {
        ts_query_delete(internalQuery)
    }

	var internalQuery: OpaquePointer {
		internalQueryPointer.pointer
	}

    public var patternCount: Int {
        return Int(ts_query_pattern_count(internalQuery))
    }

    public var captureCount: Int {
        return Int(ts_query_capture_count(internalQuery))
    }

    public var stringCount: Int {
        return Int(ts_query_string_count(internalQuery))
    }

	/// Run a query
	///
	/// - Parameter node: the root node for the query
	/// - Parameter tree: a reference to the tree
	/// - Parameter depth: the language injection depth
	public func execute(node: Node, in tree: Tree, depth: Int = 0) -> QueryCursor {
		let cursor = QueryCursor(internalTree: tree, depth: depth)

        cursor.execute(query: self, node: node)

        return cursor
    }

	public func execute(node: Node, in tree: MutableTree) -> QueryCursor {
		execute(node: node, in: tree.tree)
	}

	/// Run a query against the root node of a tree.
	///
	/// - Parameter tree: a reference to the tree
	/// - Parameter depth: the language injection depth
	public func execute(in tree: Tree, depth: Int = 0) -> QueryCursor {
		let cursor = QueryCursor(internalTree: tree, depth: depth)

		if let node = tree.rootNode {
			cursor.execute(query: self, node: node)
		}

		return cursor
	}

	public func execute(in tree: MutableTree) -> QueryCursor {
		execute(in: tree.tree)
	}

    public func captureName(for id: Int) -> String? {
        guard captureNames.indices.contains(id) else {
            return nil
        }

        return captureNames[id]?.value
    }

    /// Returns the cached name and hierarchy for a capture identifier.
    ///
    /// - Parameter id: The Tree-sitter capture identifier.
    /// - Returns: The cached capture name when the identifier is valid.
    fileprivate func cachedCaptureName(for id: Int) -> CachedCaptureName? {
        guard captureNames.indices.contains(id) else {
            return nil
        }

        return captureNames[id]
    }

    public func stringName(for id: Int) -> String? {
        var length: UInt32 = 0

        guard let cStr = ts_query_string_value_for_id(internalQuery, UInt32(id), &length) else {
            return nil
        }

        return String(cString: cStr)
    }

    public func predicates(for patternIndex: Int) -> [Predicate] {
        return predicateList[patternIndex]
    }

    public var hasPredicates: Bool {
        for i in 0..<patternCount {
            if predicates(for: i).isEmpty == false {
                return true
            }
        }

        return false
    }
}

public struct QueryCapture {
    public let node: Node
    public let index: Int
    public let nameComponents: [String]
    public let patternIndex: Int
	public let metadata: [String: String]

	/// The language injection depth.
	public let depth: Int

	init?(tsCapture: TSQueryCapture, internalTree: Tree, nameComponents: [String], patternIndex: Int, metadata: [String: String], depth: Int) {
		guard let node = Node(internalNode: tsCapture.node, internalTree: internalTree) else {
            return nil
        }

        self.node = node
        self.index = Int(tsCapture.index)
        self.nameComponents = nameComponents
        self.patternIndex = patternIndex
		self.metadata = metadata
		self.depth = depth
    }

	init?(tsCapture: TSQueryCapture, internalTree: Tree, query: Query?, patternIndex: Int, depth: Int) {
		let captureName = query?.cachedCaptureName(for: Int(tsCapture.index))

		let predicates = query?.predicates(for: patternIndex) ?? []

		let metadata = captureName.map { QueryCapture.evaluateDirectives(predicates, with: $0.value) } ?? [:]

		self.init(tsCapture: tsCapture, internalTree: internalTree, nameComponents: captureName?.components ?? [], patternIndex: patternIndex, metadata: metadata, depth: depth)
	}

	private static func evaluateDirectives(_ predicates: [Predicate], with name: String) -> [String: String] {
		let pairs = predicates.compactMap { predicate -> (String, String)? in
			switch predicate {
			case let .set(captureName: captureName, key: key, value: value):
				if captureName == name {
					return (key, value)
				}
			default:
				break
			}

			return nil
		}

		return Dictionary(pairs, uniquingKeysWith: { $1 })
	}

    public var range: NSRange {
        return node.range
    }

    public var name: String? {
        return nameComponents.joined(separator: ".")
    }
}

extension QueryCapture: CustomDebugStringConvertible {
    public var debugDescription: String {
        let name = name ?? ""

        return "<capture \(index) \"\(name)\": \(node.debugDescription)>"
    }
}

extension QueryCapture: Comparable {
    public static func < (lhs: QueryCapture, rhs: QueryCapture) -> Bool {
		if lhs.depth != rhs.depth {
			return lhs.depth < rhs.depth
		}

        if lhs.range.lowerBound != rhs.range.lowerBound {
            return lhs.range.lowerBound < rhs.range.lowerBound
        }

        if lhs.nameComponents.count != rhs.nameComponents.count {
            return lhs.nameComponents.count < rhs.nameComponents.count
        }

        return lhs.patternIndex < rhs.patternIndex
    }
}

public struct QueryMatch {
    public var id: Int
    public var patternIndex: Int
    public var captures: [QueryCapture]
    public let predicates: [Predicate]
	public let metadata: [String: String]

    public func captures(named name: String) -> [QueryCapture] {
        return captures.filter({ $0.name == name })
    }

	/// Returns all nodes that correspond to the captures.
	public var nodes: [Node] {
		captures.map { $0.node }
	}

	/// Returns a range that spans all captures.
	public var range: NSRange? {
		guard let first = captures.first else {
			return nil
		}

		return captures.dropFirst().reduce(first.range, { $0.union($1.range) })
	}

	/// Determines if this match is actually allowed given the context.
	public func allowed(in context: Predicate.Context) -> Bool {
		predicates.allSatisfy { $0.allowsMatch(self, context: context) }
	}
}

/// A tree-sitter TSQueryCursor wrapper
///
/// This class is pretty faithful to to C API. However, it does evaluate `#set!` directives.
public final class QueryCursor {
    let internalCursor: OpaquePointer
	let internalTree: Tree
	let depth: Int

    public private(set) var activeQuery: Query?

	init(internalTree: Tree, depth: Int) {
        self.internalCursor = ts_query_cursor_new()
		self.internalTree = internalTree
		self.depth = depth
    }

    deinit {
        ts_query_cursor_delete(internalCursor)
    }

    /// Run a query
    ///
    /// Note that the node **and** the Tree is is part of
    /// must remain valid as long as the query is being used.
    ///
    /// - Parameter query: the query object to execute
    /// - Parameter node: the root node for the query
    public func execute(query: Query, node: Node) {
        self.activeQuery = query

        ts_query_cursor_exec(internalCursor, query.internalQuery, node.internalNode)
    }

    public var matchLimit: Int {
        get {
            Int(ts_query_cursor_match_limit(internalCursor))
        }
        set {
            ts_query_cursor_set_match_limit(internalCursor, UInt32(newValue))
        }
    }

    public func setByteRange(range: Range<UInt32>) {
        ts_query_cursor_set_byte_range(internalCursor, range.lowerBound, range.upperBound)
    }

    public func setRange(_ range: NSRange) {
        setByteRange(range: range.byteRange)
    }

    public func setPointRange(range: Range<Point>) {
        let start = range.lowerBound.internalPoint
        let end = range.upperBound.internalPoint

        ts_query_cursor_set_point_range(internalCursor, start, end)
    }

    @available(*, deprecated, renamed: "next")
    public func nextMatch() -> QueryMatch? {
        return next()
    }

    public func nextCapture() -> QueryCapture? {
        var match = TSQueryMatch(id: 0, pattern_index: 0, capture_count: 0, captures: nil)
        var index: UInt32 = 0

        if ts_query_cursor_next_capture(internalCursor, &match, &index) == false {
            return nil
        }

        let captureBuffer = UnsafeBufferPointer<TSQueryCapture>(start: match.captures,
                                                                count: Int(match.capture_count))

        let capture = captureBuffer[Int(index)]

		return QueryCapture(
			tsCapture: capture,
			internalTree: internalTree,
			query: activeQuery,
			patternIndex: Int(match.pattern_index),
			depth: depth
		)
    }
}

extension QueryCursor: Sequence, IteratorProtocol {
	private func evaluateDirectives(_ predicates: [Predicate]) -> [String: String] {
		let pairs = predicates.compactMap { predicate -> (String, String)? in
			switch predicate {
			case .set(captureName: nil, key: let key, value: let value):
				return (key, value)
			default:
				return nil
			}
		}

		return Dictionary(pairs, uniquingKeysWith: { $1 })
	}

    public func next() -> QueryMatch? {
        var match = TSQueryMatch(id: 0, pattern_index: 0, capture_count: 0, captures: nil)

        if ts_query_cursor_next_match(internalCursor, &match) == false {
            return nil
        }

        let captureBuffer = UnsafeBufferPointer<TSQueryCapture>(start: match.captures,
                                                                count: Int(match.capture_count))

        let patternIndex = Int(match.pattern_index)
        let predicates = activeQuery?.predicates(for: patternIndex) ?? []
		let metadata = evaluateDirectives(predicates)

		let captures = captureBuffer.compactMap({
			return QueryCapture(tsCapture: $0, internalTree: internalTree, query: activeQuery, patternIndex: patternIndex, depth: depth)
		})

        return QueryMatch(id: Int(match.id),
                          patternIndex: Int(match.pattern_index),
                          captures: captures,
                          predicates: predicates,
						  metadata: metadata)
    }
}
