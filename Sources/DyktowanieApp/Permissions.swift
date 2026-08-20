import AppKit
import AVFoundation
import ApplicationServices

enum Permissions {
    /// Prosi o dostęp do mikrofonu (przy pierwszym uruchomieniu pokaże systemowy prompt).
    static func requestMicrophone(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        default:
            completion(false)
        }
    }

    static var hasMicrophone: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// Sprawdza uprawnienie Accessibility (potrzebne do globalnego skrótu).
    /// - Parameter prompt: czy pokazać systemowe okno kierujące do Ustawień.
    static func hasAccessibility(prompt: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    static func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }
}
