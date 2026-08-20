import AppKit

// Tryb testowy: nagrywa N sekund i wypisuje statystyki pliku, bez UI.
// Użycie: build/Dyktowanie.app/Contents/MacOS/DyktowanieApp --test-record 3
if let index = CommandLine.arguments.firstIndex(of: "--test-record") {
    let seconds = Double(CommandLine.arguments[safe: index + 1] ?? "3") ?? 3
    TestRecording.run(seconds: seconds)
} else if let index = CommandLine.arguments.firstIndex(of: "--test-transcribe") {
    guard let path = CommandLine.arguments[safe: index + 1] else {
        print("Użycie: --test-transcribe ścieżka/do/pliku.wav")
        exit(1)
    }
    TestRecording.transcribeFile(path: path)
} else if let index = CommandLine.arguments.firstIndex(of: "--test-pipeline") {
    guard let path = CommandLine.arguments[safe: index + 1] else {
        print("Użycie: --test-pipeline plik.wav [fast|faithful|disabled]")
        exit(1)
    }
    let model = CleanupModel(rawValue: CommandLine.arguments[safe: index + 2] ?? "fast") ?? .fast
    TestRecording.pipeline(path: path, model: model)
} else if let index = CommandLine.arguments.firstIndex(of: "--test-inject") {
    let text = CommandLine.arguments[safe: index + 1]
        ?? "Zażółć gęślą jaźń — ĄĆĘŁŃÓŚŹŻ, test wpisywania 123."
    let method = InjectionMethod(rawValue: CommandLine.arguments[safe: index + 2] ?? "typing") ?? .typing
    TestRecording.inject(text: text, method: method)
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
