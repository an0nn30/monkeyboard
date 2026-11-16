import UIKit

enum Key: Equatable {
    case type(String), shift, delete, layer, symbols, globe, space, rightSpace, enter

    var soundKey: TypingSoundKey {
        switch self {
        case .delete: .backspace
        case .space, .rightSpace: .space
        default: .regular
        }
    }

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
    enum Layer {
        case letters, numbers, symbols, keypad

        static func initial(for type: UIKeyboardType) -> Self {
            switch type {
            case .numberPad, .asciiCapableNumberPad, .decimalPad: return .keypad
            case .numbersAndPunctuation: return .numbers
            default: return .letters
            }
        }
    }
    enum Shift { case lower, upper, locked }
    var layer = Layer.letters
    var shift = Shift.lower
    var needsGlobe = false
    var isSplit = false
    var repeatSplitLetters = false
    var oneHanded = OneHandedLayout.fullWidth
    var keyboardType = UIKeyboardType.default

    var rows: [[Key]] {
        let lines: [String]
        switch layer {
        case .keypad:
            func digit(_ value: Int) -> Key {
                .type(keyboardType == .asciiCapableNumberPad ? String(value) : value.formatted(.number.locale(.current)))
            }
            var bottom: [Key] = []
            if keyboardType == .decimalPad { bottom.append(.type(Locale.current.decimalSeparator ?? ".")) }
            else if needsGlobe { bottom.append(.globe) }
            bottom += [digit(0), .delete]
            return [(1...3).map(digit), (4...6).map(digit), (7...9).map(digit), bottom]
        case .letters: lines = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
        case .numbers: lines = ["1234567890", "-/:;()$&@\"", ".,?!'"]
        case .symbols: lines = ["[]{}#%^*+=", "_\\|~<>€£¥\"", ".,?!'"]
        }
        var rows = lines.map { line in
            line.map { character in
                Key.type(layer == .letters && shift != .lower ? character.uppercased() : String(character))
            }
        }
        rows[2].insert(layer == .letters ? .shift : .symbols, at: 0)
        rows[2].append(.delete)
        // Keep the two extra controls across split/join transitions so they can
        // fold into their matching keys in the joined layout.
        for row in [0, 2] {
            if let index = repeatedLetterIndex(in: row) {
                let letter = rows[row][index]
                rows[row].insert(letter, at: index)
            }
        }
        var bottom: [Key] = [.layer]
        if needsGlobe { bottom.append(.globe) }
        let punctuation = keyboardType == .emailAddress ? "@" : (keyboardType == .URL ? "/" : ",")
        // Keep the second space control in both layouts so it can slide into the first.
        bottom += [.type(punctuation), .space, .rightSpace, .type("."), .enter]
        rows.append(bottom)
        return rows
    }

    /// The added key sits immediately before the original Y or B.
    func repeatedLetterIndex(in row: Int) -> Int? {
        guard repeatSplitLetters, layer == .letters, row == 0 || row == 2 else { return nil }
        return 5 // Q W E R T | Y, or Shift Z X C V | B
    }

    /// The first key in the right bank.
    func splitIndex(row: Int, count: Int) -> Int {
        if let extra = repeatedLetterIndex(in: row) { return extra + 1 }
        switch row {
        case 0, 1: return 5       // T | Y and G | H on the letter layer
        case 2: return (count + 1) / 2
        default: return count - 3 // Right space, period, Return
        }
    }
}
