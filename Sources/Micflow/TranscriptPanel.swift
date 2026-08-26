import AppKit

/// Panel z podyktowanym tekstem, pokazywany, gdy nie ma gdzie go wpisać.
///
/// Bez niego tekst lądował po cichu w schowku i trzeba było się domyślić,
/// że w ogóle powstał. Panel pokazuje go wprost, z przyciskiem kopiowania.
///
/// W odróżnieniu od pastylki to okno **przyjmuje kliknięcia** — inaczej nie dałoby
/// się nacisnąć żadnego przycisku. Nadal jednak nie przejmuje fokusu klawiatury.
final class TranscriptPanel {
    /// Po tym czasie panel znika sam, żeby nie zawadzał, gdy go zignorujesz.
    private static let autoDismissSeconds: TimeInterval = 15

    private var panel: NSPanel?
    private var textView: NSTextView?
    private var dismissTimer: Timer?
    private var text = ""

    func show(text: String) {
        guard !text.isEmpty else { return }
        self.text = text

        let panel = self.panel ?? makePanel()
        self.panel = panel

        textView?.string = text
        resize(for: text)
        reposition()

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 1
        }

        scheduleDismiss()
    }

    func hide() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        panel?.orderOut(nil)
    }

    // MARK: - Budowa

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Layout.width, height: 140),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false

        let background = BackgroundView(frame: NSRect(origin: .zero, size: panel.frame.size))
        background.autoresizingMask = [.width, .height]

        let scroll = NSScrollView(frame: NSRect(
            x: Layout.padding,
            y: Layout.padding,
            width: Layout.width - Layout.padding * 2,
            height: 80
        ))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        let textView = NSTextView(frame: scroll.bounds)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 13)
        textView.textColor = .white
        textView.textContainerInset = .zero
        textView.autoresizingMask = [.width]
        scroll.documentView = textView
        self.textView = textView

        background.addSubview(scroll)

        // Przyciski w prawym górnym rogu, tak jak prosiłeś.
        let close = makeButton(symbol: "xmark", action: #selector(closeTapped))
        close.frame = NSRect(x: Layout.width - Layout.padding - 22, y: 0, width: 22, height: 22)
        close.autoresizingMask = [.minXMargin, .minYMargin]
        background.addSubview(close)

        let copy = makeButton(symbol: "doc.on.doc", action: #selector(copyTapped))
        copy.frame = NSRect(x: Layout.width - Layout.padding - 50, y: 0, width: 22, height: 22)
        copy.autoresizingMask = [.minXMargin, .minYMargin]
        background.addSubview(copy)

        self.closeButton = close
        self.copyButton = copy

        panel.contentView = background
        return panel
    }

    private var closeButton: NSButton?
    private var copyButton: NSButton?

    private func makeButton(symbol: String, action: Selector) -> NSButton {
        let button = NSButton()
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.contentTintColor = NSColor.white.withAlphaComponent(0.75)
        button.imageScaling = .scaleProportionallyDown
        button.target = self
        button.action = action
        return button
    }

    // MARK: - Układ

    private func resize(for text: String) {
        guard let panel, let textView else { return }

        let inset = Layout.padding * 2
        let available = Layout.width - inset
        let bounding = (text as NSString).boundingRect(
            with: NSSize(width: available, height: Layout.maxTextHeight),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: 13)]
        )

        let textHeight = min(max(ceil(bounding.height), 20), Layout.maxTextHeight)
        let total = textHeight + Layout.padding * 2 + Layout.headerHeight

        panel.setContentSize(NSSize(width: Layout.width, height: total))

        textView.enclosingScrollView?.frame = NSRect(
            x: Layout.padding,
            y: Layout.padding,
            width: available,
            height: textHeight
        )

        let buttonY = total - Layout.padding - 20
        closeButton?.frame.origin = NSPoint(x: Layout.width - Layout.padding - 22, y: buttonY)
        copyButton?.frame.origin = NSPoint(x: Layout.width - Layout.padding - 50, y: buttonY)
    }

    private func reposition() {
        guard let panel, let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size

        // Nad pastylką po prawej, żeby oba elementy trzymały się jednej strony ekranu.
        panel.setFrameOrigin(NSPoint(
            x: visible.maxX - size.width - 24,
            y: visible.midY - size.height / 2
        ))
    }

    // MARK: - Akcje

    private func scheduleDismiss() {
        dismissTimer?.invalidate()
        dismissTimer = Timer.scheduledTimer(
            withTimeInterval: Self.autoDismissSeconds,
            repeats: false
        ) { [weak self] _ in
            self?.hide()
        }
    }

    @objc private func closeTapped() {
        hide()
    }

    @objc private func copyTapped() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        copyButton?.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.copyButton?.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        }
    }

    private enum Layout {
        static let width: CGFloat = 360
        static let padding: CGFloat = 14
        static let headerHeight: CGFloat = 28
        static let maxTextHeight: CGFloat = 180
    }
}

/// Granatowe tło z zaokrąglonymi rogami — ten sam kolor co ikona i pastylka.
private final class BackgroundView: NSView {
    private static let navy = NSColor(red: 0.188, green: 0.263, blue: 0.392, alpha: 1)

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        context.saveGState()
        NSBezierPath(roundedRect: bounds, xRadius: 14, yRadius: 14).addClip()

        let colors = [
            Self.navy.blended(withFraction: 0.10, of: .white)?.cgColor ?? Self.navy.cgColor,
            Self.navy.blended(withFraction: 0.16, of: .black)?.cgColor ?? Self.navy.cgColor
        ]
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                     colors: colors as CFArray, locations: [0, 1]) {
            context.drawLinearGradient(gradient,
                                       start: CGPoint(x: 0, y: bounds.height),
                                       end: CGPoint(x: 0, y: 0),
                                       options: [])
        }
        context.restoreGState()
    }
}
