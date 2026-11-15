import UIKit

@main
struct Replay {
    @MainActor static func main() throws {
        let decoder = try SentenceDecoder(resources: URL(fileURLWithPath: CommandLine.arguments[1]))
        let corrections = WordCorrections()
        corrections.preparesTransformerReviews = true
        let board = KeyboardView()
        var keyboard = KeyboardModel()
        keyboard.needsGlobe = true
        board.onLetterGeometry = { corrections.neighborMasks = $0 }
        board.frame = CGRect(x: 0, y: 0, width: 393, height: 250)
        board.update(keyboard, returnTitle: nil)
        board.layoutIfNeeded()
        let shard = Int(ProcessInfo.processInfo.environment["MB_SHARD"] ?? "0") ?? 0
        let shards = Int(ProcessInfo.processInfo.environment["MB_SHARDS"] ?? "1") ?? 1
        precondition(shards > 0 && (0..<shards).contains(shard))
        let data = try String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8)
        print("id\tcommit\tfinal\tstrip\tcompact")
        for (index, line) in data.split(separator: "\n").dropFirst().enumerated() {
            guard index % shards == shard else { continue }
            let f = line.components(separatedBy: "\t")
            precondition(f.count == 9)
            if CommandLine.arguments.count > 3 && !CommandLine.arguments[3...].contains(f[0]) { continue }
            // Release autoreleased UIKit/Core ML temporaries after each message,
            // as the real keyboard does between run-loop events.
            try autoreleasepool {
                let leading = f[5].isEmpty ? "" : f[5] + " "
                let word = f[6], following = f[8].split(separator: " ").map(String.init)
                if f[2] == "next" {
                    let compact = corrections.nextWords(before: leading)
                    let words = try decoder.nextWords(before: leading)
                    let strip = words.isEmpty ? compact : words
                    print([String(index), "", "", strip.joined(separator: "|"), compact.joined(separator: "|")].joined(separator: "\t"))
                } else {
                    let choices = corrections.choices(for: word, before: leading + word, includeCompletions: false)
                    let committed = choices.automatic ?? word
                    var final = committed
                    if !choices.reviewAlternatives.isEmpty {
                        let request = SentenceDecoder.Review(typed: word, leading: leading, alternatives: choices.reviewAlternatives)
                        for n in following.indices.prefix(request.followingWordLimit) {
                            if let winner = try decoder.revision(request, committed: committed, following: following[...n].joined(separator: " ")) {
                                final = winner
                                break
                            }
                        }
                    }
                    print([String(index), committed, final, "", ""].joined(separator: "\t"))
                }
            }
            if index % 100 == 0 { fflush(stdout) }
        }
    }
}
