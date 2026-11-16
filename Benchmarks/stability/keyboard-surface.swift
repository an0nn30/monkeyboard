import UIKit

@main struct PresentationCheck {
    @MainActor static func main() {
        // Reproduce the compositor state directly: a row of contrasting system caps
        // may remain in the host while the extension is being presented.
        var leaks = 0
        for style in [UIUserInterfaceStyle.light, .dark] {
            for (width, split) in [(466, false), (669, true)] {
                let size = CGSize(width: width, height: 289)
                let stage = UIView(frame: CGRect(origin: .zero, size: size))
                stage.overrideUserInterfaceStyle = style
                let keycaps = UIView(frame: stage.bounds)
                keycaps.backgroundColor = .black
                for i in 0..<10 {
                    let cap = UIView(frame: CGRect(x: CGFloat(i)*size.width/10+3, y: 7, width: size.width/10-6, height: 46))
                    cap.backgroundColor = .white; keycaps.addSubview(cap)
                }
                stage.addSubview(keycaps)
                let board = KeyboardView(); board.frame = stage.bounds
                stage.addSubview(board)
                var model = KeyboardModel(); model.isSplit = split
                board.update(model, returnTitle: nil)
                stage.layoutIfNeeded(); board.layoutIfNeeded()
                func render(_ underlay: Bool) -> Data {
                    keycaps.isHidden = !underlay
                    let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1; fmt.opaque = true
                    return UIGraphicsImageRenderer(size: size, format: fmt).pngData { ctx in
                        stage.layer.render(in: ctx.cgContext)
                    }
                }
                let clean = render(false)
                let overlay = render(true)
                if clean != overlay { leaks += 1 }
                print("underlay visible in \(width)pt \(style == .dark ? "dark" : "light"): \(clean != overlay)")
            }
        }
        exit(leaks == 0 ? 0 : 1)
    }
}
