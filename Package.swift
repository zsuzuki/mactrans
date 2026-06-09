// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MacTrans",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "MacTrans", targets: ["MacTrans"])
    ],
    targets: [
        .executableTarget(
            name: "MacTrans",
            dependencies: ["WhisperBridge"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Security"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("UniformTypeIdentifiers"),
                .unsafeFlags([
                    "-L", "../whisper.cpp/build/src",
                    "-L", "../whisper.cpp/build/ggml/src",
                    "-L", "../whisper.cpp/build/ggml/src/ggml-blas",
                    "-L", "../whisper.cpp/build/ggml/src/ggml-metal",
                    "-lwhisper",
                    "-lggml",
                    "-lggml-base",
                    "-lggml-cpu",
                    "-lggml-blas",
                    "-lggml-metal",
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"
                ])
            ]
        ),
        .target(
            name: "WhisperBridge",
            publicHeadersPath: "include",
            cSettings: [
                .unsafeFlags([
                    "-I", "../whisper.cpp/include",
                    "-I", "../whisper.cpp/ggml/include",
                    "-I", "../whisper.cpp/ggml/src"
                ])
            ]
        )
    ]
)
