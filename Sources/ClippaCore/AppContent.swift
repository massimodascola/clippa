import Foundation

/// Copies that belong to an app and only make sense pasted back into it,
/// like clips copied from a Final Cut Pro timeline. Clippa keeps every
/// format byte for byte, so pasting puts back exactly what the app wrote.
public enum AppContent {
    public static let finalCutPro = "com.apple.flexo.proFFPasteboardUTI"

    /// Formats that belong to a known app, with the app's name. A copy that
    /// has one of them is that app's content, even if text comes with it.
    public static let knownTypes: [String: String] = [finalCutPro: "Final Cut Pro"]

    /// The name of the known app whose format is in the copy, if any.
    public static func knownApp(in types: [String]) -> String? {
        types.lazy.compactMap { knownTypes[$0] }.first
    }

    /// Text for the card and the search: the app's name on the first line,
    /// then the names found in the data (the clips, for Final Cut Pro).
    public static func describe(types: [String], data: (String) -> Data?, appName: String?) -> String {
        let name = knownApp(in: types) ?? appName ?? types.first ?? ""
        var names: [String] = []
        if types.contains(finalCutPro), let content = data(finalCutPro) {
            names = clipNames(in: content)
        }
        return ([name] + names).joined(separator: "\n")
    }

    /// Names of the clips in Final Cut Pro's clipboard data. The format is
    /// not documented: it is a property list holding archived objects
    /// (NSKeyedArchiver), whose names are stored under "displayName".
    /// Best effort: the list is empty if the format is different.
    public static func clipNames(in data: Data, limit: Int = 20) -> [String] {
        var names: [String] = []
        var seen = Set<String>()

        func visit(_ value: Any, depth: Int) {
            guard depth < 8, names.count < limit else { return }
            switch value {
            case let data as Data:
                guard data.starts(with: Array("bplist".utf8)) || data.starts(with: Array("<?xml".utf8)),
                      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) else { return }
                visit(plist, depth: depth + 1)
            case let dictionary as [String: Any]:
                if let objects = dictionary["$objects"] as? [Any] {
                    collect(from: objects, depth: depth)
                } else {
                    for key in dictionary.keys.sorted() { visit(dictionary[key]!, depth: depth + 1) }
                }
            case let array as [Any]:
                for element in array { visit(element, depth: depth + 1) }
            default:
                break
            }
        }

        func collect(from objects: [Any], depth: Int) {
            for object in objects {
                guard let dictionary = object as? [String: Any] else {
                    // An archive inside the archive.
                    if object is Data { visit(object, depth: depth + 1) }
                    continue
                }
                guard let reference = dictionary["displayName"], let index = uidValue(reference),
                      index < objects.count, let name = objects[index] as? String else { continue }
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, trimmed != "$null", seen.insert(trimmed).inserted else { continue }
                names.append(trimmed)
                if names.count >= limit { return }
            }
        }

        if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) {
            visit(plist, depth: 0)
        }
        return names
    }

    /// The index held by an archive reference (a CFKeyedArchiverUID). It
    /// has no public accessor; its description reads "{value = 12}".
    static func uidValue(_ value: Any) -> Int? {
        let text = String(describing: value)
        guard text.contains("CFKeyedArchiverUID"), let range = text.range(of: "value = ") else { return nil }
        return Int(text[range.upperBound...].prefix { $0.isNumber })
    }
}
