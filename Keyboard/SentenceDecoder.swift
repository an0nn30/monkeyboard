import Accelerate
import CoreML
import Foundation
import MonkeyBoardEngine

/// Native inference for the five-block causal decoder. Each instance is confined to the worker queue.
final class SentenceDecoder {
    struct Review {
        let typed: String
        let leading: String
        let alternatives: [String]
        var followingWordLimit: Int {
            typed.lowercased() == "leek" && alternatives.contains("leek") ? 5 : 3
        }

        var isGoesInflection: Bool { typed == "gos" }
    }

    private let model: MLModel
    private let words: [String]
    private let ids: [String: Int]
    private let displayIndex: [String: Int]
    private let display: [Int]
    private let reviewWeights: [Float]
    private let functionWords: Set<Int>
    private static let stateWidth = 384
    private static let wordPattern = try! NSRegularExpression(pattern: "[a-z]+(?:'[a-z]+)*")
    private static let window = 32

    init(resources: URL) throws {
        let config = MLModelConfiguration()
        config.computeUnits = .cpuOnly
        model = try MLModel(contentsOf: resources.appendingPathComponent("MonkeyDecoder.mlmodelc"), configuration: config)
        let vocab = try String(contentsOf: resources.appendingPathComponent("decoder-vocab.tsv"), encoding: .utf8)
        let rows = vocab.split(separator: "\n").map { $0.split(separator: "\t") }
        guard rows.count == 8192, rows.allSatisfy({ $0.count == 2 }) else { throw CocoaError(.fileReadCorruptFile) }
        words = rows.map { String($0[0]) }
        ids = Dictionary(uniqueKeysWithValues: words.enumerated().map { ($1, $0) })
        display = rows.indices.filter { rows[$0][1] == "1" }
        displayIndex = Dictionary(uniqueKeysWithValues: display.enumerated().map { (String(rows[$0.element][0]), $0.offset) })
        let functionTokens = ["a", "an", "the", "my", "our", "this", "that", "one", "another"]
        let vocabulary = ids
        functionWords = Set(functionTokens.compactMap { vocabulary[$0] })
        let data = try Data(contentsOf: resources.appendingPathComponent("leek-review.bin"))
        let count = 1 + 2 * Self.stateWidth + rows.count
        guard data.starts(with: Data("MBH1".utf8)), data.count == 4 + count * 4 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        reviewWeights = data.withUnsafeBytes { bytes in
            (0..<count).map { Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: 4 + $0 * 4, as: UInt32.self))) }
        }
    }

    private func tokens(_ text: String) -> [Int] {
        let sentence = String(text.suffix(4096)).components(separatedBy: CharacterSet(charactersIn: ".!?\n")).last ?? ""
        let normalized = sentence.lowercased().replacingOccurrences(of: "’", with: "'")
        let string = normalized as NSString
        let matches = Self.wordPattern.matches(in: normalized, range: NSRange(location: 0, length: string.length))
        return matches.map { ids[string.substring(with: $0.range)] ?? 0 }
    }

    private func predict(_ sequence: [Int], feature: String = "logits") throws -> MLMultiArray {
        let input = try MLMultiArray(shape: [1, 32], dataType: .int32)
        let ptr = input.dataPointer.bindMemory(to: Int32.self, capacity: Self.window)
        for i in 0..<Self.window { ptr[i] = i < sequence.count ? Int32(sequence[i]) : 0 }
        let features = try MLDictionaryFeatureProvider(dictionary: ["tokens": MLFeatureValue(multiArray: input)])
        let result = try model.prediction(from: features)
        let width = feature == "states" ? Self.stateWidth : words.count
        guard let output = result.featureValue(for: feature)?.multiArrayValue,
              output.dataType == .float16, output.shape.map(\.intValue) == [1, Self.window, width] else {
            throw CocoaError(.coderInvalidValue)
        }
        return output
    }

    private func logits(_ output: MLMultiArray, at position: Int) -> [Float] {
        let strides = output.strides
        let ptr = output.dataPointer.assumingMemoryBound(to: Float16.self) + position * strides[1].intValue
        let step = strides[2].intValue
        return (0..<words.count).map { Float(ptr[$0 * step]) }
    }

    func nextWords(before text: String) throws -> [String] {
        let prefix = tokens(text)
        guard !prefix.isEmpty else { return [] }
        let sequence = Array(([1] + prefix).suffix(Self.window))
        let output = try predict(sequence)
        let scores = logits(output, at: sequence.count - 1)
        let allowed = display.map { scores[$0] }
        let probabilities = vForce.exp(vDSP.add(-vDSP.maximum(allowed), allowed))
        var blended = vDSP.divide(probabilities, vDSP.sum(probabilities))
        var buffer = [CChar](repeating: 0, count: 2048)
        let context = String(text.suffix(160))
        if !context.utf8.contains(0), mb_phrase_evidence_v1(context, &buffer, 2048) > 0 {
            for row in String(cString: buffer).split(separator: "\n") {
                let entries = row.split(separator: " ")
                guard let first = entries.first, let length = Int(first) else { continue }
                let counts: [(Int, Float)] = entries.dropFirst().compactMap { entry in
                    let fields = entry.split(separator: ":")
                    guard fields.count == 2, let index = displayIndex[String(fields[0])],
                          let n = Float(fields[1]) else { return nil }
                    return (index, n)
                }
                let mass = counts.reduce(Float.zero) { $0 + $1.1 }
                guard mass > 0 else { continue }
                let order = abs(length)
                let specificity: Float = order == 1 ? 0.35 : (order == 2 ? 0.8 : 1)
                let sourceWeight: Float = length < 0 ? 0.38 : 0.8
                let weight = sourceWeight * specificity * mass / (mass + 5)
                blended = vDSP.multiply(1 - weight, blended)
                for (index, count) in counts { blended[index] += weight * count / mass }
            }
        }
        return blended.indices.sorted { blended[$0] > blended[$1] }.prefix(3).map {
            let word = words[display[$0]]
            return word == "i" || word.hasPrefix("i'") ? "I" + word.dropFirst() : word
        }
    }

    // These token substitutions match spelling_review.py. Several common fixture
    // names were outside the frozen decoder's original 8,192-word vocabulary.
    private static let reviewAliases = ["boiler": "heating", "heater": "heating", "tub": "basin",
        "bathtub": "basin", "hose": "pipe", "hoses": "pipe", "faucet": "tap", "pipes": "pipe",
        "sinks": "sink", "insurer": "insurance", "rainfall": "rain"]
    private static let fixtures: Set<String> = ["sink", "pipe", "tank", "drain", "toilet", "roof", "radiator",
        "shower", "ceiling", "basin", "engine", "tap", "heating", "valve", "attic", "cellar", "boat"]
    private static let foodCues: Set<String> = ["eat", "ate", "plant", "planted", "grow", "grew", "growing",
        "grown", "cook", "cooked", "cut", "cutting", "chop", "chopped", "raw", "fresh", "green",
        "wash", "washed", "washes", "washing", "rinse", "rinsed", "rinses", "rinsing", "buy", "bought",
        "picked", "drop", "dropped", "hid", "hide", "place", "placed", "put", "set", "store", "stored",
        "left", "slice", "sliced", "vegetable", "vegetables", "grocery", "groceries", "plastic", "wooden",
        "toy", "draw", "drew", "recipe", "chef", "soup", "salad", "stew", "produce", "fridge", "market",
        "roast", "roasted", "basket", "onion", "dinner", "lunch", "peeled", "boiled", "stuck"]
    private static let literalCues: Set<String> = ["word", "words", "spell", "spelling", "type", "typed",
        "answer", "code", "nickname", "name", "password", "label", "literal", "wrote", "crossword"]
    private static let reportCues: Set<String> = ["there", "there's", "have", "has", "had", "found", "find",
        "detected", "detect", "notice", "noticed", "spotted", "suspect", "suspects", "suspected", "reported",
        "report", "checked", "check", "traced", "investigate", "saw", "discovered", "mentioned",
        "photographed", "documented", "confirmed", "revealed", "about", "caught"]
    private static let repairs: Set<String> = ["fixed", "fix", "repair", "repaired", "patch", "patched", "seal", "plugged"]
    private static let proximity: Set<String> = ["near", "by", "beside"]
    private static let repairReports: Set<String> = ["maintenance", "plumber", "handyman", "mechanic", "reported",
        "detected", "inspect", "inspector", "check", "investigate", "traced"]
    private static let locationModifiers: Set<String> = ["a", "an", "the", "my", "your", "his", "her", "our", "their",
        "that", "this", "under", "above", "below", "beneath", "behind", "inside", "over", "by", "in", "near",
        "through", "around", "beside", "along", "from", "on", "at", "underneath", "right", "next", "to", "somewhere",
        "just", "kitchen", "bathroom", "water", "old", "basement"]

    private func reviewWords(_ text: String) -> [String] {
        let normalized = text.lowercased().replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "there's", with: "there is") as NSString
        return Self.wordPattern.matches(in: normalized as String, range: NSRange(location: 0, length: normalized.length)).map {
            let word = normalized.substring(with: $0.range)
            return Self.reviewAliases[word] ?? word
        }
    }

    /// Classify only after the continuation supplies evidence. Both senses use
    /// the same marker because the base model has no token for the vegetable.
    private func reviewsAsLeak(leading: String, following: String) throws -> Bool {
        let sentence = leading.components(separatedBy: CharacterSet(charactersIn: ".!?\n")).last ?? ""
        let words = reviewWords(sentence)
        let right = Array(reviewWords(following).prefix(5))
        let recent = Set(words.suffix(8))
        guard let last = right.last, let marker = ids["leak"],
              recent.isDisjoint(with: Self.literalCues),
              Self.foodCues.isDisjoint(with: words), Self.foodCues.isDisjoint(with: right) else { return false }

        let hasRepair = !recent.isDisjoint(with: Self.repairs)
        let fluid = words.last.map { ["gas", "oil", "coolant", "water"].contains($0) } == true
        let location = Self.fixtures.contains(last) && right.dropLast().allSatisfy(Self.locationModifiers.contains)
        let weather = ["rain", "storm"].contains(last) && right.contains(where: { ["after", "during", "following"].contains($0) })
        let claim = ["insurance", "claim"].contains(last) && right.first == "for"
        let report = !recent.isDisjoint(with: Self.reportCues) || words.allSatisfy { ["a", "an", "the", "another"].contains($0) }
        // Arbitrary proximity to a fixture can describe a deliberately placed vegetable.
        if let first = right.first, Self.proximity.contains(first),
           !hasRepair, !fluid, recent.isDisjoint(with: Self.repairReports) { return false }
        let evidence = (location || weather || claim) && (report || hasRepair || fluid)
        let specificCause = (hasRepair || fluid) && right.count >= 3
        guard evidence || specificCause else { return false }

        let leftIDs = Array(([1] + words.map { ids[$0] ?? 0 }).suffix(26))
        let rightIDs = right.map { ids[$0] ?? 0 }
        guard let lastID = rightIDs.last, lastID > 1 else { return false }
        func classifierScore(leftIDs: [Int]) throws -> Float {
            let sequence = leftIDs + [marker] + rightIDs
            let states = try predict(sequence, feature: "states")
            let rowStride = states.strides[1].intValue, colStride = states.strides[2].intValue
            let data = states.dataPointer.assumingMemoryBound(to: Float16.self)
            var positions = Array(leftIDs.indices.filter { leftIDs[$0] > 1 && !functionWords.contains(leftIDs[$0]) }.suffix(6))
            if positions.isEmpty { positions = [0] }
            let width = Self.stateWidth
            var score = reviewWeights[0] + reviewWeights[1 + 2 * width + lastID]
            for j in 0..<width {
                var mean: Float = 0
                for p in positions { mean += Float(data[p * rowStride + j * colStride]) }
                score += mean / Float(positions.count) * reviewWeights[1 + j]
                score += Float(data[(sequence.count - 1) * rowStride + j * colStride]) * reviewWeights[1 + width + j]
            }
            return score
        }
        let score = try classifierScore(leftIDs: leftIDs)
        if score >= 2 { return true }
        // A person's name can dominate the pooled states in a short report.
        // For a fixture in an otherwise credible location, require corroboration
        // from the same trained head with the identity of the reporter removed.
        guard score >= -1, location, report else { return false }
        return try classifierScore(leftIDs: [1] + ["there", "is", "a"].compactMap { ids[$0] }) >= 2
    }

    /// Compare the joint likelihood of each spelling and the words actually typed after it.
    func revision(_ review: Review, committed: String, following: String) throws -> String? {
        if review.typed == "us", committed == "us", review.alternatives == ["us", "is"] {
            let words = following.lowercased().split(whereSeparator: { $0.isWhitespace })
            guard words.count >= 2, ["a", "an"].contains(words[0]), words[1].allSatisfy(\.isLetter),
                  let predicate = ids["is"], let literal = ids["us"], let article = ids[String(words[0])]
            else { return nil }
            let left = Array(([1] + tokens(review.leading)).suffix(Self.window - 1))
            let prior = logits(try predict(left), at: left.count - 1)
            // Compare P(is, article | subject) with P(us, article | subject).
            // The second continuation word confirms the noun phrase is underway;
            // it needn't be in the decoder vocabulary (e.g. a job title).
            func articleLogP(_ preceding: Int) throws -> Float {
                let row = logits(try predict(left + [preceding]), at: left.count)
                let peak = vDSP.maximum(row)
                return row[article] - peak - log(vDSP.sum(vForce.exp(vDSP.add(-peak, row))))
            }
            let margin = try prior[predicate] - prior[literal] + articleLogP(predicate) - articleLogP(literal)
            return margin >= 3.5 ? "is" : nil
        }
        if review.alternatives.count == 1, let split = review.alternatives.first, split.contains(" "),
           split.replacingOccurrences(of: " ", with: "") == review.typed.lowercased(), committed == review.typed {
            let pieces = split.split(separator: " ")
            guard pieces.count == 2, let first = following.lowercased().split(whereSeparator: { $0.isWhitespace }).first,
                  first.allSatisfy({ $0.isASCII && $0.isLetter }), mb_pair_support_v1(String(pieces[1]), String(first)) >= 4
            else { return nil }
            return review.typed.first?.isUppercase == true ? split.prefix(1).uppercased() + split.dropFirst() : split
        }
        if review.typed == "amanor", committed == review.typed, review.alternatives.contains("another") {
            // The literal is out of vocabulary; its <unk> probability is not
            // evidence for replacing it. Require a compatible noun on the right
            // in addition to the copula frame admitted by WordCorrections.
            let nouns: Set<String> = ["test", "trial", "attempt", "round", "run", "example",
                                      "question", "issue", "problem", "option", "chance", "reason"]
            return following.lowercased().split(whereSeparator: { $0.isWhitespace }).first
                .map { nouns.contains(String($0)) } == true ? "another" : nil
        }
        if review.typed.lowercased() == "leek", committed == review.typed, review.alternatives.contains("leek") {
            guard try reviewsAsLeak(leading: review.leading, following: following) else { return nil }
            return review.typed.first?.isUppercase == true ? "Leak" : "leak"
        }
        if review.typed.lowercased() == "lets", review.alternatives.contains("let's") {
            // At a sentence opening "let's" takes a bare verb. Preserve quoted
            // labels and other literal uses unless the next word supports it.
            let verbs: Set<String> = ["try", "see", "check", "go", "get", "make", "wait", "take", "meet",
                                      "order", "talk", "ask", "send", "call", "start", "stop", "keep",
                                      "look", "leave", "finish", "find", "grab", "use", "bring", "do",
                                      "move", "play", "watch", "eat", "give", "plan", "put", "head"]
            guard let first = following.lowercased().split(separator: " ").first,
                  verbs.contains(String(first)) else { return nil }
            return review.typed.first?.isUppercase == true ? "Let's" : "let's"
        }
        if review.alternatives.contains("we've"), review.typed.lowercased() == "were" {
            let participles: Set<String> = ["got", "done", "heard", "seen", "made", "learned", "lost",
                                            "found", "bought", "spent", "said", "tried", "missed"]
            guard let first = following.lowercased().split(separator: " ").first,
                  participles.contains(String(first)) else { return nil }
        }
        let right = Array(tokens(following).prefix(3))
        guard !right.isEmpty, right[0] != 0 else { return nil }
        let left = Array(([1] + tokens(review.leading)).suffix(Self.window - right.count))
        let leftScores = logits(try predict(left), at: left.count - 1)
        let literal = review.typed.lowercased()
        let incumbent = committed.lowercased()
        // The training loss ignored <unk>. Never replace an explicitly committed
        // out-of-vocabulary spelling based on its arbitrary unknown-token score.
        guard incumbent == literal || ids[incumbent] != nil else { return nil }
        var pool = review.alternatives.filter { ids[$0] != nil }
        if incumbent != literal, !pool.contains(incumbent) { pool.append(incumbent) }
        guard !pool.isEmpty else { return nil }
        func prior(_ word: String) -> Float {
            // A common missing e in the third-person inflection. WordCorrections
            // admits this accepted spelling only in a singular subject position.
            if review.isGoesInflection, word == "goes" { return 5.5 }
            return word == incumbent && word != literal ? 2 : 0
        }
        // Abstain on broad candidate pools. Omitting contenders would inflate confidence.
        guard pool.count <= 8 else { return nil }
        func continuation(after id: Int) throws -> Float {
            let output = try predict(left + [id] + right.dropLast())
            var evidence: Float = 0
            for (offset, token) in right.enumerated() where token != 0 {
                let row = logits(output, at: left.count + offset)
                let peak = vDSP.maximum(row)
                evidence += row[token] - peak - log(vDSP.sum(vForce.exp(vDSP.add(-peak, row))))
            }
            return evidence
        }
        var scores: [(word: String, score: Float, continuation: Float)] = []
        for word in pool {
            guard let id = ids[word] else { continue }
            let evidence = try continuation(after: id)
            scores.append((word, leftScores[id] + prior(word) + evidence, evidence))
        }
        scores.sort { $0.score > $1.score }
        guard let best = scores.first, best.word != incumbent,
              best.score - (scores.dropFirst().first?.score ?? -.infinity) >= 2.3 else { return nil }
        if review.isGoesInflection {
            guard best.word == "goes" else { return nil }
        } else {
            // Require odds for the observed continuation to support changing the word.
            // For an uncleared typo compare against replay with the literal's token.
            let reference: Float
            if let current = scores.first(where: { $0.word == incumbent }) {
                reference = current.continuation
            } else {
                reference = try continuation(after: ids[literal] ?? 0)
            }
            guard best.continuation - reference >= 1.5, leftScores[ids[best.word]!] >= 2 else { return nil }
        }
        return review.typed.first?.isUppercase == true ? best.word.prefix(1).uppercased() + best.word.dropFirst() : best.word
    }
}

/// Canceled work never delivers its result. Loading and prediction happen off the typing thread.
final class DecoderWorker {
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "MonkeyBoard sentence decoder"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()
    private var decoder: SentenceDecoder?
    @discardableResult
    func submit<T>(_ work: @escaping (SentenceDecoder) throws -> T, completion: @escaping (T) -> Void) -> Operation {
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak self, weak operation] in
            guard let self, let operation, !operation.isCancelled else { return }
            do {
                if decoder == nil, let url = Bundle.main.resourceURL { decoder = try SentenceDecoder(resources: url) }
                guard let decoder, !operation.isCancelled else { return }
                let result = try work(decoder)
                DispatchQueue.main.async { if !operation.isCancelled { completion(result) } }
            } catch {
                // Typing and the compact suggestions remain available.
                NSLog("MonkeyBoard decoder unavailable (%@ %ld)", (error as NSError).domain, (error as NSError).code)
            }
        }
        queue.addOperation(operation)
        return operation
    }
}
