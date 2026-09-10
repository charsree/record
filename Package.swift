// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Record",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Record", targets: ["Record"])
    ],
    targets: [
        .target(
            name: "CWhisperBridge",
            path: "Sources/CWhisperBridge",
            publicHeadersPath: "include",
            cSettings: [
                .unsafeFlags(["-I/opt/homebrew/include"])
            ],
            linkerSettings: [
                .unsafeFlags(["-L/opt/homebrew/lib"]),
                .linkedLibrary("whisper"),
                .linkedLibrary("ggml")
            ]
        ),
        .executableTarget(
            name: "Record",
            dependencies: ["CWhisperBridge"],
            path: "Sources/Record",
            linkerSettings: [
                .unsafeFlags(["-L/opt/homebrew/lib"]),
                .linkedLibrary("whisper"),
                .linkedLibrary("ggml"),
                .linkedLibrary("sqlite3")
            ]
        ),
        .testTarget(
            name: "RecordTests",
            dependencies: ["Record"],
            path: "Tests/RecordTests"
        )
    ]
)
