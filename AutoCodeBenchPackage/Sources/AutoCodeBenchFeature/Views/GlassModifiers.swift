import SwiftUI

// MARK: - Liquid Glass (macOS 26+)

/// Standard glass card: apply after padding/layout. Use for section cards in sheets and dashboard.
extension View {
    /// Applies the regular interactive glass effect in a rounded rect. Use after layout and appearance modifiers.
    public func glassCard(cornerRadius: CGFloat = 12) -> some View {
        self.glassEffect(.regular.interactive(), in: .rect(cornerRadius: cornerRadius))
    }

    /// Non-interactive glass card for display-only surfaces (charts, stat blocks). Use after layout and appearance modifiers.
    public func glassCardStatic(cornerRadius: CGFloat = 12) -> some View {
        self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
    }
}
