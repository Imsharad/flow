import Foundation

class TextFormatter {
    func format(text: String, context: String?) -> String {
        var formatted = text

        // Auto-capitalization: Sentence case
        // If context ends with '.', assume new sentence.
        if let context = context, context.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(".") {
            formatted = capitalizeFirstLetter(formatted)
        } else if context == nil {
            formatted = capitalizeFirstLetter(formatted)
        }

        // Basic punctuation (very naive implementation)
        // In a real app, this would be handled by an LLM or more sophisticated rules

        return formatted
    }

    private func capitalizeFirstLetter(_ string: String) -> String {
        return string.prefix(1).capitalized + string.dropFirst()
    }
}
