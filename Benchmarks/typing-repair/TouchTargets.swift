import UIKit

@main
struct TouchTargets {
    @MainActor static func main() {
        var failures = 0
        for (layout, width, split) in [("cover", 393.0, false), ("wide joined", 900.0, false), ("wide split", 900.0, true)] {
            let board = KeyboardView()
            var model = KeyboardModel()
            model.isSplit = split
            board.frame = CGRect(x: 0, y: 0, width: width, height: 289)
            board.update(model, returnTitle: nil)
            board.layoutIfNeeded()
            let keys = board.subviews.compactMap { $0 as? UIButton }.filter {
                !$0.isHidden && $0.isUserInteractionEnabled && $0.alpha > 0 && $0.frame.width > 0
            }
            let bars = keys.filter { $0.accessibilityLabel == "Space" }
            precondition(bars.count == (split ? 2 : 1))
            var totals: [String: Int] = [:], hits: [String: Int] = [:]
            func check(_ category: String, x: CGFloat, y: CGFloat, intended: UIButton?) {
                let hit = board.hitTest(CGPoint(x: x, y: y), with: nil) as? UIButton
                totals[category, default: 0] += 1
                if hit === intended { hits[category, default: 0] += 1 }
                else { failures += 1 }
            }
            for bar in bars {
                let face = board.keycapFrame(of: bar)
                for fraction in [0.12, 0.5, 0.88] {
                    let x = face.minX + fraction * face.width
                    for y in [face.minY - 2, face.minY - 1, face.minY + 1, face.midY, face.maxY + 10] {
                        check("space", x: x, y: y, intended: bar)
                    }
                }
                for mark in keys where [",", "."].contains(mark.accessibilityLabel ?? "") {
                    let punct = board.keycapFrame(of: mark)
                    let onLeft = punct.midX < face.midX
                    let edge = onLeft ? face.minX : face.maxX
                    let gap = (onLeft ? punct.maxX : punct.minX) - edge
                    guard abs(gap) <= 5 else { continue }
                    for fraction in [0.2, 0.4, 0.6, 0.8] {
                        let closerToSpace = fraction < 0.5
                        check(closerToSpace ? "space" : "punctuation", x: edge + gap * fraction, y: face.midY,
                              intended: closerToSpace ? bar : mark)
                    }
                    check("punctuation", x: punct.midX, y: punct.midY, intended: mark)
                }
            }
            for letter in keys where ["b", "n"].contains(letter.accessibilityLabel?.lowercased() ?? "") {
                let face = board.keycapFrame(of: letter)
                for y in [face.midY, face.maxY - 1, face.maxY + 1] {
                    check("B/N", x: face.midX, y: y, intended: letter)
                }
            }
            if split {
                let left = board.keycapFrame(of: bars[0]), right = board.keycapFrame(of: bars[1])
                for x in [left.maxX + 6, board.bounds.midX, right.minX - 6] {
                    check("gutter", x: x, y: left.midY, intended: nil)
                }
            }
            for category in totals.keys.sorted() {
                print("\(layout)\t\(category)\t\(hits[category, default: 0])/\(totals[category]!)")
            }
        }
        if failures > 0 { exit(1) }
    }
}
