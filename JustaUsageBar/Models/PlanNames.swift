import Foundation

/// Maps raw provider plan identifiers to the names providers use in their own
/// products. Unknown identifiers map to an empty string so internal codes such
/// as `prolite` never reach the panel.
nonisolated enum PlanNames {
    /// ChatGPT `plan_type` values, labeled as the Codex CLI labels them.
    static func codex(_ raw: String?) -> String {
        switch raw?.lowercased() {
        case "free": "Free"
        case "go": "Go"
        case "plus": "Plus"
        case "pro": "Pro 200"
        case "prolite": "Pro 100"
        case "promax": "Pro 500"
        case "team", "self_serve_business_usage_based": "Business"
        case "self_serve_business_prolite": "Business Premium"
        case "business", "enterprise", "hc", "ent26",
             "enterprise_cbp_automation", "enterprise_cbp_usage_based": "Enterprise"
        case "edu", "education": "Edu"
        case "edu_plus": "Edu Plus"
        case "edu_pro": "Edu Pro"
        default: ""
        }
    }

    /// Claude Code's `subscriptionType`, refined by `rateLimitTier` for Max.
    static func claude(subscriptionType: String?, rateLimitTier: String?) -> String {
        let tier = rateLimitTier?.lowercased() ?? ""
        switch subscriptionType?.lowercased() {
        case "pro": return "Pro"
        case "max":
            if tier.contains("20x") { return "Max 20x" }
            if tier.contains("5x") { return "Max 5x" }
            return "Max"
        case "team": return "Team"
        case "enterprise": return "Enterprise"
        default: return ""
        }
    }
}
