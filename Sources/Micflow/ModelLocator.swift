import Foundation

/// Znajduje pliki, których aplikacja potrzebuje w czasie działania.
///
/// Wszystko ciężkie leży w `~/Library/Application Support/MICFLOW` — katalogu,
/// który nie wędruje razem z kodem. Dzięki temu folder z projektem można
/// przenieść, przemianować albo usunąć, a aplikacja działa dalej.
enum ModelLocator {
    static let whisperModelName = "ggml-large-v3-turbo-q5_0.bin"
    static let vadModelName = "ggml-silero-v5.1.2.bin"

    /// Stałe miejsce na modele i środowisko Pythona.
    static let runtimeRoot: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/MICFLOW")

    static var pythonExecutable: URL {
        runtimeRoot.appendingPathComponent("venv/bin/python")
    }

    /// Skrypt czyszczący jedzie w pakiecie .app, więc jest zawsze pod ręką
    /// i zawsze w wersji zgodnej z binarką.
    static func cleanupScript() -> URL? {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("cleanup.py"),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }

        // Uruchomienie wprost z .build/ podczas pracy nad kodem.
        let fromProject = developmentRoot?.appendingPathComponent("scripts/cleanup.py")
        if let fromProject, FileManager.default.fileExists(atPath: fromProject.path) {
            return fromProject
        }

        return nil
    }

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
        var paths = [runtimeRoot.appendingPathComponent("models/\(name)")]

        // Zapasowo katalog projektu — przydaje się przed pierwszą instalacją.
        if let developmentRoot {
            paths.append(developmentRoot.appendingPathComponent("models/\(name)"))
        }

        return paths
    }

    /// Katalog projektu, o ile aplikację uruchomiono z drzewa źródeł.
    /// Do normalnego działania nie jest potrzebny.
    static let developmentRoot: URL? = {
        let candidates = [
            // .build/debug/Micflow
            Bundle.main.bundleURL.deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent(),
            // build/MICFLOW.app
            Bundle.main.bundleURL.deletingLastPathComponent()
                .deletingLastPathComponent()
        ]

        return candidates.first {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("Package.swift").path)
        }
    }()
}
