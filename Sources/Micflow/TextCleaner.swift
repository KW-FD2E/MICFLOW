import Foundation

/// Model czyszczący tekst.
///
/// Był tu wcześniej wybór między dwoma wariantami Bielika, ale mniejszy z nich
/// potrafił zmieniać sens wypowiedzi (np. „niech potwierdzi" → „potwierdź"),
/// więc został usunięty. Przy dyktowaniu wiadomości to zbyt kosztowny błąd,
/// żeby nadrabiać go szybkością.
enum CleanupModel {
    static let identifier = "speakleash/Bielik-11B-v3.0-Instruct-MLX-4bit"
}

/// Czyszczenie tekstu lokalnym LLM-em. Python z MLX działa jako długo żyjący
/// proces potomny — model ładuje się raz, a komunikacja idzie liniami JSON
/// przez stdin/stdout.
final class TextCleaner {
    enum CleanerError: Error, LocalizedError {
        case notRunning
        case pythonMissing(String)
        case timedOut
        case remote(String)

        var errorDescription: String? {
            switch self {
            case .notRunning:            return "Proces czyszczenia nie działa."
            case .pythonMissing(let p):  return "Brak środowiska Pythona: \(p). Uruchom scripts/setup.sh"
            case .timedOut:              return "Czyszczenie tekstu przekroczyło limit czasu."
            case .remote(let message):   return "Błąd modelu: \(message)"
            }
        }
    }

    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()

    private(set) var isReady = false

    var onStateChange: ((String) -> Void)?

    deinit {
        shutdown()
    }

    // MARK: - Cykl życia procesu

    func start() throws {
        shutdown()

        let python = ModelLocator.pythonExecutable

        guard FileManager.default.fileExists(atPath: python.path) else {
            throw CleanerError.pythonMissing(python.path)
        }
        guard let script = ModelLocator.cleanupScript() else {
            throw CleanerError.pythonMissing("cleanup.py")
        }

        let process = Process()
        process.executableURL = python
        process.arguments = [script.path, "--serve"]

        var environment = ProcessInfo.processInfo.environment
        environment["BIELIK_MODEL"] = CleanupModel.identifier
        // Bez tego Python buforuje stdout i odpowiedzi nie docierają na czas.
        environment["PYTHONUNBUFFERED"] = "1"

        // Model jest już na dysku i nigdy go nie aktualizujemy w tle. Bez tego
        // huggingface_hub przy każdym starcie odpytuje sieć o nowszą wersję —
        // przy zerwanym połączeniu (np. portal logowania w hotelu) potrafi
        // czekać na timeout zamiast od razu sięgnąć do cache.
        environment["HF_HUB_OFFLINE"] = "1"
        environment["TRANSFORMERS_OFFLINE"] = "1"
        process.environment = environment

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        try process.run()

        self.process = process
        self.input = inputPipe.fileHandleForWriting
        self.output = outputPipe.fileHandleForReading
        self.buffer = Data()

        onStateChange?("Ładowanie modelu…")

        // Pierwsza linia to sygnał gotowości — model wczytuje się kilka sekund.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let handshake = try self.readLine(timeout: 180)
                let seconds = handshake["load_seconds"] as? Double ?? 0
                DispatchQueue.main.async {
                    self.isReady = true
                    self.onStateChange?(String(format: "Model gotowy (%.1fs)", seconds))
                }
            } catch {
                DispatchQueue.main.async {
                    self.onStateChange?("Błąd modelu: \(error.localizedDescription)")
                }
            }
        }
    }

    func shutdown() {
        input?.closeFile()
        process?.terminate()
        process = nil
        input = nil
        output = nil
        isReady = false
    }

    // MARK: - Czyszczenie

    /// Wywoływać poza głównym wątkiem — blokuje do czasu odpowiedzi modelu.
    /// - Parameter language: kod języka („pl", „en"). Decyduje, którego promptu
    ///   użyje model — polski prompt na angielskim tekście powoduje tłumaczenie.
    func clean(text: String, language: String) throws -> String {
        guard isReady, let input else { throw CleanerError.notRunning }

        let request = try JSONSerialization.data(withJSONObject: ["text": text, "language": language])
        input.write(request)
        input.write(Data("\n".utf8))

        let response = try readLine(timeout: 120)
        if let message = response["error"] as? String {
            throw CleanerError.remote(message)
        }
        return response["text"] as? String ?? text
    }

    /// Czyta jedną linię JSON ze stdout procesu potomnego.
    private func readLine(timeout: TimeInterval) throws -> [String: Any] {
        guard let output else { throw CleanerError.notRunning }
        let deadline = Date().addingTimeInterval(timeout)

        while true {
            if let index = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = buffer.subdata(in: buffer.startIndex..<index)
                buffer.removeSubrange(buffer.startIndex...index)

                guard
                    let parsed = try? JSONSerialization.jsonObject(with: line),
                    let dictionary = parsed as? [String: Any]
                else {
                    continue  // pomiń śmieci na stdout, czekaj na poprawną linię
                }
                return dictionary
            }

            guard Date() < deadline else { throw CleanerError.timedOut }

            let chunk = output.availableData
            if chunk.isEmpty {
                guard process?.isRunning == true else { throw CleanerError.notRunning }
                continue
            }
            buffer.append(chunk)
        }
    }
}
