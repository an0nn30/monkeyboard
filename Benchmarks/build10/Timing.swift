import Foundation
import MonkeyBoardEngine

@main struct Timing {
    static func main() {
        let candidates = "soon\tsong\tsung\tson\tsongbird\tlong\twrong\tstrong"
        var out = [Float](repeating: 0, count: 8)
        for n in [12, 128] {
            let sentence = String(repeating: "we went out to hear that band play again last night together ", count: (n + 11) / 12)
            var times = [Double]()
            for _ in 0..<501 {
                let start = DispatchTime.now().uptimeNanoseconds
                precondition(mb_sentence_scores_v1(sentence, candidates, &out, 8) == 8)
                times.append(Double(DispatchTime.now().uptimeNanoseconds-start) / 1e6)
            }
            let first = times.removeFirst()
            let sorted = times.sorted()
            print("context=\(n) candidates=8 first_ms=\(first) warm_p50_ms=\(sorted[250]) warm_p95_ms=\(sorted[474])")
        }
    }
}
