import Foundation
import TreeSitter

enum ParserError: Error {
    case languageIncompatible
    case languageFailure
    case languageInvalid
    case unsupportedEncoding(String.Encoding)
}

public class Parser {
    private let internalParser: OpaquePointer
    private let encoding: String.Encoding

    public init() {
        self.internalParser = ts_parser_new()
        self.encoding = String.nativeUTF16Encoding
    }

    deinit {
        ts_parser_delete(internalParser)
    }
}

extension Parser {
	/// Access the parser's language
	///
	/// Setting a language via this property isn't possible because that operation is failable. Please use `setLanguage`.
	public var language: Language? {
		get {
			return ts_parser_language(internalParser).map { Language(language: $0) }
		}
	}

    public func setLanguage(_ language: Language) throws {
        try setLanguage(language.tsLanguage)
    }

    public func setLanguage(_ language: OpaquePointer) throws {
        let success = ts_parser_set_language(internalParser, language)

        if success == false {
            throw ParserError.languageFailure
        }
    }

    /// Resets the parser to begin at the beginning of the document.
    ///
    /// If the parser was cancelled or timed out, use this to reset it.
    public func reset() {
        ts_parser_reset(internalParser)
    }

	/// The ranges this parser will operate on.
	///
	/// This defaults to the entire document. This is useful for working with embedded languages.
	///
	/// > Warning: These values must be manually updated, and must be in ascending order. The `includedRanges` property of `Tree` can be useful for this, as it is updtaed when edits are applied.
	public var includedRanges: [TSRange] {
		get {
			var count: UInt32 = 0
			let tsRangePointer = ts_parser_included_ranges(internalParser, &count)

			let tsRangeBuffer = UnsafeBufferPointer<TreeSitter.TSRange>(start: tsRangePointer, count: Int(count))

			return tsRangeBuffer.map({ TSRange(internalRange: $0) })
		}
		set {
			let ranges = newValue.map({ $0.internalRange })

			ranges.withUnsafeBytes { bufferPtr in
				let count = newValue.count

				guard let ptr = bufferPtr.baseAddress?.bindMemory(to: TreeSitter.TSRange.self, capacity: count) else {
					preconditionFailure("unable to convert pointer")
				}

				ts_parser_set_included_ranges(internalParser, ptr, UInt32(count))
			}
		}
	}

	/// The maximum time interval the parser can run before halting.
	public var timeout: TimeInterval {
		get {
			let us = ts_parser_timeout_micros(internalParser)

			return TimeInterval(us) / 1000.0 / 1000.0
		}
		set {
			let us = UInt64(newValue * 1000.0 * 1000.0)

			ts_parser_set_timeout_micros(internalParser, us)
		}
	}
}

extension Parser {
    public typealias ReadBlock = (Int, Point) -> Data?
	public typealias DataSnapshotProvider = @Sendable (Int, Point) -> Data?

    public func parse(_ source: String) -> MutableTree? {
        guard let data = source.data(using: encoding) else { return nil }

        let dataLength = data.count

        let optionalTreePtr = data.withUnsafeBytes({ (byteBuffer) -> OpaquePointer? in
            guard let ptr = byteBuffer.baseAddress?.bindMemory(to: Int8.self, capacity: dataLength) else {
                return nil
            }

            return ts_parser_parse_string_encoding(internalParser, nil, ptr, UInt32(dataLength), TSInputEncodingUTF16LE)
        })

		return optionalTreePtr.flatMap({ MutableTree(internalTree: $0,source: source) })
    }

	public func parse(tree: Tree?, encoding: TSInputEncoding = TSInputEncodingUTF16LE, readBlock: ReadBlock) -> MutableTree? {
		return withoutActuallyEscaping(readBlock) { escapingClosure in
			let input = Input(encoding: encoding, readBlock: escapingClosure)

			guard let internalInput = input.internalInput else {
				return nil
			}

			guard let newTree = ts_parser_parse(internalParser, tree?.internalTree, internalInput) else {
				return nil
			}

			return MutableTree(internalTree: newTree,source: tree?.source)
		}
    }

	public func parse(tree: MutableTree?, encoding: TSInputEncoding = TSInputEncodingUTF16LE, readBlock: ReadBlock) -> MutableTree? {
		parse(tree: tree?.tree, encoding: encoding, readBlock: readBlock)
	}

    public func parse(tree: Tree?, string: String, limit: Int? = nil, chunkSize: Int = 2048) -> MutableTree? {
        let readFunction = Parser.readFunction(for: string, limit: limit, chunkSize: chunkSize)

        return parse(tree: tree, readBlock: readFunction)
    }

	public func parse(tree: MutableTree?, string: String, limit: Int? = nil, chunkSize: Int = 2048) -> MutableTree? {
		parse(tree: tree?.tree, string: string, limit: limit, chunkSize: chunkSize)
	}

	/// Form a function that captures an immutable view into the data of a `String`.
	public static func readFunction(for string: String, limit: Int? = nil, chunkSize: Int = 2048) -> Parser.DataSnapshotProvider {
		let usableLimit = limit ?? string.utf16.count
		let encoding = String.nativeUTF16Encoding
		
		return { (start, _) -> Data? in
			return string.data(
				at: start,
				limit: usableLimit,
				using: encoding,
				chunkSize: chunkSize
			)
		}
	}
}
