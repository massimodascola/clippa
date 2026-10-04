import Foundation

// Checks that every text shown by the app has an Italian translation.
// Usage: swift tools/check-strings.swift   (from the repository root)
// Exits with 1 and lists the missing keys if something is not translated.

let sources = "Sources/Clippa"
let pattern = try! NSRegularExpression(pattern: #"L\("((?:[^"\\]|\\.)*)""#)
var used = Set<String>()
for name in try! FileManager.default.contentsOfDirectory(atPath: sources) where name.hasSuffix(".swift") {
    let text = try! String(contentsOfFile: "\(sources)/\(name)", encoding: .utf8)
    for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
        let raw = String(text[Range(match.range(at: 1), in: text)!])
        used.insert(raw.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\\"", with: "\""))
    }
}

func keys(_ path: String) -> Set<String> {
    Set((NSDictionary(contentsOfFile: path) as? [String: Any])?.keys.map { $0 } ?? [])
}
let italian = keys("Resources/it.lproj/Localizable.strings").union(keys("Resources/it.lproj/Localizable.stringsdict"))
let missing = used.subtracting(italian).sorted()
let unused = italian.subtracting(used).sorted()

for key in unused { print("unused: \(key)") }
if missing.isEmpty {
    print("All \(used.count) texts are translated.")
} else {
    for key in missing { print("missing Italian: \(key)") }
    exit(1)
}
