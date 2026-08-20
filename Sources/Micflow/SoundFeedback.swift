import AVFoundation

/// Krótkie sygnały dźwiękowe startu i końca nagrania.
///
/// Dźwięki są syntezowane, a nie brane z systemu — dzięki temu da się dobrać
/// barwę: miękki atak, łagodne wybrzmienie i dwie nakładające się harmoniczne,
/// żeby brzmiało ciepło zamiast piszczeć.
final class SoundFeedback {
    enum Cue {
        case start
        case stop

        /// Kolejne dźwięki: częstotliwość w Hz i czas trwania.
        /// Start rośnie (zaczynamy), koniec opada (skończone).
        var notes: [(frequency: Double, duration: Double)] {
            switch self {
            case .start: return [(659.25, 0.055), (987.77, 0.085)]   // E5 → B5
            case .stop:  return [(987.77, 0.055), (659.25, 0.095)]   // B5 → E5
            }
        }
    }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var buffers: [Cue: AVAudioPCMBuffer] = [:]
    private var isEnabled = true

    init() {
        engine.attach(player)

        // Format podajemy jawnie. Odpytanie miksera przed startem silnika
        // potrafi zwrócić 0 Hz, co dawało bufory o zerowej długości — czyli ciszę.
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 44_100,
            channels: 2,
            interleaved: false
        ) else {
            NSLog("Dźwięki wyłączone — nie udało się utworzyć formatu audio.")
            isEnabled = false
            return
        }

        engine.connect(player, to: engine.mainMixerNode, format: format)

        for cue in [Cue.start, Cue.stop] {
            guard let buffer = render(cue: cue, format: format), buffer.frameLength > 0 else {
                NSLog("Dźwięki: nie udało się wygenerować sygnału \(cue).")
                continue
            }
            buffers[cue] = buffer
        }

        do {
            try engine.start()
            player.play()
            NSLog("Dźwięki gotowe: \(buffers.count) sygnały, \(Int(format.sampleRate)) Hz")
        } catch {
            NSLog("Dźwięki wyłączone — nie udało się uruchomić wyjścia audio: \(error.localizedDescription)")
            isEnabled = false
        }
    }

    /// Czy syntezowane sygnały faktycznie powstały i silnik gra.
    var isWorking: Bool {
        engine.isRunning && buffers.count == 2
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
    }

    func play(_ cue: Cue) {
        guard isEnabled, engine.isRunning, let buffer = buffers[cue] else { return }
        player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
    }

    // MARK: - Synteza

    private func render(cue: Cue, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let sampleRate = format.sampleRate
        let total = cue.notes.reduce(0.0) { $0 + $1.duration }
        let frames = AVAudioFrameCount(sampleRate * total)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames

        guard let channels = buffer.floatChannelData else { return nil }

        var offset = 0
        for note in cue.notes {
            let noteFrames = Int(sampleRate * note.duration)

            for i in 0..<noteFrames {
                let position = Double(i) / Double(noteFrames)
                let time = Double(i) / sampleRate

                // Miękki atak (~8 ms) usuwa trzask na początku, a wykładnicze
                // wybrzmienie sprawia, że dźwięk gaśnie zamiast się urywać.
                let attack = min(1.0, Double(i) / (sampleRate * 0.008))
                let decay = pow(1.0 - position, 1.8)
                let envelope = attack * decay

                // Oktawa wyżej, cicho — dodaje jasności bez ostrości.
                let fundamental = sin(2 * .pi * note.frequency * time)
                let harmonic = sin(4 * .pi * note.frequency * time) * 0.18

                let value = Float((fundamental + harmonic) * envelope * 0.16)

                for channel in 0..<Int(format.channelCount) {
                    channels[channel][offset + i] = value
                }
            }

            offset += noteFrames
        }

        return buffer
    }
}
