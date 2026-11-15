import UIKit

enum KeyboardFont: Int, CaseIterable {
    case system = 0
    case rounded = 1
    case serif = 2
    case monospaced = 3

    var title: String {
        switch self {
        case .system: "System"
        case .rounded: "Rounded"
        case .serif: "Serif"
        case .monospaced: "Monospaced"
        }
    }

    func font(ofSize size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        let design: UIFontDescriptor.SystemDesign
        switch self {
        case .system: return base
        case .rounded: design = .rounded
        case .serif: design = .serif
        case .monospaced: design = .monospaced
        }
        guard let descriptor = base.fontDescriptor.withDesign(design) else { return base }
        return UIFont(descriptor: descriptor, size: size)
    }

    static var stored: Self {
        KeyboardSetting.font.read().flatMap(Self.init(rawValue:)) ?? .system
    }

    func save() -> Bool { KeyboardSetting.font.save(UInt8(rawValue)) }
}
