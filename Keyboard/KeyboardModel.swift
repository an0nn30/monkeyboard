import UIKit

enum Key: Equatable {
    case type(String), shift, delete, layer, symbols, globe, space, rightSpace, enter

    var weight: CGFloat {
        switch self {
        case .shift, .delete, .symbols: return 1.4
        case .layer: return 1.7
        case .enter: return 1.9
        case .space, .rightSpace: return 5.7
        default: return 1
        }
    }
}

enum OneHandedLayout: Int, CaseIterable {
    case left = 1, fullWidth = 0, right = 2

    var title: String {
        switch self {
        case .left: return "Left Hand"
        case .fullWidth: return "Full Width"
        case .right: return "Right Hand"
        }
    }

    func typingArea(in bounds: CGRect) -> CGRect {
        guard self != .fullWidth else { return bounds }
        // Keep ten letters across, with a usable key width even on smaller phones.
        let width = min(bounds.width, max(272, min(342, (bounds.width * 0.80).rounded())))
        return CGRect(x: self == .left ? bounds.minX : bounds.maxX - width,
                      y: bounds.minY, width: width, height: bounds.height)
    }
}

struct KeyboardModel: Equatable {
    enum Layer { case letters, numbers, symbols }
    enum Shift { case lower, upper, locked }
    var layer = Layer.letters
    var shift = Shift.lower
    var needsGlobe = false
    var isSplit = false
    var oneHanded = OneHandedLayout.fullWidth
    var keyboardType = UIKeyboardType.default

    var rows: [[Key]] {
        let lines: [String]
        switch layer {
        case .letters: lines = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
        case .numbers: lines = ["1234567890", "-/:;()$&@", ".,?!'"]
        case .symbols: lines = ["[]{}#%^*+=", "_\\|~<>€£¥", ".,?!'"]
        }
        var rows = lines.map { line in
            line.map { character in
                Key.type(layer == .letters && shift != .lower ? character.uppercased() : String(character))
            }
        }
        rows[2].insert(layer == .letters ? .shift : .symbols, at: 0)
        rows[2].append(.delete)
        var bottom: [Key] = [.layer]
        if needsGlobe { bottom.append(.globe) }
        let punctuation = keyboardType == .emailAddress ? "@" : (keyboardType == .URL ? "/" : ",")
        // Keep the second space control in both layouts so it can slide into the first.
        bottom += [.type(punctuation), .space, .rightSpace, .type("."), .enter]
        rows.append(bottom)
        return rows
    }

    /// The first key in the right bank, in the same order as the joined layout.
    func splitIndex(row: Int, count: Int) -> Int {
        switch row {
        case 0, 1: return 5       // T | Y and G | H on the letter layer
        case 2: return (count + 1) / 2
        default: return count - 3 // Right space, period, Return
        }
    }
}
