import SwiftUI
import AppKit

/// Appearance chosen in the settings popover (stored in UserDefaults "NovaMac.theme").
enum AppTheme: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var scheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
    var title: LocalizedStringKey {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

/// Interface language chosen in the settings popover (stored in UserDefaults "NovaMac.language").
/// Applied at once to the SwiftUI texts through the environment locale, and written to "AppleLanguages" so that
/// menus and the rest of the app follow after a restart.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, en, ru, zhHans = "zh-Hans"
    var id: String { rawValue }
    var locale: Locale? { self == .system ? nil : Locale(identifier: rawValue) }
    /// Each language's own name, so it can be found whatever the current language is.
    var title: String {
        switch self {
        case .system: return String(localized: "System")
        case .en: return "English"
        case .ru: return "Русский"
        case .zhHans: return "简体中文"
        }
    }
    func apply() {
        if self == .system { UserDefaults.standard.removeObject(forKey: "AppleLanguages") }
        else { UserDefaults.standard.set([rawValue], forKey: "AppleLanguages") }
    }
}

extension Color {
    /// A colour with separate light and dark values that follows the window's appearance.
    static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

/// The small settings panel behind the gear button in the top bar.
struct SettingsPopover: View {
    @Binding var theme: String
    @Binding var language: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Settings").font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                Text("Appearance").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $theme) {
                    ForEach(AppTheme.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 260)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Language").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: Binding(get: { language }, set: { value in
                    language = value
                    AppLanguage(rawValue: value)?.apply()
                })) {
                    ForEach(AppLanguage.allCases) { Text(verbatim: $0.title).tag($0.rawValue) }
                }
                .labelsHidden()
                .frame(width: 260)
                Text("Menus and some messages change after restarting NovaMac.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 260, alignment: .leading)
            }
        }
        .padding(16)
    }
}
