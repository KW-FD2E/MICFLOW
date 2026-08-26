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
        "AXMenuItem", "AXMenuButton", "AXMenuBarItem", "AXMenuBar", "AXSlider",
        "AXStepper", "AXDisclosureTriangle", "AXTabGroup", "AXToolbar",
        "AXScrollBar", "AXImage", "AXProgressIndicator",
        // Listy, tabele i całe okna — m.in. pulpit Findera.
        "AXList", "AXTable", "AXOutline", "AXBrowser", "AXCell", "AXRow",
        "AXStaticText", "AXWindow", "AXApplication",
    ]

    /// Role, które na pewno przyjmują tekst. Używane tylko tam, gdzie aplikacja
    /// zgłasza wiarygodne role — czyli poza światem Electrona.
    private static let textRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXWebArea",
    ]

    /// Aplikacje, którym ufamy, że poprawnie opisują swoje elementy. Dla nich
    /// wymagamy trafienia w rolę tekstową zamiast domyślać się na korzyść
    /// wpisywania — inaczej kliknięcie w pulpit uchodziłoby za pole tekstowe.
    private static let reliableApps: Set<String> = ["com.apple.finder"]

    /// Sama decyzja, odseparowana od odpytywania systemu — dzięki temu
    /// da się ją sprawdzić testem, bez klikania po ekranie.
    static func decision(role: String?, bundleIdentifier: String?) -> String? {
        let reliable = bundleIdentifier.map { reliableApps.contains($0) } ?? false

        guard let role else {
            // Brak roli zwykle znaczy, że aplikacja ukrywa drzewo Accessibility
            // (Electron). Wtedy zakładamy, że jest gdzie pisać — ale nie
            // w aplikacji, o której wiemy, że opisuje się rzetelnie.
            return reliable ? nil : "nieustalone"
        }

        if nonTextRoles.contains(role) { return nil }
        if reliable { return textRoles.contains(role) ? role : nil }
        return role
    }

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
            let roleName = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success
                ? (role as? String)
                : nil

            guard let verdict = decision(role: roleName, bundleIdentifier: frontmost.bundleIdentifier) else {
                return nil
            }
            return "\(verdict) w \(name)"
        }

        // Nie udało się pobrać elementu z fokusem.
        guard let verdict = decision(role: nil, bundleIdentifier: frontmost.bundleIdentifier) else {
            return nil
        }
        return "\(verdict) w \(name)"
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
