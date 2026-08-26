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
    /// Role, które na pewno NIE przyjmują tekstu.
    ///
    /// Odwracamy pytanie: zamiast wyliczać, co jest polem tekstowym — czego
    /// aplikacje Electronowe i tak nie deklarują — wykluczamy to, co polem
    /// na pewno nie jest. Wpisywanie w przycisk byłoby groźne, bo spacja
    /// wciska przycisk, a więc uruchamia przypadkowe akcje.
    private static let nonTextRoles: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton",
        "AXMenuItem", "AXMenuButton", "AXMenuBarItem", "AXSlider",
        "AXStepper", "AXDisclosureTriangle", "AXTabGroup", "AXToolbar",
        "AXScrollBar", "AXImage", "AXProgressIndicator",
    ]

    /// Gdzie trafi podyktowany tekst.
    ///
    /// - Returns: opis miejsca, gdy jest gdzie pisać; `nil`, gdy nie ma.
    ///   `nil` oznacza pokazanie panelu z tekstem do skopiowania.
    @discardableResult
    static func focusedTextRole() -> String? {
        guard AXIsProcessTrusted() else { return nil }

        // Punktem wyjścia jest aktywna aplikacja, nie samo drzewo Accessibility.
        // Jeśli cokolwiek jest na wierzchu, użytkownik tam właśnie pisze.
        guard let frontmost = NSWorkspace.shared.frontmostApplication else { return nil }
        guard frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }

        let name = frontmost.localizedName ?? "?"
        let application = AXUIElementCreateApplication(frontmost.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.4)

        // Aplikacje na Electronie (Claude, Slack, VS Code) budują drzewo
        // Accessibility dopiero, gdy program pomocniczy wprost o to poprosi.
        // Bez tego pytanie o element z fokusem nie zwraca niczego.
        AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.4)

        var focused: AnyObject?
        if AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &focused
        ) == .success, let focusedElement = focused {
            let element = focusedElement as! AXUIElement
            AXUIElementSetMessagingTimeout(element, 0.4)

            var role: AnyObject?
            if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
               let roleName = role as? String {
                // Przycisk czy suwak tekstu nie przyjmie, a spacja by go wcisnęła.
                return nonTextRoles.contains(roleName) ? nil : "\(roleName) w \(name)"
            }
        }

        // Nie udało się nic ustalić. Kliknięcie w pulpit wysuwa na wierzch
        // Findera i wtedy naprawdę nie ma gdzie pisać — w każdym innym wypadku
        // zakładamy, że jest, bo blokada dotyczy drzewa Accessibility,
        // a nie samej możliwości wpisywania.
        if frontmost.bundleIdentifier == "com.apple.finder" { return nil }
        return "nieustalone w \(name)"
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
        text.split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
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
