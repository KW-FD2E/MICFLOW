import AppKit
import ApplicationServices

/// Pływająca plakietka pokazywana przy kursorze tekstowym w trakcie dyktowania.
///
/// Bez niej użytkownik po puszczeniu klawisza patrzy w puste pole i nie wie,
/// czy aplikacja pracuje, czy się zawiesiła. Okno jest nieaktywne i przezroczyste
/// dla myszy, więc nie przejmuje fokusu z pola, do którego wpisujemy tekst.
final class RecordingIndicator {
    enum State {
        case listening
        case processing

        var text: String {
            switch self {
            case .listening:  return "Słucham…"
            case .processing: return "Przetwarzam…"
            }
        }

        var color: NSColor {
            switch self {
            case .listening:  return NSColor.systemBlue
            case .processing: return NSColor.systemIndigo
            }
        }

        var pulses: Bool {
            self == .listening
        }
    }

    private var panel: NSPanel?
    private var label: NSTextField?
    private var dot: NSView?
    private var background: NSVisualEffectView?

    // MARK: - Sterowanie

    func show(_ state: State) {
        let panel = self.panel ?? makePanel()
        self.panel = panel

        label?.stringValue = state.text
        label?.sizeToFit()
        dot?.layer?.backgroundColor = NSColor.white.cgColor
        background?.layer?.backgroundColor = state.color.withAlphaComponent(0.92).cgColor

        resize()
        reposition()

        panel.orderFrontRegardless()
        setPulsing(state.pulses)
    }

    func hide() {
        setPulsing(false)
        panel?.orderOut(nil)
    }

    // MARK: - Budowa okna

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 150, height: 34),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // Plakietka nie może przejmować fokusu ani łapać kliknięć — inaczej
        // odebrałaby kursor polu tekstowemu, do którego wpisujemy.
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false

        let container = NSVisualEffectView(frame: panel.contentView?.bounds ?? .zero)
        container.autoresizingMask = [.width, .height]
        container.wantsLayer = true
        container.layer?.cornerRadius = 17
        container.layer?.masksToBounds = true
        container.blendingMode = .behindWindow
        container.state = .active
        background = container

        let dot = NSView(frame: NSRect(x: 14, y: 13, width: 8, height: 8))
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.layer?.backgroundColor = NSColor.white.cgColor
        container.addSubview(dot)
        self.dot = dot

        let label = NSTextField(labelWithString: "Słucham…")
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.backgroundColor = .clear
        label.isBezeled = false
        label.isEditable = false
        label.sizeToFit()
        label.frame.origin = NSPoint(x: 30, y: 8)
        container.addSubview(label)
        self.label = label

        panel.contentView = container
        return panel
    }

    private func resize() {
        guard let panel, let label else { return }
        let width = max(120, label.frame.width + 46)
        panel.setContentSize(NSSize(width: width, height: 34))
        label.frame.origin = NSPoint(x: 30, y: 9)
    }

    private func setPulsing(_ pulsing: Bool) {
        guard let layer = dot?.layer else { return }

        guard pulsing else {
            layer.removeAllAnimations()
            layer.opacity = 1
            return
        }

        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.25
        pulse.duration = 0.6
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(pulse, forKey: "pulse")
    }

    // MARK: - Pozycjonowanie

    private func reposition() {
        guard let panel else { return }

        let size = panel.frame.size
        let anchor = caretRect() ?? mouseRect()

        // Współrzędne z Accessibility mają początek w LEWYM GÓRNYM rogu ekranu,
        // a okna AppKit w lewym dolnym — stąd odbicie względem wysokości ekranu.
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: anchor.midX, y: anchor.midY)) }
            ?? NSScreen.main
        let screenFrame = screen?.frame ?? .zero
        let flippedY = screenFrame.maxY - anchor.maxY

        var origin = NSPoint(x: anchor.minX, y: flippedY - size.height - 8)

        // Gdy brakuje miejsca pod kursorem, pokazujemy plakietkę nad nim.
        if origin.y < screenFrame.minY + 8 {
            origin.y = flippedY + anchor.height + 8
        }

        // Nie pozwalamy jej wyjść poza krawędź ekranu.
        origin.x = min(max(origin.x, screenFrame.minX + 8), screenFrame.maxX - size.width - 8)

        panel.setFrameOrigin(origin)
    }

    /// Prostokąt kursora tekstowego w aktywnej aplikacji. Nie wszystkie
    /// aplikacje to udostępniają — wtedy zwracamy nil i lądujemy przy myszy.
    private func caretRect() -> CGRect? {
        guard AXIsProcessTrusted() else { return nil }

        let systemWide = AXUIElementCreateSystemWide()

        var focused: AnyObject?
        guard
            AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
            let focusedElement = focused
        else { return nil }

        let element = focusedElement as! AXUIElement

        var range: AnyObject?
        guard
            AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &range) == .success,
            let selectedRange = range
        else { return nil }

        var bounds: AnyObject?
        guard
            AXUIElementCopyParameterizedAttributeValue(
                element,
                kAXBoundsForRangeParameterizedAttribute as CFString,
                selectedRange,
                &bounds
            ) == .success,
            let boundsValue = bounds
        else { return nil }

        var rect = CGRect.zero
        guard AXValueGetValue(boundsValue as! AXValue, .cgRect, &rect) else { return nil }

        // Zwinięty kursor bywa zerowej szerokości — to nadal poprawna pozycja.
        guard rect.height > 0 else { return nil }
        return rect
    }

    private func mouseRect() -> CGRect {
        let location = NSEvent.mouseLocation
        let screenHeight = NSScreen.main?.frame.maxY ?? 0
        // NSEvent.mouseLocation jest w układzie AppKit — zamieniamy na ekranowy
        // z początkiem u góry, żeby reszta liczenia miała jeden układ.
        return CGRect(x: location.x, y: screenHeight - location.y, width: 0, height: 20)
    }
}
