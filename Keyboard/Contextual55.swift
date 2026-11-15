import Accelerate
import CoreML
import Foundation
import NaturalLanguage

/// A queue-confined, bidirectional masked-language model for completed messages.
final class Contextual55 {
    struct Edit {
        let range: NSRange
        let replacement: String
        let gain: Float
    }

    private struct Vocabulary: Decodable {
        let tokens: [String]
        let merges: [[String]]
        let words: [String: Int]
        let anchorWords: [String]?
        let acceptance: [Float]?
    }

    private struct Token {
        let text: String
        let range: NSRange
        let prefix: String
        let ids: [Int]
    }

    private struct Option {
        let text: String
        let ids: [Int]
        let distance: Int
        var phonetic = false
    }

    private struct Site {
        let index: Int
        let options: [Option]
        let raw: String?
    }

    private struct State {
        let values: [Float]
        let mass: Float
        let corruption: Float
        let top: [String]
    }

    private static let width = 768
    private static let batch = 4
    private static let window = 32
    private static let mask = 50264
    private static let surface = try! NSRegularExpression(
        pattern: #"[\p{L}\p{M}]+(?:['’][\p{L}\p{M}]+)*|\p{N}+|[^\s\p{L}\p{M}\p{N}]+"#)
    private static let pieces = try! NSRegularExpression(
        pattern: #"'s|'t|'re|'ve|'m|'ll|'d| ?\p{L}+| ?\p{N}+| ?[^\s\p{L}\p{N}]+|\s+(?!\S)|\s+"#)

    private let model: MLModel
    private let embeddings: Data
    private let dimension: Int
    private let words: [String: Int]
    private let anchorWords: [String]
    private let acceptance: [Float]
    private let merges: [UInt64: (rank: Int, result: Int)]
    private let bytes: [Int]
    private var encoded: [String: [Int]] = [:]
    private let tagger = NLTagger(tagSchemes: [.lexicalClass])

    init?(resources: URL) {
        let configuration = MLModelConfiguration()
        #if targetEnvironment(simulator)
        // The Core ML simulator GPU returns +infinity for some FP16
        // normalizers; the CPU gives finite scores on the same compiled graph.
        configuration.computeUnits = .cpuOnly
        #else
        configuration.computeUnits = .all
        #endif
        guard let model = try? MLModel(contentsOf: resources.appendingPathComponent("MBMaskedEncoder.mlmodelc"),
                                       configuration: configuration),
              model.modelDescription.outputDescriptionsByName["corruption"] != nil,
              let file = try? Data(contentsOf: resources.appendingPathComponent("contextual55-vocab.txt")),
              let vocab = try? JSONDecoder().decode(Vocabulary.self, from: file),
              let embeddings = try? Data(contentsOf: resources.appendingPathComponent("contextual55-embeddings.bin"),
                                         options: .alwaysMapped),
              embeddings.count > 12, embeddings.starts(with: Data("MBCE".utf8)) else { return nil }
        let shape = embeddings.withUnsafeBytes {
            ($0.loadUnaligned(fromByteOffset: 4, as: UInt32.self).littleEndian,
             $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self).littleEndian)
        }
        let rows = Int(shape.0), width = Int(shape.1)
        guard rows == vocab.tokens.count, width == Self.width,
              embeddings.count == 12 + rows * (8 + width) else { return nil }

        let ids = Dictionary(uniqueKeysWithValues: vocab.tokens.enumerated().map { ($1, $0) })
        var ranks = [UInt64: (Int, Int)]()
        ranks.reserveCapacity(vocab.merges.count)
        for (rank, pair) in vocab.merges.enumerated() {
            guard pair.count == 2, let a = ids[pair[0]], let b = ids[pair[1]], let c = ids[pair[0] + pair[1]] else { return nil }
            ranks[Self.key(a, b)] = (rank, c)
        }
        let visible = Set(Array(33...126) + Array(161...172) + Array(174...255))
        var next = 256
        var byteIDs = [Int]()
        for byte in 0...255 {
            let scalar = visible.contains(byte) ? byte : next
            if !visible.contains(byte) { next += 1 }
            guard let scalar = UnicodeScalar(scalar), let id = ids[String(scalar)] else { return nil }
            byteIDs.append(id)
        }
        self.model = model
        self.embeddings = embeddings
        self.dimension = rows
        self.anchorWords = vocab.anchorWords ?? []
        guard let acceptance = vocab.acceptance, acceptance.count == 15 else { return nil }
        self.acceptance = acceptance
        self.words = vocab.words
        self.merges = ranks
        self.bytes = byteIDs
    }

    private static func key(_ left: Int, _ right: Int) -> UInt64 {
        UInt64(left) << 32 | UInt64(right)
    }

    private func encode(_ text: String) -> [Int] {
        if let cached = encoded[text] { return cached }
        let input = text.replacingOccurrences(of: "’", with: "'") as NSString
        let ranges = Self.pieces.matches(in: input as String, range: NSRange(location: 0, length: input.length))
        var result = [Int]()
        for match in ranges {
            var parts = input.substring(with: match.range).utf8.map { bytes[Int($0)] }
            while parts.count > 1 {
                var best: (rank: Int, result: Int, left: Int, right: Int)?
                for i in 1..<parts.count {
                    let a = parts[i - 1], b = parts[i]
                    guard let pair = merges[Self.key(a, b)], pair.rank < (best?.rank ?? Int.max) else { continue }
                    best = (pair.rank, pair.result, a, b)
                }
                guard let best else { break }
                var i = 0, next = [Int]()
                while i < parts.count {
                    if i + 1 < parts.count, parts[i] == best.left, parts[i + 1] == best.right {
                        next.append(best.result)
                        i += 2
                    } else {
                        next.append(parts[i])
                        i += 1
                    }
                }
                parts = next
            }
            result += parts
        }
        if encoded.count >= 4096 { encoded.removeAll(keepingCapacity: true) }
        encoded[text] = result
        return result
    }

    private func tokenize(_ sentence: String) -> [Token] {
        let input = sentence as NSString
        let matches = Self.surface.matches(in: sentence, range: NSRange(location: 0, length: input.length))
        return matches.enumerated().map { i, match in
            let text = input.substring(with: match.range)
            let previousEnd = i == 0 ? 0 : NSMaxRange(matches[i - 1].range)
            let prefix = match.range.location > previousEnd ? " " : ""
            return Token(text: text, range: match.range, prefix: prefix, ids: encode(prefix + text))
        }
    }

    private static func distance(_ a: String, _ b: String) -> Int {
        let lhs = Array(a.utf8), rhs = Array(b.utf8)
        guard abs(lhs.count - rhs.count) <= 3 else { return 4 }
        var older = Array(0...rhs.count), old = older
        for (i, l) in lhs.enumerated() {
            var next = [i + 1]
            for (j, r) in rhs.enumerated() {
                var n = min(old[j + 1] + 1, next[j] + 1, old[j] + (l == r ? 0 : 1))
                if i > 0 && j > 0 && l == rhs[j - 1] && lhs[i - 1] == r {
                    n = min(n, older[j - 1] + 1)
                }
                next.append(n)
            }
            older = old
            old = next
        }
        return old[rhs.count]
    }

    private func options(for token: Token, first: Bool, raw: String?, phonetic: ((String, String) -> Bool)?, candidates: (String) -> [String]) -> [Option] {
        let source = token.text.replacingOccurrences(of: "’", with: "'")
        let lower = source.lowercased()
        guard (2...26).contains(lower.utf8.count),
              lower.utf8.allSatisfy({ (97...122).contains($0) || $0 == 39 }),
              source == lower || (first && source == source.capitalized) else { return [] }
        var alternatives = candidates(lower)
        guard !alternatives.isEmpty || raw != nil else { return [] }
        if let raw, raw.lowercased() != lower { alternatives += candidates(raw.lowercased()) }
        // Productive contractions can exceed a one-letter edit while retaining
        // the complete source. Limit them to attested English spellings.
        if lower.count <= 6 {
            for ending in ["'re", "'ve", "'d", "'ll", "'s", "n't", "'m"] {
                let word = lower + ending
                if words[word] != nil { alternatives.append(word) }
            }
        }
        var options = [Option(text: source, ids: token.ids, distance: 0)]
        for alternative in Set(alternatives).sorted() {
            let spelling = alternative.lowercased()
            guard spelling != lower, !spelling.contains(" "), words[spelling] != nil else { continue }
            let distance = min(Self.distance(lower, spelling), raw.map { Self.distance($0.lowercased(), spelling) } ?? 99)
            let soundsAlike = phonetic?(lower, spelling) ?? false
            guard distance <= 2 || soundsAlike || spelling.contains("'") || source.contains("'") else { continue }
            var display = source != lower ? spelling.prefix(1).uppercased() + spelling.dropFirst() : spelling
            if display == "i" || display.hasPrefix("i'") { display = "I" + display.dropFirst() }
            let pieces = encode(token.prefix + display)
            if !pieces.isEmpty { options.append(Option(text: display, ids: pieces, distance: distance, phonetic: soundsAlike)) }
        }
        return options
    }

    private func maskedSequence(before: [Int], after: [Int]) -> [Int] {
        let spare = Self.window - 3
        let left = min(before.count, max(spare / 2, spare - after.count))
        return [0] + before.suffix(left) + [Self.mask] + after.prefix(spare - left) + [2]
    }

    private func row(from data: UnsafeRawBufferPointer, id: Int, into floats: inout [Float]) -> Float {
        let scale = data.loadUnaligned(fromByteOffset: 12 + id * 4, as: Float.self)
        let start = 12 + dimension * 8 + id * Self.width
        let q = data.baseAddress!.advanced(by: start).assumingMemoryBound(to: Int8.self)
        vDSP_vflt8(q, 1, &floats, 1, vDSP_Length(Self.width))
        return scale
    }

    private func states(_ sequences: [[Int]], selected: [Range<Int>]? = nil) throws -> [State] {
        var output = [State]()
        for offset in stride(from: 0, to: sequences.count, by: Self.batch) {
            let chunk = Array(sequences[offset..<min(offset + Self.batch, sequences.count)])
            let vectors = try MLMultiArray(shape: [4, 32, 768], dataType: .float16)
            let tokens = try MLMultiArray(shape: [4, 32], dataType: .int32)
            let ids = tokens.dataPointer.assumingMemoryBound(to: Int32.self)
            let vec = vectors.dataPointer.assumingMemoryBound(to: Float16.self)
            ids.update(repeating: 1, count: Self.batch * Self.window)
            vec.update(repeating: 0, count: Self.batch * Self.window * Self.width)
            var converted = [Int: [Float16]]()
            embeddings.withUnsafeBytes { data in
                var floats = [Float](repeating: 0, count: Self.width)
                for (r, sequence) in chunk.enumerated() {
                    for (t, id) in sequence.enumerated() {
                        let index = r * Self.window + t
                        ids[index] = Int32(selected?[offset + r].contains(t) == true ? Self.mask : id)
                        if converted[id] == nil {
                            let scale = row(from: data, id: id, into: &floats)
                            converted[id] = floats.map { Float16($0 * scale) }
                        }
                        converted[id]!.withUnsafeBufferPointer { buffer in
                            (vec + index * Self.width).update(from: buffer.baseAddress!, count: Self.width)
                        }
                    }
                }
            }
            let input = try MLDictionaryFeatureProvider(dictionary: [
                "tokens": MLFeatureValue(multiArray: tokens), "vectors": MLFeatureValue(multiArray: vectors)])
            let prediction = try model.prediction(from: input)
            guard let context = prediction.featureValue(for: "context")?.multiArrayValue,
                  context.dataType == .float16 else { throw CocoaError(.coderReadCorrupt) }
            let verdict = prediction.featureValue(for: "corruption")?.multiArrayValue
            if selected != nil {
                for i in chunk.indices {
                    output.append(State(values: [], mass: 0, corruption: verdict?[i].floatValue ?? 0, top: []))
                }
                continue
            }
            let anchors = prediction.featureValue(for: "anchors")?.multiArrayValue
            let legacyMass = prediction.featureValue(for: "mass")?.multiArrayValue
            let ptr = context.dataPointer.assumingMemoryBound(to: Float16.self)
            for i in chunk.indices {
                let start = i * context.strides[0].intValue, step = context.strides[1].intValue
                let values = (0..<Self.width).map { Float(ptr[start + $0 * step]) }
                var top = [String]()
                let mass: Float
                if let anchors, anchors.dataType == .float16, anchors.shape.count == 2 {
                    let base = anchors.dataPointer.assumingMemoryBound(to: Float16.self) + i * anchors.strides[0].intValue
                    let stride = anchors.strides[1].intValue
                    let logits = (0..<anchors.shape[1].intValue).map { Float(base[$0 * stride]) }
                    let maximum = vDSP.maximum(logits)
                    mass = maximum + log(vDSP.sum(vForce.exp(vDSP.add(-maximum, logits))))
                    if logits.count == anchorWords.count {
                        let relevant = logits.indices.filter { logits[$0] > maximum - 7 }
                        top = relevant.sorted { logits[$0] > logits[$1] }.prefix(64).compactMap { index in
                            let piece = anchorWords[index]
                            return piece.first == "Ġ" ? String(piece.dropFirst()) : nil
                        }
                    }
                } else if let legacyMass {
                    mass = legacyMass[i].floatValue
                } else {
                    throw CocoaError(.coderReadCorrupt)
                }
                guard mass.isFinite else { throw CocoaError(.coderReadCorrupt) }
                output.append(State(values: values, mass: mass, corruption: 0, top: top))
            }
        }
        return output
    }

    private func probability(_ id: Int, given state: State) -> Float {
        embeddings.withUnsafeBytes { data in
            var floats = [Float](repeating: 0, count: Self.width)
            let scale = row(from: data, id: id, into: &floats)
            let bias = data.loadUnaligned(fromByteOffset: 12 + (dimension + id) * 4, as: Float.self)
            return vDSP.dot(floats, state.values) * scale + bias - state.mass
        }
    }

    private func filled(before: [Int], option: [Int], after: [Int]) -> ([Int], Range<Int>) {
        let spare = Self.window - 2 - option.count
        let left = min(before.count, max(spare / 2, spare - after.count))
        let ids = [0] + before.suffix(left) + option + after.prefix(spare - left) + [2]
        return (ids, (1 + left)..<(1 + left + option.count))
    }

    private struct Ranked {
        let option: Option
        var score: Float
        var corruption: Float = 0
    }

    private func rank(_ site: Site, given state: State, tokens: [Token], corruption: Float) throws -> [Ranked] {
        let original = site.options[0]
        let prior: (Option) -> Float = {
            let contraction = $0.text.contains("'") || original.text.contains("'")
            return (contraction || $0.phonetic ? 0.5 : 3.5) * Float(max(0, $0.distance - 1))
        }
        func evaluate(_ option: Option) -> Ranked {
            Ranked(option: option, score: probability(option.ids[0], given: state) - prior(option))
        }
        var source = evaluate(original)
        source.corruption = corruption
        var alternativesList = Array(site.options.dropFirst())
        let lower = original.text.lowercased()
        if lower.count >= 3 {
            var seen = Set(site.options.map { $0.text.lowercased() })
            for word in state.top where word == word.lowercased() && words[word] != nil && !seen.contains(word) {
                let distance = Self.distance(lower, word)
                guard distance <= (lower.count >= 4 ? 2 : 1) else { continue }
                let display = original.text != lower ? word.prefix(1).uppercased() + word.dropFirst() : word
                let ids = encode(tokens[site.index].prefix + display)
                guard !ids.isEmpty else { continue }
                alternativesList.append(Option(text: display, ids: ids, distance: distance))
                seen.insert(word)
            }
        }
        let options = alternativesList.map(evaluate).sorted { $0.score > $1.score }
        let single = options.filter { $0.option.ids.count == 1 }.prefix(4)
        let compound = options.filter { $0.option.ids.count > 1 && $0.option.ids.count <= 4 }.prefix(3)
        let bestScore = max(single.first?.score ?? -100, compound.first?.score ?? -100)
        let followsSource = compound.contains {
            $0.option.text.lowercased().hasPrefix(original.text.lowercased() + "'")
        }
        guard corruption > -2 || original.ids.count > 1 || source.score < -7 ||
                bestScore > source.score + 1.5 || followsSource else { return [] }
        var ranked = [source] + single + compound
        let left = tokens[..<site.index].flatMap(\.ids), right = tokens[(site.index + 1)...].flatMap(\.ids)
        var jobs = [[Int]](), work = [(Int, Int)]()
        for j in ranked.indices where ranked[j].option.ids.count > 1 {
            let ids = ranked[j].option.ids
            for k in ids.indices {
                jobs.append(maskedSequence(before: left + ids[..<k], after: Array(ids[(k + 1)...]) + right))
                work.append((j, ids[k]))
            }
        }
        var pieceScore = [Int: Float]()
        for ((j, piece), prediction) in zip(work, try states(jobs)) {
            pieceScore[j, default: 0] += probability(piece, given: prediction)
        }
        for (j, total) in pieceScore {
            let option = ranked[j].option
            // Conditioning on other pieces discloses part of the spelling.
            // Mix in the whole-word mask and a length penalty to compare it
            // with a one-piece alternative under a common score scale.
            let revealed = total / Float(option.ids.count)
            if j == 0 {
                ranked[j].score = max(ranked[j].score, 0.35 * ranked[j].score + 0.65 * revealed - 3.0)
            } else {
                ranked[j].score = 0.50 * (ranked[j].score + prior(option)) + 0.50 * revealed - 3.7 - prior(option)
            }
        }
        // A common inflectional suffix supplies additional evidence of the
        // intended grammatical form. The model can still override this prior.
        let suffixes = ["ing", "ed", "s"]
        for j in 1..<ranked.count {
            let candidate = ranked[j].option.text.lowercased()
            for suffix in suffixes where lower.count >= suffix.count + 3 && candidate.count >= suffix.count + 3 {
                if lower.hasSuffix(suffix) != candidate.hasSuffix(suffix) { ranked[j].score -= 1.25; break }
            }
        }
        let filledRows = ranked.dropFirst().map { filled(before: left, option: $0.option.ids, after: right) }
        let assessed = try states(filledRows.map { $0.0 }, selected: filledRows.map { $0.1 })
        for j in assessed.indices {
            let value = assessed[j].corruption
            ranked[j + 1].corruption = value
            ranked[j + 1].score += 0.65 * max(-10, min(10, corruption - value))
        }
        let alternatives = ranked.dropFirst().sorted { $0.score > $1.score }
        guard let best = alternatives.first else { return [] }
        guard best.score > -15, best.score - ranked[0].score > 1 else { return [] }
        var finalists = [ranked[0]] + alternatives.prefix(3)
        let lead = best.score - (alternatives.dropFirst().first?.score ?? -100)
        if lead < 2.8 || best.score < -6.5 || best.score - ranked[0].score < 5.5 {
            let neighbors = tokens.indices.filter {
                $0 != site.index && tokens[$0].text.contains(where: { $0.isLetter })
            }.sorted { abs($0 - site.index) < abs($1 - site.index) }.prefix(4)
            var queries = [[Int]](), observed = [Int]()
            for proposal in finalists {
                var altered = tokens.map(\.ids)
                altered[site.index] = proposal.option.ids
                for n in neighbors {
                    queries.append(maskedSequence(before: altered[..<n].flatMap { $0 },
                                                  after: altered[(n + 1)...].flatMap { $0 }))
                    observed.append(altered[n][0])
                }
            }
            if !neighbors.isEmpty {
                let estimates = try states(queries)
                var sums = [Float](repeating: 0, count: finalists.count)
                for k in estimates.indices {
                    sums[k / neighbors.count] += probability(observed[k], given: estimates[k])
                }
                for j in 1..<finalists.count {
                    finalists[j].score += 0.45 * max(-8, min(8, sums[j] - sums[0]))
                }
            }
        }
        return [finalists[0]] + finalists.dropFirst().sorted { $0.score > $1.score }
    }

    // Open-class nouns often remain reasonable alternatives in the same slot.
    // A name or a different object can fit the grammar of a clean sentence.
    private func nouns(in sentence: String, at range: NSRange, replacement: String) -> Bool {
        func isNoun(_ text: String) -> Bool {
            tagger.string = text
            let start = String.Index(utf16Offset: range.location, in: text)
            return tagger.tag(at: start, unit: .word, scheme: .lexicalClass).0 == .noun
        }
        return isNoun(sentence) &&
            isNoun((sentence as NSString).replacingCharacters(in: range, with: replacement))
    }

    func edits(in sentence: String, original: ((NSRange) -> String?)? = nil, phonetic: ((String, String) -> Bool)? = nil, candidates: (String) -> [String]) -> [Edit] {
        guard !sentence.isEmpty, sentence.utf16.count <= 1024 else { return [] }
        let tokens = tokenize(sentence)
        guard tokens.count >= 3 else { return [] }
        let sites = tokens.indices.compactMap { i -> Site? in
            let raw = original?(tokens[i].range)
            let options = options(for: tokens[i], first: i == 0, raw: raw, phonetic: phonetic, candidates: candidates)
            return options.count >= 2 ? Site(index: i, options: options, raw: raw) : nil
        }
        let sequences = sites.map { site in
            maskedSequence(before: tokens[..<site.index].flatMap(\.ids),
                           after: tokens[(site.index + 1)...].flatMap(\.ids))
        }
        let sourceRows = sites.map { site in filled(before: tokens[..<site.index].flatMap(\.ids),
            option: site.options[0].ids, after: tokens[(site.index + 1)...].flatMap(\.ids)) }
        guard let predictions = try? states(sequences),
              let confidence = try? states(sourceRows.map { $0.0 }, selected: sourceRows.map { $0.1 }) else { return [] }
        var edits = [Edit]()
        for (index, site) in sites.enumerated() {
            guard let ranking = try? rank(site, given: predictions[index], tokens: tokens, corruption: confidence[index].corruption), ranking.count >= 2 else { continue }
            let best = ranking[1], gain = best.score - ranking[0].score
            let fromTypo = site.raw.map { raw in
                best.option.distance <= Self.distance(raw.lowercased(), site.options[0].text.lowercased())
            } ?? false
            let lead = best.score - (ranking.dropFirst(2).first?.score ?? -100)
            let token = tokens[site.index]
            let source = ranking[0], s = source.option.text.lowercased(), a = best.option.text.lowercased()
            let detectorAdjustment = max(-10, min(10, source.corruption - best.corruption)) * 0.65
            let sourceFrequency = Float(words[s] ?? 0) / 10, targetFrequency = Float(words[a] ?? 0) / 10
            let noun = nouns(in: sentence, at: token.range, replacement: best.option.text)
            // This feature order matches the fitted acceptance model from the
            // three released development cohorts. Each logit is bounded.
            let signals: [Float] = [
                max(-15, min(20, gain - detectorAdjustment)), max(-15, min(5, best.score - detectorAdjustment)),
                max(-12, min(12, source.corruption)), max(-12, min(12, best.corruption)),
                max(0, min(8, lead)), fromTypo ? 1 : 0, noun ? 1 : 0,
                max(-2, min(3, sourceFrequency - 4)), max(-3, min(3, targetFrequency - sourceFrequency)),
                Float(best.option.distance - 1), source.option.ids.count > 1 ? 1 : 0, best.option.ids.count > 1 ? 1 : 0,
                Float(abs(s.count - a.count)), min(s.count, a.count) <= 3 ? 1 : 0
            ]
            let logOdds = zip(acceptance.dropFirst(), signals).reduce(acceptance[0]) { $0 + $1.0 * $1.1 }
            guard logOdds > -0.55 else { continue }
            edits.append(Edit(range: token.range, replacement: best.option.text, gain: gain))
        }
        return edits
    }

    func correct(_ sentence: String, original: ((NSRange) -> String?)? = nil, phonetic: ((String, String) -> Bool)? = nil, candidates: (String) -> [String]) -> String {
        let result = NSMutableString(string: sentence)
        for edit in edits(in: sentence, original: original, phonetic: phonetic, candidates: candidates).reversed() {
            result.replaceCharacters(in: edit.range, with: edit.replacement)
        }
        return result as String
    }
}
