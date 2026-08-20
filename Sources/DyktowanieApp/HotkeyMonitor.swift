import AppKit

/// Klawisz push-to-talk. Wszystkie warianty to klawisze modyfikujące,
/// bo tylko one dają czysty sygnał „wciśnięty / puszczony" bez powtarzania.
enum HotkeyChoice: String, CaseIterable {
    case fn
    case rightCommand
    case rightOption

    var keyCode: UInt16 {
        switch self {
        case .fn:           return 63   // kVK_Function
        case .rightCommand: return 54   // kVK_RightCommand
        case .rightOption:  return 61   // kVK_RightOption
        }
    }

    var flag: NSEvent.ModifierFlags {
        switch self {
        case .fn:           return .function
        case .rightCommand: return .command
        case .rightOption:  return .option
        }
    }

    var title: String {
        switch self {
        case .fn:           return "fn / 🌐"
        case .rightCommand: return "prawy ⌘"
        case .rightOption:  return "prawy ⌥ (kolizja z polskimi znakami)"
        }
    }
}

/// Sposób wyzwalania nagrania.
enum HotkeyMode: String, CaseIterable {
    case hold
    case toggle

    var title: String {
        switch self {
        case .hold:   return "Przytrzymanie (mów, gdy trzymasz)"
        case .toggle: return "Dwuklik włącza, klik wyłącza"
        }
    }
}

/// Nasłuchuje globalnie na klawisz push-to-talk.
/// Wymaga uprawnienia Accessibility / Input Monitoring.
final class HotkeyMonitor {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isDown = false

    private(set) var choice: HotkeyChoice = .fn
    private(set) var mode: HotkeyMode = .toggle

    /// Maksymalna przerwa między kliknięciami, żeby uznać je za dwuklik.
    private static let doubleTapWindow: TimeInterval = 0.45

    private var lastPressTime: Date?

    /// Monitor musi wiedzieć, czy nagranie już trwa — w trybie dwukliku
    /// pojedyncze kliknięcie ma wtedy zatrzymywać, a nie czekać na drugie.
    var isRecording: (() -> Bool)?

    /// Ile razy skrót zadziałał. W diagnostyce pozwala odróżnić „monitor nie
    /// dostaje zdarzeń" od „dostaje, ale coś dalej nie działa".
    private(set) var pressCount = 0

    /// Ostatni kod klawisza modyfikującego, jaki w ogóle dotarł do monitora —
    /// pokazuje, czy system w ogóle przepuszcza zdarzenia.
    private(set) var lastSeenKeyCode: UInt16?

    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?

    func start(choice: HotkeyChoice, mode: HotkeyMode) {
        stop()
        self.choice = choice
        self.mode = mode

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(event)
        }

        // Global monitor nie dostaje zdarzeń, gdy nasza aplikacja jest aktywna
        // (np. otwarte menu), więc dokładamy monitor lokalny.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        isDown = false
    }

    private func handle(_ event: NSEvent) {
        lastSeenKeyCode = event.keyCode

        guard event.keyCode == choice.keyCode else { return }

        let pressed = event.modifierFlags.contains(choice.flag)
        guard pressed != isDown else { return }
        isDown = pressed

        switch mode {
        case .hold:
            if pressed {
                pressCount += 1
                onPress?()
            } else {
                onRelease?()
            }

        case .toggle:
            // Reagujemy tylko na wciśnięcie; puszczenie klawisza jest bez znaczenia.
            guard pressed else { return }
            pressCount += 1

            if isRecording?() == true {
                lastPressTime = nil
                onRelease?()
                return
            }

            let now = Date()
            if let previous = lastPressTime, now.timeIntervalSince(previous) <= Self.doubleTapWindow {
                lastPressTime = nil
                onPress?()
            } else {
                lastPressTime = now
            }
        }
    }
}
