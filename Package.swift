// swift-tools-version: 5.9

import PackageDescription

let settings: [SwiftSetting] = [
	.enableExperimentalFeature("StrictConcurrency")
]

let package = Package(
	name: "SwiftTreeSitter",
	platforms: [
		.macOS(.v10_13),
		.macCatalyst(.v13),
		.iOS(.v12),
		.tvOS(.v12),
		.watchOS(.v5),
		.visionOS(.v1),
	],
	products: [
		.library(name: "SwiftTreeSitter", targets: ["SwiftTreeSitter"]),
		.library(name: "SwiftTreeSitterLayer", targets: ["SwiftTreeSitterLayer"]),
	],
	dependencies: [
		.package(url: "https://github.com/tree-sitter/tree-sitter", .upToNextMinor(from: "0.25.0"))
	],
	targets: [
		.target(
			name: "TestTreeSitterSwift",
			path: "tree-sitter-swift",
			sources: ["src/parser.c", "src/scanner.c"],
			publicHeadersPath: "bindings/swift",
			cSettings: [.headerSearchPath("src")]
		),
		.target(
			name: "SwiftTreeSitter",
			dependencies: [
				.product(name: "TreeSitter", package: "tree-sitter")
			],
			swiftSettings: settings
		),
		.testTarget(
			name: "SwiftTreeSitterTests",
			dependencies: ["SwiftTreeSitter", "TestTreeSitterSwift"],
			swiftSettings: settings
		),
		.target(
			name: "SwiftTreeSitterLayer",
			dependencies: ["SwiftTreeSitter"],
			swiftSettings: settings
		),
		.testTarget(
			name: "SwiftTreeSitterLayerTests",
			dependencies: ["SwiftTreeSitterLayer", "TestTreeSitterSwift"],
			swiftSettings: settings
		),
	]
)
