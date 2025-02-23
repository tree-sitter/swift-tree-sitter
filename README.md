<div align="center">

[![Build Status][build status badge]][build status]
[![Platforms][platforms badge]][platforms]
[![Documentation][documentation badge]][documentation]
[![Discord][discord badge]][discord]

</div>

# SwiftTreeSitter

Swift API for the [tree-sitter](https://tree-sitter.github.io/) incremental parsing system.

- Close to full coverage of the C API
- Swift/Foundation types where possible
- Standard query result mapping for highlights and injections
- Query predicate/directive support via `ResolvingQueryMatchSequence`
- Nested language support
- Swift concurrency support where possible

# Structure

This project is actually split into two parts: `SwiftTreeSitter` and `SwiftTreeSitterLayer`.

The SwiftTreeSitter target is a close match to the C runtime API. It adds only a few additional types to help support querying. It is fairly low-level, and there will be significant work to use it in a real project.

SwiftTreeSitterLayer is an abstraction built on top of SwiftTreeSitter. It supports documents with nested languages and transparent querying across those nestings. It also supports asynchronous language resolution. While still low-level, SwiftTreeSitterLayer is easier to work with while also supporting more features.

And yet there's more! If you are looking a higher-level system for syntax highlighting and other syntactic operations, you might want to have a look at [Neon](https://github.com/ChimeHQ/Neon). It is much easier to integrate with a text system, and has lots of additional performance-related features.


## Integration

```swift
dependencies: [
    .package(url: "https://github.com/ChimeHQ/SwiftTreeSitter")
],
targets: [
    .target(
        name: "MySwiftTreeSitterTarget",
        dependencies: ["SwiftTreeSitter"]
    ),
    .target(
        name: "MySwiftTreeSitterLayerTarget",
        dependencies: [
            .product(name: "SwiftTreeSitterLayer", package: "SwiftTreeSitter"),
        ]
    ),
]
```

## Range Translation

The tree-sitter runtime operates on raw string data. This means it works with bytes, and is string-encoding-sensitive. Swift's `String` type is an abstraction on top of raw data and cannot be used directly. To overcome this, you also have to be aware of the types of indexes you are using and how string data is translated back and forth.

To help, SwiftTreeSitter supports the base tree-sitter encoding facilities. You can control this via `Parser.parse(tree:encoding:readBlock:)`. But, by default this will assume UTF-16-encoded data. This is done to offer direct compatibility with Foundation strings and `NSRange`, which both use UTF-16.

Also, to help with all the back and forth, SwiftTreeSitter includes some accessors that are NSRange-based, as well as extension on `NSRange`. These **must** be used when working with the native tree-sitter types unless you take care to handle encoding yourself.

To keep things clear, consistent naming and types are used. `Node.byteRange` returns a `Range<UInt32>`, which is an encoding-dependent value. `Node.range` is an `NSRange` which is defined to use UTF-16.
    
```swift
let node = tree.rootNode!

// this is encoding-dependent and cannot be used with your storage
node.byteRange

// this is a UTF-16-assumed translation of the byte ranges
node.range

// converting UTF-16-based changed ranges on re-parse
let ranges: [NSRange] = newtree.changedRanges(from: oldTree)
    .map{ $0.bytes.range }
```

## Query Conflicts

SwiftTreeSitter does its best to resolve poor/incorrect query constructs, which are surprisingly common.

When using injections, child query ranges are automatically expanded using parent matches. This handles cases where a parent has queries that overlap with children in conflicting ways. Without expansion, it is possible to construct queries that fall within children ranges but produce on parent matches.

All matches are sorted by:

- depth
- location in content
- specificity of match label (more components => more specific)
- occurrence in the query source

Even with these, it is possible to produce queries that will result in "incorrect" behavior that are either ambiguous or undefined in the query definition.

## Highlighting

A very common use of tree-sitter is to do syntax highlighting. It is possible to use this library directly, especially if your source text does not change. Here's a little example that sets everything up with a SPM-bundled language.

First, check out how it works with SwiftTreeSitterLayer. It's complex, but does a lot for you.

````swift
// LanguageConfiguration takes care of finding and loading queries in SPM-created bundles.
let markdownConfig = try LanguageConfiguration(tree_sitter_markdown(), name: "Markdown")
let markdownInlineConfig = try LanguageConfiguration(
    tree_sitter_markdown_inline(),
    name: "MarkdownInline",
    bundleName: "TreeSitterMarkdown_TreeSitterMarkdownInline"
)
let swiftConfig = try LanguageConfiguration(tree_sitter_swift(), name: "Swift")

// Unfortunately, injections do not use standardized language names, and can even be content-dependent. Your system must do this mapping.
let config = LanguageLayer.Configuration(
    languageProvider: {
        name in
        switch name {
        case "markdown":
            return markdownConfig
        case "markdown_inline":
            return markdownInlineConfig
        case "swift":
            return swiftConfig
        default:
            return nil
        }
    }
)

let rootLayer = try LanguageLayer(languageConfig: markdownConfig, configuration: config)

let source = """
# this is markdown

```swift
func main(a: Int) {
}
```

## also markdown

```swift
let value = "abc"
```
"""

rootLayer.replaceContent(with: source)

let fullRange = NSRange(source.startIndex..<source.endIndex, in: source)

let textProvider = source.predicateTextProvider
let highlights = try rootLayer.highlights(in: fullRange, provider: textProvider)

for namedRange in highlights {
    print("\(namedRange.name): \(namedRange.range)")
}
````

You can also use SwiftTreeSitter directly:

```swift
let swiftConfig = try LanguageConfiguration(tree_sitter_swift(), name: "Swift")

let parser = Parser()
try parser.setLanguage(swiftConfig.language)

let source = """
func main() {}
"""
let tree = parser.parse(source)!

let query = swiftConfig.queries[.highlights]!

let cursor = query.execute(in: tree)
let highlights = cursor
    .resolve(with: .init(string: source))
    .highlights()

for namedRange in highlights {
    print("range: ", namedRange)
}
```

## Language Parsers

Tree-sitter language parsers are separate projects, and you'll probably need at least one. More details are available in the [documentation][documentation]. How they can be installed an incorporated varies.

Here's a list of parsers that support SPM. Since you're here, you might find that convenient. And the `LanguageConfiguration` type supports loading bundled queries directly.

| Parser | Make | SPM | Official Repo |
| --- | :---: | :---: | :---: |
| [Bash](https://github.com/tree-sitter/tree-sitter-bash) | | ✅ | ✅ |
| [C](https://github.com/tree-sitter/tree-sitter-c) | | ✅ | ✅ |
| [C++](https://github.com/tree-sitter/tree-sitter-cpp) | | ✅ | ✅ |
| [C#](https://github.com/tree-sitter/tree-sitter-c-sharp) | | ✅ | ✅ |
| [Clojure](https://github.com/mattmassicotte/tree-sitter-clojure/tree/feature/spm) | | ✅ | |
| [CSS](https://github.com/tree-sitter/tree-sitter-css) | ✅ | ✅ | ✅ |
| [Dockerfile](https://github.com/camdencheek/tree-sitter-dockerfile) | ✅ | ✅ | ✅ |
| [Diff](https://github.com/the-mikedavis/tree-sitter-diff) | | ✅ | ✅ |
| [Elixir](https://github.com/elixir-lang/tree-sitter-elixir) | ✅ | ✅ | ✅ |
| [Elm](https://github.com/elm-tooling/tree-sitter-elm) | | ✅ | ✅ |
| [Go](https://github.com/tree-sitter/tree-sitter-go) | ✅ | ✅ | ✅ |
| [GoMod](https://github.com/camdencheek/tree-sitter-go-mod) | ✅ | ✅ | ✅ |
| [GoWork](https://github.com/omertuc/tree-sitter-go-work) | ✅ | | |
| [Haskell](https://github.com/tree-sitter/tree-sitter-haskell) | | ✅ | ✅ |
| [HCL](https://github.com/MichaHoffmann/tree-sitter-hcl) | | ✅ | ✅ |
| [HTML](https://github.com/tree-sitter/tree-sitter-html) | | ✅ | ✅ |
| [Java](https://github.com/tree-sitter/tree-sitter-java) | ✅ | ✅ | ✅ |
| [Javascript](https://github.com/tree-sitter/tree-sitter-javascript) | | ✅ | ✅ |
| [JSON](https://github.com/tree-sitter/tree-sitter-json) | ✅ | ✅ | ✅ |
| [JSDoc](https://github.com/tree-sitter/tree-sitter-jsdoc) | | ✅ | ✅ |
| [Julia](https://github.com/tree-sitter/tree-sitter-julia) | | ✅ | ✅ |
| [Kotlin](https://github.com/fwcd/tree-sitter-kotlin) | ✅ | | |
| [Latex](https://github.com/latex-lsp/tree-sitter-latex) | ✅ | ✅ | ✅ |
| [Lua](https://github.com/Azganoth/tree-sitter-lua) | | ✅ | ✅ |
| [Markdown](https://github.com/MDeiml/tree-sitter-markdown) | | ✅ | ✅ |
| [OCaml](https://github.com/tree-sitter/tree-sitter-ocaml) | | ✅ | ✅ |
| [Perl](https://github.com/ganezdragon/tree-sitter-perl) | | ✅ | ✅ |
| [PHP](https://github.com/tree-sitter/tree-sitter-php) | ✅ | ✅ | ✅ |
| [Pkl](https://github.com/apple/tree-sitter-pkl) | | ✅ | ✅ |
| [Python](https://github.com/tree-sitter/tree-sitter-python) | | ✅ | ✅ |
| [Ruby](https://github.com/tree-sitter/tree-sitter-ruby) | ✅ | ✅ | ✅ |
| [Rust](https://github.com/tree-sitter/tree-sitter-rust) | | ✅ | ✅ |
| [Scala](https://github.com/tree-sitter/tree-sitter-scala) | | ✅ | ✅ |
| [SQL](https://github.com/DerekStride/tree-sitter-sql/tree/gh-pages) | | ✅ | ✅ |
| [SSH](https://github.com/metio/tree-sitter-ssh-client-config) | | ✅ | ✅ |
| [Swift](https://github.com/alex-pinkus/tree-sitter-swift/tree/with-generated-files) | ✅ | ✅ | ✅ |
| [TOML](https://github.com/mattmassicotte/tree-sitter-toml/feature/spm) | | ✅ | |
| [Tree-sitter query language](https://github.com/nvim-treesitter/tree-sitter-query) | | ✅ | ✅ |
| [Typescript](https://github.com/tree-sitter/tree-sitter-typescript) | | ✅ | ✅ |
| [Verilog](https://github.com/tree-sitter/tree-sitter-verilog) | | ✅ | ✅ |
| [YAML](https://github.com/mattmassicotte/tree-sitter-yaml/tree/feature/spm) | | ✅ | |
| [Zig](https://github.com/maxxnino/tree-sitter-zig) | ✅ | ✅ | ✅ |

## Contributing and Collaboration

I would love to hear from you! Issues or pull requests work great. A [Discord server][discord] is also available for live help, but I have a strong bias towards answering in the form of documentation.

I prefer collaboration, and would love to find ways to work together if you have a similar project.

I prefer indentation with tabs for improved accessibility. But, I'd rather you use the system you want and make a PR than hesitate because of whitespace.

By participating in this project you agree to abide by the [Contributor Code of Conduct](CODE_OF_CONDUCT.md).

[build status]: https://github.com/tree-sitter/swift-tree-sitter/actions
[build status badge]: https://github.com/tree-sitter/swift-tree-sitter/workflows/CI/badge.svg
[platforms]: https://swiftpackageindex.com/tree-sitter/swift-tree-sitter
[platforms badge]: https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Ftree-sitter%2Fswift-tree-sitter%2Fbadge%3Ftype%3Dplatforms
[documentation]: https://swiftpackageindex.com/tree-sitter/swift-tree-sitter/main/documentation
[documentation badge]: https://img.shields.io/badge/Documentation-DocC-blue
[discord]: https://discord.gg/esFpX6sErJ
[discord badge]: https://img.shields.io/badge/Discord-purple?logo=Discord&label=Chat&color=%235A64EC
