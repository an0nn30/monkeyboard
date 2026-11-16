import Foundation
import NaturalLanguage

/// Shared candidate search for the sentence ranker and local nonword repairs.
final class Lexical55 {
    private struct Entry {
        let frequency: Float  // Zipf scale
        let contextID: UInt16
        let flags: UInt8
        let peerOffset: Int
        var isTarget: Bool { flags & 1 != 0 }
        var casual: Bool { flags & 2 != 0 }
    }

    private enum Edit: Int, CaseIterable {
        case swap, moved, doubled, inserted, deleted, nearby, vowel, otherKey, homophone, split, twoEdits, twoSwaps, extraNeighbor, repeatedSwap
    }

    private struct Candidate {
        let text: String
        let first: Entry
        let second: Entry?
        let edit: Edit
    }

    // Global coefficients apply equally to all words. An exact transposition
    // preserves the complete inventory of letters, unlike an arbitrary substitution.
    private static let priors: [Float] = [3.7, 2.35, 3.2, 0.85, 0.35, 2.75, 1.2, -0.35, -0.8, 2.5, -2.6, 1.55, 1.45, 1.65]
    private static let contractions = ["'s", "'re", "'ve", "'ll", "'d", "'m", "n't"]
    private static let vowels = Set("aeiou".utf8)
    private static let alphabet = Array("abcdefghijklmnopqrstuvwxyz'".utf8)
    private final class Pool {
        let values: [Candidate]
        init(_ values: [Candidate]) { self.values = values }
    }
    private let cache = NSCache<NSString, Pool>()
    private let entryCount: Int
    private let pairCount: Int
    private let pairOffset: Int
    private let peerStart: Int
    private let sounds: [String: [String]]
    private let affixes: [UInt16: [String]]
    private let contexts: Data
    private static let adjacent: Set<UInt16> = {
        var coords: [UInt8: (Double, Double)] = [:]
        for (i, row) in ["qwertyuiop", "asdfghjkl", "zxcvbnm"].enumerated() {
            for (j, c) in row.utf8.enumerated() { coords[c] = (Double(j) + [0, 0.25, 0.75][i], Double(i)) }
        }
        var pairs = Set<UInt16>()
        for (a, p) in coords {
            for (b, q) in coords where a != b && pow(p.0 - q.0, 2) + pow(p.1 - q.1, 2) <= 2.1 {
                pairs.insert(UInt16(a) << 8 | UInt16(b))
            }
        }
        return pairs
    }()

    init?(resources: URL) {
        guard let file = try? String(contentsOf: resources.appendingPathComponent("lexical55.tsv"), encoding: .utf8),
              let data = try? Data(contentsOf: resources.appendingPathComponent("lexical55-context.bin"), options: .mappedIfSafe),
              data.count >= 16, data.starts(with: "MBL2".utf8), let start = file.range(of: "\nLEX55\n") else { return nil }
        let (count, pairs, extra) = data.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            (Int(UInt32(littleEndian: p.loadUnaligned(fromByteOffset: 4, as: UInt32.self))),
             Int(UInt32(littleEndian: p.loadUnaligned(fromByteOffset: 8, as: UInt32.self))),
             Int(UInt32(littleEndian: p.loadUnaligned(fromByteOffset: 12, as: UInt32.self))))
        }
        guard count > 0, pairs > 0, 16 + count * 16 + pairs * 6 + extra == data.count else { return nil }
        var groups: [String: [String]] = [:], byAffix: [UInt16: [String]] = [:]
        for row in file[start.upperBound...].split(separator: "\n") {
            let fields = row.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 3 else { return nil }
            let word = String(fields[0])
            if !fields[2].isEmpty { groups[word] = fields[2].split(separator: ",").map(String.init) }
            if fields[1] == "1" {
                let bytes = Array(word.utf8)
                guard bytes.count >= 4 else { return nil }
                byAffix[Self.prefix(bytes), default: []].append(word)
                byAffix[Self.suffix(bytes), default: []].append(word)
            }
        }
        sounds = groups
        affixes = byAffix
        entryCount = count
        pairCount = pairs
        pairOffset = 16 + count * 16
        peerStart = pairOffset + pairs * 6
        contexts = data
        cache.countLimit = 192
    }

    private func entry(_ word: String) -> Entry? {
        var hash: UInt64 = 14695981039346656037
        for byte in word.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return contexts.withUnsafeBytes { (p: UnsafeRawBufferPointer) -> Entry? in
            var lo = 0, hi = entryCount
            while lo < hi {
                let mid = lo + (hi - lo) / 2, at = 16 + mid * 16
                let h = UInt64(littleEndian: p.loadUnaligned(fromByteOffset: at, as: UInt64.self))
                if h < hash { lo = mid + 1 } else if h > hash { hi = mid } else {
                    let f = UInt16(littleEndian: p.loadUnaligned(fromByteOffset: at + 8, as: UInt16.self))
                    let id = UInt16(littleEndian: p.loadUnaligned(fromByteOffset: at + 10, as: UInt16.self))
                    let peers = Int(p[at + 13]) | Int(p[at + 14]) << 8 | Int(p[at + 15]) << 16
                    return Entry(frequency: Float(f) / 100, contextID: id, flags: p[at + 12], peerOffset: peers)
                }
            }
            return nil
        }
    }

    private func peers(_ raw: String) -> [(String, Bool)] {
        guard let offset = entry(raw)?.peerOffset, offset > 0 else { return [] }
        return contexts.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            let start = peerStart + offset - 1
            guard start < p.count else { return [] }
            var values: [(String, Bool)] = [], i = start + 1
            for _ in 0..<Int(p[start]) {
                guard i < p.count else { return [] }
                let n = Int(p[i] & 0x7f), phonetic = p[i] & 0x80 != 0
                guard n > 0, i + 1 + n <= p.count else { return [] }
                let w = String(decoding: p[(i + 1)..<(i + 1 + n)], as: UTF8.self)
                values.append((w, phonetic))
                i += n + 1
            }
            return values
        }
    }

    func isPhoneticAlternative(_ source: String, _ candidate: String) -> Bool {
        let target = Self.normalized(candidate)
        return peers(Self.normalized(source)).contains { $0.1 && $0.0 == target }
    }

    /// A narrow set for the fast word-boundary check. Only rare lowercase
    /// spellings can nominate a much more common word from the same lexicon.
    func boundaryAlternatives(for token: String, left: String) -> [String] {
        guard (3...6).contains(token.utf8.count), token.utf8.allSatisfy({ (97...122).contains($0) }),
              let source = entry(token), source.frequency < 3.3, !source.casual else { return [] }
        let protected = isLiteralProtected(token)
        if protected {
            // A lowercase surname after an article can also be a missing
            // doubled letter. Names elsewhere and texting vocabulary stay literal.
            let clause = left.split(whereSeparator: { ".!?;:,\n".contains($0) }).last ?? ""
            let recent = clause.split(whereSeparator: \.isWhitespace).suffix(2)
            guard source.flags & 32 != 0, recent.contains(where: {
                ["the", "a", "my", "your", "our", "his", "her", "their"].contains($0.lowercased())
            }) else { return [] }
        }
        var pool = Set<String>()
        if !protected {
            for word in sounds[token] ?? [] where word.count == token.count {
                if zip(word, token).filter({ $0 != $1 }).count == 1 { pool.insert(word) }
            }
        }
        for i in token.indices {
            pool.insert(String(token[...i]) + token[i...])
        }
        return pool.filter { word in
            guard let target = entry(word) else { return false }
            return target.isTarget && target.frequency >= max(3.8, source.frequency + 1.1)
        }.sorted()
    }

    private static func prefix(_ bytes: [UInt8]) -> UInt16 { UInt16(bytes[0]) << 8 | UInt16(bytes[1]) }
    private static func suffix(_ bytes: [UInt8]) -> UInt16 { 0x8000 | UInt16(bytes[bytes.count - 2]) << 8 | UInt16(bytes.last!) }

    private static func normalized(_ token: String) -> String {
        token.lowercased().replacingOccurrences(of: "’", with: "'")
    }

    func isEstablished(_ token: String) -> Bool {
        guard let entry = entry(Self.normalized(token)) else { return false }
        return entry.frequency >= 2.70 || entry.casual || entry.flags & 20 != 0 || (entry.flags & 8 != 0 && entry.frequency >= 1.0)
    }

    func isLiteralProtected(_ token: String) -> Bool {
        let raw = Self.normalized(token)
        if let word = entry(raw) { return word.flags & 4 != 0 }
        guard !raw.utf8.allSatisfy({ $0 < 128 }) else { return false }
        let folded = raw.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX"))
        return entry(folded).map { $0.flags & 4 != 0 } ?? false
    }

    /// Evaluate homographs in their actual role. Title-casing a candidate is
    /// only a name probe; the original spelling is always preserved verbatim.
    func protects(_ token: String, left: String, right: String) -> Bool {
        if isLiteralProtected(token) { return true }
        let raw = Self.normalized(token)
        guard (2...24).contains(raw.utf8.count), !right.isEmpty || !left.isEmpty else { return false }
        let e = entry(raw)
        let proper = e.map { $0.flags & 32 != 0 } ?? false
        let title = token.first?.isUppercase == true
        guard (proper && (e?.frequency ?? 0) < 4.9) || (title && (e?.frequency ?? 0) < 2.7) else { return false }
        let before = left.split(whereSeparator: \.isWhitespace).suffix(4).map(String.init)
        let after = right.split(whereSeparator: \.isWhitespace).prefix(4).map(String.init)
        let surface = raw.prefix(1).uppercased() + raw.dropFirst()
        let words = before + [surface] + after
        let line = words.joined(separator: " ")
        let tagger = NLTagger(tagSchemes: [.nameTypeOrLexicalClass])
        tagger.string = line
        let pos = line.index(line.startIndex, offsetBy: before.reduce(0) { $0 + $1.count + 1 })
        if !title {
            // Counterfactual capitalization alone can reclassify a verb or
            // adjective as a proper name. The typed word must fill a noun slot.
            let lowerLine = (before + [raw] + after).joined(separator: " ")
            tagger.string = lowerLine
            let i = lowerLine.index(lowerLine.startIndex, offsetBy: line.distance(from: line.startIndex, to: pos))
            let original = tagger.tag(at: i, unit: .word, scheme: .nameTypeOrLexicalClass).0
            guard original == .noun || original == .personalName || original == .placeName else { return false }
            tagger.string = line
        }
        let tag = tagger.tag(at: pos, unit: .word, scheme: .nameTypeOrLexicalClass).0
        if tag == .personalName || (title && tag == .placeName) { return true }
        // A known given-name homograph between two verbs can be the object of
        // the first verb and the subject of the following infinitive.
        guard proper, tag == .noun, let previous = before.last, let next = after.first,
              !previous.isEmpty, !next.isEmpty else { return false }
        let prevPos = line.index(pos, offsetBy: -(previous.count + 1))
        let nextPos = line.index(pos, offsetBy: surface.count + 1)
        return tagger.tag(at: prevPos, unit: .word, scheme: .nameTypeOrLexicalClass).0 == .verb &&
            tagger.tag(at: nextPos, unit: .word, scheme: .nameTypeOrLexicalClass).0 == .verb
    }

    private func pair(_ a: UInt16, _ b: UInt16) -> Float {
        guard a != 0, b != 0 else { return 0 }
        let key = UInt32(a) << 16 | UInt32(b)
        return contexts.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Float in
            var low = 0, high = pairCount
            while low < high {
                let mid = low + (high - low) / 2, at = pairOffset + mid * 6
                let k = UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: at, as: UInt32.self))
                if k < key { low = mid + 1 } else if k > key { high = mid } else {
                    let n = UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: at + 4, as: UInt16.self))
                    return log1p(Float(n))
                }
            }
            return 0
        }
    }

    /// Restricted Damerau distance with a two-edit band. Used only for a small
    /// affix bucket when the direct-edit search has little support.
    private static func withinTwo(_ raw: [UInt8], _ word: [UInt8]) -> Bool {
        guard abs(raw.count - word.count) <= 2 else { return false }
        var old = Array(0...word.count), older = old, new = old
        for i in 1...raw.count {
            new[0] = i
            let lo = max(1, i - 2), hi = min(word.count, i + 2)
            if lo > 1 { new[lo - 1] = 3 }
            var best = 3
            for j in lo...hi {
                var v = min(old[j] + 1, new[j - 1] + 1, old[j - 1] + (raw[i - 1] == word[j - 1] ? 0 : 1))
                if i > 1, j > 1, raw[i - 1] == word[j - 2], raw[i - 2] == word[j - 1] { v = min(v, older[j - 2] + 1) }
                new[j] = v
                best = min(best, v)
            }
            if hi < word.count { new[hi + 1] = 3 }
            if best > 2 { return false }
            swap(&older, &old)
            swap(&old, &new)
        }
        return old[word.count] <= 2
    }

    private func options(_ raw: String) -> [Candidate] {
        let bytes = Array(raw.utf8), count = bytes.count
        guard (2...26).contains(count), bytes.allSatisfy({ (97...122).contains($0) || $0 == 39 }) else { return [] }
        if let cached = cache.object(forKey: raw as NSString) { return cached.values }
        var pool: [String: Candidate] = [:]
        func consider(_ word: String, _ edit: Edit) {
            guard word != raw, let entry = entry(word), entry.isTarget, entry.frequency >= 2.3 else { return }
            if let old = pool[word], Self.priors[old.edit.rawValue] >= Self.priors[edit.rawValue] { return }
            pool[word] = Candidate(text: word, first: entry, second: nil, edit: edit)
        }
        func text(_ bytes: [UInt8]) -> String { String(decoding: bytes, as: UTF8.self) }

        var buffer = bytes
        for i in bytes.indices {
            let c = bytes[i]
            buffer.remove(at: i)
            let duplicate = (i > 0 && bytes[i - 1] == c) || (i + 1 < count && bytes[i + 1] == c)
            let extraNeighbor = i == count - 1 && i > 0 && Self.adjacent.contains(UInt16(c) << 8 | UInt16(bytes[i - 1]))
            consider(text(buffer), duplicate ? .doubled : extraNeighbor ? .extraNeighbor : .deleted)
            if count >= 4 {
                for j in max(0, i - 3)...min(count - 1, i + 3) where abs(i - j) >= 2 {
                    buffer.insert(c, at: j)
                    consider(text(buffer), .moved)
                    buffer.remove(at: j)
                }
            }
            buffer.insert(c, at: i)
            if i + 1 < count, c != bytes[i + 1] {
                buffer.swapAt(i, i + 1)
                consider(text(buffer), .swap)
                buffer.swapAt(i, i + 1)
            }
            for letter in Self.alphabet where letter != c {
                buffer[i] = letter
                let neighbor = Self.adjacent.contains(UInt16(c) << 8 | UInt16(letter))
                let vowel = Self.vowels.contains(c) && Self.vowels.contains(letter)
                consider(text(buffer), neighbor ? .nearby : vowel ? .vowel : .otherKey)
            }
            buffer[i] = c
        }
        for i in 0...count {
            buffer.insert(0, at: i)
            for letter in Self.alphabet {
                buffer[i] = letter
                consider(text(buffer), .inserted)
            }
            buffer.remove(at: i)
        }
        // Two localized slips can preserve the complete set of intended keys.
        // Keep these candidates available even when an easier word is one edit away.
        if count >= 4 && !isEstablished(raw) {
            for i in 0..<(count - 1) {
                if bytes[i] == bytes[i + 1] {
                    buffer.remove(at: i)
                    for j in 0..<(buffer.count - 1) where buffer[j] != buffer[j + 1] {
                        buffer.swapAt(j, j + 1)
                        consider(text(buffer), .repeatedSwap)
                        buffer.swapAt(j, j + 1)
                    }
                    buffer.insert(bytes[i], at: i)
                } else if i + 3 < count {
                    buffer.swapAt(i, i + 1)
                    for j in (i + 2)..<(count - 1) where buffer[j] != buffer[j + 1] {
                        buffer.swapAt(j, j + 1)
                        consider(text(buffer), .twoSwaps)
                        buffer.swapAt(j, j + 1)
                    }
                    buffer.swapAt(i, i + 1)
                }
            }
        }
        for (word, _) in peers(raw) { consider(word, .homophone) }
        for word in sounds[raw, default: []] { consider(word, .homophone) }
        for suffix in Self.contractions {
            consider(raw + suffix, .homophone)
            if raw.hasSuffix(suffix), raw.count > suffix.count { consider(String(raw.dropLast(suffix.count)), .homophone) }
        }
        for i in 1..<count {
            let a = String(decoding: bytes[..<i], as: UTF8.self), b = String(decoding: bytes[i...], as: UTF8.self)
            guard let x = entry(a), let y = entry(b), x.isTarget, y.isTarget,
                  min(x.frequency, y.frequency) >= 2.3, (a.count > 1 || a == "a" || a == "i"),
                  (b.count > 1 || b == "a" || b == "i") else { continue }
            let word = a + " " + b
            pool[word] = Candidate(text: word, first: x, second: y, edit: .split)
        }
        let hasStrong = pool.values.contains { $0.edit == .swap || $0.edit == .doubled || $0.edit == .nearby || $0.edit == .moved }
        if count >= 5, !isEstablished(raw), !hasStrong {
            let possible = (affixes[Self.prefix(bytes)] ?? []) + (affixes[Self.suffix(bytes)] ?? [])
            for word in possible where pool[word] == nil && abs(count - word.utf8.count) <= 2 && Self.withinTwo(bytes, Array(word.utf8)) {
                consider(word, word.utf8.sorted() == bytes.sorted() ? .twoSwaps : .twoEdits)
            }
        }
        let values = Array(pool.values)
        cache.setObject(Pool(values), forKey: raw as NSString)
        return values
    }

    private func contextIDs(_ left: String, _ right: String) -> (UInt16, UInt16) {
        let separate: (Character) -> Bool = { !$0.isLetter && $0 != "'" && $0 != "’" }
        let a = left.split(whereSeparator: separate).last.map { Self.normalized(String($0)) }
        let b = right.split(whereSeparator: separate).first.map { Self.normalized(String($0)) }
        return (a.flatMap { entry($0)?.contextID } ?? 0, b.flatMap { entry($0)?.contextID } ?? 0)
    }

    private func score(_ item: Candidate, left: UInt16, right: UInt16) -> Float {
        let first = item.first, last = item.second ?? first
        let before = pair(left, first.contextID), after = pair(last.contextID, right)
        let ctx = 0.42 * (min(before, 4) + min(after, 4))
        if let second = item.second {
            let inner = pair(first.contextID, second.contextID)
            let short = item.text.split(separator: " ").contains { $0.count <= 2 }
            let shortPenalty: Float = short && min(first.frequency, second.frequency) < 4.8 && inner == 0 ? 2.9 : 0
            let shortSpanPenalty: Float = item.text.count <= 7 ? 1.1 : 0
            let unsupported: Float = inner == 0 && item.text.count <= 9 && max(first.frequency, second.frequency) < 5.75 ? 1.9 : 0
            return Self.priors[item.edit.rawValue] + min(first.frequency, second.frequency) * 0.8
                + max(first.frequency, second.frequency) * 0.4 + min(inner, 4) * 0.55 + ctx - shortPenalty - shortSpanPenalty - unsupported
        }
        return Self.priors[item.edit.rawValue] + first.frequency * 1.0 + ctx
    }

    private func ranked(_ raw: String, left: String, right: String) -> [(Candidate, Float)] {
        let (a, b) = contextIDs(left, right)
        let pool = options(raw)
        let letterSwap = pool.contains { $0.edit == .swap && $0.first.frequency >= 2.7 }
        return pool.map { item in
            let unsupportedSplit = letterSwap && item.second.map { pair(item.first.contextID, $0.contextID) == 0 } == true
            return (item, score(item, left: a, right: b) - (unsupportedSplit ? 2.15 : 0))
        }.sorted {
            $0.1 == $1.1 ? $0.0.text < $1.0.text : $0.1 > $1.1
        }
    }

    func isKeyboardSequence(_ source: String, _ candidate: String) -> Bool {
        let result = Self.normalized(candidate)
        return options(Self.normalized(source)).contains {
            $0.text == result && ($0.edit == .twoSwaps || $0.edit == .repeatedSwap)
        }
    }

    func rankedCandidates(for token: String, left: String, right: String, limit: Int = 32) -> [String] {
        guard limit > 0 else { return [] }
        return ranked(Self.normalized(token), left: left, right: right).prefix(limit).map { $0.0.text }
    }

    func candidates(for token: String, limit: Int = 32) -> [String] {
        rankedCandidates(for: token, left: "", right: "", limit: limit)
    }

    func repair(_ token: String, left: String, right: String) -> String? {
        let raw = Self.normalized(token)
        let caps = token.indices.filter { token[$0].isUppercase }
        let possibleBoundary = caps.count == 1 && caps[0] != token.startIndex
        let whole = entry(raw)
        let rareCompound = whole.map { $0.flags & 64 != 0 && $0.flags & 20 == 0 && $0.frequency < 1.95 } ?? false
        guard raw.utf8.count >= 3, !isEstablished(raw) || rareCompound,
              token == token.lowercased() || token == token.uppercased() ||
                (token.first?.isUppercase == true && token.dropFirst().allSatisfy({ !$0.isUppercase })) || possibleBoundary else { return nil }
        let ranked = ranked(raw, left: left, right: right)
        guard let (best, score) = ranked.first else { return nil }
        if rareCompound && isEstablished(raw) {
            guard best.edit == .split, min(best.first.frequency, best.second?.frequency ?? 0) >= 4,
                  raw.count >= 6, !left.isEmpty || !right.isEmpty else { return nil }
        }
        let threshold: Float
        switch best.edit {
        case .split: threshold = raw.utf8.count >= 6 ? 6.7 : 7.6
        case .swap, .doubled: threshold = raw.count >= 7 ? 5.9 : 6.5
        case .nearby: threshold = raw.count >= 5 && ranked.dropFirst().allSatisfy { $0.0.edit == .split } ? 5.35 : 6.1
        case .moved: threshold = 5.5
        case .deleted, .inserted, .extraNeighbor: threshold = 5.2
        case .twoEdits, .otherKey: threshold = 4.9
        case .twoSwaps, .repeatedSwap, .vowel: threshold = 5.1
        case .homophone: return nil
        }
        if raw.contains("'"), best.edit != .split { return nil }
        let singleton = ranked.count == 1 && best.first.frequency >= 2.75
        let margin = ranked.dropFirst().first.map { score - $0.1 } ?? 20
        guard score >= threshold || singleton, margin >= 0.18 else { return nil }
        if best.edit == .split, let i = best.text.firstIndex(of: " ") {
            let offset = best.text.distance(from: best.text.startIndex, to: i)
            let cut = token.index(token.startIndex, offsetBy: offset)
            if possibleBoundary && cut != caps[0] { return nil }
            return String(token[..<cut]) + " " + String(token[cut...])
        }
        if possibleBoundary { return nil }
        if token == token.uppercased() { return best.text.uppercased() }
        if token.first?.isUppercase == true { return best.text.prefix(1).uppercased() + best.text.dropFirst() }
        return best.text
    }
}
