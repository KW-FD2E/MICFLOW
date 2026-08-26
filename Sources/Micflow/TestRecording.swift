import AppKit
import AVFoundation
import ApplicationServices
import Foundation

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// Nagrywanie z linii poleceń — służy do sprawdzenia, że mikrofon faktycznie
/// zapisuje sygnał, a nie ciszę, bez klikania w menu.
enum TestRecording {
    /// Sprawdza wstawianie tekstu. Po odliczeniu użytkownik ma czas, żeby
    /// kliknąć w docelowe pole tekstowe w innej aplikacji.
    static func inject(text: String, delay: Int = 5) {
        guard AXIsProcessTrusted() else {
            print("BŁĄD: brak uprawnienia Accessibility.")
            print("Przyznaj je w Ustawieniach → Prywatność i ochrona → Dostępność,")
            print("a potem uruchom test ponownie.")
            exit(1)
        }

        print("Kliknij teraz w pole tekstowe, w którym ma pojawić się tekst.")
        for remaining in stride(from: delay, to: 0, by: -1) {
            print("  \(remaining)…")
            Thread.sleep(forTimeInterval: 1)
        }

        do {
            try TextInjector().inject(text)
            print("Wysłano. Sprawdź, czy tekst pojawił się poprawnie.")
            // Schowek przywraca się z opóźnieniem, więc dajemy procesowi dożyć.
            Thread.sleep(forTimeInterval: 1)
            exit(0)
        } catch {
            print("BŁĄD: \(error.localizedDescription)")
            exit(1)
        }
    }

    /// Pełny łańcuch: WAV → whisper → Bielik. Sprawdza spięcie wszystkich
    /// elementów bez potrzeby dostępu do mikrofonu.
    static func pipeline(path: String, language: DictationLanguage) {
        let code = runPipeline(path: path, language: language)
        exit(code)
    }

    private static func runPipeline(path: String, language: DictationLanguage) -> Int32 {
        guard let modelPath = ModelLocator.whisperModel() else {
            print("BŁĄD: nie znaleziono modelu Whisper.")
            return 1
        }

        let cleaner = TextCleaner()
        defer { cleaner.shutdown() }

        do {
            try cleaner.start()

            let deadline = Date().addingTimeInterval(180)
            while !cleaner.isReady && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            }
            guard cleaner.isReady else {
                print("BŁĄD: model czyszczenia nie wystartował.")
                return 1
            }

            let transcriber = try WhisperTranscriber(
                modelPath: modelPath,
                vadModelPath: ModelLocator.vadModel(),
                language: language.whisperCode
            )
            print("Język: \(language.title)")
            let samples = try loadSamples(path: path)

            var started = Date()
            let raw = try transcriber.transcribe(samples: samples)
            let transcribeSeconds = Date().timeIntervalSince(started)

            started = Date()
            let cleaned = try cleaner.clean(text: raw, language: transcriber.detectedLanguage)
            let cleanSeconds = Date().timeIntervalSince(started)

            print(String(format: "\nTranskrypcja: %.2fs", transcribeSeconds))
            print("Wykryty język: \(transcriber.detectedLanguage)")
            print("SUROWY:  \(raw)")
            print(String(format: "\nCzyszczenie: %.2fs", cleanSeconds))
            print("GOTOWY:  \(cleaned)")
            print(String(format: "\nRAZEM: %.2fs", transcribeSeconds + cleanSeconds))
            return 0
        } catch {
            print("BŁĄD: \(error.localizedDescription)")
            return 1
        }
    }

    /// Transkrybuje gotowy plik WAV przez to samo C API, którego używa aplikacja.
    static func transcribeFile(path: String) {
        guard let modelPath = ModelLocator.whisperModel() else {
            print("BŁĄD: nie znaleziono modelu Whisper.")
            exit(1)
        }

        // Kontekst whisper.cpp musi zostać zwolniony PRZED exit() — inaczej
        // teardown backendu Metal trafia na żywe zasoby i przewraca proces.
        let code = runTranscription(modelPath: modelPath, path: path)
        exit(code)
    }

    private static func runTranscription(modelPath: String, path: String) -> Int32 {
        do {
            var started = Date()
            let transcriber = try WhisperTranscriber(modelPath: modelPath, vadModelPath: ModelLocator.vadModel())
            print(String(format: "Model wczytany w %.2fs", Date().timeIntervalSince(started)))

            let samples = try loadSamples(path: path)
            let audioSeconds = Double(samples.count) / 16000
            print(String(format: "Audio: %.1fs (%d próbek)", audioSeconds, samples.count))

            started = Date()
            let text = try transcriber.transcribe(samples: samples)
            let elapsed = Date().timeIntervalSince(started)

            print(String(format: "Transkrypcja w %.2fs (%.1fx realtime)", elapsed, audioSeconds / elapsed))
            print("--- TEKST ---")
            print(text.isEmpty ? "(pusto)" : text)
            return 0
        } catch {
            print("BŁĄD: \(error.localizedDescription)")
            return 1
        }
    }

    /// Wczytuje WAV i zwraca próbki float32 16 kHz mono — format wymagany przez whisper.
    private static func loadSamples(path: String) throws -> [Float] {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        ) else {
            return []
        }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    static func run(seconds: Double) {
        let recorder = AudioRecorder()

        Permissions.requestMicrophone { granted in
            guard granted else {
                print("BŁĄD: brak dostępu do mikrofonu.")
                exit(1)
            }

            do {
                let url = try recorder.start()
                print("Nagrywanie \(seconds)s → \(url.path)")
                print("Mów teraz…")
            } catch {
                print("BŁĄD: \(error.localizedDescription)")
                exit(1)
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                guard let result = recorder.stop() else {
                    print("BŁĄD: nagrywanie nie zwróciło pliku.")
                    exit(1)
                }
                print(String(format: "Szczyt surowego wejścia: %.4f", recorder.rawInputPeak))
                report(url: result.url, duration: result.duration)
                exit(0)
            }
        }

        RunLoop.main.run()
    }

    /// Wypisuje parametry pliku i szczytową amplitudę — zero oznacza ciszę.
    private static func report(url: URL, duration: TimeInterval) {
        print("Zapisano: \(url.path)")
        print(String(format: "Długość: %.2f s", duration))

        guard let file = try? AVAudioFile(forReading: url) else {
            print("BŁĄD: nie udało się otworzyć pliku do odczytu.")
            return
        }

        let format = file.processingFormat
        print("Format: \(Int(file.fileFormat.sampleRate)) Hz, \(file.fileFormat.channelCount) kanał(y)")
        print("Klatki: \(file.length)")

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil,
              let samples = buffer.floatChannelData?[0] else {
            print("BŁĄD: nie udało się odczytać próbek.")
            return
        }

        var peak: Float = 0
        var sumOfSquares: Float = 0
        for i in 0..<Int(buffer.frameLength) {
            let value = abs(samples[i])
            peak = max(peak, value)
            sumOfSquares += samples[i] * samples[i]
        }
        let rms = sqrt(sumOfSquares / Float(max(buffer.frameLength, 1)))

        print(String(format: "Szczyt: %.4f   RMS: %.4f", peak, rms))
        if peak < 0.001 {
            print("UWAGA: nagranie wygląda na ciszę — sprawdź uprawnienia i wybrane wejście audio.")
        } else {
            print("OK: wykryto sygnał audio.")
        }
    }
}

extension TestRecording {
    /// Zapisuje podgląd pastylki w kilku stanach, żeby dało się ocenić wygląd
    /// bez uruchamiania aplikacji i bez mikrofonu.
    static func renderIndicator() {
        let warianty: [(String, [Float], RecordingIndicator.State)] = [
            ("cisza",     Array(repeating: 0.02, count: 12), .listening),
            ("cicho",     (0..<12).map { _ in Float.random(in: 0.10...0.30) }, .listening),
            ("mowa",      (0..<12).map { i in Float(0.35 + 0.5 * sin(Double(i) * 0.9)) }, .listening),
            ("glosno",    (0..<12).map { _ in Float.random(in: 0.65...1.0) }, .listening),
            ("przetwarzanie", Array(repeating: 0, count: 12), .processing),
        ]

        for (nazwa, poziomy, stan) in warianty {
            let image = RecordingIndicator.renderPreview(levels: poziomy, state: stan)
            guard
                let tiff = image.tiffRepresentation,
                let rep = NSBitmapImageRep(data: tiff),
                let png = rep.representation(using: .png, properties: [:])
            else { continue }
            let url = URL(fileURLWithPath: "/tmp/klatki/podglad-\(nazwa).png")
            try? png.write(to: url)
            print("zapisano \(url.path)")
        }
        exit(0)
    }
}


extension TestRecording {
    /// Podgląd panelu z tekstem — sprawdza układ i to, czy w ogóle się buduje.
    static func renderPanel() {
        let teksty = [
            "Krótkie zdanie.",
            "Muszę wysłać temu klientowi ten deadline, bo meeting jest jutro rano i trzeba to zrobić przed standupem. Daj znać, czy to gra.",
        ]

        let panel = TranscriptPanel()
        for (index, tekst) in teksty.enumerated() {
            guard
                let image = panel.renderPreview(text: tekst),
                let tiff = image.tiffRepresentation,
                let rep = NSBitmapImageRep(data: tiff),
                let png = rep.representation(using: .png, properties: [:])
            else {
                print("BŁĄD: nie udało się wyrenderować panelu \(index)")
                continue
            }
            let path = "/tmp/klatki/panel-\(index).png"
            try? png.write(to: URL(fileURLWithPath: path))
            print("zapisano \(path) — rozmiar \(Int(image.size.width))x\(Int(image.size.height))")
        }
        exit(0)
    }
}


extension TestRecording {
    /// Wypisuje co sekundę, gdzie trafiłby teraz podyktowany tekst.
    /// Pozwala sprawdzić zachowanie w konkretnej aplikacji bez dyktowania.
    static func watchFocus(seconds: Int = 12) {
        guard AXIsProcessTrusted() else {
            print("BŁĄD: brak uprawnienia Accessibility dla tej binarki.")
            print("Ten test wymaga zgody przyznanej dokładnie temu plikowi.")
            exit(1)
        }

        print("Przełączaj się między aplikacjami i klikaj w pola tekstowe.\n")
        for remaining in stride(from: seconds, to: 0, by: -1) {
            let role = TextInjector.focusedTextRole()
            let decision = role == nil ? "PANEL (nie ma gdzie pisać)" : "WPISZE → \(role!)"
            print("  \(decision)")
            _ = remaining
            Thread.sleep(forTimeInterval: 1)
        }
        exit(0)
    }
}
