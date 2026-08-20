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

    /// Katalog projektu wyliczany w czasie DZIAŁANIA, nie kompilacji.
    ///
    /// Wcześniej brał się z `#filePath`, przez co przeniesienie folderu projektu
    /// psuło aplikację — szukała modeli tam, gdzie stała w chwili kompilacji.
    /// Teraz idziemy w górę od pakietu .app, który leży w <projekt>/build/.
    static let projectRoot: URL = {
        // Ścieżka wpisana przez scripts/bundle.sh — jedyna, która przeżywa
        // przeniesienie samego pakietu .app (np. instalację w /Applications).
        if let declared = Bundle.main.object(forInfoDictionaryKey: "DyktowanieProjectRoot") as? String,
           FileManager.default.fileExists(atPath: (declared as NSString).appendingPathComponent("Package.swift")) {
            return URL(fileURLWithPath: declared)
        }

        let bundle = Bundle.main.bundleURL          // <projekt>/build/Dyktowanie.app
        let candidate = bundle
            .deletingLastPathComponent()            // <projekt>/build
            .deletingLastPathComponent()            // <projekt>

        // Sprawdzamy po charakterystycznym pliku, czy trafiliśmy w projekt.
        if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("Package.swift").path) {
            return candidate
        }

        // Uruchomienie binarki wprost z .build/debug/ — wtedy w górę o trzy.
        let fromBuildDirectory = bundle
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: fromBuildDirectory.appendingPathComponent("Package.swift").path) {
            return fromBuildDirectory
        }

        return candidate
    }()
}
