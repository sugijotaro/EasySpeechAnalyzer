// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "EasySpeechAnalyzer",
    platforms: [
        .iOS("26.0")
    ],
    products: [
        .library(
            name: "EasySpeechAnalyzer",
            targets: ["EasySpeechAnalyzer"]
        ),
    ],
    targets: [
        .target(
            name: "EasySpeechAnalyzer"
        ),
    ],
    swiftLanguageModes: [.v6]
)
