import SwiftUI

/// App-wide appearance choice.
///
/// The reader keeps its own paper/sepia/night palettes — those are reading
/// surfaces, not the app chrome — so this only governs the browsing UI.
enum AppAppearance: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    public var systemImage: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }

    /// `nil` means "follow the system", which is what `preferredColorScheme` wants.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    static let storageKey = "app.appearance"

    static var current: AppAppearance {
        let raw = UserDefaults.standard.string(forKey: storageKey) ?? AppAppearance.system.rawValue
        return AppAppearance(rawValue: raw) ?? .system
    }
}
