import Foundation

nonisolated enum DisplayProvider: String, CaseIterable, Sendable {
    case claude
    case codex
    case cursor
    case kimi
    case zai
    case xai

    /// Fixed provider order used for panel layout and refresh fallback.
    static let displayOrder: [DisplayProvider] = [.claude, .codex, .cursor, .kimi, .zai, .xai]
}
