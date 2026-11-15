import UIKit

@main
struct Compare {
    @MainActor static func main() throws {
        let fixture = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
        let baseline = Build6WordCorrections()
        #if !BASELINE_ONLY
        let candidate = WordCorrections()
        // Optional reproducible input to offline model and threshold comparison.
        candidate.sentenceWindowForBenchmark = Int(ProcessInfo.processInfo.environment["MB_WINDOW"] ?? "")
        let dump = ProcessInfo.processInfo.environment["MB_DUMP"] ?? ""
        var request: [String: Any] = [:]
        var detail = [[String: Any]]()
        candidate.onSentenceCandidates = { leading, baseline, choices in
            request["leading"] = leading
            request["pool"] = choices.map { ["word": $0.word, "edits": $0.edits, "score": $0.logit as Any? ?? NSNull()] }
        }
        let split = ProcessInfo.processInfo.environment["MB_LAYOUT"] == "split"
        let board = KeyboardView()
        var model = KeyboardModel()
        model.isSplit = split
        model.needsGlobe = true
        board.onLetterGeometry = { candidate.neighborMasks = $0 }
        board.frame = CGRect(x: 0, y: 0, width: split ? 900 : 393, height: 250)
        board.update(model, returnTitle: nil)
        board.layoutIfNeeded()
        precondition(candidate.neighborMasks?.contains(where: { $0 != 0 }) == true)
        #endif
        print("kind\tcontext\texpected\tbuild6\tcandidate")
        for line in fixture.split(separator: "\n") where !line.hasPrefix("#") {
            let fields = line.components(separatedBy: "\t")
            precondition(fields.count == 3)
            let (kind, before, expected) = (fields[0], fields[1], fields[2])
            let word = String(before.reversed().prefix { $0.isLetter || $0 == "'" || $0 == "’" }.reversed())
            var old: String
            var new: String
            if kind == "next" {
                old = "I|the|you"
                #if BASELINE_ONLY
                new = old
                #else
                new = candidate.nextWords(before: before + " ").joined(separator: "|")
                #endif
            } else {
                old = baseline.choices(for: word, before: before, includeCompletions: false).automatic ?? word
                #if BASELINE_ONLY
                new = old
                #else
                new = candidate.choices(for: word, before: before, includeCompletions: false).automatic ?? word
                #endif
            }
            #if !BASELINE_ONLY
            if !dump.isEmpty {
                request["input"] = before; request["typed"] = word; request["kind"] = kind; request["expected"] = expected
                detail.append(request); request = [:]
            }
            #endif
            print([kind, before, expected, old, new].joined(separator: "\t"))
        }
        #if !BASELINE_ONLY
        if !dump.isEmpty { try JSONSerialization.data(withJSONObject: detail).write(to: URL(fileURLWithPath: dump)) }
        #endif
    }
}
