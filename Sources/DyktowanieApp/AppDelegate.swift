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

    private let sounds = SoundFeedback()
    private var hotkeyMenuItems: [HotkeyChoice: NSMenuItem] = [:]
    private var soundMenuItem: NSMenuItem?
    private var loginMenuItem: NSMenuItem?

    private var hotkeyChoice: HotkeyChoice {
        get { HotkeyChoice(rawValue: UserDefaults.standard.string(forKey: "hotkey") ?? "") ?? .fn }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "hotkey") }
    }

    private var soundsEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "sounds") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "sounds") }
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
                self.setStatus("Gotowe — przytrzymaj \(hotkeyChoice.title)")
            } else {
                self.setStatus("Brak dostępu do mikrofonu")
            }
        }

        loadTranscriber()

        cleaner.onStateChange = { [weak self] state in
            DispatchQueue.main.async { self?.setStatus(state) }
        }
        startCleaner(model: selectedModel)

        sounds.setEnabled(soundsEnabled)

        hotkey.onPress = { [weak self] in self?.startRecording() }
        hotkey.onRelease = { [weak self] in self?.stopRecording() }
        hotkey.start(choice: hotkeyChoice)

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

        let hotkeyItem = NSMenuItem(title: "Skrót", action: nil, keyEquivalent: "")
        let hotkeyMenu = NSMenu()
        for choice in HotkeyChoice.allCases {
            let item = NSMenuItem(title: choice.title, action: #selector(selectHotkey(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = choice.rawValue
            item.state = (choice == hotkeyChoice) ? .on : .off
            hotkeyMenu.addItem(item)
            hotkeyMenuItems[choice] = item
        }
        hotkeyItem.submenu = hotkeyMenu
        menu.addItem(hotkeyItem)

        let sound = NSMenuItem(title: "Dźwięki", action: #selector(toggleSounds), keyEquivalent: "")
        sound.target = self
        sound.state = soundsEnabled ? .on : .off
        menu.addItem(sound)
        soundMenuItem = sound

        let login = NSMenuItem(title: "Uruchamiaj przy starcie", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = LaunchAtLogin.isEnabled ? .on : .off
        menu.addItem(login)
        loginMenuItem = login

        menu.addItem(NSMenuItem.separator())

        let diagnostics = NSMenuItem(title: "Diagnostyka…", action: #selector(showDiagnostics), keyEquivalent: "")
        diagnostics.target = self
        menu.addItem(diagnostics)

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
            sounds.play(.start)
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
        sounds.play(.stop)
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
        var cleaned = text
        do {
            cleaned = try cleaner.clean(text: text)
        } catch {
            // Nieudane czyszczenie nie może wstrzymać wstawiania — użytkownik
            // dostaje wtedy surową transkrypcję, ale dostaje ją tam, gdzie chciał.
            NSLog("Czyszczenie nieudane, zostaje surowy tekst: \(error.localizedDescription)")
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

    /// Zbiera stan wszystkich elementów w jednym miejscu — przy problemach
    /// łatwiej wskazać, który krok pipeline'u nie działa.
    @objc private func showDiagnostics() {
        let accessibility = Permissions.hasAccessibility(prompt: false)

        var report = """
        Accessibility:  \(accessibility ? "TAK" : "NIE — bez tego skrót i wpisywanie nie zadziałają")
        Mikrofon:       \(Permissions.hasMicrophone ? "TAK" : "NIE")
        Model Whisper:  \(transcriber != nil ? "wczytany" : "BRAK")
        Czyszczenie:    \(cleaner.model.title)
        Stan modelu:    \(cleaner.model == .disabled ? "wyłączone" : (cleaner.isReady ? "gotowy" : "NIEGOTOWY"))
        Wstawianie:     \(injectionMethod.title)
        Skrót:          \(hotkeyChoice.title)
        Skrót zadziałał: \(hotkey.pressCount) raz(y)
        Ostatni klawisz: \(hotkey.lastSeenKeyCode.map(String.init) ?? "żaden nie dotarł")
        Przy starcie:   \(LaunchAtLogin.isEnabled ? "TAK" : "nie")
        Dźwięki:        \(soundsEnabled ? "włączone" : "wyłączone")\(sounds.isWorking ? "" : " — silnik audio NIE działa")

        Ścieżka aplikacji:
        \(Bundle.main.bundlePath)
        """

        if let transcript = lastTranscript {
            report += "\n\nOstatni tekst:\n\(transcript)"
        }

        let alert = NSAlert()
        alert.messageText = "Diagnostyka"
        alert.informativeText = report
        alert.addButton(withTitle: "Kopiuj i zamknij")
        alert.addButton(withTitle: "Zamknij")

        if !accessibility {
            alert.addButton(withTitle: "Otwórz ustawienia")
        }

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()

        if response == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(report, forType: .string)
        } else if response == .alertThirdButtonReturn {
            Permissions.openAccessibilitySettings()
        }
    }

    @objc private func selectHotkey(_ sender: NSMenuItem) {
        guard
            let raw = sender.representedObject as? String,
            let choice = HotkeyChoice(rawValue: raw)
        else { return }

        hotkeyChoice = choice
        for (candidate, item) in hotkeyMenuItems {
            item.state = (candidate == choice) ? .on : .off
        }

        hotkey.start(choice: choice)
        setStatus("Skrót: przytrzymaj \(choice.title)")
    }

    @objc private func toggleSounds() {
        soundsEnabled.toggle()
        sounds.setEnabled(soundsEnabled)
        soundMenuItem?.state = soundsEnabled ? .on : .off
        if soundsEnabled { sounds.play(.start) }
    }

    @objc private func toggleLaunchAtLogin() {
        let target = !LaunchAtLogin.isEnabled

        if let problem = LaunchAtLogin.set(target) {
            setStatus(problem)
            NSLog("Element logowania: \(problem)")
        } else {
            setStatus(target ? "Będzie uruchamiane przy starcie" : "Nie będzie uruchamiane przy starcie")
        }

        loginMenuItem?.state = LaunchAtLogin.isEnabled ? .on : .off
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
