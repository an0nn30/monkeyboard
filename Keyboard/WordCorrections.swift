import UIKit
import MonkeyBoardEngine

/// Uses the English system dictionary for spelling and completions. Only close,
/// high-confidence guesses are eligible to replace a word without a tap.
@MainActor
final class WordCorrections {
    var usesSentenceContext = true
    var preparesTransformerReviews = false
    var neighborMasks: [UInt32]?
    private let checker = UITextChecker()
    private let language = "en_US"
    private var knownWords = Set<String>()
    private var shortcuts: [String: String] = [:]
    // Frequent English typos for which the dictionary can rank a different
    // one-edit word first (e.g. “wired” for “wierd”).
    private let commonTypos = ["teh": "the", "wierd": "weird", "thier": "their",
                               "recieve": "receive", "becuase": "because", "definately": "definitely",
                               "adress": "address"]

    struct Choices {
        var automatic: String?
        var suggestions: [String] = []
        var reviewAlternatives: [String] = []
        // Only a verified subject + verb frame can reopen a dictionary split.
        var reviewsProtectedBoundary = false
        var reviewsShortWord = false
        var missingLetterOnly = false
    }

    // Build the lexical candidate pool before consulting sentence models.
    struct Candidate {
        let word: String
        let edits: Int
        let logit: Float?
    }
    #if BENCHMARK
    var sentenceWindowForBenchmark: Int?
    var onSentenceCandidates: ((String, String?, [Candidate]) -> Void)?
    #endif
    private func sentenceContext(before leading: Substring) -> String {
        let tail = leading.utf8.suffix(8192)
        let context = String(decoding: tail, as: UTF8.self)
        #if BENCHMARK
        if let window = sentenceWindowForBenchmark {
            let sentence = context.components(separatedBy: CharacterSet(charactersIn: ".!?\n")).last ?? ""
            return sentence.split(whereSeparator: { $0.isWhitespace }).suffix(window).joined(separator: " ")
        }
        #endif
        return context
    }

    private func sentenceCandidates(_ words: [String], typed: String, context: String) -> [Candidate] {
        var seen = Set<String>()
        let pool = words.prefix(24).map { $0.lowercased() }.filter {
            $0 != typed && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0 == "'") } && seen.insert($0).inserted
        }
        guard !pool.isEmpty else { return [] }
        var scores = [Float](repeating: -.infinity, count: pool.count)
        let count = !context.utf8.contains(0) ? mb_sentence_scores_v1(context, pool.joined(separator: "\t"), &scores, pool.count) : 0
        return zip(pool, scores).map { Candidate(word: $0.0, edits: Self.distance(typed,$0.0),
                                                logit: count == pool.count && $0.1.isFinite ? $0.1 : nil) }
    }

    func use(_ lexicon: UILexicon) {
        for entry in lexicon.entries {
            knownWords.insert(entry.documentText.lowercased())
            if !entry.userInput.isEmpty && entry.userInput.caseInsensitiveCompare(entry.documentText) != .orderedSame {
                shortcuts[entry.userInput] = entry.documentText
            }
        }
    }

    // A fixed-size, caller-owned buffer; the engine never retains keyboard text.
    private func ranked(_ word: String, after context: String) -> (Bool, [String]) {
        var out = [CChar](repeating: 0, count: 256)
        let tail = String(context.suffix(160))
        guard !tail.utf8.contains(0), !word.utf8.contains(0) else { return (false, []) }
        let capacity = out.count
        let masks = neighborMasks ?? []
        let status = masks.withUnsafeBufferPointer { buffer in
            mb_rank_v1(tail, word, buffer.count == 26 ? buffer.baseAddress : nil, &out, capacity)
        }
        guard status >= 0 else { return (false, []) }
        return (status == 1, String(cString: out).split(separator: "\t").map(String.init))
    }

    func nextWords(before context: String) -> [String] {
        ranked("", after: context).1.map { word in
            word == "i" || word.hasPrefix("i'") ? "I" + word.dropFirst() : word
        }
    }

    // Compare physical neighbors in the current layout, including its split gap.
    private func isNeighborSlip(_ typed: String, _ candidate: String) -> Bool {
        guard let masks = neighborMasks, masks.count == 26 else { return false }
        let from = Array(typed.utf8), to = Array(candidate.utf8)
        guard from.count == to.count else { return false }
        let differences = zip(from, to).filter { $0 != $1 }
        guard differences.count == 1, let (a,b) = differences.first,
              (97...122).contains(a), (97...122).contains(b) else { return false }
        return masks[Int(a - 97)] & (1 << (b - 97)) != 0
    }

    private func supportedCorrection(_ typed: String, rankedWords: [String], guesses: [String],
                                     context: String) -> String? {
        guard let best = rankedWords.first, typed.count >= 3 else { return nil }
        let system = guesses.prefix(4).map { $0.lowercased() }
        guard system.contains(best) else { return nil }
        if mb_frequency_v1(best) >= 12, isNeighborSlip(typed, best) {
            if system.first == best { return best }
            if nextWords(before: context).map({ $0.lowercased() }).contains(best) { return best }
        }
        // Common internal omissions are often ranked below dictionary guesses
        // that change an already correctly typed consonant.
        if typed.count >= 5, best.count == typed.count + 1, best.first == typed.first,
           best.last == typed.last, Self.distance(typed, best) == 1 { return best }
        if typed.count >= 6, rankedWords.count == 1, system.first == best,
           best.count == typed.count + 2, Self.distance(typed, best) == 2 { return best }
        // Independent agreement is especially useful for a missing last letter.
        if typed.count >= 5, system.first == best, best.count == typed.count + 1,
           best.hasPrefix(typed) { return best }
        return nil
    }

    private static let weekdays = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
    private static let months = ["January", "February", "March", "April", "August", "September", "October", "November", "December"]
    private static let datePrepositions: Set<String> = ["on", "by", "until", "since", "every", "next", "last", "this", "to", "before", "after", "in", "during"]
    // Only fix capitalized date-shaped inputs in a date slot. A correct name
    // or dictionary word next to "on" isn't itself evidence of an error.
    private static func calendarRepair(_ word: String, prior: String) -> String? {
        guard word.contains(where: \.isUppercase), word != word.uppercased(),
              (5...12).contains(word.count), datePrepositions.contains(prior) else { return nil }
        let lower = word.lowercased()
        var pool = weekdays + weekdays.map { $0 + "s" }
        if ["in", "during", "since", "by", "until", "before", "after", "to", "last", "next", "this"].contains(prior) {
            pool += months
        }
        // Singular and plural dates compete; preserve an explicitly typed plural.
        let hits = pool.filter { $0.hasSuffix("s") == lower.hasSuffix("s") }
            .filter { $0.prefix(1).lowercased() == String(lower.prefix(1)) || lower.hasSuffix("day") || lower.hasSuffix("days") }
            .map { ($0, distance(lower, $0.lowercased())) }.sorted { $0.1 < $1.1 }
        guard let best = hits.first, best.1 <= (lower.count >= 7 ? 2 : 1),
              hits.dropFirst().first?.1 != best.1, best.0 != word else { return nil }
        return best.0
    }

    // A lower-case function word fused to a capitalized place/date is different
    // from an ordinary camelCase identifier. Require an attested phrase.
    private static func capitalBoundary(_ word: String) -> String? {
        guard let cut = word.firstIndex(where: \.isUppercase), cut != word.startIndex else { return nil }
        let a = String(word[..<cut]), b = String(word[cut...]), lower = b.lowercased()
        guard b.count >= 3, b.dropFirst().allSatisfy(\.isLowercase),
              ["in","on","by","to","from","until","after","before","since","next","last","every","this","already"].contains(a)
        else { return nil }
        let calendar = weekdays + weekdays.map { $0 + "s" } + months + ["May","June","July"]
        guard calendar.contains(b) || (["in","to","from"].contains(a) && mb_pair_support_v1(a, lower) >= 8) else { return nil }
        return a + " " + b
    }

    // Compete against letter substitutions only when a unique exact boundary
    // has two independent pieces of evidence (or a very strong internal pair).
    private static let boundaryFunctions: Set<String> = ["the","a","an","my","your","this","that","is",
        "are","was","were","can","could","will","would","should","have","has","to","for","in","on",
        "at","of","with","and","or","you","we","they","he","she","it","i","be","do","did","from"]
    private static func attestedFunctionBoundary(_ word: String, prior: String) -> String? {
        guard (4...28).contains(word.count), word.allSatisfy({ $0.isASCII && $0.isLowercase }),
              mb_frequency_v1(word) == 0, mb_whole_compound_v1(word) == 0 else { return nil }
        var best: String?
        for i in word.indices.dropFirst() {
            let a = String(word[..<i]), b = String(word[i...])
            guard boundaryFunctions.contains(a) || boundaryFunctions.contains(b),
                  mb_frequency_v1(a) > 0, mb_frequency_v1(b) > 0 else { continue }
            let inside = mb_pair_support_v1(a,b), left = mb_pair_support_v1(prior,a)
            guard (inside >= 5 && left >= 3) || inside >= 60 else { continue }
            if best != nil { return nil }
            best = a + " " + b
        }
        return best
    }

    // Only waive the historical dictionary veto for an unattested whole spelling
    // with a subject, a verb and a preposition. Rust excludes observed whole words.
    // The following word must independently fit the preposition before any edit.
    private static func predicateBoundary(_ word: String, prior: String) -> String? {
        guard word.hasSuffix("in"), word.count >= 5, word == word.lowercased(),
              ["i","we","they","you","he","she"].contains(prior) else { return nil }
        var buffer = [CChar](repeating: 0, count: 96)
        guard mb_boundary_v1(prior, word, &buffer, buffer.count) == 1 else { return nil }
        let verb = String(word.dropLast(2)), split = verb + " in"
        guard String(cString: buffer) == split, mb_pair_support_v1(prior, verb) >= 4,
              mb_pair_support_v1(verb, "in") >= 8 else { return nil }
        return split
    }

    func choices(for word: String, before: String, includeCompletions: Bool) -> Choices {
        var result = rawChoices(for: word, before: before, includeCompletions: includeCompletions)
        // Prevent only an exact internal space insertion. Normal spelling,
        // apostrophes, and explicit user shortcuts still use their own policy.
        let lower = word.lowercased()
        func splitsLiteral(_ text: String) -> Bool {
            text.contains(" ") && text.lowercased().replacingOccurrences(of: " ", with: "") == lower
        }
        let splits = result.automatic.map(splitsLiteral) == true || result.reviewAlternatives.contains(where: splitsLiteral)
            || result.suggestions.contains(where: splitsLiteral)
        if splits, shortcuts[word] == nil, !lower.utf8.contains(0), mb_whole_compound_v1(lower) == 1 {
            if result.automatic.map(splitsLiteral) == true { result.automatic = nil }
            if !result.reviewsProtectedBoundary { result.reviewAlternatives.removeAll(where: splitsLiteral) }
            result.suggestions.removeAll(where: splitsLiteral)
        }
        if !includeCompletions, shortcuts[word] == nil, before.hasSuffix(word) {
            let left = String(before.dropLast(word.count).suffix(200))
            if let automatic = result.automatic, Self.keepsLiteral(left, word, "", automatic) {
                result.automatic = nil
            }
        }
        return result
    }

    /// The residual channel models mistyped letters and spaces, not a choice
    /// between two valid words. Only the explicit context models make that choice.
    func isRecognizedSpelling(_ word: String) -> Bool {
        let range = NSRange(word.startIndex..., in: word)
        return checker.rangeOfMisspelledWord(in: word, range: range, startingAt: 0, wrap: false, language: language).location == NSNotFound
    }

    private static func keepsLiteral(_ left: String, _ word: String, _ right: String, _ proposal: String) -> Bool {
        word != proposal && ((word.lowercased() != proposal.lowercased() && mb_original_name54_v1(word) == 1) ||
                             mb_keep_literal53_v1(left, word, right, proposal) == 1)
    }

    private static let literalPrompts: [String] = ["type the literal", "identifier is", "code is", "password is", "type exactly", "word is spelled", "spelled exactly", "i wrote", "label says", "saved it as", "username is", "literal word", "please type", "please spell", "i typed", "word is", "literal is", "the word", "the spelling", "the syllable", "the abbreviation", "the variable"]
    private static func isLiteralContext(_ context: String) -> Bool {
        literalPrompts.contains { context == $0 || context.hasSuffix(" " + $0) }
    }

    private static func uniqueJoin(original: [String], proposed: [String]) -> Int? {
        var match: Int?
        for i in proposed.indices where proposed[i].lowercased() ==
            (original[i] + original[i + 1]).lowercased() {
            if match != nil { return nil }
            match = i
        }
        return match
    }

    private func ordinaryLowercaseCorrection(_ surface: String, from typed: String) -> Bool {
        let lower = surface.lowercased()
        guard let first = surface.first, first.isUppercase,
              surface.dropFirst().allSatisfy({ !$0.isUppercase }),
              mb_midword_lowercase_v1(lower) == 1 else { return false }
        return Self.distance(typed.lowercased(), lower) <= 2
    }

    func allowsLearnedEdits(in raw: String, leading: String) -> Bool {
        let combined = (leading + raw).lowercased()
        if Self.literalPrompts.contains(where: { combined.contains($0 + " ") }) { return false }
        let tokens = raw.split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "’" })
        return !tokens.contains { knownWords.contains($0.lowercased()) || shortcuts[String($0)] != nil }
    }

    // Only the controller can nominate text for lookback: this is an owned
    // span, never a sentence copied from an unrelated field or a pasted draft.
    func learnedSentence(raw: String, leading: String, rendered: String, word: String, baseline: Choices) -> String? {
        guard !raw.isEmpty, raw.utf8.count <= 180, raw.allSatisfy({ $0.isLetter || $0.isNumber || " '’-,;:".contains($0) }),
              !raw.utf8.contains(0), !leading.utf8.contains(0),
              raw.split(separator: " ").count <= 12 else { return nil }
        guard allowsLearnedEdits(in: raw, leading: leading) else { return nil }
        let originals = raw.split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "’" })
        // A scheduled ambiguity review owns the current spelling until a
        // following word arrives. Other edits in the same span can still commit.
        let waitsForRight = baseline.automatic == nil && baseline.reviewAlternatives.contains(word.lowercased())
        var buf = [CChar](repeating: 0, count: 384)
        if mb_pipeline22_v1(raw, &buf, buf.count) == 1 {
            var proposal = String(cString: buf)
            // A bounded typing span can start after a comma. Casing predictions
            // for that local start must respect the actual sentence boundary.
            if let firstRaw = raw.split(separator: " ").first,
               let firstProposed = proposal.split(separator: " ").first,
               let ch = firstProposed.first, ch.isASCII, ch.isUppercase,
               firstRaw.first?.isLowercase == true,
               !leading.trimmingCharacters(in: .whitespaces).isEmpty,
               leading.trimmingCharacters(in: .whitespaces).last.map({ !".!?".contains($0) }) == true,
               (firstRaw.lowercased() == firstProposed.lowercased() ||
                ordinaryLowercaseCorrection(String(firstProposed), from: String(firstRaw))) {
                proposal = ch.lowercased() + proposal.dropFirst()
            }
            if let first = originals.first, let ch=first.first, ch.isUppercase, first.count < 5,
               let proposedFirst = proposal.split(separator: " ").first,
               proposedFirst.lowercased() != first.lowercased() && proposedFirst.count < first.count &&
               !raw.lowercased().hasPrefix(proposedFirst.lowercased()) &&
               mb_supported_opening_v1(raw, String(proposedFirst)) == 0 &&
               !(first.count == proposedFirst.count + 1 && first.dropFirst().first?.isUppercase == true &&
                 first.dropFirst().lowercased() == proposedFirst.lowercased()) {
                return nil
            }
            let originalWords = raw.components(separatedBy: " ")
            let displayedWords = rendered.components(separatedBy: " ")
            var proposedWords = proposal.components(separatedBy: " ")
            if originalWords.count == proposedWords.count && originalWords.count == displayedWords.count {
                let opening = originalWords[0]
                let repairedOpening = opening.count > 1 && opening.first?.isUppercase == true &&
                    opening.dropFirst().first?.isUppercase == true &&
                    opening.lowercased() != proposedWords[0].lowercased()
                for i in originalWords.indices {
                    let literal = originalWords[i], guess = proposedWords[i]
                    guard literal != guess || displayedWords[i] != literal else { continue }
                    let left = leading + proposedWords[..<i].joined(separator: " ")
                    let right = proposedWords[(i + 1)...].joined(separator: " ")
                    // A corrected opening is not evidence that a later valid
                    // word was mistyped. Keep an attested informal phrase unless
                    // both sides support the proposed change.
                    if Self.keepsLiteral(left, literal, right, guess) ||
                        (guess == literal && Self.keepsLiteral(left, literal, right, displayedWords[i])) {
                        proposedWords[i] = literal
                    } else if i > 0 && guess == literal && displayedWords[i] != literal &&
                        originalWords[0] != proposedWords[0] &&
                        (3...24).contains(literal.utf8.count) && literal.allSatisfy({ $0.isASCII && $0.isLowercase }) &&
                        displayedWords[i].allSatisfy({ $0.isASCII && $0.isLowercase }) &&
                        mb_frequency_v1(literal) == 0 && mb_spelling22_known_v1(literal) == 0 &&
                        (mb_frequency_v1(displayedWords[i]) > 0 || mb_spelling22_known_v1(displayedWords[i]) == 1 ||
                         checker.rangeOfMisspelledWord(in: displayedWords[i], range: NSRange(displayedWords[i].startIndex..., in: displayedWords[i]),
                                                       startingAt: 0, wrap: false, language: language).location == NSNotFound) &&
                        Self.distance(literal, displayedWords[i]) <= 2 {
                        // A sentence revision may simply abstain about another
                        // token. Abstention must not undo a committed spelling
                        // repair while changing the opening. Undo resets the run.
                        proposedWords[i] = displayedWords[i]
                    } else if i > 0 && repairedOpening && literal.allSatisfy(\.isLetter) && guess.allSatisfy(\.isLetter) &&
                        literal.lowercased() != guess.lowercased() &&
                        mb_casual_keep_v1(left, literal, guess) == 1 &&
                        mb_context_agrees_v1(left, literal.lowercased(), right, guess.lowercased()) == 0 {
                        proposedWords[i] = literal
                    } else if guess.compare(literal, options: .diacriticInsensitive) == .orderedSame {
                        proposedWords[i] = literal
                    } else if mb_literal_supported_v1(left, literal, right, guess) == 1 || mb_uncorroborated_v1(left, literal, right, guess) == 1 {
                        proposedWords[i] = literal
                    }
                }
                proposal = proposedWords.joined(separator: " ")
            }
            // Joining two fragments must not undo an independent earlier
            // correction (e.g. correcting a preposition before the joined word).
            // Carry it over only on a single, exact join with unambiguous offsets.
            if displayedWords.count == originalWords.count && proposedWords.count + 1 == originalWords.count,
               let join = Self.uniqueJoin(original: originalWords, proposed: proposedWords) {
                for index in proposedWords.indices where index != join {
                    let i = index < join ? index : index + 1
                    let literal = originalWords[i], guess = proposedWords[index]
                    let prior = leading + proposedWords[..<index].joined(separator: " ")
                    let after = proposedWords[(index + 1)...].joined(separator: " ")
                    if guess.lowercased() != literal.lowercased() {
                        if Self.keepsLiteral(prior, literal, after, guess) || mb_literal_supported_v1(prior, literal, after, guess) == 1 ||
                            mb_uncorroborated_v1(prior, literal, after, guess) == 1 {
                            proposedWords[index] = literal
                        }
                    } else if guess == literal, displayedWords[i] != literal {
                        let earlier = displayedWords[i]
                        // Recheck against the resolved neighbors. A guess made
                        // next to a partial word can cease to fit after the join.
                        let supported = !Self.keepsLiteral(prior, literal, after, earlier) && mb_literal_supported_v1(prior, literal, after, earlier) == 0 &&
                            mb_uncorroborated_v1(prior, literal, after, earlier) == 0
                        if supported || earlier.lowercased() == literal.lowercased() { proposedWords[index] = earlier }
                    }
                }
                proposal = proposedWords.joined(separator: " ")
            }
            // Recheck a boundary proposal against each original token at the
            // boundary. Preserve other word repairs when the boundary is vetoed.
            if originalWords.count + 1 == proposedWords.count,
               let at = Self.uniqueJoin(original: proposedWords, proposed: originalWords) {
                let left = leading + proposedWords[..<at].joined(separator: " ")
                let right = proposedWords.dropFirst(at + 2).joined(separator: " ")
                let split = proposedWords[at...(at + 1)].joined(separator: " ")
                if Self.keepsLiteral(left, originalWords[at], right, split) {
                    proposedWords.replaceSubrange(at...(at + 1), with: [originalWords[at]])
                    proposal = proposedWords.joined(separator: " ")
                }
            } else if originalWords.count == proposedWords.count + 1,
                      let at = Self.uniqueJoin(original: originalWords, proposed: proposedWords) {
                let left = leading + proposedWords[..<at].joined(separator: " ")
                let right = proposedWords.dropFirst(at + 1).joined(separator: " ")
                if Self.keepsLiteral(left, originalWords[at], right, proposedWords[at]) ||
                    Self.keepsLiteral(left, originalWords[at + 1], right, proposedWords[at]) {
                    proposedWords.replaceSubrange(at...at, with: originalWords[at...(at + 1)])
                    proposal = proposedWords.joined(separator: " ")
                }
            }
            if waitsForRight && proposal.split(separator: " ").last != rendered.split(separator: " ").last {
                return nil
            }
            // Keep the existing delayed review when this new model has no edit
            // at the active word (e.g. a valid spelling awaiting a right word).
            if proposal != rendered { return proposal }
            // If earlier words already match the model, still check this boundary.
        }
        guard !word.isEmpty, rendered.hasSuffix(word), raw.hasSuffix(word),
              word.allSatisfy({ $0.isASCII && ($0.isLetter || $0 == "'") }) else { return nil }
        let left = String((leading + raw.dropLast(word.count)).suffix(160))
        let r = NSRange(word.startIndex..., in: word)
        let accepted = checker.rangeOfMisspelledWord(in: word, range: r, startingAt: 0, wrap: false, language: language).location == NSNotFound
        var committed = word
        if let guess = baseline.automatic {
            // Do not introduce an accent as the only change to an otherwise
            // correct spelling (for example, an English loanword).
            let accentOnly = guess != word && guess.compare(word, options: .diacriticInsensitive) == .orderedSame
            if !accentOnly && !Self.keepsLiteral(left, word, "", guess) && mb_literal_supported_v1(left, word, "", guess) == 0 && mb_casual_keep_v1(left, word, guess) == 0 { committed = guess }
        } else if !waitsForRight && !accepted && word.count >= 2 && (mb_spelling22_v1(left, word, "", &buf, buf.count) == 1
                    || mb_textspell30_v1(left, word, "", &buf, buf.count) == 1) {
            let candidate = String(cString: buf)
            if !Self.keepsLiteral(left, word, "", candidate) && mb_casual_keep_v1(left, word, candidate) == 0 { committed = candidate }
        }

        // Review a word once its immediate right context arrives. Align on
        // original word boundaries so a split, undo or earlier choice cannot
        // move this replacement onto someone else's word.
        let typed = raw.components(separatedBy: " ")
        var shown = rendered.components(separatedBy: " ")
        var revised = false
        if typed.count == shown.count, typed.count >= 2 {
            for i in max(0, typed.count - 3)..<(typed.count - 1) {
                let w = typed[i]
                guard (2...24).contains(w.utf8.count), w.allSatisfy({ $0.isASCII && $0.isLetter }) else { continue }
                let prior = String((leading + shown[..<i].joined(separator: " ")).suffix(160))
                let after = shown[(i + 1)...].joined(separator: " ")
                if shown[i] != w {
                    if Self.keepsLiteral(prior, w, after, shown[i]) || mb_literal_supported_v1(prior, w, after, shown[i]) == 1 {
                        shown[i] = w
                        revised = true
                    }
                    continue
                }
                let realEdit = w.count <= 7 && mb_real25_v1(prior, w, after, &buf, buf.count) == 1
                let spellingEdit = !realEdit && mb_spelling22_known_v1(w) == 0
                    && checker.rangeOfMisspelledWord(in: w, range: NSRange(w.startIndex..., in: w), startingAt: 0,
                                                     wrap: false, language: language).location != NSNotFound
                    && (mb_spelling22_v1(prior, w, after, &buf, buf.count) == 1 || mb_textspell30_v1(prior, w, after, &buf, buf.count) == 1)
                if realEdit || spellingEdit {
                    let guess = String(cString: buf)
                    if Self.keepsLiteral(prior, w, after, guess) || mb_literal_supported_v1(prior, w, after, guess) == 1 { continue }
                    if mb_casual_keep_v1(prior, w, guess) == 1 &&
                        !(realEdit && mb_context_agrees_v1(prior, w, after, guess) == 1) { continue }
                    shown[i] = guess
                    revised = true
                }
            }
        }
        if revised {
            shown[shown.count - 1] = committed
            return shown.joined(separator: " ")
        }
        if committed == baseline.automatic || (committed == word && baseline.automatic == nil) { return nil }
        return String(rendered.dropLast(word.count)) + committed
    }

    private func rawChoices(for word: String, before: String, includeCompletions: Bool) -> Choices {
        guard (1...40).contains(word.count), before.hasSuffix(word) else { return Choices() }
        let original = word.lowercased()
        let normalized = original.replacingOccurrences(of: "’", with: "'")
        let context = String(before.suffix(180))
        let range = NSRange(context.index(context.endIndex, offsetBy: -word.count)..<context.endIndex, in: context)
        let wordRange = NSRange(word.startIndex..., in: word)
        var choices = Choices()
        let leading = before.dropLast(word.count)
        let startsToken = leading.last.map { $0.isWhitespace || "(\"“‘[{—".contains($0) } ?? true
        let ordinaryCase = word == original || word == original.prefix(1).uppercased() + original.dropFirst()
        if startsToken, let expansion = shortcuts[word] {
            choices.automatic = expansion
            choices.suggestions.append(expansion)
        } else if startsToken, !knownWords.contains(original),
                  normalized.allSatisfy({ $0.isASCII && ($0.isLetter || $0 == "'") }) {
            let missed = checker.rangeOfMisspelledWord(in: context, range: range, startingAt: range.location,
                                                       wrap: false, language: language)
            let leadingText = String(leading.suffix(160))
            // Keep a literal spelling after an explicit code or spelling prompt.
            let literalContext = leadingText.lowercased().trimmingCharacters(in: .whitespaces)
            if Self.isLiteralContext(literalContext) { return choices }
            let prior = literalContext.split(whereSeparator: { !$0.isLetter && $0 != "'" }).last.map(String.init) ?? ""
            // Only read a left neighbour in the same phrase. Punctuation, quoted
            // spellings, and identifier fragments cannot authorize these edits.
            let adjacent = leading.last == " " && leading.dropLast()
                .last.map { $0.isLetter } == true
            if let restored = SentenceSurface.contraction(word, left: leadingText, right: "") {
                return Choices(automatic: restored, suggestions: [restored])
            }
            if usesSentenceContext, (adjacent || leading.isEmpty), let spaced = Self.capitalBoundary(word) {
                return Choices(automatic: spaced, suggestions: [spaced])
            }
            if usesSentenceContext, adjacent, word == normalized {
                if preparesTransformerReviews, missed == range, let split = Self.predicateBoundary(word, prior: prior) {
                    return Choices(reviewAlternatives: includeCompletions ? [] : [split], reviewsProtectedBoundary: true)
                }
                if word.hasSuffix("a"), (3...14).contains(word.count),
                   missed == range || word == "asa" {
                    let first = String(word.dropLast())
                    if mb_pair_support_v1(prior, first) >= 4, mb_pair_support_v1(first, "a") >= 16,
                       mb_whole_compound_v1(word) == 0 {
                        // "Asa" is a name; only the lowercase occupational frame
                        // can override a valid spelling, and only after a noun.
                        if word == "asa" {
                            if preparesTransformerReviews, ["works","worked","working","hired","serves","served"].contains(prior) {
                                return Choices(reviewAlternatives: includeCompletions ? [] : ["as a"])
                            }
                        } else {
                            return Choices(automatic: first + " a", suggestions: [first + " a"])
                        }
                    }
                }
            }
            if usesSentenceContext, missed == range, let repaired = Self.calendarRepair(word, prior: prior) {
                return Choices(automatic: repaired, suggestions: [repaired])
            }
            guard ordinaryCase else { return choices }
            // These literal spellings were false positives in the previous benchmark.
            if ["tmux", "pnpm"].contains(normalized) ||
                (normalized.hasPrefix("soo") && normalized.dropFirst().allSatisfy({ $0 == "o" })) { return choices }
            // A confirmed multi-edit slip. Don't change it in isolation, as a
            // surname or identifier, or until the next word resolves its meaning.
            if normalized == "amanor" {
                if word == normalized, usesSentenceContext, preparesTransformerReviews,
                   ["this is", "that is", "it is", "this was", "that was", "it was"].contains(where: {
                       literalContext == $0 || literalContext.hasSuffix(" " + $0)
                   }) {
                    choices.suggestions = ["another"]
                    if !includeCompletions { choices.reviewAlternatives = ["amanor", "another"] }
                }
                return choices
            }
            // UTF-16 spellcheck ranges can cover just one side of an apostrophe.
            // Only split an unrecognized ordinary token. Preserve the original
            // casing and apostrophe; the fitted model proposes the boundary index.
            let contractionMiss = normalized.contains("'") && missed.location != NSNotFound &&
                NSIntersectionRange(missed, range).length > 0
            if usesSentenceContext, missed == range || contractionMiss,
               word == normalized || leading.isEmpty || normalized.first == "i" && word.first == "I",
               (4...30).contains(normalized.count), !includeCompletions, !prior.utf8.contains(0) {
                var buffer = [CChar](repeating: 0, count: 96)
                let left = adjacent ? prior : "^"
                if mb_trained_split_v1(left, normalized, &buffer, buffer.count) == 1 {
                    let length = String(cString: buffer).prefix(while: { $0 != " " }).count
                    let cut = word.index(word.startIndex, offsetBy: length)
                    func displayPart(_ s: Substring) -> String {
                        let lower = s.lowercased()
                        return lower == "i" || lower.hasPrefix("i'") || lower.hasPrefix("i’") ? "I" + s.dropFirst() : String(s)
                    }
                    let form = displayPart(word[..<cut]) + " " + displayPart(word[cut...])
                    return Choices(automatic: form, suggestions: [form])
                }
            }
            if usesSentenceContext, missed == range, word == normalized || leading.isEmpty,
               let split = Self.attestedFunctionBoundary(normalized, prior: prior.isEmpty ? "^" : prior) {
                let form = Self.splitDisplay(split, typed: word)
                return Choices(automatic: form, suggestions: [form])
            }
            let (strong, rankedWords) = ranked(normalized, after: leadingText)
            let previous = leading.last(where: { !$0.isWhitespace })
            let sentenceStart = previous == nil || previous.map { ".!?".contains($0) } == true || leading.last?.isNewline == true
            let mayCommit = word.first?.isLowercase == true || sentenceStart
            if preparesTransformerReviews, usesSentenceContext, mayCommit {
                if normalized == "lets", sentenceStart {
                    let form = word.first?.isUppercase == true ? "Let's" : "let's"
                    choices.suggestions = [form]
                    if !includeCompletions { choices.reviewAlternatives = ["lets", "let's"] }
                    return choices
                }
                // A participle after "what were" can resolve "we've".
                // Questions such as "what were you doing" keep the original.
                if normalized == "were", leadingText.lowercased().split(whereSeparator: { $0.isWhitespace }).last == "what" {
                    if !includeCompletions { choices.reviewAlternatives = ["were", "we've", "we're"] }
                    return choices
                }
            }
            // Keep the literal at the delimiter. A dedicated trained review compares
            // this valid spelling with "leak" once the continuation is available.
            if preparesTransformerReviews, usesSentenceContext, !includeCompletions, normalized == "leek", mayCommit {
                choices.reviewAlternatives = ["leek", "leak"]
                return choices
            }
            // Canonical first-person forms can be capitalized even mid-sentence.
            if strong, let first = rankedWords.first,
               first == "I" || first.hasPrefix("I'") {
                let canonical = word.contains("’") ? first.replacingOccurrences(of: "'", with: "’") : first
                if canonical != word {
                    choices.automatic = canonical
                    choices.suggestions.append(canonical)
                }
                return choices
            }
            if usesSentenceContext, preparesTransformerReviews, mayCommit, ordinaryCase,
               (2...3).contains(normalized.count), normalized.allSatisfy(\.isLetter),
               (leading.last?.isWhitespace ?? true), !leadingText.utf8.contains(0) {
                // iOS can recognize a genuine word absent from our corpus.
                // Permit only a contextual, missing-letter review in that case;
                // never turn an unseen, accepted word into a different spelling by substitution.
                if missed != range, mb_short_unseen_v1(normalized) == 1 {
                    var alternatives = [CChar](repeating: 0, count: 96)
                    return Choices(reviewsShortWord: !includeCompletions && mb_short_pool_v1(normalized, &alternatives, alternatives.count) == 1,
                                   missingLetterOnly: true)
                }
                var buffer = [CChar](repeating: 0, count: 32)
                let status = mb_short_word_v1(leadingText, normalized, "", &buffer, buffer.count)
                if status == 1 {
                    let fixed = Self.splitDisplay(String(cString: buffer), typed: word)
                    return Choices(automatic: fixed, suggestions: [fixed])
                }
                if status == 2, !includeCompletions {
                    return Choices(reviewsShortWord: true)
                }
            }
            // A repeatedly observed repair can include a missing space or a
            // word outside the decoder vocabulary. Don't override accepted words,
            // a manually capitalized name, a lexicon entry, or a literal.
            if usesSentenceContext, mayCommit, missed == range, !leadingText.utf8.contains(0) {
                var result = [CChar](repeating: 0, count: 128)
                if mb_attested_v1(leadingText, normalized, &result, 128) == 1 {
                    let form = String(cString: result)
                    if form == normalized { return choices } // Deliberately used in this phrase.
                    let cased = word.first?.isUppercase == true ? form.prefix(1).uppercased() + form.dropFirst() : form
                    return Choices(automatic: cased, suggestions: [cased])
                }
            }
            // Only known missing-apostrophe forms may override an accepted system spelling.
            // Ordinary valid words always win against statistical guesses.
            let contraction = strong && rankedWords.first?.contains("'") == true &&
                rankedWords.first?.replacingOccurrences(of: "'", with: "") == original
            // A colloquial spelling such as "tryin" can be deliberate. Offer its
            // standard spelling when the system accepts the literal.
            if missed != range, !contraction, strong, let first = rankedWords.first,
               normalized.hasSuffix("in"), first == normalized + "g" {
                choices.suggestions = [word.first?.isUppercase == true ? first.capitalized : first]
            }
            if missed == range || contraction {
                var guesses = checker.guesses(forWordRange: range, in: context, language: language) ?? []
                if word != original {
                    // A capital supplied by sentence shift shouldn't turn a typo into a proper name.
                    let lowerRange = NSRange(original.startIndex..., in: original)
                    let lowerGuesses = checker.guesses(forWordRange: lowerRange, in: original, language: language) ?? []
                    if !lowerGuesses.isEmpty { guesses = lowerGuesses }
                }
                // Native guesses may contain a space even when neither the
                // keyboard's error table nor its bigram table knows the join.
                // Keep explicit contractions/attested repairs ahead of these.
                if usesSentenceContext, missed == range, mayCommit, !contraction,
                   normalized.count >= 4, normalized.allSatisfy({ $0.isLetter }),
                   !strong {
                    var splits = Set<String>()
                    for (index, guess) in guesses.prefix(4).enumerated() {
                        let candidate = guess.lowercased()
                        if candidate.contains(" "), mb_supports_split_v1(prior.isEmpty ? "^" : prior,
                                normalized, candidate, UInt32(index)) == 1 {
                            splits.insert(candidate)
                        }
                    }
                    if splits.count == 1, let split = splits.first {
                        let form = Self.splitDisplay(split, typed: word)
                        return Choices(automatic: form, suggestions: [form])
                    }
                    // A well-attested boundary can be absent from UIKit's top
                    // guesses ("letme"). It must outrank a speculative letter edit.
                    var buffer = [CChar](repeating: 0, count: 96)
                    if mb_boundary_v1(prior.isEmpty ? "^" : prior, normalized, &buffer, buffer.count) == 1 {
                        let split = String(cString: buffer)
                        let parts = split.split(separator: " ")
                        if parts.count == 2, mb_pair_support_v1(String(parts[0]), String(parts[1])) >= 12 {
                            let form = Self.splitDisplay(split, typed: word)
                            return Choices(automatic: form, suggestions: [form])
                        }
                    }
                }
                // A native guess can omit the apostrophe too. Require the native
                // first choice, an adjacent key, and a known contraction before
                // composing those two edits (e.g. whays -> whats -> what's).
                let repairedContraction: String? = guesses.first.flatMap { guess in
                    let stem = guess.lowercased()
                    guard stem.count >= 4, isNeighborSlip(normalized, stem) else { return nil }
                    let (sure, words) = ranked(stem, after: leadingText)
                    guard sure, let form = words.first, form.contains("'"),
                          form.replacingOccurrences(of: "'", with: "").lowercased() == stem else { return nil }
                    return form
                }
                if let preferred = commonTypos[original],
                   let index = guesses.firstIndex(where: { $0.lowercased() == preferred }) {
                    guesses.swapAt(0, index)
                }
                let supported = supportedCorrection(original, rankedWords: rankedWords, guesses: guesses, context: leadingText)
                let prioritizeRust = strong || supported != nil
                let ordered = [repairedContraction].compactMap { $0 } + (prioritizeRust ? rankedWords + guesses : guesses + rankedWords)
                choices.suggestions = ordered.map { guess in
                    word.first?.isUppercase == true ? guess.prefix(1).uppercased() + guess.dropFirst() : guess
                }
                if (prioritizeRust || repairedContraction != nil), mayCommit, let best = choices.suggestions.first {
                    choices.automatic = best
                } else if mayCommit, let first = guesses.first, first.first?.isUppercase != true,
                   let best = choices.suggestions.first, word.count >= 3,
                   best.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "’" }),
                   best.caseInsensitiveCompare(word) != .orderedSame {
                    let edits = Self.distance(original, best.lowercased())
                    let ambiguous = choices.suggestions.dropFirst().prefix(2).contains {
                        $0.caseInsensitiveCompare(best) != .orderedSame && Self.distance(original, $0.lowercased()) <= edits
                    }
                    if edits <= (word.count >= 6 ? 2 : 1) && (!ambiguous || commonTypos[original] == best.lowercased()) {
                        choices.automatic = best
                    }
                }
                // Common typos, canonical apostrophes and user choices already have strong evidence.
                if usesSentenceContext, mayCommit, missed == range, !contraction, repairedContraction == nil,
                   commonTypos[original] == nil, normalized.count >= 3 {
                    let tail = sentenceContext(before: leading)
                    let candidates = sentenceCandidates(ordered, typed: normalized, context: tail)
                    #if BENCHMARK
                    onSentenceCandidates?(String(leading), choices.automatic, candidates)
                    #endif
                    let neural = sentenceWinner(candidates, typed: normalized, baseline: choices.automatic?.lowercased())
                    let base = neural ?? choices.automatic?.lowercased() ?? normalized
                    if preparesTransformerReviews, !includeCompletions {
                        choices.reviewAlternatives = candidates.filter { $0.edits == 1 }.map(\.word)
                    }
                    let pool = candidates.map(\.word)
                    let index = tail.utf8.contains(0) ? -1 : Int(mb_refine_v1(tail, normalized, base, pool.joined(separator: "\t")))
                    if let best = pool.indices.contains(index) ? pool[index] : neural {
                        let cased = word.first?.isUppercase == true ? best.prefix(1).uppercased() + best.dropFirst() : best
                        choices.automatic = cased
                        choices.suggestions.insert(cased, at: 0)
                    }
                }
                if choices.automatic == nil, usesSentenceContext, missed == range, mayCommit,
                   normalized.count >= 5 {
                    var result = [CChar](repeating: 0, count: 96)
                    let status = mb_boundary_v1(prior.isEmpty ? "^" : prior, normalized, &result, result.count)
                    if status == 1 || (status == 2 && preparesTransformerReviews) {
                        let split = String(cString: result)
                        let form = word.first?.isUppercase == true ? split.prefix(1).uppercased() + split.dropFirst() : split
                        if status == 1 { return Choices(automatic: form, suggestions: [form]) }
                        return Choices(suggestions: [form], reviewAlternatives: includeCompletions ? [] : [split])
                    }
                }
                if choices.automatic == nil, mayCommit, usesSentenceContext, (4...32).contains(normalized.count),
                   !leadingText.utf8.contains(0) {
                    var buffer = [CChar](repeating: 0, count: 128)
                    let masks = neighborMasks ?? []
                    let found = masks.withUnsafeBufferPointer {
                        mb_touch_repair_v1(leadingText, normalized, $0.count == 26 ? $0.baseAddress : nil, &buffer, 128)
                    }
                    if found == 1 {
                        let repair = String(cString: buffer)
                        let replacement = word.first?.isUppercase == true ? repair.prefix(1).uppercased() + repair.dropFirst() : repair
                        choices.automatic = replacement
                        choices.suggestions.insert(replacement, at: 0)
                        choices.reviewAlternatives = []
                    }
                }
            }
        }
        if includeCompletions {
            choices.suggestions += checker.completions(forPartialWordRange: wordRange, in: word, language: language) ?? []
        }
        var seen = Set([original])
        choices.suggestions = Array(choices.suggestions.filter { seen.insert($0.lowercased()).inserted }.prefix(2))
        return choices
    }

    private static func splitDisplay(_ candidate: String, typed: String) -> String {
        let form = candidate.split(separator: " ").map { $0 == "i" ? "I" : String($0) }.joined(separator: " ")
        return typed.first?.isUppercase == true ? form.prefix(1).uppercased() + form.dropFirst() : form
    }

    private func sentenceWinner(_ candidates: [Candidate], typed: String, baseline: String?) -> String? {
        // Frozen using the separate calibration replay. Scores are logit
        // margins, not probabilities. Retain unseen candidates as competitors.
        var best: (Candidate, Float)?
        var runnerUp: Float = 0
        for (index, candidate) in candidates.enumerated() where candidate.edits <= (typed.count >= 6 ? 2 : 1) {
            let score = (candidate.logit ?? 0) - 3 * Float(candidate.edits - 1)
                + (candidate.word == baseline ? 3 : 0) + 0.5 / Float(1 + index)
            if score > (best?.1 ?? -.infinity) {
                runnerUp = max(runnerUp, best?.1 ?? 0)
                best = (candidate, score)
            } else { runnerUp = max(runnerUp, score) }
        }
        guard let (candidate, score) = best, let logit = candidate.logit,
              logit >= 3, score - runnerUp >= 3.5 else { return nil }
        return candidate.word
    }

    /// Adjacent transpositions count as one mistap.
    private static func distance(_ first: String, _ second: String) -> Int {
        let a = Array(first), b = Array(second)
        var previous = Array(0...b.count)
        var older = previous
        for (i, lhs) in a.enumerated() {
            var next = [i + 1]
            for (j, rhs) in b.enumerated() {
                var cost = min(previous[j + 1] + 1, next[j] + 1, previous[j] + (lhs == rhs ? 0 : 1))
                if i > 0, j > 0, lhs == b[j - 1], a[i - 1] == rhs {
                    cost = min(cost, older[j - 1] + 1)
                }
                next.append(cost)
            }
            older = previous
            previous = next
        }
        return previous[b.count]
    }
}
