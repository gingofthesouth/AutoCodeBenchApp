import SwiftUI

// MARK: - Chart annotation styling (hover callouts)

#if os(macOS)
import AppKit
#endif

extension Color {
    /// System-appropriate background for chart annotations (visible in light and dark mode).
    public static var chartAnnotationBackground: Color {
        #if os(macOS)
        return Color(nsColor: .controlBackgroundColor)
        #elseif os(iOS)
        return Color(uiColor: .secondarySystemBackground)
        #else
        return Color.secondary.opacity(0.95)
        #endif
    }
}

#if os(iOS)
import UIKit
#endif

/// Reusable container for chart annotation content: padding, background, corner radius.
public struct ChartAnnotationContainer<Content: View>: View {
    let content: Content
    var cornerRadius: CGFloat = 8

    public init(cornerRadius: CGFloat = 8, @ViewBuilder content: () -> Content) {
        self.cornerRadius = cornerRadius
        self.content = content()
    }

    public var body: some View {
        content
            .padding(12)
            .background(Color.chartAnnotationBackground)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}
