import UIKit

@main
struct ReviewReplay {
    @MainActor static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let decoder = try SentenceDecoder(resources: root)
        let compact = WordCorrections()
        let corrections = WordCorrections()
        corrections.preparesTransformerReviews = true
        let board = KeyboardView()
        var keyboard = KeyboardModel()
        keyboard.needsGlobe = true
        board.onLetterGeometry = { masks in
            compact.neighborMasks = masks
            corrections.neighborMasks = masks
        }
        board.frame = CGRect(x: 0, y: 0, width: 393, height: 250)
        board.update(keyboard, returnTitle: nil)
        board.layoutIfNeeded()
        print("left\ttyped\tright\tgold\tcommit\tafter_context\tfollowing_words\tcompact")
        let input = try String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8)
        for line in input.split(separator: "\n") where !line.hasPrefix("#") {
            let fields = line.components(separatedBy: "\t")
            precondition(fields.count == 4)
            let (left, word, right, expected) = (fields[0] + " ", fields[1], fields[2], fields[3])
            let compactWord = compact.choices(for: word, before: left + word, includeCompletions: false).automatic ?? word
            let choices = corrections.choices(for: word, before: left + word, includeCompletions: false)
            let committed = choices.automatic ?? word
            var final = committed
            var count = 0
            let following = right.components(separatedBy: " ")
            if !choices.reviewAlternatives.isEmpty {
                let review = SentenceDecoder.Review(typed: word, leading: left, alternatives: choices.reviewAlternatives)
                for n in 1...min(review.followingWordLimit, following.count) {
                    if let winner = try decoder.revision(review, committed: committed, following: following.prefix(n).joined(separator: " ")) {
                        final = winner
                        count = n
                        break
                    }
                }
            }
            print([fields[0], word, right, expected, committed, final, String(count), compactWord].joined(separator: "\t"))
        }
    }
}
