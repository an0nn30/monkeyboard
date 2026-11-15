import UIKit

@main
struct TapReplay {
    @MainActor static func main() {
        for split in [false, true] {
            let board = KeyboardView()
            var model = KeyboardModel()
            model.isSplit = split
            board.frame = CGRect(x: 0, y: 0, width: split ? 900 : 393, height: 250)
            board.update(model, returnTitle: nil)
            board.layoutIfNeeded()
            let buttons = board.subviews.compactMap { $0 as? UIButton }.filter { $0.bounds.width > 0 && $0.isUserInteractionEnabled }
            let top = buttons.map { board.keycapFrame(of: $0).minY }.min()!
            var correct = 0, dropped = 0, wrong = 0
            var checked = 0
            for key in buttons where key.accessibilityLabel?.count == 1 && key.accessibilityLabel?.first?.isLetter == true {
                let r = board.keycapFrame(of: key)
                for point in [CGPoint(x:r.midX,y:r.midY), CGPoint(x:r.minX+1,y:r.midY), CGPoint(x:r.maxX-1,y:r.midY),
                              CGPoint(x:r.minX-0.75,y:r.midY), CGPoint(x:r.maxX+0.75,y:r.midY),
                              CGPoint(x:r.midX,y:r.minY-0.75), CGPoint(x:r.midX,y:r.maxY+0.75)] {
                    // Top of the first row touches the toolbar. That region belongs to its controls.
                    if point.y < top { continue }
                    checked += 1
                    let hit = board.hitTest(point, with: nil)
                    if hit === key { correct += 1 }
                    else if !(hit is UIButton) { dropped += 1 }
                    else { wrong += 1 }
                }
            }
            precondition(checked == 172 && correct == checked && dropped == 0 && wrong == 0,
                         "Letter hit coverage regressed")
            if split {
                let hit = board.hitTest(CGPoint(x:board.bounds.midX,y:buttons[0].frame.midY),with:nil)
                precondition(!(hit is UIButton), "Split gutter captured a touch")
            }
            print("\(split ? "split" : "joined")\t\(checked)\t\(correct)\t\(dropped)\t\(wrong)")
        }
    }
}
