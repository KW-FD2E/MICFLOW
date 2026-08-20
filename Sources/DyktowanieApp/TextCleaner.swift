import Foundation

/// Wybór modelu czyszczącego. Oba warianty Bielika mają inny kompromis
/// między szybkością a wiernością wobec tego, co użytkownik faktycznie powiedział.
enum CleanupModel: String, CaseIterable {
    case disabled
    case fast
    case faithful

    var identifier: String? {
        switch self {
        case .disabled:  return nil
        case .fast:      return "vqstudio/Bielik-4.5B-v3.0-Instruct-MLX-4bit"
        case .faithful:  return "speakleash/Bielik-11B-v3.0-Instruct-MLX-4bit"
        }
    }

    var title: String {
        switch self {
        case .disabled:  return "Wyłączone (sam Whisper)"
        case .fast:      return "Szybki — Bielik 4,5B (~1,5 s)"
        case .faithful:  return "Wierny — Bielik 11B (~5 s)"
        }
    }
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

    private(set) var model: CleanupModel = .disabled
    private(set) var isReady = false

    var onStateChange: ((String) -> Void)?

    deinit {
        shutdown()
    }

    // MARK: - Cykl życia procesu

    func start(model: CleanupModel) throws {
        shutdown()
        self.model = model

        guard let identifier = model.identifier else {
            onStateChange?("Czyszczenie wyłączone")
            return
        }

        let root = ModelLocator.projectRoot
        let python = root.appendingPathComponent(".venv/bin/python")
        let script = root.appendingPathComponent("scripts/cleanup.py")

        guard FileManager.default.fileExists(atPath: python.path) else {
            throw CleanerError.pythonMissing(python.path)
        }

        let process = Process()
        process.executableURL = python
        process.arguments = [script.path, "--serve"]

        var environment = ProcessInfo.processInfo.environment
        environment["BIELIK_MODEL"] = identifier
        // Bez tego Python buforuje stdout i odpowiedzi nie docierają na czas.
        environment["PYTHONUNBUFFERED"] = "1"
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
    func clean(text: String) throws -> String {
        guard model != .disabled else { return text }
        guard isReady, let input else { throw CleanerError.notRunning }

        let request = try JSONSerialization.data(withJSONObject: ["text": text])
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
