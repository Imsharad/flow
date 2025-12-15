import Foundation

class TextFormatter {
    static func format(text: String, previousContext: String? = nil) -> String {
        guard !text.isEmpty else { return "" }

        var formatted = text

        // Auto-capitalization: Capitalize first letter
        let first = formatted.prefix(1).uppercased()
        let other = formatted.dropFirst()
        formatted = first + other

        // Add trailing space if needed (context aware usually)
        // For now, simple sentence case.

        return formatted
    }
}
