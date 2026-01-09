import Foundation

class Utils {
    static func formatText(_ text: String) -> String {
        // Capitalize first letter
        var formatted = text.prefix(1).uppercased() + text.dropFirst()

        // Add punctuation if missing
        if !formatted.hasSuffix(".") && !formatted.hasSuffix("?") && !formatted.hasSuffix("!") {
            formatted += "."
        }

        return formatted
    }
}
