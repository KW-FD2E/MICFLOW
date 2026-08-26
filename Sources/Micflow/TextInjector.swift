import AppKit
import CoreGraphics

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

    /// Wysyła tekst jako zdarzenia klawiatury. Wariant ze schowkiem został
    /// usunięty — był szybszy przy długim tekście, ale na ułamek sekundy
    /// podmieniał zawartość schowka użytkownika.
    /// Czy w aktywnej aplikacji stoi kursor w polu, które przyjmie tekst.
    ///
    /// Decyduje, czy wpisać tekst wprost, czy pokazać panel z możliwością
    /// skopiowania. Bez tego tekst wpadałby po cichu w próżnię.
    static func hasFocusedTextField() -> Bool {
        guard AXIsProcessTrusted() else { return false }

        var focused: AnyObject?
        guard
            AXUIElementCopyAttributeValue(
                AXUIElementCreateSystemWide(),
                kAXFocusedUIElementAttribute as CFString,
                &focused
            ) == .success,
            let focusedElement = focused
        else { return false }

        let element = focusedElement as! AXUIElement

        // Zakres zaznaczenia udostępniają tylko elementy tekstowe — to najpewniejszy sygnał.
        var range: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &range) == .success {
            return true
        }

        // Część aplikacji zakresu nie daje, ale deklaruje rolę pola tekstowego.
        var role: AnyObject?
        guard
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
            let roleName = role as? String
        else { return false }

        return [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(roleName)
    }

    func inject(_ text: String) throws {
        guard !text.isEmpty else { return }
        guard AXIsProcessTrusted() else { throw InjectorError.noAccessibility }
        try type(text)
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
}
