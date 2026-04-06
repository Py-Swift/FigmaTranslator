// swift-tools-version: 6.0
import PackageDescription

let local = true

let figmaApi: Package.Dependency = local
    ? .package(path: "../FigmaApi")
    : .package(url: "https://github.com/Py-Swift/FigmaApi.git", branch: "master")

let pySwiftAST: Package.Dependency = .package(url: "https://github.com/Py-Swift/PySwiftAST.git", branch: "master")

let package = Package(
    name: "FigmaTranslator",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "FigmaTranslator", targets: ["FigmaTranslator"]),
        .library(name: "KivyCanvasDesigner", targets: ["KivyCanvasDesigner"]),
        .library(name: "KivyWidgetDesigner", targets: ["KivyWidgetDesigner"]),
    ],
    dependencies: [
        figmaApi,
        pySwiftAST,
        .package(url: "https://github.com/Py-Swift/SwiftyKvLang", branch: "master"),
    ],
    targets: [
        .target(
            name: "FigmaTranslator",
            dependencies: [
                .product(name: "FigmaApi", package: "FigmaApi"),
                .product(name: "KvParser", package: "SwiftyKvLang"),
                .product(name: "KivyWidgetRegistry", package: "SwiftyKvLang"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        .target(
            name: "KivyCanvasDesigner",
            dependencies: [
                .product(name: "FigmaApi", package: "FigmaApi"),
                .product(name: "PySwiftCodeGen", package: "PySwiftAST"),
                .product(name: "KivyWidgetRegistry", package: "SwiftyKvLang"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        .target(
            name: "KivyWidgetDesigner",
            dependencies: [
                .product(name: "FigmaApi", package: "FigmaApi"),
                .product(name: "PySwiftCodeGen", package: "PySwiftAST"),
                .target(name: "KivyCanvasDesigner"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
    ]
)
