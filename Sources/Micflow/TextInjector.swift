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
    /// Role, które przyjmują wpisywany tekst. `AXWebArea` obejmuje pola
    /// w przeglądarkach, `AXGroup` — edytory rysujące własne widoki.
    private static let textRoles: Set<String> = [
        kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole,
        "AXWebArea", "AXSearchField",
    ]

    /// Czy w aktywnej aplikacji stoi kursor w polu, które przyjmie tekst.
    ///
    /// Decyduje, czy wpisać tekst wprost, czy pokazać panel z możliwością
    /// skopiowania. Celowo przechyla się w stronę wpisywania: panel ma się
    /// pokazywać wyłącznie wtedy, gdy naprawdę nie ma dokąd pisać.
    ///
    /// - Returns: nazwa roli znalezionego elementu albo nil.
    @discardableResult
    static func focusedTextRole() -> String? {
        guard AXIsProcessTrusted() else { return nil }

        let systemWide = AXUIElementCreateSystemWide()

        // Zapytania Accessibility idą przez IPC do obcej aplikacji. Bez limitu
        // czasu zawieszona aplikacja zablokowałaby nas na kilka sekund —
        // a wołamy to przy starcie nagrania, więc przepadłyby pierwsze słowa.
        AXUIElementSetMessagingTimeout(systemWide, 0.4)

        var focused: AnyObject?
        guard
            AXUIElementCopyAttributeValue(
                systemWide,
                kAXFocusedUIElementAttribute as CFString,
                &focused
            ) == .success,
            let focusedElement = focused
        else { return nil }

        let element = focusedElement as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.4)

        // Pomijamy własne okna — pastylka i panel nie są miejscem na tekst.
        var pid: pid_t = 0
        if AXUIElementGetPid(element, &pid) == .success, pid == ProcessInfo.processInfo.processIdentifier {
            return nil
        }

        var role: AnyObject?
        let roleName = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success
            ? (role as? String)
            : nil

        // Zakres zaznaczenia udostępniają tylko elementy tekstowe —
        // to najpewniejszy sygnał, niezależny od zadeklarowanej roli.
        var range: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &range) == .success {
            return roleName ?? "AXTextRange"
        }

        // Pole, którego wartość da się ustawić, też przyjmie tekst.
        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
           settable.boolValue {
            return roleName ?? "AXSettableValue"
        }

        // Aplikacje Electronowe (m.in. Claude) wystawiają szczątkowe drzewo
        // Accessibility — bywa, że nie ma ani zakresu zaznaczenia, ani znanej
        // roli. Skoro jednak COŚ ma fokus, jest gdzie pisać. Panel zostawiamy
        // na przypadek, gdy fokusu nie ma w ogóle.
        return roleName ?? "AXNieznana"
    }

    func inject(_ text: String) throws {
        let safe = Self.singleLine(text)
        guard !safe.isEmpty else { return }
        guard AXIsProcessTrusted() else { throw InjectorError.noAccessibility }
        try type(safe)
    }

    /// Zamienia znaki nowej linii na spacje.
    ///
    /// `CGEvent` wpisuje znak nowej linii jako naciśnięcie Enter, a w oknach
    /// czatu Enter wysyła wiadomość — zamiast tekstu szła więc przedwcześnie
    /// wysłana wypowiedź. Dyktowana mowa i tak rzadko wymaga wielu akapitów,
    /// a ryzyko przypadkowego wysłania jest zbyt kosztowne.
    static func singleLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
