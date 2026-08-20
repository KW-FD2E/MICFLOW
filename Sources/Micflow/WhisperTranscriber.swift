import CWhisper
import Foundation

/// Język dyktowania wybierany przez użytkownika.
enum DictationLanguage: String, CaseIterable {
    case polish
    case english
    case automatic

    /// Kod podawany Whisperowi. "auto" uruchamia wykrywanie na podstawie audio.
    var whisperCode: String {
        switch self {
        case .polish:    return "pl"
        case .english:   return "en"
        case .automatic: return "auto"
        }
    }

    var title: String {
        switch self {
        case .polish:    return "Polski"
        case .english:   return "English"
        case .automatic: return "Automatycznie (wykrywa z mowy)"
        }
    }
}

/// Transkrypcja mowy przez whisper.cpp, wołaną w procesie przez C API.
/// Model ładuje się raz i zostaje w pamięci — dzięki temu każde kolejne
/// dyktowanie nie płaci ~300 ms za wczytanie modelu z dysku.
final class WhisperTranscriber {
    enum TranscriberError: Error, LocalizedError {
        case modelNotFound(String)
        case modelLoadFailed(String)
        case inferenceFailed

        var errorDescription: String? {
            switch self {
            case .modelNotFound(let path):
                return "Nie znaleziono modelu Whisper: \(path)"
            case .modelLoadFailed(let path):
                return "Nie udało się wczytać modelu Whisper: \(path)"
            case .inferenceFailed:
                return "Transkrypcja nie powiodła się."
            }
        }
    }

    private let context: OpaquePointer
    private let vadModelPath: String?

    /// Kod języka podawany Whisperowi. "auto" włącza wykrywanie na podstawie audio.
    /// Ustawiany przy każdym wywołaniu, więc zmiana nie wymaga przeładowania modelu.
    var language: String

    /// Język faktycznie rozpoznany przy ostatniej transkrypcji ("pl", "en", ...).
    /// Przy wymuszonym języku jest po prostu nim; przy "auto" — wynikiem wykrycia.
    private(set) var detectedLanguage: String = "pl"

    init(modelPath: String, vadModelPath: String? = nil, language: String = "pl") throws {
        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw TranscriberError.modelNotFound(modelPath)
        }

        var params = whisper_context_default_params()
        params.use_gpu = true
        params.flash_attn = true

        guard let context = whisper_init_from_file_with_params(modelPath, params) else {
            throw TranscriberError.modelLoadFailed(modelPath)
        }

        self.context = context
        self.language = language
        self.vadModelPath = vadModelPath.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }

        if self.vadModelPath == nil {
            NSLog("VAD wyłączony — brak modelu Silero. Cisza będzie tylko przycinana heurystycznie.")
        }
    }

    deinit {
        whisper_free(context)
    }

    /// Transkrybuje próbki PCM float32, 16 kHz, mono.
    func transcribe(samples: [Float]) throws -> String {
        let trimmed = Self.trimSilence(samples)
        guard !trimmed.isEmpty else { return "" }

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)

        params.print_realtime = false
        params.print_progress = false
        params.print_timestamps = false
        params.print_special = false
        params.translate = false
        params.n_threads = Int32(max(1, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))

        // Każde dyktowanie jest niezależne — bez tego model przenosi kontekst
        // z poprzedniej wypowiedzi i potrafi dokleić nieistniejące zdania.
        params.no_context = true
        params.suppress_blank = true

        // Turbo lubi halucynować na ciszy (np. powtarzać ostatnie słowo bez końca).
        // Wyższy próg no_speech ucina fragmenty, w których nikt nie mówi.
        params.no_speech_thold = 0.6

        let status = language.withCString { lang -> Int32 in
            params.language = lang

            // VAD wycina fragmenty bez mowy jeszcze przed dekoderem. To właściwe
            // lekarstwo na halucynacje na ciszy — przycinanie końców pomaga tylko
            // wtedy, gdy cisza jest na brzegach, a nie w środku nagrania.
            guard let vadModelPath else { return run(params: params, samples: trimmed) }

            return vadModelPath.withCString { vadPath -> Int32 in
                params.vad = true
                params.vad_model_path = vadPath

                var vad = whisper_vad_default_params()
                vad.speech_pad_ms = 300  // hojny zapas, żeby nie obciąć początków słów
                params.vad_params = vad

                return run(params: params, samples: trimmed)
            }
        }

        guard status == 0 else { throw TranscriberError.inferenceFailed }

        if let name = whisper_lang_str(whisper_full_lang_id(context)) {
            detectedLanguage = String(cString: name)
        }

        var text = ""
        for index in 0..<whisper_full_n_segments(context) {
            guard let segment = whisper_full_get_segment_text(context, index) else { continue }
            text += String(cString: segment)
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func run(params: whisper_full_params, samples: [Float]) -> Int32 {
        samples.withUnsafeBufferPointer { buffer in
            whisper_full(context, params, buffer.baseAddress, Int32(buffer.count))
        }
    }

    // MARK: - Przycinanie ciszy

    private static let sampleRate = 16_000
    private static let windowSamples = 320          // 20 ms
    private static let paddingWindows = 5           // 100 ms zapasu wokół mowy
    private static let minimumSamples = 16_000      // whisper potrzebuje ~1 s materiału

    /// Obcina ciszę z początku i końca nagrania.
    ///
    /// Whisper (zwłaszcza warianty turbo) na dłuższych fragmentach ciszy zaczyna
    /// zmyślać — najczęściej powtarza ostatnie słowo albo wstawia frazy z napisów
    /// filmowych ("Dzięki za oglądanie"), na których był trenowany.
    static func trimSilence(_ samples: [Float]) -> [Float] {
        guard samples.count > windowSamples else { return [] }

        var peak: Float = 0
        for sample in samples {
            peak = max(peak, abs(sample))
        }

        // Próg względem najgłośniejszego miejsca — działa i przy cichym mikrofonie,
        // i przy głośnym, w przeciwieństwie do wartości sztywnej.
        let threshold = max(0.005, peak * 0.02)
        guard peak > threshold else { return [] }

        let windowCount = samples.count / windowSamples
        var firstLoud: Int?
        var lastLoud = 0

        for window in 0..<windowCount {
            let start = window * windowSamples
            var sumOfSquares: Float = 0
            for i in start..<(start + windowSamples) {
                sumOfSquares += samples[i] * samples[i]
            }
            let rms = (sumOfSquares / Float(windowSamples)).squareRoot()

            if rms > threshold {
                if firstLoud == nil { firstLoud = window }
                lastLoud = window
            }
        }

        guard let firstLoud else { return [] }

        let startWindow = max(0, firstLoud - paddingWindows)
        let endWindow = min(windowCount, lastLoud + paddingWindows + 1)

        var result = Array(samples[(startWindow * windowSamples)..<(endWindow * windowSamples)])

        // Zbyt krótki fragment whisper odrzuca — dopychamy ciszą.
        if result.count < minimumSamples {
            result.append(contentsOf: repeatElement(0, count: minimumSamples - result.count))
        }

        return result
    }
}
