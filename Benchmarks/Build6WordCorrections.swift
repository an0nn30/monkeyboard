import UIKit

/// Uses the English system dictionary for spelling and completions. Only close,
/// high-confidence guesses are eligible to replace a word without a tap.
@MainActor
final class Build6WordCorrections {
    private let checker = UITextChecker()
    private let language = "en_US"
    private var knownWords = Set<String>()
    private var shortcuts: [String: String] = [:]
    // Frequent English typos for which the dictionary can rank a different
    // one-edit word first (e.g. “wired” for “wierd”).
    private let commonTypos = ["teh": "the", "wierd": "weird", "thier": "their",
                               "recieve": "receive", "becuase": "because", "definately": "definitely",
                               "dont": "don't", "adress": "address"]

    struct Choices {
        var automatic: String?
        var suggestions: [String] = []
    }

    func use(_ lexicon: UILexicon) {
        for entry in lexicon.entries {
            knownWords.insert(entry.documentText.lowercased())
            if !entry.userInput.isEmpty && entry.userInput.caseInsensitiveCompare(entry.documentText) != .orderedSame {
                shortcuts[entry.userInput] = entry.documentText
            }
        }
    }

    func choices(for word: String, before: String, includeCompletions: Bool) -> Choices {
        guard (1...40).contains(word.count), before.hasSuffix(word) else { return Choices() }
        let original = word.lowercased()
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
        } else if startsToken, ordinaryCase, !knownWords.contains(original),
                  word.allSatisfy({ $0.isASCII && ($0.isLetter || $0 == "'") }) {
            let missed = checker.rangeOfMisspelledWord(in: context, range: range, startingAt: range.location,
                                                       wrap: false, language: language)
            if missed == range {
                var guesses = checker.guesses(forWordRange: range, in: context, language: language) ?? []
                if word != original {
                    // A capital supplied by sentence shift shouldn't turn a typo into a proper name.
                    let lowerRange = NSRange(original.startIndex..., in: original)
                    let lowerGuesses = checker.guesses(forWordRange: lowerRange, in: original, language: language) ?? []
                    if !lowerGuesses.isEmpty { guesses = lowerGuesses }
                }
                if let preferred = commonTypos[original],
                   let index = guesses.firstIndex(where: { $0.lowercased() == preferred }) {
                    guesses.swapAt(0, index)
                }
                choices.suggestions = guesses.map { guess in
                    word.first?.isUppercase == true ? guess.prefix(1).uppercased() + guess.dropFirst() : guess
                }
                // Protect intentional capitalized names away from the start of a sentence.
                let previous = leading.last(where: { !$0.isWhitespace })
                let sentenceStart = previous == nil || previous.map { ".!?".contains($0) } == true || leading.last?.isNewline == true
                if let first = guesses.first, first.first?.isUppercase != true,
                   let best = choices.suggestions.first, word.count >= 3,
                   (word.first?.isLowercase == true || sentenceStart),
                   best.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "’" }),
                   best.caseInsensitiveCompare(word) != .orderedSame {
                    let edits = Self.distance(original, best.lowercased())
                    let ambiguous = choices.suggestions.dropFirst().prefix(2).contains {
                        Self.distance(original, $0.lowercased()) <= edits
                    }
                    if edits <= (word.count >= 6 ? 2 : 1) && (!ambiguous || commonTypos[original] == best.lowercased()) {
                        choices.automatic = best
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
