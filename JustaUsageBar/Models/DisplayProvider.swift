import Foundation

nonisolated enum DisplayProvider: String, CaseIterable, Sendable {
    case claude
    case codex
    case antigravity
    case cursor
    case kimi
    case zai
    case xai

    /// Fixed provider order used for panel layout and refresh fallback.
    static let displayOrder: [DisplayProvider] = [.claude, .codex, .antigravity, .cursor, .kimi, .zai, .xai]
}
