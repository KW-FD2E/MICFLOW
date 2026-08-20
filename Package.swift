// swift-tools-version:5.9
import PackageDescription

// whisper.cpp jest budowany osobno przez scripts/build_whisper.sh (cmake + Metal),
// a tutaj tylko dolinkowany. Ścieżki są względne wobec katalogu pakietu.
let whisperInclude = "vendor/whisper.cpp/include"
let ggmlInclude = "vendor/whisper.cpp/ggml/include"
let whisperLibs = "vendor/whisper.cpp/build/bin"

let package = Package(
    name: "DyktowanieApp",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .systemLibrary(
            name: "CWhisper",
            path: "Sources/CWhisper"
        ),
        .executableTarget(
            name: "DyktowanieApp",
            dependencies: ["CWhisper"],
            path: "Sources/DyktowanieApp",
            swiftSettings: [
                .unsafeFlags([
                    "-Xcc", "-I\(whisperInclude)",
                    "-Xcc", "-I\(ggmlInclude)"
                ])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L\(whisperLibs)",
                    "-lwhisper",
                    // Przy uruchomieniu z .app biblioteki leżą w Contents/Frameworks;
                    // druga ścieżka pozwala odpalać binarkę wprost z .build/.
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                    "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../../\(whisperLibs)"
                ])
            ]
        )
    ]
)
