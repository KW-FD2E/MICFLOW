import AppKit

// Tryb testowy: nagrywa N sekund i wypisuje statystyki pliku, bez UI.
// Użycie: build/MICFLOW.app/Contents/MacOS/Micflow --test-record 3
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
        print("Użycie: --test-pipeline plik.wav")
        exit(1)
    }
    TestRecording.pipeline(path: path)
} else if let index = CommandLine.arguments.firstIndex(of: "--test-inject") {
    let text = CommandLine.arguments[safe: index + 1]
        ?? "Zażółć gęślą jaźń — ĄĆĘŁŃÓŚŹŻ, test wpisywania 123."
    TestRecording.inject(text: text)
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
