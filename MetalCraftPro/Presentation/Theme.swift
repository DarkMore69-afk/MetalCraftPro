import SwiftUI

/// Quiet charcoal surfaces, fine borders and one workshop amber accent.
enum Theme {
    static let accent = Color(red: 1, green: 0.69, blue: 0.035)
    static let cardBackground = Color(white: 0.125)
    static let appBackground = Color(white: 0.075)
    static let fieldBackground = Color(white: 0.18)
    static func card(cornerRadius: CGFloat = 20) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(cardBackground)
            .overlay { RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.6) }
    }
}

enum DeFormat {
    static func number(_ value: Double, maxFractionDigits: Int = 2) -> String {
        guard value.isFinite else { return "–" }
        return value.formatted(.number.locale(Locale(identifier: "de_DE")).grouping(.never).precision(.fractionLength(0...maxFractionDigits)))
    }
    /// Deliberately does not accept grouping separators. Decimal comma and decimal point
    /// are accepted; formatting editable values never adds grouping separators.
    static func parse(_ text: String) -> Double? {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        guard let result = Double(normalized), result.isFinite else { return nil }
        return result
    }
}
