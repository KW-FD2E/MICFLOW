import AppKit

/// Klawisz push-to-talk. Wszystkie warianty to klawisze modyfikujące,
/// bo tylko one dają czysty sygnał „wciśnięty / puszczony" bez powtarzania.
///
/// Prawy ⌥ celowo nie jest dostępny — na polskim układzie to AltGr
/// do wpisywania ą, ć, ę i dyktowanie zjadałoby diakrytyki.
enum HotkeyChoice: String, CaseIterable {
    case fn
    case rightCommand

    var keyCode: UInt16 {
        switch self {
        case .fn:           return 63   // kVK_Function
        case .rightCommand: return 54   // kVK_RightCommand
        }
    }

    var flag: NSEvent.ModifierFlags {
        switch self {
        case .fn:           return .function
        case .rightCommand: return .command
        }
    }

    var title: String {
        switch self {
        case .fn:           return "fn / 🌐"
        case .rightCommand: return "prawy ⌘"
        }
    }
}

/// Nasłuchuje globalnie na klawisz push-to-talk i sam rozpoznaje, czy
/// użytkownik przytrzymuje klawisz, czy kliknął dwa razy.
///
/// Sedno problemu: w chwili puszczenia klawisza nie wiadomo jeszcze, czy było
/// to krótkie przytrzymanie, czy pierwsze z dwóch kliknięć. Dlatego nagrywanie
/// rusza natychmiast przy wciśnięciu (inaczej przytrzymanie gubiłoby pierwsze
/// słowa), a rozstrzygnięcie zapada dopiero przy puszczeniu.
///
/// Wymaga uprawnienia Accessibility / Input Monitoring.
final class HotkeyMonitor {
    /// Puszczenie po tym czasie liczymy jako przytrzymanie, nie kliknięcie.
    private static let holdThreshold: TimeInterval = 0.35

    /// Ile czekamy na drugie kliknięcie, zanim uznamy gest za krótkie przytrzymanie.
    private static let doubleTapWindow: TimeInterval = 0.40

    private enum Gesture {
        /// Nic się nie dzieje.
        case idle
        /// Klawisz wciśnięty, nagrywamy, czekamy na puszczenie.
        case holding(since: Date)
        /// Puszczony szybko — może zaraz przyjdzie drugie kliknięcie.
        case awaitingSecondTap
        /// Tryb bez trzymania: nagrywa, dopóki nie kliknie się ponownie.
        case handsFree
    }

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isDown = false
    private var gesture: Gesture = .idle
    private var decisionTimer: Timer?

    private(set) var choice: HotkeyChoice = .fn

    /// Pozwala odświeżyć stan, gdy nagranie skończyło się poza skrótem —
    /// na przykład przez limit czasu albo przycisk w menu.
    var isRecording: (() -> Bool)?

    /// Ile razy skrót zadziałał. W diagnostyce pozwala odróżnić „monitor nie
    /// dostaje zdarzeń" od „dostaje, ale coś dalej nie działa".
    private(set) var pressCount = 0

    /// Ostatni kod klawisza modyfikującego, jaki w ogóle dotarł do monitora.
    private(set) var lastSeenKeyCode: UInt16?

    /// Opis rozpoznanego gestu — widoczny w Diagnostyce.
    private(set) var lastGesture = "—"

    var onStart: (() -> Void)?
    var onStop: (() -> Void)?

    func start(choice: HotkeyChoice) {
        stop()
        self.choice = choice

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
        decisionTimer?.invalidate()
        decisionTimer = nil
        isDown = false
        gesture = .idle
    }

    // MARK: - Rozpoznawanie gestu

    private func handle(_ event: NSEvent) {
        lastSeenKeyCode = event.keyCode
        guard event.keyCode == choice.keyCode else { return }

        let pressed = event.modifierFlags.contains(choice.flag)
        guard pressed != isDown else { return }
        isDown = pressed

        if pressed {
            pressCount += 1
            handlePress()
        } else {
            handleRelease()
        }
    }

    func handlePress() {
        // Nagranie mogło się skończyć poza skrótem — wtedy zaczynamy od zera.
        if case .handsFree = gesture, isRecording?() == false {
            gesture = .idle
        }

        switch gesture {
        case .idle:
            gesture = .holding(since: Date())
            lastGesture = "wciśnięty"
            onStart?()

        case .awaitingSecondTap:
            // Drugie kliknięcie w oknie czasowym — przechodzimy w tryb bez trzymania.
            cancelDecision()
            gesture = .handsFree
            lastGesture = "dwuklik → bez trzymania"

        case .handsFree:
            // Kolejne kliknięcie kończy nagranie.
            gesture = .idle
            lastGesture = "kliknięcie → koniec"
            onStop?()

        case .holding:
            break   // nie powinno wystąpić: dwa wciśnięcia bez puszczenia
        }
    }

    func handleRelease() {
        switch gesture {
        case .holding(let since):
            if Date().timeIntervalSince(since) >= Self.holdThreshold {
                // Klawisz był trzymany — klasyczne push-to-talk.
                gesture = .idle
                lastGesture = "przytrzymanie → koniec"
                onStop?()
            } else {
                // Za krótko, żeby rozstrzygnąć. Czekamy na ewentualny drugi klik.
                gesture = .awaitingSecondTap
                lastGesture = "krótki klik — czekam"
                scheduleDecision()
            }

        case .handsFree, .awaitingSecondTap, .idle:
            break   // w tych stanach puszczenie klawisza nic nie znaczy
        }
    }

    /// Drugie kliknięcie nie przyszło — gest był krótkim przytrzymaniem.
    private func scheduleDecision() {
        cancelDecision()
        let timer = Timer(timeInterval: Self.doubleTapWindow, repeats: false) { [weak self] _ in
            guard let self, case .awaitingSecondTap = self.gesture else { return }
            self.gesture = .idle
            self.lastGesture = "krótki klik → koniec"
            self.onStop?()
        }
        RunLoop.main.add(timer, forMode: .common)
        decisionTimer = timer
    }

    private func cancelDecision() {
        decisionTimer?.invalidate()
        decisionTimer = nil
    }
}
