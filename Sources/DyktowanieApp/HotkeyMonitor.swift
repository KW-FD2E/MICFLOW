import AppKit

/// Nasłuchuje globalnie na przytrzymanie wybranego klawisza modyfikującego
/// (push-to-talk). Wymaga uprawnienia Accessibility / Input Monitoring.
final class HotkeyMonitor {
    /// Klawisz push-to-talk. Prawy ⌘ — celowo NIE prawy Alt, bo na polskim
    /// układzie Alt służy do wpisywania znaków diakrytycznych (ą, ć, ę…).
    enum Key {
        static let rightCommand: UInt16 = 54

        static let current = rightCommand
        static let currentFlag: NSEvent.ModifierFlags = .command
        static let currentDescription = "prawy ⌘"
    }

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isDown = false

    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?

    func start() {
        guard globalMonitor == nil else { return }

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
        guard event.keyCode == Key.current else { return }

        let pressed = event.modifierFlags.contains(Key.currentFlag)
        guard pressed != isDown else { return }
        isDown = pressed

        if pressed {
            onPress?()
        } else {
            onRelease?()
        }
    }
}
