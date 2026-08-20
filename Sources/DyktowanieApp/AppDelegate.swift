import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let recorder = AudioRecorder()
    private let hotkey = HotkeyMonitor()

    private var statusMenuItem: NSMenuItem?
    private var toggleMenuItem: NSMenuItem?
    private var lastRecordingURL: URL?

    private var transcriber: WhisperTranscriber?
    private var lastTranscript: String?

    private let cleaner = TextCleaner()
    private let injector = TextInjector()
    private var modelMenuItems: [CleanupModel: NSMenuItem] = [:]
    private var methodMenuItems: [InjectionMethod: NSMenuItem] = [:]

    private var injectionMethod: InjectionMethod {
        get { InjectionMethod(rawValue: UserDefaults.standard.string(forKey: "injectionMethod") ?? "") ?? .typing }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "injectionMethod") }
    }

    /// Wybór modelu przeżywa restart aplikacji.
    private var selectedModel: CleanupModel {
        get { CleanupModel(rawValue: UserDefaults.standard.string(forKey: "cleanupModel") ?? "") ?? .fast }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "cleanupModel") }
    }

    /// Transkrypcja liczy się poza głównym wątkiem, żeby nie zamrażać menu.
    private let transcribeQueue = DispatchQueue(label: "local.dyktowanie.transcribe", qos: .userInitiated)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        buildStatusItem()

        Permissions.requestMicrophone { [weak self] granted in
            guard let self else { return }
            if granted {
                self.setStatus("Gotowe — przytrzymaj \(HotkeyMonitor.Key.currentDescription)")
            } else {
                self.setStatus("Brak dostępu do mikrofonu")
            }
        }

        loadTranscriber()

        cleaner.onStateChange = { [weak self] state in
            DispatchQueue.main.async { self?.setStatus(state) }
        }
        startCleaner(model: selectedModel)

        hotkey.onPress = { [weak self] in self?.startRecording() }
        hotkey.onRelease = { [weak self] in self?.stopRecording() }
        hotkey.start()

        if !Permissions.hasAccessibility(prompt: true) {
            setStatus("Przyznaj Accessibility, by działał skrót")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkey.stop()
        if recorder.isRecording { _ = recorder.stop() }

        cleaner.shutdown()

        // Zwolnij kontekst whisper.cpp, zanim proces zacznie się zamykać —
        // backend Metal przewraca się, jeśli zostaną nieuwolnione zasoby.
        transcriber = nil
    }

    // MARK: - UI

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item

        item.button?.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "Dyktowanie")

        let menu = NSMenu()

        let status = NSMenuItem(title: "Uruchamianie…", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        statusMenuItem = status

        menu.addItem(NSMenuItem.separator())

        // Ręczny przełącznik — pozwala testować nagrywanie bez uprawnienia Accessibility.
        let toggle = NSMenuItem(title: "Rozpocznij nagrywanie", action: #selector(toggleRecording), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        toggleMenuItem = toggle

        let copy = NSMenuItem(title: "Kopiuj transkrypcję", action: #selector(copyTranscript), keyEquivalent: "")
        copy.target = self
        menu.addItem(copy)

        let reveal = NSMenuItem(title: "Pokaż ostatnie nagranie", action: #selector(revealLastRecording), keyEquivalent: "")
        reveal.target = self
        menu.addItem(reveal)

        menu.addItem(NSMenuItem.separator())

        let modelItem = NSMenuItem(title: "Czyszczenie tekstu", action: nil, keyEquivalent: "")
        let modelMenu = NSMenu()
        for model in CleanupModel.allCases {
            let item = NSMenuItem(title: model.title, action: #selector(selectModel(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = model.rawValue
            item.state = (model == selectedModel) ? .on : .off
            modelMenu.addItem(item)
            modelMenuItems[model] = item
        }
        modelItem.submenu = modelMenu
        menu.addItem(modelItem)

        let methodItem = NSMenuItem(title: "Wstawianie tekstu", action: nil, keyEquivalent: "")
        let methodMenu = NSMenu()
        for method in InjectionMethod.allCases {
            let item = NSMenuItem(title: method.title, action: #selector(selectMethod(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = method.rawValue
            item.state = (method == injectionMethod) ? .on : .off
            methodMenu.addItem(item)
            methodMenuItems[method] = item
        }
        methodItem.submenu = methodMenu
        menu.addItem(methodItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Zakończ", action: #selector(quit), keyEquivalent: "q"))

        item.menu = menu
    }

    private func setStatus(_ text: String) {
        statusMenuItem?.title = text
    }

    private func updateIcon(recording: Bool) {
        let symbol = recording ? "mic.fill" : "mic"
        statusItem?.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Dyktowanie")
        statusItem?.button?.contentTintColor = recording ? .systemRed : nil
        toggleMenuItem?.title = recording ? "Zatrzymaj nagrywanie" : "Rozpocznij nagrywanie"
    }

    // MARK: - Model

    /// Model ładuje się w tle — zajmuje to chwilę, a ikona ma być klikalna od razu.
    private func loadTranscriber() {
        guard let modelPath = ModelLocator.whisperModel() else {
            let searched = ModelLocator.searchPaths(for: ModelLocator.whisperModelName)
                .map(\.path)
                .joined(separator: "\n  ")
            NSLog("Nie znaleziono modelu Whisper. Szukano w:\n  \(searched)")
            setStatus("Brak modelu Whisper")
            return
        }

        transcribeQueue.async { [weak self] in
            let started = Date()
            do {
                let transcriber = try WhisperTranscriber(modelPath: modelPath, vadModelPath: ModelLocator.vadModel())
                let elapsed = Date().timeIntervalSince(started)
                DispatchQueue.main.async {
                    self?.transcriber = transcriber
                    NSLog("Model Whisper wczytany w \(String(format: "%.2f", elapsed))s: \(modelPath)")
                }
            } catch {
                NSLog("Błąd ładowania modelu: \(error.localizedDescription)")
                DispatchQueue.main.async { self?.setStatus("Błąd modelu: \(error.localizedDescription)") }
            }
        }
    }

    // MARK: - Nagrywanie

    private func startRecording() {
        guard !recorder.isRecording else { return }

        guard Permissions.hasMicrophone else {
            setStatus("Brak dostępu do mikrofonu")
            return
        }

        do {
            try recorder.start()
            updateIcon(recording: true)
            setStatus("Nagrywanie…")
        } catch {
            setStatus("Błąd: \(error.localizedDescription)")
            NSLog("Nie udało się rozpocząć nagrywania: \(error.localizedDescription)")
        }
    }

    private func stopRecording() {
        guard let result = recorder.stop() else { return }

        lastRecordingURL = result.url
        updateIcon(recording: false)

        let seconds = String(format: "%.1f", result.duration)
        NSLog("Nagranie zapisane: \(result.url.path) (\(seconds)s)")

        guard let transcriber else {
            setStatus("Zapisano \(seconds)s — brak modelu")
            return
        }

        setStatus("Transkrypcja \(seconds)s…")
        transcribe(samples: result.samples, using: transcriber, duration: result.duration)
    }

    private func transcribe(samples: [Float], using transcriber: WhisperTranscriber, duration: TimeInterval) {
        transcribeQueue.async { [weak self] in
            let started = Date()
            do {
                let text = try transcriber.transcribe(samples: samples)
                let elapsed = Date().timeIntervalSince(started)

                NSLog("--- TRANSKRYPCJA (\(String(format: "%.2f", elapsed))s dla \(String(format: "%.1f", duration))s audio) ---")
                NSLog("%@", text.isEmpty ? "(pusto)" : text)

                guard !text.isEmpty else {
                    DispatchQueue.main.async { self?.setStatus("Nic nie rozpoznano") }
                    return
                }

                DispatchQueue.main.async { self?.setStatus("Czyszczenie tekstu…") }
                self?.clean(text: text)
            } catch {
                NSLog("Błąd transkrypcji: \(error.localizedDescription)")
                DispatchQueue.main.async { self?.setStatus("Błąd: \(error.localizedDescription)") }
            }
        }
    }

    @objc private func toggleRecording() {
        if recorder.isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    /// Ostatni krok pipeline'u. Gdy czyszczenie zawiedzie, zostawiamy surową
    /// transkrypcję — lepszy niedoskonały tekst niż żaden.
    private func clean(text: String) {
        let started = Date()
        let cleaned: String
        do {
            cleaned = try cleaner.clean(text: text)
        } catch {
            NSLog("Czyszczenie nieudane, zostaje surowy tekst: \(error.localizedDescription)")
            DispatchQueue.main.async { [weak self] in
                self?.lastTranscript = text
                self?.setStatus(text)
            }
            return
        }

        if cleaner.model != .disabled {
            NSLog("--- PO CZYSZCZENIU (\(String(format: "%.2f", Date().timeIntervalSince(started)))s) ---")
            NSLog("%@", cleaned)
        }

        DispatchQueue.main.async { [weak self] in
            self?.finish(text: cleaned)
        }
    }

    /// Ostatni krok: tekst trafia tam, gdzie stoi kursor użytkownika.
    private func finish(text: String) {
        lastTranscript = text

        guard injectionMethod != .none else {
            setStatus(text)
            return
        }

        let method = injectionMethod

        // Wpisywanie idzie porcjami z przerwami, więc nie może blokować menu.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                try self.injector.inject(text, method: method)
                DispatchQueue.main.async { self.setStatus("Wstawiono: \(text)") }
            } catch {
                // Tekst zostaje w menu i w schowku — użytkownik go nie traci.
                NSLog("Wstawianie nieudane: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    self.setStatus("\(error.localizedDescription) Tekst jest w schowku.")
                }
            }
        }
    }

    @objc private func selectMethod(_ sender: NSMenuItem) {
        guard
            let raw = sender.representedObject as? String,
            let method = InjectionMethod(rawValue: raw)
        else { return }

        injectionMethod = method
        for (candidate, item) in methodMenuItems {
            item.state = (candidate == method) ? .on : .off
        }
        setStatus(method.title)
    }

    @objc private func selectModel(_ sender: NSMenuItem) {
        guard
            let raw = sender.representedObject as? String,
            let model = CleanupModel(rawValue: raw),
            model != cleaner.model
        else { return }

        selectedModel = model
        for (candidate, item) in modelMenuItems {
            item.state = (candidate == model) ? .on : .off
        }

        startCleaner(model: model)
    }

    /// Przełączenie modelu to restart procesu Pythona — dzięki temu w pamięci
    /// nigdy nie siedzą oba modele naraz.
    private func startCleaner(model: CleanupModel) {
        do {
            try cleaner.start(model: model)
        } catch {
            NSLog("Nie udało się uruchomić czyszczenia: \(error.localizedDescription)")
            setStatus(error.localizedDescription)
        }
    }

    @objc private func copyTranscript() {
        guard let lastTranscript, !lastTranscript.isEmpty else {
            setStatus("Brak transkrypcji do skopiowania")
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastTranscript, forType: .string)
        setStatus("Skopiowano do schowka")
    }

    @objc private func revealLastRecording() {
        guard let lastRecordingURL else {
            setStatus("Brak nagrań w tej sesji")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([lastRecordingURL])
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
