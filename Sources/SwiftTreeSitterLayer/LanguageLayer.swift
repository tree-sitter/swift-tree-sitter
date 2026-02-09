import Foundation

import SwiftTreeSitter

public enum LanguageLayerError: Error, Hashable {
	case noRootNode
	case queryUnavailable(String, Query.Definition)
}

public final class LanguageLayer {
	public typealias LanguageProvider = (String) -> LanguageConfiguration?

	public struct Content {
		public let readHandler: Parser.ReadBlock
		public let textProvider: SwiftTreeSitter.Predicate.TextProvider

		public init(
			readHandler: @escaping Parser.ReadBlock,
			textProvider: @escaping SwiftTreeSitter.Predicate.TextProvider
		) {
			self.readHandler = readHandler
			self.textProvider = textProvider
		}

		public init(string: String) {
			self.init(string: string, limit: string.utf16.count)
		}

		public init(string: String, limit: Int) {
			let read = Parser.readFunction(for: string, limit: limit)

			self.init(
				readHandler: read,
				textProvider: string.predicateTextProvider
			)
		}
	}
	
	public struct ContentSnapshot: Sendable {
		public let readHandler: Parser.DataSnapshotProvider
		public let textProvider: SwiftTreeSitter.Predicate.TextSnapshotProvider
		
		public init(
			readHandler: @escaping @Sendable (Int, Point) -> Data?,
			textProvider: @escaping @Sendable (NSRange, Range<Point>) -> String?
		) {
			self.readHandler = readHandler
			self.textProvider = textProvider
		}
		
		public init(string: String, limit: Int) {
			let read = Parser.readFunction(for: string, limit: limit)

			self.init(
				readHandler: read,
				textProvider: string.predicateTextSnapshotProvider
			)
		}
		
		public init(string: String) {
			self.init(string: string, limit: string.utf16.count)
		}

		public var content: LanguageLayer.Content {
			.init(readHandler: readHandler, textProvider: textProvider)
		}
	}

	public struct Configuration {
		public let languageProvider: LanguageProvider
		public let maximumLanguageDepth: Int

		public init(
			maximumLanguageDepth: Int = 4,
			languageProvider: @escaping LanguageProvider = { _ in nil }
		) {
			self.languageProvider = languageProvider
			self.maximumLanguageDepth = maximumLanguageDepth
		}
	}

	private enum NestedEntry {
		case layer(LanguageLayer)
		case missing(String, [TSRange])
	}

	public let languageConfig: LanguageConfiguration
	public let depth: Int
	private let configuration: Configuration
	private let parser = Parser()
	private(set) var state = ParseState()
	private var sublayers = [String : LanguageLayer]()
	private var missingInjections = [String : [TSRange]]()
	private let rangeRestricted: Bool

	init(languageConfig: LanguageConfiguration, configuration: Configuration, ranges: [TSRange], depth: Int) throws {
		self.languageConfig = languageConfig
		self.configuration = configuration
		self.rangeRestricted = ranges.isEmpty == false
		self.depth = depth

		try parser.setLanguage(languageConfig.language)

		if rangeRestricted {
			parser.includedRanges = ranges
		}
	}

	public convenience init(languageConfig: LanguageConfiguration, configuration: Configuration, depth: Int = 0) throws {
		try self.init(languageConfig: languageConfig, configuration: configuration, ranges: [], depth: depth)
	}

	public var languageName: String {
		languageConfig.name
	}

	public var supportsNestedLanguages: Bool {
		languageConfig.queries[.injections] != nil && configuration.maximumLanguageDepth > 0
	}

	public var includedRangeSet: IndexSet? {
		state.includedSet
	}
}

extension LanguageLayer {
	func contains(_ range: NSRange) -> Bool {
		guard let set = includedRangeSet else {
			return false
		}

		return set.intersects(integersIn: Range(range)!)
	}

	func languageLayer(for range: NSRange) -> LanguageLayer? {
		guard contains(range) else {
			return nil
		}

		return sublayers.values.first(where: { $0.contains(range) }) ?? self
	}
}

extension LanguageLayer {
	private func applyEdit(_ edit: InputEdit) {
		state.applyEdit(edit)

		// and now update the included ranges
		if rangeRestricted, let tree = state.tree {
			parser.includedRanges = tree.includedRanges
		}

		for sublayer in sublayers.values {
			sublayer.applyEdit(edit)
		}
	}

	private func parse(with content: Content) -> IndexSet {
		let newState = parser.parse(state: state, readHandler: content.readHandler)

		let oldState = state

		self.state = newState

		var invalidations = oldState.changedSet(for: newState)

		for layer in sublayers.values {
			let subset = layer.parse(with: content)

			invalidations.formUnion(subset)
		}

		return invalidations
	}

	private func parse(with content: Content, affecting affectedSet: IndexSet, resolveSublayers resolve: Bool) -> IndexSet {
		// after this completes, affectedSet is valid again
		var set = parse(with: content)

		set.formUnion(affectedSet)

		if resolve {
			do {
				let subset = try resolveSublayers(with: content, in: set)

				set.formUnion(subset)
			} catch {
				print("parsing sublayers for \(languageName) failed: ", error)
			}
		}

		return set
	}

	@discardableResult
	public func replaceContent(with string: String, transformer: Point.LocationTransformer = { _ in nil }) -> IndexSet {
		let set = includedRangeSet

		let start = set?.first ?? 0
		let end = set?.last ?? start

		let fullRange = NSRange(start..<end)
		let delta = string.utf16.count - fullRange.length
		let edit = InputEdit(
			range: fullRange,
			delta: delta,
			oldEndPoint: transformer(fullRange.length) ?? .zero,
			transformer: transformer
		)

		let content = LanguageLayer.Content(string: string)

		return didChangeContent(content, using: edit, resolveSublayers: true)
	}

	/// Inform the layer tree that content has changed.
	///
	/// By default, this function will eagerly resolve sublayers. However, there could be a significant benefit to deferring that work until a query. Layer resolution is always performed at that point anyways, because it is needed to compute query results.
	///
	/// - Parameter content: The means of determining the state of the current content.
	/// - Parameter edit: Describes how the content has changed
	/// - Parameter resolveSublayers: If false, this will defer sublayer resolution.
	public func didChangeContent(_ content: LanguageLayer.Content, using edit: InputEdit, resolveSublayers: Bool = true) -> IndexSet {
		// includedRangeSet becomes invalid here
		applyEdit(edit)

		let editedRange = (edit.startByte..<edit.newEndByte).range
		let affectedSet = IndexSet(integersIn: Range(editedRange)!)

		return parse(with: content, affecting: affectedSet, resolveSublayers: resolveSublayers)
	}

	public func languageConfigurationChanged(for name: String, content: Content) throws -> IndexSet {
		var invalidated = IndexSet()

		for sublayer in sublayers.values {
			let subset = try sublayer.languageConfigurationChanged(for: name, content: content)

			invalidated.formUnion(subset)
		}

		invalidated.formUnion(try fillMissingSublayer(for: name, content: content))

		return invalidated
	}
}

extension LanguageLayer {
	public func snapshot(in set: IndexSet? = nil) -> LanguageLayerTreeSnapshot? {
		guard let rootSnapshot = LanguageLayerSnapshot(languageLayer: self) else {
			return nil
		}

		let subSnapshots = sublayers.values.compactMap { $0.snapshot(in: set) }

		if subSnapshots.count != sublayers.count {
			return nil
		}

		return LanguageLayerTreeSnapshot(rootSnapshot: rootSnapshot, sublayerSnapshots: subSnapshots)
	}
}

extension LanguageLayer: Queryable {
	private func executeShallowQuery(_ queryDef: Query.Definition, in set: IndexSet) throws -> LanguageLayerQueryCursor {
		let name = languageConfig.name

		guard let query = languageConfig.queries[queryDef] else {
			throw LanguageLayerError.queryUnavailable(name, queryDef)
		}

		// a copy here is a small inefficiency...
		guard let tree = state.tree?.copy() else {
			throw LanguageLayerError.noRootNode
		}

		let target = LanguageLayerQueryCursor.Target(tree: tree, query: query, depth: depth, name: languageName)

		return LanguageLayerQueryCursor(target: target, set: set)
	}
	
	public func executeQuery(_ queryDef: Query.Definition, in set: IndexSet) throws -> LanguageTreeQueryCursor {
		guard let treeSnapshot = snapshot(in: set) else {
			throw LanguageLayerError.noRootNode
		}

		return try treeSnapshot.executeQuery(queryDef, in: set)
	}
}

extension LanguageLayer {
	private func fillMissingSublayer(for name: String, content: Content) throws -> IndexSet {
		guard let tsRanges = missingInjections[name] else {
			return IndexSet()
		}

		return try addNewSublayer(named: name, tsRanges: tsRanges, content: content)
	}

	private func addNewSublayer(named name: String, tsRanges: [TSRange], content: Content) throws -> IndexSet {
		precondition(sublayers[name] == nil)

		guard let subLang = configuration.languageProvider(name) else {
			self.missingInjections[name] = tsRanges

			return IndexSet()
		}

		let subConfig = Configuration(
			maximumLanguageDepth: max(0, configuration.maximumLanguageDepth - 1),
			languageProvider: configuration.languageProvider
		)

		let layer = try LanguageLayer(languageConfig: subLang, configuration: subConfig, ranges: tsRanges, depth: depth + 1)

		self.sublayers[name] = layer
		self.missingInjections[name] = nil

		var affectedSet = IndexSet()

		for tsRange in tsRanges {
			let rangeSet = IndexSet(integersIn: tsRange.bytes.range)

			affectedSet.formUnion(rangeSet)
		}

		return layer.parse(with: content, affecting: affectedSet, resolveSublayers: true)
	}

	private func encorporateRanges(_ tsRanges: [TSRange], content: Content) throws -> IndexSet {
		guard let includedRanges = state.tree?.includedRanges else {
			preconditionFailure("Cannot encorporateRanges into a layer that doesn't have any already defined")
		}

		var allRanges = includedRanges
		var invalidation = IndexSet()

		for newTSRange in tsRanges {
			allRanges.removeAll(where: { newTSRange.bytes.lowerBound == $0.bytes.lowerBound })

			allRanges.append(newTSRange)

			invalidation.insert(integersIn: Range(newTSRange.bytes.range)!)
		}

		// included ranges must be sorted and the above algorithm does not guarantee that
		self.parser.includedRanges = allRanges.sorted()

		let set = parse(with: content)

		invalidation.formUnion(set)

		return invalidation
	}

	/// Recursively resolve any language injections within the set.
	///
	/// This process is manual to offer the greatest control to clients.
	public func resolveSublayers(with content: LanguageLayer.Content, in set: IndexSet) throws -> IndexSet {
		guard supportsNestedLanguages else {
			return IndexSet()
		}

		// injections must be shallow
		let injections = try executeShallowQuery(.injections, in: set).injections(with: content.textProvider)
		let groupedInjections = Dictionary(grouping: injections, by: { $0.name })
		var invalidations = IndexSet()

		// they could be new, or could be updates to existing
		for pair in groupedInjections {
			let name = pair.0
			let ranges = pair.value.map { $0.tsRange }

			guard let sublayer = sublayers[name] else {
				let set = try addNewSublayer(named: name, tsRanges: ranges, content: content)

				invalidations.formUnion(set)

				continue
			}

			let set = try sublayer.encorporateRanges(ranges, content: content)

			invalidations.formUnion(set)
		}

		return invalidations
	}
}
