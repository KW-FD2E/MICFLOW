import Foundation
import ServiceManagement

/// Uruchamianie przy starcie systemu przez SMAppService (macOS 13+).
/// Rejestruje sam pakiet .app jako element logowania.
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Zwraca komunikat o błędzie albo nil, gdy się udało.
    static func set(_ enabled: Bool) -> String? {
        do {
            if enabled {
                // Ponowna rejestracja bez wyrejestrowania kończy się błędem,
                // jeśli wpis już istnieje w stanie "requiresApproval".
                if SMAppService.mainApp.status == .requiresApproval {
                    return "Otwórz Ustawienia → Ogólne → Elementy logowania i zezwól na MICFLOW."
                }
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
