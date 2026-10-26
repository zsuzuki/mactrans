// swift-tools-version: 6.0

import PackageDescription
import Foundation

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let whisperRoot = ProcessInfo.processInfo.environment["WHISPER_CPP_DIR"]
    ?? packageRoot.appendingPathComponent("../whisper.cpp").standardizedFileURL.path

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
            resources: [
                .copy("Resources/ggml-silero-v6.2.0.bin"),
                .copy("Resources/Silero-LICENSE.txt"), .copy("Resources/README.txt")
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Security"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("UniformTypeIdentifiers"),
                .unsafeFlags([
                    "-L", "\(whisperRoot)/build/src",
                    "-L", "\(whisperRoot)/build/ggml/src",
                    "-L", "\(whisperRoot)/build/ggml/src/ggml-blas",
                    "-L", "\(whisperRoot)/build/ggml/src/ggml-metal",
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
        .testTarget(
            name: "MacTransTests", dependencies: ["MacTrans"],
            linkerSettings: [.unsafeFlags([
                "-Xlinker", "-rpath", "-Xlinker", "\(whisperRoot)/build/src",
                "-Xlinker", "-rpath", "-Xlinker", "\(whisperRoot)/build/ggml/src",
                "-Xlinker", "-rpath", "-Xlinker", "\(whisperRoot)/build/ggml/src/ggml-blas",
                "-Xlinker", "-rpath", "-Xlinker", "\(whisperRoot)/build/ggml/src/ggml-metal"
            ])]
        ),
        .target(
            name: "WhisperBridge",
            publicHeadersPath: "include",
            cSettings: [
                .unsafeFlags([
                    "-I", "\(whisperRoot)/include",
                    "-I", "\(whisperRoot)/ggml/include",
                    "-I", "\(whisperRoot)/ggml/src"
                ])
            ]
        )
    ]
)
