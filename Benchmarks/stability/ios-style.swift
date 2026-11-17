import UIKit

@main struct IOSStyleCheck {
    @MainActor static func main() {
        var failures = 0
        func check(_ value: Bool, _ message: String) {
            if !value { failures += 1; print("FAIL: \(message)") }
        }
        let board = KeyboardView()
        for width in [320.0, 452, 655, 801, 951] {
            for split in [false, true] where !split || width >= 560 {
                for repeats in [false, true] {
                    for hand in OneHandedLayout.allCases where (width < 560 && !split) || hand == .fullWidth {
                        for layer in [KeyboardModel.Layer.letters, .numbers, .symbols, .keypad] {
                            var model = KeyboardModel()
                            model.style = .ios
                            model.layer = layer
                            model.isSplit = split
                            model.repeatSplitLetters = repeats
                            model.needsGlobe = true
                            model.oneHanded = hand
                            board.frame = CGRect(x: 0, y: 0, width: width,
                                                 height: model.style.height(for: width, compact: false) + model.style.bottomOverlap(for: width, safeBottom: 34))
                            board.update(model, returnTitle: nil)
                            board.layoutIfNeeded()
                            let caps = board.subviews.compactMap { $0 as? UIButton }.filter {
                                !$0.isHidden && $0.alpha > 0 && $0.isUserInteractionEnabled &&
                                ($0.accessibilityIdentifier?.hasPrefix("key-") ?? false)
                            }
                            for cap in caps {
                                let face = board.keycapFrame(of: cap)
                                check(face.width > 10 && face.height > 10, "empty key \(cap.accessibilityIdentifier ?? "")")
                                check(board.bounds.insetBy(dx: -1, dy: -1).contains(face), "outside bounds \(width) \(split) \(hand) \(layer) \(face)")
                                check(board.hitTest(CGPoint(x: face.midX, y: face.midY), with: nil) === cap,
                                      "center hit \(width) \(split) \(hand) \(layer) \(cap.accessibilityIdentifier ?? "")")
                            }
                            if layer == .numbers || layer == .symbols {
                                let numbers = caps.filter { $0.accessibilityLabel == "1" || $0.accessibilityLabel == "[" }
                                let second = caps.filter { $0.accessibilityLabel == "-" || $0.accessibilityLabel == "_" }
                                if let a = numbers.first, let b = second.first {
                                    let first = board.keycapFrame(of: a), next = board.keycapFrame(of: b)
                                    let point = CGPoint(x: (max(first.minX, next.minX) + min(first.maxX, next.maxX)) / 2,
                                                        y: (first.maxY + next.minY) / 2)
                                    check(board.hitTest(point, with: nil) !== board, "symbol row gap \(width) \(split) \(hand)")
                                }
                            }
                            if layer == .letters {
                                let labels = caps.compactMap(\.accessibilityLabel)
                                for letter in "abcdefghijklmnopqrstuvwxyz" { check(labels.contains(String(letter)), "missing \(letter)") }
                                check(!labels.contains("."), "iOS bottom row should give the shortcut room to Space")
                                check(labels.filter { $0 == "Space" }.count == (split ? 2 : 1), "space count")
                            }
                        }
                    }
                }
            }
        }
        // Reach adjusts positions, never painted sizes. Exercise both repeat modes
        // and all pages so an extra split key cannot silently compress its neighbors.
        for style in KeyboardStyle.allCases {
            for width in [452.0, 560, 655, 801, 951] {
                for split in [false, true] where !split || width >= 560 {
                    for repeats in [false, true] {
                        for layer in [KeyboardModel.Layer.letters, .numbers, .symbols, .keypad] {
                            var model = KeyboardModel()
                            model.style = style
                            model.layer = layer
                            model.isSplit = split
                            model.repeatSplitLetters = repeats
                            model.needsGlobe = true
                            board.frame = CGRect(x: 0, y: 0, width: width, height: style.height(for: width, compact: false))
                            var original: [CGRect] = []
                            var lastQ: CGFloat?
                            for reach in [0, 50, 100] {
                                model.thumbReachPercent = reach
                                var geometryRebuilt = false
                                board.onLetterGeometry = { _ in geometryRebuilt = true }
                                board.update(model, returnTitle: nil)
                                board.layoutIfNeeded()
                                let caps = board.subviews.compactMap { $0 as? UIButton }.filter {
                                    !$0.isHidden && $0.alpha > 0 && $0.isUserInteractionEnabled &&
                                    ($0.accessibilityIdentifier?.hasPrefix("key-") ?? false)
                                }
                                let faces = caps.map { board.keycapFrame(of: $0) }
                                let active = style == .ios && split && layer != .keypad
                                if reach == 0 { original = faces }
                                check(faces.count == original.count, "reach changed key count")
                                for (index, face) in faces.enumerated() {
                                    let before = original[index]
                                    check(abs(face.width - before.width) < 0.001 && abs(face.height - before.height) < 0.001,
                                          "reach shrank a key: \(width) \(layer) \(repeats)")
                                    check(face.minY == before.minY, "reach changed vertical spacing")
                                    if !active { check(face == before, "reach changed an unrelated layout") }
                                    check(board.bounds.insetBy(dx: -1, dy: -1).contains(face), "reach moved key out of bounds")
                                    check(board.hitTest(CGPoint(x: face.midX, y: face.midY), with: nil) === caps[index], "reach tap missed key")
                                    if active {
                                        for other in faces.dropFirst(index + 1) where abs(other.minY - face.minY) < 0.1 {
                                            let gap = max(other.minX - face.maxX, face.minX - other.maxX)
                                            check(gap >= 5.99, "reach crowded keys: \(width) \(layer) \(gap)")
                                        }
                                    }
                                }
                                if active && layer == .letters {
                                    let q = faces[caps.firstIndex { $0.accessibilityLabel == "q" }!]
                                    if let lastQ { check(q.minX < lastQ, "reach did not move left bank toward edge") }
                                    lastQ = q.minX
                                    if reach > 0 { check(geometryRebuilt, "reach left stale swipe geometry") }
                                    let p = faces[caps.firstIndex { $0.accessibilityLabel == "p" }!]
                                    if reach == 100 {
                                        check(q.minX <= 4.01 && width - p.maxX <= 4.01, "reach left large outside margins")
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        for appearance in [UIUserInterfaceStyle.light, .dark] {
            board.overrideUserInterfaceStyle = appearance
            let preview = KeyPreview()
            preview.show("S", above: CGRect(x: 100, y: 115, width: 38, height: 45), in: board, font: .system, style: .ios)
            check(preview.frame.maxY == 112, "popup gap")
            check(preview.frame.height == 67.5, "popup height")
            preview.show("Q", above: CGRect(x: 0, y: 40, width: 38, height: 45), in: board, font: .system, style: .ios)
            check(preview.frame.maxY <= 37, "top popup detached")
        }
        print("iOS style layout checks: \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
