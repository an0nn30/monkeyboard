import Foundation

struct PickerEmoji {
    let glyph: String
    let name: String
    let group: Int
    let words: [String]
    let variants: [String]

    func label(for form: String) -> String {
        let tones = ["light", "medium-light", "medium", "medium-dark", "dark"]
        let modifiers = form.unicodeScalars.compactMap { scalar -> String? in
            guard (0x1F3FB...0x1F3FF).contains(scalar.value) else { return nil }
            return tones[Int(scalar.value - 0x1F3FB)] + " skin tone"
        }
        return ([name] + modifiers).joined(separator: ", ")
    }
}

struct EmojiCatalog {
    static let shared = EmojiCatalog()
    let entries: [PickerEmoji]
    let byGlyph: [String: PickerEmoji]

    private init() {
        let version: Double
        if #available(iOS 26.4, *) { version = 17 }
        else if #available(iOS 18.4, *) { version = 16 }
        else { version = 15.1 }
        let url = Bundle.main.url(forResource: "emoji-en", withExtension: "tsv")
        let source = url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        entries = source.split(separator: "\n").compactMap { line in
            guard !line.hasPrefix("#") else { return nil }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 6, let group = Int(fields[0]), let introduced = Double(fields[4]),
                  introduced <= version else { return nil }
            let variants = fields[5].split(separator: " ").compactMap { field -> String? in
                let pair = field.split(separator: ":")
                guard pair.count == 2, let added = Double(pair[1]), added <= version else { return nil }
                return String(pair[0])
            }
            let name = String(fields[2])
            let words = (name + " " + fields[3]).lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
            return PickerEmoji(glyph: String(fields[1]), name: name, group: group, words: words, variants: variants)
        }
        var index: [String: PickerEmoji] = [:]
        for entry in entries {
            index[entry.glyph] = entry
            for variant in entry.variants { index[variant] = entry }
        }
        byGlyph = index
    }

    func search(_ query: String) -> [PickerEmoji] {
        let phrase = query.lowercased().trimmingCharacters(in: .whitespaces)
        let terms = phrase.split(separator: " ")
        var exact: [PickerEmoji] = [], prefix: [PickerEmoji] = [], matches: [PickerEmoji] = []
        for entry in entries {
            let name = entry.name.lowercased()
            if name == phrase { exact.append(entry) }
            else if name.hasPrefix(phrase) { prefix.append(entry) }
            else if terms.allSatisfy({ term in entry.words.contains { $0.hasPrefix(term) } }) {
                matches.append(entry)
            }
        }
        return exact + prefix + matches
    }
}
