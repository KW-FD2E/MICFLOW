import AVFoundation

/// Nagrywa z mikrofonu przez AVAudioEngine i zapisuje do pliku WAV
/// w formacie, którego oczekuje whisper.cpp: 16 kHz, mono, PCM 16-bit.
final class AudioRecorder {
    enum RecorderError: Error, LocalizedError {
        case converterUnavailable
        case conversionFailed(String)

        var errorDescription: String? {
            switch self {
            case .converterUnavailable:
                return "Nie udało się utworzyć konwertera audio do formatu 16 kHz mono."
            case .conversionFailed(let detail):
                return "Konwersja audio nie powiodła się: \(detail)"
            }
        }
    }

    /// Format wymagany przez whisper.cpp.
    private static let targetSampleRate = 16_000.0

    private let engine = AVAudioEngine()
    private var outputFile: AVAudioFile?
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?

    private(set) var isRecording = false

    /// Szczytowa amplituda surowego sygnału z mikrofonu (przed konwersją).
    /// Pozwala odróżnić ciszę na wejściu od błędu w konwersji.
    private(set) var rawInputPeak: Float = 0

    /// Próbki 16 kHz mono trzymane w pamięci i podawane wprost do whisper.cpp.
    /// Plik WAV powstaje równolegle, ale służy już tylko do podglądu i debugowania.
    private var samples: [Float] = []
    private let samplesLock = NSLock()

    /// Zaczyna nagrywanie do nowego pliku WAV w katalogu tymczasowym.
    /// - Returns: URL pliku, do którego trwa zapis.
    @discardableResult
    func start() throws -> URL {
        guard !isRecording else { throw RecorderError.conversionFailed("Nagrywanie już trwa.") }

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw RecorderError.converterUnavailable
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: target) else {
            throw RecorderError.converterUnavailable
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dyktowanie-\(Int(Date().timeIntervalSince1970)).wav")

        // Plik na dysku trzymamy jako PCM 16-bit; AVAudioFile sam zamienia
        // bufory float32 (processingFormat) na int16 przy zapisie.
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.targetSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ])

        self.converter = converter
        self.targetFormat = target
        self.outputFile = file
        self.rawInputPeak = 0
        samplesLock.lock()
        samples.removeAll(keepingCapacity: true)
        samplesLock.unlock()

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.append(buffer)
        }

        engine.prepare()
        try engine.start()
        isRecording = true

        return url
    }

    /// Kończy nagrywanie i zwraca próbki gotowe dla whisper.cpp
    /// oraz URL pliku WAV z tym samym nagraniem.
    @discardableResult
    func stop() -> (url: URL, duration: TimeInterval, samples: [Float])? {
        guard isRecording else { return nil }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false

        defer {
            outputFile = nil
            converter = nil
            targetFormat = nil
        }

        guard let file = outputFile else { return nil }

        samplesLock.lock()
        let captured = samples
        samplesLock.unlock()

        let duration = Double(captured.count) / Self.targetSampleRate
        return (file.url, duration, captured)
    }

    // MARK: - Prywatne

    /// Wywoływane na wątku audio — przelicza bufor do 16 kHz mono i dopisuje do pliku.
    private func append(_ buffer: AVAudioPCMBuffer) {
        guard let converter, let targetFormat, let outputFile else { return }

        if let raw = buffer.floatChannelData?[0] {
            for i in 0..<Int(buffer.frameLength) {
                rawInputPeak = max(rawInputPeak, abs(raw[i]))
            }
        }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024

        guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var consumed = false
        var error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        guard status != .error, converted.frameLength > 0 else {
            if let error { NSLog("Błąd konwersji audio: \(error.localizedDescription)") }
            return
        }

        if let channel = converted.floatChannelData?[0] {
            let frames = Int(converted.frameLength)
            samplesLock.lock()
            samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: frames))
            samplesLock.unlock()
        }

        do {
            try outputFile.write(from: converted)
        } catch {
            NSLog("Błąd zapisu do pliku WAV: \(error.localizedDescription)")
        }
    }
}
