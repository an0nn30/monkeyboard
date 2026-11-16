import UIKit

@main struct PresentationCheck {
    @MainActor static func main() {
        var failures = 0
        for style in [UIUserInterfaceStyle.light, .dark] {
            for (width, split) in [(466, false), (669, true)] {
                let size = CGSize(width: width, height: 289)
                let traits = UITraitCollection(userInterfaceStyle: style)
                traits.performAsCurrent {
                    let stage = UIView(frame: CGRect(origin: .zero, size: size))
                    stage.overrideUserInterfaceStyle = style
                    // A varying material exposes a fixed fill even when its color looks
                    // correct against the plain background in the app's typing demo.
                    let material = CAGradientLayer()
                    material.frame = stage.bounds
                    material.colors = [UIColor.systemTeal.cgColor, UIColor.systemBrown.cgColor]
                    material.startPoint = .zero
                    material.endPoint = CGPoint(x: 1, y: 1)
                    stage.layer.addSublayer(material)
                    let board = KeyboardView()
                    board.frame = stage.bounds
                    stage.addSubview(board)
                    var model = KeyboardModel()
                    model.isSplit = split
                    board.update(model, returnTitle: nil)
                    board.setSuggestions(["I", "the", "you"])
                    stage.layoutIfNeeded()
                    // Read the actual sRGB pixels so image metadata is irrelevant.
                    let height = Int(size.height)
                    func render() -> [UInt8] {
                        var bytes = [UInt8](repeating: 0, count: width * height * 4)
                        bytes.withUnsafeMutableBytes { buffer in
                            let ctx = CGContext(data: buffer.baseAddress!, width: width, height: height,
                                                bitsPerComponent: 8, bytesPerRow: width * 4,
                                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                            ctx.translateBy(x: 0, y: size.height)
                            ctx.scaleBy(x: 1, y: -1)
                            stage.layer.render(in: ctx)
                        }
                        return bytes
                    }
                    board.coverKeyboardHandoff(true)
                    let duringHandoff = render()
                    material.isHidden = true
                    if duringHandoff != render() {
                        print("FAIL: outgoing keyboard can show through during handoff")
                        failures += 1
                    }
                    material.isHidden = false
                    board.coverKeyboardHandoff(false)
                    let keyboard = render()
                    board.isHidden = true
                    let host = render()
                    func check(_ name: String, _ rect: CGRect, same: Bool) {
                        let matches = (Int(rect.minY)..<Int(rect.maxY)).allSatisfy { y in
                            let start = 4 * (y * width + Int(rect.minX))
                            let span = start..<(start + 4 * Int(rect.width))
                            return keyboard[span] == host[span]
                        }
                        if matches != same {
                            print("FAIL: \(width)pt \(style == .dark ? "dark" : "light") \(name)")
                            failures += 1
                        }
                    }
                    check("toolbar edge", CGRect(x: 0, y: 0, width: width, height: 3), same: true)
                    check("footer", CGRect(x: 70, y: 277, width: width - 140, height: 12), same: true)
                    if split {
                        check("split gutter", CGRect(x: width / 2 - 4, y: 65, width: 8, height: 180), same: true)
                    }
                    check("visible keycap", CGRect(x: 15, y: 68, width: 10, height: 5), same: false)
                }
            }
        }
        print("Keyboard material checks: \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
