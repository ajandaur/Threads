import SwiftUI

/// The single source of truth for the Thread color system.
///
/// Dark mode only — these values are absolute, not adaptive, and there is no
/// light-mode variant. Color is semantic here, never decorative: do not
/// introduce colors outside this set, and **never reassign the node-type
/// colors**. A reader identifies a node by its color, so the color *is* the
/// node type. See `.claude/rules/ui.md`.
enum Palette {

    // MARK: - Surfaces

    /// App background.
    static let background = Color(hex: 0x0F0F0F)
    /// Cards and sheets.
    static let surface = Color(hex: 0x1A1A1A)
    /// Raised surfaces above cards.
    static let elevated = Color(hex: 0x242424)

    // MARK: - Text

    /// Primary text — white at 90%.
    static let textPrimary = Color.white.opacity(0.9)
    /// Secondary text and metadata — white at 50%.
    static let textSecondary = Color.white.opacity(0.5)

    // MARK: - Accent

    /// Interactive elements, focus, and the primary action.
    static let accent = Color(hex: 0x4A9EFF)

    // MARK: - Node-type colors (load-bearing — never reassign or swap for system colors)

    /// Facts.
    static let fact = Color(hex: 0x4A9EFF)
    /// Decisions.
    static let decision = Color(hex: 0xFFB84D)
    /// Open questions.
    static let openQuestion = Color(hex: 0xFF6B6B)
    /// Action items.
    static let actionItem = Color(hex: 0x4ADE80)

    /// The load-bearing color for a node type.
    ///
    /// `reference` and `insight` carry no assigned semantic color, so they fall
    /// back to neutral secondary text rather than borrowing another type's
    /// meaning.
    static func color(for type: ContextNodeType) -> Color {
        switch type {
        case .fact: fact
        case .decision: decision
        case .openQuestion: openQuestion
        case .actionItem: actionItem
        case .reference, .insight: textSecondary
        }
    }
}

// MARK: - Superseded treatment

extension View {
    /// Superseded nodes render at 30% opacity with a strikethrough rule.
    /// See `.claude/rules/ui.md`.
    func superseded(_ isSuperseded: Bool = true) -> some View {
        strikethrough(isSuperseded)
            .opacity(isSuperseded ? 0.3 : 1)
    }
}

// MARK: - Hex initializer

extension Color {
    /// Creates an opaque sRGB color from a 24-bit RGB hex literal, e.g. `0x4A9EFF`.
    init(hex: UInt32) {
        let red = Double((hex >> 16) & 0xFF) / 255
        let green = Double((hex >> 8) & 0xFF) / 255
        let blue = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: 1)
    }
}
