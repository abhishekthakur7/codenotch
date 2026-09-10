import Foundation

/// How a provider's own plan slug is shown under the tooltip title.
///
/// The wire names are lowercase tokens (`plus`, `max_5x`, `extra_usage`).
/// The card wants the same words the provider prints on its own account page.
enum SubscriptionPlan {
    /// Nil when there is no tier to name — an empty string, or a generic
    /// "subscription" with nothing after it.
    static func display(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let key = trimmed.lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        if key == "subscription" { return nil }
        if let named = names[key] { return named }

        for (slug, name) in names where key.hasSuffix("_\(slug)") || key.hasPrefix("\(slug)_") {
            return name
        }

        return trimmed.split { $0 == "_" || $0 == "-" || $0.isWhitespace }
            .map { part in
                let word = String(part)
                if word.uppercased() == word { return word }
                return word.prefix(1).uppercased() + word.dropFirst().lowercased()
            }
            .joined(separator: " ")
    }

    private static let names: [String: String] = [
        "plus": "Plus",
        "pro": "Pro",
        "pro_plus": "Pro Plus",
        "prolite": "Pro Lite",
        "max": "Max",
        "max_5x": "Max 5x",
        "max5x": "Max 5x",
        "5x": "Max 5x",
        "max_20x": "Max 20x",
        "max20x": "Max 20x",
        "20x": "Max 20x",
        "team": "Team",
        "enterprise": "Enterprise",
        "business": "Business",
        "free": "Free",
        "lite": "Lite",
        "ultra": "Ultra",
        "go": "Go",
        "goat": "GOAT",
        "extra": "Extra",
        "extra_usage": "Extra",
        "supergrok": "SuperGrok",
        "super_grok": "SuperGrok",
        "premium": "Premium",
        "premium_plus": "Premium+",
        "premiumplus": "Premium+",
        "edu": "Education",
        "education": "Education",
        "student": "Student",
        "hobby": "Hobby",
        "individual": "Individual",
        "pro_plan": "Pro",
        "max_plan": "Max",
    ]
}
