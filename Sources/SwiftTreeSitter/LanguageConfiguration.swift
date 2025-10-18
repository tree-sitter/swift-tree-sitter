import Foundation

import TreeSitter

/// A structure that holds a language name and its associated queries.
public struct LanguageData: Sendable {
	public let name: String
	public let queries: [Query.Definition: Query]

	public init(name: String, queries: [Query.Definition: Query]) {
		self.name = name
		self.queries = queries
	}
}

enum LanguageConfigurationError: Error {
	case queryDirectoryNotFound
	case queryDirectoryNotReadable(URL)
}

/// A structure that holds a language parser, name, and its associated queries.
public struct LanguageConfiguration: Sendable {
	public let language: Language
	public let data: LanguageData

	/// Create a configuration with the language parser reference and details about its queries.
	public init(_ language: Language, data: LanguageData) {
		self.language = language
		self.data = data
	}

	/// Create a configuration with the language parser reference, a name, and the query definitions.
	public init(_ language: Language, name: String, queries: [Query.Definition: Query]) {
		self.language = language
		self.data = LanguageData(name: name, queries: queries)
	}

	public var name: String {
		data.name
	}

	public var queries: [Query.Definition: Query] {
		data.queries
	}
}

#if !os(WASI)
extension LanguageConfiguration {
	/// Create a configuration with a pointer to the language parser structure, a name, and the query definitions.
	public init(_ tsLanguage: OpaquePointer, name: String, queries: [Query.Definition: Query]) {
        self.init(Language(tsLanguage), name: name, queries: queries)
    }

    /// Create a configuration with a name assumed to match a bundle.
    ///
	/// When using SPM to build and package tree-sitter parsers, at build time a bundle will be created for the package. Typically, this bundle will also include the query definition `.scm` files, via its `resources` property. This initializer can be used **if** the parser name and bundle follow the pattern `TreeSitter\(name)_TreeSitter\(name)`.
	public init(_ language: Language, name: String) throws {
		let bundleName = "TreeSitter\(name)_TreeSitter\(name)"

		try self.init(language, name: name, bundleName: bundleName)
	}

    /// Create a configuration with a name assumed to match a bundle.
	///
	/// When using SPM to build and package tree-sitter parsers, at build time a bundle will be created for the package. Typically, this bundle will also include the query definition `.scm` files, via its `resources` property. This initializer can be used **if** the parser name and bundle follow the pattern `TreeSitter\(name)_TreeSitter\(name)`.
	public init(_ tsLanguage: OpaquePointer, name: String) throws {
		try self.init(Language(tsLanguage), name: name)
	}

	/// Create a configuration with a name and an independent bundle name.
	///
	/// When using SPM to build and package tree-sitter parsers, at build time a bundle will be created for the package. Typically, this bundle will also include the query definition `.scm` files, via its `resources` property. This initializer is good option if the package output bundle's naming convention doesn't follow a common pattern. This frequently happens when on parser package includes more than one parser implementation.
	public init(_ language: Language, name: String, bundleName: String) throws {
		guard let queriesURL = Self.bundleQueriesDirectoryURL(for: bundleName) else {
			throw LanguageConfigurationError.queryDirectoryNotFound
		}

		let path = queriesURL.standardizedFileURL.path

		if FileManager.default.isReadableFile(atPath: path) == false {
			throw LanguageConfigurationError.queryDirectoryNotReadable(queriesURL)
		}

		let queries = try Query.queries(for: language, in: queriesURL)

		self.init(language, name: name, queries: queries)
	}

	/// Create a configuration with a name, and an independent bundle name.
	public init(_ tsLanguage: OpaquePointer, name: String, bundleName: String) throws {
		try self.init(Language(tsLanguage), name: name, bundleName: bundleName)
	}

	/// Create a configuration a name and a url to a directory of query definition files.
	///
	/// This is a more-general way to initialize configuration objects. It is useful if the query definitions you'd like to use are not part of a parser package, or if their on-disk layout doesn't match the heuristics used for the more automated initializers.
	public init(_ language: Language, name: String, queriesURL: URL) throws {
		let queries = try Query.queries(for: language, in: queriesURL)

		self.init(language, name: name, queries: queries)
	}

	/// Create a configuration with a pointer to the language parser structure, a name, and a url to a directory of query definition files.
	///
	/// This is a more-general way to initialize configuration objects. It is useful if the query definitions you'd like to use are not part of a parser package, or if their on-disk layout doesn't match the heuristics used for the more automated initializers.
	public init(_ tsLanguage: OpaquePointer, name: String, queriesURL: URL) throws {
		try self.init(Language(tsLanguage), name: name, queriesURL: queriesURL)
	}
}

extension LanguageConfiguration {
	static let bundleContainerURL: URL? = {
		let mainBundle = Bundle.main

		guard mainBundle.isXCTestRunner else {
			return mainBundle.resourceURL
		}

		// we have to go up one directory, because Xcode puts SPM dependency bundles
		return Bundle.testBundle?.bundleURL.deletingLastPathComponent()
	}()

	static func bundleQueriesDirectoryURL(for bundleName: String) -> URL? {
#if os(macOS) || targetEnvironment(macCatalyst)
		let bundlePath = bundleContainerURL?.appendingPathComponent("\(bundleName).bundle", isDirectory: true)
		
		guard let bundlePath else { return nil }
		
		// Depending on how you compile a macOS executable, this path varies.
		// Couldn't nail down when with compiler flags
		//     (Xcode seems to create the longer paths, SwiftPM the shorter ones)
		let shortQueriesPath = bundlePath.appendingPathComponent("queries", isDirectory: true)
		if FileManager.default.fileExists(atPath: shortQueriesPath.path) {
			return shortQueriesPath
		}
		return bundlePath.appendingPathComponent("Contents/Resources/queries", isDirectory: true)
#elseif os(iOS) || os(tvOS) || os(visionOS) || os(watchOS)
		let bundlePath = bundleContainerURL?.appendingPathComponent("\(bundleName).bundle", isDirectory: true)
		
        return bundlePath?.appendingPathComponent("queries", isDirectory: true)
#else
		// Linux and Windows use .resources instead of .bundle
		let resourcePath = bundleContainerURL?.appendingPathComponent("\(bundleName).resources", isDirectory: true)
		
		return resourcePath?.appendingPathComponent("queries", isDirectory: true)
#endif
	}
}

extension Query {
	static func query(definition: Query.Definition, for language: Language, in url: URL) throws -> Query? {
		let fullURL = url.appendingPathComponent(definition.filename).standardizedFileURL

		guard FileManager.default.isReadableFile(atPath: fullURL.path) else {
			return nil
		}

		return try Query(language: language, url: fullURL)
	}

	static func queries(for language: Language, in url: URL) throws -> [Query.Definition: Query] {
		var queries = [Query.Definition: Query]()

		if let query = try Self.query(definition: .injections, for: language, in: url) {
			queries[.injections] = query
		}

		if let query = try Self.query(definition: .highlights, for: language, in: url) {
			queries[.highlights] = query
		}

		if let query = try Self.query(definition: .locals, for: language, in: url) {
			queries[.locals] = query
		}

		return queries
	}
}
#endif
