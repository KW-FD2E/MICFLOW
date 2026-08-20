import AppKit
import CoreGraphics

/// Sposób wstawiania tekstu do aktywnej aplikacji.
enum InjectionMethod: String, CaseIterable {
    case typing
    case clipboard
    case none

    var title: String {
        switch self {
        case .typing:    return "Wpisywanie (nie rusza schowka)"
        case .clipboard: return "Wklejanie ze schowka (szybsze)"
        case .none:      return "Nie wstawiaj — tylko pokaż w menu"
        }
    }
}

/// Wstawia gotowy tekst w miejsce kursora w dowolnej aplikacji.
/// Wymaga uprawnienia Accessibility.
final class TextInjector {
    enum InjectorError: Error, LocalizedError {
        case noAccessibility
        case eventCreationFailed

        var errorDescription: String? {
            switch self {
            case .noAccessibility:
                return "Brak uprawnienia Accessibility — nie mogę wpisać tekstu."
            case .eventCreationFailed:
                return "Nie udało się utworzyć zdarzenia klawiatury."
            }
        }
    }

    /// CGEvent przyjmuje dłuższe napisy, ale przy większych porcjach część
    /// aplikacji gubi znaki. 20 jednostek UTF-16 to bezpieczny kompromis.
    private static let chunkSize = 20

    private static let vKeyCode: CGKeyCode = 9   // kVK_ANSI_V

    func inject(_ text: String, method: InjectionMethod) throws {
        guard !text.isEmpty, method != .none else { return }
        guard AXIsProcessTrusted() else { throw InjectorError.noAccessibility }

        switch method {
        case .typing:    try type(text)
        case .clipboard: try paste(text)
        case .none:      break
        }
    }

    // MARK: - Wpisywanie znak po znaku

    /// Wysyła tekst jako zdarzenia klawiatury z ustawionym napisem Unicode.
    /// Dzięki temu polskie znaki działają niezależnie od układu klawiatury.
    private func type(_ text: String) throws {
        let source = CGEventSource(stateID: .combinedSessionState)
        let units = Array(text.utf16)
        var index = 0

        while index < units.count {
            var end = min(index + Self.chunkSize, units.count)

            // Nie wolno rozciąć pary zastępczej (np. emoji) na pół —
            // powstałby uszkodzony znak.
            if end < units.count, UTF16.isLeadSurrogate(units[end - 1]) {
                end -= 1
            }

            var chunk = Array(units[index..<end])

            guard
                let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else {
                throw InjectorError.eventCreationFailed
            }

            keyDown.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
            keyUp.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)

            // Bez wyzerowania flag zdarzenie odziedziczyłoby modyfikatory, które
            // użytkownik akurat trzyma — i zamiast tekstu poszłyby skróty.
            keyDown.flags = []
            keyUp.flags = []

            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)

            index = end
            Thread.sleep(forTimeInterval: 0.004)
        }
    }

    // MARK: - Wklejanie ze schowka

    /// Podmienia schowek, wysyła Cmd+V i przywraca poprzednią zawartość.
    private func paste(_ text: String) throws {
        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        let source = CGEventSource(stateID: .combinedSessionState)
        guard
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: Self.vKeyCode, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: Self.vKeyCode, keyDown: false)
        else {
            throw InjectorError.eventCreationFailed
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)

        // Schowek przywracamy dopiero, gdy aplikacja docelowa zdąży wkleić.
        // Bez opóźnienia wklejałaby się poprzednia zawartość.
        guard let previous else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            pasteboard.clearContents()
            pasteboard.setString(previous, forType: .string)
        }
    }
}
