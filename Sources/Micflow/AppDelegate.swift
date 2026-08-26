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

    private let sounds = SoundFeedback()
    private let indicator = RecordingIndicator()
    private let transcriptPanel = TranscriptPanel()

    /// Czy w chwili rozpoczęcia nagrania kursor stał w polu tekstowym.
    /// Sprawdzamy wtedy, bo później fokus mógł się zmienić — a użytkownik
    /// oczekuje tekstu tam, gdzie klikał PRZED dyktowaniem.
    private var hadTextFieldAtStart = false

    /// Ostatnio wykryta rola elementu z fokusem — widoczna w Diagnostyce,
    /// żeby dało się ustalić, czemu w danej aplikacji poszło nie tak.
    private var lastFocusRole = "—"
    private var hotkeyMenuItems: [HotkeyChoice: NSMenuItem] = [:]
    private var languageMenuItems: [DictationLanguage: NSMenuItem] = [:]

    private var language: DictationLanguage {
        get { DictationLanguage(rawValue: UserDefaults.standard.string(forKey: "language") ?? "") ?? .polish }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "language") }
    }
    private var modeMenuItems: [HotkeyMode: NSMenuItem] = [:]

    private var hotkeyMode: HotkeyMode {
        get { HotkeyMode(rawValue: UserDefaults.standard.string(forKey: "hotkeyMode") ?? "") ?? .toggle }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "hotkeyMode") }
    }
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

    /// W trybie dwukliku nagrywanie trwa, dopóki użytkownik go nie przerwie —
    /// łatwo o nim zapomnieć. Bez limitu próbki rosłyby w nieskończoność
    /// (~64 kB na sekundę), a transkrypcja godzinnego nagrania trwałaby minuty.
    private static let maximumRecordingSeconds: TimeInterval = 300
    private var recordingLimitTimer: Timer?

    /// Transkrypcja liczy się poza głównym wątkiem, żeby nie zamrażać menu.
    private let transcribeQueue = DispatchQueue(label: "local.micflow.transcribe", qos: .userInitiated)

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
        startCleaner()

        sounds.setEnabled(soundsEnabled)

        recorder.onLevel = { [weak self] level in self?.indicator.update(level: level) }

        hotkey.isRecording = { [weak self] in self?.recorder.isRecording ?? false }
        hotkey.onPress = { [weak self] in self?.startRecording() }
        hotkey.onRelease = { [weak self] in self?.stopRecording() }
        hotkey.start(choice: hotkeyChoice, mode: hotkeyMode)

        if !Permissions.hasAccessibility(prompt: true) {
            setStatus("Przyznaj Accessibility, by działał skrót")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkey.stop()
        indicator.hide()
        if recorder.isRecording { _ = recorder.stop() }

        transcriptPanel.hide()
        cleaner.shutdown()

        // Zwolnij kontekst whisper.cpp, zanim proces zacznie się zamykać —
        // backend Metal przewraca się, jeśli zostaną nieuwolnione zasoby.
        transcriber = nil
    }

    // MARK: - UI

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item

        item.button?.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "MICFLOW")

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

        let languageItem = NSMenuItem(title: "Języki", action: nil, keyEquivalent: "")
        let languageMenu = NSMenu()
        for option in DictationLanguage.allCases {
            let item = NSMenuItem(title: option.title, action: #selector(selectLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option.rawValue
            item.state = (option == language) ? .on : .off
            languageMenu.addItem(item)
            languageMenuItems[option] = item
        }
        languageItem.submenu = languageMenu
        menu.addItem(languageItem)

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

        let modeItem = NSMenuItem(title: "Sposób nagrywania", action: nil, keyEquivalent: "")
        let modeMenu = NSMenu()
        for mode in HotkeyMode.allCases {
            let item = NSMenuItem(title: mode.title, action: #selector(selectMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = (mode == hotkeyMode) ? .on : .off
            modeMenu.addItem(item)
            modeMenuItems[mode] = item
        }
        modeItem.submenu = modeMenu
        menu.addItem(modeItem)

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
        statusItem?.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "MICFLOW")
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

        let languageCode = language.whisperCode
        transcribeQueue.async { [weak self] in
            let started = Date()
            do {
                let transcriber = try WhisperTranscriber(
                    modelPath: modelPath,
                    vadModelPath: ModelLocator.vadModel(),
                    language: languageCode
                )
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
            transcriptPanel.hide()

            let role = TextInjector.focusedTextRole()
            hadTextFieldAtStart = role != nil
            lastFocusRole = role ?? "brak fokusu"
            NSLog("Pole tekstowe przy starcie: %@", lastFocusRole)

            try recorder.start()
            sounds.play(.start)
            startRecordingLimit()
            updateIcon(recording: true)
            indicator.show(.listening)
            setStatus("Nagrywanie…")
        } catch {
            indicator.hide()
            setStatus("Błąd: \(error.localizedDescription)")
            NSLog("Nie udało się rozpocząć nagrywania: \(error.localizedDescription)")
        }
    }

    private func stopRecording() {
        recordingLimitTimer?.invalidate()
        recordingLimitTimer = nil

        guard let result = recorder.stop() else { return }

        // Poprzednie nagranie przestaje być potrzebne w chwili, gdy mamy nowe.
        // Bez tego pliki WAV odkładałyby się w nieskończoność.
        discardRecording(at: lastRecordingURL)
        lastRecordingURL = result.url

        sounds.play(.stop)
        updateIcon(recording: false)
        indicator.show(.processing)

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
                    DispatchQueue.main.async {
                        self?.indicator.hide()
                        self?.setStatus("Nic nie rozpoznano")
                    }
                    return
                }

                DispatchQueue.main.async { self?.setStatus("Czyszczenie tekstu…") }
                self?.clean(text: text, language: transcriber.detectedLanguage)
            } catch {
                NSLog("Błąd transkrypcji: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self?.indicator.hide()
                    self?.setStatus("Błąd: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Automatycznie kończy nagranie po ustalonym czasie.
    private func startRecordingLimit() {
        recordingLimitTimer?.invalidate()
        recordingLimitTimer = Timer.scheduledTimer(
            withTimeInterval: Self.maximumRecordingSeconds,
            repeats: false
        ) { [weak self] _ in
            guard let self, self.recorder.isRecording else { return }
            NSLog("Osiągnięto limit \(Int(Self.maximumRecordingSeconds))s — kończę nagranie.")
            self.stopRecording()
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
    private func clean(text: String, language: String) {
        let started = Date()
        var cleaned = text
        do {
            cleaned = try cleaner.clean(text: text, language: language)
        } catch {
            // Nieudane czyszczenie nie może wstrzymać wstawiania — użytkownik
            // dostaje wtedy surową transkrypcję, ale dostaje ją tam, gdzie chciał.
            NSLog("Czyszczenie nieudane, zostaje surowy tekst: \(error.localizedDescription)")
        }

        NSLog("--- PO CZYSZCZENIU (\(String(format: "%.2f", Date().timeIntervalSince(started)))s) ---")
        NSLog("%@", cleaned)

        DispatchQueue.main.async { [weak self] in
            self?.finish(text: cleaned)
        }
    }

    /// Usuwa plik nagrania. Na dysku trzymamy tylko ostatni, dla pozycji
    /// „Pokaż ostatnie nagranie".
    private func discardRecording(at url: URL?) {
        guard let url else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
            // Katalog tymczasowy mógł zostać wyczyszczony przez system — w porządku.
        } catch {
            NSLog("Nie udało się usunąć nagrania \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Ostatni krok: tekst trafia tam, gdzie stoi kursor użytkownika.
    private func finish(text: String) {
        lastTranscript = text
        indicator.hide()

        // Panel tylko wtedy, gdy ANI przy starcie, ANI teraz nie było pola
        // tekstowego. Jedno trafienie wystarczy, żeby wpisać — pomyłka w tę
        // stronę jest tańsza niż niepotrzebny panel.
        let roleNow = TextInjector.focusedTextRole()
        NSLog("Pole tekstowe przy wstawianiu: %@ (przy starcie: %@)",
              roleNow ?? "brak", hadTextFieldAtStart ? "tak" : "nie")

        guard hadTextFieldAtStart || roleNow != nil else {
            transcriptPanel.show(text: text)
            setStatus("Brak pola tekstowego — tekst w panelu")
            return
        }

        // Wpisywanie idzie porcjami z przerwami, więc nie może blokować menu.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                try self.injector.inject(text)
                DispatchQueue.main.async { self.setStatus("Wstawiono: \(text)") }
            } catch {
                NSLog("Wstawianie nieudane: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.transcriptPanel.show(text: text)
                    self.setStatus(error.localizedDescription)
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
        Czyszczenie:    \(cleaner.isReady ? "gotowe" : "NIEGOTOWE")
        Język:          \(language.title)
        Ostatnio wykryty: \(transcriber?.detectedLanguage ?? "—")
        Element z fokusem: \(lastFocusRole)
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

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard
            let raw = sender.representedObject as? String,
            let option = DictationLanguage(rawValue: raw)
        else { return }

        language = option
        for (candidate, item) in languageMenuItems {
            item.state = (candidate == option) ? .on : .off
        }

        // Język podajemy przy każdej transkrypcji, więc zmiana działa od razu
        // i nie wymaga przeładowania modelu.
        transcriber?.language = option.whisperCode
        setStatus("Język: \(option.title)")
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

        hotkey.start(choice: choice, mode: hotkeyMode)
        setStatus("Skrót: \(choice.title)")
    }

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard
            let raw = sender.representedObject as? String,
            let mode = HotkeyMode(rawValue: raw)
        else { return }

        hotkeyMode = mode
        for (candidate, item) in modeMenuItems {
            item.state = (candidate == mode) ? .on : .off
        }

        hotkey.start(choice: hotkeyChoice, mode: mode)
        setStatus(mode.title)
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

    private func startCleaner() {
        do {
            try cleaner.start()
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
