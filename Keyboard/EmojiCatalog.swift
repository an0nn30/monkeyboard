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

/// A compact, exact-word lookup for the suggestion bar. It does not initialize
/// the picker catalog, retain all search tags, or load a language model.
struct EmojiPredictionIndex {
    struct Match: Equatable {
        let glyph: String
        let name: String
        let variants: [String]
    }
    private let entries: [Match]
    private let terms: [String: [Int]]

    static let shared: Self = {
        let version: Double
        if #available(iOS 26.4, *) { version = 17 }
        else if #available(iOS 18.4, *) { version = 16 }
        else { version = 15.1 }
        let source = Bundle.main.url(forResource: "emoji-en", withExtension: "tsv")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        return Self(source: source, maximumVersion: version)
    }()

    private static let ignored = Set("a an the and or but if then than is am are was were be been being do does did have has had can could will would should may might must i me my mine you your yours he him his she her hers it its we us our ours they them their this that these those there here to of in on at by for from with as so not no yes one all any some other more most less only also very just still now how what when where who why which".split(separator: " ").map(String.init))

    init(source: String, maximumVersion: Double) {
        var entries: [Match] = []
        var ranked: [String: [(id: Int, score: Int)]] = [:]
        var byGlyph: [String: Int] = [:]
        for line in source.split(separator: "\n") where !line.hasPrefix("#") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 6, let version = Double(fields[4]), version <= maximumVersion else { continue }
            let name = String(fields[2]), glyph = String(fields[1])
            let variants = fields[5].split(separator: " ").compactMap { item -> String? in
                let pair = item.split(separator: ":")
                guard pair.count == 2, let version = Double(pair[1]), version <= maximumVersion else { return nil }
                return String(pair[0])
            }
            let id = entries.count
            entries.append(Match(glyph: glyph, name: name, variants: variants))
            byGlyph[glyph] = id
            let lower = name.lowercased()
            let nameWords = Set(lower.split { !$0.isLetter }.map(String.init))
            let keywords = Set(fields[3].lowercased().split { !$0.isLetter }.map(String.init))
            for word in nameWords.union(keywords) where word.count >= 3 && !Self.ignored.contains(word) {
                let score = lower == word ? 100 : (nameWords.contains(word) ? 80 : 60)
                var choices = ranked[word] ?? []
                choices.append((id, score))
                choices.sort { $0.score == $1.score ? $0.id < $1.id : $0.score > $1.score }
                ranked[word] = Array(choices.prefix(2))
            }
        }
        var terms = ranked.mapValues { $0.map(\.id) }
        // Favor familiar conversational meanings over broad catalog tags.
        for (word, glyphs) in ["key": ["🔑", "🔐"], "love": ["❤️", "😍"],
                               "happy": ["😊", "😄"], "sad": ["😢", "😔"],
                               "thanks": ["🙏"], "wave": ["👋"], "hi": ["👋"], "ok": ["👌"]] {
            terms[word] = glyphs.compactMap { byGlyph[$0] }
        }
        self.entries = entries
        self.terms = terms
    }

    func matches(_ input: String) -> [Match] {
        let word = input.lowercased()
        guard (2...40).contains(word.count), word.allSatisfy(\.isLetter), !Self.ignored.contains(word) else { return [] }
        var forms = [word]
        if word.hasSuffix("s"), word.count > 3 { forms.append(String(word.dropLast())) }
        if word.hasSuffix("es"), word.count > 4 { forms.append(String(word.dropLast(2))) }
        if word.hasSuffix("ies"), word.count > 4 { forms.append(String(word.dropLast(3)) + "y") }
        var ids: [Int] = []
        for form in forms {
            for id in terms[form] ?? [] where !ids.contains(id) { ids.append(id) }
        }
        return ids.prefix(2).map { entries[$0] }
    }
}
