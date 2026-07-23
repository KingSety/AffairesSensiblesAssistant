// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "LocalVectorSearch",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "LocalVectorSearch", targets: ["LocalVectorSearch"]),
        .executable(name: "build-episode-embeddings", targets: ["BuildEpisodeEmbeddings"]),
    ],
    targets: [
        .target(name: "LocalVectorSearch"),
        .executableTarget(
            name: "BuildEpisodeEmbeddings",
            dependencies: ["LocalVectorSearch"]
        ),
        .testTarget(
            name: "LocalVectorSearchTests",
            dependencies: ["LocalVectorSearch"]
        ),
    ]
)
