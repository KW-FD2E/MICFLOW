import AppKit

/// Pionowa pastylka przy prawej krawędzi ekranu, pokazywana na czas dyktowania.
///
/// Proporcje odwzorowane z Wispr Flow: 30×72 px przy szerokości ekranu 1920,
/// 6 px od krawędzi, wyśrodkowana pionowo, 12 poziomych pasków w środku.
/// Szerokość pasków napędza bieżący poziom sygnału z mikrofonu.
///
/// Okno jest nieaktywne i przezroczyste dla myszy, żeby nie odebrało kursora
/// polu tekstowemu, do którego zaraz wpiszemy tekst.
final class RecordingIndicator {
    enum State {
        case listening
        case processing
    }

    private var panel: NSPanel?
    private var view: PillView?

    // MARK: - Sterowanie

    func show(_ state: State) {
        let panel = self.panel ?? makePanel()
        self.panel = panel

        view?.state = state
        reposition()
        panel.orderFrontRegardless()
        view?.startAnimating()
    }

    /// Poziom z mikrofonu (0–1). Wołane z wątku audio, więc przerzucamy na główny.
    func update(level: Float) {
        DispatchQueue.main.async { [weak self] in
            self?.view?.push(level: level)
        }
    }

    func hide() {
        view?.stopAnimating()
        panel?.orderOut(nil)
    }

    /// Rysuje pastylkę do obrazka — służy do obejrzenia wyglądu bez uruchamiania
    /// całej aplikacji i bez dostępu do mikrofonu.
    static func renderPreview(levels: [Float], state: State, scale: CGFloat = 6) -> NSImage {
        let view = PillView(frame: NSRect(origin: .zero, size: PillView.size))
        view.state = state
        view.setPreviewLevels(levels)

        let size = NSSize(width: PillView.size.width * scale, height: PillView.size.height * scale)
        let image = NSImage(size: size)
        image.lockFocus()
        NSGraphicsContext.current?.cgContext.scaleBy(x: scale, y: scale)
        view.draw(view.bounds)
        image.unlockFocus()
        return image
    }

    // MARK: - Budowa okna

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: PillView.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false

        let view = PillView(frame: NSRect(origin: .zero, size: PillView.size))
        panel.contentView = view
        self.view = view

        return panel
    }

    private func reposition() {
        guard let panel, let screen = NSScreen.main else { return }

        let frame = screen.visibleFrame
        let size = PillView.size
        panel.setFrameOrigin(NSPoint(
            x: frame.maxX - size.width - 8,
            y: frame.midY - size.height / 2
        ))
    }
}

/// Rysuje pastylkę i paski poziomu.
private final class PillView: NSView {
    static let size = NSSize(width: 28, height: 67)

    private static let barCount = 12
    private static let barHeight: CGFloat = 2.0
    private static let barSpacing: CGFloat = 2.4
    private static let minBarWidth: CGFloat = 3
    private static let maxBarWidth: CGFloat = 17

    /// Granat z ikony aplikacji (#304364).
    private static let navy = NSColor(red: 0.188, green: 0.263, blue: 0.392, alpha: 1)

    var state: RecordingIndicator.State = .listening {
        didSet { needsDisplay = true }
    }

    /// Historia poziomów — najnowszy wchodzi na górze i spycha resztę w dół,
    /// dzięki czemu paski płyną zamiast skakać w miejscu.
    private var levels = [Float](repeating: 0, count: PillView.barCount)

    /// Bufory z mikrofonu przychodzą ~11 razy na sekundę, a rysujemy 60 —
    /// bez wygładzania animacja byłaby skokowa.
    private var current: Float = 0
    private var target: Float = 0

    private var timer: Timer?
    private var spinnerPhase: CGFloat = 0

    // MARK: - Animacja

    func startAnimating() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        // .common — bez tego animacja zamiera, gdy otwarte jest menu aplikacji.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stopAnimating() {
        timer?.invalidate()
        timer = nil
        levels = [Float](repeating: 0, count: Self.barCount)
        current = 0
        target = 0
    }

    func setPreviewLevels(_ values: [Float]) {
        for (index, value) in values.prefix(Self.barCount).enumerated() {
            levels[index] = value
        }
    }

    func push(level: Float) {
        // Mowa mieści się w wąskim zakresie RMS, więc rozciągamy go pierwiastkiem —
        // inaczej paski ledwo drgały przy normalnej głośności.
        target = min(1, (level * 12).squareRoot())
    }

    private func tick() {
        current += (target - current) * 0.25
        target *= 0.92                       // opadanie, gdy mikrofon milczy

        levels.removeLast()
        levels.insert(current, at: 0)

        if state == .processing { spinnerPhase += 0.12 }

        needsDisplay = true
    }

    // MARK: - Rysowanie

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        drawCapsule(in: context)

        switch state {
        case .listening:  drawBars(in: context)
        case .processing: drawProcessing(in: context)
        }
    }

    private func drawCapsule(in context: CGContext) {
        context.saveGState()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.width / 2, yRadius: bounds.width / 2).addClip()

        // Delikatny gradient jak na ikonie — jaśniej u góry, ciemniej u dołu.
        let colors = [
            Self.navy.blended(withFraction: 0.12, of: .white)?.cgColor ?? Self.navy.cgColor,
            Self.navy.blended(withFraction: 0.18, of: .black)?.cgColor ?? Self.navy.cgColor
        ]
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                     colors: colors as CFArray, locations: [0, 1]) {
            // y rośnie do góry, więc jaśniejszy kolor idzie na górną krawędź.
            context.drawLinearGradient(gradient,
                                       start: CGPoint(x: 0, y: bounds.height),
                                       end: CGPoint(x: 0, y: 0),
                                       options: [])
        }
        context.restoreGState()
    }

    private func drawBars(in context: CGContext) {
        let totalHeight = CGFloat(Self.barCount) * Self.barHeight
            + CGFloat(Self.barCount - 1) * Self.barSpacing
        var y = (bounds.height - totalHeight) / 2

        context.setFillColor(NSColor.white.cgColor)

        for index in 0..<Self.barCount {
            // Soczewka: środkowe paski sięgają dalej niż skrajne. Bez tego
            // kształt byłby prostokątny i wyglądał martwo.
            let distance = abs(CGFloat(index) - CGFloat(Self.barCount - 1) / 2)
            let envelope = 1 - pow(distance / (CGFloat(Self.barCount) / 2), 2) * 0.55

            let width = Self.minBarWidth
                + (Self.maxBarWidth - Self.minBarWidth) * CGFloat(levels[index]) * envelope

            let rect = CGRect(x: (bounds.width - width) / 2, y: y, width: width, height: Self.barHeight)
            context.addPath(CGPath(roundedRect: rect,
                                   cornerWidth: Self.barHeight / 2,
                                   cornerHeight: Self.barHeight / 2,
                                   transform: nil))
            context.fillPath()

            y += Self.barHeight + Self.barSpacing
        }
    }

    /// Stan po zakończeniu mówienia: kropki u góry i obracający się wskaźnik.
    private func drawProcessing(in context: CGContext) {
        context.setFillColor(NSColor.white.withAlphaComponent(0.55).cgColor)

        // Kropki u góry, wskaźnik u dołu — jak w oryginale.
        var y = bounds.height * 0.74
        for _ in 0..<6 {
            context.addPath(CGPath(ellipseIn: CGRect(x: bounds.width / 2 - 1, y: y, width: 2, height: 2),
                                   transform: nil))
            context.fillPath()
            y -= 4.5
        }

        let center = CGPoint(x: bounds.width / 2, y: bounds.height * 0.28)
        let spokes = 8
        context.setLineWidth(1.4)
        context.setLineCap(.round)
        for index in 0..<spokes {
            let angle = spinnerPhase + CGFloat(index) * (.pi * 2 / CGFloat(spokes))
            let alpha = 0.25 + 0.75 * (CGFloat(index) / CGFloat(spokes))
            context.setStrokeColor(NSColor.white.withAlphaComponent(alpha).cgColor)
            context.move(to: CGPoint(x: center.x + cos(angle) * 2.5, y: center.y + sin(angle) * 2.5))
            context.addLine(to: CGPoint(x: center.x + cos(angle) * 5.5, y: center.y + sin(angle) * 5.5))
            context.strokePath()
        }
    }
}
