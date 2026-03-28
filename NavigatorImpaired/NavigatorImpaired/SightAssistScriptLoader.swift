import Foundation

/// Loads bundled SightAssist JS for injection into an OpenClaw / WKWebView host when one exists.
enum SightAssistScriptLoader {
    static func sightAssistSkillsSource() -> String? {
        guard let url = Bundle.main.url(forResource: "SightAssistSkills", withExtension: "js") else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
