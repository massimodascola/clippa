import Foundation

/// Decides what kind of item a copied text is.
public enum Classifier {
    /// A hex color copied on its own. Same rule as Paste: six hex digits,
    /// with a leading # or at least one letter A-F, so a six-digit
    /// verification code like 235442 stays text.
    public static func hexColor(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasHash = trimmed.hasPrefix("#")
        let digits = hasHash ? String(trimmed.dropFirst()) : trimmed
        guard digits.count == 6,
              digits.allSatisfy({ $0.isHexDigit && $0.isASCII }) else { return nil }
        guard hasHash || digits.contains(where: { $0.isLetter }) else { return nil }
        return "#" + digits.uppercased()
    }

    /// A single web or mail link copied on its own.
    public static func link(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count < 4_096,
              !trimmed.contains(where: { $0.isWhitespace }) else { return nil }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else { return nil }
        switch scheme {
        case "http", "https":
            return url.host?.isEmpty == false ? url : nil
        case "mailto", "tel", "ftp", "sftp", "ssh":
            return url
        default:
            return nil
        }
    }

    /// Kind of a text-only copy.
    public static func kind(forText text: String) -> ItemKind {
        if hexColor(text) != nil { return .color }
        if link(text) != nil { return .link }
        return .text
    }

    /// RGB components (0...1) of a hex color string like "#1A2B3C".
    public static func rgb(_ hex: String) -> (red: Double, green: Double, blue: Double)? {
        guard let normalized = hexColor(hex) else { return nil }
        let value = Int(normalized.dropFirst(), radix: 16) ?? 0
        return (Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
    }
}
