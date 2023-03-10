import Foundation
import tree_sitter

/// This is a closure whose output URL is to the directory which has the language `scm` files in its hierarchy. The
/// ultimate search is recursive; if the resource files are embedded within hierarchy
/// `Resources.bundle/Contents/Resources/queries`, giving the path to `Resources.bundle` will result in the files
/// being found.
public typealias DirectoryProvider = () -> URL

public struct Language {
    public var tsLanguage: UnsafePointer<TSLanguage>
    public var directoryProvider: DirectoryProvider?

    /// Creates an instance.
    /// - Parameters:
    ///   - language: The language to parse.
    ///   - directoryProvider: An optional closure which would return a `URL` that can be searched for resources
    ///   used by the language (such as highlights.scm).
    public init(language: UnsafePointer<TSLanguage>, directoryProvider: DirectoryProvider? = nil) {
        self.tsLanguage = language
        self.directoryProvider = directoryProvider
    }

    /// Creates an instance.
    /// - Parameters:
    ///   - language: The language to parse.
    ///   - languageName: The name of the language. This is used to attempt to find the embeeded resource directory
    ///    for the language (which would contain files like highlights.scm).
    public init(language: UnsafePointer<TSLanguage>, languageName: String) {
        self.init(language: language, directoryProvider: embeddedResourceProvider(named: languageName))
    }
}

extension Language {
    public static var version: Int {
        return Int(TREE_SITTER_LANGUAGE_VERSION)
    }

    public static var minimumCompatibleVersion: Int {
        return Int(TREE_SITTER_MIN_COMPATIBLE_LANGUAGE_VERSION)
    }

    public var ABIVersion: Int {
        return Int(ts_language_version(tsLanguage))
    }
    
    public var fieldCount: Int {
        return Int(ts_language_field_count(tsLanguage))
    }

    public var symbolCount: Int {
        return Int(ts_language_symbol_count(tsLanguage))
    }

    public func fieldName(for id: Int) -> String? {
        guard let str = ts_language_field_name_for_id(tsLanguage, TSFieldId(id)) else { return nil }
        
        return String(cString: str)
    }
    
    public func fieldId(for name: String) -> Int? {
        let count = UInt32(name.utf8.count)
        
        let value = name.withCString { cStr in
            return ts_language_field_id_for_name(tsLanguage, cStr, count)
        }
        
        return Int(value)
    }

    public func symbolName(for id: Int) -> String? {
        guard let str = ts_language_symbol_name(tsLanguage, TSSymbol(id)) else {
            return nil
        }

        return String(cString: str)
    }
}

extension Language: Equatable {
    public static func ==(lhs: Language, rhs: Language) -> Bool {
        return lhs.tsLanguage == rhs.tsLanguage
    }
}

/// For languages where the resources are embedded in the app's bundle, this function returns the directory provider
/// that finds the location of the resource's containing folder on disk. The match is fuzzy so if a Swift Package
/// Manager's resource bundle is in use it could take the shape of `PackageName_PackageName.bundle` in which case
/// this function only needs `PackageName` as its input to find the path to the bundle.
///
/// This function also normalizes for tests so that resources can be found while under test. `Bundle.main` is different
/// in an app context vs an XCTest context.
/// - Parameter resourceDirectory: The name of the directory or bundle to search for embedded within the main bundle.
/// - Returns: If found, returns the directory provider closure.
private func embeddedResourceProvider(named resourceDirectory: String) -> DirectoryProvider? {
    let fileManager = FileManager.default
    var bundle = Bundle.main

    if bundle.isXCTestRunner {
        bundle = Bundle.allBundles
            .first(where: { $0.bundlePath.components(separatedBy: "/").last!.contains("Tests.xctest") == true })!
    }

    guard
        let foundBundleURL = try? fileManager
            .contentsOfDirectory(at: bundle.bundleURL, includingPropertiesForKeys: nil)
            .first(where: { $0.lastPathComponent.contains(resourceDirectory) })
    else { return nil }

    return { foundBundleURL }
}

public extension Language {
    var highlightsFileURL: URL? {
        guard let url = directoryProvider?() else { return nil }
        return findFile("highlights.scm", in: url)
    }

    var injectionsFileURL: URL? {
        guard let url = directoryProvider?() else { return nil }
        return findFile("injections.scm", in: url)
    }

    private func findFile(_ filename: String, in directory: URL) -> URL? {
        let fileManager = FileManager.default

        do {
            let contents = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.nameKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            )

            for item in contents {
                var isDirectory: ObjCBool = false
                fileManager.fileExists(atPath: item.path, isDirectory: &isDirectory)

                if isDirectory.boolValue {
                    if let foundURL = findFile(filename, in: item.standardizedFileURL) {
                        return foundURL
                    }
                } else {
                    if item.lastPathComponent == filename {
                        return item
                    }
                }
            }
        }
        catch {
            return nil
        }

        return nil
    }
}

private extension Bundle {
    var isXCTestRunner: Bool {
        guard NSClassFromString("XCTest") != nil else { return false }
        return bundlePath.contains("/Developer/Library/Xcode/Agents")
    }
}


#if !os(WASI)
public extension Language {
    /// Construct a query object from data in a file.
    func query(contentsOf url: URL) throws -> Query {
        let data = try Data(contentsOf: url)

        return try Query(language: self, data: data)
    }
}
#endif
