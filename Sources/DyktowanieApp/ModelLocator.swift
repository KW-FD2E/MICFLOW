import Foundation

/// Znajduje plik modelu Whisper. Model waży pół giga, więc nie kopiujemy go
/// do pakietu .app przy każdej przebudowie — szukamy go w kilku miejscach.
enum ModelLocator {
    static let whisperModelName = "ggml-large-v3-turbo-q5_0.bin"
    static let vadModelName = "ggml-silero-v5.1.2.bin"

    static func whisperModel() -> String? {
        locate(whisperModelName)
    }

    static func vadModel() -> String? {
        locate(vadModelName)
    }

    private static func locate(_ name: String) -> String? {
        for candidate in searchPaths(for: name) where FileManager.default.fileExists(atPath: candidate.path) {
            return candidate.path
        }
        return nil
    }

    static func searchPaths(for name: String) -> [URL] {
        var paths: [URL] = []

        if let resources = Bundle.main.resourceURL {
            paths.append(resources.appendingPathComponent("models/\(name)"))
        }

        let appSupport = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Dyktowanie/models/\(name)")
        paths.append(appSupport)

        // Katalog projektu — wygodne przy pracy z .build/ bez pakowania do .app.
        paths.append(projectRoot.appendingPathComponent("models/\(name)"))

        return paths
    }

    /// Wyliczony ze ścieżki tego pliku w czasie kompilacji: Sources/DyktowanieApp/ → w górę o 3.
    static let projectRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}
